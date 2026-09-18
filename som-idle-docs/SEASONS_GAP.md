# Seasons — Gap Técnico (F4) — REVISADO 2026-09-18

**Status anterior (desatualizado):** dizia que snapshot + 4 corridas "não estão
implementadas". **Verificação contra o código em 2026-09-18: estão.**

| Peça (ROADMAP §F4) | Código | Teste |
|---|---|---|
| Snapshot Power | `EconomyService.SnapshotSeasonPower` (top por `power_score`) | `SuiteSeasonAH` ("power snapshot") |
| Snapshot Spend | `SnapshotSeasonSpend` (gasto de gems do ledger desde `starts_at`) | `SuiteSeasonAH` ("spend snapshot") |
| Snapshot Boss Kills | `SnapshotSeasonBossKills` (por char) | `SuiteSeasonRaces` ("boss snapshot 1 row") |
| Snapshot Guild Points | `SnapshotSeasonGuildPoints` (por guild, de `GuildSettlePoints` + vitória de boss) | `SuiteSeasonRaces` ("guild snapshot 1 row") |
| 4 boards nomeados | `GetSeasonBoardsState` (power/spend/boss_kills/guild_points) | `SuiteSeasonRaces` + boards |
| Premiação não-cashable | `SettleSeasonPrizes` (gems/cosméticos por colocação, top-N) | `SuiteSeasonPayout` |
| Fechamento automático | `TickSeasonLifecycle` (fecha vencidas + liquida fechadas, idempotente) | `SuiteSeasonPayout` |
| Congelamento de regras | `season.rules_frozen` (gravada em `CreateSeason`) | — |

**O que resta de verdade (não é código):** a decisão de live-ops que o próprio
ROADMAP §F4 exige — regras congeladas + changelog público **por temporada**.
**Decisão do dono (2026-09-18): PÓS-LANÇAMENTO** — a 1ª temporada competitiva
não entra no lançamento; loja/passe funcionam sem as corridas até lá. Quando
ativar: congelar regras + publicar changelog, sem código novo. Suíte: 1015
checks, 0 failures.
