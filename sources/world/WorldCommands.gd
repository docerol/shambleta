extends CommandCollection
class_name WorldCommands

# Command constructor and destructor
func RegisterCommands():
	CommandManager.Register("spawn", CommandSpawn, ActorCommons.Permission.GM, "spawn <mob_name> <count>" )
	CommandManager.Register("warp", CommandWarp, ActorCommons.Permission.MODERATOR, "warp <map> <posX> <posY>" )
	CommandManager.Register("jump", CommandJump, ActorCommons.Permission.MODERATOR, "jump" )
	CommandManager.Register("goto", CommandGoto, ActorCommons.Permission.MODERATOR, "goto <player>" )
	CommandManager.Register("recall", CommandRecall, ActorCommons.Permission.MODERATOR, "recall <player>" )
	CommandManager.Register("recallnpc", CommandRecallNpc, ActorCommons.Permission.ADMIN, "recallnpc <npc_name>" )
	CommandManager.Register("disablenpc", CommandDisableNpc, ActorCommons.Permission.ADMIN, "disablenpc <npc_name>" )
	CommandManager.Register("godmode", CommandGodmode, ActorCommons.Permission.MODERATOR, "godmode <on/off>" )
	CommandManager.Register("hide", CommandHide, ActorCommons.Permission.MODERATOR, "hide <on/off>" )
	CommandManager.Register("invisible", CommandInvisible, ActorCommons.Permission.GM, "invisible <on/off>" )
	CommandManager.Register("stat", CommandStat, ActorCommons.Permission.ADMIN, "stat <entry> <value>" )
	CommandManager.Register("setstat", CommandSetStat, ActorCommons.Permission.ADMIN, "setstat <player> <entry> <value>" )
	CommandManager.Register("level", CommandSpecificStat.bind("level"), ActorCommons.Permission.ADMIN, "level <value>" )
	CommandManager.Register("experience", CommandSpecificStat.bind("experience"), ActorCommons.Permission.ADMIN, "experience <value>" )
	CommandManager.Register("gp", CommandSpecificStat.bind("gp"), ActorCommons.Permission.GM, "gp <value>" )
	CommandManager.Register("health", CommandSpecificStat.bind("health"), ActorCommons.Permission.MODERATOR, "health <value>" )
	CommandManager.Register("mana", CommandSpecificStat.bind("mana"), ActorCommons.Permission.MODERATOR, "mana <value>" )
	CommandManager.Register("stamina", CommandSpecificStat.bind("stamina"), ActorCommons.Permission.MODERATOR, "stamina <value>" )
	CommandManager.Register("speed", CommandSpecificModifier.bind("WalkSpeed"), ActorCommons.Permission.GM, "speed <value>" )
	CommandManager.Register("localbroadcast", CommandLocalBroadcast, ActorCommons.Permission.MODERATOR, "localbroadcast <text>" )
	CommandManager.Register("broadcast", CommandBroadcast, ActorCommons.Permission.MODERATOR, "broadcast <text>" )
	CommandManager.Register("quest", CommandQuest, ActorCommons.Permission.ADMIN, "quest <name> <state>" )
	CommandManager.Register("bestiary", CommandBestiary, ActorCommons.Permission.ADMIN, "bestiary <name> <state>" )
	CommandManager.Register("item", CommandItem, ActorCommons.Permission.GM, "item <name> <count> <custom>" )
	CommandManager.Register("skill", CommandSkill, ActorCommons.Permission.GM, "skill <name> <level>" )
	CommandManager.Register("killall", CommandKillAll, ActorCommons.Permission.ADMIN, "killall <filter>" )
	CommandManager.Register("kill", CommandKill, ActorCommons.Permission.MODERATOR, "kill <nick>" )
	CommandManager.Register("revive", CommandRevive, ActorCommons.Permission.MODERATOR, "revive <nick>" )
	CommandManager.Register("permission", CommandPermission, ActorCommons.Permission.ADMIN, "permission <player_name> <level>, with level: None=0, Moderator=1, GM=2, Admin=3" )
	CommandManager.Register("ipcheck", CommandIpCheck, ActorCommons.Permission.MODERATOR, "ipcheck <player_name>" )
	CommandManager.Register("kick", CommandKick, ActorCommons.Permission.MODERATOR, "kick <player_name>" )
	CommandManager.Register("ban", CommandBan, ActorCommons.Permission.GM, "ban <player_name> <time> <reason>" )
	CommandManager.Register("unban", CommandUnban, ActorCommons.Permission.GM, "unban <player_name>" )
	CommandManager.Register("banlist", CommandBanList, ActorCommons.Permission.MODERATOR, "banlist <filter>" )
	CommandManager.Register("ipban", CommandIpBan, ActorCommons.Permission.ADMIN, "ipban <ip> <reason>, use * as an octet wildcard (e.g. 192.168.*.*), never expires, remove it with ipunban" )
	CommandManager.Register("ipunban", CommandIpUnban, ActorCommons.Permission.ADMIN, "ipunban <ip>" )
	CommandManager.Register("ipbanlist", CommandIpBanList, ActorCommons.Permission.MODERATOR, "ipbanlist <filter>" )
	CommandManager.Register("whisper", CommandWhisper, ActorCommons.Permission.NONE, "whisper <player> <message>" )
	CommandManager.Register("w", CommandWhisper, ActorCommons.Permission.NONE, "w <player> <message>" )
	CommandManager.Register("query", CommandQuery, ActorCommons.Permission.NONE, "query <player>" )
	CommandManager.Register("q", CommandQuery, ActorCommons.Permission.NONE, "q <player>" )
	# SOM-IDLE: F2 idle-spike — in-game farm session control
	CommandManager.Register("farm", CommandFarm, ActorCommons.Permission.NONE, "farm <zone_id 1-40> [slot 0-5] | farm stop" )
	# SOM-IDLE: F3
	CommandManager.Register("zones", CommandZones, ActorCommons.Permission.NONE, "zones" )
	CommandManager.Register("top", CommandTop, ActorCommons.Permission.NONE, "top" )
	CommandManager.Register("vip", CommandVIP, ActorCommons.Permission.NONE, "vip | vip buy <1|2>" )
	# SOM-IDLE: F4
	CommandManager.Register("gems", CommandGems, ActorCommons.Permission.NONE, "gems" )
	CommandManager.Register("chests", CommandChests, ActorCommons.Permission.NONE, "chests" )
	CommandManager.Register("openchest", CommandOpenChest, ActorCommons.Permission.NONE, "openchest <chest_id>" )
	CommandManager.Register("trade", CommandTrade, ActorCommons.Permission.NONE, "trade <player> <item_id> [count=1]" )
	# SOM-IDLE: D3 — CS panel (procurar transação/item, fila de revisão)
	CommandManager.Register("cs_trans", CommandCsTrans, ActorCommons.Permission.GM, "cs_trans <account> [limit]" )
	CommandManager.Register("cs_item", CommandCsItem, ActorCommons.Permission.GM, "cs_item <uid>" )
	CommandManager.Register("cs_flags", CommandCsFlags, ActorCommons.Permission.GM, "cs_flags" )
	CommandManager.Register("cs_flag", CommandCsFlag, ActorCommons.Permission.GM, "cs_flag <id> <reviewed|dismissed>" )
	# SOM-IDLE: E1/E2 — guilds, auction house, seasons
	CommandManager.Register("guild", CommandGuild, ActorCommons.Permission.NONE, "guild create|join|leave|info|deposit|withdraw|levelup|top ..." )
	CommandManager.Register("ah", CommandAH, ActorCommons.Permission.NONE, "ah list|buy|cancel|browse ..." )
	CommandManager.Register("season", CommandSeason, ActorCommons.Permission.NONE, "season active|board ..." )
	# Fase F: copas semanais (inscrição em gold, prêmios em gems + título).
	CommandManager.Register("tournament", CommandTournament, ActorCommons.Permission.NONE, "tournament info|enter" )
	# Sinks voluntários (sem wipe): corrupção (risco), cubagem 3:1, desmanche.
	CommandManager.Register("corrupt", CommandCorrupt, ActorCommons.Permission.NONE, "corrupt <item_id>" )
	CommandManager.Register("cube", CommandCube, ActorCommons.Permission.NONE, "cube <item_id>" )
	CommandManager.Register("salvage", CommandSalvage, ActorCommons.Permission.NONE, "salvage <item_id>" )
	# Conquistas one-time (sem wipe): lista progresso + resgata recompensa.
	CommandManager.Register("ach", CommandAch, ActorCommons.Permission.NONE, "ach list|claim <id>" )
	# Tormento (D2): dificuldade opt-in com mais recompensa; boss rush com key.
	CommandManager.Register("torment", CommandTorment, ActorCommons.Permission.NONE, "torment [0..max]" )
	CommandManager.Register("rush", CommandRush, ActorCommons.Permission.NONE, "rush info|start|key" )
	# SOM-IDLE Fase H: GM review of player-crafted item submissions
	CommandManager.Register("cs_craft", CommandCsCraft, ActorCommons.Permission.GM, "cs_craft <list|approve <id>|reject <id> [reason]>" )

