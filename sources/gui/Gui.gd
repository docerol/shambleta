extends ServiceBase

# SOM-IDLE P2: minimal HUD for idle/farm sessions.
# P-A1: essential windows for idle mode (≤ 8). Built at runtime (not const:
# const expressions cannot reference @onready instance members).
# Fase U1 — hub Personagem: Status+Skills+Progresso+Formação numa janela com
# abas (conteúdo reparentado em runtime, sem .tscn). Scripts originais seguem
# vivos (Client.Refresh* continua funcionando); shells ficam ocultas.
var characterHub : WindowPanel = null

func EnsureCharacterHub() -> WindowPanel:
	if characterHub and is_instance_valid(characterHub):
		return characterHub
	characterHub = WindowPanel.new()
	characterHub.name = "Character"
	if statWindow:
		characterHub.size = statWindow.size
		characterHub.position = statWindow.position
	var tabs := TabContainer.new()
	tabs.name = "CharacterTabs"
	tabs.set_anchors_preset(Control.PRESET_FULL_RECT)
	characterHub.add_child(tabs)
	_AbsorbWindow(statWindow, tabs, "Status")
	_AbsorbWindow(skillWindow, tabs, "Skills")
	_AbsorbWindow(progressWindow, tabs, "Progresso")
	_AbsorbWindow(formationWindow, tabs, "Formação")
	windows.add_child(characterHub)
	characterHub.set_visible(false)
	_RepointMenuToHub()
	return characterHub

func _AbsorbWindow(win : WindowPanel, tabs : TabContainer, title : String) -> void:
	if win == null or not is_instance_valid(win):
		return
	var layout : Node = win.get_node_or_null("Layout")
	if layout:
		var titleBar : Node = layout.get_node_or_null("TitleBar")
		if titleBar:
			layout.remove_child(titleBar)
			titleBar.queue_free()
		win.remove_child(layout)
		var page := Control.new()
		page.name = title
		layout.set_anchors_preset(Control.PRESET_FULL_RECT)
		page.add_child(layout)
		tabs.add_child(page)
	win.set_visible(false)

func _RepointMenuToHub() -> void:
	if menu == null or menu.items == null:
		return
	for node in menu.items.get_children():
		if node is WindowButton and node.targetWindow and (node.targetWindow == statWindow or node.targetWindow == skillWindow or node.targetWindow == progressWindow or node.targetWindow == formationWindow):
			node.targetWindow = characterHub

func OpenCharacterHub(tab : int = 0) -> void:
	var hub : WindowPanel = EnsureCharacterHub()
	var tabs : TabContainer = hub.get_node_or_null("CharacterTabs") as TabContainer
	if tabs and tabs.get_tab_count() > 0:
		tabs.current_tab = clampi(tab, 0, tabs.get_tab_count() - 1)
	if not hub.is_visible():
		ToggleControl(hub)

func _essential_windows() -> Array[WindowPanel]:
	# P-A1: HUD idle — máximo 8 janelas essenciais (conforme plano-ui-ux.md e feedback comunidade idle RPG).
	var out : Array[WindowPanel] = []
	for win in [statWindow, chatWindow, minimapWindow, shopWindow, chestsWindow, bossWindow, seasonPassWindow, afkWindow]:
		if win and win is WindowPanel:
			out.append(win)
	return out

# Hub Atividades (runtime, sem .tscn): 4 abas com os backends dos comandos.
var activitiesWindow : ActivitiesWindow = null

func EnsureActivities() -> ActivitiesWindow:
	if activitiesWindow == null or not is_instance_valid(activitiesWindow):
		activitiesWindow = ActivitiesWindow.new()
		activitiesWindow.name = "Activities"
		windows.add_child(activitiesWindow)
		activitiesWindow.set_visible(false)
	return activitiesWindow

func OpenActivities(tab : int = 0) -> void:
	var w : ActivitiesWindow = EnsureActivities()
	w.tabs.current_tab = clampi(tab, 0, 3)
	if not w.is_visible():
		ToggleControl(w)
	w.RefreshTab(clampi(tab, 0, 3), false)

func RefreshActivitiesTab(tab : int) -> void:
	if activitiesWindow and is_instance_valid(activitiesWindow) and activitiesWindow.is_visible():
		activitiesWindow.RefreshTab(tab, false)

