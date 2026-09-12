## 0.2.0 (unreleased)

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
- Curated successors for packages that died without being marked discontinued,
  each citing its source, and only suggested when the successor is healthy.
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
