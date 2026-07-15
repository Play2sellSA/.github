#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
for t in "$DIR"/test_*.sh; do
  if bash "$t"; then echo "✅ PASS: $(basename "$t")"; PASS=$((PASS+1)); else echo "❌ FAIL: $(basename "$t")"; FAIL=$((FAIL+1)); fi
done
echo ""; echo "Self-tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
