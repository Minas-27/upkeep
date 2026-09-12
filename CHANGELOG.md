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
