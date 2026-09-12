import 'dart:io';

import 'package:path/path.dart' as p;

import '../project/android.dart';
import '../project/references.dart';
import '../rules/android_matrix.dart';
import '../rules/dependency_health.dart';

/// A change `upkeep fix --apply` can make on its own.
///
/// Only two shapes of change qualify, and both are narrow on purpose: each is
/// fully determined by published data, touches one file, and is undone by
/// `git checkout`. Anything that needs judgement is a [FixTodo] instead.
sealed class AutomaticFix {
  const AutomaticFix();

  String get title;

  /// Why the change is being made. Never empty.
  List<String> get reasons;

  /// The file it edits, relative to the project root.
  String get file;

  /// True when the change blocks a build today, so making it matters for the
  /// exit code.
  bool get isBlocking;
}

/// Removes a blocking dependency that nothing in the project refers to.
class RemoveDependency extends AutomaticFix {
  const RemoveDependency({required this.package, required this.isDev, required this.reasons});

  final String package;
  final bool isDev;

  @override
  final List<String> reasons;

  @override
  String get title => 'Remove $package, which nothing imports';

  @override
  String get file => 'pubspec.yaml';

  @override
  bool get isBlocking => true;
}

/// Points the Gradle wrapper at the version the AGP in use requires.
class RaiseGradleWrapper extends AutomaticFix {
  const RaiseGradleWrapper({required this.from, required this.to, required this.reasons});

  final String from;
  final String to;

  @override
  final List<String> reasons;

  @override
  String get title => 'Raise the Gradle wrapper to $to';

  @override
  String get file => gradleWrapperPath;

  @override
  bool get isBlocking => true;

  static const gradleWrapperPath = 'android/gradle/wrapper/gradle-wrapper.properties';
}

/// A change only a person can make, with everything they need to make it.
class FixTodo {
  const FixTodo({
    required this.title,
    required this.reasons,
    required this.isBlocking,
    this.action,
    this.references = const [],
  });

  final String title;
  final List<String> reasons;
  final bool isBlocking;

  /// The concrete next step, when there is one to name.
  final String? action;

  /// Where the project uses the thing being replaced.
  final List<Reference> references;
}

/// Everything `upkeep fix` would do for one project.
class FixPlan {
  const FixPlan({required this.automatic, required this.todos});

  final List<AutomaticFix> automatic;
  final List<FixTodo> todos;

  bool get isEmpty => automatic.isEmpty && todos.isEmpty;
}

/// Turns scan results into a plan.
///
/// The asymmetry is the design. A verdict can be wrong in either direction,
/// but an automatic change made on a wrong verdict edits someone's project,
/// while a to-do made on one costs a minute of reading. So a change is only
/// automatic when being wrong about it is impossible or harmless, and every
/// automatic change is still verified by the resolver before it is kept.
class FixPlanner {
  const FixPlanner();

  FixPlan plan({
    required String projectRoot,
    required List<DependencyReport> dependencies,
    required List<MatrixFinding> android,
    required AndroidConfig? androidConfig,
    required ReferenceIndex references,
  }) {
    final automatic = <AutomaticFix>[];
    final todos = <FixTodo>[];

    for (final finding in android) {
      if (finding.level != FindingLevel.fail && finding.level != FindingLevel.warn) continue;
      _planAndroid(projectRoot, finding, androidConfig, automatic, todos);
    }

    for (final dep in dependencies) {
      if (!dep.verdict.isBlocking && dep.verdict != Verdict.atRisk) continue;
      _planDependency(dep, references, automatic, todos);
    }

    // Blocking to-dos first: they are the ones failing the build.
    todos.sort((a, b) => (a.isBlocking == b.isBlocking) ? 0 : (a.isBlocking ? -1 : 1));
    return FixPlan(automatic: automatic, todos: todos);
  }

