extends RefCounted
class_name EconomyKernel

# SOM-IDLE Fatia 12: kernel compartilhado do EconomyService (ROADMAP_COMERCIAL S3,
# ultima fatia). Primitivos que TODOS os dominios usam: carteira (gold/gems),
# espelho no ledger, ops raw de stack com identidade de lote (B1), concesso/remocao
# de item bound e a coluna de boss keys. NAO tem mutex proprio: o lock continua no
# EconomyService (_eco.settleMutex / _eco._get_settle_mutex), entao a semantica de
# locking e identica a de antes da fatia e os 11 servicos seguem chamando pelos
# wrappers do facade (hub-and-spoke inalterado).
# Gold tem caminho unico desde o P0 do snapshot (ver _MoveGoldLocked): quem move
# stat.gp usa _MoveGoldLocked dentro da transacao aberta e aplica o dicionario de
# moves na memoria depois do commit — ou chama MoveGold, que ja faz os dois.

var _eco : EconomyService = null

# ------------------------------------------------------------------ wallet

func GetBalance(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT balance_after FROM ledger_transaction WHERE account_id = ? ORDER BY id DESC LIMIT 1;",
		[accountID])
	return int(rows[0]["balance_after"]) if not rows.is_empty() else 0

func GetGoldLedgerSum(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT COALESCE(SUM(amount), 0) AS total FROM ledger_transaction WHERE account_id = ? AND kind = ?;",
		[accountID, EconomyCatalog.LedgerKindGold])
	return int(rows[0]["total"]) if not rows.is_empty() else 0

# ------------------------------------------------------------------ ledger

# Append-only ledger write; MUST be called inside the same transaction as the
# state mutation it mirrors (see OfflineSettle._Apply). Uses db.* directly —
# it runs inside SQL.Transaction() which already holds queryMutex.
func LedgerAppend(charID : int, accountID : int, kind : String, amount : int, balanceAfter : int, reason : String = "") -> bool:
	var dbNode : SQLite = Launcher.SQL.db
	return dbNode.query_with_bindings(
		"INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
		[accountID, charID, kind, amount, balanceAfter, reason, SQLCommons.Timestamp()])

# ------------------------------------------------------------------ item ops (account-bound stash paths, used by F3/F4)

func GrantItem(accountID : int, itemHash : int, count : int, reason : String = "") -> bool:
	# Valida se o item existe no inventário antes de registrar no ledger.
	# Se o hash for 0 (inválido) ou o item não existir e não for um caso de
	# referência, rejeita para manter a integridade (invariante 1 de auditabilidade).
	var itemExists : bool = DB.ItemsDB.has(itemHash) if itemHash > 0 else false
	if not itemExists and itemHash > 0:
		return false
	var mutex : Mutex = _eco._get_settle_mutex(accountID)
	mutex.lock()
	var ok : bool = Launcher.SQL.db.query_with_bindings(
		"INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?, 0, ?, ?, 0, ?, ?);",
		[accountID, EconomyCatalog.LedgerKindItem, count, reason, SQLCommons.Timestamp()])
	mutex.unlock()
	return ok

# ------------------------------------------------------------------ wallet (gems; gold remains stat.gp per ARCHITECTURE §9)

func GetGems(accountID : int) -> int:
	return Launcher.SQL.GetGems(accountID)

# Single gems mutation path: wallet.gems is the source of truth, the ledger
# row mirrors it (invariant 1). Composed mutations inside an open transaction
# (ExecuteTrade fee) use SetGems + _LedgerAppendLocked directly.
func AddGems(accountID : int, amount : int, reason : String) -> bool:
	if amount == 0:
		return false
	var mutex : Mutex = _eco._get_settle_mutex(accountID)
	mutex.lock()
	var ok : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var current : int = Launcher.SQL.GetGemsRaw(accountID)
		var newBalance : int = current + amount
		if newBalance < 0:
			return false
		if not Launcher.SQL.SetGemsRaw(accountID, newBalance):
			return false
		return _LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, amount, newBalance, reason)):
		ok = true
	mutex.unlock()
	return ok

# ------------------------------------------------------------------ gold (carteira stat.gp — single writer)
# O gold do personagem mora em `stat.gp` e tem DOIS leitores do mesmo estado: o
# ledger, que espelha cada mutação (invariante 1, ver AddGems), e o agente
# carregado, que `SQL.UpdateStat` grava de volta como snapshot ABSOLUTO do que
# está na memória (RefreshCharacter -> World.BackupPlayers -> ciclo de 600 s de
# SQLBackups). Quem escreve `stat.gp` no banco sem mexer no agente está portanto
# escrevendo um valor que sobrevive no máximo até o próximo snapshot: o débito
# volta a existir no comprador e o crédito desaparece do vendedor (§7.1 do
# AUDITORIA_2026-09-27: o leilão movia gold cru via UpdateRowsRaw). Este é o
# caminho único: grava o banco, espelha no ledger e acumula o delta em `moves`
# para o chamador aplicar no agente DEPOIS do commit — aplicado antes, um
# rollback deixaria no agente gold que ninguém pagou.

