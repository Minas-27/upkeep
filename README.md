# upkeep

**44% of Flutter developer dissatisfaction comes from version-matrix guesswork. That number is Google's, not mine.**

The [Flutter Q2 2026 survey](https://flutter.dev/blog/what-do-flutter-package-users-need-findings-from-q2-user-survey)
found that platform and ecosystem maturity drives 44% of developer
dissatisfaction, and named the cause directly: hours lost "juggling Flutter,
Dart, Gradle, Kotlin, and JVM versions together." Another 18% said the packages
they needed did not exist. And when a package quietly dies, nothing tells you.

`upkeep` tells you. One command, no configuration.

```console
$ dart pub global activate upkeep
$ upkeep scan
```

```
upkeep 0.1.0   my_app   Dart 3.11.0

DEPENDENCIES   27 direct

  DISCONTINUED   telephony  0.2.0
      marked discontinued by its publisher on pub.dev

  INCOMPATIBLE   lucide_icons  0.257.0
      its newest release (0.257.0) caps Dart at >=2.12.0 <3.0.0, which excludes the Dart 3.11.0 in use here
      no release has ever supported this Dart, so waiting will not fix it

  AT RISK        isar  3.1.0+1
      declares support only up to Dart >=2.17.0 <3.0.0; it resolves today
      through pub's Dart 3 allowance, not because it was updated
      no release in 30 months

  SDK BLOCKED    8 packages have a newer release your Dart is too old for
      cached_network_image, flutter_riverpod, go_router, lottie, pdf, printing, ...
      upgrade Flutter to pick these up: flutter upgrade

  11 healthy  .  7 stale  .  3 skipped (sdk, git or path)

ANDROID BUILD

  FAIL       Gradle 8.4 is too old for AGP 8.9
             AGP 8.9 requires Gradle 8.11.1 or newer. This combination does not build.
             fix: ./gradlew wrapper --gradle-version=8.11.1   (run inside android/)

  PASS       JDK 17 satisfies AGP 8.9

1 blocking, 1 at risk, 1 build failure
```

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
  never reported as a missing package.
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

## In CI

`upkeep` exits non-zero when it finds something blocking, so it works as a CI
check with no extra configuration.

```yaml
- run: dart pub global activate upkeep
- run: upkeep scan
```

| Code | Meaning |
|---|---|
| `0` | Clean |
| `1` | Blocking findings: a discontinued, incompatible or dead dependency, or an Android matrix that does not build |
| `2` | The scan could not run |

Add `--fail-on-at-risk` to treat warnings as failures too.

## Options

```
-p, --path             Project directory to scan (default: .)
    --no-cache         Ignore cached pub.dev responses and refetch
    --fail-on-at-risk  Also exit non-zero for AT RISK dependencies
    --no-color         Disable coloured output
    --version          Show the upkeep version
-h, --help             Show usage
```

Responses are cached for 24 hours under `~/.upkeep/cache`, so repeat scans do no
network work.

## Status

Version 0.1.0. It diagnoses; it does not yet edit your files. Automatic fixes
land once the diagnosis has earned the right to be trusted.

Built by [Abraham Addisu](https://abroid.dev). MIT licensed.
