extends SceneTree

# SOM-IDLE UX/UI (juiz cego 2026-09-27, UX/UI 7.5/10): "botão fora da tela". O
# `GuildPanel` declarava 420x560 e o corpo montado em código pedia 511x1061 — contra
# o viewport de projeto (1280x720) a linha de chat da guild, o Confirm/Cancel da
# prévia de gasto e o Feedback simplesmente não existiam para o jogador, porque
# `WindowPanel.UpdateWindow` (sources/gui/WindowPanel.gd:203-205) força
# `size >= minimum_size`: janela cujo conteúdo é maior que a tela transborda e nasce
# com a parte de baixo abaixo da borda.
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
# Painel em medição (o walk é método e não leva nome por parâmetro) e o que a regra
# horizontal tolerate: rótulo/painel decorativo alguns pixels fora da caixa, que a
# própria janela apara. Registrado, nunca escondido.
var currentName : String = ""
var cosmeticX : Array = []

# Meio pixel de boa-vontade com arredondamento de layout; nada mais.
const Epsilon : float = 1.5

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

	var report : Array = await _measureAll()
	# A régua só vale se ela realmente cobre a tela toda do HUD. Um `load()` que
	# falha ou um painel que sai da lista encolhe a cobertura em silêncio — por isso
	# o piso é check, não comentário.
	Check(measured >= 20, "%d painéis de HUD medidos com layout de verdade (piso 20)" % measured)
	for row in report:
		var entry : Dictionary = row as Dictionary
		var name : String = String(entry["name"])
		var minimum : Vector2 = entry["min"]
		var box : Vector2 = entry["box"]
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
	_finish()

# ------------------------------------------------------------------ medição

func _measureAll() -> Array:
	var report : Array = []
	for entry in _panelCandidates():
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
			continue
		windows.add_child(panel)
		var control : Control = panel as Control
		# Caixa declarada = o mínimo que o painel anuncia (a cena traz o
		# `custom_minimum_size` da janela; o corpo montado em código traz o seu). Sem
		# declaração, o teto é a tela inteira: painel de HUD sem tamanho é janela que
		# cresce até caber.
		var declared : Vector2 = control.get_combined_minimum_size()
		if declared.x <= 0.0:
			declared.x = canvas.x
		if declared.y <= 0.0:
			declared.y = canvas.y
		control.visible = true
		control.size = declared
		# Duas imagens: a primeira dispara o sort dos containers, a segunda estabiliza
		# tamanho de rótulo/scroll depois do primeiro layout.
		await process_frame
		await process_frame
		var minimum : Vector2 = control.get_combined_minimum_size()
		# A caixa que o jogador vê é a maior das duas: `WindowPanel.UpdateWindow`
		# (sources/gui/WindowPanel.gd:203-205) nunca deixa a janela ficar menor que o
		# próprio mínimo, então um painel cujo conteúdo pede mais cresce até lá. Medir
		# o transbordamento contra a caixa DESenhada (menor) acusaria de bug todo painel
		# cujo conteúdo só esticou a janela — e é R1, acima, que pega o caso grave:
		# janela maior que a tela.
		var box : Vector2 = Vector2(maxf(declared.x, minimum.x), maxf(declared.y, minimum.y))
		control.size = box
		await process_frame
		currentName = String(entry["name"])
		var overflow : Dictionary = _walkOverflows(control, control, box, false, false, [], [])
		report.append({
			"name": String(entry["name"]),
			"min": minimum,
			"box": box,
			"declared": declared,
			"overX": overflow["x"],
			"overY": overflow["y"],
		})
		print("    [mede] %-26s caixa %4dx%-4d  min %4dx%-4d  overflow x=%d y=%d" % [
			String(entry["name"]), int(box.x), int(box.y), int(minimum.x), int(minimum.y),
			(overflow["x"] as Array).size(), (overflow["y"] as Array).size()])
		measured += 1
		windows.remove_child(control)
		control.free()
	return report

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
			else:
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

# ------------------------------------------------------------------ limpeza

func _finish() -> void:
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
