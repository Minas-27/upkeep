import 'dart:io';

import '../rules/android_matrix.dart';
import '../rules/dependency_health.dart';

/// ANSI styling, switched off when output is piped or NO_COLOR is set.
class Style {
  Style({bool? enabled})
      : _on = enabled ?? (stdout.hasTerminal && Platform.environment['NO_COLOR'] == null);

  final bool _on;

  String _wrap(String code, String text) => _on ? '\x1B[${code}m$text\x1B[0m' : text;

  String bold(String t) => _wrap('1', t);
  String dim(String t) => _wrap('2', t);
  String red(String t) => _wrap('31', t);
  String yellow(String t) => _wrap('33', t);
  String green(String t) => _wrap('32', t);
  String cyan(String t) => _wrap('36', t);
  String magenta(String t) => _wrap('35', t);
}

/// Renders a scan to the terminal.
class TerminalReport {
  TerminalReport({Style? style, StringSink? out})
      : _s = style ?? Style(),
        _out = out ?? stdout;

  final Style _s;
  final StringSink _out;

  /// Writes the full report.
  void render({
    required String projectName,
    required String dartVersion,
    required String toolVersion,
    required List<DependencyReport> dependencies,
    required int skippedCount,
    required List<MatrixFinding> android,
    required bool androidChecked,
  }) {
    _out
      ..writeln()
      ..writeln('${_s.bold('upkeep')} ${_s.dim(toolVersion)}   '
          '${_s.bold(projectName)}   ${_s.dim('Dart $dartVersion')}');

    _renderDependencies(dependencies, skippedCount);
    if (androidChecked) _renderAndroid(android);
    _renderSummary(dependencies, android, androidChecked);
  }

  void _renderDependencies(List<DependencyReport> reports, int skipped) {
    _out
      ..writeln()
      ..writeln('${_s.bold('DEPENDENCIES')}${_s.dim('   ${reports.length} direct')}');

    final notable = reports
        .where((r) =>
            r.verdict != Verdict.healthy &&
            r.verdict != Verdict.stale &&
            r.verdict != Verdict.upgradeBlocked)
        .toList();

    if (notable.isEmpty) {
      _out
        ..writeln()
        ..writeln('  ${_s.green('Nothing to worry about.')}');
    }

    for (final report in notable) {
      _out
        ..writeln()
        ..writeln('  ${_badge(report.verdict)}  ${_s.bold(report.name)}${_versionSuffix(report)}');
      for (final reason in report.reasons) {
        _out.writeln('      ${_s.dim(reason)}');
      }
      final replacement = report.replacedBy;
      if (replacement != null) {
        final source = report.replacementSource == ReplacementSource.curated
            ? _s.dim('   successor named at ${report.replacementEvidence}')
            : '';
        _out.writeln('      ${_s.cyan('move to $replacement')}$source');
        if (report.replacementWarnings.isNotEmpty) {
          _out.writeln('        ${_s.dim('about $replacement itself:')}');
          for (final warning in report.replacementWarnings) {
            _out.writeln('          ${_s.dim(warning)}');
          }
        }
      }
    }

    _renderSdkBlocked(reports);

    final counts = <Verdict, int>{};
    for (final r in reports) {
      counts[r.verdict] = (counts[r.verdict] ?? 0) + 1;
    }
    final tail = <String>[
      if ((counts[Verdict.healthy] ?? 0) > 0) '${counts[Verdict.healthy]} healthy',
      if ((counts[Verdict.stale] ?? 0) > 0) '${counts[Verdict.stale]} stale',
      if (skipped > 0) '$skipped skipped (sdk, git or path)',
    ];
    if (tail.isNotEmpty) {
      _out
        ..writeln()
        ..writeln('  ${_s.dim(tail.join('  .  '))}');
    }
  }

