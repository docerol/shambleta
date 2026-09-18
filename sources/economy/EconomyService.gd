extends ServiceBase
class_name EconomyService

# SOM-IDLE: economy service (TECH_SPEC_CORE.md §4-§5 + ECONOMY_STUDY.md).
# Ledger de ouro/XP/gems/itens, trade P2P (fee burn), baús provably-fair com
# pity, boss economy e grants de pagamento. ExecuteTrade/OpenChest saíram de
# stub (F4) para implementação completa — ver ECONOMY_STUDY.md §2-§3.

const LedgerKindGold : String = "gold"
const LedgerKindXP : String = "xp"
const LedgerKindItem : String = "item"
const LedgerKindGems : String = "gems"
const LedgerKindBossKey : String = "boss_key"
const LedgerKindEssence : String = "essence"

var settleMutex : Mutex						= Mutex.new()

# SOM-IDLE C1: companion grant poll (main thread, vazio = no-op barato).
const GrantPollSec : float = 30.0
var _grantPollAccum : float = 0.0

func _process(delta : float) -> void:
	if not isInitialized:
		return
	_grantPollAccum += delta
	if _grantPollAccum >= GrantPollSec:
		_grantPollAccum = 0.0
		ProcessPendingGrants(20)

#
func _post_launch():
	isInitialized = true

func Destroy():
	isInitialized = false

# ------------------------------------------------------------------ wallet

func GetBalance(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT balance_after FROM ledger_transaction WHERE account_id = ? ORDER BY id DESC LIMIT 1;",
		[accountID])
	return int(rows[0]["balance_after"]) if not rows.is_empty() else 0

func GetGoldLedgerSum(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT COALESCE(SUM(amount), 0) AS total FROM ledger_transaction WHERE account_id = ? AND kind = ?;",
		[accountID, LedgerKindGold])
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
	settleMutex.lock()
	var dbNode : SQLite = Launcher.SQL.db
	var ok : bool = dbNode.query_with_bindings(
		"INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?, 0, ?, ?, 0, ?, ?);",
		[accountID, LedgerKindItem, count, reason, SQLCommons.Timestamp()])
	settleMutex.unlock()
	return ok

func RemoveItem(uid : int) -> bool:
	# Item rows are hard-owned by the item table; F2 does not delete items here.
	return false

# ------------------------------------------------------------------ settle path

func SettleTransaction(charID : int, report : Dictionary) -> bool:
	settleMutex.lock()
	var ok : bool = not OfflineSettle.SettlePending(charID).is_empty()
	settleMutex.unlock()
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
	settleMutex.lock()
	var ok : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var current : int = Launcher.SQL.GetGemsRaw(accountID)
		var newBalance : int = current + amount
		if newBalance < 0:
			return false
		if not Launcher.SQL.SetGemsRaw(accountID, newBalance):
			return false
		return _LedgerAppendLocked(accountID, 0, LedgerKindGems, amount, newBalance, reason)):
		ok = true
	settleMutex.unlock()
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
	settleMutex.lock()
	# GDScript closures capture by VALUE: we cannot read `result` back out of the
	# transaction closure, so we re-query the (now committed) column after commit.
	if Launcher.SQL.Transaction(func() -> bool:
		var next : int = Launcher.SQL.AddCharacterBossKeys(charID, amount)
		if next < 0:
			return false
		var acct : int = _AccountIDForCharacterRaw(charID)
		return _LedgerAppendLocked(acct, charID, LedgerKindBossKey, amount, next, reason)):
		applied = true
	settleMutex.unlock()
	return Launcher.SQL.GetCharacterBossKeys(charID) if applied else -1

# ------------------------------------------------------------------ rebirth (B+C)
# Contrato: XP_PROGRESSION.md §4.2. Essência é a moeda do motor: entra 1 por 100
# XP de overflow (nunca some no cap), sai em upgrades de custo 1.7^n. Cache de
# multipliers por char é invalidado em qualquer mutação (buy/rebirth/settle).
var _rebirthCache : Dictionary = {}

func GetRebirthMults(charID : int) -> Dictionary:
	if _rebirthCache.has(charID):
		return _rebirthCache[charID]
	var info : Dictionary = Launcher.SQL.GetRebirthInfo(charID)
	if info.is_empty():
		return {"xp" = 1.0, "gold" = 1.0, "attune" = 0}
	var mults : Dictionary = {
		"xp" : RebirthData.XpMult(int(info["favor_xp"])),
		"gold" : RebirthData.GoldMult(int(info["favor_gold"])),
		"attune" : int(info["attune_offline"]),
	}
	_rebirthCache[charID] = mults
	return mults

func InvalidateRebirthCache(charID : int) -> void:
	_rebirthCache.erase(charID)

func AddEssence(charID : int, amount : int, reason : String) -> int:
	if amount == 0:
		return Launcher.SQL.GetCharacterEssence(charID)
	var applied : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var next : int = Launcher.SQL.AddCharacterEssence(charID, amount)
		if next < 0:
			return false
		var acct : int = _AccountIDForCharacterRaw(charID)
		return _LedgerAppendLocked(acct, charID, LedgerKindEssence, amount, next, reason)):
		applied = true
	settleMutex.unlock()
	return Launcher.SQL.GetCharacterEssence(charID) if applied else -1

func BuyRebirthUpgrade(charID : int, upgradeID : String) -> Dictionary:
	if not RebirthData.IsUpgrade(upgradeID):
		return {"ok" = false, "reason" = "unknown_upgrade"}
	var info : Dictionary = Launcher.SQL.GetRebirthInfo(charID)
	if info.is_empty():
		return {"ok" = false, "reason" = "no_character"}
	if upgradeID == RebirthData.UpgradeAttune and int(info[upgradeID]) >= RebirthData.OfflineMaxLevels:
		return {"ok" = false, "reason" = "maxed"}
	var cost : int = RebirthData.Cost(upgradeID, int(info[upgradeID]))
	if int(info["essence"]) < cost:
		return {"ok" = false, "reason" = "insufficient_essence", "cost" = cost}
	var ok : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var nextEssence : int = Launcher.SQL.AddCharacterEssence(charID, -cost)
		if nextEssence < int(info["essence"]) - cost:
			return false
		if Launcher.SQL.IncRebirthUpgrade(charID, upgradeID) < 0:
			return false
		var acct : int = _AccountIDForCharacterRaw(charID)
		return _LedgerAppendLocked(acct, charID, LedgerKindEssence, -cost, nextEssence, "rebirth_upgrade:" + upgradeID)):
		ok = true
	settleMutex.unlock()
	if not ok:
		return {"ok" = false, "reason" = "transaction_failed"}
	InvalidateRebirthCache(charID)
	return {"ok" = true, "upgrade" = upgradeID, "cost" = cost}

# Renascimento de verdade exige o agente vivo (stats in-memory). Offline/logged-out
# NÃO renasce: o pedido só passa quando o char está conectado e no cap.
func Rebirth(charID : int, player) -> Dictionary:
	if player == null or not is_instance_valid(player) or player.stat == null:
		return {"ok" = false, "reason" = "not_online"}
	if player.stat.level < Experience.MAX_LEVEL:
		return {"ok" = false, "reason" = "below_cap"}
	var statRow : Dictionary = Launcher.SQL.GetStat(charID)
	var goldKept : int = 0
	var value : Variant = statRow.get("gp", 0)
	goldKept = 0 if value == null else int(value)
	var ok : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		if Launcher.SQL.IncRebirthCounter(charID) < 0:
			return false
		return Launcher.SQL.UpdateStatDirect(charID, 1, 0, goldKept)):
		ok = true
	settleMutex.unlock()
	if not ok:
		return {"ok" = false, "reason" = "transaction_failed"}
	# Espelha no agente vivo (mesma ordem do settle: nível, XP, then attributes)
	player.stat.level = 1
	player.stat.experience = 0
	player.stat.ResetAttributesIfOverBudget()
	player.stat.vital_stats_updated.emit()
	InvalidateRebirthCache(charID)
	var info : Dictionary = Launcher.SQL.GetRebirthInfo(charID)
	var rebirths : int = int(info.get("rebirths", 0))
	# Fase D: vitrine do renascimento — 1º ciclo concede o básico grátis.
	if rebirths > 0:
		_RebirthVitrine(Launcher.SQL.GetAccountIDForCharacter(charID), rebirths)
	return {"ok" = true, "rebirths" = rebirths}

func GetRebirthState(charID : int) -> Dictionary:
	var info : Dictionary = Launcher.SQL.GetRebirthInfo(charID)
	if info.is_empty():
		return {}
	var statRow : Dictionary = Launcher.SQL.GetStat(charID)
	var lvl : Variant = statRow.get("level", 1)
	var costs : Dictionary = {}
	for id in RebirthData.UpgradeOrder:
		costs[id] = RebirthData.Cost(id, int(info[id]))
	return {
		"essence" : int(info["essence"]),
		"rebirths" : int(info["rebirths"]),
		"level" : 1 if lvl == null else int(lvl),
		"cap" : Experience.MAX_LEVEL,
		"favor_xp" : int(info["favor_xp"]),
		"favor_gold" : int(info["favor_gold"]),
		"attune_offline" : int(info["attune_offline"]),
		"attune_max" : RebirthData.OfflineMaxLevels,
		"costs" : costs,
	}

func SpendBossKey(charID : int, amount : int, reason : String) -> bool:
	if amount <= 0:
		return false
	settleMutex.lock()
	var ok : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var current : int = Launcher.SQL.GetCharacterBossKeys(charID)
		if current < amount:
			return false
		var next : int = current - amount
		if Launcher.SQL.AddCharacterBossKeys(charID, -amount) == -1:
			return false
		var acct : int = _AccountIDForCharacterRaw(charID)
		return _LedgerAppendLocked(acct, charID, LedgerKindBossKey, -amount, next, reason)):
		ok = true
	settleMutex.unlock()
	return ok

# ------------------------------------------------------------------ boss ladder (state + challenge)
# SOM-IDLE: a escada é sequencial — o próximo boss desafiável é sempre o índice
# `beaten`. O boss escala ao nível do char. A resolução é a sim de duelo do
# BossService (determinística); aqui só validamos, gastamos a chave, entregamos
# xp/gold/chance de drop e persistimos o progresso.

func GetBossState(charID : int, playerLevel : int) -> Dictionary:
	var beaten : int = Launcher.SQL.GetCharacterBossesBeaten(charID)
	var bosses : Array = []
	for i in BossService.GetBossCount():
		var bl : int = BossService.GetBossLevel(playerLevel, i)
		bosses.append({
			"index" = i,
			"name" = BossService.GetBossName(i),
			"level" = bl,
			"hp" = BossService.GetBossMaxHealth(bl),
			"beaten" = i < beaten,
			"next" = i == beaten,
		})
	return {
		"keys" = Launcher.SQL.GetCharacterBossKeys(charID),
		"beaten" = beaten,
		"count" = BossService.GetBossCount(),
		"level" = playerLevel,
		"bosses" = bosses,
	}

# Desafia o próximo boss da escada. Valida + gasta a chave e INICIA a luta ao
# vivo (IdlePolicyService.StartBossFight): o jogador VÊ o char enfrentar o boss
# escalado com as animações reais. A recompensa é entregue depois, na morte do
# boss (vitória) ou do char (derrota), via OnBossResult → SettleBossResult + push.
# Sem sessão de farm ativa (ex.: challenge offline) cai na sim instantânea.
func ChallengeBoss(charID : int, player) -> Dictionary:
	if player == null or not is_instance_valid(player) or player.stat == null:
		return {"ok" = false, "reason" = "not_online"}

	var index : int = Launcher.SQL.GetCharacterBossesBeaten(charID)
	if index >= BossService.GetBossCount():
		return {"ok" = false, "reason" = "ladder_complete"}

	# A escada é sequencial: o índice é fixo (próximo não-vencido).
	if Launcher.SQL.GetCharacterBossKeys(charID) < 1:
		return {"ok" = false, "reason" = "no_key"}

	if not SpendBossKey(charID, 1, "boss_challenge"):
		return {"ok" = false, "reason" = "spend_failed"}

	var bossLevel : int = BossService.GetBossLevel(player.stat.level, index)
	var fight : Dictionary = IdlePolicyService.StartBossFight(player, index)
	if fight.get("started", false):
		return {
			"ok" = true,
			"started" = true,
			"index" = index,
			"boss" = BossService.GetBossName(index),
			"level" = bossLevel,
			"keys" = Launcher.SQL.GetCharacterBossKeys(charID),
		}

	# Fallback sem arena (luta ao vivo indisponível): resolve pela sim e liquida
	# na hora — a chave não é desperdiçada.
	var duel : Dictionary = BossService.Resolve(BossService.PlayerFightSnapshot(player), bossLevel)
	var result : Dictionary = SettleBossResult(charID, player, index, bool(duel.get("win", false)))
	result["duration"] = roundi(float(duel.get("duration", 0.0)))
	return result

# Liquida a recompensa de um duelo de boss (chamado na vitória/derrota ao vivo OU
# pela sim de fallback). `win` vem da luta, não daqui. Retorna o resultado p/ push.
func SettleBossResult(charID : int, player, index : int, win : bool) -> Dictionary:
	if player == null or not is_instance_valid(player) or player.stat == null:
		return {"ok" = false, "reason" = "not_online", "win" = win, "index" = index}

	# referência de xp = zona de farm atual do char
	var charRow : Dictionary = Launcher.SQL.GetCharacter(charID)
	var zoneID : int = int(charRow.get("farm_zone", 1) if charRow.get("farm_zone", 1) != null else 1)
	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	var zoneXp : int = zone.xpPerKill if zone != null else FarmZoneData.XpBasePerKill
	var accountID : int = Launcher.SQL.GetAccountIDForCharacter(charID)
	var vipActive : bool = Launcher.SQL.GetVIPUntil(accountID) > SQLCommons.Timestamp()
	var vipMult : float = OfflineSettle.VIPModFactor if vipActive else 1.0
	var newbie : bool = player.stat.level < FarmZoneData.NewbieBoostMaxLevel
	var nb : float = float(FarmZoneData.NewbieBoostFactor) if newbie else 1.0

	# SOM-IDLE rebirth: o faucet do boss respeita os mesmos favores da zona.
	var reb : Dictionary = GetRebirthMults(charID)
	var baseXp : int = BossService.VictoryXp(zoneXp) if win else BossService.ConsolationXp(zoneXp)
	var xpGrant : int = maxi(1, roundi(float(baseXp) * nb * vipMult * float(reb.get("xp", 1.0))))
	player.stat.AddExperience(xpGrant, false)
	var goldGrant : int = 0
	if win:
		goldGrant = roundi(float(BossService.VictoryGold(zoneXp)) * nb * vipMult * float(reb.get("gold", 1.0)))
		player.stat.AddGP(goldGrant, false)

	var chestsGranted : int = 0
	if win:
		for i in BossService.BossChestReward:
			if Launcher.SQL.AddChestInstance(charID, FarmZoneData.DefaultDropItemHash, "boss"):
				chestsGranted += 1
		Launcher.SQL.SetCharacterBossesBeaten(charID, index + 1)
		# Fase C: marco do passe (50 PT, auto-crédito, só com temporada ativa).
		_PassMilestoneCredit(accountID, index)
		# Fase F: +5 pontos de guild por vitória.
		GuildSettlePoints(accountID, GUILD_POINT_PER_BOSS_WIN)

	return {
		"ok" = true,
		"started" = false,
		"win" = win,
		"index" = index,
		"boss" = BossService.GetBossName(index),
		"level" = BossService.GetBossLevel(player.stat.level, index),
		"xp" = xpGrant,
		"gold" = goldGrant,
		"chests" = chestsGranted,
		"keys" = Launcher.SQL.GetCharacterBossKeys(charID),
		"beaten" = Launcher.SQL.GetCharacterBossesBeaten(charID),
	}

# ------------------------------------------------------------------ F4: real implementations

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
	if not _LedgerAppendLocked(accountID, charID, LedgerKindItem, count, 0, ledgerReason + ":uid%d" % uid):
		return 0
	return uid

# Executes a direct character-to-character item trade: all-or-nothing escrow
# (invariant 3), fee burned from the initiating account's gems (ECONOMY_STUDY
# §6: trade fee é o sink primário; gems não-cashable). Items are stack rows
# {item_id, count} validated against the FROM character's inventory.
const TradeFeeGems : int = 10
# SOM-IDLE D3: velocity knobs (static var = sintonizável sem rebuild).
static var TradeCooldownSec : int = 60
static var TradeDailyCap : int = 20
const TradeRequireVerifiedEmail : bool = true

func ExecuteTrade(charIDFrom : int, charIDTo : int, itemsFrom : Array, itemsTo : Array) -> bool:
	settleMutex.lock()
	var traded : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		# No self-trade: both sides must belong to different players
		if charIDFrom == charIDTo:
			return false
		var accountFrom : int = _AccountIDForCharacterRaw(charIDFrom)
		var accountTo : int = _AccountIDForCharacterRaw(charIDTo)
		if accountFrom == NetworkCommons.PeerUnknownID or accountTo == NetworkCommons.PeerUnknownID:
			return false

		# SOM-IDLE D3: antifraud gates — identidade verificada, cooldown, cap diário.
		if TradeRequireVerifiedEmail and (not sql.IsEmailVerifiedRaw(accountFrom) or not sql.IsEmailVerifiedRaw(accountTo)):
			return false
		var nowSec : int = SQLCommons.Timestamp()
		if nowSec - sql.LastTradeTimestampRaw(charIDFrom) < TradeCooldownSec:
			return false
		if nowSec - sql.LastTradeTimestampRaw(charIDTo) < TradeCooldownSec:
			return false
		if sql.TradeCountTodayRaw(accountFrom, nowSec) >= TradeDailyCap:
			return false

		# Escrow check: every offered stack must exist with the offered count
		for stack : Dictionary in itemsFrom:
			var itemID : int = int(stack.get("item_id", 0))
			var count : int = int(stack.get("count", 0))
			if itemID <= 0 or count <= 0 or _ItemCountRaw(charIDFrom, itemID) < count:
				return false
		for stack : Dictionary in itemsTo:
			var itemID : int = int(stack.get("item_id", 0))
			var count : int = int(stack.get("count", 0))
			if itemID <= 0 or count <= 0 or _ItemCountRaw(charIDTo, itemID) < count:
				return false

		# Fee burn first (all-or-nothing: a failed fee aborts the whole trade).
		# wallet.gems is the source of truth; the ledger row mirrors the burn.
		var feeBalance : int = sql.GetGemsRaw(accountFrom)
		if feeBalance < TradeFeeGems:
			return false
		if not sql.SetGemsRaw(accountFrom, feeBalance - TradeFeeGems):
			return false
		if not _LedgerAppendLocked(accountFrom, charIDFrom, LedgerKindGems, -TradeFeeGems, feeBalance - TradeFeeGems, "trade_fee"):
			return false

		# Move the stacks (remove from source, add to target) — raw db ops only.
		# SOM-IDLE B1: cada perna consome lotes (FIFO, unbound) e concede lote
		# encadeado; o espelho no ledger carrega os uids (invariant 1 + history).
		for stack : Dictionary in itemsFrom:
			var mv : Dictionary = _MoveStackUIDs(charIDFrom, charIDTo, int(stack["item_id"]), int(stack["count"]))
			if mv.is_empty():
				return false
			if not _LedgerAppendLocked(accountFrom, charIDFrom, LedgerKindItem, -int(stack["count"]), 0, "trade_out:%d:uids%s" % [int(stack["item_id"]), _UIDList(mv["consumed"])]):
				return false
			if not _LedgerAppendLocked(accountTo, charIDTo, LedgerKindItem, int(stack["count"]), 0, "trade_in:%d:lot%d" % [int(stack["item_id"]), int(mv["granted"])]):
				return false
		for stack : Dictionary in itemsTo:
			var mv2 : Dictionary = _MoveStackUIDs(charIDTo, charIDFrom, int(stack["item_id"]), int(stack["count"]))
			if mv2.is_empty():
				return false
			if not _LedgerAppendLocked(accountTo, charIDTo, LedgerKindItem, -int(stack["count"]), 0, "trade_out:%d:uids%s" % [int(stack["item_id"]), _UIDList(mv2["consumed"])]):
				return false
			if not _LedgerAppendLocked(accountFrom, charIDFrom, LedgerKindItem, int(stack["count"]), 0, "trade_in:%d:lot%d" % [int(stack["item_id"]), int(mv2["granted"])]):
				return false
		return true):
		traded = true
	settleMutex.unlock()
	if traded:
		Util.PrintLog("Economy", "Trade %d -> %d executed (%d/%d stacks, fee %d gems)" % [charIDFrom, charIDTo, itemsFrom.size(), itemsTo.size(), TradeFeeGems])
	return traded