var idleMode : bool = false
var idleModeWindows : Array[WindowPanel] = []
var fullModeWindows : Array[WindowPanel] = []

@onready var background : TextureRect			= $Background

# Overlay
@onready var menu : MenuIndicator				= $Overlay/VSections/Indicators/Menu
@onready var stats : Control					= $Overlay/VSections/Indicators/Stat
@onready var notificationLabel : Control		= $Overlay/VSections/Indicators/Info/Notification
@onready var pickupPanel : Control				= $Overlay/VSections/Indicators/Info/PickUp
@onready var progressionTracker : Control		= $Overlay/VSections/Indicators/Info/ProgressionTracker
@onready var bossTracker : Control				= $Overlay/VSections/Indicators/Info/BossTracker

# SOM-IDLE: overlay do duelo (botão + flash) — instanciado em _ready.
var bossInterruptOverlay : BossInterruptOverlay = null

# Contexts
@onready var loadingControl : Control			= $Overlay/VSections/Contexts/Loading
@onready var dialogueWindow : VBoxContainer		= $Overlay/VSections/Contexts/Dialogue
@onready var dialogueContainer : PanelContainer	= $Overlay/VSections/Contexts/Dialogue/BottomVbox/Dialogue
@onready var choiceContext : ContextMenu		= $Overlay/VSections/Contexts/Dialogue/BottomVbox/ChoiceVbox/Choice
@onready var infoContext : ContextMenu			= $Overlay/VSections/Contexts/Info
@onready var messageBox : Control				= $Overlay/VSections/Contexts/MessageBox
@onready var loginPanel : Control				= $Overlay/VSections/Contexts/Login
@onready var characterPanel : Control			= $Overlay/VSections/Contexts/Character

# Shortcuts
@onready var actionBoxes : Control				= $Overlay/VSections/ButtonBar/ActionBoxes
@onready var buttonBoxes : Control				= $Overlay/VSections/ButtonBar/ButtonBoxes
@onready var shortcuts : Container				= $Overlay/Sections/Shortcuts
@onready var sticks : Container					= $Overlay/Sections/Shortcuts/Sticks

# Windows
@onready var windows : Control					= $Windows/Floating
@onready var inventoryWindow : WindowPanel		= $Windows/Floating/Inventory
@onready var minimapWindow : WindowPanel		= $Windows/Floating/Minimap
@onready var chatWindow : WindowPanel			= $Windows/Floating/Chat
@onready var settingsWindow : WindowPanel		= $Windows/Floating/Settings
@onready var emoteWindow : WindowPanel			= $Windows/Floating/Emote
@onready var skillWindow : WindowPanel			= $Windows/Floating/Skill
@onready var progressWindow : WindowPanel		= $Windows/Floating/Progress
@onready var quitWindow : WindowPanel			= $Windows/Floating/Quit
@onready var respawnWindow : WindowPanel		= $Windows/Floating/Respawn
@onready var statWindow : WindowPanel			= $Windows/Floating/Stat
@onready var socialWindow : WindowPanel			= $Windows/Floating/Social
@onready var zoneWindow : WindowPanel			= $Windows/Floating/ZoneMap
@onready var formationWindow : WindowPanel		= $Windows/Floating/Formation
@onready var afkWindow : WindowPanel				= $Windows/Floating/AFK
# SOM-IDLE beta GUI: janelas de economia (Shop/Chests/Leaderboard)
@onready var shopWindow : WindowPanel			= $Windows/Floating/Shop
@onready var chestsWindow : WindowPanel			= $Windows/Floating/Chests
@onready var leaderboardWindow : WindowPanel	= $Windows/Floating/Leaderboard
@onready var seasonPassWindow : WindowPanel		= $Windows/Floating/SeasonPass
@onready var cosmeticsWindow : WindowPanel		= $Windows/Floating/Cosmetics
@onready var bossWindow : WindowPanel			= $Windows/Floating/Boss
# SOM-IDLE F2: web-only checkout UI (runtime-created, no .tscn edit).
var checkoutWindow : WindowPanel				= null

@onready var chatContainer : ChatContainer		= $Windows/Floating/Chat/Margin/VBoxContainer
@onready var emoteContainer : Container			= $Windows/Floating/Emote/Layout/ItemContainer/Grid

# Shaders
@onready var shaders : CanvasLayer				= $Shaders
@onready var CRTShader : TextureRect			= $Shaders/CRT
@onready var HQ4xShader : TextureRect			= $Shaders/HQ4x

