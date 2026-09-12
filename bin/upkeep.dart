import 'dart:io';

import 'package:args/args.dart';
import 'package:upkeep/upkeep.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.')
    ..addFlag('version', negatable: false, help: 'Show the upkeep version.')
    ..addOption('path', abbr: 'p', defaultsTo: '.', help: 'Project directory.')
    ..addOption('format',
        abbr: 'f',
        allowed: ['text', 'json', 'markdown'],
        defaultsTo: 'text',
        help: 'Output format. json is a versioned contract for tools; markdown suits '
            'GitHub job summaries and pull requests.')
    ..addFlag('no-cache', negatable: false, help: 'Ignore cached pub.dev responses and refetch.')
    ..addFlag('fail-on-at-risk',
        negatable: false,
        help: 'Also exit non-zero for AT RISK dependencies, not just blocking ones.')
    ..addFlag('no-color', negatable: false, help: 'Disable coloured output.')
    ..addSeparator('fix only:')
    ..addFlag('apply',
        negatable: false,
        help: 'Make the automatic changes. Without it, fix only prints the plan.')
    ..addFlag('allow-dirty',
        negatable: false,
        help: 'Apply even when the files involved have uncommitted changes, or are not in git.');

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('upkeep: ${e.message}');
    stderr.writeln(_usage(parser));
    exit(ExitCodes.error);
  }

  if (args.flag('version')) {
    stdout.writeln('upkeep $upkeepVersion');
    return;
  }

  final rest = args.rest;
  final command = rest.isEmpty ? 'scan' : rest.first;
  const arity = {'scan': 1, 'fix': 1, 'explain': 2};
  final expected = arity[command];
  final wellFormed = expected != null && (rest.isEmpty || rest.length == expected);

  if (args.flag('help')) {
    stdout.writeln(_usage(parser));
    exit(ExitCodes.clean);
  }
  if (!wellFormed) {
    stderr.writeln(command == 'explain'
        ? 'upkeep: explain needs exactly one package name, e.g. upkeep explain http'
        : 'upkeep: unknown command "${rest.join(' ')}"');
    stderr.writeln(_usage(parser));
    exit(ExitCodes.error);
  }

  if (command != 'fix' && (args.flag('apply') || args.flag('allow-dirty'))) {
    stderr.writeln('upkeep: --apply and --allow-dirty only work with upkeep fix.');
    exit(ExitCodes.error);
  }

  final path = args.option('path') ?? '.';
  final format = OutputFormat.values.byName(args.option('format') ?? 'text');
  final style = args.flag('no-color') || format != OutputFormat.text ? Style(enabled: false) : null;
  final useCache = !args.flag('no-cache');

  final code = switch (command) {
    'fix' => await runFix(
        projectPath: path,
        apply: args.flag('apply'),
        allowDirty: args.flag('allow-dirty'),
        useCache: useCache,
        failOnAtRisk: args.flag('fail-on-at-risk'),
        format: format,
        style: style,
      ),
    'explain' => await runExplain(
        package: rest[1],
        projectPath: path,
        useCache: useCache,
        format: format,
        style: style,
      ),
    _ => await runScan(
        projectPath: path,
        useCache: useCache,
        failOnAtRisk: args.flag('fail-on-at-risk'),
        format: format,
        style: style,
      ),
  };
  exit(code);
}

String _usage(ArgParser parser) => '''
upkeep $upkeepVersion - the truth about your Flutter project's health.

Usage:
  upkeep scan [options]              dependency health and the Android build matrix
  upkeep fix [options]               what can be fixed automatically, and what needs a person
  upkeep fix --apply [options]       make the automatic changes, verified by pub get
  upkeep explain <package> [options] every fact behind one package's verdict

${parser.usage}

Exit codes:
  0  clean
  1  blocking findings (discontinued, incompatible or dead dependency,
     or an Android build matrix that does not build)
  2  the command could not run, or fix --apply refused or rolled back
''';