static func UnregisterCommands():
	CommandManager.Unregister("spawn")
	CommandManager.Unregister("warp")
	CommandManager.Unregister("jump")
	CommandManager.Unregister("goto")
	CommandManager.Unregister("recall")
	CommandManager.Unregister("recallnpc")
	CommandManager.Unregister("disablenpc")
	CommandManager.Unregister("godmode")
	CommandManager.Unregister("hide")
	CommandManager.Unregister("invisible")
	CommandManager.Unregister("stat")
	CommandManager.Unregister("setstat")
	CommandManager.Unregister("level")
	CommandManager.Unregister("experience")
	CommandManager.Unregister("gp")
	CommandManager.Unregister("health")
	CommandManager.Unregister("mana")
	CommandManager.Unregister("stamina")
	CommandManager.Unregister("speed")
	CommandManager.Unregister("localbroadcast")
	CommandManager.Unregister("broadcast")
	CommandManager.Unregister("quest")
	CommandManager.Unregister("bestiary")
	CommandManager.Unregister("item")
	CommandManager.Unregister("skill")
	CommandManager.Unregister("killall")
	CommandManager.Unregister("kill")
	CommandManager.Unregister("revive")
	CommandManager.Unregister("permission")
	CommandManager.Unregister("ipcheck")
	CommandManager.Unregister("kick")
	CommandManager.Unregister("ban")
	CommandManager.Unregister("unban")
	CommandManager.Unregister("banlist")
	CommandManager.Unregister("ipban")
	CommandManager.Unregister("ipunban")
	CommandManager.Unregister("ipbanlist")
	CommandManager.Unregister("whisper")
	CommandManager.Unregister("w")
	CommandManager.Unregister("query")
	CommandManager.Unregister("q")
	# SOM-IDLE: F2
	CommandManager.Unregister("farm")
	# SOM-IDLE: F3
	CommandManager.Unregister("zones")
	CommandManager.Unregister("top")
	CommandManager.Unregister("vip")
	# SOM-IDLE: F4
	CommandManager.Unregister("chests")
	CommandManager.Unregister("openchest")
	CommandManager.Unregister("trade")
	CommandManager.Unregister("gems")
	# SOM-IDLE: D3
	CommandManager.Unregister("cs_trans")
	CommandManager.Unregister("cs_item")
	CommandManager.Unregister("cs_flags")
	CommandManager.Unregister("cs_flag")
	# SOM-IDLE: E1/E2
	CommandManager.Unregister("guild")
	CommandManager.Unregister("ah")
	CommandManager.Unregister("season")
	CommandManager.Unregister("tournament")
	CommandManager.Unregister("corrupt")
	CommandManager.Unregister("cube")
	CommandManager.Unregister("salvage")
	CommandManager.Unregister("ach")
	CommandManager.Unregister("torment")
	CommandManager.Unregister("rush")
	# SOM-IDLE Fase H
	CommandManager.Unregister("cs_craft")

# SOM-IDLE: F3 — zone map listing with power gates ("/zones")
func CommandZones(caller : PlayerAgent) -> bool:
	if not caller:
		return false

	var power : int = Formula.GetPowerScore(caller.stat)
	var list : PackedStringArray = PackedStringArray()
	list.append("Zones (your power %d):" % power)
	for zoneID in range(1, FarmZoneData.GetZoneCount() + 1):
		var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
		if zone == null:
			continue
		var locked : bool = zone.tier > 1 and power < zone.minPower
		list.append("#%d %s — T%d %s (power %d)" % [zoneID, zone.mapName, zone.tier, "LOCKED" if locked else "OPEN", zone.minPower])
	Network.CommandFeedback("\n".join(list), caller.peerID)
	return true

# SOM-IDLE: F3 — power score leaderboard ("/top")
func CommandTop(caller : PlayerAgent) -> bool:
	if not caller:
		return false
	Network.GetLeaderboard(caller.peerID)
	return true

