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
- [ ] S3: fatiar `EconomyService.gd` — FATIA 1 FEITA: `EconomyCatalog.gd` (605 linhas, 114 consts + 18 puros) + wrappers; BLOQUEIO ANTERIOR REMOVIDO (network destravado, suíte 1122 checks/25 fails pré-existentes)
- [ ] S2: AH seed de bots + crash-test duplicação
