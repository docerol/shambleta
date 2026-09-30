extends SceneTree

# shard_capacity_test.gd — P1 de escalabilidade: o cap de players por instância
# passou de "um passo e reza" para BUSCA LIMITADA de shard, e a espera na
# `queryMutex` (o gargalo do processo) deixou de ser invisível. As duas coisas são o
# mesmo diagnóstico: sem medição e sem invariante, "o servidor aguenta" era opinião.
#
# Uso:    ./scripts/test.sh shard_capacity     (ou o comando cru do cabeçalho do gate)
# Saída:  "== RESULT: <n> checks, <m> failures =="   (exit code = <m>)
#
# O que ele responde, na ordem:
#   1) A LOTAÇÃO PELO CAMINHO REAL: `WorldAgent.CreateAgent` com N players, sem
#      tocar em lista nenhuma. Antes do conserto o 21º entrava em `base+1` e o 22º,
#      o 23º e todos os seguintes também — a instância vizinha era um balde, não uma
#      segunda instância. Agora a distribuição é cheia-na-ordem: 41 players →
#      20/20/1, 61 → 20/20/20/1, e nenhuma instância da família passa de
#      `MAX_PLAYERS_PER_INSTANCE` (sources/world/WorldAgent.gd:217).
#   2) O CAMINHO DE WARP: `World.Spawn` (sources/world/World.gd:86) é por onde o
#      login e todo warp de porta entram, e até aqui ele pegava
#      `map.instances[instanceID]` e empurrava o player na lista fosse qual fosse a
#      lotação — `NpcCommons.Warp` sempre passa 0 (sources/actor/agent/NpcCommons.gd:@Warp).
#   3) O BURACO: `PopAgent` fecha instância vazia com `DestroyEmptyInstanceIfUnchanged`
#      (sources/world/WorldMap.gd:55). O shard seguinte tem de REAPROVEITAR o id
#      livre, não empilhar id novo por cima dele.
#   4) A JANELA LIMITADA: a busca anda no máximo `MAX_SHARDS_PER_FAMILY` ids e NUNCA
#      entra na numeração dedicada. Com a instância 999 cheia, `ResolvePlayerInstance`
#      devolve null — não `1000`, que é `IdlePolicyService.ZoneInstanceBase`.
#   5) A EXCEÇÃO QUE É CONTRATO: ids >= `ZoneInstanceBase` (zona de farm) e
#      `BossInstanceBase` (arena por char) não são shardáveis, porque o id é a chave
#      sob a qual a `ZonePolicy`/sessão idle do jogador mora. Mover o player de
#      instância sem mover a policy derruba a sessão idle — o cap que vale ali é o do
#      tick (tests/tick_capacity_test.gd), não o de lotação.
#   6) MOB NÃO É SHARDADO: mob pertence à instância de quem o chamou
#      (sources/world/WorldInstance.gd:57, `_map_loaded`). O código antigo sharded
#      QUALQUER tipo de agente e fabricava instância órfã de mobs, com o timer de
#      respawn preso nela.
#   7) A ESPERA NA MUTEX: `SQL.QueryMutexWaitStats()` conta quantas vezes alguém
#      entrou na seção crítica e por quanto tempo esperou, com cauda em degrades
#      (sources/sql/SQL.gd:1424). Prova também a contabilidade: leitura roteada para o
#      pool NÃO conta como espera (não pega a mutex), escrita conta exatamente 1, e
#      ler a estatística não infla a estatística.
#
# Como todo harness `-s`: nada de identificador de autoload (Launcher/Network/...)
# nem class_name de projeto em anotação de tipo — o main-loop é compilado antes de
# eles existirem. Tudo via load()/get()/call().
#
# Nada aqui apaga dado de usuário: roda no sandbox do gate e os fixtures têm prefixo
# próprio (`ShardCap`), removido no `_finish`.

const NickPrefix : String = "ShardCap"
const AcctPrefix : String = "shardcap"
const Seed41 : int = 41
const Seed61 : int = 61

var checks : int = 0
var failures : int = 0
var launcher : Node = null
var sql : Node = null
var world : Node = null
var dbScript : GDScript = null
var worldAgentScript : GDScript = null
var worldInstanceScript : GDScript = null
var policyScript : GDScript = null
var actorCommonsScript : GDScript = null
var spawnScript : GDScript = null
var farmScript : GDScript = null
var suites : RefCounted = null

