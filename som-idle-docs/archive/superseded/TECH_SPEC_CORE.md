# Tech Spec — Módulos da Fase 2 (Core Idle)

**Versão:** 1.0 (2026-09-09) · Relacionados: [ARCHITECTURE.md](ARCHITECTURE.md) · [XP_PROGRESSION.md](XP_PROGRESSION.md) · [ROADMAP.md](ROADMAP.md)
**Propósito:** especificação implementável (contratos, assinaturas, fluxos, critérios de aceite) dos 4 módulos do MVP. **Ainda não é código** — é o contrato que o código deverá cumprir. Convenções seguem o codebase existente (`ServiceBase`, `static func`, tipos explícitos, `class_name`).

---

## 0. Convenções e integração com o codebase

- **Serviços** estendem `ServiceBase` (`sources/system/ServiceBase.gd`) e são instanciados/registrados em `Launcher.gd` (padrão `SQL`, `Discord`, `Email`), com `_post_launch()` para dependências entre serviços.
- **Client-side** e **server-side** vivem no mesmo projeto: todo serviço checa `Network.Client`/servidor ativo antes de agir (padrão de `DB.StripUnused` e handlers `NetClient`/`NetServer`).
- **RPCs** declarados em `sources/network/Network.gd` com `@rpc("any_peer"|"authority", ...)` + handler em `sources/network/server/Server.gd` (validação) e `sources/network/client/Client.gd` (efeito local). Rate-limit via `Peers.Footprint`.
- **Nomeação:** módulos novos em `sources/idle/` e `sources/economy/` (política de fork ARCHITECTURE §13). Patches em arquivos upstream marcados `# SOM-IDLE:`.
- **Persistência:** sempre via `SQL.gd`/`QueryBindings`; novas tabelas só por migration (nunca editar 001–008).

## 1. `ExperienceSystem` (reescrita de `sources/actor/stat/Experience.gd`)

**Tipo:** patch substitutivo (arquivo upstream, mudança mínima mantendo a API pública).

```gdscript
# API pública preservada:
static func GetNeededExperienceForNextLevel(currentLevel : int) -> int  # idêntica assinatura
const MAX_LEVEL_REACHED : int = 0

# Novo contrato:
const MAX_LEVEL : int = 150
const XpBase : int = 8000          # XP(L→L+1) = round(XpBase * Growth ^ L)
const Growth : float = 1.22
static func GetTotalExperienceForLevel(level : int) -> int   # soma cumulativa (cache)
static func GetLevelProgress(experience : int, level : int) -> float  # 0.0..1.0 p/ barra UI
static func IsMaxLevel(level : int) -> bool
```

**Fluxo:** `AddExperience` (`Stats.gd:207`) permanece; o `while` de level-up usa a fórmula. Tabela hardcoded removida; `MAX_LEVEL` substitui o fim da tabela (acima = `MAX_LEVEL_REACHED`).

**Aceite:** (a) L2 → 9.760 XP (±0,5%); (b) L150 → 1,39e15 XP sem overflow (teste int64); (c) clientes antigos sincronizam pois `experience` é absoluto (sem migração de schema); (d) headless test cobre L1→150 em < 1s.

## 2. `IdlePolicy` (`sources/idle/IdlePolicy.gd`)

**Tipo:** módulo novo. **Responsabilidade:** substituir o input humano por política de combate, por personagem, dentro do `WorldInstance` da zona de farm.

```gdscript
extends RefCounted
class_name IdlePolicy

var agent : PlayerAgent                     # dono da política
var zone : FarmZoneData                     # dados da zona (tier, gates, drops, xp_per_kill)
var tickAccumulator : float = 0.0
const TickInterval : float = 0.25           # 4 decisões/s — suficiente p/ idle, barato

func Setup(p_agent : PlayerAgent, p_zone : FarmZoneData) -> void
func Tick(delta : float) -> void            # chamado pelo WorldInstance da zona (server only)
func ComputeSessionEfficiency() -> float    # 0.5..1.0 — alimenta settle (§3)
func Halt(reason : String) -> void          # morte/travamento → respawn ou fim de sessão
```

