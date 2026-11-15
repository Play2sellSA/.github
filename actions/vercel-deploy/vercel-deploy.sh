#!/usr/bin/env bash
# =============================================================================
# vercel-deploy (canônico, v1) — publica na Vercel o COMMIT EXATO do run,
# espera ficar pronto e prova que o domínio do ambiente passou a servi-lo.
#
# ── O buraco que isto fecha ─────────────────────────────────────────────────
#
# Até aqui os front-ends (Dashboard, Frontend, Website, Console) subiam por
# deploy hook. O hook constrói a PONTA da branch configurada na Vercel, não o
# commit do run — e só sabe construir a branch dele. Com o tronco único
# (plano "só STAGING e PROD", etapa f5-02) o MESMO commit da main tem de ir
# primeiro ao STAGING e depois à PRODUÇÃO; hook de staging amarrado à branch
# `staging` não faz isso. Medido em 14/11/2026: a API com
# `gitSource.sha` + `customEnvironmentSlugOrId=staging` publica um commit de
# OUTRA branch no ambiente staging, e o domínio do ambiente passa para ele
# sozinho (Console, dpl_FHzjht5JeTFBYH7NvB93RFCuiC6M).
#
# ── O que ele prova antes de dizer "subiu" ──────────────────────────────────
#
#   1. a Vercel aceitou o deploy (id devolvido);
#   2. o deploy terminou READY (ERROR/CANCELED/tempo esgotado reprovam);
#   3. o commit que a Vercel construiu é o SHA pedido (canário do instrumento:
#      se a leitura trouxer outro commit, reprova);
#   4. o domínio do ambiente aponta para ESTE deploy — lido na API da Vercel,
#      nunca por polling na URL pública (o Security Checkpoint da Vercel
#      bloqueia laço contra o domínio e cega a verificação).
#
# Sem token NÃO pula: um push que não virou deploy não pode ficar verde.
#
# Env: VERCEL_TOKEN · VERCEL_TEAM_ID · VERCEL_PROJECT_ID · VERCEL_PROJECT_NAME
#      VD_REPO_ID · VD_REF · VD_SHA · VD_ALVO (production|staging|preview)
#      VD_CUSTOM_ENV · VD_ALIAS · VD_DOMINIO · VD_TIMEOUT_S · VD_INTERVALO_S
#      VERCEL_API_BASE · GITHUB_OUTPUT (opcional)
# Saídas: 0 publicado e conferido · 1 falhou · 2 configuração inválida
# =============================================================================
set -uo pipefail

TOKEN="${VERCEL_TOKEN:-}"
TEAM="${VERCEL_TEAM_ID:-}"
PROJETO="${VERCEL_PROJECT_ID:-}"
NOME="${VERCEL_PROJECT_NAME:-}"
REPO_ID="${VD_REPO_ID:-}"
REF="${VD_REF:-}"
SHA="${VD_SHA:-}"
ALVO="${VD_ALVO:-}"
CUSTOM_ENV="${VD_CUSTOM_ENV:-}"
ALIAS="${VD_ALIAS:-}"
DOMINIO="${VD_DOMINIO:-}"
TIMEOUT_S="${VD_TIMEOUT_S:-1500}"
INTERVALO_S="${VD_INTERVALO_S:-15}"
API="${VERCEL_API_BASE:-https://api.vercel.com}"

faltando=""
[ -n "$TOKEN" ]   || faltando="$faltando token(VERCEL_TOKEN)"
[ -n "$TEAM" ]    || faltando="$faltando team_id"
[ -n "$PROJETO" ] || faltando="$faltando project_id"
[ -n "$NOME" ]    || faltando="$faltando project_name"
[ -n "$REPO_ID" ] || faltando="$faltando repo_id"
[ -n "$REF" ]     || faltando="$faltando ref"
[ -n "$SHA" ]     || faltando="$faltando sha"
[ -n "$DOMINIO" ] || faltando="$faltando dominio"
if [ -n "$faltando" ]; then
  echo "::error::vercel-deploy: nenhum deploy foi feito — falta:$faltando"
  exit 2
fi
case "$SHA" in
  *[!0-9a-f]*|"") echo "::error::vercel-deploy: sha '$SHA' não é um SHA completo em minúsculas"; exit 2 ;;
esac
if [ "${#SHA}" != "40" ]; then
  echo "::error::vercel-deploy: sha precisa dos 40 caracteres (veio ${#SHA}) — SHA curto deixa a Vercel escolher o commit"
  exit 2
