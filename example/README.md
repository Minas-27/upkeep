# Using upkeep

`upkeep` is a command line tool. Install it once, then run it inside any Dart or
Flutter project.

```console
$ dart pub global activate upkeep
$ cd path/to/your_flutter_app
$ upkeep scan
```

## What you get

```
upkeep 0.1.0   my_app   Dart 3.11.0

DEPENDENCIES   27 direct

  DISCONTINUED   telephony  0.2.0
      marked discontinued by its publisher on pub.dev

  INCOMPATIBLE   lucide_icons  0.257.0
      its newest release caps Dart at >=2.12.0 <3.0.0, which excludes
      the Dart 3.11.0 in use here
      no release has ever supported this Dart, so waiting will not fix it

  AT RISK        isar  3.1.0+1
      declares support only up to Dart <3.0.0; it resolves today through
      pub's Dart 3 allowance, not because it was updated
      no release in 30 months

  SDK BLOCKED    8 packages have a newer release your Dart is too old for
      upgrade Flutter to pick these up: flutter upgrade

  11 healthy  .  7 stale  .  3 skipped (sdk, git or path)

ANDROID BUILD

  FAIL       Gradle 8.4 is too old for AGP 8.9
             AGP 8.9 requires Gradle 8.11.1 or newer. This does not build.
             fix: ./gradlew wrapper --gradle-version=8.11.1   (run in android/)

1 blocking, 1 at risk, 1 build failure
```

Every verdict prints the reasons behind it, so you can disagree with `upkeep`
and see exactly why it said what it said.

## In CI

`upkeep` exits non-zero on blocking findings, so it needs no configuration to
work as a check.

```yaml
- run: dart pub global activate upkeep
- run: upkeep scan
```

| Code | Meaning |
|---|---|
| `0` | Clean |
| `1` | Blocking findings |
| `2` | The scan could not run |

## Scanning somewhere else

```console
$ upkeep scan --path ../other_project
$ upkeep scan --no-cache          # ignore the 24 hour response cache
$ upkeep scan --fail-on-at-risk   # treat warnings as failures too
$ upkeep scan --no-color          # for logs and CI output
```

## Using the engine directly

The CLI is the product, but the engine is importable for tooling that needs the
verdicts rather than the report.

```dart
import 'package:upkeep/upkeep.dart';

Future<void> main() async {
  final code = await runScan(projectPath: '.');
  print('upkeep exited with $code');
}
```
