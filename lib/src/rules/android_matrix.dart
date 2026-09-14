import '../data/agp_matrix.dart';
import '../project/android.dart';

/// How serious a matrix finding is.
enum FindingLevel {
  /// The build will fail, or is already failing, because of this.
  fail,

  /// Worth fixing, but not proven fatal.
  warn,

  /// Checked and fine.
  pass,

  /// Could not be checked, and the report says why rather than staying silent.
  unchecked,
}

/// Which part of the matrix a finding is about.
enum MatrixCheck { agp, gradle, jdk, compileSdk }

/// One statement about the Android build configuration.
class MatrixFinding {
  const MatrixFinding({
    required this.level,
    required this.check,
    required this.title,
    this.detail,
    this.fix,
    this.fixFile,
    this.requiredVersion,
  });

  final FindingLevel level;
  final MatrixCheck check;
  final String title;

  /// The minimum version the finding asks for, when it names one.
  final String? requiredVersion;

  /// The evidence behind the finding.
  final String? detail;

  /// The exact change to make.
  final String? fix;

  /// Where to make it.
  final String? fixFile;
}

/// Validates a project's Android build configuration against Google's published
/// AGP requirements.
class AndroidMatrixChecker {
  const AndroidMatrixChecker();

  /// Every finding for [config], most serious first.
  List<MatrixFinding> check(AndroidConfig config) {
    final findings = <MatrixFinding>[];

    final agp = config.agpVersion;
    if (agp == null) {
      findings.add(const MatrixFinding(
        level: FindingLevel.unchecked,
        check: MatrixCheck.agp,
        title: 'Android Gradle Plugin version not found',
        detail: 'Looked in android/settings.gradle[.kts] and android/build.gradle[.kts]. '
            'Without it the build matrix cannot be checked.',
      ));
      return findings;
    }

    final required = requirementForAgp(agp);
    if (required == null) {
      findings.add(MatrixFinding(
        level: FindingLevel.warn,
        check: MatrixCheck.agp,
        title: 'AGP $agp is outside the bundled compatibility data',
        detail: 'upkeep carries Google\'s published requirements for AGP 8.0 through '
            '${newestKnownAgp.agp}. Rather than guess at $agp, it is skipping the checks that '
            'depend on it.',
      ));
      return findings;
    }

    findings.add(_gradleFinding(config, required, agp));
    findings.add(_jdkFinding(config, required, agp));

    final compileSdkFinding = _compileSdkFinding(config, required, agp);
    if (compileSdkFinding != null) findings.add(compileSdkFinding);

    findings.sort((a, b) => a.level.index.compareTo(b.level.index));
    return findings;
  }

  MatrixFinding _gradleFinding(AndroidConfig config, AgpRequirement required, String agp) {
    final gradle = config.gradleVersion;
    if (gradle == null) {
      return const MatrixFinding(
        level: FindingLevel.unchecked,
        check: MatrixCheck.gradle,
        title: 'Gradle wrapper version not found',
        detail: 'Expected android/gradle/wrapper/gradle-wrapper.properties.',
      );
    }

    if (compareLooseVersions(gradle, required.gradleMin) < 0) {
      return MatrixFinding(
        level: FindingLevel.fail,
        check: MatrixCheck.gradle,
        title: 'Gradle $gradle is too old for AGP $agp',
        detail: 'AGP $agp requires Gradle ${required.gradleMin} or newer. '
            'This combination does not build.',
        fix: './gradlew wrapper --gradle-version=${required.gradleMin}',
        fixFile: 'run inside android/',
        requiredVersion: required.gradleMin,
      );
    }

    return MatrixFinding(
      level: FindingLevel.pass,
      check: MatrixCheck.gradle,
      title: 'Gradle $gradle satisfies AGP $agp',
      detail: 'Requires ${required.gradleMin} or newer.',
    );
  }

  MatrixFinding _jdkFinding(AndroidConfig config, AgpRequirement required, String agp) {
    final jdk = config.jdkVersion;
    if (jdk == null) {
      return MatrixFinding(
        level: FindingLevel.unchecked,
        check: MatrixCheck.jdk,
        title: 'JDK version not detected',
        detail: config.jdkUnavailableReason ?? 'No JDK version was available to check.',
      );
    }

    if (jdk < required.jdkMin) {
      return MatrixFinding(
        level: FindingLevel.fail,
        check: MatrixCheck.jdk,
        title: 'JDK $jdk is below the JDK ${required.jdkMin} that AGP $agp requires',
        detail: 'Detected via ${config.jdkSource}. Note this is the JDK on PATH; '
            'Gradle may be configured to use a different one.',
        fix: 'Install JDK ${required.jdkMin} or newer, then point Flutter at it: '
            'flutter config --jdk-dir=<path>',
      );
    }

    return MatrixFinding(
      level: FindingLevel.pass,
      check: MatrixCheck.jdk,
      title: 'JDK $jdk satisfies AGP $agp',
      detail: 'Requires JDK ${required.jdkMin} or newer. Detected via ${config.jdkSource}.',
    );
  }

  MatrixFinding? _compileSdkFinding(AndroidConfig config, AgpRequirement required, String agp) {
    if (config.compileSdkIsFlutterManaged) {
      return const MatrixFinding(
        level: FindingLevel.pass,
        check: MatrixCheck.compileSdk,
        title: 'compileSdk is managed by Flutter',
        detail: 'Set from flutter.compileSdkVersion, so it tracks your Flutter SDK.',
      );
    }

    final compileSdk = config.compileSdk;
    final maxApi = required.maxApi;
    if (compileSdk == null || maxApi == null) return null;

    if (compileSdk > maxApi) {
      // Never a FAIL. AGP reports this as COMPILE_SDK_VERSION_TOO_HIGH through
      // IssueReporter.reportWarning and the build carries on (checked in the
      // bytecode of AGP 8.6.0, 8.13.1 and 9.0.1). Calling it a build failure
      // failed Spotube, Hiddify and Hacki, which all build.
      final inferred = required.maxApiInferred;
      return MatrixFinding(
        level: FindingLevel.warn,
        check: MatrixCheck.compileSdk,
        title: 'compileSdk $compileSdk is above what AGP $agp supports',
        detail: inferred
            ? 'AGP $agp appears to top out at API $maxApi, though Google does not state it '
                'outright on that release page. Verify before acting.'
            : 'AGP $agp was tested up to API $maxApi. The build still runs, with a warning, '
                'but API $compileSdk is untested with this AGP.',
        fix: 'Either lower compileSdk to $maxApi, or raise AGP to a version that supports '
            'API $compileSdk.',
        fixFile: 'android/app/build.gradle[.kts]',
      );
    }

    return MatrixFinding(
      level: FindingLevel.pass,
      check: MatrixCheck.compileSdk,
      title: 'compileSdk $compileSdk is within AGP $agp limits',
      detail: 'Supports up to API $maxApi.',
    );
  }
}

/// Compares dotted numeric versions such as `8.10.2` and `8.13`.
///
/// Gradle versions are not semver (`8.13` has two parts), so [Version.parse]
/// cannot be used here. Missing parts count as zero, so `8.13` == `8.13.0`.
int compareLooseVersions(String a, String b) {
  final left = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final right = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}
