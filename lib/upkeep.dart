/// The truth about your Flutter project's health.
///
/// The command line tool is the product; this library exists so the engine can
/// be embedded, tested, and later reused by the CI integration.
library;

export 'src/cli/runner.dart'
    show runScan, runFix, runExplain, upkeepVersion, ExitCodes, OutputFormat, currentDartVersion;
export 'src/data/replacements.dart';
export 'src/fix/apply.dart';
export 'src/fix/plan.dart';
export 'src/data/agp_matrix.dart';
export 'src/project/android.dart';
export 'src/project/lockfile.dart';
export 'src/project/pubspec.dart';
export 'src/project/references.dart';
export 'src/pub/client.dart';
export 'src/report/terminal.dart' show Style;
export 'src/rules/android_matrix.dart';
export 'src/rules/dependency_health.dart';
export 'src/rules/replacements.dart';
export 'src/report/json_report.dart' show jsonSchemaVersion;
