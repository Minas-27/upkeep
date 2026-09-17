import '../fix/result.dart';
import '../fix/plan.dart';
import '../rules/android_matrix.dart';
import '../rules/dependency_health.dart';

/// GitHub-flavoured Markdown, for job summaries and pull request bodies.
///
/// Same rule as the terminal: no verdict without its reasons.

String _code(String s) => '`${s.replaceAll('`', "'")}`';

String _escape(String s) => s.replaceAll('|', r'\|').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _replacementLine(DependencyReport r) {
  final successor = r.replacedBy;
  if (successor == null) return '';
  final line = switch (r.replacementSource) {
    ReplacementSource.curated =>
      '<br>Move to ${_code(successor)} ([evidence](${r.replacementEvidence ?? ''}))',
    _ => '<br>Move to ${_code(successor)}, named by its publisher',
  };
  if (r.replacementWarnings.isEmpty) return line;
  return '$line<br>About ${_code(successor)} itself: '
      '${_escape(r.replacementWarnings.join('; '))}';
}

String scanMarkdown({
  required String toolVersion,
  required String projectName,
  required String dartVersion,
  required List<DependencyReport> dependencies,
  required int skippedCount,
  required bool androidChecked,
  required List<MatrixFinding> android,
}) {
  final out = StringBuffer();
  final blocking = dependencies.where((d) => d.verdict.isBlocking).length;
  final atRisk = dependencies.where((d) => d.verdict == Verdict.atRisk).length;
  final failures = android.where((f) => f.level == FindingLevel.fail).length;

  out
    ..writeln('## upkeep: ${_code(projectName)}')
    ..writeln()
    ..writeln(blocking + failures == 0
        ? '**Clean.**${atRisk > 0 ? ' $atRisk at risk.' : ''}'
        : '**${[
            if (blocking > 0) '$blocking blocking',
            if (atRisk > 0) '$atRisk at risk',
            if (failures > 0) '$failures build ${failures == 1 ? 'failure' : 'failures'}',
          ].join(', ')}**')
    ..writeln()
    ..writeln('<sub>upkeep $toolVersion · Dart $dartVersion · ${dependencies.length} direct dependencies'
        '${skippedCount > 0 ? ' · $skippedCount skipped (sdk, git or path)' : ''}</sub>')
    ..writeln();

  final notable = dependencies
      .where((r) =>
          r.verdict != Verdict.healthy &&
          r.verdict != Verdict.stale &&
          r.verdict != Verdict.upgradeBlocked)
      .toList();
  // One line, as in the terminal: an old local Flutter is one problem, not many.
  final sdkBlocked = dependencies.where((r) => r.verdict == Verdict.upgradeBlocked).toList();
  if (notable.isNotEmpty) {
    out
      ..writeln('### Dependencies')
      ..writeln()
      ..writeln('| Package | Verdict | Why |')
      ..writeln('|---|---|---|');
    for (final r in notable) {
      final version = r.resolvedVersion == null ? '' : ' ${_code(r.resolvedVersion!)}';
      out.writeln('| ${_code(r.name)}$version | **${r.verdict.label}** | '
          '${r.reasons.map(_escape).join('<br>')}${_replacementLine(r)} |');
    }
    out.writeln();
  }
  if (sdkBlocked.isNotEmpty) {
    out
      ..writeln('${sdkBlocked.length} ${sdkBlocked.length == 1 ? 'package has' : 'packages have'} a newer '
          'release this Dart is too old for (${sdkBlocked.map((r) => _code(r.name)).join(', ')}). '
          'Not a project problem; ${_code('flutter upgrade')} picks them up.')
      ..writeln();
  }

  if (androidChecked && android.isNotEmpty) {
    out
      ..writeln('### Android build')
      ..writeln();
    for (final f in android) {
      final mark = switch (f.level) {
        FindingLevel.fail => '❌',
        FindingLevel.warn => '⚠️',
        FindingLevel.pass => '✅',
        FindingLevel.unchecked => '➖',
      };
      out.writeln('- $mark ${_escape(f.title)}');
      if (f.detail != null) out.writeln('  <br><sub>${_escape(f.detail!)}</sub>');
      if (f.fix != null) out.writeln('  <br>Fix: ${_code(f.fix!)}');
    }
    out.writeln();
  }

  return out.toString();
}

String fixMarkdown({
  required String toolVersion,
  required String projectName,
  required FixPlan plan,
  ApplyResult? result,
}) {
  final out = StringBuffer();
  final applied = result != null && !result.wasReverted;

  out
    ..writeln(applied ? '## upkeep fixed ${_code(projectName)}' : '## upkeep fix plan: ${_code(projectName)}')
    ..writeln();

  if (plan.isEmpty) {
    out.writeln('Nothing to fix.');
    return out.toString();
  }

  if (plan.automatic.isNotEmpty) {
    out
      ..writeln(applied ? '### Changed in this pull request' : '### Automatic')
      ..writeln();
    for (final fix in applied ? result.applied : plan.automatic) {
      out.writeln('- [${applied ? 'x' : ' '}] **${_escape(fix.title)}** in ${_code(fix.file)}');
      for (final reason in fix.reasons) {
        out.writeln('  - ${_escape(reason)}');
      }
    }
    if (applied && result.verifiedWith != null) {
      out
        ..writeln()
        ..writeln('Verified: ${_code(result.verifiedWith!)} resolves with the new pubspec.');
    }
    if (applied && result.applied.any((f) => f is RaiseGradleWrapper)) {
      out.writeln('The Gradle change is not built by upkeep; CI or '
          '${_code('flutter build apk --debug')} confirms it.');
    }
    out.writeln();
  }

  if (plan.todos.isNotEmpty) {
    out
      ..writeln('### Still needs a person')
      ..writeln();
    for (final todo in plan.todos) {
      out.writeln('- [ ] **${_escape(todo.title)}**${todo.isBlocking ? '' : ' _(not blocking)_'}');
      for (final reason in todo.reasons) {
        out.writeln('  - ${_escape(reason)}');
      }
      if (todo.action != null) out.writeln('  - Next: ${_escape(todo.action!)}');
      if (todo.references.isNotEmpty) {
        out.writeln('  - Used in: ${todo.references.take(10).map((r) => _code('$r')).join(', ')}'
            '${todo.references.length > 10 ? ' and ${todo.references.length - 10} more' : ''}');
      }
    }
    out.writeln();
  }

  out.writeln('<sub>Generated by [upkeep](https://pub.dev/packages/upkeep) $toolVersion. '
      'Every change is reversible, and every verdict lists its reasons.</sub>');
  return out.toString();
}
