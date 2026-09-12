#!/usr/bin/env bash
# Decides whether the project needs Flutter or plain Dart.
set -euo pipefail

mode="${UPKEEP_FLUTTER:-auto}"
pubspec="${UPKEEP_PATH:-.}/pubspec.yaml"

if [[ "$mode" == "auto" ]]; then
  if [[ -f "$pubspec" ]] && grep -Eq '^\s+sdk:\s*flutter\s*$' "$pubspec"; then
    mode=true
  else
    mode=false
  fi
fi

echo "flutter=$mode" >> "$GITHUB_OUTPUT"
