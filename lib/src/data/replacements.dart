/// Successors for packages that died without ever being marked discontinued.
///
/// pub.dev's `replacedBy` only exists when a publisher bothered to set it. Most
/// dead packages were simply left behind, and the person who needs a successor
/// is left to search. This map fills that gap, and it holds itself to a higher
/// bar than anything else in upkeep, because naming the wrong successor sends
/// someone down a migration for nothing:
///
/// - every entry cites a primary source: the old package's own README or repo
///   naming the successor, or the same author publishing the continuation
/// - where several alternatives compete and nobody official named one, the
///   package is left out rather than picked for
/// - an entry is only ever shown for a package the engine already judged
///   unhealthy, and only when the successor itself checks out healthy today
///
/// Last verified: see [curatedReplacementsVerified].
library;

/// One curated successor, with the evidence behind it.
class CuratedReplacement {
  const CuratedReplacement({
    required this.package,
    required this.replacement,
    required this.evidenceUrl,
    this.note,
  });

  /// The dead package.
  final String package;

  /// The package to move to.
  final String replacement;

  /// Where the successor is named. A reader must be able to check it.
  final String evidenceUrl;

  /// What the migration involves, when that was verified.
  final String? note;
}

/// The date the entries below were last checked against pub.dev and their
/// sources.
const String curatedReplacementsVerified = '';

const List<CuratedReplacement> curatedReplacements = <CuratedReplacement>[];

/// The curated successor for [package], if there is one.
CuratedReplacement? curatedReplacementFor(String package) {
  for (final entry in curatedReplacements) {
    if (entry.package == package) return entry;
  }
  return null;
}
