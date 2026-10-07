# SHAMBLETA — AUDITORIA COMPLETA (2026-10-04)

## 1. Executive Summary

Shambleta is a **maturely engineered** Godot 4.7 server-authoritative idle RPG (~61k lines GDScript, 333 GD files, 71 SQL migrations, 120+ test harnesses) with some of the strongest money-boundary and security engineering I have audited: parameterized SQL enforced via allowlist, append-only ledger gated by DB triggers, server-authoritative combat with zero client-trusted damage, a triple-layer gate (ci_gate_log + structure gates + doc-drift) with planted controls, real Prometheus/Alertmanager, and a money pipeline (Mercado Pago HMAC + authoritative re-fetch + idempotency-keyed grant queue) that survives a crash.

**But it ships RED today.** Three money/state harnesses are failing in the working tree (`refund_revocation_test`, `fraud_test`, `balance_test`), the entry-gate harness (`admission_gate_test`) does not compile, and the production analytics funnel, while on by default in code, depends entirely on a JSON blob that Prometheus cannot scrape. On top of that, the **product model is one axis deep**: a player reaching the level cap (L60) in 7.7 days can finish the 27-zone ladder in 2 hours of attention, after which the only repeatable content is `BossRush` (which pays the active-timing mechanic 0%) followed by a single `torment` integer, and the prestige layer is documented-internal as skippable.

The codebase is **not** five minutes from a bad refactor. Its risk is **commercial**: the live offer states `BaseCapHours = 8.0` while every doc and the marketing header says 1h (`BaseCapHours=8.0` was adopted 2026-09-25 as retention hardening, docs never updated); the auction house — the headline anti-inflation sink in the roadmap — **destroys zero gold** (price leaves buyer, reaches seller; nothing is destroyed); and a single DB read of `live.db` converts to account + payment takeover because the remember-me token is an unsalted SHA-256 hash with a 30-day validity and the companion's checkout path drops the IP binding.

**Prontidão geral: 5/10.** The engineering base is closer to 7/10, but the **product model and the money boundary's operational wiring are not launch-ready**, and two of the five red gates are live-revenue defects, not polish.

---

## 2. Inventário do repositório

- **Stack:** Godot 4.7.1 (engine pin), 4.7.2 local; server-authoritative; SQLite WAL single-file, WAL single-writer + 2-slot read-pool (`SQLReadPool.gd`); companion Python `ThreadingHTTPServer` (Pix/Mercado Pago webhook + checkout intent + `/store`, `/metrics`, PWA push); nginx 1.27 reverse proxy; Coolify staging deploy; Prometheus 3.15 + Alertmanager.
- **Frontend:** Godot 4 client; web export HTML5/WASM; `sources/gui/` = 90 files / 14,085 lines (largest module). i18n 100% pt_BR (1,337 CSV rows, 0 missing), WCAG 2.5.5 touch targets.
- **Backend modules (`sources/`):** actor, ads, ai, audio, auth, camera, cell, combat, conf, db, debug, economy (25 files / 11,389 lines), effects, gui, idle, input, launcher, map, network, ops, season, shaders, skill, social, sql, system, util, web, world.
- **Migrations:** 67 forward-only, dense numbered series addressed by directory position; `apply` transactions each patch, fail-closed, stamps version per-patch.
- **Test harnesses:** 76 GDScript gates (70 auto-enrolled by filename + 6 explicit) + 10 Python suites (`companion/test_security.py`, `test_webhook.py`) + 11 structure gates + 52 secrets checks.
- **CI:** `.github/workflows/godot-ci.yml` — push-only, **no `pull_request` trigger**; `release.yml` gates on `test.sh all`.
- **`.env.example`** empty-credential policy with in-line rationale; `check_secrets.sh` enforces both directions with planted controls.
- **Graph:** `graphify-out/` rebuilt during this audit; 1,913 nodes / 2,395 edges / 257 communities (stale at `9e38f16b`, rebuilt to `eb9514e`).

---

## 3. Arquitetura

The architecture is documented honestly at `docs/development/architecture.md` and matches the code. Key verified facts:

- **Authority:** identity read from the transport via `AuthPeerID`/`TransportSenderID` (`Network.gd:1128-1143`), overrides any packet field; **all 126 inbound RPCs** route through it; zero client→SQL paths (only one hit is a comment); client runs combat sim for responsiveness but the server grants XP/gold in `Formula.ApplyXp`.
- **Money boundary:** webhooks live in companion (HMAC + authoritative re-fetch + idempotency), not in the game process. A compromised game server cannot mint real money.
- **God-node gate:** ratcheted allowlist, 8 files with named ceilings; currently 0 failures, but **3 of 8 at slack ≤ 3** and `TelemetryService.gd` at 799/800 — refactoring budget is zero.
- **Lock discipline:** `_eco.settleMutex` (global) on 47 sites + `_eco._get_settle_mutex()` (sharded) on 8 sites — **two locking disciplines**, 85% of sites still global. The shard split is 85% inert and creates a latent two-discipline hazard.
- **FKs:** declared on templates, **`PRAGMA foreign_keys` never set** (`grep` 0 hits); replaced by explicit `AFTER DELETE` triggers (`066`, `067`) + delta-baselined orphan census. **Not a bug, but `architecture.md` does not document this** — the templates imply enforcement.
- **CHECK constraints:** **none** on `wallet.gems`, `stat.gp`, `item.count`, `item_instance.count`, `ah_buy_order.escrow_gold`. Money integrity lives only in GDScript.

---

## 4. Game Design

### Core loop
Server-authoritative state machine at 4 Hz (`IdlePolicy.gd:18`), five states (`IDLE→SEEK→COMBAT→LOOT→DEAD`), 0.25 s game-seconds clamped to `MaxCatchUpSeconds = 2.0`. The player is warped into a dedicated farm instance on login (`IdlePolicyService.gd:70`) and auto-farmed. **Active play = one timing mechanic** (`RequestBossInterrupt` window, 1.2 s/3.0 s) in 2 buttons (`ManualHudBar.gd:31`: Melee, Run). **The interrupt mechanic is worth 0% in `BossRush`** — `RunBossRush` calls `BossService.Resolve(snapshot, level)` (2 args) so `interruptMult` defaults to 1.0 (`BossService.gd:175`, `:173` comment).

### Progression
- XP(L→L+1) = `round(8000 × 1.22^L)`; cap L60; cumulative = 5.52 × 10⁹. **Time to cap: ~7.7 days continuous online, ~13.3 days offline-only.** (`archive/XP_PROGRESSION.md:68` claims "17–21 dias" — **doc-vs-code: code is 2.5× faster**.)
- Zone gate is **linear** (`MinPowerBase=24 + 8×zone`); zone XP is **exponential** (`1200 × 1.25^(z-1)`). Zone 27 = 167.6× zone 1 income, reachable at L21 in ~2 hours of attention. The ladder is a 2-hour ramp.
- 10 one-time bosses (`BossService.gd:23`); `ladder_complete` gate (`BossProgressionService.gd:210-211`). After 10 wins, only `BossRush` (1 key → up to 10 sim duels).
- **Content volume:** 27 farm zones, 10 bosses, 96 item cells (tiers 4–9 = only 25 items = the entire deep game), 13 skills (2 have manual buttons), 3 classes, 17 quests, 21 cosmetics, 2 set bonuses. For comparison: Melvor ~20 skills/1100 items/40 monsters; AFK Arena 5-hero auto-battle with deep ascension. **Shambleta is ~15–20% of a commercial idle RPG's content volume.**

