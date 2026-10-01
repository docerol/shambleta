extends Node
class_name NpcCommons

const Greetings : PackedStringArray = [
	"Hello %s!",
	"Greetings, %s.",
	"Ah, %s.",
	"Welcome.",
	"Salutations.",
	"Good to see you, %s.",
	"Ahoy!",
	"Well met, %s.",
	"Hey there.",
	"Good day.",
	"Well met."
]

static var Farewells : PackedStringArray = [
	"Goodbye, %s.",
	"Farewell.",
	"See you later, %s.",
	"Until next time.",
	"Safe travels, %s.",
	"Take care.",
	"Good journey.",
	"Until we meet again, %s.",
	"Stay safe.",
	"Goodbye for now."
]

# Display
static func DisplayActions(agent : BaseAgent, actions : PackedStringArray):
	if agent and agent is PlayerAgent and agent.peerID != NetworkCommons.PeerUnknownID:
		Network.DisplayActions(actions, agent.peerID)

static func PushNotification(agent : BaseAgent, text : String):
	if agent:
		if agent is PlayerAgent and agent.peerID != NetworkCommons.PeerUnknownID:
			Network.PushNotification(text, agent.peerID)
		elif agent is NpcAgent:
			var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)
			if inst:
				Network.NotifyInstance(inst, "PushNotification", [text])

static func PushTracker(agent : BaseAgent, label : String, value : int, maxValue : int, unit : String = ""):
	if agent:
		if agent is PlayerAgent and agent.peerID != NetworkCommons.PeerUnknownID:
			Network.DisplayProgressionTracker(label, value, maxValue, unit, agent.peerID)
		elif agent is NpcAgent:
			var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)
			if inst:
				Network.NotifyInstance(inst, "DisplayProgressionTracker", [label, value, maxValue, unit])

static func ClearTracker(agent : BaseAgent):
	if agent:
		if agent is PlayerAgent and agent.peerID != NetworkCommons.PeerUnknownID:
			Network.ClearProgressionTracker(agent.peerID)
		elif agent is NpcAgent:
			var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(agent)
			if inst:
				Network.NotifyInstance(inst, "ClearProgressionTracker", [])

# Tutorial
static func HighlightUI(pc : BaseAgent, target : UICommons.UITarget):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.HighlightUI(target, pc.peerID)

static func OpenUI(pc : BaseAgent):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.OpenUI(pc.peerID)

# Camera
static func CameraLookAt(pc : BaseAgent, pos : Vector2):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.CameraLookAt(pos, pc.peerID)

static func CameraReset(pc : BaseAgent):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.CameraReset(pc.peerID)

# Context sent to client
static func Emote(npc : NpcAgent, emoteID : int):
	if npc:
		Network.NotifyNeighbours(npc, "Emote", [npc.get_rid().get_id(), emoteID])

static func Express(npc : NpcAgent, pc : BaseAgent, text : String):
	if npc and pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.Express(npc.get_rid().get_id(), text, pc.peerID)

static func Chat(npc : NpcAgent, pc : BaseAgent, chat : String):
	if npc and pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.ChatPlayer(str(GUICommons.ChatChannel.LOCAL), npc.nick, chat, npc.get_rid().get_id(), pc.peerID)

static func ContextText(pc : BaseAgent, author : String, text : String):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.ContextText(author, text, pc.peerID)

static func ContextThink(pc : BaseAgent, author : String, text : String):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.ContextThink(author, text, pc.peerID)

static func ContextChoices(pc : BaseAgent, texts : PackedStringArray):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.ContextChoice(texts, pc.peerID)

static func ContextContinue(pc : BaseAgent):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.ContextContinue(pc.peerID)

static func ContextClose(pc : BaseAgent):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.ContextClose(pc.peerID)

static func ToggleContext(pc : BaseAgent, enable : bool):
	if pc and pc is PlayerAgent and pc.peerID != NetworkCommons.PeerUnknownID:
		Network.ToggleContext(enable, pc.peerID)

static func GetRandomGreeting(nick : String) -> String:
	var greet : String = Greetings[randi() % Greetings.size()]
	return greet if greet.find("%s") == -1 else greet % [nick]

static func GetRandomFarewell(nick : String) -> String:
	var farewell : String = Farewells[randi() % Farewells.size()]
	return farewell if farewell.find("%s") == -1 else farewell % [nick]

# Context received from client
static func TryCloseContext(pc : BaseAgent):
	if pc and pc is PlayerAgent and pc.ownScript and not pc.ownScript.IsWaiting():
		pc.ownScript.ToggleWindow(false)
		pc.ClearScript()

