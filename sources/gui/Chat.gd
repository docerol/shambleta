extends VBoxContainer
class_name ChatContainer

const ChatLabelScene : PackedScene = preload(Path.GuiPst + "labels/ChatLabel.tscn")
const WhisperUnreadIcon : Texture2D = preload("res://data/graphics/gui/tab/tab_warn.png")

# Teto do histórico por aba, em pedaços de AddLine (um pedaço = nick + mensagem de
# uma linha). O corte mantém os ChunkKeep últimos e só reescreve o buffer quando
# ele estoura — contar no texto, e não em `get_line_count()`, é o que faz o teto
# valer também em aba escondida e em headless, onde a contagem do motor é 0.
const ChunkKeep : int = 200
const ChunkEnd : String = "[/color]"

@onready var tabContainer : TabContainer		= $ChatTabContainer
@onready var lineEdit : LineEdit				= $NewText

@onready var backlog : ChatBacklog				= ChatBacklog.new()

var channelTabs : Dictionary[String, int]		= {}

#
func AddLocalFeedback(text : String):
	var channelIdx : GUICommons.ChatChannel = GUICommons.ChatChannel.LOCAL
	AddLine(channelIdx, text + "\n", UICommons.TextColor)

func AddPlayerChat(channelName : String, callerName : String, text : String, agentRID : int = -1):
	var channelIdx : GUICommons.ChatChannel = GetChannelIndex(channelName)
	if channelIdx == GUICommons.ChatChannel.UNKNOWN:
		return

	AddLine(channelIdx, callerName, UICommons.PlayerNameToColor(callerName))
	AddLine(channelIdx, ": " + text + "\n", UICommons.LightTextColor)

	if channelIdx == GUICommons.ChatChannel.LOCAL:
		var entity : Entity = Entities.Get(agentRID) if agentRID > 0 else Entities.GetNamed(callerName)
		if entity and entity.get_parent() and entity.interactive:
			entity.interactive.DisplaySpeech(text)
	elif channelIdx >= GUICommons.ChatChannel.DEFAULT_CHANNEL_COUNT:
		var localNick : String = Launcher.Player.nick if Launcher.Player else ""
		if callerName != localNick:
			NotifyWhisper(channelIdx)

#
func NotifyWhisper(channelIdx : int):
	if Launcher.Player and Launcher.Player.sfx:
		Launcher.Player.sfx.HandleAlteration(ActorCommons.Alteration.WHISPER)

	if tabContainer and tabContainer.current_tab != channelIdx:
		tabContainer.get_tab_bar().set_tab_icon(channelIdx, WhisperUnreadIcon)

#
func AddSystemChat(channelName : String, text : String):
	var channelIdx : GUICommons.ChatChannel = GetChannelIndex(channelName)
	if channelIdx == GUICommons.ChatChannel.UNKNOWN:
		return

	AddLine(channelIdx, text + "\n", UICommons.TextColor)

func AddLine(channelID : GUICommons.ChatChannel, text : String, color : Color):
	var tab : Control = tabContainer.get_tab_control(channelID) if tabContainer else null
	var label : RichTextLabel = tab as RichTextLabel
	if label == null:
		return
	# SOM-IDLE C1: `text` é conteúdo de terceiros (linha de chat, nick de
	# quem fala) e o rótulo é bbcode_enabled → escapa o texto, mantém vivo
	# só o [color=...] que a gente mesmo monta.
	#
	# `append_text()` foi tentado aqui e não serve: medido num RichTextLabel com
	# bbcode ligado nesta engine, ele renderiza mas NÃO atualiza `.text` — e
	# `.text` é o contrato que o portão verifica (IdleTests "o wrapper [color]
	# nosso continua markup") e a única fonte do corte abaixo. O custo real desta
	# tela nunca foi o parse por linha, era o buffer crescer sem teto: com o corte
	# em ChunkKeep, o re-parse de cada linha passa a custar no máximo ChunkKeep
	# linhas.
	label.text += "[color=#" + color.to_html(false) + "]" + Util.EscapeBBCode(text) + ChunkEnd
	TrimHistory(label)

# Teto de histórico por aba, contado no próprio buffer (não em `get_line_count()`,
# que é 0 enquanto o rótulo não tem layout — aba escondida, headless, boot).
# Mantém os ChunkKeep últimos pedaços, onde um pedaço é uma AddLine inteira: nick
# e mensagem da mesma linha caem juntos. Acima do teto cada linha nova reescreve o
# buffer — e portanto re-parseia no máximo ChunkKeep linhas, que é o que torna o
# custo por linha constante em vez de crescer com a sessão.
static func TrimHistory(label : RichTextLabel):
	var chunks : int = label.text.count(ChunkEnd)
	if chunks <= ChunkKeep:
		return
	var raw : String = label.text
	var cut : int = 0
	for _dropIdx in chunks - ChunkKeep:
		var found : int = raw.find(ChunkEnd, cut)
		if found < 0:
			return
		cut = found + ChunkEnd.length()
	label.text = raw.substr(cut)

#
func GetChannelIndex(channelName : String) -> GUICommons.ChatChannel:
	if not channelTabs.has(channelName):
		return CreateChannel(channelName)
	return channelTabs.get(channelName, GUICommons.ChatChannel.UNKNOWN)

func SetChannelIndex(channelIdx : GUICommons.ChatChannel):
	tabContainer.current_tab = channelIdx

