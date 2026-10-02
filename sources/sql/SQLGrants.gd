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
static func FlushGoldDelta(sql : Object, charID : int, stats : ActorStats) -> bool:
	if stats == null or stats.gpFlushed < 0:
		return true
	var delta : int = stats.gp - stats.gpFlushed
	if delta == 0:
		return true
	if not sql.ExecuteBindings("UPDATE stat SET gp = MAX(0, gp + ?) WHERE char_id = ?;", [delta, charID]):
		return false
	stats.gpFlushed = stats.gp
	return true

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
	var from : int = 0
	while from < ids.size():
		var to : int = mini(from + GrantBatchSlice, ids.size())
		var stackValues : String = ""
		var stackParams : Array = []
		var lotValues : String = ""
		var lotParams : Array = []
		for i in range(from, to):
			var itemID : int = int(ids[i])
			var count : int = int(rolls[ids[i]])
			if itemID <= 0 or count <= 0:
				return false
			var sep : String = "," if i > from else ""
			stackValues += "%s(?, ?, ?, 0, '')" % sep
			stackParams.append(itemID)
			stackParams.append(charID)
			stackParams.append(count)
			var bound : int = 1 if CellCommons.IsMaterial(DB.ItemsDB.get(itemID, null)) else 0
			lotValues += "%s(?, ?, ?, 0, ?, '', ?, 0, 0, ?)" % sep
			lotParams.append(charID)
			lotParams.append(itemID)
			lotParams.append(count)
			lotParams.append(bound)
			lotParams.append(reason)
			lotParams.append(stampedAt)
		if not sql.ExecuteBindings("INSERT INTO item (item_id, char_id, count, storage, customfield) "
			+ "VALUES " + stackValues
			+ " ON CONFLICT(char_id, item_id, storage, customfield) DO UPDATE SET count = item.count + excluded.count;",
			stackParams):
			return false
		if not sql.ExecuteBindings("INSERT INTO item_instance (char_id, item_id, count, storage, bound, customfield, reason, parent_uid, creator_account_id, created_at) "
			+ "VALUES " + lotValues + ";", lotParams):
			return false
		from = to
	return true
