import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The resolved versions recorded in `pubspec.lock`.
///
/// Optional by design: a project that has never run `pub get` should still get
/// a useful report, just without "you are N versions behind".
class Lockfile {
  const Lockfile(this._versions);

  final Map<String, String> _versions;

  /// The resolved version of [package], or null when it is not locked.
  String? versionOf(String package) => _versions[package];

  /// True when nothing was resolved.
  bool get isEmpty => _versions.isEmpty;

  /// Reads `pubspec.lock` from [projectRoot], returning an empty lockfile when
  /// it is absent or unreadable.
  static Lockfile load(String projectRoot) {
    final file = File(p.join(projectRoot, 'pubspec.lock'));
    if (!file.existsSync()) return const Lockfile({});

    final Object? parsed;
    try {
      parsed = loadYaml(file.readAsStringSync());
    } on YamlException {
      return const Lockfile({});
    }
    if (parsed is! YamlMap) return const Lockfile({});

    final packages = parsed['packages'];
    if (packages is! YamlMap) return const Lockfile({});

    final out = <String, String>{};
    for (final entry in packages.entries) {
      final name = entry.key;
      final body = entry.value;
      if (name is! String || body is! YamlMap) continue;
      final version = body['version'];
      if (version is String) out[name] = version;
    }
    return Lockfile(out);
  }
}
