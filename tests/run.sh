#!/usr/bin/env bash
# Every check in one go: the helper tests, the plain-text QML check, and the
# Metrics.js tests when node is installed.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -I -B -m unittest discover -s tests
python3 -I -B tests/check_plaintext.py

if command -v node >/dev/null 2>&1; then
  node --test tests/test_metrics.mjs
else
  echo "node not found, skipped tests/test_metrics.mjs" >&2
fi