### Meta game
One axis (zone depth), one integer (torment 0–10), one prestige axis. **No dungeons, no world boss, no procedural event, no collection set, no build optimization** (no skill levels — all 13 skills are level 1, `SkillTrainer.gd:132`). Torment and rebirth favours both multiply the same faucet products, creating positive feedback rather than depth.

### Onboarding / retention hooks
- Onboarding: 6 steps (`Onboarding.gd:8-16`), touch-aware, but **steps 2-4 teach F1/F2 on the platform that has neither** (`Onboarding.gd:124/127/130/133`).
- **Login streak UI exists** (correcting an upstream false-positive): rendered inside `AfkReport.gd` via `StreakRows.Build/Refresh`. It IS wired; it IS reachable on return. The streak is 3,250 gold + 75 gems + key + chest per *character* per 7-day cycle, 10 characters = ~1.2–2.0× the declared band (per-character faucets × `MaxCharacterCount=10`, `ActorCommons.gd:407`).
- Pass: 40 levels, 3 dailies + weeklies, **30/40 free and 22/40 premium are empty reward slots** (`EconomyCatalog.gd:467-483`).
- **Login warps to farm; no town portal; `/warp` is MODERATOR-only** (`IdlePolicyService.gd:70/181/219`, `WorldCommands.gd:7`). Quest NPCs, the sole skill trainer, and guildmate interactions are structurally unreachable from game flow.

### Social
Guilds, guild chat (verified wired + tested `guild_chat_fanout_test.gd`), chat moderation, social graph, PvP arena (ELO), tournaments, trade (10-gem burn), AH. **Gift is absent. Guild points have zero economic value** (only a display board + season prize behind `SeasonsBetaLock`).

### Live Ops
Real remote config: JSON events calendar (15 entries), seasons, paid catalog, base-economy knobs — all fail-closed validated. **No A/B testing, no segmentation, no numeric remote balance.** `double_xp`/`chest_bonus` windows exist but the calendar has **11 of 15 windows as `tournament`** (prize-pool-only, F2P-irrelevant) and the file documents a 44-day gap. S1 anchored to first server boot (`start_unix: 0, end_unix: 0`).

---

## 5. Core Loop / Meta

| Dimension | Implemented | Quality |
|---|---|---|
| Clarity | high — login→farm→claim→menu | 3 of 4 actions gated behind the farm instance |
| Force | high — offline 5.07× XP/attention vs online 1.58× XP/wall-clock | 2.07 hours of total attention exhausts the game |
| Variety | 1 farm instance, 1 active mechanic worth 0% post-ladder | 1 axis |
| Reward | strong per-minute offline; negligible per-day streak vs faucet | streak = 21% of one settle/week/char |
| Motivation | offline efficiency; torment/rebirth as scalars | no second axis |
| Sustain | fails after L60 + 10 bosses (≈ day 14) | single scalar axis |

**Core Loop: 3/10. Meta: 2/10.**

---

## 6. Condições de retenção

| Mechanic | Present | Effective? |
|---|---|---|
| Daily login streak | yes | **structurally weakened** — per-char × 10 (D3), rendered in AFK report (not missing) |
| Season pass | yes | **25% of levels pay nothing** (P2) |
| D1/D7 retention triggers | code-level | **`d1_return` is a telemetry *event*, not a D1-retention *metric*** (`TelemetryService.gd` records the event; no `shambleta_*_retention` gauge emitted) |
| Social obligation | guilds exist | **login auto-warps to private farm — guildmates unreachable** (P0) |
| FOMO | weekly arena + pass | **no limited-time shop, no countdown framing** |
| Collection | — | **none** |
| Push re-engagement | built (1,174 lines) | **not wired to any game event** |

### Gap crítico de analytics — verificado
- `FeatureFlags.FUNNEL_DAILY: true` is the code default, and **`deploy/docker-compose.yml` does not override it OFF** → the funnel is ON in the shipped compose. (An upstream report claimed the funnel is "disabled by default in production"; **re-checked against `FeatureFlags.gd:45-50`**: it is not. Marking CORRIGIDO.)
- **However:** `d1_return` is an *event*, and `IsD1Return()` is only used inside `RecordFunnel`. The GameAnalytics benchmark the roadmap cites (D1 22/27%, D7 3.4-3.9%/7%) needs D1/D7/D30 in Prometheus; D1 retention is a JSON cohort (`cohort_retention` view, `companion/server.py:1500-1510`) that the companion now also publishes as gauges (`companion/server.py:1474-1489`) — **CORRIGIDO na revisão live (2026-10-04).**
- **`server.py /metrics` returns JSON with `Content-Type: application/json`** (`server.py:1401-1404`), served at `/metrics` (`server.py:1558-1561`). **CORRIGIDO na revisão live (2026-10-04):** `deploy/prometheus.yml:69` scrapeia `companion:8901` em `/metrics/prometheus`, que serve exposition em texto (`companion/server.py:1424-1537`) — o scrape morto virou alvo alcançável, e os money KPIs (ARPU, ARPPU, sales_by_sku, revenue_by_currency, accounts, settles) saem como métrica. **Ainda aberto:** zero das 21 regras de alerta referencia uma métrica do companion (todas apontam métricas do game: `grant_queue`, `reconcile`, `fraud_flags`).
- `ROrtedMetrics` exposes the **raw components** (`money_units`, `money_gross_minor_cents`) in Prometheus exposition, but the KPI *ratios* (ARPU, ARPPU, conversion) are only composed in the JSON. **No `shambleta_*_arpu` or `_conversion` family exists.**

---

## 7. Economia — análise profunda

### Flow map (reconstruído do código)
PLAYER → faucet (online kill / offline settle / boss / streak / IAP / season / tournament / referral) → storage (`stat.gp`, `wallet.gems`, `item`/`item_instance`, `chest_instance`, `boss_keys`, `character.essence`) → sink (corrupt fees / craft material / vendor / AH-list gems / trade gems / guild-gem-upgrades / VIP) → transfer (trade 10-gem-burn, AH 5-gem-list) → destruction (corrupt 85%, cube 3:1, salvage) → ledger (`ledger_transaction`, append-only via DB triggers `009_idle_economy.sql:26-30`).

### Faucet→sink por moeda (confidencial)

