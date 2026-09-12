# upkeep

A Dart CLI that reports the health of a Flutter or Dart project: which
dependencies are dying, and whether the Android build matrix actually works.

## Commands

```bash
dart analyze          # must be clean
dart test             # 22 tests
dart run bin/upkeep.dart scan --no-color --path <dir>
dart pub publish --dry-run   # must be 0 warnings before any release
```

## Layout

| Path | Role |
|---|---|
| `bin/upkeep.dart` | argument parsing only |
| `lib/src/cli/runner.dart` | orchestrates a scan, owns the exit codes |
| `lib/src/project/` | reads `pubspec.yaml`, `pubspec.lock`, and the Android Gradle files |
| `lib/src/pub/` | pub.dev API client and its 24-hour on-disk cache |
| `lib/src/rules/` | the two engines: dependency health, Android matrix |
| `lib/src/data/agp_matrix.dart` | Google's published AGP requirements, 8.0 to 9.4 |
| `lib/src/report/terminal.dart` | rendering, and nothing else |
| `site/index.html` | the landing page |

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
4. **The resolver gets the last word.** Where pub.dev's `is:dart3-compatible`
   tag contradicts our reading of a package's SDK ceiling, the tag wins. `isar`
   and `hive` cap below Dart 3 yet resolve, because pub relaxes that bound for
   null-safe packages.
5. **Stable is not abandoned.** A small, finished, widely used package that has
   not needed a release in two years is done, not dying. See the `loadBearing`
   rescue in `dependency_health.dart`.
6. **An out-of-date local Flutter is not the project's fault.** `SDK BLOCKED` is
   grouped into one line and never fails a build.
7. **No guessing.** Where Google does not publish a number, say it cannot be
   checked. Inferred values soften a verdict, never harden it — see
   `maxApiInferred`.

## Exit codes

These are a public contract; CI depends on them.

| Code | Meaning |
|---|---|
| 0 | clean |
| 1 | blocking: discontinued, incompatible or dead dependency, or an Android matrix that does not build |
| 2 | the scan could not run |

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

1. Bump `pubspec.yaml` **and** `upkeepVersion` in `lib/src/cli/runner.dart`.
   They must match.
2. Add a CHANGELOG entry.
3. `dart analyze && dart test && dart pub publish --dry-run` — clean, 22 passing,
   0 warnings.
4. Commit, then `dart pub publish`, then push.

`.pubignore` keeps `site/`, the planning files and the handoff out of the
published archive. Check it still does after adding any top-level file.
