import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml_edit/yaml_edit.dart';

import 'plan.dart';
import 'result.dart';

export 'result.dart';

/// Runs `pub get` for the project at [root] and reports whether it resolved.
typedef PubGetRunner = Future<ProcessResult> Function(String root, {required bool flutter});

/// Runs the real `flutter pub get` or `dart pub get`.
Future<ProcessResult> runPubGet(String root, {required bool flutter}) => Process.run(
      flutter ? 'flutter' : 'dart',
      const ['pub', 'get'],
      workingDirectory: root,
      runInShell: Platform.isWindows,
    );

/// Applies the automatic part of a [FixPlan].
///
/// Reversible twice over. It refuses to run unless every file it touches is
/// committed, so `git checkout` always undoes it; and it keeps the original
/// bytes itself, so when `pub get` rejects the result it puts them back before
/// returning. The resolver gets the last word, and a failed resolve leaves the
/// project exactly as it was found.
class FixApplier {
  const FixApplier({this.pubGet = runPubGet, this.allowDirty = false});

  final PubGetRunner pubGet;

  /// Skips the clean-git check. For projects outside git, at the user's word.
  final bool allowDirty;

  Future<ApplyResult> apply(
    String root,
    List<AutomaticFix> fixes, {
    required bool isFlutterProject,
  }) async {
    if (fixes.isEmpty) return const ApplyResult(applied: []);

    final touched = {for (final f in fixes) f.file};
    final touchesPubspec = fixes.any((f) => f is RemoveDependency);
    if (touchesPubspec) touched.add('pubspec.lock');

    // The lockfile is left out of the git check: pub regenerates it, and the
    // original is restored below if the resolve fails.
    if (!allowDirty) await _requireClean(root, {for (final f in fixes) f.file});

    final originals = <String, String?>{
      for (final file in touched) file: _readOrNull(File(p.join(root, file))),
    };

    try {
      _editPubspec(root, fixes.whereType<RemoveDependency>().toList());
      for (final fix in fixes.whereType<RaiseGradleWrapper>()) {
        _editWrapper(root, fix);
      }
    } on Object {
      _restore(root, originals);
      rethrow;
    }

    if (!touchesPubspec) return ApplyResult(applied: fixes);

    final command = '${isFlutterProject ? 'flutter' : 'dart'} pub get';
    final ProcessResult result;
    try {
      result = await pubGet(root, flutter: isFlutterProject);
    } on ProcessException catch (e) {
      _restore(root, originals);
      return ApplyResult(applied: const [], revertedBecause: '$command could not run: ${e.message}');
    }

    if (result.exitCode != 0) {
      _restore(root, originals);
      return ApplyResult(
        applied: const [],
        revertedBecause: '$command failed:\n${_tail('${result.stderr}${result.stdout}')}',
      );
    }

    return ApplyResult(applied: fixes, verifiedWith: command);
  }

  Future<void> _requireClean(String root, Set<String> files) async {
    final ProcessResult status;
    try {
      status = await Process.run(
        'git',
        ['status', '--porcelain', '--', ...files],
        workingDirectory: root,
      );
    } on ProcessException {
      throw const ApplyRefused(
        'git is not available, so these changes could not be undone with it.',
        hint: 'Pass --allow-dirty to apply anyway.',
      );
    }

    if (status.exitCode != 0) {
      throw const ApplyRefused(
        'This project is not in a git repository, so these changes could not be undone with it.',
        hint: 'Commit it to git first, or pass --allow-dirty to apply anyway.',
      );
    }

    final dirty = '${status.stdout}'
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.substring(3).trim())
        .toList();
    if (dirty.isNotEmpty) {
      throw ApplyRefused(
        'Uncommitted changes in ${dirty.join(', ')}. upkeep only edits files git can restore.',
        hint: 'Commit or stash them, or pass --allow-dirty to apply anyway.',
      );
    }
  }

  static void _editPubspec(String root, List<RemoveDependency> removals) {
    if (removals.isEmpty) return;
    final file = File(p.join(root, 'pubspec.yaml'));
    final editor = YamlEditor(file.readAsStringSync());
    for (final removal in removals) {
      editor.remove([removal.isDev ? 'dev_dependencies' : 'dependencies', removal.package]);
    }
    file.writeAsStringSync(editor.toString());
  }

  static void _editWrapper(String root, RaiseGradleWrapper fix) {
    final file = File(p.join(root, fix.file));
    final text = file.readAsStringSync();
    final pattern = RegExp(r'gradle-[0-9]+(?:\.[0-9]+)*-(all|bin)\.zip');
    if (!pattern.hasMatch(text)) {
      throw StateError('no Gradle distribution URL found in ${fix.file}');
    }
    file.writeAsStringSync(text.replaceFirstMapped(pattern, (m) => 'gradle-${fix.to}-${m[1]}.zip'));
  }

  static void _restore(String root, Map<String, String?> originals) {
    for (final entry in originals.entries) {
      final file = File(p.join(root, entry.key));
      final content = entry.value;
      if (content == null) {
        if (file.existsSync()) file.deleteSync();
      } else {
        file.writeAsStringSync(content);
      }
    }
  }

  static String? _readOrNull(File file) => file.existsSync() ? file.readAsStringSync() : null;

  static String _tail(String output) {
    final lines = output.trim().split('\n');
    return lines.skip(lines.length > 6 ? lines.length - 6 : 0).join('\n');
  }
}
