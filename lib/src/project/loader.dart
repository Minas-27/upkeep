import 'dart:io';

import 'package:path/path.dart' as p;

import 'android.dart';
import 'lockfile.dart';
import 'pubspec.dart';
import 'references.dart';

/// Reads a project from disk for the command line.
///
/// Everything here is file system and process work. The parsing it feeds lives
/// in files with no `dart:io`, so the same engine also runs in a browser.

/// Reads `pubspec.yaml` from [projectRoot].
Pubspec loadPubspec(String projectRoot) {
  final file = File(p.join(projectRoot, 'pubspec.yaml'));
  if (!file.existsSync()) {
    throw const PubspecException(
        'No pubspec.yaml here. Run upkeep from a Dart or Flutter project directory.');
  }
  return Pubspec.parse(file.readAsStringSync());
}

/// Reads `pubspec.lock` from [projectRoot], or an empty lockfile when there is
/// none.
Lockfile loadLockfile(String projectRoot) {
  final file = File(p.join(projectRoot, 'pubspec.lock'));
  if (!file.existsSync()) return const Lockfile({});
  try {
    return Lockfile.parse(file.readAsStringSync());
  } on FileSystemException {
    return const Lockfile({});
  }
}

/// Reads the Android build configuration under [projectRoot].
///
/// Returns null when there is no `android/` directory, which is normal for
/// pure Dart packages and for Flutter projects targeting other platforms.
AndroidConfig? loadAndroidConfig(String projectRoot) {
  if (!Directory(p.join(projectRoot, 'android')).existsSync()) return null;

  final contents = <String, String>{};
  for (final path in AndroidConfig.files) {
    final file = File(p.joinAll([projectRoot, ...path.split('/')]));
    if (!file.existsSync()) continue;
    try {
      contents[path] = file.readAsStringSync();
    } on FileSystemException {
      continue;
    }
  }

  final jdk = _localJdk();
  return AndroidConfig.fromFiles(
    contents,
    jdkVersion: jdk?.$1,
    jdkSource: jdk?.$2,
    jdkUnavailableReason: jdk == null ? 'Could not run `java -version`.' : null,
  );
}

/// The local JDK, as reported by `java -version`.
///
/// This is the JDK on PATH, which is not necessarily the one Gradle uses. The
/// report says so rather than pretending otherwise.
(int, String)? _localJdk() {
  try {
    final result = Process.runSync('java', ['-version']);
    final output = '${result.stdout}${result.stderr}';
    final hit = RegExp(r'version\s+"([0-9]+)(?:\.([0-9]+))?').firstMatch(output);
    if (hit == null) return null;
    final major = int.parse(hit.group(1)!);
    // Java 8 and earlier report as 1.8.x; the real major is the second part.
    if (major == 1 && hit.group(2) != null) {
      return (int.parse(hit.group(2)!), 'java -version on PATH');
    }
    return (major, 'java -version on PATH');
  } on ProcessException {
    return null;
  }
}

/// Directories never worth walking: generated output, tool state, and native
/// dependency trees that hold no Dart the project wrote.
const _skipped = {'build', 'node_modules', 'Pods', 'ephemeral'};

/// Indexes where the project at [root] refers to [packageNames].
ReferenceIndex scanReferences(String root, Iterable<String> packageNames) {
  final dartFiles = <String, String>{};
  for (final file in _dartFiles(Directory(root))) {
    try {
      final relative = p.posix.joinAll(p.split(p.relative(file.path, from: root)));
      dartFiles[relative] = file.readAsStringSync();
    } on FileSystemException {
      continue;
    }
  }

  final rootYaml = <String, String>{};
  final dir = Directory(root);
  if (dir.existsSync()) {
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final base = p.basename(entity.path);
      if (!(base.endsWith('.yaml') || base.endsWith('.yml'))) continue;
      try {
        rootYaml[base] = entity.readAsStringSync();
      } on FileSystemException {
        continue;
      }
    }
  }

  return ReferenceIndex.fromSources(
    dartFiles: dartFiles,
    rootYaml: rootYaml,
    packageNames: packageNames,
  );
}

Iterable<File> _dartFiles(Directory dir) sync* {
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
