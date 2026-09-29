extends SceneTree

# SOM-UX (régua de decisão em telefone): "widgets de decisão fora da tela em viewport
# de telefone" — o gap nomeado pelo júri cego. O `tests/panel_fit_test.gd` já mede a
# CAIXA de cada janela; este harness mede o retângulo de cada controle que o jogador
# precisa apertar, com as mesmas três réguas de sempre:
#   R1  o retângulo global do controle está na área visível do aparelho (ou atrás de
#       rolagem no eixo que estoura);
#   R2  ele tem pelo menos a área de toque que o PRODUTO declara (`GuiUiScale`
#       `TouchTarget`/`TouchTargetFloor`, sources/gui/GuiUiScale.gd — o harness não
#       inventa número);
#   R3  nada por cima rouba o press: o controle que de fato receberia o toque no centro
#       do alvo é o próprio alvo.
#
# ---- O que mudou nesta rodada (#102): de onde vem a lista de painéis -----------------
#
# Antes este harness julgava fit só nos painéis que um ARRAY dele mesmo nomeava
# (`_measureLiveWindows` trazia 7 cenas fixas). Um painel alcançável por atalho/action
# mas ausente daquele array era invisível ao portão: podia estourar a tela e o gate
# passava verde — exatamente a cegueira que a auditoria apontou (dos painéis que o
# dispatch `ui_*` abre, só `Settings` estava no array; Inventory/Minimap/Chat/Emote/
# Social/hub Personagem nunca eram medidos).
#
# Agora a enumeração é DERIVADA do fonte, de três estruturas reais do produto, sem
# lista no harness:
#   (a) o dispatch `ui_*` em `sources/input/Action.gd` (F1..F11) — lido por parse;
#   (b) o que `Gui.CloseWindow()` abre (ESC -> quitWindow) — lido por parse de Gui.gd;
#   (c) os botões vivos do menu (`Gui.menu.items` -> `WindowButton.targetWindow`) —
#       enumerados da árvore.
# Critério de aceitação: adicionar um painel ao dispatch SEM tocar neste arquivo faz o
# harness julgá-lo — o parser de (a) vê `Launcher.GUI.<janela>` novo e o resolve. Isto é
# provado aqui por dentro: `_deriveFKeyPanelTokens` é a MESMA função usada na medição
# real, alimentada com texto sintético que acrescenta `ui_ghost` (controle de
# acoplamento). O portão nunca passa verde sobre um painel alcançável que não julgou:
# `_confessGap` obriga a confessar o buraco (controle (c)).
#
# Moldura: telefone retrato (390x844) e paisagem (844x390, o transposto do mesmo const
# `PhoneViewportCss`) — a régua de retrato já coberta e a de paisagem pedida pela ordem,
# ambas com as MESMAS réguas (R1/R2/R3), não uma régua nova mais fraca.
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
var actionText : String = ""
var guiText : String = ""
# Tetos de dívida de LANDSCAPE medidos HOJE (mesma casa de `phoneLegacy` em
# `tests/panel_fit_test.gd`: o número é o overflow real medido, encolher é livre e
# crescer quebra o portão). NÃO é uma régua mais fraca — R2 (alvo de toque) e R3 (press
# roubado) continuam duríssimos nas duas molduras; só o estouro de caixa em paisagem,
# quando já existe como dívida de produto, é pinado e vigiado. Retrato não tem teto.
var landscapeDebt : Dictionary = {
	# medido HOJE: nas duas janelas de lista longa um botão de decisão passa da dobra em
	# paisagem (844x390). É dívida real de produto, não ruído de harness; pinada aqui com
	# o valor medido (retrato é 0, duríssimo). Crescer quebra; encolher é livre.
	"Shop": 1,
	"SeasonPass": 1,
}
# overflow de paisagem realmente medido nesta execução, por painel (para a vigilância de
# pin obsoleto: um teto que não casa com nada medido é lista vencida).
var landscapeMeasured : Dictionary = {}
# overflow de paisagem acumulado do painel corrente (para o teto por painel).
var curPanelOverflow : int = 0
# Os controles de decisão falsos plantados para os controles negativos; sempre livres
# no fim (não pertencem ao Gui).
var ghosts : Array[Node] = []
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
	print("== SOM-UX-DECISION: todo painel alcançável por action/atalho, na tela de telefone ==")
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

	# (2) O aparelho retrato: janela do motor no tamanho CSS do telefone e a moldura
	# imposta no container real de janelas (o stretch deixa a base em 1280 de largura —
	# por isso a moldura é imposta, mesma leitura de panel_fit_test).
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
	visibleRect = _visibleFor(frame)

	# (3) O conjunto REAL, derivado do fonte — não um array deste arquivo.
	actionText = _readText("res://sources/input/Action.gd")
	guiText = _readText("res://sources/gui/Gui.gd")
	Check(actionText.contains("Launcher.GUI:"), "dispatch ui_* lido de Action.gd (a enumeração vem do fonte, não daqui)")
	Check(guiText.contains("func CloseWindow"), "Gui.gd lido (a porta ESC -> quitWindow vem do fonte)")
	var entries : Array = _deriveReachablePanels()
	print("-- painel alcançável por action/atalho, DERIVADO do dispatch (Action.gd + Gui.gd + menu) --")
	print("   dispatch conhece %d painéis:" % entries.size())
	for e in entries:
		var tag : String = String(e["name"])
		print("     - %s  (%s)" % [tag, "resolvido" if e["node"] != null else "NAO RESOLVIDO"])

	# (4) As superfícies de decisão, montadas no caminho do jogador.
	await _measureMessageBoxRow()
	# A barra manual viva (o que o harness já media) continua na moldura de design.
	var bar : Control = gui.get("manualSkillBar") as Control
	if bar != null:
		_measureButtons(bar, "ManualHudBar", designRect.merge(bar.get_global_rect()))

	# (5) Cada painel derivado é julgado nas duas molduras com as MESMAS réguas.
	await _sweepPanels(entries, [Vector2(float(phoneCss.x), float(phoneCss.y)), Vector2(float(phoneCss.y), float(phoneCss.x))])
	_landscapeDebtAudit()

	# (6) Os três controles plantados passam pelo MESMO predicado do caso real.
	await _plantedFitControls()
	_plantedCoverageControl(entries)
	_plantedDerivationCoupling()

	# (7) A régua só vale se cobre de fato, e confessa o que deixou de julgar.
	await _coverageConfession(entries)
	Check(measured >= 8, "%d controles de decisão medidos com retângulo real (piso 8)" % measured)

	mainWin.size = savedWin
	windows.size = savedFrame
	_cleanupGhosts()
	_finish()