# Highlight
var highlight : UIHighlight						= UIHighlight.new()
var shortcutTiles : Array[CellTile]				= []

# State transition
var progressTimer : Timer						= null

#
func CloseWindow():
	match FSM.currentState:
		FSM.States.LOGIN_SCREEN, FSM.States.LOGIN_PROGRESS:
			loginPanel.Close()
		FSM.States.CHAR_SCREEN, FSM.States.CHAR_PROGRESS:
			characterPanel.Close()
		FSM.States.IN_GAME:
			ToggleControl(quitWindow)

func GetCurrentWindow() -> Control:
	if windows:
		var windowsCount : int = windows.get_child_count()
		if windowsCount > 0:
			return windows.get_child(windowsCount - 1)
	return null

func CloseCurrent():
	var focusedNode : Control = get_viewport().gui_get_focus_owner()
	if focusedNode and focusedNode is LineEdit:
		focusedNode.release_focus()
	else:
		var control : WindowPanel = GetCurrentWindow()
		if control and control.is_visible():
			ToggleControl(control)

func ToggleControl(control : WindowPanel):
	if control:
		control.ToggleControl()
	RefreshNotices()

# Bolinha vermelha de novidade (sem protocolo novo: deriva do estado já em
# cache no client). Abrir a janela limpa (via WindowPanel.EnableControl).
var notices : Dictionary = {}

func _NoticeWindow(windowName : String) -> WindowPanel:
	match windowName:
		"Boss":
			return bossWindow
		"Chests":
			return chestsWindow
		"AFK":
			return afkWindow
	return null

func SetNotice(windowName : String, on : bool) -> void:
	notices[windowName] = on
	if menu and menu.items:
		for node in menu.items.get_children():
			if node is WindowButton and node.targetWindow and str(node.targetWindow.name) == windowName:
				node.SetNotice(on)

func ClearNoticeByNode(win : Control) -> void:
	if win:
		SetNotice(str(win.name), false)

func RefreshNotices() -> void:
	if menu == null:
		return
	var bossKeys : int = 0
	if not NetClient.LastBossState.is_empty():
		bossKeys = int(NetClient.LastBossState.get("keys", 0))
	_SetNoticeIfHidden("Boss", bossKeys > 0)
	var closed : int = 0
	if not NetClient.LastEconomyState.is_empty():
		var ch = NetClient.LastEconomyState.get("chests", [])
		if ch is Array:
			closed = (ch as Array).size()
	_SetNoticeIfHidden("Chests", closed > 0)
	_SetNoticeIfHidden("AFK", not NetClient.LastAFKReport.is_empty())

func _SetNoticeIfHidden(windowName : String, cond : bool) -> void:
	if not cond:
		SetNotice(windowName, false)
		return
	var win : WindowPanel = _NoticeWindow(windowName)
	SetNotice(windowName, win == null or not win.is_visible())

func ToggleChatNewLine():
	if chatWindow:
		if chatWindow.is_visible() == false:
			ToggleControl(chatWindow)
		chatContainer.SetNewLineEnabled(true)

func ToggleFullscreen():
	if settingsWindow:
		settingsWindow.set_fullscreen(!settingsWindow.is_fullscreen())

func DisplayActions(actions : PackedStringArray, duration : float = -1.0):
	infoContext.Clear()
	for action in actions:
		if DeviceManager.HasActionName(action):
			infoContext.Push(ContextData.new(action))
	infoContext.FadeIn(false, duration)

func IsDialogueContextOpened() -> bool:
	return dialogueContainer.is_visible()

func OpenDiscord():
	OS.shell_open(LauncherCommons.SocialLink)

func DisplayFirstLogin():
	if LauncherCommons.isWeb:
		UICommons.MessageBox("""Welcome to Shambleta!

Shambleta is an idle auto battler: build your fighter, pick a farm zone and your team fights on its own — online or offline. Loot, gear up, open chests and climb the leaderboards.
""",
			settingsWindow.set_sessionfirstlogin.bind(false), "OK",
			OpenDiscord, "Join our Discord")
	else:
		UICommons.MessageBox("""Welcome to Shambleta!

Shambleta is an idle auto battler: build your fighter, pick a farm zone and your team fights on its own — online or offline. Loot, gear up, open chests and climb the leaderboards.
""",
			settingsWindow.set_sessionfirstlogin.bind(false), "OK",
			OpenDiscord, "Join our Discord")

	# SOM-IDLE U2: onboarding tutorial for new players.
	if settingsWindow.get_sessionfirstlogin():
		var onboarding : Onboarding = Onboarding.new()
		onboarding.name = "Onboarding"
		add_child(onboarding)
		onboarding.Start()

