import 'package:pub_semver/pub_semver.dart';

import 'project/android.dart';
import 'project/lockfile.dart';
import 'project/pubspec.dart';
import 'pub/client.dart';
import 'rules/android_matrix.dart';
import 'rules/dependency_health.dart';
import 'rules/replacements.dart';

/// Everything upkeep concludes about one project.
///
/// The command line and the web app both come through [analyzeProject], so the
/// terminal and the browser can never disagree about a verdict.
class ProjectAnalysis {
  const ProjectAnalysis({
    required this.pubspec,
    required this.dependencies,
    required this.skipped,
    required this.android,
    required this.androidFindings,
    required this.dartVersion,
  });

  final Pubspec pubspec;
  final List<DependencyReport> dependencies;

  /// Declared dependencies that are not hosted on pub.dev.
  final int skipped;
  final AndroidConfig? android;
  final List<MatrixFinding> androidFindings;

  /// The Dart the verdicts were judged against.
  final Version dartVersion;
}

/// Judges [pubspec] against pub.dev facts and the Android matrix.
Future<ProjectAnalysis> analyzeProject({
  required Pubspec pubspec,
  required Lockfile lockfile,
  required AndroidConfig? android,
  required PubClient pub,
  required Version dartVersion,
}) async {
  final hosted =
      pubspec.dependencies.where((d) => d.source == DepSource.hosted).map((d) => d.name).toList();
  final engine = HealthEngine(dartSdkVersion: dartVersion);
  final lookups = await pub.fetchAll(hosted);
  final dependencies = await attachSuccessors(
    engine.evaluate(pubspec.dependencies, lookups, lockfile.versionOf),
    pub,
    engine,
  );
  return ProjectAnalysis(
    pubspec: pubspec,
    dependencies: dependencies,
    skipped: pubspec.dependencies.length - hosted.length,
    android: android,
    androidFindings: android == null ? const [] : const AndroidMatrixChecker().check(android),
    dartVersion: dartVersion,
  );
}

/// Looks up and attaches curated successors for [reports].
Future<List<DependencyReport>> attachSuccessors(
  List<DependencyReport> reports,
  PubClient pub,
  HealthEngine engine,
) async {
  const curated = CuratedReplacements();
  final wanted = curated.candidates(reports);
  if (wanted.isEmpty) return reports;
  return curated.attach(reports, await pub.fetchAll(wanted), engine);
}
