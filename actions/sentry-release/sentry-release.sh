#!/usr/bin/env bash
# =============================================================================
# sentry-release (canônico, v1) — registra no Sentry a release que acabou de
# subir, associa os commits dela e cria o deploy do ambiente.
#
# ── O buraco que isto fecha ─────────────────────────────────────────────────
#
# O Sentry sabe QUE um erro aconteceu. Sem release e sem deploy ele não sabe
# DESDE QUANDO nem DE QUAL entrega — e por isso não marca regressão, não sugere
# o commit suspeito e não fecha nada "na próxima versão". Medido em 18/09: os
# três projetos da frota (salesos-backend, salesos-pay, salesos-agents) estavam
# com "Track Deploys" por configurar, e os dois primeiros mandavam todo evento
# SEM release.
#
# ── O que ele NÃO faz ───────────────────────────────────────────────────────
#
# Nada que mude o que já subiu. Este passo roda DEPOIS do deploy e só escreve
# no Sentry. Se ele falhar, o deploy continua de pé — o que fica vermelho é a
# escrituração, com o nome disso na tela.
#
# ── Por que fail-closed e não `|| true` ─────────────────────────────────────
#
# Um `|| true` aqui devolveria exatamente o que estamos consertando: o painel
# vazio indistinguível do painel são. Falha de registro sai com código != 0 e
# com o CORPO da resposta impresso — a API do Sentry explica no corpo (repo não
# integrado, escopo faltando, projeto errado) e o código HTTP sozinho não.
#
# Ausência de token é OUTRA coisa: é o grupo opcional do padrão da frota (igual
# ao sync-edge-secrets do Backend). Sem `auth_token` o passo pula em silêncio e
# sai 0 — assim o ambiente que ainda não tem token não pinta o CI de vermelho.
#
# Env: SENTRY_AUTH_TOKEN · SENTRY_ORG · SENTRY_PROJECTS (csv) · SENTRY_VERSION
#      SENTRY_ENV · SENTRY_REPOSITORY · SENTRY_DEPLOY_URL · SENTRY_API_BASE
# Saídas: 0 registrado (ou pulado) · 1 falhou o registro · 2 configuração inválida
# =============================================================================
set -uo pipefail

TOKEN="${SENTRY_AUTH_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  echo "ℹ️ SENTRY_AUTH_TOKEN ausente — release e deploy não serão registrados no Sentry."
  echo "   (os eventos seguem chegando; o que falta é a escrituração da versão)"
  exit 0
fi

ORG="${SENTRY_ORG:-}"
PROJECTS="${SENTRY_PROJECTS:-}"
VERSION="${SENTRY_VERSION:-}"
ENVIRONMENT="${SENTRY_ENV:-}"
REPOSITORY="${SENTRY_REPOSITORY:-}"
DEPLOY_URL="${SENTRY_DEPLOY_URL:-}"
API="${SENTRY_API_BASE:-https://sentry.io/api/0}"

faltando=""
[ -n "$ORG" ]         || faltando="$faltando org"
[ -n "$PROJECTS" ]    || faltando="$faltando projects"
[ -n "$VERSION" ]     || faltando="$faltando version"
[ -n "$ENVIRONMENT" ] || faltando="$faltando environment"
if [ -n "$faltando" ]; then
  echo "::error::sentry-release: com token e sem$faltando o registro sairia mudo ou no lugar errado"
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORPO="$TMP/corpo"

# Toda chamada passa por aqui: o token vai no cabeçalho (nunca na URL, que o
# runner ecoa no log), e o CORPO é lido antes de o código HTTP ser interpretado.
# `--fail` de propósito NÃO: com ele o corpo do erro some, que é o único lugar
# onde o Sentry diz o motivo.
chamar() { # método url [json]
  local metodo="$1" url="$2" json="${3:-}" code
  if [ -n "$json" ]; then
    code=$(curl -sS -X "$metodo" "$url" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$json" -o "$CORPO" -w '%{http_code}')
  else
    code=$(curl -sS -X "$metodo" "$url" \
      -H "Authorization: Bearer $TOKEN" \
      -o "$CORPO" -w '%{http_code}')
  fi
  local rc=$?
  if [ "$rc" != "0" ]; then
    echo "::error::sentry-release: curl falhou ($rc) em $metodo $url" >&2
    return 1
  fi
  printf '%s' "$code"
}

ok2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }

