extends CommandCollection
class_name WorldCommands

# Command constructor and destructor
# C-4: o bloco CS mora em `WorldCommandsSupport.gd`; as registraturas
# abaixo ligam os verbetes ao objeto bound — mesma contract do `Command.Call`.
var _support : WorldCommandsSupport = WorldCommandsSupport.new()

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
	# SOM-IDLE C1c: canal de denúncia do jogador e sanção que não é ban.
	CommandManager.Register("report", CommandReport, ActorCommons.Permission.NONE, "report <player> <reason>" )
	CommandManager.Register("mute", CommandMute, ActorCommons.Permission.MODERATOR, "mute <player> <time> <reason>" )
	CommandManager.Register("unmute", CommandUnmute, ActorCommons.Permission.MODERATOR, "unmute <player>" )
	CommandManager.Register("reports", CommandReports, ActorCommons.Permission.MODERATOR, "reports [limit]" )
	CommandManager.Register("resolve", CommandResolveReport, ActorCommons.Permission.MODERATOR, "resolve <report_id>" )
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
	# SOM-IDLE retenção: superfície do streak de login no chat ("/streak")
	CommandManager.Register("streak", CommandStreak, ActorCommons.Permission.NONE, "streak" )
	# SOM-IDLE: D3 — CS panel (procurar transação/item, fila de revisão)
	CommandManager.Register("cs_trans", _support.CommandCsTrans, ActorCommons.Permission.GM, "cs_trans <account> [limit]" )
	CommandManager.Register("cs_item", _support.CommandCsItem, ActorCommons.Permission.GM, "cs_item <uid>" )
	CommandManager.Register("cs_flags", _support.CommandCsFlags, ActorCommons.Permission.GM, "cs_flags [pagina]" )
	CommandManager.Register("cs_flag", _support.CommandCsFlag, ActorCommons.Permission.GM, "cs_flag <id> <reviewed|dismissed> [nota]" )
	CommandManager.Register("cs_flag_info", _support.CommandCsFlagInfo, ActorCommons.Permission.GM, "cs_flag_info <id>" )
	CommandManager.Register("cs_fraud_stats", _support.CommandCsFraudStats, ActorCommons.Permission.GM, "cs_fraud_stats" )
	# SOM-IDLE: E1/E2 — guilds, auction house, seasons
	CommandManager.Register("guild", CommandGuild, ActorCommons.Permission.NONE, "guild create|join|leave|kick|promote|demote|invite|info|deposit|withdraw|levelup|top ..." )
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
	# SOM-GAMEPLAY G1/G3: prioridade de cast do auto-combat e requisito real do
	# próximo boss da escada. Permission.NONE porque são os dois instrumentos de
	# decisão que faltavam para o farmer comum (sem eles o auto-combat é fixo e
	# a escada é caixa-preta).
	CommandManager.Register("priority", CommandPriority, ActorCommons.Permission.NONE, "priority [set <skill> ...|clear]" )
	CommandManager.Register("boss", CommandBoss, ActorCommons.Permission.NONE, "boss [next]" )
	# SOM-IDLE Fase H: GM review of player-crafted item submissions
	CommandManager.Register("cs_craft", _support.CommandCsCraft, ActorCommons.Permission.GM, "cs_craft <list|approve <id>|reject <id> [reason]>" )
	# SOM-IDLE social (AUDITORIA_2026-09-27 §14 SOCIAL): os cinco verbos do grafo, no
	# mesmo dispatcher que porta /report. ROTA DE COMANDO, não @rpc dedicado: `Server.gd`
	# não tem folga nenhuma no teto do gate anti-god-node (o número é o que
	# `scripts/check_god_nodes.sh` imprime, não este texto), e levantar ratchet para caber
	# feature é o que a régua proíbe. Permission.NONE porque amigo e bloqueio são
	# instrumentos do jogador comum; o alvo é nick resolvido pelo servidor.
	CommandManager.Register("friend", CommandFriend, ActorCommons.Permission.NONE, "friend <player>" )
	CommandManager.Register("unfriend", CommandUnfriend, ActorCommons.Permission.NONE, "unfriend <player>" )
	CommandManager.Register("ignore", CommandIgnore, ActorCommons.Permission.NONE, "ignore <player>" )
	CommandManager.Register("unignore", CommandUnignore, ActorCommons.Permission.NONE, "unignore <player>" )
	CommandManager.Register("social", CommandSocial, ActorCommons.Permission.NONE, "social [friends|ignores]" )

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
	# SOM-IDLE C1c
	CommandManager.Unregister("report")
	CommandManager.Unregister("mute")
	CommandManager.Unregister("unmute")
	CommandManager.Unregister("reports")
	CommandManager.Unregister("resolve")
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
	CommandManager.Unregister("streak")
	# SOM-IDLE: D3
	CommandManager.Unregister("cs_trans")
	CommandManager.Unregister("cs_item")
	CommandManager.Unregister("cs_flags")
	CommandManager.Unregister("cs_flag")
	CommandManager.Unregister("cs_flag_info")
	CommandManager.Unregister("cs_fraud_stats")
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
	# SOM-GAMEPLAY G1/G3
	CommandManager.Unregister("priority")
	CommandManager.Unregister("boss")
	# SOM-IDLE Fase H
	CommandManager.Unregister("cs_craft")
		# SOM-IDLE social: o par exato dos cinco verbos. Faltar o Unregister faz o
	# `RegisterCommands` da sessão seguinte morrer em "already registered".
	CommandManager.Unregister("friend")
	CommandManager.Unregister("unfriend")
	CommandManager.Unregister("ignore")
	CommandManager.Unregister("unignore")
	CommandManager.Unregister("social")

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

