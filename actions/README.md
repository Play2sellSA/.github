# Actions canônicas da frota SalesOS*

- `check-code-has-test` — guard "código novo ⇒ teste" (fail-closed; escape auditável
  via label `test-exempt-approved`). Inputs: base_ref, code_regex, test_regex,
  code_exclude_regex, low_risk_regex/max, hint.
- `evaluate-test-gate` — avalia `toJSON(needs)` do caller e decide o required check
  (`🧪 Test gate`).

**Consumo (pin por SHA + comentário da versão — lição tj-actions):**
```yaml
- uses: Play2sellSA/.github/actions/check-code-has-test@<SHA> # v1.0.0
```
Mudança aqui exige self-tests verdes (matriz de 14 cenários em `scripts/tests/`).
Breaking change = major novo (v2), nunca re-tag. Runbook:
vault `04-projects/play2sell/runbooks/qa-gates-frota-implementacao.md`.
