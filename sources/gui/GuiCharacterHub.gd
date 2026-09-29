extends RefCounted
class_name GuiCharacterHub

# Fatia do HUD (gate anti-god-node — teto de 800 linhas do `Gui`, mesmos
# precedentes de `ManualHudBar`/`HudWindows`/`GuildPanelRows`): montar o hub
# Personagem em runtime — uma `WindowPanel` com um `TabContainer` onde as quatro
# janelas próprias (Status, Skills, Progresso, Formação) são REPARENTADAS, sem
# `.tscn` novo.
#
# O `Gui` continua dono do estado (`characterHub`) e dos métodos que o `Client` e
# o `Action.gd` chamam (`EnsureCharacterHub`, `OpenCharacterHub`, `characterHub`,
# `windows`): quem abre a aba é de lá. Aqui mora só a construção do hub.
#
# Nada muda de comportamento: os mesmos nós com os mesmos nomes
# ("Character", "CharacterTabs"), o mesmo size/position copiados de `statWindow`,
# a mesma ordem de absorção (Status, Skills, Progresso, Formação), o mesmo
# TitleBar removido antes do reparent (é ele que some da aba, não o layout), o
# mesmo `set_visible(false)` antes de repontuar o menu.

# Cria o hub, engole as quatro janelas e devolve o painel pronto — quem guarda a
# instância e decide quando mostrar é o `Gui`.
static func Build(gui : Node) -> WindowPanel:
	var hub := WindowPanel.new()
	hub.name = "Character"
	if gui.statWindow:
		hub.size = gui.statWindow.size
		hub.position = gui.statWindow.position
	var tabs := TabContainer.new()
	tabs.name = "CharacterTabs"
	tabs.set_anchors_preset(Control.PRESET_FULL_RECT)
	hub.add_child(tabs)
	AbsorbWindow(gui.statWindow, tabs, "Status")
	AbsorbWindow(gui.skillWindow, tabs, "Skills")
	AbsorbWindow(gui.progressWindow, tabs, "Progresso")
	AbsorbWindow(gui.formationWindow, tabs, "Formação")
	gui.windows.add_child(hub)
	hub.set_visible(false)
	RepointMenu(gui, hub)
	return hub

# O layout da janela vira a página da aba: arranca o TitleBar (o botão de fechar
# da janela original não tem o que fechar dentro de uma aba) e pendura o resto.
# A janela origem fica oculta — os scripts originais seguem vivos e
# `Client.Refresh*` continua achando os nós dela.
static func AbsorbWindow(win : WindowPanel, tabs : TabContainer, title : String) -> void:
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

# Os botões do menu que apontavam para uma das quatro janelas passam a apontar
# para o hub: um botão por aba, não quatro janelas soltas no HUD.
static func RepointMenu(gui : Node, hub : WindowPanel) -> void:
	var menu : MenuIndicator = gui.menu
	if menu == null or menu.items == null:
		return
	for node in menu.items.get_children():
		if node is WindowButton and node.targetWindow and (node.targetWindow == gui.statWindow or node.targetWindow == gui.skillWindow or node.targetWindow == gui.progressWindow or node.targetWindow == gui.formationWindow):
			node.targetWindow = hub