fi
case "$ALVO" in
  production)
    [ -z "$CUSTOM_ENV" ] || { echo "::error::vercel-deploy: alvo production não aceita custom_environment"; exit 2; } ;;
  staging)
    if [ -z "$CUSTOM_ENV" ] && [ -z "$ALIAS" ]; then
      echo "::error::vercel-deploy: alvo staging precisa de custom_environment (projeto com ambiente staging) ou de alias (domínio de staging a atribuir)"
      exit 2
    fi ;;
  preview) ;;
  *) echo "::error::vercel-deploy: alvo '$ALVO' inválido (production|staging|preview)"; exit 2 ;;
esac
case "$TIMEOUT_S$INTERVALO_S" in *[!0-9]*) echo "::error::vercel-deploy: timeout/intervalo precisam ser inteiros"; exit 2 ;; esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORPO="$TMP/corpo"

# Token no cabeçalho, nunca na URL (o runner ecoa a URL no log). Sem --fail:
# o motivo do erro vem no CORPO, e é ele que vai para a tela.
#
# Rede instável (15/11/2026, run 43721560273 do Frontend): o deploy foi CRIADO,
# mas a 1ª leitura do estado esperou 134 s e caiu com curl (28) — o passo
# reprovou e a produção não saiu, por um soluço de rede. Agora:
#   - toda chamada tem teto de conexão e de duração (um travamento não come o
#     prazo inteiro);
#   - LEITURA=1 (GET, que pode repetir sem efeito): falha de rede vira o código
#     "000" e quem chamou tenta de novo dentro do prazo que já tinha;
#   - a CRIAÇÃO (POST) continua reprovando na hora: repetir criaria outro deploy.
CURL_LIMITES=(--connect-timeout "${VD_CONNECT_TIMEOUT_S:-20}" --max-time "${VD_MAX_TIME_S:-120}")
chamar() { # método caminho [json]
  local metodo="$1" caminho="$2" json="${3:-}" code rc sep="?"
  case "$caminho" in *\?*) sep="&" ;; esac
  local url="$API$caminho${sep}teamId=$TEAM"
  if [ -n "$json" ]; then
    code=$(curl -sS "${CURL_LIMITES[@]}" -X "$metodo" "$url" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$json" -o "$CORPO" -w '%{http_code}')
  else
    code=$(curl -sS "${CURL_LIMITES[@]}" -X "$metodo" "$url" \
      -H "Authorization: Bearer $TOKEN" \
      -o "$CORPO" -w '%{http_code}')
  fi
  rc=$?
  if [ "$rc" != "0" ]; then
    if [ -n "${LEITURA:-}" ] && [ "$metodo" = "GET" ]; then
      echo "::warning::vercel-deploy: curl falhou ($rc) em $metodo $caminho — é leitura, vou tentar de novo" >&2
      : > "$CORPO"; printf '000'; return 0
    fi
    echo "::error::vercel-deploy: curl falhou ($rc) em $metodo $caminho" >&2
    return 1
  fi
  printf '%s' "$code"
}
ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }
mostrar_erro() { # contexto code
  echo "::error::vercel-deploy: $1 — HTTP $2. Resposta da Vercel:"
  sed 's/^/    /' "$CORPO" | head -20
}
campo() { # expressão python sobre `d` (json do CORPO)
  python3 -c "import json,sys
d=json.load(open(sys.argv[1]))
v=$1
print('' if v is None else v)" "$CORPO" 2>/dev/null || true
}

# ── 1. Criar o deploy do commit exato ───────────────────────────────────────
json_deploy() {
  NOME="$NOME" PROJETO="$PROJETO" REPO_ID="$REPO_ID" REF="$REF" SHA="$SHA" \
  ALVO="$ALVO" CUSTOM_ENV="$CUSTOM_ENV" GH_RUN="${GITHUB_RUN_ID:-}" GH_REPO="${GITHUB_REPOSITORY:-}" \
  python3 - <<'PY'
import json, os
e = os.environ
corpo = {
    "name": e["NOME"],
    "project": e["PROJETO"],
    "gitSource": {"type": "github", "repoId": int(e["REPO_ID"]), "ref": e["REF"], "sha": e["SHA"]},
}
# A Vercel recusa `meta` com valor vazio (HTTP 400, medido em 14/11/2026):
# só entra o que existe.
meta = {"origem": "vercel-deploy", "githubRunId": e.get("GH_RUN", ""), "githubRepo": e.get("GH_REPO", "")}
corpo["meta"] = {k: v for k, v in meta.items() if v}
if e["ALVO"] == "production":
    corpo["target"] = "production"
elif e.get("CUSTOM_ENV"):
    corpo["customEnvironmentSlugOrId"] = e["CUSTOM_ENV"]
print(json.dumps(corpo))
PY
}

