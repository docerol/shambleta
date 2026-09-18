# Débitos técnicos pós-beta fechado

Consolidação canônica (2026-09-18). Nada aqui bloqueia o beta fechado técnico,
sem dinheiro real — veredito `GO` na rodada de hardening (commit `b37b685`).
Cada item lista dono, critério de aceite e onde está o detalhe. Não adicionar
escopo novo antes de quitar: a regra do beta é estabilizar o existente.

| # | Débito | Dono | Critério de aceite | Detalhe |
|---|---|---|---|---|
| 1 | Ativação de Seasons (ciclo `ACTIVE→CLOSING→CLOSED→SETTLED` ou event sourcing imutável; auditoria de corrida, replay e idempotência) | eng + dono (regras congeladas + changelog S1) | suítes de ativação verdes + S1 congelada/publicada; remover `SeasonsBetaLock` | `SEASON_ACTIVATION_NOTE.md` |
| 2 | Regra de acúmulo de guild points (hoje `maxi(1, floori(h))`; definir floor puro vs. participação mínima junto do snapshot) | eng | regra definida + `SuiteGuildPremium` ajustada | `SEASON_ACTIVATION_NOTE.md` (seção "Débito incluído") |
| 3 | Restore S3 real com RPO/RTO observados (drill em container isolado) | dono/infra | `OFFSITE_RESTORE_REPORT.md` §2–3 executados e anotados | `archive/reports/OFFSITE_RESTORE_REPORT.md` |
| 4 | Rewarded ads reais (conta CrazyGames + SDK no `ads_bridge.js`, `SHAMBLETA_AD_PROVIDER=portal`) | dono (conta) + eng (ponte) | anúncio real credita; token adulterado rejeitado; sem downgrade p/ stub | `deploy/web/ads_bridge.js`, `LAUNCH_HANDOFF.md` §2 |
| 5 | Conta Mercado Pago PJ + secrets (`SHAMBLETA_MP_ACCESS_TOKEN`, `SHAMBLETA_MP_WEBHOOK_SECRET`, `SHAMBLETA_MP_BACK_URLS_BASE`) + primeira compra sandbox ponta-a-ponta | dono | preferência real abre; webhook credita sem intervenção | `LAUNCH_HANDOFF.md` §2, `companion/test_security.py` |
| 6 | Setup 2FA server-side (`SetupTwoFactor`/`VerifyTwoFactorSetup`/`DisableTwoFactor` não têm handler — botão morto, fail-closed) | eng | handlers + suíte; rever expiração de setup | `sources/network/Network.gd:87-95` |
| 7 | Primeira run do CI com créditos (workflows sem `liuyuzui`, timeout 1200s — nunca executados remotamente) | dono (créditos) | jobs verdes no GitHub Actions | `.github/workflows/godot-ci.yml` |
| 8 | Smoke interativo client/browser (display + navegador real; coberto só via headless nesta rodada) | QA manual | checklist T11 todo PASS em navegador | relatório da rodada (seção C) |
| 9 | Observabilidade (métricas além do `/metrics` local, alertas, Sentry com DSN) | eng/ops | dashboard + alerta de grant_queue presa | `LAUNCH_HANDOFF.md` §3 |
| 10 | Release signing (builds desktop assinados) | eng/ops | artefatos assinados no CI de release | — |

## Notas que não são débito (registro p/ não re-auditar à toa)

- Gate `realtime: sanity ceiling` é flaky em janelas curtas por construção
  (granularidade de kills inteiros; calibrado p/ 300s no D1). Em janela de 60s,
  3 kills = 180/h (PASS) vs 4 kills = 240/h (FAIL) — variância, não regressão.
- `.autowrap =` em `Checkout/Onboarding/Settings` (propriedade não existe
  neste build; erro runtime não-fatal) — LOW, cosmético de log.
- `/metrics` do companion sem auth, mas bind default `127.0.0.1` — LOW.
- `benchmarks.gd` reporta 24 zonas (só as com mapa) — informativo, não falha.
- `SuiteSeasonLock` + `SHAMBLETA_ENABLE_SEASONS=1` nos testes: intencional
  (trava default travada; testes habilitam explicitamente).
