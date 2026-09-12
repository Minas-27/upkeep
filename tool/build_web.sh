#!/usr/bin/env bash
# Compiles the upkeep engine to JavaScript for the web app in site/app/.
set -euo pipefail
cd "$(dirname "$0")/.."
dart compile js -O2 --no-source-maps -o site/app/engine.js web/engine.dart
rm -f site/app/engine.js.deps
echo "site/app/engine.js: $(wc -c < site/app/engine.js) bytes"
