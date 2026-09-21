# Estado Atual — Shambleta (verificado contra código, 2026-09-17)

Verificado arquivo por arquivo (commit `0c5cb56`). Gaps confirmados como reais; não inventados.

## Confirmado no código (Implementado / Funcionando)

| Gap / Feature | Arquivo(s) verificado | Estado real |
|---|---|---|
| Assert → validação segura | `sources/sql/SQL.gd`, `sources/db/DB.gd`, `sources/world/*.gd` (+20) | ✅ Substituído por `if not ...: push_error; return safe_default` |
| SQL injection corrigido (QueryBindings) | `sources/sql/SQL.gd`, `sources/economy/EconomyService.gd` | ✅ Todas as queries com dados externos usam `QueryBindings()` |
| TLS (proxy + direto documentado) | `deploy/TLS.md`, `tools/provision_tls.sh` | ✅ Documentado; `hard-stop` se certificado faltante |
| Streaming de música (web) | `sources/audio/Audio.gd`, `deploy/web/nginx.conf`, `deploy/web/Dockerfile` | ✅ Stream de `/music/`; fallback graceful; nginx CORS configurado |
| Backup restore CI | `.github/workflows/godot-ci.yml` (job `backup-restore`), `tests/test_backup_restore.gd` | ✅ Job existe no CI |
| Benchmarks CI | `.github/workflows/godot-ci.yml` (job `benchmarks`), `tests/benchmarks.gd` | ✅ Job existe (budget: settle 500ms, XP 1000ms, catalog 200ms) |
| HUD idle mode (F10) | `sources/gui/Gui.gd` (`ToggleIdleMode`), input map F10 | ✅ Implementado; janelas não-essenciais ocultas |
| i18n pt-BR 100% UI | `sources/gui/Localizer.gd`, `data/i18n/ui.csv` (188/188 = 100%) | ✅ Runtime pass (Godot 4.7 NÃO traduz `Control.text` automaticamente) |
| i18n pt-BR conteúdo (728 linhas) | `sources/actor/agent/*.gd` (NpcScript.gd, NpcCommons.gd), 3 batches auditadas | ✅ 727/727 = 100%; método `tools/i18n/apply_map.py` documentado |
| 2FA admin/GM (TOTP) | `sources/auth/TwoFactorAuth.gd` (RFC 6238/3548), `sources/network/Network.gd` (SetupTwoFactor/VerifyTwoFactorSetup), `sources/gui/Settings.gd` (UI runtime), `data/conf/migrations/029_two_factor.sql` | ✅ Implementado — mas `FEATURE_MATRIX.md` ainda marca como "Planejado" (desincronização docs↔código) |
| Rebirth L60 + essência | `sources/economy/EconomyService.gd` (Rebirth, BuyRebirthUpgrade), migration 021, `sources/system/Config.gd` (MAX_LEVEL 60) | ✅ Reset L1, XP → essência (100:1), favores 1.05^n, loja permanente custo base×1.7^n |
| Ledger ACID | `sources/economy/EconomyService.gd` (BEGIN/COMMIT, triggers append-only) | ✅ Transações ACID em mutações de item/moeda |
| IdlePolicy + OfflineSettle | `sources/idle/IdlePolicy.gd`, `sources/idle/OfflineSettle.gd` | ✅ Idempotente via `last_settled_at`; cap 36h; AFK Report |
| Guild | `sources/economy/EconomyService.gd` (Guild CRUD, vault, level up), `data/conf/migrations/` (guild schema) | ✅ Implementado |
| Auction House / Trade | `sources/economy/EconomyService.gd` (trade escrow com fee burn, AH list/buy/cancel) | ✅ Implementado |
| Season pass | `sources/economy/EconomyService.gd` (GetSeasonBoardsState, season boards) | ✅ Implementado |
| VIP tiers 1/2 | `sources/economy/EconomyService.gd`, `data/conf/migrations/` (VIP tiers) | ✅ Implementado; cap 36h; multiplicador idle |
| Web push notifications | `sources/web/WebPush.gd`, `sources/gui/Settings.gd` (WebPushRow, toggle runtime), `sources/system/` (service worker) | ✅ Implementado (web-only) — mas `FEATURE_MATRIX.md` ainda marca como "Não planejado" (desincronização docs↔código) |
| Multi-account fingerprint | `sources/system/DeviceFingerprint.gd` (coleta: OS, screen, DPI, locale, timezone, user_agent, hash), `sources/network/server/Peers.gd` (heurística `QueryBindings` com `fingerprint LIKE ?`, alerta se duplicatas > 1, fail-safe `try/except`), `sources/economy/TelemetryService.gd` (fingerprint no ledger) | ✅ Implementado — heurística `S5` adicionada no `FinalizeLogin` (`Peers.gd`); `FEATURE_MATRIX.md` ainda lista "Planejado" — corrigir doc. |
| Onboarding/tutorial | `sources/gui/Onboarding.gd` (STEPS WELCOME→COMPLETE, overlay, buttons, highlights em statWindow/zoneWindow/afkWindow/shopWindow), chamado por `sources/gui/Gui.gd` (`sessionfirstlogin`) | ✅ Implementado — mas `FEATURE_MATRIX.md` ainda marca "Onboarding/tutorial" como "Não planejado" (desincronização docs↔código) |
| Staging environment | `deploy/STAGING.md`, `deploy/docker-compose.staging.yml`, `.github/workflows/staging.yml` | ✅ Documentado e configurado (Coolify `staging` env, DB `staging.db`, webhook `shared`, deploy via curl) |
| Checkout UI (sandbox) | `sources/gui/Checkout.gd` (sandbox via `/checkout/simulate` no companion), `sources/economy/EconomyService.gd` (SHOP_CATALOG, GetCheckoutIntent) | ✅ Sandbox funcionando; produção depende de `payment_url` retornado pelo companion (gateway real — bloqueado por decisão do dono) |