echo "🚀 Vercel: projeto=$NOME alvo=$ALVO${CUSTOM_ENV:+ (ambiente $CUSTOM_ENV)} commit=$SHA (ref $REF)"
code=$(chamar POST "/v13/deployments?forceNew=1&skipAutoDetectionConfirmation=1" "$(json_deploy)") || exit 1
if ! ok2xx "$code"; then
  mostrar_erro "a Vercel recusou o deploy" "$code"
  exit 1
fi
ID=$(campo 'd.get("id")')
URL=$(campo 'd.get("url")')
if [ -z "$ID" ]; then
  echo "::error::vercel-deploy: a Vercel respondeu $code sem id de deploy"; sed 's/^/    /' "$CORPO" | head -10
  exit 1
fi
echo "   deploy $ID criado (https://$URL)"
[ -n "${GITHUB_OUTPUT:-}" ] && { echo "deployment_id=$ID"; echo "url=https://$URL"; } >> "$GITHUB_OUTPUT"

# ── 2. Esperar READY ────────────────────────────────────────────────────────
# Laço contra a API da Vercel (não contra o domínio público).
inicio=$(date +%s); ESTADO=""
while :; do
  code=$(LEITURA=1 chamar GET "/v13/deployments/$ID") || exit 1
  if ok2xx "$code"; then
    ESTADO=$(campo 'd.get("readyState")')
    case "$ESTADO" in
      READY) break ;;
      ERROR|CANCELED)
        echo "::error::vercel-deploy: deploy $ID terminou $ESTADO: $(campo 'd.get("errorMessage")')"
        echo "::error::   log: https://vercel.com/$TEAM/$NOME/$ID"
        exit 1 ;;
    esac
  else
    echo "::warning::vercel-deploy: leitura do deploy devolveu HTTP $code — tentando de novo"
  fi
  if [ $(( $(date +%s) - inicio )) -ge "$TIMEOUT_S" ]; then
    echo "::error::vercel-deploy: deploy $ID não ficou pronto em ${TIMEOUT_S}s (último estado: ${ESTADO:-desconhecido})"
    exit 1
  fi
  sleep "$INTERVALO_S"
done
echo "✅ deploy $ID READY"

# ── 3. O commit construído é o pedido ───────────────────────────────────────
CONSTRUIDO=$(campo '(d.get("gitSource") or {}).get("sha") or (d.get("meta") or {}).get("githubCommitSha")')
if [ "$CONSTRUIDO" != "$SHA" ]; then
  echo "::error::vercel-deploy: a Vercel construiu o commit '${CONSTRUIDO:-?}', o pedido foi '$SHA' — este deploy não é o nosso"
  exit 1
fi
echo "✅ commit construído = $SHA"

# ── 4. Domínio (alias explícito quando pedido) e a prova ────────────────────
if [ -n "$ALIAS" ]; then
  AJSON=$(ALIAS="$ALIAS" python3 -c 'import json,os;print(json.dumps({"alias":os.environ["ALIAS"]}))')
  code=$(chamar POST "/v2/deployments/$ID/aliases" "$AJSON") || exit 1
  if ! ok2xx "$code"; then
    mostrar_erro "não consegui apontar $ALIAS para o deploy $ID" "$code"
    exit 1
  fi
  echo "   $ALIAS → $ID"
fi

# A Vercel atribui o domínio do ambiente ao ficar READY, mas não no mesmo
# instante: até 6 leituras espaçadas da API antes de reprovar.
APONTA=""
for tentativa in 1 2 3 4 5 6; do
  code=$(LEITURA=1 chamar GET "/v4/aliases/$DOMINIO") || exit 1
  if ok2xx "$code"; then
    APONTA=$(campo 'd.get("deploymentId")')
    [ "$APONTA" = "$ID" ] && break
  fi
  [ "$tentativa" = "6" ] || sleep "$INTERVALO_S"
done
if [ "$APONTA" != "$ID" ]; then
  echo "::error::vercel-deploy: $DOMINIO aponta para '${APONTA:-nada}', não para o deploy $ID — o ambiente NÃO está servindo este commit"
  exit 1
fi
echo "✅ $DOMINIO servindo o deploy $ID (commit ${SHA:0:12})"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "- Vercel \`$NOME\` · $ALVO · \`$DOMINIO\` → \`$ID\` · commit \`${SHA:0:12}\`" >> "$GITHUB_STEP_SUMMARY"
exit 0
