extends SceneTree

# SOM-CONTENT: régua de higiene de conteúdo (juiz 2026-09-27: "os sistemas
# correm na frente do conteúdo"). Quatro classes de defeito que HOJE nada lê no
# portão:
#
#  (0) CATÁLOGO PELA METADE — `.tres` de entidade que não chega ao `EntitiesDB`.
#      A fonte desta régua é o DIRETÓRIO, não o dicionário: quem só olha o
#      `EntitiesDB` julga o que sobreviveu ao parse. Ver `_suiteEntityCensus`.
#
#  (1) ROSTER SUJO — zona apontando para um spawn cujo id não existe no
#      EntitiesDB. Medido no dump de 24 zonas: a zona 17 (Drazil) renderizava
#      "? L0 x17" — 16 grupos de spawn (17 mobs no censo) com dois ids fantasmas
#      (3851394706, 4085786187), sem nome, sem nível, sem XP de matar e sem
#      sprite. Isso não é bug de render: é o jogador clicando num nada.
#      Agora: todo grupo de mob de toda zona tem de resolver para uma entidade
#      com nome, nível > 0 e contagem > 0.
#
#  (2) FAIXA DE DROP NASCIDA VAZIA — FarmZoneData.GetDropPool confessava um
#      fallback ("band empty → desce um tier → senão Apple"). Medido: tiers 6, 7
#      e 8 não tinham UM item, então 9 das 24 zonas lootavam item de tier
#      errado. O fallback foi deletado e as faixas cheias com conteúdo real.
#      Agora: a pool de cada zona É exatamente o conjunto de itens da própria
#      faixa — e um item fora da faixa (ou o Apple-stand-in numa zona funda) é
#      falha. Desde SOM-CRAFT (2026-09-27) a faixa carrega duas classes — peça
#      vestível e matéria-prima (ItemCell.material) — e cobertura de material por
#      tier é conteúdo obrigatório; a PROPORÇÃO do roll é régua de
#      tests/balance_test.gd, que é dona das curvas.
#
#  (3) ESCADA — a perna nova de boss (índices 4..9) tem de ser conteúdo, não
#      string: entidade real no EntitiesDB, sala real no MapsDB e o MOB daquela
#      sala spawneado nela.
#
# Uso: godot --headless --path . -s tests/content_hygiene_test.gd
# Régua do gate = última linha `== RESULT: N checks, M failures ==` e o exit code.

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _dbScript : GDScript = null
var _farm : GDScript = null
var _bossService : GDScript = null
var _monsterType : int = 0

