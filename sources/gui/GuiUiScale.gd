extends RefCounted
class_name GuiUiScale

# Fatia do HUD (gate anti-god-node — teto de 800 linhas do `Gui`, mesmos
# precedentes de `ManualHudBar`/`HudWindows`/`GuildPanelRows`): a matemática da
# escala de fonte e de janelas, e o ajuste responsivo mínimo de mobile/web.
#
# Continua sendo o ÚNICO mecanismo de escala do produto (era mobile/web-only; hoje
# também é manual no Desktop pela opção Settings "General-UIScale"). Fator 1.0 =
# tamanho de design (viewport 1280×720, fonte base do tema). Chamadas são
# absolutas, não acumulam: a base é capturada uma vez e toda chamada reaplica
# base × fator — por isso o `Gui` guarda `uiScaleFactor` e `_baseUIFontSize`
# (estado lido por fora: o `tests/IdleTests.gd` confere o fator armazenado e o
# clamp no teto pela instância do `Gui`, e `Settings.gd` chama
# `Launcher.GUI.ApplyUIScale`).

const MobileDefault : float = 1.2
const Min : float = 1.0
const Max : float = 2.0

# Alvo de toque do produto, em pixels. Era um literal solto na linha dos botões da
# barra manual; hoje é o número único que a chrome de janela, o botão de fechar da
# barra de título e a barra manual obedecem no toque. O piso externo (Apple HIG
# 44 pt / WCAG 2.5.5 "Target Size") vive logo abaixo como chão: 48 é o que o
# produto promete, 44 é o que a régua não deixa cruzar — e vale o MAIOR dos dois,
# ou seja, 48.
const TouchTarget : int = 48
const TouchTargetFloor : int = 44

# MOLDURA DE TELEFONE DO PRODUTO (lado de produto, não de teste): 390x844 CSS px,
# retrato iPhone 12/13/14. De onde vem o número: (a) o shell web entrega
# `width=device-width` (`deploy/web/checkout_return.html:5`, `landing/index.html:5`),
# ou seja, o CSS viewport do aparelho É o viewport do jogo; (b) `display`
# (`project.godot:@display`) fixa a base em 1280x720 com `stretch/mode="canvas_items"`
# + `aspect="expand"`,
# então o espaço de design nunca é o do aparelho — é a moldura abaixo que a régua
# impõe no container real. Este é o ÚNICO lugar onde o tamanho de telefone existe em
# produto; `tests/hud_decision_fit_test.gd` lê daqui em vez de inventar número.
const PhoneViewportCss : Vector2i = Vector2i(390, 844)

# Área mínima de toque que o produto declara, num só número: vale o MAIOR entre a
# promessa (`TouchTarget`) e o piso externo (`TouchTargetFloor`) — mesma leitura de
# `panel_fit_test.gd`. Régua de hit-area lê daqui, nunca um literal.
static func DecisionTouchPx() -> int:
	return maxi(TouchTarget, TouchTargetFloor)

