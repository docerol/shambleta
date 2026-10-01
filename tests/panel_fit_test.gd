extends SceneTree

# SOM-IDLE UX/UI (juiz cego 2026-09-27, UX/UI 7.5/10): "botão fora da tela". O
# `GuildPanel` declarava 420x560 e o corpo montado em código pedia 511x1061 — contra
# o viewport de projeto (1280x720) a linha de chat da guild, o Confirm/Cancel da
# prévia de gasto e o Feedback simplesmente não existiam para o jogador, porque a
# janela cujo conteúdo é maior que a tela transborda e nasce com a parte de baixo
# abaixo da borda. O clamp que faz isso está em
# `size.x = clamp(...)` / `size.y = clamp(...)` (sources/gui/WindowPanel.gd:238-240),
# dentro de `UpdateWindow` — as três linhas acima dele são o ramo de arrastar a
# janela, que não mexe em tamanho nenhum.
#
# Esta é a cerca da CLASSE de bug, não uma foto do GuildPanel: o harness instancia
# TODO painel de HUD (todo script de `sources/gui` que herda de `WindowPanel`,
# direto ou por classe do próprio diretório; quando existe cena do painel, é a cena
# que entra, porque é ela que declara a caixa da janela) dentro do container de
# janelas flutuantes real do `Gui`, roda layout de verdade e mede retângulos — é a
# primeira régua do repo que mede geometria (`grep -rn "combined_minimum" tests/`
# devolvia vazio antes disto). Duas regras, por painel:
#
#   R1  o mínimo do painel cabe na área de janelas flutuantes (viewport de design);
#   R2  todo nó visível do painel cabe na caixa realizada da janela — se não cabe, o
#       desbordamento tem que ser ALCANÇÁVEL: existe ScrollContainer ancestral com
#       rolagem habilitada NAQUELE eixo. Sem isso, um rótulo longo ou uma linha de
#       botões nova empurra controles para fora da tela de novo e ninguém vê.
#       Os eixos não são iguais: embaixo da borda não existe escape, então VALE para
#       qualquer nó; na largura, rótulo/painel decorativo é aparado pela janela e vai
#       para o log, enquanto controle interactivo (botão, campo, slider) fora da caixa
#       sem rolagem horizontal é falha — era exatamente esse o defeito nomeado.
#
# Painel novo entra sozinho na régua (a lista é descoberta em disco, sem whitelist).
#
# ---- segunda passada: o telefone (390x844, iPhone 12/13/14 em retrato) ----------
#
# A régua acima mede contra o viewport do PROJETO (1280x720). Ela nunca respondeu a
# pergunta "a UI CABE num telefone?", porque nenhuma passada existia num viewport de
# telefone. Agora existe, e ela é dura por um motivo que também é medido aqui: com
# `window/stretch/mode="canvas_items"` + `aspect="expand"` da base `display` em 1280x720
# (`project.godot:@display`), uma janela de 390x844 CSS px não vira um design space de
# 390x844 — vira 1280x2770, ou seja, o motor espreme o layout de desktop em 0,30 CSS
# px por pixel de design (a passada lê esse número do próprio motor, linha abaixo).
# É por isso que a pergunta que vale é a de 1:1: se o telefone fosse o espaço de
# design, o layout cabe? Respondido com retângulos reais, não com intenção.
#
#   R3  o mínimo realizado da janela cabe no telefone (390x844). Onde hoje não cabe,
#       o portão é o medido por painel (`phoneLegacy`, com folga) e a meta 390x844
#       continua declarada e impressa com nome e número — mesma política de
#       `deploy/WEB_SLIM.md` para o peso do pacote: teto real acima da meta => o
#       número de hoje barra, a meta não some. Encolher é livre; crescer, ou nascer
#       janela nova fora da lista, quebra.
#   R4  no telefone, todo controle interactivo que passa da moldura do telefone
#       (390x844, ou o teto nomeado do painel) tem que estar atrás de rolagem no
#       eixo — é R2, mas contra a tela do aparelho, não contra o monitor.
#   R5  chrome de toque: alvo de resize da janela e o botão de fechar da barra de
#       título são do tamanho que o produto promete (`GuiUiScale.TouchTarget`, 48 px,
#       sobre um piso externo de 44 px) quando o toque é o dispositivo, e voltam ao
#       valor de mouse (6/10 px) quando não é — os dois lados são medidos, porque só
#       o lado "grande" não prova que a regra faz alguma coisa.
#   R6  controle negativo: uma janela inflada em memória tem que ser pega por R3 e
#       por R4. Régua que nunca viu um transbordamento não é régua.
#
# Uso: godot --headless --path . -s tests/panel_fit_test.gd
#       (XDG_DATA_HOME/XDG_CACHE_HOME próprios — ver scripts/test.sh.)
# Exit code: número de checks falhos. Última linha: `== RESULT: N checks, M failures ==`.
#
# Como todo harness `-s`: o main-loop compila antes de autoload/class_name do projeto
# existirem, então nada de identificador de autoload nem class_name em anotação de
# tipo — tudo via load()/get()/call(). Classes do motor (Control, ScrollContainer,
# PackedScene) são resolvidas de outro jeito e continuam valendo.

