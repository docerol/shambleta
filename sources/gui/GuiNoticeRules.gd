extends RefCounted
class_name GuiNoticeRules

# Fatia do HUD (gate anti-god-node — teto de 800 linhas do `Gui`, mesmos
# precedentes de `ManualHudBar`/`HudWindows`/`GuildPanelRows`): a DERIVAÇÃO da
# bolinha vermelha de novidade — quais janelas têm o que anunciar e se já estão
# abertas.
#
# Continuação do desenho original, sem protocolo novo: o estado vem do que o client
# já deixou em cache (`NetClient.LastBossState`/`LastEconomyState`/`LastAFKReport`),
# e o `Gui` continua dono do `notices` e de `SetNotice` — é ele que escreve no
# dicionário e atravessa os `WindowButton` do menu pintando o ponto. O
# harness e2e (`tests/test_e2e_implementation.gd`) cobra `SetNotice` e
# `RefreshNotices` no `Gui`, não aqui.
#
# A regra que mora neste arquivo e que é fácil perder numa refatoração: a bolinha
# só vale com a janela FECHADA. Janela aberta é novidade que o jogador já está
# vendo, e foi por isso que `WindowPanel.EnableControl` chama
# `Gui.ClearNoticeByNode` ao abrir.

# A janela que o ponto de cada nome marca (nulo = não há janela montada para ela).
static func WindowFor(gui : Node, windowName : String) -> WindowPanel:
	match windowName:
		"Boss":
			return gui.bossWindow as WindowPanel
		"Chests":
			return gui.chestsWindow as WindowPanel
		"AFK":
			return gui.afkWindow as WindowPanel
	return null

# As três novidades que o HUD sabe anunciar, na mesma ordem de sempre.
static func Refresh(gui : Node) -> void:
	var bossKeys : int = 0
	if not NetClient.LastBossState.is_empty():
		bossKeys = int(NetClient.LastBossState.get("keys", 0))
	SetIfHidden(gui, "Boss", bossKeys > 0)
	var closed : int = 0
	if not NetClient.LastEconomyState.is_empty():
		var ch = NetClient.LastEconomyState.get("chests", [])
		if ch is Array:
			closed = (ch as Array).size()
	SetIfHidden(gui, "Chests", closed > 0)
	SetIfHidden(gui, "AFK", not NetClient.LastAFKReport.is_empty())

# Sem novidade → apaga. Com novidade → acende só se a janela estiver fechada.
static func SetIfHidden(gui : Node, windowName : String, cond : bool) -> void:
	if not cond:
		gui.SetNotice(windowName, false)
		return
	var win : WindowPanel = WindowFor(gui, windowName)
	gui.SetNotice(windowName, win == null or not win.is_visible())
