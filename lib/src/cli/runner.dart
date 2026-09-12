import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import '../project/android.dart';
import '../project/lockfile.dart';
import '../project/pubspec.dart';
import '../pub/cache.dart';
import '../pub/client.dart';
import '../report/terminal.dart';
import '../rules/android_matrix.dart';
import '../rules/dependency_health.dart';

/// The published version of this tool.
const String upkeepVersion = '0.1.0';

/// Process exit codes. CI depends on these, so they are part of the contract.
abstract final class ExitCodes {
  /// Nothing blocking found.
  static const int clean = 0;

  /// Blocking findings: a discontinued, incompatible or dead dependency, or an
  /// Android matrix combination that does not build.
  static const int findings = 1;

  /// The scan could not run at all.
  static const int error = 2;
}

/// Runs `upkeep scan` and returns the process exit code.
Future<int> runScan({
  required String projectPath,
  bool useCache = true,
  bool failOnAtRisk = false,
  Style? style,
  StringSink? out,
  PubClient? client,
}) async {
  final sink = out ?? stdout;
  final styling = style ?? Style();

  final Pubspec pubspec;
  try {
    pubspec = Pubspec.load(projectPath);
  } on PubspecException catch (e) {
    sink.writeln(styling.red('upkeep: ${e.message}'));
    return ExitCodes.error;
  }

  final lock = Lockfile.load(projectPath);
  final android = AndroidConfig.load(projectPath);

  final hosted =
      pubspec.dependencies.where((d) => d.source == DepSource.hosted).map((d) => d.name).toList();
  final skipped = pubspec.dependencies.length - hosted.length;

  final cache = ResponseCache();
  if (!useCache) cache.clear();
  final pub = client ?? PubClient(cache: cache);

  final lookups = await pub.fetchAll(hosted);
  if (client == null) pub.close();

  final engine = HealthEngine(dartSdkVersion: currentDartVersion());
  final dependencies = engine.evaluate(
    pubspec.dependencies,
    lookups,
    lock.versionOf,
  );

  final androidFindings =
      android == null ? const <MatrixFinding>[] : const AndroidMatrixChecker().check(android);

  TerminalReport(style: styling, out: sink).render(
    projectName: pubspec.name,
    dartVersion: currentDartVersion().toString(),
    toolVersion: upkeepVersion,
    dependencies: dependencies,
    skippedCount: skipped,
    android: androidFindings,
    androidChecked: android != null,
  );

  final blocking = dependencies.any((d) => d.verdict.isBlocking) ||
      androidFindings.any((f) => f.level == FindingLevel.fail) ||
      (failOnAtRisk && dependencies.any((d) => d.verdict == Verdict.atRisk));

  return blocking ? ExitCodes.findings : ExitCodes.clean;
}

/// The Dart SDK running this process.
///
/// `Platform.version` looks like `3.11.0 (stable) (...) on "linux_x64"`, so the
/// version is the first token. Build-channel suffixes such as `-dev.1` are
/// dropped, because a pre-release Dart should be treated as its release line
/// when judging whether a package supports it.
Version currentDartVersion() {
  final token = Platform.version.split(' ').first;
  try {
    final parsed = Version.parse(token);
    return Version(parsed.major, parsed.minor, parsed.patch);
  } on FormatException {
    return Version(3, 0, 0);
  }
}
