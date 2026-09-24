extends RefCounted
class_name BossProgressionService

# SOM-IDLE Fatia 7: domínio de progressão de boss extraído do EconomyService
# (ROADMAP_COMERCIAL S3). Rebirth (essência + favores), escada de boss (chave →
# desafio ao vivo ou sim), tormento e boss rush. Composição com back-reference:
# este serviço NÃO tem mutex próprio — toda mutação passa pelo settleMutex do
# EconomyService via _eco, exatamente como antes da fatia. Ledger, conta do char
# e sinks de ouro continuam sendo helpers do EconomyService (_eco.*).

var _eco : EconomyService = null

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
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var next : int = Launcher.SQL.AddCharacterEssence(charID, amount)
		if next < 0:
			return false
		var acct : int = _eco._AccountIDForCharacterRaw(charID)
		return _eco._LedgerAppendLocked(acct, charID, EconomyCatalog.LedgerKindEssence, amount, next, reason)):
		applied = true
	_eco.settleMutex.unlock()
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
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var nextEssence : int = Launcher.SQL.AddCharacterEssence(charID, -cost)
		if nextEssence < int(info["essence"]) - cost:
			return false
		if Launcher.SQL.IncRebirthUpgrade(charID, upgradeID) < 0:
			return false
		var acct : int = _eco._AccountIDForCharacterRaw(charID)
		return _eco._LedgerAppendLocked(acct, charID, EconomyCatalog.LedgerKindEssence, -cost, nextEssence, "rebirth_upgrade:" + upgradeID)):
		ok = true
	_eco.settleMutex.unlock()
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
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		if Launcher.SQL.IncRebirthCounter(charID) < 0:
			return false
		return Launcher.SQL.UpdateStatDirect(charID, 1, 0, goldKept)):
		ok = true
	_eco.settleMutex.unlock()
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
		_eco._RebirthVitrine(Launcher.SQL.GetAccountIDForCharacter(charID), rebirths)
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
	_eco.settleMutex.lock()
	var ok : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var current : int = Launcher.SQL.GetCharacterBossKeys(charID)
		if current < amount:
			return false
		var next : int = current - amount
		if Launcher.SQL.AddCharacterBossKeys(charID, -amount) == -1:
			return false
		var acct : int = _eco._AccountIDForCharacterRaw(charID)
		return _eco._LedgerAppendLocked(acct, charID, EconomyCatalog.LedgerKindBossKey, -amount, next, reason)):
		ok = true
	_eco.settleMutex.unlock()
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
	# Tormento (D2): recompensa de boss escala com a dificuldade do char.
	var tormentMult : float = Formula.TormentRewardMult(player.tormentLevel if player is PlayerAgent else 0)
	var baseXp : int = BossService.VictoryXp(zoneXp) if win else BossService.ConsolationXp(zoneXp)
	var xpGrant : int = maxi(1, roundi(float(baseXp) * nb * vipMult * float(reb.get("xp", 1.0)) * tormentMult))
	player.stat.AddExperience(xpGrant, false)
	var goldGrant : int = 0
	if win:
		goldGrant = roundi(float(BossService.VictoryGold(zoneXp)) * nb * vipMult * float(reb.get("gold", 1.0)) * tormentMult)
		player.stat.AddGP(goldGrant, false)

	var chestsGranted : int = 0
	if win:
		for i in BossService.BossChestReward:
			if Launcher.SQL.AddChestInstance(charID, FarmZoneData.DefaultDropItemHash, "boss"):
				chestsGranted += 1
		var prevBeaten : int = Launcher.SQL.GetCharacterBossesBeaten(charID)
		Launcher.SQL.SetCharacterBossesBeaten(charID, index + 1)
		# Tormento: zerar a escada (4 bosses) libera T1; vencer no teto atual
		# sobe o teto (+1, cap). Fronteira nova tem 30% de dropar +1 key.
		var tmax : int = Launcher.SQL.GetTormentMax(charID)
		if maxi(prevBeaten, index + 1) >= BossService.GetBossCount() and tmax < 1:
			Launcher.SQL.SetTormentMax(charID, 1)
		elif tmax >= 1 and tmax < Formula.TormentMaxCap and player is PlayerAgent and (player as PlayerAgent).tormentLevel >= tmax:
			Launcher.SQL.SetTormentMax(charID, tmax + 1)
		if index + 1 > prevBeaten and randf() < EconomyCatalog.FRONTIER_KEY_CHANCE:
			_eco.GrantBossKey(charID, 1, "frontier_bonus")
		# Fase C: marco do passe (50 PT, auto-crédito, só com temporada ativa).
		_eco._PassMilestoneCredit(accountID, index)
		# Fase F: +5 pontos de guild por vitória.
		_eco.GuildSettlePoints(accountID, EconomyCatalog.GUILD_POINT_PER_BOSS_WIN)
		# ROADMAP_COMERCIAL S2: funil first_boss (best-effort, primeira vitória).
		if prevBeaten == 0 and Launcher.get("Telemetry") != null and Launcher.Telemetry.has_method("RecordFunnel"):
			Launcher.Telemetry.RecordFunnel("first_boss", accountID, charID)

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


