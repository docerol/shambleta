extends SceneTree

# SOM-UX (régua de decisão em telefone): "widgets de decisão fora da tela em viewport
# de telefone" — o gap nomeado pelo júri cego. O `tests/panel_fit_test.gd` já mede a
# CAIXA de cada janela (e só de janelas que herdam `WindowPanel`); nada no repositório
# media o retângulo de cada controle que o jogador precisa apertar. Este harness mede:
#   R1  o retângulo global do controle está na área visível do aparelho (ou atrás de
#       rolagem no eixo que estoura);
#   R2  ele tem pelo menos a área de toque que o PRODUTO declara (`GuiUiScale`
#       `TouchTarget`/`TouchTargetFloor`, sources/gui/GuiUiScale.gd — o harness não
#       inventa número);
#   R3  nada por cima rouba o press: o controle que de fato receberia o toque no centro
#       do alvo é o próprio alvo.
# A moldura de telefone vem de `GuiUiScale.PhoneViewportCss` (lado de produto, citando
# o `width=device-width` do shell web e a base 1280x720 de `project.godot:46-51`), e é
# imposta no container real de janelas — mesma técnica de `panel_fit_test._phonePass`.
#
# Uso: `bash scripts/test.sh one hud_decision_fit_test` (o portão que de fato o
# chama — ele é descoberto por nome em `harnesses_extra`). A mão, com home de
# scratch: XDG_DATA_HOME=/tmp/phq-data XDG_CACHE_HOME=/tmp/phq-cache \
#   godot --headless --path . -s tests/hud_decision_fit_test.gd

