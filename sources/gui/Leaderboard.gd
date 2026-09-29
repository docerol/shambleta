extends WindowPanel

# SOM-IDLE beta GUI: Leaderboard — top power score global (RPC GetLeaderboard)
# + boards da temporada ativa (RPC GetSeasonBoards: power e spend com nomes
# resolvidos no servidor). Read-only; os dados chegam por push da NetClient.
#
# SOM-IDLE auditoria 2026-09-27: a inscrição no torneio paga entry_gold e a
# taxa NÃO volta seja qual for o resultado — era lambda mandando RPC direto.
# Idiom da casa: handler nomeado arma a pendência citando ouro e torneio,
# `ConfirmPending()` é o ÚNICO caminho de rede (primitivos via `bind`, não
# closure: lambda captura por valor e este repo já foi mordido duas vezes).
@onready var topList : VBoxContainer		= $Layout/TopScroll/TopList
@onready var seasonLabel : Label			= $Layout/SeasonLabel
@onready var seasonList : VBoxContainer		= $Layout/SeasonScroll/SeasonList
@onready var tournamentLabel : Label		= $Layout/TournamentLabel
@onready var tournamentList : VBoxContainer	= $Layout/TournamentScroll/TournamentList

var SendHook : Callable
var _pending : Dictionary = {}

#
func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshBoards()

func _on_visibility_changed():
	if is_visible():
		RefreshBoards()

func RefreshBoards():
	# Render otimista do último snapshot (rate limits de 12s/60s podem engolir
	# reaberturas rápidas — a janela mostra o cache e atualiza quando chegar).
	ShowTop(NetClient.LastLeaderboard)
	ShowSeason(NetClient.LastSeasonBoards)
	ShowTournaments(NetClient.LastTournaments)
	Network.GetLeaderboard()
	Network.GetSeasonBoards()
	Network.GetTournaments()

# Top power global (NetClient.Leaderboard → ShowTop). Fase D: prefixa o
# título equipado (vitrine social do passe/renascimento/apoio).
func ShowTop(entries : Array):
	for child in topList.get_children():
		child.queue_free()
	var rank : int = 1
	for entry in entries:
		if rank > 10:
			break
		var row : Label = Label.new()
		var level : int = int(entry.get("level", 0) if entry.get("level", 0) != null else 0)
		var eqTitle : String = str(entry.get("title", ""))
		var who : String = str(entry.get("nickname", "?"))
		if not eqTitle.is_empty():
			who = "[%s] %s" % [eqTitle, who]
		row.text = "#%d %s — L%d power %s" % [rank, who, level, Util.FormatNumber(int(entry.get("power_score", 0) if entry.get("power_score", 0) != null else 0))]
		topList.add_child(row)
		rank += 1
	if rank == 1:
		var empty : Label = Label.new()
		empty.text = "No ranked players yet."
		topList.add_child(empty)

# Boards da temporada ativa (NetClient.SeasonBoards → ShowSeason).
func ShowSeason(data : Dictionary):
	for child in seasonList.get_children():
		child.queue_free()
	if data.is_empty():
		seasonLabel.text = "Season: none active"
		return
	var daysLeft : int = ceili((int(data.get("ends_at", 0)) - Time.get_unix_time_from_system()) / 86400.0)
	seasonLabel.text = "Season #%d — ends in %d day(s)" % [int(data.get("season_id", 0)), maxi(daysLeft, 0)]
	# Desde a migration 064 o placar é diferença contra o marco zero gravado na
	# abertura. Uma linha anterior a ela não tem marco e o número é o estado
	# corrente do personagem — a etiqueta fala qual dos dois o jogador está
	# olhando, em vez de ele descobrir quando não reconhecer o próprio power score.
	if str(data.get("scoring", "delta")) != "delta":
		seasonLabel.text += " · scores below are lifetime, not this season"
	_FillBoard(seasonList, "Season power", data.get("power", []))
	_FillBoard(seasonList, "Season spend (gems)", data.get("spend", []))
	_FillBoard(seasonList, "Season boss kills", data.get("boss_kills", []))
	_FillBoard(seasonList, "Season guild points", data.get("guild_points", []))

