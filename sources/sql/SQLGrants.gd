extends RefCounted
class_name SQLGrants

# Fatia do funil de dados que saiu de `SQL.gd` quando o teto anti-god-node dele
# estourou. O padrão é o das outras fatias deste diretório (`SQLSecurity`,
# `SQLRetention`, `SQLReadPool`, `SQLReadRules`): `RefCounted`, tudo estático, e o
# store entra como `Object` para o harness poder passar um fake no lugar do
# autoload. A fachada mantém a delegação, porque o contrato público é
# `SQL.FlushGoldDelta` e `SQL.AddItemsBatchToCharacter` — chamar o funil por fora
# dele é o que a régua de escrita crua existe para impedir.

# ------------------------------------------------------------------ WorkOrder #88
# O ouro do personagem tem DOIS escritores do mesmo `stat.gp`: o agente carregado
# (faucet de farm, que vive na memória e só desce para o banco aqui) e o kernel
# (`_MoveGoldLocked`, que grava no banco direto para loja, forja, guilda, copa,
# boss, streak, checkout e leilão). Enquanto `UpdateStat` era snapshot ABSOLUTO do
# agente, o passe de 600 s do `World.BackupPlayers` apagava a segunda origem: o
# débito do vendor voltava a existir no comprador com o item no bolso (ouro
# infinito) e o crédito do checkout desaparecia do contemplado. Agora a memória
# entrega só o DELTA que ganhou desde o último flush — as duas origens compõem em
# vez de uma apagar a outra.
#
# Lastro (`gpFlushed`): posto com o valor do banco na carga do personagem
# (`PlayerAgent.SetCharacterInfo`) e avançado junto com a memória pelo kernel
# (`EconomyKernel.ApplyGoldMoves`), porque o que o kernel grava já está no banco.
# Quem escreve o banco por fora do funil e MESMO espelha no agente tem de fazer o
# mesmo avance — é o que o ramo online de `StreakService.RecordLogin` faz desde o
# WorkOrder #163; espelho sem lastro é o granto entrando de novo no próximo passe.
# `-1` = agente nunca carregado do banco, e aí não se credita nada às cegas. O
# piso 0 é o único teto: um lastro errado nunca pode mintar ouro, e quem gasta
# passa pelo kernel, que recusa carteira negativa.
#
# ------------------------------------------------------------------ WorkOrder #185
# O delta acima descreve QUANTO o banco ganhou; nada dele dizia se o ganho era
# AUDITÁVEL. Enquanto este funil gravava `stat.gp` mudo, toda outra origem de ouro
# do jogo escrevia a linha de ledger junto (`EconomyKernel._MoveGoldLocked`, o ramo
# online de `StreakService.RecordLogin`, `GrantItem`): o faucet do farm — a torneira
# que mais enche, `Formula.AddGP` por kill de zona — existia no banco e na memória e
# não existia no único lugar que audita dinheiro. Consequência medida, não temida:
# `EconomyKernel.CensusSupply` atesta a carteira pelo ÚLTIMO `balance_after` do
# ledger, então cada jogador online que coletava ouro ficava `unattested` no censo,
# e `ReconcileWalletDaily` (que só enxerga carteira ABAIXO do atestado) nunca via o
# contrário porque ouro sem linha de ledger só empurra a carteira para CIMA.
#
# Agora as duas pernas nascem na MESMA transação, com a família de `reason` vinda de
# `ActorStats.gpPending` — o censo somar `farm`, `quest` e `boss` separados é o que
# faz "quanto dinheiro entrou no jogo" continuar sendo uma conta depois daqui. As
# três regras de fechamento, cada uma com controle plantado em
# `tests/faucet_census_test.gd`:
#   1. as linhas somam EXATAMENTE o que o banco moveu (`landed`), nunca o delta
#      pedido: se o `MAX(0, …)` de um débito cortou o movimento, a linha conta o
#      corte, senão o ledger atestaria ouro que ninguém tem;
#   2. pending maior que o delta não é re-emitido — o excedente é ouro que outro
#      writer já comitou e já atestou (é o ramo online do streak, que soma em
#      `gp` e avança o lastro na mesma transação), e re-emitir seria dar duas
#      linhas ao mesmo grant;
#   3. delta maior que o pending vira linha `flush_untracked`, a família cuja
#      existência no censo grita "há um writer de ouro que ninguém enumerou" — o
#      silêncio aqui é que era o defeito.
static func FlushGoldDelta(sql : Object, charID : int, stats : ActorStats) -> bool:
	if stats == null or stats.gpFlushed < 0:
		return true
	var delta : int = stats.gp - stats.gpFlushed
	if delta == 0:
		return true
	var pending : Dictionary = stats.gpPending
	var committed : bool = sql.Transaction(func() -> bool:
		# `ExecNoLockQuery`, não `QueryBindings`: dentro de `Transaction()` a leitura
		# com lock pode ser atendida pelo pool (`query_only=1`), que em WAL não vê o
		# que este mesmo handle ainda não comitou. `SELECT` cru no handle do writer é
		# a leitura sancionada do estado dentro da transação.
		var bank : Array[Dictionary] = sql.ExecNoLockQuery(
			"SELECT s.gp AS gp, c.account_id AS account_id FROM stat s"
			+ " INNER JOIN character c ON c.char_id = s.char_id WHERE s.char_id = ?;", [charID])
		if bank.size() != 1:
			push_error("SQLGrants.FlushGoldDelta: char %d sem linha de stat+character; flush abortado" % charID)
			return false
		var current : int = int(bank[0]["gp"])
		var accountID : int = int(bank[0]["account_id"])
		var next : int = maxi(0, current + delta)
		var landed : int = next - current
		if landed == 0:
			return true
		if not sql.ExecNoLock("UPDATE stat SET gp = ? WHERE char_id = ?;", [next, charID]):
			return false
		var rows : Array = _FlushRows(landed, pending)
		var stampedAt : int = SQLCommons.Timestamp()
		var running : int = current
		for rec in rows:
			var amount : int = int(rec["amount"])
			running += amount
			if not sql.ExecNoLock(
					"INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at)"
					+ " VALUES (?, ?, ?, ?, ?, ?, ?);",
					[accountID, charID, EconomyCatalog.LedgerKindGold, amount, running,
						"%s:%d" % [String(rec["family"]), charID], stampedAt]):
				return false
		return true)
	if not committed:
		return false
	stats.gpFlushed = stats.gp
	stats.gpPending.clear()
	return true

