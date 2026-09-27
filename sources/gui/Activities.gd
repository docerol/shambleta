extends WindowPanel
class_name ActivitiesWindow

# Hub Atividades (GUI sem fricção): Conquistas | Tormento | Rush | Altar.
# Construída em runtime (sem .tscn); dados via NetClient.Last* (RPCs Get*);
# ações via Network.* (resultados no chat + pushes de estado atualizam as abas).
#
# SOM-IDLE auditoria 2026-09-27: chave de boss gasta gold e as TRÊS operações do
# altar (corrupt/cube/salvage) DESTROEM um item do inventário — era um clique
# sem freio nenhum. Idiom da casa (arm + ConfirmPending, espelho de
# AuctionHousePanel/ArenaPanel): `Request*` só arma, `ConfirmPending()` é o
# ÚNICO caminho de rede, e a linha do altar NOMEIA o item e a perda — quem
# destrói um equipamento tem que ler o que está destruindo.
var SendHook : Callable
var _pending : Dictionary = {}

const TAB_ACH : int = 0
const TAB_TORMENT : int = 1
const TAB_RUSH : int = 2
const TAB_ALTAR : int = 3

var tabs : TabContainer = null
var achBox : VBoxContainer = null
var tormentBox : VBoxContainer = null
var rushBox : VBoxContainer = null
var altarBox : VBoxContainer = null
var altarOption : OptionButton = null
var altarItems : Array = []

func _ready():
	tabs = TabContainer.new()
	tabs.name = "ActivitiesTabs"
	tabs.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(tabs)
	achBox = _make_tab("Conquistas")
	tormentBox = _make_tab("Tormento")
	rushBox = _make_tab("Rush")
	altarBox = _make_tab("Altar")