# Commands
static func Spawn(caller : BaseAgent, mobID : int, count : int = 1, position : Vector2 = Vector2.ZERO, spawnRadius : Vector2 = Vector2(64, 64)) -> Array[MonsterAgent]:
	var agents : Array[MonsterAgent] = []
	var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(caller)
	if inst and inst.map:
		for i in count:
			var spawnObject : SpawnObject = SpawnObject.new()
			spawnObject.map					= inst.map
			spawnObject.type				= ActorCommons.Type.MONSTER
			spawnObject.id					= mobID
			spawnObject.count				= count
			spawnObject.spawn_offset		= spawnRadius
			if position == Vector2.ZERO:
				spawnObject.spawn_position	= WorldNavigation.GetRandomPosition(inst)
			else:
				spawnObject.spawn_position	= WorldNavigation.GetRandomPositionAABB(inst, position, spawnRadius)
			agents.push_back(WorldAgent.CreateAgent(spawnObject, inst.id))
	return agents

static func Warp(caller : BaseAgent, mapID : int, position : Vector2, direction : ActorCommons.Direction = ActorCommons.Direction.UNKNOWN):
	if caller is PlayerAgent:
		var map : WorldMap = Launcher.World.GetMap(mapID)
		if map:
			Launcher.World.Warp(caller, map, position, direction, 0)

static func WarpInstance(caller : BaseAgent, mapID : int, position : Vector2, direction : ActorCommons.Direction = ActorCommons.Direction.UNKNOWN):
	if caller is PlayerAgent:
		var map : WorldMap = Launcher.World.GetMap(mapID)
		if map:
			var instanceID : int = caller.get_rid().get_id()
			if not map.instances.has(instanceID):
				map.CreateInstance(instanceID)
			Launcher.World.Warp(caller, map, position, direction, instanceID)

# Progress
static func SetQuest(caller : BaseAgent, questID : int, state : int):
	if caller is PlayerAgent and caller.progress:
		var questData : QuestData = DB.GetQuest(questID)
		if not questData:
			return

		# O estado ANTES da escrita é a única coisa que distingue "concluir" de
		# "reentregar a conclusão": script de diálogo roda de novo a cada visita ao
		# NPC (Ryan.gd:101 e :114 entregam o MESMO REWARDS_WITHDREW em dois ramos) e
		# o estado volta do banco no login (Progress.gd:97), então o pagamento tem
		# que estar amarrado à transição, não à chamada.
		var previousState : int = caller.progress.GetQuest(questID)
		if previousState == ProgressCommons.UnknownProgress:
			PushNotification(caller, "Quest Started: " + questData.name)
		caller.progress.SetQuest(questID, state)
		if state == ProgressCommons.CompletedProgress:
			PushNotification(caller, "Quest Completed: " + questData.name)
			# A quest era a única atividade não-kill do jogo que não pagava nada:
			# até aqui este bloco só emitia notificação (auditado em
			# NpcCommons.gd:167-177, com QuestData.gd:11 como texto de vitrine).
			if ShouldPayQuestReward(previousState, state):
				PayQuestReward(caller, questData)

# ------------------------------------------------------------------ Quest reward
# Recompensa DECLARADA em QuestData (rewardGP / rewardEXP), paga pelo servidor e
# espelhada no ledger. Por que não deixar como estava nos diálogos: os scripts que
# pagavam à mão somavam em `stat.gp` na memória do agente e o crédito só chegava ao
# banco se o snapshot de 600 s pegasse — sem linha de ledger ninguém prova o grant,
# e a regra do valor morava no corpo do diálogo em vez de morar no dado da quest.
# Sete já migraram para o dado (o censo e o ratchet por nome são a suíte 8 de
# tests/quest_reward_test.gd; os diálogos hoje só têm no lugar do pagamento o
# comentário que diz para onde o número foi — `Nina.gd:144`, `Frost.gd:54`,
# `Mauro.gd:47`, `Nathan.gd:89`, `ThiefsChest.gd:30`, `Eridu.gd:85`,
# `Riskim.gd:123`). Continua à mão o que um número por quest não declara: em Ryan.gd
# o ramo `OnNickosAlive` soma 1000 (`Ryan.gd:@OnNickosAlive`). O `OnNickosDead` soma
# 2000 (`Ryan.gd:@OnNickosDead`); ficam os estados intermediários de
# `PeterGlobal.gd`, `Ekinu.gd` e `Kael.gd`. Todo ganho de dinheiro do resto do
# projeto já passa pelo kernel (EconomyKernel.gd:142 MoveGold, :247
# _LedgerAppendLocked).

