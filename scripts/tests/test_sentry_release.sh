#!/usr/bin/env bash
# Self-test do sentry-release: o que ele registra, o que ele pula e o que ele
# REPROVA. O `curl` é trocado por um falso no PATH — nenhuma chamada sai daqui.
#
# O caso que dá nome ao arquivo é o [7]: se a leitura de volta trouxer outra
# versão, o script tem de reprovar. Sem ele, a "prova" do passo 3 seria enfeite
# — uma régua que nunca reprova não mede nada.
set -uo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$RAIZ/actions/sentry-release/sentry-release.sh"
FAILURES=0
_ok()   { echo "  ✓ $1"; }
_bad()  { echo "  ✗ $1"; FAILURES=$((FAILURES+1)); }

BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT

# ── curl falso ──────────────────────────────────────────────────────────────
# Registra método, URL, cabeçalhos e corpo em $FAKE_LOG; responde com o código
# que o caso pedir. A 1ª e a 2ª criação de release respondem separado, que é
# como se exercita o repositório não integrado.
cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
metodo=""; url=""; saida=""; corpo=""; cabecalhos=""
prox=""
for arg in "$@"; do
  case "$prox" in
    X) metodo="$arg"; prox="" ; continue ;;
    o) saida="$arg";  prox="" ; continue ;;
    d) corpo="$arg";  prox="" ; continue ;;
    H) cabecalhos="$cabecalhos|$arg"; prox=""; continue ;;
    w) prox="" ; continue ;;
  esac
  case "$arg" in
    -X) prox=X ;; -o) prox=o ;; -d) prox=d ;; -H) prox=H ;; -w) prox=w ;;
    -sS|-s|-S) ;;
    http*) url="$arg" ;;
  esac
done
{ echo "CHAMADA metodo=$metodo url=$url"; echo "  headers=$cabecalhos"; echo "  body=$corpo"; } >> "$FAKE_LOG"

if [ -n "${FAKE_CURL_RC:-}" ] && [ "${FAKE_CURL_RC}" != "0" ]; then
  echo "curl: (${FAKE_CURL_RC}) simulado" >&2
  exit "${FAKE_CURL_RC}"
fi

resposta='{}'; code=200
case "$url" in
  */deploys/)
    code="${FAKE_CODE_DEPLOY:-201}"; resposta='{"id":"1","environment":"x"}' ;;
  */releases/)
    n=$(( $(grep -c 'url=.*/releases/$' "$FAKE_LOG") ))
    if [ "$n" -le 1 ]; then code="${FAKE_CODE_RELEASE1:-201}"; else code="${FAKE_CODE_RELEASE2:-201}"; fi
    resposta='{"version":"'"${FAKE_GET_VERSION:-$SENTRY_VERSION}"'"}' ;;
  *)
    code="${FAKE_CODE_GET:-200}"
    resposta='{"version":"'"${FAKE_GET_VERSION:-$SENTRY_VERSION}"'"}' ;;
esac
[ -n "$saida" ] && printf '%s' "$resposta" > "$saida"
printf '%s' "$code"
exit 0
FAKE
chmod +x "$BIN/curl"

SHA=0123456789abcdef0123456789abcdef01234567

# Roda o script com o curl falso no PATH. Ecoa o rc; o log fica em $FAKE_LOG.
_rodar() { # [env extra...]
  FAKE_LOG="$BIN/log"; : > "$FAKE_LOG"
  env PATH="$BIN:$PATH" FAKE_LOG="$FAKE_LOG" "$@" \
    SENTRY_API_BASE="https://sentry.test/api/0" \
    bash "$SCRIPT" > "$BIN/saida" 2>&1
  echo $?
}
# `grep -c` sem casar IMPRIME 0 e sai 1 — com `|| echo 0` o valor saía "0\n0"
# e a comparação reprovava caso certo. Contador com uma saída só.
_chamadas() { local n; n=$(grep -c '^CHAMADA' "$BIN/log" 2>/dev/null); echo "${n:-0}"; }

BASE=(SENTRY_AUTH_TOKEN=tok SENTRY_ORG=play2sell SENTRY_PROJECTS=salesos-backend
      SENTRY_VERSION="$SHA" SENTRY_ENV=production SENTRY_REPOSITORY=Play2sellSA/SalesOS-Backend)

# [1] sem token: pula em silêncio, sem tocar na rede
rc=$(_rodar SENTRY_AUTH_TOKEN= SENTRY_ORG=play2sell SENTRY_PROJECTS=p SENTRY_VERSION=$SHA SENTRY_ENV=production)
[ "$rc" = "0" ] && [ "$(_chamadas)" = "0" ] && _ok "[1] sem token → pula (exit 0, zero chamadas)" \
  || _bad "[1] sem token: exit=$rc chamadas=$(_chamadas)"

