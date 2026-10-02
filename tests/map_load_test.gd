extends SceneTree

# SOM-MAP (auditoria 2026-09-28): a corrente de carga do mapa. O `Client.gd:56` chama
# `EmplaceMapNode(mapID)` em todo warp, e o que o jogador vê depende de quatro elos que
# acontecem dentro de `Map.LoadMapNode`: a instância nasce, a franja é achada, o nó entra
# na árvore sob `Launcher`, e `MapLoaded` dispara (o único consumidor é
# `Camera.gd:130-131`, que define a fronteira). Cada elo é um check separado porque foi
# exatamente assim que a corrente se quebrou sem ninguém ver: a reescrita mecânica de
# `0c5cb56` ("Replace assert() with production-safe validation across 20+ files") moveu o
# corpo de `if currentMapNode:` para dentro de `if currentMapNode == null:`, e o caminho
# feliz parou de adicionar o nó e de emitir o sinal — nenhum teste olhava a árvore, e o
# log do portão não tinha como saber, porque a função simplesmente não fazia nada.
#
# A régua vem nos dois sentidos: um mapa real tem que acender todos os elos, e um id sem
# camada tem que falhar limpo — sem sinal de sucesso, sem gravar `currentMapID` (o
# sentinela `DB.UnknownHash` é o que `Warped` (`Minimap.gd:@Warped`) lê como "sem mapa", e um id gravado
# para um mapa inexistente faria `EmplaceMapNode` (`Map.gd:@EmplaceMapNode`) sair cedo no `not force` em toda
# tentativa seguinte). Sem a metade negativa, "1 emissão" pode ser um sinal que dispara
# para qualquer coisa.
#
# Uso: godot --headless --path . -s tests/map_load_test.gd
# Exit code: nº de checks falhos. Última linha: `== RESULT: N checks, M failures ==`.
#
# Como todo harness `-s`: nada de identificador de autoload (Launcher/DB/...) nem
# class_name de projeto em anotação de tipo aqui — as instâncias vêm por
# root.get_node_or_null()/get()/call(), e as constantes por `get_script_constant_map()`.

var _checks : int = 0
var _fails : int = 0
var _dbScript : GDScript = null
var _launcher : Node = null
var _map : Node = null
var _pool : Node = null
var _mapLoaded : int = 0
var _mapUnloaded : int = 0

