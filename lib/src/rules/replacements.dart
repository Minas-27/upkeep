import '../data/replacements.dart';
import '../project/pubspec.dart';
import '../pub/client.dart';
import 'dependency_health.dart';

/// Attaches curated successors to reports that need one.
///
/// A curated successor is a suggestion, so it is held back unless both halves
/// check out: the dependency must already be judged unhealthy on its own
/// evidence, and the successor must be judged healthy today by the same engine.
/// Recommending a package that is itself dying would be worse than silence.
class CuratedReplacements {
  const CuratedReplacements({this.lookup = curatedReplacementFor});

  final CuratedReplacement? Function(String package) lookup;

  static const _eligible = {
    Verdict.discontinued,
    Verdict.incompatible,
    Verdict.dead,
    Verdict.atRisk,
  };

  /// The successor packages that need looking up for [reports].
  List<String> candidates(List<DependencyReport> reports) => {
        for (final r in reports)
          if (r.replacedBy == null && _eligible.contains(r.verdict) && lookup(r.name) != null)
            lookup(r.name)!.replacement,
      }.toList();

  /// [reports], with a successor attached wherever one was vouched for.
  List<DependencyReport> attach(
    List<DependencyReport> reports,
    Map<String, PackageLookup> successorLookups,
    HealthEngine engine,
  ) {
    return [
      for (final report in reports) _attachOne(report, successorLookups, engine),
    ];
  }

  DependencyReport _attachOne(
    DependencyReport report,
    Map<String, PackageLookup> lookups,
    HealthEngine engine,
  ) {
    if (report.replacedBy != null || !_eligible.contains(report.verdict)) return report;
    final entry = lookup(report.name);
    if (entry == null) return report;

    final successor = lookups[entry.replacement];
    if (successor?.info == null) return report;

    final judged = engine.evaluate(
      [DeclaredDependency(name: entry.replacement, source: DepSource.hosted, isDev: report.isDev)],
      {entry.replacement: successor!},
      (_) => null,
    ).single;
    if (judged.verdict != Verdict.healthy && judged.verdict != Verdict.stale) return report;

    return report.withCuratedReplacement(entry.replacement, entry.evidenceUrl);
  }
}
