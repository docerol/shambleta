extends Node
class_name WorldAgent

static var agents : Dictionary[int, BaseAgent]		= {}
static var _agentsMutex : Mutex = Mutex.new()
static var defaultSpawnLocation : SpawnObject		= SpawnObject.new()
# P2 — escalabilidade: raio de visibilidade para limitar notificações de rede.
const VISIBLE_RADIUS_SQUARED : float = 200.0

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

	# P1 — escalabilidade: se a instância atingiu o cap de players, cria sub-instância automaticamente.
	if inst and inst.players.size() >= WorldInstance.MAX_PLAYERS_PER_INSTANCE:
		var subInstanceID : int = instanceID + 1
		# Se já existe sub-instância para este batch, tenta usá-la; senão cria nova.
		var subInst : WorldInstance = spawn.map.instances.get(subInstanceID, null)
		if not subInst:
			subInst = WorldInstance.Create(spawn.map, subInstanceID)
			if subInst:
				spawn.map.instances[subInstanceID] = subInst
		if subInst:
			inst = subInst
			instanceID = subInstanceID
		else:
			return null

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
