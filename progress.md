# Gauntlet Progress — Shambleta Beta Comercial

Bar: Old School RuneScape (https://oldschool.runescape.com)

Métrica: FPS 60 | Load < 3s | 30min zero crash | Comerciais end-to-end

## Peças

| Peça | Status | Vencedor (Cego) | Lacuna Maior | Notas |
|---|---|---|---|---|
| Loop de jogo (idle, combate, rebirth, offline) | Avaliado + Implementado (híbrido) | OSRS (cego) | Interação estratégica e feedback visual contínuo | Implementado: skills manuais via botões no HUD (`AddManualSkillButtons`) + fallback idle (`IdlePolicy`) intacto; notificação + feedback visual adicionado. |
| Economia (leilão, gems, gold, itens, lot-tracking) | Avaliado | OSRS | Interface visual de leilão e integração direta | Leilão funcional por comandos; falta UI gráfica integrada ao gameplay. |
| Guildas | Avaliado | OSRS | Interface visual de guilda e interação social | Guildas funcionais por comandos; falta UI de guilda e interação social contínua. |
| UI e gráficos | Avaliado | OSRS | Polimento visual e simplificação da interface para idle | Gráficos pixel art funcionais; UI herdada de MMO (20+ janelas) não simplificada para idle; onboarding parcial; touch não otimizado. |
| Performance e otimização | Avaliado | OSRS | Sharding de banco e profiling de produção completo | SQLite WAL single-node; profiling stub (Monitoring.gd) sem spans; benchmarks básicos existentes mas sem otimização de rede/multi-node. |
| Funcionalidades comerciais (VIP, temporadas, cosméticos, pagamento) | Implementado (sandbox) + Melhorado | OSRS (cego) | Checkout real (gateway) ainda pendente; sandbox funcional (`GetCheckoutIntent` + `SimulateCheckout`) | VIP, season pass, cosméticos, torneios e checkout sandbox completos; gateway real ainda planejado. |
| Estabilidade rede/servidor | Avaliado | OSRS | Infra de deploy documentada mas não confirmada em produção; webhooks em sandbox; TLS configurado via proxy mas sem cert direto testado | Deploy Coolify documentado (docker-compose, proxy TLS, companion); sem evidência de ambiente de produção estável; backup local implementado; offsite parcial. |

## Progresso Atual

- [x] Bar obtida (OSRS site + cliente oficial)
- [x] Página de progresso criada
- [x] Loop de jogo — avaliação cega concluída (OSRS vence)
- [x] Economia — avaliação cega concluída (OSRS vence)
- [x] Guildas — avaliação cega concluída (OSRS vence)
- [x] UI e gráficos — avaliação cega concluída (OSRS vence)
- [x] Performance e otimização — avaliação cega concluída (OSRS vence)
- [x] Funcionalidades comerciais — avaliação cega concluída (OSRS vence)
- [x] Estabilidade rede/servidor — avaliação cega concluída (OSRS vence)
- [x] Nenhuma peça venceu o nosso lado — todas as lacunas precisam ser fechadas antes do lançamento beta comercial.
- [x] Resultado completo: `gauntlet_result.md`
- [x] Gameplay híbrido implementado: `Gui.gd` (`AddManualSkillButtons`, `IdlePolicy` fallback intacto)
- [x] UI/UX polimento: P-A1 (`_essential_windows`, ≤8), P-A2 (highlights + clear), P-A3/P-A4 (mobile/web + 48px), P-B1/P-B2 (confirmados)
- [x] Comerciais sandbox: `SimulateCheckout` (`Gui.gd`) + `GetCheckoutIntent` (EconomyService)
- [x] Rede: `CheckNetworkStability` (`Gui.gd`) | Performance: `RunPerformanceBenchmark` (`Gui.gd`)
- [x] Parse errors corrigidos: `WorldAgent.gd` (elif-after-else), `IdlePolicyService.gd` (P3 sem shadowing, ZonePolicy com super.Tick), `Gui.gd` (const→helper, Peer guard), `FloatingWindows`/`Settings`/`Social`/`AfkReport` guards
- [x] R3/R4 revividos sem os defeitos: live events + arena na EconomyService (sharding P4, wins incrementais, JSON seguro), RPCs Network/Server, suites SuiteLiveEvents/SuiteArena, migrations 033/034, hygiene anti-poluição entre runs
- [x] E2E `tests/test_e2e_implementation.gd`: 10/10 PASS
- [x] Suite completa `run_idle_tests.gd`: 1124 checks, 0 failures | `benchmarks.gd`: 0 failures
- [ ] Ações restantes (pós-beta): checkout real (gateway), staging/TLS direto, sharding eval, tuning de preços VIP por catálogo.

## Roadmap Comercial (2026-09-22 — lucrar)

Plano executável em `ROADMAP_COMERCIAL.md` (3 semanas: Cobrar → Reter → Escalar).

- [x] S1 código: funil `onboarding_done/first_boss/first_chest/d1_return` (`TelemetryService.RecordFunnel` + emits best-effort) + `FunnelSummary()` + migration 042 (covering index)
- [x] S2 código: Skip onboarding + `TradeDailyCapVIP` (20→40) + `GetTradeFeeState()` + `SeasonS1Rules()`/`EnsureSeasonS1()` (respeita trava T5)
- [x] S3 código: load probe real 200 settles P99<200ms (`benchmarks.gd`) + `.graphifyignore` (remove Sentry vendorado + sprites do grafo)
- [x] Correções: `EconomyService.gd:2264` (newline) + `Onboarding.gd:161` (walrus inválido) — parse OK isolado
- [ ] S1 dono: ligar 1 gateway (Stripe OU MP) + `refund-sweep --dry-run` em staging
- [x] S3: fatiar `EconomyService.gd` — FATIA 1 FEITA: `EconomyCatalog.gd` (605 linhas, 114 consts + 18 puros) + wrappers; FATIA 2 FEITA: `CheckoutService.gd` (305: grant queue C1 + VIP F4 + checkout intent + refund CDC) + `SeasonService.gd` (181: E2 corridas/lifecycle/prêmio + trava T5) + `GuildService.gd` (348), todos via composição `_eco` com MESMO `settleMutex` (locking idêntico, wrappers preservam callers); `EconomyService.gd` 3839→3292; baseline suíte verde exigida cumprida (1304 checks/0 failures); FATIA 3 FEITA: `PassService.gd` (438: Fase C passe — PT/missões/claims/skip/auto-claim), `EconomyService.gd` 3292→2895; FATIA 4 FEITA: `AuctionHouseService.gd` (301: E2 listings+escrow+highlight/slots+creator fee e S2 bot seed), `EconomyService.gd` 2895→2649; FATIA 5 FEITA: `ShopService.gd` (273: BuyChests + Fase B daily shop/reroll/one-time + R2 vendor), `EconomyService.gd` 2649→2432; FATIA 6 FEITA: `ItemForgeService.gd` (406: sinks de item Corrupt/CubeUpcycle/Salvage + Fase H crafting com budget de raridade e aprovação manual), `EconomyService.gd` 2432→2070; FATIA 7 FEITA: `BossProgressionService.gd` (372: rebirth B+C + escada de boss + tormento/boss rush D2), `EconomyService.gd` 2070→1757; FATIA 8 FEITA: `AdsCosmeticsService.gd` (237: Fase E rewarded ads + Fase D cosmeticos/entitlements), `EconomyService.gd` 1757→1601; FATIA 9 FEITA: `TournamentArenaService.gd` (320: Fase F torneios + R4 arena assimetrica), `EconomyService.gd` 1601→1340; FATIA 10 FEITA: `CommunityService.gd` (372: R3 live events + boards nomeados + conquistas + R1 referral/anti-fraude), `EconomyService.gd` 1340→1052; FATIA 11 FEITA: `TradeChestService.gd` (208: trade com escrow + fee queimado + cooldown/teto diario, e baus com pity deterministico e odds publicas), `EconomyService.gd` 1052→887 — knobs estaticos de trade ficaram no facade porque o teste os escreve pela classe (`EconomyService.TradeCooldownSec = 0`) e o servico so os le. FATIA 12 FEITA (fechamento): `EconomyKernel.gd` (196: carteira gold/gems, `LedgerAppend`/`_LedgerAppendLocked`, `SettleTransaction`, `GrantItem`/`RemoveItem`/`GrantBossKey` e as ops raw de stack com identidade de lote B1), `EconomyService.gd` 887→**763** e **fora da allowlist** do gate; os mutexes (`settleMutex`/`settleMutexes`/`_get_settle_mutex`/`_shardInitMutex`) ficaram no facade de proposito, o kernel chama `_eco.settleMutex` entao a semantica de trava e identica. Gate endurecido: `git ls-files --cached --others --exclude-standard`, entao arquivo novo ja nasce medido. Idle 1329/0 falhas, benchmarks 0 falhas, backup-restore probe PASSED (migration 42=42), companion 75+25 e refund CLI 12 checks 0 falhas. BUG SILENCIOSO DA FATIA 1 CORRIGIDO: consts acessados via instância (`economy.X`, `Launcher.Economy.X`) abortavam a função em runtime — 9 em IdleTests (3 suítes paravam no meio) + 1 em `Server.WatchAd` (painel AFK 2× nunca atualizava); varredura programática = 0 restantes
- [x] Segfault de shutdown corrigido (causa raiz dupla, ambas pré-existentes às fatias): (1) `quit()` caindo no meio do `DB.Preload()` deixava jobs de `load_threaded_request` sem join — o engine destrói o worker enquanto ele parseia sob um script cache que o teardown já estava liberando (evidência: `Parse Error` não-determinístico em `script = ExtResource(...)` de `.tres`, aviso `~Thread`, 362 ObjectDB instances vazadas). Criado `DB.DrainPendingPreloads()` (join bloqueante + limpa a continuation `process_frame`), chamado por `Launcher._exit_tree()` — último hook com árvore viva — e por `DB.Clear()`. (2) `tests/test_backup_restore.gd` instancia `SQLBackups`, cujo `_init()` dispara um worker que chama de volta `Launcher.World/Economy` e sobrevivia ao `quit()`; o probe recolhe o worker e `SQLBackups._exit_tree()` agora chama `Stop()` para qualquer holder. A/B: sem drain crash 1/1 + 5 parse errors + 362 leaks; com drain 0/0/19; com o worker do backup recolhido também **8/8 limpo** (~8 s). Armadilhas evitadas no caminho: `ResourceLoader.THREAD_LOAD_NOT_IN_QUEUE` e `SceneTree.tree_exiting` não existem em Godot 4 (o segundo abortava `Launcher._ready()` em silêncio). Radar: o probe retorna exit 0 mesmo quando o engine segfaulta, então o job `backup-restore` do CI não enxerga essa classe de falha. Revalidado após o fix: idle exit 0 / 0 falhas, benchmarks 0 falhas, 3 probes crash=0 warn=0, gate OK.
- [ ] S2: AH seed de bots + crash-test duplicação
