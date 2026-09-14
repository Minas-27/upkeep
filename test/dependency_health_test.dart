import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upkeep/upkeep.dart';

/// Builds a [PackageInfo] with healthy defaults, so each test only states the
/// one thing it is actually about.
PackageInfo pkg({
  String name = 'example',
  String latest = '1.0.0',
  int monthsAgo = 1,
  String? sdk = '>=3.0.0 <4.0.0',
  int points = 160,
  int maxPoints = 160,
  int downloads = 5000,
  List<String> tags = const ['is:dart3-compatible'],
  bool discontinued = false,
  String? replacedBy,
  bool hasScoreData = true,
}) =>
    PackageInfo(
      name: name,
      latestVersion: Version.parse(latest),
      latestPublished: DateTime.now().toUtc().subtract(Duration(days: (monthsAgo * 30.44).round())),
      latestSdkConstraint: sdk == null ? null : VersionConstraint.parse(sdk),
      grantedPoints: points,
      maxPoints: maxPoints,
      likeCount: 10,
      downloads30Days: downloads,
      tags: tags,
      releaseCount: 5,
      isDiscontinued: discontinued,
      replacedBy: replacedBy,
      hasScoreData: hasScoreData,
    );

DependencyReport judge(PackageInfo? info, {LookupStatus status = LookupStatus.found}) {
  final engine = HealthEngine(dartSdkVersion: Version(3, 11, 0));
  final declared = [
    const DeclaredDependency(
      name: 'example',
      source: DepSource.hosted,
      isDev: false,
      constraint: '^1.0.0',
    ),
  ];
  final lookups = {
    'example': PackageLookup(name: 'example', status: status, info: info),
  };
  return engine.evaluate(declared, lookups, (_) => '1.0.0').single;
}