# ------------------------------------------------------------------ tormento + boss rush (D2)
# Tormento: opt-in 0..max (desbloqueio por progressão na escada). Boss rush:
# 1 key = até 4 duelos simulados em sequência, níveis escalados (+2/luta +
# tormento), para na primeira derrota; recompensas somadas via SettleBossResult
# (tormento, unlock e bônus de fronteira valem por vitória, igual ao ao vivo).

func SetTorment(charID : int, player, level : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	var tmax : int = Launcher.SQL.GetTormentMax(charID)
	if level < 0 or level > mini(tmax, Formula.TormentMaxCap):
		result["reason"] = "locked"
		return result
	if not Launcher.SQL.SetTormentLevel(charID, level):
		result["reason"] = "db_error"
		return result
	if player is PlayerAgent:
		(player as PlayerAgent).tormentLevel = level
	result["ok"] = true
	result["reason"] = "ok"
	result["level"] = level
	return result

func BuyBossKey(charID : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	var accountID : int = _eco._AccountIDForCharacterRaw(charID)
	if accountID == NetworkCommons.PeerUnknownID:
		result["reason"] = "no_character"
		return result
	var mutex : Mutex = _eco._get_settle_mutex(accountID)
	mutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var gp : int = _eco._CharGoldRaw(charID)
		if gp < EconomyCatalog.BOSS_KEY_GOLD_PRICE:
			result["reason"] = "insufficient_gold"
			return false
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - EconomyCatalog.BOSS_KEY_GOLD_PRICE}):
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindGold, -EconomyCatalog.BOSS_KEY_GOLD_PRICE, gp - EconomyCatalog.BOSS_KEY_GOLD_PRICE, "boss_key_buy"):
			return false
		var next : int = sql.AddCharacterBossKeys(charID, 1)
		if next < 0:
			return false
		if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindBossKey, 1, next, "boss_key_buy"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["keys"] = next
		return true):
		pass
	mutex.unlock()
	return result

func RunBossRush(charID : int, player) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected", "wins": 0, "xp": 0, "gold": 0, "chests": 0}
	if player == null or not is_instance_valid(player) or player.stat == null:
		result["reason"] = "not_online"
		return result
	if not SpendBossKey(charID, 1, "boss_rush"):
		result["reason"] = "no_key"
		return result
	var torment : int = player.tormentLevel if player is PlayerAgent else 0
	var snapshot : Dictionary = BossService.PlayerFightSnapshot(player)
	var wins : int = 0
	var totalXp : int = 0
	var totalGold : int = 0
	var totalChests : int = 0
	for i in BossService.GetBossCount():
		var level : int = BossService.GetBossLevel(player.stat.level, i) + i * EconomyCatalog.BOSS_RUSH_ESCALATION + torment * 2
		var duel : Dictionary = BossService.Resolve(snapshot, level)
		if not bool(duel.get("win", false)):
			break
		var settled : Dictionary = SettleBossResult(charID, player, i, true)
		wins += 1
		totalXp += int(settled.get("xp", 0))
		totalGold += int(settled.get("gold", 0))
		totalChests += int(settled.get("chests", 0))
	if wins == 0:
		var consolation : Dictionary = SettleBossResult(charID, player, 0, false)
		totalXp += int(consolation.get("xp", 0))
	result["ok"] = true
	result["reason"] = "ok"
	result["wins"] = wins
	result["xp"] = totalXp
	result["gold"] = totalGold
	result["chests"] = totalChests
	return result