# [2] com token e faltando campo: fail-closed, antes de qualquer chamada
for falta in SENTRY_ORG SENTRY_PROJECTS SENTRY_VERSION SENTRY_ENV; do
  args=(SENTRY_AUTH_TOKEN=tok SENTRY_ORG=play2sell SENTRY_PROJECTS=p SENTRY_VERSION=$SHA SENTRY_ENV=production)
  for i in "${!args[@]}"; do [[ "${args[$i]}" == "$falta="* ]] && args[$i]="$falta="; done
  rc=$(_rodar "${args[@]}")
  [ "$rc" = "2" ] && [ "$(_chamadas)" = "0" ] && _ok "[2] sem $falta → exit 2 sem chamar" \
    || _bad "[2] sem $falta: exit=$rc chamadas=$(_chamadas)"
done

# [3] caminho feliz: release com refs, deploy, e a leitura de volta
rc=$(_rodar "${BASE[@]}")
if [ "$rc" = "0" ] && [ "$(_chamadas)" = "3" ]; then _ok "[3] feliz → exit 0 em 3 chamadas"; else _bad "[3] feliz: exit=$rc chamadas=$(_chamadas)"; fi
grep -q '"refs"' "$BIN/log"            && _ok "[3] a release vai COM commits"        || _bad "[3] release sem refs"
grep -q '"environment": *"production"' "$BIN/log" && _ok "[3] o deploy leva o ambiente" || _bad "[3] deploy sem environment"
grep -q "metodo=GET url=.*/releases/$SHA/" "$BIN/log" && _ok "[3] confere lendo a release de volta" || _bad "[3] não releu a release"

# [4] o token nunca vai na URL (o runner ecoa URL no log; cabeçalho não)
grep -q 'url=.*tok' "$BIN/log" && _bad "[4] token vazou na URL" || _ok "[4] token só no cabeçalho, nunca na URL"
grep -q 'headers=.*Authorization: Bearer tok' "$BIN/log" && _ok "[4] e ele É enviado (canário: o falso viu o cabeçalho)" \
  || _bad "[4] Authorization não chegou ao curl"

# [5] repositório não integrado: a 1ª criação é recusada, a 2ª vai sem refs
rc=$(_rodar "${BASE[@]}" FAKE_CODE_RELEASE1=400)
if [ "$rc" = "0" ] && [ "$(_chamadas)" = "4" ]; then _ok "[5] refs recusado → refaz sem commits e segue"; else _bad "[5] refs recusado: exit=$rc chamadas=$(_chamadas)"; fi
[ "$(grep -c '"refs"' "$BIN/log")" = "1" ] && _ok "[5] a 2ª tentativa vai SEM refs" || _bad "[5] a 2ª tentativa repetiu os refs"
grep -q 'NÃO associados' "$BIN/saida" && _ok "[5] e diz na tela que os commits não foram associados" || _bad "[5] silêncio sobre os commits"

# [6] falha real na criação: reprova com o corpo do Sentry na tela
rc=$(_rodar "${BASE[@]}" FAKE_CODE_RELEASE1=500 FAKE_CODE_RELEASE2=500)
[ "$rc" = "1" ] && _ok "[6] release recusada duas vezes → exit 1" || _bad "[6] release 500: exit=$rc"
grep -q "não consegui criar a release" "$BIN/saida" && _ok "[6] com o motivo na tela" || _bad "[6] falhou mudo"

# [7] deploy recusado
rc=$(_rodar "${BASE[@]}" FAKE_CODE_DEPLOY=403)
[ "$rc" = "1" ] && _ok "[7] deploy recusado → exit 1" || _bad "[7] deploy 403: exit=$rc"

# [8] CANÁRIO DO INSTRUMENTO: a leitura de volta traz outra versão
rc=$(_rodar "${BASE[@]}" FAKE_GET_VERSION=outra-versao)
[ "$rc" = "1" ] && _ok "[8] leu outra versão → reprova (a prova PROVA)" || _bad "[8] aceitou versão alheia: exit=$rc"

# [9] rede fora: curl sai != 0
rc=$(_rodar "${BASE[@]}" FAKE_CURL_RC=7)
[ "$rc" = "1" ] && _ok "[9] curl falhando → exit 1" || _bad "[9] curl rc=7: exit=$rc"

# [10] canário do próprio teste: sem o falso no PATH, o caso feliz NÃO passaria
[ -x "$BIN/curl" ] && _ok "[10] o curl falso existe e é executável" || _bad "[10] o falso não estava no PATH"

echo
[ "$FAILURES" -eq 0 ] && echo "PASS: sentry-release — todos os casos" || echo "FAIL: sentry-release — $FAILURES caso(s)"
exit $((FAILURES > 0))
