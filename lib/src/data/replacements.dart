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
const String curatedReplacementsVerified = '2026-09-12';

const List<CuratedReplacement> curatedReplacements = <CuratedReplacement>[
  CuratedReplacement(
    package: 'datadog_flutter',
    replacement: 'datadog_flutter_plugin',
    evidenceUrl: 'https://pub.dev/packages/datadog_flutter',
    note: 'Community wrapper superseded by Datadog\'s official SDK (announcement: GetDutchie/datadog_flutter issue #108); repo archived',
  ),
  CuratedReplacement(
    package: 'envify',
    replacement: 'envied',
    evidenceUrl: 'https://pub.dev/packages/envify',
    note: 'Author says Envied works pretty much the same way as Envify; package and import names change',
  ),
  CuratedReplacement(
    package: 'flare_flutter',
    replacement: 'rive',
    evidenceUrl: 'https://github.com/2d-inc/Flare-Flutter',
    note: 'flare_flutter is the runtime for old Rive (Flare) files; rive is the runtime for the new Rive, so this is not a drop-in swap',
  ),
  CuratedReplacement(
    package: 'flutter_bucketeer',
    replacement: 'bucketeer_flutter_client_sdk',
    evidenceUrl: 'https://pub.dev/packages/flutter_bucketeer',
    note: 'V2 SDK lives in bucketeer-io/flutter-client-sdk, published as bucketeer_flutter_client_sdk; follow its setup instructions',
  ),
  CuratedReplacement(
    package: 'gallery',
    replacement: 'gal',
    evidenceUrl: 'https://pub.dev/packages/gallery',
    note: 'Same author and repository (natsuk4ze/gal)',
  ),
  CuratedReplacement(
    package: 'get_it_mixin',
    replacement: 'watch_it',
    evidenceUrl: 'https://pub.dev/packages/get_it_mixin',
    note: 'Same author; API is overhauled, author says porting from get_it_mixin is really easy and quick',
  ),
  CuratedReplacement(
    package: 'intercom',
    replacement: 'intercom_flutter',
    evidenceUrl: 'https://pub.dev/packages/intercom',
  ),
  CuratedReplacement(
    package: 'modular_di',
    replacement: 'flutter_easy_di',
    evidenceUrl: 'https://pub.dev/packages/modular_di',
    note: 'Same author; README says swap the dependency, then follow the flutter_easy_di docs to update code',
  ),
  CuratedReplacement(
    package: 'native_pdf_renderer',
    replacement: 'pdfx',
    evidenceUrl: 'https://pub.dev/packages/native_pdf_renderer',
    note: 'Renamed by the same author; README lists smaller API changes: PdfPageFormat -> PdfPageImageFormat, enum values lower-cased (jpeg, png, webp)',
  ),
  CuratedReplacement(
    package: 'native_pdf_view',
    replacement: 'pdfx',
    evidenceUrl: 'https://pub.dev/packages/native_pdf_view',
    note: 'Renamed by the same author; README lists smaller API changes: PdfPageFormat -> PdfPageImageFormat, enum values lower-cased (jpeg, png, webp)',
  ),
  CuratedReplacement(
    package: 'pagecall_flutter',
    replacement: 'flutter_pagecall',
    evidenceUrl: 'https://pub.dev/packages/pagecall_flutter',
    note: 'Same publisher and repository (pagecall/flutter-pagecall)',
  ),
  CuratedReplacement(
    package: 'pdf_render',
    replacement: 'pdfrx',
    evidenceUrl: 'https://pub.dev/packages/pdf_render',
    note: 'Same author; README says pdfrx is not a full drop-in replacement',
  ),
  CuratedReplacement(
    package: 'qr_code_scanner',
    replacement: 'mobile_scanner',
    evidenceUrl: 'https://pub.dev/packages/qr_code_scanner',
    note: 'New plugin by the same maintainer (MLKit, CameraX on Android, AVFoundation on iOS), not a rename; expect API changes',
  ),
  CuratedReplacement(
    package: 'xrp_dart',
    replacement: 'xrpl_dart',
    evidenceUrl: 'https://pub.dev/packages/xrp_dart',
    note: 'Rename by the same author and repo; xrpl_dart has since moved several major versions (4.x -> 7.x)',
  ),
];

/// The curated successor for [package], if there is one.
CuratedReplacement? curatedReplacementFor(String package) {
  for (final entry in curatedReplacements) {
    if (entry.package == package) return entry;
  }
  return null;
}
