extends WindowPanel

var platformSection : String					= Util.GetPlatformName()
const defaultSection : String					= "Default"
const userSection : String						= "User"

const creditsJson : JSON						= preload("res://data/db/credits.json")

@onready var creditsContainer : VBoxContainer	= $Layout/Margin/TabBar/Credits/Margin/VBox
@onready var accountVBox : VBoxContainer		= $Layout/Margin/TabBar/Account/AccountVBox

# SOM-IDLE S4: 2FA UI state.
var _twoFactorButton : Button					= null
var _twoFactorQRDialog : AcceptDialog			= null

@onready var renderAccessors : Dictionary = {
	"Render-MinWindowSize": [init_minwinsize, set_minwinsize, apply_minwinsize, null],
	"Render-Fullscreen": [init_fullscreen, set_fullscreen, apply_fullscreen, $Layout/Margin/TabBar/Render/RenderVBox/VisualVBox/Fullscreen],
	"Render-Scaling": [init_scaling, set_scaling, apply_scaling, $Layout/Margin/TabBar/Render/RenderVBox/VisualVBox/Scaling/Option],
	"Render-WindowSize": [init_resolution, set_resolution, apply_resolution, $Layout/Margin/TabBar/Render/RenderVBox/VisualVBox/WindowResolution/Option],
	"Render-WindowPos": [init_windowPos, set_windowPos, apply_windowPos, null],
	"Render-ActionOverlay": [init_actionoverlay, set_actionoverlay, apply_actionoverlay, $Layout/Margin/TabBar/Render/RenderVBox/VisualVBox/ActionOverlay],
	"Render-Lighting": [init_lighting, set_lighting, apply_lighting, $Layout/Margin/TabBar/Render/RenderVBox/EffectVBox/Lighting],
	"Render-HQ4x": [init_hq4x, set_hq4x, apply_hq4x, $Layout/Margin/TabBar/Render/RenderVBox/EffectVBox/HQx4],
	"Render-CRT": [init_crt, set_crt, apply_crt, $Layout/Margin/TabBar/Render/RenderVBox/EffectVBox/CRT],
	"Audio-General": [init_audiogeneral, set_audiogeneral, apply_audiogeneral, $"Layout/Margin/TabBar/Audio/VBoxContainer/Global Volume/HSlider"],
	"Audio-Alteration": [init_audioalteration, set_audioalteration, apply_audioalteration, $"Layout/Margin/TabBar/Audio/VBoxContainer/Alteration SFX Volume/HSlider"],
	"Audio-State": [init_audiostate, set_audiostate, apply_audiostate, $"Layout/Margin/TabBar/Audio/VBoxContainer/State SFX Volume/HSlider"],
	"Session-AccountName": [init_sessionaccountname, set_sessionaccountname, apply_sessionaccountname, null],
	"Session-FirstLogin": [init_sessionfirstlogin, set_sessionfirstlogin, apply_sessionfirstlogin, null],
	"Session-Overlay": [init_sessionoverlay, set_sessionoverlay, apply_sessionoverlay, null],
	"Session-ShortcutCells": [init_shortcutcells, set_shortcutcells, apply_shortcutcells, null],
	"Web-PushEnabled": [init_webpush, set_webpush, apply_webpush, null],
	"Input-Bindings": [init_inputbindings, null, null, null],
	"Account-PasswordChange": [null, set_account_password, null, $Layout/Margin/TabBar/Account],
	"Privacy-BugReports": [init_bugreports, set_bugreports, apply_bugreports, $Layout/Margin/TabBar/Privacy/PrivacyVBox/BugReports],
	"Network-Local": [init_localserver, set_localserver, apply_localserver, $Layout/Margin/TabBar/Privacy/PrivacyVBox/LocalServer],
}

enum CATEGORY { RENDER, SOUND, INPUT, COUNT }
enum ACC_TYPE { INIT, SET, APPLY, LABEL }

# MinWindowSize
func init_minwinsize(apply : bool):
	if apply:
		var minSize : Vector2 = GetVal("Render-MinWindowSize")
		apply_minwinsize(minSize)