void main() {
  group('discontinued', () {
    test('outranks popularity and a perfect score', () {
      // Modelled on `pedantic`: discontinued, 160/160 points, ~869k downloads a
      // month. An earlier version of the engine rescued it as healthy.
      final report = judge(pkg(
        discontinued: true,
        replacedBy: 'lints',
        points: 160,
        downloads: 869355,
        monthsAgo: 60,
      ));

      expect(report.verdict, Verdict.discontinued);
      expect(report.replacedBy, 'lints');
      expect(report.verdict.isBlocking, isTrue);
      expect(report.reasons.join(' '), contains('lints'));
    });
  });

  group('missing score data', () {
    test('never produces a negative verdict', () {
      // A dropped score request leaves zero points and no tags, which looks
      // exactly like neglect. It must not be treated as evidence.
      final report = judge(pkg(
        hasScoreData: false,
        points: 0,
        maxPoints: 0,
        tags: const [],
        monthsAgo: 2,
      ));

      expect(report.verdict, Verdict.healthy);
    });

    test('still reports staleness, and says what it could not check', () {
      final report = judge(pkg(
        hasScoreData: false,
        points: 0,
        maxPoints: 0,
        tags: const [],
        monthsAgo: 20,
      ));

      expect(report.verdict, Verdict.stale);
      expect(report.reasons.join(' '), contains('score data was unavailable'));
    });

    test('a failed pub.dev analysis is missing data too', () {
      // Modelled on `phosphor_flutter`: its constraint allows Dart 3 and it
      // resolves, but pub.dev's analysis errored, leaving 55 points and no
      // compatibility tags. An earlier engine called it dead on that alone.
      final report = judge(pkg(
        sdk: '>=2.12.0 <4.0.0',
        points: 55,
        tags: const ['has:error', 'license:mit'],
        monthsAgo: 28,
        downloads: 72000,
      ));

      expect(report.verdict, Verdict.stale);
      expect(report.reasons.join(' '), contains('analysis of this package failed'));
    });
  });

  group('sdk constraints', () {
    test('pub\'s Dart 3 allowance holds even when pub.dev\'s analysis failed', () {
      // Modelled on `lucide_icons` 0.257.0: `>=2.12.0 <3.0.0`, analysis errored
      // so there is no dart3 tag, yet it resolves in real Dart 3.11 projects.
      final report = judge(pkg(
        sdk: '>=2.12.0 <3.0.0',
        points: 45,
        tags: const ['has:error'],
        monthsAgo: 38,
      ));

      expect(report.verdict, Verdict.atRisk);
      expect(report.verdict.isBlocking, isFalse);
      expect(report.reasons.join(' '), contains("pub's Dart 3 allowance"));
    });

    test('the allowance follows pub\'s rule exactly', () {
      bool allowed(String c) => HealthEngine.resolvesUnderDart3Allowance(VersionConstraint.parse(c));
      expect(allowed('>=2.12.0 <3.0.0'), isTrue);
      expect(allowed('>=2.12.0-0 <3.0.0'), isTrue);
      expect(allowed('>=2.17.0 <3.0.0'), isTrue);
      expect(allowed('>=2.7.0 <3.0.0'), isFalse, reason: 'not null-safe');
      expect(allowed('>=2.12.0 <2.19.0'), isFalse, reason: 'a tighter ceiling is not relaxed');
    });

    test('a newer-Dart requirement is not the package\'s fault', () {
      final report = judge(pkg(latest: '4.0.0', sdk: '^3.12.0'));

      expect(report.verdict, Verdict.upgradeBlocked);
      expect(report.verdict.isBlocking, isFalse,
          reason: 'an out-of-date local Flutter must not fail someone\'s CI');
      expect(report.requiresDart, '^3.12.0');
    });

    test('pub.dev\'s dart3 tag overrides a pre-Dart-3 ceiling', () {
      // isar and hive both cap at <3.0.0 yet carry is:dart3-compatible,
      // because Dart 3's pub relaxes that bound for null-safe packages. An
      // earlier engine called both INCOMPATIBLE, which was simply wrong.
      final report = judge(pkg(
        latest: '3.1.0',
        sdk: '>=2.17.0 <3.0.0',
        points: 130,
        monthsAgo: 30,
        tags: const ['is:dart3-compatible'],
      ));

      expect(report.verdict, Verdict.atRisk);
      expect(report.verdict.isBlocking, isFalse);
      expect(report.reasons.join(' '), contains('Dart 3 allowance'));
    });

    test('a ceiling pub does not relax stays a dead end', () {
      // Not null-safe, so pub's Dart 3 allowance does not apply and the
      // resolver really will not take it. (`lucide_icons` was once the example
      // here, wrongly: `>=2.12.0 <3.0.0` is relaxed and resolves on Dart 3.)
      final report = judge(pkg(
        latest: '0.9.0',
        sdk: '>=2.7.0 <3.0.0',
        points: 45,
        tags: const [],
      ));

      expect(report.verdict, Verdict.incompatible);
      expect(report.verdict.isBlocking, isTrue);
    });
  });

  group('staleness', () {
    test('a widely used, fully scoring package is stale, not dead', () {
      final report = judge(pkg(monthsAgo: 30, downloads: 1200000, points: 160));

      expect(report.verdict, Verdict.stale);
      expect(report.reasons.join(' '), contains('still widely used'));
    });

    test('a widely used package that lost points to age is stale, not at risk', () {
      // Modelled on `collection`: dart.dev, ~9.8M downloads a month, no release
      // in 22 months, 140/160 for a missing example and newer lints. At a 0.9
      // threshold it was AT RISK in 16 of 20 real apps.
      final report = judge(pkg(monthsAgo: 22, downloads: 9800000, points: 140));

      expect(report.verdict, Verdict.stale);
      expect(report.reasons.join(' '), contains('still widely used'));
    });

    test('popularity does not rescue a badly scoring old package', () {
      final report = judge(pkg(monthsAgo: 22, downloads: 240000, points: 120));

      expect(report.verdict, Verdict.atRisk);
    });

    test('old, low scoring and pre-Dart-3 is dead', () {
      final report = judge(pkg(
        monthsAgo: 30,
        downloads: 400,
        points: 60,
        tags: const [],
      ));

      expect(report.verdict, Verdict.dead);
      expect(report.verdict.isBlocking, isTrue);
    });

    test('a recent release with no warning signs is healthy', () {
      expect(judge(pkg()).verdict, Verdict.healthy);
    });
  });

  group('lookup failures', () {
    test('an unpublished package and an unreachable API do not share a message', () {
      final missing = judge(null, status: LookupStatus.notFound);
      final offline = judge(null, status: LookupStatus.unreachable);

      expect(missing.verdict, Verdict.unknown);
      expect(offline.verdict, Verdict.unknown);
      expect(missing.reasons.single, contains('not published'));
      expect(offline.reasons.single, contains('could not be reached'));
      expect(missing.verdict.isBlocking, isFalse);
    });
  });

  group('formatCount', () {
    test('shortens large numbers', () {
      expect(formatCount(4214118), '4.2M');
      expect(formatCount(3234), '3k');
      expect(formatCount(412), '412');
    });
  });
}
