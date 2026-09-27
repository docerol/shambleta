extends WindowPanel

# SOM-IDLE Fase C: janela do passe de temporada (BATTLE_PASS_S1). Trilhas
# grátis/premium lado a lado por nível claimável, missões do período com
# progresso server-side e botões BuyPass/Skip. Tudo dinâmico a partir do
# SeasonPassState; ações voltam como PassFeedback + estado fresco.
#
# SOM-IDLE auditoria 2026-09-27: os três gastos do passe (premium standard,
# deluxe e skip em gems) saíam com um clique. Idiom da casa: handler arma a
# pendência (`Request*`), `ConfirmPending()` é o ÚNICO caminho de rede, modal da
# casa é a superfície. O skip cita o preço em gems que o próprio servidor cobra
# (EconomyCatalog.PASS_SKIP_COST = 50, o mesmo número do botão).
@onready var headerLabel : Label = $Layout/Header
@onready var trackBox : VBoxContainer = $Layout/TrackScroll/TrackList
@onready var missionBox : VBoxContainer = $Layout/MissionScroll/MissionList
@onready var buyPassButton : Button = $Layout/BuyPass
@onready var buyDeluxeButton : Button = $Layout/BuyDeluxe
@onready var skipButton : Button = $Layout/SkipLevel

var SendHook : Callable
var _pending : Dictionary = {}
# Último estado visto — a linha armada cita skips restantes, não chute.
var _skipsUsed : int = 0
var _skipsMax : int = 10

func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshPass()

func _on_visibility_changed():
	if is_visible():
		RefreshPass()

func RefreshPass():
	ShowSeasonPass(NetClient.LastSeasonPass)
	Network.GetSeasonPass()

func ShowSeasonPass(state : Dictionary):
	for c in trackBox.get_children():
		c.queue_free()
	for c in missionBox.get_children():
		c.queue_free()
	if state.is_empty() or not bool(state.get("ok", false)):
		headerLabel.text = "Season pass: %s" % str(state.get("reason", "no season"))
		buyPassButton.disabled = true
		buyDeluxeButton.disabled = true
		skipButton.disabled = true
		return
	var premium : bool = int(state.get("premium", 0)) == 1
	var dbl : String = " · 2× PT!" if bool(state.get("double_xp", false)) else ""
	headerLabel.text = "Season #%d — L%d (%d PT)%s · %s" % [
		int(state.get("season_id", 0)), int(state.get("level", 0)),
		int(state.get("pt", 0)), dbl, "PREMIUM" if premium else "free track"]
	buyPassButton.disabled = premium
	buyPassButton.text = "Premium owned" if premium else "Buy premium — R$ 24,90"
	buyDeluxeButton.disabled = premium
	buyDeluxeButton.text = "Premium owned" if premium else "Buy deluxe — R$ 44,90"
	var skips : int = int(state.get("skips_used", 0))
	var skipsMax : int = int(state.get("skips_max", 10))
	_skipsUsed = skips
	_skipsMax = skipsMax
	skipButton.disabled = skips >= skipsMax
	skipButton.text = "Skip level — 50 gems (%d/%d)" % [skips, skipsMax]
	for lvl in state.get("free_claimable", []):
		trackBox.add_child(_claim_button("Free L%d" % int(lvl), int(lvl), "free"))
	for lvl in state.get("premium_claimable", []):
		trackBox.add_child(_claim_button("Premium L%d" % int(lvl), int(lvl), "premium"))
	if trackBox.get_children().is_empty():
		var none := Label.new()
		none.text = "No rewards to claim — earn PT from missions below."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		trackBox.add_child(none)
	_add_missions("Dailies", state.get("dailies", []))
	_add_missions("Weeklies", state.get("weeklies", []))
	_add_missions("Milestones", state.get("milestones", []))

func _claim_button(text : String, level : int, track : String) -> Button:
	var b := Button.new()
	b.text = "Claim %s" % text
	b.pressed.connect(func() -> void: Network.ClaimPassReward(level, track))
	return b

func _add_missions(title : String, missions : Array):
	var header := Label.new()
	header.text = title
	missionBox.add_child(header)
	for m in missions:
		if not (m is Dictionary):
			continue
		var done : bool = int(m.get("progress", 0)) >= int(m.get("goal", 1))
		var claimed : bool = int(m.get("claimed", 0)) == 1
		var row := Button.new()
		row.text = "%s — %d/%d PT%s%s" % [str(m.get("label", "?")),
			int(m.get("progress", 0)), int(m.get("goal", 1)),
			" · claimed" if claimed else (" · CLAIM" if done else "")]
		row.disabled = claimed or not done
		if done and not claimed:
			var mid : String = str(m.get("id", ""))
			row.pressed.connect(func() -> void: Network.ClaimMission(mid))
		missionBox.add_child(row)

# ------------------------------------------------------------------ gasto com freio
# Mesmo bloco do leilão/arena. `BuyPass` no servidor só fabrica um intent de
# checkout (dinheiro real) — ainda assim passa pelo freio porque abre diálogo de
# pagamento, que é um compromisso para o jogador. O skip gasta gems de verdade.
func _on_buy_pass_pressed():
	RequestBuyPass("standard")

func _on_buy_deluxe_pressed():
	RequestBuyPass("deluxe")

func RequestBuyPass(tier : String) -> bool:
	if tier != "standard" and tier != "deluxe":
		return false
	var price : String = "R$ 24,90" if tier == "standard" else "R$ 44,90"
	_pending = {
		"method" = "BuyPass",
		"args" = [tier],
		"line" = "Buy the %s season pass — %s? A real-money checkout opens next; nothing is charged until you approve it there." % [tier, price],
	}
	_Ask(str(_pending["line"]))
	return true

func _on_skip_level_pressed():
	RequestSkipLevel()

func RequestSkipLevel() -> bool:
	if _skipsUsed >= _skipsMax:
		return false
	_pending = {
		"method" = "SkipPassLevel",
		"args" = [],
		"line" = "Skip one pass level for 50 gems? The gems are spent now (%d/%d skips used this season)." % [_skipsUsed, _skipsMax],
	}
	_Ask(str(_pending["line"]))
	return true

func _Ask(text : String) -> void:
	# O cabeçalho é o único texto neutro desta janela nascida de .tscn; fora do
	# modal ele segura a pergunta armada (nunca envia sozinho).
	if headerLabel:
		headerLabel.text = text
	var modal : bool = Launcher.GUI != null and Launcher.GUI.messageBox != null
	if modal:
		UICommons.MessageBox(text, Callable(self, "ConfirmPending"), "Confirm")

# ÚNICO caminho que fala com a rede. Sem confirmação, este método não é chamado.
func ConfirmPending() -> void:
	if _pending.is_empty():
		return
	var methodName : String = str(_pending.get("method", ""))
	var args : Array = _pending.get("args", []) as Array
	_pending = {}
	_send(methodName, args)
	if is_node_ready():
		ShowSeasonPass(NetClient.LastSeasonPass)

func CancelPending() -> void:
	_pending = {}

# Estado observável pelo jogador e pelo harness: o que está armado agora.
func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingLine() -> String:
	return str(_pending.get("line", ""))

func PendingArgs() -> Array:
	return (_pending.get("args", []) as Array).duplicate()

func _send(methodName : String, args : Array) -> void:
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		return
	match methodName:
		"BuyPass":
			Network.BuyPass(str(args[0]))
		"SkipPassLevel":
			Network.SkipPassLevel()
		_:
			push_error("SeasonPass: unknown send target " + methodName)
