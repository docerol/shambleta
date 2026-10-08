extends RefCounted
class_name GiftForm

# M-3 (2026-10-07): a fileira do presente de gems na aba Account, nascida em
# runtime (mesmo regime da referral-row — sem .tscn). O gasto é irreversível e
# queima 20%, então entra pelo freio da casa: o handler do botão APENAS arma,
# `ConfirmPending()` é o ÚNICO caminho que emite, `SendHook` é a costura medida
# por `tests/spend_confirm_test.gd`. A linha armada cita destinatário, valor,
# taxa e total — cobrar sem dizer quanto é o bug que aquele harness prendeu.
#
# A prévia usa a MESMA aritmética do funil (`maxi(1, roundi(gems × pct/100))`)
# e os MESMOS knobs congelados de `EconomyCatalog`; o veredito continua sendo
# de `GiftService.SendGift` — a tela desenha, o funil decide.

var SendHook : Callable = Callable()
var _pending : Dictionary = {}

var _nickInput : LineEdit = null
var _amountInput : LineEdit = null
var _sendButton : Button = null
var _statusLabel : Label = null

func Build(parent : VBoxContainer) -> void:
	if _nickInput != null or parent == null:
		return
	_nickInput = LineEdit.new()
	_nickInput.name = "GiftNickInput"
	_nickInput.placeholder_text = tr("Friend's nickname")
	_amountInput = LineEdit.new()
	_amountInput.name = "GiftAmountInput"
	_amountInput.placeholder_text = tr("gems")
	_sendButton = Button.new()
	_sendButton.name = "GiftSendButton"
	_sendButton.text = tr("Send gift")
	_sendButton.pressed.connect(_on_send_pressed)
	_statusLabel = Label.new()
	_statusLabel.name = "GiftStatusLabel"
	parent.add_child(_nickInput)
	parent.add_child(_amountInput)
	parent.add_child(_sendButton)
	parent.add_child(_statusLabel)
	Refresh(NetClient.LastEconomyState.get("gift", {}))

# O estado da porta vem do servidor (`GetGiftState` na projeção): taxa, mínimo,
# cota do dia e janela anti-flip desenhados com os números que o funil usa.
func Refresh(state : Dictionary) -> void:
	if _statusLabel == null or state.is_empty():
		return
	var hours : int = int(int(state.get("flip_window_sec", 0)) / 3600.0)
	_statusLabel.text = "Gift gems: fee %d%% burned, min %d, %d left today, no back-flip for %dh" % [
		int(state.get("fee_pct", 0)), int(state.get("min_gems", 0)),
		int(state.get("left_today", 0)), hours]

func _on_send_pressed():
	if _nickInput == null or _amountInput == null:
		return
	var gems : int = int(_amountInput.text.strip_edges())
	RequestSendGift(_nickInput.text.strip_edges(), gems)

func FeeFor(gems : int) -> int:
	return maxi(1, roundi(float(gems) * float(EconomyCatalog.GiftFeePct) / 100.0))

# Arma exatamente uma pendência com a linha citando tudo que sai da carteira.
func RequestSendGift(nickname : String, gems : int) -> bool:
	if nickname.is_empty() or gems < EconomyCatalog.GiftMinGems:
		return false
	var fee : int = FeeFor(gems)
	_pending = {
		"method" = "SendGift",
		"args" = [nickname, gems],
		"line" = "Send %d gems to \"%s\"? It costs %d gems now — %d of that burns as gift fee and reaches nobody. No undo." % [gems, nickname, gems + fee, fee],
	}
	_Ask(str(_pending["line"]))
	return true

func _Ask(text : String) -> void:
	if _statusLabel != null:
		_statusLabel.text = text
	if Launcher.GUI != null and Launcher.GUI.messageBox != null:
		UICommons.MessageBox(text, Callable(self, "ConfirmPending"), "Confirm")

# ÚNICO caminho que fala com a rede.
func ConfirmPending() -> void:
	if _pending.is_empty():
		return
	var methodName : String = str(_pending.get("method", ""))
	var args : Array = _pending.get("args", []) as Array
	_pending = {}
	if _nickInput != null:
		_nickInput.text = ""
	if _amountInput != null:
		_amountInput.text = ""
	_send(methodName, args)

func CancelPending() -> void:
	_pending = {}

func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingLine() -> String:
	return str(_pending.get("line", ""))

func _send(methodName : String, args : Array) -> void:
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		return
	match methodName:
		"SendGift":
			Network.SendGift(str(args[0]), int(args[1]))
		_:
			push_error("GiftForm: unknown send target " + methodName)
