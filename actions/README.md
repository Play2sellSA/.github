# Actions canônicas da frota SalesOS*

- `check-code-has-test` — guard "código novo ⇒ teste" (fail-closed; escape auditável
  via label `test-exempt-approved`). Inputs: base_ref, code_regex, test_regex,
  code_exclude_regex, low_risk_regex/max, hint.
- `evaluate-test-gate` — avalia `toJSON(needs)` do caller e decide o required check
  (`🧪 Test gate`).
- `sentry-release` — registra no Sentry a release deployada, associa os commits e cria
  o deploy do ambiente (Release Health). Inputs: auth_token (vazio = pula em silêncio),
  org, projects, version, environment, repository, deploy_url. Roda DEPOIS do deploy e
  só escreve no Sentry: se reprovar, o que subiu continua de pé — vermelha fica a
  escrituração. `version` e `environment` têm de ser os MESMOS valores que o app manda
  nos eventos, senão o Sentry não casa release com erro.

**Consumo (pin por SHA + comentário da versão — lição tj-actions):**
```yaml
- uses: Play2sellSA/.github/actions/check-code-has-test@<SHA> # v1.0.0
```
Mudança aqui exige self-tests verdes (matriz de 14 cenários em `scripts/tests/`).
Breaking change = major novo (v2), nunca re-tag. Runbook:
vault `04-projects/play2sell/runbooks/qa-gates-frota-implementacao.md`.