**Máquina de estados (por tick):** `IDLE → SEEK (alvo mais próximo elegível; reusa navegação/AI existente) → COMBAT (skill por prioridade do loadout; reusa `Skill.Cast`) → LOOT (coleta reusando `WorldDrop.PickupDrop`) → SEEK…` com transição `DEAD → respawn na entrada da zona (contabiliza death tax)` e failsafe `STUCK > 8s → re-target/respawn`.

**Regras invioláveis:** (1) roda **apenas server-side** (guard `if not Network.is_server(): return`); (2) usa apenas ações que um cliente real poderia emitir (nenhum atalho de dano/teleport); (3) consumível se HP < `auto_potion_pct` (default 35, da `formation`); (4) sem interação com jogadores sociais (zonas separadas, ARCHITECTURE §7).

**Aceite:** 1 char farma zona 1 por 10 min com zero intervenção; `session_efficiency` ∈ [0.5, 1.0]; kill-rate dentro de ±15% do par da zona em 3 execuções; trava de segurança: policy sem `zone` válida não executa nada.

## 3. `OfflineSettle` (`sources/idle/OfflineSettle.gd`)

**Tipo:** módulo novo (server). **Responsabilidade:** converter tempo offline em recompensas por fórmula, atomicamente, com relatório.

```gdscript
extends RefCounted
class_name OfflineSettle

const OfflineFactor : float = 0.6
const BaseCapHours : int = 12               # VIP estende (ECONOMY §3)

static func SettlePending(charID : int) -> SettleReport      # idempotente por last_settled_at
static func BuildReport(charID : int) -> SettleReport        # leitura p/ UI (sem mutação)

class SettleReport:
    var hours : float
    var xp : int; var gold : int
    var drops : Array[Dictionary]            # [{item_hash, count}]
    var chests : Array[int]                  # chest_instance ids ganhos
    var efficiency : float
    var deaths : int
```

**Fórmula (contrato, XP_PROGRESSION §4 + ARCHITECTURE §8):**
`gold = zone.gold_per_hour × h × eff × OfflineFactor × mods` · `xp` análogo com `xp_per_kill` da zona · drops = rolagem `rate_ppm × h × 3600 × eff × OfflineFactor × mods` · `mods = (1+guild) × (1+vip) × events`.

**Atomicidade:** settle inteiro em `BEGIN/COMMIT` (SQL transacional) escrevendo: `character_settle.last_settled_at`, `stat.experience/gp`, `item`, `ledger_transaction(kind=settle)` e `chest_instance` — ou nada.

**Idempotência:** `SettlePending` re-lido 2× no mesmo ms não duplica (chave temporal em `character_settle`); claim automático no login (`Server.gd` handler `SelectCharacter` → após `SetCharacterInfo`), + RPC manual `ClaimOfflineSettle()`.

**Aceite:** (a) settle 12h zona 5 → valores = fórmula (teste de ouro fixo); (b) crash simulado entre INSERTs → rollback completo (teste de caos); (c) 2 logins simultâneos (multi-abas) → 1 settle só; (d) AFK Report exibe todos os deltas do ledger.

## 4. `EconomyService` (`sources/economy/EconomyService.gd`)

**Tipo:** serviço (`ServiceBase`) registrado no Launcher, server-only. **Responsabilidade:** ponto único de mutação de moedas/itens com ledger append-only.