# SOM-IDLE: F3 — VIP status ("/vip"); F4 extends it with the gems checkout
func CommandVIP(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false

	# "/vip buy 1|2" — purchase VIP with gems (EconomyService enforces the cost)
	var buyParts : PackedStringArray = arg.strip_edges().to_lower().split(" ", false)
	if buyParts.size() == 2 and buyParts[0] == "buy":
		var tier : int = buyParts[1].to_int()
		var accountID : int = Peers.GetAccount(caller.peerID)
		if accountID == NetworkCommons.PeerUnknownID:
			Network.CommandFeedback("No account bound", caller.peerID)
			return false
		if Launcher.Economy.PurchaseVIP(accountID, tier):
			var until : int = Launcher.SQL.GetVIPUntil(accountID)
			Network.CommandFeedback("VIP%d active until %s (idle faucet x%.1f)" % [tier, Time.get_datetime_string_from_unix_time(until), OfflineSettle.VIPModFactor], caller.peerID)
			return true
		Network.CommandFeedback("Purchase failed: not enough gems (%d/%d)" % [Launcher.Economy.GetGems(accountID), 440 if tier == 1 else 880], caller.peerID)
		return false

	Network.GetVIPState(caller.peerID)
	return true

# SOM-IDLE: F4 — gems wallet ("/gems")
func CommandGems(caller : PlayerAgent) -> bool:
	if not caller:
		return false
	var accountID : int = Peers.GetAccount(caller.peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("No account bound", caller.peerID)
		return false
	Network.CommandFeedback("Gems: %d" % Launcher.Economy.GetGems(accountID), caller.peerID)
	return true

# SOM-IDLE: F4 — chest listing and opening ("/chests", "/openchest <id>")
func CommandChests(caller : PlayerAgent) -> bool:
	if not caller:
		return false
	var chests : Array[Dictionary] = Launcher.SQL.GetClosedChests(caller.GetCharacterID())
	if chests.is_empty():
		Network.CommandFeedback("No closed chests (earn them by offline settles)", caller.peerID)
		return true
	var list : PackedStringArray = PackedStringArray()
	list.append("Closed chests: %s" % ", ".join(chests.map(func(c : Dictionary) -> String: return str(c["id"]))))
	# SOM-IDLE B2: odds públicas antes de abrir (compliance loot box).
	list.append("Odds: " + Launcher.Economy.FormatChestOdds(Launcher.Economy.GetChestOddsForCharacter(caller.GetCharacterID())))
	Network.CommandFeedback("\n".join(list), caller.peerID)
	return true

func CommandOpenChest(caller : PlayerAgent, chestArg : String = "") -> bool:
	if not caller:
		return false
	var chestID : int = chestArg.strip_edges().to_int()
	if chestID <= 0:
		Network.CommandFeedback("Usage: /openchest <chest_id> (see /chests)", caller.peerID)
		return false
	var result : Dictionary = Launcher.Economy.OpenChest(caller.GetCharacterID(), chestID)
	if result.is_empty():
		Network.CommandFeedback("Could not open chest %d (not yours or already opened)" % chestID, caller.peerID)
		return false
	var itemName : String = "?"
	var cell : ItemCell = DB.ItemsDB.get(int(result["item_id"]), null)
	if cell != null:
		itemName = cell._name
	var pityTag : String = " [PITY!]" if bool(result["pity"]) else ""
	Network.CommandFeedback("Chest %d opened: %s x%d%s" % [chestID, itemName, int(result["count"]), pityTag], caller.peerID)
	return true

# SOM-IDLE: F4 — direct item trade, atomic with a fee burn ("/trade <player> <item_id> [count]")
func CommandTrade(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.size() < 2:
		Network.CommandFeedback("Usage: /trade <player> <item_id> [count=1] (fee: %d gems, paid by you)" % EconomyCatalog.TradeFeeGems, caller.peerID)
		return false
	var targetNick : String = parts[0]
	var itemID : int = parts[1].to_int()
	var count : int = parts[2].to_int() if parts.size() > 2 else 1
	if itemID <= 0 or count <= 0:
		Network.CommandFeedback("Invalid item or count", caller.peerID)
		return false

	# Only characters of OTHER accounts can be trade targets (no self-trade)
	if Launcher.SQL.HasCharacter(targetNick):
		var targetCharID : int = Launcher.SQL.GetCharacterIDByName(targetNick)
		if targetCharID == caller.GetCharacterID():
			Network.CommandFeedback("You cannot trade with yourself", caller.peerID)
			return false
		if Launcher.Economy.ExecuteTrade(caller.GetCharacterID(), targetCharID, [{"item_id" = itemID, "count" = count}], []):
			Network.CommandFeedback("Traded %dx item %d to %s (fee %d gems burned)" % [count, itemID, targetNick, EconomyCatalog.TradeFeeGems], caller.peerID)
			return true
		Network.CommandFeedback("Trade failed: check your items and gem balance", caller.peerID)
		return false
	Network.CommandFeedback("Player '%s' not found" % targetNick, caller.peerID)
	return false

# SOM-IDLE: D3 — CS panel (thin wrappers over SQL reads; permission GM).
func CommandCsTrans(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		Network.CommandFeedback("Usage: /cs_trans <account> [limit]", caller.peerID)
		return false
	var accountID : int = Launcher.SQL.GetAccountID(parts[0])
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Account '%s' not found" % parts[0], caller.peerID)
		return false
	var limit : int = parts[1].to_int() if parts.size() > 1 else 10
	var rows : Array = Launcher.SQL.SearchLedger(accountID, limit)
	if rows.is_empty():
		Network.CommandFeedback("No transactions for %s" % parts[0], caller.peerID)
		return true
	var lines : PackedStringArray = PackedStringArray()
	for row in rows:
		lines.append("#%d %s %+d (bal %d) %s" % [int(row["id"]), str(row["kind"]), int(row["amount"]), int(row["balance_after"]), str(row["reason"])])
	Network.CommandFeedback("\n".join(lines), caller.peerID)
	return true

func CommandCsItem(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var uid : int = arg.strip_edges().to_int()
	if uid <= 0:
		Network.CommandFeedback("Usage: /cs_item <uid>", caller.peerID)
		return false
	var chain : Array = Launcher.SQL.LotHistory(uid)
	if chain.is_empty():
		Network.CommandFeedback("Lot %d not found" % uid, caller.peerID)
		return false
	var lines : PackedStringArray = PackedStringArray()
	for lot in chain:
		lines.append("uid %d: char %d item %d x%d (%s, parent %d)" % [int(lot["uid"]), int(lot["char_id"]), int(lot["item_id"]), int(lot["count"]), str(lot["reason"]), int(lot["parent_uid"])])
	Network.CommandFeedback("\n".join(lines), caller.peerID)
	return true

func CommandCsFlags(caller : PlayerAgent) -> bool:
	if not caller:
		return false
	var rows : Array = Launcher.SQL.ListFraudFlags("open")
	if rows.is_empty():
		Network.CommandFeedback("No open fraud flags", caller.peerID)
		return true
	var lines : PackedStringArray = PackedStringArray()
	for row in rows:
		lines.append("#%d %s acct %d char %d: %s" % [int(row["id"]), str(row["kind"]), int(row["account_id"]), int(row["char_id"]), str(row["detail"])])
	Network.CommandFeedback("\n".join(lines), caller.peerID)
	return true

func CommandCsFlag(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.size() < 2:
		Network.CommandFeedback("Usage: /cs_flag <id> <reviewed|dismissed>", caller.peerID)
		return false
	if Launcher.SQL.ReviewFraudFlag(parts[0].to_int(), parts[1]):
		Network.CommandFeedback("Flag #%d -> %s" % [parts[0].to_int(), parts[1]], caller.peerID)
		return true
	Network.CommandFeedback("Flag not found, already closed, or bad status", caller.peerID)
	return false

# SOM-IDLE Fase H: GM review of craft submissions (ITEM_CRAFTING.md §5).
# /cs_craft list                         — lists pending submissions
# /cs_craft approve <id>                  — approves (enters ItemsDB + drops creator item)
# /cs_craft reject <id> [reason]          — rejects (no fee refund per §5.3 policy)
func CommandCsCraft(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty() or parts[0] == "list" or parts.size() == 1:
		var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
			"SELECT id, account_id, char_id, slot, name, template_hash, tier, budget_used, rarity, submits_used, created_at FROM craft_submission WHERE status = 'pending' ORDER BY id;", [])
		if rows.is_empty():
			Network.CommandFeedback("No pending craft submissions", caller.peerID)
			return true
		var lines : PackedStringArray = PackedStringArray()
		lines.append("Pending craft submissions (%d):" % rows.size())
		for row in rows:
			lines.append("#%d acct %d char %d slot %d '%s' T%d %s budget %d resubmit %d" % [
				int(row["id"]), int(row["account_id"]), int(row["char_id"]),
				int(row["slot"]), str(row["name"]), int(row["tier"]),
				str(row["rarity"]), int(row["budget_used"]), int(row["submits_used"])])
		Network.CommandFeedback("\n".join(lines), caller.peerID)
		return true
	if parts.size() < 2:
		Network.CommandFeedback("Usage: /cs_craft <list|approve <id>|reject <id> [reason]>", caller.peerID)
		return false
	var subID : int = parts[1].to_int()
	if subID <= 0:
		Network.CommandFeedback("Invalid submission ID", caller.peerID)
		return false
	match parts[0]:
		"approve":
			if Launcher.Economy.ApproveCraftSubmission(caller, subID):
				Network.CommandFeedback("Submission #%d approved — entered drop pool" % subID, caller.peerID)
				return true
			Network.CommandFeedback("Approval failed (invalid ID or DB error)", caller.peerID)
			return false
		"reject":
			var reason : String = "rejected by GM"
			if parts.size() >= 3:
				reason = " ".join(parts.slice(2))
			if Launcher.Economy.RejectCraftSubmission(caller, subID, reason):
				Network.CommandFeedback("Submission #%d rejected: %s" % [subID, reason], caller.peerID)
				return true
			Network.CommandFeedback("Rejection failed (invalid ID or already reviewed)", caller.peerID)
			return false
		_:
			Network.CommandFeedback("Usage: /cs_craft <list|approve <id>|reject <id> [reason]>", caller.peerID)
			return false

# SOM-IDLE: E1/E2 — guilds, auction house, seasons (subcommand routers).
func CommandGuild(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		Network.CommandFeedback("Usage: /guild create <name> | join <id> | leave | info | deposit <item> <n> | withdraw <item> <n> | levelup | fastlevelup | buyslot | tag <TAG> | top", caller.peerID)
		return false
	var accountID : int = Peers.GetAccount(caller.peerID)
	var charID : int = caller.GetCharacterID()
	match parts[0]:
		"create":
			if parts.size() < 2:
				Network.CommandFeedback("Usage: /guild create <name> (cost: 5000 gold)", caller.peerID)
				return false
			var guildID : int = Launcher.Economy.CreateGuild(accountID, charID, " ".join(parts.slice(1)))
			Network.CommandFeedback("Guild created (#%d)" % guildID if guildID > 0 else "Could not create guild (name taken, already in one, or no gold)", caller.peerID)
			return guildID > 0
		"join":
			if parts.size() < 2 or not Launcher.Economy.JoinGuild(accountID, parts[1].to_int()):
				Network.CommandFeedback("Usage: /guild join <id>", caller.peerID)
				return false
			Network.CommandFeedback("Joined guild #%s" % parts[1], caller.peerID)
			return true
		"leave":
			if Launcher.Economy.LeaveGuild(accountID):
				Network.CommandFeedback("You left the guild", caller.peerID)
				return true
			Network.CommandFeedback("Could not leave (vault must be empty to disband)", caller.peerID)
			return false
		"info":
			var guildID : int = Launcher.Economy.GetGuildForAccount(accountID)
			if guildID == 0:
				Network.CommandFeedback("You are in no guild", caller.peerID)
				return true
			var guild : Dictionary = Launcher.Economy.GetGuild(guildID)
			Network.CommandFeedback("Guild %s (#%d): level %d, %d points, your rank: %s" % [str(guild.get("name", "?")), guildID, int(guild.get("level", 1)), int(guild.get("points", 0)), Launcher.Economy.GetMemberRank(accountID)], caller.peerID)
			return true
		"deposit":
			if parts.size() < 3 or not Launcher.Economy.DepositToVault(accountID, charID, parts[1].to_int(), parts[2].to_int()):
				Network.CommandFeedback("Usage: /guild deposit <item> <count>", caller.peerID)
				return false
			Network.CommandFeedback("Deposited %sx item %s" % [parts[2], parts[1]], caller.peerID)
			return true
		"withdraw":
			if parts.size() < 3 or not Launcher.Economy.WithdrawFromVault(accountID, charID, parts[1].to_int(), parts[2].to_int()):
				Network.CommandFeedback("Usage: /guild withdraw <item> <count> (officers+)", caller.peerID)
				return false
			Network.CommandFeedback("Withdrew %sx item %s" % [parts[2], parts[1]], caller.peerID)
			return true
		"levelup":
			if Launcher.Economy.LevelUpGuild(accountID, charID):
				Network.CommandFeedback("Guild leveled up", caller.peerID)
				return true
			Network.CommandFeedback("Could not level up (officers+, check gold/gems)", caller.peerID)
			return false
		"fastlevelup":
			var fast : Dictionary = Launcher.Economy.LevelUpGuildFast(accountID, charID)
			Network.CommandFeedback("Guild leveled up (fast, %d gems)" % int(fast.get("cost", 0)) if bool(fast.get("ok", false)) else "Fast level-up failed (%s)" % str(fast.get("reason", "?")), caller.peerID)
			return bool(fast.get("ok", false))
		"buyslot":
			var bs : Dictionary = Launcher.Economy.BuyVaultSlots(accountID, charID)
			Network.CommandFeedback("Vault slots: %d" % int(bs.get("slots", 0)) if bool(bs.get("ok", false)) else "Vault slot failed (%s)" % str(bs.get("reason", "?")), caller.peerID)
			return bool(bs.get("ok", false))
		"tag":
			if parts.size() < 2:
				Network.CommandFeedback("Usage: /guild tag <2-5 A-Z0-9> (leader only)", caller.peerID)
				return false
			var tg : Dictionary = Launcher.Economy.SetGuildTag(accountID, parts[1])
			Network.CommandFeedback("Guild tag: [%s]" % str(tg.get("tag", "")) if bool(tg.get("ok", false)) else "Tag failed (%s)" % str(tg.get("reason", "?")), caller.peerID)
			return bool(tg.get("ok", false))
		"top":
			var rows : Array = Launcher.Economy.GetGuildLeaderboard(10)
			if rows.is_empty():
				Network.CommandFeedback("No guilds yet", caller.peerID)
				return true
			var lines : PackedStringArray = PackedStringArray()
			for row in rows:
				lines.append("#%d %s — Lv%d, %d pts, %d members" % [int(row["guild_id"]), str(row["name"]), int(row["level"]), int(row["points"]), int(row["members"])])
			Network.CommandFeedback("\n".join(lines), caller.peerID)
			return true
	Network.CommandFeedback("Unknown /guild subcommand", caller.peerID)
	return false

func CommandAH(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		Network.CommandFeedback("Usage: /ah list <item> <n> <price> | buy <id> | cancel <id> | browse | highlight <id> | buyslot", caller.peerID)
		return false
	var charID : int = caller.GetCharacterID()
	match parts[0]:
		"list":
			if parts.size() < 4:
				Network.CommandFeedback("Usage: /ah list <item> <count> <price_gold> (fee: 5 gems)", caller.peerID)
				return false
			var listing : int = Launcher.Economy.ListItemForSale(charID, parts[1].to_int(), parts[2].to_int(), parts[3].to_int())
			Network.CommandFeedback("Listed (#%d)" % listing if listing > 0 else "Could not list (stock, gems, or 5 open max)", caller.peerID)
			return listing > 0
		"buy":
			if parts.size() < 2 or not Launcher.Economy.BuyListing(charID, parts[1].to_int()):
				Network.CommandFeedback("Usage: /ah buy <id>", caller.peerID)
				return false
			Network.CommandFeedback("Bought listing #%s" % parts[1], caller.peerID)
			return true
		"cancel":
			if parts.size() < 2 or not Launcher.Economy.CancelListing(charID, parts[1].to_int()):
				Network.CommandFeedback("Usage: /ah cancel <id> (your listings only)", caller.peerID)
				return false
			Network.CommandFeedback("Listing #%s cancelled (items back, fee kept)" % parts[1], caller.peerID)
			return true
		"browse":
			var rows : Array = Launcher.Economy.BrowseListings(20)
			if rows.is_empty():
				Network.CommandFeedback("No open listings", caller.peerID)
				return true
			var lines : PackedStringArray = PackedStringArray()
			for row in rows:
				var star : String = "★ " if int(row.get("highlight", 0)) == 1 else ""
				lines.append("%s#%d: %dx item %d — %d gold" % [star, int(row["id"]), int(row["count"]), int(row["item_id"]), int(row["price_gold"])])
			Network.CommandFeedback("\n".join(lines), caller.peerID)
			return true
		"highlight":
			if parts.size() < 2:
				Network.CommandFeedback("Usage: /ah highlight <id> (fee: 15 gems, yours only)", caller.peerID)
				return false
			var hl : Dictionary = Launcher.Economy.HighlightListing(Peers.GetAccount(caller.peerID), parts[1].to_int())
			Network.CommandFeedback("Listing #%s highlighted" % parts[1] if bool(hl.get("ok", false)) else "Highlight failed (%s)" % str(hl.get("reason", "?")), caller.peerID)
			return bool(hl.get("ok", false))
		"buyslot":
			var sl : Dictionary = Launcher.Economy.BuyAHSlot(Peers.GetAccount(caller.peerID))
			Network.CommandFeedback("AH slots: %d open max" % int(sl.get("slots", 0)) if bool(sl.get("ok", false)) else "AH slot failed (%s)" % str(sl.get("reason", "?")), caller.peerID)
			return bool(sl.get("ok", false))
	Network.CommandFeedback("Unknown /ah subcommand", caller.peerID)
	return false

# Sinks voluntários (sem wipe): /corrupt arrisca 1 unidade (fee em gold;
# brick 25% / sealed 30% soulbound / blessed 30% essência / exalted 15% tier+1),
# /cube funde 3 iguais em 1 de tier+1, /salvage desmancha por gold (+essência T4+).
func CommandCorrupt(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		Network.CommandFeedback("Usage: /corrupt <item_id> (fee burns gold; sealed items can't be corrupted)", caller.peerID)
		return false
	var r : Dictionary = Launcher.Economy.CorruptItem(caller.GetCharacterID(), parts[0].to_int())
	if not bool(r.get("ok", false)):
		Network.CommandFeedback("Corrupt failed (%s)" % str(r.get("reason", "?")), caller.peerID)
		return false
	match str(r.get("outcome", "?")):
		"brick":
			Network.CommandFeedback("The altar consumes the item. Nothing remains.", caller.peerID)
		"sealed":
			Network.CommandFeedback("Sealed: the item survives, soulbound forever (no trade, no re-corrupt).", caller.peerID)
		"blessed":
			Network.CommandFeedback("Blessed: +%d essence." % int(r.get("essence", 0)), caller.peerID)
		_:
			Network.CommandFeedback("EXALTED: %s!" % str(r.get("prize_name", "?")), caller.peerID)
	return true

func CommandCube(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		Network.CommandFeedback("Usage: /cube <item_id> (needs 3 unbound units, grants tier+1)", caller.peerID)
		return false
	var r : Dictionary = Launcher.Economy.CubeUpcycle(caller.GetCharacterID(), parts[0].to_int())
	if not bool(r.get("ok", false)):
		Network.CommandFeedback("Cube failed (%s)" % str(r.get("reason", "?")), caller.peerID)
		return false
	Network.CommandFeedback("Cubed into: %s!" % str(r.get("prize_name", "?")), caller.peerID)
	return true

func CommandSalvage(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		Network.CommandFeedback("Usage: /salvage <item_id> (destroys 1 unit for gold; T4+ also gives essence)", caller.peerID)
		return false
	var r : Dictionary = Launcher.Economy.SalvageItem(caller.GetCharacterID(), parts[0].to_int())
	if not bool(r.get("ok", false)):
		Network.CommandFeedback("Salvage failed (%s)" % str(r.get("reason", "?")), caller.peerID)
		return false
	if int(r.get("essence", 0)) > 0:
		Network.CommandFeedback("Salvaged: +%d gold, +%d essence." % [int(r.get("gold", 0)), int(r.get("essence", 0))], caller.peerID)
	else:
		Network.CommandFeedback("Salvaged: +%d gold." % int(r.get("gold", 0)), caller.peerID)
	return true

# Conquistas: /ach list mostra id, progresso/meta e resgatado; /ach claim <id>
# resgata gems (+cosmético no topo). Sem wipe, sem poder direto.
func CommandAch(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	var accountID : int = Peers.GetAccount(caller.peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Not logged in", caller.peerID)
		return false
	if parts.is_empty() or parts[0] == "list":
		var rows : Array = Launcher.Economy.GetAchievements(accountID)
		if rows.is_empty():
			Network.CommandFeedback("No achievements yet", caller.peerID)
			return true
		var lines : PackedStringArray = PackedStringArray()
		for row in rows:
			var mark : String = "✓ " if bool(row.get("claimed", false)) else ""
			lines.append("%s%s: %d/%d — %s" % [mark, str(row.get("id", "?")), int(row.get("progress", 0)), int(row.get("goal", 0)), str(row.get("label", "?"))])
		Network.CommandFeedback("\n".join(lines), caller.peerID)
		return true
	if parts[0] == "claim" and parts.size() >= 2:
		var r : Dictionary = Launcher.Economy.ClaimAchievement(accountID, parts[1])
		if not bool(r.get("ok", false)):
			Network.CommandFeedback("Claim failed (%s)" % str(r.get("reason", "?")), caller.peerID)
			return false
		var extra : String = " + %s" % EconomyService.CosmeticLabel(str(r.get("cosmetic", ""))) if not str(r.get("cosmetic", "")).is_empty() else ""
		Network.CommandFeedback("Achievement claimed: +%d gems%s!" % [int(r.get("gems", 0)), extra], caller.peerID)
		return true
	Network.CommandFeedback("Usage: /ach list | /ach claim <id>", caller.peerID)
	return false

# Tormento (D2): /torment mostra nível/teto/mult; /torment <n> troca (0..teto).
# Desbloqueio: zerar a escada libera T1; vencer no teto sobe +1 (cap 10).
func CommandTorment(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var charID : int = caller.GetCharacterID()
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		var level : int = Launcher.SQL.GetTormentLevel(charID)
		var tmax : int = Launcher.SQL.GetTormentMax(charID)
		Network.CommandFeedback("Torment %d (max %d): reward x%.2f, mobs x%.2f HP / x%.2f dmg" % [level, tmax, Formula.TormentRewardMult(level), Formula.TormentMobHpFactor(level), Formula.TormentMobDmgFactor(level)], caller.peerID)
		return true
	var r : Dictionary = Launcher.Economy.SetTorment(charID, caller, parts[0].to_int())
	Network.CommandFeedback("Torment %d active" % int(r.get("level", 0)) if bool(r.get("ok", false)) else "Torment locked (%s, max %d)" % [str(r.get("reason", "?")), Launcher.SQL.GetTormentMax(charID)], caller.peerID)
	return bool(r.get("ok", false))

# Boss rush: /rush info (keys, recorde), /rush start (1 key, até 4 duelos
# simulados escalados, para na 1ª derrota), /rush key (compra por gold).
func CommandRush(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	var charID : int = caller.GetCharacterID()
	var accountID : int = Peers.GetAccount(caller.peerID)
	if parts.is_empty() or parts[0] == "info":
		Network.CommandFeedback("Boss rush: %d keys, %d/4 beaten, key = %d gold (/rush key)" % [Launcher.SQL.GetCharacterBossKeys(charID), Launcher.SQL.GetCharacterBossesBeaten(charID), EconomyCatalog.BOSS_KEY_GOLD_PRICE], caller.peerID)
		return true
	if parts[0] == "key":
		var r : Dictionary = Launcher.Economy.BuyBossKey(charID)
		Network.CommandFeedback("Boss key bought (%d keys)" % int(r.get("keys", 0)) if bool(r.get("ok", false)) else "Key buy failed (%s)" % str(r.get("reason", "?")), caller.peerID)
		return bool(r.get("ok", false))
	if parts[0] == "start":
		var r : Dictionary = Launcher.Economy.RunBossRush(charID, caller)
		if not bool(r.get("ok", false)):
			Network.CommandFeedback("Rush failed (%s)" % str(r.get("reason", "?")), caller.peerID)
			return false
		Network.CommandFeedback("Rush: %d wins, +%d xp, +%d gold, %d chests" % [int(r.get("wins", 0)), int(r.get("xp", 0)), int(r.get("gold", 0)), int(r.get("chests", 0))], caller.peerID)
		return true
	Network.CommandFeedback("Usage: /rush info|start|key", caller.peerID)
	return false

# Fase F: copa semanal (inscrição em gold, rank por ganho de power).
func CommandTournament(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	var accountID : int = Peers.GetAccount(caller.peerID)
	var charID : int = caller.GetCharacterID()
	if parts.is_empty() or parts[0] == "info":
		var t : Dictionary = Launcher.Economy.GetTournaments(accountID)
		var active : Dictionary = t.get("active", {})
		if active.is_empty():
			Network.CommandFeedback("No active tournament", caller.peerID)
			return true
		Network.CommandFeedback("%s: %d players, entry %d gold, ends %s" % [str(active.get("name", "?")), int(active.get("players", 0)), int(active.get("entry_gold", 0)), Time.get_datetime_string_from_unix_time(int(active.get("ends_at", 0)))], caller.peerID)
		return true
	if parts[0] == "enter":
		var t2 : Dictionary = Launcher.Economy.GetTournaments(accountID)
		var active2 : Dictionary = t2.get("active", {})
		if active2.is_empty():
			Network.CommandFeedback("No active tournament", caller.peerID)
			return false
		var res : Dictionary = Launcher.Economy.EnterTournament(accountID, charID, int(active2.get("id", 0)))
		Network.CommandFeedback("Entered the cup (power snapshot taken)" if bool(res.get("ok", false)) else "Enter failed (%s)" % str(res.get("reason", "?")), caller.peerID)
		return bool(res.get("ok", false))
	Network.CommandFeedback("Usage: /tournament info|enter", caller.peerID)
	return false

func CommandSeason(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		Network.CommandFeedback("Usage: /season active | board <power|spend> (GMs: create <days> | close)", caller.peerID)
		return false
	match parts[0]:
		"active":
			var season : Dictionary = Launcher.Economy.ActiveSeason()
			if season.is_empty():
				Network.CommandFeedback("No active season", caller.peerID)
				return true
			Network.CommandFeedback("Season #%d ends %s" % [int(season["season_id"]), Time.get_datetime_string_from_unix_time(int(season["ends_at"]))], caller.peerID)
			return true
		"board":
			if parts.size() < 2:
				Network.CommandFeedback("Usage: /season board <power|spend|boss_kills|guild_points> (GMs: create <days> | close)", caller.peerID)
				return false
			var season2 : Dictionary = Launcher.Economy.ActiveSeason()
			if season2.is_empty():
				Network.CommandFeedback("No active season", caller.peerID)
				return false
			var rows : Array = Launcher.Economy.GetSeasonBoard(int(season2["season_id"]), parts[1], 10)
			if rows.is_empty():
				Network.CommandFeedback("Empty board (snapshot pending)", caller.peerID)
				return true
			var lines : PackedStringArray = PackedStringArray()
			for row in rows:
				lines.append("%d: %d" % [int(row["subject_id"]), int(row["value"])])
			Network.CommandFeedback("\n".join(lines), caller.peerID)
			return true
		"create", "close":
			if Peers.GetPermission(caller.peerID) < ActorCommons.Permission.GM:
				Network.CommandFeedback("GMs only", caller.peerID)
				return false
			if parts[0] == "create":
				if parts.size() < 2:
					Network.CommandFeedback("Usage: /season create <days>", caller.peerID)
					return false
				var seasonID : int = Launcher.Economy.CreateSeason(parts[1].to_int())
				if seasonID == -1:
					Network.CommandFeedback("Seasons disabled in beta (SOM-IDLE T5)", caller.peerID)
					return false
				Network.CommandFeedback("Season #%d started" % seasonID if seasonID > 0 else "Could not create (one already active?)", caller.peerID)
				return seasonID > 0
			var season3 : Dictionary = Launcher.Economy.ActiveSeason()
			if season3.is_empty() or not Launcher.Economy.CloseSeason(int(season3["season_id"])):
				Network.CommandFeedback("No active season to close", caller.peerID)
				return false
			Network.CommandFeedback("Season closed", caller.peerID)
			return true
	Network.CommandFeedback("Unknown /season subcommand", caller.peerID)
	return false

# SOM-IDLE: F2 — start/stop an idle farming session ("/farm <zone>" / "/farm stop")
func CommandFarm(caller : PlayerAgent, zoneArg : String = "") -> bool:
	if not caller:
		return false

	var arg : String = zoneArg.strip_edges().to_lower()
	if arg == "stop" or arg == "off":
		caller.autoIdleEnabled = false
		if caller.idlePolicy:
			IdlePolicyService.StopIdleSession(caller)
			Network.CommandFeedback("Idle farming stopped (auto-idle off)", caller.peerID)
			return true
		Network.CommandFeedback("No active farming session (auto-idle off)", caller.peerID)
		return false

	var zoneID : int = arg.to_int()
	var formSlot : int = 0
	# "/farm 5 2" — zone 5 with formation slot 2
	if arg.contains(" "):
		var parts : PackedStringArray = arg.split(" ", false)
		zoneID = parts[0].to_int()
		if parts.size() > 1:
			formSlot = parts[1].to_int()
	if zoneID <= 0:
		Network.CommandFeedback("Usage: /farm <zone_id 1-40> | /farm stop", caller.peerID)
		return false

	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone == null or zone.mapID == DB.UnknownHash:
		Network.CommandFeedback("Zone %d is not available in this spike" % zoneID, caller.peerID)
		return false

	if zone.tier > 1 and Formula.GetPowerScore(caller.stat) < zone.minPower:
		Network.CommandFeedback("Zone %d requires power %d" % [zoneID, zone.minPower], caller.peerID)
		return false

	Launcher.SQL.SetCharacterFormationSlot(caller.GetCharacterID(), clampi(formSlot, 0, IdlePolicyService.MaxFormationSlots - 1))
	Launcher.SQL.SetCharacterFarmZone(caller.GetCharacterID(), zoneID)
	caller.autoIdleEnabled = true
	var started : bool = IdlePolicyService.StartIdleSession(caller, zoneID)
	if not started:
		Network.CommandFeedback("Could not start farming zone %d" % zoneID, caller.peerID)
	return started

# Spawn 'x' times a specific monster near the calling player
func CommandSpawn(caller : PlayerAgent, entityName : String, countStr : String = "1") -> bool:
	if not caller:
		return false

	var count : int = countStr.to_int()
	if count <= 0:
		return false

	var entityID : int = entityName.hash()
	var entity : EntityData = DB.EntitiesDB.get(entityID, null)
	if not entity:
		return false

	var spawnedAgents : Array[MonsterAgent] = NpcCommons.Spawn(caller, entityID, count, caller.position, Vector2(200, 200))
	return not spawnedAgents.is_empty()

# Warp the current player to a specific map
func CommandWarp(caller : PlayerAgent, mapName : String, positionXStr : String = "0", positionYStr : String = "0") -> bool:
	if not caller:
		return false

	var mapID : int = mapName.hash()
	var map : WorldMap = Launcher.World.GetMap(mapID)
	if map:
		var mapPos : Vector2i = Vector2i(positionXStr.to_int(), positionYStr.to_int())
		if mapPos == Vector2i.ZERO:
			var inst : WorldInstance = map.instances.get(0, null)
			if inst:
				mapPos = WorldNavigation.GetRandomPosition(inst)
		Launcher.World.Warp(caller, map, mapPos, ActorCommons.Direction.UNKNOWN)
		return true
	return false

# Jump to a random position within the current map
func CommandJump(caller : PlayerAgent) -> bool:
	if not caller:
		return false

	var map : WorldMap = WorldAgent.GetMapFromAgent(caller)
	if not map:
		return false

	return CommandWarp(caller, map.name)

# Warp the current player to a specific player or NPC
func CommandGoto(caller : PlayerAgent, nickname : String) -> bool:
	if not caller:
		return false

	var target : BaseAgent = Launcher.World.GetGlobalPlayer(nickname)
	if target:
		var targetInst : WorldInstance = WorldAgent.GetInstanceFromAgent(target)
		if targetInst:
			Launcher.World.Warp(caller, targetInst.map, target.position, ActorCommons.Direction.UNKNOWN, targetInst.id)
		return true

	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(caller)
	if inst:
		for npc in inst.npcs:
			if npc and npc.nick == nickname:
				Launcher.World.Warp(caller, inst.map, npc.position, ActorCommons.Direction.UNKNOWN, inst.id)
				return true

	target = Launcher.World.GetGlobalNpc(nickname)
	if target:
		var targetInst : WorldInstance = WorldAgent.GetInstanceFromAgent(target)
		if targetInst:
			Launcher.World.Warp(caller, targetInst.map, target.position, ActorCommons.Direction.UNKNOWN, targetInst.id)
		return true

	Network.CommandFeedback("Player or NPC '%s' not found" % nickname, caller.peerID)
	return false

# Recall a player to the caller's position
func CommandRecall(caller : PlayerAgent, nickname : String) -> bool:
	if not caller:
		return false

	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(nickname)
	if not target:
		Network.CommandFeedback("Player '%s' is disconnected" % nickname, caller.peerID)
		return false

	var callerInst : WorldInstance = WorldAgent.GetInstanceFromAgent(caller)
	if callerInst:
		Launcher.World.Warp(target, callerInst.map, caller.position, ActorCommons.Direction.UNKNOWN, callerInst.id)
	return true

# Recall an NPC to the caller's position
func CommandRecallNpc(caller : PlayerAgent, npcName : String) -> bool:
	if not caller:
		return false

	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(caller)
	if not inst:
		return false

	for npc in inst.npcs:
		if npc and npc.nick == npcName:
			RecallAgent(npc, caller.position)
			return true

	Network.CommandFeedback("NPC '%s' not found in current instance" % npcName, caller.peerID)
	return false

# Disable an NPC in the current instance
func CommandDisableNpc(caller : PlayerAgent, npcName : String) -> bool:
	if not caller:
		return false

	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(caller)
	if not inst:
		return false

	for npc in inst.npcs:
		if npc and npc.nick == npcName:
			npc.spawnInfo = null
			WorldAgent.RemoveAgent(npc)
			return true

	Network.CommandFeedback("NPC '%s' not found in current instance" % npcName, caller.peerID)
	return false

# Modifiers
func CommandGodmode(caller : PlayerAgent, toggleStr : String) -> bool:
	if not caller:
		return false

	if toggleStr == "on":
		return CommandSpecificModifier(caller, "10000", "DodgeRate")
	elif toggleStr == "off":
		return CommandSpecificModifier(caller, "-10000", "DodgeRate")
	return false

func CommandHide(caller : PlayerAgent, toggleStr : String) -> bool:
	if not caller:
		return false

	if toggleStr == "on":
		return CommandSpecificModifier(caller, "1", "Hide")
	elif toggleStr == "off":
		return CommandSpecificModifier(caller, "0", "Hide")
	return false

func CommandInvisible(caller : PlayerAgent, toggleStr : String) -> bool:
	if not caller:
		return false

	if toggleStr == "on":
		var result : bool = CommandSpecificModifier(caller, "1", "Invisible")
		if result:
			RemoveFromNearbyPlayers(caller)
		return result
	elif toggleStr == "off":
		var result : bool = CommandSpecificModifier(caller, "0", "Invisible")
		if result:
			ShowToNearbyPlayers(caller)
		return result
	return false

func RecallAgent(agent : AIAgent, pos : Vector2):
	agent.position = pos
	agent.ResetNav()
	agent.set_physics_process(true)
	agent.requireFullUpdate = true
	if agent.agent:
		agent.agent.target_position = pos

func RemoveFromNearbyPlayers(agent : PlayerAgent):
	var agentRID : int = agent.get_rid().get_id()
	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)
	if inst:
		for player in inst.players:
			if player != agent and player is PlayerAgent and player.visibleAgents.has(agentRID):
				player.visibleAgents.erase(agentRID)
				Network.Bulk("RemoveEntity", [agentRID], player.peerID)

func ShowToNearbyPlayers(agent : PlayerAgent):
	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)
	if inst:
		for player in inst.players:
			if player != agent and player is PlayerAgent:
				player.CheckVisibility(agent)

func CommandSpecificModifier(caller : PlayerAgent, valueStr : String, entry : String) -> bool:
	if not caller or not caller.stat or not caller.stat.modifiers:
		return false

	var effect : CellCommons.Modifier = CellCommons.Modifier.get(entry, CellCommons.Modifier.None)
	if effect == CellCommons.Modifier.None:
		return false

	for modifier in caller.stat.modifiers._modifiers:
		if modifier._effect == effect and modifier._command:
			caller.stat.modifiers.Remove(modifier)

	var value : float = valueStr.to_float()
	Network.CommandModifier(effect, value, caller.peerID)
	if value > 0.0:
		var modifier : StatModifier = StatModifier.new()
		modifier._effect = effect
		modifier._value = value
		modifier._persistent = true
		modifier._command = true
		caller.stat.modifiers.Add(modifier)

	caller.stat.RefreshAttributes()
	return true

# Stats
const EntityHashedStats : PackedStringArray	= ["spirit", "shape", "currentShape"]

func ApplyStat(stats : ActorStats, entry : String, valueStr : String) -> bool:
	if entry in EntityHashedStats:
		var entityID : int = valueStr.hash()
		if not DB.EntitiesDB.has(entityID):
			return false
		stats[entry] = entityID
	else:
		match typeof(stats[entry]):
			TYPE_INT:	stats[entry] += valueStr.to_int()
			TYPE_FLOAT:	stats[entry] += valueStr.to_float()
			_:			return false

	stats.RefreshAttributes()
	return true

func CommandStat(caller : PlayerAgent, entry : String, valueStr : String) -> bool:
	return CommandSpecificStat(caller, valueStr, entry)

func CommandSpecificStat(caller : PlayerAgent, valueStr : String, entry : String) -> bool:
	if not caller or not caller.stat or entry not in caller.stat:
		return false

	return ApplyStat(caller.stat, entry, valueStr)

func CommandSetStat(caller : PlayerAgent, nickname : String, entry : String, valueStr : String) -> bool:
	if not caller:
		return false

	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(nickname)
	if not target:
		Network.CommandFeedback("Player '%s' is disconnected" % nickname, caller.peerID)
		return false

	if not target.stat or entry not in target.stat:
		Network.CommandFeedback("Stat '%s' not found" % entry, caller.peerID)
		return false

	if not ApplyStat(target.stat, entry, valueStr):
		Network.CommandFeedback("Invalid value '%s' for stat '%s'" % [valueStr, entry], caller.peerID)
		return false
	return true

# Broadcast
func CommandLocalBroadcast(caller : PlayerAgent, text : String) -> bool:
	if not caller:
		return false

	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(caller)
	if inst:
		Network.NotifyInstance(inst, "PushNotification", [text])
		return true
	return false

func CommandBroadcast(_caller : PlayerAgent, text : String) -> bool:
	Network.NotifyGlobal("PushNotification", [text])
	return true

# Progress
func CommandQuest(caller : PlayerAgent, questName : String, stateStr : String) -> bool:
	if not caller or not caller.progress or not DB.HasCellHash(questName):
		return false

	var questID : int = DB.GetCellHash(questName)
	var state : int = stateStr.to_int()
	NpcCommons.SetQuest(caller, questID, state)
	return true

func CommandBestiary(caller : PlayerAgent, monsterName : String, countStr : String) -> bool:
	if not caller or not caller.progress:
		return false

	var monsterID : int = monsterName.hash()
	var count : int = countStr.to_int()
	if monsterID in DB.EntitiesDB:
		NpcCommons.AddBestiary(caller, monsterID, count)
		return true
	return false

# Inventory
func CommandItem(caller : PlayerAgent, itemName : String, countStr : String = "1", customField : String = "") -> bool:
	if not caller or not caller.progress or not DB.HasCellHash(itemName):
		return false

	var itemID : int = itemName.hash()
	var count : int = countStr.to_int()
	if count > 0:
		return NpcCommons.AddItem(caller, itemID, count, customField)
	elif count < 0:
		return NpcCommons.RemoveItem(caller, itemID, -count, customField)
	return false

# Skills
func CommandSkill(caller : PlayerAgent, skillName : String, levelStr : String = "1") -> bool:
	if not caller or not caller.progress:
		return false

	var skillID : int = skillName.hash()
	var cell : SkillCell = DB.SkillsDB.get(skillID, null)
	if not cell:
		return false

	var level : int = levelStr.to_int()
	caller.progress.RemoveSkill(cell)
	if level > 0:
		caller.progress.AddSkill(cell, level)
	return true

# Death
func CommandKillAll(caller : PlayerAgent, filter : String = "") -> bool:
	if not caller:
		return false

	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(caller)
	if inst:
		for mob in inst.mobs:
			if mob and (filter.is_empty() or mob.nick == filter):
				mob.Kill()
	return true

func CommandKill(caller : PlayerAgent, nick : String) -> bool:
	if not caller:
		return false

	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(caller)
	if inst:
		for player in inst.players:
			if player and player.nick == nick:
				player.Kill()
				return true
	return false

func CommandRevive(caller : PlayerAgent, nick : String) -> bool:
	if not caller:
		return false

	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(caller)
	if inst:
		for player in inst.players:
			if player and player.nick == nick:
				player.Revive()
				return true
	return false

# Admin
func CommandPermission(caller : PlayerAgent, nickname : String, levelStr : String) -> bool:
	if not caller:
		return false

	var level : int = levelStr.to_int()
	if level < ActorCommons.Permission.NONE or level > ActorCommons.Permission.ADMIN:
		Network.CommandFeedback("Invalid permission level, must be between %d and %d" % [ActorCommons.Permission.NONE, ActorCommons.Permission.ADMIN], caller.peerID)
		return false

	var accountID : int = GetAccountID(nickname)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Character '%s' not found" % nickname, caller.peerID)
		return false

	return Launcher.SQL.SetPermission(accountID, level)

func CommandIpCheck(caller : PlayerAgent, nickname : String) -> bool:
	if not caller:
		return false

	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(nickname)
	if not target:
		Network.CommandFeedback("Player '%s' is disconnected" % nickname, caller.peerID)
		return false

	var peer : Peers.Peer = Peers.GetPeer(target.peerID)
	if not peer:
		Network.CommandFeedback("Player '%s' is disconnected" % nickname, caller.peerID)
		return false

	var ip : String = Peers.GetPeerIP(target.peerID)
	if ip.is_empty():
		ip = "unavailable"
	Network.CommandFeedback("IP for '%s': %s" % [nickname, ip], caller.peerID)
	return true

# Moderation
func CommandKick(caller : PlayerAgent, nickname : String) -> bool:
	if not caller:
		return false

	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(nickname)
	if not target or target.peerID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Player '%s' is not online" % nickname, caller.peerID)
		return false

	if target.peerID == caller.peerID:
		Network.CommandFeedback("Cannot kick yourself", caller.peerID)
		return false

	var server : NetServer = Peers.GetAssociatedNetServer(target.peerID)
	if not server or not server.multiplayerAPI:
		Network.CommandFeedback("Missing peer information for '%s'" % nickname, caller.peerID)
		return false

	server.multiplayerAPI.disconnect_peer(target.peerID)
	server.DisconnectPeer(target.peerID)
	Network.CommandFeedback("'%s' kicked" % nickname, caller.peerID)
	return true

func CommandBan(caller : PlayerAgent, nickname : String, durationStr : String = "1d", reason : String = "") -> bool:
	if not caller:
		return false

	var accountID : int = GetAccountID(nickname)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Character '%s' not found" % nickname, caller.peerID)
		return false

	var duration : int = Util.ParseDuration(durationStr)
	if duration <= 0:
		Network.CommandFeedback("Couldn't parse the duration", caller.peerID)
		return false

	var unbanTimestamp : int = SQLCommons.Timestamp() + duration
	if not Launcher.SQL.BanAccount(accountID, unbanTimestamp, reason):
		Network.CommandFeedback("Ban registration failed", caller.peerID)
		return false

	Peers.bannedAccounts[accountID] = unbanTimestamp

	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(nickname)
	if target:
		CommandKick(caller, nickname)

	Network.CommandFeedback("'%s' banned for %s" % [nickname, durationStr], caller.peerID)
	return true

func CommandUnban(caller : PlayerAgent, nickname : String) -> bool:
	if not caller:
		return false

	var accountID : int = Launcher.SQL.GetAccountID(nickname)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Player '%s' not found" % nickname, caller.peerID)
		return false

	if not Peers.bannedAccounts.has(accountID):
		Network.CommandFeedback("Player '%s' is not banned" % nickname, caller.peerID)
		return false

	Launcher.SQL.UnbanAccount(accountID)
	Peers.bannedAccounts.erase(accountID)
	return true

func CommandBanList(caller : PlayerAgent, filter : String = "") -> bool:
	if not caller:
		return false

	var results : Array[Dictionary] = Launcher.SQL.GetBanList(filter)
	if results.is_empty():
		Network.CommandFeedback("No active bans found", caller.peerID)
		return true

	var now : int = SQLCommons.Timestamp()
	for row in results:
		var username : String = row.get("username", "unknown")
		var remaining : int = row.get("unban_timestamp", 0) - now
		var banReason : String = row.get("reason", "")
		if banReason.is_empty():
			Network.CommandFeedback("%s: %s remaining" % [username, Util.FormatDuration(remaining)], caller.peerID)
		else:
			Network.CommandFeedback("%s: %s remaining (%s)" % [username, Util.FormatDuration(remaining), banReason], caller.peerID)
	return true

func CommandIpBan(caller : PlayerAgent, ipRange : String, reason : String = "") -> bool:
	if not caller:
		return false

	if not NetworkCommons.IsValidIPRange(ipRange):
		Network.CommandFeedback("Invalid IP, expected 4 octets with * as wildcard (e.g. 192.168.*.*)", caller.peerID)
		return false

	if not Launcher.SQL.BanIPRange(ipRange, reason):
		Network.CommandFeedback("IP ban registration failed", caller.peerID)
		return false

	Peers.bannedIPRanges[ipRange] = reason

	# Disconnect any online peer whose IP falls within the banned range
	var bannedPeers : Array[int] = []
	for peerID in Peers.peers:
		if peerID != caller.peerID and NetworkCommons.IsIPInRange(Peers.GetPeerIP(peerID), ipRange):
			bannedPeers.append(peerID)

	for peerID in bannedPeers:
		var server : NetServer = Peers.GetAssociatedNetServer(peerID)
		if server and server.multiplayerAPI:
			server.multiplayerAPI.disconnect_peer(peerID)
			server.DisconnectPeer(peerID)

	Network.CommandFeedback("IP range '%s' banned" % ipRange, caller.peerID)
	return true

func CommandIpUnban(caller : PlayerAgent, ipRange : String) -> bool:
	if not caller:
		return false

	if not Peers.bannedIPRanges.has(ipRange):
		Network.CommandFeedback("IP range '%s' is not banned" % ipRange, caller.peerID)
		return false

	Launcher.SQL.UnbanIPRange(ipRange)
	Peers.bannedIPRanges.erase(ipRange)
	Network.CommandFeedback("IP range '%s' unbanned" % ipRange, caller.peerID)
	return true

func CommandIpBanList(caller : PlayerAgent, filter : String = "") -> bool:
	if not caller:
		return false

	var results : Array[Dictionary] = Launcher.SQL.GetIPBanList(filter)
	if results.is_empty():
		Network.CommandFeedback("No IP bans found", caller.peerID)
		return true

	for row in results:
		var ipRange : String = row.get("ip_range", "unknown")
		var banReason : String = row.get("reason", "")
		if banReason.is_empty():
			Network.CommandFeedback("%s" % ipRange, caller.peerID)
		else:
			Network.CommandFeedback("%s (%s)" % [ipRange, banReason], caller.peerID)
	return true

# Private messages
func CommandWhisper(caller : PlayerAgent, channelName : String, text : String) -> bool:
	if not caller or channelName.is_empty() or text.is_empty():
		return false

	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(channelName)
	if not target:
		Network.ChatSystem(channelName, "Player '%s' is no longer online" % channelName, caller.peerID)
		return true

	if target == caller:
		Network.ChatSystem(channelName, "You cannot whisper to yourself", caller.peerID)
		return true

	Network.ChatPlayer(caller.nick, caller.nick, text, caller.get_rid().get_id(), target.peerID)
	Network.ChatPlayer(target.nick, caller.nick, text, caller.get_rid().get_id(), caller.peerID)
	return true

func CommandQuery(caller : PlayerAgent, targetName : String) -> bool:
	if not caller or targetName.is_empty():
		return false

	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(targetName)
	if not target:
		Network.CommandFeedback("Player '%s' is not online" % targetName, caller.peerID)
		return true

	if target == caller:
		Network.CommandFeedback("You cannot query yourself", caller.peerID)
		return true

	Network.ChatQuery(target.nick, caller.peerID)
	return true

# Helpers
static func GetAccountID(nickname : String) -> int:
	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(nickname)
	if target:
		return Peers.GetAccount(target.peerID)
	return Launcher.SQL.GetAccountID(nickname)