func set_minwinsize(minSize : Vector2):
	SetVal("Render-MinWindowSize", minSize)
	apply_minwinsize(minSize)
func apply_minwinsize(minSize : Vector2):
	DisplayServer.window_set_min_size(minSize, 0)

# FullScreen
func init_fullscreen(apply : bool):
	var pressed : bool = is_fullscreen()
	renderAccessors["Render-Fullscreen"][ACC_TYPE.LABEL].set_pressed_no_signal(pressed)
	if apply:
		apply_fullscreen(pressed)
func is_fullscreen() -> bool:
	return GetVal("Render-Fullscreen")
func set_fullscreen(pressed : bool, apply : bool = true):
	SetVal("Render-Fullscreen", pressed)
	if apply:
		apply_fullscreen(pressed)
func apply_fullscreen(pressed : bool):
	renderAccessors["Render-Fullscreen"][ACC_TYPE.LABEL].set_pressed_no_signal(pressed)
	if pressed:
		clear_resolution_labels()
		if DisplayServer.window_get_mode(0) != DisplayServer.WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		populate_resolution_labels(DisplayServer.screen_get_size())
		if DisplayServer.window_get_mode(0) != DisplayServer.WINDOW_MODE_WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)

# Window Resolution
const resolutionEntriesCount : int = 5
func init_resolution(apply : bool):
	var resolution : Vector2i = GetVal("Render-WindowSize")
	populate_resolution_labels(resolution)
	if apply:
		apply_resolution(resolution)
func clear_resolution_labels():
	renderAccessors["Render-WindowSize"][ACC_TYPE.LABEL].clear()
func populate_resolution_labels(resolution : Vector2i):
	clear_resolution_labels()
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN:
		var minScreenSize : Vector2i = GetVal("Render-MinWindowSize")
		var maxScreenSize : Vector2i = DisplayServer.screen_get_size()
		var label : OptionButton = renderAccessors["Render-WindowSize"][ACC_TYPE.LABEL]
		for i in resolutionEntriesCount:
			var item : Vector2i = calculate_resolution(i, minScreenSize, maxScreenSize)
			label.add_item(str(item))
		label.add_separator()
		label.add_item(str(resolution))
		label.selected = label.item_count - 1
func calculate_resolution(index : int, minScreenSize : Vector2, maxScreenSize : Vector2) -> Vector2i:
	return lerp(minScreenSize, maxScreenSize, index / maxf(resolutionEntriesCount - 1, 1.0))
func set_resolutionIdx(resolutionIdx : int):
	var minScreenSize : Vector2i = GetVal("Render-MinWindowSize")
	var maxScreenSize : Vector2i = DisplayServer.screen_get_size()
	var resolution : Vector2i = calculate_resolution(resolutionIdx, minScreenSize, maxScreenSize)
	set_resolution(resolution)
func set_resolution(resolution : Vector2i, apply : bool = true):
	SetVal("Render-WindowSize", resolution)
	if apply:
		apply_resolution(resolution)
func apply_resolution(resolution : Vector2i):
	var windowSize : Vector2i = DisplayServer.screen_get_size()
	var minScreenSize : Vector2i = GetVal("Render-MinWindowSize")

	var newSize : Vector2i = clamp(resolution, minScreenSize, windowSize)
	var currentPos : Vector2i = GetVal("Render-WindowPos")
	if currentPos == Vector2i(-1, -1):
		currentPos = (windowSize - newSize) / 2.0
	var newPosition : Vector2i = Vector2i(clampi(currentPos.x, 0, (windowSize - newSize).x), clampi(currentPos.y, 0, (windowSize - newSize).y))
	DisplayServer.window_set_size(newSize)
	set_windowPos(newPosition)
	init_actionoverlay(true)
	populate_resolution_labels(newSize)

# Window Position
func init_windowPos(apply : bool):
	if apply:
		var pos : Vector2 = GetVal("Render-WindowPos")
		apply_windowPos(pos)
func set_windowPos(pos : Vector2, apply : bool = true):
	SetVal("Render-WindowPos", pos)
	if apply:
		apply_windowPos(pos)
