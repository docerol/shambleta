extends RefCounted
class_name GuildMemberRoster

# As linhas da lista de membros do `GuildPanel`: marca de presença + nome + posto +
# (para quem pode) o clique que mexe no roster.
#
# A regra de presença não mora aqui de propósito: `OnlineList` é estado do servidor e
# a fronteira de quem pode consultá-lo é do painel (num cliente puro a presença fica
# desconhecida, e é o painel que decide dizer isso). Então a consulta entra como
# `Callable` e esta peça só desenha — O(1) por membro, batendo nick no índice do
# `OnlineList` em vez de varrer `Peers` linha a linha.
#
# O clique também não decide nada: a fileira emite `(verb, alvo, conta do alvo)` para o
# `onAction` que o painel passou, e é o servidor que diz se quem clicava podia. Os
# verbos vêm de `GuildRoster.RowVerbs` — a lista do desenho É a lista da política, não
# uma cópia que pode envelhecer. Sem `canAct`, ou na própria linha de quem olha, nenhum
# botão nasce: a régua que mede as duas direções é `tests/guild_roster_actions_test.gd`.

static func Render(box : VBoxContainer, members : Array, isOnline : Callable,
		canAct : bool = false, onAction : Callable = Callable(), selfAccount : int = 0) -> void:
	GuildPanelRows.Clear(box)
	if box == null:
		return
	if members.is_empty():
		GuildPanelRows.LabelOf(box, "Empty", "No members.")
		return
	for entry in members:
		var member : Dictionary = entry
		var line := HBoxContainer.new()
		line.name = "MemberRow"
		var dot := Label.new()
		dot.name = "Presence"
		dot.text = PresenceFor(member.get("nicks", []), str(member.get("name", "")), isOnline)
		line.add_child(dot)
		var who := Label.new()
		who.name = "Who"
		who.text = "%s (%s)" % [str(member.get("name", "?")), str(member.get("rank", "member"))]
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(who)
		var target : String = str(member.get("name", ""))
		var targetAccount : int = int(member.get("account_id", 0))
		if canAct and onAction.is_valid() and targetAccount != selfAccount:
			for verb in GuildRoster.RowVerbs:
				line.add_child(ActionButton(str(verb), target, targetAccount, onAction))
		box.add_child(line)

# Um botão por verbo, com o alvo fechado no lambda no instante do desenho. É o mesmo
# formato das prateleiras do vault: a linha não sabe o que o clique faz, só a quem ele
# pertence — por isso o nome do nó sai do próprio verbo (`PromoteButton`,
# `DemoteButton`, `KickButton`), que é o que a árvore real e as réguas de wiring procuram.
# A conta vai junto porque ela já veio do servidor (`GetGuildState` responde
# `account_id` por membro) e o painel local a usa direto no funil; quem não tem conta
# desenhada não vira botão mutante — o `CallServer` que resolve o nick é do outro caminho.
static func ActionButton(verb : String, target : String, targetAccount : int, onAction : Callable) -> Button:
	var button := Button.new()
	button.name = "%sButton" % verb.capitalize().replace(" ", "")
	button.text = verb.capitalize()
	button.pressed.connect(func() -> void: onAction.call(verb, target, targetAccount))
	return button

static func PresenceFor(nicks : Array, username : String, isOnline : Callable) -> String:
	for nick in nicks:
		if bool(isOnline.call(str(nick))):
			return "*"
	return "*" if bool(isOnline.call(username)) else "."
