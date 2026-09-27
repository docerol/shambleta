extends RefCounted
class_name GuildListings

# As duas listas de GUILDES (não de gente) do `GuildPanel`: o resultado da busca por
# nome, com botão de entrar, e a placa de ranking. São o mesmo par de decisões —
# montar `[tag] nome` e escolher o que citar da linha —, por isso moram juntas.
#
# O `Join` passa pelo `onJoin` do painel: entrar numa guilda muda quem manda no
# vault, então quem tem sessão, quem confirma e quem fala com o serviço continua
# sendo um só lugar (`GuildPanel.JoinGuildByID`).

static func DisplayName(guild : Dictionary) -> String:
	var tag : String = str(guild.get("tag", ""))
	var gname : String = str(guild.get("name", "?"))
	return gname if tag.is_empty() else "[%s] %s" % [tag, gname]

static func RenderResults(box : VBoxContainer, results : Array, onJoin : Callable) -> void:
	GuildPanelRows.Clear(box)
	if box == null:
		return
	if results.is_empty():
		GuildPanelRows.LabelOf(box, "None", "No matches.")
		return
	for row in results:
		var g : Dictionary = row
		var line := HBoxContainer.new()
		var label := Label.new()
		label.text = "%s — L%d · %d pts · %d members" % [DisplayName(g), int(g.get("level", 1)),
			int(g.get("points", 0)), int(g.get("members", 0))]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(label)
		var joinID : int = int(g.get("guild_id", 0))
		if onJoin.is_valid():
			var join := Button.new()
			join.text = "Join"
			join.pressed.connect(func() -> void: onJoin.call(joinID))
			line.add_child(join)
		box.add_child(line)

# Placa de ranking: `#posição nome — nível · pontos`, uma Label por linha. Os nomes
# de nó (`Row1`, `Row2`, …) são estáveis porque é por eles que um harness acha a
# posição sem depender de texto.
static func RenderBoard(box : VBoxContainer, board : Array) -> void:
	GuildPanelRows.Clear(box)
	if box == null:
		return
	if board.is_empty():
		GuildPanelRows.LabelOf(box, "None", "No ranked guilds yet.")
		return
	var pos : int = 1
	for row in board:
		var g : Dictionary = row
		GuildPanelRows.LabelOf(box, "Row%d" % pos, "#%d %s — L%d · %d pts" % [
			pos, DisplayName(g), int(g.get("level", 1)), int(g.get("points", 0))])
		pos += 1
