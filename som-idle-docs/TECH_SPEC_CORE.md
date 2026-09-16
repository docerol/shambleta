# TECH_SPEC_CORE — SOM-IDLE

Documento de contrato técnico do pivô idle do Shambleta. É a fonte de verdade
para arquitetura, invariantes e parâmetros de sistema citados no código e em
`som-idle-docs/D1_GATE_REPORT.md`. Reconstruído em 2026-09 a partir do código
em produção e das mensagens de commit `SOM-IDLE`, para fechar a lacuna de este
arquivo ser citado (§2, §4, §11) sem existir no repositório.

Qualquer mudança de parâmetro citado aqui deve atualizar este documento no
mesmo commit que muda o código (ver `ECONOMY_STUDY.md` e `XP_PROGRESSION.md`
para os parâmetros de economia/progressão especificamente).

## §1. Visão geral

Shambleta é um MMORPG 2D (Godot 4, cliente/servidor autoritativo, fork de
*Source of Mana*) convertido em um idle/AFK-farm: o personagem entra em uma
"farm instance" de uma zona e o `IdlePolicy` assume o combate automaticamente
(login já entra em farm — "idle-first"; `/farm <n>` troca de zona; `/farm
stop` devolve controle manual para o caminho "adventure" original, que
permanece intacto).

Serviços centrais (`sources/idle/`, `sources/economy/`):

| Serviço | Arquivo | Responsabilidade |
|---|---|---|
| `IdlePolicy` | `IdlePolicy.gd` | Máquina de estados do auto-combate de uma sessão (seek → combat → loot → auto-poção), por personagem |
| `IdlePolicyService` | `IdlePolicyService.gd` | Orquestra o ciclo de vida das sessões idle (start/stop/attach) e o gate de login idle-first |
| `FarmZoneData` | `FarmZoneData.gd` | Catálogo estático das 24 zonas de farm (curva de XP/ouro/par, ver `XP_PROGRESSION.md`) |
| `OfflineSettle` | `OfflineSettle.gd` | Liquida o progresso acumulado enquanto o jogador estava desconectado |
| `BossService` | `BossService.gd` | Sistema de chave de farm → duelo de boss escalado ao nível do personagem |
| `RebirthData` | `RebirthData.gd` | Contrato numérico do renascimento (cap L60, divisor de essência, loja `base × 1.7^n`, favores `1.05^n`, cap do attune) — pura, sem I/O |
| `EconomyService` | `EconomyService.gd` | Ledger de ouro/XP/gems/itens/**essência**, trade P2P, baús (provably-fair), grants de pagamento, loja e ato de renascimento (`BuyRebirthUpgrade`/`Rebirth`) |
| `TelemetryService` | `TelemetryService.gd` | Buffer de eventos de produto (login/settle/levelup), flush periódico para `telemetry_event` |

## §2. Farm spawns e respawn (por zona)

Cada zona de farm escala a própria densidade de spawn do mapa, em vez de
herdar a densidade do mapa de aventura original:

- **Multiplicador de spawn** = `2 + tier` (tier 1 → 3×, tier 8 → 10× a
  contagem base de grupos do mapa).
- **Respawn** = `18s − 2s × tier`, limitado a `[4s, 16s]` (tier 1 → 16s,
  tier 8 → 4s).
- Itens dropados vêm de uma banda de tier `[tier, min(tier+1, 8)]`; pool vazio
  cai para o item padrão (Maçã, cura).

## §3. Relógio de tick do IdlePolicy (D1 — normalização de tempo real)

Resolvido no `som-idle-docs/D1_GATE_REPORT.md` após um bug de dois relógios
(policy no clock de render, combate no clock de física):

- `WorldInstance` bombeia `IdlePolicy.Tick` em `_physics_process` — o mesmo
  clock dos agentes de combate, não mais `_process` (render).
- `IdlePolicy.Tick(delta)` roda em substeps de cadência fixa,
  `TickInterval = 0.25s` de jogo, com teto `MaxCatchUpSeconds = 2.0`
  (≤ 8 substeps por pump, protege contra pumps patológicos sob carga).
- A cadência de decisão do bot é assim independente de FPS e de
  `Engine.time_scale`.

## §4. Pacing (banda de kills/hora)

**§4.1.1 — banda de tempo real (gate de teste, D1):**
piso `30 kills/h`, teto de sanidade `200 kills/h` (medido saudável:
~80/h standalone na zona 1, 36–48/h em suíte completa sob carga; ver
D1_GATE_REPORT para o histórico da recalibração 60→30).

Curva de par por zona documentada em `XP_PROGRESSION.md §4.1.2` (usada tanto
para o ritmo esperado online quanto para a liquidação offline).

## §5. Item invariants (baús e grants)

- **Invariante 1** — todo grant de item via `_GrantStackRaw` tem espelho no
  ledger (auditoria: nenhuma criação de item silenciosa).
- **Invariante 3** — fee de trade é o sink primário da economia; gems gastas
  em fee não são cashable (ver `ECONOMY_STUDY.md §6`).
- **Invariante 4** — abertura de baú é provably-fair: roll determinístico via
  hash de `server_seed + client_seed + nonce`; odds públicas (`/chests`) e
  snapshot persistido por baú aberto, para replay em disputa (ver
  `ECONOMY_STUDY.md §7`).
- **Invariante 5 (rebirth)** — renascer exige o **agente vivo no cap** (offline
  responde `not_online`, abaixo do cap responde `below_cap`); contador + reset de
  `level/experience/gp` acontecem em **uma única transação**, e o cache de
  multiplicadores só é invalidado depois do commit. Nenhum outro estado é
  tocado: equipamento, chaves, essência e favores sobrevivem ao reset.
- **Invariante 6 (essência)** — o excedente de XP do cap é convertido em chunks
  inteiros do divisor (100 XP : 1), nunca em fração: o resto continua no bucket
  de XP. Online (`Stats.AddExperience`) e offline (`OfflineSettle._Apply`) usam o
  mesmo `RebirthData.EssenceDivisor`, então a taxa é idêntica nos dois caminhos.

## §6/§7 — ver `ECONOMY_STUDY.md`

Fee de trade, pity de baú, VIP e boss economy estão documentados em detalhe em
`ECONOMY_STUDY.md`, que é o contrato de economia propriamente dito.

## §11. Infraestrutura e escala

- **Servidor de jogo**: Godot headless server-authoritative (build "Linux/X11
  Headless Server").
- **Companion**: servidor Python (`companion/server.py`) — webhook de
  pagamento (assinatura de provedor, catálogo autoritativo de SKU,
  `grant_queue` idempotente por `payment_id`), métricas (`/metrics`),
  alerta/uptime opt-in.
- **Persistência**: SQLite/WAL em nó único, tanto para o servidor de jogo
  quanto para o companion. Escolha deliberada para validar produto antes de
  escalar; **teto de escala conhecido** (ver auditoria comercial,
  `auditoria-shambleta-idle-comercial.md` item 11).
- **Gatilho de migração** (a definir por CCU ou volume de transação/minuto):
  companion reescrito (Go/Node) + Postgres. A tabela `grant_queue` e sua
  idempotência por `payment_id` foram desenhadas para sobreviver à migração
  sem mudança de contrato.
- **Web**: export Web (HTML5/WASM) é o pivô idle priorizado ("web-first").
  Ver `deploy/WEB_SLIM.md` para o orçamento de payload (~32 MB gzip no
  primeiro load, meta <25 MB) e `deploy/COOLIFY.md` para a stack de deploy
  (web/game/companion via Coolify, proxy-TLS).
