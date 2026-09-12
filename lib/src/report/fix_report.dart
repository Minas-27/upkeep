import 'dart:io';

import '../fix/apply.dart';
import '../fix/plan.dart';
import 'terminal.dart';

/// Renders `upkeep fix`: the plan, and what applying it did.
class FixReport {
  FixReport({Style? style, StringSink? out})
      : _s = style ?? Style(),
        _out = out ?? stdout;

  final Style _s;
  final StringSink _out;

  void _header(String projectName, String toolVersion, String what) {
    _out
      ..writeln()
      ..writeln('${_s.bold('upkeep')} ${_s.dim(toolVersion)}   '
          '${_s.bold(projectName)}   ${_s.dim(what)}');
  }

  /// Writes the plan without changing anything.
  void renderPlan({
    required String projectName,
    required String toolVersion,
    required FixPlan plan,
  }) {
    _header(projectName, toolVersion, 'fix plan');

    if (plan.isEmpty) {
      _out
        ..writeln()
        ..writeln('  ${_s.green('Nothing to fix.')}')
        ..writeln();
      return;
    }

    _renderAutomatic(plan.automatic);
    _renderTodos(plan.todos);

    _out.writeln();
    final count = plan.automatic.length;
    if (count > 0) {
      _out.writeln('Run ${_s.bold('upkeep fix --apply')} to make the $count automatic '
          '${count == 1 ? 'change' : 'changes'}.');
    } else {
      _out.writeln(_s.dim('Nothing here can be changed safely without a person.'));
    }
    _out.writeln();
  }

  /// Writes what `--apply` did, then whatever is still left for a person.
  void renderApplied({
    required String projectName,
    required String toolVersion,
    required FixPlan plan,
    required ApplyResult result,
  }) {
    final count = plan.automatic.length;
    _header(projectName, toolVersion,
        'applying $count ${count == 1 ? 'change' : 'changes'}');
    _out.writeln();

    final reverted = result.revertedBecause;
    if (reverted != null) {
      for (final fix in plan.automatic) {
        _out.writeln('  ${_s.yellow('reverted'.padRight(10))}${fix.title}');
      }
      _out
        ..writeln()
        ..writeln('  ${_s.red('Every file was restored.')} pub get did not succeed, so nothing was kept:');
      for (final line in reverted.split('\n')) {
        _out.writeln('      ${_s.dim(line)}');
      }
      _out.writeln();
      return;
    }

    for (final fix in result.applied) {
      _out.writeln('  ${_s.green('done'.padRight(10))}${fix.title}');
    }
    final verified = result.verifiedWith;
    if (verified != null) {
      _out.writeln('  ${_s.green('verified'.padRight(10))}$verified resolves with the new pubspec');
    }
    if (result.applied.any((f) => f is RaiseGradleWrapper)) {
      _out.writeln('  ${_s.dim('unbuilt'.padRight(10))}${_s.dim('the Gradle change has not been '
          'built yet; flutter build apk --debug confirms it')}');
    }

    _renderTodos(plan.todos);

    final remaining = plan.todos.length;
    _out
      ..writeln()
      ..writeln('${result.applied.length} applied.'
          '${remaining == 0 ? '' : ' $remaining ${remaining == 1 ? 'to-do remains' : 'to-dos remain'}.'}')
      ..writeln();
  }

  /// Writes why `--apply` refused to start.
  void renderRefused(ApplyRefused refusal) {
    _out
      ..writeln()
      ..writeln('  ${_s.yellow('Nothing was changed.')} ${refusal.message}');
    final hint = refusal.hint;
    if (hint != null) _out.writeln('  ${_s.dim(hint)}');
    _out.writeln();
  }

  void _renderAutomatic(List<AutomaticFix> fixes) {
    if (fixes.isEmpty) return;
    _out
      ..writeln()
      ..writeln('${_s.green(_s.bold('AUTOMATIC'))}   ${_s.dim('${fixes.length} '
          '${fixes.length == 1 ? 'change' : 'changes'} upkeep can make, each one reversible')}');

    for (var i = 0; i < fixes.length; i++) {
      final fix = fixes[i];
      _out
        ..writeln()
        ..writeln('  ${_s.bold('${i + 1}'.padRight(3))}${_s.bold(fix.title)}');
      for (final reason in fix.reasons) {
        _out.writeln('     ${_s.dim(reason)}');
      }
      _out.writeln('     ${_s.cyan(fix.file)}');
    }
  }

  void _renderTodos(List<FixTodo> todos) {
    if (todos.isEmpty) return;
    _out
      ..writeln()
      ..writeln('${_s.yellow(_s.bold('TO DO'))}   ${_s.dim('${todos.length} '
          '${todos.length == 1 ? 'change needs' : 'changes need'} a person')}');

    for (final todo in todos) {
      final tag = todo.isBlocking ? '' : _s.dim('   not blocking');
      _out
        ..writeln()
        ..writeln('  [ ] ${_s.bold(todo.title)}$tag');
      for (final reason in todo.reasons) {
        _out.writeln('      ${_s.dim(reason)}');
      }
      final action = todo.action;
      if (action != null) _out.writeln('      ${_s.cyan(action)}');

      final refs = todo.references;
      if (refs.isNotEmpty) {
        final files = {for (final r in refs) r.file}.length;
        _out.writeln('      ${_s.dim('used in $files ${files == 1 ? 'file' : 'files'}:')}');
        const shown = 8;
        for (final ref in refs.take(shown)) {
          _out.writeln('        $ref');
        }
        if (refs.length > shown) {
          _out.writeln('        ${_s.dim('and ${refs.length - shown} more')}');
        }
      }
    }
  }
}
