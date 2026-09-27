# SOM-IDLE P1 (auditoria 2026-09-27): arena assíncrona + eventos ao vivo jogáveis.
#
# O servidor já calculava tudo (`ArenaSetDefense` / `ArenaAttack` / `ArenaBoard` /
# `GetActiveEvents` em Server.gd) e já empurrava os resultados; o que não existia
# era (a) o receptor no cliente e (b) uma tela. Sem a janela, a arena — o único
# PvP assíncrono do jogo — e os eventos ao vivo eram invisíveis para o jogador.
#
# Ataque gasta ticket do dia e muda o seu elo: por isso passa pela MESMA
# confirmação do leilão. `RequestAttack()` arma; só `ConfirmPending()` emite RPC.
extends WindowPanel
class_name ArenaPanel

var SendHook : Callable

var _state : Dictionary = {}
var _board : Dictionary = {}
var _pending : Dictionary = {}
var _eventsLabel : Label = null
var _myLabel : Label = null
var _boardBox : VBoxContainer = null
var _statusLabel : Label = null
var _confirmRow : HBoxContainer = null
var _confirmLabel : Label = null
var _events : Array = []

func _ready():
	name = "Arena"
	custom_minimum_size = Vector2(340, 400)

	var root := VBoxContainer.new()
	root.name = "ArenaRoot"
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Nascendo da cena (presets/gui/Arena.tscn), o TitleBar é quem dá o botão de
	# fechar e o conteúdo entra num ScrollContainer DEBAIXO dele — board e eventos
	# crescem além da janela fixa (§13, corte no web). Fora de cena, segue colado.
	var host : Node = get_node_or_null("Layout")
	if host != null:
		var scroll := ScrollContainer.new()
		scroll.name = "ArenaScroll"
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		host.add_child(scroll)
		scroll.add_child(root)
	else:
		add_child(root)

	var title := _label(root, "Arena")
	title.add_theme_font_size_override("font_size", 18)
	_eventsLabel = _label(root, "No live event right now.")
	_myLabel = _label(root, "Arena: no ladder entry yet. Save a defense to join.")
	_statusLabel = _label(root, "Loading arena…")

	_boardBox = VBoxContainer.new()
	_boardBox.name = "ArenaBoard"
	root.add_child(_boardBox)

	_confirmRow = HBoxContainer.new()
	_confirmRow.name = "ArenaConfirmRow"
	_confirmRow.visible = false
	root.add_child(_confirmRow)
	_confirmLabel = _label(_confirmRow, "")
	_confirmLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var confirm := Button.new()
	confirm.name = "ArenaConfirm"
	confirm.text = "Confirm"
	confirm.pressed.connect(ConfirmPending)
	_confirmRow.add_child(confirm)
	var abort := Button.new()
	abort.name = "ArenaAbort"
	abort.text = "Cancel"
	abort.pressed.connect(CancelPending)
	_confirmRow.add_child(abort)

	var save := Button.new()
	save.name = "ArenaSaveDefense"
	save.text = "Save defense"
	save.pressed.connect(RequestDefense)
	root.add_child(save)
	var refresh := Button.new()
	refresh.name = "ArenaRefresh"
	refresh.text = "Refresh"
	refresh.pressed.connect(_on_refresh_pressed)
	root.add_child(refresh)