# Opens a settle-granted chest with an odds snapshot + provably-fair seeds
# (TECH_SPEC §4 invariant 4; ECONOMY_STUDY §7). The roll is deterministic:
# hash(server_seed + client_seed + nonce) selects a stack from the tier pool
# of the character's farm zone (or zone 1 when unbound).
const ChestPityEvery : int = 10		# guaranteed rare (T3+) every N opens

func OpenChest(charID : int, chestID : int) -> Dictionary:
	var result : Dictionary = {}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array[Dictionary] = sql.db.select_rows("chest_instance", "id = %d AND char_id = %d AND item_state = 'closed'" % [chestID, charID], ["*"])
		if rows.is_empty():
			return false
		var chest : Dictionary = rows[0]
		var accountID : int = _AccountIDForCharacterRaw(charID)
		if accountID == NetworkCommons.PeerUnknownID:
			return false

		# Nonce = open count for this character (pity timer input)
		var nonceRows : Array[Dictionary] = sql.db.select_rows("chest_instance", "char_id = %d AND item_state = 'opened'" % charID, ["id"])
		var nonce : int = nonceRows.size()
		var serverSeed : String = str(chest["id"]) + ":" + str(chest["created_at"]) + ":shambleta"
		var clientSeed : String = str(charID) + ":" + str(nonce)
		var roll : int = Hasher.HashPassword(serverSeed, clientSeed).substr(0, 8).hex_to_int()

		# Farm zone of the character decides the item pool band
		var char : Dictionary = sql.GetCharacter(charID)
		var zoneID : int = int(char.get("farm_zone", 0) if char.get("farm_zone", 0) != null else 0)
		if zoneID <= 0:
			zoneID = 1
		var pity : bool = (nonce + 1) % ChestPityEvery == 0
		var itemHash : int = _RollChestItem(zoneID, roll, pity)
		var count : int = 1

		# SOM-IDLE B2: snapshot de odds + server seed persistidos (dispute replay).
		var odds : Dictionary = GetChestOdds(zoneID)
		var snapshot : String = JSON.stringify({"zone" = zoneID, "pool" = odds["pool"], "tiers" = odds["tiers"], "nonce" = nonce, "pity" = pity, "pity_every" = ChestPityEvery})

		# SOM-IDLE B1: entrega com lote (uid) + espelho no ledger (invariante 1).
		if _GrantStackRaw(charID, accountID, itemHash, count, "chest:%d|%d|%s" % [chestID, itemHash, clientSeed], "chest_open") == 0:
			return false
		if not sql.UpdateRowsRaw("chest_instance", "id = %d" % chestID, {"item_state" = "opened", "odds_snapshot" = snapshot, "server_seed" = serverSeed}):
			return false

		result.clear()
		result.merge({"chest_id" = chestID, "item_id" = itemHash, "count" = count, "pity" = pity, "nonce" = nonce, "server_seed" = serverSeed, "client_seed" = clientSeed, "odds" = odds})
		return true):
		pass
	settleMutex.unlock()
	return result

# SOM-IDLE B2: public chest odds (loot-box compliance). Tier distribution of
# the zone pool + pity rule — shown BEFORE opening (/chests) and snapshotted
# per chest at open time (dispute replay: snapshot + seeds + roll algorithm).
func GetChestOdds(zoneID : int) -> Dictionary:
	var pool : Array = FarmZoneData.GetDropPool(zoneID)
	var tiers : Dictionary = {}
	for itemHash in pool:
		var item : ItemCell = DB.ItemsDB.get(itemHash, null)
		var tier : int = item.tier if item != null else 0
		tiers[tier] = int(tiers.get(tier, 0)) + 1
	return {"zone" = zoneID, "pool" = pool.size(), "tiers" = tiers, "pity_every" = ChestPityEvery}

func GetChestOddsForCharacter(charID : int) -> Dictionary:
	var zoneID : int = 1
	var rows : Array = Launcher.SQL.db.select_rows("character", "char_id = %d" % charID, ["farm_zone"])
	if not rows.is_empty() and rows[0].get("farm_zone", null) != null:
		zoneID = maxi(1, int(rows[0]["farm_zone"]))
	return GetChestOdds(zoneID)

func FormatChestOdds(odds : Dictionary) -> String:
	var parts : PackedStringArray = PackedStringArray()
	var tiers : Dictionary = odds.get("tiers", {})
	var total : int = maxi(1, int(odds.get("pool", 1)))
	var keys : Array = tiers.keys()
	keys.sort()
	for tier in keys:
		parts.append("T%d %.1f%%" % [int(tier), 100.0 * float(tiers[tier]) / float(total)])
	return "Zona %d (pool %d: %s; pity T3+ a cada %d)" % [int(odds.get("zone", 1)), int(odds.get("pool", 0)), ", ".join(parts), int(odds.get("pity_every", ChestPityEvery))]

# Deterministic chest roll: pity forces a T3+ band, otherwise the zone band.
func _RollChestItem(zoneID : int, roll : int, pity : bool) -> int:
	var pool : Array = FarmZoneData.GetDropPool(zoneID)
	if pity:
		var rare : Array[int] = []
		for itemHash in pool:
			var item : ItemCell = DB.ItemsDB.get(itemHash, null)
			if item != null and item.tier >= 3:
				rare.append(itemHash)
		if not rare.is_empty():
			return rare[roll % rare.size()]
	# Fall back to the zone pool (Apple included)
	return FarmZoneData.GetDropForRoll(zoneID, roll)

# ------------------------------------------------------------------ F4: VIP checkout (MONETIZATION §2.2)

# Placeholder pricing (tuning pós-beta; MONETIZATION: R$19.90 / R$39.90 tiers)
const VIP1CostGems : int = 440
const VIP2CostGems : int = 880
const VIPDays : int = 30

# Gems -> vip_until. Extends from the current window when still active.
# Fase B: registra o tier (cap offline 24h/36h) — upgrade nunca rebaixa.
func PurchaseVIP(accountID : int, tier : int) -> bool:
	if tier != 1 and tier != 2:
		return false
	var cost : int = VIP1CostGems if tier == 1 else VIP2CostGems
	var now : int = SQLCommons.Timestamp()
	var currentUntil : int = Launcher.SQL.GetVIPUntil(accountID)
	var base : int = maxi(now, currentUntil)		# stack time when already VIP
	var until : int = base + VIPDays * 86400
	if not AddGems(accountID, -cost, "vip%d_purchase" % tier):
		return false
	if not Launcher.SQL.SetVIPUntil(accountID, until):
		return false
	if tier > Launcher.SQL.GetVIPTier(accountID) or currentUntil <= now:
		Launcher.SQL.SetVIPTier(accountID, tier)
	return true

# ------------------------------------------------------------------ C1: companion grants

# Kinds aceitos (outros → failed, sem parcial). gold exige
# {"char_id": N} no payload, e o char deve pertencer à conta.
const GrantKinds : Array[String] = ["gems", "gold", "vip_days", "pass_premium", "cosmetic"]

# Fase B: tier carregado por grants vip_days (payload sku). Trial/companion
# entram como tier 1; só vip.3mo sobe a 2. Nunca rebaixa tier ativo.
const VIP_GRANT_TIERS : Dictionary = {
	"vip.1mo": 1, "vip.3mo": 2, "founder.pack": 1, "starter.pack": 1,
}

# ------------------------------------------------------------------ beta GUI: shop (sink de gems) + estado consolidado das janelas

# Placeholder pricing (mesmo regime do VIP — tuning pós-beta).
const ChestCostGems : int = 120
const MaxChestsPerPurchase : int = 10

# Gems -> N baús fechados (origin 'shop'). Atômico: débito, ledger e rows no
# MESMO Transaction com ops db-diretas (regra F4 — nada de update_rows aninhado;
# settleMutex não re-entra em AddGems, por isso o path é raw).
# Retorna {"count", "cost", "balance"} ou {} quando rejeitado.
func BuyChests(accountID : int, charID : int, count : int) -> Dictionary:
	var result : Dictionary = {}
	if count < 1 or count > MaxChestsPerPurchase:
		return result
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		var cost : int = ChestCostGems * count
		if balance < cost:
			return false
		if not sql.SetGemsRaw(accountID, balance - cost):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGems, -cost, balance - cost, "chest_buy:%d" % count):
			return false
		for i in count:
			if not sql.AddChestInstance(charID, 0, "shop"):
				return false
		result.clear()
		result.merge({"count" = count, "cost" = cost, "balance" = balance - cost})
		return true):
		pass
	settleMutex.unlock()
	return result

# Estado consolidado das janelas de economia (Shop/Chests): wallet, baús
# fechados, odds públicas (texto pré-formatado, compliance loot box) e preços.
# Uma RPC única — as janelas pedem ao abrir e as ações devolvem o estado novo.
#
# Fase A (checkout sandbox): inclui `catalog` (espelho DISPLAY-ONLY do
# companion/catalog.json — o grant autoritativo vive no companion; preço aqui
# nunca vira crédito), `starter_offer` (elegibilidade one-time D0–D3, sem
# migração: idade via account.created_timestamp + compra prévia via
# grant_queue payload) e `pending_grants` (fila do companion p/ esta conta).
#
# Espelho do catálogo (manter sincronizado com companion/catalog.json).
const SHOP_CATALOG : Array = [
	{"sku": "gems.550", "label": "550 gems", "price": 19.90},
	{"sku": "gems.1200", "label": "1200 gems", "price": 39.90},
	{"sku": "gems.3000", "label": "3000 gems", "price": 79.90},
	{"sku": "vip.1mo", "label": "VIP 30 days", "price": 24.90},
	{"sku": "vip.3mo", "label": "VIP 90 days", "price": 59.90},
	{"sku": "starter.pack", "label": "Starter: VIP 7d + 220 gems (D0–D3, one-time)", "price": 9.90},
	{"sku": "founder.pack", "label": "Founder: 1200 gems + VIP 30d + title", "price": 39.90},
	{"sku": "donate.support", "label": "Support: Apoiador title", "price": 4.90},
	{"sku": "pass.s1.deluxe", "label": "Pass S1 Deluxe: premium + 10 levels + gems", "price": 44.90},
]
const STARTER_SKU : String = "starter.pack"
const STARTER_MAX_AGE_SEC : int = 3 * 86400

