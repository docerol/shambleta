extends Control
class_name Onboarding

# SOM-IDLE U2: first-login onboarding flow for new players.
# Manages a step-by-step tutorial that highlights key game features.
# Steps are shown as overlays with Next/Back buttons and optional highlights.

const STEP_WELCOME : int = 0
const STEP_CHARACTER : int = 1
const STEP_FARM : int = 2
const STEP_AFK : int = 3
const STEP_SHOP : int = 4
# §13 (AUDITORIA 2026-09-27): passo novo — ensina a barra de botões tocáveis
# (Eventos/Guilda/AH/Arena/Idle) em vez de teclas que Web/celular não têm.
const STEP_HUD : int = 5
const STEP_COMPLETE : int = 6

var _currentStep : int = STEP_WELCOME
var _previousHighlightedNode : Node = null
var _overlay : ColorRect = null
var _label : Label = null
var _nextButton : Button = null
var _backButton : Button = null
var _skipButton : Button = null
var _isActive : bool = false

func _ready():
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0.7)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	add_child(_overlay)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_font_size_override("font_size", 24)
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_label.offset_top = -100
	_label.offset_bottom = 100
	_label.offset_left = 100
	_label.offset_right = -100
	_label.visible = false
	add_child(_label)

	_nextButton = Button.new()
	_nextButton.text = "Next"
	_nextButton.pressed.connect(_on_next)
	_nextButton.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_nextButton.offset_top = -60
	_nextButton.offset_bottom = -20
	_nextButton.offset_left = 100
	_nextButton.offset_right = -100
	_nextButton.visible = false
	add_child(_nextButton)

	_backButton = Button.new()
	_backButton.text = "Back"
	_backButton.pressed.connect(_on_back)
	_backButton.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_backButton.offset_top = -60
	_backButton.offset_bottom = -20
	_backButton.offset_left = -200
	_backButton.offset_right = -120
	_backButton.visible = false
	add_child(_backButton)

	# ROADMAP_COMERCIAL S2: pular tour em 1 clique (onboarding ≤30s).
	_skipButton = Button.new()
	_skipButton.text = "Skip"
	_skipButton.pressed.connect(_on_skip)
	_skipButton.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_skipButton.offset_top = -60
	_skipButton.offset_bottom = -20
	_skipButton.offset_left = -80
	_skipButton.offset_right = 80
	_skipButton.visible = false
	add_child(_skipButton)

func Start():
	if _isActive:
		return
	_isActive = true
	_currentStep = STEP_WELCOME
	_show_step()

func Stop():
	_isActive = false
	_overlay.visible = false
	_label.visible = false
	_nextButton.visible = false
	_backButton.visible = false
	_skipButton.visible = false
	if _previousHighlightedNode != null:
		_clear_highlight(_previousHighlightedNode)
		_previousHighlightedNode = null
	# ROADMAP_COMERCIAL S1: funil onboarding_done (best-effort, fora de transação).
	if Launcher.get("Telemetry") != null and Launcher.Telemetry.has_method("RecordFunnel"):
		Launcher.Telemetry.RecordFunnel("onboarding_done")
	if Launcher.GUI:
		Launcher.GUI.set_visible(true)

