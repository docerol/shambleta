extends Node
class_name WorldAgent

static var agents : Dictionary[int, BaseAgent]		= {}
static var _agentsMutex : Mutex = Mutex.new()
static var defaultSpawnLocation : SpawnObject		= SpawnObject.new()
# P2 — escalabilidade: raio de visibilidade para limitar notificações de rede.
const VISIBLE_RADIUS_SQUARED : float = 200.0

# P1 — escalabilidade: teto de shards por família de instância. Com
# WorldInstance.MAX_PLAYERS_PER_INSTANCE = 20 isso são 640 players num mesmo mapa
# público antes de `ResolvePlayerInstance` devolver null (e o chamador recusar o
# spawn em vez de estourar a lotação). É escolha de projeto, não medida: o que foi
# medido é o teto de tick do processo, que chega muito antes disto — número, método
# e motivo em `deploy/SCALING.md`.
const MAX_SHARDS_PER_FAMILY : int = 32

# From Agent getters
static func GetInstanceFromAgent(agent : BaseAgent) -> SubViewport:
	return agent.get_parent()

static func GetMapFromAgent(agent : BaseAgent) -> WorldMap:
	var map : WorldMap = null
	var inst : WorldInstance = GetInstanceFromAgent(agent)
	if inst:
		if inst == null or inst.map == null:
			push_error("Agent's base map is incorrect, instance is not referenced inside a map")
			return null
		map = inst.map
	return map

# Basic Agent container handling
static func GetAgent(agentRID : int) -> BaseAgent:
	var agent : BaseAgent = null
	_agentsMutex.lock()
	if agents.has(agentRID):
		agent = agents.get(agentRID)
	_agentsMutex.unlock()
	return agent

static func AddAgent(agent : BaseAgent):
	if agent == null:
		push_error("Agent is null, can't add it")
		return
	var agentRID : int = agent.get_rid().get_id()
	_agentsMutex.lock()
	if not agents.has(agentRID):
		agents[agentRID] = agent
	_agentsMutex.unlock()

static func RemoveAgent(agent : BaseAgent):
	if agent == null:
		push_error("Agent is null, can't remove it")
		return
	if agent:
		if agent is AIAgent:
			var inst : WorldInstance = agent.get_parent()
			if inst and inst.timers and agent.spawnInfo and agent.spawnInfo.is_persistant:
				Callback.SelfDestructTimer(inst.timers, agent.spawnInfo.respawn_delay, WorldAgent.CreateAgent, [agent.spawnInfo, inst.id])
			if agent.leader != null:
				agent.leader.RemoveFollower(agent)

		PopAgent(agent)
		_agentsMutex.lock()
		agents.erase(agent.get_rid().get_id())
		_agentsMutex.unlock()
		agent.queue_free()

static func PopAgent(agent : BaseAgent):
	if agent == null:
		push_error("Agent is null, can't pop it")
		return
	if agent:
		# A lista é a autoridade, não a árvore: entre PushAgent e o add_child adiado
		# o agente está listado sem ter pai — derivar a instância de get_parent()
		# apagava de lugar nenhum e deixava objeto liberado pendurado na lista.
		var inst : WorldInstance = agent.listedIn as WorldInstance
		agent.listedIn = null
		if inst:
			agent.set_physics_process(false)
			if agent is PlayerAgent:
				inst.players.erase(agent)
				agent.visibleAgents.clear()
			elif agent is MonsterAgent:
				inst.mobs.erase(agent)
			elif agent is NpcAgent:
				inst.npcs.erase(agent)
			if inst.players.is_empty():
				if inst.id != 0 and inst.map:
					inst.map.DestroyEmptyInstanceIfUnchanged.call_deferred(inst.id, inst)
				else:
					inst.QueryProcessMode()
			else:
				var agentRID : int = agent.get_rid().get_id()
				for neighbour in inst.players:
					if neighbour and neighbour.visibleAgents.has(agentRID):
						# P2 — limite de raio: só notifica vizinhos dentro do raio de visibilidade.
						if agent.position.distance_squared_to(neighbour.position) < WorldAgent.VISIBLE_RADIUS_SQUARED:
							Network.Bulk("RemoveEntity", [agentRID], neighbour.peerID)
						neighbour.visibleAgents.erase(agentRID)
			# Desanexa de onde o agente ESTÁ, que no meio de um warp é a instância
			# antiga (a lista já aponta a nova, o add_child ainda não rodou).
			var parent : Node = agent.get_parent()
			if parent:
				parent.remove_child(agent)

static func PushAgent(agent : BaseAgent, inst : WorldInstance):
	if agent == null:
		push_error("Agent is null, can't push it")
		return
	if inst == null:
		push_error("Instance is null, can't push the agent in it")
		return
	if agent and inst:
		agent.set_physics_process(true)
		agent.listedIn = inst
		if agent is PlayerAgent:
			inst.players.push_back(agent)
			inst.RefreshProcessMode()
		elif agent is MonsterAgent:
			inst.mobs.push_back(agent)
		elif agent is NpcAgent:
			inst.npcs.push_back(agent)

		# SOM-IDLE: F2 — idempotent deferred push: two pushes queued in the same
		# frame (CreateAgent → Warp, e.g. spawn straight into a farm instance)
		# used to collide ("already has a parent"). Converge to the last target.
		_DeferredPush.call_deferred(agent, inst)
	else:
		RemoveAgent(agent)

