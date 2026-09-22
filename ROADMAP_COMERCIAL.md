# Roadmap Comercial — Shambleta (lucrar)

**Criado:** 2026-09-22 · **Origem:** avaliação comercial (média real 6.8/10) · **Bar:** OSRS
**Relacionados:** `archive/ROADMAP.md` (F0–F5, base técnica) · `progress.md` (gauntlet) · `plano-ui-ux.md` (polimento)
**Princípio:** jogo F2P-friendly, VIP = QoL (offline cap, velocidade), sem P2W, sem crypto. Moeda fechada, não-cashable.

> Este arquivo é o plano comercial executável. O `archive/ROADMAP.md` continua como referência técnica; o que está aqui tem gate de receita.

## Oferta (congelada para o soft-launch)

| SKU | Preço | Regra |
|---|---|---|
| `starter.pack` | R$ 9,90 | D0–D3, one-time por conta (já existe `STARTER_SKU` + grant idempotente) |
| `vip.1mo` | R$ 14,90/mês | QoL: offline cap 24h, settle ×1.2. Sem power direto |
| `pass.s1` / `pass.s1.deluxe` | R$ 19,90 / R$ 44,90 | Temporada 30d, regras congeladas, cosmético + chaves |
| Taxa AH/trade | 10 gems flat burn (`TradeFeeGems`) + listagem gold | Sink primário anti-inflação e anti-RMT |

## Semana 1 — Cobrar (gate: 1ª venda end-to-end em staging)

- [x] Funil telemetria: `onboarding_done, first_boss, first_chest, d1_return` (`TelemetryService.RecordFunnel`)
- [x] `onboarding_done` emitido no `Onboarding.Stop()` (best-effort, null-safe)
- [x] `first_chest` emitido no `EconomyService.OpenChest()` (best-effort, fora da transação)
- [x] Dashboard mínimo: `TelemetryService.FunnelSummary()` (5 KPIs por conta distinta) + índice 042 (covering index verificado via `EXPLAIN QUERY PLAN`)
- [ ] Ligar 1 gateway só (Stripe OU Mercado Pago) no `companion/server.py` — webhook → `grant_queue` (já idempotente). **Exige decisão do dono + conta PJ.**
- [ ] `refund-sweep --dry-run` executado em staging (`SHAMBLETA_MP_REFUNDS=1` só com conta real)
- **Gate S1:** checkout sandbox → grant → item no client + `refund dry-run` OK + backup restore OK.

## Semana 2 — Reter (gate: D1 ≥ 35%, D7 ≥ 20% no beta)

- [x] Skip 1-clique no onboarding (`Onboarding._skipButton` → mesma semântica do Finish)
- [x] `first_boss` emitido na 1ª vitória (`SettleBossResult`, `prevBeaten == 0`)
- [x] `d1_return` emitido no 2º dia de login (`Peers.FinalizeLogin`)
- [x] Trade: cap diário F2P 20 vs VIP 40 (`TradeDailyCapVIP`) + `GetTradeFeeState()` p/ UI (taxa burn visível antes de confirmar)
- [x] Temporada S1: `SeasonS1Rules()` congeladas + `EnsureSeasonS1()` idempotente (respeita trava T5 — cria só com `SHAMBLETA_ENABLE_SEASONS=1`)
- [ ] AH seed de bots no lançamento + cooldown/cap já existem (60s, email verificado)
- **Gate S2:** loop conta→farm→sair→voltar→coletar offline→abrir baú medido no funil, 0 duplicações em crash-test.

## Semana 3 — Escalar (gate: 200 CCU reais, P99 settle < 200ms)

- [x] `.graphifyignore`: exclui `addons/sentry/*`, `data/graphics/*` do grafo (grafo era 2674 nodes poluídos)
- [x] Load probe real: 200 settles medidos com P99 + gate 200ms (`tests/benchmarks.gd` — substitui print-only; verificado **0 failures**, P99 1ms)
- [x] Índice do funil (042) validado com `EXPLAIN QUERY PLAN`
- [x] **Network destravado**: causa raiz = `.godot/` nunca importado neste ambiente (cache de classes globais inexistente) + 6 fragmentos P4 com `class_name` colidindo com autoload + 3 `RefCounted` registrados como autoload + erros reais de sintaxe (`SQL.gd` var duplicada, indentação espaço-vs-tab em `IdlePolicy`/`BossService`/`WorldAgent`/`Server`/`TwoFactorAuth`, `Footprint.CheckAction` inexistente, `dbNode` indefinido, `_killRegistered` não declarado). Suíte saiu de FATAL para **1122 checks, 25 failures** (todas pré-existentes: goldens drift 5x, vendor, replay-auth, spawn sim)
- [x] **Fatia 1 do EconomyService**: `EconomyCatalog.gd` (605 linhas: 114 consts + 18 helpers puros, zero mudança de comportamento); `EconomyService.gd` 4137→3806. Wrappers mantidos (`ShopDay`, `PassLevelForPT`, `SeasonsEnabled`, `CosmeticLabel`); testes/world atualizados p/ `EconomyCatalog.*`
- [ ] Fatia 2 (lógica: GrantQueue/VIP/Checkout/Season/Guild): exige desacoplar mutex/transações — backlog, suíte precisa estar verde antes
- [ ] Soft-launch web + Android, custo infra < meta, uptime ≥ 99.5%
- **Gate S3 (LAUNCH):** ToS/LGPD auditados, sink/faucet gems 0.8–1.2/semana, conversão paga ≥ 2%.

## Métricas 30/90 dias (mesmas do roadmap técnico, cobradas aqui)

- Jogo: D1 ≥ 35%, D7 ≥ 20%, D30 ≥ 8%; 1ª coleta offline < 30min
- Economia: ≥ 60% das gems em chaves/guild; divergência ledger = 0 (job diário)
- Receita: conversão ≥ 2%, ARPPU ≥ US$ 8/mês, VIP ≥ 60% da receita

## Bloqueados fora da engenharia (não executar sem dono/terceiro)

Preços finais, conta MP/Stripe PJ, arte de cosméticos, SDK de ads real, contas em portais web. Ver `archive/ROADMAP.md` § Follow-ups.