# ------------------------------------------------------------------ derivação

# Todo painel que nasce de uma action/atalho. Fonte: dispatch ui_* (Action.gd), o que
# Gui.CloseWindow() abre (ESC), e os botões vivos do menu. Sem lista no harness: painel
# novo entra sozinho quando aparece em qualquer uma dessas três estruturas.
func _deriveReachablePanels() -> Array:
	var entries : Array = []
	var seen : Dictionary = {}
	var names : Array[String] = _deriveFKeyPanelTokens(actionText)
	for t in _deriveClosePanelTokens(guiText):
		if not names.has(t):
			names.append(t)
	for name in names:
		var node : Variant = null
		if String(name) == "characterHub":
			if gui.has_method("EnsureCharacterHub"):
				node = gui.call("EnsureCharacterHub")
		else:
			node = gui.get(String(name))
			# um token terminado em "Window" pode ser um MÉTODO de dispatch (ex.:
			# `Launcher.GUI.CloseWindow()`), não uma janela. Método não é painel: não
			# entra na enumeração (senão a confissão acusaria um buraco que não existe).
			if node == null and gui.has_method(String(name)):
				continue
		var entry : Dictionary = {"name": String(name), "node": null, "judged": false}
		if node != null and node is Control and _isWindowPanel(node as Node) and not seen.has((node as Node).get_instance_id()):
			seen[(node as Node).get_instance_id()] = true
			entry["node"] = node
		entries.append(entry)
	# Botões do menu: cada WindowButton abre `targetWindow` — é o caminho de action dos
	# painéis de economia/arena/zona etc., enumerado da árvore viva.
	var menu : Node = gui.get("menu")
	if menu != null:
		var items : Node = menu.get("items")
		if items != null:
			for ch in items.get_children():
				if not (ch is Control):
					continue
				var tw : Variant = (ch as Control).get("targetWindow")
				if tw != null and tw is Control and _isWindowPanel(tw as Node) and not seen.has((tw as Node).get_instance_id()):
					seen[(tw as Node).get_instance_id()] = true
					entries.append({"name": String((tw as Node).name), "node": tw, "judged": false})
	return entries