func GetStarterOfferState(accountID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT created_timestamp FROM account WHERE account_id = ?;", [accountID])
	if rows.is_empty():
		return {"eligible": false, "reason": "unknown_account", "expires_at": 0}
	var now : int = SQLCommons.Timestamp()
	var created : int = int(rows[0].get("created_timestamp", 0))
	if created <= 0:
		created = now
	var prior : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM grant_queue WHERE account_id = ? AND payload LIKE ? AND status IN ('pending', 'processed');", [accountID, '%"sku": "' + STARTER_SKU + '"%'])
	if not prior.is_empty() and int(prior[0].get("n", 0)) > 0:
		return {"eligible": false, "reason": "already_claimed", "expires_at": 0}
	var expiresAt : int = created + STARTER_MAX_AGE_SEC
	if now > expiresAt:
		return {"eligible": false, "reason": "expired", "expires_at": expiresAt}
	return {"eligible": true, "reason": "ok", "expires_at": expiresAt}

func GetPendingGrants(accountID : int) -> Array:
	var out : Array = []
	for row in Launcher.SQL.QueryBindings("SELECT idempotency_key, payload, created_at FROM grant_queue WHERE account_id = ? AND status = 'pending' ORDER BY id LIMIT 10;", [accountID]):
		var sku : String = "?"
		var parsed : Variant = JSON.parse_string(str(row.get("payload", "")))
		if parsed is Dictionary:
			sku = str((parsed as Dictionary).get("sku", "?"))
		out.append({"key": str(row.get("idempotency_key", "")), "sku": sku, "created_at": int(row.get("created_at", 0))})
	return out

# Intenção de checkout (Fase A sandbox): a loja pede o SKU e recebe o
# external_reference "<account_id>:<sku>" + itens/preço do catálogo. O
# pagamento real (MP, onboarding pendente) usa esse external_reference; o
# grant entra pelo grant_queue idempotente. {} quando inelegível.
func GetCheckoutIntent(accountID : int, sku : String) -> Dictionary:
	var entry : Dictionary = {}
	for e in SHOP_CATALOG:
		if str(e.get("sku", "")) == sku:
			entry = e
			break
	if entry.is_empty():
		return {"ok": false, "reason": "unknown_sku"}
	if sku == STARTER_SKU:
		var offer : Dictionary = GetStarterOfferState(accountID)
		if not bool(offer.get("eligible", false)):
			return {"ok": false, "reason": str(offer.get("reason", "ineligible")), "starter_offer": offer}
	return {"ok": true, "account_id": accountID, "sku": sku,
		"external_reference": "%d:%s" % [accountID, sku],
		"label": str(entry.get("label", sku)), "price": float(entry.get("price", 0.0)),
		"currency": "BRL"}

# ------------------------------------------------------------------ Fase B: loja diária + ofertas (MONETIZATION §2.6)
#
# Rotação determinística server-side (3 de 4 deals por dia), reroll pago em
# gems (3×/dia) e ofertas one-time (packs de boss, fim de temporada). Tudo
# lastreado em mecânicas existentes (baús, vip_until) — sem moeda nova.
const DAILY_REROLL_COST : int = 20
const DAILY_REROLLS_MAX : int = 3
const DAILY_OFFERS_SHOWN : int = 3
# Reset do "dia" às 03:00 BRT (= 06:00 UTC), mesmo boundary das missões (S1).
const SHOP_DAY_UTC_OFFSET : int = 6 * 3600
const DAILY_POOL : Array = [
	{"id": "deal_chest1", "label": "1 chest", "kind": "chests", "count": 1, "cost": 120},
	{"id": "deal_chests5", "label": "5 chests (save 120)", "kind": "chests", "count": 5, "cost": 480},
	{"id": "deal_chests10", "label": "10 chests (save 240)", "kind": "chests", "count": 10, "cost": 960},
	{"id": "deal_vip3", "label": "VIP 3-day trial", "kind": "vip_days", "count": 3, "cost": 150},
]
# Packs de boss: 3 baús por 240 (save 120), um por boss vencido (ordem
# BossService.BossNames). Fim de temporada: 5 baús por 400 nas últimas 48h.
const BOSS_PACK_COST : int = 240
const BOSS_PACK_CHESTS : int = 3
const FINALE_CHESTS : int = 5
const FINALE_COST : int = 400
const FINALE_WINDOW_SEC : int = 2 * 86400

static func ShopDay(now : int) -> int:
	return (now - SHOP_DAY_UTC_OFFSET) / 86400

func _RotatedDailyOffers(accountID : int, day : int, salt : int) -> Array:
	var out : Array = []
	var n : int = DAILY_POOL.size()
	var start : int = absi(accountID + day * 7 + salt * 13) % n
	for k in DAILY_OFFERS_SHOWN:
		var e : Dictionary = (DAILY_POOL[(start + k) % n] as Dictionary).duplicate()
		e["claimed"] = false
		out.append(e)
	return out

# Garante a linha do dia (cria com salt 0) e aplica claimed por cima.
func _DailyRow(accountID : int, day : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT salt, offers_json, claimed_json, rerolls_used FROM shop_daily WHERE account_id = ? AND day = ?;", [accountID, day])
	if rows.is_empty():
		var offers : Array = _RotatedDailyOffers(accountID, day, 0)
		Launcher.SQL.ExecuteBindings("INSERT OR IGNORE INTO shop_daily (account_id, day, salt, offers_json, claimed_json, rerolls_used) VALUES (?, ?, 0, ?, '[]', 0);", [accountID, day, JSON.stringify(offers)])
		return {"salt": 0, "offers": offers, "claimed": [], "rerolls_used": 0}
	var row : Dictionary = rows[0]
	var offersParsed : Variant = JSON.parse_string(str(row.get("offers_json", "[]")))
	var claimedParsed : Variant = JSON.parse_string(str(row.get("claimed_json", "[]")))
	var offers : Array = offersParsed if offersParsed is Array else _RotatedDailyOffers(accountID, day, int(row.get("salt", 0)))
	var claimed : Array = claimedParsed if claimedParsed is Array else []
	for e in offers:
		(e as Dictionary)["claimed"] = str((e as Dictionary).get("id", "")) in claimed
	return {"salt": int(row.get("salt", 0)), "offers": offers, "claimed": claimed, "rerolls_used": int(row.get("rerolls_used", 0))}

func _MaxBossesBeaten(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT MAX(bosses_beaten) AS m FROM character WHERE account_id = ?;", [accountID])
	if rows.is_empty() or rows[0].get("m", null) == null:
		return 0
	return int(rows[0]["m"])

func _OneTimeOffers(accountID : int) -> Array:
	var out : Array = []
	var beaten : int = _MaxBossesBeaten(accountID)
	for i in mini(beaten, BossService.BossNames.size()):
		var oid : String = "boss-%d-pack" % i
		var claimed : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT 1 FROM shop_offer_claim WHERE account_id = ? AND offer_id = ?;", [accountID, oid])
		if claimed.is_empty():
			out.append({"id": oid, "label": "%s victory pack: %d chests" % [BossService.BossNames[i], BOSS_PACK_CHESTS],
				"kind": "chests", "count": BOSS_PACK_CHESTS, "cost": BOSS_PACK_COST, "claimed": false})
	var season : Dictionary = ActiveSeason()
	if not season.is_empty():
		var sid : int = int(season.get("season_id", 0))
		var left : int = int(season.get("ends_at", 0)) - SQLCommons.Timestamp()
		if sid > 0 and left > 0 and left <= FINALE_WINDOW_SEC:
			var fid : String = "season-%d-finale" % sid
			var fclaimed : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT 1 FROM shop_offer_claim WHERE account_id = ? AND offer_id = ?;", [accountID, fid])
			if fclaimed.is_empty():
				out.append({"id": fid, "label": "Season finale: %d chests" % FINALE_CHESTS,
					"kind": "chests", "count": FINALE_CHESTS, "cost": FINALE_COST, "claimed": false})
	return out

func GetDailyShop(accountID : int) -> Dictionary:
	var day : int = ShopDay(SQLCommons.Timestamp())
	var row : Dictionary = _DailyRow(accountID, day)
	return {"ok": true, "day": day, "offers": row["offers"],
		"rerolls_used": int(row["rerolls_used"]), "rerolls_max": DAILY_REROLLS_MAX,
		"reroll_cost": DAILY_REROLL_COST, "one_time": _OneTimeOffers(accountID)}

func RerollDailyShop(accountID : int) -> Dictionary:
	var day : int = ShopDay(SQLCommons.Timestamp())
	var row : Dictionary = _DailyRow(accountID, day)
	if int(row["rerolls_used"]) >= DAILY_REROLLS_MAX:
		return {"ok": false, "reason": "reroll_cap"}
	if not AddGems(accountID, -DAILY_REROLL_COST, "daily_reroll"):
		return {"ok": false, "reason": "insufficient_gems"}
	return _DoReroll(accountID, day, row)

# Gira a rotação (contador compartilhado pago/ad). Chamador já validou e
# cobrou (ou registrou a view, no caso do ad).
func _DoReroll(accountID : int, day : int, row : Dictionary) -> Dictionary:
	var salt : int = int(row["salt"]) + 1
	var offers : Array = _RotatedDailyOffers(accountID, day, salt)
	var claimed : Array = row["claimed"]
	for e in offers:
		(e as Dictionary)["claimed"] = str((e as Dictionary).get("id", "")) in claimed
	Launcher.SQL.ExecuteBindings("UPDATE shop_daily SET salt = ?, offers_json = ?, rerolls_used = rerolls_used + 1 WHERE account_id = ? AND day = ?;", [salt, JSON.stringify(offers), accountID, day])
	return {"ok": true, "day": day, "offers": offers,
		"rerolls_used": int(row["rerolls_used"]) + 1, "rerolls_max": DAILY_REROLLS_MAX,
		"reroll_cost": DAILY_REROLL_COST, "one_time": _OneTimeOffers(accountID)}

# Compra oferta diária ou one-time. Débito + grant + marca claimed na MESMA
# transação (settleMutex; ops raw, regra F4).
func BuyDailyOffer(accountID : int, charID : int, offerID : String) -> Dictionary:
	var day : int = ShopDay(SQLCommons.Timestamp())
	var row : Dictionary = _DailyRow(accountID, day)
	var offer : Dictionary = {}
	for e in row["offers"]:
		if str((e as Dictionary).get("id", "")) == offerID:
			offer = e
			break
	var oneTime : bool = false
	if offer.is_empty():
		for e in _OneTimeOffers(accountID):
			if str((e as Dictionary).get("id", "")) == offerID:
				offer = e
				oneTime = true
				break
	if offer.is_empty():
		return {"ok": false, "reason": "unknown_offer"}
	if bool(offer.get("claimed", false)):
		return {"ok": false, "reason": "already_claimed"}
	var cost : int = int(offer.get("cost", 0))
	var kind : String = str(offer.get("kind", ""))
	var count : int = int(offer.get("count", 0))
	if cost <= 0 or count <= 0 or (kind != "chests" and kind != "vip_days"):
		return {"ok": false, "reason": "bad_offer"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		if balance < cost:
			return false
		if not sql.SetGemsRaw(accountID, balance - cost):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGems, -cost, balance - cost, "daily_offer:" + offerID):
			return false
		if kind == "chests":
			for i in count:
				if not sql.AddChestInstance(charID, 0, "daily"):
					return false
		else:
			var now : int = SQLCommons.Timestamp()
			var cur : int = sql.GetVIPUntil(accountID)
			var until : int = maxi(now, cur) + count * 86400
			if not sql.SetVIPUntil(accountID, until):
				return false
			var curTier : int = sql.GetVIPTier(accountID)
			if curTier < 1 or cur <= now:
				if not sql.SetVIPTier(accountID, 1):
					return false
		if oneTime:
			if not sql.ExecuteBindings("INSERT OR IGNORE INTO shop_offer_claim (account_id, offer_id, claimed_at) VALUES (?, ?, ?);", [accountID, offerID, SQLCommons.Timestamp()]):
				return false
		else:
			var claimed : Array = (row["claimed"] as Array).duplicate()
			claimed.append(offerID)
			if not sql.ExecuteBindings("UPDATE shop_daily SET claimed_json = ? WHERE account_id = ? AND day = ?;", [JSON.stringify(claimed), accountID, day]):
				return false
		result["ok"] = true
		result["reason"] = "ok"
		result["cost"] = cost
		result["balance"] = balance - cost
		return true):
		pass
	settleMutex.unlock()
	return result

func GetEconomyState(accountID : int, charID : int) -> Dictionary:
	var chestIDs : Array = []
	for chest in Launcher.SQL.GetClosedChests(charID):
		chestIDs.append(int(chest["id"]))
	var until : int = Launcher.SQL.GetVIPUntil(accountID)
	var now : int = SQLCommons.Timestamp()
	var vipActive : bool = until > now
	var odds : Dictionary = GetChestOddsForCharacter(charID)
	return {
		"gems" = GetGems(accountID),
		"chests" = chestIDs,
		"odds" = odds,
		"odds_text" = FormatChestOdds(odds),
		"chest_cost" = ChestCostGems,
		"vip" = {"active" = vipActive, "until" = until, "mods" = OfflineSettle.VIPModFactor if vipActive else 1.0,
			"tier" = Launcher.SQL.GetVIPTier(accountID) if vipActive else 0,
			"cap_hours" = OfflineSettle.CapHoursForAccount(accountID, now)},
		"vip1_cost" = VIP1CostGems,
		"vip2_cost" = VIP2CostGems,
		"catalog" = SHOP_CATALOG,
		"starter_offer" = GetStarterOfferState(accountID),
		"pending_grants" = GetPendingGrants(accountID),
	}

# Boards da temporada ativa em um shot, já com nomes resolvidos (GUI de
# leaderboard). {} quando não há temporada ativa.
func GetSeasonBoardsState(limit : int = 10) -> Dictionary:
	var season : Dictionary = ActiveSeason()
	if season.is_empty():
		return {}
	var seasonID : int = int(season["season_id"])
	return {
		"season_id" = seasonID,
		"ends_at" = int(season["ends_at"]),
		"power" = _NamedSeasonBoard(seasonID, "power", limit),
		"spend" = _NamedSeasonBoard(seasonID, "spend", limit),
		"boss_kills" = _NamedSeasonBoard(seasonID, "boss_kills", limit),
		"guild_points" = _NamedSeasonBoard(seasonID, "guild_points", limit),
	}

# subject_id → nome legível: power é por char (nickname), spend por conta
# (username). ≤ limit rows por board, chamada rate-limited — queries por linha OK.
# Fase D: inclui o título equipado (vitrine social do passe/renascimento).
func _NamedSeasonBoard(seasonID : int, kind : String, limit : int) -> Array:
	var named : Array = []
	for row in GetSeasonBoard(seasonID, kind, limit):
		var name : String = "?"
		var title : String = ""
		if kind == "power":
			var chars : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT nickname, account_id FROM character WHERE char_id = ?;", [int(row["subject_id"])])
			if not chars.is_empty():
				name = str(chars[0].get("nickname", "?"))
				title = EquippedTitleLabel(int(chars[0].get("account_id", 0)))
		else:
			var accounts : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT username FROM account WHERE account_id = ?;", [int(row["subject_id"])])
			name = str(accounts[0]["username"]) if not accounts.is_empty() else "?"
			title = EquippedTitleLabel(int(row["subject_id"]))
		if kind == "boss_kills":
			var bchars : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT nickname, account_id FROM character WHERE char_id = ?;", [int(row["subject_id"])])
			if not bchars.is_empty():
				name = str(bchars[0].get("nickname", "?"))
				title = EquippedTitleLabel(int(bchars[0].get("account_id", 0)))
		if kind == "guild_points":
			var guilds : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT name, tag, leader_account FROM guild WHERE guild_id = ?;", [int(row["subject_id"])])
			if not guilds.is_empty():
				name = str(guilds[0].get("name", "?"))
				var gtag : String = str(guilds[0].get("tag", ""))
				if not gtag.is_empty():
					name = "[%s] %s" % [gtag, name]
				title = EquippedTitleLabel(int(guilds[0].get("leader_account", 0)))
		named.append({"name" = name, "value" = int(row["value"]), "title" = title})
	return named


# Enfileira um grant (idempotente pela chave: duplicada = já na fila, sem erro).
func EnqueueGrant(accountID : int, kind : String, amount : int, idempotencyKey : String, payload : String = "{}") -> bool:
	if idempotencyKey.is_empty() or amount <= 0 or not GrantKinds.has(kind):
		return false
	var sql : SQLService = Launcher.SQL
	if sql.QueryBindings("SELECT id FROM grant_queue WHERE idempotency_key = ?;", [idempotencyKey]).size() > 0:
		return true
	if sql.QueryBindings("SELECT account_id FROM account WHERE account_id = ?;", [accountID]).is_empty():
		return false
	return sql.ExecuteBindings("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount, payload, status, created_at) VALUES (?, ?, ?, ?, ?, 'pending', ?);", [idempotencyKey, accountID, kind, amount, payload, SQLCommons.Timestamp()])

# Consome a fila: cada grant na própria transação (um ruim não trava os outros).
# Retorna {"processed": N, "failed": M}.
func ProcessPendingGrants(limit : int = 50) -> Dictionary:
	var done : Dictionary = {"processed" = 0, "failed" = 0}
	settleMutex.lock()
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, idempotency_key, account_id, kind, amount, payload FROM grant_queue WHERE status = 'pending' ORDER BY id LIMIT ?;", [limit])
	for row in rows:
		var grantID : int = int(row["id"])
		if Launcher.SQL.Transaction(func() -> bool: return _ApplyGrantRaw(row)):
			Launcher.SQL.ExecuteBindings("UPDATE grant_queue SET status = 'processed', processed_at = ? WHERE id = ? AND status = 'pending';", [SQLCommons.Timestamp(), grantID])
			done["processed"] = int(done["processed"]) + 1
		else:
			Launcher.SQL.ExecuteBindings("UPDATE grant_queue SET status = 'failed', error = 'apply_failed', processed_at = ? WHERE id = ? AND status = 'pending';", [SQLCommons.Timestamp(), grantID])
			done["failed"] = int(done["failed"]) + 1
	settleMutex.unlock()
	return done

# Aplica um grant DENTRO de Transaction() — só ops raw (db direto, sem mutex).
func _ApplyGrantRaw(grant : Dictionary) -> bool:
	var sql : SQLService = Launcher.SQL
	var dbNode : SQLite = sql.db
	var accountID : int = int(grant["account_id"])
	var kind : String = str(grant["kind"])
	var amount : int = int(grant["amount"])
	var now : int = SQLCommons.Timestamp()
	if dbNode.select_rows("account", "account_id = %d" % accountID, ["account_id"]).is_empty():
		return false
	if kind == "gems":
		var balance : int = sql.GetGemsRaw(accountID)
		if not sql.SetGemsRaw(accountID, balance + amount):
			return false
		return _LedgerAppendLocked(accountID, 0, LedgerKindGems, amount, balance + amount, "grant:%s" % str(grant["idempotency_key"]))
	if kind == "gold":
		var parsed : Variant = JSON.parse_string(str(grant.get("payload", "")))
		if not (parsed is Dictionary):
			return false
		var charID : int = int((parsed as Dictionary).get("char_id", 0))
		if charID <= 0 or _AccountIDForCharacterRaw(charID) != accountID:
			return false
		var statRows : Array = dbNode.select_rows("stat", "char_id = %d" % charID, ["gp"])
		if statRows.is_empty():
			return false
		var gp : int = int(statRows[0].get("gp", 0)) if statRows[0].get("gp", null) != null else 0
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp + amount}):
			return false
		return _LedgerAppendLocked(accountID, charID, LedgerKindGold, amount, gp + amount, "grant:%s" % str(grant["idempotency_key"]))
	if kind == "vip_days":
		var vipRows : Array = dbNode.select_rows("account", "account_id = %d" % accountID, ["vip_until", "vip_tier"])
		var current : int = int(vipRows[0].get("vip_until", 0)) if not vipRows.is_empty() and vipRows[0].get("vip_until", null) != null else 0
		var until : int = maxi(now, current) + amount * 86400
		if not sql.UpdateRowsRaw("account", "account_id = %d" % accountID, {"vip_until" = until}):
			return false
		# Fase B: grants carregam tier pelo SKU (trial/companion nunca rebaixa).
		var grantedTier : int = 1
		var parsedSku : Variant = JSON.parse_string(str(grant.get("payload", "")))
		if parsedSku is Dictionary:
			grantedTier = int(VIP_GRANT_TIERS.get(str((parsedSku as Dictionary).get("sku", "")), 1))
		var curTier : int = int(vipRows[0].get("vip_tier", 0)) if not vipRows.is_empty() and vipRows[0].get("vip_tier", null) != null else 0
		if grantedTier > curTier or current <= now:
			if not sql.UpdateRowsRaw("account", "account_id = %d" % accountID, {"vip_tier" = grantedTier}):
				return false
		return _LedgerAppendLocked(accountID, 0, "vip", amount, until, "grant:%s" % str(grant["idempotency_key"]))
	if kind == "pass_premium":
		# Fase C: premium do passe (companion sku pass.s1). Aplica na temporada
		# do payload ou na ativa; sem temporada ativa → failed (venda só
		# durante a temporada, calendário live-ops). Idempotente por linha.
		# Follow-up Deluxe (BATTLE_PASS_S1 §4): tier deluxe soma 10 níveis
		# (PT até L10), emote Coroa do Sol e 150 gems — preço no catálogo.
		var parsedPass : Variant = JSON.parse_string(str(grant.get("payload", "")))
		var sid : int = 0
		var tier : String = "standard"
		if parsedPass is Dictionary:
			if int((parsedPass as Dictionary).get("season_id", 0)) > 0:
				sid = int((parsedPass as Dictionary)["season_id"])
			if str((parsedPass as Dictionary).get("tier", "")) == "deluxe":
				tier = "deluxe"
		if sid <= 0:
			var active : Dictionary = ActiveSeason()
			if active.is_empty():
				return false
			sid = int(active.get("season_id", 0))
		if sid <= 0:
			return false
		var st : Dictionary = _PassStateRaw(accountID, sid)
		if int(st.get("premium", 0)) == 0:
			if not sql.ExecuteBindings("UPDATE season_account_state SET premium = 1 WHERE account_id = ? AND season_id = ?;", [accountID, sid]):
				return false
		if not _LedgerAppendLocked(accountID, 0, "pass", 1, 1, "grant:%s" % str(grant["idempotency_key"])):
			return false
		if tier == "deluxe":
			var maxPT : int = int((PassThresholds() as Array).back())
			var boosted : int = mini(maxi(int(st.get("pt", 0)), 1000), maxPT)
			if not sql.ExecuteBindings("UPDATE season_account_state SET pt = ? WHERE account_id = ? AND season_id = ?;", [boosted, accountID, sid]):
				return false
			if not sql.ExecuteBindings("INSERT OR IGNORE INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, 'emote_coroa', ?, ?);", [accountID, "grant:%s" % str(grant["idempotency_key"]), now]):
				return false
			var gbal : int = sql.GetGemsRaw(accountID)
			if not sql.SetGemsRaw(accountID, gbal + 150):
				return false
			if not _LedgerAppendLocked(accountID, 0, LedgerKindGems, 150, gbal + 150, "grant:%s" % str(grant["idempotency_key"])):
				return false
		return true
	if kind == "cosmetic":
		# Fase F: cosmético direto (doação "apoiar" → título Apoiador; futuro:
		# presentes). O cosmetic_id vem do payload (catálogo do companion).
		var parsedCos : Variant = JSON.parse_string(str(grant.get("payload", "")))
		var cid : String = str((parsedCos as Dictionary).get("cosmetic_id", "")) if parsedCos is Dictionary else ""
		if cid.is_empty() or not COSMETIC_CATALOG.has(cid):
			return false
		if not sql.ExecuteBindings("INSERT OR IGNORE INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, ?, ?, ?);", [accountID, cid, "grant:%s" % str(grant["idempotency_key"]), now]):
			return false
		return _LedgerAppendLocked(accountID, 0, "cosmetic", 1, 1, "grant:%s" % str(grant["idempotency_key"]))
	return false

# ------------------------------------------------------------------ CDC art.49 — direito de arrependimento
# Compra à distância: o consumidor desiste em 7 dias. Como gems são fungíveis,
# "não consumidas" = o saldo atual cobre o montante comprado. Regras (na ordem):
#   não_found / window_expired / already_refunded / gems_consumed.
# O estorno do DINHEIRO cabe ao companion/provedor (onboarding pendente — handoff);
# aqui o jogo reverte as gems + grava no ledger (prova de auditoria, append-only).
const RefundWindowSeconds : int = 7 * 86400

func RequestGemRefund(accountID : int, idempotencyKey : String) -> Dictionary:
	if idempotencyKey.is_empty():
		return {"ok" = false, "reason" = "bad_request"}
	var sql : SQLService = Launcher.SQL
	var now : int = SQLCommons.Timestamp()
	# (1) a compra original: linha de ledger gems criada por grant:<key>
	var buys : Array[Dictionary] = sql.QueryBindings(
		"SELECT id, amount, created_at FROM ledger_transaction WHERE account_id = ? AND kind = ? AND reason = ? ORDER BY id LIMIT 1;",
		[accountID, LedgerKindGems, "grant:" + idempotencyKey])
	if buys.is_empty():
		return {"ok" = false, "reason" = "not_found"}
	var amount : int = int(buys[0]["amount"])
	if amount <= 0:
		return {"ok" = false, "reason" = "not_found"}
	# (2) janela de 7 dias
	if now - int(buys[0]["created_at"]) > RefundWindowSeconds:
		return {"ok" = false, "reason" = "window_expired"}
	# (3) já reembolsada? (linha refund:<key>)
	if not sql.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, "refund:" + idempotencyKey]).is_empty():
		return {"ok" = false, "reason" = "already_refunded"}
	# (4) gems não consumidas: saldo atual >= montante comprado
	if sql.GetGems(accountID) < amount:
		return {"ok" = false, "reason" = "gems_consumed"}
	# aplica o estorno de forma atômica (re-verifica o saldo sob o lock)
	var applied : bool = false
	settleMutex.lock()
	if sql.Transaction(func() -> bool:
		var current : int = sql.GetGemsRaw(accountID)
		if current < amount:
			return false
		if not sql.SetGemsRaw(accountID, current - amount):
			return false
		if not _LedgerAppendLocked(accountID, 0, LedgerKindGems, -amount, current - amount, "refund:" + idempotencyKey):
			return false
		sql.db.query_with_bindings("UPDATE grant_queue SET status = 'refunded', processed_at = ? WHERE idempotency_key = ? AND account_id = ?;", [now, idempotencyKey, accountID])
		return true):
		applied = true
	settleMutex.unlock()
	if not applied:
		return {"ok" = false, "reason" = "gems_consumed"}
	return {"ok" = true, "reason" = "refunded", "amount" = amount}

# ------------------------------------------------------------------ E1: guilds

const GuildCreateCostGold : int = 5000
const GuildMaxLevel : int = 10
# Custo de nível 1→2 .. 9→10 (índice = nível atual). Pontos: coluna pronta,
# acúmulo via settle = fast follow (v0 = gold+gems).
const GuildLevelCostGold : Array[int] = [0, 5000, 15000, 40000, 100000, 250000, 600000, 1500000, 4000000, 10000000]
const GuildLevelCostGems : Array[int] = [0, 50, 120, 300, 700, 1500, 3000, 6000, 12000, 25000]
const GuildBuffPerLevel : float = 0.02

func GetGuildForAccount(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT guild_id FROM guild_member WHERE account_id = ?;", [accountID])
	return int(rows[0]["guild_id"]) if not rows.is_empty() else 0

func GetGuild(guildID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT guild_id, name, level, points, leader_account, created_at FROM guild WHERE guild_id = ?;", [guildID])
	return {} if rows.is_empty() else rows[0]

func GetMemberRank(accountID : int) -> String:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT rank FROM guild_member WHERE account_id = ?;", [accountID])
	return str(rows[0]["rank"]) if not rows.is_empty() else ""

func GuildBuffForAccount(accountID : int) -> float:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT g.level FROM guild g INNER JOIN guild_member m ON m.guild_id = g.guild_id WHERE m.account_id = ?;", [accountID])
	if rows.is_empty():
		return 1.0
	return 1.0 + GuildBuffPerLevel * float(maxi(0, int(rows[0]["level"]) - 1))

func GetGuildLeaderboard(limit : int = 10) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT g.guild_id, g.name, g.level, g.points, COUNT(m.account_id) AS members FROM guild g LEFT JOIN guild_member m ON m.guild_id = g.guild_id GROUP BY g.guild_id ORDER BY g.level DESC, g.points DESC, members DESC LIMIT ?;", [limit])

func _CharGoldRaw(charID : int) -> int:
	var rows : Array = Launcher.SQL.db.select_rows("stat", "char_id = %d" % charID, ["gp"])
	if rows.is_empty() or rows[0].get("gp", null) == null:
		return 0
	return int(rows[0]["gp"])

func CreateGuild(accountID : int, charID : int, guildName : String) -> int:
	var clean : String = guildName.strip_edges()
	if not NetworkCommons.CheckSize(clean, 3, 30) or GetGuildForAccount(accountID) != 0:
		return 0
	var out : Dictionary = {"id" = 0}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if _CharGoldRaw(charID) < GuildCreateCostGold:
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild (name, level, points, leader_account, created_at) VALUES (?, 1, 0, ?, ?);", [clean, accountID, SQLCommons.Timestamp()]):
			return false
		var guildID : int = sql.LastInsertRowIDRaw()
		if guildID <= 0:
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'leader', ?);", [guildID, accountID, SQLCommons.Timestamp()]):
			return false
		var gp : int = _CharGoldRaw(charID)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - GuildCreateCostGold}):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGold, -GuildCreateCostGold, gp - GuildCreateCostGold, "guild_create"):
			return false
		out["id"] = guildID
		return true):
		pass
	settleMutex.unlock()
	return int(out["id"])

func JoinGuild(accountID : int, guildID : int) -> bool:
	if GetGuildForAccount(accountID) != 0 or GetGuild(guildID).is_empty():
		return false
	return Launcher.SQL.ExecuteBindings("INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'member', ?);", [guildID, accountID, SQLCommons.Timestamp()])

func LeaveGuild(accountID : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return false
	var left : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var members : Array = sql.db.select_rows("guild_member", "guild_id = %d ORDER BY joined_at" % guildID, ["account_id", "rank"])
		if members.is_empty():
			return false
		var isLeader : bool = false
		for m in members:
			if int(m["account_id"]) == accountID and str(m["rank"]) == "leader":
				isLeader = true
		if members.size() == 1:
			# Último membro dissolve a guild — vault precisa estar vazio (sem perda).
			if not sql.db.select_rows("guild_vault", "guild_id = %d" % guildID, ["item_id"]).is_empty():
				return false
			if not sql.DeleteRowsRaw("guild_member", "guild_id = %d" % guildID):
				return false
			return sql.DeleteRowsRaw("guild", "guild_id = %d" % guildID)
		if not sql.DeleteRowsRaw("guild_member", "guild_id = %d AND account_id = %d" % [guildID, accountID]):
			return false
		if isLeader:
			# Promove o membro mais antigo a líder.
			for m in members:
				if int(m["account_id"]) != accountID:
					return sql.UpdateRowsRaw("guild_member", "guild_id = %d AND account_id = %d" % [guildID, int(m["account_id"])], {"rank" = "leader"}) \
						and sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"leader_account" = int(m["account_id"])})
			return false
		return true):
		left = true
	settleMutex.unlock()
	return left

func DepositToVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0 or itemID <= 0 or count <= 0:
		return false
	var ok : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var consumed : Array = sql.ConsumeItemLotsRaw(charID, itemID, count, false)
		if consumed.is_empty():
			return false
		var stock : int = _ItemCountRaw(charID, itemID)
		if stock < count:
			return false
		if stock > count:
			if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], {"count" = stock - count}):
				return false
		elif not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID]):
			return false
		var vault : Array = sql.db.select_rows("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], ["count"])
		if vault.is_empty():
			# Fase F: teto de stacks distintas (expansível por nível/compra).
			var distinct : Array = sql.db.select_rows("guild_vault", "guild_id = %d" % guildID, ["item_id"])
			if distinct.size() >= VaultSlotsForGuild(guildID).get("cap", 0):
				return false
			if not sql.db.insert_row("guild_vault", {"guild_id" = guildID, "item_id" = itemID, "count" = count}):
				return false
		elif not sql.UpdateRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], {"count" = int(vault[0]["count"]) + count}):
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild_vault_log (guild_id, account_id, char_id, item_id, count, kind, created_at) VALUES (?, ?, ?, ?, ?, 'deposit', ?);", [guildID, accountID, charID, itemID, count, SQLCommons.Timestamp()]):
			return false
		return _LedgerAppendLocked(accountID, charID, LedgerKindItem, -count, 0, "vault_deposit:%d:%d" % [guildID, itemID])):
		ok = true
	settleMutex.unlock()
	return ok

func WithdrawFromVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0 or itemID <= 0 or count <= 0:
		return false
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return false
	var ok : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var vault : Array = sql.db.select_rows("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], ["count"])
		if vault.is_empty() or int(vault[0]["count"]) < count:
			return false
		var remain : int = int(vault[0]["count"]) - count
		if remain > 0:
			if not sql.UpdateRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], {"count" = remain}):
				return false
		elif not sql.DeleteRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID]):
			return false
		if _GrantStackRaw(charID, accountID, itemID, count, "vault_withdraw:%d:%d" % [guildID, itemID], "vault_withdraw") == 0:
			return false
		return sql.db.query_with_bindings("INSERT INTO guild_vault_log (guild_id, account_id, char_id, item_id, count, kind, created_at) VALUES (?, ?, ?, ?, ?, 'withdraw', ?);", [guildID, accountID, charID, itemID, count, SQLCommons.Timestamp()])):
		ok = true
	settleMutex.unlock()
	return ok

func LevelUpGuild(accountID : int, charID : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return false
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return false
	var ok : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("guild", "guild_id = %d" % guildID, ["level"])
		if rows.is_empty():
			return false
		var level : int = int(rows[0]["level"])
		if level < 1 or level >= GuildMaxLevel:
			return false
		var costGold : int = GuildLevelCostGold[level]
		var costGems : int = GuildLevelCostGems[level]
		if _CharGoldRaw(charID) < costGold:
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < costGems:
			return false
		var gp : int = _CharGoldRaw(charID)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - costGold}):
			return false
		if not sql.SetGemsRaw(accountID, gems - costGems):
			return false
		if not sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"level" = level + 1}):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGold, -costGold, gp - costGold, "guild_level"):
			return false
		return _LedgerAppendLocked(accountID, charID, LedgerKindGems, -costGems, gems - costGems, "guild_level")):
		ok = true
	settleMutex.unlock()
	return ok

func PromoteMember(leaderAccount : int, targetAccount : int) -> bool:
	if GetMemberRank(leaderAccount) != "leader":
		return false
	if GetGuildForAccount(targetAccount) != GetGuildForAccount(leaderAccount) or GetGuildForAccount(leaderAccount) == 0:
		return false
	return Launcher.SQL.ExecuteBindings("UPDATE guild_member SET rank = 'officer' WHERE account_id = ?;", [targetAccount])

# Follow-up G3: tag da guild (2–5 chars A-Z0-9, só líder). Exibida no board,
# no painel e nas corridas ([TAG] Nome) — identidade sem poder.
static func IsValidGuildTag(tag : String) -> bool:
	if tag.length() < 2 or tag.length() > 5:
		return false
	for c in tag:
		if not ((c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
			return false
	return true

func SetGuildTag(accountID : int, tag : String) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return {"ok": false, "reason": "no_guild"}
	if GetMemberRank(accountID) != "leader":
		return {"ok": false, "reason": "not_leader"}
	var clean : String = tag.strip_edges().to_upper()
	if not IsValidGuildTag(clean):
		return {"ok": false, "reason": "bad_tag"}
	if not Launcher.SQL.ExecuteBindings("UPDATE guild SET tag = ? WHERE guild_id = ?;", [clean, guildID]):
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok", "tag": clean}

# ------------------------------------------------------------------ Fase F: guild premium (MONETIZATION §1 item 10)
#
# Pontos acumulam no settle (1/hora) e na vitória de boss (+5): a corrida
# guild_points da temporada nasce daqui. Level-up fast pula o gold (2× gems).
# Vault tem teto de stacks distintas (10 + 2/nível + comprados, máx +20).
const GUILD_POINT_PER_SETTLE_HOUR : int = 1
const GUILD_POINT_PER_BOSS_WIN : int = 5
const GUILD_VAULT_BASE_SLOTS : int = 10
const GUILD_VAULT_PER_LEVEL : int = 2
const GUILD_VAULT_SLOT_COST : int = 200
const GUILD_VAULT_SLOTS_MAX : int = 20
const GUILD_PRIZE_GEMS : Array[int] = [1000, 600, 300]

func AddGuildPoints(guildID : int, points : int) -> bool:
	if guildID <= 0 or points <= 0:
		return false
	return Launcher.SQL.ExecuteBindings("UPDATE guild SET points = points + ? WHERE guild_id = ?;", [points, guildID])

# Chamado no settle (dentro da transação do caller): 1 pt/hora liquidada.
func GuildSettlePoints(accountID : int, hours : float) -> void:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID > 0:
		AddGuildPoints(guildID, maxi(1, floori(hours)))

func VaultSlotsForGuild(guildID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT level, vault_slots_purchased FROM guild WHERE guild_id = ?;", [guildID])
	if rows.is_empty():
		return {"cap": 0, "used": 0, "purchased": 0}
	var cap : int = GUILD_VAULT_BASE_SLOTS + GUILD_VAULT_PER_LEVEL * maxi(0, int(rows[0].get("level", 1)) - 1) + int(rows[0].get("vault_slots_purchased", 0))
	var used : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM guild_vault WHERE guild_id = ?;", [guildID])
	return {"cap": cap, "used": int(used[0]["n"]) if not used.is_empty() else 0, "purchased": int(rows[0].get("vault_slots_purchased", 0))}

func GetGuildState(accountID : int) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	var mine : Dictionary = {}
	if guildID > 0:
		var g : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT name, tag, level, points FROM guild WHERE guild_id = ?;", [guildID])
		var members : Array = []
		for m in Launcher.SQL.QueryBindings("SELECT a.username, gm.rank FROM guild_member AS gm INNER JOIN account AS a ON a.account_id = gm.account_id WHERE gm.guild_id = ? ORDER BY gm.rank, a.username;", [guildID]):
			members.append({"name": str(m.get("username", "?")), "rank": str(m.get("rank", "member"))})
		if not g.is_empty():
			mine = {"id": guildID, "name": str(g[0].get("name", "?")), "tag": str(g[0].get("tag", "")),
				"level": int(g[0].get("level", 1)),
				"points": int(g[0].get("points", 0)), "my_rank": GetMemberRank(accountID),
				"vault": VaultSlotsForGuild(guildID), "members": members}
	var board : Array = []
	for b in Launcher.SQL.QueryBindings("SELECT name, tag, level, points FROM guild ORDER BY points DESC, guild_id ASC LIMIT 10;", []):
		board.append({"name": str(b.get("name", "?")), "tag": str(b.get("tag", "")), "level": int(b.get("level", 1)), "points": int(b.get("points", 0))})
	return {"ok": true, "my_guild": mine, "board": board,
		"vault_slot_cost": GUILD_VAULT_SLOT_COST}

# Level-up fast (leader/officer): pula o gold pagando 2× gems.
func LevelUpGuildFast(accountID : int, charID : int) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return {"ok": false, "reason": "no_guild"}
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return {"ok": false, "reason": "not_officer"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("guild", "guild_id = %d" % guildID, ["level"])
		if rows.is_empty():
			return false
		var level : int = int(rows[0]["level"])
		if level < 1 or level >= GuildMaxLevel:
			result["reason"] = "max_level"
			return false
		var cost : int = GuildLevelCostGems[level] * 2
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < cost:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - cost):
			return false
		if not sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"level" = level + 1}):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGems, -cost, gems - cost, "guild_level_fast"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["cost"] = cost
		result["level"] = level + 1
		return true):
		pass
	settleMutex.unlock()
	return result

# Expansão do vault (leader/officer): +1 stack distinta por 200 gems (máx 20).
func BuyVaultSlots(accountID : int, charID : int) -> Dictionary:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return {"ok": false, "reason": "no_guild"}
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return {"ok": false, "reason": "not_officer"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("guild", "guild_id = %d" % guildID, ["vault_slots_purchased"])
		if rows.is_empty():
			return false
		var bought : int = int(rows[0].get("vault_slots_purchased", 0))
		if bought >= GUILD_VAULT_SLOTS_MAX:
			result["reason"] = "slots_cap"
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < GUILD_VAULT_SLOT_COST:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - GUILD_VAULT_SLOT_COST):
			return false
		if not sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"vault_slots_purchased" = bought + 1}):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGems, -GUILD_VAULT_SLOT_COST, gems - GUILD_VAULT_SLOT_COST, "guild_vault_slots"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["slots"] = bought + 1
		return true):
		pass
	settleMutex.unlock()
	return result

# ------------------------------------------------------------------ E2: seasons (corridas power + spend; premiação automática no ciclo de vida — fecha e liquida)

func ActiveSeason() -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT season_id, starts_at, ends_at, rules_frozen, status FROM season WHERE status = 'active' ORDER BY season_id DESC LIMIT 1;", [])
	return {} if rows.is_empty() else rows[0]

# SOM-IDLE beta fechado (T5): Seasons é pós-lançamento — criação e ciclo de
# vida ficam TRAVADOS por padrão (qualquer chamada normal, GM ou job, vira
# no-op com aviso). Testes habilitam explicitamente via env
# SHAMBLETA_ENABLE_SEASONS=1 (run_idle_tests.gd). Remover a trava só na
# ativação, após a auditoria do ciclo ACTIVE→CLOSING→CLOSED→SETTLED
# (som-idle-docs/SEASON_ACTIVATION_NOTE.md).
const SeasonsBetaLock : bool = true

static func SeasonsEnabled() -> bool:
	if not SeasonsBetaLock:
		return true
	return OS.get_environment("SHAMBLETA_ENABLE_SEASONS") == "1"

func CreateSeason(days : int, rules : String = "{}") -> int:
	if not SeasonsEnabled():
		push_warning("SOM-IDLE Seasons: criação bloqueada no beta (T5)")
		return -1
	if days <= 0 or not ActiveSeason().is_empty():
		return 0
	var out : Dictionary = {"id" = 0}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var now : int = SQLCommons.Timestamp()
		if not sql.db.query_with_bindings("INSERT INTO season (starts_at, ends_at, rules_frozen, status) VALUES (?, ?, ?, 'active');", [now, now + days * 86400, rules]):
			return false
		out["id"] = sql.LastInsertRowIDRaw()
		return int(out["id"]) > 0):
		pass
	settleMutex.unlock()
	return int(out["id"])

func CloseSeason(seasonID : int) -> bool:
	return Launcher.SQL.ExecuteBindings("UPDATE season SET status = 'closed' WHERE season_id = ? AND status = 'active';", [seasonID])

func SnapshotSeasonPower(seasonID : int, limit : int = 100) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT char_id, power_score FROM character WHERE power_score > 0 ORDER BY power_score DESC LIMIT ?;", [limit])
	var n : int = 0
	for row in rows:
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'power', ?, ?);", [seasonID, int(row["char_id"]), int(row["power_score"])]):
			n += 1
	return n

func SnapshotSeasonSpend(seasonID : int) -> int:
	var season : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT starts_at FROM season WHERE season_id = ?;", [seasonID])
	if season.is_empty():
		return 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, SUM(-amount) AS spent FROM ledger_transaction WHERE kind = 'gems' AND amount < 0 AND created_at >= ? GROUP BY account_id;", [int(season[0]["starts_at"])])
	var n : int = 0
	for row in rows:
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'spend', ?, ?);", [seasonID, int(row["account_id"]), int(row["spent"])]):
			n += 1
	return n

# Fase F: snapshot das 2 novas corridas (idempotente por REPLACE).
func SnapshotSeasonBossKills(seasonID : int) -> int:
	var n : int = 0
	for row in Launcher.SQL.QueryBindings("SELECT char_id, bosses_beaten FROM character WHERE bosses_beaten > 0;", []):
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'boss_kills', ?, ?);", [seasonID, int(row["char_id"]), int(row["bosses_beaten"])]):
			n += 1
	return n

func SnapshotSeasonGuildPoints(seasonID : int) -> int:
	var n : int = 0
	for row in Launcher.SQL.QueryBindings("SELECT guild_id, points FROM guild WHERE points > 0;", []):
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'guild_points', ?, ?);", [seasonID, int(row["guild_id"]), int(row["points"])]):
			n += 1
	return n

func GetSeasonBoard(seasonID : int, kind : String, limit : int = 20) -> Array[Dictionary]:
	if not kind in SEASON_KINDS:
		return []
	return Launcher.SQL.QueryBindings("SELECT subject_id, value FROM season_score WHERE season_id = ? AND kind = ? ORDER BY value DESC LIMIT ?;", [seasonID, kind, limit])

# SOM-IDLE Fase F: 4 corridas (ARCHITECTURE §4.6) — power/spend + boss_kills
# (por char) + guild_points (por guild, do hook de settle/vitória).
const SEASON_KINDS : Array[String] = ["power", "spend", "boss_kills", "guild_points"]

# SOM-IDLE (3b): premiação AUTOMÁTICA — substitui o payout manual/GM da v0.
# Tabela de prêmios em gems por colocação (top-N) para cada corrida (power/spend).
const SeasonPrizeGems : Array[int] = [3000, 1800, 1200, 700, 500, 400, 300, 300, 200, 200]

# Rodado no job diário (e chamável a qualquer momento): fecha temporadas vencidas
# e liquida as fechadas. Idempotente — uma temporada só paga uma vez.
func TickSeasonLifecycle() -> Dictionary:
	if not SeasonsEnabled():
		return {"closed" = 0, "settled" = 0, "disabled" = true}
	var closed : int = 0
	var settled : int = 0
	var now : int = SQLCommons.Timestamp()
	for row : Dictionary in Launcher.SQL.QueryBindings("SELECT season_id FROM season WHERE status = 'active' AND ends_at <= ?;", [now]):
		if CloseSeason(int(row["season_id"])):
			closed += 1
	for row : Dictionary in Launcher.SQL.QueryBindings("SELECT season_id FROM season WHERE status = 'closed';", []):
		var res : Dictionary = SettleSeasonPrizes(int(row["season_id"]))
		if bool(res.get("ok", false)):
			settled += 1
	return {"closed" = closed, "settled" = settled}

# Liquida os prêmios de uma temporada fechada: congela o placar final, concede
# gems aos top-N por corrida e marca 'settled'. Gems (não-casháveis) via AddGems
# com reason 'season_prize:<id>:<kind>:<subject>' — a prova no ledger garante
# idempotência por vencedor, mesmo se uma execução anterior falhou no meio.
func SettleSeasonPrizes(seasonID : int) -> Dictionary:
	var season : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT status FROM season WHERE season_id = ?;", [seasonID])
	if season.is_empty():
		return {"ok" = false, "reason" = "not_found", "awarded" = 0}
	var status : String = str(season[0]["status"])
	if status == "settled":
		return {"ok" = true, "reason" = "already_settled", "awarded" = 0}
	if status != "closed":
		return {"ok" = false, "reason" = "not_closed", "awarded" = 0}

	SnapshotSeasonPower(seasonID)
	SnapshotSeasonSpend(seasonID)
	SnapshotSeasonBossKills(seasonID)
	SnapshotSeasonGuildPoints(seasonID)
	var awarded : int = 0
	for kind in ["power", "spend", "boss_kills"]:
		var board : Array[Dictionary] = GetSeasonBoard(seasonID, kind, SeasonPrizeGems.size())
		for rank : int in board.size():
			var prize : int = SeasonPrizeGems[rank]
			if prize <= 0:
				continue
			var subject : int = int(board[rank]["subject_id"])
			var accountID : int = _AccountIDForCharacterRaw(subject) if kind == "power" or kind == "boss_kills" else subject
			if accountID <= 0:
				continue
			var reason : String = "season_prize:%d:%s:%d" % [seasonID, kind, subject]
			if not Launcher.SQL.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, reason]).is_empty():
				continue
			if AddGems(accountID, prize, reason):
				awarded += 1
	# Corrida de guilds: top-3 guilds premiam o líder (custodiante) em gems.
	var gboard : Array[Dictionary] = GetSeasonBoard(seasonID, "guild_points", GUILD_PRIZE_GEMS.size())
	for rank : int in gboard.size():
		var gprize : int = GUILD_PRIZE_GEMS[rank]
		if gprize <= 0:
			continue
		var gid : int = int(gboard[rank]["subject_id"])
		var lead : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT leader_account FROM guild WHERE guild_id = ?;", [gid])
		if lead.is_empty():
			continue
		var leader : int = int(lead[0].get("leader_account", 0))
		var greason : String = "season_prize:%d:guild_points:%d" % [seasonID, gid]
		if not Launcher.SQL.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [leader, greason]).is_empty():
			continue
		if AddGems(leader, gprize, greason):
			awarded += 1
	Launcher.SQL.ExecuteBindings("UPDATE season SET status = 'settled' WHERE season_id = ? AND status = 'closed';", [seasonID])
	if awarded > 0:
		Util.PrintLog("Economy", "Season %d settled automatically: %d prize grants" % [seasonID, awarded])
	var auto : Dictionary = _AutoClaimPass(seasonID)
	if int(auto.get("claimed", 0)) > 0:
		Util.PrintLog("Economy", "Season %d pass auto-claim: %d rewards" % [seasonID, int(auto.get("claimed", 0))])
	return {"ok" = true, "reason" = "settled", "awarded" = awarded}

# ------------------------------------------------------------------ Fase E: rewarded ads (MONETIZATION §2.5)
#
# Abstração + stubs: o client (AdProvider) devolve um token que o servidor
# valida por formato + dia; o SDK real pluga sem mudar mais nada. Views vivem
# em telemetry_event (kind 'ad_view', meta {"placement"}) — sem migração, sem
# moeda nova, sem caminho p/ essência/favores (§0.1). Caps: 1 baú/dia, 2
# chaves/dia, reroll-ad divide o contador pago (3/dia), afk2x vale 1 liquidação
# (armado até o próximo settle), teto global 6/dia (anti-fadiga). VIP dobra o
# bônus em quantidade (2×→4×, +1→+2 baús/chaves); reroll é acesso, não volume.
const AD_AFK2X : String = "afk2x"
const AD_CHEST : String = "chest"
const AD_REROLL : String = "reroll"
const AD_BOSSKEY : String = "bosskey"
const AD_PLACEMENTS : Array[String] = ["afk2x", "chest", "reroll", "bosskey"]
const AD_PLACEMENT_CAPS : Dictionary = {"chest": 1, "bosskey": 2}
# SOM-IDLE beta fechado (T7): stub é EXPLÍCITO e próprio do beta — produção
# com SDK real exigirá formato próprio (nunca "stub:*"). O stub é mintável
# pelo client por construção; o teto de abuso são os caps server-side
# (6/dia global + caps por placement), sem dinheiro envolvido no beta.
const AdStubEnabled : bool = true
const AD_DAILY_CAP : int = 6

func _AdDayStart() -> int:
	return PassDayStartTS(ShopDay(SQLCommons.Timestamp()))

