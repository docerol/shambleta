extends SceneTree

# SOM-IDLE: régua de CONTEÚDO das faixas de drop por tier. Juiz externo
# 2026-09-28: "bandas de drop nascem vazias nos tiers iniciais — fallback
# declarado para Apple", apontando o construtor de faixa em
# sources/idle/FarmZoneData.gd:243-254 (revisão auditada; no arquivo de hoje é o
# bloco de `GetDropPool`). O defeito tem três faces e as três são travadas aqui,
# como dados, não como contagem regravada:
#
#  (1) NADA NOMEAVA O CONTEÚDO — as matérias-primas de
#      presets/cells/items/material/*.tres entravam na faixa só por acaso de um
#      número digitado no .tres, e o repo inteiro (receita, mesa de mob, teste)
#      podia ignorá-las sem que nada reclamasse. Agora a faixa declara o próprio
#      conteúdo em `FarmZoneData.BandMaterialNames`; este harness exige que toda
#      declaração resolva para uma célula real do ItemsDB, que a célula seja
#      matéria-prima de verdade (`ItemCell.material`, a flag que a economia lê) e
#      que ela esteja NO tier que a declara — é o que impede a faixa de responder
#      loot de tier errado, a outra face do fallback antigo.
#
#  (2) FAIXA QUE NASCE VAZIA NÃO PODE DEGRADAR PARA APPLE — toda zona da escada
#      tem de ter pool, toda entrada da pool tem de ser item do catálogo (ou
#      template de craft aprovado, que tem faixa própria no SQL) com tier dentro
#      da banda, e o Apple só pode aparecer onde o próprio catálogo o coloca: na
#      banda do tier dele. O caminho "sem zona" (id de zona inválido no registro
#      do char) continua sendo o único Apple por desenho, e é asserido como tal.
#
#  (3) O PREÇO DE ENCHER FAIXA É ZERO, e isto é régua, não promessa: a contagem
#      de drop por kill não lê a pool — ela sai de `dropRatePPM`
#      (`OfflineSettle.gd:356`) no offline e da soma das tabelas `_drops` do mob
#      no farm vivo, que é o que a suíte `SuiteIdleLootPipeline`
#      (`tests/IdleTestsFrontier.gd:@SuiteIdleLootPipeline`) mede e costura ao mesmo ppm
#      dentro de si. Três medidas aqui, nenhuma regravada em texto:
#      nenhuma zona carrega taxa própria escondida (a pia é uma régua do
#      catálogo), o roll devolve exatamente UM item por roll (identidade, nunca
#      quantidade), e as matérias-primas que a faixa ganhou NÃO estão em mesa
#      `_drops` de mob nenhum — é por isso que preencher faixa não tem como tocar
#      no 0,7/kill. A grandeza em si é conferida contra a mesa viva da zona que a
#      própria `SuiteIdleLootPipeline` instancia — a instância da zona 1 é asserida por
#      ela — com a mesma folga de 25% daquela régua.
#
# Uso: godot --headless --path . -s tests/drop_band_content_test.gd
# Régua do gate = última linha `== RESULT: N checks, M failures ==` e o exit code.

var checks : int = 0
var failures : int = 0

# Amostras por zona na roleta. Não é tamanho de pool (isso é dado do catálogo) e
# não é amostra estatística: é a varredura do espaço de roll, que em
# `GetDropForRoll` é determinística (mesmo roll → mesmo item), então o que
# importa é cobrir o suporte da pool com folga — o número que a suíte de conteúdo
# do repo já usa para o mesmo fim.
const RollProbePerZone : int = 200

var _launcher : Node = null
var _worldNode : Node = null
var _dbScript : GDScript = null
var _farm : GDScript = null
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

func _checkNear(value : float, expected : float, tolerance : float, label : String) -> bool:
	checks += 1
	if absf(value - expected) > tolerance:
		failures += 1
		print("  [FAIL] %s: %f vs %f (±%f)" % [label, value, expected, tolerance])
		return false
	return true

func _finish():
	# Drenar o preload antes de quit: sem isto o engine destrói o worker de load
	# no meio do parse e o processo SIGSEGVA na saída (contrato de DB.gd, mesmo
	# caminho dos outros harnesses).
	if _dbScript != null:
		_dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