func save_windowPos():
	set_windowPos(get_viewport().get_position())
func apply_windowPos(pos : Vector2):
	DisplayServer.window_set_position(pos)

# DoubleResolution
func init_scaling(apply : bool):
	var mode : int = GetVal("Render-Scaling")
	renderAccessors["Render-Scaling"][ACC_TYPE.LABEL].selected = mode
	if apply:
		apply_scaling(mode)
func set_scaling(mode : int):
	SetVal("Render-Scaling", mode)
	apply_scaling(mode)
func apply_scaling(mode : int):
	Launcher.Root.set_content_scale_factor(mode + 1)
	init_actionoverlay(true)

# Language (SOM-IDLE i18n)
const LanguageOptions : Array[String] = ["auto", "en", "pt_BR"]
func init_language(apply : bool):
	var setting : String = str(GetVal("General-Language"))
	var idx : int = LanguageOptions.find(setting)
	if idx < 0:
		idx = 0
	renderAccessors["General-Language"][ACC_TYPE.LABEL].selected = idx
	if apply:
		apply_language(idx)
func set_language(idx : int):
	SetVal("General-Language", LanguageOptions[idx])
	apply_language(idx)
	# OptionButton item labels bypass the Localizer prop-pass: refresh in place
	var opt : OptionButton = renderAccessors["General-Language"][ACC_TYPE.LABEL]
	opt.set_item_text(0, tr("Auto"))
	opt.set_item_text(1, "English")
	opt.set_item_text(2, "Português")
func apply_language(idx : int):
	TranslationServer.set_locale(Localizer.ResolveLocale(LanguageOptions[idx]))

# ActionOverlay
func init_actionoverlay(apply : bool):
	var enable : bool = GetVal("Render-ActionOverlay")
	renderAccessors["Render-ActionOverlay"][ACC_TYPE.LABEL].set_pressed_no_signal(enable)
	if apply:
		apply_actionoverlay(enable)
func set_actionoverlay(enable : bool):
	SetVal("Render-ActionOverlay", enable)
	apply_actionoverlay(enable)
func apply_actionoverlay(enable : bool):
	if Launcher.GUI and Launcher.GUI.sticks:
		Launcher.GUI.sticks.Enable(enable)

# Lighting
func init_lighting(apply : bool):
	var enable : bool = GetVal("Render-Lighting")
	renderAccessors["Render-Lighting"][ACC_TYPE.LABEL].set_pressed_no_signal(enable)
	if apply:
		apply_lighting(enable)
func set_lighting(enable : bool):
	SetVal("Render-Lighting", enable)
	apply_lighting(enable)
func apply_lighting(enable : bool):
	Effects.EnableLighting(enable)

# HQ4x
func init_hq4x(apply : bool):
	var enable : bool = GetVal("Render-HQ4x")
	renderAccessors["Render-HQ4x"][ACC_TYPE.LABEL].set_pressed_no_signal(enable)
	if apply:
		apply_hq4x(enable)
func set_hq4x(enable : bool):
	SetVal("Render-HQ4x", enable)
	apply_hq4x(enable)
func apply_hq4x(enable : bool):
	if Launcher.GUI and Launcher.GUI.HQ4xShader:
		Launcher.GUI.HQ4xShader.set_visible(enable)

# CRT
func init_crt(apply : bool):
	var enable : bool = GetVal("Render-CRT")
	renderAccessors["Render-CRT"][ACC_TYPE.LABEL].set_pressed_no_signal(enable)
	if apply:
		apply_crt(enable)
func set_crt(enable : bool):
	SetVal("Render-CRT", enable)
	apply_crt(enable)
func apply_crt(enable : bool):
	if Launcher.GUI and Launcher.GUI.CRTShader:
		Launcher.GUI.CRTShader.set_visible(enable)

# Audio General
func init_audiogeneral(apply : bool):
	var volumeRatio : float = GetVal("Audio-General")
	renderAccessors["Audio-General"][ACC_TYPE.LABEL].value = volumeRatio
	if apply:
		apply_audiogeneral(volumeRatio)
