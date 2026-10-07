extends RefCounted
class_name IdlePolicy

# SOM-IDLE: F2 idle-spike policy (TECH_SPEC_CORE.md §2)
# Server-only per-player brain attached to a farming PlayerAgent. Uses exclusively
# existing world primitives: WalkToward, Skill.Cast, WorldDrop.PickupDrop,
# inventory.UseItem — it never writes stats directly.

enum State
{
	IDLE,
	SEEK,
	COMBAT,
	LOOT,
	DEAD,
}

const TickInterval : float = 0.25
const MaxCatchUpSeconds : float = 2.0	# D1 (b): cap pathological pumps at 8 substeps

const SeekInterval : float = 0.4			# re-evaluate target every 0.4s
const LootInterval : float = 0.4
# Raio de coleta: o drop nasce na posição do mob ± `_radius` (`WorldDrop.PushDrop`)
# e o farmer está em alcance de melee quando o mata, então a própria presa está
# sempre aqui. Sem teto, `_findNearestDrop` varre a instância inteira e um drop
# distante de outro jogador arrastava o farmer para fora do farm — e LOOT virava
# o novo estado-presa que DEAD era.
const LootSearchRadius : float = 192.0
const PotionCheckInterval : float = 1.0
const StuckTimeout : float = 8.0
const AttackRangeBuffer : float = 8.0		# walk slightly inside skill range
const EfficiencySampleMinInterval : float = 5.0
const DeathPenalty : float = 0.05
const MinEfficiency : float = 0.5
const RespawnDelay : float = 2.0
# SOM-IDLE D1: farm vigor — policy-driven agents regen stamina/mana fast
# enough to sustain auto-combat (a melee swing costs 10 stamina; base regen
# starves a L1 farmer after ~5 swings and 99% of casts fizzle). Farm instances
# are idle-only, so this never touches live balance, damage or power score.
const FarmVigorStaminaPct : float = 0.5
const FarmVigorManaPct : float = 0.5

#
var agent : PlayerAgent						= null
var zoneID : int							= 0
var state : State							= State.IDLE
var halted : bool							= false

var sessionStartTime : int					= 0
var sessionGameTime : float					= 0.0
var sessionKills : int						= 0
var sessionDeaths : int						= 0
var sessionDowntimeSecs : float				= 0.0

# SOM-IDLE D1: pacing instrumentation (where does farm time go?).
var metricSeekTicks : int						= 0
var metricCombatTicks : int					= 0
var metricLootTicks : int						= 0
var metricNoTargetTicks : int					= 0
var metricAttacksCast : int					= 0
var metricWalkDistance : float					= 0.0
# A esteira de item do farm vivo tem dois elos que já foram código morto (o mob
# não derrubava nada e o farmer não coletava nada), e cada um tem que ter número
# próprio no snapshot: sem `drops_picked` e `potions_used`, "loot_ticks > 0" era
# a única evidência de que o item chegou em alguém.
var metricDropsPicked : int					= 0
var metricPotionsUsed : int					= 0
# O outro lado do mesmo limiar: quantas vezes o HP afundou e a mochila não tinha
# o que beber. Sem este número, `potions_used = 0` não distingue "nunca precisou"
# de "precisou e não tinha", que é exatamente a diferença que a régua da esteira
# afirma quando diz por que o farmer não bebeu.
var metricPotionShortfalls : int			= 0
var _metricLastPos : Vector2					= Vector2.ZERO

var currentTargetRID : int					= 0
# SOM-IDLE: boss-key ladder — quando bossIndex>=0 o char está num duelo de boss:
# persegue e ataca SÓ o boss (bossRID) e uma morte do char é derrota (ApplyXp
# cuida da vitória quando o boss cai). Runtime-only.
var bossRID : int							= 0
var bossIndex : int							= -1
# SOM-GAMEPLAY G1: ORDEM DE PRIORIDADE de cast (skill IDs, 1º = preferida).
# Persistida em formation.skill_loadout (já era um Array[int] ordenado via
# var_to_str — coluna nova nenhuma foi necessária; ver /priority).
var skillLoadout : Array[int]				= []
var autoPotionPct : float					= 35.0

