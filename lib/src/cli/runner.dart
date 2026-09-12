import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import '../engine.dart';
import '../version.dart';
import '../fix/apply.dart';
import '../fix/plan.dart';
import '../project/loader.dart';
import '../project/lockfile.dart';
import '../project/pubspec.dart';
import '../project/references.dart';
import '../pub/cache.dart';
import '../pub/client.dart';
import '../report/explain_report.dart';
import '../report/fix_report.dart';
import '../report/json_report.dart';
import '../report/markdown_report.dart';
import '../report/terminal.dart';
import '../rules/android_matrix.dart';
import '../rules/dependency_health.dart';


/// Process exit codes. CI depends on these, so they are part of the contract.
abstract final class ExitCodes {
  /// Nothing blocking found.
  static const int clean = 0;

  /// Blocking findings: a discontinued, incompatible or dead dependency, or an
  /// Android matrix combination that does not build.
  static const int findings = 1;

  /// The command could not run, or `fix --apply` refused or rolled back.
  static const int error = 2;
}

/// How a command writes its result.
enum OutputFormat {
  /// Coloured, for people.
  text,

  /// A versioned JSON document, for tools. See `json_report.dart`.
  json,

  /// GitHub-flavoured Markdown, for job summaries and pull requests.
  markdown,
}

PubClient _client(bool useCache) {
  final cache = ResponseCache();
  if (!useCache) cache.clear();
  return PubClient(cache: cache);
}

/// Writes a failure in the format the caller asked for.
void _fail(StringSink sink, Style style, OutputFormat format, String command, String message) {
  switch (format) {
    case OutputFormat.json:
      sink.writeln(encodeJson({
        'schemaVersion': jsonSchemaVersion,
        'tool': {'name': 'upkeep', 'version': upkeepVersion},
        'command': command,
        'error': message,
        'exitCode': ExitCodes.error,
      }));
    case OutputFormat.markdown:
      sink.writeln('## upkeep could not run\n\n$message');
    case OutputFormat.text:
      sink.writeln(style.red('upkeep: $message'));
  }
}

Future<ProjectAnalysis?> _analyze({
  required String projectPath,
  required bool useCache,
  required Style style,
  required StringSink sink,
  required OutputFormat format,
  required String command,
  PubClient? client,
}) async {
  final Pubspec pubspec;
  try {
    pubspec = loadPubspec(projectPath);
  } on PubspecException catch (e) {
    _fail(sink, style, format, command, e.message);
    return null;
  }

  final pub = client ?? _client(useCache);
  try {
    return await analyzeProject(
      pubspec: pubspec,
      lockfile: loadLockfile(projectPath),
      android: loadAndroidConfig(projectPath),
      pub: pub,
      dartVersion: currentDartVersion(),
    );
  } finally {
    if (client == null) pub.close();
  }
}

/// Runs `upkeep scan` and returns the process exit code.
Future<int> runScan({
  required String projectPath,
  bool useCache = true,
  bool failOnAtRisk = false,
  OutputFormat format = OutputFormat.text,
  Style? style,
  StringSink? out,
  PubClient? client,
}) async {
  final sink = out ?? stdout;
  final styling = style ?? Style();

  final analysis = await _analyze(
    projectPath: projectPath,
    useCache: useCache,
    style: styling,
    sink: sink,
    format: format,
    command: 'scan',
    client: client,
  );
  if (analysis == null) return ExitCodes.error;

  final dependencies = analysis.dependencies;
  final androidFindings = analysis.androidFindings;

  final blocking = dependencies.any((d) => d.verdict.isBlocking) ||
      androidFindings.any((f) => f.level == FindingLevel.fail) ||
      (failOnAtRisk && dependencies.any((d) => d.verdict == Verdict.atRisk));
  final code = blocking ? ExitCodes.findings : ExitCodes.clean;

  switch (format) {
    case OutputFormat.text:
      TerminalReport(style: styling, out: sink).render(
        projectName: analysis.pubspec.name,
        dartVersion: currentDartVersion().toString(),
        toolVersion: upkeepVersion,
        dependencies: dependencies,
        skippedCount: analysis.skipped,
        android: androidFindings,
        androidChecked: analysis.android != null,
      );
    case OutputFormat.json:
      sink.writeln(scanJson(
        toolVersion: upkeepVersion,
        projectName: analysis.pubspec.name,
        dartVersion: currentDartVersion().toString(),
        dependencies: dependencies,
        skippedCount: analysis.skipped,
        androidChecked: analysis.android != null,
        android: androidFindings,
        exitCode: code,
      ));
    case OutputFormat.markdown:
      sink.write(scanMarkdown(
        toolVersion: upkeepVersion,
        projectName: analysis.pubspec.name,
        dartVersion: currentDartVersion().toString(),
        dependencies: dependencies,
        skippedCount: analysis.skipped,
        androidChecked: analysis.android != null,
        android: androidFindings,
      ));
  }

  return code;
}

