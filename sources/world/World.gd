extends ServiceBase
class_name WorldService

# Vars
var areas : Dictionary[int, WorldMap]				= {}
var commands : WorldCommands						= WorldCommands.new()
var canary : ShutdownCanary							= ShutdownCanary.new()
# Auto-idle watchdog: acumulador de 1s (policies rodam no physics; isto é só presença).
var _autoIdleAccum : float							= 0.0

func _process(delta : float) -> void:
	_autoIdleAccum += delta
	if _autoIdleAccum >= 1.0:
		# §12 (AUDITORIA_2026-09-27): presença durável no MESMO acumulador de 1 s — o
		# heartbeat e a poda dele são uma statement cada e só disparam na própria
		# cadência, então o tick não acrescenta trabalho por frame. Não mora no worker
		# de backup: o `SQLBackups.new()` de `_post_launch` (`sources/sql/SQL.gd:@_post_launch`) não roda sob debug
		# nem na build web, e presença tem que viver enquanto o mundo roda.
		Presence.Tick(Launcher.SQL, _autoIdleAccum, int(Time.get_unix_time_from_system()))
		_autoIdleAccum = 0.0
		IdlePolicyService.TickAutoIdle()
		# #125: o checkpoint do WAL tem dono, e o dono é este tick — não o commit do
		# próximo jogador. `MaybeCheckpoint()` decide por CADÊNCIA DE TRABALHO, então
		# servidor parado não paga fsync nenhum e servidor em movimento drena fora do
		# caminho quente. Aqui é endereço de conveniência, não o único gatilho.
		Launcher.SQL.MaybeCheckpoint()
	# Drena o passe de persistência em slices curtos (um chunk por frame). O worker
	# só marca o início; o esvaziamento roda no thread principal, então cada fatia
	# segura o queryMutex por pouco tempo e as writes de RPC não esperam um burst.
	if _backupActive:
		StepBackupPass()

# Getters
func GetMap(mapID : int) -> WorldMap:
	return areas.get(mapID, null)

func GetGlobalPlayer(nickname : String) -> PlayerAgent:
	for areaIdx in areas:
		var area = areas[areaIdx]
		for inst in area.instances.values():
			for player in inst.players:
				if player.nick == nickname:
					return player
	return null

func GetGlobalNpc(nickname : String) -> NpcAgent:
	for areaIdx in areas:
		var area = areas[areaIdx]
		for inst in area.instances.values():
			for npc in inst.npcs:
				if npc.nick == nickname:
					return npc
	return null

# Helper
func BulkPreload(agent : BaseAgent, agentRID : int, peerID : int):
	if agent is PlayerAgent:
		Network.Bulk("PreloadPlayer", [
			agentRID, agent.stat.spirit, agent.stat.currentShape, agent.nick,
			agent.stat.level, agent.stat.health,
			agent.stat.hairstyle, agent.stat.haircolor,
			agent.stat.gender, agent.stat.race, agent.stat.skintone,
			agent.inventory.ExportEquipment() if agent.inventory else {}
		], peerID)
	else:
		Network.Bulk("PreloadEntity", [
			agentRID, agent.GetActorType(), agent.stat.currentShape, agent.nick, agent.defaultState
		], peerID)

# Core functions
func Warp(agent : BaseAgent, newMap : WorldMap, newPos : Vector2i, direction : ActorCommons.Direction, instanceID : int = 0):
	if newMap == null or agent == null:
		push_error("Warp could not proceed, agent or new map missing")
		return
	if agent and newMap:
		if agent is PlayerAgent:
			var currentMap : WorldMap = WorldAgent.GetMapFromAgent(agent)
			if currentMap and currentMap.HasFlags(WorldMap.Flags.ONLY_SPIRIT) and not newMap.HasFlags(WorldMap.Flags.ONLY_SPIRIT):
				agent.Morph(false, agent.stat.shape)

		# Force reset velocity to prevent any input residue due to the map transition
		agent._velocity_computed(Vector2.ZERO)
		agent.currentVelocity = Vector2.ZERO
		agent.velocity = Vector2.ZERO
		if agent is PlayerAgent:
			agent.isWarping = true
		WorldAgent.PopAgent(agent)
		if not agent.isRelativeMode:
			agent.SwitchInputMode(true)

		agent.position = newPos
		if direction != ActorCommons.Direction.UNKNOWN:
			agent.currentOrientation = ActorCommons.GetDirectionFromEnum(direction)

		Spawn(newMap, agent, instanceID)