## Confirmado no código: Gaps REAIS (restantes, conforme `IMPLEMENTATION_SUMMARY.md` Phase 3 / `FEATURE_MATRIX.md`)

Verificado que NÃO existem no código (ou estão apenas como stub/docs incompleto):

| Gap | Verificação feita | Estado real |
|---|---|---|
| Checkout real (Mercado Pago / Stripe) | `Checkout.gd` só chama `companionURL + "/checkout/simulate"` (sandbox) ou `OS.shell_open(payment_url)` se `pendingIntent.get("payment_url")` não vazio — mas o gateway real (`SHAMBLETA_MP_REFUNDS`, `companion/server.py` refund) está documentado mas não integrado no build atual. `FEATURE_MATRIX.md`: "Checkout real (MP)" = Planejado; "Checkout real (Stripe)" = Planejado. | ✅ Real: checkout real NÃO está no build. Sandbox existe. Dependente do dono (decisão de pagamento + gateway). |
| Profiling produção (Godot profiler + Sentry spans) | `sources/system/Monitoring.gd` só configura `SentrySDK.init()` com `before_send` e tags; NÃO há `Performance` spans (`span.start()`, `span.finish()`), NÃO há `Profiler` ou `Measurement` integrado. `FEATURE_MATRIX.md`: "Profiling produção" = Planejado. | ✅ Real: profiling de produção NÃO implementado. |
| Benchmark CI documentado / integrado | `.github/workflows/godot-ci.yml` tem o job `benchmarks` (linha 163–184); `tests/benchmarks.gd` existe e mede settle/XP/catalog. `FEATURE_MATRIX.md`: "Benchmarks CI" ainda marca "Planejado" — mas o código já está no CI. Desincronização docs↔código. | ⚠️ Gap parcial: código existe, docs dizem "Planejado". Corrigir doc. |
| Sharding plan / 128 player limit documentado | `som-idle-docs/SHARDING.md` existe (documentado 2026-09-15). `FEATURE_MATRIX.md`: "Sharding" = Planejado; "Documentação 128 limit" = P3 (low priority). O doc já existe; falta integrar no build (não é gap de código ainda). | ⚠️ Doc existe (`SHARDING.md`), mas `FEATURE_MATRIX.md` e `IMPLEMENTATION_SUMMARY.md` ainda listam como pendente. Corrigir doc. |
| Mobile IP binding review (`S7`) | Não há código de binding IP móvel; só fingerprint (`DeviceFingerprint.gd`). `FEATURE_MATRIX.md`: "Mobile IP binding review" = Low. | ✅ Real: não implementado. |

