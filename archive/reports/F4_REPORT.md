# F4 — Implementation Report

**Branch:** `master` (pushed)
**Base:** F3_REPORT deviations + ECONOMY_STUDY §6/§7 + MONETIZATION §2.2 + TECH_SPEC_CORE §4 (invariantes 1–4)
**Testes:** `== RESULT: 155 checks, 0 failures ==` (fresh install, migration chain 001→010)

## Escopo entregue

| Feature | Implementação |
|---|---|
| **Trade P2P real** | `EconomyService.ExecuteTrade(from, to, itemsFrom, itemsTo)` substitui o stub: escrow validado dentro da transação (toda stack ofertada deve existir com a contagem exata), troca all-or-nothing, taxas queimadas antes do movimento. Rejeita: auto-trade (`charIDFrom == charIDTo`), stacks insuficientes, saldo de gems menor que a taxa — tudo com rollback do lambda (nada é persistido parcialmente). |
| **Taxa de trade (sink primário)** | `TradeFeeGems = 10` gems fixas, queimadas da wallet do iniciador (`ECONOMY_STUDY §6`: fee é o sink primário; gems não-cashable). Row de ledger `trade_fee` espelha o burn; ambas as pernas da troca geram rows `trade_out:hash` / `trade_in:hash`. Merge no receptor: stack existente soma, ausente cria row nova. Stack zerada no remetente é deletada (schema sem rows-count 0). |
| **Baús com drop real** | `EconomyService.OpenChest(charID, chestID)` substitui o stub: valida `item_state='closed'`, resolve o pool pela zona do farm do personagem (fallback zona 1), rola determinístico e entrega o item no inventário. Baú vai para `item_state='opened'`, ledger espelha `chest:<id>|<item>|<clientSeed>`. Rejeita id inexistente e double-open (estado já `opened`). |
| **Provably fair + pity** | Roll = `SHA256(HashPassword(serverSeed, clientSeed))` primeiros 8 hex chars → índice do pool. `serverSeed = "<chestId>:<createdAt>:shambleta"` (derivável da row — não precisa coluna extra), `clientSeed = "<charID>:<nonce>"` com `nonce` = nº de baús abertos do personagem. Pity: a cada 10ª abertura (`ChestPityEvery = 10`) o pool é filtrado para T3+ (`ECONOMY_STUDY §7`). Seeds retornam no dict de resultado para auditoria do jogador. |
| **Checkout VIP real** | `EconomyService.PurchaseVIP(accountID, tier)` substitui o stub: valida tier (1/2), debita gems da wallet (source of truth) dentro de transação, estende a janela a partir de `maxi(now, vipUntil atual)` (stack correto: compra com janela ativa soma 30 dias; compra expirada recomeça de agora), espelha `vip<N>_purchase` no ledger. Rejeita tier inválido e saldo insuficiente — sem debito parcial. |
| **Wallet de gems** | `AddGems`/`GetGems` reais (antes eram stubs): debit/credit com validação de saldo, settleMutex + Transaction, ledger kind `gems`. `GetGemsRaw`/`SetGemsRaw` variantes db-diretas para uso dentro de lambdas. |
| **Comandos de chat** | `/gems` (saldo), `/chests` (lista fechados + contagem aberta), `/openchest <id>` (abre e notifica drop), `/trade <player> <item> [count=1]` (resolução por nickname via `GetCharacterIDByName`, rejeita self-trade na camada de comando também), `/vip buy 1|2` (checkout). Todos com Register/Unregister simétrico (convenção F3). |

## Bug real encontrado durante a implementação

**Transações aninhadas do godot-sqlite (corrompiam silenciosamente o commit).** `update_rows`/`delete_rows` do upstream `godot-sqlite` embrulham o statement num próprio `BEGIN/END TRANSACTION`. Chamá-los dentro de `SQL.Transaction` (que já tem `BEGIN` externo) produzia: `cannot start a transaction within a transaction` → o `END` aninhado commitava o trabalho externo → o `COMMIT` externo falhava (`no transaction is active`) → `ROLLBACK` também falhava. Efeito: **os dados persistiam, mas `Transaction` retornava `false`** — e o código F2 tinha sido escrito em volta desse comportamento (`if not Transaction: applied = true`, invertido), o que mascarava o problema desde o spike. Além disso `QueryBindings`/`ExecuteBindings` re-travam `queryMutex` que `Transaction` já segura (Mutex do Godot não é reentrante).

