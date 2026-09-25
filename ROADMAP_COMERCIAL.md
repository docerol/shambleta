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

## Semana 2 — Reter (gate: D1 ≥ 27%, D7 ≥ 7%, D30 ≥ 4% no beta)

> **Meta reescrita em 2026-09-24** (`AUDITORIA_INDEPENDENTE_2026-09-24.md`
> "Retenção" e §23 Bloco 1 item 6). Os 35/20/8 que estavam aqui não eram
> medição, eram desejo: benchmarks de 2025 (GameAnalytics, 11.600 jogos / 1,48 bi MAU)
> dão mediana **D1 22% / D7 3,4–3,9%** e topo de quartil **D1 25–33% / D7 7–8%
> / D30 single-digit**. A meta antiga ficava ~2,5× acima do percentil de topo
> medido em D7 — mantida, ela transforma um beta bom em "fracasso" na hora de
> julgar. As novas são a borda do topo de quartil, que é o mais agressivo que
> se pode pedir de um idle web novo sem tráfego comprado.
>
> **Consequência declarada (UA pago não fecha):** com CPI casual ~US$1,50 e
> D30 ~3,5%, o custo por jogador-vivo sai ~US$43 e o ROAS de D30 de casual é
> ~1/7 — com D7 de 7% não existe conversão de 2% que pague mídia. O beta é
> **organic-first** (comunidade do fork, portais web, boca-a-boca) e qualquer
> spend vem depois de D7 medido em gente real.
>
> Onde medir: view `cohort_retention` (migration 045, D1/D7/D30 por conta) e o
> evento `d1_return` do funil — nenhum dos dois existia quando a meta de 35%
> foi escrita.

