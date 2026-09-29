extends SceneTree

# SOM-IDLE auditoria 2026-09-27 (§GASTOS IRREVERSÍVEIS): harness do freio de
# confirmação. Treze cliques que destroem moeda/item sem volta (abrir baú,
# comprar baús, vendor, oferta diária, reroll, cosmético, passe standard/deluxe,
# skip do passe, chave de boss, e as TRÊS operações do altar que destroem um
# equipamento) saíam para a rede com um clique só. Hoje cada um passa pelo
# idiom da casa (leilão/arena): o handler do botão APENAS arma a pendência e
# `ConfirmPending()` é o ÚNICO caminho que emite RPC.
#
# Uso: godot --headless --path . -s tests/spend_confirm_test.gd
#       (XDG_DATA_HOME próprio — ver scripts/test.sh.)
# Exit code: nº de checks falhos (0 = verde). Última linha:
#       == RESULT: N checks, M failures ==
#
# Contrato de gate (scripts/ci_gate_log.sh): nada de linha "PASSED"; a régua é a
# linha de resultado + exit code. E — igualzinho aos harnesses irmãos — este
# arquivo é duck-typed: um main-loop `-s` compila ANTES dos autoloads e dos
# class_names do projeto existirem, então nada de `Launcher`/`Network`/
# `UICommons` como identificador em anotação de tipo; os painéis entram por
# load() pós-boot e tudo que vem deles é chamado via call()/set()/get().
#
# POR QUE é comportamental e não "olha o texto do arquivo": cada painel expõe a
# costura `SendHook` (a mesma do leilão, medida em `tests/IdleTests.gd:1250-1254`
# dentro de `SuiteGuiPanels`), e
# "emitiu" é MEDIDO pela lista de envios. O driver abaixo exercita o handler
# REAL que o botão conecta (`_on_*`), exige zero envios até o `ConfirmPending()`
# rodar, o RPC certo com os args certos depois dele, idempotência no segundo
# confirm e silêncio total no cancel. Se alguém arrancar a confirmação de um
# painel (handler voltando a chamar a rede direto), o check "armar NÃO emite"
# morre vermelho — é exatamente o contrato que este harness veio fechar.
# Onde isto não basta para provar o freio SOZINHO (a superfície modal que o
# jogador vê, inexistente headless), há um wiring guard nominal, marcado como
# tal, do mesmo tipo dos de gameplay_fix_test.gd.

var checks : int = 0
var failures : int = 0
var dbScript : GDScript = null

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