Correções estruturais:

1. **`UpdateRowsRaw(table, conditions, data)`** em `SQL.gd` — UPDATE via `db.query_with_bindings`, sem wrapper implícito de transação e sem tocar o mutex.
2. **Todos os pontos dentro de lambdas migrados para ops db-diretas**: `UpdateStatDirect`, `AddItemToCharacter` (branch de update), `UpdateSettleAnchor` (F2, latente), `ExecuteTrade`/`OpenChest`/`AddGems` (F4). Regra documentada no comentário de `Transaction`: dentro do lambda só `db.select_rows`, `insert_row`, `db.query_with_bindings` e `UpdateRowsRaw`.
3. **Semântica de retorno corrigida**: `applied = Transaction(...)` (retorna `true` no commit). O padrão invertido antigo dependia do commit quebrado — com o fix, settle/trade/chest/VIP commitam e reportam sucesso corretamente.
4. **Captura de lambda por valor**: `result = {...}` dentro do lambda rebinda a cópia local (o dict externo continuava vazio) — mutação agora é in-place (`result.clear()` + `result.merge(...)`).

## Desvios e decisões (documentados)

- **Seeds do baú não persistem em colunas** (migration `011` não criada): `serverSeed` é derivável da própria row (`id + created_at + salt`) e o `clientSeed` (`charID:nonce`) fica espelhado no ledger (`chest:<id>|<item>|<clientSeed>`), garantindo auditoria sem mudança de schema. Se o launch exigir regeneração de roll para dispute, aí sim vale coluna `odds_snapshot`/`server_seed` (TECH_SPEC invariant 4 fica funcionalmente cumprido pelo par derivável + ledger).
- **Negociação multi-item interativa do trade** (UI de offers/counter-offer, ECONOMY_STUDY §6.4 "trade direto por último") fica para a camada de GUI; o comando atual suporta 1 stack por lado por chamada, com escrow atômico já pronto para a sessão de negociação.
- **Preços VIP são placeholder** (`VIP1CostGems=440`, `VIP2CostGems=880`, 30 dias) — tuning pós-beta (MONETIZATION: R$19.90/R$39.90). O checkout, o stack e o ledger são finais.
- **Fee fixa, não percentual**: `TradeFeeGems=10` flat independe do valor trocado; simples de comunicar e auditável. Recalibrar é trocar 1 constante.
- **Pity simplificado**: contagem global de aberturas do personagem (não por tipo de baú — só existe 1 tipo no spike). Se novos tipos surgirem, o nonce precisa migrar para escopo por baú.

## Testes novos (3 suítes, +37 checks → 155 total)

- `SuiteTrade` — fee insuficiente rejeitado, stack faltando rejeitado, happy path (3+2 apples cruzando), fee queimada (100−10=90), rows de ledger nas duas pernas, auto-trade rejeitado
- `SuiteChests` — id inexistente rejeitado, open entrega item no inventário, seeds presentes, mirror de ledger, double-open rejeitado
- `SuiteVIPCheckout` — sanity, compra sem gems rejeitada sem conceder janela, VIP1 debita 460 e abre janela, VIP2 empilha +30d a partir do `until` atual, rows de ledger, tier inválido rejeitado

## Estado do ledger (invariantes TECH_SPEC §4)

- **(1) Espelhamento** — toda mutação F4 (trade fee, trade in/out, chest, VIP) gera row append-only no mesmo lambda/commit.
- **(2) Append-only** — triggers SQL negam UPDATE/DELETE em `ledger_transaction` (suíte F2 revalidada).
- **(3) Escrow/atomicidade** — nada persiste parcialmente: fee, movimentos e mirrors falham juntos (rollback do lambda).
- **(4) Provably fair** — derivável por terceiros (serverSeed da row + clientSeed no ledger + nonce incremental).