static func _DeferredPush(agent : BaseAgent, inst : WorldInstance):
	if not is_instance_valid(agent) or not is_instance_valid(inst) or agent.is_queued_for_deletion():
		return
	var parent : Node = agent.get_parent()
	if parent == inst:
		return
	if parent != null:
		parent.remove_child(agent)
	inst.add_child(agent)

# Uma instância é dividida em shards só na numeração "pública" do mapa. Acima de
# `IdlePolicyService.ZoneInstanceBase` o id é CONTRATO de outro subsistema: a zona
# de farm é procurada por `ZoneInstanceBase + zoneID`
# (sources/idle/IdlePolicyService.gd:9-24) e a arena de boss é privada por char
# (`BossInstanceBase + charID`, sources/idle/IdlePolicyService.gd:9) — mover o
# jogador para outro id sem mover a policy dele é o que quebraria a sessão idle,
# não a lotação. O cap que vale nesses ids é o do tick, medido em
# `deploy/SCALING.md` / `tests/tick_capacity_test.gd`.
static func IsShardableInstance(instanceID : int) -> bool:
	return instanceID >= 0 and instanceID < IdlePolicyService.ZoneInstanceBase

# Devolve a instância da família de `baseID` que ainda comporta MAIS UM player, ou
# null quando a família está cheia. Percorre `base`, `base+1`, ... `base +
# MAX_SHARDS_PER_FAMILY - 1`; onde não existe instância, cria ali (reaproveitando
# buraco deixado por `DestroyEmptyInstanceIfUnchanged`, sources/world/WorldMap.gd:55)
# e para. Nunca cria uma segunda quando a primeira tem vaga, nem entrega uma cheia.
static func ResolvePlayerInstance(map : WorldMap, baseID : int) -> WorldInstance:
	if map == null:
		return null
	if not IsShardableInstance(baseID):
		return map.instances.get(baseID, null)
	for shard in range(MAX_SHARDS_PER_FAMILY):
		var instID : int = baseID + shard
		if not IsShardableInstance(instID):
			return null
		var inst : WorldInstance = map.instances.get(instID, null)
		if inst == null:
			return map.CreateInstance(instID)
		if inst.players.size() < WorldInstance.MAX_PLAYERS_PER_INSTANCE:
			return inst
	return null

# Quantos players ainda cabem na família de `baseID` — usado pelo harness de
# medição e por qualquer diagnóstico de lotação; não tem efeito no caminho quente.
static func FamilyFreeSlots(map : WorldMap, baseID : int) -> int:
	if map == null or not IsShardableInstance(baseID):
		return 0
	var free : int = 0
	for shard in range(MAX_SHARDS_PER_FAMILY):
		var instID : int = baseID + shard
		if not IsShardableInstance(instID):
			break
		var inst : WorldInstance = map.instances.get(instID, null)
		if inst == null:
			free += WorldInstance.MAX_PLAYERS_PER_INSTANCE
			continue
		free += maxi(WorldInstance.MAX_PLAYERS_PER_INSTANCE - inst.players.size(), 0)
	return free

static func CreateAgent(spawn : SpawnObject, instanceID : int = 0, nickname : String = "") -> BaseAgent:
	if not spawn or not spawn.map:
		return null

	var agent : BaseAgent = null
	var data : EntityData = DB.EntitiesDB.get(spawn.id, null)
	if not data:
		return null

	var inst : WorldInstance = spawn.map.instances.get(instanceID, null)
	if not inst:
		return null

	# P1 — escalabilidade: cap de players por instância, com BUSCA LIMITADA de
	# shard. A versão anterior dava UM passo (`instanceID + 1`) e nunca re-conferia
	# a lotação do destino: o 21º, o 22º e todos os seguintes entravam em `base+1`,
	# que virava balde e não segunda instância. A invariante agora é "nenhuma
	# instância da família passa de MAX_PLAYERS_PER_INSTANCE, e a próxima só nasce
	# quando todas as existentes estão cheias" — provada com 41/61 players em
	# `tests/shard_capacity_test.gd`.
	#
	# Só player é shardado. Mob/NPC pertencem à instância de quem os chamou:
	# `WorldInstance._map_loaded` (sources/world/WorldInstance.gd:57-78) e o respawn
	# de farm criam os mobs com o id da própria zona, e empurrá-los para `id+1`
	# fabricava uma instância órfã de mobs que ninguém vê, com o timer de respawn
	# preso nela.
	if spawn.type == ActorCommons.Type.PLAYER:
		var target : WorldInstance = ResolvePlayerInstance(spawn.map, instanceID)
		if target == null:
			push_error("WorldAgent: sem instância com vaga para player (mapa %s, base %d)" % [spawn.map.id, instanceID])
			return null
		inst = target
		instanceID = target.id

	var position : Vector2i = WorldNavigation.GetSpawnPosition(inst, spawn)
	if position == Vector2i.ZERO:
		return null

	agent = Instantiate.CreateAgent(spawn, data, spawn.nick if nickname.length() == 0 else nickname)
	if not agent:
		return null

	AddAgent(agent)
	Launcher.World.Warp(agent, spawn.map, position, ActorCommons.Direction.UNKNOWN, instanceID)
	return agent

static func _post_launch():
	defaultSpawnLocation.map				= Launcher.World.GetMap(LauncherCommons.DefaultStartMapID)
	defaultSpawnLocation.spawn_position		= LauncherCommons.DefaultStartPos
	defaultSpawnLocation.spawn_offset		= LauncherCommons.DefaultStartOffset
	defaultSpawnLocation.type				= ActorCommons.Type.PLAYER
	defaultSpawnLocation.id					= DB.PlayerHash