# Internals
var _accumulator : float					= 0.0
var _seekAccumulator : float				= 0.0
var _lootAccumulator : float				= 0.0
var _potionAccumulator : float				= 0.0
var _stuckAccumulator : float				= 0.0
var _lastPosition : Vector2					= Vector2.ZERO
var _respawnAccumulator : float				= 0.0
var _deathDownAccumulator : float			= 0.0
var _lastEfficiencySample : float			= 0.0
var _retargets : int						= 0
var _attackedTarget : bool					= false
var _killRegistered : bool					= false
# SOM-IDLE (2026-09-23): mecânica ativa no duelo de boss. Durante a luta ao vivo
# uma janela de interrupt abre em ciclo; tocar nela (RequestBossInterrupt) pula o
# cooldown do auto-ataque — DPS ~2x para quem aprende a janela, idêntico ao auto
# para quem ignora (o idle continua 100% funcional, sem input obrigatório).
# SOM-IDLE (2026-09-27): a LARGURA do que conta perfect/good é a do boss em duelo
# (BossService.InterruptQuality/InterruptBonus recebem `bossIndex`); este ciclo é
# apenas o relógio da janela aberta, igual para todos.
const InterruptCycleSec : float				= 3.0
const InterruptWindowSec : float			= 1.2
var _interruptTimer : float					= 0.0		# avança só em duelo
var _interruptWindow : bool					= false		# janela aberta (server-side)
var _interruptRequest : bool				= false		# toque do jogador pendente

#
func Setup(pAgent : PlayerAgent, pZoneID : int):
	agent = pAgent
	zoneID = pZoneID
	state = State.IDLE
	halted = false
	_accumulator = 0.0
	_seekAccumulator = 0.0
	_lootAccumulator = 0.0
	_potionAccumulator = 0.0
	_stuckAccumulator = 0.0
	_respawnAccumulator = 0.0
	_deathDownAccumulator = 0.0
	_retargets = 0
	_attackedTarget = false
	_killRegistered = false
	sessionStartTime = Time.get_ticks_msec()
	sessionGameTime = 0.0
	sessionKills = 0
	sessionDeaths = 0
	sessionDowntimeSecs = 0.0
	metricSeekTicks = 0
	metricCombatTicks = 0
	metricLootTicks = 0
	metricNoTargetTicks = 0
	metricAttacksCast = 0
	metricWalkDistance = 0.0
	metricDropsPicked = 0
	metricPotionsUsed = 0
	metricPotionShortfalls = 0
	_lastPosition = agent.position if agent else Vector2.ZERO
	_metricLastPos = _lastPosition

func Halt():
	halted = true

func Resume():
	halted = false

# ------------------------------------------------------------------ tick

func Tick(delta : float):
	if halted or not _isValid():
		return

	sessionGameTime += delta
	if agent:
		metricWalkDistance += agent.position.distance_to(_metricLastPos)
		_metricLastPos = agent.position

	# SOM-IDLE D1 (b): fixed-cadence substeps. The pump (WorldInstance) runs on
	# the physics clock; under load or time compression one call can carry a
	# huge delta (timeScale 20 -> 0.667 game-s per step). Driving the state
	# machine in TickInterval-sized GAME seconds keeps pacing identical no
	# matter how the host machine schedules frames/steps.
	_accumulator = minf(_accumulator + delta, MaxCatchUpSeconds)
	while _accumulator >= TickInterval:
		_accumulator -= TickInterval
		_tickStep(TickInterval)