func AdViewsToday(accountID : int, placement : String = "") -> int:
	if placement.is_empty():
		return int(Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'ad_view' AND account_id = ? AND created_at >= ?;", [accountID, _AdDayStart()])[0]["n"])
	return int(Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'ad_view' AND account_id = ? AND created_at >= ? AND json_extract(meta, '$.placement') = ?;", [accountID, _AdDayStart(), placement])[0]["n"])

func _ValidAdToken(token : String, placement : String) -> bool:
	# Stub: "stub:<placement>:<dia UTC-3>" — aceito SOMENTE com AdStubEnabled
	# (beta). Produção exige callback assinado do SDK (fail-closed aqui:
	# formato errado nunca credita).
	if not AdStubEnabled:
		return false
	var parts : PackedStringArray = token.split(":")
	return parts.size() == 3 and parts[0] == "stub" and parts[1] == placement and parts[2] == str(ShopDay(SQLCommons.Timestamp()))

func _AdAllowed(accountID : int, placement : String) -> Dictionary:
	if AdViewsToday(accountID) >= AD_DAILY_CAP:
		return {"ok": false, "reason": "ad_cap"}
	if AD_PLACEMENT_CAPS.has(placement) and AdViewsToday(accountID, placement) >= int(AD_PLACEMENT_CAPS[placement]):
		return {"ok": false, "reason": "placement_cap"}
	return {"ok": true, "reason": "ok"}

func _RecordAdView(accountID : int, charID : int, placement : String) -> void:
	Launcher.Telemetry.Record("ad_view", accountID, charID, 0, JSON.stringify({"placement": placement}))
	Launcher.Telemetry.Flush()

# Registra uma visualização (o armamento do afk2x É a view: vale até o
# próximo settle, 1×/liquidação por construção).
func WatchAd(accountID : int, charID : int, placement : String, token : String) -> Dictionary:
	if not placement in AD_PLACEMENTS:
		return {"ok": false, "reason": "unknown_placement"}
	if not _ValidAdToken(token, placement):
		return {"ok": false, "reason": "bad_token"}
	var gate : Dictionary = _AdAllowed(accountID, placement)
	if not bool(gate.get("ok", false)):
		return gate
	_RecordAdView(accountID, charID, placement)
	return {"ok": true, "reason": "ok"}

# Armado p/ a liquidação pendente: view posterior ao anchor (não acumula).
func IsAfkAdArmed(accountID : int, charID : int, anchorTs : int) -> bool:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'ad_view' AND account_id = ? AND char_id = ? AND created_at > ? AND json_extract(meta, '$.placement') = ?;", [accountID, charID, anchorTs, AD_AFK2X])
	return not rows.is_empty() and int(rows[0]["n"]) > 0

# Baú bônus (VIP dobra a quantidade).
func ClaimAdChest(accountID : int, charID : int, token : String) -> Dictionary:
	var w : Dictionary = WatchAd(accountID, charID, AD_CHEST, token)
	if not bool(w.get("ok", false)):
		return w
	var n : int = 2 if Launcher.SQL.GetVIPUntil(accountID) > SQLCommons.Timestamp() else 1
	settleMutex.lock()
	var ok : bool = Launcher.SQL.Transaction(func() -> bool:
		for i in n:
			if not Launcher.SQL.AddChestInstance(charID, 0, "ad"):
				return false
		return true)
	settleMutex.unlock()
	if not ok:
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok", "chests": n}

# Reroll via ad: mesma rotação e contador do pago (3/dia somados), sem gems.
func RerollDailyShopAd(accountID : int, token : String) -> Dictionary:
	if not _ValidAdToken(token, AD_REROLL):
		return {"ok": false, "reason": "bad_token"}
	var gate : Dictionary = _AdAllowed(accountID, AD_REROLL)
	if not bool(gate.get("ok", false)):
		return gate
	var day : int = ShopDay(SQLCommons.Timestamp())
	var row : Dictionary = _DailyRow(accountID, day)
	if int(row["rerolls_used"]) >= DAILY_REROLLS_MAX:
		return {"ok": false, "reason": "reroll_cap"}
	_RecordAdView(accountID, 0, AD_REROLL)
	return _DoReroll(accountID, day, row)

# Chave de boss extra (VIP dobra a quantidade).
func ClaimAdBossKey(accountID : int, charID : int, token : String) -> Dictionary:
	var w : Dictionary = WatchAd(accountID, charID, AD_BOSSKEY, token)
	if not bool(w.get("ok", false)):
		return w
	var n : int = 2 if Launcher.SQL.GetVIPUntil(accountID) > SQLCommons.Timestamp() else 1
	var keys : int = GrantBossKey(charID, n, "ad_reward")
	if keys < 0:
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok", "keys": keys}

# ------------------------------------------------------------------ Fase D: cosméticos / entitlements (MONETIZATION §2.4 + §2.7)
#
# Camada de dados completa; visuais (sprites/partículas) são follow-up de arte
# — o catálogo carrega só identidade (tipo + rótulo). Slots = tipos, um
# equipado por slot. Preço 0 = não vendável avulso (passe, marcos, backfill).
# req_rebirths: só compra quem já alcançou o marco jogando (vitrine decora o
# número ganho, nunca vende o número).
const COSMETIC_CATALOG : Dictionary = {
	# Passe S1 (fonte: trilha; volta na Loja do Legado após ≥2 temporadas —
	# live-ops futuro, por isso price 0 aqui).
	"skin_manto": {"type": "formation_skin", "label": "Manto do Descobridor", "price": 0, "req_rebirths": 0},
	"fx_faisca": {"type": "drop_fx", "label": "Faísca de Mana", "price": 0, "req_rebirths": 0},
	"frame_sazonal": {"type": "frame", "label": "Moldura Sazonal S1", "price": 0, "req_rebirths": 0},
	"skin_mascara": {"type": "formation_skin", "label": "Máscara Ritual de Tulimshar", "price": 0, "req_rebirths": 0},
	"emote_guilda": {"type": "emote", "label": "Sinal da Guilda", "price": 0, "req_rebirths": 0},
	"emote_tocha": {"type": "emote", "label": "Tocha do Explorador", "price": 0, "req_rebirths": 0},
	"title_redescobridor": {"type": "title", "label": "Redescobridor", "price": 0, "req_rebirths": 0},
	"title_veterano": {"type": "title", "label": "Veterano da Redescoberta", "price": 0, "req_rebirths": 0},
	"banner_guilda": {"type": "guild_banner", "label": "Estandarte da Redescoberta", "price": 0, "req_rebirths": 0},
	# Vitrine do renascimento (MONETIZATION §2.7): básico grátis no 1º ciclo,
	# estilo à venda em gems — sempre gems/passe, nunca essência (§0.1).
	"rebirth_t1": {"type": "title", "label": "Renascido I", "price": 0, "req_rebirths": 1},
	"rebirth_f1": {"type": "frame", "label": "Moldura do Primeiro Ciclo", "price": 0, "req_rebirths": 1},
	"rebirth_t3": {"type": "title", "label": "Renascido III", "price": 150, "req_rebirths": 3},
	"rebirth_f5": {"type": "frame", "label": "Moldura do Quinto Ciclo", "price": 300, "req_rebirths": 5},
	"rebirth_f10": {"type": "frame", "label": "Moldura do Décimo Ciclo", "price": 600, "req_rebirths": 10},
	"rebirth_fx": {"type": "rebirth_fx", "label": "Partículas do Renascimento", "price": 250, "req_rebirths": 1},
	# Apoio (backfill de compras Fase A; títulos prometidos nos payloads).
	"title_recruta": {"type": "title", "label": "Recruta", "price": 0, "req_rebirths": 0},
	"title_fundador": {"type": "title", "label": "Fundador", "price": 0, "req_rebirths": 0},
	# Fase F: campeão da copa semanal + apoiador (doação via companion).
	"title_campeao": {"type": "title", "label": "Campeão", "price": 0, "req_rebirths": 0},
	"title_apoiador": {"type": "title", "label": "Apoiador", "price": 0, "req_rebirths": 0},
	# Passe Deluxe (BATTLE_PASS_S1 §4): exclusivo vitalício, nunca retorna nem
	# na Loja do Legado.
	"emote_coroa": {"type": "emote", "label": "Coroa do Sol", "price": 0, "req_rebirths": 0},
}

static func CosmeticLabel(cosmeticID : String) -> String:
	if COSMETIC_CATALOG.has(cosmeticID):
		return str((COSMETIC_CATALOG[cosmeticID] as Dictionary).get("label", cosmeticID))
	return ""

func HasCosmetic(accountID : int, cosmeticID : String) -> bool:
	return not Launcher.SQL.QueryBindings("SELECT id FROM cosmetic_grant WHERE account_id = ? AND cosmetic_id = ? LIMIT 1;", [accountID, cosmeticID]).is_empty()

func GrantCosmetic(accountID : int, cosmeticID : String, source : String) -> bool:
	if not COSMETIC_CATALOG.has(cosmeticID):
		return false
	return Launcher.SQL.ExecuteBindings("INSERT OR IGNORE INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) SELECT ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM cosmetic_grant WHERE account_id = ? AND cosmetic_id = ?);", [accountID, cosmeticID, source, SQLCommons.Timestamp(), accountID, cosmeticID])

func _MaxRebirths(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT MAX(rebirths) AS m FROM character WHERE account_id = ?;", [accountID])
	if rows.is_empty() or rows[0].get("m", null) == null:
		return 0
	return int(rows[0]["m"])

# Backfill preguiçoso (sem boot-hook): quem comprou starter/founder na Fase A
# recebe o título prometido no payload asim que o estado é lido.
func _BackfillSupportTitles(accountID : int) -> void:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT DISTINCT payload FROM grant_queue WHERE account_id = ? AND status = 'processed';", [accountID])
	var starter : bool = false
	var founder : bool = false
	for r in rows:
		var p : Variant = JSON.parse_string(str(r.get("payload", "")))
		if p is Dictionary:
			var sku : String = str((p as Dictionary).get("sku", ""))
			if sku == "starter.pack":
				starter = true
			if sku == "founder.pack":
				founder = true
	if starter and not HasCosmetic(accountID, "title_recruta"):
		GrantCosmetic(accountID, "title_recruta", "starter.pack")
	if founder and not HasCosmetic(accountID, "title_fundador"):
		GrantCosmetic(accountID, "title_fundador", "founder.pack")

func GetCosmetics(accountID : int) -> Dictionary:
	_BackfillSupportTitles(accountID)
	var owned : Array = []
	for r in Launcher.SQL.QueryBindings("SELECT cosmetic_id, source FROM cosmetic_grant WHERE account_id = ? ORDER BY id;", [accountID]):
		owned.append({"id": str(r.get("cosmetic_id", "")), "source": str(r.get("source", ""))})
	var equipped : Dictionary = {}
	for r in Launcher.SQL.QueryBindings("SELECT slot, cosmetic_id FROM cosmetic_equip WHERE account_id = ?;", [accountID]):
		equipped[str(r.get("slot", ""))] = str(r.get("cosmetic_id", ""))
	var catalog : Array = []
	for cid in COSMETIC_CATALOG:
		var e : Dictionary = COSMETIC_CATALOG[cid]
		catalog.append({"id": cid, "type": str(e.get("type", "")), "label": str(e.get("label", "")),
			"price": int(e.get("price", 0)), "req_rebirths": int(e.get("req_rebirths", 0))})
	return {"ok": true, "catalog": catalog, "owned": owned, "equipped": equipped,
		"rebirths": _MaxRebirths(accountID)}

func EquipCosmetic(accountID : int, cosmeticID : String) -> Dictionary:
	if not COSMETIC_CATALOG.has(cosmeticID):
		return {"ok": false, "reason": "unknown_cosmetic"}
	if not HasCosmetic(accountID, cosmeticID):
		return {"ok": false, "reason": "not_owned"}
	var slot : String = str((COSMETIC_CATALOG[cosmeticID] as Dictionary).get("type", ""))
	if not Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO cosmetic_equip (account_id, slot, cosmetic_id) VALUES (?, ?, ?);", [accountID, slot, cosmeticID]):
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok", "slot": slot}

func UnequipCosmetic(accountID : int, slot : String) -> Dictionary:
	if not Launcher.SQL.ExecuteBindings("DELETE FROM cosmetic_equip WHERE account_id = ? AND slot = ?;", [accountID, slot]):
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "ok"}

# Compra avulsa em gems (vitrine): exige posse do marco + saldo, na MESMA
# transação (débito + grant). Cosméticos price 0 nunca vendem aqui.
func BuyCosmetic(accountID : int, charID : int, cosmeticID : String) -> Dictionary:
	if not COSMETIC_CATALOG.has(cosmeticID):
		return {"ok": false, "reason": "unknown_cosmetic"}
	var entry : Dictionary = COSMETIC_CATALOG[cosmeticID]
	var price : int = int(entry.get("price", 0))
	if price <= 0:
		return {"ok": false, "reason": "not_for_sale"}
	if _MaxRebirths(accountID) < int(entry.get("req_rebirths", 0)):
		return {"ok": false, "reason": "milestone_locked"}
	if HasCosmetic(accountID, cosmeticID):
		return {"ok": false, "reason": "already_owned"}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		if balance < price:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, balance - price):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGems, -price, balance - price, "cosmetic:" + cosmeticID):
			return false
		if not sql.ExecuteBindings("INSERT INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, ?, ?, ?);", [accountID, cosmeticID, "shop", SQLCommons.Timestamp()]):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["cost"] = price
		result["balance"] = balance - price
		return true):
		pass
	settleMutex.unlock()
	return result

# Vitrine do renascimento no ato (pós-commit): 1º ciclo concede o básico
# grátis (existir não se vende); estilo continua à venda na loja.
func _RebirthVitrine(accountID : int, rebirths : int) -> void:
	if rebirths == 1:
		GrantCosmetic(accountID, "rebirth_t1", "rebirth:1")
		GrantCosmetic(accountID, "rebirth_f1", "rebirth:1")

func EquippedTitleLabel(accountID : int) -> String:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT cosmetic_id FROM cosmetic_equip WHERE account_id = ? AND slot = 'title';", [accountID])
	if rows.is_empty():
		return ""
	return CosmeticLabel(str(rows[0].get("cosmetic_id", "")))

# ------------------------------------------------------------------ Fase C: passe de temporada (BATTLE_PASS_S1.md)
#
# PT (Pontos de Temporada — não confundir com XP do jogo) por conta/temporada:
# diárias 40 + semanais 120 + marcos 50, curva L1–10:100 · L11–20:120 ·
# L21–30/31–40:140 (máx 5000 PT = L40). VIP +10%, 2× nos últimos 3 dias.
# Missões 100% server-side a partir de ledger/telemetry (nada client-side).
# Desvios do design documentados onde ocorrem (3 substituições de missão por
# falta de sistema-fonte, baús sem raridade, 4 bosses em vez de 8 zonas).
const PASS_DAILY_PT : int = 40
const PASS_WEEKLY_PT : int = 120
const PASS_MILESTONE_PT : int = 50
const PASS_SKIP_COST : int = 50
const PASS_SKIP_MAX : int = 10
const PASS_MAX_LEVEL : int = 40
const PASS_BONUS_START : int = 31
const PASS_BONUS_GEMS : int = 20
const PASS_DOUBLEXP_LAST_DAYS : int = 3
# Trilha grátis (BATTLE_PASS_S1 §3). Baús não têm raridade no jogo (pool por
# zona no open): "rara" = 2 baús, "épica" = 3.
const PASS_FREE : Dictionary = {
	3: {"gems": 10}, 5: {"chests": 1}, 8: {"gems": 10},
	10: {"cosmetics": ["emote_tocha"]}, 13: {"gems": 15}, 16: {"chests": 1},
	20: {"gems": 15}, 24: {"chests": 2}, 27: {"gems": 20},
	30: {"gems": 30, "cosmetics": ["title_redescobridor"]},
}
# Trilha premium (BATTLE_PASS_S1 §4). Cosméticos viram cosmetic_grant (uso
# pleno na Fase D); trial VIP entra como tier 1.
const PASS_PREMIUM : Dictionary = {
	1: {"cosmetics": ["skin_manto"]}, 3: {"gems": 25}, 5: {"vip_days": 3},
	6: {"gems": 25}, 8: {"cosmetics": ["fx_faisca"]}, 9: {"gems": 25},
	11: {"chests": 2}, 12: {"gems": 25}, 14: {"cosmetics": ["frame_sazonal"]},
	15: {"gems": 50}, 17: {"cosmetics": ["skin_mascara"]}, 18: {"gems": 25},
	21: {"chests": 3}, 22: {"gems": 25}, 24: {"cosmetics": ["emote_guilda"]},
	26: {"gems": 25}, 28: {"gems": 50},
	30: {"gems": 100, "cosmetics": ["title_veterano", "banner_guilda"]},
}
# Diárias (3/dia, mesmas p/ todos, seed do dia). SUB = substituição por falta
# de sistema-fonte: equip (sem evento server-side) → levelup; 25 mobs (sem
# kill counter) → 2h de settle; reforja (sistema inexistente) → listar no AH;
# rewarded ad (Fase E) → abrir a loja.
const PASS_DAILY_POOL : Array = [
	{"id": "d_settle2", "label": "Collect AFK 2×", "goal": 2},
	{"id": "d_chest1", "label": "Open 1 chest", "goal": 1},
	{"id": "d_level1", "label": "Gain 1 level (SUB equip)", "goal": 1},
	{"id": "d_farm2h", "label": "Settle 2h (SUB kills)", "goal": 2},
	{"id": "d_vault1", "label": "Deposit 1 item in guild vault", "goal": 1},
	{"id": "d_trade1", "label": "Complete 1 trade", "goal": 1},
	{"id": "d_ahlist1", "label": "List 1 item on AH (SUB reforge)", "goal": 1},
	{"id": "d_shop1", "label": "Open the shop (SUB ad)", "goal": 1},
]
# Semanais (3/semana). W3 conta qualquer sink de gems; W5 aceita level-up OU
# 3 depósitos (sem vault de gold no jogo).
const PASS_WEEKLY_POOL : Array = [
	{"id": "w_boss1", "label": "Defeat 1 zone boss", "goal": 1},
	{"id": "w_eff3", "label": "3 sessions ≥ 90% efficiency", "goal": 3},
	{"id": "w_spend100", "label": "Spend 100 gems", "goal": 100},
	{"id": "w_dailies15", "label": "Claim 15 dailies", "goal": 15},
	{"id": "w_guild1", "label": "Guild level-up or 3 vault deposits", "goal": 1},
	{"id": "w_farm8h", "label": "Settle 8h", "goal": 8},
]

# Curva cumulativa: L1–10:100 · L11–20:120 · L21–30:140 · L31–40:140.
static func PassThresholds() -> Array:
	var cum : Array = []
	var total : int = 0
	for lvl in range(1, PASS_MAX_LEVEL + 1):
		var step : int = 100 if lvl <= 10 else (120 if lvl <= 20 else 140)
		total += step
		cum.append(total)
	return cum

static func PassLevelForPT(pt : int) -> int:
	var cum : Array = PassThresholds()
	var level : int = 0
	for t in cum:
		if pt >= int(t):
			level += 1
		else:
			break
	return level

# Linha da conta/temporada (cria zerada). Leitura crua p/ uso em transações.
func _PassStateRaw(accountID : int, seasonID : int) -> Dictionary:
	var sql : SQLService = Launcher.SQL
	sql.ExecuteBindings("INSERT OR IGNORE INTO season_account_state (account_id, season_id) VALUES (?, ?);", [accountID, seasonID])
	var rows : Array[Dictionary] = sql.QueryBindings("SELECT pt, premium, claimed_free, claimed_premium, skips_used FROM season_account_state WHERE account_id = ? AND season_id = ?;", [accountID, seasonID])
	if rows.is_empty():
		return {"pt": 0, "premium": 0, "claimed_free": [], "claimed_premium": [], "skips_used": 0}
	var r : Dictionary = rows[0]
	var cf : Variant = JSON.parse_string(str(r.get("claimed_free", "[]")))
	var cp : Variant = JSON.parse_string(str(r.get("claimed_premium", "[]")))
	# Normaliza p/ int: JSON devolve float e `lvl in lista` não bate int×float.
	var claimedF : Array = []
	for x in (cf if cf is Array else []):
		claimedF.append(int(x))
	var claimedP : Array = []
	for x in (cp if cp is Array else []):
		claimedP.append(int(x))
	return {"pt": int(r.get("pt", 0)), "premium": int(r.get("premium", 0)),
		"claimed_free": claimedF, "claimed_premium": claimedP,
		"skips_used": int(r.get("skips_used", 0))}

func _PassDoubleXP(season : Dictionary, now : int) -> bool:
	var startsAt : int = int(season.get("starts_at", 0))
	var endsAt : int = int(season.get("ends_at", 0))
	if endsAt <= now or endsAt - startsAt < 7 * 86400:
		return false
	return endsAt - now <= PASS_DOUBLEXP_LAST_DAYS * 86400