# P2-retenção (AUDITORIA_2026-09-27 §6 — "sem streaks em lugar nenhum"): o streak
# tem que poder ser PERGUNTADO, não só empurrado no login (a janela de retorno fica
# escondida atrás do mouse; o chat é a superfície de um MMO de texto). Nada é
# calculado aqui: `StreakService.View` relê `login_streak` e projeta a MESMA escada
# que `RecordLogin` pagou, então o número que o jogador lê é o número gravado pelo
# servidor. Cliente não manda dia, streak nem ouro.
func CommandStreak(caller : PlayerAgent) -> bool:
	if not caller:
		return false
	var state : Dictionary = StreakService.View(caller.GetCharacterID())
	var today : String = "pagou +%d de ouro" % int(state.get("today_reward", 0)) if bool(state.get("logged_today", false)) else "ainda não foi carimbado"
	var lines : PackedStringArray = PackedStringArray()
	lines.append("Streak: dia %d (melhor %d) — hoje %s." % [int(state.get("current_streak", 0)), int(state.get("best_streak", 0)), today])
	lines.append("Próximo login: dia %d paga +%d. Marco no dia %d libera +%d (faltam %d dia(s))." % [
		int(state.get("next_day", 0)), int(state.get("next_reward", 0)), int(state.get("mark_day", 0)),
		int(state.get("mark_reward", 0)), int(state.get("days_to_mark", 0))])
	lines.append("Quebrar a sequência custa %d de ouro e volta ao degrau 1. Dia do servidor em %ds." % [
		int(state.get("loss_on_break", 0)), int(state.get("reset_in_sec", 0))])
	Network.CommandFeedback("\n".join(lines), caller.peerID)
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

