extends WindowPanel
class_name Social

#
@onready var playerList : VBoxContainer			= $Layout/Margin/TabBar/Online/Scroll/PlayerList
@onready var onlineCount : Label				= $Layout/Margin/TabBar/Online/OnlineCount
@onready var guildList : VBoxContainer			= $Layout/Margin/TabBar/Guild/GuildList

#
func UpdateCount() -> void:
	var count : int = playerList.get_child_count()
	onlineCount.text = str(count) + " player" + ("s" if count != 1 else "") + " online"

func RefreshOnline(players : PackedStringArray) -> void:
	for child in playerList.get_children():
		child.free()
	for playerName in players:
		playerList.add_child(PlayerLine.new(playerName))
	UpdateCount()

func AddOnlinePlayer(playerName : String) -> void:
	if not playerList.has_node(playerName):
		playerList.add_child(PlayerLine.new(playerName))
		UpdateCount()

func RemoveOnlinePlayer(playerName : String) -> void:
	var line : Node = playerList.get_node_or_null(playerName)
	if line:
		line.free()
		UpdateCount()

#
func _ready():
	if Network and Network.has_method("RequestOnlineList"):
		FSM.enter_game.connect(Network.RequestOnlineList)
	FSM.enter_game.connect(RefreshGuild)

# Fase F (guild premium): painel da minha guild + top por pontos + ações de
# líder/oficial (fast level-up, vault slots). Gerência segue no /guild.
func RefreshGuild():
	ShowGuildState(NetClient.LastGuildState)
	Network.GetGuildState()

func ShowGuildState(state : Dictionary):
	for child in guildList.get_children():
		child.queue_free()
	if state.is_empty() or not bool(state.get("ok", false)):
		return
	var mine : Dictionary = state.get("my_guild", {})
	if mine.is_empty():
		var none := Label.new()
		none.text = "No guild joined — /guild create <name> (5000 gold)"
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		guildList.add_child(none)
	else:
		var header := Label.new()
		var vault : Dictionary = mine.get("vault", {})
		var gtag : String = str(mine.get("tag", ""))
		var gname : String = str(mine.get("name", "?"))
		if not gtag.is_empty():
			gname = "[%s] %s" % [gtag, gname]
		header.text = "%s — L%d · %d pts · vault %d/%d · you: %s" % [
			gname, int(mine.get("level", 1)),
			int(mine.get("points", 0)), int(vault.get("used", 0)),
			int(vault.get("cap", 0)), str(mine.get("my_rank", "?"))]
		header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		guildList.add_child(header)
		var rank : String = str(mine.get("my_rank", ""))
		if rank == "leader" or rank == "officer":
			var fast := Button.new()
			fast.text = "Fast level-up (2× gems, no gold)"
			fast.pressed.connect(func() -> void: Network.LevelUpGuildFast())
			guildList.add_child(fast)
			var slots := Button.new()
			slots.text = "Buy vault slot — %d gems" % int(state.get("vault_slot_cost", 200))
			slots.pressed.connect(func() -> void: Network.BuyVaultSlots())
			guildList.add_child(slots)
		for m in mine.get("members", []):
			var line := Label.new()
			line.text = "  %s (%s)" % [str((m as Dictionary).get("name", "?")), str((m as Dictionary).get("rank", "?"))]
			guildList.add_child(line)
	var btitle := Label.new()
	btitle.text = "Top guilds (season points race)"
	guildList.add_child(btitle)
	var pos : int = 1
	for g in state.get("board", []):
		var btag : String = str((g as Dictionary).get("tag", ""))
		var bname : String = str((g as Dictionary).get("name", "?"))
		if not btag.is_empty():
			bname = "[%s] %s" % [btag, bname]
		var row := Label.new()
		row.text = "  #%d %s — L%d · %d pts" % [pos, bname, int((g as Dictionary).get("level", 1)), int((g as Dictionary).get("points", 0))]
		guildList.add_child(row)
		pos += 1