var checks : int = 0
var failures : int = 0
var dbScript : GDScript = null
var launcher : Node = null
var gui : Node = null
var windows : Node = null
var canvas : Vector2 = Vector2.ZERO
var measured : int = 0
var phoneMeasured : int = 0
# Moldura do telefone medida no motor (390x844 CSS px), não digitada na conta.
var phoneFrame : Vector2 = Vector2.ZERO
# Quantos CSS px um pixel de design ocupa no telefone: é o que a passada lê do
# stretch real, e o motivo de a régua de telefone ser a de 1:1.
var cssPerDesignPx : float = 1.0
# O que o telefone mostra de cada janela HOJE, por nome: [largura, altura] medidos
# na passada de telefone + folga de 10 px. Meta declarada: 390x844 (const Phone*).
# Só entram aqui os painéis que NÃO cabem: Boss/Chests/StatPanel/ZoneMap/GuildPanel
# estouram a largura, AuctionHouseWindow/Boss/Chests/Cosmetics/SeasonPass estouram a
# altura. Sai da lista quem encolher (aí passou a caber de verdade); quem crescer
# além do teto nomeado, ou nascer janela nova fora dele, quebra o portão.
var phoneLegacy : Dictionary = {
	"AuctionHouseWindow": [237, 1644],
	"Boss": [410, 3002],
	"Chests": [410, 1440],
	"Cosmetics": [390, 1442],
	"GuildPanel": [430, 570],
	"SeasonPass": [390, 1016],
	"StatPanel": [490, 330],
	"ZoneMap": [430, 410],
}
# Painel em medição (o walk é método e não leva nome por parâmetro) e o que a regra
# horizontal tolerate: rótulo/painel decorativo alguns pixels fora da caixa, que a
# própria janela apara. Registrado, nunca escondido.
var currentName : String = ""
var cosmeticX : Array = []
# A varrida de telefone roda sobre a mesma árvore e não precisa regravar o que a de
# desktop já registrou: decorativo é logged uma vez por painel.
var quietCosmetic : bool = false