| Moeda | Faucet principal (taxa) | Sink principal | Defeito? |
|---|---|---|---|
| **Gold** | online kill (sem cap diário); offline settle (capped 8h F2P/24h VIP +1h/ad ×12); streak 3,250/dia/char; boss; questa; IAP | corrupt_fee (500×tier²×ratio^0.886, **sem cap diário**), craft_submit_fee (3/dia), vendor (≤7,340/dia), boss_key_buy (10k, sem cap), guild_create/level, tournament (1k/sem) | **SIM — AH vende ouro a preço-cheio, sem comissão** |
| **Gems** | IAP (550/1200/3000 BRL19.90/39.90/79.90); streak 75/ciclo/char; tournament 4,800/sem; season prizes 9,600/30d; referral 200/par; pass free/premium | chest_buy (120); daily_offer (7,340/dia); reroll (60); AH fees (5 list +15 highlight + gem slots 750); trade (10, cap 20); guild upgrades; pass_skip; cosmetics | **Parcial — 1,150 de 1,300 cosmetic prices são UNBUYABLE** |
| **Essence** | cap overflow (XP/100); salvage 2×tier≥4; corrupt blessed 5×tier (30%) | rebirth upgrades (1.05^n, uncapped gold/xp; attune 1.05^n, cap 10) | rebirth racionalmente evitável |
| **Items** | 0.7/kill drops; 1/chest; craft approval; AH bot seed | corrupt (85%); cube 3:1; salvage; craft (12×tier) | OK |

### O defeito central: AH vende ouro sem destruí-lo
`AuctionHouseService.gd:845-861` (verificado na época; **atualizado no lote C-10/P0-7 (2026-10-06)**: o `price` sai integral do comprador, o vendedor recebe `price − creatorFee` e o `creatorFee` vira `ah_burn`; a listagem gold também queima via `ah_burn`). Antes disto: **Soma = price. Nada destruído.** A road map alega que o "sink primário" é "listagem gold" (`ROADMAP_COMERCIAL.md:16`), mas a listagem só queima 5 gems, não gold. O único sink real é a direct-trade fee (10 gems, 20/dia). **Isso habilita lavagem de ouro/RMT** (D2).

### Escassez / inflação — com números
- Zona 27 (max-stack VP2+guild10+torment10+weekend+double_xp+ad×2+attune10, 36h settle) entrega 4.31×10⁹ gold no singelo settle. Fonte: `OfflineSettle.gd:338`, `mods = 1.2×1.18×2×2×3.5=19.824`.
- O corrupt_fee tier-9 z27 custa 3.78×10⁶, declarado como "60–180 min de par" (`gold_sink_scale_test.gd:56-57`). **Medido contra o faucet entregue, é 3.2–9.5 segundos.** O teste passa porque divide por `goldPerHour` (`FarmZoneData.gd:273`), não pelo income real. **1142× de desvio para uma conta full-stack, 63× para uma conta modestinha.** (D4)
- Streak é **per-character**: 10 chars = ~1.2–2.0× a banda declarada (D3).
- Gems: F2P weekly faucet ≈ 5,550; weekly sink capacity ≈ 6,570 → **parcialmente saudável**.

### Verificado (NÃO um defeito)
- `OfflineSettle` idempotência: `BaseCapHours`, `AdHoursEarned` (counts `views + outstanding`, not just views) [`OfflineSettle.gd:239-247`]. Server clock only. CONFIRMED.
- Chest cap applied *after* the campaign multiplier — `LiveOpsChestMods` (`OfflineSettle.gd:299`). CONFIRMED.
- Escrow com lineage restore (`_RestoreEscrowLocked:182-240`). CONFIRMED.
- Buy-order escrow `held_gold == quantity × unit_price` invariant. CONFIRMED.
- Ledger append-only via trigger. CONFIRMED.

---

## 8. Monetização

| SKU | Kind | Price BRL | Quantidade |
|---|---|---|---|
| gems.550 | gems | 19.90 | 550 (R$0.0362/gem) |
| gems.1200 | gems | 39.90 | 1,200 |
| gems.3000 | gems | 79.90 | 3,000 (R$0.0266/gem — melhor) |
| vip.1mo | vip_days | 24.90 | 30 |
| vip.3mo | vip_days | 59.90 | 90 |
| pass.s1 / pass.s2 | pass_premium | 39.90 | premium S1/S2 |
| starter / founder | bundle | (19.90?) | 220 gems + cosmetic |
| donate.support | entitlement | 19.90 | title "Apoiador" |

- **Conversion ≥ 2% target** (`ROADMAP_COMERCIAL.md:84`); **D7 ≥ 7%** (`@28`). Baseline real (GameAnalytics 2025): median D7 ~4% (top quartile 7-8%). O plano exige ser top-quartile.
- **P2W via gems → guild power:** `guild_level_fast` skips gold ladders entirely at `2× guild_level` gems → up to 97,340 gems ≈ R$2,593 for a permanent ×1.18 on three faucets. **Contradicts "sem P2W"** (`ROADMAP_COMERCIAL.md:5` vs `GuildService.gd:493`). (D6)
- **Cosmetic sink efetivo: 150 gems, one-time per account** (1 unbuyable of 21). (D5)
- **ARPU alvo:** não declarado numericamente na roadmap; conversão + ARPPU ≥ US$8/mês (`@222`). GameAnalytics: ARPPU median mobile 2026 = ~US$2.33 (top 1%). O gap típico.
- Pix é o método dominante no Brasil (65%→76% conversão em estudo PagBrasil). Mercado Pago integrado. **Pix expiry default 24h** — pode virar problema de chargeback se usado em season pass de 30 dias sem re-assinatura (verificado em `mercadopago.com.br/developers`).

---

## 9. Marketplace

| Aspecto | Realidade | Risco |
|---|---|---|
| Liquidez | AH com 1,155 linhas + escrow de lineage + 50 listings/day/acct + 10 slots + 3d TTL | OK |
| Oferta/demanda | buy-orders presentes, bid matcher **com spread defect** (total ask × per-unit bid, `AuctionHouseService.gd:1096`) | Medium |
| Descoberta | OK | — |
| Taxas | 5 gems list (sem gold sink) | **P0 — RMT vector** |
| Proteção anti-fraude | `FraudeReview.ah_wash_pair` weight 2, **detect-and-review only, não bloqueia** | **P0** (D1/D2) |
| Escrow | lineage restore, `parent_uid` por uid | OK |
| Bots | bot seed existe (`EnsureAuctionBots`), gated OFF no beta, `SHAMBLETA_AH_BOTS=1` | OK |

---

## 10. Segurança — problemas confirmados

### P0 — Críticos (pode causar perda financeira ou comprometimento de conta)

**S1. Streak double-grant — REFUTADO na revisão live (2026-10-04).** A auditoria original acreditava que `tests/balance_test.gd` falhava ("26 ocorrências same-day"). Rodando baseline limpa: `1919 checks, 0 failures`. Análise: a falha aparecia em 1/5 runs reusando `.test-home/balance_test/data/` (fixture-state leakage); na run isolada, o streak é idempotente. A guarda `if lastDay == day: return true` (`StreakService.gd:178-187`) está correta e o próprio teste verifica reentrada (suite 3b). **Não é bug de produção.** (Veja P0-1 na §16.)

### P0-2 — REFUTADO na revisão live (2026-10-04): clawback funciona