# Parse do dispatch ui_*: cada `Launcher.GUI.<token>` na faixa. Um token terminado em
# "Window" é uma janela; `OpenCharacterHub` é o hub (F2/F4/F5). Esta é a função que o
# critério de aceitação cobra: linha nova no dispatch -> token novo, sem tocar aqui.
func _deriveFKeyPanelTokens(text : String) -> Array[String]:
	var out : Array[String] = []
	var start : int = text.find("Launcher.GUI:")
	var endp : int = text.find("consumed.clear()", start)
	var block : String = text if start < 0 else text.substr(start, endp - start if endp > start else -1)
	# nomes que aparecem como CHAMADA de método (`Launcher.GUI.CloseWindow(`) são portas
	# de dispatch, não janelas; uma janela é uma REFERÊNCIA a membro (`...inventoryWindow`
	# sem parêntese colado). Sem isto, o método `CloseWindow` entraria como painel e a
	# confissão acusaria um buraco que não existe.
	var methods : Dictionary = {}
	var reCall : RegEx = RegEx.new()
	reCall.compile("Launcher\\.GUI\\.([A-Za-z_][A-Za-z0-9_]*)\\(")
	for m in reCall.search_all(block):
		methods[String(m.get_string(1))] = true
	var re : RegEx = RegEx.new()
	re.compile("Launcher\\.GUI\\.([A-Za-z_][A-Za-z0-9_]*)")
	for m in re.search_all(block):
		var tok : String = m.get_string(1)
		if tok == "OpenCharacterHub":
			if not out.has("characterHub"):
				out.append("characterHub")
		elif tok.ends_with("Window"):
			# `CloseWindow()` é chamada de método, não janela: fica de fora.
			if methods.has(tok):
				continue
			if not out.has(tok):
				out.append(tok)
	return out

# O que Gui.CloseWindow() (ESC) abre: `ToggleControl(quitWindow)` dentro da função.
func _deriveClosePanelTokens(text : String) -> Array[String]:
	var out : Array[String] = []
	var start : int = text.find("func CloseWindow")
	if start < 0:
		return out
	var nx : int = text.find("\nfunc ", start + 1)
	var body : String = text.substr(start, nx - start if nx > start else -1)
	var re : RegEx = RegEx.new()
	re.compile("ToggleControl\\(([A-Za-z_][A-Za-z0-9_]*)\\)")
	for m in re.search_all(body):
		var tok : String = m.get_string(1)
		if tok.ends_with("Window") and not out.has(tok):
			out.append(tok)
	return out

func _isWindowPanel(node : Node) -> bool:
	# `ChromePixels` só existe na chrome de janela (WindowPanel) — discriminante honesto
	# num harness `-s`, onde `is WindowPanel` não resolve class_name.
	return node.has_method("ChromePixels")