# SOM-IDLE: E1/E2 — guilds, auction house, seasons (subcommand routers).
func CommandGuild(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		Network.CommandFeedback("Usage: /guild create <name> | join <id> | leave | info | deposit|withdraw <item> <n> | levelup | buyslot | tag <TAG> | kick|promote|demote|invite <player> | top", caller.peerID)
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
		# AUDITORIA 2026-09-28 (administração de guilda na mão do jogador): os quatro
		# verbos de roster entram pela ROTA DE COMANDO e a política inteira mora em
		# `sources/economy/GuildRoster.gd`. Aqui só se resolve o nick (nunca o id do
		# pacote) e se devolve a frase. É o MESMO desenho de `/friend`, pelo MESMO
		# motivo medido: `Server.gd` está no teto do ratchet anti-god-node.
		"kick", "promote", "demote", "invite":
			if parts.size() < 2:
				Network.CommandFeedback("Usage: /guild <kick|promote|demote|invite> <player>", caller.peerID)
				return false
			var admin : Dictionary = GuildRoster.Command(parts[0], accountID, GetAccountID(parts[1]), parts[1])
			Network.CommandFeedback(str(admin.get("text", "")), caller.peerID)
			return bool(admin.get("ok", false))
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

# SOM-GAMEPLAY G1: /priority — o jogador DECIDE o auto-combat.
# "/priority" lista a carga efetiva; "/priority [slot <n>] set <skill> [...]" grava a
# ordem (nome da skill, hash ou ID numérico) no MESMO campo que a formação já
# persiste (formation.skill_loadout, Array[int] ordenado via var_to_str — por isso
# não houve migração nova) e aplica ao vivo na policy do farmer; "/priority clear"
# volta para melee. O cast em si obedece a ordem em IdlePolicy._getSkill().
#
# Este comando é também o caminho do PAINEL: sources/gui/Formation.gd declara a
# ordem mandando a mesma string por `Network.TriggerCommand` (o mesmo RPC do chat,
# o mesmo despachante CommandManager.Handle, que resolve o agente pelo PEER). O
# painel não tem caminho de escrita próprio — ver tests/formation_priority_ui_test.gd.
func CommandPriority(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var accountID : int = Peers.GetAccount(caller.peerID)
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("No account bound", caller.peerID)
		return false
	var charID : int = caller.GetCharacterID()
	var activeSlot : int = _FormationSlotOf(caller)
	var slot : int = activeSlot

	var parts : PackedStringArray = arg.strip_edges().to_lower().split(" ", false)
	# SOM-GAMEPLAY (juiz cego 2026-09-27): o painel de formação declara a ordem de
	# um slot específico, e um char pode ter carga em qualquer um dos
	# MaxFormationSlots slots da SUA conta. `slot <n>` é só SELETOR DE LINHA: a
	# conta continua vindo do PEER (nunca de um argumento do cliente) e o que entra
	# na carga continua sendo decidido por SkillPriority.Trim abaixo. Sem o
	# prefixo, comportamento idêntico ao de sempre (slot ativo do personagem).
	if parts.size() >= 2 and parts[0] == "slot" and parts[1].is_valid_int():
		slot = clampi(parts[1].to_int(), 0, IdlePolicyService.MaxFormationSlots - 1)
		parts.remove_at(0)
		parts.remove_at(0)
	var stored : Array[int] = _StoredLoadout(accountID, slot)

	if parts.is_empty() or parts[0] == "list":
		var names : Dictionary = _SkillNames(stored)
		var lines : PackedStringArray = PackedStringArray()
		lines.append("Skill priority (slot %d%s): %s" % [slot, "" if slot == activeSlot else ", not this char's active slot", SkillPriority.FormatOrder(stored, names)])
		lines.append("Set: /priority [slot <n>] set <skill> [skill...] (max %d) | /priority clear" % SkillPriority.MaxPrioritySkills)
		lines.append("Learned: " + _LearnedSkillNames(caller))
		Network.CommandFeedback("\n".join(lines), caller.peerID)
		return true

	if parts[0] == "clear":
		return _SavePriority(caller, accountID, slot, charID, activeSlot, [], _PriorityClearedMessage(slot))

	if parts[0] != "set" or parts.size() < 2:
		Network.CommandFeedback("Usage: /priority | /priority [slot <n>] set <skill> [skill...] | /priority clear", caller.peerID)
		return false

	var picked : Array[int] = []
	var unknown : PackedStringArray = PackedStringArray()
	for token : String in parts.slice(1):
		var skillID : int = _ResolveSkillID(token)
		if skillID == DB.UnknownHash:
			unknown.append(token)
		elif not (skillID in picked):
			picked.append(skillID)
	if picked.is_empty():
		Network.CommandFeedback("No valid skill in '%s' (use the skill name, see /priority)" % arg, caller.peerID)
		return false
	var owned : Array[int] = _LearnedSkillIDs(caller)
	var trimmed : Dictionary = SkillPriority.Trim(picked, owned)
	if (trimmed["order"] as Array[int]).is_empty():
		Network.CommandFeedback("None of those skills is learned by this character", caller.peerID)
		return false
	var message : String = "Priority set (slot %d): " % slot + SkillPriority.FormatOrder(trimmed["order"], _SkillNames(trimmed["order"]))
	if not unknown.is_empty() or (trimmed["rejected"] as Array[int]).size() > 0:
		message += "\nSkipped: " + _RejectedLabels(trimmed["rejected"], unknown)
	return _SavePriority(caller, accountID, slot, charID, activeSlot, trimmed["order"], message)

# Persiste + aplica ao vivo. Sem SaveFormation não há por que mexer em Server.gd:
# o RPC SetFormation já aceita um Array ordenado e é exatamente essa a
# serialização usada aqui.
#
# `activeSlot` é o slot que o farmer ESTÁ usando (character.formation_slot). A
# carga só entra na policy viva quando o jogador editou esse slot: mexer na
# reserva (slot 3 de um char ativo no 0) não pode trocar o golpe do tick em
# andamento — quem decide o cast é a carga do slot ativo, lida em
# IdlePolicyService._Attach na próxima sessão.
func _SavePriority(caller : PlayerAgent, accountID : int, slot : int, charID : int, activeSlot : int, order : Array[int], message : String) -> bool:
	var formation : Dictionary = Launcher.SQL.GetFormationForSlot(accountID, slot)
	var pct : float = float(formation.get("auto_potion_pct", caller.idlePolicy.autoPotionPct if caller.idlePolicy else 35.0))
	if not Launcher.SQL.SaveFormation(accountID, slot, charID, order, pct):
		Network.CommandFeedback("Could not save the priority (DB error)", caller.peerID)
		return false
	if caller.idlePolicy and slot == activeSlot:
		caller.idlePolicy.skillLoadout = order.duplicate()
	Network.CommandFeedback(message, caller.peerID)
	return true

func _PriorityClearedMessage(slot : int) -> String:
	return "Priority cleared (slot %d) — auto-combat is back to plain melee." % slot

# O slot que _Attach lê ao montar a policy (character.formation_slot, clampado).
func _FormationSlotOf(caller : PlayerAgent) -> int:
	var row : Dictionary = Launcher.SQL.GetCharacter(caller.GetCharacterID())
	var raw : Variant = row.get("formation_slot", 0)
	return clampi(int(raw) if raw != null else 0, 0, IdlePolicyService.MaxFormationSlots - 1)

func _StoredLoadout(accountID : int, slot : int) -> Array[int]:
	var loadout : Array[int] = []
	var raw : String = str(Launcher.SQL.GetFormationForSlot(accountID, slot).get("skill_loadout", ""))
	if raw.is_empty():
		return loadout
	var parsed : Variant = str_to_var(raw)
	if parsed is Array:
		for skillID : Variant in parsed:
			loadout.append(int(skillID))
	return loadout

func _ResolveSkillID(token : String) -> int:
	if token.is_empty():
		return DB.UnknownHash
	if token.is_valid_int() and DB.SkillsDB.has(token.to_int()):
		return token.to_int()
	var hash : int = token.hash()
	if DB.SkillsDB.has(hash):
		return hash
	for skillID : int in DB.SkillsDB:
		var cell : SkillCell = DB.SkillsDB[skillID]
		if cell != null and str(cell.name).to_lower() == token:
			return skillID
	return DB.UnknownHash

func _SkillNames(order : Array[int]) -> Dictionary:
	var names : Dictionary = {}
	for skillID : int in order:
		var cell : SkillCell = DB.SkillsDB.get(skillID, null)
		names[skillID] = cell.name if cell else "skill %d" % skillID
	return names

func _LearnedSkillIDs(caller : PlayerAgent) -> Array[int]:
	var learned : Array[int] = []
	for skillID : int in DB.SkillsDB:
		var cell : SkillCell = DB.SkillsDB[skillID]
		if cell != null and SkillCommons.HasSkill(caller, cell):
			learned.append(skillID)
	return learned

func _LearnedSkillNames(caller : PlayerAgent) -> String:
	var names : PackedStringArray = PackedStringArray()
	for skillID : int in _LearnedSkillIDs(caller):
		var cell : SkillCell = DB.SkillsDB[skillID]
		names.append(str(cell.name))
	return ", ".join(names) if not names.is_empty() else "(none)"

func _RejectedLabels(rejected : Array[int], unknown : PackedStringArray) -> String:
	var parts : PackedStringArray = PackedStringArray()
	if not unknown.is_empty():
		parts.append("unknown: " + ", ".join(unknown))
	if not rejected.is_empty():
		parts.append("not learned / over the cap: " + ", ".join(_SkillNames(rejected).values().map(func(v : Variant) -> String: return str(v))))
	return "; ".join(parts)

# SOM-GAMEPLAY G3: /boss — requisito REAL do próximo duelo, derivado da mesma
# simulação que decide a luta (BossService.Resolve invertido em BossLadder).
# Substitui o "gear decides" por um número que o jogador pode checar na própria
# ficha. "/boss next" imprime só a linha do próximo.
func CommandBoss(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var charID : int = caller.GetCharacterID()
	var state : Dictionary = Launcher.Economy.GetBossState(charID, caller.stat.level)
	var snapshot : Dictionary = BossService.PlayerFightSnapshot(caller)
	if arg.strip_edges().to_lower() == "next":
		var need : Dictionary = BossLadder.Requirement(state, snapshot)
		Network.CommandFeedback("%s (Lv %d, %d HP): %s" % [str(need.get("name", "?")), int(need.get("level", 1)), int(need.get("hp", 0)), BossLadder.RequirementText(need)], caller.peerID)
		return true
	Network.CommandFeedback(BossLadder.RequirementLine(state, snapshot), caller.peerID)
	return true

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
		# OPS-2 (AUDITORIA_2026-09-27 §15): gate de runtime da inscrição. Aqui o
		# ouro do jogador vira linha em `tournament_entry` e o prêmio sai em gems
		# no settle — se a copa quebrar (settle errado, prêmio duplicado), o
		# operator desliga SEM redeploy: `/flags set tournament_enter 0`. É o
		# segundo gate server-side real desta passada (o primeiro é `ads_rewarded`,
		# no client). `info` continua liberado de propósito: ver a copa e não
		# poder entrar é o estado que o player precisa conseguir inspecionar.
		if not FeatureFlags.Enabled(FeatureFlags.TOURNAMENT_ENTER):
			Network.CommandFeedback("Tournament entry is closed (operator flag)", caller.peerID)
			return false
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

# SOM-IDLE C1c (AUDITORIA §16 SOCIAL): denúncia e mute de chat. A única resposta a assédio
# no canal era /ban da CONTA inteira — não havia para onde denunciar, e não havia
# como calar alguém sem tirar o jogo. /report é Permission.NONE porque é o caminho
# legal para o moderador existir; o texto do denunciante é só um apontador, a prova
# é o trecho que o SERVIDOR viu aquele account falar (ChatModeration.Report).
func CommandReport(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false

	var parts : PackedStringArray = arg.strip_edges().split(" ", false, 1)
	if parts.size() < 2:
		Network.CommandFeedback("Usage: /report <player> <motivo>", caller.peerID)
		return false

	var targetID : int = GetAccountID(parts[0])
	if targetID <= 0:
		Network.CommandFeedback("Player '%s' not found" % parts[0], caller.peerID)
		return false

	var result : Dictionary = ChatModeration.Report(Peers.GetAccount(caller.peerID), targetID, "", parts[1])
	match str(result.get("reason", "")):
		"not_logged_in":
			Network.CommandFeedback("Not logged in", caller.peerID)
			return false
		"self_report":
			Network.CommandFeedback("You cannot report yourself", caller.peerID)
			return false
		"empty_reason":
			Network.CommandFeedback("Usage: /report <player> <motivo>", caller.peerID)
			return false
		"already_reported":
			Network.CommandFeedback("You already have an open report against '%s'" % parts[0], caller.peerID)
			return false
	if not bool(result.get("ok", false)):
		Network.CommandFeedback("Report could not be filed", caller.peerID)
		return false

	var verified : bool = bool(result.get("verified", false))
	Network.CommandFeedback("Report #%d filed against '%s'%s" % [int(result.get("report_id", 0)), parts[0], "" if verified else " (no recent line from them in the log — the moderator will hear only your side)"], caller.peerID)
	return true

func CommandMute(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false

	var parts : PackedStringArray = arg.strip_edges().split(" ", false, 2)
	if parts.size() < 2:
		Network.CommandFeedback("Usage: /mute <player> <time> [reason]", caller.peerID)
		return false

	var targetID : int = GetAccountID(parts[0])
	if targetID <= 0:
		Network.CommandFeedback("Player '%s' not found" % parts[0], caller.peerID)
		return false

	var duration : int = Util.ParseDuration(parts[1])
	if duration <= 0:
		Network.CommandFeedback("Couldn't parse the duration", caller.peerID)
		return false

	var reason : String = ChatModeration.ClipReason(parts[2]) if parts.size() > 2 else ""
	if not ChatModeration.Mute(targetID, SQLCommons.Timestamp() + duration, reason, Peers.GetAccount(caller.peerID)):
		Network.CommandFeedback("Mute registration failed", caller.peerID)
		return false

	Network.CommandFeedback("'%s' muted for %s" % [parts[0], parts[1]], caller.peerID)
	return true

func CommandUnmute(caller : PlayerAgent, nickname : String) -> bool:
	if not caller:
		return false

	var targetID : int = GetAccountID(nickname)
	if targetID <= 0:
		Network.CommandFeedback("Player '%s' not found" % nickname, caller.peerID)
		return false

	if not ChatModeration.IsMuted(targetID):
		Network.CommandFeedback("Player '%s' is not muted" % nickname, caller.peerID)
		return false

	if not ChatModeration.Unmute(targetID):
		Network.CommandFeedback("Unmute failed", caller.peerID)
		return false

	Network.CommandFeedback("'%s' unmuted" % nickname, caller.peerID)
	return true

func CommandReports(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false

	var requested : int = arg.strip_edges().to_int()
	var limit : int = clampi(requested, 1, 100) if requested > 0 else 20
	var rows : Array[Dictionary] = Launcher.SQL.GetChatReports("open", limit)
	if rows.is_empty():
		Network.CommandFeedback("No open chat reports", caller.peerID)
		return true

	var lines : PackedStringArray = PackedStringArray()
	lines.append("%d open chat report(s):" % Launcher.SQL.CountChatReports("open"))
	for row in rows:
		var excerpt : String = str(row.get("excerpt", ""))
		lines.append("#%d %s -> %s: %s%s" % [int(row.get("report_id", 0)), Launcher.SQL.GetAccountName(int(row.get("reporter_account", 0))), Launcher.SQL.GetAccountName(int(row.get("reported_account", 0))), str(row.get("reason", "")), (" | \"" + excerpt + "\"") if not excerpt.is_empty() else " | (no logged line)"])
	Network.CommandFeedback("\n".join(lines), caller.peerID)
	return true

# Sem /resolve a fila não fecha: o guard anti-metralhadora (uma open por par)
# viraria punição permanente para quem denuncia mais de uma vez a mesma pessoa.
func CommandResolveReport(caller : PlayerAgent, reportIDStr : String) -> bool:
	if not caller:
		return false

	var reportID : int = reportIDStr.to_int()
	if reportID <= 0:
		Network.CommandFeedback("Usage: /resolve <report_id>", caller.peerID)
		return false

	if not Launcher.SQL.ResolveChatReport(reportID, Peers.GetAccount(caller.peerID)):
		Network.CommandFeedback("Report #%d not found or already resolved" % reportID, caller.peerID)
		return false

	Network.CommandFeedback("Report #%d resolved" % reportID, caller.peerID)
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

	# SOM-IDLE C1/C1c: este caminho entrega direto no alvo, sem passar por
	# Server.TriggerChat. Sem o teto e sem o mute aqui, "/w" era o portão de trás
	# do canal — o mute só valeria para quem não sabe que ele existe.
	var message : String = NetworkCommons.ClipChat(text)
	if message.is_empty():
		return false
	var silenced : String = ChatModeration.CanSpeak(Peers.GetAccount(caller.peerID))
	if not silenced.is_empty():
		Network.ChatSystem(channelName, silenced, caller.peerID)
		return true

	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(channelName)
	if not target:
		Network.ChatSystem(channelName, "Player '%s' is no longer online" % channelName, caller.peerID)
		return true

	if target == caller:
		Network.ChatSystem(channelName, "You cannot whisper to yourself", caller.peerID)
		return true

	Network.ChatPlayer(caller.nick, caller.nick, message, caller.get_rid().get_id(), target.peerID)
	Network.ChatPlayer(target.nick, caller.nick, message, caller.get_rid().get_id(), caller.peerID)
	ChatModeration.Note(Peers.GetAccount(caller.peerID), caller.nick, channelName, message)
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

# SOM-IDLE social (AUDITORIA_2026-09-27 §14 SOCIAL, 4/10: "amizades, lista de
# ignorados, denúncias: inexistente ou decorativo"): os cinco verbos do grafo entram no
# MESMO dispatcher que já porta /report. A ROTA é comando, não @rpc dedicado, por medida
# e não por gosto: `Server.gd` não tem folga nenhuma no teto do gate anti-god-node (o
# número que vale é o que `scripts/check_god_nodes.sh` imprime no run), e levantar
# ratchet para caber feature é exatamente o que a régua da casa proíbe — então a escrita
# acontece aqui, no funil que `OnNewTextSubmitted` (`Chat.gd:@OnNewTextSubmitted`) já usa
# (`Network.TriggerCommand` → `Server.TriggerCommand` → `CommandManager.Handle`). Estes
# handlers são finos de propósito: resolve o nick, delega, responde. Toda a política
# (simetria da amizade, tetos, auto-relacionamento, o corte de entrega no chat) mora em
# `sources/social/SocialGraph.gd`, arquivo fora da allowlist — e a frase vista pelo
# jogador também, ao lado do token que a produziu (precedente:
# `ChatModeration.CanSpeak` devolve mensagem, não código).
func CommandFriend(caller : PlayerAgent, arg : String = "") -> bool:
	return _SocialEdge(caller, arg, SocialGraph.KindFriend, true)

func CommandUnfriend(caller : PlayerAgent, arg : String = "") -> bool:
	return _SocialEdge(caller, arg, SocialGraph.KindFriend, false)

func CommandIgnore(caller : PlayerAgent, arg : String = "") -> bool:
	return _SocialEdge(caller, arg, SocialGraph.KindIgnore, true)

func CommandUnignore(caller : PlayerAgent, arg : String = "") -> bool:
	return _SocialEdge(caller, arg, SocialGraph.KindIgnore, false)

# Os quatro verbos compartilham um caminho porque a única diferença entre eles é qual
# aresta o módulo escreve: dois fluxos de identidade e resposta seriam duas chances de
# tratar conta como dado vindo do client e duas chances de vazar token cru na tela.
func _SocialEdge(caller : PlayerAgent, arg : String, kind : String, add : bool) -> bool:
	if not caller:
		return false
	var nick : String = arg.strip_edges().get_slice(" ", 0)
	# A identidade de quem age sai do PEER; o alvo sai de um nick resolvido AQUI.
	# `target_account_id` nunca é lido do pacote — quem escreve o pacote escolhe a
	# própria caixa de entrada, não a do vizinho.
	var accountID : int = Peers.GetAccount(caller.peerID)
	var targetID : int = GetAccountID(nick) if not nick.is_empty() else 0
	if targetID <= 0:
		Network.CommandFeedback(SocialGraph.Message({"ok": false, "reason": "usage" if nick.is_empty() else "unknown_target"}, kind, add, nick), caller.peerID)
		return false
	var result : Dictionary = SocialGraph.Add(kind, accountID, targetID) if add else SocialGraph.Remove(kind, accountID, targetID)
	Network.CommandFeedback(SocialGraph.Message(result, kind, add, nick, accountID), caller.peerID)
	return bool(result.get("ok", false))

# A lista do grafo, lida do banco pelo servidor. O `/social` é o que o painel mostra
# quando o jogador quer conferir o estado; nada aqui inventa cópia local no cliente.
func CommandSocial(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var listed : Dictionary = SocialGraph.DescribeLists(Peers.GetAccount(caller.peerID), arg.strip_edges().to_lower())
	Network.CommandFeedback(str(listed.get("text", "")), caller.peerID)
	return bool(listed.get("ok", false))

# Helpers
static func GetAccountID(nickname : String) -> int:
	var target : PlayerAgent = Launcher.World.GetGlobalPlayer(nickname)
	if target:
		return Peers.GetAccount(target.peerID)
	return Launcher.SQL.GetAccountID(nickname)
