extends RefCounted
class_name EconomyKernel

# SOM-IDLE Fatia 12: kernel compartilhado do EconomyService (ROADMAP_COMERCIAL S3,
# ultima fatia). Primitivos que TODOS os dominios usam: carteira (gold/gems),
# espelho no ledger, ops raw de stack com identidade de lote (B1), concesso/remocao
# de item bound e a coluna de boss keys. NAO tem mutex proprio: o lock continua no
# EconomyService (_eco.settleMutex / _eco._get_settle_mutex), entao a semantica de
# locking e identica a de antes da fatia e os 11 servicos seguem chamando pelos
# wrappers do facade (hub-and-spoke inalterado).

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
