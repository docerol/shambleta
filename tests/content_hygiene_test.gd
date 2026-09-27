extends SceneTree

# SOM-CONTENT: régua de higiene de conteúdo (juiz 2026-09-27: "os sistemas
# correm na frente do conteúdo"). Duas classes de defeito que HOJE nada lê no
# portão:
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
#      falha.
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
	print("== content hygiene harness (rosters + faixas de drop + escada de boss) ==")
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
	_suiteRosters(worldNode)
	_suiteDropBands()
	_suiteBossLadder(worldNode)
	_finish()

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
	for t in range(1, int(_farm.MAX_TIER) + 1):
		var inTier : int = 0
		for h in tierOf.keys():
			if int(tierOf[h]) == t:
				inTier += 1
		_check(inTier > 0, "tier %d tem item próprio na pool (%d cells)" % [t, inTier])
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
