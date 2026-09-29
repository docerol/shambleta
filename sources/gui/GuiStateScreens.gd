extends RefCounted
class_name GuiStateScreens

# Fatia do HUD (gate anti-god-node — teto de 800 linhas do `Gui`, precedentes:
# `ManualHudBar`, `HudWindows`, `GuildPanelRows`): a coreografia das telas de
# estado do FSM — login, progresso de login, seleção de personagem, progresso de
# personagem, entrada e saída do jogo.
#
# O que fica no `Gui` é o que o resto do repo chama: o FSM conecta
# `FSM.enter_login`/`enter_char`/`enter_game`/`exit_game` em métodos DELE, o
# `Client` lê `GUI.progressTimer`/`GUI.characterPanel` e `Loading.gd` mexe no
# mesmo timer. Os ~80 `set_visible` que dizem O QUE aparece em cada tela saem
# daqui, onde dão para ler de uma vez só.
#
# Comportamento idêntico ao do arquivo de origem, linha por linha: mesma ordem,
# mesmos nós, mesmos `Callable`. O `Callback.SelfDestructTimer` continua recebendo
# o `Gui` como `parent` (é ele que pendura e reaproveita o nó "ProgressTimer"), e o
# one-shot em `Launcher.dbInitialized` continua apontando para o método `_show_char_menu`
# do `Gui` — `Callable(gui, "...")` é o mesmo Callable que a referência nua dentro
# do `Gui` produzia, então `is_connected()` continua vendo uma ligação só.

# Tela de login: some com o HUD do jogo e abre o painel de acesso.
static func EnterLoginMenu(gui : Node) -> void:
	if gui.progressTimer != null:
		gui.progressTimer.stop()
		gui.progressTimer = null

	gui.infoContext.set_visible(false)
	gui.choiceContext.Hide()
	gui.progressionTracker.set_visible(false)
	gui.bossTracker.set_visible(false)
	gui.menu.SetItemsVisible(false)
	gui.menu.Close()
	gui.stats.SetBarsVisible(false)
	gui.statWindow.set_visible(false)
	gui.dialogueContainer.set_visible(false)
	gui.pickupPanel.AnimateClose()
	gui.loadingControl.set_visible(false)
	gui.actionBoxes.set_visible(false)
	gui.HideManualSkillButtons()
	gui.quitWindow.set_visible(false)
	gui.respawnWindow.EnableControl(false)
	gui.shortcuts.set_visible(false)
	gui.characterPanel.set_visible(false)
	gui.buttonBoxes.set_visible(false)

	gui.background.set_visible(true)
	gui.loginPanel.set_visible(true)
	gui.loginPanel.RefreshOnce()
	gui.buttonBoxes.set_visible(true)

# Viagem de autenticação: o timer de timeout é o que devolve o jogador à tela se a
# resposta nunca chegar.
static func EnterLoginProgress(gui : Node) -> void:
	gui.loginPanel.set_visible(false)
	gui.buttonBoxes.set_visible(false)

	gui.progressTimer = Callback.SelfDestructTimer(gui, NetworkCommons.LoginAttemptTimeout, Callable(gui, "TimeoutLoginProgress"), [], "ProgressTimer")
	gui.loadingControl.set_visible(true)

# O personagem ainda não chegou: espera `Launcher.dbInitialized` (DB no client é
# carregado em thread) em vez de abrir uma tela vazia.
static func EnterCharMenu(gui : Node) -> void:
	if gui.progressTimer:
		gui.progressTimer.stop()
		gui.progressTimer = null

	if not DB.isInitialized:
		if not Launcher.dbInitialized.is_connected(Callable(gui, "_show_char_menu")):
			Launcher.dbInitialized.connect(Callable(gui, "_show_char_menu"), CONNECT_ONE_SHOT)
		return
	gui._show_char_menu()

static func ShowCharMenu(gui : Node) -> void:
	gui.loadingControl.set_visible(false)
	gui.background.set_visible(false)
	gui.loginPanel.set_visible(false)
	gui.characterPanel.RefreshOnce()

	gui.characterPanel.set_visible(true)
	gui.buttonBoxes.set_visible(true)

static func EnterCharProgress(gui : Node) -> void:
	gui.characterPanel.set_visible(false)
	gui.buttonBoxes.set_visible(false)

	gui.progressTimer = Callback.SelfDestructTimer(gui, NetworkCommons.CharSelectionTimeout, Callable(gui, "TimeoutCharProgress"), [], "ProgressTimer")
	gui.loadingControl.set_visible(true)

# Chegada ao mundo: HUD completo, barra de ações e skills manuais.
static func EnterGame(gui : Node) -> void:
	if gui.progressTimer:
		gui.progressTimer.stop()
		gui.progressTimer = null
	gui.loadingControl.set_visible(false)
	gui.background.set_visible(false)
	gui.loginPanel.set_visible(false)
	gui.characterPanel.set_visible(false)
	gui.buttonBoxes.set_visible(false)

	Launcher.Camera.ResetCinematic()
	gui.DisplayActions(["gp_interact", "gp_target", "gp_untarget", "gp_pickup", "gp_sit"])

	gui.stats.SetBarsVisible(true)
	gui.menu.set_visible(true)
	gui.actionBoxes.set_visible(true)
	gui.shortcuts.set_visible(true)
	gui.menu.SetItemsVisible(true)
	# Hybrid gameplay: manual skills available on HUD
	gui.AddManualSkillButtons()

static func ExitGame(gui : Node) -> void:
	gui.notificationLabel.ClearNotification()
	gui.HideManualSkillButtons()
