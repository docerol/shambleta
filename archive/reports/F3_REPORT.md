# F3 — Implementation Report

**Commit:** `383a1a8` (branch `master`, pushed)
**Base:** SPIKE_F2_REPORT deviations + TECH_SPEC_CORE §2/§3/§5
**Testes:** `== RESULT: 118 checks, 0 failures ==` (fresh install, migration chain 001→010)

## Escopo entregue

| Feature | Implementação |
|---|---|
| **Spawns dedicados por zona** | Farm instances não copiam mais a densidade do mapa de aventura: `FarmZoneData.GetFarmSpawnMultiplier(zone)` = `2 + tier` (T1→3x … T8→10x) aplicado a cada spawn group; respawn `18s − 2s·tier` clampado a [4s, 16s] (`WorldInstance._map_loaded`). |
| **Tiers de item** | Campo `ItemCell.tier` (1..8). Os 65 presets foram tierados por banda de poder (maior modificador "de poder" ÷ 25): T1×55, T2×1 (Desert Armor), T3×3, T4×3, T5×3 (Cleaver, Rock Knife…). Sem arte nova — tier é atributo, não sprite. |
| **Drop pools por tier** | Zona derruba itens da banda `[tier, tier+1]`; pool vazio cai uma banda abaixo; fallback final Apple. Pick determinístico `(charID + zoneID) % pool`. |
| **Mods VIP no settle** | `account.vip_until` (migration 010); janela ativa multiplica o faucet offline (xp/gold) por **1.2** (`MONETIZATION §2.2` — VIP vende respeito ao tempo, +20% só na camada idle). Guild hook fixado 1.0 (F4). Report expõe `mods` para auditoria. |
| **Leaderboard de power score** | `character.power_score` cacheado no connect/disconnect (`level*10 + attack + defense`); `GetLeaderboard(50)` join account+stat; comando `/top` renderiza top 10 via notification (convenção F2). |
| **Formation slots (2–6)** | `character.formation_slot` seleciona o loadout no attach (`/farm <zone> <slot 0-5>`); `GetFormationForSlot(account, slot)`; `SaveFormation` corrigido (upsert que nunca gravava — ver bugs). |
| **Zone map UI (chat)** | `/zones` lista as 40 zonas com tier, gate de power e status OPEN/LOCKED. |
| **VIP status** | `/vip` consulta o estado da janela (RPC `GetVIPState`/`VIPState`). |

## Bugs reais encontrados durante a implementação

1. **`SaveFormation` nunca gravava slot novo** — `db.update_rows(...) or db.insert_row(...)`: `update_rows` retorna `true` mesmo com 0 rows afetadas, curto-circuitando o insert. Corrigido com gate de existência.
2. **`select_rows` com `;` final retorna 0 rows** — `GetVIPUntil` usava `"account_id = %d;"`; o conector ignora a query silenciosamente. Trocado por `QueryBindings` parametrizado.
3. **`c.level` não existe** — `level` vive na tabela `stat`, não em `character`; leaderboard corrigido com join.

## Desvios e decisões (documentados)

- **Kill rate do sim: ~15–24/h vs par 600/h (−96%).** Os multiplicadores de spawn (3x–10x) melhoram a densidade mas o gargalo medido não é densidade: é o *kill time* do mob L1 vs xp/kill da zona + walk time. A cadeia completa par→xp/kill→density é recalibração de balance (F4/pre-launch), não estrutura — a estrutura (spawn table + respawn + par por zona) está em cima da mesa e parametrizada.
- **Tiers T6–T8 sem itens.** Só existem 65 itens; bandas altas ficam vazias até conteúdo novo ser criado. O sistema já aceita (drop pool cai com fallback). Criar itens T6+ é job de conteúdo, não de código.
- **VIP ainda não é comprável** — o schema e os mods existem; o *checkout* (gems → vip_until) é a camada de monetização (EconomyService), planejada no bloco de monetização real (F4+/launch).
- **UI gráfica para slots/leaderboard** fica para o polish de GUI; hoje tudo é acessível por comandos de chat (convenção do spike F2, `/farm`).

## Testes novos (5 suítes, +27 checks)

- `SuiteItemTiers` — todos os presets dentro de [1..8]; pools de drop resolvem; pick determinístico
- `SuiteFarmSpawnTable` — multiplicador ≥ 3; respawn monotônico decrescente com tier; floor respeitado
- `SuiteVIPMods` — mods 1.0 sem VIP; ×1.2 com VIP ativo (xp = base × 1.2 exato); 1.0 com VIP expirado
- `SuiteLeaderboard` — cache de power score; ordenação DESC; fixture presente com score
- `SuiteFormationSlots` — `formation_slot` persiste no character row; save/load por slot com auto-potion
