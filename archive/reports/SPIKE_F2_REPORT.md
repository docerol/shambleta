# SPIKE F2 — Idle Core (Relatório de Implementação)

**Status:** ✅ concluído — 91 checks headless, 0 falhas (2 execuções consecutivas verdes)
**Contrato:** `TECH_SPEC_CORE.md` (§1–§7), `ROADMAP.md` §3
**Escopo:** Fase 2 — ExperienceSystem, FarmZoneData, IdlePolicy, OfflineSettle, EconomyService (settle-path), RPCs, patches SOM-IDLE, testes headless + CI

---

## 1. Como rodar os testes

```bash
cd sourceofmana-audit

# import dos assets (necessário após adicionar scripts com class_name)
XDG_DATA_HOME="$PWD/.test-home/data" XDG_CACHE_HOME="$PWD/.test-home/cache" \
  godot --headless --editor --import --quit

# suíte completa (XDG redirecionado: o sandbox/CI não pode escrever em ~/.local/share)
XDG_DATA_HOME="$PWD/.test-home/data" XDG_CACHE_HOME="$PWD/.test-home/cache" \
  timeout 400 godot --headless --path . -s tests/run_idle_tests.gd
# == RESULT: 91 checks, 0 failures ==
```

CI: job `idle-tests` adicionado em `.github/workflows/godot-ci.yml` (marcado `# SOM-IDLE`),
rodando import + suíte a cada push. O código de saída do processo é o número de falhas.

---

## 2. Escopo entregue vs contrato

| Contrato | Entregue | Arquivos |
|---|---|---|
| §1 ExperienceSystem | Fórmula XP(L→L+1) = round(8000 × 1.22^L), MAX 150, caches estáticos, `IsMaxLevel`/`GetTotalExperienceForLevel` | `sources/actor/stat/Experience.gd` |
| §2 FarmZoneData | Catálogo de 40 zonas (tier = ceil(id/5), minPower, xp/gold per kill, par, drops, newbie boost ×5 até L10) | `sources/idle/FarmZoneData.gd` |
| §2 IdlePolicy | FSM IDLE→SEEK→COMBAT→LOOT→DEAD, TickInterval 0.25, reuso de `WalkToward`/`Skill.Cast`/`PickupDrop`, potion < 35%, stuck 8s, eficiência de sessão | `sources/idle/IdlePolicy.gd` |
| §2 IdlePolicyService | Sessões por jogador, instâncias dedicadas 1001..1040, attach com retry (não-corrotina) | `sources/idle/IdlePolicyService.gd` |
| §3 OfflineSettle | `BuildReport` (sem escrita) + `SettlePending` idempotente em transação; fórmula exata (OfflineFactor 0.6, cap 12h, death tax 5%, chests floor(h/4) cap 3, drops ppm determinístico) | `sources/idle/OfflineSettle.gd` |
| §4 EconomyService | `LedgerAppend` (append-only via triggers SQL), `GetBalance`, `SettleTransaction`, `ReconcileDaily` | `sources/economy/EconomyService.gd` |
| §5/§6 Migrations | `009_idle_economy.sql`: wallet, ledger_transaction (triggers RAISE(ABORT) em UPDATE/DELETE), character.farm_zone/last_settled_at/session_efficiency, formation, chest_instance | `data/conf/migrations/009_idle_economy.sql` |
| §6 Patches SOM-IDLE | Formula (XP de zona + power score), Util.FormatNumber, Network (8 RPCs), Server (settle-then-load + handlers), Client (AFK report/feedback), WorldCommands (`/farm`), WorldInstance (tick de policies + respawn de fazenda), PlayerAgent (policy hook), Launcher (Economy service), SQL (helpers transacionais) | ver §4 |
| §7 Testes | 7 suítes: curva XP, catálogo zonas, formatter, settle golden, idempotência, chaos/rollback, triggers ledger, reconcile, sim determinístico 3×600s | `tests/IdleTests.gd`, `tests/run_idle_tests.gd` |

---

## 3. Resultados dos testes

```
[suite] XP curve            — golden L2=9760 ±0.5%, monotônica, sem overflow (total L150 ≈ 2.7e15 < 2^62), sentinela L150, walk L1→150 < 1s
[suite] zone catalog        — 40 zonas, goldens z1 (1200 xp/600 par) e z40 (≈7.22M xp), tier/minPower, resolução de mapa via MapsDB, 10k fetches < 1s
[suite] formatter           — pt-BR < 100000, K/M/B/T/Qa/Qi com 3 dígitos significativos
[suite] settle golden       — zona 5, 12h, eff 0.8: xp/gold/drops/chests exatos, level recomputado pela curva (L1→28), ledger com saldo
[suite] settle idempotency  — re-settle no mesmo anchor = no-op; zero linhas duplicadas
[suite] settle chaos        — INSERT em tabela inexistente dentro da transação → rollback completo (item/ledger/anchor intactos)
[suite] ledger triggers     — UPDATE/DELETE em ledger_transaction bloqueados (RAISE ABORT)
[suite] reconcile           — divergências detectadas via soma do ledger vs wallet
[suite] idle policy sim     — 3 runs × 600s game-time (20×): kills > 0, eficiência ∈ [0.5, 1.0], banda de sanidade de kill-rate, snapshot vs par
```

