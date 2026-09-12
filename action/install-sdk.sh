#!/usr/bin/env bash
# Makes dart (and flutter, when the project needs it) available.
#
# Deliberately not a nested `uses:` of setup-dart or flutter-action: inside a
# composite action, GitHub resolves a nested action's own files against the
# wrong directory, and setup-dart fails before upkeep ever runs. An SDK the
# workflow already set up is always preferred.
set -euo pipefail

needs_flutter="${UPKEEP_NEEDS_FLUTTER:-false}"
tools="${RUNNER_TOOL_CACHE:-$HOME/.upkeep-sdk}"

case "${RUNNER_OS:-Linux}" in
  Linux) os=linux ;;
  macOS) os=macos ;;
  *) echo "::error title=upkeep::Install Dart or Flutter before this action on ${RUNNER_OS}; automatic install covers Linux and macOS."; exit 2 ;;
esac
case "${RUNNER_ARCH:-X64}" in
  ARM64) arch=arm64 ;;
  *) arch=x64 ;;
esac

if [[ "$needs_flutter" == "true" ]]; then
  if command -v flutter > /dev/null; then
    echo "Using the Flutter already on PATH: $(command -v flutter)"
  else
    echo "Installing Flutter (stable)"
    git clone --quiet --depth 1 --branch stable https://github.com/flutter/flutter.git "$tools/flutter"
    export PATH="$tools/flutter/bin:$PATH"
    echo "$tools/flutter/bin" >> "$GITHUB_PATH"
    flutter --version --suppress-analytics > /dev/null
  fi
  # Flutter bundles the Dart that should judge a Flutter project.
  dart_bin="$(dirname "$(command -v flutter)")"
  echo "$dart_bin" >> "$GITHUB_PATH"
elif command -v dart > /dev/null; then
  echo "Using the Dart already on PATH: $(command -v dart)"
else
  echo "Installing Dart (stable, $os-$arch)"
  zip="$tools/dartsdk.zip"
  mkdir -p "$tools"
  curl -fsSL -o "$zip" \
    "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-$os-$arch-release.zip"
  unzip -q -o "$zip" -d "$tools"
  echo "$tools/dart-sdk/bin" >> "$GITHUB_PATH"
fi

echo "$HOME/.pub-cache/bin" >> "$GITHUB_PATH"
