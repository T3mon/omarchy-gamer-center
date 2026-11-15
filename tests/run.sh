#!/usr/bin/env bash
# Every check in one go: the helper tests, the plain-text QML check, and the
# Metrics.js and steam/Library.js tests when node is installed.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -I -B -m unittest discover -s tests
python3 -I -B tests/check_plaintext.py

if command -v node >/dev/null 2>&1; then
  node --test tests/test_metrics.mjs tests/test_steam.mjs
else
  echo "node not found, skipped the JS tests" >&2
fi
