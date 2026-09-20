extends WindowPanel
class_name ActivitiesWindow

# Hub Atividades (GUI sem fricção): Conquistas | Tormento | Rush | Altar.
# Construída em runtime (sem .tscn); dados via NetClient.Last* (RPCs Get*);
# ações via Network.* (resultados no chat + pushes de estado atualizam as abas).

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
	Network.BuyBossKey()

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

func _on_altar_action(kind : String) -> void:
	var itemID : int = _selectedAltarItem()
	if itemID <= 0:
		return
	match kind:
		"corrupt":
			Network.CorruptItem(itemID)
		"cube":
			Network.CubeUpcycle(itemID)
		_:
			Network.SalvageItem(itemID)
