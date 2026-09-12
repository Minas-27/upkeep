import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upkeep/upkeep.dart';

PackageInfo info({bool? plugin = false, bool discontinued = true}) => PackageInfo(
      name: 'x',
      latestVersion: Version(1, 0, 0),
      latestPublished: DateTime.now().toUtc(),
      latestSdkConstraint: VersionConstraint.parse('>=3.0.0 <4.0.0'),
      grantedPoints: 160,
      maxPoints: 160,
      likeCount: 0,
      downloads30Days: 0,
      tags: const ['is:dart3-compatible'],
      releaseCount: 1,
      isDiscontinued: discontinued,
      hasScoreData: true,
      isFlutterPlugin: plugin,
    );

DependencyReport dep(
  String name, {
  Verdict verdict = Verdict.discontinued,
  bool isDev = false,
  bool? plugin = false,
  String? replacedBy,
}) =>
    DependencyReport(
      name: name,
      isDev: isDev,
      verdict: verdict,
      reasons: const ['marked discontinued by its publisher on pub.dev'],
      info: info(plugin: plugin),
      replacedBy: replacedBy,
    );

/// Writes [files] under a fresh temporary directory and returns its path.
String project(Map<String, String> files) {
  final root = Directory.systemTemp.createTempSync('upkeep_fix_').path;
  addTearDown(() => Directory(root).deleteSync(recursive: true));
  files.forEach((path, content) {
    File(p.join(root, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  });
  return root;
}

FixPlan planFor(String root, List<DependencyReport> deps) => const FixPlanner().plan(
      dependencies: deps,
      android: const [],
      androidConfig: null,
      references: scanReferences(root, deps.map((d) => d.name)),
    );

Future<ProcessResult> resolves(String root, {required bool flutter}) async =>
    ProcessResult(0, 0, '', '');

Future<ProcessResult> rejects(String root, {required bool flutter}) async =>
    ProcessResult(0, 1, '', 'Because demo depends on nothing, version solving failed.');

void main() {
  group('references', () {
    test('finds package imports with their line numbers, and config mentions', () {
      final root = project({
        'lib/a.dart': "import 'package:foo/foo.dart';\n\nexport \"package:foo/bar.dart\";\n",
        'test/b.dart': '// see package:bar/bar.dart\n',
        'analysis_options.yaml': 'include: package:baz/recommended.yaml\n',
        'pubspec.yaml': 'name: demo\nflutter_launcher_icons:\n  android: true\n',
      });

      final index =
          scanReferences(root, ['foo', 'bar', 'baz', 'flutter_launcher_icons', 'qux']);

      expect(index.dartReferencesTo('foo').map((r) => '$r'), ['lib/a.dart:1', 'lib/a.dart:3']);
      // A mention in a comment still counts. A false "still used" costs a
      // manual step; a false "unused" deletes something someone needed.
      expect(index.isReferenced('bar'), isTrue);
      expect(index.isReferenced('baz'), isTrue);
      expect(index.isReferenced('flutter_launcher_icons'), isTrue);
      expect(index.isReferenced('qux'), isFalse);
    });
  });

  group('planner', () {
    test('removes a blocking dependency nothing refers to', () {
      final root = project({'lib/main.dart': 'void main() {}\n'});
      final plan = planFor(root, [dep('gone')]);

      final removal = plan.automatic.single as RemoveDependency;
      expect(removal.package, 'gone');
      expect(removal.reasons, contains(contains('no Dart file imports package:gone')));
      expect(plan.todos, isEmpty);
    });

    test('turns an imported blocking dependency into a to-do with locations', () {
      final root = project({'lib/main.dart': "import 'package:used/used.dart';\n"});
      final plan = planFor(root, [dep('used', replacedBy: 'better')]);

      expect(plan.automatic, isEmpty);
      final todo = plan.todos.single;
      expect(todo.title, 'Replace used with better');
      expect(todo.isBlocking, isTrue);
      expect(todo.references.single.toString(), 'lib/main.dart:1');
    });

    test('never removes a Flutter plugin, which can work with no import', () {
      final root = project({});
      expect(planFor(root, [dep('native_libs', plugin: true)]).automatic, isEmpty);
    });

    test('treats an unknown plugin status as a plugin', () {
      final root = project({});
      expect(planFor(root, [dep('mystery', plugin: null)]).automatic, isEmpty);
    });

    test('never removes a dev dependency, which is usually run rather than imported', () {
      final root = project({});
      expect(planFor(root, [dep('some_generator', isDev: true)]).automatic, isEmpty);
    });

    test('never removes an at-risk dependency, and marks its to-do not blocking', () {
      final root = project({});
      final plan = planFor(root, [dep('wobbly', verdict: Verdict.atRisk)]);
      expect(plan.automatic, isEmpty);
      expect(plan.todos.single.isBlocking, isFalse);
    });

    test('leaves a checksum-pinned Gradle wrapper to Gradle itself', () {
      final config = AndroidConfig.fromFiles({
        RaiseGradleWrapper.gradleWrapperPath:
            'distributionUrl=https\\://services.gradle.org/distributions/gradle-8.4-all.zip\n'
                'distributionSha256Sum=abc\n',
        'android/settings.gradle': "plugins { id 'com.android.application' version '8.9.0' apply false }",
      }, jdkVersion: 17, jdkSource: 'test');
      final plan = const FixPlanner().plan(
        dependencies: const [],
        android: const AndroidMatrixChecker().check(config),
        androidConfig: config,
        references: const ReferenceIndex.unknown(),
      );

      expect(plan.automatic, isEmpty);
      expect(plan.todos.single.action, contains('--gradle-version=8.11.1'));
    });

    test('never removes anything when the project code was not read', () {
      final plan = const FixPlanner().plan(
        dependencies: [dep('gone')],
        android: const [],
        androidConfig: null,
        references: const ReferenceIndex.unknown(),
      );
      expect(plan.automatic, isEmpty);
      expect(plan.todos.single.isBlocking, isTrue);
    });
  });

  group('applier', () {
    const pubspec = 'name: demo\n\ndependencies:\n  gone: ^1.0.0\n  kept: ^2.0.0\n';
    const removal = RemoveDependency(package: 'gone', isDev: false, reasons: ['test']);

    test('removes the dependency and keeps everything else as written', () async {
      final root = project({'pubspec.yaml': pubspec});
      final result = await const FixApplier(pubGet: resolves, allowDirty: true)
          .apply(root, [removal], isFlutterProject: false);

      expect(result.applied, hasLength(1));
      expect(result.verifiedWith, 'dart pub get');
      expect(File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
          'name: demo\n\ndependencies:\n  kept: ^2.0.0\n');
    });

    test('restores every file when the resolver rejects the change', () async {
      final root = project({
        'pubspec.yaml': pubspec,
        RaiseGradleWrapper.gradleWrapperPath: 'distributionUrl=gradle-8.4-bin.zip\n',
      });
      final result = await const FixApplier(pubGet: rejects, allowDirty: true).apply(
        root,
        [removal, const RaiseGradleWrapper(from: '8.4', to: '8.11.1', reasons: ['test'])],
        isFlutterProject: false,
      );

      expect(result.wasReverted, isTrue);
      expect(result.applied, isEmpty);
      expect(File(p.join(root, 'pubspec.yaml')).readAsStringSync(), pubspec);
      expect(File(p.join(root, RaiseGradleWrapper.gradleWrapperPath)).readAsStringSync(),
          'distributionUrl=gradle-8.4-bin.zip\n');
    });

    test('raises the wrapper and keeps the distribution type', () async {
      final root = project({
        RaiseGradleWrapper.gradleWrapperPath:
            'distributionUrl=https\\://services.gradle.org/distributions/gradle-8.4-bin.zip\n',
      });
      await const FixApplier(allowDirty: true).apply(
        root,
        [const RaiseGradleWrapper(from: '8.4', to: '8.11.1', reasons: ['test'])],
        isFlutterProject: false,
      );

      expect(File(p.join(root, RaiseGradleWrapper.gradleWrapperPath)).readAsStringSync(),
          contains('gradle-8.11.1-bin.zip'));
    });

    test('refuses to touch a project that git cannot restore', () async {
      final root = project({'pubspec.yaml': pubspec});
      final git = await Process.run('git', ['rev-parse'], workingDirectory: root);
      if (git.exitCode == 0) {
        markTestSkipped('the temp directory is inside a git repository');
        return;
      }

      await expectLater(
        const FixApplier(pubGet: resolves).apply(root, [removal], isFlutterProject: false),
        throwsA(isA<ApplyRefused>()),
      );
      expect(File(p.join(root, 'pubspec.yaml')).readAsStringSync(), pubspec);
    });

    test('refuses when a file it would edit has uncommitted changes', () async {
      final root = project({'pubspec.yaml': pubspec});
      Process.runSync('git', ['init', '-q'], workingDirectory: root);
      Process.runSync('git', ['add', '-A'], workingDirectory: root);
      Process.runSync(
          'git', ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init'],
          workingDirectory: root);
      File(p.join(root, 'pubspec.yaml')).writeAsStringSync('$pubspec# edited\n');

      await expectLater(
        const FixApplier(pubGet: resolves).apply(root, [removal], isFlutterProject: false),
        throwsA(isA<ApplyRefused>()),
      );
      expect(File(p.join(root, 'pubspec.yaml')).readAsStringSync(), '$pubspec# edited\n');
    });
  });
}