var checks : int = 0
var failures : int = 0
var measured : int = 0
var launcher : Node = null
var gui : Node = null
var windows : Control = null
var dbScript : GDScript = null
var chromeScript : GDScript = null
var frame : Vector2 = Vector2.ZERO
var visibleRect : Rect2 = Rect2()
var designRect : Rect2 = Rect2()
var touchPx : int = 48
var phoneCss : Vector2i = Vector2i(390, 844)
var epsilon : float = 1.5
# Botões que decidem algo. É nome/texto de controle de decisão, não qualquer Button:
# um harness que mede tudo aceita qualquer coisa; este cobra a linha de confirmar.
const DecisionWords : Array[String] = ["Confirm", "Abort", "Cancel", "Primary", "Secondary",
		"Tertiary", "Yes", "No", "Buy", "Sell", "Slot", "Forge", "Withdraw", "Submit", "Accept",
		"Decline", "Equip", "Drop", "Delete", "Ok", "OK"]

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckI(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func _initialize():
	_run()

func _noop() -> void:
	pass

func _run() -> void:
	print("== SOM-UX-DECISION: todo controle de decisão alcançável num telefone ==")
	launcher = root.get_node_or_null(NodePath("Launcher"))
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return
	var waited : int = 0
	var ready : bool = false
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sql : Node = launcher.get("SQL")
		var worldNode : Node = launcher.get("World")
		if sql != null and bool(sql.get("isInitialized")) and worldNode != null and bool(worldNode.get("isInitialized")):
			ready = true
			break
	dbScript = load("res://sources/db/DB.gd")
	for tick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			break
		await create_timer(0.25).timeout
	if not Check(ready, "SQL + World init no boot headless"):
		_finish()
		return
	gui = launcher.get("GUI")
	if not Check(gui != null, "Launcher.GUI vive no boot headless (é o canvas do HUD real)"):
		_finish()
		return
	windows = gui.get("windows") as Control
	if not Check(windows != null, "Gui.windows (container das janelas flutuantes) vive"):
		_finish()
		return

	# (1) Os números vêm do produto, nunca deste arquivo.
	var consts : Dictionary = load("res://sources/gui/GuiUiScale.gd").get_script_constant_map()
	touchPx = maxi(int(consts.get("TouchTarget", 0)), int(consts.get("TouchTargetFloor", 0)))
	phoneCss = consts.get("PhoneViewportCss", Vector2i(390, 844)) as Vector2i
	chromeScript = load("res://sources/gui/GuiUiScale.gd") as GDScript
	Check(touchPx >= 44, "área de toque declarada em produto = %d px (piso externo 44)" % touchPx)
	Check(phoneCss.x == 390 and phoneCss.y == 844, "moldura de telefone declarada em produto = %dx%d CSS px" % [phoneCss.x, phoneCss.y])

	# (2) O aparelho: janela do motor no tamanho CSS do telefone e a moldura imposta
	# no container real de janelas (o stretch deixa a base em 1280 de largura — por
	# isso a moldura é imposta, mesma leitura de panel_fit_test).
	var mainWin : Window = root as Window
	var savedWin : Vector2i = mainWin.size
	var savedFrame : Vector2 = windows.size
	designRect = Rect2(Vector2.ZERO, windows.get_global_rect().size)
	mainWin.size = phoneCss
	await process_frame
	await process_frame
	windows.size = Vector2(float(phoneCss.x), float(phoneCss.y))
	await process_frame
	await process_frame
	frame = windows.size
	CheckI(int(frame.x), phoneCss.x, "moldura de telefone imposta no container de janelas (largura)")
	CheckI(int(frame.y), phoneCss.y, "moldura de telefone imposta no container de janelas (altura)")
	visibleRect = Rect2(windows.get_global_position(), frame).intersection(Rect2(Vector2.ZERO, Vector2(float(phoneCss.x), float(phoneCss.y) + windows.get_global_position().y)))

	# (3) As superfícies de decisão, montadas no caminho do jogador.
	await _measureMessageBoxRow()
	await _measureLiveWindows()

	# (4) A régua só vale se cobre de fato.
	Check(measured >= 8, "%d controles de decisão medidos com retângulo real (piso 8)" % measured)

	mainWin.size = savedWin
	windows.size = savedFrame
	_finish()

# ------------------------------------------------------------------ superfícies

# O diálogo global de confirmar/cancelar: `MessageBox` + seus 4 botões de
# `ButtonBox`. Ele NÃO é `WindowPanel`, então nenhuma outra régua do repo o media.
# Instanciado sob o container real de janelas, na moldura do telefone.
func _measureMessageBoxRow() -> void:
	print("-- MessageBox (confirmar/cancelar global) --")
	var packed : PackedScene = load("res://presets/gui/MessageBox.tscn")
	if not Check(packed != null, "MessageBox.tscn carrega"):
		return
	var box : Node = packed.instantiate()
	windows.add_child(box)
	var control : Control = box as Control
	if not Check(control != null, "MessageBox instanciou como Control"):
		return
	# Mesma âncora do nó em Game.tscn: centro do container que o hospeda.
	control.set_anchors_preset(Control.PRESET_CENTER)
	control.grow_horizontal = Control.GROW_DIRECTION_BOTH
	control.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.call("Display", "Fundir consome o minério. Confirmar?",
			Callable(self, "_noop"), "Confirm", Callable(self, "_noop"), "Cancel",
			Callable(self, "_noop"), "Secondary", Callable(self, "_noop"), "Tertiary")
	await process_frame
	await process_frame
	var buttonBox : Control = box.get("buttonBox") as Control
	if not Check(buttonBox != null, "o MessageBox trouxe a linha de botões (buttonBox)"):
		box.queue_free()
		return
	_measureButtons(buttonBox, "MessageBox", visibleRect)
	# Largura que o telefone tem, menos a margem do painel: é o que a linha pode usar.
	var room : float = frame.x - 10.0
	var needed : int = touchPx * _visibleCount(buttonBox)
	if needed > int(room):
		# Nomeado, não escondido: a linha de 4 decisões não cabe em 390 px do jeito
		# que a cena desenha. Isto é o que a régua acusa; o conserto é produto.
		Check(false, "linha de decisão do MessageBox (%d botões × %d px = %d px) cabe nos %d px do telefone" % [_visibleCount(buttonBox), touchPx, needed, int(room)])
	box.call("Clear")
	windows.remove_child(box)
	box.free()

# Cada janela viva do HUD (aberta pelo botão real da barra) é reencolhida para a
# moldura do telefone e tem suas linhas de decisão medidas controle a controle.
func _measureLiveWindows() -> void:
	print("-- painéis de decisão na moldura do telefone --")
	var scenes : Array[String] = ["res://presets/gui/AuctionHouse.tscn", "res://presets/gui/RespawnWindow.tscn",
			"res://presets/gui/CellSelection.tscn", "res://presets/gui/Shop.tscn", "res://presets/gui/Settings.tscn",
			"res://presets/gui/Formation.tscn", "res://presets/gui/Quit.tscn"]
	var hosts : Array[Control] = []
	for path in scenes:
		var packed : PackedScene = load(path)
		if packed == null:
			continue
		var node : Node = packed.instantiate()
		if not (node is Control):
			node.free()
			continue
		var control : Control = node as Control
		windows.add_child(control)
		# Reencolhido para a moldura do aparelho: abaixo do próprio mínimo o painel
		# não vai, e é assim que ele estoura o telefone de verdade.
		control.size = frame
		control.position = Vector2.ZERO
		# Caminho de produto do telefone: `WindowPanel._enter_tree` faz exatamente
		# isto quando `IsTouch()`; aqui o flag é falso (headless), então o harness
		# chama a mesma entrada com toque explícito, como `panel_fit_test` faz.
		if chromeScript != null:
			chromeScript.call("ApplyDecisionChrome", control, true, frame.x - 12.0)
		await process_frame
		await process_frame
		hosts.append(control)
		for row in _decisionRows(control):
			_measureButtons(row, String(control.name), visibleRect)
	Check(hosts.size() >= 4, "%d painéis de decisão montados e medidos na moldura (piso 4)" % hosts.size())
	var bar : Control = gui.get("manualSkillBar") as Control
	if bar != null:
		_measureButtons(bar, "ManualHudBar", designRect.merge(bar.get_global_rect()))
	for host in hosts:
		windows.remove_child(host)
		host.free()

func _decisionRows(panel : Control) -> Array[Control]:
	var rows : Array[Control] = []
	for candidate in panel.find_children("*", "Container", true, false):
		var row : Control = candidate as Control
		var decisions : int = 0
		for child in row.get_children():
			if child is Button and _isDecision(child as Button):
				decisions += 1
		if decisions >= 2:
			rows.append(row)
	return rows

# ------------------------------------------------------------------ as três réguas

# Os botões de uma linha, PROCURADOS e não só como filhos diretos: quando a linha não
# cabe na sala do aparelho, `GuiUiScale.FitDecisionRow` empilha as decisões dentro de um
# `DecisionStack`. Ler `get_children()` da linha deixaria de enxergar os botões logo
# antes da régua que decide se o empilhamento era necessário — e a régua passaria por
# insuficiência de amostra, não por acerto.
func _rowButtons(row : Node) -> Array:
	var found : Array = []
	if row == null or not is_instance_valid(row):
		return found
	for candidate in row.find_children("*", "Button", true, false):
		found.append(candidate)
	return found

func _measureButtons(row : Node, tag : String, area : Rect2) -> void:
	for child in _rowButtons(row):
		if not (child is Button):
			continue
		var button : Button = child as Button
		if not _isDecision(button) or not bool(button.is_visible_in_tree()):
			continue
		measured += 1
		var label : String = "%s/%s" % [tag, String(button.name)]
		var rect : Rect2 = button.get_global_rect()
		# R1: na tela.
		Check(rect.intersects(area), "%s: retângulo %s INTERSECTA a área visível do telefone %s" % [label, _fmt(rect), _fmt(area)])
		var scrollable : bool = _isBehindScroll(button, rect, area)
		Check(area.grow(-epsilon).encloses(rect) or scrollable,
				"%s: retângulo %s cabe no telefone %dpx (ou está atrás de rolagem) — estoura %.0f px à direita / %.0f px embaixo" %
				[label, _fmt(rect), int(area.size.x), maxf(0.0, rect.end.x - area.end.x), maxf(0.0, rect.end.y - area.end.y)])
		# R2: área de toque declarada em produto.
		Check(rect.size.x >= float(touchPx) - epsilon and rect.size.y >= float(touchPx) - epsilon,
				"%s: alvo de toque %dx%d ≥ %d px declarado (largura %.1f, altura %.1f)" %
				[label, int(rect.size.x), int(rect.size.y), touchPx, rect.size.x, rect.size.y])
		# R3: ninguém rouba o press no centro do alvo.
		var center : Vector2 = rect.get_center()
		var owner : Control = _pressOwnerAt(center, windows)
		if owner != null and owner != button:
			Check(false, "%s: o press no centro %s cai em %s (%s), não no próprio botão — alvo coberto" %
					[label, _vec(center), String(owner.name), _fmt(owner.get_global_rect())])
		else:
			Check(true, "%s: nenhum controle acima rouba o press" % label)

func _isDecision(button : Button) -> bool:
	var haystack : String = String(button.name) + " " + String(button.text)
	for word in DecisionWords:
		if haystack.contains(word):
			return true
	return false

func _visibleCount(row : Node) -> int:
	var hits : int = 0
	for child in _rowButtons(row):
		if child is Button and bool((child as Button).is_visible_in_tree()) and _isDecision(child as Button):
			hits += 1
	return hits

# Quem receberia o toque em `point`: varre a árvore na ordem de pintura (pai antes dos
# filhos, filhos na ordem de irmão, `z_index` acumulado por cima) e devolve o último
# candidato visível que não ignora mouse. É a definição operacional de "coberto".
func _pressOwnerAt(point : Vector2, host : Node) -> Control:
	var ordered : Array[Control] = []
	_collectPaint(host, ordered)
	var best : Control = null
	var bestZ : float = -1.0e18
	var bestIdx : int = -1
	for idx in ordered.size():
		var candidate : Control = ordered[idx]
		if not bool(candidate.visible) or candidate.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			continue
		if not candidate.get_global_rect().has_point(point):
			continue
		var z : float = _zKey(candidate)
		if z > bestZ or (absf(z - bestZ) < 0.0001 and idx > bestIdx):
			best = candidate
			bestZ = z
			bestIdx = idx
	return best

func _collectPaint(node : Node, out : Array[Control]) -> void:
	if node is Control:
		out.append(node as Control)
	for child in node.get_children():
		_collectPaint(child, out)

func _zKey(node : Node) -> float:
	var total : float = 0.0
	var walker : Node = node
	while walker != null:
		if walker is CanvasItem:
			total += float((walker as CanvasItem).z_index)
			if not bool((walker as CanvasItem).z_as_relative):
				break
		walker = walker.get_parent()
	return total

# Estouro atrás de rolagem é alcançável de verdade; estouro solto não. Só conta
# rolagem no eixo que excede a moldura.
func _isBehindScroll(button : Control, rect : Rect2, area : Rect2) -> bool:
	var walker : Node = button.get_parent()
	while walker != null and walker != windows:
		if walker is ScrollContainer:
			var scroller : ScrollContainer = walker as ScrollContainer
			var fitsX : bool = rect.end.x <= area.end.x + epsilon
			var fitsY : bool = rect.end.y <= area.end.y + epsilon
			if fitsX and fitsY:
				return true
			if fitsY and int(scroller.vertical_scroll_mode) != int(ScrollContainer.SCROLL_MODE_DISABLED):
				return true
			if fitsX and int(scroller.horizontal_scroll_mode) != int(ScrollContainer.SCROLL_MODE_DISABLED):
				return true
		walker = walker.get_parent()
	return false

func _fmt(rect : Rect2) -> String:
	return "%.0f,%.0f..%.0f,%.0f" % [rect.position.x, rect.position.y, rect.end.x, rect.end.y]

func _vec(point : Vector2) -> String:
	return "%.0f,%.0f" % [point.x, point.y]

func _finish() -> void:
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