func _run():
	print("== drop band content harness (faixa por tier, fallback, contagem por kill) ==")
	_launcher = root.get_node_or_null(^"Launcher")
	if _launcher == null:
		print("FATAL: Launcher autoload missing")
		_finish()
		return
	var waited : int = 0
	while waited < 60000:
		await create_timer(0.25).timeout
		waited += 250
		_worldNode = _launcher.World
		# SQL junto com o World: `GetDropPool` (`FarmZoneData.gd:@GetDropPool`) acrescenta
		# as templates aprovadas de `craft_item_template` e cacheia a pool da zona.
		# Ler a mesa de craft antes do SQL subir produziria pool sem essas entradas
		# contra um craftSet lido depois — e a régua de "toda entrada existe no
		# catálogo" fritaria um falso positivo. Mesmo contrato de boot de
		# `tests/content_hygiene_test.gd:86`.
		if _worldNode != null and _worldNode.isInitialized and _launcher.SQL != null and _launcher.SQL.isInitialized:
			break
	print("== boot wait done (waited %d ms) ==" % waited)

	_dbScript = load("res://sources/db/DB.gd")
	_farm = load("res://sources/idle/FarmZoneData.gd")
	var commons : GDScript = load("res://sources/actor/ActorCommons.gd")
	_monsterType = int(commons.Type.MONSTER)

	var dbReady : bool = false
	for attempt in 80:
		if _dbScript.isInitialized:
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (items e mapas resolvidos antes da régua)"):
		_finish()
		return
	if not _check(_worldNode != null and _worldNode.isInitialized, "World inicializado (mesa viva dos mobs lida em runtime)"):
		_finish()
		return

	_farm.SyncWithDB()
	_suiteDeclaration()
	_suiteBands()
	_suiteAppleScope()
	_suiteKillCount()
	_finish()

# ------------------------------------------------------------------ (1) declaração por tier

# A tabela `BandMaterialNames` é o contrato: um piso declarado por tier da escada.
# Aqui ela é conferida contra o catálogo, célula a célula — o que falha se alguém
# renomear a célula, trocar o tier ou apontar o piso para equipamento.
func _suiteDeclaration():
	print("[suite] declaração: todo tier tem matéria-prima própria e resolvida")
	var maxTier : int = int(_farm.MAX_TIER)
	var declaredNames : Array = _farm.BandMaterialNames
	_checkEq(declaredNames.size(), maxTier, "a declaração de conteúdo cobre todo tier da escada (piso por tier, sem buraco)")
	var tiersPerName : Dictionary = {}
	for tier in range(1, maxTier + 1):
		var wanted : String = str(_farm.GetBandMaterialName(tier))
		if not _check(not wanted.is_empty(), "tier %d declara uma matéria-prima por nome" % tier):
			continue
		_check(not tiersPerName.has(wanted), "tier %d: '%s' não é piso de dois tiers (cada tier paga o próprio insumo)" % [tier, wanted])
		tiersPerName[wanted] = tier
		var resolved : int = int(_farm.GetBandMaterialHash(tier))
		if not _check(resolved != int(_dbScript.UnknownHash), "tier %d: a matéria-prima declarada '%s' resolve no ItemsDB" % [tier, wanted]):
			continue
		var cell = _dbScript.ItemsDB.get(resolved, null)
		if not _check(cell != null, "tier %d: hash declarado (%d) é célula do catálogo" % [tier, resolved]):
			continue
		_checkEq(str(cell.name), wanted, "tier %d: a célula resolvida é a declarada" % tier)
		_check(bool(cell.material), "tier %d: '%s' é matéria-prima de verdade (ItemCell.material), não item com nome bonito" % [tier, wanted])
		_checkEq(int(cell.tier), tier, "tier %d: '%s' está no tier que a declara (piso de faixa não entrega tier errado)" % [tier, wanted])

# ------------------------------------------------------------------ (2) faixas por zona