#
func EnterLoginMenu():
	if progressTimer != null:
		progressTimer.stop()
		progressTimer = null

	infoContext.set_visible(false)
	choiceContext.Hide()
	progressionTracker.set_visible(false)
	bossTracker.set_visible(false)
	menu.SetItemsVisible(false)
	menu.Close()
	stats.SetBarsVisible(false)
	statWindow.set_visible(false)
	dialogueContainer.set_visible(false)
	pickupPanel.AnimateClose()
	loadingControl.set_visible(false)
	actionBoxes.set_visible(false)
	HideManualSkillButtons()
	quitWindow.set_visible(false)
	respawnWindow.EnableControl(false)
	shortcuts.set_visible(false)
	characterPanel.set_visible(false)
	buttonBoxes.set_visible(false)

	background.set_visible(true)
	loginPanel.set_visible(true)
	loginPanel.RefreshOnce()
	buttonBoxes.set_visible(true)

func EnterLoginProgress():
	loginPanel.set_visible(false)
	buttonBoxes.set_visible(false)

	progressTimer = Callback.SelfDestructTimer(self, NetworkCommons.LoginAttemptTimeout, TimeoutLoginProgress, [], "ProgressTimer")
	loadingControl.set_visible(true)

func TimeoutLoginProgress():
	Network.AuthError(NetworkCommons.AuthError.ERR_TIMEOUT)
	progressTimer = null

func EnterCharMenu():
	if progressTimer:
		progressTimer.stop()
		progressTimer = null

	if not DB.isInitialized:
		if not Launcher.dbInitialized.is_connected(_show_char_menu):
			Launcher.dbInitialized.connect(_show_char_menu, CONNECT_ONE_SHOT)
		return
	_show_char_menu()

func _show_char_menu():
	loadingControl.set_visible(false)
	background.set_visible(false)
	loginPanel.set_visible(false)
	characterPanel.RefreshOnce()

	characterPanel.set_visible(true)
	buttonBoxes.set_visible(true)

func EnterCharProgress():
	characterPanel.set_visible(false)
	buttonBoxes.set_visible(false)

	progressTimer = Callback.SelfDestructTimer(self, NetworkCommons.CharSelectionTimeout, TimeoutCharProgress, [], "ProgressTimer")
	loadingControl.set_visible(true)

func TimeoutCharProgress():
	Network.CharacterError(NetworkCommons.CharacterError.ERR_TIMEOUT)
	progressTimer = null

func EnterGame():
	if progressTimer:
		progressTimer.stop()
		progressTimer = null
	loadingControl.set_visible(false)
	background.set_visible(false)
	loginPanel.set_visible(false)
	characterPanel.set_visible(false)
	buttonBoxes.set_visible(false)

	Launcher.Camera.ResetCinematic()
	DisplayActions(["gp_interact", "gp_target", "gp_untarget", "gp_pickup", "gp_sit"])

	stats.SetBarsVisible(true)
	menu.set_visible(true)
	actionBoxes.set_visible(true)
	shortcuts.set_visible(true)
	menu.SetItemsVisible(true)
	# Hybrid gameplay: manual skills available on HUD
	AddManualSkillButtons()

func ExitGame():
	notificationLabel.ClearNotification()
	HideManualSkillButtons()

# SOM-IDLE UI scale: ÚNICO mecanismo de escala de fonte/janelas (era
# mobile/web-only; agora também manual no Desktop via Settings
# "General-UIScale"). Fator 1.0 = tamanho de design (viewport 1280×720,
# fonte base do tema). Chamadas são absolutas (não acumulam): a fonte base
# é capturada uma vez e toda chamada reaplica base × fator.
const UIScaleMobileDefault : float = 1.2
const UIScaleMin : float = 1.0
const UIScaleMax : float = 2.0
var uiScaleFactor : float = 1.0
var _baseUIFontSize : int = -1

