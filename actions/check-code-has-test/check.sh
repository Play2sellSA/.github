#!/usr/bin/env bash
# =============================================================================
# check-code-has-test (canônico da frota SalesOS*, v1) — fail-closed.
# PR que adiciona/altera CÓDIGO exige TESTE tocado no MESMO PR.
# União dos endurecimentos do rollout 2026-07-15: fail-closed (Pay),
# threshold low-risk (Dashboard/Frontend), sem SC2001 (Connect/ShellCheck).
#
# Env (via action inputs):
#   BASE_REF            branch base (required)
#   TEST_EXEMPT         "true" → escape auditável (label test-exempt-approved)
#   CODE_REGEX          grep -E: o que é código
#   CODE_EXCLUDE_REGEX  grep -vE: excluído do código (d.ts, mocks...)
#   TEST_REGEX          grep -E: o que é teste
#   LOW_RISK_REGEX      grep -E opcional: basenames cosméticos
#   LOW_RISK_MAX        default 2
#   HINT                mensagem de ensino específica do repo (multiline)
#
# Exit: 0 ok · 1 código sem teste · 2 setup inválido (fail-closed)
# =============================================================================
set -euo pipefail

for req in BASE_REF CODE_REGEX TEST_REGEX; do
  if [[ -z "${!req:-}" ]]; then echo "❌ fail-closed: $req obrigatório" >&2; exit 2; fi
done
TEST_EXEMPT="${TEST_EXEMPT:-false}"
CODE_EXCLUDE_REGEX="${CODE_EXCLUDE_REGEX:-$^}"
LOW_RISK_REGEX="${LOW_RISK_REGEX:-}"
LOW_RISK_MAX="${LOW_RISK_MAX:-2}"
HINT="${HINT:-Adicione um teste cobrindo a mudança (veja exemplos no repo).}"

if [[ "$TEST_EXEMPT" == "true" ]]; then
  echo "⚠️ test-exempt-approved: gate liberado por label (escape auditável)."
  echo "   Justificativa deve estar no corpo/comentário do PR."
  exit 0
fi

git fetch --quiet origin "$BASE_REF" 2>/dev/null || true
if ! git rev-parse --verify --quiet "origin/${BASE_REF}" >/dev/null; then
  echo "❌ fail-closed: origin/${BASE_REF} irresolvível — não dá pra diffar." >&2
  exit 2
fi

CHANGED=$(git diff --diff-filter=AM --name-only "origin/${BASE_REF}...HEAD" || { echo "❌ fail-closed: git diff falhou" >&2; exit 2; })

CODE=$(printf '%s\n' "$CHANGED" | grep -E "$CODE_REGEX" | grep -vE "$CODE_EXCLUDE_REGEX" | grep -vE "$TEST_REGEX" || true)
TESTS=$(printf '%s\n' "$CHANGED" | grep -E "$TEST_REGEX" || true)

if [[ -z "$CODE" ]]; then
  echo "✅ Nenhum código novo/alterado vs origin/${BASE_REF} — gate não se aplica."
  exit 0
fi

echo "Código novo/alterado neste PR:"
printf '%s\n' "$CODE" | sed 's/^/  /'
echo ""

if [[ -n "$LOW_RISK_REGEX" ]]; then
  N=$(printf '%s\n' "$CODE" | grep -c . || true)
  NOT_LOW=$(printf '%s\n' "$CODE" | grep -vE "$LOW_RISK_REGEX" || true)
  if [[ -z "$NOT_LOW" && "$N" -le "$LOW_RISK_MAX" ]]; then
    echo "⚠️ Só arquivos low-risk (≤${LOW_RISK_MAX}) — passa com aviso."
    exit 0
  fi
fi

if [[ -n "$TESTS" ]]; then
  echo "✅ Teste presente no PR:"
  printf '%s\n' "$TESTS" | sed 's/^/  /'
  exit 0
fi

echo "❌ Código novo SEM teste no mesmo PR."
echo ""
printf '%s\n' "$HINT"
echo ""
echo "Exceção legítima (reassert/no-op, data-fix one-shot, hotfix P0 com débito"
echo "registrado): peça o label 'test-exempt-approved' com justificativa no PR."
echo "O label precisa estar no PR ANTES da CI rodar (re-trigger com commit vazio)."
exit 1