# One decision tick — all cooldowns/accumulators below advance in game seconds.
func _tickStep(delta : float):
	_tickVigor(delta)

	# SOM-IDLE: boss duel — se o farmer caiu enquanto o boss ainda vive, é
	# derrota (a chave já foi gasta no desafio). Consolação + limpa o duelo; a
	# vitória chega por outro caminho (Formula.ApplyXp quando o boss morre).
	if bossIndex >= 0 and not ActorCommons.IsAlive(agent):
		var lostIndex : int = bossIndex
		bossIndex = -1
		bossRID = 0
		currentTargetRID = 0
		InterruptBossReset()
		IdlePolicyService.OnBossResult(agent, lostIndex, false)
		return

	# A morte do ATOR é a única autoridade de DEAD. Sem esta linha ninguém entrava
	# em State.DEAD (não havia produtor no arquivo) e `_tickDead` — o único revive
	# do idle — era código morto: o farmer caía, `ActorCommons.State.DEATH` é
	# absorvente na tabela, `_velocity_computed` trava currentVelocity em ZERO para
	# estado != WALK, e a policy ficava COMBAT mandando WalkToward para um corpo.
	# Medido 2026-09-27 com `tests/diag_pacing.gd` a 1× (L1, zona 1): 4 kills e
	# estátua pelo resto da sessão (pos congelado, input≠0, navpath válido, vel=0).
	if state != State.DEAD and not ActorCommons.IsAlive(agent):
		state = State.DEAD
		currentTargetRID = 0
		_attackedTarget = false
		_respawnAccumulator = 0.0

	match state:
		State.IDLE:
			state = State.SEEK
		State.SEEK:
			metricSeekTicks += 1
			_tickSeek(delta)
		State.COMBAT:
			metricCombatTicks += 1
			_tickCombat(delta)
		State.LOOT:
			metricLootTicks += 1
			_tickLoot(delta)
		State.DEAD:
			_tickDead(delta)

	_tickStuck(delta)
	_tickPotion(delta)

func _tickVigor(delta : float):
	if agent == null or agent.stat == null or not ActorCommons.IsAlive(agent):
		return
	var maxStam : int = agent.stat.current.maxStamina
	if maxStam > 0 and agent.stat.stamina < maxStam:
		agent.stat.SetStamina(maxi(1, int(float(maxStam) * FarmVigorStaminaPct * delta)))
	var maxMana : int = agent.stat.current.maxMana
	if maxMana > 0 and agent.stat.mana < maxMana:
		agent.stat.SetMana(maxi(1, int(float(maxMana) * FarmVigorManaPct * delta)))

func _isValid() -> bool:
	if agent == null or not is_instance_valid(agent):
		return false
	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone == null or zone.mapID == DB.UnknownHash:
		return false
	return true

func _getInst() -> WorldInstance:
	return WorldAgent.GetInstanceFromAgent(agent) as WorldInstance if agent else null

# SOM-GAMEPLAY G1: skill PRIMÁRIA (comportamento antigo) ou a escolha da
# prioridade declarada pelo jogador para o alvo informado. Com um único
# candidato, ou sem alvo (interrupt), cai exatamente no caminho antigo.
func _getSkill(target : BaseAgent = null) -> SkillCell:
	var candidates : Array[int] = GetPriorityOrder()
	if target == null or candidates.size() == 1:
		return DB.SkillsDB.get(candidates[0], null)

	var blocked : Dictionary = {}
	var reachable : Dictionary = {}
	for skillID : int in candidates:
		var cell : SkillCell = DB.SkillsDB.get(skillID, null)
		if cell == null or _skillBlocked(cell):
			blocked[skillID] = true
			reachable[skillID] = false
			continue
		blocked[skillID] = false
		reachable[skillID] = _skillReaches(cell, target)

	var chosen : int = SkillPriority.Select(candidates, blocked, reachable)
	return DB.SkillsDB.get(chosen if chosen != SkillPriority.NoSkill else candidates[0], null)