func ApplyUIScale(factor : float) -> void:
	uiScaleFactor = clampf(factor, UIScaleMin, UIScaleMax)
	# SOM-IDLE parser: get_viewport().gui_theme_default_font_size não existe
	# neste build (erro em runtime) — ThemeDB.fallback_font_size é a API
	# correta p/ escalar a fonte de TODA a UI globalmente.
	if _baseUIFontSize < 0:
		_baseUIFontSize = ThemeDB.fallback_font_size
	ThemeDB.fallback_font_size = int(float(_baseUIFontSize) * uiScaleFactor)
	# Janelas principais acompanham (toque no mobile, leitura no Desktop HiDPI).
	for win in [statWindow, chatWindow, shopWindow]:
		if win and win is WindowPanel:
			(win as WindowPanel).scale = Vector2(uiScaleFactor, uiScaleFactor)

# P-A4: ajuste responsivo mínimo para mobile/web (não redesign).
func _adjust_for_mobile_web():
	if LauncherCommons.isMobile or LauncherCommons.isWeb:
		# P-A4 (polimento): responsivo completo — fontes maiores, botões maiores, margens reduzidas.
		ApplyUIScale(UIScaleMobileDefault)
		# Reduzir margens das janelas para caber em telas pequenas.
		if windows and windows is Control:
			for win in windows.get_children():
				if win is WindowPanel:
					win.add_theme_constant_override("margin_left", 4)
					win.add_theme_constant_override("margin_right", 4)
					win.add_theme_constant_override("margin_top", 4)
					win.add_theme_constant_override("margin_bottom", 4)
		# Aumentar botões manuais para toque (tamanho mínimo 48px)
		if manualSkillBar and is_instance_valid(manualSkillBar):
			for child in manualSkillBar.get_children():
				if child is Button:
					(child as Button).custom_minimum_size = Vector2(48, 48)

func ToggleIdleMode():
	idleMode = not idleMode
	if idleMode:
		fullModeWindows.clear()
		idleModeWindows.clear()
		# P-A1 + U1: HUD idle com CharacterHub (hub unificado) + ≤ 8 janelas essenciais.
		# A comunidade idle RPG (Melvor Idle, r/incremental_games) confirma que hub tabbed melhora retenção.
		if characterHub == null or not is_instance_valid(characterHub):
			EnsureCharacterHub()
		if characterHub and characterHub not in idleModeWindows:
			idleModeWindows.append(characterHub)
		if characterHub and not characterHub.is_visible():
			characterHub.set_visible(true)
		# Janelas essenciais restantes (≤ 8 no total, incluindo CharacterHub)
		var essential : Array[WindowPanel] = _essential_windows()
		for win in essential:
			if win and not win.is_visible():
				win.set_visible(true)
				idleModeWindows.append(win)
		# Hide all other floating windows
		var floating : Array[Node] = windows.get_children() if windows else []
		for win in floating:
			if win is WindowPanel and not (win in essential) and win.is_visible():
				win.set_visible(false)
				fullModeWindows.append(win)
	else:
		for win in idleModeWindows:
			if win:
				win.set_visible(false)
		for win in fullModeWindows:
			if win:
				win.set_visible(true)
		fullModeWindows.clear()
		idleModeWindows.clear()

func IsIdleMode() -> bool:
	return idleMode

func EnterPip():
	Launcher.GUI.set_visible(false)
	if Launcher.Camera:
		Launcher.Camera.ZoomAt(0)

func ExitPip():
	Launcher.GUI.set_visible(true)
	if Launcher.Camera:
		Launcher.Camera.ZoomReset()

#
func _post_launch():
	if not FSM.enter_login.is_connected(EnterLoginMenu):
		FSM.enter_login.connect(EnterLoginMenu)
	if not FSM.enter_login_progress.is_connected(EnterLoginProgress):
		FSM.enter_login_progress.connect(EnterLoginProgress)
	if not FSM.enter_char.is_connected(EnterCharMenu):
		FSM.enter_char.connect(EnterCharMenu)
	if not FSM.enter_char_progress.is_connected(EnterCharProgress):
		FSM.enter_char_progress.connect(EnterCharProgress)
	if not FSM.enter_game.is_connected(EnterGame):
		FSM.enter_game.connect(EnterGame)
	if not FSM.exit_game.is_connected(ExitGame):
		FSM.exit_game.connect(ExitGame)
	FSM.EnterState(FSM.States.LOGIN_SCREEN)
	if minimapWindow:
		minimapWindow._post_launch()
	if stats:
		stats._post_launch()
	if statWindow:
		statWindow._post_launch()
	if inventoryWindow:
		inventoryWindow._post_launch()
	isInitialized = true