func Spawn(map : WorldMap, agent : BaseAgent, instanceID : int = 0):
	if map == null or not map.instances.has(instanceID) or agent == null:
		push_error("Spawn could not proceed, agent or map missing")
		return
	if map and map.instances.has(instanceID) and agent:
		var inst : WorldInstance = map.instances[instanceID]
		if inst == null:
			push_error("Spawn could not proceed, map instance missing")
			return

		# P1 — escalabilidade: o cap também vale para quem entra por `Warp`, e até
		# aqui ele NÃO valia: `Spawn` pegava `map.instances[instanceID]` e empurrava
		# o player na lista fosse qual fosse a lotação. Como todo warp de NPC/porta
		# cai em `NpcCommons.Warp` com instanceID 0
		# (sources/actor/agent/NpcCommons.gd:@Warp) — e `PlayerAgent.WarpTo` passa
		# `dest.instance` (sources/actor/agent/variants/PlayerAgent.gd:280), campo que
		# `GetDestinationFromData` (`sources/actor/agent/variants/PlayerAgent.gd:@GetDestinationFromData`)
		# nunca preenche: só o caminho de login respeitava o teto. Mesma busca do
		# `CreateAgent`, então os dois caminhos concordam por construção e não por cópia.
		if agent is PlayerAgent:
			var target : WorldInstance = WorldAgent.ResolvePlayerInstance(map, instanceID)
			if target == null:
				push_error("Spawn could not proceed, no free instance in family %d" % instanceID)
				return
			inst = target

		if inst:
			if agent.is_node_ready():
				AgentCreated(agent, map.mapRID)
			else:
				Callback.OneShotCallback(agent.ready, AgentCreated, [agent, map.mapRID])
			Callback.OneShotCallback(agent.tree_entered, AgentWarped, [map, agent])
			WorldAgent.PushAgent(agent, inst)

func ClearWarpFlag(agent : PlayerAgent):
	if agent and agent.is_inside_tree():
		await agent.get_tree().physics_frame
		agent.isWarping = false
		agent.warp_confirmed.emit()

func AgentCreated(agent : BaseAgent, mapRID : RID):
	if agent and agent.agent:
		agent.agent.set_navigation_map(mapRID)

func AgentWarped(map : WorldMap, agent : BaseAgent):
	if agent == null:
		return

	if agent is PlayerAgent:
		if agent.peerID == NetworkCommons.PeerUnknownID:
			return

		if map.HasFlags(WorldMap.Flags.ONLY_SPIRIT):
			if not agent.stat.IsMorph():
				agent.Morph(false, agent.stat.spirit)

		Network.WarpPlayer(map.id, agent.position, agent.peerID)
		ClearWarpFlag(agent)
		agent.visibleAgents.clear()
		var instance : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)
		if instance:
			var agentRID : int = agent.get_rid().get_id()
			for neighbour in instance.players:
				if neighbour:
					var neighbourRID : int = neighbour.get_rid().get_id()
					BulkPreload(neighbour, neighbourRID, agent.peerID)
			for neighbour in instance.npcs:
				if neighbour and neighbour.isVisible:
					var neighbourRID : int = neighbour.get_rid().get_id()
					BulkPreload(neighbour, neighbourRID, agent.peerID)
			for neighbour in instance.mobs:
				if neighbour:
					var neighbourRID : int = neighbour.get_rid().get_id()
					BulkPreload(neighbour, neighbourRID, agent.peerID)

			# Spawn self
			Network.Bulk("FullUpdateEntity", [
				agentRID, agent.velocity, agent.position, agent.currentOrientation,
				agent.state, agent.currentSkillID, agent.stat.isRunning, NetworkCommons.FrameID()
			], agent.peerID)

			# Notify existing players about the new arrival
			for player in instance.players:
				if player and player != agent and player.peerID != NetworkCommons.PeerUnknownID:
					BulkPreload(agent, agentRID, player.peerID)
	else:
		var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)
		var agentRID : int = agent.get_rid().get_id()
		if inst:
			for player in inst.players:
				if player and player.peerID != NetworkCommons.PeerUnknownID:
					BulkPreload(agent, agentRID, player.peerID)