# Uso DENTRO de Transaction() (mesma regra dos outros raw: sem mutex, sem tx).
# `amount` é o delta (negativo = débito); recusa carteira que ficaria negativa.
func _MoveGoldLocked(sql : SQLService, charID : int, accountID : int, amount : int, reason : String, moves : Dictionary) -> bool:
	var current : int = _CharGoldRaw(charID)
	var next : int = current + amount
	if next < 0:
		return false
	if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = next}):
		return false
	if not _LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, amount, next, reason):
		return false
	moves[charID] = int(moves.get(charID, 0)) + amount
	return true

# Espelha na memória os deltas gravados por _MoveGoldLocked. Roda FORA da
# transação, depois do commit. Aplica o delta e não o valor absoluto: o agente
# pode ter gold de farm ganho depois da leitura (o faucet vive na memória e só
# desce para o banco no snapshot), e substituir o valor apagaria essa receita.
func ApplyGoldMoves(moves : Dictionary) -> void:
	for charID in moves:
		var delta : int = int(moves[charID])
		if delta == 0:
			continue
		var agent : PlayerAgent = AgentForCharacter(int(charID))
		if agent != null:
			agent.stat.gp = maxi(0, agent.stat.gp + delta)
	moves.clear()

# Agente do personagem carregado no servidor (null = offline, e é o caso comum:
# quem paga o leilão pode estar desconectado, aí o banco é o único estado).
# Mesmo roteiro de OnlineList.GetPlayerNames: peer -> agentRID -> WorldAgent.
func AgentForCharacter(charID : int) -> PlayerAgent:
	if charID <= 0:
		return null
	for peerID : int in Peers.peers.keys():
		if Peers.GetCharacter(peerID) != charID:
			continue
		var agent : PlayerAgent = Peers.GetAgent(peerID)
		if agent != null and is_instance_valid(agent) and agent.stat != null:
			return agent
	return null

# Caminho público para quem NÃO tem transação aberta — mesma forma de AddGems
# (mutex de shard + Transaction + ledger) mais o espelho na memória.
func MoveGold(charID : int, amount : int, reason : String) -> bool:
	if amount == 0:
		return false
	var accountID : int = _AccountIDForCharacterRaw(charID)
	if accountID == NetworkCommons.PeerUnknownID:
		return false
	var moves : Dictionary = {}
	var mutex : Mutex = _eco._get_settle_mutex(accountID)
	mutex.lock()
	var committed : bool = Launcher.SQL.Transaction(func() -> bool:
		return _MoveGoldLocked(Launcher.SQL, charID, accountID, amount, reason, moves))
	mutex.unlock()
	if committed:
		ApplyGoldMoves(moves)
	return committed