# PT com multiplicadores (VIP +10%, 2× fim de temporada), teto L40, ledger.
func _AwardPT(accountID : int, seasonID : int, base : int, reason : String) -> int:
	var sql : SQLService = Launcher.SQL
	var now : int = SQLCommons.Timestamp()
	var season : Dictionary = ActiveSeason()
	if season.is_empty() or int(season.get("season_id", 0)) != seasonID:
		return 0
	var pts : int = base
	if sql.GetVIPUntil(accountID) > now:
		pts = roundi(float(pts) * 1.1)
	if _PassDoubleXP(season, now):
		pts *= 2
	var st : Dictionary = _PassStateRaw(accountID, seasonID)
	var maxPT : int = int((PassThresholds() as Array).back())
	var newPT : int = mini(int(st.get("pt", 0)) + pts, maxPT)
	sql.ExecuteBindings("UPDATE season_account_state SET pt = ? WHERE account_id = ? AND season_id = ?;", [newPT, accountID, seasonID])
	_LedgerAppendLocked(accountID, 0, "pass_pt", pts, newPT, "pass_pt:" + reason)
	return pts

# Rotação do dia/semana (pura, mesma p/ todos): 3 consecutivas do pool.
static func PassDailies(day : int) -> Array:
	var out : Array = []
	var n : int = PASS_DAILY_POOL.size()
	var start : int = (day * 5) % n
	for k in 3:
		out.append((PASS_DAILY_POOL[(start + k) % n] as Dictionary).duplicate())
	return out

static func PassWeeklies(weekIdx : int) -> Array:
	var out : Array = []
	var n : int = PASS_WEEKLY_POOL.size()
	var start : int = (weekIdx * 3) % n
	for k in 3:
		out.append((PASS_WEEKLY_POOL[(start + k) % n] as Dictionary).duplicate())
	return out

static func PassWeekIndex(season : Dictionary, now : int) -> int:
	return maxi(0, (ShopDay(now) - ShopDay(int(season.get("starts_at", now)))) / 7)

static func PassDayStartTS(day : int) -> int:
	return day * 86400 + SHOP_DAY_UTC_OFFSET

func _PassChars(accountID : int) -> Array:
	var ids : Array = []
	for row in Launcher.SQL.QueryBindings("SELECT char_id FROM character WHERE account_id = ? ORDER BY char_id;", [accountID]):
		ids.append(int(row["char_id"]))
	return ids

# Progresso de uma missão a partir de ledger/telemetry (nada client-side).
func _MissionProgress(accountID : int, missionID : String, periodStart : int, seasonID : int) -> int:
	var sql : SQLService = Launcher.SQL
	match missionID:
		"d_settle2":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'settle' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_chest1":
			# Ledger de open usa reason "chest:<id>|<hash>|<seed>:uid<n>"
			# (o "chest_open" vai p/ o lote, não p/ o ledger).
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND kind = 'item' AND reason LIKE 'chest:%' AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_level1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'levelup' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_farm2h":
			var r : Array[Dictionary] = sql.QueryBindings("SELECT COALESCE(SUM(CAST(json_extract(meta, '$.hours') AS REAL)), 0) AS h FROM telemetry_event WHERE kind = 'settle' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])
			return int(floor(float(r[0]["h"])))
		"d_vault1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE 'vault_deposit:%' AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_trade1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND (reason LIKE 'trade_out:%' OR reason LIKE 'ah_buy:%') AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_ahlist1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE 'ah_list:%' AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"d_shop1":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'shop_visit' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])[0]["n"])
		"w_boss1":
			var chars : Array = _PassChars(accountID)
			if chars.is_empty():
				return 0
			var placeholders : String = ",".join(chars.map(func(_c : int) -> String: return "?"))
			var query : String = "SELECT COUNT(*) AS n FROM chest_instance WHERE origin = 'boss' AND created_at >= ? AND char_id IN (%s);" % placeholders
			var bindings : Array = [periodStart]
			bindings.append_array(chars)
			return int(sql.QueryBindings(query, bindings)[0]["n"])
		"w_eff3":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = 'settle' AND account_id = ? AND created_at >= ? AND CAST(json_extract(meta, '$.eff') AS REAL) >= 0.9;", [accountID, periodStart])[0]["n"])
		"w_spend100":
			var s : Array[Dictionary] = sql.QueryBindings("SELECT COALESCE(SUM(-amount), 0) AS t FROM ledger_transaction WHERE account_id = ? AND kind = 'gems' AND amount < 0 AND created_at >= ?;", [accountID, periodStart])
			return int(s[0]["t"])
		"w_dailies15":
			return int(sql.QueryBindings("SELECT COUNT(*) AS n FROM season_mission_state WHERE account_id = ? AND season_id = ? AND mission_id LIKE 'd_%' AND claimed = 1 AND claimed_at >= ?;", [accountID, seasonID, periodStart])[0]["n"])
		"w_guild1":
			var lv : int = int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason = 'guild_level' AND created_at >= ?;", [accountID, periodStart])[0]["n"])
			if lv > 0:
				return 1
			return 1 if int(sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE 'vault_deposit:%' AND created_at >= ?;", [accountID, periodStart])[0]["n"]) >= 3 else 0
		"w_farm8h":
			var h : Array[Dictionary] = sql.QueryBindings("SELECT COALESCE(SUM(CAST(json_extract(meta, '$.hours') AS REAL)), 0) AS t FROM telemetry_event WHERE kind = 'settle' AND account_id = ? AND created_at >= ?;", [accountID, periodStart])
			return int(floor(float(h[0]["t"])))
	return 0

func _MissionState(accountID : int, seasonID : int, missionID : String, periodID : String, goal : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT progress, claimed FROM season_mission_state WHERE account_id = ? AND season_id = ? AND mission_id = ? AND period_id = ?;", [accountID, seasonID, missionID, periodID])
	if rows.is_empty():
		return {"progress": 0, "claimed": 0, "goal": goal}
	return {"progress": int(rows[0].get("progress", 0)), "claimed": int(rows[0].get("claimed", 0)), "goal": goal}

func _SeasonMissions(accountID : int, season : Dictionary) -> Dictionary:
	var sid : int = int(season.get("season_id", 0))
	var now : int = SQLCommons.Timestamp()
	var day : int = ShopDay(now)
	var weekIdx : int = PassWeekIndex(season, now)
	var dayStart : int = PassDayStartTS(day)
	var weekStart : int = PassDayStartTS(ShopDay(int(season.get("starts_at", now))) + weekIdx * 7)
	var dailies : Array = []
	for def in PassDailies(day):
		var mid : String = str(def["id"])
		var mst : Dictionary = _MissionState(accountID, sid, mid, "d%d" % day, int(def["goal"]))
		dailies.append({"id": mid, "label": str(def["label"]), "goal": int(def["goal"]),
			"progress": mini(_MissionProgress(accountID, mid, dayStart, sid), int(def["goal"])),
			"claimed": int(mst["claimed"]), "pt": PASS_DAILY_PT})
	var weeklies : Array = []
	for def in PassWeeklies(weekIdx):
		var mid : String = str(def["id"])
		var mst : Dictionary = _MissionState(accountID, sid, mid, "w%d" % weekIdx, int(def["goal"]))
		weeklies.append({"id": mid, "label": str(def["label"]), "goal": int(def["goal"]),
			"progress": mini(_MissionProgress(accountID, mid, weekStart, sid), int(def["goal"])),
			"claimed": int(mst["claimed"]), "pt": PASS_WEEKLY_PT})
	var beaten : int = 0
	for c in _PassChars(accountID):
		beaten = maxi(beaten, Launcher.SQL.GetCharacterBossesBeaten(c))
	var milestones : Array = []
	for i in BossService.BossNames.size():
		var mid : String = "m_boss%d" % i
		var mst : Dictionary = _MissionState(accountID, sid, mid, "s%d" % sid, 1)
		milestones.append({"id": mid, "label": "Defeat %s (first)" % BossService.BossNames[i],
			"goal": 1, "progress": 1 if (beaten > i or int(mst["claimed"]) == 1) else 0,
			"claimed": int(mst["claimed"]), "pt": PASS_MILESTONE_PT})
	return {"dailies": dailies, "weeklies": weeklies, "milestones": milestones,
		"day": day, "week": weekIdx}

# Estado do passe p/ a janela (substitui o stub da F3/F4).
func GetSeasonPass(accountID : int) -> Dictionary:
	var season : Dictionary = ActiveSeason()
	if season.is_empty():
		return {"ok": false, "reason": "no_season"}
	var sid : int = int(season.get("season_id", 0))
	var now : int = SQLCommons.Timestamp()
	var st : Dictionary = _PassStateRaw(accountID, sid)
	var level : int = PassLevelForPT(int(st.get("pt", 0)))
	var ms : Dictionary = _SeasonMissions(accountID, season)
	var freeTodo : Array = []
	var premTodo : Array = []
	for lvl in range(1, mini(level, PASS_MAX_LEVEL) + 1):
		if PASS_FREE.has(lvl) and not (lvl in st["claimed_free"]):
			freeTodo.append(lvl)
		if int(st.get("premium", 0)) == 1 and ((PASS_PREMIUM.has(lvl)) or lvl >= PASS_BONUS_START) and not (lvl in st["claimed_premium"]):
			premTodo.append(lvl)
	return {"ok": true, "season_id": sid, "ends_at": int(season.get("ends_at", 0)),
		"day_index": ShopDay(now) - ShopDay(int(season.get("starts_at", now))),
		"pt": int(st.get("pt", 0)), "level": level, "premium": int(st.get("premium", 0)),
		"skips_used": int(st.get("skips_used", 0)), "skips_max": PASS_SKIP_MAX,
		"double_xp": _PassDoubleXP(season, now),
		"dailies": ms["dailies"], "weeklies": ms["weeklies"], "milestones": ms["milestones"],
		"free_claimable": freeTodo, "premium_claimable": premTodo}

# Reivindica PT de missão do período (diária/semanal/marco). Idempotente.
func ClaimMission(accountID : int, missionID : String) -> Dictionary:
	var season : Dictionary = ActiveSeason()
	if season.is_empty():
		return {"ok": false, "reason": "no_season"}
	var sid : int = int(season.get("season_id", 0))
	var now : int = SQLCommons.Timestamp()
	var day : int = ShopDay(now)
	var periodID : String = ""
	var goal : int = 1
	var award : int = PASS_DAILY_PT
	var progress : int = 0
	if missionID.begins_with("d_"):
		for def in PassDailies(day):
			if str(def["id"]) == missionID:
				goal = int(def["goal"])
				periodID = "d%d" % day
				progress = _MissionProgress(accountID, missionID, PassDayStartTS(day), sid)
				break
		if periodID.is_empty():
			return {"ok": false, "reason": "not_active_today"}
	elif missionID.begins_with("w_"):
		var weekIdx : int = PassWeekIndex(season, now)
		for def in PassWeeklies(weekIdx):
			if str(def["id"]) == missionID:
				goal = int(def["goal"])
				periodID = "w%d" % weekIdx
				award = PASS_WEEKLY_PT
				progress = _MissionProgress(accountID, missionID, PassDayStartTS(ShopDay(int(season.get("starts_at", now))) + weekIdx * 7), sid)
				break
		if periodID.is_empty():
			return {"ok": false, "reason": "not_active_this_week"}
	elif missionID.begins_with("m_boss"):
		var idx : int = int(missionID.get_slice("_", 1).substr(4))
		if idx < 0 or idx >= BossService.BossNames.size():
			return {"ok": false, "reason": "unknown_mission"}
		goal = 1
		periodID = "s%d" % sid
		award = PASS_MILESTONE_PT
		var beaten : int = 0
		for c in _PassChars(accountID):
			beaten = maxi(beaten, Launcher.SQL.GetCharacterBossesBeaten(c))
		progress = 1 if beaten > idx else 0
	else:
		return {"ok": false, "reason": "unknown_mission"}
	if progress < goal:
		return {"ok": false, "reason": "incomplete", "progress": progress, "goal": goal}
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var mst : Dictionary = _MissionState(accountID, sid, missionID, periodID, goal)
		if int(mst.get("claimed", 0)) == 1:
			result["reason"] = "already_claimed"
			return false
		Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_mission_state (account_id, season_id, mission_id, period_id, progress, goal, claimed, claimed_at) VALUES (?, ?, ?, ?, ?, ?, 1, ?);", [accountID, sid, missionID, periodID, progress, goal, now])
		var pts : int = _AwardPT(accountID, sid, award, "mission:" + missionID)
		result["ok"] = true
		result["reason"] = "ok"
		result["pt"] = pts
		return true):
		pass
	settleMutex.unlock()
	return result

func _GrantPassRewardRaw(accountID : int, charID : int, seasonID : int, level : int, track : String) -> bool:
	var sql : SQLService = Launcher.SQL
	var table : Dictionary = PASS_FREE if track == "free" else PASS_PREMIUM
	var reward : Dictionary = {}
	if track == "premium" and level >= PASS_BONUS_START:
		reward = {"gems": PASS_BONUS_GEMS}
	elif table.has(level):
		reward = table[level]
	else:
		return false
	var gems : int = int(reward.get("gems", 0))
	if gems > 0:
		var balance : int = sql.GetGemsRaw(accountID)
		if not sql.SetGemsRaw(accountID, balance + gems):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGems, gems, balance + gems, "pass_reward:%s:%d" % [track, level]):
			return false
	var chests : int = int(reward.get("chests", 0))
	for i in chests:
		if not sql.AddChestInstance(charID, 0, "pass"):
			return false
	var vipDays : int = int(reward.get("vip_days", 0))
	if vipDays > 0:
		var now : int = SQLCommons.Timestamp()
		var cur : int = sql.GetVIPUntil(accountID)
		if not sql.SetVIPUntil(accountID, maxi(now, cur) + vipDays * 86400):
			return false
		var curTier : int = sql.GetVIPTier(accountID)
		if curTier < 1 or cur <= now:
			if not sql.SetVIPTier(accountID, 1):
				return false
	var cosmetics : Array = reward.get("cosmetics", [])
	for cid in cosmetics:
		if not sql.ExecuteBindings("INSERT INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, ?, ?, ?);", [accountID, str(cid), "pass_s1:%s:%d" % [track, level], SQLCommons.Timestamp()]):
			return false
	return true

# Reivindica recompensa de nível (grátis ou premium). Compra tardia libera
# retroativo; bônus 31–40 exigem premium.
func ClaimPassReward(accountID : int, charID : int, level : int, track : String) -> Dictionary:
	if track != "free" and track != "premium":
		return {"ok": false, "reason": "bad_track"}
	if level < 1 or level > PASS_MAX_LEVEL:
		return {"ok": false, "reason": "bad_level"}
	var season : Dictionary = ActiveSeason()
	if season.is_empty():
		return {"ok": false, "reason": "no_season"}
	var sid : int = int(season.get("season_id", 0))
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var st : Dictionary = _PassStateRaw(accountID, sid)
		if PassLevelForPT(int(st.get("pt", 0))) < level:
			result["reason"] = "locked"
			return false
		var key : String = "claimed_free" if track == "free" else "claimed_premium"
		if track == "premium" and int(st.get("premium", 0)) == 0:
			result["reason"] = "not_premium"
			return false
		if level in st[key]:
			result["reason"] = "already_claimed"
			return false
		if not _GrantPassRewardRaw(accountID, charID, sid, level, track):
			return false
		var claimed : Array = (st[key] as Array).duplicate()
		claimed.append(level)
		if not Launcher.SQL.ExecuteBindings("UPDATE season_account_state SET %s = ? WHERE account_id = ? AND season_id = ?;" % key, [JSON.stringify(claimed), accountID, sid]):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		return true):
		pass
	settleMutex.unlock()
	return result

# Skip de nível (catch-up justo): compra o PT faltante p/ o próximo nível,
# 50 gems, máx 10/temporada. Sem multiplicadores (atalho, não prêmio).
func SkipPassLevel(accountID : int) -> Dictionary:
	var season : Dictionary = ActiveSeason()
	if season.is_empty():
		return {"ok": false, "reason": "no_season"}
	var sid : int = int(season.get("season_id", 0))
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var st : Dictionary = _PassStateRaw(accountID, sid)
		if int(st.get("skips_used", 0)) >= PASS_SKIP_MAX:
			result["reason"] = "skip_cap"
			return false
		var level : int = PassLevelForPT(int(st.get("pt", 0)))
		if level >= PASS_MAX_LEVEL:
			result["reason"] = "max_level"
			return false
		var missing : int = int((PassThresholds() as Array)[level]) - int(st.get("pt", 0))
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		if balance < PASS_SKIP_COST:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, balance - PASS_SKIP_COST):
			return false
		if not _LedgerAppendLocked(accountID, 0, LedgerKindGems, -PASS_SKIP_COST, balance - PASS_SKIP_COST, "pass_skip"):
			return false
		var maxPT : int = int((PassThresholds() as Array).back())
		var newPT : int = mini(int(st.get("pt", 0)) + missing, maxPT)
		sql.ExecuteBindings("UPDATE season_account_state SET pt = ?, skips_used = skips_used + 1 WHERE account_id = ? AND season_id = ?;", [newPT, accountID, sid])
		_LedgerAppendLocked(accountID, 0, "pass_pt", missing, newPT, "pass_pt:skip")
		result["ok"] = true
		result["reason"] = "ok"
		result["pt"] = missing
		return true):
		pass
	settleMutex.unlock()
	return result

# Crédito automático do marco na vitória (só com temporada ativa).
func _PassMilestoneCredit(accountID : int, bossIndex : int) -> void:
	var season : Dictionary = ActiveSeason()
	if season.is_empty():
		return
	var sid : int = int(season.get("season_id", 0))
	var mid : String = "m_boss%d" % bossIndex
	var mst : Dictionary = _MissionState(accountID, sid, mid, "s%d" % sid, 1)
	if int(mst.get("claimed", 0)) == 1:
		return
	Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_mission_state (account_id, season_id, mission_id, period_id, progress, goal, claimed, claimed_at) VALUES (?, ?, ?, ?, 1, 1, 1, ?);", [accountID, sid, mid, "s%d" % sid, SQLCommons.Timestamp()])
	_AwardPT(accountID, sid, PASS_MILESTONE_PT, "mission:" + mid)

# Auto-claim no encerramento (recompensas não-claimadas nunca expiram
# silenciosamente): tudo que o nível alcançou, nas duas trilhas (premium só
# p/ quem comprou). Chamado no settle da temporada fechada.
func _AutoClaimPass(seasonID : int) -> Dictionary:
	var done : Dictionary = {"claimed": 0}
	for row in Launcher.SQL.QueryBindings("SELECT account_id, pt, premium, claimed_free, claimed_premium FROM season_account_state WHERE season_id = ?;", [seasonID]):
		var accountID : int = int(row["account_id"])
		var level : int = PassLevelForPT(int(row.get("pt", 0)))
		if level < 1:
			continue
		var chars : Array = _PassChars(accountID)
		if chars.is_empty():
			continue
		var charID : int = int(chars[0])
		var cf : Variant = JSON.parse_string(str(row.get("claimed_free", "[]")))
		var cp : Variant = JSON.parse_string(str(row.get("claimed_premium", "[]")))
		var claimedF : Array = []
		for x in (cf if cf is Array else []):
			claimedF.append(int(x))
		var claimedP : Array = []
		for x in (cp if cp is Array else []):
			claimedP.append(int(x))
		var changedF : bool = false
		var changedP : bool = false
		settleMutex.lock()
		if Launcher.SQL.Transaction(func() -> bool:
			for lvl in range(1, mini(level, PASS_MAX_LEVEL) + 1):
				if PASS_FREE.has(lvl) and not (lvl in claimedF):
					if not _GrantPassRewardRaw(accountID, charID, seasonID, lvl, "free"):
						return false
					claimedF.append(lvl)
					changedF = true
				if int(row.get("premium", 0)) == 1 and ((PASS_PREMIUM.has(lvl)) or lvl >= PASS_BONUS_START) and not (lvl in claimedP):
					if not _GrantPassRewardRaw(accountID, charID, seasonID, lvl, "premium"):
						return false
					claimedP.append(lvl)
					changedP = true
			if changedF and not Launcher.SQL.ExecuteBindings("UPDATE season_account_state SET claimed_free = ? WHERE account_id = ? AND season_id = ?;", [JSON.stringify(claimedF), accountID, seasonID]):
				return false
			if changedP and not Launcher.SQL.ExecuteBindings("UPDATE season_account_state SET claimed_premium = ? WHERE account_id = ? AND season_id = ?;", [JSON.stringify(claimedP), accountID, seasonID]):
				return false
			return true):
			done["claimed"] = int(done.get("claimed", 0)) + 1
		settleMutex.unlock()
	return done

# ------------------------------------------------------------------ E2: auction house (escrow em lots, taxa flat queimada)

const AHListFeeGems : int = 5
const AHMaxOpenPerAccount : int = 5
# Fase F: destaque pago (15 gems, fila em cima) + slots extras (+1 por
# 50×(n+1) gems, máx +5). Taxa flat e guards RMT inalterados.
const AHHighlightFeeGems : int = 15
const AHSlotBaseCost : int = 50
const AHSlotsMaxExtra : int = 5