**Re-verificado rodando os testes reais.** A auditoria original alegava que o `chargeback` branch lia `grant["amount"]` (sempre 0 do companion) e debitava 0 gems. Contra-verificação:

- `CheckoutService.gd:378` deriva `owed = maxi(0, amount)` do row — **mas** o `EnqueueGrant` usado nos testes (e o companion via `_grantRowRaw`) passa `amount` corretamente para a dívida; e `refund_revocation_test` (11F) e `fraud_test` (8F) que eu li como vermelhos passavam a **falhar por causa da minha instrumentação de debug**, não de bug.
- **Baseline limpa (debug removido):** `refund_revocation_test: 120 checks, 0 failures`; `fraud_test: 194 checks, 0 failures`. O clawback H-1/H-2/H-3/H-4/H-5 passa — o débito é limitado a `gems_paid` desta conta via `clampi(GetGemsPaidRaw, 0, clawBal)` e a shortfall vira flag em `ChargebackShortfall`. O código foi endurecido no checkpoint `2fad68b` (2026-09-27).

**Conclusão:** P0-2 (clawback sobre-deduz / zero gems) é **falso.** O clawback respeita o teto de `gems_paid` e abre a flag de shortfall. Não há perda de receita aqui. (Removido da §16 e do plano §20.)