func set_audiogeneral(volumeRatio : float):
	SetVal("Audio-General", volumeRatio)
	apply_audiogeneral(volumeRatio)
func apply_audiogeneral(volumeRatio : float):
	if Launcher.Audio:
		Launcher.Audio.SetVolume(Util.VolumeRatioToDb(volumeRatio))

# Audio Alteration SFX
func init_audioalteration(apply : bool):
	var volumeRatio : float = GetVal("Audio-Alteration")
	renderAccessors["Audio-Alteration"][ACC_TYPE.LABEL].value = volumeRatio
	if apply:
		apply_audioalteration(volumeRatio)
func set_audioalteration(volumeRatio : float):
	SetVal("Audio-Alteration", volumeRatio)
	apply_audioalteration(volumeRatio)
func apply_audioalteration(volumeRatio : float):
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(ActorCommons.SfxAlterationBus), Util.VolumeRatioToDb(volumeRatio))

# Audio State SFX
func init_audiostate(apply : bool):
	var volumeRatio : float = GetVal("Audio-State")
	renderAccessors["Audio-State"][ACC_TYPE.LABEL].value = volumeRatio
	if apply:
		apply_audiostate(volumeRatio)
func set_audiostate(volumeRatio : float):
	SetVal("Audio-State", volumeRatio)
	apply_audiostate(volumeRatio)
func apply_audiostate(volumeRatio : float):
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(ActorCommons.SfxStateBus), Util.VolumeRatioToDb(volumeRatio))

# Session Account Name
func init_sessionaccountname(apply : bool):
	if apply:
		var accountName : String = GetVal("Session-AccountName")
		apply_sessionaccountname(accountName)
func set_sessionaccountname(accountName : String):
	SetVal("Session-AccountName", accountName)
	apply_sessionaccountname(accountName)
func apply_sessionaccountname(accountName : String):
	if Launcher.GUI and Launcher.GUI.loginPanel:
		Launcher.GUI.loginPanel.nameTextControl.set_text(accountName)

# Session First Login
func init_sessionfirstlogin(apply : bool):
	if apply:
		var firstTime : bool = GetVal("Session-FirstLogin")
		apply_sessionfirstlogin(firstTime)
func set_sessionfirstlogin(firstTime : bool):
	SetVal("Session-FirstLogin", firstTime)
	apply_sessionfirstlogin(firstTime)
func apply_sessionfirstlogin(firstTime : bool):
	if Launcher.GUI and firstTime:
		Launcher.GUI.DisplayFirstLogin()

# Session Windows Overlay placement
enum ESessionOverlay { NAME = 0, POSITION, SIZE, COUNT}
func init_sessionoverlay(apply : bool):
	if apply:
		var overlay : Array = GetVal("Session-Overlay")
		apply_sessionoverlay(overlay)
func save_sessionoverlay():
	var overlay : Array = []
	if Launcher.GUI and Launcher.GUI.windows:
		for window in Launcher.GUI.windows.get_children():
			if window.is_visible() and window.saveOverlayState:
				overlay.append([window.get_name().get_file(), window.get_position(), window.get_size()])
		set_sessionoverlay(overlay)
func reset_sessionoverlay():
	if Launcher.GUI and Launcher.GUI.windows:
		Launcher.GUI.windows.ResetWindowsLayout()
		save_sessionoverlay()
func set_sessionoverlay(overlay : Array):
	SetVal("Session-Overlay", overlay)
	apply_sessionoverlay(overlay)
func apply_sessionoverlay(overlay : Array):
	if Launcher.GUI and Launcher.GUI.windows:
		for window in overlay:
			if window.size() >= ESessionOverlay.COUNT:
				var floatingWindow : WindowPanel = Launcher.GUI.windows.get_node(window[ESessionOverlay.NAME])
				if floatingWindow:
					floatingWindow.set_visible(true)
					floatingWindow.set_size(window[ESessionOverlay.SIZE])
					floatingWindow.set_position(window[ESessionOverlay.POSITION])
					floatingWindow.UpdateWindow()