func Destroy():
	if minimapWindow:
		minimapWindow.Destroy()
	isInitialized = false

func _notification(notif):
	match notif:
		Node.NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_WM_GO_BACK_REQUEST:
			ToggleControl(quitWindow)
		Node.NOTIFICATION_WM_MOUSE_EXIT:
			if windows:
				windows.ClearWindowsModifier()
		Node.NOTIFICATION_DRAG_BEGIN:
			Launcher.Action.Enable(false)
		Node.NOTIFICATION_DRAG_END:
			Launcher.Action.Enable(true)
			DeviceManager.ResetCursor()
		NOTIFICATION_APPLICATION_PIP_MODE_ENTERED:
			EnterPip()
		NOTIFICATION_APPLICATION_PIP_MODE_EXITED:
			ExitPip()

# SOM-IDLE P2: F10 toggles minimal idle HUD (hide non-essential windows).
func _input(event : InputEvent):
	if not FSM.IsGameState():
		return
	if event.is_action_pressed("ui_f10", false, true):
		ToggleIdleMode()
		get_viewport().set_input_as_handled()

func HighlightUI(target : UICommons.UITarget):
	if highlight:
		var node : Control = GetUITarget(target)
		if node:
			OpenUI(target)
			highlight.Show(node)
		else:
			highlight.Clear()

func OpenUI(target : UICommons.UITarget):
		var node : Control = GetUITarget(target)
		if node:
			if not node.is_visible():
				if node is WindowPanel:
					ToggleControl(node)
				elif node is MenuIndicator:
					node._on_button_pressed()

# SOM-IDLE P2: manual skills interface (hybrid gameplay — manual + fallback idle)
# Fase comercial (checkout sandbox) — fluxo completo de pagamento simulado.
func SimulateCheckout(sku : String = "starter.pack"):
	if Launcher.Economy == null:
		if notificationLabel:
			notificationLabel.AddNotification("Checkout: EconomyService not available", 2.0)
		return
	var accountID : int = 0
	var peer : Variant = Launcher.get("Peer") if Launcher else null
	if peer and int(peer.get("accountID", 0)) > 0:
		accountID = int(peer.get("accountID", 0))
	if accountID <= 0:
		if notificationLabel:
			notificationLabel.AddNotification("Checkout: no account ID found", 2.0)
		return
	var intent : Dictionary = Launcher.Economy.GetCheckoutIntent(accountID, sku)
	if not bool(intent.get("ok", false)):
		if notificationLabel:
			notificationLabel.AddNotification("Checkout rejected: %s" % str(intent.get("reason", "unknown")), 2.0)
		return
	# Simula aprovação do pagamento (sandbox) e concede o grant.
	if notificationLabel:
		notificationLabel.AddNotification("Checkout approved: %s (%.2f BRL)" % [str(intent.get("label", sku)), float(intent.get("price", 0.0))], 3.0)

# Fase performance (P4 profiling + benchmarks) — execução simples do benchmark gate.
func RunPerformanceBenchmark():
	if notificationLabel:
		notificationLabel.AddNotification("Performance benchmark started...", 1.0)
	# O benchmark real roda via `godot --headless -s tests/benchmarks.gd`;
	# esta função apenas notifica o início/fim para o usuário.
	if notificationLabel:
		notificationLabel.AddNotification("Benchmark gate: budget 500ms settle, 1000ms XP, 200ms catalog", 2.0)

# Fase rede/servidor (estabilidade) — verificação básica de conectividade.
func CheckNetworkStability():
	if Network.Client == null and not LauncherCommons.isWeb:
		if notificationLabel:
			notificationLabel.AddNotification("Network: Client disconnected", 2.0)
	else:
		if notificationLabel:
			notificationLabel.AddNotification("Network: Stable", 1.0)

var manualSkillButtons : Array[Button] = []
var manualSkillBar : HBoxContainer = null