func _make_tab(title : String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return box

func _clear(box : VBoxContainer) -> void:
	for c in box.get_children():
		c.queue_free()

func _label(box : VBoxContainer, text : String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(l)
	return l

func _refresh_button(box : VBoxContainer, tab : int) -> void:
	var b := Button.new()
	b.text = "Atualizar"
	b.pressed.connect(_on_refresh_pressed.bind(tab))
	box.add_child(b)

func _on_refresh_pressed(tab : int) -> void:
	RefreshTab(tab, true)

func RefreshAll() -> void:
	for i in 4:
		RefreshTab(i, false)

func RefreshTab(tab : int, forceRequest : bool) -> void:
	match tab:
		TAB_ACH:
			ShowAchievements(forceRequest)
		TAB_TORMENT:
			ShowTorment(forceRequest)
		TAB_RUSH:
			ShowRush(forceRequest)
		TAB_ALTAR:
			ShowAltar()

# --- Conquistas -------------------------------------------------------
func ShowAchievements(forceRequest : bool) -> void:
	if achBox == null:
		return
	_clear(achBox)
	if NetClient.LastAchievements.is_empty() or forceRequest:
		Network.GetAchievements()
	if NetClient.LastAchievements.is_empty():
		_label(achBox, "Carregando conquistas...")
		return
	for row in NetClient.LastAchievements:
		var claimed : bool = bool((row as Dictionary).get("claimed", false))
		var h := HBoxContainer.new()
		achBox.add_child(h)
		var l := Label.new()
		l.text = "%s %s: %d/%d" % ["✓" if claimed else "•", str((row as Dictionary).get("id", "?")), int((row as Dictionary).get("progress", 0)), int((row as Dictionary).get("goal", 0))]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		var b := Button.new()
		b.text = "Resgatado" if claimed else "Resgatar"
		b.disabled = claimed
		if not claimed:
			b.pressed.connect(_on_claim_pressed.bind(str((row as Dictionary).get("id", ""))))
		h.add_child(b)
	_refresh_button(achBox, TAB_ACH)

func _on_claim_pressed(achievementID : String) -> void:
	Network.ClaimAchievement(achievementID)

# --- Tormento ---------------------------------------------------------
func ShowTorment(forceRequest : bool) -> void:
	if tormentBox == null:
		return
	_clear(tormentBox)
	if NetClient.LastTorment.is_empty() or forceRequest:
		Network.GetTorment()
	var st : Dictionary = NetClient.LastTorment
	if st.is_empty():
		_label(tormentBox, "Carregando tormento...")
		return
	var level : int = int(st.get("level", 0))
	_label(tormentBox, "Tormento %d (máx %d)" % [level, int(st.get("max", 0))])
	_label(tormentBox, "Recompensa x%.2f • mobs x%.2f HP / x%.2f dano" % [float(st.get("reward", 1.0)), float(st.get("mob_hp", 1.0)), float(st.get("mob_dmg", 1.0))])
	var h := HBoxContainer.new()
	tormentBox.add_child(h)
	var minus := Button.new()
	minus.text = "−"
	minus.custom_minimum_size = Vector2(48, 36)
	minus.pressed.connect(_on_torment_set.bind(level - 1))
	h.add_child(minus)
	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(48, 36)
	plus.pressed.connect(_on_torment_set.bind(level + 1))
	h.add_child(plus)
	_refresh_button(tormentBox, TAB_TORMENT)

func _on_torment_set(level : int) -> void:
	Network.SetTorment(level)

# --- Rush -------------------------------------------------------------
func ShowRush(forceRequest : bool) -> void:
	if rushBox == null:
		return
	_clear(rushBox)
	if NetClient.LastBossState.is_empty() or forceRequest:
		Network.GetBossState()
	var st : Dictionary = NetClient.LastBossState
	if st.is_empty():
		_label(rushBox, "Carregando rush...")
		return
	_label(rushBox, "Keys: %d • chefes: %d" % [int(st.get("keys", 0)), int(st.get("count", 0))])
	var h := HBoxContainer.new()
	rushBox.add_child(h)
	var start := Button.new()
	start.text = "Iniciar rush (1 key)"
	start.pressed.connect(_on_rush_start)
	h.add_child(start)
	var buy := Button.new()
	buy.text = "Comprar key"
	buy.pressed.connect(_on_rush_buy_key)
	h.add_child(buy)
	_refresh_button(rushBox, TAB_RUSH)

func _on_rush_start() -> void:
	Network.RunBossRush()

func _on_rush_buy_key() -> void:
	RequestBuyBossKey()

# A chave é cobrada em GOLD no servidor (`BOSS_KEY_GOLD_PRICE`) — a linha diz a
# moeda certa porque susto bom é susto verdadeiro: gold gasto não volta.
func RequestBuyBossKey() -> bool:
	_pending = {
		"method" = "BuyBossKey",
		"args" = [],
		"line" = "Comprar chave de boss? O gold sai na hora e a chave não é reembolsável.",
	}
	_Ask(str(_pending["line"]))
	return true

# --- Altar (corromper/cubo/desmanche) ----------------------------------
func ShowAltar() -> void:
	if altarBox == null:
		return
	_clear(altarBox)
	altarItems.clear()
	altarOption = OptionButton.new()
	altarBox.add_child(altarOption)
	if Launcher.Player and Launcher.Player.inventory:
		for item in Launcher.Player.inventory.items:
			var cell : ItemCell = DB.GetItem(item.cellID, item.cellCustomfield)
			if cell and cell.slot != ActorCommons.Slot.NONE:
				altarOption.add_item("%s x%d" % [cell.name, item.count])
				altarItems.append(item.cellID)
	if altarItems.is_empty():
		_label(altarBox, "Sem equipamentos no inventário.")
		return
	var h := HBoxContainer.new()
	altarBox.add_child(h)
	var b1 := Button.new()
	b1.text = "Corromper"
	b1.pressed.connect(_on_altar_action.bind("corrupt"))
	h.add_child(b1)
	var b2 := Button.new()
	b2.text = "Cubo 3:1"
	b2.pressed.connect(_on_altar_action.bind("cube"))
	h.add_child(b2)
	var b3 := Button.new()
	b3.text = "Desmanchar"
	b3.pressed.connect(_on_altar_action.bind("salvage"))
	h.add_child(b3)
	_refresh_button(altarBox, TAB_ALTAR)

func _selectedAltarItem() -> int:
	if altarOption == null or altarItems.is_empty():
		return 0
	var idx : int = altarOption.selected
	if idx < 0 or idx >= altarItems.size():
		return 0
	return int(altarItems[idx])

# Texto exibido no seletor (nome + pilha) — é o que o jogador OLHOU, então é o
# que a confirmação cita. Vazio quando a janela ainda não montou o altar.
func _selectedAltarLabel() -> String:
	if altarOption == null or altarItems.is_empty():
		return ""
	var idx : int = altarOption.selected
	if idx < 0 or idx >= altarItems.size():
		return ""
	return altarOption.get_item_text(idx)

func _on_altar_action(kind : String) -> void:
	RequestAltar(kind)

# As três falas do altar: só ARMAM. A linha nomeia o item e o que se perde —
# "corromper" pode voltar coisa pior, "cubo" engole o item na loteria 3:1,
# "desmanchar" destrói para devolver materiais. Um clique mudo aqui era perda
# definitiva de equipamento.
func RequestAltar(kind : String) -> bool:
	var itemID : int = _selectedAltarItem()
	if itemID <= 0:
		return false
	var methodName : String = "SalvageItem"
	var question : String = "Desmanchar \"%s\"? O item é DESTRUÍDO em troca de materiais — não volta."
	match kind:
		"corrupt":
			methodName = "CorruptItem"
			question = "Corromper \"%s\"? O item é consumido no altar e o resultado pode ser PIOR que ele — não volta."
		"cube":
			methodName = "CubeUpcycle"
			question = "Jogar \"%s\" no Cubo 3:1? O item entra no cubo e é consumido — não volta."
	_pending = {
		"method" = methodName,
		"args" = [itemID],
		"line" = question % _selectedAltarLabel(),
	}
	_Ask(str(_pending["line"]))
	return true

# ------------------------------------------------------------------ confirmação
# Blocos espelhados de AuctionHousePanel (mesma régua da arena). Diferença
# honesta: este hub é montado em runtime e suas abas são reconstruídas a cada
# refresh — não há rótulo neutro estável para segurar a pergunta fora do modal,
# então a pendência vive em `_pending` (o modal da casa é a superfície; sem
# modal — client em boot ou harness headless — nada sai sozinho).
func _Ask(text : String) -> void:
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

func CancelPending() -> void:
	_pending = {}

# Estado observável pelo jogador e pelo harness: o que está armado agora.
func PendingCount() -> int:
	return 0 if _pending.is_empty() else 1

func PendingLine() -> String:
	return str(_pending.get("line", ""))

func PendingArgs() -> Array:
	return (_pending.get("args", []) as Array).duplicate()

# Costura de produção: `Network.<rpc>` sempre em nome literal (a porta de
# dispatch de `Network` exige o mesmo formato dos demais calls). Os demais
# RPCs desta janela (leituras de aba, rush, tormento, conquista) não gastam
# nada do jogador e continuam direto em `Network.*`.
func _send(methodName : String, args : Array) -> void:
	if SendHook.is_valid():
		SendHook.call(methodName, args)
		return
	match methodName:
		"BuyBossKey":
			Network.BuyBossKey()
		"CorruptItem":
			Network.CorruptItem(int(args[0]))
		"CubeUpcycle":
			Network.CubeUpcycle(int(args[0]))
		"SalvageItem":
			Network.SalvageItem(int(args[0]))
		_:
			push_error("Activities: unknown send target " + methodName)
