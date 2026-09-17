import 'dart:convert';

import '../fix/result.dart';
import '../fix/plan.dart';
import '../pub/client.dart';
import '../rules/android_matrix.dart';
import '../rules/dependency_health.dart';

/// The machine-readable form of every command, for CI and other tools.
///
/// The shape is a public contract like the exit codes. Fields are only ever
/// added; anything removed or renamed bumps [jsonSchemaVersion].
const int jsonSchemaVersion = 1;

const _encoder = JsonEncoder.withIndent('  ');

String encodeJson(Map<String, Object?> document) => _encoder.convert(document);

Map<String, Object?> _envelope(String command, String toolVersion, Map<String, Object?> body) => {
      'schemaVersion': jsonSchemaVersion,
      'tool': {'name': 'upkeep', 'version': toolVersion},
      'command': command,
      ...body,
    };

String _verdictKey(Verdict v) => switch (v) {
      Verdict.discontinued => 'discontinued',
      Verdict.incompatible => 'incompatible',
      Verdict.dead => 'dead',
      Verdict.atRisk => 'at_risk',
      Verdict.upgradeBlocked => 'sdk_blocked',
      Verdict.stale => 'stale',
      Verdict.healthy => 'healthy',
      Verdict.unknown => 'unknown',
    };

Map<String, Object?> dependencyJson(DependencyReport r) => {
      'name': r.name,
      'dev': r.isDev,
      'verdict': _verdictKey(r.verdict),
      'label': r.verdict.label,
      'blocking': r.verdict.isBlocking,
      'reasons': r.reasons,
      'declared': r.declaredConstraint,
      'resolved': r.resolvedVersion,
      'latest': r.info?.latestVersion.toString(),
      'behind': r.isBehind,
      'requiresDart': r.requiresDart,
      'replacement': r.replacedBy == null
          ? null
          : {
              'package': r.replacedBy,
              'source': r.replacementSource?.name,
              'evidence': r.replacementEvidence,
              'warnings': r.replacementWarnings,
            },
    };

Map<String, Object?> findingJson(MatrixFinding f) => {
      'level': f.level.name,
      'check': f.check.name,
      'title': f.title,
      'detail': f.detail,
      'fix': f.fix,
      'fixWhere': f.fixFile,
    };

String scanJson({
  required String toolVersion,
  required String projectName,
  required String dartVersion,
  required List<DependencyReport> dependencies,
  required int skippedCount,
  required bool androidChecked,
  required List<MatrixFinding> android,
  required int exitCode,
}) =>
    encodeJson(_envelope('scan', toolVersion, {
      'project': {'name': projectName, 'dart': dartVersion},
      'summary': {
        'blocking': dependencies.where((d) => d.verdict.isBlocking).length,
        'atRisk': dependencies.where((d) => d.verdict == Verdict.atRisk).length,
        'buildFailures': android.where((f) => f.level == FindingLevel.fail).length,
        'direct': dependencies.length,
        'skipped': skippedCount,
      },
      'dependencies': dependencies.map(dependencyJson).toList(),
      'android': {
        'checked': androidChecked,
        'findings': android.map(findingJson).toList(),
      },
      'exitCode': exitCode,
    }));

Map<String, Object?> _automaticJson(AutomaticFix fix) => {
      'kind': switch (fix) {
        RemoveDependency() => 'remove_dependency',
        RaiseGradleWrapper() => 'raise_gradle_wrapper',
      },
      'title': fix.title,
      'file': fix.file,
      'reasons': fix.reasons,
      ...switch (fix) {
        RemoveDependency(:final package, :final isDev) => {'package': package, 'dev': isDev},
        RaiseGradleWrapper(:final from, :final to) => {'from': from, 'to': to},
      },
    };

Map<String, Object?> _todoJson(FixTodo todo) => {
      'title': todo.title,
      'blocking': todo.isBlocking,
      'reasons': todo.reasons,
      'action': todo.action,
      'references': [
        for (final r in todo.references) {'file': r.file, 'line': r.line},
      ],
    };

String fixJson({
  required String toolVersion,
  required String projectName,
  required FixPlan plan,
  required ApplyResult? result,
  required String? refusedBecause,
  required int exitCode,
}) =>
    encodeJson(_envelope('fix', toolVersion, {
      'project': {'name': projectName},
      'applied': result != null,
      'automatic': plan.automatic.map(_automaticJson).toList(),
      'todos': plan.todos.map(_todoJson).toList(),
      if (result != null)
        'result': {
          'kept': result.applied.map((f) => f.title).toList(),
          'verifiedWith': result.verifiedWith,
          'revertedBecause': result.revertedBecause,
        },
      if (refusedBecause != null) 'refusedBecause': refusedBecause,
      'exitCode': exitCode,
    }));

String explainJson({
  required String toolVersion,
  required String package,
  required LookupStatus status,
  required DependencyReport? report,
  required bool declared,
  required List<Map<String, Object?>> references,
  required String dartVersion,
  required int exitCode,
}) {
  final info = report?.info;
  return encodeJson(_envelope('explain', toolVersion, {
    'package': package,
    'lookup': status.name,
    'declaredInProject': declared,
    'dart': dartVersion,
    'facts': info == null ? null : packageFactsJson(info),
    'result': report == null ? null : dependencyJson(report),
    'references': references,
    'exitCode': exitCode,
  }));
}

Map<String, Object?> packageFactsJson(PackageInfo info) => {
      'latest': info.latestVersion.toString(),
      'published': info.latestPublished.toIso8601String(),
      'monthsSinceRelease': info.monthsSinceRelease,
      'releases': info.releaseCount,
      'sdkConstraint': info.latestSdkConstraint?.toString(),
      'discontinued': info.isDiscontinued,
      'replacedBy': info.replacedBy,
      'flutterPlugin': info.isFlutterPlugin,
      'scoreAvailable': info.hasScoreData,
      'analysisFailed': info.analysisFailed,
      'points': info.hasScoreData ? info.grantedPoints : null,
      'maxPoints': info.hasScoreData ? info.maxPoints : null,
      'downloads30Days': info.hasScoreData ? info.downloads30Days : null,
      'likes': info.hasScoreData ? info.likeCount : null,
      'dart3Compatible': info.hasAnalysis ? info.isDart3Compatible : null,
      'publisher': info.publisher,
      'tags': info.tags,
    };