# Ordem efetiva de cast (carga declarada, sem duplicata, só aprendidas).
func GetPriorityOrder() -> Array[int]:
	return SkillPriority.ResolveOrder(skillLoadout, _learnedLoadout(), SkillCommons.SkillMeleeName.hash())

# Quais IDs da carga o char REALMENTE tem — 1 lookup por skill declarada
# (a carga é limitada a SkillPriority.MaxPrioritySkills), nunca um varredura
# do SkillsDB por tick.
func _learnedLoadout() -> Array[int]:
	var learned : Array[int] = []
	if agent == null or not is_instance_valid(agent):
		return learned
	for skillID : int in skillLoadout:
		var cell : SkillCell = DB.SkillsDB.get(skillID, null)
		if cell != null and not (skillID in learned) and SkillCommons.HasSkill(agent, cell):
			learned.append(skillID)
	return learned

# Trava que impede o cast AGORA. Stamina fica de fora de propósito: no motor
# stamina curta só piora o RNG do golpe (SkillCommons.GetRNG), não cancela o
# cast — marcar a skill como bloqueada aqui mudaria o DPS medido pelas sims.
func _skillBlocked(skill : SkillCell) -> bool:
	if SkillCommons.IsCoolingDown(agent, skill):
		return true
	if not ClassBonus.CanUseSkill(agent, skill):
		return true
	if skill.modifiers == null:
		return false
	var manaCost : int = int(skill.modifiers.Get(CellCommons.Modifier.Mana))
	if agent.stat.mana < -manaCost:
		return true
	var healthCost : int = int(skill.modifiers.Get(CellCommons.Modifier.Health))
	return agent.stat.health < -healthCost

func _skillReaches(skill : SkillCell, target : BaseAgent) -> bool:
	var range : float = float(ActorCommons.GetSkillRange(agent, skill)) - AttackRangeBuffer
	return agent.position.distance_to(target.position) <= range

# ------------------------------------------------------------------ seek

func _tickSeek(delta : float):
	_seekAccumulator += delta
	if _seekAccumulator < SeekInterval:
		return
	_seekAccumulator = 0.0

	# Commit to the current target while it lives — re-picking the nearest mob
	# every tick makes the agent thrash between wandering mobs and never close
	# the distance. STUCK failsafe still breaks deadlocks.
	var current : AIAgent = WorldAgent.GetAgent(currentTargetRID) as AIAgent if currentTargetRID != 0 else null
	if current and is_instance_valid(current) and ActorCommons.IsAlive(current):
		state = State.COMBAT
		return
	currentTargetRID = 0

	var target : AIAgent = _findNearestMob()
	if target:
		_setTarget(target)
		state = State.COMBAT
		return

	metricNoTargetTicks += 1
	# No mobs: wander toward instance center to stay in the farm area
	var inst : WorldInstance = _getInst()
	if inst and agent.agent and not agent.agent.is_navigation_finished():
		pass	# already walking
	elif inst:
		var center : Vector2 = WorldNavigation.GetPolygonCenter(inst.map.navPoly.get_vertices()) if inst.map.navPoly and inst.map.navPoly.get_polygon_count() > 0 else agent.position
		if agent.position.distance_squared_to(center) > 64.0:
			agent.WalkToward(center)

func _findNearestMob() -> AIAgent:
	var inst : WorldInstance = _getInst()
	if inst == null:
		return null

	# SOM-IDLE: num duelo de boss, o alvo é SEMPRE o boss (ignora o resto do farm).
	if bossRID != 0:
		var boss : AIAgent = WorldAgent.GetAgent(bossRID) as AIAgent
		if boss != null and is_instance_valid(boss) and ActorCommons.IsAlive(boss):
			return boss

	var best : AIAgent = null
	var bestDist : float = INF
	for mob in inst.mobs:
		if mob and is_instance_valid(mob) and ActorCommons.IsAlive(mob):
			var dist : float = agent.position.distance_squared_to(mob.position)
			if dist < bestDist:
				bestDist = dist
				best = mob
	return best