func _show_step():
	if not _isActive:
		return
	_overlay.visible = true
	_label.visible = true
	_nextButton.visible = true
	_skipButton.visible = true
	_backButton.visible = _currentStep > STEP_WELCOME

	# P-A2: limpa destaque anterior antes de aplicar o novo.
	if _previousHighlightedNode != null:
		_clear_highlight(_previousHighlightedNode)
		_previousHighlightedNode = null

	var text : String = ""
	match _currentStep:
		STEP_WELCOME:
			text = tr("Welcome to Shambleta!\n\nThis is an idle RPG — your character fights on its own. Let's take a quick tour.")
		STEP_CHARACTER:
			# Q-7 (2026-10-07): o toque primeiro, a tecla depois. Os passos ensinavam
			# "Menu (F1)"/"F2" numa plataforma que o produto entrega como web/celular
			# — §13 já tinha criado o STEP_HUD pelo mesmo motivo; aqui a mentira era
			# só o atalho. O menu tem `TouchButton` (Game.tscn) e os ícones Stat/
			# ZoneMap/AFK/Shop são `WindowButton` reais dentro dele.
			text = tr("Your character is shown here.\n\nTap the Menu button at the top of the screen and tap the Stat icon — on a keyboard, F1 opens the same menu — to customize attributes, equipment, and skills.")
			_highlight_node(Launcher.GUI.statWindow)
		STEP_FARM:
			text = tr("Pick a farm zone to start earning gold and XP automatically.\n\nTap the Menu button at the top of the screen and tap the Zone Map icon to choose where to farm.")
			_highlight_node(Launcher.GUI.zoneWindow)
		STEP_AFK:
			text = tr("When you come back, your AFK earnings are ready to claim.\n\nTap the Menu button at the top of the screen and tap the AFK icon to collect your offline progress.")
			_highlight_node(Launcher.GUI.afkWindow)
		STEP_SHOP:
			text = tr("Spend your gems in the shop!\n\nTap the Menu button at the top of the screen and tap the Shop icon to buy chests, VIP status, and more.")
			_highlight_node(Launcher.GUI.shopWindow)
		STEP_HUD:
			text = tr("The quick bar at the top of your screen is touch-friendly: Eventos lists live events, Guilda opens your guild, AH the auction house, Arena the PvP ladder, and Idle hides everything else.")
			_highlight_node(Launcher.GUI.manualSkillBar)
		STEP_COMPLETE:
			text = tr("You're all set!\n\nYour character will now farm automatically. Come back later to collect your rewards.")
			_nextButton.text = "Finish"
			_highlight_node(null)
			if Launcher.GUI:
				Launcher.GUI.set_visible(true)
	_label.text = text

func _clear_highlight(node : Node):
	if node and node is Control:
		node.remove_theme_color_override("border_color")
		node.remove_theme_constant_override("border_width_left")
		node.remove_theme_constant_override("border_width_top")
		node.remove_theme_constant_override("border_width_right")
		node.remove_theme_constant_override("border_width_bottom")

func _highlight_node(node : Node):
	# P-A2: destaque visual real — limpa destaque anterior e aplica no novo nó.
	if _previousHighlightedNode != null:
		_clear_highlight(_previousHighlightedNode)
	_previousHighlightedNode = node
	# Se há um nó específico, aplica uma borda colorida temporária + overlay pulse.
	if node and node is Control:
		node.add_theme_color_override("border_color", Color(1.0, 0.9, 0.2, 1.0))
		node.add_theme_constant_override("border_width_left", 3)
		node.add_theme_constant_override("border_width_top", 3)
		node.add_theme_constant_override("border_width_right", 3)
		node.add_theme_constant_override("border_width_bottom", 3)
		# Overlay de pulso animado (feedback visual forte, conforme comunidade idle RPG)
		var _pulse : Node = node.get_node_or_null("_OnboardPulse")
		if _pulse != null:
			node.remove_child(_pulse)
			_pulse.queue_free()
		var pulse : ColorRect = ColorRect.new()
		pulse.name = "_OnboardPulse"
		pulse.color = Color(1.0, 0.9, 0.2, 0.35)
		pulse.set_anchors_preset(Control.PRESET_FULL_RECT)
		pulse.mouse_filter = Control.MOUSE_FILTER_IGNORE
		node.add_child(pulse)
		var tween : Tween = node.create_tween()
		tween.set_loops()
		tween.tween_property(pulse, "modulate", Color(1.0, 0.9, 0.2, 0.05), 0.8)
		tween.tween_property(pulse, "modulate", Color(1.0, 0.9, 0.2, 0.35), 0.8)

func _on_next():
	if _currentStep == STEP_COMPLETE:
		Stop()
		if Launcher.GUI:
			Launcher.GUI.settingsWindow.set_sessionfirstlogin(false)
		return
	_currentStep += 1
	_show_step()

func _on_back():
	if _currentStep > STEP_WELCOME:
		_currentStep -= 1
		_show_step()

# ROADMAP_COMERCIAL S2: mesma semântica de conclusão do Finish (funil + flag).
func _on_skip():
	Stop()
	if Launcher.GUI:
		Launcher.GUI.settingsWindow.set_sessionfirstlogin(false)