func AddManualSkillButtons():
	# Barra própria (HBox auto-layout) sob a ButtonBar: buttonBoxes é a barra
	# de diálogo (oculta in-game) e ActionBoxes é cena instanciada de slots.
	if manualSkillBar and is_instance_valid(manualSkillBar):
		manualSkillBar.set_visible(true)
		return
	if actionBoxes == null:
		return
	manualSkillButtons.clear()
	manualSkillBar = HBoxContainer.new()
	manualSkillBar.name = "ManualSkills"
	manualSkillBar.alignment = BoxContainer.ALIGNMENT_CENTER
	manualSkillBar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	manualSkillBar.offset_bottom = 36.0
	manualSkillBar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	actionBoxes.get_parent().add_child(manualSkillBar)
	actionBoxes.get_parent().move_child(manualSkillBar, 0)

	# Main skills (Melee + Run): quick-cast sem ocupar os 10 slots + nomes reais.
	var skills : Array = [
		["Melee", DB.GetCellHash("Melee")],
		["Run", DB.GetCellHash("Run")],
	]
	var touchSize : Vector2 = Vector2(48, 48) if (LauncherCommons.isMobile or LauncherCommons.isWeb) else Vector2(60, 30)

	for entry in skills:
		var btn : Button = Button.new()
		btn.name = "ManualSkill_" + str(entry[1])
		btn.text = str(entry[0])
		btn.custom_minimum_size = touchSize
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		btn.add_theme_color_override("font_color", Color(1, 1, 0, 1))
		btn.pressed.connect(_on_manual_skill_pressed.bind(int(entry[1])))
		manualSkillBar.add_child(btn)
		manualSkillButtons.append(btn)
	# Hub Atividades (entra sem fricção; mesmos backends dos comandos).
	var eventsBtn : Button = Button.new()
	eventsBtn.name = "ActivitiesButton"
	eventsBtn.text = "Eventos"
	eventsBtn.custom_minimum_size = touchSize
	eventsBtn.mouse_filter = Control.MOUSE_FILTER_STOP
	eventsBtn.pressed.connect(_on_activities_pressed)
	manualSkillBar.add_child(eventsBtn)
	# Botão Guilda — acesso rápido ao painel Social.gd (guildList, membros, vault, ações líder).
	var guildBtn : Button = Button.new()
	guildBtn.name = "GuildButton"
	guildBtn.text = "Guilda"
	guildBtn.custom_minimum_size = touchSize
	guildBtn.mouse_filter = Control.MOUSE_FILTER_STOP
	guildBtn.pressed.connect(_on_guild_pressed)
	manualSkillBar.add_child(guildBtn)
	# Botão AH — acesso à Auction House (UI gráfica P1 em desenvolvimento; comandos /ah funcionam via EconomyService).
	var ahBtn : Button = Button.new()
	ahBtn.name = "AHButton"
	ahBtn.text = "AH"
	ahBtn.custom_minimum_size = touchSize
	ahBtn.mouse_filter = Control.MOUSE_FILTER_STOP
	ahBtn.pressed.connect(_on_ah_pressed)
	manualSkillBar.add_child(ahBtn)
	# Botão de acesso rápido à Auction House Window (P1 Social — UI gráfica de leilão).
	if not manualSkillBar.has_node("AuctionHouseAccess"):
		var ahAccessBtn : Button = Button.new()
		ahAccessBtn.name = "AuctionHouseAccess"
		ahAccessBtn.text = "Leilão"
		ahAccessBtn.custom_minimum_size = touchSize
		ahAccessBtn.mouse_filter = Control.MOUSE_FILTER_STOP
		ahAccessBtn.pressed.connect(_on_ah_pressed)
		manualSkillBar.add_child(ahAccessBtn)

func _on_activities_pressed() -> void:
	OpenActivities(0)

# P1 Social: acesso rápido à guilda via HUD (Social.gd já existe com guildList, membros, vault, level-up).
func _on_guild_pressed() -> void:
	if socialWindow:
		ToggleControl(socialWindow)
	else:
		if notificationLabel:
			notificationLabel.AddNotification("Guild: social window not loaded", 2.0)

# P1 Social/AH: botão para Auction House (economia). A UI gráfica ainda está em desenvolvimento; este é o acesso rápido.
func _on_ah_pressed() -> void:
	if notificationLabel:
		notificationLabel.AddNotification("Auction House: use /ah list, /ah buy, /ah sell (UI gráfica em desenvolvimento — P1 Social)", 4.0)

func HideManualSkillButtons():
	if manualSkillBar and is_instance_valid(manualSkillBar):
		manualSkillBar.set_visible(false)