# GDScript 4: passar String onde a assinatura é (int,int,String) é Parse Error
# e derruba o preflight inteiro (mordida duas vezes neste repo — ver o header
# de scripts/test.sh). Por isso os helpers são separados por tipo, sem Variant.
func CheckEq(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func CheckStr(value : String, expected : String, label : String) -> bool:
	return Check(value == expected, "%s (got '%s', want '%s')" % [label, value, expected])

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

# Carrega o script do painel, instancia FORA da árvore e devolve (objeto, log
# de envios). Fora da árvore não há _ready nem @onready — os Request*/Confirm*
# são escritos para viver só de variáveis próprias (rótulos guardados por
# `if label:`), e é assim que o leilão/arena já são testados em IdleTests.
func _spawn(panelPath : String, label : String) -> Dictionary:
	var script : GDScript = load(panelPath)
	if not Check(script != null, "%s: script carrega" % label):
		return {}
	var panel : Object = script.new()
	if not Check(panel != null, "%s: instanciável fora da árvore" % label):
		return {}
	var sends : Array = []
	# O log é um Array capturado POR REFERÊNCIA de conteúdo (a regra que morde
	# closures GDScript: valor capturado, conteúdo do container propaga).
	panel.set("SendHook", func(methodName : String, args : Array) -> void:
		sends.append([methodName, args]))
	return {"panel" = panel, "sends" = sends}

# Única forma de ler o `pendingLabel`/hint de um painel fora da árvore: os
# getters nominais do estado armado — que os painéis da casa já expõem.
func _pendingCount(panel : Object) -> int:
	return int(panel.call("PendingCount"))

func _pendingLine(panel : Object) -> String:
	return str(panel.call("PendingLine"))

# ------------------------------------------------------------------ o gate em si
# entry: handler = nome do método que o botão conecta; args = argumentos do
# clique; method = RPC que DEVE sair no confirm; rpcArgs = args esperados;
# needles = fragmentos que a linha armada tem que citar (preço, item, perda).
func _driveSpend(where : String, panel : Object, sends : Array, entry : Dictionary) -> void:
	var handler : String = str(entry["handler"])
	var args : Array = entry["args"] as Array
	# Contagem RELATIVA ao site: um painel pode hospedar até quatro gastos (Shop)
	# e o log de envios é único — régua absoluta acusaria o gasto do site anterior.
	var base : int = sends.size()
	Check(bool(Callable(panel, handler).is_valid()), "%s: handler conectado ao botão existe (%s)" % [where, handler])
	Callable(panel, handler).callv(args)
	CheckEq(sends.size(), base, "%s.%s: o clique NÃO fala com a rede sem confirmação" % [where, handler])
	CheckEq(_pendingCount(panel), 1, "%s.%s: o clique arma exatamente uma pendência" % [where, handler])
	var line : String = _pendingLine(panel)
	for needle in (entry["needles"] as Array):
		Check(line.contains(str(needle)), "%s.%s: a linha armada cita '%s' (got '%s')" % [where, handler, str(needle), line])
	panel.call("ConfirmPending")
	CheckEq(sends.size(), base + 1, "%s.%s: confirmar é o único caminho que emite" % [where, handler])
	var emitted : Array = sends[base] as Array
	CheckStr(str(emitted[0]), str(entry["method"]), "%s.%s: o RPC emitido é o do gasto" % [where, handler])
	Check((emitted[1] as Array) == (entry["rpcArgs"] as Array), "%s.%s: com os args certos %s (got %s)" % [where, handler, str(entry["rpcArgs"]), str(emitted[1])])
	CheckEq(_pendingCount(panel), 0, "%s.%s: confirmar desenrosca a pendência" % [where, handler])
	panel.call("ConfirmPending")
	CheckEq(sends.size(), base + 1, "%s.%s: confirmar duas vezes não emite duas vezes" % [where, handler])
	Callable(panel, handler).callv(args)
	CheckEq(_pendingCount(panel), 1, "%s.%s: rearma depois do gasto" % [where, handler])
	panel.call("CancelPending")
	CheckEq(_pendingCount(panel), 0, "%s.%s: cancelar desarma" % [where, handler])
	CheckEq(sends.size(), base + 1, "%s.%s: cancelar não emite nada" % [where, handler])

func _source(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text : String = file.get_as_text()
	file.close()
	return text

# Wiring guard (declarado, §gameplay_fix_test): o que o driver de cima NÃO pode
# medir headless é a SUPERFÍCIE — sem `Launcher.GUI.messageBox` o modal é no-op
# por contrato de UICommons. Se um painel armasse pendência sem nunca abrir o
# MessageBox, o jogador ficaria sem botão de confirmar (só o harness chamaria
# ConfirmPending). Então cada arquivo tem que citar o modal da casa AMARRADO ao
# ConfirmPending — texto-fonte, no mínimo verificável, mesmo padrão dos guards
# do leilão.
func _guardAskSurface(path : String, label : String) -> void:
	var src : String = _source(path)
	Check(src.contains("UICommons.MessageBox("), "%s: a pergunta sai pelo modal da casa (wiring guard)" % label)
	Check(src.contains("\"ConfirmPending\""), "%s: o modal confirma via ConfirmPending, o único caminho de rede (wiring guard)" % label)

func _initialize():
	_runTests()

func _runTests():
	print("== SOM-SPEND confirm harness (13 gastos irreversíveis atrás de confirmação) ==")
	var launcher : Node = _autoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return

	# Espera do boot offline — idiom copiado de social_fix_test.gd:59-75 e
	# gameplay_fix_test.gd:126-136: SQL+World primeiro, DRAIN DO PRELOAD THREADADO
	# do DB depois. Sem o segundo wait, os load()/quit() deste harness caem no
	# meio dos parses em worker thread e o teardown segfaulta sob carga de CPU
	# (a corrida documentada em sources/db/DB.gd:232 e Launcher.gd:254).
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = launcher.get("SQL")
		var worldNode : Node = launcher.get("World")
		if sqlNode != null and sqlNode.get("isInitialized") and worldNode != null and worldNode.get("isInitialized"):
			break
	print("== boot wait done (waited %d ms) ==" % waited)
	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for dbTick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "DB.isInitialized drenado antes de carregar painéis ou quit"):
		_finish()
		return

	# ---------------------------------------------------------------- Chests
	# custo: abrir baú pago (baú é consumido). rpc: OpenChest(chestID).
	var chests : Dictionary = _spawn("res://sources/gui/Chests.gd", "Chests")
	if not chests.is_empty():
		_driveSpend("Chests", chests["panel"], chests["sends"], {
			"handler" = "_on_chest_pressed", "args" = [7],
			"method" = "OpenChest", "rpcArgs" = [7],
			"needles" = ["#7", "consumes"]})
		# Recusa nominal sem pendência: baú inexistente não arma nada.
		Check(not bool(chests["panel"].call("RequestOpenChest", 0)), "Chests: baú #0 não arma nada")
		CheckEq(_pendingCount(chests["panel"]), 0, "Chests: a recusa não deixa pendência")
		CheckEq((chests["sends"] as Array).size(), 1, "Chests: a recusa não emite")
		_guardAskSurface("res://sources/gui/Chests.gd", "Chests")

	# ---------------------------------------------------------------- Shop (4 sites)
	var shop : Dictionary = _spawn("res://sources/gui/Shop.gd", "Shop")
	if not shop.is_empty():
		# preço do baú visto no último estado do servidor (120 é o default da
		# própria janela) — a linha cita o TOTAL porque é o total que dói.
		(shop["panel"] as Object).set("_chestCost", 120)
		_driveSpend("Shop", shop["panel"], shop["sends"], {
			"handler" = "_on_buy_chest_pressed", "args" = [5],
			"method" = "BuyChests", "rpcArgs" = [5],
			"needles" = ["600", "gems", "not refundable"]})
		_driveSpend("Shop", shop["panel"], shop["sends"], {
			"handler" = "_on_buy_vendor_pressed", "args" = ["supplies.wood", "Wood bundle", 35],
			"method" = "BuyVendorOffer", "rpcArgs" = ["supplies.wood"],
			"needles" = ["Wood bundle", "35", "gold"]})
		_driveSpend("Shop", shop["panel"], shop["sends"], {
			"handler" = "_on_buy_daily_offer_pressed", "args" = ["daily.buff", "Double drops", 40],
			"method" = "BuyDailyOffer", "rpcArgs" = ["daily.buff"],
			"needles" = ["Double drops", "40", "gems"]})
		(shop["panel"] as Object).set("_rerollCost", 20)
		_driveSpend("Shop", shop["panel"], shop["sends"], {
			"handler" = "_on_reroll_daily_pressed", "args" = [],
			"method" = "RerollDailyShop", "rpcArgs" = [],
			"needles" = ["20", "gems"]})
		Check(not bool(shop["panel"].call("RequestBuyVendor", "", "x", 1)), "Shop: vendor sem id não arma")
		_guardAskSurface("res://sources/gui/Shop.gd", "Shop")

	# ---------------------------------------------------------------- Cosmetics
	var cosmetics : Dictionary = _spawn("res://sources/gui/Cosmetics.gd", "Cosmetics")
	if not cosmetics.is_empty():
		_driveSpend("Cosmetics", cosmetics["panel"], cosmetics["sends"], {
			"handler" = "_on_buy_cosmetic_pressed", "args" = ["title.alpha", "Alpha title", 80],
			"method" = "BuyCosmetic", "rpcArgs" = ["title.alpha"],
			"needles" = ["Alpha title", "80", "gems", "final sales"]})
		_guardAskSurface("res://sources/gui/Cosmetics.gd", "Cosmetics")

	# ---------------------------------------------------------------- SeasonPass (3 sites)
	var passPanel : Dictionary = _spawn("res://sources/gui/SeasonPass.gd", "SeasonPass")
	if not passPanel.is_empty():
		_driveSpend("SeasonPass", passPanel["panel"], passPanel["sends"], {
			"handler" = "_on_buy_pass_pressed", "args" = [],
			"method" = "BuyPass", "rpcArgs" = ["standard"],
			"needles" = ["standard", "24,90"]})
		_driveSpend("SeasonPass", passPanel["panel"], passPanel["sends"], {
			"handler" = "_on_buy_deluxe_pressed", "args" = [],
			"method" = "BuyPass", "rpcArgs" = ["deluxe"],
			"needles" = ["deluxe", "44,90"]})
		_driveSpend("SeasonPass", passPanel["panel"], passPanel["sends"], {
			"handler" = "_on_skip_level_pressed", "args" = [],
			"method" = "SkipPassLevel", "rpcArgs" = [],
			"needles" = ["50", "gems"]})
		# Fail-closed no teto do servidor: com os skips usados em 10/10 o skip
		# não arma (o botão já estava disabled; a régua agora é dupla).
		passPanel["panel"].set("_skipsUsed", 10)
		passPanel["panel"].set("_skipsMax", 10)
		Check(not bool(passPanel["panel"].call("RequestSkipLevel")), "SeasonPass: skip no teto não arma")
		CheckEq(_pendingCount(passPanel["panel"]), 0, "SeasonPass: teto estourado não deixa pendência")
		_guardAskSurface("res://sources/gui/SeasonPass.gd", "SeasonPass")

	# ---------------------------------------------------------------- Activities
	# chave de boss (gold) + as três destruições do altar. O altar fora da
	# árvore precisa do seletor seedado: `altarOption`/`altarItems` são vars
	# públicas exatamente para isto (ShowAltar as preenche do inventário).
	var activities : Dictionary = _spawn("res://sources/gui/Activities.gd", "Activities")
	if not activities.is_empty():
		_driveSpend("Activities", activities["panel"], activities["sends"], {
			"handler" = "_on_rush_buy_key", "args" = [],
			"method" = "BuyBossKey", "rpcArgs" = [],
			"needles" = ["chave", "gold"]})
		var opt : OptionButton = OptionButton.new()
		opt.add_item("Sword of Trials x2")
		opt.select(0)
		activities["panel"].set("altarOption", opt)
		activities["panel"].set("altarItems", [215387671])
		# Destruição nomeada: as três falas citam o item E a perda ("não volta").
		_driveSpend("Activities", activities["panel"], activities["sends"], {
			"handler" = "_on_altar_action", "args" = ["corrupt"],
			"method" = "CorruptItem", "rpcArgs" = [215387671],
			"needles" = ["Sword of Trials", "consumido", "não volta"]})
		_driveSpend("Activities", activities["panel"], activities["sends"], {
			"handler" = "_on_altar_action", "args" = ["cube"],
			"method" = "CubeUpcycle", "rpcArgs" = [215387671],
			"needles" = ["Sword of Trials", "consumido", "não volta"]})
		_driveSpend("Activities", activities["panel"], activities["sends"], {
			"handler" = "_on_altar_action", "args" = ["salvage"],
			"method" = "SalvageItem", "rpcArgs" = [215387671],
			"needles" = ["Sword of Trials", "DESTRUÍDO", "não volta"]})
		# Sem item selecionado (janela vazia) não se arma destruição nenhuma.
		activities["panel"].set("altarItems", [])
		Check(not bool(activities["panel"].call("RequestAltar", "corrupt")), "Activities: altar vazio não arma")
		opt.free()
		_guardAskSurface("res://sources/gui/Activities.gd", "Activities")

	# ---------------------------------------------------------------- Leaderboard
	# inscrição em torneio: entry_gold queimado na hora, sem reembolso nem em 1º.
	var board : Dictionary = _spawn("res://sources/gui/Leaderboard.gd", "Leaderboard")
	if not board.is_empty():
		_driveSpend("Leaderboard", board["panel"], board["sends"], {
			"handler" = "_on_enter_tournament_pressed", "args" = [4, "Copa Semanal", 500],
			"method" = "EnterTournament", "rpcArgs" = [4],
			"needles" = ["Copa Semanal", "500", "gold", "NEVER refunded"]})
		Check(not bool(board["panel"].call("RequestEnterTournament", 0, "x", 1)), "Leaderboard: torneio #0 não arma")
		_guardAskSurface("res://sources/gui/Leaderboard.gd", "Leaderboard")

	# ---------------------------------------------------------------- não-gates (âncora)
	# Duas coisas ficaram Direto-SEM-modal DE PROPÓSITO e o gate trava a decisão
	# contra regressão de sinal contrário: o reroll grátis por ad (não gasta
	# moeda nem item — mesmo contrato do `RequestDefense` da arena, que vai
	# direto porque salvar defesa não custa ticket) e a equipagem de cosmético
	# (reversível — trocar de volta não cobra nada). Se alguém confirmar um dia,
	# é só mover a âncora com o motivo, não apagar.
	var adsSrc : String = _source("res://sources/gui/Shop.gd")
	Check(adsSrc.contains("Network.RerollDailyShopAd(token)"), "Shop: reroll POR AD continua sem freio (não gasta nada — âncora de não-gate)")
	var equipSrc : String = _source("res://sources/gui/Cosmetics.gd")
	Check(equipSrc.contains("Network.EquipCosmetic(cid)"), "Cosmetics: equip continua sem freio (reversível — âncora de não-gate)")

	# ---------------------------------------------------------------- limpeza
	# O modal da casa pode ter ficado aberto segurando Callable para os painéis
	# livres — Clear() devolve o input ao jogo ANTES do free, e é no-op quando o
	# GUI não bootou (modo -s puro). ordem importa: liberar superfícies, depois
	# nós.
	var gui : Node = launcher.get("GUI")
	if gui != null:
		var msg : Node = gui.get("messageBox")
		if msg != null and msg.has_method("Clear"):
			msg.call("Clear")
	for spawned in [chests, shop, cosmetics, passPanel, activities, board]:
		if not spawned.is_empty():
			(spawned["panel"] as Object).free()

	_finish()

func _finish():
	# Última linha de defesa contra a corrida do preload threadado (mesmo
	# mecanismo de social_fix_test.gd:221-232): juntar o que ainda está em voo
	# com a árvore viva, nunca deixar o join cair dentro do teardown.
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