# Generic
# Passe de persistência fatiado (write serialization, P1-5/P2): o worker SQLBackups
# chama BackupPlayers() a cada BackupPlayersSec (600 s) via call_deferred. Antes
# disso era um burst síncrono: um RefreshCharacter (≈ 5 upserts + 1 SELECT por
# tabela) por jogador, todos de uma vez, atrás do queryMutex único — um servidor
# cheio congelava as writes de RPC no meio do laço. Agora o passe congela o
# snapshot e processa no máximo BackupChunkSize por chamada; o resto é drenado em
# World._process. "Todos são persistidos dentro do ciclo" vale porque 600 s é
# ordens de grandeza maior que (jogadores / chunk) frames, e o snapshot é varrido
# antes do próximo passe.
#
# Pendência (não resolvida aqui — posse de outro agente): não há dirty-flag no
# modelo de memória (PlayerAgent/Stat/Progress não expõem "mudou desde a última
# gravação"), então TODO player regravado a cada passe. Sem esse sinal não dá para
# pular quem não mudou; ver relatório.
const BackupChunkSize : int = 16

var _backupQueue : Array = []
var _backupCursor : int = 0
var _backupActive : bool = false

func BackupPlayers():
	_CollectBackupPass()
	StepBackupPass()

func _CollectBackupPass():
	_backupQueue.clear()
	for area : WorldMap in areas.values():
		for inst : WorldInstance in area.instances.values():
			for player : PlayerAgent in inst.players:
				_backupQueue.append(player)
	_backupCursor = 0
	_backupActive = not _backupQueue.is_empty()

# Processa um chunk do passe corrente. Devolve true quando o passe terminou.
func StepBackupPass() -> bool:
	return _RunBackupChunk(_RefreshCharacterSafely)

func _RefreshCharacterSafely(player):
	if player != null and is_instance_valid(player):
		Launcher.SQL.RefreshCharacter(player)

# Avança no máximo BackupChunkSize itens, chamando `saveFn` para cada. `saveFn` é
# injetável para o harness medir o tempo e a invariante de slicing de UM chunk com
# trabalho real contra o DB temporário, sem precisar de PlayerAgents vivos na mesa.
func _RunBackupChunk(saveFn : Callable) -> bool:
	if not _backupActive:
		return true
	var end : int = mini(_backupCursor + BackupChunkSize, _backupQueue.size())
	while _backupCursor < end:
		saveFn.call(_backupQueue[_backupCursor])
		_backupCursor += 1
	_backupActive = _backupCursor < _backupQueue.size()
	return not _backupActive


func _post_launch():
	if not DB.isInitialized:
		if not Launcher.dbInitialized.is_connected(_init_world):
			Launcher.dbInitialized.connect(_init_world, CONNECT_ONE_SHOT)
		return
	_init_world()

func _init_world():
	for mapID in DB.MapsDB:
		areas[mapID] = WorldMap.Create(mapID)
	var variants : int = MobVariant.InjectZoneVariants()
	if variants > 0:
		Util.PrintLog("World", "Mob variants injected: %d spawns" % variants)
	WorldAgent._post_launch()
	canary.Start()
	isInitialized = true

func Destroy():
	for areaIdx in areas:
		areas[areaIdx].Destroy()
	areas.clear()
