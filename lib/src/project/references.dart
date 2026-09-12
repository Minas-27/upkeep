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
  const ReferenceIndex._(this._dart, this._config) : known = true;

  /// An index for a project whose code could not be read.
  ///
  /// Every package counts as referenced, because not having looked is not the
  /// same as having found nothing.
  const ReferenceIndex.unknown()
      : _dart = const {},
        _config = const {},
        known = false;

  final Map<String, List<Reference>> _dart;
  final Set<String> _config;

  /// False when the project's code was never read.
  final bool known;

  static final _packageUri = RegExp(r'\bpackage:([a-zA-Z0-9_]+)/');

  /// The Dart files that mention `package:<name>/`, with line numbers.
  List<Reference> dartReferencesTo(String name) => _dart[name] ?? const [];

  /// True when [name] appears in project configuration rather than Dart code:
  /// an `analysis_options.yaml` include, a `build.yaml` builder, a top-level
  /// key in `pubspec.yaml` such as `flutter_launcher_icons:`, or a config file
  /// named after the package.
  bool isConfiguredByName(String name) => _config.contains(name);

  /// True when anything at all in the project refers to [name], or when the
  /// project's code was never read.
  bool isReferenced(String name) =>
      !known || dartReferencesTo(name).isNotEmpty || isConfiguredByName(name);

  /// Indexes file contents.
  ///
  /// [dartFiles] maps project-relative paths to Dart source. [rootYaml] maps
  /// the names of YAML files at the project root, `pubspec.yaml` included, to
  /// their text.
  static ReferenceIndex fromSources({
    required Map<String, String> dartFiles,
    required Map<String, String> rootYaml,
    required Iterable<String> packageNames,
  }) {
    final names = packageNames.toSet();
    final dart = <String, List<Reference>>{};
    final config = <String>{};

    final paths = dartFiles.keys.toList()..sort();
    for (final path in paths) {
      final lines = dartFiles[path]!.split('\n');
      for (var i = 0; i < lines.length; i++) {
        for (final match in _packageUri.allMatches(lines[i])) {
          final name = match.group(1)!;
          if (!names.contains(name)) continue;
          final refs = dart.putIfAbsent(name, () => []);
          if (refs.isEmpty || refs.last.file != path || refs.last.line != i + 1) {
            refs.add(Reference(path, i + 1));
          }
        }
      }
    }

    rootYaml.forEach((base, text) {
      if (base == 'pubspec.lock') return;
      for (final name in names) {
        if (base.startsWith('$name.') || base.startsWith('${name}_')) config.add(name);
      }
      if (base == 'pubspec.yaml') {
        config.addAll(_pubspecConfigKeys(text).where(names.contains));
        return;
      }
      for (final name in names) {
        if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(text)) config.add(name);
      }
    });

    return ReferenceIndex._(dart, config);
  }

  /// Top-level `pubspec.yaml` keys that are not pub's own, which is where
  /// tools like `flutter_launcher_icons` read their configuration from.
  static Iterable<String> _pubspecConfigKeys(String text) {
    const standard = {
      'name', 'description', 'version', 'homepage', 'repository', 'issue_tracker',
      'documentation', 'publish_to', 'environment', 'dependencies', 'dev_dependencies',
      'dependency_overrides', 'flutter', 'executables', 'platforms', 'funding', 'topics',
      'screenshots', 'false_secrets', 'ignored_advisories', 'workspace', 'resolution',
    };
    try {
      final parsed = loadYaml(text);
      if (parsed is! YamlMap) return const [];
      return parsed.keys.whereType<String>().where((k) => !standard.contains(k));
    } on Exception {
      return const [];
    }
  }
}