# Fase F: copa semanal (inscrição em gold, rank por ganho de power).
func ShowTournaments(data : Dictionary):
	for child in tournamentList.get_children():
		child.queue_free()
	if data.is_empty() or not bool(data.get("ok", false)):
		tournamentLabel.text = "Tournament: —"
		return
	var active : Dictionary = data.get("active", {})
	if active.is_empty():
		tournamentLabel.text = "Tournament: none (next rotates in soon)"
		return
	var left : int = ceili((int(active.get("ends_at", 0)) - Time.get_unix_time_from_system()) / 86400.0)
	tournamentLabel.text = "%s — %d players, ends in %dd" % [str(active.get("name", "?")), int(active.get("players", 0)), maxi(left, 0)]
	if (data.get("my_entry", {}) as Dictionary).is_empty():
		var enter := Button.new()
		enter.text = "Enter — %d gold (prizes in gems + Champion title)" % int(active.get("entry_gold", 0))
		# Primitivos no bind (idom da casa pós-auditoria): nada de lambda fechando
		# sobre `active` — a confirmação cita o torneio e a taxa que ela cobra.
		enter.pressed.connect(_on_enter_tournament_pressed.bind(int(active.get("id", 0)), str(active.get("name", "?")), int(active.get("entry_gold", 0))))
		tournamentList.add_child(enter)
	else:
		var mine := Label.new()
		mine.text = "Entered — power start %s. Gain power to climb!" % Util.FormatNumber(int((data.get("my_entry", {}) as Dictionary).get("power_start", 0)))
		tournamentList.add_child(mine)

# ------------------------------------------------------------------ gasto com freio
# Mesmo bloco do leilão/arena: `Request*` arma, `ConfirmPending()` é o ÚNICO
# caminho que fala com a rede, modal da casa é a superfície de confirmação.
func _on_enter_tournament_pressed(tournamentID : int, tournamentName : String = "", entryGold : int = 0):
	RequestEnterTournament(tournamentID, tournamentName, entryGold)

func RequestEnterTournament(tournamentID : int, tournamentName : String, entryGold : int) -> bool:
	if tournamentID <= 0:
		return false
	_pending = {
		"method" = "EnterTournament",
		"args" = [tournamentID],
		"line" = "Enter %s for %d gold? The entry fee is spent the moment the server accepts and is NEVER refunded, last place or first." % [
			("\"%s\"" % tournamentName) if not tournamentName.is_empty() and tournamentName != "?" else "the tournament", entryGold],
	}
	_Ask(str(_pending["line"]))
	return true

func _Ask(text : String) -> void:
	# O rótulo do torneio é o texto natural desta janela para segurar a pergunta
	# armada quando não há modal (client em boot ou harness headless).
	if tournamentLabel:
		tournamentLabel.text = text
	var modal : bool = Launcher.GUI != null and Launcher.GUI.messageBox != null
	if modal:
		UICommons.MessageBox(text, Callable(self, "ConfirmPending"), "Confirm")

func ConfirmPending() -> void:
	if _pending.is_empty():
		return
	var methodName : String = str(_pending.get("method", ""))
	var args : Array = _pending.get("args", []) as Array
	_pending = {}
	_send(methodName, args)
	if is_node_ready():
		ShowTournaments(NetClient.LastTournaments)

func CancelPending() -> void:
	_pending = {}

# Estado observável pelo jogador e pelo harness: o que está armado agora.
func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingLine() -> String:
	return str(_pending.get("line", ""))

func PendingArgs() -> Array:
	return (_pending.get("args", []) as Array).duplicate()

# Costura de produção: `Network.<rpc>` sempre em nome literal. As leituras da
# janela (GetLeaderboard/GetSeasonBoards/GetTournaments) não gastam nada e
# continuam direto em `Network.*`.
func _send(methodName : String, args : Array) -> void:
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		return
	match methodName:
		"EnterTournament":
			Network.EnterTournament(int(args[0]))
		_:
			push_error("Leaderboard: unknown send target " + methodName)

func _FillBoard(parent : Container, title : String, rows : Array):
	var header : Label = Label.new()
	header.text = title
	parent.add_child(header)
	if rows.is_empty():
		var empty : Label = Label.new()
		empty.text = "  (no scores yet)"
		parent.add_child(empty)
		return
	var rank : int = 1
	for row in rows:
		var line : Label = Label.new()
		var who : String = str(row.get("name", "?"))
		var eqTitle : String = str(row.get("title", ""))
		if not eqTitle.is_empty():
			who = "[%s] %s" % [eqTitle, who]
		line.text = "  #%d %s — %s" % [rank, who, Util.FormatNumber(int(row.get("value", 0)))]
		parent.add_child(line)
		rank += 1
