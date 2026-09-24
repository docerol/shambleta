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
- [x] **Fatia 2 do EconomyService**: `CheckoutService.gd` (305 linhas: grant queue C1 `EnqueueGrant`/`ProcessPendingGrants`/`_ApplyGrantRaw`, VIP F4, checkout intent sandbox/gateway, refund CDC art.49) + `SeasonService.gd` (181 linhas: E2 create/close, 4 snapshots, `TickSeasonLifecycle`, `SettleSeasonPrizes`, trava T5 `SeasonsEnabled`) + `GuildService.gd` (348, já feita); `EconomyService.gd` 3839→3292. Mesma composição da fatia guild (back-reference `_eco`, MESMO `settleMutex`/helpers raw → locking idêntico; desacoplamento de mutex NÃO foi necessário — pré-requisito de suíte verde cumprido: baseline 1304 checks/0 failures). Wrappers mantidos (callers Server/WorldCommands/Gui/testes não mudam)
- [x] **Fatia 3 do EconomyService (passe)**: `PassService.gd` (438 linhas: Fase C completa — PT/multiplicadores, missões d/w/m via ledger+telemetry, `GetSeasonPass`, `ClaimMission`, `ClaimPassReward`, `SkipPassLevel`, `_AutoClaimPass`); `EconomyService.gd` 3292→2895; mesma composição `_eco` (settleMutex único), wrappers mantidos (Server RPC/SeasonPass/testes/hooks)
- [x] **Fatia 4 do EconomyService (auction house)**: `AuctionHouseService.gd` (301 linhas: E2 completa — `AHOpenCap`/`BuyAHSlot`/`HighlightListing`/`BrowseListings`/`ListItemForSale`/`BuyListing`/`CancelListing`, escrow em lots, taxa flat queimada, creator fee 1% Fase H §7 + S2 bot seed `AHBotsEnabled`/`EnsureAuctionBots`/`_trySeedAuctionBots`); `EconomyService.gd` 2895→2649 (−246). Movido verbatim (diff conferido programaticamente: única diferença = cabeçalho de seção), `_eco.` apenas nos 7 helpers raw compartilhados (`settleMutex`, `_LedgerAppendLocked`, `_AccountIDForCharacterRaw`, `_ItemCountRaw`, `_CharGoldRaw`, `_UIDList`, `_GrantStackRaw`); `AHBotsEnabled` ficou estático no serviço + wrapper estático (testes chamam por instância); callers WorldCommands/testes intocados
- [x] **Fatia 5 do EconomyService (loja)**: `ShopService.gd` (273 linhas: baús por gems da beta GUI `BuyChests` + Fase B completa — `ShopDay`, rotação determinística `_RotatedDailyOffers`/`_DailyRow`, ofertas one-time de boss/finale, `GetDailyShop`/`RerollDailyShop`/`_DoReroll`/`BuyDailyOffer` + R2 vendor gold `GetVendorState`/`BuyVendorOffer`); `EconomyService.gd` 2649→2432 (−217). Verbatim conferido por diff programático; `_eco.` em 6 helpers compartilhados; `_DailyRow`/`_DoReroll` viraram wrappers privados porque a Fase E (ads) ainda chama; `GetEconomyState` continua agregador em `EconomyService`
- [x] **Regressão silenciosa da Fatia 1 caçada e corrigida**: consts movidos p/ `EconomyCatalog` deixaram de resolver quando acessados *via instância* — `economy.CONST` estoura "Invalid access to property or key" e o GDScript **aborta a função no meio**. 9 acessos em `tests/IdleTests.gd` (3 suítes paravam antes da metade: `SuiteEconomyShop`, `SuiteDailyShop`, `SuiteArena`) → trocados p/ `EconomyCatalog.*`; 1 acesso real de produção em `Server.WatchAd` (`Launcher.Economy.AD_AFK2X`) → o painel de AFK nunca era atualizado no 2× → corrigido. Varredura programática do repositório inteiro: 0 restantes
- [x] **Fatia 6 do EconomyService (forja de itens)**: `ItemForgeService.gd` (406 linhas: sinks de item `CorruptItem`/`CubeUpcycle`/`SalvageItem` + Fase H crafting `SubmitCraft`/`ApproveCraftSubmission`/`RejectCraftSubmission`, com budget de raridade, norma de nome + edit-distance anti-duplicado e aprovação manual); `EconomyService.gd` 2432→2070 (−362). Verbatim conferido por diff programático (ranges 1038–1236 + 2239–2431); `_eco.` em 6 helpers compartilhados (`settleMutex`, `_get_settle_mutex`, `_LedgerAppendLocked`, `_AccountIDForCharacterRaw`, `_CharGoldRaw`, `_GrantStackRaw`); wrappers `CorruptItem`/`CubeUpcycle`/`SalvageItem` preservam o arg default `forceOutcome`/`forceResultID` usado pelos golden tests
- [x] **Fatia 7 do EconomyService (progressão de boss)**: `BossProgressionService.gd` (372 linhas: rebirth B+C — `GetRebirthMults`/`AddEssence`/`BuyRebirthUpgrade`/`Rebirth`/`GetRebirthState` + cache de favores por char, escada de boss — `GetBossState`/`ChallengeBoss`/`SettleBossResult` com luta ao vivo e fallback de sim, D2 — `SetTorment`/`BuyBossKey`/`RunBossRush`, e `SpendBossKey`); `EconomyService.gd` 2070→1757 (−313). Verbatim conferido por diff programático (ranges 186–457 + 1057–1143); `_eco.` em 9 compartilhados (`settleMutex`, `_get_settle_mutex`, `_LedgerAppendLocked`, `_AccountIDForCharacterRaw`, `_CharGoldRaw`, `GrantBossKey`, `GuildSettlePoints`, `_PassMilestoneCredit`, `_RebirthVitrine`); `_NamedSeasonBoard` ficou no core (é apresentador de board, chamado por R3) — vai com F10; `boss keys` (coluna do char + espelho no ledger) permanece no kernel
- [x] **Fatia 8 do EconomyService (monetização de janela)**: `AdsCosmeticsService.gd` (237 linhas: Fase E rewarded ads — `_AdDayStart`/`AdViewsToday`/`_ValidAdToken`/`_AdAllowed`/`_RecordAdView`/`WatchAd`/`IsAfkAdArmed`/`ClaimAdChest`/`RerollDailyShopAd`/`ClaimAdBossKey`, com rate-limit diário e token assinado — e Fase D cosméticos/entitlements — `HasCosmetic`/`GrantCosmetic`/`GetCosmetics`/`Equip`/`Unequip`/`BuyCosmetic`, backfill de títulos de suporte, `_RebirthVitrine` e `EquippedTitleLabel`); `EconomyService.gd` 1757→1601 (−156). Verbatim conferido por diff programático (range 1036–1260); `_eco.` em 5 compartilhados (`settleMutex`, `_LedgerAppendLocked`, `_DailyRow`, `_DoReroll`, `GrantBossKey`); `CosmeticLabel` permaneceu **static** no wrapper e passou a chamar `AdsCosmeticsService.CosmeticLabel` via `class_name` (contexto estático não enxerga campo de instância — `Server.gd:538`/`WorldCommands.gd:609` chamam pela classe)
- [x] **Fatia 9 do EconomyService (competição)**: `TournamentArenaService.gd` (320 linhas: Fase F torneios — `ActiveTournament`/`EnsureWeeklyTournament`/`GetTournaments`/`EnterTournament` (entrada em gold queimada + ledger)/`SettleTournament` (prêmio em gems por rank)/`TickTournaments`/`ReconcileDaily`/`RunReconcileJob` — e R4 arena assimétrica — `TickArenaTickets`, `ArenaSetDefense`, `_EnsureArenaLadder`, `ArenaAttack` (resolve determinística + ELO), `ArenaBoard`); `EconomyService.gd` 1601→1340 (−261). Verbatim conferido por diff programático (ranges 701–811 + 1158–1353); `_eco.` em 8 compartilhados (`settleMutex`, `_LedgerAppendLocked`, `_AccountIDForCharacterRaw`, `_CharGoldRaw`, `RunFraudScan`, `TickSeasonLifecycle`, `GrantReferralBonuses`, `TickLiveEvents`); o `ReconcileDaily` continua o agregador do job diário no core por delegação — os 4 domínios que ele coordena seguem wrappers
- [x] **Fatia 10 do EconomyService (comunidade)**: `CommunityService.gd` (372 linhas: R3 live events — framework por timestamp, `weekend_drops`/`smith_week`, `_ApplyLiveEventActivation`/`_ApplyLiveEventMods`/`GetActiveEventsState`/`GetLiveEventMods`/`GetLiveEventCraftingFeeMod`/`GetSeasonBoardsState` + `_NamedSeasonBoard` (nickname/username/tag + título equipado) — conquistas one-time sem wipe (`AchievementProgress`/`GetAchievements`/`ClaimAchievement`, resgate idempotente por PK) — e R1 referral (`GetReferralState`/`SetReferralCode`/`GrantReferralBonuses`) + anti-fraude (`RunFraudScan`, `_FlagOpen`, `FlagMultiAccount`, `_FlagTradeBursts`, `_FlagLevelVelocity`, `_FlagFlipTrades`); `EconomyService.gd` 1340→1052 (−288). Verbatim conferido por diff programático (ranges 613–704 + 747–778 + 1093–1327); `_eco.` em 6 compartilhados (`ActiveSeason`, `GetSeasonBoard`, `EquippedTitleLabel`, `AddGems`, `_get_settle_mutex`, `_LedgerAppendLocked`)
- [x] **Fatia 11 do EconomyService (troca + baús)**: `TradeChestService.gd` (208 linhas: `GetTradeFeeState`/`ExecuteTrade` — escrow all-or-nothing, fee de gems queimado, cooldown + teto diário com VIP — e baús `OpenChest`/`GetChestOdds`/`GetChestOddsForCharacter`/`GetChestPityStatus`/`FormatChestOdds`/`_RollChestItem` com pity determinístico); `EconomyService.gd` 1052→887 (−165). Verbatim conferido por diff programático (range 323–517). **Armadilha de `static var` evitada**: os knobs `TradeCooldownSec`/`TradeDailyCap`/`TradeDailyCapVIP` ficam no `EconomyService` porque `tests/IdleTests.gd:2611` os escreve pela classe (`EconomyService.TradeCooldownSec = 0`) — o serviço lê qualificado (`EconomyService.X`, 7 ocorrências, todas leituras), então a superfície de tuning continua a mesma e o static não é duplicado. Suíte de trade (F4) verde com o knob escrevendo pela classe
- [x] **Fatia 12 (fechamento): kernel extraído, `EconomyService` fora da allowlist**: `EconomyKernel.gd` (196 linhas: carteira gold/gems `GetBalance`/`GetGems`/`AddGems`, `GetGoldLedgerSum`, `LedgerAppend`/`_LedgerAppendLocked`, `SettleTransaction`, `GrantItem`/`RemoveItem`, `GrantBossKey` e as ops raw de stack com identidade de lote B1 — `_AccountIDForCharacterRaw`, `_ItemCountRaw`, `_MoveStack`, `_MoveStackUIDs`, `_UIDList`, `_GrantStackRaw`, `_CharGoldRaw`); `EconomyService.gd` 887→**763** (−124). Os **mutexes ficam no facade** de propósito (`settleMutex`, `settleMutexes`, `_get_settle_mutex`, `_shardInitMutex`) — o kernel chama `_eco.settleMutex`/`_eco._get_settle_mutex`, então a semântica de trava é byte a byte a de antes. `EconomyService.gd` **removido do `ALLOWLIST`** de `scripts/check_god_nodes.sh` (3839→763; 14 módulos extraídos em 12 fatias, chamadores externos e assinaturas nunca mudaram). O gate foi **endurecido**: a listagem passou de tracked-only para `git ls-files --cached --others --exclude-standard`, então um serviço novo já nasce medido em `<800` sem precisar ser commitado. Verbatim conferido por diff programático; suite idle **1329 checks / 0 failures / 0 SCRIPT ERROR**, benchmarks 0 failures, probe backup-restore PASSED (migration 42 = 42), companion 75+25+12 checks 0 failures
- [ ] Soft-launch web + Android, custo infra < meta, uptime ≥ 99.5%
- **Gate S3 (LAUNCH):** ToS/LGPD auditados, sink/faucet gems 0.8–1.2/semana, conversão paga ≥ 2%.

## Status de validação (2026-09-24, headless real — S3 fechada)

- **Suíte idle: 1329 checks, 0 failures, 0 SCRIPT ERROR** (1232 → 1304 com a suíte ampliada → **1329** ao destravar 25 checks que abortavam em silêncio; ver Fatia 5). Rodada repetida e verde após **cada** uma das 12 fatias
- **Gate anti-god-node: OK** — `EconomyService.gd` fora da allowlist (763 linhas); maior nó próprio remanescente da allowlist é `Server.gd`. Listagem do gate agora cobre também arquivos não rastreados
- **Benchmarks: 0 failures** (settle 1 ms / orçamento 500 ms; 200 settles P99 1 ms, 0 erros) · **Backup-restore probe: PASSED** (migration 42 = live 42) · **Companion: 75+25 checks, 0 failures** · **Refund CLI: 12 checks, 0 failures**
- **Segfault de shutdown corrigido (S3 fechada)** — duas causas independentes, ambas
  pré-existentes no código commitado (nenhuma delas introduceda pelas fatias):
  (1) `quit()` caindo no meio do `DB.Preload()` deixava jobs de
  `load_threaded_request` sem join — o engine destrói o worker enquanto ele ainda
  está parseando, sob um script cache que o teardown já está liberando (evidência:
  `Parse Error` não-determinístico em linhas `script = ExtResource(...)` de `.tres`,
  aviso `~Thread`, 362 ObjectDB instances vazadas). `DB.DrainPendingPreloads()`
  faz o join bloqueante e é chamado por `Launcher._exit_tree()` (último hook com
  árvore viva) e por `DB.Clear()`.
  (2) `tests/test_backup_restore.gd` instancia `SQLBackups` cujo `_init()` dispara
  um worker que chama de volta `Launcher.World/Economy`; o worker agora é recolhido no probe
  e `SQLBackups._exit_tree()` chama `Stop()` para qualquer outro holder.
  A/B: sem o drain → crash 1/1, 5 parse errors, 362 leaks; com o drain → 0/0/19;
  após recolher o worker do backup → **8/8 limpo**, ~8 s.
- **Radar (não corrigido):** `test_backup_restore.gd` retorna exit 0 mesmo quando o
  engine segfaulta, então o job `backup-restore` do CI não enxerga essa classe de
  falha — o crash desta rodada foi achado no log, não no status.
- Últimas 20 corrigidas com causa raiz: goldens sem newbie ×5, vendor
- (`query_with_bindings` retorna bool), anti-replay TOTP (`INSERT OR IGNORE`
- sempre true → `changes()`), snapshot global sem isolamento, `_killRegistered`
- sem reset por alvo (só 1º kill contava), `_tickStuck` abortando kills colados,
- melee static + sem-grude (fizzle), floor idle 3.5%→8%, realtime movido p/ cedo

## Métricas 30/90 dias (mesmas do roadmap técnico, cobradas aqui)

- Jogo: D1 ≥ 35%, D7 ≥ 20%, D30 ≥ 8%; 1ª coleta offline < 30min
- Economia: ≥ 60% das gems em chaves/guild; divergência ledger = 0 (job diário)
- Receita: conversão ≥ 2%, ARPPU ≥ US$ 8/mês, VIP ≥ 60% da receita

## Bloqueados fora da engenharia (não executar sem dono/terceiro)

Preços finais, conta MP/Stripe PJ, arte de cosméticos, SDK de ads real, contas em portais web. Ver `archive/ROADMAP.md` § Follow-ups.
