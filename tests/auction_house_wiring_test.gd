extends SceneTree

# 059 (JUIZ MARKETPLACE 2026-09-27) — harness de ALCANÇABILIDADE do leilão.
#
# O serviço (AuctionHouseService), a migração 059 e os RPCs de página/bid/janela
# de ordens JÁ existiam e `tests/marketplace_depth_test.gd` já mede a ECONOMIA
# (paginação no SQL, offset além do fim = página vazia, exatamente uma linha de
# histórico por liquidação inclusive `via='bid'`, escrow/cancel/cruzamento/sem
# auto-negócio/taxa). O que NÃO existia — e o que este harness veio fechar — era
# a certeza de que essas três capacidades CHEGAM AO JOGADOR. A costura do painel
# (`_send` → `NetworkSend` → `Network.<rpc>` → `Server.<handler>`) é uma corrente:
# se um elo cai, o resto continua verde. `marketplace_depth_test.gd:343` só fazia
# `panel.contains("\"GetAuctionPage\"")` — e foi exatamente assim que a página, a
# bid e o cancelamento de bid ficaram PRESOS no serviço: o painel continha a
# string, mas o `match` de `NetworkSend` não tinha braço, caía no `push_error` e o
# `SendHook` de teste, que corta ANTES do `match`, nunca viu o buraco.
#
# Este harness fecha as três pontas que o texto-fonte não fecha:
#   (A) TABELA FECHADA (nominal, em texto): cada alvo declarado na tabela do
#       painel tem braço LITERAL `Network.<nome>(` no `NetworkSend`, existe como
#       `func <nome>(` no `Network` E como `func <nome>(` no `Server`. Um braço
#       arrancado, um RPC renomeado só de um lado, ou um handler sumido do
#       servidor derrubam a corrente.
#   (B) DISPARO (comportamental): com o painel REAL montado na árvore, cada
#       clique/drive manda o NOME e os ARGS certos para a rua — inclusive os três
#       da migração (GetAuctionPage/AuctionBid/AuctionBidCancel) — e o "armar sem
#       confirmar" não emite nada (o freio de gasto irreversível do leilão).
#   (C) RENDER (comportamental): o preço realizado e as ordens em pé que aparecem
#       nos rótulos vêm do PAYLOAD DO SERVIDOR (`sold_recent`/`sold`/`orders`), não
#       mais da memória da janela — a prova de que o histórico do 059 é servido.
#
# Uso: godot --headless --path . -s tests/auction_house_wiring_test.gd
#       (XDG_DATA_HOME próprio — ver scripts/test.sh.)
# Exit code = nº de checks falhos (0 = verde). Última linha:
#       == RESULT: N checks, M failures ==
#
# Igual aos irmãos: duck-typed (um main-loop `-s` compila antes dos autoloads e
# class_names), painéis entram por load() e tudo que vem deles é call()/get()/set().

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