# Meio pixel de boa-vontade com arredondamento de layout; nada mais.
const Epsilon : float = 1.5
# Telefone real: 390x844 CSS px (iPhone 12/13/14, retrato). O número é a moldura,
# não uma preferência: é o viewport que o shell web entrega (meta width=device-width).
const PhoneW : float = 390.0
const PhoneH : float = 844.0
# Piso externo de alvo de toque (Apple HIG 44 pt / WCAG 2.5.5). O produto promete
# mais que isso (`GuiUiScale.TouchTarget` = 48 px) e é 48 que vale; 44 é o chão que
# esta régua não deixa cruzar nem por argumento de "o número mudou".
const TouchFloorPx : int = 44

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

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _repoFile(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()

func _initialize():
	_run()

func _run() -> void:
	print("== SOM-UX: todo painel de HUD cabe na tela (ou é rolável) ==")
	launcher = _autoload("Launcher")
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
	# O preload threadado do DB precisa estar drenado antes de qualquer load()/quit()
	# (mesma espera de social_fix_test/hud_wiring_test; sources/db/DB.gd:232).
	dbScript = load("res://sources/db/DB.gd")
	for tick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			break
		await create_timer(0.25).timeout
	print("== boot wait done (%d ms) ==" % waited)
	if not Check(ready, "SQL + World init no boot headless"):
		_finish()
		return

	gui = launcher.get("GUI")
	if not Check(gui != null, "Launcher.GUI vive no boot headless (é o canvas do HUD real)"):
		_finish()
		return
	windows = gui.get("windows")
	if not Check(windows is Control, "Gui.windows (container das janelas flutuantes) vive"):
		_finish()
		return

	# O número da régua vem do projeto: se alguém mexer no viewport de design, a
	# cerca acompanha — e hoje ele é 1280x720.
	canvas = Vector2(float(ProjectSettings.get_setting("display/window/size/viewport_width")), float(ProjectSettings.get_setting("display/window/size/viewport_height")))
	CheckI(int(canvas.x), 1280, "viewport de design (largura)")
	CheckI(int(canvas.y), 720, "viewport de design (altura)")

	var report : Array = await _measureAll(canvas, false)
	# A régua só vale se ela realmente cobre a tela toda do HUD. Um `load()` que
	# falha ou um painel que sai da lista encolhe a cobertura em silêncio — por isso
	# o piso é check, não comentário.
	Check(measured >= 20, "%d painéis de HUD medidos com layout de verdade (piso 20)" % measured)
	for row in report:
		var entry : Dictionary = row as Dictionary
		var name : String = String(entry["name"])
		var minimum : Vector2 = entry["min"]
		Check(minimum.x <= canvas.x and minimum.y <= canvas.y, "%s: mínimo %dx%d cabe no viewport %dx%d" % [name, int(minimum.x), int(minimum.y), int(canvas.x), int(canvas.y)])
		Check((entry["overX"] as Array).is_empty(), "%s: nada mais largo que a janela sem rolagem horizontal (%s)" % [name, str(entry["overX"])])
		Check((entry["overY"] as Array).is_empty(), "%s: nada mais alto que a janela sem rolagem vertical (%s)" % [name, str(entry["overY"])])
	if not cosmeticX.is_empty():
		print("    [decorativo] %d rótulo/painel fora da caixa no eixo horizontal, sem rolagem: a própria janela apara isso, e nenhum controle interactivo está nesta lista (para esses a regra continua dura):" % cosmeticX.size())
		for note in cosmeticX:
			print("      - " + String(note))
	# `await` obrigatório: a função tem `await process_frame` dentro, e chamada sem
	# esperar ela devolve uma corrotina — o `_finish()` embaixo faria `quit()` antes de
	# qualquer check pós-await rodar, e a cerca passaria sem medir nada.
	await _guildPanelRegression(report)
	# Segunda passada: o mesmo HUD montado dentro de um telefone de verdade.
	await _phonePass()
	# Chrome de toque (R5); o controle negativo R6 roda dentro da passada de telefone.
	await _touchChromePass()
	_finish()

# ------------------------------------------------------------------ medição

# Uma passada sobre todos os painéis. `area` é a moldura contra a qual o painel é
# medido (viewport de design na passada de desktop, 390x844 na de telefone);
# `phone` liga as duas regras de telefone — R3 (a caixa realizada da janela cabe no
# aparelho) e R4 (nada interactivo fica fora da moldura do aparelho sem rolagem).
func _measureAll(area : Vector2, phone : bool) -> Array:
	var report : Array = []
	for entry in _panelCandidates():
		var row : Dictionary = await _measureOne(entry, area, phone)
		if not row.is_empty():
			report.append(row)
	return report

# Um painel, do `load()` ao retângulo medido, montado no container real do `Gui`.
# Devolve {} quando o painel nem instanciou (o check já foi registrado dentro).
func _measureOne(entry : Dictionary, area : Vector2, phone : bool) -> Dictionary:
	var scenePath : String = String(entry["scene"])
	var scriptPath : String = String(entry["script"])
	var panel : Node = null
	if not scenePath.is_empty():
		var packed : PackedScene = load(scenePath)
		if packed != null:
			panel = packed.instantiate()
	else:
		var script : GDScript = load(scriptPath)
		if script != null:
			panel = script.new()
	if not Check(panel is Control, "%s: instanciou como Control" % String(entry["name"])):
		if panel != null and is_instance_valid(panel):
			panel.free()
		return {}
	windows.add_child(panel)
	var control : Control = panel as Control
	# Controle negativo: a janela é inflada em memória ANTES de qualquer medição, e
	# o botão órfão entra num Control simples (um Container reacondicionaria o filho
	# e o transbordamento sumiria da árvore — que é exatamente o tipo de cegueira
	# que este bloco existe para excluir). É isto que prova que R3/R4 vêem um
	# estouro; ver `_phoneNegativeControl`.
	if entry.has("inflate"):
		var fat : Vector2 = entry["inflate"] as Vector2
		control.custom_minimum_size = fat
		control.size = fat
		var pad : Control = Control.new()
		pad.name = "BeyondFramePad"
		pad.custom_minimum_size = fat
		control.add_child(pad)
		var stray : Button = Button.new()
		stray.name = "StrayBeyondPhone"
		stray.size = Vector2(60.0, 40.0)
		stray.position = Vector2(fat.x - 60.0, fat.y - 40.0)
		stray.visible = true
		pad.add_child(stray)
	# Caixa declarada = o mínimo que o painel anuncia (a cena traz o
	# `custom_minimum_size` da janela; o corpo montado em código traz o seu). Sem
	# declaração, o teto é a tela inteira: painel de HUD sem tamanho é janela que
	# cresce até caber. No telefone, "caber" é 390x844 — e é exatamente aí que a
	# segunda passada difere da primeira.
	var declared : Vector2 = control.get_combined_minimum_size()
	if declared.x <= 0.0:
		declared.x = area.x
	if declared.y <= 0.0:
		declared.y = area.y
	control.visible = true
	control.size = declared
	# Duas imagens: a primeira dispara o sort dos containers, a segunda estabiliza
	# tamanho de rótulo/scroll depois do primeiro layout.
	await process_frame
	await process_frame
	var minimum : Vector2 = control.get_combined_minimum_size()
	# A caixa que o jogador vê é a maior das duas: `WindowPanel.UpdateWindow`
	# (sources/gui/WindowPanel.gd:@UpdateWindow) nunca deixa a janela ficar menor que o
	# próprio mínimo, então um painel cujo conteúdo pede mais cresce até lá. Medir
	# o transbordamento contra a caixa DESenhada (menor) acusaria de bug todo painel
	# cujo conteúdo só esticou a janela — e é R1, acima, que pega o caso grave:
	# janela maior que a tela.
	var box : Vector2 = Vector2(maxf(declared.x, minimum.x), maxf(declared.y, minimum.y))
	control.size = box
	await process_frame
	currentName = String(entry["name"])
	var overflow : Dictionary = _walkOverflows(control, control, box, false, false, [], [])
	var row : Dictionary = {
		"name": String(entry["name"]),
		"min": minimum,
		"box": box,
		"declared": declared,
		"overX": overflow["x"],
		"overY": overflow["y"],
	}
	if phone:
		# R4 contra a MOLDURA do aparelho, não contra a janela: um controle a
		# y=1900 dentro de uma janela de 2992 de altura alcançável na janela é
		# inalcançável no telefone. A segunda varrida é isso. O walk não acumula
		# nada por eixo fora das listas que devolve, então só o registro decorativo
		# precisa ser silenciado (ele já foi registrado na varrida de cima).
		var mold : Vector2 = _phoneMoldure(String(entry["name"]), area)
		quietCosmetic = true
		var frame : Dictionary = _walkOverflows(control, control, mold, false, false, [], [])
		quietCosmetic = false
		row["phX"] = frame["x"]
		row["phY"] = frame["y"]
		row["box"] = box
		row["mold"] = mold
		row["windowOutside"] = box.x > mold.x + Epsilon or box.y > mold.y + Epsilon
		print("    [tel] %-24s caixa %4dx%-4d  moldura %4dx%-4d  fora: botoes x=%d, nodes y=%d  estoura=%s" % [
			String(entry["name"]), int(box.x), int(box.y), int(mold.x), int(mold.y),
			(row["phX"] as Array).size(), (row["phY"] as Array).size(), str(row["windowOutside"])])
		phoneMeasured += 1
	else:
		print("    [mede] %-26s caixa %4dx%-4d  min %4dx%-4d  overflow x=%d y=%d" % [
			String(entry["name"]), int(box.x), int(box.y), int(minimum.x), int(minimum.y),
			(overflow["x"] as Array).size(), (overflow["y"] as Array).size()])
		measured += 1
	windows.remove_child(control)
	control.free()
	return row

# Varre a árvore do painel carregando "já estou dentro de uma rolagem neste eixo?".
func _walkOverflows(node : Node, panel : Control, box : Vector2, inScrollX : bool, inScrollY : bool, outX : Array, outY : Array) -> Dictionary:
	var origin : Vector2 = panel.global_position
	for child in node.get_children():
		if not (child is Control):
			continue
		var c : Control = child as Control
		if not c.visible:
			continue
		var scrollX : bool = inScrollX
		var scrollY : bool = inScrollY
		if c is ScrollContainer:
			# 0 == SCROLL_MODE_DISABLED: desligado não dá caminho para nada.
			scrollX = scrollX or int((c as ScrollContainer).horizontal_scroll_mode) != 0
			scrollY = scrollY or int((c as ScrollContainer).vertical_scroll_mode) != 0
		var local : Vector2 = c.global_position - origin
		var right : float = local.x + c.size.x
		var bottom : float = local.y + c.size.y
		# Os dois eixos não significam a mesma coisa. Embaixo da borda NÃO existe
		# escape: o controle nasce fora da janela e sem rolagem ninguém alcança — foi
		# exatamente o Confirm/Cancel e a linha de chat do GuildPanel. Na largura, um
		# rótulo/painel decorativo que passa alguns pixels por causa das margens do
		# tema é aparado pela própria janela (cosmético; fica no log, em
		# `cosmeticX`). O que é bug de verdade — e era o defeito que o juiz nomeou,
		# "botão fora da tela" — é controle COM interactivo fora da caixa sem rolagem
		# horizontal, porque esse o jogador não aperta.
		if bottom > box.y + Epsilon and not scrollY:
			outY.append(_pathOf(c, panel) + " y=%.0f>%.0f" % [bottom, box.y])
		if right > box.x + Epsilon and not scrollX:
			if _IsInteractive(c):
				outX.append(_pathOf(c, panel) + " x=%.0f>%.0f" % [right, box.x])
			elif not quietCosmetic:
				cosmeticX.append(String(currentName) + ": " + _pathOf(c, panel) + " x=%.0f>%.0f" % [right, box.x])
		_walkOverflows(c, panel, box, scrollX, scrollY, outX, outY)
	return {"x": outX, "y": outY}

# Controle que o jogador usa. Um deles fora da caixa sem rolagem no eixo é o bug.
func _IsInteractive(c : Control) -> bool:
	return c is Button or c is LineEdit or c is TextEdit or c is OptionButton \
			or c is CheckBox or c is CheckButton or c is HSlider or c is VSlider \
			or c is ItemList or c is Tree or c is TextureButton or c is ColorPickerButton

func _pathOf(node : Node, panel : Control) -> String:
	var parts : Array[String] = []
	var walk : Node = node
	while walk != null and walk != panel:
		parts.push_front(String(walk.name))
		walk = walk.get_parent()
	return String(panel.name) + "/" + "/".join(parts)

# ------------------------------------------------------------------ candidatos

# Todo script de sources/gui que herda de WindowPanel — direto ou através de outra
# classe do mesmo diretório (ActivitiesWindow, por exemplo). Sem whitelist: painel
# novo entra sozinho. Quando existe a cena do painel, ela é a instância medida, porque
# é a cena que declara a caixa da janela (GuildPanel.tscn: 420x560).
func _panelCandidates() -> Array:
	var dir : DirAccess = DirAccess.open("res://sources/gui")
	if dir == null:
		return []
	var parents : Dictionary = {}
	dir.list_dir_begin()
	var scanName : String = dir.get_next()
	while scanName != "":
		if scanName.ends_with(".gd"):
			parents[scanName] = _extendsLine(_repoFile("res://sources/gui/" + scanName))
		scanName = dir.get_next()
	dir.list_dir_end()
	# Nome de classe -> arquivo que a declara. É o que fecha a cadeia de herança sem
	# que eu precise citar class_name aqui (o harness não resolve class_name).
	var byClass : Dictionary = {}
	for ownName in parents.keys():
		var declared : String = _classNameOf(_repoFile("res://sources/gui/" + String(ownName)))
		if not declared.is_empty():
			byClass[declared] = String(ownName)
	var panelFiles : Dictionary = {}
	for passIdx in 6:
		for stepName in parents.keys():
			var base : String = String(parents[stepName])
			if base == "WindowPanel":
				panelFiles[String(stepName)] = true
			elif byClass.has(base) and panelFiles.has(String(byClass[base])):
				panelFiles[String(stepName)] = true
	# Só painéis de fato entram na medição.
	var byName : Dictionary = {}
	for hitName in parents.keys():
		if panelFiles.has(String(hitName)):
			var stem : String = String(hitName).trim_suffix(".gd")
			byName[stem] = {"name": stem, "script": "res://sources/gui/" + stem + ".gd", "scene": ""}
	var scenes : DirAccess = DirAccess.open("res://presets/gui")
	if scenes != null:
		scenes.list_dir_begin()
		var sceneName : String = scenes.get_next()
		while sceneName != "":
			if sceneName.ends_with(".tscn"):
				var scriptRef : String = _rootGuiScript(_repoFile("res://presets/gui/" + sceneName))
				var base : String = scriptRef.get_file().trim_suffix(".gd")
				if byName.has(base):
					byName[base]["scene"] = "res://presets/gui/" + sceneName
			sceneName = scenes.get_next()
		scenes.list_dir_end()
	var out : Array = []
	for stem in byName.keys():
		out.append(byName[stem])
	out.sort_custom(func(a : Variant, b : Variant) -> bool: return String((a as Dictionary)["name"]) < String((b as Dictionary)["name"]))
	return out

func _extendsLine(scriptText : String) -> String:
	for line in scriptText.split("\n"):
		var trimmed : String = String(line).strip_edges()
		if trimmed.begins_with("extends "):
			return trimmed.substr(len("extends ")).strip_edges()
		if trimmed.begins_with("static func ") or trimmed.begins_with("func "):
			return ""
	return ""

func _classNameOf(scriptText : String) -> String:
	for line in scriptText.split("\n"):
		var trimmed : String = String(line).strip_edges()
		if trimmed.begins_with("class_name "):
			return trimmed.substr(len("class_name ")).strip_edges()
		if trimmed.begins_with("extends "):
			continue
		if trimmed.begins_with("func ") or trimmed.begins_with("static func "):
			return ""
	return ""

# O script do nó RAIZ da cena, quando é um script de sources/gui.
func _rootGuiScript(sceneText : String) -> String:
	var scriptID : String = ""
	var rootStarted : bool = false
	for line in sceneText.split("\n"):
		var raw : String = String(line)
		if raw.begins_with("[node "):
			if raw.contains(" parent="):
				break
			rootStarted = true
		elif rootStarted and raw.begins_with("["):
			break
		elif rootStarted and raw.begins_with("script = ExtResource("):
			# O `id` vem entre aspas no .tscn (`ExtResource("2_socgd")`): sem tirar as
			# aspas a comparação de baixo nunca bate, toda cena cai para o `.new()` de
			# script e a régua passa a medir painel vazio (10x9) achando que mediu a
			# janela — foi exatamente assim que esta cerca ficou cega para a caixa
			# declarada de cada painel.
			scriptID = raw.substr(raw.find("(") + 1).get_slice(")", 0).strip_edges().trim_prefix("\"").trim_suffix("\"")
	if scriptID.is_empty():
		return ""
	for line in sceneText.split("\n"):
		var raw : String = String(line)
		if not raw.begins_with("[ext_resource") or not raw.contains("type=\"Script\""):
			continue
		if not raw.contains("id=\"" + scriptID + "\""):
			continue
		var path : String = raw.substr(raw.find("path=\"") + 6).get_slice("\"", 0)
		return path if path.begins_with("res://sources/gui/") else ""
	return ""

# ------------------------------------------------------------------ o defeito fechado

# A régua geral mede qualquer painel; estas linhas prendem o caso concreto que o juiz
# apontou, para o GuildPanel não voltar a ser a janela com botão invisível nem num
# monitor grande o bastante para esconder o problema.
func _guildPanelRegression(report : Array) -> void:
	var row : Dictionary = {}
	for entry in report:
		if String((entry as Dictionary)["name"]) == "GuildPanel":
			row = entry as Dictionary
	if not Check(not row.is_empty(), "GuildPanel está na lista medida (o painel do defeito continua coberto)"):
		return
	var minimum : Vector2 = row["min"]
	var declared : Vector2 = row["declared"]
	# Sem esta linha a cerca mede um script solto e se diz feliz: é a cena que declara
	# a caixa da janela, e `min` de painel sem corpo montado (10x9) passa em qualquer
	# viewport.
	Check(declared.x >= 420.0 and declared.y >= 560.0, "GuildPanel: medido pela CENA, caixa declarada 420x560 (medido %dx%d)" % [int(declared.x), int(declared.y)])
	Check(minimum.y <= 560.0, "GuildPanel: o mínimo do PAINEL é a janela (560), não o corpo (era 1061) — medido %d; sem o ScrollContainer do corpo isto volta a ~1000" % int(minimum.y))
	Check(minimum.x <= 420, "GuildPanel: o mínimo horizontal cabe na janela de 420 (era 511, medido %d)" % int(minimum.x))
	Check(minimum.y <= canvas.y, "GuildPanel: o mínimo cabe no viewport (%d <= %d)" % [int(minimum.y), int(canvas.y)])

	# Os três controles que nasciam abaixo da borda, conferidos na ÁRVORE montada.
	# Texto de arquivo não prova composição — o que torna um controle alcançável é o
	# ancestral ScrollContainer com rolagem ligada NAQUELE eixo, e isso só se lê na
	# instância.
	var packed : PackedScene = load("res://presets/gui/GuildPanel.tscn")
	if not Check(packed != null, "GuildPanel: a cena do painel carrega"):
		return
	var panel : Control = packed.instantiate() as Control
	windows.add_child(panel)
	panel.visible = true
	panel.size = panel.get_combined_minimum_size()
	await process_frame
	await process_frame
	for widget in ["ChatRow", "ConfirmRow", "Feedback"]:
		var node : Node = panel.find_child(widget, true, false)
		if not Check(node != null, "GuildPanel: '%s' existe na árvore montada" % widget):
			continue
		var scrollY : bool = false
		var scrollX : bool = false
		var walk : Node = node
		while walk != null and walk != panel:
			if walk is ScrollContainer:
				scrollY = scrollY or int((walk as ScrollContainer).vertical_scroll_mode) != 0
				scrollX = scrollX or int((walk as ScrollContainer).horizontal_scroll_mode) != 0
			walk = walk.get_parent()
		Check(scrollY, "GuildPanel: '%s' fica atrás de rolagem VERTICAL (o que não cabe é alcançável, não perdido)" % widget)
		Check(not scrollX, "GuildPanel: '%s' sem atalho horizontal — a linha é obrigada a caber na largura da janela" % widget)
	# O corpo que rola: a altura dele é livre (é para isso que existe rolagem), a
	# largura não — foi uma linha larga que empurrou o botão para fora da tela.
	var bodyNode : Node = panel.find_child("Body", true, false)
	if Check(bodyNode is Control, "GuildPanel: o corpo rolável 'Body' existe"):
		var bodyMin : Vector2 = (bodyNode as Control).get_combined_minimum_size()
		print("    [mede] GuildPanel corpo: %dx%d (janela 420x560)" % [int(bodyMin.x), int(bodyMin.y)])
		Check(bodyMin.x <= 420.0, "GuildPanel: a LARGURA do corpo cabe na janela (%d <= 420); só a altura (%d) pode rolar" % [int(bodyMin.x), int(bodyMin.y)])
	windows.remove_child(panel)
	panel.free()

# ------------------------------------------------------------------ telefone

# Moldura que um painel tem que caber no telefone: 390x844, salvo para o legado
# nomeado em `phoneLegacy`, cuja moldura passa a ser o teto medido hoje. A meta
# continua 390x844 e continua impressa com nome e numero em cada linha da passada —
# mesma politica de `deploy/WEB_SLIM.md` para o peso do pacote: quando o teto real
# esta acima da meta, o numero de hoje e o que barra, e a meta nao some. Encolher e
# livre; crescer, ou nascer janela nova fora da lista, quebra o portao.
func _phoneMoldure(name : String, area : Vector2) -> Vector2:
	if phoneLegacy.has(name):
		var ceiling : Array = phoneLegacy[name] as Array
		return Vector2(maxf(float(ceiling[0]), area.x), maxf(float(ceiling[1]), area.y))
	return area

func _candidateByName(name : String) -> Dictionary:
	for entry in _panelCandidates():
		if String((entry as Dictionary)["name"]) == name:
			return entry as Dictionary
	return {}

# Coloca o motor dentro de um iPhone 12/13/14 em retrato e mede o que a UI faz la.
# Nada aqui e conta de cabecalho: a moldura e lida do container real de janelas
# flutuantes (`Gui.windows`), e o que o stretch entrega hoje e medido ANTES de
# qualquer afirmacao.
func _phonePass() -> void:
	print("== SOM-UX: segunda passada na tela de um telefone (390x844) ==")
	var win : Window = root as Window
	var savedSize : Vector2i = win.size
	var savedWindows : Vector2 = windows.get_size()
	# (1) O que o aparelho recebe com a base do projeto. Com
	# `window/stretch/mode="canvas_items"` + `aspect="expand"` da base `display` em 1280x720
	# (`project.godot:@display`), um telefone de 390x844 CSS px nao ganha um espaco de
	# design de 390x844: a largura fica presa a base e a altura desce. Medido,
	# porque e este numero que diz por que "cabe no viewport de 1280x720" nunca foi
	# evidencia de que cabe no aparelho. Se alguem mexer na base/stretch, o check
	# abaixo muda junto e esta passada tem que ser relida.
	win.size = Vector2i(int(PhoneW), int(PhoneH))
	await process_frame
	await process_frame
	var squeezed : Vector2 = windows.get_size()
	CheckI(int(squeezed.x), int(canvas.x), "telefone fisico 390x844: container de janelas continua com a largura da base do projeto (medido %dx%d de design)" % [int(squeezed.x), int(squeezed.y)])
	cssPerDesignPx = PhoneW / maxf(squeezed.x, 1.0)
	var targetPx : int = int(_guiConst("TouchTarget", TouchFloorPx))
	Check(cssPerDesignPx < 1.0, "telefone fisico: 1 px de design vale %.2f CSS px, entao o alvo de %d px que o produto promete e um alvo de %.1f CSS px no aparelho (piso externo 44)" % [cssPerDesignPx, targetPx, cssPerDesignPx * float(targetPx)])
	print("    [tel] design space do telefone: %dx%d (moldura fisica %dx%d CSS px)" % [int(squeezed.x), int(squeezed.y), int(PhoneW), int(PhoneH)])
	# O outro lado da mesma moeda, impresso em vez de enterrado: os 48 px da chrome
	# existem no espaco de design, entao no aparelho de hoje eles chegam como %.1f CSS
	# px. Fechar isto nao e tarefa desta régua nem deste escopo -- e a base/stretch em
	# `project.godot` (1280x720 + expand) que decide o fator, e o `MobileDefault` de
	# 1,2 nao compensa um fator de 0,30. A régua mede e nomeia; nao finge que passou.
	print("    [aberto] alvo de toque fisico no aparelho: %.1f CSS px (faltam %.0f px de design por causa do fator %.2f; a correcao e de espaco de design, nao de chrome)" % [cssPerDesignPx * float(targetPx), float(targetPx) / cssPerDesignPx - float(targetPx), cssPerDesignPx])
	# (2) A pergunta de 1:1, que e a unica com resposta util para um aparelho: se o
	# telefone for o espaco de design (o que uma UI de toque precisa ser), cada
	# janela do produto cabe? A moldura e imposta no container por codigo, nao por
	# display.
	windows.size = Vector2(PhoneW, PhoneH)
	await process_frame
	phoneFrame = windows.get_size()
	CheckI(int(phoneFrame.x), int(PhoneW), "moldura de telefone imposta no container de janelas (largura)")
	CheckI(int(phoneFrame.y), int(PhoneH), "moldura de telefone imposta no container de janelas (altura)")
	var report : Array = await _measureAll(Vector2(PhoneW, PhoneH), true)
	Check(phoneMeasured >= 20, "%d janelas remontadas e medidas na moldura do telefone (piso 20)" % phoneMeasured)
	var fora : Array = []
	var passaDaMeta : Dictionary = {}
	for row in report:
		var entry : Dictionary = row as Dictionary
		var name : String = String(entry["name"])
		var box : Vector2 = entry["box"] as Vector2
		var mold : Vector2 = entry["mold"] as Vector2
		# R3: a janela, como ela abre (nunca menor que o proprio minimo), cabe no
		# aparelho.
		Check(not bool(entry["windowOutside"]), "%s: janela %dx%d cabe na moldura do telefone %dx%d (meta 390x844)" % [name, int(box.x), int(box.y), int(mold.x), int(mold.y)])
		# R4: o que passa da moldura tem que estar atras de rolagem no eixo, senao o
		# jogador do aparelho nunca alcanca.
		Check((entry["phX"] as Array).is_empty(), "%s: nenhum botao fora da moldura do telefone sem rolagem horizontal (%s)" % [name, str(entry["phX"])])
		Check((entry["phY"] as Array).is_empty(), "%s: nada abaixo da moldura do telefone sem rolagem vertical (%s)" % [name, str(entry["phY"])])
		if box.x > PhoneW + Epsilon or box.y > PhoneH + Epsilon:
			passaDaMeta[name] = true
			fora.append("%s: caixa %dx%d contra a meta 390x844 (teto aplicado %dx%d) — botoes fora do teto em x=%d, nodes fora em y=%d" % [name, int(box.x), int(box.y), int(mold.x), int(mold.y), (entry["phX"] as Array).size(), (entry["phY"] as Array).size()])
	if not fora.is_empty():
		print("    [legado] %d janelas passam da meta 390x844 no telefone hoje. A meta nao some: cada uma esta nomeada em `phoneLegacy` com o teto medido (+10 px), o portao barra quem crescer acima do teto, e a linha acima continua dizendo 390x844:" % fora.size())
		for note in fora:
			print("      - " + String(note))
	# O teto so existe para quem passa da meta. Painel que encolheu ate caber tem que
	# sair da lista — senão o ratchet vira licença permanente e a régua deixa de
	# enxergar a janela que voltou a caber no aparelho.
	var sobra : Array = []
	for chave in phoneLegacy.keys():
		if not passaDaMeta.has(String(chave)):
			sobra.append(String(chave))
	Check(sobra.is_empty(), "%d tetos nomeados para %d janelas que hoje passam da meta 390x844 (teto sem estouro e lista vencida: %s)" % [phoneLegacy.size(), passaDaMeta.size(), str(sobra)])
	await _phoneNegativeControl(report)
	# Devolve o motor ao estado de antes: a regressao do GuildPanel e a chrome de
	# toque medem no desktop, e o HUD vivo nao pode sair da passada espremido.
	windows.size = savedWindows
	win.size = savedSize
	await process_frame
	await process_frame

# O controle negativo: uma janela inflada em memoria tem que ser pega por R3 e por
# R4, e o mesmo painel sem inflacao tem que passar limpo. Sem os dois lados, verde
# quer dizer apenas "a regua nunca viu um transbordamento".
func _phoneNegativeControl(report : Array) -> void:
	var fat : Vector2 = Vector2(1200.0, 1400.0)
	var refName : String = ""
	# Prefere um painel que caiba de verdade em 390x844 (nao apenas dentro do teto
	# nomeado dele): e contra a moldura do aparelho, nao contra a excecao, que a
	# régua tem que dizer "passa limpo".
	for row in report:
		var entry : Dictionary = row as Dictionary
		var box : Vector2 = entry["box"] as Vector2
		if bool(entry["windowOutside"]) or not (entry["phX"] as Array).is_empty() or not (entry["phY"] as Array).is_empty():
			continue
		refName = String(entry["name"])
		if box.x <= PhoneW + Epsilon and box.y <= PhoneH + Epsilon:
			break
	if not Check(not refName.is_empty(), "controle negativo: existe painel que cabe em 390x844 (a regua nao so sabe acusar, ela deixa passar o que cabe)"):
		return
	var base : Dictionary = _candidateByName(refName)
	if not Check(not base.is_empty(), "controle negativo: '%s' esta na lista descoberta de paineis" % refName):
		return
	var clean : Dictionary = await _measureOne(base, Vector2(PhoneW, PhoneH), true)
	if clean.is_empty():
		Check(false, "controle negativo: '%s' remontou para a medicao limpa" % refName)
		return
	Check(not bool(clean["windowOutside"]) and (clean["phX"] as Array).is_empty() and (clean["phY"] as Array).is_empty(), "controle negativo: '%s' sem inflacao passa limpo na moldura do telefone (caixa %dx%d)" % [refName, int((clean["box"] as Vector2).x), int((clean["box"] as Vector2).y)])
	var inflatedEntry : Dictionary = base.duplicate(true)
	inflatedEntry["inflate"] = fat
	var bad : Dictionary = await _measureOne(inflatedEntry, Vector2(PhoneW, PhoneH), true)
	if bad.is_empty():
		Check(false, "controle negativo: a janela inflada remontou")
		return
	var box : Vector2 = bad["box"] as Vector2
	Check(bool(bad["windowOutside"]), "controle negativo: R3 PEGA a janela inflada (%dx%d estoura a moldura %dx%d)" % [int(box.x), int(box.y), int(PhoneW), int(PhoneH)])
	Check(not (bad["phX"] as Array).is_empty(), "controle negativo: R4 PEGA o botao nascido fora da moldura do telefone sem rolagem (%s)" % str(bad["phX"]))

# ------------------------------------------------------------------ chrome de toque

# O alvo que o dedo alcanca nas alcades resize e no fechar da janela. Os dois lados
# sao medidos: no toque, as 8 direcoes pegam a alca a 44 px da borda; com a chrome de
# mouse, a mesma sonda a 44 px nao pega nada. Sem o segundo lado, "48" seria um
# numero decorativo e a regua nao veria diferenca nenhuma.
func _touchChromePass() -> void:
	print("== SOM-UX: alvo de toque da chrome de janela (resize + fechar) ==")
	var panelScript : GDScript = load("res://sources/gui/WindowPanel.gd")
	if not Check(panelScript != null, "WindowPanel carrega"):
		return
	var guiConsts : Dictionary = _guiConstants()
	var panelConsts : Dictionary = panelScript.get_script_constant_map()
	var target : int = int(guiConsts.get("TouchTarget", 0))
	var floor : int = int(guiConsts.get("TouchTargetFloor", 0))
	Check(target >= floor and floor >= TouchFloorPx, "alvo de toque do produto = %d px sobre um piso externo = %d px: o produto promete acima do chao, e %d e o numero que vale" % [target, floor, target])
	var mouseEdge : int = int(panelConsts.get("edgeSize", -1))
	var mouseCorner : int = int(panelConsts.get("cornerSize", -1))
	Check(mouseEdge < TouchFloorPx and mouseCorner < TouchFloorPx, "chrome de mouse continua em %d/%d px (valor de cursor, nao de dedo) - era o que a janela herdava no toque" % [mouseEdge, mouseCorner])
	var enumMap : Dictionary = panelConsts.get("EdgeOrientation", {}) as Dictionary
	var packed : PackedScene = load("res://presets/gui/GuildPanel.tscn")
	if not Check(packed != null and not enumMap.is_empty(), "GuildPanel.tscn (janela real, com barra de título) carrega e o enum de direcoes e legivel"):
		return
	var panel : Control = packed.instantiate() as Control
	windows.add_child(panel)
	panel.visible = true
	panel.size = Vector2(420.0, 560.0)
	await process_frame
	await process_frame
	var hide : Node = panel.find_child("HideButton", true, false)
	var pick : Node = panel.find_child("TouchButton", true, false)
	Check(hide is Button, "fechar da barra de titulo existe na arvore montada (chrome de janela medido: nao so o resize)")
	var baseMin : Vector2 = Vector2.ZERO
	var baseRadius : float = -1.0
	if hide is Button:
		baseMin = (hide as Button).custom_minimum_size
	if pick is TouchScreenButton and (pick as TouchScreenButton).shape is CircleShape2D:
		baseRadius = ((pick as TouchScreenButton).shape as CircleShape2D).radius
	print("    [toque] base de cena do fechar: botao %dx%d, circulo de toque %.0f px de diametro" % [int(baseMin.x), int(baseMin.y), baseRadius * 2.0])
	_guiScript().call("ApplyWindowTouchChrome", panel, true)
	# Uma imagem para o container reacondicionar o fechar com o minimo novo: o que o
	# dedo alcanca e o retangulo realizado, nao o numero declarado.
	await process_frame
	CheckI(int(panel.call("ChromePixels")), target, "chrome de resize da janela no toque (px)")
	var probes : Array = [
		["LEFT", Vector2(44.0, 300.0), 44.0],
		["RIGHT", Vector2(420.0 - 44.0, 300.0), 44.0],
		["TOP", Vector2(210.0, 44.0), 44.0],
		["BOTTOM", Vector2(210.0, 560.0 - 44.0), 44.0],
		["TOP_LEFT", Vector2(44.0, 44.0), 44.0],
		["TOP_RIGHT", Vector2(420.0 - 44.0, 44.0), 44.0],
		["BOTTOM_LEFT", Vector2(44.0, 560.0 - 44.0), 44.0],
		["BOTTOM_RIGHT", Vector2(420.0 - 44.0, 560.0 - 44.0), 44.0],
	]
	for probe in probes:
		var label : String = String(probe[0])
		var pos : Vector2 = probe[1] as Vector2
		var want : int = int(enumMap.get(label, -1))
		CheckI(int(panel.call("GetEdgeOrientation", pos)), want, "toque a %.0f px da borda %s pega a alca de resize" % [float(probe[2]), label])
	if hide is Button:
		var minSize : Vector2 = (hide as Button).custom_minimum_size
		Check(minSize.x >= float(TouchFloorPx) and minSize.y >= float(TouchFloorPx), "fechar da barra de titulo no toque: minimo %dx%d >= %d px" % [int(minSize.x), int(minSize.y), TouchFloorPx])
		var real : Vector2 = (hide as Button).size
		Check(real.x >= float(TouchFloorPx) and real.y >= float(TouchFloorPx), "fechar da barra de titulo no toque: retangulo realizado %dx%d >= %d px (e o retangulo que o dedo alcanca, nao o numero declarado)" % [int(real.x), int(real.y), TouchFloorPx])
	if pick is TouchScreenButton and (pick as TouchScreenButton).shape is CircleShape2D:
		var diameter : float = ((pick as TouchScreenButton).shape as CircleShape2D).radius * 2.0
		Check(diameter >= float(TouchFloorPx), "circulo de toque do fechar: %.0f px de diametro >= %d px" % [diameter, TouchFloorPx])
	# Todo painel vivo no boot entra pela mesma porta do produto (o modulo, nao a
	# maquete da janela acima).
	_guiScript().call("ApplyTouchChrome", gui, true)
	var vivos : int = 0
	var miudos : Array = []
	for child in windows.get_children():
		# `child is WindowPanel` nao compila aqui: o main-loop de `-s` e montado antes
		# de qualquer class_name do projeto existir. `ChromePixels` so existe na chrome
		# de janela, entao o metodo e o discriminante honesto.
		if not (child is Control) or not (child as Control).has_method("ChromePixels"):
			continue
		vivos += 1
		if int((child as Control).call("ChromePixels")) < TouchFloorPx:
			miudos.append("%s=%d" % [String((child as Control).name), int((child as Control).call("ChromePixels"))])
	Check(miudos.is_empty(), "%d janelas vivas no boot: todas com chrome de toque >= %d px (%s)" % [vivos, TouchFloorPx, str(miudos)])
	# Volta para a chrome de mouse e a sonda de 44 px tem que deixar de pegar: prova
	# de que foi a regra de toque que mudou o comportamento, e nao o acaso.
	_guiScript().call("ApplyWindowTouchChrome", panel, false)
	CheckI(int(panel.call("ChromePixels")), mouseEdge, "chrome de resize volta para o valor de cursor (%d px)" % mouseEdge)
	for probe in probes:
		CheckI(int(panel.call("GetEdgeOrientation", probe[1] as Vector2)), int(enumMap.get("NONE", -1)), "chrome de mouse: sonda a 44 px de %s nao pega alca nenhuma" % String(probe[0]))
	CheckI(int(panel.call("GetEdgeOrientation", Vector2(3.0, 300.0))), int(enumMap.get("LEFT", -1)), "chrome de mouse continua funcionando na profundia dela (3 px da borda esquerda)")
	if hide is Button:
		Check((hide as Button).custom_minimum_size == baseMin, "fechar volta ao minimo declarado em cena quando o toque nao e o dispositivo (%s)" % str(baseMin))
	if pick is TouchScreenButton and baseRadius > 0.0:
		Check(is_equal_approx(((pick as TouchScreenButton).shape as CircleShape2D).radius, baseRadius), "circulo de toque volta ao raio de cena (%.0f px) - idempotente nos dois sentidos" % baseRadius)
	windows.remove_child(panel)
	panel.free()

func _guiScript() -> GDScript:
	return load("res://sources/gui/GuiUiScale.gd") as GDScript

func _guiConstants() -> Dictionary:
	var script : GDScript = _guiScript()
	return {} if script == null else script.get_script_constant_map()

func _guiConst(key : String, fallback : int) -> int:
	var consts : Dictionary = _guiConstants()
	return int(consts.get(key, fallback))

# ------------------------------------------------------------------ limpeza

func _finish() -> void:
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
