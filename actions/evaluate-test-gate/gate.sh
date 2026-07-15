#!/usr/bin/env bash
# =============================================================================
# evaluate-test-gate (canônico, v1) — avalia os results dos jobs `needs` do
# caller e decide o required check. Semântica:
#   qualquer failure/cancelled → FAIL · skipped: passa só se RELEVANT=false ou
#   SKIP_LABEL=true (com warning auditado) · success → PASS.
# Env: RESULTS (JSON de toJSON(needs)) · RELEVANT (default true) · SKIP_LABEL
# =============================================================================
set -euo pipefail
RESULTS="${RESULTS:?exit-2: RESULTS obrigatório}"
RELEVANT="${RELEVANT:-true}"
SKIP_LABEL="${SKIP_LABEL:-false}"

echo "results=$RESULTS relevant=$RELEVANT skip-label=$SKIP_LABEL"
STATES=$(printf '%s' "$RESULTS" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for k,v in d.items(): print(k+"="+str(v.get("result","?")))
') || { echo "❌ fail-closed: RESULTS não é JSON válido" >&2; exit 2; }
RC=0
while IFS= read -r kv; do
  [ -n "$kv" ] || continue
  job="${kv%%=*}"; res="${kv#*=}"
  case "$res" in
    success) echo "✅ $job: success" ;;
    skipped)
      if [[ "$RELEVANT" != "true" ]]; then echo "✅ $job: skipped (PR não-relevante — trivial)"
      elif [[ "$SKIP_LABEL" == "true" ]]; then echo "::warning::$job pulado via label (escape auditável — justificativa no PR)"
      else echo "::error::$job skipped com PR relevante e sem label"; RC=1; fi ;;
    *) echo "::error::$job: $res"; RC=1 ;;
  esac
done <<EOF_STATES
$STATES
EOF_STATES
exit $RC