func CheckEq(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _fileText(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t : String = f.get_as_text()
	f.close()
	return t

func _initialize():
	_runTests()

func _runTests():
	print("== auction house reachability harness (059: painel -> Network -> Server) ==")
	var launcherNode : Node = _autoload("Launcher")
	if launcherNode == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = launcherNode.get("SQL")
		var worldNode : Node = launcherNode.get("World")
		if sqlNode != null and sqlNode.get("isInitialized") and worldNode != null and worldNode.get("isInitialized"):
			break
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

	_suiteTable()
	await _suiteDispatch()
	await _suiteRender()
	_finish()

# ------------------------------------------------------------------ (A) tabela fechada
# Os alvos que a migração 059 empurrou para o primeiro plano e que o painel tem
# que saber emitir. Se um dia a tabela do painel perder um destes, o loop abaixo
# ainda o cobre (vira "declarado?"), mas aqui exigimos nominalmente.
const MigratedTargets : Array[String] = ["GetAuctionPage", "AuctionBid", "AuctionBidCancel"]

func _suiteTable() -> void:
	print("-- A) tabela de alvos fecha até o Network e o Server")
	var panelSrc : String = _fileText("res://sources/gui/AuctionHousePanel.gd")
	var netSrc : String = _fileText("res://sources/network/Network.gd")
	var srvSrc : String = _fileText("res://sources/network/server/Server.gd")
	Check(not panelSrc.is_empty() and not netSrc.is_empty() and not srvSrc.is_empty(), "os três elos da corrente têm fonte legível")
	# A tabela lida do PRÓPRIO objeto, não do texto: editar o const vira falha.
	var script : GDScript = load("res://sources/gui/AuctionHousePanel.gd")
	Check(script != null, "o painel carrega")
	if script == null:
		return
	var panel : Object = script.new()
	if panel == null:
		Check(false, "o painel instancia (fora da árvore, para ler a tabela)")
		return
	var declared : Array = panel.get("NetworkTargets") as Array
	Check(declared.size() >= 9, "a tabela declara os nove alvos de leilão (got %d)" % declared.size())
	for target in MigratedTargets:
		Check(declared.has(target), "o alvo da migração '%s' está na tabela do painel" % target)
	# Cada alvo declarado tem que fechar até o facade e até o servidor.
	for entry in declared:
		var name : String = str(entry)
		Check(panelSrc.contains("Network." + name + "("), "'%s': NetworkSend tem braço literal Network.%s( (senão cai no push_error)" % [name, name])
		Check(netSrc.contains("func " + name + "("), "'%s': o facade Network declara func %s(" % [name, name])
		Check(srvSrc.contains("func " + name + "("), "'%s': o Server atende func %s(" % [name, name])
	# O arm da leitura limpa usa a janela do painel (não um literal solto que pode
	# divergir do page_size do servidor): AHBrowseWindow existe e é chamado.
	Check(panelSrc.contains("Network.GetAuctionListings(AHBrowseWindow())"), "a leitura sem filtro passa pela janela do painel (AHBrowseWindow)")
	panel.free()

# ------------------------------------------------------------------ helpers de disparo
# Monta um painel REAL na árvore (roda _ready → AuctionHouseForm.Build) e devolve
# (objeto, log de envios). `SendHook` captura DEPOIS do portão de nomes, então um
# alvo fora da tabela NÃO aparece aqui — é o negativo que o bug antigo escondia.
func _spawnInTree() -> Dictionary:
	var script : GDScript = load("res://sources/gui/AuctionHousePanel.gd")
	if script == null:
		return {}
	var panel : Object = script.new()
	if panel == null:
		return {}
	var sends : Array = []
	panel.set("SendHook", func(methodName : String, args : Array) -> void:
		sends.append([methodName, args]))
	root.add_child(panel)
	return {"panel" = panel, "sends" = sends}

func _lastSend(sends : Array) -> Array:
	return [] if sends.is_empty() else (sends[sends.size() - 1] as Array)

func _sentName(sends : Array) -> String:
	return "" if sends.is_empty() else str((_lastSend(sends)[0]))

func _sentArgs(sends : Array) -> Array:
	return [] if sends.is_empty() else (_lastSend(sends)[1] as Array)

# Acesso por índice que não estoura quando o envio esperado nem aconteceu: um
# handler quebrado deve FALAR vermelho no check, não derrubar o harness inteiro
# com um index-out-of-bounds no meio da suíte (mordida clássica de driver de UI).
func _sentArg(sends : Array, index : int) -> int:
	var args : Array = _sentArgs(sends)
	return 0 if index >= args.size() else int(args[index])

func _argsEq(sends : Array, expected : Array) -> bool:
	return _sentArgs(sends) == expected

func _hasSend(sends : Array, methodName : String) -> bool:
	for e in sends:
		if str((e as Array)[0]) == methodName:
			return true
	return false

# Preenche o estado que o painel leria de uma janela do servidor SEM passar por
# ShowState (que re-renderiza e emite sozinho): para os drives de clique queremos
# a mesa posta e o log de envios ZERADO antes de cada tecla.
func _seedBlock(panel : Object, rows : int, total : int, gold : int) -> void:
	var listings : Array = []
	for i in rows:
		listings.append({"id" = 100 + i, "item_id" = 5001, "name" = "Blade", "price_gold" = 120, "count" = 1, "mine" = false})
	var state : Dictionary = {"ok" = true, "gold" = gold, "gems" = 5000, "listings" = listings, "total" = total, "offset" = 0, "page_size" = 40, "orders" = [], "sold" = {}, "sold_recent" = []}
	panel.set("_state", state)
	panel.set("_listings", listings)
	panel.set("_shownOffset", 0)
	_resetAsk(panel)

func _resetAsk(panel : Object) -> void:
	panel.set("_askedOffset", 0)
	panel.set("_askedMaxPrice", 0)
	panel.set("_askedItemID", 0)
	panel.set("_maxPrice", 0)
	panel.set("_page", 0)

# ------------------------------------------------------------------ (B) disparo
func _suiteDispatch() -> void:
	print("-- B) cada clique manda o alvo certo para a rua")
	var ctx : Dictionary = _spawnInTree()
	if ctx.is_empty():
		Check(false, "painel montado na árvore (dispatch)")
		return
	var panel : Object = ctx["panel"]
	var sends : Array = ctx["sends"]
	Check(panel.get("_listBox") != null, "a árvore do formulário montou a vitrine (_listBox)")

	# --- paginar atravessa BLOCO: com um bloco de 40 entregue e o cursor na última
	# página local, a seta PEDS a próxima janela AO SERVIDOR com offset = page_size.
	# O antigo "1/1" nunca emite aqui — é o que faz 40 ser tamanho de página, não
	# teto do catálogo.
	_seedBlock(panel, 40, 41, 100000)
	panel.set("_page", 4)
	sends.clear()
	Callable(panel, "_on_page_pressed").call(1)
	CheckStrEq(_sentName(sends), "GetAuctionPage", "Next na borda do bloco pede GetAuctionPage ao servidor")
	CheckEq(_sentArg(sends, 0), 40, "com offset = tamanho da janela do servidor (40)")

	# --- o teto de preço digitado é PEDIDO ao servidor (WHERE price_gold<=?), não
	# um recorte silencioso do que já chegou.
	_seedBlock(panel, 5, 5, 100000)
	sends.clear()
	Callable(panel, "_on_max_price_changed").call("150")
	CheckStrEq(_sentName(sends), "GetAuctionPage", "mudar o teto de preço requery o servidor (filtro SQL)")
	CheckEq(_sentArg(sends, 1), 150, "levando o maxPrice pedido como argumento")

	# --- as três ações da migração, com o freio de confirmação: armar NÃO emite;
	# só ConfirmPending emite.
	_resetAsk(panel)
	panel.set("_state", {"ok" = true, "gold" = 100000, "gems" = 5000, "orders" = [], "bid_cap" = 5, "bid_max_quantity" = 99, "listings" = [], "total" = 0, "offset" = 0, "page_size" = 40})
	sends.clear()
	Check(bool(Callable(panel, "RequestBid").call(5001, 2, 50)), "RequestBid de escrow 100 com saldo 100000 arma")
	CheckEq(_pendingCount(panel), 1, "RequestBid arma exatamente uma pendência")
	CheckEq(sends.size(), 0, "armar a bid NÃO fala com a rede (gasto irreversível atrás de confirmação)")
	CheckStrEq(str(Callable(panel, "PendingMethod").call()), "AuctionBid", "a pendência é do alvo AuctionBid")
	Callable(panel, "ConfirmPending").call()
	CheckStrEq(_sentName(sends), "AuctionBid", "confirmar a bid emite AuctionBid")
	Check(_sentArgs(sends) == [5001, 2, 50] as bool, "com (item, qtd, teto) na ordem exata (got %s)" % str(_sentArgs(sends)))

	# recusa de escrow: bid acima do teto de quantidade NÃO arma (não emite, não
	# pendura) — a UI não reimplementa a regra, mas lê o teto do payload.
	_resetAsk(panel)
	sends.clear()
	Check(not bool(Callable(panel, "RequestBid").call(5001, 500, 50)), "RequestBid acima de bid_max_quantity é recusado")
	CheckEq(_pendingCount(panel), 0, "a recusa não deixa pendência")
	CheckEq(sends.size(), 0, "a recusa não emite")

	sends.clear()
	panel.set("_state", {"ok" = true, "orders" = [{"id" = 77, "item_id" = 5001, "escrow_gold" = 100, "mine" = true}, {"id" = 78, "item_id" = 5001, "escrow_gold" = 100, "mine" = false}]})
	Check(not bool(Callable(panel, "RequestBidCancel").call(78)), "cancelar ordem NÃO-minha é recusado (o servidor decide a linha)")
	CheckEq(sends.size(), 0, "a recusa de cancelar ordem alheia não emite")
	Check(bool(Callable(panel, "RequestBidCancel").call(77)), "RequestBidCancel de ordem da conta arma")
	CheckEq(sends.size(), 0, "armar o cancelamento NÃO emite")
	Callable(panel, "ConfirmPending").call()
	CheckStrEq(_sentName(sends), "AuctionBidCancel", "confirmar o cancelamento emite AuctionBidCancel")
	Check(_sentArgs(sends) == [77] as bool, "com o id da ordem que o servidor deu")

	# --- compra da linha alheia fecha o caminho AuctionBuy; comprar a PRÓPRIA
	# linha não arma (o mesmo veto de self-dealing que o serviço aplica no settle).
	_resetAsk(panel)
	panel.set("_state", {"ok" = true, "gold" = 100000, "gems" = 5000, "creator_fee_pct" = 5, "orders" = [], "listings" = [], "total" = 0, "offset" = 0, "page_size" = 40})
	panel.set("_listings", [{"id" = 9, "item_id" = 5001, "name" = "Blade", "price_gold" = 40, "price" = 40, "qty" = 1, "mine" = false}])
	panel.set("_selected", 9)
	sends.clear()
	Check(bool(Callable(panel, "RequestBuy").call(9)), "RequestBuy de linha alheia arma")
	Callable(panel, "ConfirmPending").call()
	CheckStrEq(_sentName(sends), "AuctionBuy", "comprar emite AuctionBuy")
	sends.clear()
	panel.set("_listings", [{"id" = 9, "item_id" = 5001, "name" = "Blade", "price_gold" = 40, "price" = 40, "qty" = 1, "mine" = true}])
	Check(not bool(Callable(panel, "RequestBuy").call(9)), "RequestBuy da PRÓPRIA linha não arma (no self-deal na UI)")
	CheckEq(sends.size(), 0, "e não emite")

	# --- NEGATIVO: um nome fora da tabela NÃO pode sair pela rua nem ser anotado
	# (é exatamente o buraco que o SendHook do teste antigo escondia).
	sends.clear()
	var before : int = (panel.get("SentTargets") as Array).size()
	Callable(panel, "_send").call("Network.SelfDestruct", [] as Array)
	CheckEq(sends.size(), 0, "alvo fora da tabela não chega ao hook (portão de nomes)")
	CheckEq((panel.get("SentTargets") as Array).size(), before, "alvo fora da tabela não entra no rastro de envios")

	_clearGui(launcher())
	panel.free()

func _pendingCount(panel : Object) -> int:
	return int(panel.call("PendingCount"))

func launcher() -> Node:
	return _autoload("Launcher")

func CheckStrEq(value : String, expected : String, label : String) -> bool:
	return Check(value == expected, "%s (got '%s', want '%s')" % [label, value, expected])

func _clearGui(l : Node) -> void:
	if l == null:
		return
	var gui : Node = l.get("GUI")
	if gui != null:
		var msg : Node = gui.get("messageBox")
		if msg != null and msg.has_method("Clear"):
			msg.call("Clear")

# ------------------------------------------------------------------ (C) render servido
# O histórico realizado e as ordens em pé que o jogador vê VÊM do payload do
# servidor. Se alguém voltar a pintar de memória de sessão, os rótulos deixam de
# citar os números que colocamos na janela e estes checks caem.
func _suiteRender() -> void:
	print("-- C) preço realizado e ordens chegam ao jogador pela janela do servidor")
	var ctx : Dictionary = _spawnInTree()
	if ctx.is_empty():
		Check(false, "painel montado na árvore (render)")
		return
	var panel : Object = ctx["panel"]
	var state : Dictionary = {
		"ok" = true, "gold" = 777, "gems" = 88, "open" = 1, "cap" = 3, "total" = 41, "offset" = 0, "page_size" = 40,
		"listings" = [{"id" = 12, "item_id" = 5001, "name" = "Blade", "price_gold" = 123, "count" = 2, "mine" = false}],
		"sold_recent" = [{"count" = 3, "unit_price" = 91}],
		"sold" = {"samples" = 7, "avg_unit" = 95, "ask_unit" = 80},
		"orders" = [{"id" = 42, "item_id" = 5001, "item_name" = "Blade", "quantity" = 4, "unit_price" = 90, "escrow_gold" = 360, "mine" = true}],
	}
	Callable(panel, "ShowState").call(state)

	var refs : Dictionary = panel.get("_refs") as Dictionary
	var history : Label = refs.get("history", null) as Label
	var orders : Label = refs.get("orders", null) as Label
	var balance : Label = refs.get("balance", null) as Label
	Check(history != null and history.text.contains("91"), "o rótulo de 'sold' cita o preço realizado do servidor (unit_price 91) — got '%s'" % (history.text if history != null else "nil"))
	Check(history != null and history.text.contains("95"), "e a média realizada (avg_unit 95)")
	Check(orders != null and orders.text.contains("42"), "o rótulo de ordens mostra a ordem em pé #42 do servidor")
	var orderBox : VBoxContainer = refs.get("orderBox", null) as VBoxContainer
	var rowText : String = ""
	if orderBox != null:
		for child in orderBox.get_children():
			if String(child.name) == "AuctionOrder_42":
				rowText = str(child.get("text"))
	Check(not rowText.is_empty(), "cada ordem ganha uma linha clicável (AuctionOrder_42) para cancelar")
	Check(rowText.contains("360") and rowText.contains("90"), "a linha declara o escrow (360) e o teto/unidade (90) linha a linha — got '%s'" % rowText)
	Check(balance != null and balance.text.contains("360"), "o saldo anuncia o ouro em escrow (360) que não é gastável")

	# Não-uso do RecordSale de sessão: o painel novo NÃO pinta histórico da memória
	# antiga; sem `sold_recent` o rótulo diz "nothing on record", não um eco local.
	var refs2 : Dictionary = panel.get("_refs") as Dictionary
	Callable(panel, "ShowState").call({"ok" = true, "gold" = 1, "gems" = 1, "listings" = [], "total" = 0, "offset" = 0, "page_size" = 40, "orders" = [], "sold" = {}, "sold_recent" = []})
	var hist2 : Label = (refs2.get("history", null) as Label)
	Check(hist2 != null and hist2.text.contains("nothing on record"), "sem histórico no servidor, o rótulo é honesto (não eco de sessão)")
	panel.free()

func _finish():
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
