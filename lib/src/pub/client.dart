import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import 'cache.dart';

/// What pub.dev knows about one package.
class PackageInfo {
  const PackageInfo({
    required this.name,
    required this.latestVersion,
    required this.latestPublished,
    required this.latestSdkConstraint,
    required this.grantedPoints,
    required this.maxPoints,
    required this.likeCount,
    required this.downloads30Days,
    required this.tags,
    required this.releaseCount,
    required this.isDiscontinued,
    this.replacedBy,
    required this.hasScoreData,
  });

  final String name;
  final Version latestVersion;
  final DateTime latestPublished;

  /// The `environment.sdk` constraint of the latest version, when parseable.
  final VersionConstraint? latestSdkConstraint;

  final int grantedPoints;
  final int maxPoints;
  final int likeCount;
  final int downloads30Days;
  final List<String> tags;

  /// How many versions have ever been published.
  final int releaseCount;

  /// pub.dev's own "this package is discontinued" flag. Authoritative.
  final bool isDiscontinued;

  /// The package the author nominated as the replacement, when they named one.
  final String? replacedBy;

  /// True when pub.dev's score endpoint actually answered.
  ///
  /// This matters more than it looks. When the score request fails, points are
  /// zero and the tag list is empty, which reads exactly like a badly
  /// maintained package. Every rule that leans on scores or tags must check
  /// this first, or upkeep will accuse healthy packages of being abandoned on
  /// nothing more than a dropped connection.
  final bool hasScoreData;

  /// Score as a fraction of the maximum, or null when pub.dev reported no max.
  double? get pointsRatio => maxPoints <= 0 ? null : grantedPoints / maxPoints;

  /// Whole months since the most recent release.
  int get monthsSinceRelease {
    final days = DateTime.now().toUtc().difference(latestPublished).inDays;
    return (days / 30.44).floor();
  }

  bool get isDart3Compatible => tags.contains('is:dart3-compatible');
  bool get isWasmReady => tags.contains('is:wasm-ready');
  bool get isFlutterFavorite => tags.contains('is:flutter-favorite');

  /// True when pub.dev reports no OSI-approved license.
  bool get lacksOpenLicense => !tags.any((t) => t.startsWith('license:osi-approved'));

  /// The verified publisher, when the package has one.
  String? get publisher {
    for (final tag in tags) {
      if (tag.startsWith('publisher:')) return tag.substring('publisher:'.length);
    }
    return null;
  }
}

/// Reads package facts from the public pub.dev API.
class PubClient {
  PubClient({http.Client? httpClient, ResponseCache? cache, this.concurrency = 8})
      : _http = httpClient ?? http.Client(),
        _cache = cache ?? ResponseCache();

  final http.Client _http;
  final ResponseCache _cache;

  /// How many packages to look up at once. Deliberately modest: this hits a
  /// free public API that owes us nothing.
  final int concurrency;

  static const _base = 'https://pub.dev/api/packages';

  /// Looks up every name in [names].
  ///
  /// Every name gets an entry, including the ones that failed. Silently
  /// dropping failures is how a tool ends up reporting a verdict it did not
  /// earn.
  Future<Map<String, PackageLookup>> fetchAll(List<String> names) async {
    final out = <String, PackageLookup>{};
    for (var i = 0; i < names.length; i += concurrency) {
      final batch = names.skip(i).take(concurrency);
      final results = await Future.wait(batch.map(fetch));
      for (final lookup in results) {
        out[lookup.name] = lookup;
      }
    }
    return out;
  }

