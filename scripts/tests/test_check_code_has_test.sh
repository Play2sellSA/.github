#!/usr/bin/env bash
# Self-test do guard canônico: repo-fixture git com origin/dev simulada.
# Matriz: sem código→0 · código sem teste→1 (msg ensina label) · código+teste→0 ·
# low-risk ≤2→0 · low-risk + código real→1 · TEST_EXEMPT→0 · sem BASE_REF→2 ·
# base irresolvível→2 (fail-closed).
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/actions/check-code-has-test/check.sh"
FAILURES=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q -b feature
git -C "$TMP" config user.email t@t && git -C "$TMP" config user.name t
mkdir -p "$TMP/src"
echo "x" > "$TMP/src/mod.ts"; echo "t" > "$TMP/src/mod.test.ts"
git -C "$TMP" add -A && git -C "$TMP" commit -qm base
git -C "$TMP" update-ref refs/remotes/origin/dev HEAD

ENV_COMMON=(BASE_REF=dev CODE_REGEX='^src/.*\.ts$' CODE_EXCLUDE_REGEX='\.d\.ts$' TEST_REGEX='\.test\.ts$' LOW_RISK_REGEX='(^|/)(types|constants|index)\.ts$' LOW_RISK_MAX=2)

_case() { local name="$1" want="$2"; shift 2
  local out rc
  out=$(cd "$TMP" && env "${ENV_COMMON[@]}" "$@" bash "$SCRIPT" 2>&1); rc=$?
  if [[ $rc -ne $want ]]; then echo "  ✗ $name: exit=$rc (want $want)"; echo "$out" | head -4 | sed 's/^/      /'; FAILURES=$((FAILURES+1)); else echo "  ✓ $name"; fi
}
_reset() { git -C "$TMP" checkout -q feature; git -C "$TMP" reset -q --hard refs/remotes/origin/dev; }

_reset; echo d >> "$TMP/README.md"; git -C "$TMP" add -A; git -C "$TMP" commit -qm docs
_case "sem código → 0" 0
_reset; echo n > "$TMP/src/novo.ts"; git -C "$TMP" add -A; git -C "$TMP" commit -qm code
out=$(cd "$TMP" && env "${ENV_COMMON[@]}" bash "$SCRIPT" 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *test-exempt-approved* ]]; then echo "  ✓ código sem teste → 1 + msg do label"; else echo "  ✗ código sem teste: exit=$rc"; FAILURES=$((FAILURES+1)); fi
_reset; echo n > "$TMP/src/novo.ts"; echo t > "$TMP/src/novo.test.ts"; git -C "$TMP" add -A; git -C "$TMP" commit -qm both
_case "código + teste → 0" 0
_reset; echo c > "$TMP/src/constants.ts"; git -C "$TMP" add -A; git -C "$TMP" commit -qm lowrisk
_case "low-risk ≤2 → 0" 0
_reset; echo c > "$TMP/src/constants.ts"; echo n > "$TMP/src/real.ts"; git -C "$TMP" add -A; git -C "$TMP" commit -qm mix
_case "low-risk + código real → 1" 1
_reset; echo n > "$TMP/src/novo2.ts"; git -C "$TMP" add -A; git -C "$TMP" commit -qm ex
_case "TEST_EXEMPT=true → 0" 0 TEST_EXEMPT=true
out=$(cd "$TMP" && env CODE_REGEX=x TEST_REGEX=y bash "$SCRIPT" 2>&1); rc=$?
[[ $rc -eq 2 ]] && echo "  ✓ sem BASE_REF → 2" || { echo "  ✗ sem BASE_REF: exit=$rc"; FAILURES=$((FAILURES+1)); }
out=$(cd "$TMP" && env "${ENV_COMMON[@]}" BASE_REF=nao-existe bash "$SCRIPT" 2>&1); rc=$?
[[ $rc -eq 2 ]] && echo "  ✓ base irresolvível → 2 (fail-closed)" || { echo "  ✗ base irresolvível: exit=$rc"; FAILURES=$((FAILURES+1)); }
exit $FAILURES