func _setTarget(target : AIAgent):
	currentTargetRID = target.get_rid().get_id()
	_retargets += 1
	_lastPosition = agent.position
	# Alvo novo, janela nova de crédito: sem isso só o 1º kill da sessão conta.
	_attackedTarget = false
	_killRegistered = false

# ------------------------------------------------------------------ combat

func _tickCombat(delta : float):
	var target : BaseAgent = WorldAgent.GetAgent(currentTargetRID) as AIAgent if currentTargetRID != 0 else null
	if target == null or not is_instance_valid(target) or not ActorCommons.IsAlive(target):
		if _attackedTarget and not _killRegistered:
			sessionKills += 1
			_killRegistered = true
		_attackedTarget = false
		currentTargetRID = 0
		# Kill NOSSO → o mob acabou de derrubar a mesa dele em `inst.drops`
		# (`MonsterAgent.Killed` → `_RollDrops` → `WorldDrop.PushDrop`). Sem ir a
		# LOOT aqui, o estado era inalcançável: o `state = State.LOOT` do fim da
		# função só pega quem morre dentro do mesmo tick, e no tick seguinte o
		# alvo já entra morto pelo topo — loot apodrecia no chão e o farmer não
		# coletava item nenhum (medido: `loot_ticks` = 0 em 41 kills).
		state = State.LOOT if _killRegistered else State.SEEK
		return

	# SOM-IDLE: janela de interrupt só existe em duelo de boss (nunca no farm).
	if bossIndex >= 0:
		_interruptTimer += delta
		if not _interruptWindow and _interruptTimer >= InterruptCycleSec:
			_interruptTimer = 0.0
			_interruptWindow = true
			NotifyInterruptWindow(target, true)
		elif _interruptWindow and _interruptTimer >= InterruptWindowSec:
			_interruptWindow = false
			NotifyInterruptWindow(target, false)
		_consumeBossInterrupt(target)

	var skill : SkillCell = _getSkill(target)
	if skill == null:
		state = State.SEEK
		return

	var range : float = float(ActorCommons.GetSkillRange(agent, skill)) - AttackRangeBuffer
	var dist : float = agent.position.distance_to(target.position)

	if dist > range:
		if not SkillCommons.IsCasting(agent) and not SkillCommons.HasAnyActionInProgress(agent):
			agent.WalkToward(target.position)
	else:
		# SOM-IDLE: grude no alvo — SÓ se a skill é castWalk (ex.: Melee).
		# Andar com cast static cancela o próprio golpe (Stopped); sem o grude
		# o mob passeia para fora do re-check do Process e o golpe fizzla.
		if skill.castWalk and not SkillCommons.IsCasting(agent) and not SkillCommons.HasAnyActionInProgress(agent):
			agent.WalkToward(target.position)
		if not SkillCommons.HasAnyActionInProgress(agent) and not SkillCommons.IsCasting(agent) and not SkillCommons.IsCoolingDown(agent, skill):
			Skill.Cast(agent, target, skill)
			_attackedTarget = true
			metricAttacksCast += 1

	if not ActorCommons.IsAlive(target):
		if _attackedTarget and not _killRegistered:
			sessionKills += 1
			_killRegistered = true
		_attackedTarget = false
		currentTargetRID = 0
		state = State.LOOT

# ------------------------------------------------------------------ boss interrupt (ativa)

