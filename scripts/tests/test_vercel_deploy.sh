#!/usr/bin/env bash
# Self-test do vercel-deploy: o que ele publica, o que ele recusa e o que ele
# REPROVA. O `curl` é trocado por um falso no PATH — nenhuma chamada sai daqui.
#
# Os casos que dão nome ao arquivo são os canários [9] e [10]: se a Vercel
# construir OUTRO commit, ou se o domínio não passar a apontar para o deploy,
# o passo tem de ficar vermelho. Sem eles, "subiu" seria a palavra do script.
set -uo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$RAIZ/actions/vercel-deploy/vercel-deploy.sh"
FAILURES=0
_ok()   { echo "  ✓ $1"; }
_bad()  { echo "  ✗ $1"; FAILURES=$((FAILURES+1)); }

BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT

cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
metodo="GET"; url=""; saida=""; corpo=""; cabecalhos=""; prox=""
for arg in "$@"; do
  case "$prox" in
    X) metodo="$arg"; prox=""; continue ;;
    o) saida="$arg";  prox=""; continue ;;
    d) corpo="$arg";  prox=""; continue ;;
    H) cabecalhos="$cabecalhos|$arg"; prox=""; continue ;;
    w) prox=""; continue ;;
  esac
  case "$arg" in
    -X) prox=X ;; -o) prox=o ;; -d) prox=d ;; -H) prox=H ;; -w) prox=w ;;
    -sS|-s|-S) ;;
    http*) url="$arg" ;;
  esac