# ------------------------------------------------------------------ reconciliação gp/gems (janela por dia)
# `ReconcileDaily` somava ledger e lots; o saldo real das carteiras não entrava.
# A única direção com leitura sem falso positivo é a carteira ABAIXO do que o
# ledger atesta: o faucet de farm só soma, então se `stat.gp` caiu abaixo do
# último `balance_after` de gold do personagem, alguém escreveu o stat row por
# fora do caminho único (ou um snapshot da memória apagou um crédito). Para gems
# a régua é a mesma, com `wallet.gems` como fonte de verdade espelhada no ledger.
# A janela (dia UTC corrente) limita a varredura ao movimento do dia — o ledger
# é append-only e cresce para sempre. Retorna {"gp", "gems", "total"}.
# O `created_at >= created_timestamp` é o que impede o saldo atestado da VIDA
# ANTERIOR de um id de personagem/conta (LGPD purge + linha de `stat` órfã, que
# nenhum cascade apaga) de virar falso positivo contra a carteira nova.
func ReconcileWalletDaily(nowSec : int = 0) -> Dictionary:
	var sql : SQLService = Launcher.SQL
	if sql == null or not sql.isInitialized:
		return {"gp": 0, "gems": 0, "total": 0}
	if nowSec <= 0:
		nowSec = SQLCommons.Timestamp()
	var dayStart : int = nowSec - (nowSec % 86400)
	var dayEnd : int = dayStart + 86400
	# Personagens/contas MOVIDOS a ouro ou gems neste dia (o EXISTS do ledger com
	# a janela é o índice do varredura) cuja carteira está abaixo do saldo que o
	# próprio ledger atesta para ela — o ÚLTIMO `balance_after`, não o máximo. O
	# máximo flagava todo mundo que já gastou: medido em 2026-09-27 na base do
	# harness, um personagem com três taxas de forja legítimas (7000 → 6000) era
	# "divergência" porque o pico histórico ficou no ledger. O débito está no
	# ledger, logo a atestação corrente é a última linha da série.
	var gpRows : Array[Dictionary] = sql.QueryBindings(
		"SELECT s.char_id FROM stat s INNER JOIN character c ON c.char_id = s.char_id"
		+ " WHERE s.gp < (SELECT l.balance_after FROM ledger_transaction l WHERE l.char_id = s.char_id AND l.kind = ? AND l.created_at >= c.created_timestamp ORDER BY l.id DESC LIMIT 1)"
		+ " AND EXISTS (SELECT 1 FROM ledger_transaction w WHERE w.char_id = s.char_id AND w.kind = ? AND w.created_at >= ? AND w.created_at < ?);",
		[EconomyCatalog.LedgerKindGold, EconomyCatalog.LedgerKindGold, dayStart, dayEnd])
	var gemsRows : Array[Dictionary] = sql.QueryBindings(
		"SELECT wa.account_id FROM wallet wa INNER JOIN account a ON a.account_id = wa.account_id"
		+ " WHERE wa.gems < (SELECT l.balance_after FROM ledger_transaction l WHERE l.account_id = wa.account_id AND l.kind = ? AND l.created_at >= a.created_timestamp ORDER BY l.id DESC LIMIT 1)"
		+ " AND EXISTS (SELECT 1 FROM ledger_transaction x WHERE x.account_id = wa.account_id AND x.kind = ? AND x.created_at >= ? AND x.created_at < ?);",
		[EconomyCatalog.LedgerKindGems, EconomyCatalog.LedgerKindGems, dayStart, dayEnd])
	var gpCount : int = gpRows.size()
	var gemsCount : int = gemsRows.size()
	return {"gp": gpCount, "gems": gemsCount, "total": gpCount + gemsCount}

# Diagnóstico da perna de gp: quais personagens estão abaixo do atestado e por
# quanto. `/metrics` só expõe o contador; quem abre o incidente precisa do par
# (char, esperado, gravado) — e é a mesma régua do `ReconcileWalletDaily` acima,
# incluindo aí o ÚLTIMO `balance_after` como atestado: com MAX aqui, o contador e
# esta lista divergiam (o job dizia 1, o diagnóstico entregava 4 nomes).
func DivergingWallets(nowSec : int = 0) -> Array[Dictionary]:
	var sql : SQLService = Launcher.SQL
	if sql == null or not sql.isInitialized:
		return []
	if nowSec <= 0:
		nowSec = SQLCommons.Timestamp()
	var dayStart : int = nowSec - (nowSec % 86400)
	var dayEnd : int = dayStart + 86400
	return sql.QueryBindings(
		"SELECT s.char_id AS char_id, s.gp AS recorded, (SELECT l.balance_after FROM ledger_transaction l WHERE l.char_id = s.char_id AND l.kind = ? AND l.created_at >= c.created_timestamp ORDER BY l.id DESC LIMIT 1) AS attested"
		+ " FROM stat s INNER JOIN character c ON c.char_id = s.char_id"
		+ " WHERE s.gp < (SELECT l.balance_after FROM ledger_transaction l WHERE l.char_id = s.char_id AND l.kind = ? AND l.created_at >= c.created_timestamp ORDER BY l.id DESC LIMIT 1)"
		+ " AND EXISTS (SELECT 1 FROM ledger_transaction w WHERE w.char_id = s.char_id AND w.kind = ? AND w.created_at >= ? AND w.created_at < ?);",
		[EconomyCatalog.LedgerKindGold, EconomyCatalog.LedgerKindGold, EconomyCatalog.LedgerKindGold, dayStart, dayEnd])


# ------------------------------------------------------------------ boss keys (character column + ledger mirror)
# SOM-IDLE: boss-key ladder. boss_keys vive no character (progressão por char,
# como farm_zone); o ledger só espelha os fluxos para auditoria. GrantBossKey é o
# único caminho de drop; SpendBossKey retorna false se não houver chave (nunca
# negativa). Retorna o saldo novo (>=0) ou -1 em falha.
func GrantBossKey(charID : int, amount : int, reason : String) -> int:
	if amount == 0:
		return Launcher.SQL.GetCharacterBossKeys(charID)
	var applied : bool = false
	var accountID : int = _AccountIDForCharacterRaw(charID)
	var mutex : Mutex = _eco._get_settle_mutex(accountID) if accountID > 0 else _eco.settleMutex
	mutex.lock()
	# GDScript closures capture by VALUE: we cannot read `result` back out of the
	# transaction closure, so we re-query the (now committed) column after commit.
	if Launcher.SQL.Transaction(func() -> bool:
		var next : int = Launcher.SQL.AddCharacterBossKeys(charID, amount)
		if next < 0:
			return false
		var acct : int = _AccountIDForCharacterRaw(charID)
		return _LedgerAppendLocked(acct, charID, EconomyCatalog.LedgerKindBossKey, amount, next, reason)):
		applied = true
	mutex.unlock()
	return Launcher.SQL.GetCharacterBossKeys(charID) if applied else -1


