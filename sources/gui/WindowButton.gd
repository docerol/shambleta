extends Control
class_name WindowButton

@export var targetWindow : Control = null
@export var targetShortcut : StringName = ""

#
func OnTopButtonPressed():
	if targetWindow:
		Launcher.GUI.ToggleControl(targetWindow)

func _ready():
	if targetWindow == null:
		push_error("Invalid shortcut given for this window button")
	tooltip_text = tooltip_text + " " + name
	noticeDot = ColorRect.new()
	noticeDot.name = "NoticeDot"
	noticeDot.color = Color(1.0, 0.15, 0.15, 1.0)
	noticeDot.size = Vector2(10, 10)
	noticeDot.custom_minimum_size = Vector2(10, 10)
	noticeDot.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	noticeDot.position = Vector2(-8, -2)
	noticeDot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	noticeDot.set_visible(false)
	add_child(noticeDot)

# Bolinha vermelha de novidade (keys, baús, AFK). Ignora clique.
var noticeDot : ColorRect = null

func SetNotice(on : bool) -> void:
	if noticeDot:
		noticeDot.set_visible(on)
