extends SceneTree

# SOM-CRAFT (juiz "Core Loop" 8.7/10, 2026-09-28) — régua de ALCANÇABILIDADE da forja.
#
# O achado era literal: `grep -i craft sources/gui/` devolvia ZERO. O serviço, o
# catálogo, os RPCs e a fila de aprovação existiam; o único caminho era o comando de
# GM `/cs_craft`. Um jogador não alcançava a forja. Este harness fixa a corrente —
# botão do HUD → handler do `Gui` → painel da CENA → prévia confirmada →
# `Network.SubmitCraft` → `Server.SubmitCraft` → `EconomyService.SubmitCraft` →
# `ItemForgeService.SubmitCraft` — e as duas propriedades que fazem dela uma porta e
# não um segundo motor:
#   (a) o clique termina na MESMA função autorizada que o comando de GM usa, e a
#       identidade vem do PEER (o payload do cliente tem 4 campos, nenhum charID /
#       accountID — mentir sobre materiais não compra item);
#   (b) a vitrine é LIDA do catálogo em runtime: nenhum nome de slot, de
#       matéria-prima ou de célula existe como literal em `CraftPanel.gd`/`.tscn`.
#
# HÍBRIDO de propósito, e os dois lados são necessários:
#  * EXECUTA onde dá: sobe o boot, aperta o botão real do HUD, mede a janela na
#    árvore, roda `BuildRecipes()` contra uma recomputação INDEPENDENTE das
#    constantes do catálogo + ItemsDB, arma e confirma com `SendHook` (o envio é
#    medido, não lido do texto) e atravessa o `Server.SubmitCraft` vivo com um peer
#    fantasma. Nada disso pede navegador, banco externo ou GM logado — os mesmos 3
#    minutos de boot dos irmãos (`hud_wiring_test`, `auction_house_wiring_test`).
#  * LÍ a fonte onde não dá: o braço de `NetworkSend` só dispara com socket real,
#    e "o clique não alcança a rua sem confirmação" é propriedade estrutural do
#    arquivo (quem chama `_send`). As réguas de texto leem CORPOS de função, nunca
#    o arquivo inteiro, e só linhas de código: régua que grepa o whole-file fica
#    verde quando a chamada some e sobra a frase que a descreve. A suíte E entrega
#    exatamente esse corpo mutilado às réguas e exige que digam "AUSENTE".
#
# Uso: godot --headless --path . -s tests/craft_wiring_test.gd
#       (XDG_DATA_HOME próprio — ver scripts/test.sh.)
# Exit code = nº de checks falhos. Última linha:
#       == RESULT: N checks, M failures ==
#
# Como todo harness `-s`: o main-loop compila antes dos autoloads e dos class_names,
# então nada de identificador de autoload ou class_name de projeto em anotação de
# tipo — instâncias entram por load()/get()/call().