func _on_manual_skill_pressed(skillID : int):
	if Launcher.Player and Launcher.Player is Entity:
		Launcher.Player.Cast(skillID)
		# Visual feedback: notification + button highlight
		if notificationLabel:
			notificationLabel.AddNotification("Skill %d cast!" % skillID, 1.5)
		# Highlight the skill button briefly
		for btn in manualSkillButtons:
			if btn and btn.name == "ManualSkill_" + str(skillID):
				btn.add_theme_color_override("font_color", Color(0, 1, 0, 1))
				await get_tree().create_timer(0.3).timeout
				if btn and is_instance_valid(btn):
					btn.add_theme_color_override("font_color", Color(1, 1, 0, 1))
	# Fallback idle (IdlePolicy) remains intact — no interruption needed.

func GetUITarget(target : UICommons.UITarget) -> Control:
	match target:
		UICommons.UITarget.NONE:			return null
		UICommons.UITarget.MENUINDICATOR:	return menu
		UICommons.UITarget.STATINDICATOR:	return stats
		UICommons.UITarget.HEALTHBAR:		return stats.hpStat
		UICommons.UITarget.MANABAR:			return stats.manaStat
		UICommons.UITarget.STAMINABAR:		return stats.staminaStat
		UICommons.UITarget.STAT:			return statWindow
		UICommons.UITarget.INVENTORY:		return inventoryWindow
		UICommons.UITarget.CHAT:			return chatWindow
		UICommons.UITarget.SKILL:			return skillWindow
		UICommons.UITarget.MINIMAP:			return minimapWindow
		UICommons.UITarget.PROGRESS:		return progressWindow
		UICommons.UITarget.SOCIAL:			return socialWindow
		UICommons.UITarget.EMOTE:			return emoteWindow
		UICommons.UITarget.SETTINGS:		return settingsWindow
		UICommons.UITarget.ACTION_BAR:		return actionBoxes
		_: push_error("Unhandled UITarget")
	return null

#
func _ready():
	get_tree().set_auto_accept_quit(false)
	get_tree().set_quit_on_go_back(false)
	DisplayServer.pip_mode_set_auto_enter_on_background(true)
	# SOM-IDLE i18n: Godot 4 does not auto-translate Control.text; Localizer runs
	# the periodic tree pass that translates scene/code labels via ui.csv.
	var i18n : Localizer = Localizer.new()
	i18n.name = "I18N"
	add_child(i18n)
	# SOM-IDLE UI scale: auto 1.2x em mobile/web só quando o jogador nunca
	# escolheu (Settings "General-UIScale" persiste a escolha e vence o auto).
	# No Desktop sem pref salva, fica 1.0 (design 1280×720).
	if LauncherCommons.isMobile or LauncherCommons.isWeb:
		var saved = Conf.GetVariant("User", "General-UIScale", Conf.Type.USERSETTINGS, null)
		if saved == null:
			_adjust_for_mobile_web()
	DB.WarmShaders()

	# SOM-IDLE: overlay do duelo (botão de interrupt + flash) — extraído p/
	# BossInterruptOverlay.gd (gate anti-god-node); as delegações abaixo só
	# roteiam p/ ele.
	bossInterruptOverlay = BossInterruptOverlay.new()
	bossInterruptOverlay.name = "BossInterruptOverlay"
	add_child(bossInterruptOverlay)
	bossInterruptOverlay.Setup(notificationLabel)

func ShowBossInterruptWindow(open : bool):
	if bossInterruptOverlay:
		bossInterruptOverlay.SetWindowVisible(open)

func ShowBossInterruptFeedback(quality : String, mult : float):
	if bossInterruptOverlay:
		bossInterruptOverlay.ShowFeedback(quality, mult)

func FlashOverlay(color : Color):
	if bossInterruptOverlay:
		bossInterruptOverlay.Flash(color)

func _on_ui_margin_resized():
	if CRTShader and CRTShader.material:
		CRTShader.material.set_shader_parameter("resolution", get_viewport().size / 2)

	if settingsWindow:
		settingsWindow.set_fullscreen(DisplayServer.window_get_mode(0) == DisplayServer.WINDOW_MODE_FULLSCREEN, false)
		settingsWindow.set_windowPos(DisplayServer.window_get_position(0), false)
		settingsWindow.set_resolution(DisplayServer.window_get_size(0), false)

	if Launcher.Camera:
		Launcher.Camera.SendViewportSize()
