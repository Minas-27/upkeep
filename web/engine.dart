/// The upkeep engine, compiled to JavaScript for the web app.
///
/// Exposes one function, `upkeepEngine.analyze(requestJson)`, which returns a
/// promise of a JSON string. It runs the same `analyzeProject`, planner and
/// report code as the command line; only file reading differs, because the page
/// hands over file contents instead.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:pub_semver/pub_semver.dart';
import 'package:upkeep/src/engine.dart';
import 'package:upkeep/src/fix/plan.dart';
import 'package:upkeep/src/project/android.dart';
import 'package:upkeep/src/project/lockfile.dart';
import 'package:upkeep/src/project/pubspec.dart';
import 'package:upkeep/src/project/references.dart';
import 'package:upkeep/src/pub/client.dart';
import 'package:upkeep/src/report/json_report.dart';
import 'package:upkeep/src/report/markdown_report.dart';
import 'package:upkeep/src/rules/android_matrix.dart';
import 'package:upkeep/src/version.dart';

final _pub = PubClient();

void main() {
  final api = JSObject();
  api.setProperty('version'.toJS, upkeepVersion.toJS);
  api.setProperty(
    'analyze'.toJS,
    ((JSString request) => _analyze(request.toDart).then((r) => r.toJS).toJS).toJS,
  );
  globalContext.setProperty('upkeepEngine'.toJS, api);
}

/// Request: `{pubspec, lock?, android?: {path: text}, dartFiles?: {path: text},
/// rootYaml?: {name: text}, dartVersion}`.
Future<String> _analyze(String requestJson) async {
  try {
    final request = jsonDecode(requestJson) as Map<String, dynamic>;
    final pubspec = Pubspec.parse(request['pubspec'] as String);
    final lockText = request['lock'] as String?;
    final androidFiles = (request['android'] as Map<String, dynamic>?)?.cast<String, String>();
    final dartFiles = (request['dartFiles'] as Map<String, dynamic>?)?.cast<String, String>();
    final rootYaml = (request['rootYaml'] as Map<String, dynamic>?)?.cast<String, String>();
    final dart = Version.parse(request['dartVersion'] as String);

    final android = androidFiles == null || androidFiles.isEmpty
        ? null
        : AndroidConfig.fromFiles(
            androidFiles,
            jdkUnavailableReason: 'A browser cannot see your JDK. Run upkeep scan locally to check it.',
          );

    final analysis = await analyzeProject(
      pubspec: pubspec,
      lockfile: lockText == null ? const Lockfile({}) : Lockfile.parse(lockText),
      android: android,
      pub: _pub,
      dartVersion: dart,
    );

    final references = dartFiles == null
        ? const ReferenceIndex.unknown()
        : ReferenceIndex.fromSources(
            dartFiles: dartFiles,
            rootYaml: {'pubspec.yaml': request['pubspec'] as String, ...?rootYaml},
            packageNames: analysis.dependencies.map((d) => d.name),
          );

    final plan = const FixPlanner().plan(
      dependencies: analysis.dependencies,
      android: analysis.androidFindings,
      androidConfig: analysis.android,
      references: references,
    );

    final blocking = analysis.dependencies.any((d) => d.verdict.isBlocking) ||
        analysis.androidFindings.any((f) => f.level == FindingLevel.fail);
    final exitCode = blocking ? 1 : 0;

    final scan = scanJson(
      toolVersion: upkeepVersion,
      projectName: pubspec.name,
      dartVersion: dart.toString(),
      dependencies: analysis.dependencies,
      skippedCount: analysis.skipped,
      androidChecked: analysis.android != null,
      android: analysis.androidFindings,
      exitCode: exitCode,
    );
    final fix = fixJson(
      toolVersion: upkeepVersion,
      projectName: pubspec.name,
      plan: plan,
      result: null,
      refusedBecause: null,
      exitCode: exitCode,
    );

    return jsonEncode({
      'ok': true,
      'referencesRead': references.known,
      'scan': jsonDecode(scan),
      'fix': jsonDecode(fix),
      'markdown': {
        'scan': scanMarkdown(
          toolVersion: upkeepVersion,
          projectName: pubspec.name,
          dartVersion: dart.toString(),
          dependencies: analysis.dependencies,
          skippedCount: analysis.skipped,
          androidChecked: analysis.android != null,
          android: analysis.androidFindings,
        ),
        'fix': fixMarkdown(toolVersion: upkeepVersion, projectName: pubspec.name, plan: plan),
      },
    });
  } on PubspecException catch (e) {
    return jsonEncode({'ok': false, 'error': e.message});
  } on FormatException catch (e) {
    return jsonEncode({'ok': false, 'error': 'Could not read the input: ${e.message}'});
  } catch (e) {
    return jsonEncode({'ok': false, 'error': '$e'});
  }
}