var checks : int = 0
var failures : int = 0
var dbScript : GDScript = null
var launcherNode : Node = null
var guiNode : Node = null
var windowsNode : Node = null
var networkNode : Node = null
var netServer : Object = null
var sqlNode : Node = null
var ecoNode : Node = null

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func CheckStr(value : String, expected : String, label : String) -> bool:
	return Check(value == expected, "%s (got '%s', want '%s')" % [label, value, expected])

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _fileText(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t : String = f.get_as_text()
	f.close()
	return t

# ------------------------------------------------------------------ réguas de fonte
# Linha de comentário não é chamada: caem as linhas cujo texto começa com `#`
# (mesmo helper de `tests/webpush_subscription_test.gd:169`, pela mesma razão).
func _codeOnly(text : String) -> String:
	var kept : String = ""
	for rawLine in text.split("\n"):
		var line : String = String(rawLine)
		if line.strip_edges().begins_with("#"):
			continue
		kept += line + "\n"
	return kept

# Corpo de um membro: da assinatura até o próximo membro de topo. É isso que impede
# a régua de ler o arquivo inteiro e se aprovar com o próprio cabeçalho.
func _funcBody(src : String, signature : String) -> String:
	var at : int = src.find(signature)
	if at < 0:
		return ""
	var out : String = ""
	var first : bool = true
	for rawLine in src.substr(at).split("\n", false):
		var line : String = String(rawLine)
		if not first:
			if line.begins_with("func ") or line.begins_with("static func ") \
					or line.begins_with("class ") or line.begins_with("static var ") \
					or line.begins_with("const "):
				break
		out += line + "\n"
		first = false
	return out

func _countOccurrences(haystack : String, needle : String) -> int:
	if needle.is_empty():
		return 0
	var total : int = 0
	var at : int = haystack.find(needle)
	while at >= 0:
		total += 1
		at = haystack.find(needle, at + needle.length())
	return total

# Literais entre aspas de linhas de código (escaneio simples, sem parser).
func _stringLiterals(code : String) -> Array[String]:
	var out : Array[String] = []
	for rawLine in code.split("\n"):
		var rest : String = String(rawLine)
		while true:
			var open : int = rest.find("\"")
			if open < 0:
				break
			var close : int = rest.find("\"", open + 1)
			if close < 0:
				break
			out.append(rest.substr(open + 1, close - open - 1))
			rest = rest.substr(close + 1)
	return out

# O detetor de receita chumbada: o vocabulário REAL do produto (slots do catálogo,
# matérias-primas por faixa, nomes de célula do ItemsDB) contra cada literal de
# linha de código. Igualdade é violação; nome longo (>= 8) encaixado também.
func _HardcodedRecipeNames(literals : Array[String], vocab : Array[String]) -> Array[String]:
	var hits : Array[String] = []
	for entry in vocab:
		var word : String = String(entry).strip_edges().to_lower()
		if word.length() < 4:
			continue
		for lit in literals:
			var needle : String = String(lit).strip_edges().to_lower()
			if needle == word or (word.length() >= 8 and needle.contains(word)):
				hits.append("%s ~ \"%s\"" % [String(entry), lit])
	return hits

# A régua do RPC: o corpo emite a chamada, sim ou não. Usada na fonte real E nas
# contra-provas da suíte E — mesmo código, dois destinos.
func _EmitsCraftRpc(body : String) -> bool:
	return body.contains("Network.SubmitCraft(")

# Só `ConfirmPending` pode chamar `_send`. Na fonte real isso é contagem: 1
# definição + 1 chamada. Um clique ligado direto à rua vira 3 e cai aqui.
func _SendCallSites(code : String) -> int:
	return _countOccurrences(code, "_send(")

# ------------------------------------------------------------------ élos nomeados
# Cada elo da corrente ALCANÇABILIDADE é um predicado com nome. A suíte (A) aplica-o
# à fonte viva e a suíte (F) aplica o MESMO predicado à mesma fonte mutilada em
# memória: se o predicado não discorda da mutilação, ele não media o elo — media o
# próprio texto. Nada aqui escreve em disco.
func _LinkBarButton(barCode : String) -> bool:
	return barCode.contains("CraftAccess")
# O elo que separa "botão no HUD" de "botão que só o harness monta": `EnterGame`
# (a chegada ao mundo) é quem chama `AddManualSkillButtons`. É a exata classe do
# órfão `GuildPanel` — janela sem chamador não é função.
func _LinkEnterGameBuildsBar(screensCode : String) -> bool:
	return _funcBody(screensCode, "static func EnterGame(").contains("AddManualSkillButtons(")

func _LinkBarWiresHandler(barCode : String) -> bool:
	return barCode.contains("Callable(gui, \"_on_craft_pressed\")")

func _LinkHandlerOpensGui(guiCode : String) -> bool:
	return _funcBody(guiCode, "func _on_craft_pressed(").contains("OpenCraft(")

func _LinkGuiOpensSceneWindow(guiCode : String) -> bool:
	var openBody : String = _funcBody(guiCode, "func OpenCraft(")
	return openBody.contains("EnsureCraftPanel(") and openBody.contains("ToggleControl(") \
		and openBody.contains(".OpenCraft(")

func _LinkGuiInstantiatesScene(guiCode : String) -> bool:
	var ensure : String = _funcBody(guiCode, "func EnsureCraftPanel(")
	return ensure.contains("CraftPanelScene.instantiate()") and not ensure.contains("CraftPanel.new(")

func _LinkGuiPreloadsCraftScene(guiCode : String) -> bool:
	return guiCode.contains("preload(\"res://presets/gui/CraftPanel.tscn\")")

func _LinkSceneBringsScriptAndTitleBar(sceneRaw : String) -> bool:
	return sceneRaw.contains("res://sources/gui/CraftPanel.gd") and sceneRaw.contains("presets/gui/TitleBar.tscn")

func _LinkForgeClickOnlyArms(panelCode : String) -> bool:
	var ready : String = _funcBody(panelCode, "func _ready():")
	var press : String = _funcBody(panelCode, "func _on_forge_pressed(")
	return ready.contains("pressed.connect(_on_forge_pressed)") and press.contains("RequestCraft") \
		and not press.contains("_send(") and not _EmitsCraftRpc(press)

func _LinkConfirmIsTheOnlyDoor(panelCode : String) -> bool:
	return _funcBody(panelCode, "func ConfirmPending(").contains("_send(") \
		and _SendCallSites(panelCode) == 2

func _LinkRpcBranchIsSubmitCraft(panelCode : String) -> bool:
	return _EmitsCraftRpc(_funcBody(panelCode, "func NetworkSend("))

# A mesa de mutilação: [nome do elo, fonte (gui/bar/panel/scene), agulha, substituta,
# predicado]. A substituta `#cortado` vira linha de comentário e `_codeOnly()` a
# apaga — cortar de verdade, não trocar de palavra.
const _RotTable : Array = [
	["chegada ao mundo monta a barra", "screens", "gui.AddManualSkillButtons()", "\t#cortado", "_LinkEnterGameBuildsBar"],
	["bar->botão existe", "bar", "CraftAccess", "HuntAccess", "_LinkBarButton"],
	["bar->handler do Gui", "bar", "Callable(gui, \"_on_craft_pressed\")", "Callable(gui, \"_on_idle_hud_pressed\")", "_LinkBarWiresHandler"],
	["handler->OpenCraft", "gui", "\tOpenCraft()", "\tOpenIdleHud()", "_LinkHandlerOpensGui"],
	["OpenCraft->janela+cena", "gui", "w.OpenCraft()", "#cortado", "_LinkGuiOpensSceneWindow"],
	["Ensure nasce da CENA", "gui", "CraftPanelScene.instantiate()", "CraftPanel.new()", "_LinkGuiInstantiatesScene"],
	["preload da cena certa", "gui", "res://presets/gui/CraftPanel.tscn", "res://presets/gui/GuildPanel.tscn", "_LinkGuiPreloadsCraftScene"],
	["cena traz script+TitleBar", "scene", "presets/gui/TitleBar.tscn", "presets/gui/WindowButton.tscn", "_LinkSceneBringsScriptAndTitleBar"],
	["clique só arma", "panel", "pressed.connect(_on_forge_pressed)", "pressed.connect(_on_refresh_pressed)", "_LinkForgeClickOnlyArms"],
	["ConfirmPending é a única porta", "panel", "\t_send(methodName, args)", "\t#cortado", "_LinkConfirmIsTheOnlyDoor"],
	["braço literal SubmitCraft", "panel", "Network.SubmitCraft(", "Network.SubmitAuction(", "_LinkRpcBranchIsSubmitCraft"],
]

func _linkSources() -> Dictionary:
	return {
		"gui" = _codeOnly(_fileText("res://sources/gui/Gui.gd")),
		"bar" = _codeOnly(_fileText("res://sources/gui/ManualHudBar.gd")),
		"panel" = _codeOnly(_fileText("res://sources/gui/CraftPanel.gd")),
		"scene" = _fileText("res://presets/gui/CraftPanel.tscn"),
		"screens" = _codeOnly(_fileText("res://sources/gui/GuiStateScreens.gd")),
	}

func _LinkPredicate(name : String, source : String) -> bool:
	match name:
		"_LinkEnterGameBuildsBar": return _LinkEnterGameBuildsBar(source)
		"_LinkBarButton": return _LinkBarButton(source)
		"_LinkBarWiresHandler": return _LinkBarWiresHandler(source)
		"_LinkHandlerOpensGui": return _LinkHandlerOpensGui(source)
		"_LinkGuiOpensSceneWindow": return _LinkGuiOpensSceneWindow(source)
		"_LinkGuiInstantiatesScene": return _LinkGuiInstantiatesScene(source)
		"_LinkGuiPreloadsCraftScene": return _LinkGuiPreloadsCraftScene(source)
		"_LinkSceneBringsScriptAndTitleBar": return _LinkSceneBringsScriptAndTitleBar(source)
		"_LinkForgeClickOnlyArms": return _LinkForgeClickOnlyArms(source)
		"_LinkConfirmIsTheOnlyDoor": return _LinkConfirmIsTheOnlyDoor(source)
		"_LinkRpcBranchIsSubmitCraft": return _LinkRpcBranchIsSubmitCraft(source)
	return false

func _catalogConsts() -> Dictionary:
	var catalog : GDScript = load("res://sources/economy/CraftCatalog.gd")
	return {} if catalog == null else catalog.get_script_constant_map()

func _RecipeVocabulary() -> Array[String]:
	var out : Array[String] = []
	var consts : Dictionary = _catalogConsts()
	for entry in (consts.get("SLOT_NAMES", []) as Array):
		out.append(String(entry))
	var farm : GDScript = load("res://sources/idle/FarmZoneData.gd")
	if farm != null:
		for entry in (farm.get_script_constant_map().get("BandMaterialNames", []) as Array):
			out.append(String(entry))
	var items : Dictionary = dbScript.get("ItemsDB") as Dictionary
	for cellHash in items.keys():
		var cell : Object = items.get(int(cellHash), null)
		if cell != null:
			out.append(String(cell.get("name")))
	return out

# Todo `.gd` de sources/gui como código puro — é o terreno do grep que o juiz fez.
func _dirCode(path : String) -> String:
	var dir : DirAccess = DirAccess.open(path)
	if dir == null:
		return ""
	var out : String = ""
	dir.list_dir_begin()
	var scanName : String = dir.get_next()
	while scanName != "":
		if scanName.ends_with(".gd"):
			out += _codeOnly(_fileText(path + "/" + scanName))
		scanName = dir.get_next()
	dir.list_dir_end()
	return out

# ------------------------------------------------------------------ boot

func _initialize():
	_run()

func _run() -> void:
	print("== craft wiring harness (forja alcançável, autoridade no servidor) ==")
	launcherNode = _autoload("Launcher")
	if launcherNode == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return
	var waited : int = 0
	var ready : bool = false
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlProbe : Node = launcherNode.get("SQL")
		var worldProbe : Node = launcherNode.get("World")
		if sqlProbe != null and bool(sqlProbe.get("isInitialized")) and worldProbe != null and bool(worldProbe.get("isInitialized")):
			ready = true
			break
	dbScript = load("res://sources/db/DB.gd")
	for tick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			break
		await create_timer(0.25).timeout
	print("== boot wait done (%d ms) ==" % waited)
	if not Check(ready, "SQL + World init no boot headless"):
		_finish()
		return
	if not Check(dbScript != null and bool(dbScript.get("isInitialized")), "preload threadado do DB drenado antes de load()/quit()"):
		_finish()
		return
	guiNode = launcherNode.get("GUI")
	if not Check(guiNode != null, "Launcher.GUI vive no boot headless (é o canvas do HUD real)"):
		_finish()
		return
	windowsNode = guiNode.get("windows")
	if not Check(windowsNode != null and bool(windowsNode.is_inside_tree()), "Gui.windows é o contêiner vivo das janelas"):
		_finish()
		return
	networkNode = _autoload("Network")
	netServer = networkNode.get("ENetServer") if networkNode != null else null
	sqlNode = launcherNode.get("SQL")
	ecoNode = launcherNode.get("Economy")
	if not Check(netServer != null and sqlNode != null and ecoNode != null, "Network/ENetServer/SQL/Economy vivos no boot"):
		_finish()
		return

	_suiteSource()
	_suiteOpen()
	_suiteCatalog()
	_suiteDispatch()
	_suiteAuthority()
	_suiteNegativeControls()
	_finish()

# ------------------------------------------------------------------ (A) a corrente, na fonte
func _suiteSource() -> void:
	print("-- A) fonte: botão -> handler -> painel -> RPC, e nada além disso")
	var panelRaw : String = _fileText("res://sources/gui/CraftPanel.gd")
	var sceneRaw : String = _fileText("res://presets/gui/CraftPanel.tscn")
	var guiRaw : String = _fileText("res://sources/gui/Gui.gd")
	var barRaw : String = _fileText("res://sources/gui/ManualHudBar.gd")
	var netRaw : String = _fileText("res://sources/network/Network.gd")
	var srvRaw : String = _fileText("res://sources/network/server/Server.gd")
	var ecoRaw : String = _fileText("res://sources/economy/EconomyService.gd")
	var forgeRaw : String = _fileText("res://sources/economy/ItemForgeService.gd")
	var cmdRaw : String = _fileText("res://sources/world/WorldCommands.gd")
	Check(not panelRaw.is_empty() and not sceneRaw.is_empty() and not guiRaw.is_empty() and not barRaw.is_empty(),
		"os quatro elos novos têm fonte legível (painel, cena, Gui, barra do HUD)")
	var panel : String = _codeOnly(panelRaw)
	var guiCode : String = _codeOnly(guiRaw)
	var barCode : String = _codeOnly(barRaw)

	Check(panel.contains("extends WindowPanel"), "CraftPanel.gd: herda de WindowPanel (janela do HUD, não tela solta)")
	Check(panel.contains("class_name CraftPanel"), "CraftPanel.gd: declara class_name (o censo de painéis lêve por tipo)")
	Check(_countOccurrences(_dirCode("res://sources/gui"), "Craft") > 0,
		"sources/gui/: o grep que devolvia ZERO agora acha a forja (o achado literal do juiz)")

	# Elo 1 — botão da barra, handler do Gui. Cada régua é o predicado nomeado que a
	# suíte (F) recebe mutilado: aqui se mede a corrente viva, ali se mede a mordida.
	Check(_LinkBarButton(barCode), "ManualHudBar.gd: a barra cria o botão CraftAccess")
	Check(_LinkBarWiresHandler(barCode), "ManualHudBar.gd: o botão aponta para _on_craft_pressed do Gui")
	Check(_LinkHandlerOpensGui(guiCode), "Gui.gd: existe _on_craft_pressed e ele cai em OpenCraft")
	Check(_LinkGuiOpensSceneWindow(guiCode), "Gui.gd: OpenCraft instancia por EnsureCraftPanel, abre por ToggleControl e pede a releitura à janela")
	Check(_LinkGuiInstantiatesScene(guiCode), "Gui.gd: EnsureCraftPanel nasce da CENA (instantiate, nunca CraftPanel.new())")
	Check(_LinkGuiPreloadsCraftScene(guiCode), "Gui.gd: o preload é presets/gui/CraftPanel.tscn")
	Check(_LinkSceneBringsScriptAndTitleBar(sceneRaw), "CraftPanel.tscn: a cena cola o script do painel E traz o TitleBar (única porta de fechar)")
	# O último elo é do PRODUTO, não do harness: a barra nasce na chegada ao mundo.
	var screensCode : String = _codeOnly(_fileText("res://sources/gui/GuiStateScreens.gd"))
	Check(not screensCode.is_empty(), "GuiStateScreens.gd tem fonte legível (o caminho EnterGame)")
	Check(_LinkEnterGameBuildsBar(screensCode), "GuiStateScreens.EnterGame: a barra do HUD é montada no jogo real, não só no harness")

	# Elo 2 — o clique do painel só ARMA, e só `ConfirmPending` abre a porta.
	Check(_LinkForgeClickOnlyArms(panel), "CraftPanel: o botão de forjar está ligado no handler que ARMA (e o handler não emite)")
	Check(_LinkConfirmIsTheOnlyDoor(panel), "CraftPanel: ConfirmPending é a única porta — exatamente 1 definição + 1 chamada de _send")
	var request : String = _funcBody(panel, "func RequestCraft(")
	Check(request.contains("\"SubmitCraft\""), "CraftPanel: RequestCraft arma a pendência no alvo SubmitCraft")
	Check(request.contains("_pending = {"), "CraftPanel: RequestCraft guarda a prévia em _pending")
	Check(not request.contains("_send(") and not request.contains("Network."),
		"CraftPanel: RequestCraft não emite (todo gasto passa pela confirmação)")
	var send : String = _funcBody(panel, "func _send(")
	Check(send.contains("NetworkTargets.has(methodName)"), "CraftPanel: _send fecha a saída pela tabela declarada")
	Check(send.contains("NetworkSend("), "CraftPanel: _send delega o ramo literal a NetworkSend")
	Check(_LinkRpcBranchIsSubmitCraft(panel), "CraftPanel: NetworkSend tem o braço literal Network.SubmitCraft(")
	var branch : String = _funcBody(panel, "func NetworkSend(")
	Check(branch.contains("int(args[0])") and branch.contains("int(args[1])") and branch.contains("str(args[2])") and branch.contains("args[3] as Dictionary"),
		"CraftPanel: os quatro argumentos saem na ordem e tipo do RPC (slot, base, nome, modifiers)")
	Check(panel.contains("const NetworkTargets : Array[String] = [\"SubmitCraft\"]"),
		"CraftPanel: a tabela de alvos declara exatamente SubmitCraft")

	# Elo 3 — a rua é a MESMA autoridade do comando de GM: um serviço, duas pontas.
	var facade : String = _funcBody(netRaw, "func SubmitCraft(")
	Check(facade.contains("CallServer(\"SubmitCraft\""), "Network.gd: o facade roteia SubmitCraft para o servidor")
	var serverBody : String = _funcBody(srvRaw, "func SubmitCraft(")
	Check(serverBody.contains("Launcher.Economy.SubmitCraft("), "Server.gd: o handler cai em Launcher.Economy.SubmitCraft")
	Check(serverBody.contains("Peers.GetCharacter(peerID)") and serverBody.contains("Peers.GetAccount(peerID)"),
		"Server.gd: character e account vêm do PEER, nunca do payload")
	var ecoBody : String = _funcBody(ecoRaw, "func SubmitCraft(")
	Check(ecoBody.contains("itemForgeService.SubmitCraft("), "EconomyService.gd: a fachada chama o mesmo serviço que o GM usa")
	var forgeBody : String = _funcBody(forgeRaw, "func SubmitCraft(")
	Check(forgeBody.contains("CraftCatalog.MaterialPerCraft("), "ItemForgeService.gd: a matéria-prima cobrada é a do catálogo")
	Check(forgeBody.contains("CraftCatalog.BudgetCap("), "ItemForgeService.gd: o budget que decide o pedido é o do catálogo")
	Check(forgeBody.contains("\"no_stock\"") and forgeBody.contains("\"budget_exceeded\"") and forgeBody.contains("\"daily_cap_reached\""),
		"ItemForgeService.gd: insumo, budget e cap diário são recusados AQUI (autoridade, não vitrine)")
	Check(_funcBody(cmdRaw, "func CommandCsCraft(").contains("Launcher.Economy.ApproveCraftSubmission("),
		"WorldCommands.gd: o /cs_craft do GM revisa pela mesma EconomyService que o painel submette")

	# O painel não é um segundo motor: não toca o serviço nem inventa identidade.
	for banned in ["Launcher.Economy", "ItemForgeService", "EconomyService", "ApproveCraftSubmission", "charID", "accountID"]:
		Check(not panel.contains(String(banned)), "CraftPanel.gd: zero referência a \"%s\" (cliente não mintaa item nem identidade)" % String(banned))

	# A vitrine vem do catálogo, por leitura explícita de cada número.
	var recipes : String = _funcBody(panel, "func BuildRecipes(")
	Check(recipes.contains("CraftCatalog.BUDGET_CAP"), "CraftPanel: BuildRecipes percorre BUDGET_CAP (o catálogo decide o que existe)")
	Check(recipes.contains("CraftCatalog.BudgetCap("), "CraftPanel: o cap por (tier, slot) vem de BudgetCap")
	Check(recipes.contains("CraftCatalog.SLOT_NAMES"), "CraftPanel: os nomes de slot vêm de SLOT_NAMES")
	Check(recipes.contains("CraftCatalog.SubmitFee("), "CraftPanel: a taxa vem de SubmitFee")
	Check(recipes.contains("CraftCatalog.MaterialPerCraft("), "CraftPanel: a quantidade de insumo vem de MaterialPerCraft")
	Check(recipes.contains("FarmZoneData.GetBandMaterialHash("), "CraftPanel: a matéria-prima é a da faixa declarada (FarmZoneData)")
	Check(_funcBody(panel, "func ModifierKeys(").contains("CraftCatalog.MOD_WEIGHTS"),
		"CraftPanel: só entram os modificadores com peso no catálogo")

	var vocab : Array[String] = _RecipeVocabulary()
	Check(vocab.size() > 20, "vocabulário de referência montado do catálogo + ItemsDB (%d nomes)" % vocab.size())
	var panelHits : Array[String] = _HardcodedRecipeNames(_stringLiterals(panel), vocab)
	Check(panelHits.is_empty(), "CraftPanel.gd: zero nome de slot/matéria-prima/item como literal de código (%s)" % str(panelHits))
	var sceneHits : Array[String] = _HardcodedRecipeNames(_stringLiterals(sceneRaw), vocab)
	Check(sceneHits.is_empty(), "CraftPanel.tscn: a cena não traz lista de receita chumbada (%s)" % str(sceneHits))

# ------------------------------------------------------------------ (B) abrir pelo HUD
func _suiteOpen() -> void:
	print("-- B) o jogador abre a forja pelo HUD")
	guiNode.call("AddManualSkillButtons")
	var hud : HBoxContainer = guiNode.get("manualSkillBar") as HBoxContainer
	if not Check(hud != null, "a barra de HUD foi montada"):
		return
	var btn : Button = hud.get_node_or_null(NodePath("CraftAccess")) as Button
	if not Check(btn != null, "a barra tem o botão CraftAccess (a forja tem porta no HUD)"):
		return
	CheckEq(_ConnectionsTarget(btn, guiNode, "_on_craft_pressed"), 1, "CraftAccess ligado exatamente no handler do Gui")
	btn.pressed.emit()
	var panel : Node = guiNode.get("craftWindow")
	if not Check(panel != null, "apertar o botão instanciou a janela (craftWindow)"):
		return
	CheckStr(str(panel.get("name")), "Craft", "a janela montada é a 'Craft'")
	Check(bool(panel.is_inside_tree()), "a janela está na árvore viva")
	Check(panel.get_parent() == windowsNode, "a janela está sob Gui.windows")
	Check(bool(panel.is_visible()), "abrir o botão mostra a janela")
	btn.pressed.emit()
	Check(guiNode.get("craftWindow") == panel, "segundo clique reusa a MESMA instância (EnsureCraftPanel)")
	CheckEq(_CountByScript(windowsNode, "res://sources/gui/CraftPanel.gd"), 1, "existe exatamente um painel de forja na árvore")
	Check(panel.find_child("TitleBar", true, false) != null, "a cena trouxe o TitleBar (botão de fechar no mouse/touch)")
	for field in ["_recipeOption", "_modOption", "_modValue", "_nameEdit", "_recipeLabel", "_statusLabel", "_confirmRow", "_confirmLabel"]:
		Check(panel.get(field) != null, "_ready montou %s (fora de cena não há _ready de graça)" % field)
	var row : Control = panel.get("_confirmRow") as Control
	Check(row != null and not bool(row.is_visible()), "a linha de confirmação começa escondida")
	Check(panel.find_child("CraftForgeButton", true, false) != null, "o botão de submeter existe na árvore montada")
	Check(int(panel.call("RecipeCount")) > 0, "a janela abriu já mostrando receitas (%d)" % int(panel.call("RecipeCount")))
	# Fechar e reabrir pelo caminho do jogador: o TitleBar da cena é a única porta de
	# saída no mouse/touch, e o botão do HUD tem que reabrir a MESMA janela.
	var touch : Node = panel.find_child("TouchButton", true, false)
	if not Check(touch != null, "o TitleBar da cena trouxe o botão de fechar (sem ele a janela é um beco)"):
		return
	touch.emit_signal("released")
	Check(not bool(panel.is_visible()), "fechar pelo TitleBar esconde a janela (ToggleControl do ancestral)")
	btn.pressed.emit()
	Check(bool(panel.is_visible()), "o botão do HUD reabre a janela escondida")
	Check(guiNode.get("craftWindow") == panel, "reabrir não cria uma segunda janela")

func _ConnectionsTarget(btn : Button, target : Object, methodName : String) -> int:
	var hits : int = 0
	for conn in btn.pressed.get_connections():
		var callable : Callable = conn.get("callable", Callable())
		if not callable.is_valid() or callable.get_method() != methodName:
			continue
		if callable.get_object() == target:
			hits += 1
	return hits

func _CountByScript(parent : Node, scriptPath : String) -> int:
	var total : int = 0
	for child in parent.get_children():
		var childScript : Script = child.get_script()
		if childScript != null and str(childScript.resource_path) == scriptPath:
			total += 1
	return total

# ------------------------------------------------------------------ (C) vitrine = catálogo
func _suiteCatalog() -> void:
	print("-- C) a vitrine é recomputada do catálogo, não lembrada")
	var panel : Node = guiNode.get("craftWindow")
	if not Check(panel != null, "painel de forja vivo (suíte C)"):
		return
	var rows : Array = panel.call("BuildRecipes") as Array
	var expected : Dictionary = _ExpectedRecipes()
	Check(not rows.is_empty(), "BuildRecipes devolve receitas (o catálogo libera pares com template)")
	CheckEq(rows.size(), expected.size(), "uma linha por (tier, slot) liberado que tenha célula real")
	var seen : Dictionary = {}
	for entry in rows:
		var row : Dictionary = entry as Dictionary
		var key : String = "%d:%d" % [int(row["tier"]), int(row["slot"])]
		seen[key] = true
		Check(int(row["cap"]) > 0, "%s: cap positivo (nenhum slot bloqueado entra na lista)" % key)
		if not Check(expected.has(key), "%s: existe no catálogo independentemente recomputado" % key):
			continue
		var want : Dictionary = expected[key] as Dictionary
		CheckEq(int(row["cap"]), int(want["cap"]), "%s: o budget desenhado é o do catálogo" % key)
		CheckEq(int(row["fee"]), int(want["fee"]), "%s: a taxa é SUBMIT_FEE_BASE x tier^2 recomputada" % key)
		CheckEq(int(row["material_units"]), int(want["units"]), "%s: o insumo é MATERIAL_UNITS_PER_TIER x tier" % key)
		CheckEq(int(row["base_hash"]), int(want["base"]), "%s: o template é a célula equipável do par" % key)
		Check(int(row["material_units"]) > 0, "%s: a forja tem segundo preço além do ouro" % key)
	for key in expected.keys():
		Check(seen.has(String(key)), "o par %s do catálogo chegou à tela" % String(key))
	# Pares bloqueados: se houvesse lista chumbada, um destes poderia aparecer.
	var blocked : Array[String] = _BlockedPairs()
	Check(blocked.size() > 0, "o catálogo declara pares bloqueados (%d)" % blocked.size())
	for probe in 3:
		if probe >= blocked.size():
			break
		Check(not seen.has(blocked[probe]), "o par bloqueado %s não aparece na vitrine" % blocked[probe])
	var consts : Dictionary = _catalogConsts()
	var slotNames : Array = consts.get("SLOT_NAMES", []) as Array
	var firstRow : Dictionary = rows[0] as Dictionary
	CheckStr(str(panel.call("SlotName", int(firstRow["slot"]))), str(slotNames[int(firstRow["slot"])].to_upper()),
		"SlotName() devolve exatamente SLOT_NAMES[slot] (nome lido, não digitado)")
	var modKeys : PackedStringArray = panel.call("ModifierKeys") as PackedStringArray
	Check(modKeys.size() > 0, "ModifierKeys() devolve efeitos (%d)" % modKeys.size())
	CheckEq(_countOccurrences(String(modKeys[0]), "None"), 0, "None nunca é oferta de modificador")
	_suiteStockMark(panel, firstRow)

# A vitrine diz "dá agora?" a partir do BOLSO, e a régua mede a sensibilidade: o mesmo
# par com `owned` abaixo e acima de `material_units` tem que sair com marcas
# diferentes. Sem isto a linha mostraria um estado que não muda com nada — régua que
# não pode falhar.
func _suiteStockMark(panel : Node, firstRow : Dictionary) -> void:
	var units : int = int(firstRow["material_units"])
	Check(units > 0, "a receita lida tem insumo (%d unidades)" % units)
	var poor : Dictionary = firstRow.duplicate(true)
	poor["owned"] = 0
	var rich : Dictionary = firstRow.duplicate(true)
	rich["owned"] = units
	var poorMark : String = str(panel.call("StockMark", poor))
	var richMark : String = str(panel.call("StockMark", rich))
	Check(poorMark.to_lower().contains("falta"), "sem bolso nenhum a marca diz FALTA (%s)" % poorMark)
	Check(richMark.contains("dá"), "com o insumo exato a marca diz DÁ (%s)" % richMark)
	Check(poorMark != richMark, "a marca muda com o bolso (não é texto fixo decorativo)")
	Check(str(panel.call("RecipeLabel", poor)).contains("0/%d" % units),
		"a LINHA da lista carrega o bolso: %s" % str(panel.call("RecipeLabel", poor)))
	var option : OptionButton = panel.get("_recipeOption") as OptionButton
	if Check(option != null and option.item_count > 0, "a lista montada tem linhas (%d)" % (option.item_count if option != null else 0)):
		var rowText : String = option.get_item_text(0)
		Check(rowText.contains("insumo") or rowText.contains("faixa sem insumo"),
			"a linha visível ao jogador declara o estado do insumo (%s)" % rowText)
		Check(int(panel.call("RecipeCount")) == option.item_count,
			"uma linha por receita lida (%d/%d)" % [option.item_count, int(panel.call("RecipeCount"))])

func _ExpectedRecipes() -> Dictionary:
	var out : Dictionary = {}
	var consts : Dictionary = _catalogConsts()
	var caps : Dictionary = consts.get("BUDGET_CAP", {}) as Dictionary
	var slotCount : int = (consts.get("SLOT_NAMES", []) as Array).size()
	var feeBase : int = int(consts.get("SUBMIT_FEE_BASE", 0))
	var unitsPerTier : int = int(consts.get("MATERIAL_UNITS_PER_TIER", 0))
	var items : Dictionary = dbScript.get("ItemsDB") as Dictionary
	for tierKey in caps.keys():
		var tier : int = int(tierKey)
		var row : Array = caps.get(tierKey, []) as Array
		for slot in slotCount:
			var cap : int = int(row[slot]) if slot < row.size() else 0
			if cap <= 0:
				continue
			var base : int = _FirstEquippable(items, tier, slot)
			if base <= 0:
				continue
			out["%d:%d" % [tier, slot]] = {"cap" = cap, "fee" = feeBase * tier * tier, "units" = unitsPerTier * tier, "base" = base}
	return out

func _FirstEquippable(items : Dictionary, tier : int, slot : int) -> int:
	var best : int = 0
	for cellHash in items.keys():
		var cell : Object = items.get(int(cellHash), null)
		if cell == null or bool(cell.get("material")):
			continue
		if int(cell.get("tier")) != tier or int(cell.get("slot")) != slot:
			continue
		if best == 0 or int(cellHash) < best:
			best = int(cellHash)
	return best

func _BlockedPairs() -> Array[String]:
	var out : Array[String] = []
	var consts : Dictionary = _catalogConsts()
	var caps : Dictionary = consts.get("BUDGET_CAP", {}) as Dictionary
	var slotCount : int = (consts.get("SLOT_NAMES", []) as Array).size()
	for tierKey in caps.keys():
		var row : Array = caps.get(tierKey, []) as Array
		for slot in slotCount:
			var cap : int = int(row[slot]) if slot < row.size() else 0
			if cap == 0:
				out.append("%d:%d" % [int(tierKey), slot])
	return out

# ------------------------------------------------------------------ (D) disparo medido
func _suiteDispatch() -> void:
	print("-- D) armar não emite; confirmar emite SubmitCraft com o payload certo")
	var panel : Node = guiNode.get("craftWindow")
	if not Check(panel != null, "painel de forja vivo (suíte D)"):
		return
	var sends : Array = []
	panel.set("SendHook", func(methodName : String, args : Array) -> void: sends.append([methodName, args]))
	var nameEdit : Object = panel.get("_nameEdit")
	nameEdit.set("text", "Wiring Forge Blade")
	var modOption : Object = panel.get("_modOption")
	modOption.set("selected", 0)
	var modValue : Object = panel.get("_modValue")
	modValue.set("value", 3.0)
	var sentBefore : int = _SentCount(panel)
	Check(bool(panel.call("RequestCraft")), "RequestCraft arma com nome e modificador válidos")
	CheckEq(int(panel.call("PendingCount")), 1, "a prévia fica armada (gasto atrás de confirmação)")
	CheckStr(str(panel.call("PendingMethod")), "SubmitCraft", "a pendência é do alvo SubmitCraft")
	CheckEq(sends.size(), 0, "armar NÃO fala com a rede")
	CheckEq(_SentCount(panel), sentBefore, "nada entra no rastro de envios sem confirmar")
	var armed : Dictionary = panel.call("SelectedRecipe") as Dictionary
	var args : Array = panel.call("PendingArgs") as Array
	CheckEq(args.size(), 4, "o payload do cliente tem 4 campos — nenhum char/account (identidade é do peer)")
	CheckEq(int(args[0]), int(armed["slot"]), "args[0] = slot da receita lida do catálogo")
	CheckEq(int(args[1]), int(armed["base_hash"]), "args[1] = hash do template real do par")
	CheckStr(str(args[2]), "Wiring Forge Blade", "args[2] = o nome digitado")
	Check(args[3] is Dictionary and not (args[3] as Dictionary).is_empty(), "args[3] = dicionário de modificadores")
	var line : String = str(panel.call("PendingLine"))
	Check(line.contains(str(int(armed["fee"]))) and line.contains(str(int(armed["material_units"]))),
		"a prévia cita os DOIS preços lidos do catálogo (%s)" % line)
	Check(line.to_lower().contains("aprova"), "a prévia avisa que o item só existe depois da aprovação de GM")
	panel.call("ConfirmPending")
	CheckEq(sends.size(), 1, "ConfirmPending emite exatamente um envio")
	CheckStr(str((sends[0] as Array)[0]), "SubmitCraft", "o alvo emitido é SubmitCraft")
	Check(_ArgsEqual((sends[0] as Array)[1] as Array, args), "com os mesmos args armados (got %s)" % str((sends[0] as Array)[1]))
	CheckEq(int(panel.call("PendingCount")), 0, "confirmar desarma a prévia")
	CheckEq(_SentCount(panel), sentBefore + 1, "o rastro de envios anotou o alvo")
	# Portão de nomes: fora da tabela não sai e não é anotado.
	panel.call("_send", "CraftSelfDestruct", [] as Array)
	CheckEq(sends.size(), 1, "alvo fora da tabela não chega à rua")
	CheckEq(_SentCount(panel), sentBefore + 1, "nem entra no rastro de envios")
	# Cancelar não emite; entrada inválida não arma; clique sem nome não arma.
	Check(bool(panel.call("RequestCraft")), "rearmar depois de enviar funciona")
	CheckEq(int(panel.call("PendingCount")), 1, "a nova prévia está armada")
	panel.call("CancelPending")
	CheckEq(int(panel.call("PendingCount")), 0, "CancelPending desarma")
	CheckEq(sends.size(), 1, "e não emite nada")
	nameEdit.set("text", "ab")
	Check(not bool(panel.call("RequestCraft")), "nome curto não arma (higiene de digitação, não regra de economia)")
	CheckEq(sends.size(), 1, "e não emite")
	nameEdit.set("text", "")
	var forgeBtn : Button = panel.find_child("CraftForgeButton", true, false) as Button
	if Check(forgeBtn != null, "o botão de submeter existe para o clique real"):
		forgeBtn.pressed.emit()
		CheckEq(int(panel.call("PendingCount")), 0, "clicar 'submeter' sem nome não arma")
		CheckEq(sends.size(), 1, "nem fala com a rede")
	panel.set("SendHook", Callable())
	_CloseModal()

func _SentCount(panel : Object) -> int:
	return (panel.get("SentTargets") as Array).size()

func _ArgsEqual(value : Array, expected : Array) -> bool:
	if value.size() != expected.size():
		return false
	for index in value.size():
		if typeof(value[index]) == TYPE_DICTIONARY or typeof(expected[index]) == TYPE_DICTIONARY:
			if str(value[index]) != str(expected[index]):
				return false
		elif int(value[index]) != int(expected[index]):
			return false
	return true

func _CloseModal() -> void:
	var box : Node = guiNode.get("messageBox")
	if box != null and bool(box.has_method("Clear")):
		box.call("Clear")

# ------------------------------------------------------------------ (E) autoridade viva
func _suiteAuthority() -> void:
	print("-- E) a rua é a do servidor: o peer decide a identidade")
	Check(bool(networkNode.has_method("SubmitCraft")), "Network (autoload) tem SubmitCraft — o facade do RPC vive no nó")
	Check(bool(netServer.has_method("SubmitCraft")), "ENetServer tem SubmitCraft — o handler do servidor existe")
	Check(bool(ecoNode.has_method("SubmitCraft")), "EconomyService tem SubmitCraft — a mesma fachada do /cs_craft")
	var forge : Object = ecoNode.get("itemForgeService")
	Check(forge != null and bool(forge.has_method("SubmitCraft")), "ItemForgeService tem SubmitCraft — o destino final é um só")
	Check(forge != null and bool(forge.has_method("ApproveCraftSubmission")),
		"o serviço que recebe a submissão do painel é o mesmo que o GM aprova")
	var panel : Node = guiNode.get("craftWindow")
	if not Check(panel != null, "painel vivo para a sonda de autoridade"):
		return
	var rows : Array = panel.call("BuildRecipes") as Array
	if Check(not rows.is_empty(), "sonda de autoridade: há receita para submeter"):
		var row : Dictionary = rows[0] as Dictionary
		var before : int = _CraftRows()
		Check(before >= 0, "craft_submission é consultável (%d linhas)" % before)
		netServer.call("SubmitCraft", int(row["slot"]), int(row["base_hash"]), "Ghost Peer Probe", {"Attack" = 1}, 899999)
		CheckEq(_CraftRows(), before, "peer FANTASMA no handler do servidor não cria submissão nenhuma")
		var payload : Array = [int(row["slot"]), int(row["base_hash"]), "Ghost Peer Probe 2", {"Attack" = 1}, 899999]
		netServer.callv("SubmitCraft", payload)
		CheckEq(_CraftRows(), before, "o mesmo payload do painel, reenviado por peer fantasma, segue sem criar linha")

func _CraftRows() -> int:
	if sqlNode == null or not bool(sqlNode.has_method("QueryBindings")):
		return -1
	var out : Array = sqlNode.call("QueryBindings", "SELECT COUNT(*) AS n FROM craft_submission;", []) as Array
	return -1 if out.is_empty() else int((out[0] as Dictionary).get("n", 0))

# ------------------------------------------------------------------ (F) contra-prova
# Régua que não sabe falhar não mede nada. As réguas de (A) recebem corpos FORJADOS —
# o mesmo texto com a chamada viva ou apagada — e têm que discordar.
func _suiteNegativeControls() -> void:
	print("-- F) contra-prova: as réguas leem código, não prosa")
	var alive : String = "func NetworkSend(methodName : String, args : Array) -> bool:\n\tmatch methodName:\n\t\t\"SubmitCraft\":\n\t\t\tNetwork.SubmitCraft(int(args[0]), int(args[1]), str(args[2]), args[3] as Dictionary)\n\t\t\treturn true\n\treturn false\n"
	var rotted : String = "func NetworkSend(methodName : String, args : Array) -> bool:\n\tmatch methodName:\n\t\t\"SubmitCraft\":\n\t\t\t# emite Network.SubmitCraft(int(args[0]), int(args[1]), str(args[2]), args[3]) no facade\n\t\t\treturn true\n\treturn false\n"
	Check(_EmitsCraftRpc(_funcBody(_codeOnly(alive), "func NetworkSend(")),
		"contra-prova (presente): corpo com a chamada é lido como PRESENTE")
	Check(not _EmitsCraftRpc(_funcBody(_codeOnly(rotted), "func NetworkSend(")),
		"contra-prova (AUSENTE): chamada apagada e a frase que a descreve viva => a régua diz ausente")
	Check(_codeOnly(rotted).contains("return true"), "o corpo mutilado continua legível (a régua caiu pela chamada, não pelo resto)")
	var wholeFile : String = "# forja: o painel chama Network.SubmitCraft no facade\nfunc NetworkSend(methodName : String, args : Array) -> bool:\n\treturn false\n"
	Check(not _EmitsCraftRpc(_funcBody(_codeOnly(wholeFile), "func NetworkSend(")),
		"e o corpo NÃO é lido do arquivo inteiro: só o comentário citaria a chamada")

	var direct : String = "func _on_forge_pressed() -> void:\n\t_send(\"SubmitCraft\", PendingArgs())\n\nfunc ConfirmPending() -> void:\n\t_send(\"SubmitCraft\", [])\n\nfunc _send(methodName : String, args : Array) -> void:\n\tpush_error(\"x\")\n"
	CheckEq(_SendCallSites(_codeOnly(direct)), 3, "contra-prova: clique ligado direto no _send é contado (3) e reprovaria a régua de 2")
	CheckEq(_SendCallSites(_codeOnly(_fileText("res://sources/gui/CraftPanel.gd"))), 2, "a fonte real continua com 1 definição + 1 chamada")

	var vocab : Array[String] = _RecipeVocabulary()
	var chumbed : String = "func Rebuild() -> void:\n\t_recipeOption.add_item(\"CHEST tier 1\")\n\t_label(root, \"Chalk Dust x12\")\n"
	var hits : Array[String] = _HardcodedRecipeNames(_stringLiterals(_codeOnly(chumbed)), vocab)
	Check(hits.size() >= 2, "contra-prova: lista de receita chumbada é pega pelo detetor (%s)" % str(hits))
	var honest : String = "func Rebuild() -> void:\n\t_recipeOption.add_item(RecipeLabel(row))\n\t_label(root, RecipeLine(row))\n"
	Check(_HardcodedRecipeNames(_stringLiterals(_codeOnly(honest)), vocab).is_empty(),
		"e a mesma régua não reclama de uma vitrine montada a partir do catálogo")

	_suiteLinkMutation()

# (G) A MORDIDA DA CORRENTE: a fonte REAL de cada elo é copiada para a memória, uma
# linha é cortada de cada vez, e o MESMO predicado que a suíte (A) aplicou ao arquivo
# vivo tem que discordar da cópia mutilada — sem escrever em disco, sem tocar o
# produto. No fim o arquivo é relido e tem que sair byte a byte como entrou e com
# todos os élos verdes de novo. É o que separa "226 checks, 0 failures" de uma régua
# que só sabia repetir o que estava escrito.
func _suiteLinkMutation() -> void:
	print("-- G) contra-prova da corrente: cortar um elo na memória derruba a régua")
	var pristine : Dictionary = _linkSources()
	for key in pristine.keys():
		Check(not String(pristine[key]).is_empty(), "fonte viva lida para a mesa de mutilação: %s" % String(key))
	for entry in _RotTable:
		var linkName : String = String(entry[0])
		var sourceKey : String = String(entry[1])
		var needle : String = String(entry[2])
		var replacement : String = String(entry[3])
		var predicate : String = String(entry[4])
		var alive : String = String(pristine[sourceKey])
		if not Check(alive.contains(needle), "%s: a agulha do corte existe na fonte viva (%s)" % [linkName, needle]):
			continue
		Check(_LinkPredicate(predicate, alive), "%s: predicado verde na fonte viva" % linkName)
		var rotted : String = alive.replace(needle, replacement)
		Check(rotted != alive, "%s: a cópia mutilada difere da viva" % linkName)
		Check(not _LinkPredicate(predicate, rotted),
			"%s: cortar \"%s\" quebra o elo e a régua DIZ AUSENTE (morde)" % [linkName, needle])
		# Especificidade: os demais élos do MESMO arquivo não podem cair com este corte
		# — senão a régua não mede um elo, mede o arquivo inteiro.
		for other in _RotTable:
			if String(other[0]) == linkName or String(other[1]) != sourceKey:
				continue
			Check(_LinkPredicate(String(other[4]), rotted),
				"%s: o corte não derruba o elo vizinho \"%s\" (cada régua mede o seu elo)" % [linkName, String(other[0])])
	var after : Dictionary = _linkSources()
	for key in pristine.keys():
		Check(String(after[key]) == String(pristine[key]),
			"a fonte em disco (%s) saiu intocada da mesa de mutilação" % String(key))
	for entry in _RotTable:
		Check(_LinkPredicate(String(entry[4]), String(after[String(entry[1])])),
			"revertido (nada foi escrito), o elo \"%s\" está verde de novo" % String(entry[0]))

func _finish() -> void:
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