# Reason por kind no ledger: `quest:<questID>:gold` / `:xp` — o mesmo scheme
# `domínio:chave` de `ah_buy:<id>` (AuctionHouseService.gd:371) e de
# `chest:<id>|<hash>|<seed>` (TradeChestService.gd:152), que é o que permite à
# auditoria perguntar quanto a quest N mintou sem varrer reason livre.
static func QuestRewardReason(questID : int, kind : String) -> String:
	return "quest:%d:%s" % [questID, kind]

# Pura (sem SQL, sem agente): o marco de conclusão dos enums de quest é literalmente
# REWARDS_WITHDREW = CompletedProgress (ProgressCommons.gd:32,90,107,123), então
# 255 = "recompensa retirada" e reentregar 255 não é concluir de novo. Regredir o
# estado também não paga.
static func ShouldPayQuestReward(previousState : int, state : int) -> bool:
	return state == ProgressCommons.CompletedProgress and previousState != ProgressCommons.CompletedProgress

# Prova DURÁVEL de que esta recompensa já saiu para este personagem. O guard de
# transição acima não basta sozinho: script reabre quest (Elanore.gd:152 devolve
# ELANORE_POTION a INACTIVE), `/quest <name> <state>` reseta o estado na mão de um
# GM (WorldCommands.gd:1414) e o progresso é reimportado do banco — o ledger é
# append-only (trigger de DELETE em data/conf/migrations/009_idle_economy.sql:32)
# e nenhuma dessas rotas apaga linha. A poda de retenção (056) só libera linha cujo
# reason está na lista fechada de corpo (SQLRetention.gd:42-43: settle/kill), então
# `quest:<id>:*` nunca é coberta por rollup e a prova não envelhece.
static func HasQuestRewardRow(charID : int, reason : String) -> bool:
	var sql : SQLService = Launcher.SQL
	var rows : Array[Dictionary] = sql.QueryBindings("SELECT id FROM ledger_transaction WHERE char_id = ? AND reason = ? LIMIT 1;", [charID, reason])
	return not rows.is_empty()

# Entrada do fluxo de produção (tem o agente vivo, então pode notificar o jogador).
static func PayQuestReward(caller : BaseAgent, questData : QuestData) -> bool:
	if not (caller is PlayerAgent):
		return false
	var pc : PlayerAgent = caller as PlayerAgent
	var paid : bool = PayQuestRewardForCharacter(pc.GetCharacterID(), questData, pc)
	if paid:
		PushNotification(caller, QuestRewardLine(questData))
	return paid

# Core por personagem (StreakService.gd:140 é o mesmo formato: estado no banco,
# ouro pelo ledger, espelho em memória só quando o agente está carregado). O ouro
# usa MoveGold, que resolve a carteira no banco, escreve o ledger e aplica o delta
# no agente vivo depois do commit (EconomyKernel.gd:142) — o cliente vê o novo gp
# pelo refresh de UpdatePrivateStats do próprio agente (PlayerAgent.gd:125).
# Retorna true quando mintou alguma linha nesta chamada.
static func PayQuestRewardForCharacter(charID : int, questData : QuestData, agent : PlayerAgent = null) -> bool:
	if questData == null or charID <= 0 or not questData.HasDeclaredReward():
		return false
	# Sem kernel não há caminho de ledger, e pagar fora do ledger é exatamente o
	# buraco que esta mudança veio fechar (os AddGP crus de Ryan/Nina/Frost/Mauro):
	# então nada é creditado por atalho — sai errado e grita.
	if Launcher.Economy == null:
		push_error("PayQuestRewardForCharacter: Economy ausente, nada creditado (char %d quest %d)" % [charID, questData.id])
		return false
	var paid : bool = false
	var goldReason : String = QuestRewardReason(questData.id, EconomyCatalog.LedgerKindGold)
	# Cada perna tem o SEU guard de ledger, não um guard do quest inteiro: se o
	# grant de ouro falhasse depois do XP aplicado, um guard único marcaria a
	# recompensa como paga e o jogador perderia a perna que faltava para sempre.
	if questData.rewardGP > 0 and not HasQuestRewardRow(charID, goldReason):
		if Launcher.Economy.MoveGold(charID, questData.rewardGP, goldReason):
			paid = true
		else:
			push_error("PayQuestRewardForCharacter: MoveGold recusou char %d quest %d (+%d GP)" % [charID, questData.id, questData.rewardGP])
	if questData.rewardEXP > 0:
		# XP mora na memória do agente carregado: Stats.AddExperience é quem resolve
		# level-up e o transbordo de essência (Stats.gd:225-244). Sem agente não há
		# como pagá-lo sem duplicar a curva de Experience aqui dentro, e a linha de
		# ledger só sai JUNTO do XP aplicado — linha sem crédito faria o guard
		# durável afirmar que pagou o que nunca existiu.
		# `balance_after` é o resíduo de `experience` (a curva subtrai o nível), e não
		# um saldo de carteira: é a mesma convenção da linha "xp" do settle
		# (OfflineSettle.gd:438), e é por isso que a atestação de saldo só varre
		# kind "gold" (EconomyKernel.gd:189,217).
		var xpReason : String = QuestRewardReason(questData.id, EconomyCatalog.LedgerKindXP)
		if agent != null and agent.stat != null and not HasQuestRewardRow(charID, xpReason):
			AddExp(agent, questData.rewardEXP)
			var sql : SQLService = Launcher.SQL
			# LedgerAppend pede a transação do estado que ele espelha
			# (EconomyKernel.gd:33-34). Aqui não há transação porque não há mutação de
			# banco pareada: o XP do agente vivo desce para `stat` no snapshot de 600 s
			# (World.BackupPlayers), exatamente como os quatro diálogos que pagavam XP
			# à mão — a diferença é que agora a linha existe antes do snapshot.
			if Launcher.Economy.LedgerAppend(charID, sql.GetAccountIDForCharacter(charID), EconomyCatalog.LedgerKindXP, questData.rewardEXP, agent.stat.experience, xpReason):
				paid = true
			else:
				push_error("PayQuestRewardForCharacter: ledger de XP falhou char %d quest %d (+%d EXP)" % [charID, questData.id, questData.rewardEXP])
	return paid