# Consome o toque pendente na janela atual. Exposto (não-inlined) para a arena
# de teste drive-lo com fase controlada — é a MESMA função que o tick chama.
# Regras (espelham a sim): fora da janela = ignora; miss fecha a janela sem hit
# (spam tem custo); good/perfect = hit extra com damageMult da fase.
# Devolve o veredito aplicado ({phase, index, quality, mult}) — `{}` quando o
# toque foi ignorado. É só espelho do que o servidor FEZ (a decisão continua
# sendo daqui); o retorno existe para as réguas poderem aferir a janela efetiva
# sem depender de física/instância, e nenhum chamador de produção é obrigado a
# ler o resultado.
func _consumeBossInterrupt(target : BaseAgent) -> Dictionary:
	if not _interruptRequest:
		return {}
	_interruptRequest = false
	if not _interruptWindow or target == null or not is_instance_valid(target) or not ActorCommons.IsAlive(target):
		return {}
	_interruptWindow = false
	NotifyInterruptWindow(target, false)
	var phase : float = clampf(_interruptTimer / InterruptWindowSec, 0.0, 1.0)
	# SOM-IDLE 2026-09-27: a janela pontuada é a DO BOSS em duelo (bossIndex, posto
	# por IdlePolicyService._BeginArena), não a meia-largura legacy que os 4
	# primeiros bosses compartilhavam. Sem o índice aqui o aperto declarado na
	# escada (BossService.BossInterrupt*HalfWindow) nunca chegava à luta ao vivo:
	# o /boss comunicava ±0.07 no chefe e o servidor cobrava ±0.10 — content
	# decorativo. O veredito volta com `index` para a régua apontar qual boss foi
	# aferido.
	var quality : String = BossService.InterruptQuality(phase, bossIndex)
	var mult : float = BossService.InterruptBonus(phase, bossIndex)
	NotifyInterruptFeedback(quality, mult)
	# Q-1 (2026-10-07): o acerto ao vivo vira crédito consultado pelo BossRush —
	# persistido pelo dono da identidade (peer -> char), nunca confiado ao cliente.
	if quality != "miss" and mult > 1.0 and agent != null and agent.peerID != NetworkCommons.PeerUnknownID:
		var cacheChar : int = Peers.GetCharacter(agent.peerID)
		if cacheChar > 0:
			Launcher.SQL.CacheBossInterrupt(cacheChar, mult)
	var verdict : Dictionary = {"phase" = phase, "index" = bossIndex, "quality" = quality, "mult" = mult}
	if quality == "miss":
		return verdict
	var iskill : SkillCell = _getSkill(target)
	if iskill != null:
		# hit-bônus server-side pelo mesmo caminho do auto-ataque (clamp, AI
		# aggro, TargetAlteration, procs); rng fixo 0.5 = sem crit/dodge forçado.
		Skill.Damaged(agent, target, iskill, 0.5, mult)
	return verdict

# Push da janela p/ o assistente (se houver); offline/bot é no-op seguro.
func NotifyInterruptWindow(boss : BaseAgent, open : bool):
	if agent != null and agent.peerID != NetworkCommons.PeerUnknownID:
		Network.CallClient("BossInterruptWindow", [open], agent.peerID)

# P1-1 (A-10): transmite feedback visual de progresso ao cliente.
func NotifyInterruptFeedback(quality : String, mult : float):
	if agent != null and agent.peerID != NetworkCommons.PeerUnknownID:
		Network.CallClient("BossInterruptFeedback", [quality, mult], agent.peerID)
	# Transmite SnapshotMetrics a cada tick para feedback idle (HUD/overlay).
	if agent != null and agent.peerID != NetworkCommons.PeerUnknownID:
		Network.CallClient("SnapshotMetrics", [SnapshotMetrics()], agent.peerID)

# Chamado pelo servidor quando o jogador toca no botão. Só vale em duelo; a
# resolução (janela aberta? hit-bônus?) acontece no próximo tick, server-side.
func RequestBossInterrupt() -> bool:
	if bossIndex < 0:
		return false
	_interruptRequest = true
	return true

func InterruptBossReset():
	_interruptTimer = 0.0
	_interruptWindow = false
	_interruptRequest = false

# ------------------------------------------------------------------ loot

