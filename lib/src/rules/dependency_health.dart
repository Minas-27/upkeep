import 'package:pub_semver/pub_semver.dart';

import '../project/pubspec.dart';
import '../pub/client.dart';

/// One dependency's health, most serious first.
///
/// The declaration order is the severity order, and the report sorts on it.
enum Verdict {
  /// pub.dev's own discontinued flag is set. Not a judgement call.
  discontinued('DISCONTINUED'),

  /// The package's own version ceiling excludes the Dart in use. It cannot be
  /// used here at all, and no future release is coming to fix that.
  incompatible('INCOMPATIBLE'),

  /// Long silent, poorly scoring, and not Dart 3 ready.
  dead('DEAD'),

  /// Showing more than one warning sign.
  atRisk('AT RISK'),

  /// Healthy, but its newest release needs a newer Dart than this machine has.
  /// A note about the local toolchain, not a fault in the package.
  upgradeBlocked('SDK BLOCKED'),

  /// Quiet for a while, but otherwise fine.
  stale('STALE'),

  /// No warning signs.
  healthy('HEALTHY'),

  /// Could not be judged, and the report says why.
  unknown('UNKNOWN');

  const Verdict(this.label);
  final String label;

  /// True for verdicts that should fail a CI run.
  ///
  /// Deliberately narrow. [upgradeBlocked] is excluded because an out-of-date
  /// local Flutter is not a defect in the project, and failing a build over it
  /// would train people to ignore the exit code.
  bool get isBlocking => this == discontinued || this == incompatible || this == dead;
}

/// The thresholds the engine runs on, grouped so they can be tuned and tested
/// in one place rather than scattered through the logic.
class HealthThresholds {
  const HealthThresholds({
    this.staleMonths = 12,
    this.atRiskMonths = 18,
    this.deadMonths = 24,
    this.deadPointsRatio = 0.6,
    this.atRiskPointsRatio = 0.5,
    this.widelyUsedDownloads = 100000,
    this.fullyScoringRatio = 0.9,
  });

  final int staleMonths;
  final int atRiskMonths;
  final int deadMonths;
  final double deadPointsRatio;
  final double atRiskPointsRatio;

  /// Monthly downloads above which a package is treated as load-bearing.
  final int widelyUsedDownloads;

  /// Score ratio at or above which a package is treated as well maintained.
  final double fullyScoringRatio;
}

/// The verdict on one declared dependency, with the reasons behind it.
class DependencyReport {
  const DependencyReport({
    required this.name,
    required this.isDev,
    required this.verdict,
    required this.reasons,
    this.info,
    this.declaredConstraint,
    this.resolvedVersion,
    this.replacedBy,
    this.requiresDart,
  });

  final String name;
  final bool isDev;
  final Verdict verdict;

  /// Why this verdict was reached. Empty only for healthy packages.
  final List<String> reasons;

  final PackageInfo? info;
  final String? declaredConstraint;
  final String? resolvedVersion;

  /// The maintained package to move to, when one is known.
  final String? replacedBy;

  /// The Dart constraint the newest release asks for, when that is what blocks
  /// the upgrade. Used to group SDK-blocked packages into one message.
  final String? requiresDart;

  /// True when the resolved version is behind the latest published one.
  bool get isBehind {
    final resolved = resolvedVersion;
    final latest = info?.latestVersion;
    if (resolved == null || latest == null) return false;
    try {
      return Version.parse(resolved) < latest;
    } on FormatException {
      return false;
    }
  }
}

/// Scores dependencies against pub.dev facts.
class HealthEngine {
  const HealthEngine({
    this.thresholds = const HealthThresholds(),
    required this.dartSdkVersion,
  });

  final HealthThresholds thresholds;

  /// The Dart SDK actually in use, used for the compatibility checks.
  final Version dartSdkVersion;

