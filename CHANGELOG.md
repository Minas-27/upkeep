## 0.2.3

A successor that nobody had checked.

- A successor named by a publisher is now vetted before it is offered. pub.dev's
  `replacedBy` is set by the publisher and reviewed by nobody, and it can point
  at a package in worse shape than the one being replaced:
  `super_editor_markdown` nominates `super_editor`, which has had no stable
  release since June 2024 — seventeen months longer than the package it
  replaces. The nomination is still shown, because the publisher did make it and
  hiding it would be withholding a fact, but upkeep now runs the successor
  through the same engine and prints what it found. Curated successors were
  already held to this bar; publisher-named ones bypassed it entirely.
- `--format json`: the `replacement` object gains a `warnings` array. Additive,
  so `schemaVersion` stays 1.
- Found by verifying the seven discontinued findings from the 20-app scan one by
  one. All seven were correct; the successor attached to one of them was not.

## 0.2.2

Two wrong verdicts, found by scanning 20 open-source Flutter apps.

- A widely used package that has lost some pub points to age is now STALE, not
  AT RISK. The rescue for load-bearing packages required 144 of 160 points;
  it now requires 128. `collection`, the Dart team's own package with about
  9.8M downloads a month, scores 140 because it has no example and trips lints
  added after its last release, and was called AT RISK in 16 of the 20 apps.
  `stream_channel`, `rxdart`, `scrollable_positioned_list` and `sliver_tools`
  were affected the same way.
- `compileSdk` above what the Android Gradle Plugin was tested with is now a
  warning, not a build failure, and no longer sets exit code 1. AGP reports it
  with `reportWarning` and the build continues. Spotube, Hiddify and Hacki were
  wrongly reported as not building.

## 0.2.1

- README: corrected the survey claims. The link now points to the Flutter Q2
  2026 survey (it pointed to a 2019 post), the 44% figure is described as
  Google describes it, the largest dissatisfaction theme rather than a measure
  of version-matrix guesswork alone, and the 18% figure, which came from 2019,
  is removed.
- README: no longer says nothing warns about dead packages. `pub get` does warn
  about discontinued ones; upkeep's gap is the abandoned packages that were
  never marked.
- Verdict reasons now say "no stable release in N months". The count always
  came from the latest stable version, and a package with a newer prerelease,
  such as `hive`, made "no release" inaccurate.

## 0.2.0

- `upkeep fix`: a plan of automatic changes and a to-do list, with the file and
  line where each affected package is used. Changes nothing by default.
- `upkeep fix --apply` makes the automatic changes: raising a Gradle wrapper
  that is too old for the AGP in use, and removing blocking dependencies that
  nothing refers to. Refuses to run on uncommitted files, and restores every
  file if `pub get` rejects the result.
- Exit code 2 now also covers `fix --apply` refusing to run or rolling back.
- `upkeep explain <package>`: every fact behind a verdict, and where the package
  is used. Works outside a project, as a check before adding a dependency.
- `--format json`: a versioned document (schema 1) for tools. `--format
  markdown`: for GitHub job summaries and pull request descriptions.
- The mechanism for curated successors to packages that died without being
  marked discontinued: each must cite its source, and is only suggested when the
  successor is healthy. Ships with 14 entries verified on 12 September 2026.
- A GitHub Action (`Minas-27/upkeep`): `scan` fails the job on blocking
  findings and writes a job summary; `fix-pr` opens or updates a pull request
  with the automatic fixes and the remaining to-dos.
- Fix: a package whose pub.dev analysis failed (`has:error`) was judged on the
  low points and missing tags that failure leaves behind. `phosphor_flutter`
  was called dead this way. A failed analysis is now treated as missing data.
- Fix: packages capped at `<3.0.0` with a null-safe lower bound were called
  INCOMPATIBLE whenever pub.dev's Dart 3 tag was missing, although Dart 3's pub
  relaxes that ceiling and they resolve. `lucide_icons` failed CI in real
  projects this way. upkeep now applies pub's rule directly and reports these
  packages as AT RISK.

## 0.1.2

- Document the PATH step. `dart pub global activate` puts the executable in
  `~/.pub-cache/bin`, which is not on PATH by default, so the README's own first
  instruction failed for a new user. It now says so, and offers
  `dart pub global run upkeep scan` as the alternative.

## 0.1.1

- Add an example, so the usage a new user needs is where pub.dev expects it.
- Stop shipping the landing page inside the package. It was two thirds of the
  archive and of no use to anyone running the tool.

## 0.1.0

- Initial release.
- `upkeep scan`: dependency health verdicts for direct dependencies, backed by
  the pub.dev API (release recency, pub points, download volume, Dart 3 and WASM
  readiness, SDK constraints).
- Android build matrix validation against Google's published AGP requirements
  for AGP 8.0 through 9.4 (Gradle, JDK, SDK Build Tools, max API level).
- CI-friendly exit codes.