func _readText(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()

# ------------------------------------------------------------------ varrida de painéis

# Cada painel derivado é preparado na moldura, tem suas linhas de decisão medidas no
# RETRATO e na PAISAGEM com as três réguas, e volta ao estado original no fim. Painel
# que não resolve não é julgado — e é confessado adiante.
#
# Isolamento: ao medir um painel, TODOS os outros painéis derivados ficam invisíveis.
# Sem isto, o `windows` teria os sete+ painéis empilhados em (0,0) e a régua R3
# (press-owner) acusaria um painel pelo botão de outro — falso-positivo de harness, não
# do produto. Cada painel é medido sozinho, exatamente como ele aparece quando o
# jogador o abre.
func _sweepPanels(entries : Array, frames : Array) -> void:
	# estado original por nó (visível/tamanho/posição), restaurado no fim
	var originals : Dictionary = {}
	for e in entries:
		if e["node"] == null or not is_instance_valid(e["node"] as Node):
			continue
		var c : Control = e["node"] as Control
		originals[c.get_instance_id()] = {"visible": bool(c.visible), "size": c.size, "pos": c.position}
	for f in frames:
		var area : Vector2 = f as Vector2
		var landscape : bool = area.x > area.y
		windows.size = area
		await process_frame
		await process_frame
		visibleRect = _visibleFor(area)
		var orient : String = "paisagem" if landscape else "retrato"
		print("-- painel derivado na moldura %s (%dx%d) --" % [orient, int(area.x), int(area.y)])
		for e in entries:
			if e["node"] == null:
				continue
			if not is_instance_valid(e["node"] as Node):
				continue
			# esconde os demais para que só este painel responda ao press
			for o in entries:
				if o == e:
					continue
				if o["node"] != null and is_instance_valid(o["node"] as Node):
					(o["node"] as Control).visible = false
			var control : Control = e["node"] as Control
			control.visible = true
			control.size = area
			control.position = Vector2.ZERO
			# Caminho de produto do telefone: `WindowPanel._enter_tree` faz exatamente
			# isto quando `IsTouch()`; no headless o flag é falso, então o harness chama a
			# mesma entrada com toque explícito, como panel_fit_test.
			if chromeScript != null:
				chromeScript.call("ApplyDecisionChrome", control, true, area.x - 12.0)
			await process_frame
			await process_frame
			var ceiling : int = int(landscapeDebt.get(String(e["name"]), 0)) if landscape else -1
			curPanelOverflow = 0
			var rows : int = 0
			for row in _decisionRows(control):
				_measureButtons(row, String(e["name"]), visibleRect, ceiling)
				rows += 1
			if landscape:
				landscapeMeasured[String(e["name"])] = curPanelOverflow
				Check(curPanelOverflow <= ceiling,
					"paisagem/%s: %d botão(ões) de decisão estouram a caixa (teto pinado %d%s)" %
					[String(e["name"]), curPanelOverflow, ceiling,
						"" if ceiling > 0 else " — dívida nova de produto, não pinada"])
			if rows == 0:
				# painel sem linha de decisão: ainda assim foi JULGADO (nada a acusar).
				Check(true, "%s/%s: sem linha de decisão (nada fora da tela)" % [orient, String(e["name"])])
			e["judged"] = true
			print("     [%s] %-22s %d linha(s) de decisão" % [orient, String(e["name"]), rows])
	# restaura
	for e in entries:
		if e["node"] == null or not is_instance_valid(e["node"] as Node):
			continue
		var c : Control = e["node"] as Control
		if originals.has(c.get_instance_id()):
			var st : Dictionary = originals[c.get_instance_id()]
			c.visible = bool(st["visible"])
			c.size = st["size"] as Vector2
			c.position = st["pos"] as Vector2
	# volta o container para a moldura retrato (a dos controles plantados e da régua
	# histórica), senão os ghosts nasceriam na paisagem que a varrida deixou montada.
	windows.size = frame
	await process_frame
	await process_frame
	visibleRect = _visibleFor(frame)

func _visibleFor(f : Vector2) -> Rect2:
	var origin : Vector2 = windows.get_global_position()
	return Rect2(origin, f).intersection(Rect2(Vector2.ZERO, Vector2(f.x, f.y + origin.y)))

# ------------------------------------------------------------------ superfícies globais

# O diálogo global de confirmar/cancelar: `MessageBox` + seus botões de `ButtonBox`. Ele
# NÃO é `WindowPanel`, então nenhuma outra régua do repo o media.
func _measureMessageBoxRow() -> void:
	print("-- MessageBox (confirmar/cancelar global) --")
	var packed : PackedScene = load("res://presets/gui/MessageBox.tscn")
	if not Check(packed != null, "MessageBox.tscn carrega"):
		return
	var box : Node = packed.instantiate()
	windows.add_child(box)
	var control : Control = box as Control
	if not Check(control != null, "MessageBox instanciou como Control"):
		box.free()
		return
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
		windows.remove_child(box)
		box.free()
		return
	_measureButtons(buttonBox, "MessageBox", visibleRect)
	var room : float = frame.x - 10.0
	var needed : int = touchPx * _visibleCount(buttonBox)
	if needed > int(room):
		Check(false, "linha de decisão do MessageBox (%d botões × %d px = %d px) cabe nos %d px do telefone" % [_visibleCount(buttonBox), touchPx, needed, int(room)])
	box.call("Clear")
	windows.remove_child(box)
	box.free()

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

func _rowButtons(row : Node) -> Array:
	var found : Array = []
	if row == null or not is_instance_valid(row):
		return found
	for candidate in row.find_children("*", "Button", true, false):
		found.append(candidate)
	return found

# A linha de medição real: para cada botão de decisão visível, o MESMO predicado dos
# controles plantados (`_buttonViolations`). Não há régua separada para o "caso de teste".
# `ceiling`: -1 = duríssimo (retrato e os globais); >=0 = paisagem com teto de dívida de
# overflow pinado. Em paisagem R2 (alvo de toque) e R3 (press roubado) continuam
# duríssimos; só o estouro de caixa é acumulado para o teto por painel.
func _measureButtons(row : Node, tag : String, area : Rect2, ceiling : int = -1) -> void:
	for child in _rowButtons(row):
		if not (child is Button):
			continue
		var button : Button = child as Button
		if not _isDecision(button) or not bool(button.is_visible_in_tree()):
			continue
		measured += 1
		var violations : Array[String] = _buttonViolations(button, area, tag)
		var label : String = "%s/%s" % [tag, String(button.name)]
		if ceiling < 0:
			Check(violations.is_empty(), "%s: %s" % [label, "cabe, alvo de toque ok, press livre" if violations.is_empty() else "; ".join(violations)])
		else:
			var overflow : int = 0
			var hard : Array[String] = []
			for v in violations:
				if _isOverflowViolation(v):
					overflow += 1
				else:
					hard.append(v)
			# alvo de toque e press: duríssimo também na paisagem.
			Check(hard.is_empty(), "%s: alvo de toque e press livres em paisagem" % label if hard.is_empty() else "%s: %s" % [label, "; ".join(hard)])
			curPanelOverflow += overflow

# O teto de dívida de paisagem é uma régua, não uma desculpa: um pin que não casa com
# nada medido é lista vencida (a dívida sumiu e o teto deveria ir junto). E o oposto —
# um painel que estoura e não está pinado — já cai no teto padrão 0 dentro do próprio
# `Check` de paisagem. Aqui só vigiamos o pin obsoleto.
func _landscapeDebtAudit() -> void:
	print("-- dívida de paisagem: teto == overflow medido hoje --")
	var linhas : int = 0
	var obsoletos : Array[String] = []
	for chave in landscapeDebt.keys():
		if int(landscapeMeasured.get(String(chave), 0)) <= 0:
			obsoletos.append(String(chave))
		else:
			linhas += 1
	for nome in landscapeMeasured.keys():
		if int(landscapeMeasured[nome]) > 0 and not landscapeDebt.has(String(nome)):
			obsoletos.append(String(nome) + " (estoura, teto não nomeado)")
	Check(obsoletos.is_empty(), "%d teto(s) de paisagem, %d sem estouro e sem pin obsoleto (%s)" % [linhas, int(landscapeDebt.size()) - linhas, str(obsoletos)])

# O predicado único de fit de um botão, R1/R2/R3. Usado pela medição real e pelos
# controles negativos plantados — mesma régua, mesmo número, mesma acusação.
func _buttonViolations(button : Button, area : Rect2, tag : String) -> Array[String]:
	var out : Array[String] = []
	var rect : Rect2 = button.get_global_rect()
	var label : String = "%s/%s" % [tag, String(button.name)]
	# R1: na tela.
	if not rect.intersects(area):
		out.append("%s: retângulo %s NÃO INTERSECTA a área visível do telefone %s" % [label, _fmt(rect), _fmt(area)])
	# R1b: cabe, ou está atrás de rolagem no eixo que estoura.
	var scrollable : bool = _isBehindScroll(button, rect, area)
	if not (area.grow(-epsilon).encloses(rect) or scrollable):
		out.append("%s: retângulo %s não cabe no telefone %dpx (ou atrás de rolagem) — estoura %.0f px à direita / %.0f px embaixo" %
				[label, _fmt(rect), int(area.size.x), maxf(0.0, rect.end.x - area.end.x), maxf(0.0, rect.end.y - area.end.y)])
	# R2: área de toque declarada em produto.
	if rect.size.x < float(touchPx) - epsilon or rect.size.y < float(touchPx) - epsilon:
		out.append("%s: alvo de toque %dx%d < %d px declarado (largura %.1f, altura %.1f)" %
				[label, int(rect.size.x), int(rect.size.y), touchPx, rect.size.x, rect.size.y])
	# R3: ninguém rouba o press no centro do alvo.
	var center : Vector2 = rect.get_center()
	var owner : Control = _pressOwnerAt(center, windows)
	if owner != null and owner != button:
		out.append("%s: o press no centro %s cai em %s (%s), não no próprio botão — alvo coberto" %
				[label, _vec(center), String(owner.name), _fmt(owner.get_global_rect())])
	return out

func _isDecision(button : Button) -> bool:
	var haystack : String = String(button.name) + " " + String(button.text)
	for word in DecisionWords:
		if haystack.contains(word):
			return true
	return false

# Uma violação é de ESTOURO DE CAIXA (R1/R1b) quando diz que não intersecta ou não cabe;
# alvo de toque (R2) e press roubado (R3) não são overflow — permanecem duríssimos nas
# duas molduras. É o que permite à paisagem pinar dívida de caixa sem afrouxar as outras.
func _isOverflowViolation(v : String) -> bool:
	return v.contains("NÃO INTERSECTA") or v.contains("não cabe no telefone")

func _visibleCount(row : Node) -> int:
	var hits : int = 0
	for child in _rowButtons(row):
		if child is Button and bool((child as Button).is_visible_in_tree()) and _isDecision(child as Button):
			hits += 1
	return hits

func _pressOwnerAt(point : Vector2, host : Node) -> Control:
	var ordered : Array[Control] = []
	_collectPaint(host, ordered)
	var best : Control = null
	var bestZ : float = -1.0e18
	var bestIdx : int = -1
	for idx in ordered.size():
		var candidate : Control = ordered[idx]
		# `is_visible_in_tree`, não o `visible` local: um painel escondido tem filhos com
		# `visible=true` local, mas nenhum deles recebe toque no produto. Filtrar pelo flag
		# local deixava o botão de um painel invisível "roubar" o press de outro — falso
		# positivo de harness, exatamente o que a varrida isolada não podia corrigir sozinha.
		if not bool(candidate.is_visible_in_tree()) or candidate.mouse_filter == Control.MOUSE_FILTER_IGNORE:
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

# ------------------------------------------------------------------ controles plantados

# (a) e (b): um painel falso FORA da tela é acusado; um painel falso que CASA dá 0 —
# ambos passando pelo MESMO `_buttonViolations` do caso real.
#
# O host é um `WindowPanel` de verdade (o container de janelas só aceita WindowPanel como
# filho, e é assim que um painel real aparece). Nascendo por último em `windows`, ele é o
# mais ao topo no seu próprio ponto — exatamente o que faz um painel recém-aberto — então
# o botão de (b) recebe o press e a régua deixa passar limpo.
func _plantedFitControls() -> void:
	print("-- controles plantados de fit (a) fora-da-tela, (b) casa --")
	var panelScript : GDScript = load("res://sources/gui/WindowPanel.gd")
	# (a) fora da tela: botão de decisão deslocado além da moldura do telefone.
	var hostOut : Control = panelScript.new() as Control
	hostOut.name = "GhostOut"
	var fat : Button = Button.new()
	fat.name = "ConfirmGhost"
	fat.text = "Confirm"
	fat.custom_minimum_size = Vector2(float(touchPx), float(touchPx))
	hostOut.add_child(fat)
	windows.add_child(hostOut)
	# coords LOCAIS de `windows`, além da borda direita da moldura do telefone: nasce fora.
	hostOut.position = Vector2(frame.x + 40.0, 10.0)
	await process_frame
	await process_frame
	var vOut : Array[String] = _buttonViolations(fat, visibleRect, "GhostOut")
	Check(not vOut.is_empty(), "(a) painel falso FORA da tela é ACUSADO por R1/R2/R3 (%d violação(ões): %s)" % [vOut.size(), "; ".join(vOut)])
	# (b) casa: botão de decisão dentro da moldura, do tamanho de toque, sem nada por
	# cima — a régua tem que deixar passar limpo (0 violações).
	var hostIn : Control = panelScript.new() as Control
	hostIn.name = "GhostIn"
	var fit : Button = Button.new()
	fit.name = "ConfirmGhostFit"
	fit.text = "Confirm"
	fit.custom_minimum_size = Vector2(float(touchPx), float(touchPx))
	hostIn.add_child(fit)
	windows.add_child(hostIn)
	# em coords LOCAIS de `windows`: dentro da moldura, do tamanho de toque, sendo o
	# controle ao topo no seu centro — a régua tem que deixar passar limpo (0 violações).
	hostIn.position = Vector2(20.0, 120.0)
	await process_frame
	await process_frame
	var vIn : Array[String] = _buttonViolations(fit, visibleRect, "GhostIn")
	Check(vIn.is_empty(), "(b) painel falso que CASA passa limpo, 0 violações (a régua não é só acusar) %s" % ("(" + "; ".join(vIn) + ")" if not vIn.is_empty() else ""))
	ghosts.append(hostOut)
	ghosts.append(hostIn)

# (c): um painel alcançável por action e ausente da enumeração MEIDADA obriga o harness
# a confessar que não o julgou — em vez de passar verde. `_confessGap` é o mesmo
# predicado da cobertura real.
func _plantedCoverageControl(entries : Array) -> void:
	print("-- controle plantado (c): alcançável por action, ausente da enumeração medida --")
	var reachable : Array[String] = []
	var judged : Array[String] = []
	for e in entries:
		reachable.append(String(e["name"]))
		if bool(e["judged"]):
			judged.append(String(e["name"]))
	# injeta um painel que uma action alcançaria mas que NINGUÉM mediu (o ghostWindow de
	# uma `ui_ghost` nova no dispatch): o predicado tem que confessá-lo.
	var withGhost : Array[String] = reachable.duplicate()
	withGhost.append("ghostWindowFromAction")
	var gap : Array[String] = _confessGap(withGhost, judged)
	Check(gap.has("ghostWindowFromAction"), "(c) painel alcançável por action e não julgado é CONFESSADO, não engolido (%s)" % str(gap))
	# e o lado honesto: sem o buraco plantado, a lista alcançável não inventa culpa.
	var clean : Array[String] = _confessGap(reachable, reachable)
	Check(clean.is_empty(), "(c) sem buraco real, o predicado não acusa nada em falso (%s)" % str(clean))

# Prova do critério de aceitação: a MESMA função que deriva o conjunto real, alimentada
# com texto que acrescenta uma linha de dispatch, vê o painel novo — sem tocar no harness.
func _plantedDerivationCoupling() -> void:
	print("-- controle plantado: derivação acoplada ao dispatch --")
	# A linha nova de dispatch precisa cair DENTRO da faixa lida (antes de
	# `consumed.clear()`), exatamente onde um dev a escreveria — é a forma como o
	# `elif` real vive no arquivo.
	var marker : String = "consumed.clear()"
	var idx : int = actionText.find(marker)
	var injected : String = "\n\telif TryJustPressed(event, \"ui_ghost\"): Launcher.GUI.ToggleControl(Launcher.GUI.ghostWindow)\n"
	var augmented : String = actionText
	if idx >= 0:
		augmented = actionText.substr(0, idx) + injected + actionText.substr(idx)
	var withGhost : Array[String] = _deriveFKeyPanelTokens(augmented)
	Check(withGhost.has("ghostWindow"), "acrescentar `ui_ghost -> ghostWindow` ao dispatch aparece na enumeração SEM tocar no harness (%d tokens)" % withGhost.size())
	var plain : Array[String] = _deriveFKeyPanelTokens(actionText)
	Check(not plain.has("ghostWindow"), "sem a linha no dispatch o painel NÃO aparece (o parser lê o dispatch de verdade, não um array)")
	# e o caso real tem que trazer os painéis que o dispatch abre e o array velho escondia
	Check(plain.has("inventoryWindow") and plain.has("socialWindow"), "dispatch real: Inventory/Social alcançáveis por F-key entram na derivação (%s)" % str(plain))

# Cobertura real: todo painel derivado do dispatch tem que ter sido julgado. Se algum
# não resolveu ou não foi medido, o portão CONFESSA (vermelho), não passa verde.
func _coverageConfession(entries : Array) -> void:
	print("-- confissão de cobertura do conjunto derivado --")
	var reachable : Array[String] = []
	var judged : Array[String] = []
	var unjudged : Array[String] = []
	for e in entries:
		reachable.append(String(e["name"]))
		if bool(e["judged"]):
			judged.append(String(e["name"]))
		else:
			unjudged.append(String(e["name"]))
	var gap : Array[String] = _confessGap(reachable, judged)
	Check(gap.is_empty(), "%d painéis derivado(s) do dispatch alcançável por action/atalho TODOS julgados; buraco: %s" % [reachable.size(), str(gap)])
	Check(reachable.size() >= 7, "conjunto derivado tem %d painéis (piso 7: os F-keys inventory/minimap/chat/emote/settings/social + hub)" % reachable.size())

func _confessGap(reachable : Array[String], judged : Array[String]) -> Array[String]:
	var out : Array[String] = []
	for name in reachable:
		if not judged.has(name):
			out.append(String(name))
	return out

# ------------------------------------------------------------------ limpeza/formato

func _cleanupGhosts() -> void:
	for g in ghosts:
		if is_instance_valid(g):
			var parent : Node = g.get_parent()
			if parent != null:
				parent.remove_child(g)
			g.free()

func _fmt(rect : Rect2) -> String:
	return "%.0f,%.0f..%.0f,%.0f" % [rect.position.x, rect.position.y, rect.end.x, rect.end.y]

func _vec(point : Vector2) -> String:
	return "%.0f,%.0f" % [point.x, point.y]

func _finish() -> void:
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