var cap : int = 20
var shards : int = 32
var zoneBase : int = 1000
var bossBase : int = 9000

var agents : Array = []
var charIDs : Array = []
var seeded : int = 0

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(actual : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	# Comparar tipos diferentes aborta a expressão em GDScript 4 e a check abortada
	# não era contada como falha (mesma armadilha pegada em doc_facts_test.gd).
	var same : bool = typeof(actual) == typeof(expected) and actual == expected
	if not same:
		failures += 1
		print("  [FAIL] %s (esperado %s, atual %s)" % [label, str(expected), str(actual)])
		return false
	print("  [ok] " + label)
	return true

func Note(text : String) -> void:
	print("  . " + text)

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _initialize():
	_run()

# ------------------------------------------------------------------- medição da família

# Distribuição real da família: [#id, players, #id, players, ...] na ordem de id,
# olhando só as instâncias existentes. Não consulta lista paralela nenhuma — é o
# mesmo `inst.players` que o servidor usa para endereçar visão, chat e fan-out.
func _distribution(mapObj : Object, baseID : int) -> Array:
	var out : Array = []
	var instances : Dictionary = mapObj.get("instances")
	for shard in range(shards):
		var instID : int = baseID + shard
		if instID >= zoneBase:
			break
		var inst : Object = instances.get(instID, null)
		if inst == null:
			continue
		out.append(instID)
		out.append((inst.get("players") as Array).size())
	return out

func _distText(mapObj : Object, baseID : int) -> String:
	var text : String = ""
	var pairs : Array = _distribution(mapObj, baseID)
	for i in range(0, pairs.size(), 2):
		text += "#%d=%d " % [pairs[i], pairs[i + 1]]
	return text if text != "" else "(vazia)"

func _sizes(mapObj : Object, baseID : int) -> Array:
	var pairs : Array = _distribution(mapObj, baseID)
	var out : Array = []
	for i in range(0, pairs.size(), 2):
		out.append(int(pairs[i + 1]))
	return out

func _ids(mapObj : Object, baseID : int) -> Array:
	var pairs : Array = _distribution(mapObj, baseID)
	var out : Array = []
	for i in range(0, pairs.size(), 2):
		out.append(int(pairs[i]))
	return out

# Invariantes que têm de valer em qualquer momento, em qualquer família shardável:
# nada acima do cap, ids contíguos a partir da base (buraco é reaproveitado, não
# empilhado) e ninguém desapareceu no caminho.
func _AssertFamilyInvariants(mapObj : Object, baseID : int, label : String, total : int) -> void:
	var sizes : Array = _sizes(mapObj, baseID)
	var ids : Array = _ids(mapObj, baseID)
	var over : int = 0
	for size in sizes:
		if int(size) > cap:
			over += 1
	CheckEq(over, 0, "%s: nenhuma instância da família #%d acima do cap %d (%s)" % [label, baseID, cap, _distText(mapObj, baseID)])
	var contiguous : bool = true
	for i in range(ids.size()):
		if int(ids[i]) != baseID + i:
			contiguous = false
	Check(contiguous, "%s: ids contíguos a partir de #%d (%s)" % [label, baseID, str(ids)])
	var sum : int = 0
	for size in sizes:
		sum += int(size)
	CheckEq(sum, total, "%s: %d players contados na família, nenhum perdido/duplicado" % [label, total])

# "Cheia na ordem" — a forma exata que o bug de um passo violava.
func _AssertPacked(mapObj : Object, baseID : int, label : String) -> void:
	var sizes : Array = _sizes(mapObj, baseID)
	var expected : Array = []
	var left : int = seeded
	while left > 0:
		var take : int = mini(left, cap)
		expected.append(take)
		left -= take
	CheckEq(sizes, expected, "%s: distribuição %s == esperada %s" % [label, str(sizes), str(expected)])
	CheckEq(sizes.size(), int(ceil(float(seeded) / float(cap))), "%s: %d instância(s) para %d players, nenhuma a mais" % [label, sizes.size(), seeded])

func _MonsterSpawn(mapObj : Object) -> Object:
	var monsterType : int = int(actorCommonsScript.get_script_constant_map().get("Type", {}).get("MONSTER", 2))
	for spawn in (mapObj.get("spawns") as Array):
		if spawn != null and int(spawn.get("type")) == monsterType and int(spawn.get("count")) > 0:
			return spawn
	return null

func _PlayerSpawn(mapObj : Object) -> Object:
	var playerType : int = int(actorCommonsScript.get_script_constant_map().get("Type", {}).get("PLAYER", 0))
	var spawnPoint : Object = spawnScript.new()
	spawnPoint.set("map", mapObj)
	spawnPoint.set("type", playerType)
	spawnPoint.set("id", int(dbScript.get("PlayerHash")))
	spawnPoint.set("is_global", false)
	spawnPoint.set("spawn_offset", Vector2i(32, 32))
	var anchor : Object = _MonsterSpawn(mapObj)
	spawnPoint.set("spawn_position", anchor.get("spawn_position") if anchor != null else Vector2i(64, 64))
	return spawnPoint

func _Fixture(index : int) -> int:
	var acct : String = "%s%03d" % [AcctPrefix, index]
	var nick : String = "%s%03d" % [NickPrefix, index]
	var charID : int = int(suites.call("CreateFixture", sql, acct, nick))
	if charID == 0:
		return 0
	charIDs.append(charID)
	return charID

# Player pelo caminho de produção: SpawnObject montado como o login monta e
# WorldAgent.CreateAgent, que é o caminho que decide a instância.
func _SeedPlayer(mapObj : Object, baseID : int, index : int) -> Node:
	var charID : int = _Fixture(index)
	if charID == 0:
		return null
	var agent : Node = worldAgentScript.call("CreateAgent", _PlayerSpawn(mapObj), baseID, "%s%03d" % [NickPrefix, index]) as Node
	if agent == null:
		return null
	agent.call("SetCharacterInfo", sql.call("GetCharacterInfo", charID), charID)
	agents.append(agent)
	seeded += 1
	return agent

func _Move(agent : Node, inst : Object) -> void:
	worldAgentScript.call("PopAgent", agent)
	worldAgentScript.call("PushAgent", agent, inst)

func _Drop(agent : Node) -> void:
	if agent != null and is_instance_valid(agent):
		worldAgentScript.call("RemoveAgent", agent)
		# `seeded` é contagem de players VIVOS na família, não histórico de chamadas:
		# sem o decremento o "nenhum perdido/duplicado" do reuso de buraco cobrava 62
		# players quando o teste tinha acabado de tirar um.
		if agents.has(agent):
			seeded -= 1
	agents.erase(agent)

func _Frames(count : int) -> void:
	for i in range(count):
		await process_frame

# --------------------------------------------------------------------------------------- main
func _run() -> void:
	print("== P1 escalabilidade: busca limitada de shard + espera na queryMutex ==")
	launcher = _autoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return
	var waited : int = 0
	while waited < 40000:
		await create_timer(0.25).timeout
		waited += 250
		sql = launcher.get("SQL")
		world = launcher.get("World")
		if sql != null and bool(sql.get("isInitialized")) and world != null and bool(world.get("isInitialized")):
			break
	if not Check(sql != null and bool(sql.get("isInitialized")) and world != null and bool(world.get("isInitialized")),
			"SQL + World booteds (%d ms de espera)" % waited):
		await _finish()
		return

	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for tick in 40:
		if bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "preload threadado do DB drenado antes de load()"):
		await _finish()
		return

	worldAgentScript = load("res://sources/world/WorldAgent.gd")
	worldInstanceScript = load("res://sources/world/WorldInstance.gd")
	policyScript = load("res://sources/idle/IdlePolicyService.gd")
	actorCommonsScript = load("res://sources/actor/ActorCommons.gd")
	spawnScript = load("res://addons/tiled_importer/SpawnObject.gd")
	farmScript = load("res://sources/idle/FarmZoneData.gd")
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	suites = suitesScript.new()
	if not Check(worldAgentScript != null and worldInstanceScript != null and policyScript != null and actorCommonsScript != null
			and spawnScript != null and farmScript != null and suites != null,
			"WorldAgent + WorldInstance + IdlePolicyService + ActorCommons + SpawnObject + FarmZoneData + IdleTests carregados"):
		await _finish()
		return

	var agentConsts : Dictionary = worldAgentScript.get_script_constant_map()
	var instConsts : Dictionary = worldInstanceScript.get_script_constant_map()
	var policyConsts : Dictionary = policyScript.get_script_constant_map()
	cap = int(instConsts.get("MAX_PLAYERS_PER_INSTANCE", 0))
	shards = int(agentConsts.get("MAX_SHARDS_PER_FAMILY", 0))
	zoneBase = int(policyConsts.get("ZoneInstanceBase", 0))
	bossBase = int(policyConsts.get("BossInstanceBase", 0))
	CheckEq(cap, 20, "WorldInstance.MAX_PLAYERS_PER_INSTANCE continua 20 (número citado em deploy/SCALING.md)")
	Check(shards >= 2, "WorldAgent.MAX_SHARDS_PER_FAMILY = %d — busca com teto, não passo único" % shards)
	CheckEq(zoneBase, 1000, "IdlePolicyService.ZoneInstanceBase = 1000 (fronteira da numeração shardável)")
	Check(shards * cap <= zoneBase, "%d shards x %d = %d cabe(m) abaixo de #%d: a janela não come a numeração dedicada" % [shards, cap, shards * cap, zoneBase])

	# --- 1) fronteira da busca, sem tocar em dado nenhum
	Check(bool(worldAgentScript.call("IsShardableInstance", 0)), "#0 é shardável")
	Check(bool(worldAgentScript.call("IsShardableInstance", zoneBase - 1)), "#%d é shardável" % (zoneBase - 1))
	Check(not bool(worldAgentScript.call("IsShardableInstance", zoneBase)), "#%d (zona de farm) NÃO é shardável" % zoneBase)
	Check(not bool(worldAgentScript.call("IsShardableInstance", bossBase)), "#%d (arena de boss) NÃO é shardável" % bossBase)
	Check(not bool(worldAgentScript.call("IsShardableInstance", -1)), "id negativo NÃO é shardável")

	# Mapa de trabalho: um onde o servidor JÁ prova que sabe posicionar agente —
	# nav sincronizado E mobs do boot criados na instância #0 (é `WorldInstance
	# ._map_loaded` quem os cria, pelo mesmo `WorldNavigation.GetSpawnPosition` que
	# o player usa; se #0 tem mobs, spawnar player ali funciona). Mapa sem nav
	# pronto devolve Vector2i.ZERO e `CreateAgent` recusa — escolher "o primeiro
	# mapa com spawn de MONSTER" pegou Candor Cave e 0 players nasceram.
	var mapObj : Object = null
	var areas : Dictionary = world.get("areas")
	for attempt in range(60):
		for mapID in areas:
			var candidate : Object = areas[mapID]
			if candidate == null or not (candidate.get("instances") as Dictionary).has(0):
				continue
			if _MonsterSpawn(candidate) == null:
				continue
			if int(NavigationServer2D.map_get_iteration_id(candidate.get("mapRID"))) <= 0:
				continue
			var bootInst : Object = (candidate.get("instances") as Dictionary).get(0, null)
			if bootInst == null or (bootInst.get("mobs") as Array).is_empty():
				continue
			mapObj = candidate
			break
		if mapObj != null:
			break
		await create_timer(0.25).timeout
	if not Check(mapObj != null, "um mapa do boot com nav pronto, mobs em #0 e spawn de MONSTER (%s)" % str(mapObj.get("name") if mapObj else "?")):
		await _finish()
		return
	var instances : Dictionary = mapObj.get("instances")
	var baseID : int = 0

	# --- 2) 41 players pelo caminho real
	Note("semeando %d players em #%d de %s via WorldAgent.CreateAgent..." % [Seed41, baseID, str(mapObj.get("name"))])
	for i in range(Seed41):
		if _SeedPlayer(mapObj, baseID, i + 1) == null:
			break
	await _Frames(6)
	CheckEq(seeded, Seed41, "%d players criados pelo caminho de produção (nenhum recusado)" % Seed41)
	_AssertPacked(mapObj, baseID, "41 players")
	_AssertFamilyInvariants(mapObj, baseID, "41 players", Seed41)
	CheckEq(_ids(mapObj, baseID).size(), 3, "exatamente 3 instâncias para 41 players (20/20/1) — o 21º não abriu balde")
	CheckEq(int(worldAgentScript.call("FamilyFreeSlots", mapObj, baseID)), shards * cap - Seed41,
			"FamilyFreeSlots = %d*%d-%d = %d" % [shards, cap, Seed41, shards * cap - Seed41])
	if seeded < Seed41:
		Note("distribuição parcial (%s) — sem base para as checks seguintes" % _distText(mapObj, baseID))
		await _finish()
		return

	# --- 3) o caminho de WARP obedece ao mesmo teto
	var warpAgent : Node = _SeedPlayer(mapObj, baseID, seeded + 1)
	if Check(warpAgent != null, "42º player criado"):
		var inst0 : Object = instances.get(baseID, null)
		var before : int = (inst0.get("players") as Array).size()
		Check(before >= cap, "#%d está cheia (%d) antes do warp, senão o teste não vale" % [baseID, before])
		var unknownDir : int = int(actorCommonsScript.get_script_constant_map().get("Direction", {}).get("UNKNOWN", 0))
		world.call("Warp", warpAgent, mapObj, (_MonsterSpawn(mapObj).get("spawn_position") as Vector2i), unknownDir, baseID)
		await _Frames(6)
		CheckEq((inst0.get("players") as Array).size(), before, "Warp com instanceID #%d não estourou a instância cheia" % baseID)
		var listed : Object = warpAgent.get("listedIn")
		Check(listed != null and int(listed.get("id")) != baseID, "com a base cheia, o warp caiu em #%s (busca, não a instância pedida)" % str(listed.get("id") if listed else "?"))
		_AssertFamilyInvariants(mapObj, baseID, "warp", seeded)

	# --- 4) 61 players → 20/20/20/1 (o balde antigo daria 20/41)
	Note("semeando até %d players..." % Seed61)
	while seeded < Seed61:
		if _SeedPlayer(mapObj, baseID, seeded + 1) == null:
			break
	await _Frames(6)
	CheckEq(seeded, Seed61, "%d players no mapa pelo caminho real" % Seed61)
	_AssertPacked(mapObj, baseID, "61 players")
	_AssertFamilyInvariants(mapObj, baseID, "61 players", Seed61)
	CheckEq(int(worldAgentScript.call("FamilyFreeSlots", mapObj, baseID)), shards * cap - Seed61, "FamilyFreeSlots bate com a contagem")

	# --- 5) buraco deixado por instância vazia é REAPROVEITADO
	var familyIDs : Array = _ids(mapObj, baseID)
	var lastID : int = int(familyIDs[familyIDs.size() - 1])
	var lastInst : Object = instances.get(lastID, null)
	if Check(lastInst != null, "instância #%d existe para o teste de buraco" % lastID):
		var doomed : Array = (lastInst.get("players") as Array).duplicate()
		for player in doomed:
			_Drop(player)
		await _Frames(8)
		Check(not instances.has(lastID), "#%d ficou vazia e foi destruída (DestroyEmptyInstanceIfUnchanged)" % lastID)
		var refill : Node = _SeedPlayer(mapObj, baseID, seeded + 1)
		if Check(refill != null, "player seguinte após o buraco"):
			var landed : Object = refill.get("listedIn")
			CheckEq(int(landed.get("id")) if landed else -1, lastID, "reaproveitou o id #%d em vez de empilhar um novo" % lastID)
			_AssertFamilyInvariants(mapObj, baseID, "reuso de buraco", seeded)

	# --- 6) janela limitada: base 999 cheia devolve null e NÃO invade a numeração dedicada
	var edgeID : int = zoneBase - 1
	var edge : Object = instances.get(edgeID, null)
	if edge == null:
		edge = mapObj.call("CreateInstance", edgeID)
	await _Frames(8)
	if Check(edge != null, "instância #%d criada para o teste de fronteira" % edgeID):
		var packed : int = 0
		for player in agents.duplicate():
			if packed >= cap:
				break
			if player != null and is_instance_valid(player) and player.get("listedIn") != edge:
				_Move(player, edge)
				packed += 1
		await _Frames(6)
		CheckEq((edge.get("players") as Array).size(), cap, "#%d lotada com %d players" % [edgeID, cap])
		CheckEq(worldAgentScript.call("ResolvePlayerInstance", mapObj, edgeID), null,
				"busca com #%d cheia devolve null — não pula para #%d" % [edgeID, zoneBase])
		Check(not instances.has(zoneBase), "#%d não nasceu de estouro de shard" % zoneBase)
		Check(not instances.has(bossBase), "#%d não nasceu de estouro de shard" % bossBase)
		CheckEq(int(worldAgentScript.call("FamilyFreeSlots", mapObj, edgeID)), 0, "FamilyFreeSlots da janela cheia = 0")
		var refused : Node = worldAgentScript.call("CreateAgent", _PlayerSpawn(mapObj), edgeID, "%sEDGE" % NickPrefix) as Node
		Check(refused == null, "CreateAgent recusa o spawn com a família cheia, em vez de estourar a lotação")
		var stray : Node = null
		for player in agents:
			if player != null and is_instance_valid(player) and player.get("listedIn") != edge:
				stray = player
				break
		if Check(stray != null, "sobrou um player fora de #%d para o teste de bypass" % edgeID):
			var sizeBefore : int = (edge.get("players") as Array).size()
			world.call("Spawn", mapObj, stray, edgeID)
			await _Frames(4)
			CheckEq((edge.get("players") as Array).size(), sizeBefore, "World.Spawn não acrescentou à instância cheia (bypass fechado)")
			Check(stray.get("listedIn") != edge, "o player recusado não entrou na lista de #%d" % edgeID)

	# --- 7) id dedicado NÃO é shardado (a ZonePolicy mora no id)
	var zone : Object = farmScript.call("GetZone", 1)
	if Check(zone != null, "FarmZoneData.GetZone(1) existe"):
		var farmMap : Object = world.call("GetMap", int(zone.get("mapID")))
		if Check(farmMap != null, "mapa da zona 1 instantado (%s)" % str(farmMap.get("name") if farmMap else "?")):
			var farmID : int = int(policyScript.call("GetFarmInstanceID", 1))
			var farmInst : Object = farmMap.call("CreateInstance", farmID)
			await _Frames(8)
			if Check(farmInst != null, "instância dedicada #%d (ZoneInstanceBase + 1) criada" % farmID):
				var movedFarm : int = 0
				for player in agents:
					if movedFarm >= cap + 1:
						break
					if player != null and is_instance_valid(player) and player.get("listedIn") != farmInst:
						_Move(player, farmInst)
						movedFarm += 1
				await _Frames(6)
				CheckEq(movedFarm, cap + 1, "%d players (cap+1) na instância dedicada #%d" % [movedFarm, farmID])
				var same : Object = worldAgentScript.call("ResolvePlayerInstance", farmMap, farmID)
				Check(same == farmInst, "a busca devolve a PRÓPRIA #%d lotada — id dedicado não é shardado" % farmID)
				Check(not (farmMap.get("instances") as Dictionary).has(farmID + 1),
						"#%d não nasceu: mover o player de id sem mover a ZonePolicy dele derruba a sessão idle" % (farmID + 1))
				# devolve para a família pública antes das checks de mob
				for player in (farmInst.get("players") as Array).duplicate():
					var home : Object = worldAgentScript.call("ResolvePlayerInstance", mapObj, baseID)
					if home != null:
						_Move(player, home)
				await _Frames(6)

	# --- 8) mob não é shardado
	var instancesBefore : int = instances.size()
	var family0 : Object = instances.get(baseID, null)
	var monsterSpawn : Object = _MonsterSpawn(mapObj)
	if Check(family0 != null and monsterSpawn != null, "instância #%d e um spawn de MONSTER disponíveis" % baseID):
		var fullAgain : int = (family0.get("players") as Array).size()
		var mob : Node = worldAgentScript.call("CreateAgent", monsterSpawn, baseID, str(monsterSpawn.get("nick"))) as Node
		await _Frames(4)
		Check(mob != null, "mob criado pelo mesmo CreateAgent (com #%d em %d players)" % [baseID, fullAgain])
		if mob != null:
			var mobInst : Object = mob.get("listedIn")
			CheckEq(int(mobInst.get("id")) if mobInst else -1, baseID, "mob ficou na instância de quem o chamou, sem shard")
		CheckEq(instances.size(), instancesBefore, "spawn de mob não abriu shard novo (antes %d, agora %d instâncias)" % [instancesBefore, instances.size()])

	# --- 9) a espera na queryMutex
	TestMutexMetric()

	await _finish()