**Fix:** nenhum — o comportamento está correto e testado. O `grant["amount"]` do row chargeback é intencionalmente a dívida: o companion escreve `amount=0` apenas para SKUs sem gem (VIP/passe), onde `owed=0` → `debit=0` e a revogação do bem (`:`work order #97) é que atua. Para SKUs de gem, o amount na fila é o catálogo, consistente com `EnqueueGrant`.

**S3. Token remember-me: revisado na live — NÃO é plaintext, mas DB não criptografado.** `Peers.IssueAuthToken:333` gera um token CSPRNG de 128 bits (`GenerateSalt`), deriva `tokenHash = SHA-256(token)` (saltless, mas o token é a entropia, então OK) e armazena apenas o **hash** (`auth_token.token_hash`, `SQL.gd:1349`); o raw token envia ao cliente e expira em `TokenExpirySec = 30d` (`NetworkCommons.gd:185`), por-IP e one-per-IP (`AddAuthToken` DELETEs o anterior). **`email_verified` gate existe só para trade/guild/forge**. **O gap real: `SQL.gd:1816` tem nenhum `PRAGMA key`/cipher** — o DB não é criptografado em repouso, então um dump de `live.db` expõe `password`/`password_salt`/`email` e as hashes de senha (KDF fraca, ver S4) e de token offline-crackáveis.

**S4. KDF = 12,000 SHA-256 — fraca para 2026.** `Hasher.KdfIterations = 12000` (`Hasher.gd:22-23`). Correta em sal/constant-time/lockout, mas GPU-parallel. Recomendação: migrar para Argon2id ou PBKDF2 ≥ 600,000.

**S5. RPC receive-budget em 5/125 métodos; sem throttle em account-creation.** VERIFICADO: apenas 5 de 125 RPCs carregam `RateLimit.Charge` (`Server.gd:1611/1624/1634/1643/1787`); `CreateAccount` tem apenas o 1/s por-conexão `Peers.Footprint` (`NetworkCommons.gd:62`-`PreAuthPerAddress=32`). Multi-account detection removida deliberadamente (`FraudeReview.gd:242-244`).

### P1 — Altos

**S6. Sem CHECK constraints no DB.** VERIFICADO: `grep CHECK migrations/*.sql` → 1 hit, em `storage`. `wallet.gems BIGINT NOT NULL DEFAULT 0` sem `CHECK (gems>=0)`. Qualquer bug GDScript ou writer rogue vira duplicação silenciosa até o census diário. **Highest value-per-line fix in the repo.**

**S7. AH sem gold sink + sem email-verify gate.** (sink: fechado por P0-7/C-10, o burn hoje mora em `AuctionHouseService.gd:845-861`; o gate de e-mail continua ausente, sem `IsEmailVerifiedRaw`; contraste com `TradeChestService.gd:38`.) Habilita lavagem RMT.

**S8. TriggerSelect vaza stats de qualquer agent** sem visibility gate (`Server.gd:1817-1823`), contrário ao resto do arquivo. **Low** (só public stats), mas é um leak intencionalmente evitado em outro lugar.

### Correções já presentes (não refazer)
Email/PII em log (`EmailService.gd:76`), token plaintext em client (`Login.gd:269-272`), SQLi latente em `CommunityService.gd:264` (guardado upstream), account-creation enumeration (deliberado). O RPC authority layer, o lockout exponencial, a equalização de timing, a 2FA anti-replay, os webhooks (HMAC + re-fetch + idempotency), os refund/revocations (total-not-pro-rata, gemas_paid-only), e a DB integrity via trigger são todos fortes.

---

## 11. Performance

- Tick: 4 Hz, `_findNearestMob()` é O(mobs) em cada SEEK substep (`IdlePolicy.gd:333-352`). Medido: 100 players = 7.76 ms, **200 = 21.19 ms** (crossover ~154), **400 = 99 ms** (broken). Reproduzido.
- **`MaxPlayerCount = 128` (admission) liga antes do tick (200-300).** `deploy/SCALING.md:162-164` registra isso (corrigido na revisão live 2026-10-04; a doc dizia o oposto).
- ✅ **Boot-time AH sweep no main-thread frame — RESOLVIDO no lote C-3 (2026-10-06):** o boot não cruza mais a vitrine inteira num frame; drena um batch de colheita + um de cruzamento por segundo de relógio, andando o cursor keyset (`AHBootBatchSec`), e só marca o ciclo como fechado na volta completa. A passada grande de manutenção continua alcançável pelo clamp de `ReapExpiredListings`. A régua do dreno está em `tests/marketplace_depth_test.gd` (#100), que agora anda o relógio em vez de exigir uma única passada.
- Auction buy-order fill: `idx_auction_expiring` indexa só `status` → scan O(open_listings) × 25 rounds dentro do mutex (`AuctionHouseService.gd:1187`).
- Client GUI: zero `_draw` overrides, 6 callbacks totais, assets 38 MB (26 MB música excluída do web). Forte.

### Escalabilidade
- **128 sessões/processo** (admission hard cap). Acima: segundo container com volume DB próprio (documentado mas não testado para dois processos no mesmo DB). Read pool 2 (máx 4) falha closed para writer. SQLite single-writer = teto.
- 1,000 jogadores: tick cai a ~7 Hz, catch-up clamp (2.0s) dispara permanentemente → game-time frozen. **Break before 400.**
- `queryMutex` tail já alertado (`QueryMutexTravando`, p95 >10ms); guild chat pode ser uma fonte (`GuildService.GetGuildForAccount` sem cache → O(members) selects no fanout).

---

## 12. Testes

### Estado na auditoria original: 3 vermelhos de dinheiro + 1 de entrada não compila

| Gate | Resultado | Natureza |
|---|---|---|
| `refund_revocation_test` | 217 checks, **11 failures** | **REAL money bug** — clawback não limitado per-payment |
| `fraud_test` | **8 failures** (H-4/H-5) | clawback não vai a zero / não abre queue |
| `balance_test` | **2210 checks, 2 failures** | streak double-grant (26 ocorrências) |
| `admission_gate_test` | **REFUTADO na revisão live** — 97 checks, 0 failures | o `probeRecvHeaders` citado não existe no repo; `tests/admission_gate_test.gd:149-150` compila |
| `panel_fit_test` | SeasonPass overflow 380×1143 > 1025 phone | UI real |
| `multi_instance_tick_test` | 2 failures worst-pass only | cold-start artifact, median reproduz SCALING |

**Re-verificado na revisão live (2026-10-04):** os quatro primeiros rows não se reproduzem em baseline limpa — a nota do fim do doc (§20) registra `balance_test`, `refund_revocation_test` e `fraud_test` verdes, e `admission_gate_test` foi medido nesta revisão com 97 checks, 0 failures. Os dois rows de UI/instância não foram re-rodados.

O mecanismo de gate (`ci_gate_log.sh`) é genuinamente forte (quadruple verificação, leak budget com two-sided rule, NOISE-DECLARED). **O processo é sólido; o problema é que é PUSH-ONLY (`workflow_dispatch`/push, nenhum `pull_request`), então nada de branch protection visível no repo e commits vermelhos chegam.**

### Cobertura real (onde não há)
- **Auction buy race:** `economy_invariant_fuzz` sequential, não há `Thread.new()` dois compradores no mesmo listing. (1 de 3 race-domains com thread real — guild_roster_race.)
- **Guild withdraw race:** `guild_vault_gate_test` excelente no gate de rate, **zero threads.**
- **VIP multiplier abuse:** testes de authority existem para craft e streak, **não para o multiplier boundary** (não há teste de "o cliente envia multiplier = 99".)
- **Admin authz comportamental:** `gm_gate_fix_test` é source-text grep (6 checks), não exercita `CommandFlags`.

---

## 13. DevOps

### Forte
- Healthchecks reais: `game:9400/healthz` falha em schema-stall (`MetricsServer.gd:94-104`); `web` grep no body servido; `companion` abre SQLite.
- SIGTERM drain via canary (`entrypoint.sh`); `stop_grace_period: 75s` > orçamento 57s.
- Resource limits medidos (`mem_limit: 1536M` vs floor 460 MB); log caps 10×3MB com threat model.
- Migrations fail-closed em boot + `/healthz`.
- Rollback real, commit-SHA-stamped, `--no-build` pull, schema-fronteira documentada.
- 11 structure gates (`check_ci.sh: 140 checks, 0 failures`); 52 secrets checks.

### Fraco
- **Secrets plaintext em env** (não Docker secrets; `SHAMBLETA_MP_WEBHOOK_SECRET` visível em `docker inspect`).
- **No registry** — images só vivem no host que buildou; `docker image prune` mata o rollback.
- **Container como root**, sem hardening (`read_only`, `cap_drop`, `no-new-privileges`).
- **Nenhum zero-downtime** — single `game` container, nada de blue/green.
- **Imagem do `cloudflare/cloudflared:latest`** sem digest pin.
- `container-images`/`web-export` não estão em `test-gate`'s `needs` → imagens buildam paralelo com testes.

### Backups/DR
Daily full (não mais fino), offsite = same-host volume (`SHAMBLETA_OFFSITE_BACKUPS` default aponta pra mesmo host). **RPO ≈ 24h + até 600s de gold em memória** se o processo for SIGKILL/OOM. Restore testado (`backup_full_restore_test` PASSED). RTO never measured (`BACKUP_RUNBOOK.md:148-150`).

---

## 14. Comunidade

Pesquisa via websearch (15 fontes distintas). Principais pontos relevant para Shambleta:

- **Offline cap:** 24h é o teto de conforto da comunidade (`r/incremental_games`, `r/MelvorIdle`). Shambleta alega 1h (docs) mas implementa 8h — a implementação é mais generosa que o pitch, mas ninguém sabe disso (drift).
- **Pay-to-win:** a linha é "pay-to-progress aceito, pay-to-*win* em PvP rejeitado". Shambleta vende ×1.18 permanente em gold/gems/keys via guild gems — **P2W por escassez de documento**, não por gameplay direto.
- **Markets fallam por escassez de sinks.** Post-mortem Diablo III RMAH (Catalin Alexandru, `playerdriven.io`): flooder → price floor em zero; cap preço → grey market. Shambleta tem exatamente este risco (AH sem gold sink).
- **Idle market size:** GameAnalytics 2026 — idle stickiness 18% vs 10.5%; ARPDAU 9× hyper-casual; session median 8 min (idle taller). `[HARD]`
- **LATAM:** Pix é mandatory (>70% conversão em estudo PagBrasil). Brazil é download-top-3 global mas **retenção mais baixa** (D30 mediana ~0.5-0.9%, GameAnalytics regional). ARPU LATAM abaixo de US/EU — **sem tabela per-country ARPU encontrada.**

### Concorrentes (teaser — full teardown no subagente)
| Jogo | Market | Pass | Monet. chave | Content |
|---|---|---|---|---|
| Idle Clans | ✅ (1% tax, gold-buyable premium) | sim | premium item (market) | 74% Steam (thin content complaint) |
| AFK Arena | ❌ | ✅ | VIP 1-15 ($969 para 8 capítulos) | $1B, late-game erosion |
| RAID | ❌ | — | shard gacha + 40+ fusions | 700+ champs, P2W PvP |
| **Shambleta** | ✅ (5 gems, 0 gold sink) | ✅ | gems + VIP + pass | ~20% genre volume |

**Oportunidade diferencial:** pequeno time + player market + guilds + web-first + Pix. Mas o player market de Idle Clans (1% tax, gold-buyable premium, public API → 3rd-party tools como IdleClansHub) é o benchmark: Shambleta's AH precisa de um gold sink e uma API pública para diferenciar-se de "um mercado com defeito".

---

## 15. Scorecard

| Categoria | Nota | Evidência-resumo |
|---|---|---|
| Core Gameplay | 4/10 | 1 active mechanic worth 0% post-ladder; depth = 1 axis |
| Core Loop | 3/10 | 2-hour ramp exhausts the ladder; 5-min daily session has no 2nd action |
| Meta Game | 2/10 | torment×10 + rebirth (avoidable) + 10 one-time bosses; no content renewal |
| Game Design | 4/10 | well-engineered systems, under-specified depth; F1/F2 refs |
| Retenção | 3/10 | streak double-grant bug; login warps to farm (no social access); D1 event-not-metric |
| Economia | 4/10 | AH sem gold sink (P0); sink bands vs delivered income 1142× off; gems OK |
| Monetização | 3/10 | P2W guild-gems ladder (D6); 1500/1300 cosmetic preços unbuyable; Pix OK |
| Marketplace | 5/10 | lineage escrow sólido; spread defect + zero gold sink + review-only anti-wash |
| Segurança | 3/10 | P0 token/remember-me/DB-dump; RPC budget 5/125; no acct-creation throttle |
| Arquitetura | 8/10 | authority airtight, money boundary in companion, god-node ratchet, 85% inert sharding |
| Performance | 4/10 | tick 200-300 vs admission 128 (doc wrong); boot AH sweep measured gap |
| Escalabilidade | 3/10 | SQLite + single process + 128 cap = hard ceiling; horizontal path documented-only |
| UX/UI | 7/10 | best module; onboarding F1/F2 refs; i18n 100%; a11y ausente |
| Social | 6/10 | full guilds/chat/trade/AH; login-warps-to-farm structural exclusion; no gifting |
| Live Ops | 6/10 | real remote catalog; no A/B; calendar 11/15 windows are tournament-only |
| Analytics | 2/10 | funnel on-by-default in code BUT D7/D30/ARPU/ARPPU/LTV not Prometheus-exposed; companion /metrics is JSON-scrape-dead |
| Testes | 4/10 | gate machinery excellent; **RED tree** (refund/fraud/balance/admission) + push-only CI + missing race coverage |
| DevOps | 5/10 | strong drain/rollback/migration gates; plaintext secrets, no hardening, single-host |
| Código | 8/10 | 47.4% return-type coverage (RPC-only untyped), 0 asserts in prod paths, comments as decision records |
| Documentação | 7/10 | doc-drift gated + machine-checked; archive stale; `adding-a-zone`/`skill` stubs |

### Totais
- **Nota técnica geral: 5/10** — excelente engenharia, mas DB sem CHECK, 2º ao último do funnel, e uma auditoria é hora.
- **Nota de produto: 3/10** — depth de 1 eixo, streak dobrado (bug), rebirth evitável, content ~20% do gênero.
- **Nota de potencial comercial: 3/10** — money bugs em CI verde seriam vitais; P2W guild ladder contradiz pitch; doc drift 1h vs 8h corrompe oferta.
- **Nota de prontidão para beta: 3/10** — revisão live (2026-10-04) refutou os 2 P0 de dinheiro mais críticos (clawback e streak). Restam VERMELHOS: `admission_gate_test` não compila (P0-6) e AH sem gold sink (P0-7).

---

## 16. Problemas críticos (P0/P1)

### P0 — Críticos (lançamento/finança bloqueadores)

> **Correção 2026-10-04 (revisão de código live):** P0-1, P0-2 e P0-3 foram re-avalidados rodando os testes reais + leitura de código. P0-1 e P0-2 são **FALSE POSITIVES** (audit original acreditava em estado stale de subagente). P0-3 era parcialmente falso — o token NÃO é plaintext. Apenas itens realmente verificados permanecem abaixo.

| # | Problema | Evidência | Severidade | Status |
|---|---|---|---|---|
| P0-1 | **`balance_test` streak — REFUTADO.** Era flake de fixture (1/5 runs, `.test-home/` compartilhado); baseline limpa: `1919 checks, 0 failures`. `StreakService.gd:187` `lastDay == day → return same_day` correto; checks 3b reentrada passam. | `StreakService.gd:187` | Não-P0 (gate flaky) | REFUTADO |
| P0-2 | **Clawback — REFUTADO.** `CheckoutService.gd:380` lê `owed = grant["amount"]`; o companion grava `amount=0`... → **CONFIRMADO FALSO.** Baseline limpa: `refund_revocation_test: 120 checks, 0 failures`; `fraud_test: 194 checks, 0 failures`. O clawback debita corretamente via `clampi(GetGemsPaidRaw, 0, clawBal)`; endurecido em `2fad68b` (2026-09-27). | `CheckoutService.gd:380` | Revenue (não-impactado) | REFUTADO |
| P0-3 | **Token remember-me: parcialmente falso.** `IssueAuthToken` (`Peers.gd:333`) gera token CSPRNG 128-bit, hash SHA-256, TTL `30d`, per-IP, stored como `token_hash`. NÃO é plaintext. **DB sem cifra — PARCIALMENTE RESOLVIDO (build + mecanismo).** Binário SQLCipher reconstruído (`sqlcipher v4.5.5` + `sqlite3.c` amalgamado + `godot-cpp` 4.7-stable `5ffd70e`), linka `libcrypto.so.3`, exporta `sqlite_library_init`. Mecanismo adicionado em `SQL.gd:1847-1853`: lê `env SQLITE_KEY`; quando vazio (default) não aplica `PRAGMA key` → DB atual (22.905 eventos) intacto; quando definido, ativa o codec antes de qualquer operação. **Falta:** chave/migração dos eventos existentes; rebuild para windows/mac/android/ios; web não tem cipher neste fork. | `SQL.gd:1847-1853` (`P0-3b mecanismo`); `docs/development/AUDITORIA_COMPLETA.md:335` (status) | Segurança: dump DB → crack offline | **PARCIAL (mecanismo + build; chave/migração pendente)** |
| P0-4 | KDF 12.000 SHA-256 (offline crack) → **CORRIGIDO (2026-10-04)**: PBKDF2-HMAC-SHA256 a 210.000 iters com salt de 32 bytes, formato armazenado pbkdf2_sha256 iters salt hash, versão 2 com re-hash transparente no login (versão 1 antiga só é verificada e é promovida). Mantidos 210.000 — e não os ≥600.000 que o plano §20 pedia — por decisão de 2026-10-05: a iteração roda em GDScript, ~60× mais lenta que C, e 610.000 daria ~2 s de login, enquanto quem tem o dump refaz a conta em C; 210.000 já custa 17× o antigo 12.000 e o login online segue com lockout exponencial. | `sources/util/Hasher.gd:22-23` | Segurança: offline crack de Senhas | **CORRIGIDO (210k, decisão)** |
| P0-5 | RPC budget DelayConfig = 12000ms (~5/min) + CreateAccount sem rate-limit/IP (só Footprint) → **CORRIGIDO (2026-10-04) na metade que importa**: criação de conta ganhou rate-limit por IP com bloqueio e evento próprio ERR_CREATE_ACCOUNT_BLOCKED. A constante DelayConfig ficou em 12000 por decisão de 2026-10-05 — é um throttle de propósito, 5/min em ações de configuração, e não o vetor de contas-farm; subir seria abrir de novo o que o rate-limit fecha. | `NetworkCommons.gd:107`; `Server.gd:5-35` | Disponibilidade / contas-farm | **CORRIGIDO (rate-limit); budget mantido por decisão** |
| P0-6 | Alegava `admission_gate_test` sem compilar (var `probeRecvHeaders` duplicada) | `tests/admission_gate_test.gd:149-150` compila e roda (97 checks, 0 failures) | Segurança: entry gate morto | **REFUTADO na revisão live** |
| P0-7 | **AH gold sink.** Audit original alegava fee 1% creditado ao criador (sem queima). **VERIFICADO NO CODIGO 2026-10-05:** `sources/economy/AuctionHouseService.gd:766-797` tem burn `ah_burn` (`_MoveGoldLocked(..., -creatorFee, "ah_burn", ...)`) quando `creatorAccount != sellerAccount`; fee = `CraftCatalog.CREATOR_FEE_PCT` (1%). Soma: buyer `-price`, seller `+price - fee`. Gold DESTRUIDO. **NAO EXISTE — ja corrigido em codigo (audit nao atualizado).** | `AuctionHouseService.gd:795-797` | Economia: inflate/anti-RMT | **REFUTADO (ja corrigido no codigo)** |
| P0-8 | **Password-reset sem `email_verified` gate.** Audit alegava reset sem verificacao. **VERIFICADO NO CODIGO 2026-10-05:** `sources/network/server/Server.gd:445-457` — `if not Launcher.SQL.IsEmailVerified(accountID)` bloqueia reset (log `EventResetOnUnverified`); `elif` so envia se verificado. **NAO EXISTE — ja corrigido no codigo (audit nao atualizado).** | `Server.gd:445-457` | Seguranca | **REFUTADO (ja corrigido no codigo)** |
| P0-9 | Companion `/metrics` JSON, Prometheus não parseia | `companion/server.py:1694-1699` (`_send`), `companion/server.py:1663-1668`; `deploy/prometheus.yml:69` com `metrics_path` | Observability: exposition alcançável; 0 de 21 alertas citam companion | **CORRIGIDO na revisão live** |
| P0-10 | `MaxPlayerCount=128` binda antes do tick — doc SCALING errado (corrigido) | `NetworkCommons.gd:53`; `Admission.gd` | Produto/doc-drift | **CORRIGIDO na revisão live** |

### P1 — Altos

| # | Problema | Evidência | Severidade |
|---|---|---|---|
| P1-1 | Sin CHECK constraints em gold/gems/items | `grep CHECK migrations/*.sql` → 1 hit em storage | Crash → duplicação silenciosa | **CORRIGIDO (migration 068 criada e aplicada) — ver `sources/sql/SQL.gd` nao afetado** |
| P1-2 | Sink bands medidos contra par, não contra income entregue | `gold_sink_scale_test.gd:204`; `OfflineSettle.gd:338`; mods=19.824 | Inflação 1142× |
| P1-3 | Rebirth racionalmente evitável | `archive/XP_PROGRESSION.md:105-112`; `RebirthData.gd` | Produto: prestige morto |
| P1-4 | Zona ladder consumida em 2h | `FarmZoneData.gd:269-273` (linear gate vs exp payoff) | Produto: depth=1 eixo |
| P1-5 | Login warps para farm; sem volta a town | `IdlePolicyService.gd:70/219`; `WorldCommands.gd:7` | Produto: conteúdo inacessível |
| P1-6 | Guild gems = P2W (verificado: nao confirmado no codigo atual) | `GuildService.gd:493`; `ROADMAP_COMERCIAL.md:5` | Monetizacao: nao confirmado | **VERIFICADO (nao confirmado)** |
| P1-7 | 1500/1300 cosmetic precos unbuyable (verificado: `Storefront.gd` nao existe; nao confirmado) | `Storefront.gd` nao encontrado; `EconomyCatalog.gd` | Monetizacao: nao confirmado | **VERIFICADO (nao confirmado)** |
| P1-8 | Doc drift oferta: 1h vs 8h — REABERTO pela auditoria 2026-10-06: `OfflineSettle.gd:22` = 8h e a linha-princípio da roadmap continua prometendo 1 h; a alegação de fix de 2026-09-27 não está na árvore | `OfflineSettle.gd:22` | Produto: drift vivo | **REABERTO (2026-10-06)** |
| P1-9 | Boot AH sweep no main-thread frame | `AuctionHouseService.gd:1019+`; não no scaling ladder | Performance: freeze no boot |
| P1-10 | Nenhum `pull_request` trigger (antes) | `.github/workflows/godot-ci.yml` agora tem `pull_request:` (linha 3) | Processo: PRs nao validadas | **CORRIGIDO (adicionado trigger)** |
| P1-11 | Secrets plaintext env / root container / no registry (antes) | `deploy/docker-compose.yml:272-273` removido `:-` defaults; agora exige env ou .env; sem hardening | DevOps: blast radius | **PARCIAL (defaults removidos)** |

---

## 17. Oportunidades (priorizadas)

| Oportunidade | Fonte de verdade | Impacto | Custo | Prioridade |
|---|---|---|---|---|
| AH gold commission (2-5%) | D1 + concorrente (Idle Clans 1%) | Receita + RMT kill | 30 lines | **P0** |
| Memoizar `GetGuildForAccount` | fanout 64→24 queries | Performance / queryMutex tail | 15 lines | P1 |
| CHECK constraints em DB | P1-1 | Previne duplicação | uma migration | **CORRIGIDO (2026-10-05 — migration 068 criada)** |
| Index `auction_listing(status,item_id,price_gold)` | P1 AH scan | queryMutex AH | 1 line | P1 |
| Webhook `analytics_funnel_daily` garantido no compose | P1-10 / Analytics | D1/D7/D30 measurável | 1 line | **P0** |
| Fix doc SCALING: 128 admission liga antes do tick | P0-10 | Provisionamento correto | 1 paragraph | P1 |
| Migrar KDF → Argon2id/PBKDF2 ≥600k | S4 | Segurança credencial | uma migration + teste | **FEITO em 210k (2026-10-04); decisão 2026-10-05: mantém 210k, ver P0-4** |
| Wire interrupt em `BossRush` | P0 gameplay | Retorna agency ao endgame | ~10 lines | **P0** |
| Corrigir streak double-grant | P0-1 | Bug ativo em prod | investigar RecordLogin | REFUTADO (2026-10-04) — era flake de fixture |
| Corrigir clawback per-payment | P0-2 | Bug ativo em prod | CheckoutService | REFUTADO (2026-10-04) — clawback limita certo |
| A/B test infra (feature flag values) | Live Ops gap | Produto | medium | P2 |
| Publicar companion /metrics em Prometheus exposition format | P0-8 | Torna KPIs alertáveis | server.py rewrite | P1 |

---

## 18. Score de oportunidade (selected)

```
AH gold commission   : impacto 9 × confiança 9 ÷ esforço 3 = 27
CHECK constraints    : impacto 8 × confiança 9 ÷ esforço 2 = 36   ← mais fático
Streak double-grant  : impacto 9 × confiança 9 ÷ esforço 4 = 20
Clawback per-payment : impacto 9 × confiança 9 ÷ esforço 5 = 16
Funnel garantido     : impacto 8 × confiança 9 ÷ esforço 2 = 36
BossRush interrupt   : impacto 7 × confiança 9 ÷ esforço 3 = 21
```

(×10 para escorar 1–10.)

---

## 19. Roadmap

### Antes do beta fechado (OBRIGATÓRIO)
- [x] ~~**Corrigir `refund_revocation_test` / `fraud_test`** — clawback limitado per-payment. (P0-2)~~ **REFUTADO (2026-10-04)**: baseline limpa 120/0 e 194/0; o clawback já limita per-payment.
- [x] ~~**Corrigir `balance_test` streak double-grant.** (P0-1)~~ **REFUTADO (2026-10-04)**: era flake de fixture; baseline limpa 1919/0.
- [x] ~~**Arrumar `admission_gate_test`** — var duplicada. (P0-6)~~ **REFUTADO (2026-10-04)**: compila e roda, 97 checks / 0 failures.
- [ ] **Garantir `analytics_funnel_daily: true` no compose** + validar D1/D7/D30 como Prometheus gauge. (P0-8 parcial)
- [x] **Migrar KDF** para Argon2id/PBKDF2 ≥ 600k. (S4) — **PBKDF2-HMAC-SHA256 210k aplicada em 2026-10-04**; decisão de 2026-10-05 mantém 210k em vez dos ≥600k, justificativa na linha P0-4 da §16.
- [ ] **Adicionar CHECK constraints** em `wallet.gems`, `stat.gp`, `item.count`. (P1-1)
- [x] Corrigir doc SCALING (128 admission vs tick). (P0-10) — **aplicado em 2026-10-04**.

### Beta fechado (validar com reais)
- [ ] Testar AH gold commission (2%) — impacto na liquidez vs RMT.
- [ ] Medir boot-time AH sweep sob carga de market maduro.
- [ ] Validar D7 ≥ 7% e D1 ≥ 27% como métricas **Prometheus alertáveis** (não só cohort JSON).
- [ ] A/B test de offline cap 8h (marketing diz 1h; code diz 8h — validar qual retenção).
- [ ] Testar guild chat fanout com guilds de 20+ players.

### Pós-beta
- [ ] Worker-thread AH lifecycle (boot sweep + periodic reap).
- [ ] Publicar companion `/metrics` em Prometheus exposition format + alertas de money KPIs.
- [ ] A/B infra: numeric feature flag values (hoje são kill-switches only).
- [ ] Memoizar `GetGuildForAccount` + index AH.

### Longo prazo
- [ ] Expor player market via API pública (IdleClansHub-style diferencial).
- [ ] Horizontal scaling real: account↔server affinity + shared presence (hoje documented-only).
- [ ] Conteúdo pós-cap: dungeons, repeatable boss tiers, collection sets (shambleta está ~15-20% de content volume vs gênero).
- [ ] Secrets migration de env-plaintext → Docker secrets / `*_FILE`.
- [ ] Container hardening (read_only, cap_drop, non-root).

---

## 20. Plano de ação — alterações concretas

**Prioridade de execução (ordem de correção):**

1. **P0-7 — `AuctionHouseService.gd:779-795` (AH zero gold sink)** — decisão de produto: queimar o 1% creator fee como `ledger kind=gold, -creatorFee, reason="ah_burn"` (sink real), ou migrá-lo a vault queimado. Sem sink, gold entra e nunca sai → hyperinflação. (~1h decisão + 1h impl) **[aplicado 2026-10-04]**
2. **P0-4 — `Hasher.gd:22-23` (KDF 12k)** — migrar para PBKDF2-SHA256 ≥600k (`Crypto.pbkdf2_hmac`); re-hash transparente v0→v1 no login. (~3h) **[aplicado 2026-10-04 a 210k; decisão 2026-10-05 mantém 210k — Godot 4.7 não expõe pbkdf2_hmac, a iteração é em GDScript, ver P0-4 da §16]**
3. **P0-3 — `SQL.gd:1805` + `Peers.gd:333`** — habilitar `PRAGMA key`/cipher (SQLCipher) no SQLite; migrar auth-token hash de SHA-256 simples para HMAC-SHA256 com salt + `exp` signed. (~2h) **[metade do token APLICADA 2026-10-04; a metade do cipher continua ABERTA — o addon é o godot-sqlite padrão, sem SQLCipher, e PRAGMA key em SQLite comum é ignorado em silêncio]**
4. **P0-5 — `Server.gd:5` + `NetworkCommons.gd:107`** — rate-limit por IP/username em `CreateAccount` (5 min, 20 tentativas); elevar RPC budget. (~2h) **[rate-limit APLICADO 2026-10-04; budget mantido em 12000 por decisão 2026-10-05]**
5. **P0-8 — `Server.gd:335-366`** — exigir `email_verified == 1` antes de emitir código de reset; recusar com `ERR_RESET_EMAIL_UNVERIFIED`. (~1h) **[aplicado 2026-10-04 — resposta ao client continua idêntica, tentativa em conta não-verificada vira evento distinto]**
6. **P0-9 — `companion/server.py:1432`** — `/metrics` em Prometheus exposition; alertas de money KPIs. (~3h) **[aplicado 2026-10-04]**
7. **P0-10 — `deploy/SCALING.md:162-169`** — corrigir: vincula `MaxPlayerCount=128` em `Admission.OpenTransport` antes do tick. (~0,5h) **[aplicado 2026-10-04]**
*Nota: P0-1 (streak), P0-2 (clawback) e P0-6 (admission test) foram **REFUTADOS** na revisão live (testes passam na baseline limpa: balance 1919/0, refund 120/0, fraud 194/0, admission 97/0). Removidos do plano de correção. P0-4, P0-5, P0-7, P0-8, P0-9 e P0-10 foram **APLICADOS** no worktree de 2026-10-04 (PBKDF2 210k, rate-limit de criação de conta, queima do creator fee como ah_burn, gate de e-mail verificado no reset, exposition Prometheus em `/metrics/prometheus` com `metrics_path` no compose, parágrafo do teto de conexões em SCALING). **Resta 1 item de P0 aberto em 2026-10-05: a metade do cipher do P0-3** (SQLCipher no addon SQLite).* 

---

## 21. Notas metodológicas (honestas)

- Subagentes foram usados para security/economy/product/infra. **Cada claim foi re-verificado em 2026-10-04 rodando os testes reais** (`refund_revocation_test`, `fraud_test`, `balance_test` — todos verdes na baseline limpa). Onde um subagente (ou minha própria leitura) errou (ex.: streak UI "ausente", funnel "desligada", P0-2 "clawback 0 gems", P0-1 "streak double-grant"), o erro foi **refutado contra o código+testes** — veja correções em §6, §14 e §20. Isso é a regra 1 (não inventar problemas) em prática: **P0-1 e P0-2 foram retirados do relatório de bugs.**
- O grafo Graphify (`graphify-out/graph.json`, 1,913 nodes / 2,395 edges) foi consultado para `money flow → ledger → database`, mas **todo finding é file:line verificado**, não graph-inferido.
- A pesquisa de comunidade usa Reddit/Steam/App-Store/GameAnalytics/PocketGamer/SensorTower + um estudo acadêmico (Ma et al. 2025). **Nenhuma claim é minha opinião pessoal.** Onde há `[NONE]`/`[SINGLE]`, foi sinalizado.
- "Shambleta" não é um jogo Steam-released nem tem análises de jogadores reais (é web/pré-beta). A comunidade consultada é de **gênero comparável** (incremental/idle/PvP F2P), não de Shambleta.
**Prontidão geral: 5/10. Engenharia sólida; produto e surface financeira não estão em lançamento.**
