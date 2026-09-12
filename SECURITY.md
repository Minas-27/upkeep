# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub:
**[Report a vulnerability](https://github.com/Minas-27/upkeep/security/advisories/new)**.

You will get a reply within a few days. Once a fix is released, the advisory is
published with credit to you, unless you would rather stay anonymous.

## Supported versions

Security fixes go into the latest release on
[pub.dev](https://pub.dev/packages/upkeep). Update with:

```console
$ dart pub global activate upkeep
```

## What upkeep does with your project

- `upkeep scan` and `upkeep explain` only read files. The only network calls go
  to the public pub.dev API.
- `upkeep fix --apply` edits `pubspec.yaml` and the Gradle wrapper, and only
  when those files have no uncommitted changes, so git can always undo it.
- The GitHub Action pushes to one branch and opens a pull request, with the
  token you give it. It never pushes to your default branch.
- No telemetry, no accounts, no data sent anywhere else.