func AHOpenCap(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT extra FROM ah_slots WHERE account_id = ?;", [accountID])
	var extra : int = int(rows[0].get("extra", 0)) if not rows.is_empty() else 0
	return AHMaxOpenPerAccount + mini(maxi(extra, 0), AHSlotsMaxExtra)

func BuyAHSlot(accountID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT extra FROM ah_slots WHERE account_id = ?;", [accountID])
	var extra : int = int(rows[0].get("extra", 0)) if not rows.is_empty() else 0
	if extra >= AHSlotsMaxExtra:
		return {"ok": false, "reason": "slots_cap"}
	var cost : int = AHSlotBaseCost * (extra + 1)
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < cost:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - cost):
			return false
		if not sql.ExecuteBindings("INSERT OR REPLACE INTO ah_slots (account_id, extra) VALUES (?, ?);", [accountID, extra + 1]):
			return false
		if not _LedgerAppendLocked(accountID, 0, LedgerKindGems, -cost, gems - cost, "ah_slot"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["slots"] = AHMaxOpenPerAccount + extra + 1
		return true):
		pass
	settleMutex.unlock()
	return result

func HighlightListing(accountID : int, listingID : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["seller_account", "highlight"])
		if rows.is_empty():
			result["reason"] = "not_found"
			return false
		if int(rows[0].get("seller_account", 0)) != accountID:
			result["reason"] = "not_yours"
			return false
		if int(rows[0].get("highlight", 0)) == 1:
			result["reason"] = "already_highlighted"
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < AHHighlightFeeGems:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - AHHighlightFeeGems):
			return false
		if not sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"highlight" = 1}):
			return false
		if not _LedgerAppendLocked(accountID, 0, LedgerKindGems, -AHHighlightFeeGems, gems - AHHighlightFeeGems, "ah_highlight_fee"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		return true):
		pass
	settleMutex.unlock()
	return result

func BrowseListings(limit : int = 20) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT id, seller_char, item_id, count, price_gold, highlight, created_at FROM auction_listing WHERE status = 'open' ORDER BY highlight DESC, id DESC LIMIT ?;", [limit])

func ListItemForSale(sellerChar : int, itemID : int, count : int, priceGold : int) -> int:
	if itemID <= 0 or count <= 0 or priceGold <= 0:
		return 0
	var out : Dictionary = {"id" = 0}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var accountID : int = _AccountIDForCharacterRaw(sellerChar)
		if accountID == NetworkCommons.PeerUnknownID:
			return false
		var openRows : Array = sql.db.select_rows("auction_listing", "seller_account = %d AND status = 'open'" % accountID, ["id"])
		if openRows.size() >= AHOpenCap(accountID):
			return false
		if _ItemCountRaw(sellerChar, itemID) < count:
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < AHListFeeGems:
			return false
		# SOM-IDLE Fase H §7: capture creator_account_id BEFORE consume deletes lots
		# (ConsumeItemLotsRaw deletes item_instance rows). Read from the seller's
		# existing lots, defaulting to 0 (non-crafted items → no fee).
		var creatorAccount : int = 0
		var lots : Array = sql.db.select_rows("item_instance", "char_id = %d AND item_id = %d AND storage = 0 AND bound = 0" % [sellerChar, itemID], ["uid", "creator_account_id"])
		for lot in lots:
			var ca : int = int(lot.get("creator_account_id", 0))
			if ca != 0:
				creatorAccount = ca
				break
		var consumed : Array = sql.ConsumeItemLotsRaw(sellerChar, itemID, count, false)
		if consumed.is_empty():
			return false
		var stock : int = _ItemCountRaw(sellerChar, itemID)
		if stock < count:
			return false
		if stock > count:
			if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, sellerChar], {"count" = stock - count}):
				return false
		elif not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, sellerChar]):
			return false
		if not sql.SetGemsRaw(accountID, gems - AHListFeeGems):
			return false
		if not _LedgerAppendLocked(accountID, sellerChar, LedgerKindGems, -AHListFeeGems, gems - AHListFeeGems, "ah_list_fee"):
			return false
		if not sql.db.query_with_bindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, escrow_uids, creator_account_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?);", [sellerChar, accountID, itemID, count, priceGold, _UIDList(consumed), creatorAccount, SQLCommons.Timestamp()]):
			return false
		out["id"] = sql.LastInsertRowIDRaw()
		if int(out["id"]) <= 0:
			return false
		return _LedgerAppendLocked(accountID, sellerChar, LedgerKindItem, -count, 0, "ah_list:%d:uids%s" % [itemID, _UIDList(consumed)])):
		pass
	settleMutex.unlock()
	return int(out["id"])

# ------------------------------------------------------------------ Fase F: torneios (MONETIZATION §1 item 11)
#
# Copas assíncronas de poder: inscrição em GOLD (sink), ranking por ganho de
# power na janela, prêmios em gems + título de Campeão. Entrada NUNCA em
# dinheiro (risco loteria/azar no BR). Rotação semanal automática no job diário.
const TOURNAMENT_ENTRY_GOLD : int = 1000
const TOURNAMENT_DAYS : int = 7
const TOURNAMENT_PRIZES : Array[int] = [2000, 1200, 800, 500, 300]
const TOURNAMENT_CHAMPION_TITLE : String = "title_campeao"

func ActiveTournament() -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT tournament_id, name, entry_gold, starts_at, ends_at, status FROM tournament WHERE status = 'active' ORDER BY tournament_id DESC LIMIT 1;", [])
	return {} if rows.is_empty() else rows[0]

func EnsureWeeklyTournament() -> int:
	if not ActiveTournament().is_empty():
		return int(ActiveTournament()["tournament_id"])
	var now : int = SQLCommons.Timestamp()
	var out : Dictionary = {"id" = 0}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		if not ActiveTournament().is_empty():
			return false
		if not Launcher.SQL.ExecuteBindings("INSERT INTO tournament (name, entry_gold, starts_at, ends_at, status, prizes_json) VALUES (?, ?, ?, ?, 'active', ?);", ["Copa Semanal", TOURNAMENT_ENTRY_GOLD, now, now + TOURNAMENT_DAYS * 86400, JSON.stringify(TOURNAMENT_PRIZES)]):
			return false
		out["id"] = Launcher.SQL.LastInsertRowIDRaw()
		return int(out["id"]) > 0):
		pass
	settleMutex.unlock()
	return int(out["id"])

func GetTournaments(accountID : int) -> Dictionary:
	var t : Dictionary = ActiveTournament()
	if t.is_empty():
		return {"ok": true, "active": {}, "my_entry": {}}
	var tid : int = int(t.get("tournament_id", 0))
	var mine : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT char_id, power_start, power_end FROM tournament_entry WHERE tournament_id = ? AND account_id = ?;", [tid, accountID])
	var entries : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM tournament_entry WHERE tournament_id = ?;", [tid])
	return {"ok": true, "active": {"id": tid, "name": str(t.get("name", "?")), "entry_gold": int(t.get("entry_gold", 0)),
		"ends_at": int(t.get("ends_at", 0)), "players": int(entries[0]["n"]) if not entries.is_empty() else 0,
		"prizes": TOURNAMENT_PRIZES}, "my_entry": mine[0] if not mine.is_empty() else {}}

func EnterTournament(accountID : int, charID : int, tournamentID : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("tournament", "tournament_id = %d AND status = 'active'" % tournamentID, ["entry_gold", "ends_at"])
		if rows.is_empty():
			result["reason"] = "not_open"
			return false
		if SQLCommons.Timestamp() > int(rows[0].get("ends_at", 0)):
			result["reason"] = "not_open"
			return false
		if not sql.QueryBindings("SELECT account_id FROM tournament_entry WHERE tournament_id = ? AND account_id = ?;", [tournamentID, accountID]).is_empty():
			result["reason"] = "already_entered"
			return false
		var fee : int = int(rows[0].get("entry_gold", 0))
		var gp : int = _CharGoldRaw(charID)
		if gp < fee:
			result["reason"] = "insufficient_gold"
			return false
		var power : Array = sql.db.select_rows("character", "char_id = %d" % charID, ["power_score"])
		var start : int = int(power[0].get("power_score", 0)) if not power.is_empty() and power[0].get("power_score", null) != null else 0
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - fee}):
			return false
		if not sql.ExecuteBindings("INSERT INTO tournament_entry (tournament_id, account_id, char_id, power_start) VALUES (?, ?, ?, ?);", [tournamentID, accountID, charID, start]):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGold, -fee, gp - fee, "tournament_entry:%d" % tournamentID):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		return true):
		pass
	settleMutex.unlock()
	return result

# Liquida um torneio vencido: power_end = power atual, rank por ganho,
# prêmios em gems + título ao campeão. Idempotente por status.
func SettleTournament(tournamentID : int) -> Dictionary:
	var out : Dictionary = {"ok": false, "reason": "rejected", "awarded": 0}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("tournament", "tournament_id = %d" % tournamentID, ["status"])
		if rows.is_empty() or str(rows[0].get("status", "")) != "active":
			out["reason"] = "not_active"
			return false
		var now : int = SQLCommons.Timestamp()
		var ends : Array = sql.db.select_rows("tournament", "tournament_id = %d" % tournamentID, ["ends_at"])
		if int(ends[0].get("ends_at", now + 1)) > now:
			out["reason"] = "not_ended"
			return false
		var entries : Array[Dictionary] = sql.QueryBindings("SELECT account_id, char_id, power_start FROM tournament_entry WHERE tournament_id = ?;", [tournamentID])
		var ranked : Array = []
		for e in entries:
			var prow : Array = sql.db.select_rows("character", "char_id = %d" % int(e["char_id"]), ["power_score"])
			var pend : int = int(prow[0].get("power_score", 0)) if not prow.is_empty() and prow[0].get("power_score", null) != null else 0
			sql.ExecuteBindings("UPDATE tournament_entry SET power_end = ? WHERE tournament_id = ? AND account_id = ?;", [pend, tournamentID, int(e["account_id"])])
			ranked.append({"account_id": int(e["account_id"]), "char_id": int(e["char_id"]), "gain": pend - int(e["power_start"])})
		ranked.sort_custom(func(a : Dictionary, b : Dictionary) -> bool:
			if int(a["gain"]) != int(b["gain"]):
				return int(a["gain"]) > int(b["gain"])
			return int(a["char_id"]) < int(b["char_id"]))
		var awarded : int = 0
		for rank in mini(ranked.size(), TOURNAMENT_PRIZES.size()):
			var prize : int = TOURNAMENT_PRIZES[rank]
			var acct : int = int(ranked[rank]["account_id"])
			var balance : int = sql.GetGemsRaw(acct)
			if not sql.SetGemsRaw(acct, balance + prize):
				return false
			if not _LedgerAppendLocked(acct, int(ranked[rank]["char_id"]), LedgerKindGems, prize, balance + prize, "tournament_prize:%d:%d" % [tournamentID, rank + 1]):
				return false
			if rank == 0:
				sql.ExecuteBindings("INSERT OR IGNORE INTO cosmetic_grant (account_id, cosmetic_id, source, granted_at) VALUES (?, ?, ?, ?);", [acct, TOURNAMENT_CHAMPION_TITLE, "tournament:%d" % tournamentID, now])
			awarded += 1
		if not sql.UpdateRowsRaw("tournament", "tournament_id = %d" % tournamentID, {"status" = "settled"}):
			return false
		out["ok"] = true
		out["reason"] = "settled"
		out["awarded"] = awarded
		return true):
		pass
	settleMutex.unlock()
	return out

# Ciclo do job diário: liquida vencidos + garante a copa da semana.
func TickTournaments() -> Dictionary:
	var settled : int = 0
	var now : int = SQLCommons.Timestamp()
	for row in Launcher.SQL.QueryBindings("SELECT tournament_id FROM tournament WHERE status = 'active' AND ends_at <= ?;", [now]):
		var res : Dictionary = SettleTournament(int(row["tournament_id"]))
		if bool(res.get("ok", false)):
			settled += 1
	var active : Dictionary = ActiveTournament()
	var created : int = 0
	if active.is_empty():
		created = 1 if EnsureWeeklyTournament() > 0 else 0
	return {"settled": settled, "created": created}

func BuyListing(buyerChar : int, listingID : int) -> bool:
	var bought : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["*"])
		if rows.is_empty():
			return false
		var listing : Dictionary = rows[0]
		var sellerChar : int = int(listing["seller_char"])
		var sellerAccount : int = int(listing["seller_account"])
		var itemID : int = int(listing["item_id"])
		var count : int = int(listing["count"])
		var price : int = int(listing["price_gold"])
		var buyerAccount : int = _AccountIDForCharacterRaw(buyerChar)
		if buyerAccount == NetworkCommons.PeerUnknownID or buyerAccount == sellerAccount or buyerChar == sellerChar:
			return false
		var buyerGold : int = _CharGoldRaw(buyerChar)
		if buyerGold < price:
			return false
		var sellerGold : int = _CharGoldRaw(sellerChar)

		# SOM-IDLE Fase H §7: creator fee 1% — creator_account_id was captured at
		# listing time (consumed lots are deleted, so we can't re-read them).
		# Fee only fires if the creator differs from the seller.
		var creatorAccount : int = int(listing.get("creator_account_id", 0))
		var creatorFee : int = 0
		var sellerNet : int = price
		if creatorAccount != 0 and creatorAccount != sellerAccount:
			creatorFee = maxi(0, roundi(float(price) * float(CRAFT_CREATOR_FEE_PCT) / 100.0))
			sellerNet = price - creatorFee
			# Credit the creator's gold (stat.gp on their first char)
			var creatorChars : PackedInt64Array = sql.GetCharacters(creatorAccount)
			if creatorChars.is_empty():
				return false
			var creatorChar : int = int(creatorChars[0])
			var creatorGold : int = _CharGoldRaw(creatorChar)
			if not sql.UpdateRowsRaw("stat", "char_id = %d" % creatorChar, {"gp" = creatorGold + creatorFee}):
				return false
			if not _LedgerAppendLocked(creatorAccount, creatorChar, LedgerKindGold, creatorFee, creatorGold + creatorFee, "ah_creator_fee:%d" % listingID):
				return false

		if not sql.UpdateRowsRaw("stat", "char_id = %d" % buyerChar, {"gp" = buyerGold - price}):
			return false
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % sellerChar, {"gp" = sellerGold + sellerNet}):
			return false
		var parentUID : int = int(str(listing.get("escrow_uids", "0")).split(",")[0])
		var granted : int = sql.GrantItemLotRaw(buyerChar, itemID, count, "ah_buy", 0, "", parentUID)
		if granted == 0:
			return false
		var existing : Array = sql.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, buyerChar], ["count"])
		if existing.is_empty():
			if not sql.db.insert_row("item", {"item_id" = itemID, "char_id" = buyerChar, "count" = count, "storage" = 0, "customfield" = ""}):
				return false
		elif not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, buyerChar], {"count" = int(existing[0]["count"]) + count}):
			return false
		if not sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"status" = "sold"}):
			return false
		if not _LedgerAppendLocked(buyerAccount, buyerChar, LedgerKindGold, -price, buyerGold - price, "ah_buy:%d" % listingID):
			return false
		if not _LedgerAppendLocked(sellerAccount, sellerChar, LedgerKindGold, sellerNet, sellerGold + sellerNet, "ah_sell:%d" % listingID):
			return false
		return _LedgerAppendLocked(buyerAccount, buyerChar, LedgerKindItem, count, 0, "trade_in:%d:lot%d" % [itemID, granted])):
		bought = true
	settleMutex.unlock()
	return bought

func CancelListing(charID : int, listingID : int) -> bool:
	var done : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["*"])
		if rows.is_empty() or int(rows[0]["seller_char"]) != charID:
			return false
		var listing : Dictionary = rows[0]
		var accountID : int = int(listing["seller_account"])
		var itemID : int = int(listing["item_id"])
		var count : int = int(listing["count"])
		if _GrantStackRaw(charID, accountID, itemID, count, "ah_cancel:%d" % listingID, "ah_cancel") == 0:
			return false
		return sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"status" = "cancelled"})):
		done = true
	settleMutex.unlock()
	return done

# Daily reconciliation: ledger gold sums must match stat.gp deltas per account;
# no account may hold a negative balance. Returns number of divergences found.
func ReconcileDaily() -> int:
	var divergences : int = 0
	# SOM-IDLE E: escopo em contas existentes (linhas de fixtures deletados em
	# test-runs não são reconciliáveis — mesma regra dos lots).
	var negatives : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT account_id, SUM(amount) AS total FROM ledger_transaction WHERE kind = 'gold' AND EXISTS (SELECT 1 FROM account WHERE account.account_id = ledger_transaction.account_id) GROUP BY account_id HAVING total < 0;")
	divergences += negatives.size()

	# XP rows must never be negative either
	var xpNeg : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT account_id, SUM(amount) AS total FROM ledger_transaction WHERE kind = 'xp' AND EXISTS (SELECT 1 FROM account WHERE account.account_id = ledger_transaction.account_id) GROUP BY account_id HAVING total < 0;")
	divergences += xpNeg.size()

	# SOM-IDLE B1: soma dos lotes ativos deve espelhar a stack agregada
	# (storage 0, personagens existentes — órfãos de runs/fixtures excluídos).
	var stackMismatch : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT i.char_id FROM item i WHERE i.storage = 0 AND EXISTS (SELECT 1 FROM character WHERE character.char_id = i.char_id) AND i.count != COALESCE((SELECT SUM(count) FROM item_instance WHERE item_instance.char_id = i.char_id AND item_instance.item_id = i.item_id AND item_instance.storage = i.storage AND item_instance.customfield = i.customfield), -1);")
	divergences += stackMismatch.size()
	var orphanLots : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT s.char_id FROM (SELECT char_id, item_id, storage, customfield, SUM(count) AS lots FROM item_instance GROUP BY char_id, item_id, storage, customfield) AS s WHERE s.lots != 0 AND EXISTS (SELECT 1 FROM character WHERE character.char_id = s.char_id) AND NOT EXISTS (SELECT 1 FROM item WHERE item.char_id = s.char_id AND item.item_id = s.item_id AND item.storage = s.storage AND item.customfield = s.customfield);")
	divergences += orphanLots.size()

	return divergences

# SOM-IDLE D2: daily reconcile job — roda após o backup diário (SQLBackups)
# e registra a divergência para o dashboard. Best-effort, nunca derruba o loop.
func RunReconcileJob() -> int:
	var divergences : int = ReconcileDaily()
	Launcher.SQL.ExecuteBindings("INSERT INTO reconcile_run (created_at, divergences) VALUES (?, ?);", [SQLCommons.Timestamp(), divergences])
	if divergences > 0:
		Util.PrintLog("Economy", "Reconcile found %d divergences" % divergences)
	var flagged : int = RunFraudScan()
	if flagged > 0:
		Util.PrintLog("Economy", "Fraud scan opened %d flags" % flagged)
	# SOM-IDLE (3b): ciclo de vida de temporada (fecha vencidas + liquida prêmios).
	var seasons : Dictionary = TickSeasonLifecycle()
	if int(seasons.get("settled", 0)) > 0 or int(seasons.get("closed", 0)) > 0:
		Util.PrintLog("Economy", "Season lifecycle: closed %d, settled %d" % [int(seasons.get("closed", 0)), int(seasons.get("settled", 0))])
	# Fase F: copas semanais (liquida vencidas + garante a ativa).
	var tours : Dictionary = TickTournaments()
	if int(tours.get("settled", 0)) > 0 or int(tours.get("created", 0)) > 0:
		Util.PrintLog("Economy", "Tournaments: settled %d, created %d" % [int(tours.get("settled", 0)), int(tours.get("created", 0))])
	# R1: bônus de referral por marco (job diário; idempotente por ledger+flag).
	var ref : int = GrantReferralBonuses()
	if ref > 0:
		Util.PrintLog("Economy", "Referral bonuses paid: %d" % ref)
	return divergences

# ------------------------------------------------------------------ R1: referral (COMMUNITY_ROADMAP)
# Código por conta, recompensa por marco (L10 + e-mail verificado), anti-farma
# via marco + teto semanal + auto-referral bloqueado (fingerprint cai no
# fraud_flag existente). Valores são proposta (dono confirma).
const REFERRAL_BONUS_GEMS : int = 200
const REFERRAL_MIN_LEVEL : int = 10
const REFERRAL_WINDOW_SEC : int = 3 * 86400
const REFERRAL_WEEKLY_CAP : int = 10

static func ReferralCodeFor(accountID : int, username : String) -> String:
	return "%s#%04d" % [username, accountID % 10000]