func _tickLoot(delta : float):
	_lootAccumulator += delta
	if _lootAccumulator < LootInterval:
		return
	_lootAccumulator = 0.0

	var drop : Drop = _findNearestDrop()
	if drop:
		var dist : float = agent.position.distance_squared_to(drop.position)
		if dist <= ActorCommons.PickupSquaredDistance:
			var dropID : int = drop.get_instance_id()
			if WorldDrop.PickupDrop(dropID, agent):
				metricDropsPicked += 1
			state = State.SEEK
		else:
			agent.WalkToward(drop.position)
		return

	state = State.SEEK

func _findNearestDrop() -> Drop:
	var inst : WorldInstance = _getInst()
	if inst == null or inst.drops.is_empty():
		return null

	var limit : float = LootSearchRadius * LootSearchRadius
	var best : Drop = null
	var bestDist : float = INF
	for dropID in inst.drops:
		var drop : Drop = inst.drops[dropID]
		if drop and is_instance_valid(drop) and _canCarry(drop):
			var dist : float = agent.position.distance_squared_to(drop.position)
			if dist <= limit and dist < bestDist:
				bestDist = dist
				best = drop
	return best

# O chão não é convite para um pé-de-braço: se a mochila não tem onde guardar o
# item, ele CONTINUA lá (ninguém apaga drop que não coube — ver
# `WorldDrop.PickupDrop`) e o farmer não passa a sessão andando até um drop que
# não pode carregar, o que custaria as próprias mortes e kills que as réguas de
# produtividade medem. A célula é resolvida pelo MESMO caminho de `PickupDrop`,
# então "coube?" é a mesma resposta nas duas pontas — e a resposta vem de
# `ActorInventory.CanHold`, espelho exato de `PushItem`, não de um teto novo.
func _canCarry(drop : Drop) -> bool:
	if agent == null or agent.inventory == null or drop.item == null:
		return false
	var cell : ItemCell = DB.GetItem(drop.item.cellID, drop.item.cellCustomfield)
	return cell != null and agent.inventory.CanHold(cell, drop.item.count)

# ------------------------------------------------------------------ death

func _tickDead(delta : float):
	_deathDownAccumulator += delta
	_respawnAccumulator += delta
	if _respawnAccumulator >= RespawnDelay:
		_respawnAccumulator = 0.0
		# SOM-IDLE: revive IN PLACE — warping out would destroy the dedicated
		# farm instance when its last player leaves (WorldAgent.PopAgent).
		if not ActorCommons.IsAlive(agent):
			agent.Revive()
		if ActorCommons.IsAlive(agent):
			sessionDeaths += 1
			sessionDowntimeSecs += _deathDownAccumulator
			_deathDownAccumulator = 0.0
			state = State.SEEK

# ------------------------------------------------------------------ helpers

func _tickStuck(delta : float):
	if state == State.DEAD or agent == null:
		return
	# Engajado num alvo vivo não é stuck: o melee colado mal se move (<1px) e
	# derrubar o alvo aqui abortava todo kill (só burst de <8s matava).
	if state == State.COMBAT:
		var t : BaseAgent = WorldAgent.GetAgent(currentTargetRID) as AIAgent if currentTargetRID != 0 else null
		if t and is_instance_valid(t) and ActorCommons.IsAlive(t):
			_stuckAccumulator = 0.0
			_lastPosition = agent.position
			return

	if agent.position.distance_squared_to(_lastPosition) < 1.0:
		_stuckAccumulator += delta
		if _stuckAccumulator >= StuckTimeout:
			_stuckAccumulator = 0.0
			# Force re-target / re-route
			currentTargetRID = 0
			state = State.SEEK
			_retargets += 1
	else:
		_stuckAccumulator = 0.0
		_lastPosition = agent.position

func _tickPotion(delta : float):
	_potionAccumulator += delta
	if _potionAccumulator < PotionCheckInterval or agent == null or not ActorCommons.IsAlive(agent):
		return
	_potionAccumulator = 0.0

	if agent.stat == null or agent.stat.current.maxHealth <= 0:
		return
	var threshold : float = autoPotionPct / 100.0
	var needed : int = ceili(float(agent.stat.current.maxHealth) * threshold) - agent.stat.health
	if needed <= 0:
		return
	if not _usePotion(needed):
		metricPotionShortfalls += 1

