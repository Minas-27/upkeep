import 'package:test/test.dart';
import 'package:upkeep/upkeep.dart';

MatrixFinding? findingContaining(List<MatrixFinding> findings, String fragment) {
  for (final f in findings) {
    if (f.title.contains(fragment)) return f;
  }
  return null;
}

void main() {
  const checker = AndroidMatrixChecker();

  group('compareLooseVersions', () {
    test('handles Gradle versions that are not semver', () {
      expect(compareLooseVersions('8.13', '8.10.2'), greaterThan(0));
      expect(compareLooseVersions('8.10.2', '8.13'), lessThan(0));
      expect(compareLooseVersions('8.13', '8.13.0'), 0);
      expect(compareLooseVersions('9.6.0', '9.6'), 0);
    });
  });

  group('gradle', () {
    test('flags a wrapper too old for the AGP in use, with the fix command', () {
      final findings = checker.check(const AndroidConfig(
        agpVersion: '8.9.0',
        gradleVersion: '8.4',
        jdkVersion: 17,
        jdkSource: 'test',
      ));

      final gradle = findingContaining(findings, 'Gradle 8.4');
      expect(gradle, isNotNull);
      expect(gradle!.level, FindingLevel.fail);
      expect(gradle.fix, contains('8.11.1'));
    });

    test('passes a wrapper that satisfies the requirement', () {
      final findings = checker.check(const AndroidConfig(
        agpVersion: '8.11.1',
        gradleVersion: '8.14',
        jdkVersion: 17,
        jdkSource: 'test',
      ));

      expect(findingContaining(findings, 'Gradle 8.14')?.level, FindingLevel.pass);
    });
  });

  group('jdk', () {
    test('flags a JDK below the AGP minimum', () {
      final findings = checker.check(const AndroidConfig(
        agpVersion: '8.7.0',
        gradleVersion: '8.9',
        jdkVersion: 11,
        jdkSource: 'test',
      ));

      expect(findingContaining(findings, 'JDK 11')?.level, FindingLevel.fail);
    });
  });

  group('compileSdk', () {
    test('warns, never fails, when above a documented ceiling', () {
      // AGP reports this through IssueReporter.reportWarning and builds anyway.
      // Spotube (compileSdk 36 on AGP 8.7.0) was once called a build failure.
      final findings = checker.check(const AndroidConfig(
        agpVersion: '8.5.0',
        gradleVersion: '8.7',
        jdkVersion: 17,
        jdkSource: 'test',
        compileSdk: 36,
      ));

      final finding = findingContaining(findings, 'compileSdk 36');
      expect(finding?.level, FindingLevel.warn);
      expect(finding?.detail, contains('still runs'));
    });

    test('only warns when the ceiling was inferred rather than stated', () {
      // AGP 8.11's release page never states a maximum API level outright, so a
      // hard FAIL would be an accusation built on an inference.
      final findings = checker.check(const AndroidConfig(
        agpVersion: '8.11.0',
        gradleVersion: '8.13',
        jdkVersion: 17,
        jdkSource: 'test',
        compileSdk: 37,
      ));

      final finding = findingContaining(findings, 'compileSdk 37');
      expect(finding?.level, FindingLevel.warn);
      expect(finding?.detail, contains('Verify'));
    });

    test('treats Flutter-managed compileSdk as fine', () {
      final findings = checker.check(const AndroidConfig(
        agpVersion: '8.11.0',
        gradleVersion: '8.13',
        jdkVersion: 17,
        jdkSource: 'test',
        compileSdkIsFlutterManaged: true,
      ));

      expect(findingContaining(findings, 'managed by Flutter')?.level, FindingLevel.pass);
    });
  });

  group('unknown input', () {
    test('says so rather than guessing when AGP is missing', () {
      final findings = checker.check(const AndroidConfig(gradleVersion: '8.14'));

      expect(findings.single.level, FindingLevel.unchecked);
      expect(findings.single.title, contains('not found'));
    });

    test('refuses to judge an AGP outside the bundled data', () {
      final findings = checker.check(const AndroidConfig(
        agpVersion: '7.2.0',
        gradleVersion: '7.0',
        jdkVersion: 11,
        jdkSource: 'test',
      ));

      expect(findings.single.level, FindingLevel.warn);
      expect(findings.single.detail, contains('Rather than guess'));
    });
  });

  group('bundled matrix', () {
    test('matches on the major.minor line, not the patch', () {
      expect(requirementForAgp('8.11.1')?.agp, '8.11');
      expect(requirementForAgp('8.11')?.gradleMin, '8.13');
      expect(requirementForAgp('9.4.0')?.gradleMin, '9.6.0');
      expect(requirementForAgp('7.4.0'), isNull);
    });

    test('every row carries a JDK requirement', () {
      for (final row in agpMatrix) {
        expect(row.jdkMin, greaterThanOrEqualTo(17), reason: 'AGP ${row.agp}');
      }
    });
  });
}