# Reencaixa uma linha de decisão (confirmar/cancelar/escolher slot) na largura que o
# aparelho realmente tem. É container, não coordenada: espaçadores flexíveis
# (`Empty*`, `size_flags_horizontal = EXPAND`) somem quando faltam pixels, cada botão
# passa a dividir a largura restante e leva o mínimo declarado de toque. Chamada
# idempotente e sem efeito quando há largura de sobra (desktop não muda).
static func FitDecisionRow(row : Control, availableWidth : float) -> void:
	if row == null or not is_instance_valid(row):
		return
	var minimum : int = DecisionTouchPx()
	var buttons : Array[Button] = []
	var sumMin : float = 0.0
	var expanders : Array[Control] = []
	for child in row.get_children():
		if child is Button:
			buttons.append(child as Button)
			sumMin += (child as Button).get_combined_minimum_size().x
		elif child is Control:
			var filler : Control = child as Control
			if int(filler.size_flags_horizontal) & int(Control.SizeFlags.SIZE_EXPAND) != 0:
				expanders.append(filler)
	if buttons.is_empty():
		return
	# Squeeze é medido contra a largura disponível, não contra flag de plataforma:
	# no desktop sobra pixel e a linha fica exatamente como a cena desenhou.
	# Aperta quando a linha não tem folga: os botões pelo seu mínimo natural + um
	# alvo de toque de respiro não cabem. É largura de host, não flag de plataforma.
	var squeeze : bool = sumMin + float(minimum) > availableWidth - 8.0 or float(minimum * buttons.size()) > availableWidth - 8.0
	for spacer in expanders:
		spacer.visible = not squeeze
	if squeeze:
		row.add_theme_constant_override("separation", 2)
	for button in buttons:
		SetTouchMinimum(button, minimum)
	# Quatro decisões lado a lado não cabem em 390 px nem sem espaçadores: aí a linha
	# empilha. É container (VBox dentro da linha), não coordenada: cada botão continua
	# com o piso de toque declarado e a caixa volta a caber no aparelho.
	# `reparent`, não `add_child`: o botão JÁ tem pai (a própria linha), e `add_child` de
	# nó com pai é erro recusado — foi assim que o empilhamento nasceu morto, com
	# `Can't add child 'ButtonCancel' to 'DecisionStack', already has a parent
	# 'ButtonBoxes'` no log e a linha no mesmo lugar. O gate de log não olhava esses
	# quatro botões, então só a régua de telefone viu.
	if sumMin > availableWidth - 8.0:
		var stack : VBoxContainer = row.get_node_or_null("DecisionStack") as VBoxContainer
		if stack == null:
			stack = VBoxContainer.new()
			stack.name = "DecisionStack"
			row.add_child(stack)
		for button in buttons:
			if button.get_parent() != stack:
				button.reparent(stack, false)
	else:
		var restacked : VBoxContainer = row.get_node_or_null("DecisionStack") as VBoxContainer
		if restacked != null:
			for held in restacked.get_children():
				if held is Button:
					held.reparent(row, false)
			restacked.free()

# Aplica a escala global de fonte e devolve o fator já clampeado, para o dono
# guardar na sua variável e escalar as janelas com o MESMO número.
#
# SOM-IDLE parser: `get_viewport().gui_theme_default_font_size` não existe neste
# build (erro em runtime) — `ThemeDB.fallback_font_size` é a API correta p/ escalar
# a fonte de TODA a UI globalmente.
static func Apply(gui : Node, factor : float) -> float:
	var clamped : float = clampf(factor, Min, Max)
	if gui._baseUIFontSize < 0:
		gui._baseUIFontSize = ThemeDB.fallback_font_size
	ThemeDB.fallback_font_size = int(float(gui._baseUIFontSize) * clamped)
	return clamped

# Janelas principais acompanham (toque no mobile, leitura no Desktop HiDPI) —
# §13 da auditoria: antes eram só 3. A lista é a do `Gui`, com as janelas que já
# existem quando a escala muda; as montadas em runtime depois disso são escaladas
# na próxima chamada, como sempre foram.
static func ScaleWindows(gui : Node, factor : float) -> void:
	for win in [gui.statWindow, gui.chatWindow, gui.shopWindow, gui.chestsWindow, gui.leaderboardWindow, gui.seasonPassWindow, gui.afkWindow, gui.zoneWindow, gui.auctionHouseWindow, gui.arenaWindow, gui.guildWindow]:
		if win and win is WindowPanel:
			(win as WindowPanel).scale = Vector2(factor, factor)

# P-A4: ajuste responsivo mínimo para mobile/web. NÃO é redesign — é o que o módulo
# faz e deixou de ser suposição: o alvo de toque das janelas (chrome de resize e o
# botão de fechar da barra de título) e dos botões da barra manual é `TouchTarget`,
# medido por `tests/panel_fit_test.gd`. O que este módulo NÃO entrega continua sendo
# o que a passada de telefone registra com nome e número: janelas cujo mínimo passa
# da largura de um telefone.
static func AdjustForMobileWeb(gui : Node) -> void:
	if IsTouch():
		# P-A4 (polimento): responsivo completo — fontes maiores, botões maiores,
		# margens reduzidas.
		gui.ApplyUIScale(MobileDefault)
		# Reduzir margens das janelas para caber em telas pequenas.
		if gui.windows and gui.windows is Control:
			for win in gui.windows.get_children():
				if win is WindowPanel:
					win.add_theme_constant_override("margin_left", 4)
					win.add_theme_constant_override("margin_right", 4)
					win.add_theme_constant_override("margin_top", 4)
					win.add_theme_constant_override("margin_bottom", 4)
		# Alvo de toque da chrome de TODAS as janelas (resize + fechar).
		ApplyTouchChrome(gui, true)
		# Aumentar botões manuais para toque (tamanho mínimo `TouchTarget`)
		if gui.manualSkillBar and is_instance_valid(gui.manualSkillBar):
			for child in gui.manualSkillBar.get_children():
				if child is Button:
					(child as Button).custom_minimum_size = Vector2(TouchTarget, TouchTarget)