# O controle que o jogador configura é um percentual de vida, não um item. A
# policy bebe a poção de vida que a mochila tem, e escolhe a MENOR que fecha o
# buraco do limiar; se nenhuma fecha, a maior que ela carrega. Antes havia um
# único hash fixo na declaração, incapaz de acompanhar a escada de cura do
# catálogo (20 hp no tier 1 contra 210 hp no tier 9). Devolve false quando nada
# curável está na mochila — quem conta o buraco é o chamador.
func _usePotion(needed : int) -> bool:
	if agent.inventory == null:
		return false
	var enough : ItemCell = null
	var enoughHeal : int = 0
	var biggest : ItemCell = null
	var biggestHeal : int = 0
	for item : Item in agent.inventory.items:
		if item == null:
			continue
		var cell : ItemCell = DB.GetItem(item.cellID, item.cellCustomfield)
		if cell == null or not cell.usable or cell.type != CellCommons.Type.ITEM or cell.modifiers == null:
			continue
		var heal : int = int(cell.modifiers.Get(CellCommons.Modifier.Health, false))
		if heal <= 0:
			continue
		if biggest == null or heal > biggestHeal:
			biggest = cell
			biggestHeal = heal
		if heal >= needed and (enough == null or heal < enoughHeal):
			enough = cell
			enoughHeal = heal
	var chosen : ItemCell = enough if enough != null else biggest
	if chosen == null:
		return false
	agent.inventory.UseItem(chosen)
	metricPotionsUsed += 1
	return true

# ------------------------------------------------------------------ metrics

func ComputeSessionEfficiency() -> float:
	return clampf(ComputeSessionEfficiencyRaw(), MinEfficiency, 1.0)

# Sem clamp, de propósito: o clamp do valor publicado tem o MESMO piso do gate
# (MinEfficiency), então uma régua que lê a versão clampada não pode falhar —
# 1 morte ou 100, o número é 0.5. Quem quer aferir pacing lê esta.
func ComputeSessionEfficiencyRaw() -> float:
	if agent == null:
		return MinEfficiency

	if sessionGameTime <= 0.0:
		return 1.0

	var downtimeRatio : float = sessionDowntimeSecs / sessionGameTime
	return 1.0 - downtimeRatio - float(sessionDeaths) * DeathPenalty

func GetSessionDuration() -> float:
	return sessionGameTime

# SOM-IDLE D1: pacing breakdown for the sim suites (all game-time based).
func SnapshotMetrics() -> Dictionary:
	var hours : float = maxf(1.0 / 3600.0, sessionGameTime / 3600.0)
	return {
		"kills" = sessionKills,
		"kills_per_hour" = float(sessionKills) / hours,
		"deaths" = sessionDeaths,
		"downtime_secs" = sessionDowntimeSecs,
		"efficiency_raw" = ComputeSessionEfficiencyRaw(),
		"seek_ticks" = metricSeekTicks,
		"combat_ticks" = metricCombatTicks,
		"loot_ticks" = metricLootTicks,
		"no_target_ticks" = metricNoTargetTicks,
		"attacks_cast" = metricAttacksCast,
		"walk_distance" = metricWalkDistance,
		"drops_picked" = metricDropsPicked,
		"potions_used" = metricPotionsUsed,
		"potion_shortfalls" = metricPotionShortfalls,
		"secs_per_kill" = sessionGameTime / maxf(1.0, float(sessionKills)),
		"attacks_per_kill" = float(metricAttacksCast) / maxf(1.0, float(sessionKills)),
	}

# Used by tests to inject deterministic downtime
func _addDowntime(secs : float):
	sessionDowntimeSecs += secs