# Reconstrói a banda [tier, min(tier+band-1, MAX_TIER)] a partir do catálogo e
# exige que a pool da zona responda conteúdo real nela. Faixa vazia, entrada fora
# da faixa e pool com célula repetida (o seed declarado duplicando a varredura)
# são as três formas do defeito voltar.
func _suiteBands():
	print("[suite] faixas: nenhuma zona nasce vazia e toda entrada cai na própria banda")
	var craftSet : Dictionary = {}
	if _launcher.SQL != null:
		var rows : Array = _launcher.SQL.QueryBindings("SELECT item_hash FROM craft_item_template;", [])
		for row in rows:
			craftSet[int(row.get("item_hash", 0))] = true
	var tierOf : Dictionary = {}
	var materialOf : Dictionary = {}
	for cellHash in _dbScript.ItemsDB:
		var item = _dbScript.ItemsDB[cellHash]
		if item != null:
			tierOf[int(cellHash)] = int(item.tier)
			materialOf[int(cellHash)] = bool(item.material)
	var bandSize : int = int(_farm.DropTierBandSize)
	var maxTier : int = int(_farm.MAX_TIER)
	var zoneCount : int = int(_farm.ZONE_COUNT)
	for zoneID in range(1, zoneCount + 1):
		var zone = _farm.GetZone(zoneID)
		if not _check(zone != null, "zona %d existe no catálogo" % zoneID):
			continue
		var tierLo : int = int(zone.tier)
		var tierHi : int = mini(tierLo + bandSize - 1, maxTier)
		# A banda, medida do catálogo — não da pool — é o que define "faixa cheia".
		var band : Array[int] = []
		for knownHash in tierOf.keys():
			var knownTier : int = int(tierOf[knownHash])
			if knownTier >= tierLo and knownTier <= tierHi:
				band.append(int(knownHash))
		_check(not band.is_empty(), "zona %d (tier %d): a banda [%d,%d] tem conteúdo no catálogo" % [zoneID, tierLo, tierLo, tierHi])
		var pool : Array = _farm.GetDropPool(zoneID)
		_check(not pool.is_empty(), "zona %d (tier %d): a pool resolve, não cai no ramo de faixa vazia" % [zoneID, tierLo])
		var declaredLo : int = int(_farm.GetBandMaterialHash(tierLo))
		var declaredHi : int = int(_farm.GetBandMaterialHash(tierHi))
		_check(declaredLo != int(_dbScript.UnknownHash) and pool.has(declaredLo),
			"zona %d: o piso declarado do tier %d está na pool" % [zoneID, tierLo])
		_check(declaredHi == int(_dbScript.UnknownHash) or pool.has(declaredHi),
			"zona %d: o piso declarado do tier %d (topo da banda) está na pool" % [zoneID, tierHi])
		var seen : Dictionary = {}
		var materials : int = 0
		var others : int = 0
		for entry in pool:
			var itemHash : int = int(entry)
			_check(not seen.has(itemHash), "zona %d: pool não repete célula %d (declaração e varredura são o mesmo item)" % [zoneID, itemHash])
			seen[itemHash] = true
			var isCraft : bool = craftSet.has(itemHash)
			if not isCraft:
				if not _check(tierOf.has(itemHash), "zona %d: entrada %d existe no catálogo de itens" % [zoneID, itemHash]):
					continue
				var itemTier : int = int(tierOf[itemHash])
				_check(itemTier >= tierLo and itemTier <= tierHi,
					"zona %d: entrada %d (tier %d) está dentro da banda [%d,%d]" % [zoneID, itemHash, itemTier, tierLo, tierHi])
			if bool(materialOf.get(itemHash, false)):
				materials += 1
			else:
				others += 1
		# Conteúdo das duas classes que a faixa promete: insumo (o segundo verbo do
		# farm) e peça consumível/equipamento (a pia que o balance é dono).
		_check(materials > 0, "zona %d (tier %d): a faixa tem matéria-prima própria" % [zoneID, tierLo])
		_check(others > 0, "zona %d (tier %d): a faixa tem peça além do insumo" % [zoneID, tierLo])

# ------------------------------------------------------------------ (3) alcance do Apple