# Frase do pagamento, feita dos NÚMEROS declarados — o texto `reward` do QuestData
# é o que o jogador lê na janela da quest e pode dizer "Unknown" (DesertSeed.tres:13);
# prometer na tela o que o ledger não mintou é a outra metade do bug auditado.
# Forma da casa: RewardLine de StreakService.gd:122 também sai do resultado que
# concedeu, nunca do texto do dado.
static func QuestRewardLine(questData : QuestData) -> String:
	var parts : PackedStringArray = PackedStringArray()
	if questData.rewardGP > 0:
		parts.append("+%d GP" % questData.rewardGP)
	if questData.rewardEXP > 0:
		parts.append("+%d EXP" % questData.rewardEXP)
	# Nada declarado → nada na tela, inclusive o prefixo: uma quest sem recompensa
	# (presets/quests/Tutorial.tres) exibindo "Quest Reward: " vazio seria a mesma
	# promessa vazia de antes, agora do lado do pagamento.
	if parts.is_empty():
		return ""
	return "Quest Reward: " + ", ".join(parts)

static func AddBestiary(caller : BaseAgent, monsterID : int, count : int):
	if caller is PlayerAgent and caller.progress:
		var entityData : EntityData = DB.GetEntity(monsterID)
		if entityData:
			caller.progress.AddBestiary(monsterID, count)

# Inventory
static func AddItem(caller : BaseAgent, itemID : int, count : int = 1, customfield : String = "") -> bool:
	if caller is PlayerAgent and caller.inventory:
		var cell : ItemCell = DB.GetItem(itemID, customfield)
		if cell:
			return caller.inventory.AddItem(cell, count)
	return false

static func RemoveItem(caller : BaseAgent, itemID : int, count : int = 1, customfield : String = "") -> bool:
	if caller is PlayerAgent and caller.inventory:
		var cell : ItemCell = DB.GetItem(itemID, customfield)
		if cell:
			var itemIndex : int = caller.inventory.FindItemIndex(cell)
			return caller.inventory.RemoveItem(cell, count, itemIndex)
	return false

# Skills
static func TeachSkill(caller : BaseAgent, skillID : int, level : int = 1) -> bool:
	if caller is PlayerAgent and caller.progress:
		var cell : SkillCell = DB.GetSkill(skillID)
		if cell:
			caller.progress.AddSkill(cell, level)
			return true
	return false

# Modifier
static func AddModifier(agent : BaseAgent, effect : CellCommons.Modifier, value : Variant) -> StatModifier:
	var modifier : StatModifier = StatModifier.new()
	modifier._effect = effect
	modifier._value = value
	modifier._persistent = true
	agent.stat.modifiers.Add(modifier)
	agent.stat.RefreshEntityStats()
	return modifier

static func RemoveModifier(agent : BaseAgent, modifier : StatModifier):
	agent.stat.modifiers.Remove(modifier)
	agent.stat.RefreshEntityStats()

# Karma
static func AddKarma(caller : BaseAgent, points : int) -> bool:
	if caller is PlayerAgent and caller.stat:
		caller.stat.karma += points
	return false

# Gain
static func AddExp(caller : BaseAgent, value : int):
	if caller is PlayerAgent and caller.stat and value > 0:
		caller.stat.AddExperience(value)

static func AddGP(caller : BaseAgent, value : int):
	if caller is PlayerAgent and caller.stat and value > 0:
		caller.stat.AddGP(value)