func _label(parent : Node, text : String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l

# ------------------------------------------------------------------ pushes (Client.gd)
# Board: {"ok", "my": {elo, wins, losses}, "top": [{account_id, username, elo, wins, losses}]}
func ShowBoard(board : Dictionary) -> void:
	_board = board
	if not bool(board.get("ok", false)):
		if _statusLabel:
			_statusLabel.text = ReasonLine(str(board.get("reason", "unavailable")))
		return
	var my : Dictionary = board.get("my", {}) as Dictionary
	if _myLabel:
		_myLabel.text = MyLine(my)
	if _boardBox:
		for child in _boardBox.get_children():
			child.queue_free()
		var top : Array = board.get("top", []) as Array
		if top.is_empty():
			_label(_boardBox, "Nobody is on the ladder yet.")
		for row in top:
			var entry : Dictionary = row
			var button := Button.new()
			button.name = "ArenaAttack_%d" % int(entry.get("account_id", 0))
			button.text = BoardLine(entry)
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.pressed.connect(RequestAttack.bind(int(entry.get("account_id", 0))))
			_boardBox.add_child(button)

func ShowDefense(result : Dictionary) -> void:
	if _statusLabel == null:
		return
	if bool(result.get("ok", false)):
		_statusLabel.text = "Defense saved (power %d)." % int(result.get("power", 0))
	else:
		_statusLabel.text = "Defense rejected: " + ReasonLine(str(result.get("reason", "")))

func ShowAttack(result : Dictionary) -> void:
	_status(AttackLine(result))
	_pending = {}
	if _confirmRow:
		_confirmRow.visible = false

func ShowEvents(state : Dictionary) -> void:
	_state = state
	_events = (state.get("events", []) as Array) if state.get("events", []) is Array else []
	if _eventsLabel:
		_eventsLabel.text = EventsLine(_events)

# ------------------------------------------------------------------ texto (puro)
func MyLine(my : Dictionary) -> String:
	if my.is_empty():
		return "Arena: no ladder entry yet. Save a defense to join."
	return "Your record: %d elo • %d wins • %d losses" % [int(my.get("elo", 0)), int(my.get("wins", 0)), int(my.get("losses", 0))]

# Alvo = uma linha do board. O auto-ataque não é escondido aqui: o `ArenaBoard`
# do servidor devolve `top` sem o account_id do chamador, então quem se atacaria
# recebe `self_attack` do serviço (motivo traduzido em AttackLine).
func BoardLine(entry : Dictionary) -> String:
	return "%s — %d elo (%d wins, %d losses)" % [str(entry.get("username", "?")), int(entry.get("elo", 0)),
		int(entry.get("wins", 0)), int(entry.get("losses", 0))]

func AttackLine(result : Dictionary) -> String:
	if not bool(result.get("ok", false)):
		return "Attack rejected: " + ReasonLine(str(result.get("reason", "")))
	return "%s • %d vs %d power • your elo: %d" % ["Victory" if bool(result.get("win", false)) else "Defeat",
		int(result.get("attacker_power", 0)), int(result.get("defender_power", 0)), int(result.get("new_attacker_elo", 0))]

func EventsLine(events : Array) -> String:
	if events.is_empty():
		return "No live event right now."
	var parts : PackedStringArray = PackedStringArray()
	for entry in events:
		var event : Dictionary = entry
		var params : Dictionary = event.get("params", {}) as Dictionary
		var mod : float = float(params.get("drops_mod", 1.0))
		parts.append("%s x%.2f drops (ends in %s)" % [str(event.get("kind", "?")), mod, Remaining(int(event.get("ends_at", 0)), int(_state.get("now", 0)))])
	return "Live events: " + ", ".join(parts)

func Remaining(endsAt : int, now : int) -> String:
	var delta : int = maxi(0, endsAt - now)
	if delta <= 0:
		return "moments"
	var hours : int = int(delta / 3600.0)
	if hours > 0:
		return "%dh %dm" % [hours, int((delta % 3600) / 60.0)]
	return "%dm" % int(delta / 60.0)

func ReasonLine(reason : String) -> String:
	# §13 (audit UX): a tabela mora no catálogo compilado (`reason/<token>` no
	# data/i18n/ui.csv). A versão hardcoded daqui era inglês-only e já vivia fora
	# de sincronia com o servidor; sem linha no catálogo, o código degrada para a
	# genérica localizada (e o bruto vai para o log), nunca para a tela.
	if reason.is_empty():
		return PlayerReasons.Describe("unavailable")
	return PlayerReasons.Describe(reason)

# ------------------------------------------------------------------ ações
func RequestDefense() -> void:
	# Salvar defesa não gasta nada (é só o snapshot do time) — vai direto, como o
	# `Refresh` das demais janelas.
	_send("ArenaSetDefense", [])
	_status("Saving defense…")

func RequestAttack(defenderAccountID : int) -> bool:
	if defenderAccountID <= 0:
		return false
	# O ticket é do servidor (`no_tickets` no veredito) — a UI não finge saber
	# quantos restam, porque o board não entrega esse número.
	_pending = {
		"method" = "ArenaAttack",
		"args" = [defenderAccountID],
		"line" = "Attack account #%d? This spends one of today's tickets and moves your elo." % defenderAccountID,
	}
	if _confirmLabel:
		_confirmLabel.text = str(_pending["line"])
	var modal : bool = Launcher.GUI != null and Launcher.GUI.messageBox != null
	if _confirmRow:
		_confirmRow.visible = not modal
	if modal:
		UICommons.MessageBox(str(_pending["line"]), Callable(self, "ConfirmPending"), "Confirm")
	return true

func ConfirmPending() -> void:
	if _pending.is_empty():
		return
	var methodName : String = str(_pending.get("method", ""))
	var args : Array = _pending.get("args", []) as Array
	_pending = {}
	if _confirmRow:
		_confirmRow.visible = false
	if methodName == "ArenaAttack":
		_status("Attacking…")
	_send(methodName, args)

func CancelPending() -> void:
	_pending = {}
	if _confirmRow:
		_confirmRow.visible = false
	if _confirmLabel:
		_confirmLabel.text = ""

func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingArgs() -> Array:
	return (_pending.get("args", []) as Array).duplicate()

func _send(methodName : String, args : Array) -> void:
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		return
	match methodName:
		"ArenaSetDefense":
			Network.ArenaSetDefense()
		"ArenaAttack":
			Network.ArenaAttack(int(args[0]))
		"ArenaBoard":
			Network.ArenaBoard()
		"GetActiveEvents":
			Network.GetActiveEvents()
		_:
			push_error("ArenaPanel: unknown send target " + methodName)

func _status(text : String) -> void:
	if _statusLabel:
		_statusLabel.text = text

func _on_refresh_pressed() -> void:
	_open()

# Chamada por Gui ao abrir a janela: cache primeiro (resposta instantânea), rede
# em seguida (board + eventos são rpcs distintos).
func OpenArena() -> void:
	if not NetClient.LastArenaBoard.is_empty():
		ShowBoard(NetClient.LastArenaBoard)
	if not NetClient.LastActiveEvents.is_empty():
		ShowEvents(NetClient.LastActiveEvents)
	_open()

func _open() -> void:
	_send("ArenaBoard", [])
	_send("GetActiveEvents", [])