  /// Judges every hosted dependency in [declared].
  ///
  /// SDK, git and path dependencies are skipped: pub.dev knows nothing about
  /// them, and inventing a verdict for them would be dishonest.
  List<DependencyReport> evaluate(
    List<DeclaredDependency> declared,
    Map<String, PackageLookup> lookups,
    String? Function(String name) resolvedVersionOf,
  ) {
    final reports = <DependencyReport>[];
    for (final dep in declared) {
      if (dep.source != DepSource.hosted) continue;
      reports.add(_judge(dep, lookups[dep.name], resolvedVersionOf(dep.name)));
    }
    reports.sort((a, b) {
      final bySeverity = a.verdict.index.compareTo(b.verdict.index);
      return bySeverity != 0 ? bySeverity : a.name.compareTo(b.name);
    });
    return reports;
  }

  DependencyReport _judge(DeclaredDependency dep, PackageLookup? lookup, String? resolved) {
    final info = lookup?.info;
    if (info == null) {
      // Two very different situations that must never share a message: the
      // package is not published, or we simply could not ask.
      final reason = switch (lookup?.status) {
        LookupStatus.notFound => 'not published on pub.dev',
        _ => 'pub.dev could not be reached, so no verdict was reached either',
      };
      return DependencyReport(
        name: dep.name,
        isDev: dep.isDev,
        verdict: Verdict.unknown,
        reasons: [reason],
        declaredConstraint: dep.constraint,
        resolvedVersion: resolved,
      );
    }

    // Checked first, and deliberately not rescuable. A package can be
    // discontinued while still scoring perfectly and being downloaded millions
    // of times a month; `pedantic` is exactly that. Popularity is not a defence
    // against the publisher saying "stop using this".
    if (info.isDiscontinued) {
      return DependencyReport(
        name: dep.name,
        isDev: dep.isDev,
        verdict: Verdict.discontinued,
        reasons: [
          'marked discontinued by its publisher on pub.dev',
          if (info.replacedBy != null)
            'the publisher nominates ${info.replacedBy} as the replacement',
        ],
        info: info,
        declaredConstraint: dep.constraint,
        resolvedVersion: resolved,
        replacedBy: info.replacedBy,
      );
    }

    // Set when the package only resolves thanks to pub's Dart 3 allowance.
    String? legacyCeiling;

    final sdkConstraint = info.latestSdkConstraint;
    if (sdkConstraint != null && !sdkConstraint.allows(dartSdkVersion)) {
      if (_needsNewerDart(sdkConstraint, dartSdkVersion)) {
        // The package is fine. This machine is behind.
        return DependencyReport(
          name: dep.name,
          isDev: dep.isDev,
          verdict: Verdict.upgradeBlocked,
          reasons: ['its newest release (${info.latestVersion}) needs Dart $sdkConstraint'],
          info: info,
          declaredConstraint: dep.constraint,
          resolvedVersion: resolved,
          requiresDart: sdkConstraint.toString(),
        );
      }

      // The declared ceiling excludes us. Before calling that fatal, defer to
      // pub.dev: Dart 3's pub relaxes a `<3.0.0` upper bound for null-safe
      // packages, and pub.dev records the outcome in `is:dart3-compatible`.
      // That tag is the resolver's own answer, and it beats our arithmetic.
      final exempt = info.hasScoreData && info.isDart3Compatible && dartSdkVersion.major >= 3;

      if (!exempt) {
        return DependencyReport(
          name: dep.name,
          isDev: dep.isDev,
          verdict: Verdict.incompatible,
          reasons: [
            'its newest release (${info.latestVersion}) caps Dart at $sdkConstraint, '
                'which excludes the Dart $dartSdkVersion in use here',
            'no release has ever supported this Dart, so waiting will not fix it',
          ],
          info: info,
          declaredConstraint: dep.constraint,
          resolvedVersion: resolved,
        );
      }

      // It resolves, but only on the exemption. That is worth saying plainly:
      // the author never shipped Dart 3 support, the resolver forgave them.
      legacyCeiling = 'declares support only up to Dart $sdkConstraint; it resolves today '
          'through pub\'s Dart 3 allowance, not because it was updated';
    }

    // Score and tag data are only trustworthy when pub.dev actually answered.
    // Without it, absent tags and zero points look identical to a neglected
    // package, and upkeep would accuse healthy code on the strength of a
    // dropped connection.
    if (!info.hasScoreData) {
      final months = info.monthsSinceRelease;
      if (legacyCeiling != null) {
        return _report(dep, info, resolved, Verdict.atRisk, [legacyCeiling]);
      }
      if (months >= thresholds.staleMonths) {
        return _report(dep, info, resolved, Verdict.stale, [
          'no release in $months months',
          'pub.dev score data was unavailable, so nothing further was judged',
        ]);
      }
      return _report(dep, info, resolved, Verdict.healthy, const []);
    }

    final reasons = <String>[if (legacyCeiling != null) legacyCeiling];
    final months = info.monthsSinceRelease;
    final ratio = info.pointsRatio;

    // Widely depended on and still scoring full marks. A small, finished
    // package that has not needed a release in two years is not abandoned, and
    // calling it dead is how a tool like this loses people for good.
    final loadBearing = info.downloads30Days >= thresholds.widelyUsedDownloads &&
        ratio != null &&
        ratio >= thresholds.fullyScoringRatio &&
        info.isDart3Compatible;

    if (months >= thresholds.deadMonths &&
        !info.isDart3Compatible &&
        (ratio == null || ratio < thresholds.deadPointsRatio) &&
        !loadBearing) {
      reasons
        ..add('no release in $months months')
        ..add('not Dart 3 compatible')
        ..add(_pointsReason(info));
      return _report(dep, info, resolved, Verdict.dead, reasons);
    }

    if (legacyCeiling != null) {
      if (months >= thresholds.staleMonths) reasons.add('no release in $months months');
      return _report(dep, info, resolved, Verdict.atRisk, reasons);
    }

    if (!loadBearing) {
      if (months >= thresholds.atRiskMonths) reasons.add('no release in $months months');
      if (!info.isDart3Compatible) reasons.add('not Dart 3 compatible');
      if (ratio != null && ratio < thresholds.atRiskPointsRatio) reasons.add(_pointsReason(info));
      if (reasons.isNotEmpty) return _report(dep, info, resolved, Verdict.atRisk, reasons);
    }

    if (months >= thresholds.staleMonths) {
      reasons.add('no release in $months months, but otherwise healthy');
      if (loadBearing) {
        reasons.add('still widely used: ${formatCount(info.downloads30Days)} downloads in the '
            'last 30 days');
      }
      return _report(dep, info, resolved, Verdict.stale, reasons);
    }

    return _report(dep, info, resolved, Verdict.healthy, const []);
  }

  /// True when [constraint] excludes [current] because [current] is too old,
  /// rather than because the package capped itself below it.
  static bool _needsNewerDart(VersionConstraint constraint, Version current) {
    if (constraint is VersionRange) {
      final min = constraint.min;
      if (min != null && current < min) return true;
    }
    return false;
  }

  DependencyReport _report(
    DeclaredDependency dep,
    PackageInfo info,
    String? resolved,
    Verdict verdict,
    List<String> reasons,
  ) =>
      DependencyReport(
        name: dep.name,
        isDev: dep.isDev,
        verdict: verdict,
        reasons: reasons,
        info: info,
        declaredConstraint: dep.constraint,
        resolvedVersion: resolved,
      );

  static String _pointsReason(PackageInfo info) =>
      'scores ${info.grantedPoints} of ${info.maxPoints} pub points';
}

/// Formats a count for humans: 4214118 becomes `4.2M`.
String formatCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}k';
  return '$n';
}
