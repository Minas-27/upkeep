import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// One place a package is mentioned in the project.
class Reference {
  const Reference(this.file, this.line);

  /// Path relative to the project root, with forward slashes.
  final String file;

  /// 1-based line number.
  final int line;

  @override
  String toString() => '$file:$line';
}

/// Every place the project refers to its dependencies.
///
/// Built to be conservative. Its one job in `upkeep fix` is to say "nothing
/// uses this package", and a false "nothing" deletes code someone needed. So a
/// mention in a comment counts, a mention in any YAML config counts, and a
/// package with its own top-level config key in `pubspec.yaml` counts. A wrong
/// "still used" only costs a manual step.
class ReferenceIndex {
  ReferenceIndex._(this._dart, this._config);

  final Map<String, List<Reference>> _dart;
  final Set<String> _config;

  /// Directories never worth walking: generated output, tool state, and native
  /// dependency trees that hold no Dart the project wrote.
  static const _skipped = {'build', 'node_modules', 'Pods', 'ephemeral'};

  static final _packageUri = RegExp(r'\bpackage:([a-zA-Z0-9_]+)/');

  /// The Dart files that mention `package:<name>/`, with line numbers.
  List<Reference> dartReferencesTo(String name) => _dart[name] ?? const [];

  /// True when [name] appears in project configuration rather than Dart code:
  /// an `analysis_options.yaml` include, a `build.yaml` builder, a top-level
  /// key in `pubspec.yaml` such as `flutter_launcher_icons:`, or a config file
  /// named after the package.
  bool isConfiguredByName(String name) => _config.contains(name);

  /// True when anything at all in the project refers to [name].
  bool isReferenced(String name) => dartReferencesTo(name).isNotEmpty || isConfiguredByName(name);

  /// Indexes the project at [root].
  static ReferenceIndex scan(String root, Iterable<String> packageNames) {
    final names = packageNames.toSet();
    final dart = <String, List<Reference>>{};
    final config = <String>{};

    for (final file in _dartFiles(Directory(root))) {
      final List<String> lines;
      try {
        lines = file.readAsLinesSync();
      } on FileSystemException {
        continue;
      }
      final relative = p.posix.joinAll(p.split(p.relative(file.path, from: root)));
      for (var i = 0; i < lines.length; i++) {
        for (final match in _packageUri.allMatches(lines[i])) {
          final name = match.group(1)!;
          if (!names.contains(name)) continue;
          final refs = dart.putIfAbsent(name, () => []);
          if (refs.isEmpty || refs.last.file != relative || refs.last.line != i + 1) {
            refs.add(Reference(relative, i + 1));
          }
        }
      }
    }

    final rootDir = Directory(root);
    if (rootDir.existsSync()) {
      for (final entity in rootDir.listSync()) {
        if (entity is! File) continue;
        final base = p.basename(entity.path);
        if (base == 'pubspec.lock' || !(base.endsWith('.yaml') || base.endsWith('.yml'))) continue;
        for (final name in names) {
          if (base.startsWith('$name.') || base.startsWith('${name}_')) config.add(name);
        }
        if (base == 'pubspec.yaml') {
          config.addAll(_pubspecConfigKeys(entity).where(names.contains));
          continue;
        }
        final String text;
        try {
          text = entity.readAsStringSync();
        } on FileSystemException {
          continue;
        }
        for (final name in names) {
          if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(text)) config.add(name);
        }
      }
    }

    return ReferenceIndex._(dart, config);
  }

  /// Top-level `pubspec.yaml` keys that are not pub's own, which is where
  /// tools like `flutter_launcher_icons` read their configuration from.
  static Iterable<String> _pubspecConfigKeys(File pubspec) {
    const standard = {
      'name', 'description', 'version', 'homepage', 'repository', 'issue_tracker',
      'documentation', 'publish_to', 'environment', 'dependencies', 'dev_dependencies',
      'dependency_overrides', 'flutter', 'executables', 'platforms', 'funding', 'topics',
      'screenshots', 'false_secrets', 'ignored_advisories', 'workspace', 'resolution',
    };
    try {
      final parsed = loadYaml(pubspec.readAsStringSync());
      if (parsed is! YamlMap) return const [];
      return parsed.keys.whereType<String>().where((k) => !standard.contains(k));
    } on Exception {
      return const [];
    }
  }

  static Iterable<File> _dartFiles(Directory dir) sync* {
    if (!dir.existsSync()) return;
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entity in entries) {
      final base = p.basename(entity.path);
      if (entity is Directory) {
        if (base.startsWith('.') || _skipped.contains(base)) continue;
        yield* _dartFiles(entity);
      } else if (entity is File && base.endsWith('.dart')) {
        yield entity;
      }
    }
  }
}