static func IsTouch() -> bool:
	return LauncherCommons.isMobile or LauncherCommons.isWeb

# Aplica o alvo de toque à chrome das janelas vivas. Fica separado do
# `AdjustForMobileWeb` de propósito: é a parte que dá para medir sem depender de
# flag de plataforma, de display nem de tempo real — o harness passa `touch`
# explicitamente na janela que está medindo.
static func ApplyTouchChrome(gui : Node, touch : bool) -> void:
	if gui.windows == null or not (gui.windows is Control):
		return
	for win in (gui.windows as Control).get_children():
		if win is WindowPanel:
			ApplyWindowTouchChrome(win as WindowPanel, touch)

static func ApplyWindowTouchChrome(panel : WindowPanel, touch : bool) -> void:
	panel.SetChromePixels(TouchTarget if touch else 0)
	# Fechar/ocultar da barra de título (`presets/gui/TitleBar.tscn`): 32 px de
	# botão com um TouchScreenButton de raio 14 = 28 px de alvo, abaixo do que o
	# produto promete. O botão ganha o mínimo de toque e o círculo do toque passa a
	# ter o diâmetro prometido. A base de cada número fica em `meta` do nó, então a
	# chamada é idempotente nos dois sentidos: `touch = false` devolve o valor de
	# cena (o shape do TitleBar é um sub-resource compartilhado entre instâncias —
	# mexer nele sem volta contaminaria o desktop).
	for btn in panel.find_children("HideButton", "Button", true, false):
		var button : Button = btn as Button
		SetTouchMinimum(button, TouchTarget if touch else 0)
		for pick in button.find_children("TouchButton", "TouchScreenButton", true, false):
			SetTouchPickRadius(pick as TouchScreenButton, TouchTarget / 2.0 if touch else 0.0)

# Mínimo de toque de um botão de chrome: 0 volta para o mínimo declarado em cena.
static func SetTouchMinimum(button : Button, pixels : int) -> void:
	if not button.has_meta("baseMinimum"):
		button.set_meta("baseMinimum", button.custom_minimum_size)
	if pixels <= 0:
		button.custom_minimum_size = button.get_meta("baseMinimum") as Vector2
	else:
		var base : Vector2 = button.get_meta("baseMinimum") as Vector2
		button.custom_minimum_size = Vector2(maxf(base.x, float(pixels)), maxf(base.y, float(pixels)))

static func SetTouchPickRadius(pick : TouchScreenButton, radius : float) -> void:
	if pick.shape == null or not (pick.shape is CircleShape2D):
		return
	var circle : CircleShape2D = pick.shape as CircleShape2D
	if not pick.has_meta("baseRadius"):
		pick.set_meta("baseRadius", circle.radius)
	var base : float = float(pick.get_meta("baseRadius"))
	circle.radius = base if radius <= 0.0 else maxf(base, radius)

# Varrimento de hit-area dos controles de DECISÃO (confirmar/cancelar/escolher slot) de
# um painel: cada linha com duas ou mais ações recebe o piso de toque declarado e, se
# faltar largura, os espaçadores decorativos somem. É o caminho de TOQUE: chamado por
# `WindowPanel._enter_tree` e pelo harness de telefone. No desktop o chamador passa
# `touch = false` e nada é tocado.
const DecisionWords : Array[String] = ["Confirm", "Abort", "Cancel", "Primary", "Secondary",
		"Tertiary", "Buy", "Sell", "Slot", "Forge", "Withdraw", "Submit", "Accept", "Decline",
		"Equip", "Drop", "Delete"]

static func IsDecisionButton(button : Button) -> bool:
	var haystack : String = String(button.name) + " " + String(button.text)
	for word in DecisionWords:
		if haystack.contains(word):
			return true
	return false

static func DecisionRows(host : Control) -> Array[Control]:
	var rows : Array[Control] = []
	if host == null or not is_instance_valid(host):
		return rows
	for candidate in host.find_children("*", "Container", true, false):
		var row : Control = candidate as Control
		var hits : int = 0
		for child in row.get_children():
			if child is Button and IsDecisionButton(child as Button):
				hits += 1
		if hits >= 2:
			rows.append(row)
	return rows

static func ApplyDecisionChrome(host : Control, touch : bool, room : float) -> void:
	if not touch:
		return
	for row in DecisionRows(host):
		FitDecisionRow(row, room)