func CreateChannel(channelName : String) -> GUICommons.ChatChannel:
	if channelTabs.has(channelName):
		return channelTabs[channelName] as GUICommons.ChatChannel

	var newTab : Control = ChatLabelScene.instantiate()
	newTab.name = channelName

	var channelIdx : GUICommons.ChatChannel = tabContainer.get_tab_count() as GUICommons.ChatChannel
	tabContainer.add_child(newTab)
	channelTabs[channelName] = channelIdx
	tabContainer.current_tab = channelIdx
	return channelIdx

func GetChannelName(channelIdx : int) -> String:
	for channelName in channelTabs:
		if channelTabs[channelName] == channelIdx:
			return channelName
	return "0"

#
func isNewLineEnabled() -> bool:
	return lineEdit.is_visible() and lineEdit.has_focus() if lineEdit else false

func SetNewLineEnabled(enable : bool):
	if Launcher.Action and lineEdit:
		if not LauncherCommons.isMobile:
			lineEdit.set_visible(enable)
			if enable:
				lineEdit.grab_focus()
		else:
			if not enable:
				lineEdit.release_focus()

#
func OnNewTextSubmitted(newText : String):
	if lineEdit:
		if newText.is_empty() == false:
			lineEdit.clear()
			if Launcher.Player:
				backlog.Add(newText)
				if newText[0] == "/":
					var command : String = newText.trim_prefix("/")
					var commandStripped : String = command.strip_edges().to_lower()
					# Hub Atividades: comandos de sistema abrem a GUI em vez de
					# texto (menos fricção); o resto segue para o servidor.
					var root : String = commandStripped.split(" ", false)[0] if not commandStripped.is_empty() else ""
					var hubTab : int = -1
					match root:
						"ach":
							hubTab = 0
						"torment":
							hubTab = 1
						"rush":
							hubTab = 2
						"corrupt", "cube", "salvage":
							hubTab = 3
					if hubTab >= 0 and Launcher.GUI and Launcher.GUI.has_method("OpenActivities"):
						Launcher.GUI.OpenActivities(hubTab)
						SetNewLineEnabled(false)
						return
					match commandStripped:
						"clear":
							ClearCurrentTab()
						_:
							Network.TriggerCommand(command)
				else:
					var channelIdx : int = tabContainer.get_current_tab()
					var channelName : String = ""
					if channelIdx < GUICommons.ChatChannel.DEFAULT_CHANNEL_COUNT:
						channelName = str(channelIdx)
					else:
						channelName = GetChannelName(channelIdx)
					Network.TriggerChat(channelName, newText)
		SetNewLineEnabled(false)

#
func ClearCurrentTab():
	var tab : Control = tabContainer.get_tab_control(tabContainer.get_current_tab())
	if tab and tab is RichTextLabel:
		tab.text = ""

#
func OnTabCloseRequested(channelIdx : int):
	if channelIdx < GUICommons.ChatChannel.DEFAULT_CHANNEL_COUNT:
		return

	var channelName : String = GetChannelName(channelIdx)
	if channelName.is_empty():
		return

	var tabControl : Control = tabContainer.get_tab_control(channelIdx)
	if tabControl:
		tabContainer.remove_child(tabControl)
		tabControl.queue_free()

	channelTabs.erase(channelName)
	for channelKey in channelTabs:
		if channelTabs[channelKey] > channelIdx:
			channelTabs[channelKey] -= 1

func OnTabChanged(channelIdx : int):
	var tabBar = tabContainer.get_tab_bar()
	if channelIdx < GUICommons.ChatChannel.DEFAULT_CHANNEL_COUNT:
		tabBar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_NEVER
		tabBar.drag_to_rearrange_enabled = false
	else:
		tabBar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ACTIVE_ONLY
		tabBar.drag_to_rearrange_enabled = true

	tabBar.set_tab_icon(channelIdx, null)

#
func _ready():
	var tabBar : TabBar = tabContainer.get_tab_bar()
	tabBar.drag_to_rearrange_enabled = false
	tabBar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_NEVER
	tabBar.tab_close_pressed.connect(OnTabCloseRequested)
	tabContainer.tab_changed.connect(OnTabChanged)

	# SOM-IDLE C1: teto do lado do servidor também vale aqui (conforto: o
	# jogador para de digitar no limite em vez de ver a linha sumir).
	if lineEdit:
		lineEdit.max_length = NetworkCommons.ChatMaxSize

	for channelIdx in GUICommons.ChatChannel.DEFAULT_CHANNEL_COUNT:
		channelTabs[str(channelIdx)] = channelIdx

	AddLocalFeedback("Welcome to " + LauncherCommons.ProjectName)
	SetNewLineEnabled(false)

func _input(event : InputEvent):
	if FSM.IsGameState() and isNewLineEnabled():
		if Launcher.Action.TryJustPressed(event, "ui_cancel", true):
			SetNewLineEnabled(false)
		elif Launcher.Action.TryJustPressed(event, "ui_up", true):
			backlog.Up()
			lineEdit.text = backlog.Get()
			lineEdit.set_caret_column(lineEdit.text.length())

		elif Launcher.Action.TryJustPressed(event, "ui_down", true):
			backlog.Down()
			lineEdit.text = backlog.Get()
			lineEdit.set_caret_column(lineEdit.text.length())
		elif Launcher.Action.TryJustPressed(event, "ui_validate", true):
			OnNewTextSubmitted(lineEdit.text)

func _on_new_text_editing_toggled(toggled_on):
	Launcher.Action.Enable(!toggled_on)
