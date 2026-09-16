extends PanelContainer

#
@onready var levelLabel : Label						= $Margin/VBox/Level/Value
@onready var locationLabel : Label					= $Margin/VBox/Location/Value
@onready var selection : Control					= $Margin/VBox/Selection

# SOM-IDLE: rebirth — seção construída em runtime (mesma política dos botões
# LGPD/Settings: sem editar .tscn). Renderiza LastRebirthState; pedidos por
# Network.RebirthNow/BuyRebirthUpgrade; push chega por Client._PushRebirth.
var rebInfoLabel : Label
var rebButton : Button
var rebBuyButtons : Dictionary = {}
var rebUpgradeNames : Dictionary = {
	RebirthData.UpgradeXp : "Favor of Rebirth (+5% XP)",
	RebirthData.UpgradeGold : "Gilded Echo (+5% gold)",
	RebirthData.UpgradeAttune : "Menhir Attunement (+2% offline, max 10)",
}
@onready var previousButton : Button				= $Margin/VBox/Selection/Previous
@onready var nextButton : Button					= $Margin/VBox/Selection/Next

#
func _ready():
	var vBox : VBoxContainer = $Margin/VBox
	var section : VBoxContainer = VBoxContainer.new()
	section.name = "RebirthSection"
	rebInfoLabel = Label.new()
	rebInfoLabel.name = "RebirthInfo"
	rebInfoLabel.text = tr("Essence is earned when XP overflows at the level cap.")
	section.add_child(rebInfoLabel)
	for id in RebirthData.UpgradeOrder:
		var btn : Button = Button.new()
		btn.name = "Buy_%s" % id
		btn.text = tr(str(rebUpgradeNames[id]))
		btn.pressed.connect(_on_buy_pressed.bind(id))
		rebBuyButtons[id] = btn
		section.add_child(btn)
	rebButton = Button.new()
	rebButton.name = "RebirthButton"
	rebButton.text = tr("Rebirth")
	rebButton.pressed.connect(_on_rebirth_pressed)
	section.add_child(rebButton)
	vBox.add_child(section)
	visibility_changed.connect(_on_visibility_changed)
	ShowRebirthState(NetClient.LastRebirthState)

func _on_visibility_changed():
	if visible and is_inside_tree():
		Network.GetRebirthState()

func ShowRebirthState(state : Dictionary):
	if state.is_empty():
		return
	var essence : int = int(state.get("essence", 0))
	var rebirths : int = int(state.get("rebirths", 0))
	var level : int = int(state.get("level", 1))
	var cap : int = int(state.get("cap", Experience.MAX_LEVEL))
	rebInfoLabel.text = tr("Essence: %d    •    Rebirths: %d") % [essence, rebirths]
	rebButton.disabled = level < cap
	if not rebButton.disabled:
		rebButton.text = tr("Rebirth now (level %d/%d)") % [level, cap]
	else:
		rebButton.text = tr("Rebirth (reach level %d)") % cap
	for id in rebBuyButtons:
		var btn : Button = rebBuyButtons[id]
		var owned : int = int(state.get(id, 0))
		if id == RebirthData.UpgradeAttune and owned >= int(state.get("attune_max", RebirthData.OfflineMaxLevels)):
			btn.text = "%s (%d) — %s" % [str(rebUpgradeNames[id]), owned, tr("maxed")]
			btn.disabled = true
			continue
		var cost : int = int(state.get("costs", {}).get(id, -1))
		btn.text = "%s (%d) — %d %s" % [str(rebUpgradeNames[id]), owned, cost, tr("essence")]
		btn.disabled = cost < 0 or essence < cost

func _on_rebirth_pressed():
	UICommons.MessageBox(
		tr("Rebirth returns you to level 1. Equipment, gold, boss keys and essence stay with you, and every permanent bonus keeps working. Rebirth now?"),
		Callable(self, "_confirm_rebirth"), tr("Rebirth"))

func _confirm_rebirth():
	Network.RebirthNow()

func _on_buy_pressed(upgradeID : String):
	Network.BuyRebirthUpgrade(upgradeID)

func SetInfo(info : Dictionary):
	levelLabel.set_text(str(info["level"]))
	var mapData : MapData = DB.MapsDB.get(info["pos_map"], null)
	if mapData:
		locationLabel.set_text(mapData._name)

#
func _unhandled_input(event : InputEvent):
	if visible:
		if previousButton and previousButton.is_visible() and event.is_action("ui_left"):
			if Launcher.Action.TryPressed(event, "ui_left", true):
				previousButton.pressed.emit()
		elif nextButton and nextButton.is_visible() and event.is_action("ui_right"):
			if Launcher.Action.TryPressed(event, "ui_right", true):
				nextButton.pressed.emit()