/// Runs `upkeep fix` and returns the process exit code.
///
/// Without [apply] it only prints the plan. The exit codes keep the scan's
/// meaning: 1 while anything blocking is left, whether it is waiting for
/// `--apply` or for a person; 2 when applying was refused or rolled back.
Future<int> runFix({
  required String projectPath,
  bool apply = false,
  bool allowDirty = false,
  bool useCache = true,
  bool failOnAtRisk = false,
  OutputFormat format = OutputFormat.text,
  Style? style,
  StringSink? out,
  PubClient? client,
  PubGetRunner pubGet = runPubGet,
}) async {
  final sink = out ?? stdout;
  final styling = style ?? Style();

  final analysis = await _analyze(
    projectPath: projectPath,
    useCache: useCache,
    style: styling,
    sink: sink,
    format: format,
    command: 'fix',
    client: client,
  );
  if (analysis == null) return ExitCodes.error;

  final plan = const FixPlanner().plan(
    dependencies: analysis.dependencies,
    android: analysis.androidFindings,
    androidConfig: analysis.android,
    references: scanReferences(
      projectPath,
      analysis.dependencies.map((d) => d.name),
    ),
  );

  final report = FixReport(style: styling, out: sink);
  final name = analysis.pubspec.name;

  bool blockingLeft(bool automaticDone) =>
      (!automaticDone && plan.automatic.any((f) => f.isBlocking)) ||
      plan.todos.any((t) => t.isBlocking) ||
      (failOnAtRisk && analysis.dependencies.any((d) => d.verdict == Verdict.atRisk));

  void emit({ApplyResult? result, ApplyRefused? refusal, required int code}) {
    switch (format) {
      case OutputFormat.json:
        sink.writeln(fixJson(
          toolVersion: upkeepVersion,
          projectName: name,
          plan: plan,
          result: result,
          refusedBecause: refusal?.message,
          exitCode: code,
        ));
      case OutputFormat.markdown:
        sink.write(refusal != null
            ? '## upkeep did not change anything\n\n${refusal.message}\n'
            : fixMarkdown(toolVersion: upkeepVersion, projectName: name, plan: plan, result: result));
      case OutputFormat.text:
        if (refusal != null) {
          report.renderRefused(refusal);
        } else if (result != null) {
          report.renderApplied(projectName: name, toolVersion: upkeepVersion, plan: plan, result: result);
        } else {
          report.renderPlan(projectName: name, toolVersion: upkeepVersion, plan: plan);
        }
    }
  }

  if (!apply || plan.automatic.isEmpty) {
    final code = blockingLeft(false) ? ExitCodes.findings : ExitCodes.clean;
    emit(code: code);
    return code;
  }

  final ApplyResult result;
  try {
    result = await FixApplier(pubGet: pubGet, allowDirty: allowDirty).apply(
      projectPath,
      plan.automatic,
      isFlutterProject: analysis.pubspec.isFlutterProject,
    );
  } on ApplyRefused catch (refusal) {
    emit(refusal: refusal, code: ExitCodes.error);
    return ExitCodes.error;
  }

  final code = result.wasReverted
      ? ExitCodes.error
      : (blockingLeft(true) ? ExitCodes.findings : ExitCodes.clean);
  emit(result: result, code: code);
  return code;
}