func Check(condition : bool, label : String) -> bool:
	_checks += 1
	if not condition:
		_fails += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckI(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func _initialize():
	_run()

func _OnMapLoaded() -> void:
	_mapLoaded += 1

func _OnMapUnloaded() -> void:
	_mapUnloaded += 1

# A franja é o filho `TileMapLayer` chamado "Fringe" — o mesmo predicado de
# `Map.RefreshTileMap()`, reimplementado aqui de propósito: comparar o estado do serviço
# com uma varredura independente do nó é o que prova que `RefreshTileMap()` rodou.
func _FindFringe(node : Node) -> Node:
	if node == null:
		return null
	for child in node.get_children():
		if child is TileMapLayer and (child as Node).name == &"Fringe":
			return child
	return null

func _finish() -> void:
	# Mesma defensa dos harnesses que saem limpos: o join dos loads threadados do DB com
	# a árvore já morrendo é o caminho do SIGSEGV de boot (Launcher.gd:254-258).
	if _dbScript != null and (_dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		_dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [_checks, _fails])
	quit(_fails)

func _run() -> void:
	print("== SOM-MAP load chain test ==")
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	if _launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return

	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = _launcher.get("SQL")
		var worldNode : Node = _launcher.get("World")
		if sqlNode != null and sqlNode.get("isInitialized") and worldNode != null and worldNode.get("isInitialized"):
			break
	print("== boot wait done (%d ms) ==" % waited)

	_dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for tick in 40:
		if _dbScript != null and bool(_dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "preload threadado do DB drenado antes de mexer em MapsDB"):
		_finish()
		return

	_map = _launcher.get("Map")
	# `Map` NÃO está na árvore e isso é projeto, não acidente: o corpo de `Client`
	# (`sources/launcher/Launcher.gd:@Client`) registra que só `Action` é add_child'ado ali.
	# O que tem que estar na árvore é o Nó
	# do mapa, que `LoadMapNode` pendura em `Launcher`. Exigir árvore no serviço seria
	# acusar o desenho; aceitar um serviço nulo seria não exigir nada.
	if not Check(_map != null and bool(_map.get("isInitialized")), "Launcher.Map é o serviço vivo e pós-launch no client headless"):
		_finish()
		return
	_map.connect("MapLoaded", Callable(self, "_OnMapLoaded"))
	_map.connect("MapUnloaded", Callable(self, "_OnMapUnloaded"))
	_pool = _map.get("pool")
	if not Check(_pool != null and bool(_pool.has_method("FreeMap")), "`Map.pool` é o MapPool vivo, com `FreeMap` — o harness libera o que percorre"):
		_finish()
		return

	# ------------------------------------------------------------- 0. o censo, derivado
	var consts : Dictionary = _dbScript.get_script_constant_map()
	if not Check(consts.has("UnknownHash"), "`DB.UnknownHash` é lido do fonte, não copiado para cá"):
		_finish()
		return
	var unknownHash : int = int(consts["UnknownHash"])
	var maps : Dictionary = _dbScript.get("MapsDB") as Dictionary
	var ids : Array = maps.keys()
	ids.sort()
	if not Check(ids.size() >= 5, "MapsDB tem %d mapas — abaixo disso o censo abaixo não julgaria nada" % ids.size()):
		_finish()
		return

	var comCamada : Array[int] = []
	var semCamada : Array[int] = []
	for idV in ids:
		var id : int = int(idV)
		var data : Object = maps[id]
		if String(data.get("layersPath")).is_empty():
			semCamada.append(id)
		else:
			comCamada.append(id)
	if not Check(comCamada.size() >= 2, "%d dos %d mapas têm `layersPath` — a corrente é medida em mapa de verdade" % [comCamada.size(), ids.size()]):
		_finish()
		return
	CheckI(int(_map.get("currentMapID")), unknownHash, "no boot, sem mapa em lugar nenhum")
	Check(_map.get("currentMapNode") == null, "no boot, `currentMapNode` é nulo")

	# ----------------------------------------------------- 1. caminho feliz, elo por elo
	var franjaVista : int = 0
	var released : int = 0
	for id : int in comCamada:
		var loadedAntes : int = _mapLoaded
		var mapName : String = String((maps[id] as Object).get("_name"))
		_map.call("EmplaceMapNode", id)
		var node : Node = _map.get("currentMapNode")
		if not Check(node != null, "mapa %s (%d): a instância nasceu" % [mapName, id]):
			continue
		Check(bool(node.is_inside_tree()), "mapa %s: o nó está NA ÁRVORE — elo que a inversão de guarda apagou" % mapName)
		Check(node.get_parent() == _launcher, "mapa %s: o pai é o Launcher, como jura `Launcher.add_child`" % mapName)
		Check(bool(node.is_visible_in_tree()), "mapa %s: visível na árvore (ninguém desenha mapa órfão)" % mapName)
		CheckI(int(_map.get("currentMapID")), id, "mapa %s: `currentMapID` acompanha o mapa em pé" % mapName)
		CheckI(_mapLoaded, loadedAntes + 1, "mapa %s: `MapLoaded` disparou exatamente uma vez (fronteira da câmera)" % mapName)
		var fringe : Node = _map.get("currentFringe")
		var achada : Node = _FindFringe(node)
		if achada != null:
			franjaVista += 1
		Check(fringe == achada, "mapa %s: `currentFringe` bate com o nó (%s) — `RefreshTileMap()` rodou" % [mapName, "achada" if achada != null else "sem Fringe"])

		# Idempotência: o `not force` de :35 é o que evita recarregar o mapa do warp
		# repetido; se ele vazar, cada passo do jogador recompõe a cena inteira.
		var antesIdem : int = _mapLoaded
		_map.call("EmplaceMapNode", id)
		CheckI(_mapLoaded, antesIdem, "mapa %s: re-emplacar o MESMO id não recarrega" % mapName)

		# Force: o nó volta (o pool devolve a mesma instância), mas sai e entra de novo —
		# e não sobra um segundo nó do mapa pendurado no Launcher.
		var antesForce : int = _mapLoaded
		var noArvore : int = 0
		_map.call("EmplaceMapNode", id, true)
		for child in _launcher.get_children():
			if child == node or (child != null and child.name == node.name):
				noArvore += 1
		CheckI(_mapLoaded, antesForce + 1, "mapa %s: `force` recarrega e reavisa" % mapName)
		CheckI(noArvore, 1, "mapa %s: exatamente um nó de mapa sob o Launcher depois do force" % mapName)

		# Solta o mapa percorrido antes do próximo. Não é limpeza cosmética: um harness
		# que percorre os 40 mapas do DB e deixa todos no `pool` vaza dezenas de milhares
		# de instâncias, e o teto de teardown do portão (`scripts/ci_gate_log.sh:108`) é
		# justamente a régua que não deixa um harness novo entrar verde-e-vazando.
		# FreeMap também é a única porta do `MapPool` que este harness exercita.
		_map.call("UnloadMapNode")
		_pool.call("FreeMap", id)
		Check(_pool.call("GetMap", id) == null, "mapa %s: o pool devolve o que foi liberado (sem isso, o pool é um vazamento com nome)" % mapName)
		Check(_map.get("currentMapNode") == null, "mapa %s: descarga zera `currentMapNode`" % mapName)
		Check(_map.get("currentFringe") == null, "mapa %s: descarga zera `currentFringe`" % mapName)
		released += 1
		await create_timer(0.05).timeout

	# --------------------------------------------------- 2. troca de mapa não deixa resíduo
	if comCamada.size() >= 2:
		var a : int = comCamada[0]
		var b : int = comCamada[1]
		_map.call("EmplaceMapNode", a)
		var nodeA : Node = _map.get("currentMapNode")
		var antesTroca : int = _mapLoaded
		var antesSaida : int = _mapUnloaded
		_map.call("EmplaceMapNode", b)
		Check(nodeA != null and not bool(nodeA.is_inside_tree()), "troca de mapa: o nó anterior saiu da árvore (não empilha cena)")
		CheckI(_mapUnloaded, antesSaida + 1, "troca de mapa: `MapUnloaded` disparou uma vez")
		CheckI(_mapLoaded, antesTroca + 1, "troca de mapa: o novo mapa avisou a câmera")
		Check(_map.get("currentMapNode") != null and bool((_map.get("currentMapNode") as Node).is_inside_tree()), "troca de mapa: o novo nó está na árvore")

	# ------------------------------------------------- 3. o fracasso tem que ser limpo
	var bogus : int = String("mapa_que_nao_existe_no_db").hash()
	Check(not maps.has(bogus), "controle: o id plantado não está em MapsDB (senão a metade negativa não testa falha)")
	var antesFail : int = _mapLoaded
	var poolAntesFail : int = (_pool.get("pool") as Dictionary).size()
	_map.call("EmplaceMapNode", bogus)
	Check(_map.get("currentMapNode") == null, "mapa inexistente: nada é empurrado para a árvore")
	# A chave fantasma é o defeito que o teto do pool esconde: `RefreshPool` decide se
	# tenta um adjacente por `mapID not in pool`, e `ClearUnused` conta a chave no tamanho
	# sem poder apagá-la (não há nó). Um mapa que falhou uma vez ficava proibido de carregar
	# de novo, e o teto `MapPoolMaxSize` ficava estourado para sempre.
	CheckI((_pool.get("pool") as Dictionary).size(), poolAntesFail, "mapa inexistente: o pool não ganha chave fantasma (%d antes, %d depois)" % [poolAntesFail, (_pool.get("pool") as Dictionary).size()])
	CheckI(int(_map.get("currentMapID")), unknownHash, "mapa inexistente: `currentMapID` fica no sentinela, não no id pedido")
	CheckI(_mapLoaded, antesFail, "mapa inexistente: NENHUM sinal de sucesso — é o veredito errado que a régua caça")
	# O motivo de o sentinela importar: com o id gravado, o retry sai cedo no `not force`
	# e o jogador fica sem mapa para sempre. Sem ele, o mesmo warp tenta de novo de fato.
	_map.call("EmplaceMapNode", comCamada[0])
	Check(_map.get("currentMapNode") != null and bool((_map.get("currentMapNode") as Node).is_inside_tree()), "depois de uma falha, o retry do mapa real carrega (o sentinela é o que destrava isto)")
	if not semCamada.is_empty():
		var antesNoPath : int = _mapLoaded
		_map.call("EmplaceMapNode", semCamada[0])
		CheckI(_mapLoaded, antesNoPath, "%d mapa(s) sem `layersPath` no DB também não emitem sucesso" % semCamada.size())

	# ------------------------------------------- 4. controle do predicado de franja
	var sint : Node2D = Node2D.new()
	var camada : TileMapLayer = TileMapLayer.new()
	camada.name = &"Fringe"
	sint.add_child(camada)
	Check(_FindFringe(sint) == camada, "controle: o predicado de franja acha a camada plantada")
	var semFringe : Node2D = Node2D.new()
	var outra : TileMapLayer = TileMapLayer.new()
	outra.name = &"Outra"
	semFringe.add_child(outra)
	Check(_FindFringe(semFringe) == null, "controle: o predicado de franja NÃO acha o que não é Fringe")
	Check(_FindFringe(null) == null, "controle: o predicado de franja trata nó nulo sem explodir")
	sint.free()
	semFringe.free()

	print("  [info] mapa: %d mapas no DB, %d com camada percorridos e liberados, %d com Fringe, %d sem camada" % [ids.size(), released, franjaVista, semCamada.size()])
	# Drena o que os testes 2 e 3 deixaram em pé: o `pool` guarda instância de mapa mesmo
	# fora da árvore, e um harness que percorre cenas tem que devolver o que pegou — é a
	# mesma disciplina que a régua de teardown cobra de todo harness do portão.
	_map.call("UnloadMapNode")
	var still : Dictionary = _pool.get("pool") as Dictionary
	for k in still.keys():
		_pool.call("FreeMap", int(k))
	await create_timer(0.1).timeout
	CheckI((_pool.get("pool") as Dictionary).size(), 0, "drenagem: nenhum mapa sobrou no pool ao sair (%d liberados no laço principal)" % released)
	_finish()