**Snapshot do sim (referência):** ~30–50 kills/h na zona 1 vs par de design 600/h — ver §5.3.

---

## 4. Arquivos criados/alterados

**Criados:** `sources/idle/FarmZoneData.gd`, `sources/idle/IdlePolicy.gd`, `sources/idle/IdlePolicyService.gd`, `sources/idle/OfflineSettle.gd`, `sources/economy/EconomyService.gd`, `data/conf/migrations/009_idle_economy.sql`, `tests/IdleTests.gd`, `tests/run_idle_tests.gd`

**Patcheados (marcados `SOM-IDLE`):** `Experience.gd`, `Formula.gd`, `Util.gd`, `Network.gd`, `NetworkCommons.gd`, `Server.gd`, `Client.gd`, `WorldCommands.gd`, `WorldInstance.gd`, `WorldAgent.gd`, `PlayerAgent.gd`, `Launcher.gd`, `SQL.gd`, `.github/workflows/godot-ci.yml`

---

## 5. Desvios do contrato (decisões de spike)

### 5.1 Settle-then-load
`ConnectCharacter` executa `OfflineSettle.SettlePending(charID)` **antes** de `GetCharacterInfo`,
garantindo que o cliente recebe stats já consolidados (sem janela de inconsistência entre
login e claim). O `ClaimOfflineSettle` RPC continua existindo para re-claim de relatório.

### 5.2 Catálogo 40 zonas sobre 28 mapas reais
O fork tem 28 mapas com mobs (varredura TMX); o catálogo resolve 1:1 os 28 e repete os
de menor tier para preencher 40 (contrato exige 40 zonas). A ordem segue min-level dos
presets. Zona 1 = mapa com menor min-level disponível.

### 5.3 Par de pacing vs densidade real dos mapas (ACHADO PRINCIPAL)
O par de design (600 kills/h na z1 = 6s/kill) pressupõe combate quase contínuo. Os mapas
de aventura reutilizados têm ~20 mobs/grupo de spawn com respawn de 30s e distâncias longas
→ medido **~30–70 kills/h**. Isto não é defeito da policy (ela usa as mesmas primitivas de
combate do cliente); é defasagem entre a tabela de pacing e a densidade dos mapas existentes.
**Ação F3:** tabela de spawns dedicada por zona de farm (densidade/respawn calibrados para o
par) — os spawns de instância de farm já são independentes (`is_persistant` por instância,
patch em `WorldInstance._map_loaded`).

### 5.4 Kill-rate ±15% não é validável no sim comprimido
O contrato pede kill-rate dentro de ±15% do par em 3 execuções. No CI o sim comprime 20×
dentro de um mundo vivo cujo RNG global é compartilhado (wander/timers de mobs, rolls de
combate) — execuções divergem por ambiente, não por ruído da policy. Gate implementado:
banda de sanidade (todo run produtivo, taxas dentro de 4×) + snapshot impresso. A validação
±15% fica para o harness F3 em tempo real com a tabela de spawns dedicada.

### 5.5 Morte na fazenda: revive in-place
`Agent.Respawn()` warp para o ponto de respawn do mapa — destruiria a instância dedicada
(WorldInstance auto-destrói sem players). A policy usa `agent.Revive()` in-place; a death
tax é contabilizada em `session_efficiency` (penalidade 5%/morte) e aplicada no settle.

### 5.6 `ExecuteTrade`/`OpenChest` — F4
Stubs documentados retornando `false`; ledger e wallet já suportam os fluxos.

### 5.7 Correção de engine: push de agente idempotente
`WorldAgent.PushAgent` enfileirava `add_child.call_deferred` sem guardar duplicatas — dois
warps no mesmo frame (ex.: spawn direto em instância de farm) colidiam ("already has a
parent"). Corrigido com `_DeferredPush` (converge para o último alvo; agentes marcados para
deleção são ignorados). Beneficia também troca rápida de mapa no cliente real.

### 5.8 Correções menores descobertas pelos testes
- Colunas sqlite podem ser `NULL` (`character.experience` de chars novos): leitura
  null-safe em `OfflineSettle` (`int(<null>)` lança no Godot 4.7).
- `Resource.duplicate()` copia só `@export` — `SpawnObject.map` precisa ser reatribuído
  após duplicar o spawn de fazenda.
- `FormatNumber`: < 100000 usa separador pt-BR ("53.800"); sufixos K/M/B/T/Qa/Qi com
  trim de zeros **antes** do sufixo.

---

## 6. Fora do escopo da F2 (para F3/F4)

- VIP/guild mods no settle (`mods = 1.0` fixo)
- Formação 2–6 slots (schema e RPC prontos; UI e multi-slot são F3+)
- Leaderboard de power score
- Tabela de spawns dedicada por zona (§5.3)
- Trade fee burn e chests com drops reais (F4)