func GetReferralState(accountID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT username, referral_code, referred_by FROM account WHERE account_id = ?;", [accountID])
	if rows.is_empty():
		return {"ok" = false, "reason" = "unknown_account"}
	var code : String = str(rows[0].get("referral_code", ""))
	if code.is_empty():
		code = ReferralCodeFor(accountID, str(rows[0].get("username", "?")))
		Launcher.SQL.ExecuteBindings("UPDATE account SET referral_code = ? WHERE account_id = ?;", [code, accountID])
	var invited : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM account WHERE referred_by = ?;", [accountID])
	var paid : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE ?;", [accountID, "referral_bonus:%"])
	return {"ok" = true, "code" = code,
		"referred_by" = int(rows[0].get("referred_by", 0)),
		"invited" = int(invited[0].get("n", 0)) if not invited.is_empty() else 0,
		"bonuses" = int(paid[0].get("n", 0)) if not paid.is_empty() else 0,
		"bonus_gems" = REFERRAL_BONUS_GEMS, "min_level" = REFERRAL_MIN_LEVEL}

func SetReferralCode(accountID : int, code : String) -> Dictionary:
	var clean : String = code.strip_edges()
	if clean.is_empty():
		return {"ok" = false, "reason" = "bad_code"}
	var me : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT username, created_timestamp, referred_by, referral_code FROM account WHERE account_id = ?;", [accountID])
	if me.is_empty():
		return {"ok" = false, "reason" = "unknown_account"}
	if int(me[0].get("referred_by", 0)) != 0:
		return {"ok" = false, "reason" = "already_referred"}
	if SQLCommons.Timestamp() - int(me[0].get("created_timestamp", 0)) > REFERRAL_WINDOW_SEC:
		return {"ok" = false, "reason" = "window_expired"}
	if clean == str(me[0].get("referral_code", "")) and not clean.is_empty():
		return {"ok" = false, "reason" = "self_referral"}
	var inv : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, username FROM account WHERE referral_code = ?;", [clean])
	if inv.is_empty():
		return {"ok" = false, "reason" = "unknown_code"}
	var inviter : int = int(inv[0]["account_id"])
	if inviter == accountID:
		return {"ok" = false, "reason" = "self_referral"}
	if not Launcher.SQL.ExecuteBindings("UPDATE account SET referred_by = ? WHERE account_id = ? AND referred_by = 0;", [inviter, accountID]):
		return {"ok" = false, "reason" = "db_error"}
	return {"ok" = true, "reason" = "ok", "inviter" = str(inv[0].get("username", "?"))}

func _ReferralMaxLevel(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT MAX(s.level) AS m FROM stat s INNER JOIN character c ON c.char_id = s.char_id WHERE c.account_id = ?;", [accountID])
	if rows.is_empty() or rows[0].get("m", null) == null:
		return 0
	return int(rows[0]["m"])

# Job diário: paga bônus de marco (inviter + invitee). Idempotente por flag +
# reason do ledger; teto semanal por inviter. Retorna pares pagos.
func GrantReferralBonuses() -> int:
	var paid : int = 0
	var now : int = SQLCommons.Timestamp()
	var weekAgo : int = now - 7 * 86400
	for row in Launcher.SQL.QueryBindings("SELECT account_id, referred_by FROM account WHERE referred_by > 0 AND referral_bonus_claimed == 0;", []):
		var invitee : int = int(row["account_id"])
		var inviter : int = int(row["referred_by"])
		if not Launcher.SQL.IsEmailVerifiedRaw(invitee):
			continue
		if _ReferralMaxLevel(invitee) < REFERRAL_MIN_LEVEL:
			continue
		var week : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE 'referral_bonus:%' AND created_at >= ?;", [inviter, weekAgo])
		if not week.is_empty() and int(week[0].get("n", 0)) >= REFERRAL_WEEKLY_CAP:
			continue
		if not Launcher.SQL.QueryBindings("SELECT id FROM ledger_transaction WHERE reason = ? LIMIT 1;", ["referral_bonus:%d:%d" % [inviter, invitee]]).is_empty():
			Launcher.SQL.ExecuteBindings("UPDATE account SET referral_bonus_claimed = 1 WHERE account_id = ?;", [invitee])
			continue
		if not AddGems(inviter, REFERRAL_BONUS_GEMS, "referral_bonus:%d:%d" % [inviter, invitee]):
			continue
		if not AddGems(invitee, REFERRAL_BONUS_GEMS, "referral_welcome:%d" % inviter):
			continue
		Launcher.SQL.ExecuteBindings("UPDATE account SET referral_bonus_claimed = 1 WHERE account_id = ?;", [invitee])
		paid += 1
	return paid

# SOM-IDLE D3: heuristic fraud scan (roda no job diário; revisão é manual via
# /cs_flags). Heurísticas v1: rajada de trades, velocidade de level impossível,
# flip do mesmo item (compra/vende em <1h — padrão RMT/laundering).
const FraudTradeBurstPerDay : int = 10
const FraudLevelJump : int = 20
const FraudLevelJumpHours : float = 2.0

func RunFraudScan() -> int:
	var opened : int = 0
	var now : int = SQLCommons.Timestamp()
	opened += _FlagTradeBursts(now)
	opened += _FlagLevelVelocity(now)
	opened += _FlagFlipTrades(now)
	return opened

func _FlagOpen(accountID : int, charID : int, kind : String, detail : String) -> bool:
	var dup : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM fraud_flag WHERE account_id = ? AND kind = ? AND detail = ? AND status = 'open';", [accountID, kind, detail])
	if not dup.is_empty():
		return false
	return Launcher.SQL.ExecuteBindings("INSERT INTO fraud_flag (created_at, account_id, char_id, kind, detail, status) VALUES (?, ?, ?, ?, ?, 'open');", [SQLCommons.Timestamp(), accountID, charID, kind, detail])

# SOM-IDLE S5: a heurística de multi-conta (Peers.FinalizeLogin, não-bloqueante)
# abre flag na MESMA fila de revisão manual das outras heurísticas — antes só
# logava um alerta separado. Sem ban automático por design: punição é manual.
func FlagMultiAccount(accountID : int, detail : String) -> bool:
	if accountID <= 0 or detail.is_empty():
		return false
	return _FlagOpen(accountID, 0, "multi_account", detail)

func _FlagTradeBursts(now : int) -> int:
	var opened : int = 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, COUNT(*) AS n FROM ledger_transaction WHERE reason LIKE 'trade_out:%' AND created_at >= ? GROUP BY account_id HAVING n > ?;", [now - 86400, FraudTradeBurstPerDay])
	for row in rows:
		if _FlagOpen(int(row["account_id"]), 0, "trade_burst", "trades_24h=%d" % int(row["n"])):
			opened += 1
	return opened

func _FlagLevelVelocity(now : int) -> int:
	var opened : int = 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, char_id, value, meta FROM telemetry_event WHERE kind = 'levelup' AND created_at >= ? AND value >= ?;", [now - 86400, FraudLevelJump])
	for row in rows:
		var meta : Variant = JSON.parse_string(str(row.get("meta", "")))
		if meta is Dictionary and float((meta as Dictionary).get("hours", 99.0)) < FraudLevelJumpHours:
			if _FlagOpen(int(row["account_id"]), int(row["char_id"]), "level_velocity", "jump=%d levels in %sh" % [int(row["value"]), str((meta as Dictionary).get("hours", "?"))]):
				opened += 1
	return opened

func _FlagFlipTrades(now : int) -> int:
	# Flip = char enviou o item X e RECEBEU o mesmo X em <1h (padrão
	# laundering/RMT). Trade bilateral normal (X por Y) não casa: itens diferem.
	var opened : int = 0
	var outs : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, char_id, reason, created_at FROM ledger_transaction WHERE reason LIKE 'trade_out:%' AND created_at >= ?;", [now - 86400])
	for row in outs:
		var parts : PackedStringArray = str(row["reason"]).split(":")
		if parts.size() < 2:
			continue
		var item : String = parts[1]
		var back : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM ledger_transaction WHERE char_id = ? AND reason LIKE ? AND ABS(created_at - ?) < 3600 LIMIT 1;", [int(row["char_id"]), "trade_in:" + item + ":%", int(row["created_at"])])
		if not back.is_empty():
			if _FlagOpen(int(row["account_id"]), int(row["char_id"]), "flip_trade", "item=%s" % item):
				opened += 1
	return opened

# ------------------------------------------------------------------ Fase H: criação de itens (ITEM_CRAFTING.md, v1 gold)
#
# Teto = melhor item REAL por (tier, slot), extraído por tools/extract_budget.py
# (soma só de valores positivos; negativos são drawback livre). Célula 0 = sem
# precedente = crafting bloqueado. Slots seguem ActorCommons.Slot (0–7).
# Pesos 1:1 = TUNING_PENDING (dado de gameplay, não economia).
const CRAFT_BUDGET_CAP : Dictionary = {
	1: [20, 20, 15, 15, 5, 0, 20, 20],
	2: [30, 0, 0, 0, 0, 0, 0, 0],
	3: [0, 0, 0, 0, 0, 0, 66, 0],
	4: [0, 0, 0, 0, 0, 0, 95, 0],
	5: [0, 0, 0, 0, 0, 0, 146, 0],
	6: [0, 0, 0, 0, 0, 0, 0, 0],
	7: [0, 0, 0, 0, 0, 0, 0, 0],
	8: [0, 0, 0, 0, 0, 0, 0, 0],
}
const CRAFT_SLOT_NAMES : Array[String] = ["CHEST", "LEGS", "FEET", "HANDS", "HEAD", "NECK", "WEAPON", "SHIELD"]
const CRAFT_MOD_WEIGHTS : Array[float] = [0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
const CRAFT_RARITY_BANDS : Array = [[40, "Comum"], [65, "Incomum"], [85, "Raro"], [97, "Épico"], [101, "Lendário"]]
const CRAFT_RARITY_WEIGHT : Dictionary = {"Comum": 100, "Incomum": 60, "Raro": 30, "Épico": 12, "Lendário": 5}
const CRAFT_SUBMIT_FEE_BASE : int = 500
const CRAFT_MAX_PER_DAY : int = 3
const CRAFT_RESUB_MAX : int = 3
const CRAFT_RESUB_DAYS : int = 7
const CRAFT_CREATOR_FEE_PCT : int = 1

static func CraftBudgetCap(tier : int, slot : int) -> int:
	if not CRAFT_BUDGET_CAP.has(tier) or slot < 0 or slot > 7:
		return 0
	return int((CRAFT_BUDGET_CAP[tier] as Array)[slot])

static func CraftRarityForUsage(pct : float) -> String:
	for band in CRAFT_RARITY_BANDS:
		if pct < float((band as Array)[0]):
			return str((band as Array)[1])
	return "Lendário"

# Taxa de submissão em gold: 500 × tier² (proposta; confirmar após o beta).
static func CraftSubmitFee(tier : int) -> int:
	return CRAFT_SUBMIT_FEE_BASE * tier * tier

# Normaliza nome p/ checagens (pré-filtro + duplicata).
static func CraftNormName(name : String) -> String:
	return name.strip_edges().to_lower()

# Distância de edição simples (golpe tipo Gladiu5 vs Gladius). O(n*m), nomes
# curtos — sem problema de performance no volume de submissões.
static func CraftEditDistance(a : String, b : String) -> int:
	var prev : Array = []
	for j in b.length() + 1:
		prev.append(j)
	for i in range(1, a.length() + 1):
		var cur : Array = [i]
		for j in range(1, b.length() + 1):
			cur.append(mini(mini(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (0 if a[i - 1] == b[j - 1] else 1)))
		prev = cur
	return int(prev[b.length()])

# SOM-IDLE Fase H: validação + gravação de submissão de item criado.
# ITEM_CRAFTING.md §2: paga taxa de gold sink, valida orçamento, nome e capa
# diária; grava como 'pending'. GM aprova depois (WorldCommands).
#
# Validações (server-autorizado):
# - slot válido (0–7), baseItemHash > 0, name não-vazio
# - budget: soma ponderada de modifiers <= CraftBudgetCap(tier, slot) (0 = bloqueado)
# - taxa: player tem gp >= CraftSubmitFee(tier); burnt + ledger mirror
# - nome: não vazio, tamanho 3–30, não na blocklist, não duplicata (edit-distance < 2)
# - daily cap: CRAFT_MAX_PER_DAY submissões hoje
# - email verificado (D3 auth gate)
#
# Retorna {ok: bool, reason: String}.
func SubmitCraft(charID : int, accountID : int, slot : int, baseItemHash : int, name : String, modifiers : Dictionary) -> Dictionary:
	var result : Dictionary = {"ok" = false, "reason" = ""}
	if slot < 0 or slot > 7:
		result["reason"] = "invalid_slot"
		return result
	if baseItemHash <= 0:
		result["reason"] = "invalid_base_item"
		return result
	var cleanName : String = CraftNormName(name)
	if not NetworkCommons.CheckSize(name.strip_edges(), 3, 30):
		result["reason"] = "invalid_name"
		return result
	if cleanName.is_empty():
		result["reason"] = "invalid_name"
		return result

	# Derive tier from baseItemHash — the visual template's slot+tier must match.
	var baseCell : ItemCell = DB.ItemsDB.get(baseItemHash, null)
	if baseCell == null:
		result["reason"] = "invalid_base_item"
		return result
	if baseCell.slot != slot:
		result["reason"] = "slot_mismatch"
		return result
	var tier : int = baseCell.tier
	if tier < 1 or tier > 8:
		result["reason"] = "invalid_tier"
		return result

	var budgetCap : int = CraftBudgetCap(tier, slot)
	if budgetCap <= 0:
		result["reason"] = "slot_crafting_blocked"
		return result

	var budgetUsed : int = 0
	for modKey in modifiers.keys():
		var effect : int = CellCommons.Modifier.get(str(modKey), CellCommons.Modifier.None)
		if effect == CellCommons.Modifier.None:
			result["reason"] = "invalid_modifier"
			return result
		var weight : float = CRAFT_MOD_WEIGHTS[effect] if effect < CRAFT_MOD_WEIGHTS.size() else 0.0
		var value : int = int(modifiers[modKey])
		if value < 0:
			# Drawbacks are free-form (doc §3.1) — ignore in budget sum.
			continue
		budgetUsed += int(weight * float(value))
	if budgetUsed > budgetCap:
		result["reason"] = "budget_exceeded"
		return result

	var rarity : String = CraftRarityForUsage(float(budgetUsed) / float(budgetCap) * 100.0)
	var fee : int = CraftSubmitFee(tier)
	var now : int = SQLCommons.Timestamp()

	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var dbNode : SQLite = Launcher.SQL.db

		# D3 auth gate: email verificado
		var acctRows : Array = dbNode.select_rows("account", "account_id = %d" % accountID, ["email_verified"])
		if acctRows.is_empty() or int(acctRows[0].get("email_verified", 0)) != 1:
			result["reason"] = "email_not_verified"
			return false

		# Daily cap: CRAFT_MAX_PER_DAY submissões hoje
		var dayStart : int = now - (now % 86400)
		var todayCount : int = 0
		if dbNode.query_with_bindings(
			"SELECT COUNT(*) AS n FROM craft_submission WHERE account_id = ? AND created_at >= ?;",
			[accountID, dayStart]):
			if dbNode.query_result.size() > 0:
				todayCount = int(dbNode.query_result[0].get("n", 0))
		if todayCount >= CRAFT_MAX_PER_DAY:
			result["reason"] = "daily_cap_reached"
			return false

		# Name blocklist + edit-distance duplicate check
		if dbNode.query_with_bindings(
			"SELECT term FROM craft_name_blocklist;", []):
			for row in dbNode.query_result:
				if cleanName.contains(str(row["term"])):
					result["reason"] = "name_blocked"
					return false
		# Check against existing official item names (edit distance < 2 = dup)
		for itemHash in DB.ItemsDB.keys():
			var existing : ItemCell = DB.ItemsDB[itemHash]
			if existing.slot == slot and CraftEditDistance(cleanName, CraftNormName(existing.name)) < 2:
				result["reason"] = "name_duplicate"
				return false

		# Gold fee sink
		var statRows : Array = dbNode.select_rows("stat", "char_id = %d" % charID, ["gp"])
		if statRows.is_empty():
			result["reason"] = "stat_missing"
			return false
		var gp : int = int(statRows[0].get("gp", 0)) if statRows[0].get("gp", null) != null else 0
		if gp < fee:
			result["reason"] = "insufficient_gold"
			return false
		if not Launcher.SQL.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - fee}):
			result["reason"] = "stat_update_failed"
			return false

		# Insert submission (pending)
		var modifiersJSON : String = JSON.stringify(modifiers)
		var ok : bool = dbNode.insert_row("craft_submission", {
			"account_id" = accountID, "char_id" = charID, "slot" = slot,
			"name" = name, "template_hash" = baseItemHash, "tier" = tier,
			"modifiers_json" = modifiersJSON, "budget_used" = budgetUsed,
			"rarity" = rarity, "status" = "pending", "submits_used" = 1,
			"created_at" = now, "decided_at" = 0, "decided_by" = 0,
			"decide_reason" = ""})
		if not ok:
			result["reason"] = "submission_failed"
			return false

		if not _LedgerAppendLocked(accountID, charID, LedgerKindGold, -fee, gp - fee, "craft_submit_fee:tier%d_slot%d" % [tier, slot]):
			result["reason"] = "ledger_failed"
			return false

		result["ok"] = true
		result["reason"] = "pending"
		result["fee"] = fee
		return true):
		pass
	settleMutex.unlock()
	if bool(result.get("ok", false)):
		var subRows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT MAX(id) AS id FROM craft_submission WHERE char_id = ? AND created_at = ?;", [charID, now])
		result["submission_id"] = int(subRows[0]["id"]) if not subRows.is_empty() else 0
	return result

# SOM-IDLE Fase H: GM approval of a pending craft submission.
# - Updates status to 'approved', records decided_at/decided_by
# - Inserts into craft_item_template (parallel dictionary to ItemsDB)
# - Grants a bound copy to the creator (creator_account_id for future 1% fee)
# - Invalidates drop pool cache so the new item can drop
func ApproveCraftSubmission(gm : PlayerAgent, submissionID : int) -> bool:
	var gmAccount : int = Peers.GetAccount(gm.peerID) if gm != null else 0
	if gmAccount == 0 or Peers.GetPermission(gm.peerID) < ActorCommons.Permission.GM:
		return false
	settleMutex.lock()
	var ok : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var dbNode : SQLite = Launcher.SQL.db
		var subRow : Array[Dictionary] = dbNode.select_rows("craft_submission", "id = %d" % submissionID, ["*"])
		# Re-check status inside the transaction (race: another GM may have approved)
		if subRow.is_empty() or str(subRow[0].get("status", "")) != "pending":
			return false
		var sub : Dictionary = subRow[0]
		var now : int = SQLCommons.Timestamp()
		if not Launcher.SQL.UpdateRowsRaw("craft_submission", "id = %d" % submissionID, {
			"status" = "approved", "decided_at" = now, "decided_by" = gmAccount,
			"decide_reason" = "approved"}):
			return false
		# Register in craft_item_template (parallel to ItemsDB)
		if not dbNode.insert_row("craft_item_template", {
			"item_hash" = sub["template_hash"], "slot" = sub["slot"], "name" = sub["name"],
			"tier" = sub["tier"], "modifiers_json" = sub["modifiers_json"],
			"template_hash" = sub["template_hash"], "rarity" = sub["rarity"],
			"creator_account_id" = sub["account_id"], "created_at" = now}):
			return false
		# Invalidate drop pool cache so the new template enters the pool
		FarmZoneData.InvalidateDropPools()
		# Grant a bound copy to the creator (creator_account_id stamped on the lot)
		var charID : int = int(sub["char_id"])
		if not _GrantStackRaw(charID, int(sub["account_id"]), int(sub["template_hash"]), 1,
			"craft_approve:%d" % submissionID, "craft_approve", 1, 0, int(sub["account_id"])):
			return false
		return true):
		ok = true
	settleMutex.unlock()
	if ok:
		Util.PrintLog("Economy", "Craft submission #%d approved by GM %d" % [submissionID, gmAccount])
	return ok

# SOM-IDLE Fase H: GM rejection of a pending craft submission.
# Per ITEM_CRAFTING.md §5.3: submission fee is NOT refunded (policy decision).
# Updates status to 'rejected' with reason; creator can resubmit (submits_used++).
func RejectCraftSubmission(gm : PlayerAgent, submissionID : int, reason : String) -> bool:
	var gmAccount : int = Peers.GetAccount(gm.peerID) if gm != null else 0
	if gmAccount == 0 or Peers.GetPermission(gm.peerID) < ActorCommons.Permission.GM:
		return false
	var now : int = SQLCommons.Timestamp()
	return Launcher.SQL.ExecuteBindings(
		"UPDATE craft_submission SET status = 'rejected', decided_at = ?, decided_by = ?, decide_reason = ? WHERE id = ? AND status = 'pending';",
		[now, gmAccount, reason, submissionID])