# O Apple é tier 1 de catálogo: ele pode cair na banda do tier 1 e em nada mais.
# O ramo de pool vazia devolvendo Apple tem de ser inalcançável para zona válida,
# e o único Apple por desenho é o caminho "sem zona".
func _suiteAppleScope():
	print("[suite] fallback: Apple só onde o desenho o coloca")
	var apple : int = int(_farm.DefaultDropItemHash)
	var appleCell = _dbScript.ItemsDB.get(apple, null)
	if not _check(appleCell != null, "o item de fallback (%d) é célula do catálogo" % apple):
		return
	var appleTier : int = int(appleCell.tier)
	var bandSize : int = int(_farm.DropTierBandSize)
	var maxTier : int = int(_farm.MAX_TIER)
	var zoneCount : int = int(_farm.ZONE_COUNT)
	for zoneID in range(1, zoneCount + 1):
		var zone = _farm.GetZone(zoneID)
		if zone == null:
			continue
		var tierLo : int = int(zone.tier)
		var tierHi : int = mini(tierLo + bandSize - 1, maxTier)
		var pool : Array = _farm.GetDropPool(zoneID)
		var inOwnBand : bool = appleTier >= tierLo and appleTier <= tierHi
		_checkEq(pool.has(apple), inOwnBand,
			"zona %d: Apple na pool é conteúdo do tier dele (%d), não fallback da faixa" % [zoneID, appleTier])
		if tierLo > appleTier:
			_check(not pool.has(apple), "zona %d (tier %d): faixa mais funda que o tier do Apple não o carrega" % [zoneID, tierLo])
		for roll in RollProbePerZone:
			var pick : int = int(_farm.GetDropForRoll(zoneID, roll))
			if pick == apple and not inOwnBand:
				_check(false, "zona %d roll %d: o roll respondeu o Apple de fallback, não conteúdo da banda [%d,%d]" % [zoneID, roll, tierLo, tierHi])
	# O caminho declarado por desenho: registro do char sem zona (id inválido).
	var invalidZones : Array[int] = [0, zoneCount + 1, zoneCount + int(_farm.ZonesPerTier)]
	for invalidZone : int in invalidZones:
		var guard : Array = _farm.GetDropPool(invalidZone)
		_checkEq(guard.size(), 1, "zona %d (sem zona): o guarda devolve exatamente o item de reserva" % invalidZone)
		# Índex só depois de conferir o tamanho: um guarda vazio é falha de conteúdo
		# (a asserção acima já gritou) e acessar `[0]` cega derrubaria o harness antes
		# da linha de resultado, que é o que o §24-8 lê como run incompleto.
		var reserve : int = int(guard[0]) if not guard.is_empty() else 0
		_checkEq(reserve, apple, "zona %d (sem zona): a reserva do caminho 'sem zona' é o Apple" % invalidZone)
		_checkEq(int(_farm.GetDropForRoll(invalidZone, 7)), apple, "zona %d (sem zona): o roll do guarda responde a reserva" % invalidZone)

# ------------------------------------------------------------------ (4) contagem por kill