func TestMutexMetric() -> void:
	print("-- espera na queryMutex (sources/sql/SQL.gd:1424) --")
	var stats0 : Dictionary = sql.call("QueryMutexWaitStats")
	for key in ["waits", "microseconds", "maxMicroseconds", "over1ms", "over10ms", "over100ms"]:
		Check(stats0.has(key), "QueryMutexWaitStats() expõe '%s'" % key)
	if not Check(int(stats0.get("waits", 0)) > 0, "o boot já rodou seção crítica (%d entrada(s))" % int(stats0.get("waits", 0))):
		return
	Check(float(sql.call("QueryMutexWaitSeconds")) >= 0.0, "QueryMutexWaitSeconds() não-negativo")
	sql.call("QueryMutexWaitStats")
	sql.call("QueryMutexWaitStats")
	CheckEq(int((sql.call("QueryMutexWaitStats") as Dictionary).get("waits", -1)), int(stats0.get("waits", -2)),
			"ler a estatística não conta como round trip (usa a mutex crua de propósito)")

	var writeSQL : String = "UPDATE stat SET gp = gp WHERE char_id = ?;"
	CheckEq(bool(sql.call("ReadWouldRoute", writeSQL)), false, "UPDATE não é roteado para o pool: pega a mutex")
	var before : int = int((sql.call("QueryMutexWaitStats") as Dictionary).get("waits", 0))
	sql.call("ExecuteBindings", writeSQL, [int(charIDs[0]) if not charIDs.is_empty() else 0])
	var after : int = int((sql.call("QueryMutexWaitStats") as Dictionary).get("waits", 0))
	CheckEq(after - before, 1, "ExecuteBindings() passou pela seção crítica contada (+1)")

	var readSQL : String = "SELECT 1 AS one;"
	var routed : bool = bool(sql.call("ReadWouldRoute", readSQL))
	var waitsB : int = int((sql.call("QueryMutexWaitStats") as Dictionary).get("waits", 0))
	var queriesB : int = int(sql.call("QueryCount"))
	sql.call("Query", readSQL)
	var waitsA : int = int((sql.call("QueryMutexWaitStats") as Dictionary).get("waits", 0))
	var queriesA : int = int(sql.call("QueryCount"))
	CheckEq(queriesA - queriesB, 1, "Query() conta como round trip, roteada ou não")
	CheckEq(waitsA - waitsB, 0 if routed else 1, "leitura %s conta %d espera(s) na mutex" % ["roteada" if routed else "no caminho histórico (pool indisponível)", 0 if routed else 1])

	var stats1 : Dictionary = sql.call("QueryMutexWaitStats")
	Check(int(stats1.get("over1ms", 0)) >= int(stats1.get("over10ms", 0)) and int(stats1.get("over10ms", 0)) >= int(stats1.get("over100ms", 0)),
			"degrades monotônicos (>=1ms >= >=10ms >= >=100ms)")
	Check(int(stats1.get("over1ms", 0)) <= int(stats1.get("waits", 0)), "esperas acima de 1 ms são subconjunto das entradas totais")
	Check(int(stats1.get("maxMicroseconds", 0)) <= int(stats1.get("microseconds", 0)),
			"pico (%d us) <= soma (%d us)" % [int(stats1.get("maxMicroseconds", 0)), int(stats1.get("microseconds", 0))])
	Note("mutex: %d entradas, %.3f ms acumulados, pico %.3f ms, cauda >1ms/>10ms/>100ms = %d/%d/%d" % [
		int(stats1.get("waits", 0)), float(stats1.get("microseconds", 0)) / 1000.0,
		float(stats1.get("maxMicroseconds", 0)) / 1000.0, int(stats1.get("over1ms", 0)),
		int(stats1.get("over10ms", 0)), int(stats1.get("over100ms", 0))])
	sql.call("ResetCounters")
	CheckEq(int((sql.call("QueryMutexWaitStats") as Dictionary).get("waits", -1)), 0,
			"ResetCounters() zera as esperas (o /metrics é counter; o processo zera no boot)")

func _finish() -> void:
	print("-- limpeza --")
	for agent in agents.duplicate():
		_Drop(agent)
	await _Frames(8)
	if sql != null and not charIDs.is_empty():
		sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname LIKE ?;", ["%s%%" % NickPrefix])
		sql.call("ExecuteBindings", "DELETE FROM account WHERE username LIKE ?;", ["%s%%" % AcctPrefix])
		Note("fixtures %s* removidos (%d chars)" % [NickPrefix, charIDs.size()])
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
