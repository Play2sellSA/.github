#!/usr/bin/env bash
# Self-test do gate: matriz de results × relevant × skip_label.
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/actions/evaluate-test-gate/gate.sh"
FAILURES=0
_case() { local name="$1" want="$2" results="$3" relevant="${4:-true}" skip="${5:-false}"
  local rc; RESULTS="$results" RELEVANT="$relevant" SKIP_LABEL="$skip" bash "$SCRIPT" >/dev/null 2>&1; rc=$?
  if [[ $rc -ne $want ]]; then echo "  ✗ $name: exit=$rc (want $want)"; FAILURES=$((FAILURES+1)); else echo "  ✓ $name"; fi
}
_case "tudo success → 0" 0 '{"build":{"result":"success"},"test":{"result":"success"}}'
_case "um failure → 1" 1 '{"build":{"result":"success"},"test":{"result":"failure"}}'
_case "cancelled → 1" 1 '{"test":{"result":"cancelled"}}'
_case "skipped + não-relevante → 0" 0 '{"test":{"result":"skipped"}}' false
_case "skipped + relevante sem label → 1" 1 '{"test":{"result":"skipped"}}' true false
_case "skipped + label → 0" 0 '{"test":{"result":"skipped"}}' true true
exit $FAILURES
