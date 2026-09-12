import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// Where a declared dependency comes from.
enum DepSource {
  /// A normal package resolved from pub.dev. The only kind `upkeep` can judge.
  hosted,

  /// Shipped with an SDK, such as `flutter` or `flutter_test`.
  sdk,

  /// Pinned to a git repository.
  git,

  /// Pinned to a local directory.
  path,
}

/// One dependency as declared in `pubspec.yaml`.
class DeclaredDependency {
  const DeclaredDependency({
    required this.name,
    required this.source,
    required this.isDev,
    this.constraint,
  });

  final String name;
  final DepSource source;

  /// True when declared under `dev_dependencies`.
  final bool isDev;

  /// The version constraint as written, for hosted dependencies.
  final String? constraint;
}

/// A parsed `pubspec.yaml`.
class Pubspec {
  const Pubspec({
    required this.name,
    required this.dependencies,
    this.sdkConstraint,
    this.flutterConstraint,
    required this.isFlutterProject,
  });

  final String name;
  final List<DeclaredDependency> dependencies;

  /// The `environment.sdk` constraint, when parseable.
  final VersionConstraint? sdkConstraint;

  /// The `environment.flutter` constraint, when present.
  final String? flutterConstraint;

  /// True when the project depends on the Flutter SDK.
  final bool isFlutterProject;

  /// Parses the text of a `pubspec.yaml`.
  ///
  /// Throws [PubspecException] when it is unusable, because a project without a
  /// readable pubspec is not a project `upkeep` can report on.
  static Pubspec parse(String text) {
    final Object? parsed;
    try {
      parsed = loadYaml(text);
    } on YamlException catch (e) {
      throw PubspecException('pubspec.yaml is not valid YAML: ${e.message}');
    }
    if (parsed is! YamlMap) {
      throw const PubspecException('pubspec.yaml did not parse to a YAML map.');
    }

    final name = parsed['name'];
    if (name is! String || name.isEmpty) {
      throw const PubspecException('pubspec.yaml has no package name.');
    }

    VersionConstraint? sdk;
    String? flutterConstraint;
    final env = parsed['environment'];
    if (env is YamlMap) {
      final rawSdk = env['sdk'];
      if (rawSdk is String) {
        try {
          sdk = VersionConstraint.parse(rawSdk);
        } on FormatException {
          sdk = null;
        }
      }
      final rawFlutter = env['flutter'];
      if (rawFlutter is String) flutterConstraint = rawFlutter;
    }

    final deps = <DeclaredDependency>[
      ..._readBlock(parsed['dependencies'], isDev: false),
      ..._readBlock(parsed['dev_dependencies'], isDev: true),
    ];

    return Pubspec(
      name: name,
      dependencies: deps,
      sdkConstraint: sdk,
      flutterConstraint: flutterConstraint,
      isFlutterProject: deps.any((d) => d.name == 'flutter' && d.source == DepSource.sdk),
    );
  }

  static List<DeclaredDependency> _readBlock(Object? block, {required bool isDev}) {
    if (block is! YamlMap) return const [];
    final out = <DeclaredDependency>[];
    for (final entry in block.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final value = entry.value;

      if (value == null || value is String) {
        out.add(DeclaredDependency(
          name: key,
          source: DepSource.hosted,
          isDev: isDev,
          constraint: value is String && value.isNotEmpty ? value : 'any',
        ));
        continue;
      }

      if (value is YamlMap) {
        if (value.containsKey('sdk')) {
          out.add(DeclaredDependency(name: key, source: DepSource.sdk, isDev: isDev));
        } else if (value.containsKey('git')) {
          out.add(DeclaredDependency(name: key, source: DepSource.git, isDev: isDev));
        } else if (value.containsKey('path')) {
          out.add(DeclaredDependency(name: key, source: DepSource.path, isDev: isDev));
        } else {
          final hosted = value['version'];
          out.add(DeclaredDependency(
            name: key,
            source: DepSource.hosted,
            isDev: isDev,
            constraint: hosted is String ? hosted : 'any',
          ));
        }
      }
    }
    return out;
  }
}

/// Raised when `pubspec.yaml` cannot be read or understood.
class PubspecException implements Exception {
  const PubspecException(this.message);
  final String message;
  @override
  String toString() => message;
}
