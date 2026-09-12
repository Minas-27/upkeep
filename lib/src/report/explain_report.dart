import 'dart:io';

import '../project/references.dart';
import '../pub/client.dart';
import '../rules/dependency_health.dart';
import 'terminal.dart';

/// Renders `upkeep explain <package>`: every fact the verdict rests on.
///
/// The scan shows reasons. This shows the evidence under the reasons, so a
/// reader who disagrees can see exactly which number they disagree with.
class ExplainReport {
  ExplainReport({Style? style, StringSink? out})
      : _s = style ?? Style(),
        _out = out ?? stdout;

  final Style _s;
  final StringSink _out;

  void render({
    required String toolVersion,
    required String package,
    required String dartVersion,
    required LookupStatus status,
    required DependencyReport? report,
    required bool declared,
    required List<Reference> references,
  }) {
    _out
      ..writeln()
      ..writeln('${_s.bold('upkeep')} ${_s.dim(toolVersion)}   '
          '${_s.bold(package)}   ${_s.dim('explain, against Dart $dartVersion')}');

    final info = report?.info;
    if (report == null || info == null) {
      _out
        ..writeln()
        ..writeln('  ${switch (status) {
          LookupStatus.notFound => '${_s.bold(package)} is not published on pub.dev.',
          _ => 'pub.dev could not be reached, so there is nothing to explain yet. '
              'No verdict is better than a guessed one.',
        }}')
        ..writeln();
      return;
    }

    _out
      ..writeln()
      ..writeln(_s.bold('VERDICT'))
      ..writeln()
      ..writeln('  ${_s.bold(report.verdict.label)}'
          '${report.verdict.isBlocking ? _s.dim('   fails a CI build') : _s.dim('   does not fail a build')}');
    if (report.reasons.isEmpty) {
      _out.writeln('      ${_s.dim('no warning signs')}');
    }
    for (final reason in report.reasons) {
      _out.writeln('      ${_s.dim(reason)}');
    }
    final successor = report.replacedBy;
    if (successor != null) {
      _out.writeln('      ${_s.cyan('move to $successor')}${_s.dim(
        report.replacementSource == ReplacementSource.curated
            ? '   successor named at ${report.replacementEvidence}'
            : '   named by its publisher',
      )}');
    }

    _out
      ..writeln()
      ..writeln(_s.bold('FACTS FROM PUB.DEV'))
      ..writeln();

    final published = info.latestPublished.toIso8601String().substring(0, 10);
    _fact('latest release', '${info.latestVersion}, published $published '
        '(${info.monthsSinceRelease} months ago)');
    _fact('releases ever', '${info.releaseCount}');
    _fact('sdk constraint', info.latestSdkConstraint?.toString() ?? 'not declared');
    _fact('discontinued', info.isDiscontinued
        ? 'yes${info.replacedBy == null ? '' : ', replaced by ${info.replacedBy}'}'
        : 'no');
    _fact('flutter plugin', switch (info.isFlutterPlugin) {
      true => 'yes',
      false => 'no',
      null => 'unknown',
    });
    _fact('publisher', info.publisher ?? 'none verified');
    if (info.hasAnalysis) {
      _fact('pub points', '${info.grantedPoints} of ${info.maxPoints}');
      _fact('downloads', '${formatCount(info.downloads30Days)} in the last 30 days');
      _fact('dart 3', info.isDart3Compatible ? 'compatible, per pub.dev' : 'not marked compatible');
    } else if (info.hasScoreData) {
      _fact('pub analysis', 'failed (has:error), so points and tags are not evidence');
      _fact('downloads', '${formatCount(info.downloads30Days)} in the last 30 days');
    } else {
      _fact('score data', 'unavailable, so points, downloads and tags were not judged');
    }

    _out
      ..writeln()
      ..writeln(_s.bold('IN THIS PROJECT'))
      ..writeln();
    if (!declared) {
      _out.writeln('  ${_s.dim('not a direct dependency here; judged as if it were added today')}');
    } else {
      final resolved = report.resolvedVersion;
      _fact('declared', report.declaredConstraint ?? 'any');
      _fact('resolved', resolved == null
          ? 'not locked; run pub get'
          : '$resolved${report.isBehind ? ', behind ${info.latestVersion}' : ''}');
      if (references.isEmpty) {
        _fact('used in', 'no file mentions package:$package');
      } else {
        final files = {for (final r in references) r.file}.length;
        _fact('used in', '$files ${files == 1 ? 'file' : 'files'}');
        for (final ref in references.take(12)) {
          _out.writeln('                    $ref');
        }
        if (references.length > 12) {
          _out.writeln('                    ${_s.dim('and ${references.length - 12} more')}');
        }
      }
    }
    _out.writeln();
  }

  void _fact(String label, String value) =>
      _out.writeln('  ${_s.dim(label.padRight(18))}$value');
}
