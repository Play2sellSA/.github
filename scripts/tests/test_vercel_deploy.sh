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
metodo="GET"; url=""; saida=""; corpo=""; cabecalhos=""; prox=""; limites=""
for arg in "$@"; do
  case "$prox" in
    L) limites="$limites $arg"; prox=""; continue ;;
    X) metodo="$arg"; prox=""; continue ;;
    o) saida="$arg";  prox=""; continue ;;
    d) corpo="$arg";  prox=""; continue ;;
    H) cabecalhos="$cabecalhos|$arg"; prox=""; continue ;;
    w) prox=""; continue ;;
  esac
  case "$arg" in
    -X) prox=X ;; -o) prox=o ;; -d) prox=d ;; -H) prox=H ;; -w) prox=w ;;
    --connect-timeout|--max-time) limites="$limites $arg"; prox=L ;;
    -sS|-s|-S) ;;
    http*) url="$arg" ;;
  esac
done
{ echo "CHAMADA metodo=$metodo url=$url"; echo "  headers=$cabecalhos"; echo "  body=$corpo"; echo "  limites=$limites"; } >> "$FAKE_LOG"
# Sequências "a,b,c": a N-ésima chamada daquele tipo recebe o N-ésimo item (o último se repete).
_seq() { # nome lista
  local f="$FAKE_LOG.n_$1" n; n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"
  local IFS=,; local itens=($2); local i=$(( n <= ${#itens[@]} ? n - 1 : ${#itens[@]} - 1 )); printf '%s' "${itens[$i]}"
}
[ -n "${FAKE_CURL_FALHA:-}" ] && { echo "curl: (6) Could not resolve host" >&2; exit 6; }
# Falha de rede por tipo de chamada, em sequência ("28,0" = 1ª cai com curl 28, 2ª passa).
case "$metodo $url" in
  "POST "*/v13/deployments\?*) rc=$(_seq rc_criacao "${FAKE_RC_CREATE:-0}") ;;
  "GET "*/v13/deployments/*)    rc=$(_seq rc_leitura "${FAKE_RC_GET:-0}") ;;
  "GET "*/v4/aliases/*)         rc=$(_seq rc_dominio "${FAKE_RC_ALIAS:-0}") ;;
  *) rc=0 ;;
esac
[ "$rc" != "0" ] && { echo "curl: ($rc) Failed to connect to api.vercel.com port 443 after 134376 ms" >&2; exit "$rc"; }
code=200; resposta='{}'
case "$metodo $url" in
  "POST "*/v13/deployments\?*)
    code="${FAKE_CODE_CREATE:-200}"
    if [ "$code" = "200" ]; then resposta='{"id":"dpl_TESTE","url":"teste.vercel.app"}'; else resposta='{"error":{"code":"bad_request","message":"motivo da vercel"}}'; fi
    [ -n "${FAKE_SEM_ID:-}" ] && resposta='{"url":"teste.vercel.app"}' ;;
  "GET "*/v13/deployments/dpl_TESTE*)
    code=$(_seq leitura "${FAKE_GET_CODES:-200}")
    estado=$(_seq estado "${FAKE_STATES:-${FAKE_STATE:-READY}}")
    if [ -n "${FAKE_SO_META_SHA:-}" ]; then git='{"type":"github"}'; meta='{"githubCommitSha":"'"$FAKE_SO_META_SHA"'"}'
    else git='{"type":"github","sha":"'"${FAKE_BUILT_SHA:-$VD_SHA}"'"}'; meta='{}'; fi
    [ "$code" = "200" ] && resposta='{"id":"dpl_TESTE","readyState":"'"$estado"'","errorMessage":"falha simulada","gitSource":'"$git"',"meta":'"$meta"'}' \
      || resposta='{"error":{"message":"instável"}}' ;;
  "POST "*/v2/deployments/dpl_TESTE/aliases*)
    code="${FAKE_CODE_ALIAS:-200}"; resposta='{"alias":"x"}' ;;
  "GET "*/v4/aliases/*)
    resposta='{"deploymentId":"'"$(_seq dominio "${FAKE_ALIAS_SEQ:-${FAKE_ALIAS_DEPLOY:-dpl_TESTE}}")"'"}' ;;
esac
[ -n "$saida" ] && printf '%s' "$resposta" > "$saida"
printf '%s' "$code"
exit 0
FAKE
chmod +x "$BIN/curl"

SHA=0123456789abcdef0123456789abcdef01234567
_rodar() { # [env extra...]
  FAKE_LOG="$BIN/log"; : > "$FAKE_LOG"; : > "$BIN/out"; : > "$BIN/resumo"; rm -f "$BIN"/log.n_*
  # -u: na CI o runner exporta GITHUB_RUN_ID/REPOSITORY e eles vazariam para o meta do caso.
  env -u GITHUB_RUN_ID -u GITHUB_REPOSITORY PATH="$BIN:$PATH" FAKE_LOG="$FAKE_LOG" GITHUB_OUTPUT="$BIN/out" GITHUB_STEP_SUMMARY="${RESUMO:-}" \
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

# ── Casos do comportamento real da Vercel (medidos em 14/11/2026) ───────────

echo "[15] fila real: QUEUED → BUILDING → READY publica, e espera pela API"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_STATES=QUEUED,BUILDING,READY)
[ "$rc" = "0" ] && _ok "rc 0" || { _bad "rc $rc"; cat "$BIN/saida"; }
n=$(grep -c 'metodo=GET url=https://vercel.test/v13/deployments/dpl_TESTE' "$BIN/log"); [ "$n" = "3" ] && _ok "3 leituras até READY" || _bad "$n leituras"

echo "[16] leitura instável (HTTP 500) no meio da espera não derruba o deploy"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_GET_CODES=500,502,200 FAKE_STATES=BUILDING,BUILDING,READY)
[ "$rc" = "0" ] && _ok "rc 0" || { _bad "rc $rc"; cat "$BIN/saida"; }
grep -q 'HTTP 500 — tentando de novo' "$BIN/saida" && _ok "avisa a leitura instável" || _bad "aviso sumiu"

echo "[17] CANCELED: reprova"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_STATES=BUILDING,CANCELED VD_TIMEOUT_S=3)
[ "$rc" = "1" ] && grep -q 'terminou CANCELED' "$BIN/saida" && _ok "rc 1 e diz CANCELED" || _bad "rc $rc"
grep -q '/v4/aliases/' "$BIN/log" && _bad "conferiu domínio de deploy cancelado" || _ok "parou antes do domínio"

echo "[18] domínio atrasado: aponta para o deploy velho e só depois para o nosso → publica"
# Real: a Vercel move o domínio do ambiente alguns segundos depois do READY.
rc=$(_rodar "${BASE[@]}" VD_ALVO=staging VD_CUSTOM_ENV=staging VD_DOMINIO=s.example FAKE_ALIAS_SEQ=dpl_VELHO,dpl_VELHO,dpl_TESTE)
[ "$rc" = "0" ] && _ok "rc 0" || { _bad "rc $rc"; cat "$BIN/saida"; }
n=$(grep -c 'url=https://vercel.test/v4/aliases/' "$BIN/log"); [ "$n" = "3" ] && _ok "parou na 3ª leitura (a que confere)" || _bad "$n leituras"

echo "[19] commit só no meta (gitSource sem sha): confere pelo meta"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_SO_META_SHA="$SHA")
[ "$rc" = "0" ] && _ok "meta igual → rc 0" || { _bad "rc $rc"; cat "$BIN/saida"; }
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_SO_META_SHA=ffffffffffffffffffffffffffffffffffffffff)
[ "$rc" = "1" ] && _ok "meta diferente → rc 1" || _bad "rc $rc"

echo "[20] rede fora (curl falha): reprova sem dizer que subiu"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_CURL_FALHA=1)
[ "$rc" = "1" ] && _ok "rc 1" || _bad "rc $rc"
grep -q 'curl falhou' "$BIN/saida" && _ok "diz que a chamada falhou" || _bad "mensagem muda"
grep -q '✅' "$BIN/saida" && _bad "imprimiu ✅ sem deploy" || _ok "nenhum ✅"

echo "[21] Vercel responde 200 sem id: reprova"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_SEM_ID=1 VD_TIMEOUT_S=2)
[ "$rc" = "1" ] && grep -q 'sem id de deploy' "$BIN/saida" && _ok "rc 1 e diz o porquê" || _bad "rc $rc"
[ "$(_chamadas)" = "1" ] && _ok "não seguiu adiante" || _bad "$(_chamadas) chamadas"

echo "[22] SHA em maiúsculas: configuração inválida, 0 chamadas"
rc=$(_rodar "${BASE[@]}" VD_SHA=0123456789ABCDEF0123456789ABCDEF01234567 VD_ALVO=production VD_DOMINIO=x)
[ "$rc" = "2" ] && [ "$(_chamadas)" = "0" ] && _ok "rc 2, 0 chamadas" || _bad "rc $rc"

echo "[23] sem domínio: configuração inválida (sem prova não há verde)"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production)
[ "$rc" = "2" ] && [ "$(_chamadas)" = "0" ] && _ok "rc 2, 0 chamadas" || _bad "rc $rc"

echo "[24] sucesso registra o resumo do passo e as saídas"
rc=$(RESUMO="$BIN/resumo" _rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=dashboard.play2sell.com)
grep -q 'dashboard.play2sell.com. → .dpl_TESTE. · commit .0123456789ab' "$BIN/resumo" && _ok "resumo com domínio, deploy e commit" || _bad "resumo: $(cat "$BIN/resumo")"
grep -q '^url=https://teste.vercel.app$' "$BIN/out" && _ok "saída url" || _bad "sem saída url"

echo "[25] só fala com a API (nunca com o domínio público) e nunca imprime o token"
for caso in "VD_ALVO=production VD_DOMINIO=dashboard.play2sell.com" "VD_ALVO=production VD_DOMINIO=x FAKE_CODE_CREATE=400" \
            "VD_ALVO=staging VD_ALIAS=w.example VD_DOMINIO=w.example FAKE_CODE_ALIAS=403" "VD_ALVO=production VD_DOMINIO=x FAKE_STATE=ERROR" "VD_ALVO=production VD_DOMINIO=x FAKE_CURL_FALHA=1"; do
  # shellcheck disable=SC2086
  _rodar "${BASE[@]}" $caso >/dev/null
  fora=$(grep '^CHAMADA' "$BIN/log" | grep -vc 'url=https://vercel.test/')
  [ "$fora" = "0" ] && _ok "só API em: $caso" || _bad "$fora chamada(s) fora da API em: $caso"
  grep -q 'tok-secreto' "$BIN/saida" "$BIN/out" && _bad "TOKEN NO LOG em: $caso" || _ok "token fora do log em: $caso"
done

echo "[26] rede cai na leitura do estado (curl 28, o caso de 15/11) e volta → publica"
rc=$(_rodar "${BASE[@]}" VD_ALVO=staging VD_CUSTOM_ENV=staging VD_DOMINIO=app-staging.play2sell.com FAKE_RC_GET=28,28,0 FAKE_STATES=BUILDING,READY VD_TIMEOUT_S=30)
[ "$rc" = "0" ] && _ok "exit 0 depois de 2 leituras perdidas" || _bad "exit $rc: $(tail -3 "$BIN/saida")"
grep -q '::warning::vercel-deploy: curl falhou (28) em GET /v13/deployments/dpl_TESTE' "$BIN/saida" && _ok "avisa a falha de rede (warning, não error)" || _bad "sem warning da falha"
grep -q '::error::' "$BIN/saida" && _bad "imprimiu ::error:: num deploy que deu certo" || _ok "nenhum ::error::"
[ "$(grep -c 'metodo=POST url=https://vercel.test/v13/deployments' "$BIN/log")" = "1" ] && _ok "criou UM deploy só (não recria ao reler)" || _bad "criou mais de um deploy"
grep -q 'app-staging.play2sell.com servindo o deploy dpl_TESTE' "$BIN/saida" && _ok "prova pelo domínio no fim" || _bad "sem prova do domínio"

echo "[27] rede fora em TODAS as leituras → reprova ao fim do prazo, sem dizer que subiu"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_RC_GET=28 VD_TIMEOUT_S=0)
[ "$rc" != "0" ] && _ok "exit $rc" || _bad "passou com a rede fora"
grep -q 'não ficou pronto' "$BIN/saida" && _ok "diz que não ficou pronto" || _bad "motivo: $(tail -2 "$BIN/saida")"
grep -q '✅' "$BIN/saida" && _bad "imprimiu ✅ sem o deploy pronto" || _ok "nenhum ✅"

echo "[28] rede cai na leitura do domínio uma vez → tenta de novo e publica"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=dashboard.play2sell.com FAKE_RC_ALIAS=7,0)
[ "$rc" = "0" ] && _ok "exit 0" || _bad "exit $rc: $(tail -3 "$BIN/saida")"
[ "$(grep -c 'metodo=GET url=https://vercel.test/v4/aliases/' "$BIN/log")" = "2" ] && _ok "2 leituras do domínio" || _bad "leituras do domínio: $(grep -c 'v4/aliases' "$BIN/log")"

echo "[29] rede cai na CRIAÇÃO → reprova na hora, sem tentar criar de novo"
rc=$(_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x FAKE_RC_CREATE=28,0)
[ "$rc" != "0" ] && _ok "exit $rc" || _bad "passou com a criação sem resposta"
[ "$(_chamadas)" = "1" ] && _ok "1 chamada só (POST não se repete às cegas)" || _bad "$(_chamadas) chamadas"
grep -q '::error::vercel-deploy: curl falhou (28) em POST' "$BIN/saida" && _ok "erro nomeia o POST" || _bad "erro: $(tail -2 "$BIN/saida")"

echo "[30] toda chamada sai com teto de conexão e de duração"
_rodar "${BASE[@]}" VD_ALVO=production VD_DOMINIO=x >/dev/null
sem=$(grep '^  limites=' "$BIN/log" | grep -vc -- '--connect-timeout 20 --max-time 120')
tot=$(grep -c '^  limites=' "$BIN/log")
[ "$tot" -ge 3 ] && [ "$sem" = "0" ] && _ok "$tot chamadas, todas com --connect-timeout 20 --max-time 120" || _bad "$sem de $tot sem os limites"

echo ""
[ "$FAILURES" = "0" ] && { echo "vercel-deploy: todos os casos ok"; exit 0; } || { echo "vercel-deploy: $FAILURES falha(s)"; exit 1; }