# Shortcut cells
func init_shortcutcells(apply : bool):
	if apply:
		if not DB.isInitialized:
			if not Launcher.dbInitialized.is_connected(load_shortcutcells):
				Launcher.dbInitialized.connect(load_shortcutcells, CONNECT_ONE_SHOT)
			return
		load_shortcutcells()
func load_shortcutcells():
	var cells : Array = GetVal("Session-ShortcutCells")
	apply_shortcutcells(cells)
func save_shortcutcells():
	var cells : Array = []
	if Launcher.GUI:
		for tile in Launcher.GUI.shortcutTiles:
			if tile.is_visible() and tile.cell:
				cells.append([tile.name, tile.cell.id, tile.cell.type])
		set_shortcutcells(cells)
func set_shortcutcells(cells : Array):
	SetVal("Session-ShortcutCells", cells)
func apply_shortcutcells(cells : Array):
	if Launcher.GUI:
		var tiles : Array[CellTile] = Launcher.GUI.shortcutTiles
		for tile in tiles:
			if cells.is_empty():
				break
			for cellInfo in cells:
				if cellInfo and cellInfo is Array and cellInfo.size() >= 3 and cellInfo[0] == tile.name:
					var cell : BaseCell = null
					match cellInfo[2]:
						CellCommons.Type.ITEM:
							cell = DB.ItemsDB.get(cellInfo[1])
						CellCommons.Type.EMOTE:
							cell = DB.EmotesDB.get(cellInfo[1])
						CellCommons.Type.SKILL:
							cell = DB.SkillsDB.get(cellInfo[1])
					if cell:
						tile.AssignData(cell)
						CellTile.RefreshShortcuts(cell)
					cells.erase(cellInfo)
					break

# Bug Reports
func init_bugreports(apply : bool):
	var enable : bool = GetVal("Privacy-BugReports")
	renderAccessors["Privacy-BugReports"][ACC_TYPE.LABEL].set_pressed_no_signal(enable)
	if apply:
		apply_bugreports(enable)
func set_bugreports(enable : bool):
	SetVal("Privacy-BugReports", enable)
	apply_bugreports(enable)
func apply_bugreports(_enable : bool):
	pass

# Local Server
func init_localserver(apply : bool):
	var enable : bool = GetVal("Network-Local")
	renderAccessors["Network-Local"][ACC_TYPE.LABEL].set_pressed_no_signal(enable)
	if apply:
		apply_localserver(enable)
func set_localserver(enable : bool):
	SetVal("Network-Local", enable)
	apply_localserver(enable)
func apply_localserver(_enable : bool):
	var isLocal : bool = OS.is_debug_build() and GetVal("Network-Local")
	if isLocal != NetworkCommons.IsLocal:
		NetworkCommons.IsLocal = isLocal
		if NetworkCommons.IsLocal:
			Launcher.Mode(true, false)

# Input Bindings
func init_inputbindings(apply : bool):
	if apply:
		InputBindings.LoadBindings()

# SOM-IDLE F3: web push notifications
func init_webpush(apply : bool):
	if apply:
		WebPush.Initialize()

func set_webpush(enabled : bool):
	WebPush.SetEnabled(enabled)
	if enabled and WebPush.GetPermission() == "default":
		var perm : String = WebPush.RequestPermission()
		if perm != "granted":
			WebPush.SetEnabled(false)

func apply_webpush(enabled : bool):
	pass

# Account
func set_account_password(err : NetworkCommons.AuthError):
	renderAccessors["Account-PasswordChange"][ACC_TYPE.LABEL].OnPasswordChangeResult(err)

#
func _on_visibility_changed():
	RefreshSettings(false)

func PopulateCredits():
	Scrollable.AddCategories(creditsContainer, creditsJson.get_data())

