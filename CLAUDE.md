# upkeep

A Dart CLI that reports the health of a Flutter or Dart project: which
dependencies are dying, and whether the Android build matrix actually works.

## Commands

```bash
dart analyze          # must be clean
dart test             # 53 tests
dart run bin/upkeep.dart scan --no-color --path <dir>
dart run bin/upkeep.dart fix --no-color --path <dir>   # add --apply to edit
dart run bin/upkeep.dart explain <package> --no-color
# any command takes --format json|markdown
dart pub publish --dry-run   # must be 0 warnings before any release
git tag vX.Y.Z && git push origin vX.Y.Z   # every pub.dev release; docs and the site tell users to pin this tag
tool/build_web.sh     # rebuild site/app/engine.js after any change under lib/
```

## Layout

| Path | Role |
|---|---|
| `bin/upkeep.dart` | argument parsing only |
| `lib/src/cli/runner.dart` | orchestrates `scan` and `fix`, owns the exit codes |
| `lib/src/project/` | reads `pubspec.yaml`, `pubspec.lock`, the Android Gradle files, and where packages are referenced |
| `lib/src/fix/` | `plan.dart` decides what is automatic; `apply.dart` edits, verifies with `pub get`, and rolls back |
| `lib/src/pub/` | pub.dev API client and its 24-hour on-disk cache |
| `lib/src/rules/` | the two engines: dependency health, Android matrix |
| `lib/src/data/agp_matrix.dart` | Google's published AGP requirements, 8.0 to 9.4 |
| `lib/src/rules/replacements.dart` | attaches curated successors, only when the successor is healthy |
| `lib/src/data/replacements.dart` | the curated successor map; every entry cites a primary source |
| `lib/src/report/` | rendering, and nothing else: terminal, JSON (schema v1), Markdown |
| `action.yml`, `action/` | the GitHub Action; `run.sh` holds the logic so it can be tested locally |
| `lib/src/engine.dart` | `analyzeProject`: the one analysis both the CLI and the web app call |
| `lib/src/project/loader.dart` | the only file-system code in `project/`; parsing lives in `dart:io`-free files |
| `web/engine.dart` | the engine compiled to JavaScript for the web app; build with `tool/build_web.sh` |
| `site/index.html` | the landing page |
| `site/app/` | the web app: reads GitHub or a paste, runs `engine.js` in the browser, no backend |

## The rules this codebase holds to

These are not style preferences. Each one exists because an earlier version of
the engine produced a verdict that was wrong, and a tool that judges other
people's dependencies has exactly one asset: trust.

1. **Every verdict prints its reasons.** Never a bare label. A reader must be
   able to disagree and see why.
2. **Missing data is never evidence.** `PackageInfo.hasScoreData` says whether
   pub.dev actually answered. Every rule that reads points or tags must check it
   first; absent tags and zero points look exactly like neglect. A dropped
   response once got a 160/160 package accused of being abandoned.
3. **Popularity never overrides the discontinued flag.** Checked first, and not
   rescuable. `pedantic` is discontinued, scores 160/160, and is downloaded
   hundreds of thousands of times a month.
4. **The resolver gets the last word.** Dart 3's pub reads `<3.0.0` as `<4.0.0`
   for packages with a lower bound of 2.12 or later; `resolvesUnderDart3Allowance`
   applies that rule directly, and pub.dev's `is:dart3-compatible` tag also
   counts. Never rely on the tag alone: it vanishes when pub.dev's analysis
   fails, and `lucide_icons` was once called INCOMPATIBLE while resolving in real
   Dart 3.11 projects. Lockfiles from real projects are the test.
5. **Stable is not abandoned.** A small, finished, widely used package that has
   not needed a release in two years is done, not dying. See the `loadBearing`
   rescue in `dependency_health.dart`.
6. **An out-of-date local Flutter is not the project's fault.** `SDK BLOCKED` is
   grouped into one line and never fails a build.
7. **No guessing.** Where Google does not publish a number, say it cannot be
   checked. Inferred values soften a verdict, never harden it — see
   `maxApiInferred`.
8. **An automatic fix must be impossible to get wrong.** A wrong to-do costs a
   minute; a wrong edit breaks someone's project. `ReferenceIndex` counts any
   mention as use. Dev dependencies and Flutter plugins are never removed, since
   both work without imports (`build_runner`, `isar_flutter_libs`). An unknown
   plugin status counts as a plugin. `--apply` refuses uncommitted files and
   restores everything if `pub get` fails.
9. **A failed pub.dev analysis is missing data.** `has:error` leaves low points
   and no compatibility tags; `PackageInfo.hasAnalysis` gates every rule that
   reads them. `phosphor_flutter` allows Dart 3 and was once called DEAD on this.
10. **A curated successor needs a citation and a healthy successor.** No entry in
    `data/replacements.dart` without a primary source. `CuratedReplacements`
    withholds a successor that is itself unhealthy or could not be looked up.

## Exit codes

These are a public contract; CI depends on them.

| Code | Meaning |
|---|---|
| 0 | clean |
| 1 | blocking: discontinued, incompatible or dead dependency, or an Android matrix that does not build |
| 2 | the scan could not run, or `fix --apply` refused or rolled back |

The JSON output (`--format json`, `schemaVersion: 1`) is a contract too. Only
add fields; removing or renaming one bumps `jsonSchemaVersion`.

`Verdict.isBlocking` is deliberately narrow. Widening it trains people to ignore
the exit code.

## Data sources

All public, no auth.

- `pub.dev/api/packages/<name>` — versions, publish dates, pubspec, and the
  `isDiscontinued` / `replacedBy` fields
- `pub.dev/api/packages/<name>/score` — granted points, downloads, tags
- `developer.android.com/build/releases/agp-<v>-release-notes` — the AGP matrix,
  transcribed into `agp_matrix.dart` and dated there

## Releasing

1. Bump `pubspec.yaml` **and** `upkeepVersion` in `lib/src/version.dart`.
   They must match.
2. Add a CHANGELOG entry.
3. `dart analyze && dart test && dart pub publish --dry-run` — clean, 53 passing,
   0 warnings.
4. Commit, then `dart pub publish`, then push.

Nothing under `lib/src/` except `cli/`, `fix/apply.dart`, `project/loader.dart`,
`pub/cache.dart` and the terminal reports may import `dart:io`, or the web build
breaks. `tool/build_web.sh` is the check.

`.pubignore` keeps `site/`, `web/`, `tool/`, the Action, the planning files and the handoff out of
the published archive. Check it still does after adding any top-level file.