# O fechamento das linhas, puro para poder ser plantado: `landed` é o que o banco
# moveu DE FATO, e a conta tem que fechar com ele em todas as saídas. Débito
# (landed < 0) é uma linha só, porque pendência de ganho não explica um débito — a
# família `flush_correction` nomeia exatamente isso. Crédito come o pending em ordem
# de chegada até o teto do que foi movido, e o que sobrar de `landed` sem explicação
# sai como `flush_untracked`.
#
# O que esta função NÃO pode saber, dito em vez de fingir: ela vê `gp`, `gpFlushed`
# e `gpPending`, e nada nela sabe qual pendente já foi atestado por outra linha. O
# que ela sabe é a ORDEM: `gpPending` é fila de chegada, e o writer que credita
# memória E grava o banco atestando na mesma transação (o ramo online de
# `StreakService.RecordLogin`) avança o lastro junto — o pendente dele fica mais
# velho que qualquer ganho que ainda não desceu. Por isso o excedente cai pelo fim
# velho da fila e o que é cobrado é o mais novo: com `landed` menor que o pending, a
# família que sobra é a do grant novo, não a do grant que já tem linha. O total fecha
# em qualquer ordem; o que a ordem compra é a veracidade do censo por família.
static func _FlushRows(landed : int, pending : Dictionary) -> Array:
	if landed <= 0:
		return [{"family" = "flush_correction", "amount" = landed}]
	var rows : Array = []
	var budget : int = landed
	var ids : Array = pending.keys()
	for i in range(ids.size() - 1, -1, -1):
		if budget <= 0:
			break
		var family : String = String(ids[i])
		var owed : int = int(pending[family])
		if owed <= 0:
			continue
		var take : int = mini(budget, owed)
		rows.append({"family" = family, "amount" = take})
		budget -= take
	if budget > 0:
		rows.append({"family" = "flush_untracked", "amount" = budget})
	return rows

