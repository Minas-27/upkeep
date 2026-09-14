# upkeep

**Upgrade pain is the largest source of Flutter developer dissatisfaction. That finding is Google's, not mine.**

In the [Flutter Q2 2026 survey](https://flutter.dev/blog/flutter-q2-2026-survey),
platform and ecosystem maturity was the largest dissatisfaction theme, at 44%,
"centered on upgrade pain rather than getting started." In Google's words:
"Developers described losing hours to version-matrix guesswork when upgrading
older projects, especially on Android when juggling Flutter, Dart, Gradle,
Kotlin, and JVM versions together."

`pub get` warns you when a publisher marks a package discontinued. Most
abandoned packages are never marked. `hive` has not had a stable release since
June 2022, and `pub get` installs it without a word. Flutter checks your Android
build versions too, but only when you build, one error at a time.

`upkeep` puts both in one report, before you build. One command, no
configuration.

```console
$ dart pub global activate upkeep
$ upkeep scan
```

If your shell answers `upkeep: command not found`, `pub` installed the
executable somewhere that is not on your PATH. Add it once:

```console
$ export PATH="$PATH":"$HOME/.pub-cache/bin"
```

Put that line in your `.bashrc`, `.zshrc` or shell profile to make it stick. No
PATH change needed if you would rather run it through pub:

```console
$ dart pub global run upkeep scan
```

```
upkeep 0.2.2   my_app   Dart 3.11.0

DEPENDENCIES   23 direct

  DISCONTINUED   telephony  0.2.0
      marked discontinued by its publisher on pub.dev

  AT RISK        hive  2.2.3
      declares support only up to Dart >=2.12.0 <3.0.0; it resolves today through pub's Dart 3 allowance, not because it was updated
      no stable release in 50 months

  AT RISK        hive_flutter  1.1.0
      declares support only up to Dart >=2.12.0 <3.0.0; it resolves today through pub's Dart 3 allowance, not because it was updated
      no stable release in 62 months

  SDK BLOCKED    6 packages have a newer release your Dart is too old for
      flutter_riverpod, go_router, lottie, pdf, printing, shimmer
      upgrade Flutter to pick these up: flutter upgrade

  13 healthy  .  1 stale  .  2 skipped (sdk, git or path)

ANDROID BUILD

  FAIL       Gradle 8.4 is too old for AGP 8.11.1
             AGP 8.11.1 requires Gradle 8.13 or newer. This combination does not build.
             fix: ./gradlew wrapper --gradle-version=8.13   (run inside android/)

  PASS       JDK 17 satisfies AGP 8.11.1
             Requires JDK 17 or newer. Detected via java -version on PATH.

  PASS       compileSdk is managed by Flutter
             Set from flutter.compileSdkVersion, so it tracks your Flutter SDK.

1 blocking, 2 at risk, 1 build failure
```

## Fixing what it found

`upkeep fix` turns a scan into a plan: the changes it can make safely on its
own, and a to-do list for everything that needs a person, with the file and line
where each affected package is used. It changes nothing until you add
`--apply`.

```
upkeep 0.2.2   my_app   fix plan

AUTOMATIC   2 changes upkeep can make, each one reversible

  1  Raise the Gradle wrapper to 8.11.1
     AGP 8.9.0 requires Gradle 8.11.1 or newer; the wrapper is on 8.4
     android/gradle/wrapper/gradle-wrapper.properties

  2  Remove pedantic, which nothing imports
     marked discontinued by its publisher on pub.dev
     no Dart file imports package:pedantic, and no config file names it
     pubspec.yaml

TO DO   1 change needs a person

  [ ] Replace telephony
      marked discontinued by its publisher on pub.dev
      no maintained replacement is known yet; choose one on pub.dev
      used in 1 file:
        lib/main.dart:1

Run upkeep fix --apply to make the 2 automatic changes.
```

Only two kinds of change are ever automatic, and both are narrow on purpose:

- **Raising the Gradle wrapper** to the version Google publishes as the minimum
  for your AGP. Skipped when the wrapper pins a checksum; that one goes to
  `./gradlew wrapper` instead.
- **Removing a blocking dependency nothing refers to.** Not when any Dart file
  or config file mentions it, not for dev dependencies (those are usually run,
  not imported), and not for Flutter plugins, which can work with no import at
  all.

`--apply` refuses to run unless the files it edits are committed, so
`git checkout` undoes it. After editing `pubspec.yaml` it runs `pub get`, and if
the resolver rejects the result every file is put back exactly as it was.

## What it checks

**Your dependencies.** Every direct dependency is scored against pub.dev's own
data: release recency, pub points, download volume, Dart 3 and WASM readiness,
SDK constraints, and the official discontinued flag. When a publisher has
nominated a replacement package, `upkeep` names it.

**Your Android build matrix.** Gradle, AGP, Kotlin, JDK and `compileSdk` are
validated against Google's published requirements for AGP 8.0 through 9.4. When
something will not build, you get the exact command to fix it.

## The rules it holds itself to

A tool that judges your dependencies has exactly one asset, and it is trust.
So:

- **Every verdict prints its reasons.** Never a bare label. You can disagree
  with `upkeep` and see immediately why it said what it said.
- **Missing data is never evidence.** If pub.dev cannot be reached, the verdict
  is `UNKNOWN`, not `DEAD`. Requests are retried, and a dropped response is
  never reported as a missing package. When pub.dev's own analysis of a package
  failed, its low points and missing tags are not held against it either.
- **Stable is not abandoned.** A small, finished, widely-used package that has
  not needed a release in two years is not dying, and `upkeep` will not say it
  is.
- **The resolver gets the last word.** Where pub.dev's `is:dart3-compatible`
  tag contradicts a package's own SDK ceiling, the tag wins, because that is
  what the resolver actually does.
- **No guessing.** Where Google does not publish a number, `upkeep` says it
  cannot check rather than inventing one, and inferred values soften a verdict
  instead of hardening it.
- **An out-of-date local Flutter is not your project's fault.** Packages whose
  newest release needs a newer Dart than you have are grouped into one line and
  never fail your build.

## Explaining a verdict

`upkeep explain <package>` shows every fact a verdict rests on: release dates,
the SDK constraint, pub points, downloads, the Dart 3 tag, whether pub.dev's own
analysis succeeded, and where the package is used in your code. It works outside
a project too, which makes it a check before adding a dependency:

```console
$ upkeep explain some_package && dart pub add some_package
```

## Successors for packages nobody retired

pub.dev only names a replacement when a publisher sets one, and most dead
packages were simply left behind. upkeep carries a curated map of successors
for those, held to a stricter bar than anything else it says:

- every entry cites a primary source, such as the old package's own README
  naming its successor, and the report prints that link
- where several alternatives compete and nobody official named one, the package
  is left out, and so are hedged notices ("for example", "will deprecate")
- a successor is only suggested for a package already judged unhealthy, and only
  when the successor itself checks out healthy on pub.dev that day

The first 14 entries were verified on 12 September 2026, among them
`qr_code_scanner` → `mobile_scanner`, `envify` → `envied`, and
`flare_flutter` → `rive`.

## In CI

### GitHub Action

```yaml
name: upkeep
on:
  pull_request:
  schedule:
    - cron: "0 6 * * 1"

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: Minas-27/upkeep@v0.2.2
```

Pin a release tag, as above, rather than `@main`. A tag is the exact code you
reviewed; `main` changes as upkeep is developed, and `fix-pr` runs with write
access to your repository. Each release on pub.dev has a matching tag.

The scan fails the job on blocking findings, writes the report to the job
summary, and leaves a JSON report at the `report` output. Flutter or plain Dart
is picked from your `pubspec.yaml`.

To have upkeep open the fix pull request for you:

```yaml
jobs:
  fix:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: Minas-27/upkeep@v0.2.2
        with:
          command: fix-pr
```

GitHub does not let workflows open pull requests until you allow it once:
**Settings → Actions → General → Workflow permissions → Allow GitHub Actions to
create and approve pull requests.** Or pass a personal access token as `token`.

It applies only the automatic fixes, verifies them with `pub get`, commits only
the files those fixes touched to `upkeep/fixes`, and opens or updates one pull
request. Its description is the full plan, including the to-dos that still need
a person. The branch is force-pushed on every run, so commit elsewhere.

### Anywhere else

```yaml
- run: dart pub global activate upkeep
- run: upkeep scan
```

| Code | Meaning |
|---|---|
| `0` | Clean |
| `1` | Blocking findings: a discontinued, incompatible or dead dependency, or an Android matrix that does not build |
| `2` | The command could not run, or `fix --apply` refused or rolled back |

Add `--fail-on-at-risk` to treat warnings as failures too.

`--format json` prints a versioned document (`schemaVersion: 1`) for tools:
verdicts, reasons, replacements, Android findings, fix plans with file and line
references, and the exit code. Fields are only ever added; anything removed or
renamed bumps the schema version. `--format markdown` prints GitHub-flavoured
Markdown for job summaries and pull request descriptions.

## Options

```
-p, --path             Project directory (default: .)
-f, --format           text, json or markdown (default: text)
    --no-cache         Ignore cached pub.dev responses and refetch
    --fail-on-at-risk  Also exit non-zero for AT RISK dependencies
    --no-color         Disable coloured output
    --apply            fix only: make the automatic changes
    --allow-dirty      fix only: apply even with uncommitted changes, or outside git
    --version          Show the upkeep version
-h, --help             Show usage
```

Responses are cached for 24 hours under `~/.upkeep/cache`, so repeat scans do no
network work.

## Status

Version 0.2.2. It diagnoses, and it fixes the narrow set of things that can be
fixed without judgement. Everything else it hands to you as a to-do, with the
locations.

Built by [Abraham Addisu](https://abroid.dev). MIT licensed.