mostrar_erro() { # contexto code
  echo "::error::sentry-release: $1 — HTTP $2. Resposta do Sentry:"
  sed 's/^/    /' "$CORPO" | head -20
}

json_release() { # com_refs(true|false)
  COM_REFS="$1" ORG="$ORG" VERSION="$VERSION" PROJECTS="$PROJECTS" \
  REPOSITORY="$REPOSITORY" python3 - <<'PY'
import datetime, json, os
corpo = {
    "version": os.environ["VERSION"],
    "projects": [p.strip() for p in os.environ["PROJECTS"].split(",") if p.strip()],
    "dateReleased": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if os.environ["COM_REFS"] == "true" and os.environ.get("REPOSITORY"):
    corpo["refs"] = [{"repository": os.environ["REPOSITORY"], "commit": os.environ["VERSION"]}]
print(json.dumps(corpo))
PY
}

json_deploy() {
  ENVIRONMENT="$ENVIRONMENT" VERSION="$VERSION" DEPLOY_URL="$DEPLOY_URL" PROJECTS="$PROJECTS" python3 - <<'PY'
import json, os
corpo = {
    "environment": os.environ["ENVIRONMENT"],
    "name": os.environ["VERSION"][:12],
    "projects": [p.strip() for p in os.environ["PROJECTS"].split(",") if p.strip()],
}
if os.environ.get("DEPLOY_URL"):
    corpo["url"] = os.environ["DEPLOY_URL"]
print(json.dumps(corpo))
PY
}

echo "🏷️ Sentry: org=$ORG projetos=$PROJECTS versão=$VERSION ambiente=$ENVIRONMENT"

# ── 1. A release, com os commits ────────────────────────────────────────────
# `refs` só resolve se o repositório estiver integrado no Sentry (GitHub app).
# Sem integração a API recusa a chamada INTEIRA — por isso a segunda tentativa
# sem `refs`: perder a associação de commits é aceitável, perder a release não.
COMMITS="associados"
code=$(chamar POST "$API/organizations/$ORG/releases/" "$(json_release true)") || exit 1
if ! ok2xx "$code"; then
  echo "::warning::sentry-release: criar a release COM commits falhou (HTTP $code). Resposta:"
  sed 's/^/    /' "$CORPO" | head -10
  echo "::warning::   tentando sem associar commits — integre $REPOSITORY no Sentry para ter commit suspeito e dono provável"
  COMMITS="NÃO associados (repositório não integrado no Sentry)"
  code=$(chamar POST "$API/organizations/$ORG/releases/" "$(json_release false)") || exit 1
  if ! ok2xx "$code"; then
    mostrar_erro "não consegui criar a release $VERSION" "$code"
    exit 1
  fi
fi
echo "✅ release $VERSION registrada (commits: $COMMITS)"

# ── 2. O deploy do ambiente ─────────────────────────────────────────────────
code=$(chamar POST "$API/organizations/$ORG/releases/$VERSION/deploys/" "$(json_deploy)") || exit 1
if ! ok2xx "$code"; then
  mostrar_erro "não consegui criar o deploy de $ENVIRONMENT" "$code"
  exit 1
fi
echo "✅ deploy em $ENVIRONMENT registrado"

# ── 3. A prova ──────────────────────────────────────────────────────────────
# Sem este passo, "criei" é a palavra do próprio script. O 2xx de cima diz que
# a chamada foi aceita; só a leitura de volta diz que a release EXISTE e é a
# nossa. Conferir a versão que voltou é o canário do instrumento: se a régua
# estiver lendo outra coisa, ela precisa reprovar aqui.
code=$(chamar GET "$API/organizations/$ORG/releases/$VERSION/") || exit 1
if ! ok2xx "$code"; then
  mostrar_erro "a release não está lá depois de criada" "$code"
  exit 1
fi
LIDA=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' < "$CORPO" 2>/dev/null || true)
if [ "$LIDA" != "$VERSION" ]; then
  echo "::error::sentry-release: li de volta a versão '$LIDA', esperava '$VERSION' — o registro não é o nosso"
  exit 1
fi
echo "✅ conferido no Sentry: $LIDA"