  /// SDK-blocked packages are collapsed into one message on purpose.
  ///
  /// When a developer's Flutter is a few months old, a dozen dependencies all
  /// report the same thing. Listing them one by one reads as twelve problems
  /// when it is really one, and the one is "upgrade Flutter".
  void _renderSdkBlocked(List<DependencyReport> reports) {
    final blocked = reports.where((r) => r.verdict == Verdict.upgradeBlocked).toList();
    if (blocked.isEmpty) return;

    final wanted = <String>{for (final r in blocked) r.requiresDart ?? ''}..remove('');
    final requirement = wanted.length == 1 ? ' (they want Dart ${wanted.first})' : '';

    _out
      ..writeln()
      ..writeln('  ${_badge(Verdict.upgradeBlocked)}  '
          '${_s.bold('${blocked.length} ${blocked.length == 1 ? 'package has' : 'packages have'} '
              'a newer release your Dart is too old for')}$requirement')
      ..writeln('      ${_s.dim(blocked.map((r) => r.name).join(', '))}')
      ..writeln('      ${_s.cyan('upgrade Flutter to pick these up: flutter upgrade')}');
  }

  String _versionSuffix(DependencyReport r) {
    final resolved = r.resolvedVersion;
    final latest = r.info?.latestVersion;
    if (resolved == null || latest == null) return '';
    if (r.isBehind) return _s.dim('  $resolved -> $latest available');
    return _s.dim('  $resolved');
  }

  void _renderAndroid(List<MatrixFinding> findings) {
    _out
      ..writeln()
      ..writeln(_s.bold('ANDROID BUILD'));

    if (findings.isEmpty) {
      _out
        ..writeln()
        ..writeln('  ${_s.dim('Nothing could be checked.')}');
      return;
    }

    for (final f in findings) {
      _out
        ..writeln()
        ..writeln('  ${_level(f.level)}  ${f.title}');
      final detail = f.detail;
      if (detail != null) _out.writeln('             ${_s.dim(detail)}');
      final fix = f.fix;
      if (fix != null) {
        final where = f.fixFile == null ? '' : _s.dim('   (${f.fixFile})');
        _out.writeln('             ${_s.cyan('fix: $fix')}$where');
      }
    }
  }

  void _renderSummary(
    List<DependencyReport> deps,
    List<MatrixFinding> android,
    bool androidChecked,
  ) {
    final blocking = deps.where((d) => d.verdict.isBlocking).length;
    final atRisk = deps.where((d) => d.verdict == Verdict.atRisk).length;
    final failures = androidChecked ? android.where((f) => f.level == FindingLevel.fail).length : 0;

    final parts = <String>[
      if (blocking > 0) '$blocking blocking',
      if (atRisk > 0) '$atRisk at risk',
      if (failures > 0) '$failures build ${failures == 1 ? 'failure' : 'failures'}',
    ];

    _out.writeln();
    _out.writeln(parts.isEmpty ? _s.green('Clean.') : _s.bold(parts.join(', ')));
    _out.writeln();
  }

  String _badge(Verdict v) => switch (v) {
        Verdict.discontinued => _s.magenta(_s.bold(v.label.padRight(13))),
        Verdict.incompatible => _s.red(_s.bold(v.label.padRight(13))),
        Verdict.dead => _s.red(_s.bold(v.label.padRight(13))),
        Verdict.atRisk => _s.yellow(_s.bold(v.label.padRight(13))),
        Verdict.upgradeBlocked => _s.cyan(v.label.padRight(13)),
        Verdict.stale => _s.dim(v.label.padRight(13)),
        Verdict.healthy => _s.green(v.label.padRight(13)),
        Verdict.unknown => _s.dim(v.label.padRight(13)),
      };

  String _level(FindingLevel l) => switch (l) {
        FindingLevel.fail => _s.red(_s.bold('FAIL'.padRight(9))),
        FindingLevel.warn => _s.yellow(_s.bold('WARN'.padRight(9))),
        FindingLevel.pass => _s.green('PASS'.padRight(9)),
        FindingLevel.unchecked => _s.dim('SKIPPED'.padRight(9)),
      };
}