func _ready():
	if not FSM:
		return

	PopulateCredits()
	# SOM-IDLE i18n: seletor de idioma criado em runtime no topo da aba Render
	# (mesma política do botão LGPD: não edita .tscn). Persistido em USERSETTINGS
	# como "General-Language" ("auto"|"en"|"pt_BR"); aplicar o locale dispara a
	# re-tradução pela pass do Localizer (1s) — ver Localizer.gd.
	var langBox : HBoxContainer = HBoxContainer.new()
	langBox.name = "LanguageRow"
	var langLabel : Label = Label.new()
	langLabel.name = "Text"
	langLabel.text = "Language"
	var langOption : OptionButton = OptionButton.new()
	langOption.name = "LanguageOption"
	langOption.add_item("Auto")
	langOption.add_item("English")
	langOption.add_item("Português")
	langOption.item_selected.connect(set_language)
	langBox.add_child(langLabel)
	langBox.add_child(langOption)
	var visualVBox : Node = renderAccessors["Render-Scaling"][ACC_TYPE.LABEL].get_parent()
	visualVBox.add_child(langBox)
	visualVBox.move_child(langBox, 0)
	renderAccessors["General-Language"] = [init_language, null, apply_language, langOption]
	RefreshSettings(true)
	FSM.enter_game.connect(RefreshSettings.bind(true))
	FSM.exit_game.connect(SaveSettings.bind())

	if LauncherCommons.isMobile or LauncherCommons.isWeb:
		renderAccessors["Render-WindowSize"][ACC_TYPE.LABEL].get_parent().set_visible(false)
		renderAccessors["Render-Fullscreen"][ACC_TYPE.LABEL].set_visible(false)

	renderAccessors["Network-Local"][ACC_TYPE.LABEL].set_visible(OS.is_debug_build())

	# SOM-IDLE F3: web push toggle (web-only, created at runtime).
	if LauncherCommons.isWeb:
		var pushBox : HBoxContainer = HBoxContainer.new()
		pushBox.name = "WebPushRow"
		var pushLabel : Label = Label.new()
		pushLabel.name = "Text"
		pushLabel.text = tr("Web push notifications")
		var pushOption : OptionButton = OptionButton.new()
		pushOption.name = "WebPushOption"
		pushOption.add_item("Off")
		pushOption.add_item("On")
		pushOption.item_selected.connect(set_webpush)
		pushBox.add_child(pushLabel)
		pushBox.add_child(pushOption)
		var visualVBox : Node = renderAccessors["Render-Scaling"][ACC_TYPE.LABEL].get_parent()
		visualVBox.add_child(pushBox)
		renderAccessors["Web-PushEnabled"] = [init_webpush, set_webpush, apply_webpush, pushOption]

	# SOM-IDLE LGPD art.18: o titular exercita o direito ao esquecimento logado.
	# Botão criado em runtime (não edita o .tscn); confirmação antes de enviar.
	if accountVBox:
		var deleteButton : Button = Button.new()
		deleteButton.name = "DeleteAccountButton"
		deleteButton.text = tr("Delete my account (erase personal data)")
		deleteButton.pressed.connect(_on_delete_account_pressed)
		accountVBox.add_child(deleteButton)

	# SOM-IDLE S4: TOTP 2FA setup for admin/GM accounts.
	if accountVBox:
		var twoFactorButton : Button = Button.new()
		twoFactorButton.name = "TwoFactorButton"
		twoFactorButton.text = tr("Enable Two-Factor Authentication")
		twoFactorButton.pressed.connect(_on_two_factor_pressed)
		accountVBox.add_child(twoFactorButton)
		_twoFactorButton = twoFactorButton
		_twoFactorQRDialog = AcceptDialog.new()
		_twoFactorQRDialog.title = tr("Two-Factor Authentication Setup")
		_twoFactorQRDialog.ok_button_text = tr("I have saved the code")
		_twoFactorQRDialog.confirmed.connect(_on_two_factor_qr_confirmed)
		var qrVBox : VBoxContainer = VBoxContainer.new()
		var qrLabel : Label = Label.new()
		qrLabel.name = "QRLabel"
		qrLabel.text = tr("Scan this QR code with your authenticator app (Google Authenticator, Authy, etc.):")
		var qrUrlLabel : Label = Label.new()
		qrUrlLabel.name = "QRUrlLabel"
		qrUrlLabel.autowrap = true
		qrUrlLabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		qrUrlLabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		qrVBox.add_child(qrLabel)
		qrVBox.add_child(qrUrlLabel)
		_twoFactorQRDialog.add_child(qrVBox)
		add_child(_twoFactorQRDialog)