- [x] Skip 1-clique no onboarding (`Onboarding._skipButton` → mesma semântica do Finish)
- [x] `first_boss` emitido na 1ª vitória (`SettleBossResult`, `prevBeaten == 0`)
- [x] `d1_return` emitido no 2º dia de login (`Peers.FinalizeLogin`)
- [x] Trade: cap diário F2P 20 vs VIP 40 (`TradeDailyCapVIP`) + `GetTradeFeeState()` p/ UI (taxa burn visível antes de confirmar)
- [x] Temporada S1: `SeasonS1Rules()` congeladas + `EnsureSeasonS1()` idempotente (respeita trava T5 — cria só com `SHAMBLETA_ENABLE_SEASONS=1`)
- [x] **G1 (AUDITORIA_INDEPENDENTE 2026-09-24, Bloco 1 #7): espinha sazonal LIGada no beta** com as quatro condições que a nota de ativação exigia. Decisão registrada em arquivo: `deploy/docker-compose.yml` traz `SHAMBLETA_ENABLE_SEASONS: "1"` (documentado em `deploy/COOLIFY.md`). O ciclo saiu do job de 24 h e ganhou relógio próprio (`SQLCommons.SeasonClockIntervalSec` = 5 min, disparando no boot, em `SQLBackups`), porque `ends_at` não espera o reconcile. `CloseSeason` passou a **congelar o placar no fechamento** (antes o snapshot rodava em `SettleSeasonPrizes`, que podia acontecer horas depois do fim — pagando quem subiu fora da temporada) e `SnapshotSeasonSpend` ganhou teto em `ends_at`. O `pass.s1`/`pass.s1.deluxe` virou entregável (era SKU pago sem temporada ativa: `CheckoutService` falhava com `apply_failed`) e o companion **recusa a venda antes do dinheiro** quando não há temporada ativa (`season_offer_status`, fail-closed até se a tabela `season` sumir). O que continua em aberto e é pós-beta: estágio `CLOSING` com apuração por evento (os contadores `power_score`/`bosses_beaten`/`guild.points` não têm histórico, então o valor congelado é o do instante do fechamento — vazamento residual ≤ cadência do relógio). Provado em `SuiteSeasonBootstrap`
- [x] **S2 AH seed de bots — feito em código, com a decisão de lançamento sendo OFF.** `AuctionHouseService.EnsureAuctionBots()` garante 1 conta/char de bot e 1 listagem `open` por seed, cada item dentro de `sql.Transaction` (stock → consume → escrow → ledger), e o boot liga isso uma vez por processo via `_trySeedAuctionBots()` (`EconomyService.gd:60`). A idempotência é por *"qualquer listing deste bot para este item, `open` OU `sold`"* — o bot nunca recompra, então o estoque é finito por design e a AH não vira faucet de gold. Trava `SHAMBLETA_AH_BOTS=1`; **desligada no beta** (`deploy/COOLIFY.md` §variáveis, `deploy/STAGING.md` §108, matriz de features §12 da auditoria). Medido em `SuiteAHBots`: gated-off não cria nada · gated-on cria · segunda rodada devolve 0 · jogador compra pelo caminho normal e a listagem é consumida · depois da compra não há reseed · `ReconcileDaily` fecha em 0. O cooldown/cap de trade (60 s, e-mail verificado) já existia. **O que NÃO está provado:** nenhum check injeta falha no meio da transação do seed — o rollback de `sql.Transaction` + o skip por listing existente é o que protege contra duplicação em crash, mas isso é argumento de desenho, não medição. Fica como dívida pós-beta (barata: a feature nasce desligada).
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
- [x] **Fatia 11 do EconomyService (troca + baús)**: `TradeChestService.gd` (208 linhas: `GetTradeFeeState`/`ExecuteTrade` — escrow all-or-nothing, fee de gems queimado, cooldown + teto diário com VIP — e baús `OpenChest`/`GetChestOdds`/`GetChestOddsForCharacter`/`GetChestPityStatus`/`FormatChestOdds`/`_RollChestItem` com pity determinístico); `EconomyService.gd` 1052→887 (−165). Verbatim conferido por diff programático (range 323–517). **Armadilha de `static var` evitada**: os knobs `TradeCooldownSec`/`TradeDailyCap`/`TradeDailyCapVIP` ficam no `EconomyService` porque `tests/IdleTests.gd:3797` os escreve pela classe (`EconomyService.TradeCooldownSec = 0`) — o serviço lê qualificado (`EconomyService.X`, 7 ocorrências, todas leituras), então a superfície de tuning continua a mesma e o static não é duplicado. Suíte de trade (F4) verde com o knob escrevendo pela classe
- [x] **Fatia 12 (fechamento): kernel extraído, `EconomyService` fora da allowlist**: `EconomyKernel.gd` (196 linhas: carteira gold/gems `GetBalance`/`GetGems`/`AddGems`, `GetGoldLedgerSum`, `LedgerAppend`/`_LedgerAppendLocked`, `SettleTransaction`, `GrantItem`/`RemoveItem`, `GrantBossKey` e as ops raw de stack com identidade de lote B1 — `_AccountIDForCharacterRaw`, `_ItemCountRaw`, `_MoveStack`, `_MoveStackUIDs`, `_UIDList`, `_GrantStackRaw`, `_CharGoldRaw`); <!-- 2026-09-24 (passada de beta): `SettleTransaction` e `RemoveItem` saíram do kernel e do facade. Nenhum chamador em 12 módulos + suítes; o primeiro só consultava `OfflineSettle.SettlePending` por trás do mutex e devolvia bool, o segundo era `return false` — uma API de remoção de item que mente é um sumiço silencioso esperando alguém ligar. Remoção real: `Inventory.RemoveItem` → `SQL.RemoveItem`; movimentos econômicos de item entram assinados em ledger (`_LedgerAppendLocked` em AH/grant/fee). --> `EconomyService.gd` 887→**763** (−124). Os **mutexes ficam no facade** de propósito (`settleMutex`, `settleMutexes`, `_get_settle_mutex`, `_shardInitMutex`) — o kernel chama `_eco.settleMutex`/`_eco._get_settle_mutex`, então a semântica de trava é byte a byte a de antes. `EconomyService.gd` **removido do `ALLOWLIST`** de `scripts/check_god_nodes.sh` (3839→763; 14 módulos extraídos em 12 fatias, chamadores externos e assinaturas nunca mudaram). O gate foi **endurecido**: a listagem passou de tracked-only para `git ls-files --cached --others --exclude-standard`, então um serviço novo já nasce medido em `<800` sem precisar ser commitado. Verbatim conferido por diff programático; suite idle **1329 checks / 0 failures / 0 SCRIPT ERROR**, benchmarks 0 failures, probe backup-restore PASSED (migration 42 = 42), companion 75+25+12 checks 0 failures
- [x] **Fatia 13 (HUD, achado (t) da auditoria): `Gui.gd` de volta ao teto e o gate espelhado no portão local**: `sources/gui/ManualHudBar.gd` (92 linhas; `extends RefCounted`, sem `class_name`, uma `static func Build(gui)` só — mesma forma de `sources/ads/AdProvider.gd`, então nada nasce de `.new()` e o inventário medido de painéis de runtime não mexe) ficou com a **construção** da barra de ações rápidas: `HBoxContainer` "ManualSkills", os dois botões de cast (`Melee`/`Run`), `Eventos`, `Guilda`, `AH`, `Leilão` e o `IdleHudButton` do HUD idle. O **estado** (`manualSkillBar`, `manualSkillButtons`, `idleHudButton`) e **o que cada botão faz** (`AddManualSkillButtons`, `_on_manual_skill_pressed`, `_on_guild_pressed`, `_on_ah_pressed`, `_on_activities_pressed`, `_on_idle_hud_pressed`, `HideManualSkillButtons`) ficaram no `Gui` — é de lá que `_input`, `ToggleIdleMode` e a suíte de hotkeys leem, e `tests/test_e2e_implementation.gd:20` exige os dois nomes como métodos do `Gui.gd`. `Gui.gd` 815→**749** (−66), teto 800, gate verde com folga de 51 linhas. Motivo: a CI (`code-health`) corta arquivo próprio >800 linhas e o `scripts/test.sh all` não rodava esse corte — oito gates verdes na máquina convivendo com o gate vermelho no mesmo commit (os +43 vieram dos consertos (j) e (p), ambos na barra). Conserto de radar: `gate_sh` em `scripts/test.sh` espelha `scripts/check_god_nodes.sh` pelo mesmo quádruplo de §24-8 (marcador `Gate anti-god-node:`, contagem lida da linha de resultado) e `SuiteOpsA2` amarra a divergência por fonte — todo `scripts/*.sh` que a CI executa, fora o avaliador e o próprio runner, tem que aparecer no `test.sh`, com o número de gates ancorado para o guard não passar verde por varredura vazia
- [ ] Soft-launch **web** (custo infra < meta, uptime ≥ 99.5%)
  - Android nativo (#62, **fora do gate de lançamento por decisão do dono em
    2026-09-25**): sem script de export recriado nesta passada — o censo
    de produtores continua sendo `deploy/server/Dockerfile` + `deploy/web/Dockerfile` +
    `scripts/export_web.sh`, nenhum deles Android (não recriar `export_android.sh` agora).
- **Gate S3 (LAUNCH):** ToS/LGPD auditados, sink/faucet gems 0.8–1.2/semana, conversão paga ≥ 2%.

## Status de validação (2026-09-24, headless real — S3 fechada)

- **Suíte idle: 2222 checks, 0 failures, 0 SCRIPT ERROR** (1232 → 1304 com a suíte ampliada → 1329 ao destravar 25 checks que abortavam em silêncio, ver Fatia 5 → **1908** com a passada de beta: régua de retenção medida, K1, R3, G1/`SuiteSeasonBootstrap` e os guards de superfície → **2169** com a guarda de hotkeys `SuiteInputHotkeys` → **2184** com a decisão de boot das migrations `SQL.MigrationPlan` e as guards do filtro de export → **2220** com a segunda porta do checkout web, o inventário medido de painéis que nascem de `.new()` e os checks que sobraram de ver as mordaças mordendo → **2222** com o guard de i18n: toda `tr("literal")` de `sources/` tem que ter `pt_BR` no catálogo **compilado** → **2243** com os guards de boot web e a superfície de serviços → **2255** com a fiação do update do PWA → **2257** com o censo de duplicadas do `ui.csv` (chave repetida na primeira coluna sobrescreve a anterior no importador, e foi assim que `"Attack"` chegou ao pt-BR como verbo) (`/tmp/suite_beta_final28.log`, 9× `Gate §24-8 OK`). Rodada repetida e verde após **cada** uma das 12 fatias e após cada item do Bloco 0/1
- **Gate anti-god-node: OK** — `EconomyService.gd` fora da allowlist (778 linhas); maior nó próprio remanescente da allowlist é `Server.gd`. Listagem do gate agora cobre também arquivos não rastreados
- **Passada commitada e no remoto (2026-09-25):** `6277671` levou os 148 caminhos num commit só, `da2531c..6277671` em `origin/master`. Os nove gates foram re-medidos **nesta máquina** antes do commit, com as mesmas contagens (idle 2257/0 · rpc 10/0 · e2e 0 · backup 8/0 · benchmarks 0 · companion 100/0 · security 47/0 · refund 12/0 · estrutura 0/278 arquivos) · **Artefato Web re-produzido do zero aqui** (`scripts/export_web.sh`): first-load **36 MiB** gzip (engine 12 · pck 21 · shell 3) e boot num Chromium real em `== RESULT: 10 checks, 0 failures ==` — engine no console, `crossOriginIsolated`, `SharedArrayBuffer`, canvas 780×437, manifest `standalone`, exatamente um service worker no escopo raiz, zero request falho, zero erro de console. Continua **não medível** sem servidor: o que estes checks provam é o pacote, não o TLS de produção, o WSS contra o `game` real nem o `POST /checkout/preference` na origem do site (ver §4 do handoff)
- **CI verde nos 12 jobs em `ccc927a`** (medido pela API, 2026-09-25): primeira evidência do beta construída fora da máquina de quem o escreveu — com `Companion Money Tests` e `SOM-IDLE Idle Tests` (os 2257 checks) passando em checkout limpo, Godot 4.7.1. O run anterior, `6277671`, foi útil exatamente por isso: caiu no job do dinheiro com exit 126 porque `scripts/test.sh` não tinha o bit de execução no índice, ou seja, nenhum clone novo conseguia rodar `./scripts/test.sh all`. Consertado em `ccc927a` (só modo). `Publish snap` fica `skipped` sem credencial na store
- **Benchmarks: 0 failures** (settle 2 ms / orçamento 500 ms; 200 settles P99 2 ms, 0 erros) · **Backup-restore probe: 8 checks, 0 failures** (migration 46 = live 46, re-medido em `/tmp/suite_beta_final16.log`) · **RPC identity: 10 checks, 0 failures** · **API cross-file: 0 failures** · **Companion: 100+47 checks, 0 failures** · **Refund CLI: 12 checks, 0 failures** · Os nove gates de `./scripts/test.sh all` (cinco headless Godot + um shell + três Python) passam pelo mesmo `scripts/ci_gate_log.sh`
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
- **Radar fechado (2026-09-24, passada de beta):** o job `backup-restore` não era
  gated — `test_backup_restore.gd` terminava em `quit(0)` com uma linha "PASSED"
  sem contagem, então um segfault de shutdown saía 0 e o crash era achado no log,
  não no status. O probe agora conta checks e fecha com
  `== Backup Restore Probe: N checks, M failures ==`; divergência de schema entre
  backup e vivo deixou de ser `WARNING` e virou check falho (no probe é
  determinístico: mesma conexão, worker já recolhido). Os jobs `backup-restore` e
  `benchmarks` passaram a correr por `scripts/ci_gate_log.sh`, os cinco harnesses
  headless do CI estão sob o gate quádruplo.
- **Artefatos mortos caçados (passada de beta, §13/§30):** `SQLCharacter.gd`
  (todos os métodos `pass`, zero referência), `SettleTransaction` (consultava
  `SettlePending` por trás do mutex e não tinha chamador) e `RemoveItem` do kernel
  (`return false` — uma API de remoção que mente) já tinham saído; `MetricsServer.gd`
  ganhou o `.gd` que faltava e `gut_runner.gd` foi apagado (T1). Faltava
  `sources/economy/WebhookValidator.gd`: `return true if secret.length() > 10` com
  `push_warning("… assinatura validada")` — nada no repositório chamava, e o único
  efeito possível era alguém ligar um endpoint a ele e aceitar webhook forjado.
  Apagado; a validação real de assinatura é do companion (`companion/server.py`:
  HMAC do provedor + re-fetch autoritativo, fail-closed, coverage em
  `test_security.py`). As três mensagens que atribuíam `webhook_verified: true` ao
  stub (`CheckoutService.GetCheckoutIntent`, dois comentários de
  `EconomyService.gd`) e a linha de `docs/development/architecture.md` que listavam
  `WebhookValidator` como domínio extraído foram corrigidas para apontar no
  companion — varredura final: 0 referências em `sources/`, `tests/`, `docs/`,
  `companion/`, `deploy/`, `scripts/`.
- **Documentação de autoavaliação desarmada (passada de beta, §25 risco 1):** os
  relatórios de 2026-09-21 na raiz (`AUDITORIA_SHAMBLETA.md`,
  `CONCLUSAO_FINAL_ROUND_19.md`, `RELATORIO_FINAL_2026-09-21.md`,
  `auditoria-tecnica-shambleta.md`) ainda davam notas > 9 apoiadas em evidência
  que não está mais de pé. Cada um recebeu aviso/retificação com a verificação
  feita na hora: `WebhookValidator.gd` (stub morto, apagado), `Monitoring.gd`
  "spans" (`func StartSpan` não existe em nenhum commit —
  `git log --all -S` vazio), os `SQL*.gd` de domínio (removidos; `sources/sql/`
  tem 3 arquivos), `MultiplayerTests.gd`/`run_multiplayer_tests.gd` e
  `PerformanceMonitor` (foram commitados em `f781f71` e removidos depois), e o
  `1193 checks` fabricado — substituído pela medição gated real **1920 checks, 0
  failures, 0 SCRIPT ERROR**; `MultiplayerTests.gd`/`run_multiplayer_tests.gd`
  existiram (commitados em `f781f71`) e saíram do índice nesta passada junto com
  `gut_runner.gd`, porque dependiam do estado P4 revertido;
  `PerformanceMonitor` esse sim **nunca existiu** em `sources/` — `git log --all
  -S"PerformanceMonitor"` só retorna o commit que adicionou o próprio relatório
  que o citava. A Arquitetura 9.5 caiu por outro motivo: a
  fragmentação P4 **existiu** (`Network.gd` chegou a 179 linhas / 2 `@rpc` com 6
  módulos) e foi revertida em `bd69275` porque quebrou o dispatch dos `@rpc` do
  autoload — a nota premiava um estado transitório. **Uma correção minha também
  está registrada:** a primeira versão da retificação de arquitetura afirmava que
  `NetworkAuth.gd`/`NetworkSocial.gd` "nunca existiram"; o `git log --all
  --name-status` mostra `A` em `f781f71` e `D` em `bd69275`, e o texto foi
  consertado na mesma passada.
- **Gate de idade entregue em código (Bloco 1 #11, §21/§24-11, 2026-09-24):** o
  jogo vende baús de conteúdo aleatório e não tinha nenhuma barreira de idade —
  a Lei 15.211/2025 só permite isso em acesso misto com **restrição efetiva de
  acesso de menores** + controle parental. Implementado como a **terceira cláusula
  do aceite afirmativo que já existia** (nada de RPC novo): migration
  `046_age_gate.sql` (`account.consent_age_version`), `NetworkCommons.AgreementAgeVersion`
  com bump independente, `SQL.IsConsentAccepted` passou a exigir os três valores,
  `AddAccount`/`SetConsentAccepted` gravam a versão vigente e `EraseAccount` zera a
  coluna junto do resto (esquecimento). Cobrado em dois pontos independentes: login
  e criação (`ERR_CONSENT_REQUIRED`) e **no dinheiro** —
  `CheckoutService.GetCheckoutIntent` recusa `consent_required` antes de nem
  devolver preço, porque o gate de login não segura um client que pule o diálogo de
  re-aceite. Textos: `agreement.json` ganhou a categoria "Age and Paid Randomized
  Content" e o checkbox/avisos de `Login.gd` + as 4 chaves do `ui.csv` (en e
  `pt_BR`) declaram 18+; `SuiteLGPD` cobre gravação, recusa de checkout sem
  declaração, queda do gate ao zerar a coluna, re-afirmação forçada por bump e
  apagamento na anonimização. **O que isto NÃO é:** verificação de idade — é
  autodeclaração, e o parecer jurídico (§1 do handoff) decide se satisfaz a lei; se
  não satisfizer, o que falta é documento/data de nascimento verificado, produto
  novo. E as rotas HTTP do companion não re-validam a cláusula (base zero no
  lançamento; vira gap real se houver importação de contas).
- **TLS do cliente ligado (ACHADO NOVO, 2026-09-24; registrado como V7 em
  `AUDITORIA_INDEPENDENTE_2026-09-24.md` §12):** `sources/network/client/Client.gd`
  montava `TLSOptions.client_unsafe()` e passava a opção para os dois transportes
  (`create_client(url, tlsOptions)` e `host.dtls_client_setup(serverAddress, tlsOptions)`),
  linha que está no histórico desde `c727e69` (2026-08-14, `git log -S "client_unsafe"`).
  `client_unsafe()` desliga cadeia **e** hostname; no mesmo ramo o `auth_callback`
  (`_ValidateServerAuth`, `:827`) é `complete_auth(peerID)` puro, sem teste
  criptográfico, então nada cobria. Pelo canal desses RPCs de auth viajam senha,
  token de "lembrar" e código 2FA: MITM na rota apresentava qualquer certificado,
  colhia a credencial e repassava o tráfego ao servidor real. **Nem a auditoria
  independente nem as autoavaliações tinham visto isto** — o lado do servidor estava
  fechado (`RequiresTLS()` + hard-stop do bind inseguro), e é exatamente esse tipo
  de borda-half-fechada que escapa de leitura por cima. Corrigido para
  `NetworkCommons.ClientTLSOptions()`, que passa o bundle do
  `OS.get_system_ca_certificates()` como âncora explícita do `TLSOptions.client(...)`
  (o hostname é derivado do próprio URL pelo Godot, não é argumento). A âncora
  explícita não é preciosismo: medido nesta engine (Godot 4.7.2 / mbedtls), o caminho
  sem argumento — `TLSOptions.client()` puro — morre **antes** do handshake com
  `SSL module failed to initialize!` (`-0x6C00`), então a "correção de uma linha"
  teria quebrado o login desktop aqui em vez de consertá-lo. Medido também: com a
  âncora do sistema, um certificado autoassinado é recusado (`-0x2700`/`-0x7180`) e
  o mesmo certificado aceito quando vira a âncora — a verificação está viva.
  Limitação honesta: o colhimento por MITM **não foi reproduzido localmente** (nesse
  build, nem `client_unsafe()` completa um `wss://` na máquina de teste); o risco é
  argumentado pela semântica da API + `auth_callback` oco, não por exploit executado.
  Guard em `SuiteOpsA2` que varre os 279 `.gd`
  de `sources/` atrás de `client_unsafe` fora de comentário, confere as opções TLS
  vivas (`not is_unsafe_client()`, âncora presente) e que a opção chega aos dois
  transportes. Custo real, documentado em `deploy/TLS.md` e
  `deploy/STAGING.md`: apontar cliente para `user://server.crt` autoassinado
  (`provision_tls.sh --self-signed`) passa a falhar de propósito — a correção é CA
  confiável no cliente, não afrouxar o cliente de novo. Proxy TLS do Coolify, túnel
  cloudflared, Let's Encrypt e o build Web não mudam de comportamento (certificado
  de CA pública); bind local é `ws://` plain.
- Últimas 20 corrigidas com causa raiz: goldens sem newbie ×5, vendor
  (`query_with_bindings` retorna bool), anti-replay TOTP (`INSERT OR IGNORE`
  sempre true → `changes()`), snapshot global sem isolamento, `_killRegistered`
  sem reset por alvo (só 1º kill contava), `_tickStuck` abortando kills colados,
  melee static + sem-grude (fizzle), floor idle 3.5%→8%, realtime movido p/ cedo

## Métricas 30/90 dias (mesmas do roadmap técnico, cobradas aqui)

- Jogo: D1 ≥ 27%, D7 ≥ 7%, D30 ≥ 4% (mesma régua reescrita de Semana 2 — ver a
  nota ali; 35/20/8 era inatingível e não vinha de medição); 1ª coleta offline < 30min
- Economia: ≥ 60% das gems em chaves/guild; divergência ledger = 0 (job diário)
- Receita: conversão ≥ 2%, ARPPU ≥ US$ 8/mês, VIP ≥ 60% da receita

## Bloqueados fora da engenharia (não executar sem dono/terceiro)

Preços finais, conta MP/Stripe PJ, arte de cosméticos, SDK de ads real, contas em portais web. Ver `archive/ROADMAP.md` § Follow-ups.
