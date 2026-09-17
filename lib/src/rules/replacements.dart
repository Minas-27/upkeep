import '../data/replacements.dart';
import '../project/pubspec.dart';
import '../pub/client.dart';
import 'dependency_health.dart';

/// Attaches successors to reports that need one, and vets every successor
/// against the same engine that judged the dependency.
///
/// Both kinds of successor are checked, but a failed check means different
/// things, because the two are different claims:
///
/// - A **curated** successor is upkeep's own suggestion. It is held back unless
///   both halves check out: the dependency must already be judged unhealthy on
///   its own evidence, and the successor must be healthy today. Recommending a
///   package that is itself dying would be worse than silence.
/// - A **publisher's** successor, from pub.dev's `replacedBy`, is a fact about
///   the package rather than a suggestion, so it is never withheld. Nobody
///   reviews that field, though, and it can point somewhere worse than where
///   the reader already is: `super_editor_markdown` nominates `super_editor`,
///   which has had no stable release since June 2024, seventeen months longer
///   than the package it replaces. So the nomination is shown, with what the
///   engine knows about it attached.
///
/// Either way the reader is never handed a bare "move to X".
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
  ///
  /// Both the ones a curated entry would suggest and the ones a publisher
  /// already named, since those are vetted too.
  List<String> candidates(List<DependencyReport> reports) {
    final wanted = <String>{};
    for (final report in reports) {
      if (!_eligible.contains(report.verdict)) continue;
      final named = report.replacedBy;
      if (named != null) {
        wanted.add(named);
        continue;
      }
      final entry = lookup(report.name);
      if (entry != null) wanted.add(entry.replacement);
    }
    return wanted.toList();
  }

  /// [reports], with a successor attached wherever one was vouched for, and
  /// with a publisher's successor annotated wherever it does not check out.
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
    if (!_eligible.contains(report.verdict)) return report;

    // The publisher already named one. Never withheld, only annotated.
    if (report.replacedBy != null) {
      final trouble = _troubleWith(report.replacedBy!, report, lookups, engine);
      return trouble.isEmpty ? report : report.withReplacementWarnings(trouble);
    }

    final entry = lookup(report.name);
    if (entry == null) return report;

    // Could not be checked, so it is not vouched for. Missing data is never
    // evidence, in either direction.
    if (lookups[entry.replacement]?.info == null) return report;
    if (!_vouchesFor(entry.replacement, report, lookups, engine)) return report;

    return report.withCuratedReplacement(entry.replacement, entry.evidenceUrl);
  }

  /// Whether a curated successor is good enough to suggest.
  ///
  /// STALE passes here, and deliberately: a small, finished package that has
  /// not needed a release is done, not dying, and a curated entry was reviewed
  /// by a person against a cited source before it ever got here.
  bool _vouchesFor(
    String successorName,
    DependencyReport report,
    Map<String, PackageLookup> lookups,
    HealthEngine engine,
  ) {
    final verdict = _judge(successorName, report, lookups, engine)?.verdict;
    return verdict == Verdict.healthy || verdict == Verdict.stale;
  }

  /// What the engine says is worth knowing about [successorName] before
  /// migrating to it.
  ///
  /// A lower bar than [_vouchesFor], because this annotates a nomination
  /// nobody reviewed rather than vouching for one. STALE counts here: "quiet
  /// for a while" is fine for a package already in a pubspec and worth a
  /// sentence when someone is about to spend a week moving to it.
  ///
  /// Empty when the successor is healthy, and equally when pub.dev did not
  /// answer for it or could not judge it. Missing data is never evidence.
  List<String> _troubleWith(
    String successorName,
    DependencyReport report,
    Map<String, PackageLookup> lookups,
    HealthEngine engine,
  ) {
    final judged = _judge(successorName, report, lookups, engine);
    if (judged == null) return const [];
    return switch (judged.verdict) {
      Verdict.healthy || Verdict.unknown => const [],
      _ => judged.reasons,
    };
  }

  /// [successorName] put through the same engine, or null when pub.dev did not
  /// answer for it.
  DependencyReport? _judge(
    String successorName,
    DependencyReport report,
    Map<String, PackageLookup> lookups,
    HealthEngine engine,
  ) {
    final successor = lookups[successorName];
    if (successor?.info == null) return null;
    return engine.evaluate(
      [DeclaredDependency(name: successorName, source: DepSource.hosted, isDev: report.isDev)],
      {successorName: successor!},
      (_) => null,
    ).single;
  }
}
