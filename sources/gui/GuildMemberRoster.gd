extends RefCounted
class_name GuildMemberRoster

# As linhas da lista de membros do `GuildPanel`: marca de presença + nome + posto.
#
# A regra de presença não mora aqui de propósito: `OnlineList` é estado do servidor e
# a fronteira de quem pode consultá-lo é do painel (num cliente puro a presença fica
# desconhecida, e é o painel que decide dizer isso). Então a consulta entra como
# `Callable` e esta peça só desenha — O(1) por membro, batendo nick no índice do
# `OnlineList` em vez de varrer `Peers` linha a linha.

static func Render(box : VBoxContainer, members : Array, isOnline : Callable) -> void:
	GuildPanelRows.Clear(box)
	if box == null:
		return
	if members.is_empty():
		GuildPanelRows.LabelOf(box, "Empty", "No members.")
		return
	for entry in members:
		var member : Dictionary = entry
		var line := HBoxContainer.new()
		var dot := Label.new()
		dot.text = PresenceFor(member.get("nicks", []), str(member.get("name", "")), isOnline)
		line.add_child(dot)
		var who := Label.new()
		who.text = "%s (%s)" % [str(member.get("name", "?")), str(member.get("rank", "member"))]
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(who)
		box.add_child(line)

static func PresenceFor(nicks : Array, username : String, isOnline : Callable) -> String:
	for nick in nicks:
		if bool(isOnline.call(str(nick))):
			return "*"
	return "*" if bool(isOnline.call(username)) else "."
