import 'dart:io';

import 'package:args/args.dart';
import 'package:upkeep/upkeep.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.')
    ..addFlag('version', negatable: false, help: 'Show the upkeep version.')
    ..addOption('path', abbr: 'p', defaultsTo: '.', help: 'Project directory to scan.')
    ..addFlag('no-cache', negatable: false, help: 'Ignore cached pub.dev responses and refetch.')
    ..addFlag('fail-on-at-risk',
        negatable: false,
        help: 'Also exit non-zero for AT RISK dependencies, not just blocking ones.')
    ..addFlag('no-color', negatable: false, help: 'Disable coloured output.');

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
  if (args.flag('help') || (rest.isNotEmpty && rest.first != 'scan')) {
    stdout.writeln(_usage(parser));
    exit(rest.isNotEmpty && rest.first != 'scan' ? ExitCodes.error : ExitCodes.clean);
  }

  final code = await runScan(
    projectPath: args.option('path') ?? '.',
    useCache: !args.flag('no-cache'),
    failOnAtRisk: args.flag('fail-on-at-risk'),
    style: args.flag('no-color') ? Style(enabled: false) : null,
  );
  exit(code);
}

String _usage(ArgParser parser) => '''
upkeep $upkeepVersion - the truth about your Flutter project's health.

Usage: upkeep scan [options]

${parser.usage}

Exit codes:
  0  clean
  1  blocking findings (discontinued, incompatible or dead dependency,
     or an Android build matrix that does not build)
  2  the scan could not run
''';