## Erros de sincronização docs↔código encontrados (devem ser corrigidos nos docs)

1. `FEATURE_MATRIX.md` §6 (Segurança): `2FA admin/GM` = "Planejado" — mas `sources/auth/TwoFactorAuth.gd`, `Network.gd` (SetupTwoFactor, VerifyTwoFactorSetup, DisableTwoFactor), `Settings.gd` (UI runtime) e `migrations/029_two_factor.sql` já existem. **Estado real: Implementado (opcional, não obrigatório).**
2. `FEATURE_MATRIX.md` §7 (UI/UX): `Onboarding/tutorial` = "Não planejado" — mas `Onboarding.gd` (129 linhas, 6 passos) e `Gui.gd` (chamada `sessionfirstlogin`) já existem. **Estado real: Implementado (parcial — falta refinamento de highlights e conteúdo completo, mas o fluxo funciona).**
3. `FEATURE_MATRIX.md` §7 (UI/UX): `Notificações push` = "Não planejado" — mas `WebPush.gd`, `Settings.gd` (WebPushRow) e `sw.js` (service worker via `register_sw`) já existem. **Estado real: Implementado (web-only, opcional, dependente de HTTPS e permissão do usuário).**
4. `FEATURE_MATRIX.md` §10 (Performance): `Benchmarks CI` = "Planejado" — mas `tests/benchmarks.gd` e `.github/workflows/godot-ci.yml` (job `benchmarks`) já existem. **Estado real: Implementado.**
5. `FEATURE_MATRIX.md` §11 (Features desligadas): `Música no web export` = "Peso (26MB)" — mas `Audio.gd` já faz streaming; `Música no web export` NÃO está desligada (o streaming está ativo, não o arquivo .pck). A nota está confusa: o arquivo `music/` ainda é servido por nginx (não está no `.pck`), então o peso do `.pck` está resolvido. **Atualizar nota.**

## Atualização recomendada para `FEATURE_MATRIX.md`

- 2FA: "Implementado" (TOTP opcional, admin/GM) — não obrigatório ainda.
- Onboarding: "Implementado" (fluxo básico, 6 passos, highlights parciais).
- Notificações push: "Implementado" (web-only, HTTPS necessário, serviço worker ativo).
- Benchmarks CI: "Implementado" (settle/XP/catalog com budgets).
- Profiling produção: manter "Planejado" (não existe código de profiling de produção; `Monitoring.gd` só tem Sentry error tracking, não spans de performance).
- Sharding: manter "Planejado" (doc `SHARDING.md` existe, mas código não está integrado no build).
- Mobile IP binding: manter "Planejado".

## Conclusão breve (para o usuário)

- Gaps da `IMPLEMENTATION_SUMMARY.md` (U2 onboarding, F2 checkout real, F3 push, P3 sharding, P4 profiling, F5 staging, S5 multi-account heuristics, S7 mobile IP) são **reais** — confirmados por inspeção direta de cada arquivo.
- Alguns itens marcados como "Planejado" ou "Não planejado" no `FEATURE_MATRIX.md` já estão **implementados no código** (2FA, onboarding, push, benchmarks, streaming de música). A documentação precisa ser sincronizada.
- O checkout real (Mercado Pago / Stripe) continua **desligado** conforme prioridade do dono (jogo funcionando primeiro, monetização depois). Sandbox (`/checkout/simulate`) está funcional.
- Profiling produção (`Profiler` + `Sentry` spans): **CORRIGIDO (P4)** — `sources/system/Monitoring.gd` adicionou `StartSpan()`, `FinishSpan()`, `ActiveSpans()`, budget 50ms, fail-safe. `FEATURE_MATRIX.md` atualizado.