# ------------------------------------------------------------------ WorkOrder #109
# O settle offline concedia drop por drop em `AddItemToCharacter`, que são QUATRO
# statements por identidade lida: o `select_rows` da pilha, o `update_rows`/
# `insert_row` dela, o `insert_row` do lote em `item_instance` e o
# `SELECT last_insert_rowid()` que devolve o uid. Com a distribuição real de
# drops (#95) um settle de uma hora rola ~40 identidades, ou seja ~160 statements
# por transação — medido em 2026-09-30 com o mesmo probe de 800 settles, na mesma
# máquina, contra o worktree de `2fad68b`: p50 479 → 3811 µs (8×) e max 940 µs →
# 540081 µs, com 10 hitches acima de 50 ms onde o baseline tinha zero. A régua de
# latência viu; o que ela não via é que o custo era o FORMATO da escrita, não a
# quantidade de item — os mesmos 32246 lotes saem por dois statements aqui.
#
# As duas afirmações abaixo são exatamente o laço antigo, em lote:
#   - a pilha sobe por `count = count + excluído`, que é o que o read-modify-write
#     fazia, só sem a janela entre ler e somar;
#   - cada identidade ganha UM lote em `item_instance` com o mesmo carimbo `bound`
#     lido da célula (regra #88), o mesmo `reason`, `storage` 0 e sem pai.
# Lotes não são fundidos: um lote por identidade é o que o ledger e o escrow (#94)
# exigem. O que some é a ida e volta por identidade.
#
# A fatia de 512 identidades por statement é o teto de parâmetros: 9 bindings por
# linha, e o limite do SQLite para host parameters é 32766. Uma recolha de muitos
# dias passa por aqui mais de uma vez, em vez de estourar a ligação.
const GrantBatchSlice : int = 512

static func AddItemsBatchToCharacter(sql : Object, charID : int, rolls : Dictionary, reason : String = "settle") -> bool:
	if rolls.is_empty():
		return true
	var stampedAt : int = SQLCommons.Timestamp()
	var ids : Array = rolls.keys()
	var reasonInline : bool = SQLService.IsPlainIdentifier(reason)
	var from : int = 0
	while from < ids.size():
		var to : int = mini(from + GrantBatchSlice, ids.size())
		var stackRows : PackedStringArray = PackedStringArray()
		var lotRows : PackedStringArray = PackedStringArray()
		var lotParams : Array = []
		for i in range(from, to):
			var itemID : int = int(ids[i])
			var count : int = int(rolls[ids[i]])
			if itemID <= 0 or count <= 0:
				return false
			var bound : int = 1 if CellCommons.IsMaterial(DB.ItemsDB.get(itemID, null)) else 0
			stackRows.append("(%d, %d, %d, 0, '')" % [itemID, charID, count])
			if reasonInline:
				lotRows.append("(%d, %d, %d, 0, %d, '', '%s', 0, 0, %d)" % [charID, itemID, count, bound, reason, stampedAt])
			else:
				lotRows.append("(%d, %d, %d, 0, %d, '', ?, 0, 0, %d)" % [charID, itemID, count, bound, stampedAt])
				lotParams.append(reason)
		if not sql.ExecuteBindings("INSERT INTO item (item_id, char_id, count, storage, customfield) "
			+ "VALUES " + ",".join(stackRows)
			+ " ON CONFLICT(char_id, item_id, storage, customfield) DO UPDATE SET count = item.count + excluded.count;",
			[]):
			return false
		# `OR FAIL` e não o default (`OR ABORT`): a tabela tem `NOT NULL` em todas
		# as colunas e o SQLite só liga o diário de STATEMENT (cópia de cada página
		# suja, para poder desfazer o statement) quando a resolução de conflito é
		# ABORT. Medido em 2026-10-05, 41 linhas por statement na mesma tabela:
		# default 350 µs, `OR FAIL` 80 µs, `OR IGNORE` 80 µs — e `FAIL` é o único
		# dos três que ainda devolve erro (o addon responde false e o settle inteiro
		# cai). Comportamento final igual ao de antes porque esta statement roda
		# DENTRO da transação de `_Apply` (OfflineSettle.gd:@_Apply), e um false do lambda
		# dispara o ROLLBACK da transação inteira, que desfaz as linhas que o `FAIL`
		# deixou de pé dentro do próprio statement. Não vale para chamador fora de
		# transação — por isso o nome está aqui, colado na statement.
		if not sql.ExecuteBindings("INSERT OR FAIL INTO item_instance (char_id, item_id, count, storage, bound, customfield, reason, parent_uid, creator_account_id, created_at) "
			+ "VALUES " + ",".join(lotRows) + ";", lotParams):
			return false
		from = to
	return true
