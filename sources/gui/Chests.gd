extends WindowPanel

# SOM-IDLE beta GUI: Chests — baús fechados + odds públicas (compliance loot
# box) + último drop. Dados chegam pela RPC EconomyState (estado consolidado);
# abrir um baú devolve EconomyState fresco e esta janela se redesenha sozinha.
#
# SOM-IDLE auditoria 2026-09-27: abrir baú CONSUME o baú — gasto irreversível.
# A janela entra no idiom da casa (mesmo arm + ConfirmPending de
# AuctionHousePanel/ArenaPanel): `RequestOpenChest()` só arma a pendência;
# `ConfirmPending()` é o ÚNICO caminho que emite RPC. O `SendHook` é a costura
# do harness (tests/spend_confirm_test.gd) — "emitiu" passa a ser medido.
const AdProvider = preload("res://sources/ads/AdProvider.gd")
var SendHook : Callable
var _pending : Dictionary = {}
@onready var lastDropLabel : Label		= $Layout/LastDrop
@onready var oddsLabel : Label			= $Layout/Odds
@onready var chestList : VBoxContainer	= $Layout/ChestScroll/ChestList
@onready var hintLabel : Label			= $Layout/Hint
@onready var bonusAdButton : Button		= $Layout/BonusChestAd

#
func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshState()

func _on_visibility_changed():
	if is_visible():
		RefreshState()

func RefreshState():
	ShowLastDrop(NetClient.LastChestOpened)
	ShowState(NetClient.LastEconomyState)
	Network.GetEconomyState()

# Redesenho completo a partir do estado consolidado da conta.
func ShowState(state : Dictionary):
	if state.is_empty():
		return
	oddsLabel.text = "Odds: %s%s" % [str(state.get("odds_text", "—")), _PitySuffix(state.get("pity", {}))]
	bonusAdButton.disabled = false
	for child in chestList.get_children():
		child.queue_free()
	var chests : Array = state.get("chests", [])
	hintLabel.text = "Closed chests: %d" % chests.size() if not chests.is_empty() else "No closed chests — earn via AFK settles or buy in the Shop."
	for chestID in chests:
		var btn : Button = Button.new()
		btn.text = "Open chest #%d" % int(chestID)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_chest_pressed.bind(int(chestID)))
		chestList.add_child(btn)

# Sufixo de pity ("raro garantido em N") a partir do bloco `pity` do
# EconomyState. Fallback: extrai `pity_every` do odds_text quando o state
# antigo não traz o bloco (compat com pushes antigos).
static func _PitySuffix(pity : Dictionary) -> String:
	if pity.is_empty():
		return ""
	var toPity : int = int(pity.get("to_pity", 0))
	if toPity <= 1:
		return "  •  PRÓXIMO BAÚ: RARO GARANTIDO!"
	return "  •  Raro garantido em %d baús" % toPity

# Chamado pela NetClient.ChestOpened antes do EconomyState fresco chegar.
func ShowLastDrop(result : Dictionary):
	if result.is_empty():
		return
	var pityTag : String = " [PITY!]" if bool(result.get("pity", false)) else ""
	lastDropLabel.text = "Last drop: %s x%d%s" % [str(result.get("item_name", "?")), int(result.get("count", 1)), pityTag]
	# SOM-IDLE: juice raro — drop T3+ (pity) ganha flash dourado na tela.
	if bool(result.get("pity", false)) and Launcher.GUI != null and Launcher.GUI.has_method("FlashOverlay"):
		Launcher.GUI.FlashOverlay(Color(1.0, 0.85, 0.25, 0.35))

# Botão da lista de baús: só arma. A rede fala depois do `ConfirmPending()`.
func _on_chest_pressed(chestID : int):
	RequestOpenChest(chestID)

# Arma a abertura de um baú fechado. Não fala com a rede de jeito nenhum — o
# baú é consumido no servidor assim que o RPC sai, e sem confirmação um clique
# accidental destruía a poupança de drops do jogador.
func RequestOpenChest(chestID : int) -> bool:
	if chestID <= 0:
		return false
	_pending = {
		"method" = "OpenChest",
		"args" = [chestID],
		"line" = "Open chest #%d? Opening consumes the chest — no undo, no refund." % chestID,
	}
	_Ask(str(_pending["line"]))
	return true

# Espelho do `_Ask` do leilão: o modal da casa (`UICommons.MessageBox`) é a
# única superfície de confirmação — aqui não há linha própria de botão como no
# leilão/arena porque esta janela nasce do .tscn e o hint é o único rótulo
# neutro; sem modal (client ainda montando o HUD, ou harness headless) a
# pendência fica armada no hint e NADA sai sozinha para a rede.
func _Ask(text : String) -> void:
	if hintLabel:
		hintLabel.text = text
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
	_refreshHint()
	_send(methodName, args)

func CancelPending() -> void:
	_pending = {}
	_refreshHint()

# Estado observável pelo jogador e pelo harness: o que está armado agora.
func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingLine() -> String:
	return str(_pending.get("line", ""))

func PendingArgs() -> Array:
	return (_pending.get("args", []) as Array).duplicate()

# Costura de produção: `Network.<rpc>` sempre em nome literal (a porta de
# dispatch de `Network` exige o mesmo formato dos demais calls).
func _send(methodName : String, args : Array) -> void:
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		return
	match methodName:
		"OpenChest":
			Network.OpenChest(int(args[0]))
		_:
			push_error("Chests: unknown send target " + methodName)

# Devolve o hint ao texto do estado (mesma régua de `ShowState`).
func _refreshHint() -> void:
	if hintLabel:
		var chests : Array = NetClient.LastEconomyState.get("chests", [])
		hintLabel.text = "Closed chests: %d" % chests.size() if not chests.is_empty() else "No closed chests — earn via AFK settles or buy in the Shop."

# Fase E: baú bônus via rewarded ad (1×/dia, VIP ganha 2).
func _on_bonus_chest_ad_pressed():
	if not AdProvider.IsReady("chest"):
		return
	bonusAdButton.disabled = true
	AdProvider.ShowRewarded("chest", func(token : String) -> void:
		if token.is_empty():
			bonusAdButton.disabled = false
			return
		Network.ClaimAdChest(token))