func _initialize():
	_run()

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(value : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: %s vs %s" % [label, str(value), str(expected)])
		return false
	return true

func _finish():
	if _dbScript != null:
		_dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

func _asInt(value : Variant) -> int:
	if value is int:
		return int(value)
	if value is float:
		return int(value)
	return 0

func _run():
	print("== content hygiene harness (censo de entidades + rosters + faixas de drop + escada de boss) ==")
	_launcher = root.get_node_or_null(^"Launcher")
	if _launcher == null:
		print("FATAL: Launcher autoload missing")
		_finish()
		return
	var waited : int = 0
	var worldNode : Node = null
	while waited < 60000:
		await create_timer(0.25).timeout
		waited += 250
		worldNode = _launcher.World
		if worldNode != null and worldNode.isInitialized and _launcher.SQL != null and _launcher.SQL.isInitialized:
			break
	print("== boot wait done (waited %d ms) ==" % waited)

	_dbScript = load("res://sources/db/DB.gd")
	_farm = load("res://sources/idle/FarmZoneData.gd")
	_bossService = load("res://sources/idle/BossService.gd")
	var commons : GDScript = load("res://sources/actor/ActorCommons.gd")
	_monsterType = int(commons.Type.MONSTER)

	var dbReady : bool = false
	for i in 80:
		if _dbScript.isInitialized:
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (entities/maps/items carregados)"):
		_finish()
		return
	if not _check(worldNode != null and worldNode.isInitialized, "World inicializado (rosters lidos em runtime)"):
		_finish()
		return

	_farm.SyncWithDB()
	_suiteEntityCensus()
	_suiteRosters(worldNode)
	_suiteDropBands()
	_suiteBossLadder(worldNode)
	_suiteSpawnSource()

# ------------------------------------------------------- (0) censo do EntitiesDB

# O predicates da acusação, soltos do laço para poderem ser controlados.
func _censusDrops(ids : Array, db : Dictionary) -> int:
	var drops : int = 0
	for id in ids:
		if not db.has(id):
			drops += 1
	return drops

func _censusDupes(ids : Array) -> int:
	var seen : Dictionary = {}
	var dupes : int = 0
	for id in ids:
		if seen.has(id):
			dupes += 1
		else:
			seen[id] = true
	return dupes

# Por que esta suíte existe: `DB.ParseEntitiesDB` varre `presets/entities/` e, se
# um `.tres` traz `_id` diferente de `_name.hash()`, ele é pulado com `push_error`.
# Até 2026-09-28 aquele ramo era `return`, não `continue` — legado da reescrita de
# `0c5cb56` — então o PRIMEIRO `.tres` com id stale abortava o parse e toda entidade
# depois dele sumia do catálogo sem nenhuma outra pista no log. Nenhuma régua lia o
# diretório: as suítes olhavam o que já estava no `EntitiesDB` (roster, escada de
# boss), e catálogo incompleto é exatamente o que esse tipo de leitura não enxerga,
# porque ela julga apenas o que sobreviveu. Aqui a fonte é o DIRETÓRIO, não o dicionário.
func _suiteEntityCensus():
	print("[suite] censo: todo .tres de entidade do diretório está no EntitiesDB")
	var pathScript : GDScript = load("res://sources/system/Path.gd")
	var fsScript : GDScript = load("res://sources/system/FileSystem.gd")
	var entityPst : String = str(pathScript.get_script_constant_map().get("EntityPst", ""))
	if not _check(not entityPst.is_empty() and entityPst.ends_with("/"), "Path.EntityPst é legível pelo harness (%s) — sem ele o censo varreria um caminho vazio e daria verde" % entityPst):
		_finish()
		return
	var files : PackedStringArray = fsScript.call("ParseResources", entityPst)
	_check(files.size() > 0, "o diretório de entidades lista arquivos (%d encontrados)" % files.size())

	var ids : Array = []
	var scanned : int = 0
	for filePath in files:
		var resource : Object = fsScript.call("LoadResource", filePath, false)
		# Nenhum `is EntityData` / `: EntityData` aqui, e isso é projeto do harness, não
		# estilo: amarrar o nome global de um recurso ao script do `SceneTree` coloca a
		# árvore de dependências dele no COMPILE do main loop, que roda antes dos
		# autoloads — e o boot inteiro cai com `Compile Error: Identifier not found:
		# Launcher` em `Peers.gd`, `DB.gd`, `World.gd` (medido 2026-09-28: 25 erros, e o
		# harness nunca chegava ao `DB.isInitialized`). O nome global lido do script dá a
		# mesma classificação sem esse vínculo de compilação.
		if resource == null or resource.get_script() == null:
			continue
		if str((resource as Object).get_script().get_global_name()) != "EntityData":
			continue
		var entityName : String = str(resource.get("_name"))
		var entityId : int = int(resource.get("_id"))
		var expect : int = int(entityName.hash())
		scanned += 1
		_check(entityId == expect and expect != int(_dbScript.UnknownHash),
			"entidade '%s' (%s): `_id` (%d) é o hash de `_name` (%d) — senão o parse a pula" % [entityName, filePath, entityId, expect])
		ids.append(expect)

	var db : Dictionary = _dbScript.EntitiesDB
	print("  [info] censo: %d arquivos de entidade no diretório, %d chaves no EntitiesDB" % [scanned, db.size()])
	# O piso é folga, não régua: 96 arquivos/96 chaves medidos verdes em 2026-09-28, e
	# quem pega drop de verdade são as duas réguas de baixo. A mordida também é medida:
	# trocando um dígito do `_id` de `presets/entities/Andi.tres`, o harness acusou
	# exatamente 3 falhas (a linha da entidade, `1 de fora`, `95 vs 96`) e saiu exit 3.
	_check(scanned >= 90, "o censo varreu conteúdo real, não um diretório vazio (%d entidades)" % scanned)
	_checkEq(_censusDupes(ids), 0, "censo: nenhum `_id` duplicado entre as %d entidades do diretório" % scanned)
	_checkEq(_censusDrops(ids, db), 0, "censo: toda entidade do diretório está no EntitiesDB (%d varridas, %d de fora)" % [scanned, _censusDrops(ids, db)])
	_checkEq(db.size(), scanned, "censo: |EntitiesDB| == número de arquivos de entidade varridos (sem drop nem chave órfã)")

	# Controles nos dois sentidos: sem eles as quatro réguas acima são a frase que
	# sai de uma varredura que não olhou nada.
	var sampleIds : Array = [101, 202, 303]
	var sampleDb : Dictionary = {101: true, 202: true, 303: true}
	_checkEq(_censusDrops(sampleIds, sampleDb), 0, "controle: censo completo não acusa nada")
	# O dicionário capado é escrito chave por chave, não por remoção de uma chave do
	# `sampleDb`: a régua D1 de tests/aggro_cap_test.gd varre `tests/` procurando a
	# forma «erase com literal inteiro» e não distingue o receptor — ela caça o no-op
	# de tirar por índice de uma Array de Dictionaries, e um controle que só existe
	# usando a forma proibida é o controle errado.
	var doctored : Dictionary = {101: true, 303: true}
	_checkEq(_censusDrops(sampleIds, doctored), 1, "controle: uma entidade a menos no dicionário É acusada — é o shape do `return` que sumia com o resto do catálogo")
	_checkEq(_censusDupes([5, 5, 6]), 1, "controle: `_id` repetido É acusado")
	_checkEq(_censusDupes([5, 6]), 0, "controle: ids distintos não acusam")

# ------------------------------------------------------------------ (1) rosters

# Varre o roster RESOLVIDO de cada zona (mesmo caminho do dump_calibration: o
# WorldMap runtime, não o texto do .tres) e falha na classe do defeito: nome
# vazio, nível <= 0 ou contagem <= 0.
func _suiteRosters(worldNode : Node):
	print("[suite] rosters: toda zona tem mapa, todo mob resolve")
	var zoneCount : int = int(_farm.ZONE_COUNT)
	_checkEq(int(_farm.GetZoneCount()), zoneCount, "catálogo construído com ZONE_COUNT zonas")
	var species : Dictionary = {}
	var ghostGroups : int = 0
	var maxLevelByZone : Dictionary = {}
	for z in range(1, zoneCount + 1):
		var zone = _farm.GetZone(z)
		if not _check(zone != null, "zona %d existe no catálogo" % z):
			continue
		_check(zone.mapID != _dbScript.UnknownHash, "zona %d resolve para mapa real (%s)" % [z, str(zone.mapName)])
		var worldMap = worldNode.GetMap(zone.mapID)
		if not _check(worldMap != null, "zona %d: mapa %s carregado no runtime" % [z, str(zone.mapName)]):
			continue
		var groups : int = 0
		for spawn in worldMap.spawns:
			if spawn == null:
				_check(false, "zona %d: grupo de spawn nulo" % z)
				continue
			if int(spawn.type) != _monsterType:
				continue
			groups += 1
			var count : int = _asInt(spawn.count)
			var entity = _dbScript.EntitiesDB.get(int(spawn.id), null)
			var ename : String = str(entity._name) if entity != null else ""
			if entity == null or ename.is_empty():
				ghostGroups += 1
				_check(false, "zona %d (%s): spawn id %d NÃO resolve para entidade (nome vazio)" % [z, str(zone.mapName), int(spawn.id)])
				continue
			var merged = entity.GetMergedEntity() if entity.has_method("GetMergedEntity") else entity
			var level : int = _asInt(merged._stats.get("level", 0))
			_check(level > 0, "zona %d: mob '%s' (id %d) tem nível > 0 (achado %d)" % [z, ename, int(spawn.id), level])
			_check(count > 0, "zona %d: mob '%s' spawnado com contagem > 0 (achado %d)" % [z, ename, count])
			maxLevelByZone[z] = maxi(int(maxLevelByZone.get(z, 0)), level)
			species[ename] = true
		_check(groups > 0, "zona %d (%s) tem ao menos um grupo de mob" % [z, str(zone.mapName)])
	_checkEq(ghostGroups, 0, "nenhum grupo de spawn fantasma em nenhuma zona (classe do '? L0 x17' da zona 17)")
	_check(species.size() >= 27, "o farm usa >= 27 espécies distintas (antes da perna nova eram 24; medido: %d)" % species.size())
	for wanted : String in ["Lynx", "Goblin", "Bandit"]:
		_check(species.has(wanted), "espécie nova %s entrou no roster de farm" % wanted)
	# Fim de jogo não pode ser skin de zona rasa: o topo do roster de cada zona do
	# tier fundo está pelo menos no nível do topo da zona que era o fundo da escada
	# antes (24). Medido do runtime, não do catálogo.
	var oldTop : int = int(maxLevelByZone.get(zoneCount - int(_farm.ZonesPerTier), 0))
	_check(oldTop > 0, "a antiga zona mais funda (%d) tem nível de mob medido (%d)" % [zoneCount - int(_farm.ZonesPerTier), oldTop])
	for deep in range(zoneCount - int(_farm.ZonesPerTier) + 1, zoneCount + 1):
		_check(int(maxLevelByZone.get(deep, 0)) >= oldTop,
			"zona %d: o roster do tier fundo tem mob de nível >= o antigo fundo da escada (%d >= %d)" % [deep, int(maxLevelByZone.get(deep, 0)), oldTop])

# ------------------------------------------------------------------ (2) faixas de drop

# Reproduz independently a faixa [tier, tier+band-1] e exige que a pool da zona
# seja EXATAMENTE esse conjunto (mais as templates de craft aprovadas, que tem
# faixa própria no SQL). Qualquer item fora da faixa — inclusive o Apple
# stand-in — é o fallback voltando a existir.
func _inBand(zone) -> Array[int]:
	var farmTier : int = int(zone.tier)
	var tierMax : int = mini(farmTier + int(_farm.DropTierBandSize) - 1, int(_farm.MAX_TIER))
	var out : Array[int] = []
	for cellHash in _dbScript.ItemsDB:
		var item = _dbScript.ItemsDB[cellHash]
		if item != null and int(item.tier) >= farmTier and int(item.tier) <= tierMax:
			out.append(int(cellHash))
	out.sort()
	return out

func _suiteDropBands():
	print("[suite] faixas de drop: nenhuma zona cai em fallback")
	var craftSet : Dictionary = {}
	if _launcher.SQL != null:
		var rows : Array = _launcher.SQL.QueryBindings("SELECT item_hash FROM craft_item_template;", [])
		for row in rows:
			craftSet[int(row.get("item_hash", 0))] = true
	var apple : int = int(_farm.DefaultDropItemHash)
	var tierOf : Dictionary = {}
	var nameOf : Dictionary = {}
	for cellHash in _dbScript.ItemsDB:
		var item = _dbScript.ItemsDB[cellHash]
		if item != null:
			tierOf[int(cellHash)] = int(item.tier)
			nameOf[int(cellHash)] = str(item.name)
	# Toda faixa da escada tem item de verdade (a raiz do defeito).
	# SOM-CRAFT: a faixa agora tem DUAS classes de conteúdo — peça vestível e
	# matéria-prima da forja — e as duas são conteúdo, não decoração. Cobertura de
	# material por tier entra aqui (proporção do roll é régua de
	# tests/balance_test.gd, que é dona das curvas).
	var materialTiers : Dictionary = {}
	for cellHash in _dbScript.ItemsDB:
		var item = _dbScript.ItemsDB[cellHash]
		if item != null and bool(item.material):
			materialTiers[int(item.tier)] = int(materialTiers.get(int(item.tier), 0)) + 1
	for t in range(1, int(_farm.MAX_TIER) + 1):
		var inTier : int = 0
		for h in tierOf.keys():
			if int(tierOf[h]) == t:
				inTier += 1
		_check(inTier > 0, "tier %d tem item próprio na pool (%d cells)" % [t, inTier])
		_check(int(materialTiers.get(t, 0)) > 0, "tier %d tem matéria-prima própria (%d cells)" % [t, int(materialTiers.get(t, 0))])
	var zoneCount : int = int(_farm.ZONE_COUNT)
	for z in range(1, zoneCount + 1):
		var zone = _farm.GetZone(z)
		if zone == null:
			continue
		var band : Array[int] = _inBand(zone)
		_check(not band.is_empty(), "zona %d (tier %d): faixa não vazia" % [z, int(zone.tier)])
		var pool : Array = _farm.GetDropPool(z)
		_checkEq(pool.size(), band.size(), "zona %d: pool == candidatos da faixa (fallback morto; pool tem %d)" % [z, pool.size()])
		for entry in pool:
			var h : int = int(entry)
			_check(int(tierOf.get(h, -1)) >= 0 or craftSet.has(h), "zona %d: pool entry %d é item conhecido" % [z, h])
			if not craftSet.has(h):
				_check(h in band, "zona %d: pool entry %s (tier %d) está na própria faixa" % [z, str(nameOf.get(h, "?")), int(tierOf.get(h, 0))])
		if int(zone.tier) > 1:
			_check(not pool.has(apple), "zona %d: Apple NÃO está na pool (era o stand-in do fallback)" % z)
		# Rolls reais: nada sai da faixa nem vira nulo.
		var tierMax : int = mini(int(zone.tier) + int(_farm.DropTierBandSize) - 1, int(_farm.MAX_TIER))
		for roll in range(0, 200):
			var pick : int = int(_farm.GetDropForRoll(z, roll))
			_check(pick > 0 and int(tierOf.get(pick, -1)) >= 0 or craftSet.has(pick), "zona %d roll %d: drop resolve para item real (%d)" % [z, roll, pick])
			if not craftSet.has(pick) and int(tierOf.has(pick)):
				var t : int = int(tierOf[pick])
				if t < int(zone.tier) or t > tierMax:
					_check(false, "zona %d roll %d: drop fora da faixa [%d,%d] — item %s tier %d" % [z, roll, int(zone.tier), tierMax, str(nameOf.get(pick, "?")), t])
	_check(not _farm.GetDropPool(999999).is_empty(), "zona inexistente devolve pool não vazia (guarda de registro corrompido, não de faixa)")

# ------------------------------------------------------------------ (3) escada de boss

func _mapIDByName(mapName : String) -> int:
	for mapID in _dbScript.MapsDB:
		var mapData = _dbScript.MapsDB[mapID]
		if mapData != null and str(mapData._name) == mapName:
			return int(mapID)
	return int(_dbScript.UnknownHash)

func _suiteBossLadder(worldNode : Node):
	print("[suite] escada: cada boss é entidade + arena + janela próprios")
	var names : Array = _bossService.BossNames
	var floors : Array = _bossService.BossFloorLevel
	var arenas : Array = _bossService.BossArenas
	var perfect : Array = _bossService.BossInterruptPerfectHalfWindow
	var good : Array = _bossService.BossInterruptGoodHalfWindow
	var bossMaps : Array = _farm.BossMapNames
	var count : int = names.size()
	_checkEq(int(_bossService.GetBossCount()), count, "GetBossCount == BossNames")
	_check(count >= 10, "a escada tem ao menos 10 bosses (medido: %d)" % count)
	for arr : Array in [floors, arenas, perfect, good, bossMaps]:
		_checkEq(arr.size(), count, "escada paralela tem o mesmo comprimento de BossNames (%d)" % count)
	var prevFloor : int = 0
	for i in count:
		var bossName : String = str(names[i])
		_check(not bossName.is_empty(), "boss %d tem nome" % i)
		_checkEq(str(bossMaps[i]) if i < bossMaps.size() else "", str(arenas[i]) if i < arenas.size() else "", "boss %d: sala idêntica em BossArenas e FarmZoneData.BossMapNames" % i)
		var floor : int = _asInt(floors[i])
		_check(floor > 0, "boss %d (%s) tem piso de nível > 0 (%d)" % [i, bossName, floor])
		_check(floor >= prevFloor, "boss %d: escada monotônica em piso de nível (%d >= %d)" % [i, floor, prevFloor])
		prevFloor = floor
		var entityHash : int = int(_bossService.GetBossEntityHash(i))
		if not _check(entityHash != int(_dbScript.UnknownHash), "boss %d (%s): entidade existe no EntitiesDB" % [i, bossName]):
			continue
		var arenaName : String = str(arenas[i])
		var arenaID : int = _mapIDByName(arenaName)
		if not _check(arenaID != int(_dbScript.UnknownHash), "boss %d: arena '%s' é mapa real do MapsDB" % [i, arenaName]):
			continue
		var arenaMap = worldNode.GetMap(arenaID)
		if not _check(arenaMap != null, "boss %d: arena '%s' carregada" % [i, arenaName]):
			continue
		var found : bool = false
		for spawn in arenaMap.spawns:
			if spawn != null and int(spawn.type) == _monsterType and int(spawn.id) == entityHash:
				found = true
		_check(found, "boss %d (%s): o mob está spawneado na arena '%s'" % [i, bossName, arenaName])
		var p : float = float(perfect[i])
		var g : float = float(good[i])
		# Comparação com tolerância: `InterruptPerfectMax - 0.5` em double dá
		# 0.09999999999999998, e a janela declarada 0.10 perderia por 1 ulp.
		var legacyHalf : float = float(_bossService.InterruptPerfectMax) - 0.5
		_check(p > 0.0 and p <= legacyHalf + 0.0001, "boss %d: janela perfect plausível e nunca mais larga que a legacy (±%.2f <= ±%.2f)" % [i, p, legacyHalf])
		_check(g >= p, "boss %d: janela good ⊇ perfect (%.2f >= %.2f)" % [i, g, p])
		# A janela declarada é a janela aplicada (mesma fonte, sem régua de texto).
		_checkEq(str(_bossService.InterruptQuality(0.5, i)), "perfect", "boss %d: centro do ciclo é perfect" % i)
		_check(str(_bossService.InterruptQuality(0.5 + p + 0.02, i)) != "perfect", "boss %d: fora da própria janela não é perfect" % i)
	for i in range(1, count):
		_check(float(perfect[i]) <= float(perfect[i - 1]), "boss %d: janela não alarga com a escada (%.2f <= %.2f)" % [i, float(perfect[i]), float(perfect[i - 1])])
	# Legado intacto: sem índice, a janela é a das constantes originais.
	_checkEq(float(_bossService.InterruptBonus(0.3)), float(_bossService.InterruptGoodMult), "interrupt legacy: timing 0.3 sem índice ainda é good")
	_checkEq(float(_bossService.InterruptBonus(0.9)), 1.0, "interrupt legacy: timing 0.9 sem índice ainda é miss")

# ------------------------------------------------- (4) ponto cego de import

# Por que esta suíte existe. `presets/maps/server/**` é ARTEFATO: o addon
# `tiled_importer` é o id (`tiled_import_plugin.gd:30`), e ele regride `data/maps/**.tmx`. O
# `tiled_import_plugin.gd:162` grava o `MapServerData` com os `SpawnObject` do mapa e `:169` o amarra no
# `MapData` que virá `MapsDB` (`sources/db/DB.gd:@MapsDB`), lidos pelo `ParseFileDB`.
# Com o `.godot` morno a engine NÃO reimporta um `.tmx` cujo md5 não mudou, então
# a máquina local lê o `.tres` committado; o CI regenera o `.godot` do zero e roda
# `godot --headless --editor --import --quit` (`.github/workflows/godot-ci.yml`,
# passo "Import assets"), que SOBrescreve o artefato pela fonte. Foi exatamente
# assim que este harness deu `0 failures` na máquina e `33 failures` no CI (run
# 36634640820, commit 1f540a1): o elenco de mobs e a escada de boss foram escritos
# à mão nos artefatos de 10 mapas e o `.tmx` ficou para trás. Reimportando, o CI
# acusou 13 spawns da zona 17 (Drazil) com dois ids que não resolvem para entidade
# (3851394706, 4085786187), um censo de 16 grupos fantasmas, as zonas 25/26/27 sem
# nenhum grupo (`0 >= 19` no tier fundo), o farm em 24 espécies contra a régua de
# 27 (faltavam Lynx, Goblin, Bandit) e seis chefes 4..9 sem o mob na própria
# arena. São 30 linhas `[FAIL]` no log para 33 falhas. O que voltou para a fonte:
# 18 grupos de spawn, 12 nas zonas 25/26/27 e 6 nas arenas dos chefes.
#
# A régua: para cada mapa do `MapsDB`, o MULTICONJUNTO de spawns de MONSTRO do
# `.tmx` tem de ser o do artefato carregado, campo a campo — id, contagem,
# respawn_delay, posição e offset, estes dois recalculados como o import os
# calcula: `pos + extents` e `extents` (`tiled_map_reader.gd:627-628`), e
# `set_default_obj_params` dando 0 a width/height ausentes (`tiled_map_reader.gd:@set_default_obj_params`). Divergência == o
# CI vai reescrever este mapa. Conserta-se o `.tmx` (fonte), nunca o artefato —
# e nunca se afrouxa a régua. Mordida medida: revertido só o `.tmx` de ship-hold
# para o de HEAD, 2 falhas nomeando 'Ship Hold' e os 3 grupos que o CI apagaria;
# com a fonte atual, verde (269 grupos, 0 divergentes). Ponto fixo medido direto,
# não inferido: um clone frio com os 3714 arquivos do índice e sem `.godot`,
# rodando o mesmo `--import` da CI (Godot 4.7.2 aqui, 4.7.1 no runner), devolveu
# `presets/maps/server/**` e `presets/maps/data/**` byte a byte iguais ao
# committado. O que o import regride e esta régua não julga é
# `presets/maps/layers/**`: 40/40 arquivos mudam a cada import sozinhos, por
# `unique_id`, nome de instância (`@GPUParticles2D@20401`) e dados de partícula —
# artefato gerado committado, portanto sem gate possível, e o elenco do jogo não
# vem deles.
func _suiteSpawnSource():
	print("[suite] ponto cego de import: o .tmx fonte e o artefato committado têm o mesmo elenco de mob")
	var pathScript : GDScript = load("res://sources/system/Path.gd")
	var fsScript : GDScript = load("res://sources/system/FileSystem.gd")
	var consts : Dictionary = pathScript.get_script_constant_map()
	var mapRsc : String = str(consts.get("MapRsc", ""))
	var mapExt : String = str(consts.get("MapExt", ""))
	if not _check(not mapRsc.is_empty() and mapRsc.ends_with("/") and not mapExt.is_empty(),
		"Path.MapRsc/MapExt são legíveis pelo harness ('%s' + '%s') — sem eles a varredura da fonte andaria sobre um caminho vazio e daria verde" % [mapRsc, mapExt]):
		_finish()
		return
	var tmxFiles : PackedStringArray = fsScript.call("ParseExtension", mapRsc, mapExt)
	_check(not tmxFiles.is_empty(), "o diretório de mapas fonte lista arquivos (%d '%s' em '%s')" % [tmxFiles.size(), mapExt, mapRsc])

	var byName : Dictionary = {}
	var sourceKeys : Dictionary = {}
	var sourceGroups : int = 0
	for tmxPath in tmxFiles:
		var path : String = str(tmxPath)
		var text : String = str(FileAccess.get_file_as_string(path))
		if not text.begins_with("<?xml"):
			_check(false, "mapa fonte '%s' não abriu como texto XML (a varredura não pode comparar o que não lê)" % path)
			continue
		var keys : Array = _tmxMonsterKeys(text)
		sourceGroups += keys.size()
		var mapName : String = _tmxMapName(text, path.get_file().get_basename())
		_check(not byName.has(mapName), "nome de mapa '%s' não se repete entre os .tmx — senão o pareamento com o artefato é ambíguo" % mapName)
		byName[mapName] = path
		sourceKeys[path] = keys

	var paired : Dictionary = {}
	var divergent : int = 0
	var maps : Dictionary = _dbScript.MapsDB
	for mapID in maps:
		var mapData = maps[mapID]
		if mapData == null or mapData.serverData == null:
			continue
		var artPath : String = str(mapData.serverData.resource_path)
		var mapName : String = artPath.get_file().get_basename()
		if mapName.is_empty():
			mapName = str(mapData._name)
		if not byName.has(mapName):
			divergent += 1
			_check(false, "mapa %s ('%s'): o artefato '%s' não tem .tmx fonte em '%s' — o CI não tem o que reimportar e este artefato é conteúdo órfão" % [mapID, str(mapData._name), artPath, mapRsc])
			continue
		var tmxPath : String = str(byName[mapName])
		paired[tmxPath] = true
		var src : Array = sourceKeys[tmxPath]
		var art : Array = []
		for spawn in mapData.serverData.spawns:
			if spawn == null or int(spawn.type) != _monsterType:
				continue
			art.append(_monsterKey(int(spawn.id), _asInt(spawn.count), float(spawn.respawn_delay), spawn.spawn_position, spawn.spawn_offset))
		var added : Array = _multisetDiff(src, art)
		var removed : Array = _multisetDiff(art, src)
		if added.is_empty() and removed.is_empty():
			continue
		divergent += 1
		_check(false, "mapa %s ('%s'): .tmx e artefato divergem e o --import do CI regride este mapa — %d grupo(s) que SÓ o .tmx conhece (%s) | %d grupo(s) que SÓ o artefato conhece, o CI os APAGA (%s)" % [mapID, str(mapData._name), added.size(), str(added), removed.size(), str(removed)])
	for tmxPath in tmxFiles:
		var path : String = str(tmxPath)
		var count : int = (sourceKeys.get(path, []) as Array).size()
		if count > 0 and not paired.has(path):
			divergent += 1
			_check(false, "mapa fonte '%s' tem %d grupo(s) de mob e nenhum artefato no MapsDB — o CI o importa e esse elenco entra no jogo sem que nenhuma régua tenha olhado" % [path, count])
	print("  [info] ponto cego: %d/%d mapas do MapsDB pareados com .tmx, %d grupos de mob na fonte, %d divergentes" % [paired.size(), maps.size(), sourceGroups, divergent])
	# O piso é folga, não régua: 40 mapas pareados e 269 grupos na fonte medidos
	# verdes em 2026-09-29. Quem acusa de verdade é a divergência abaixo.
	_check(paired.size() >= 40, "a varredura pareou conteúdo real, não um diretório vazio (%d mapas)" % paired.size())
	_check(sourceGroups >= 250, "a fonte tem elenco de mob real para comparar (%d grupos nos .tmx)" % sourceGroups)
	_checkEq(divergent, 0, "nenhum mapa com o .tmx e o artefato divergindo (classe dos 33 vermelhos do CI)")
	# Controles nos dois sentidos: sem eles a suíte pode ser a frase de uma
	# varredura que não comparou nada.
	# Dois lados do mesmo defeito, cada um com o seu par de arrays: `srcWide` é o que
	# o .tmx manda spawnar, `artNarrow` o que o artefato committado tem.
	var srcWide : Array = [_monsterKey(11, 2, 30.0, Vector2i(10, 20), Vector2i(5, 10)), _monsterKey(22, 1, 15000.0, Vector2i(0, 0), Vector2i(0, 0))]
	var artNarrow : Array = [_monsterKey(11, 2, 30.0, Vector2i(10, 20), Vector2i(5, 10))]
	var artWide : Array = [_monsterKey(11, 2, 30.0, Vector2i(10, 20), Vector2i(5, 10)), _monsterKey(33, 4, 30.0, Vector2i(8, 8), Vector2i(4, 4))]
	var srcNarrow : Array = [_monsterKey(11, 2, 30.0, Vector2i(10, 20), Vector2i(5, 10))]
	_checkEq(_multisetDiff(srcWide, artNarrow).size(), 1, "controle: grupo que só o .tmx conhece É acusado (o CI o acrescentaria ao mapa)")
	_checkEq(_multisetDiff(artWide, srcNarrow).size(), 1, "controle: grupo que só o artefato conhece É acusado (o CI o apagaria do mapa)")
	_checkEq(_multisetDiff(srcNarrow, artNarrow).size(), 0, "controle: multiconjuntos iguais não acusam")
	_checkEq(_multisetDiff(artNarrow, srcWide).size(), 0, "controle: o sentido da queixa não se inverte — o que falta no artefato não aparece como excesso dele")
	_checkEq(_multisetDiff([_monsterKey(11, 3, 30.0, Vector2i(0, 0), Vector2i(0, 0))], [_monsterKey(11, 2, 30.0, Vector2i(0, 0), Vector2i(0, 0))]).size(), 1, "controle: a contagem do grupo é comparada, não só a presença do id")
	_checkEq(_multisetDiff([_monsterKey(11, 2, 30.0, Vector2i(0, 0), Vector2i(0, 0))], [_monsterKey(11, 2, 30.0, Vector2i(0, 0), Vector2i(0, 0)), _monsterKey(11, 2, 30.0, Vector2i(0, 0), Vector2i(0, 0))]).size(), 0, "controle: repetição maior do outro lado não gera queixa falsa")
	_finish()

func _monsterKey(id : int, count : int, delay : float, position : Vector2i, offset : Vector2i) -> String:
	return "id %d x%d atraso %s em %d,%d + %d,%d" % [id, count, str(delay), position.x, position.y, offset.x, offset.y]

# Diferença de multiconjuntos por contagem: tirar por índice de um Array literal é
# o no-op que tests/aggro_cap_test.gd caça, então aqui se conta chave por chave.
func _multisetDiff(from : Array, against : Array) -> Array:
	var seen : Dictionary = {}
	for key in against:
		seen[str(key)] = int(seen.get(str(key), 0)) + 1
	var out : Array = []
	for key in from:
		var k : String = str(key)
		if int(seen.get(k, 0)) > 0:
			seen[k] = int(seen[k]) - 1
		else:
			out.append(k)
	return out

# O nome com que o import batiza o artefato é `map_name`: nasce vazio
# (`tiled_map_reader.gd:80`) e aqui só é atribuído pela property name do
# mapa (`tiled_map_reader.gd:1430-1431`). O import não conhece o nome do
# arquivo — o `fallback` abaixo é guarda deste harness, e um mapa sem a
# property chega com o nome vazio, que não casa com nenhum .tmx e é contado
# como divergência.
func _tmxMapName(text : String, fallback : String) -> String:
	var cut : int = -1
	for marker : String in ["<layer", "<objectgroup", "<tilelayer"]:
		var at : int = text.find(marker)
		if at >= 0 and (cut < 0 or at < cut):
			cut = at
	var head : String = text if cut < 0 else text.substr(0, cut)
	var re := RegEx.new()
	if re.compile('\\bname="name"[^>]*\\bvalue="([^"]*)"') != OK:
		return fallback
	var m : RegExMatch = re.search(head)
	return m.get_string(1) if m != null and not m.get_string(1).is_empty() else fallback

func _tmxMonsterKeys(text : String) -> Array:
	var out : Array = []
	var attrRe := RegEx.new()
	if attrRe.compile('\\b(\\w+)="([^"]*)"') != OK:
		return out
	for chunk : String in text.split("<object"):
		# "<objectgroup" e o resto do documento também caem no split: um tag de
		# objeto sempre começa com espaço (o nome do atributo).
		if not chunk.begins_with(" "):
			continue
		var closeTag : int = chunk.find(">")
		if closeTag < 0:
			continue
		var tag : String = chunk.substr(0, closeTag)
		var attrs : Dictionary = _tmxAttrs(tag, attrRe)
		if str(attrs.get("type", "")) != "Spawn":
			continue
		var body : String = ""
		if not tag.rstrip(" ").ends_with("/"):
			var endObj : int = chunk.find("</object>")
			if endObj > closeTag:
				body = chunk.substr(closeTag + 1, endObj - closeTag - 1)
		var props : Dictionary = _tmxProps(body, attrRe)
		# O tipo do spawn vem do PROPERTY, não do atributo type="Spawn" do objeto.
		if str(props.get("type", "")).to_upper() != "MONSTER":
			continue
		var pos := Vector2(float(str(attrs.get("x", "0"))), float(str(attrs.get("y", "0"))))
		var extents := Vector2(float(str(attrs.get("width", "0"))) / 2.0, float(str(attrs.get("height", "0"))) / 2.0)
		var position : Vector2i = Vector2i(pos + extents)
		var offset : Vector2i = Vector2i(extents)
		out.append(_monsterKey(str(attrs.get("name", "")).hash(), int(str(props.get("count", "1"))), float(str(props.get("respawn_delay", "30.0"))), position, offset))
	return out

func _tmxProps(body : String, attrRe : RegEx) -> Dictionary:
	var out : Dictionary = {}
	for chunk : String in body.split("<property"):
		if not chunk.begins_with(" "):
			continue # o contentor <properties>
		var closeTag : int = chunk.find(">")
		if closeTag < 0:
			continue
		var attrs : Dictionary = _tmxAttrs(chunk.substr(0, closeTag), attrRe)
		var nm : String = str(attrs.get("name", ""))
		if nm.is_empty():
			continue
		out[nm] = str(attrs.get("value", ""))
	return out

func _tmxAttrs(tag : String, attrRe : RegEx) -> Dictionary:
	var out : Dictionary = {}
	for m in attrRe.search_all(tag):
		out[str(m.get_string(1))] = str(m.get_string(2))
	return out