done
{ echo "CHAMADA metodo=$metodo url=$url"; echo "  headers=$cabecalhos"; echo "  body=$corpo"; } >> "$FAKE_LOG"
code=200; resposta='{}'
case "$metodo $url" in
  "POST "*/v13/deployments\?*)
    code="${FAKE_CODE_CREATE:-200}"
    if [ "$code" = "200" ]; then resposta='{"id":"dpl_TESTE","url":"teste.vercel.app"}'; else resposta='{"error":{"code":"bad_request","message":"motivo da vercel"}}'; fi ;;
  "GET "*/v13/deployments/dpl_TESTE*)
    resposta='{"id":"dpl_TESTE","readyState":"'"${FAKE_STATE:-READY}"'","errorMessage":"falha simulada","gitSource":{"type":"github","sha":"'"${FAKE_BUILT_SHA:-$VD_SHA}"'"}}' ;;
  "POST "*/v2/deployments/dpl_TESTE/aliases*)
    code="${FAKE_CODE_ALIAS:-200}"; resposta='{"alias":"x"}' ;;
  "GET "*/v4/aliases/*)
    resposta='{"deploymentId":"'"${FAKE_ALIAS_DEPLOY:-dpl_TESTE}"'"}' ;;
esac
[ -n "$saida" ] && printf '%s' "$resposta" > "$saida"
printf '%s' "$code"
exit 0
FAKE
chmod +x "$BIN/curl"

SHA=0123456789abcdef0123456789abcdef01234567
_rodar() { # [env extra...]
  FAKE_LOG="$BIN/log"; : > "$FAKE_LOG"; : > "$BIN/out"
  # -u: na CI o runner exporta GITHUB_RUN_ID/REPOSITORY e eles vazariam para o meta do caso.
  env -u GITHUB_RUN_ID -u GITHUB_REPOSITORY PATH="$BIN:$PATH" FAKE_LOG="$FAKE_LOG" GITHUB_OUTPUT="$BIN/out" GITHUB_STEP_SUMMARY="" \
    VERCEL_API_BASE="https://vercel.test" VD_INTERVALO_S=0 "$@" \
    bash "$SCRIPT" > "$BIN/saida" 2>&1
  echo $?
}
_chamadas() { local n; n=$(grep -c '^CHAMADA' "$BIN/log" 2>/dev/null); echo "${n:-0}"; }
_corpo_criacao() { grep -A2 'metodo=POST url=https://vercel.test/v13/deployments' "$BIN/log" | sed -n 's/^  body=//p' | head -1; }

BASE=(VERCEL_TOKEN=tok-secreto VERCEL_TEAM_ID=team_X VERCEL_PROJECT_ID=prj_X VERCEL_PROJECT_NAME=dashboard
      VD_REPO_ID=1130798516 VD_REF=main VD_SHA="$SHA")

echo "[1] produção: publica o commit exato e prova pelo domínio"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=dashboard.play2sell.com)
[ "$rc" = "0" ] && _ok "rc 0" || { _bad "rc $rc"; cat "$BIN/saida"; }
c=$(_corpo_criacao)
echo "$c" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["target"]=="production";assert "customEnvironmentSlugOrId" not in d;g=d["gitSource"];assert g=={"type":"github","repoId":1130798516,"ref":"main","sha":"'"$SHA"'"},g' \
  && _ok "corpo: target production + gitSource com sha" || _bad "corpo errado: $c"
grep -q 'url=https://vercel.test/v13/deployments?forceNew=1&skipAutoDetectionConfirmation=1&teamId=team_X' "$BIN/log" && _ok "teamId na query" || _bad "teamId fora da query"
grep -q 'tok-secreto' <(grep '^CHAMADA' "$BIN/log") && _bad "TOKEN NA URL" || _ok "token fora da URL"
n=$(grep -c '^CHAMADA' "$BIN/log"); h=$(grep -c '^  headers=.*Authorization: Bearer tok-secreto' "$BIN/log")
[ "$n" -gt 0 ] && [ "$n" = "$h" ] && _ok "token no cabeçalho de TODAS as $n chamadas" || _bad "token no cabeçalho de $h de $n chamadas"
grep -q 'url=https://vercel.test/v4/aliases/dashboard.play2sell.com' "$BIN/log" && _ok "conferiu o domínio pela API" || _bad "não conferiu o domínio"
grep -q '^deployment_id=dpl_TESTE$' "$BIN/out" && _ok "saída deployment_id" || _bad "sem saída deployment_id"
# A Vercel recusa meta com valor vazio (400 real em 14/11/2026). Fora do Actions
# não há GITHUB_RUN_ID: a chave não pode ir vazia.
echo "$c" | python3 -c 'import json,sys;m=json.load(sys.stdin)["meta"];assert all(v for v in m.values()),m;assert "githubRunId" not in m' \
  && _ok "meta sem valor vazio" || _bad "meta com valor vazio: $c"
c2=$( FAKE_LOG="$BIN/log2"; : > "$FAKE_LOG"; env -u GITHUB_REPOSITORY PATH="$BIN:$PATH" FAKE_LOG="$FAKE_LOG" GITHUB_OUTPUT="$BIN/out" GITHUB_RUN_ID=42 \
  VERCEL_API_BASE="https://vercel.test" VD_INTERVALO_S=0 "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x bash "$SCRIPT" >/dev/null 2>&1;
  grep -A2 'metodo=POST url=https://vercel.test/v13/deployments' "$FAKE_LOG" | sed -n 's/^  body=//p' | head -1 )
echo "$c2" | python3 -c 'import json,sys;assert json.load(sys.stdin)["meta"]["githubRunId"]=="42"' && _ok "meta leva o run quando existe" || _bad "run fora do meta: $c2"

echo "[2] staging em ambiente personalizado: sem target, com customEnvironmentSlugOrId"
rc=$(_rodar "${BASE[@]}" VD_ALVO=staging VD_CUSTOM_ENV=staging VD_DOMINIO=dashboard-staging.play2sell.com)
[ "$rc" = "0" ] && _ok "rc 0" || { _bad "rc $rc"; cat "$BIN/saida"; }
c=$(_corpo_criacao)
echo "$c" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert "target" not in d;assert d["customEnvironmentSlugOrId"]=="staging"' \
  && _ok "corpo: customEnvironmentSlugOrId=staging, sem target" || _bad "corpo errado: $c"
grep -q '/aliases' <(grep 'metodo=POST' "$BIN/log") && _bad "atribuiu alias sem pedir" || _ok "não atribuiu alias"

echo "[3] staging por alias (projeto sem ambiente personalizado)"
rc=$(_rodar "${BASE[@]}" VD_ALVO=staging VD_ALIAS=website-staging.play2sell.com VD_DOMINIO=website-staging.play2sell.com)
[ "$rc" = "0" ] && _ok "rc 0" || { _bad "rc $rc"; cat "$BIN/saida"; }
grep -A2 'metodo=POST url=https://vercel.test/v2/deployments/dpl_TESTE/aliases' "$BIN/log" | grep -q '"alias": "website-staging.play2sell.com"' \
  && _ok "alias atribuído ao deploy" || _bad "alias não atribuído"
c=$(_corpo_criacao)
echo "$c" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert "target" not in d and "customEnvironmentSlugOrId" not in d' \
  && _ok "deploy de preview (sem target)" || _bad "corpo errado: $c"

echo "[4] sem token: reprova e não chama nada"
rc=$(_rodar VERCEL_TEAM_ID=team_X VERCEL_PROJECT_ID=prj_X VERCEL_PROJECT_NAME=d VD_REPO_ID=1 VD_REF=main VD_SHA="$SHA" VD_ALVO=production VD_DOMINIO=x)
[ "$rc" = "2" ] && _ok "rc 2" || _bad "rc $rc"
[ "$(_chamadas)" = "0" ] && _ok "0 chamadas" || _bad "$(_chamadas) chamadas"
grep -q 'nenhum deploy foi feito' "$BIN/saida" && _ok "diz que nada subiu" || _bad "mensagem muda"

echo "[5] SHA curto: reprova (deixaria a Vercel escolher o commit)"
rc=$(_rodar "${BASE[@]}" VD_SHA=0123456 VD_ALVO=production VD_DOMINIO=x)
[ "$rc" = "2" ] && [ "$(_chamadas)" = "0" ] && _ok "rc 2, 0 chamadas" || _bad "rc $rc, $(_chamadas) chamadas"

echo "[6] staging sem ambiente nem alias: reprova"
rc=$(_rodar "${BASE[@]}" VD_ALVO=staging VD_DOMINIO=x)
[ "$rc" = "2" ] && [ "$(_chamadas)" = "0" ] && _ok "rc 2, 0 chamadas" || _bad "rc $rc"

echo "[7] Vercel recusa a criação: reprova e mostra o motivo"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_CODE_CREATE=400)
[ "$rc" = "1" ] && _ok "rc 1" || _bad "rc $rc"
grep -q 'motivo da vercel' "$BIN/saida" && _ok "corpo da resposta na tela" || _bad "motivo sumiu"

echo "[8] deploy termina ERROR: reprova"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_STATE=ERROR)
[ "$rc" = "1" ] && _ok "rc 1" || _bad "rc $rc"
grep -q 'terminou ERROR' "$BIN/saida" && _ok "diz o estado" || _bad "não diz o estado"

echo "[9] canário: a Vercel construiu OUTRO commit → reprova"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_BUILT_SHA=ffffffffffffffffffffffffffffffffffffffff)
[ "$rc" = "1" ] && _ok "rc 1" || _bad "rc $rc"
grep -q 'não é o nosso' "$BIN/saida" && _ok "nomeia o commit errado" || _bad "mensagem muda"

echo "[10] canário: domínio aponta para outro deploy → reprova"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=dashboard.play2sell.com FAKE_ALIAS_DEPLOY=dpl_OUTRO)
[ "$rc" = "1" ] && _ok "rc 1" || _bad "rc $rc"
grep -q 'NÃO está servindo' "$BIN/saida" && _ok "diz que o ambiente não serve o commit" || _bad "mensagem muda"
n=$(grep -c 'url=https://vercel.test/v4/aliases/' "$BIN/log"); [ "$n" = "6" ] && _ok "6 leituras antes de reprovar" || _bad "$n leituras"

echo "[11] tempo esgotado em BUILDING: reprova"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_STATE=BUILDING VD_TIMEOUT_S=0)
[ "$rc" = "1" ] && _ok "rc 1" || _bad "rc $rc"
grep -q 'não ficou pronto' "$BIN/saida" && _ok "diz que esgotou" || _bad "mensagem muda"

echo "[12] produção com ambiente personalizado: configuração inválida"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_CUSTOM_ENV=staging VD_DOMINIO=x)
[ "$rc" = "2" ] && [ "$(_chamadas)" = "0" ] && _ok "rc 2, 0 chamadas" || _bad "rc $rc"

echo "[13] alvo desconhecido: configuração inválida"
rc=$(_rodar "${BASE[@]}" VD_ALVO=prod VD_DOMINIO=x)
[ "$rc" = "2" ] && _ok "rc 2" || _bad "rc $rc"

echo "[14] alias recusado: reprova"
rc=$(_rodar "${BASE[@]}" VD_ALVO=staging VD_ALIAS=w.example VD_DOMINIO=w.example FAKE_CODE_ALIAS=403)
[ "$rc" = "1" ] && _ok "rc 1" || _bad "rc $rc"

echo ""
[ "$FAILURES" = "0" ] && { echo "vercel-deploy: todos os casos ok"; exit 0; } || { echo "vercel-deploy: $FAILURES falha(s)"; exit 1; }