  /// Looks up one package.
  Future<PackageLookup> fetch(String name) async {
    final metaResult = await _get('$_base/$name', 'pkg_$name');
    if (metaResult.outcome == _Outcome.notFound) {
      return PackageLookup(name: name, status: LookupStatus.notFound);
    }
    final meta = metaResult.body;
    if (meta == null) {
      return PackageLookup(name: name, status: LookupStatus.unreachable);
    }

    final scoreResult = await _get('$_base/$name/score', 'score_$name');
    final hasScore = scoreResult.body != null;
    final score = scoreResult.body ?? const <String, dynamic>{};

    final latest = meta['latest'];
    if (latest is! Map<String, dynamic>) {
      return PackageLookup(name: name, status: LookupStatus.unreachable);
    }

    final rawVersion = latest['version'];
    final rawPublished = latest['published'];
    if (rawVersion is! String || rawPublished is! String) {
      return PackageLookup(name: name, status: LookupStatus.unreachable);
    }

    final Version version;
    try {
      version = Version.parse(rawVersion);
    } on FormatException {
      return PackageLookup(name: name, status: LookupStatus.unreachable);
    }

    final published = DateTime.tryParse(rawPublished);
    if (published == null) {
      return PackageLookup(name: name, status: LookupStatus.unreachable);
    }

    VersionConstraint? sdk;
    final pubspec = latest['pubspec'];
    if (pubspec is Map<String, dynamic>) {
      final env = pubspec['environment'];
      if (env is Map<String, dynamic> && env['sdk'] is String) {
        try {
          sdk = VersionConstraint.parse(env['sdk'] as String);
        } on FormatException {
          sdk = null;
        }
      }
    }

    final versions = meta['versions'];

    return PackageLookup(
      name: name,
      status: LookupStatus.found,
      info: PackageInfo(
      name: name,
      latestVersion: version,
      latestPublished: published.toUtc(),
      latestSdkConstraint: sdk,
      grantedPoints: _int(score['grantedPoints']),
      maxPoints: _int(score['maxPoints']),
      likeCount: _int(score['likeCount']),
      downloads30Days: _int(score['downloadCount30Days']),
      tags: (score['tags'] as List<dynamic>? ?? const []).whereType<String>().toList(),
      releaseCount: versions is List ? versions.length : 0,
        isDiscontinued: meta['isDiscontinued'] == true,
        replacedBy: meta['replacedBy'] is String ? meta['replacedBy'] as String : null,
        hasScoreData: hasScore,
      ),
    );
  }

  /// Fetches [url], retrying transient failures.
  ///
  /// Retries matter here. pub.dev answers in about a second on a good
  /// connection, but responses do get truncated mid-body on unreliable ones,
  /// and a dropped response must never be mistaken for a missing package.
  Future<_Fetch> _get(String url, String cacheKey) async {
    final cached = _cache.read(cacheKey);
    if (cached != null) return _Fetch(_Outcome.ok, cached);

    const backoff = [Duration(milliseconds: 300), Duration(milliseconds: 900)];

    for (var attempt = 0; attempt <= backoff.length; attempt++) {
      try {
        final response = await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));

        if (response.statusCode == 404) return const _Fetch(_Outcome.notFound, null);
        if (response.statusCode != 200) {
          if (attempt < backoff.length) {
            await Future<void>.delayed(backoff[attempt]);
            continue;
          }
          return const _Fetch(_Outcome.failed, null);
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) return const _Fetch(_Outcome.failed, null);
        _cache.write(cacheKey, decoded);
        return _Fetch(_Outcome.ok, decoded);
      } on TimeoutException {
        // fall through to retry
      } on http.ClientException {
        // fall through to retry
      } on FormatException {
        // A truncated body fails to parse. Worth one more try.
      }

      if (attempt < backoff.length) await Future<void>.delayed(backoff[attempt]);
    }

    return const _Fetch(_Outcome.failed, null);
  }

  static int _int(Object? value) => value is int ? value : (value is num ? value.toInt() : 0);

  void close() => _http.close();
}

/// Whether a package could be looked up at all.
enum LookupStatus {
  /// pub.dev answered with usable data.
  found,

  /// pub.dev answered 404. The package genuinely is not published.
  notFound,

  /// pub.dev could not be reached, or answered with something unusable.
  unreachable,
}

/// The result of looking one package up.
class PackageLookup {
  const PackageLookup({required this.name, required this.status, this.info});

  final String name;
  final LookupStatus status;

  /// Populated only when [status] is [LookupStatus.found].
  final PackageInfo? info;
}

enum _Outcome { ok, notFound, failed }

class _Fetch {
  const _Fetch(this.outcome, this.body);
  final _Outcome outcome;
  final Map<String, dynamic>? body;
}