/// Runs `upkeep explain <package>` and returns the process exit code.
///
/// Works inside or outside a project. Inside one, the package is judged as
/// declared and located in the code; outside, it is judged as if added today.
/// Exits 1 when the verdict would block a build, so it doubles as a pre-add
/// check: `upkeep explain some_package && dart pub add some_package`.
Future<int> runExplain({
  required String package,
  required String projectPath,
  bool useCache = true,
  OutputFormat format = OutputFormat.text,
  Style? style,
  StringSink? out,
  PubClient? client,
}) async {
  final sink = out ?? stdout;
  final styling = style ?? Style();

  Pubspec? pubspec;
  try {
    pubspec = loadPubspec(projectPath);
  } on PubspecException {
    pubspec = null;
  }

  DeclaredDependency? declared;
  for (final dep in pubspec?.dependencies ?? const <DeclaredDependency>[]) {
    if (dep.name == package) declared = dep;
  }
  if (declared != null && declared.source != DepSource.hosted) {
    _fail(sink, styling, format, 'explain',
        '$package comes from ${declared.source.name}, not pub.dev, so there is nothing to judge.');
    return ExitCodes.error;
  }

  final dependency =
      declared ?? DeclaredDependency(name: package, source: DepSource.hosted, isDev: false);
  final lock = pubspec == null ? const Lockfile({}) : loadLockfile(projectPath);

  final pub = client ?? _client(useCache);
  final engine = HealthEngine(dartSdkVersion: currentDartVersion());
  final PackageLookup lookup;
  DependencyReport? report;
  try {
    lookup = await pub.fetch(package);
    report = engine.evaluate([dependency], {package: lookup}, lock.versionOf).single;
    report = (await attachSuccessors([report], pub, engine)).single;
  } finally {
    if (client == null) pub.close();
  }

  final references = declared == null
      ? const <Reference>[]
      : scanReferences(projectPath, [package]).dartReferencesTo(package);

  final code = switch (lookup.status) {
    LookupStatus.found => report.verdict.isBlocking ? ExitCodes.findings : ExitCodes.clean,
    _ => ExitCodes.error,
  };
  final shown = lookup.info == null ? null : report;

  switch (format) {
    case OutputFormat.json:
      sink.writeln(explainJson(
        toolVersion: upkeepVersion,
        package: package,
        status: lookup.status,
        report: shown,
        declared: declared != null,
        references: [for (final r in references) {'file': r.file, 'line': r.line}],
        dartVersion: currentDartVersion().toString(),
        exitCode: code,
      ));
    case OutputFormat.markdown:
      // The explanation is aligned columns, so it travels as a fenced block.
      final plain = StringBuffer();
      _renderExplain(Style(enabled: false), plain, package, lookup.status, shown, declared != null, references);
      sink
        ..writeln('```text')
        ..write(plain.toString().trim())
        ..writeln()
        ..writeln('```');
    case OutputFormat.text:
      _renderExplain(styling, sink, package, lookup.status, shown, declared != null, references);
  }
  return code;
}

void _renderExplain(
  Style style,
  StringSink sink,
  String package,
  LookupStatus status,
  DependencyReport? report,
  bool declared,
  List<Reference> references,
) =>
    ExplainReport(style: style, out: sink).render(
      toolVersion: upkeepVersion,
      package: package,
      dartVersion: currentDartVersion().toString(),
      status: status,
      report: report,
      declared: declared,
      references: references,
    );

/// The Dart SDK running this process.
///
/// `Platform.version` looks like `3.11.0 (stable) (...) on "linux_x64"`, so the
/// version is the first token. Build-channel suffixes such as `-dev.1` are
/// dropped, because a pre-release Dart should be treated as its release line
/// when judging whether a package supports it.
Version currentDartVersion() {
  final token = Platform.version.split(' ').first;
  try {
    final parsed = Version.parse(token);
    return Version(parsed.major, parsed.minor, parsed.patch);
  } on FormatException {
    return Version(3, 0, 0);
  }
}