func _on_two_factor_pressed():
	if not _twoFactorButton:
		return
	if Launcher.SQL.IsTwoFactorEnabled(Launcher.Peer.accountID):
		_confirm_disable_two_factor()
	else:
		Network.SetupTwoFactor(Launcher.Peer.peerID)

func _confirm_disable_two_factor():
	UICommons.MessageBox(
		tr("Disabling two-factor authentication reduces your account security. Enter your password to confirm:"),
		Callable(self, "_on_disable_two_factor_dialog"), "Disable 2FA")

func _on_disable_two_factor_dialog():
	var passwordControl : Control = $Layout/Margin/TabBar/Account/AccountVBox/CurrentPassword
	var passwordText : String = ""
	if passwordControl and passwordControl.has_node("Container/Text"):
		passwordText = passwordControl.get_node("Container/Text").text
	Network.DisableTwoFactor(passwordText, Launcher.Peer.peerID)

func show_two_factor_qr(qrURL : String):
	if not _twoFactorQRDialog:
		return
	var qrUrlLabel : Label = _twoFactorQRDialog.get_node_or_null("QRUrlLabel")
	if qrUrlLabel:
		qrUrlLabel.text = qrURL
	_twoFactorQRDialog.popup_centered()

func _on_two_factor_qr_confirmed():
	# Prompt user to enter a TOTP code to verify setup.
	var verifyDialog : AcceptDialog = AcceptDialog.new()
	verifyDialog.title = tr("Verify Two-Factor Authentication")
	verifyDialog.ok_button_text = tr("Verify")
	verifyDialog.confirmed.connect(_on_verify_two_factor_setup)
	var vbox : VBoxContainer = VBoxContainer.new()
	var label : Label = Label.new()
	label.text = tr("Enter the 6-digit code from your authenticator app to verify setup:")
	var codeControl : LineEdit = LineEdit.new()
	codeControl.name = "VerifyCode"
	codeControl.placeholder_text = "000000"
	codeControl.max_length = 6
	vbox.add_child(label)
	vbox.add_child(codeControl)
	verifyDialog.add_child(vbox)
	add_child(verifyDialog)
	verifyDialog.popup_centered()
	codeControl.grab_focus()

func _on_verify_two_factor_setup():
	var verifyDialog : AcceptDialog = get_child(get_child_count() - 1)
	var codeControl : LineEdit = verifyDialog.get_node_or_null("VerifyCode")
	if not codeControl:
		return
	var code : String = codeControl.text.strip_edges()
	if code.length() != 6 or not code.is_valid_int():
		return
	Network.VerifyTwoFactorSetup(code, Launcher.Peer.peerID)
	UICommons.MessageBox(
		"This permanently deletes your account and erases your personal data (LGPD art. 18). Your characters and inventory are removed; financial ledger records are retained as required by law. This action cannot be undone.",
		Callable(self, "_confirm_delete_account"), "Delete forever")

func _confirm_delete_account():
	Network.DeleteAccount()

# Conf accessors
func RefreshSettings(apply : bool):
	for option in renderAccessors:
		var initFunc = renderAccessors[option][ACC_TYPE.INIT]
		if initFunc:
			initFunc.call_deferred(apply)

func SaveSettings():
	save_sessionoverlay()
	save_windowPos()
	save_shortcutcells()
	InputBindings.SaveBindings()
	Conf.SaveType("settings", Conf.Type.USERSETTINGS)

func SetVal(key : String, value):
	Conf.SetValue(userSection, key, Conf.Type.USERSETTINGS, value)

func GetVal(key : String):
	var value = Conf.GetVariant(userSection, key, Conf.Type.USERSETTINGS, null)
	if value == null:
		value = Conf.GetVariant(platformSection, key, Conf.Type.SETTINGS, null)
	if value == null:
		value = Conf.GetVariant(defaultSection, key, Conf.Type.SETTINGS, null)

	return value