# O que encher faixa NÃO muda: a expectativa de drop por kill. A contagem tem duas
# origens e nenhuma delas lê a pool — offline `zone.dropRatePPM` × kills equivalentes
# (`OfflineSettle.gd:356`), online a soma das probabilidades da mesa `_drops` do mob,
# medida por `SuiteIdleLootPipeline` (`tests/IdleTestsFrontier.gd:@SuiteIdleLootPipeline`).
# Daí três medidas:
#   (a) nenhuma zona carrega taxa própria escondida: `FarmZoneData.gd:180` dá a
#       todas o `DefaultDropRatePPM`, e nada em `_make` (`FarmZoneData.gd:260-272`)
#       o sobrescreve, então conteúdo
#       de faixa não tem alavanca sobre contagem;
#   (b) o roll devolve identidade, nunca quantidade — um item por roll;
#   (c) o conteúdo que a faixa ganhou não fala com a mesa do mob: se matéria-prima
#       declarada entrasse num `_drops`, cada kill passaria a rolar mais um item e
#       o 0,7 medido subia silenciosamente. É a única forma de o trabalho desta
#       faixa mover a contagem, e é travada aqui.
# A grandeza do catálogo é conferida contra a mesa viva da zona 1, a instância que a
# própria suíte assera, com a mesma folga de 25% da régua do ppm em
# `SuiteIdleLootPipeline` (`tests/IdleTestsFrontier.gd:@SuiteIdleLootPipeline`).
func _suiteKillCount():
	print("[suite] contagem: conteúdo de faixa não move o drop por kill")
	var ppm : int = int(_farm.DefaultDropRatePPM)
	var perKillCatalog : float = float(ppm) / 1000000.0
	_check(ppm > 0 and ppm <= 1000000, "a taxa declarada do catálogo está na grandeza de uma pia por kill (%.3f por kill)" % perKillCatalog)
	var zoneCount : int = int(_farm.ZONE_COUNT)
	var drift : int = 0
	for zoneID in range(1, zoneCount + 1):
		var zone = _farm.GetZone(zoneID)
		if zone == null:
			continue
		if int(zone.dropRatePPM) != ppm:
			drift += 1
	_checkEq(drift, 0, "nenhuma zona carrega taxa de drop própria escondida (a pia é uma régua do catálogo)")
	var rolls : int = 0
	var delivered : int = 0
	for zoneID in range(1, zoneCount + 1):
		for roll in RollProbePerZone:
			rolls += 1
			if int(_farm.GetDropForRoll(zoneID, roll)) > 0:
				delivered += 1
	_checkEq(delivered, rolls, "todo roll entrega exatamente um item (o roll decide identidade, nunca quantidade)")
	# (c) mesa do mob não é faixa de drop: censo das probabilidades por kill que o
	# farm vivo rola, e a interseção com o conteúdo declarado das faixas.
	var tableHashes : Dictionary = _mobDropTableCensus()
	var inTable : int = 0
	for tier in range(1, int(_farm.MAX_TIER) + 1):
		var declared : int = int(_farm.GetBandMaterialHash(tier))
		if declared != int(_dbScript.UnknownHash) and tableHashes.has(declared):
			inTable += 1
	_checkEq(inTable, 0, "nenhuma matéria-prima declarada por faixa está na mesa `_drops` de um mob (conteúdo novo não fala com a contagem)")
	_check(not tableHashes.is_empty(), "a mesa viva dos mobs foi censurada (sem isto a régua (c) seria vazia)")
	# Grandeza conferida contra a zona que a fronteira mede, na folga da fronteira.
	var pinned = _farm.GetZone(1)
	if not _check(pinned != null, "zona 1 existe no catálogo (é a zona da régua de contagem da fronteira)"):
		return
	var perKill : float = _liveTablePerKill(int(pinned.mapID))
	if not _check(perKill > 0.0, "a mesa viva da zona 1 tem probabilidade por kill medida (%.3f)" % perKill):
		return
	_checkNear(perKillCatalog, perKill, 0.25 * perKill,
		"a contagem por kill da zona 1 é a taxa do catálogo (%.3f vs %.3f por kill)" % [perKillCatalog, perKill])

# Censo das células que os mobs já derrubam por mesa própria (`_drops`), na chave
# do ItemsDB. É o contrapeso da asserção (c) acima: a contagem do farm vivo nasce do
# censo que `SuiteIdleLootPipeline` faz (`tests/IdleTestsFrontier.gd:@SuiteIdleLootPipeline`)
# sobre estas mesmas mesas, então o que não está aqui não entrou no
# roll por kill — e o conteúdo que as faixas ganharam não está.
func _mobDropTableCensus() -> Dictionary:
	var out : Dictionary = {}
	for entityID in _dbScript.EntitiesDB:
		var entity = _dbScript.EntitiesDB[entityID]
		if entity == null:
			continue
		var merged = entity.GetMergedEntity() if entity.has_method("GetMergedEntity") else entity
		var table = merged._drops
		if table == null:
			continue
		for dropCell in table:
			if dropCell == null:
				continue
			out[int(dropCell.id)] = true
	return out

# Soma das probabilidades da tabela `_drops` por mob do roster da zona (mesma
# construção do roll por kill do `IdlePolicy`/`SuiteIdleLootPipeline`): média sobre
# os grupos que TÊM mesa — mob sem tabela não derruba item e não entra na média.
func _liveTablePerKill(mapID : int) -> float:
	if mapID == int(_dbScript.UnknownHash):
		return 0.0
	var worldMap = _worldNode.GetMap(mapID)
	if worldMap == null:
		return 0.0
	var groups : int = 0
	var sum : float = 0.0
	for spawn in worldMap.spawns:
		if spawn == null or int(spawn.type) != _monsterType:
			continue
		var entity = _dbScript.EntitiesDB.get(int(spawn.id), null)
		if entity == null:
			continue
		var merged = entity.GetMergedEntity() if entity.has_method("GetMergedEntity") else entity
		var table = merged._drops
		if table == null or table.is_empty():
			continue
		var perKill : float = 0.0
		for dropCell in table:
			perKill += float(table[dropCell])
		if perKill <= 0.0:
			continue
		groups += 1
		sum += perKill
	if groups <= 0:
		return 0.0
	return sum / float(groups)