  void _planDependency(
    DependencyReport dep,
    ReferenceIndex index,
    List<AutomaticFix> automatic,
    List<FixTodo> todos,
  ) {
    final name = dep.name;
    final dartRefs = index.dartReferencesTo(name);
    final blocking = dep.verdict.isBlocking;

    if (blocking && _isSafeToRemove(dep, index)) {
      automatic.add(RemoveDependency(
        package: name,
        isDev: dep.isDev,
        reasons: [
          ...dep.reasons,
          'no Dart file imports package:$name, and no config file names it',
        ],
      ));
      return;
    }

    final replacement = dep.replacedBy;
    final String title;
    final String? action;
    if (replacement != null) {
      title = 'Replace $name with $replacement';
      final evidence = dep.replacementSource == ReplacementSource.curated
          ? ' (successor named at ${dep.replacementEvidence})'
          : '';
      action = 'dart pub remove $name && dart pub add ${dep.isDev ? 'dev:' : ''}$replacement, '
          'then update the imports below$evidence';
    } else if (dep.verdict == Verdict.atRisk) {
      title = 'Plan a move off $name';
      action = null;
    } else {
      title = 'Replace $name';
      action = 'no maintained replacement is known yet; choose one on pub.dev';
    }

    todos.add(FixTodo(
      title: title,
      reasons: dep.reasons,
      isBlocking: blocking,
      action: action,
      references: dartRefs,
    ));
  }

  /// Whether removing [dep] outright can be done without a person.
  ///
  /// "Nothing imports it" is necessary and nowhere near sufficient, so each
  /// way a package can be used without an import rules removal out:
  ///
  /// - at-risk packages still work, so removing one is a choice, not a fix
  /// - dev dependencies are mostly run rather than imported: `build_runner`,
  ///   code generators, `flutter_launcher_icons`
  /// - Flutter plugins can be pure native code, such as `isar_flutter_libs`
  /// - an unknown plugin status is treated as a plugin; missing data is never
  ///   evidence
  static bool _isSafeToRemove(DependencyReport dep, ReferenceIndex index) =>
      dep.verdict.isBlocking &&
      !dep.isDev &&
      dep.info?.isFlutterPlugin == false &&
      !index.isReferenced(dep.name);

  void _planAndroid(
    String projectRoot,
    MatrixFinding finding,
    AndroidConfig? config,
    List<AutomaticFix> automatic,
    List<FixTodo> todos,
  ) {
    final required = finding.requiredVersion;
    final current = config?.gradleVersion;

    if (finding.check == MatrixCheck.gradle &&
        finding.level == FindingLevel.fail &&
        required != null &&
        current != null) {
      final wrapper = File(p.join(projectRoot, RaiseGradleWrapper.gradleWrapperPath));
      final text = wrapper.existsSync() ? wrapper.readAsStringSync() : '';

      // A pinned checksum belongs to the old distribution. Editing the URL
      // without it would break the wrapper, and inventing a checksum would be
      // worse, so the Gradle tool gets to do this one.
      if (text.contains('distributionSha256Sum')) {
        todos.add(FixTodo(
          title: 'Raise the Gradle wrapper to $required',
          reasons: [
            if (finding.detail != null) finding.detail!,
            'the wrapper pins a checksum, so upkeep leaves the change to Gradle itself',
          ],
          isBlocking: true,
          action: 'cd android && ./gradlew wrapper --gradle-version=$required',
        ));
        return;
      }

      automatic.add(RaiseGradleWrapper(
        from: current,
        to: required,
        reasons: [
          'AGP ${config?.agpVersion} requires Gradle $required or newer; the wrapper is on $current',
        ],
      ));
      return;
    }

    todos.add(FixTodo(
      title: finding.title,
      reasons: [if (finding.detail != null) finding.detail!],
      isBlocking: finding.level == FindingLevel.fail,
      action: finding.fix == null
          ? null
          : '${finding.fix}${finding.fixFile == null ? '' : ' (${finding.fixFile})'}',
    ));
  }
}