```gdscript
extends ServiceBase
class_name EconomyService

# Moedas (wallet cache + ledger)
func GetBalance(accountID : int) -> Dictionary              # {gold, gems} (cache, recomputável)
func Grant(accountID : int, currency : String, amount : int, kind : String, reason : String) -> bool
func Spend(accountID : int, currency : String, amount : int, kind : String, reason : String) -> bool

# Itens (item_uid)
func GrantItem(accountID : int, itemHash : int, count : int, reason : String) -> bool
func RemoveItem(accountID : int, uid : String, reason : String) -> bool

# Composição (transacionais)
func SettleTransaction(charID : int, report : OfflineSettle.SettleReport) -> bool
func ExecuteTrade(offer : Dictionary) -> bool               # escrow atômico + fee burn
func OpenChest(accountID : int, chestID : int, keyHash : int) -> Dictionary

# Reconciliação
func ReconcileDaily() -> Dictionary                         # soma(ledger) == saldos == inventários
```

**Invariantes (testes de aceite obrigatórios):** (1) nenhuma mutação sem linha `ledger_transaction`; (2) `balance_after` sempre consistente sob serialização do mutex; (3) `ExecuteTrade` é all-or-nothing (teste de corrida 2 trades no mesmo item); (4) `OpenChest` grava `odds_snapshot` + seeds (provably-fair); (5) triggers SQL rejeitam UPDATE/DELETE no ledger; (6) `ReconcileDaily` retorna divergência zero em operação normal.

## 5. RPCs da F2 (contrato final)

| RPC (Network.gd) | Handler server (Server.gd) | Handler client (Client.gd) | Nota |
|---|---|---|---|
| `SetFormation(f : Dictionary)` | valida chars da conta + loadout → `formation` | persist local p/ UI | 5/min |
| `SetFarmZone(zoneID : int)` | valida power gate → alterna `WorldInstance` da policy | feedback + troca de câmera | 5/min |
| `ClaimOfflineSettle()` | dispara `SettlePending` se pendente | abre AFK Report | 1/login |
| `GetAFKReport()` | `BuildReport` | render relatório | 1/min |
| `GetSeasonPass()` | leitura estado PT | UI passe (F4) | 1/min |

*Nada de RPC de combate/posição no idle — a superfície é só configuração/consulta.*

## 6. Ordem de implementação dentro da F2 (com dependências)

```
Semana 1-2: ExperienceSystem  →  farm_zone data (40 zonas)  →  spike IdlePolicy (zona 1, 1 char)
Semana 3-4: OfflineSettle (+ledger mínimo da F1 já pronto)  →  AFK Report UI
Semana 5-6: Formação (1→5 slots) + Zone Map + Power Score   →  instâncias de farm separadas
Semana 7-8: integração/telemetria + caos (crash tests)      →  beta fechado interno
```

**Definition of Done da F2:** jogador cria conta → entra → monta loadout → escolhe zona → observa farm online → fecha aba → volta 8h depois → coleta AFK Report correto → sobe níveis com XP granular → aparece no leaderboard de power. Tudo no browser (WSS), com 0 duplicação sob testes de caos.

## 7. Plano de testes (headless Godot no CI)

1. **Curva XP:** propriedades (monotônica, sem overflow, valores de ouro L2/L30/L150).
2. **Settle:** golden tests de fórmula, idempotência, atomicidade (kill -9 no meio → rollback), VIP/guild mods.
3. **Ledger:** invariante append-only, reconciliação, fee burn no trade.
4. **IdlePolicy:** 30 min de farm simulado determinístico (seed fixa) → snapshot de kill-rate/efficiency.
5. **Integração:** login → settle → claim → stat sync (`UpdatePrivateStats`) → UI numbers formatados.

## 8. Riscos técnicos específicos desta spec

| Risco | Mitigação |
|---|---|
| IdlePolicy divergir do combate "real" (skill cast falha silenciosa) | Reuso estrito de `Skill.Cast`/`AI` existentes + teste determinístico com seed |
| Settle disputado entre logins paralelos (multi-abas) | Mutex por char + coluna `last_settled_at` como trava lógica |
| Zonas de farm poluírem instâncias sociais | Instâncias dedicadas por zona (ARCHITECTURE §7) com cap e sem chat |
| Deriva de pacing (efficiency ≠ par) | Telemetria `time_to_level` por zona desde o 1º spike |