# Locked variant for use INSIDE an open SQL.Transaction() (no mutex re-entry).
# wallet.gems is the gems source of truth; ledger rows mirror every mutation.
func _LedgerAppendLocked(accountID : int, charID : int, kind : String, amount : int, balanceAfter : int, reason : String) -> bool:
	var dbNode : SQLite = Launcher.SQL.db
	return dbNode.query_with_bindings(
		"INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
		[accountID, charID, kind, amount, balanceAfter, reason, SQLCommons.Timestamp()])

# Transaction-internal raw helpers (no mutex, no implicit transactions)
func _AccountIDForCharacterRaw(charID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.db.select_rows("character", "char_id = %d" % charID, ["account_id"])
	return int(rows[0]["account_id"]) if not rows.is_empty() else NetworkCommons.PeerUnknownID

func _ItemCountRaw(charID : int, itemID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], ["count"])
	return 0 if rows.is_empty() else int(rows[0].get("count", 0) if rows[0].get("count", 0) != null else 0)

func _MoveStack(charFrom : int, charTo : int, itemID : int, count : int) -> bool:
	return not _MoveStackUIDs(charFrom, charTo, itemID, count).is_empty()

# SOM-IDLE B1: move com identidade de lote — consome lotes FIFO (somente
# unbound: cosméticos bound não negociam), move o agregado e concede lote
# encadeado (parent_uid) no receptor. Retorna {"consumed": [...], "granted": uid}.
func _MoveStackUIDs(charFrom : int, charTo : int, itemID : int, count : int) -> Dictionary:
	var sql : SQLService = Launcher.SQL
	var consumed : Array = sql.ConsumeItemLotsRaw(charFrom, itemID, count, false)
	if consumed.is_empty():
		return {}
	var sourceCount : int = _ItemCountRaw(charFrom, itemID)
	var moved : bool = false
	if sourceCount > count:
		moved = sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charFrom], {"count" = sourceCount - count})
	elif sourceCount == count:
		moved = sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charFrom])
	if not moved:
		return {}
	var targetCount : int = _ItemCountRaw(charTo, itemID)
	if targetCount > 0:
		moved = sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charTo], {"count" = targetCount + count})
	else:
		moved = sql.db.insert_row("item", {"item_id" = itemID, "char_id" = charTo, "count" = count, "storage" = 0, "customfield" = ""})
	if not moved:
		return {}
	var granted : int = sql.GrantItemLotRaw(charTo, itemID, count, "trade_in", 0, "", int(consumed[0]))
	if granted == 0:
		return {}
	return {"consumed" = consumed, "granted" = granted}

func _UIDList(uids : Array) -> String:
	var parts : PackedStringArray = PackedStringArray()
	for uid in uids:
		parts.append(str(uid))
	return ",".join(parts)

# SOM-IDLE B1: upsert agregado + lote + espelho no ledger. Para uso DENTRO de
# Transaction(). Retorna o uid do lote ou 0.
func _GrantStackRaw(charID : int, accountID : int, itemID : int, count : int, ledgerReason : String, grantReason : String = "", bound : int = 0, parentUID : int = 0, creatorAccountID : int = 0) -> int:
	var sql : SQLService = Launcher.SQL
	var existing : Array[Dictionary] = sql.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], ["count"])
	var delivered : bool = false
	if not existing.is_empty():
		delivered = sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], {"count" = int(existing[0]["count"]) + count})
	else:
		delivered = sql.db.insert_row("item", {"item_id" = itemID, "char_id" = charID, "count" = count, "storage" = 0, "customfield" = ""})
	if not delivered:
		return 0
	var uid : int = sql.GrantItemLotRaw(charID, itemID, count, grantReason if not grantReason.is_empty() else ledgerReason, bound, "", parentUID, creatorAccountID)
	if uid == 0:
		return 0
	if not _LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindItem, count, 0, ledgerReason + ":uid%d" % uid):
		return 0
	return uid

func _CharGoldRaw(charID : int) -> int:
	var rows : Array = Launcher.SQL.db.select_rows("stat", "char_id = %d" % charID, ["gp"])
	if rows.is_empty() or rows[0].get("gp", null) == null:
		return 0
	return int(rows[0]["gp"])
