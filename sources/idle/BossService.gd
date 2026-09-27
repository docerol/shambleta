extends RefCounted
class_name BossService

# SOM-IDLE: boss-key ladder (calibração 2026-09).
# Mobs de farm dropam chaves; gastar uma chave invoca o próximo boss da escada,
# ESCALADO ao nível do char (para "ficar sempre difícil"). A luta é resolvida
# por uma simulação determinística de auto-combat (mesma fórmula de dano do
# motor, sem RNG), então o resultado é uma corrida de TTK: quem derruba o outro
# primeiro. Vitória paga xp/gold/chest/drop turbinados; derrota dá consolação.
# Modelo escolhido em vez de fight-live-em-instance para manter o beta verde e
# testável; a resolução pode virar combate 3D ao vivo depois trocando só Resolve().

# Escada de bosses (nome do boss = _name da entidade no EntitiesDB + nome de
# exibição + nível-piso + sala da arena).
# SOM-IDLE 2026-09-27 (juiz: "4 bosses na escada, depois disso só boss-rush sobre
# o mesmo roster"): a perna nova (índices 4..9) são entidades REAIS do cliente que
# nunca entraram na escada — Skeleton, Xakelbael, Lynx, Goblin, Bandit, Bird — cada
# uma com sala própria em presets/maps/server/** (o mob da arena está spawneado na
# sala) e com a JANELA de interrupt apertada índice a índice: mesmo multiplicador
# (1.5, o número que o BossLadder comunica), janela mais estreita. As duas
# primeiras linhas de BossInterrupt*HalfWindow reproduzem exatamente as constantes
# legacy [0.4,0.6] / [0.25,0.75], então nenhum duelo antigo muda de resultado.
const BossNames : Array[String] = ["Dorian", "Gabriel", "Marvin", "Splatyna",
	"Skeleton", "Xakelbael", "Lynx", "Goblin", "Bandit", "Bird"]
const BossFloorLevel : Array[int] = [5, 5, 5, 10, 15, 16, 17, 18, 19, 20]
# Sala de arena por índice — mesma ordem de FarmZoneData.BossMapNames (réguas em
# tests/content_hygiene_test.gd: mapa real carregado + mob com o nome do boss lá).
const BossArenas : Array[String] = [
	"Splatyna's Dorian Dead End", "Splatyna's Gabriel Pit",
	"Splatyna's Marvin Hole", "Splatyna's Chamber",
	"Tulimshar West Chamber", "Splatyna Cave Entrance",
	"Tulimshar Castle Corridors", "Candor Arena",
	"Ship First Deck", "Ship Nard's Room",
]
# Meia-largura das janelas de timing em torno do centro 0.5 do ciclo do boss.
const BossInterruptPerfectHalfWindow : Array[float] = [0.10, 0.10, 0.10, 0.10, 0.10, 0.09, 0.09, 0.08, 0.08, 0.07]
const BossInterruptGoodHalfWindow : Array[float] = [0.25, 0.25, 0.25, 0.25, 0.25, 0.24, 0.22, 0.20, 0.18, 0.16]

# Drop de chave: ppm sobre kills de farm válidos (damageRatio>0.5). 2000 ppm =
# 0,2%/kill → ~1 chave por 500 kills; no par (~150/h) isso é ~1 chave a cada
# ~3h30 online, ou ~2 chaves por settle de 12h offline (acumula idle-first).
const KeyDropPPM : int = 2000

# Recompensa do boss (vitória). xp = xpPerKill da zona atual × BossXpKills — um
# boss vale uma boa sessão de farm. gold = xp/GoldPerKillDiv × BossGoldBonus.
const BossXpKills : int = 60
const BossGoldBonus : float = 1.5
const BossChestReward : int = 1			# cofres granted por vitória
const ConsolationXpKills : int = 8		# xp de "esforço" ao perder
const ConsolationKeepsKey : bool = false	# derrota consome a chave (sink real)

# Escala do boss. Boss fica ao nível do char (piso por índice), com HP multiplicado
# para ser uma luta longa e defesa/golpe acompanhandem — só passa quem tem build.
const BossHpBase : int = 120
const BossHpPerLevel : int = 46
const BossHpMult : int = 6
const BossAtkBase : int = 12
const BossAtkPerLevel : int = 3
const BossDefBase : int = 10
const BossDefPerLevel : int = 2
const BossAttackCycle : float = 1.5		# segundos por golpe do boss
const PlayerAttackCycle : float = 1.2	# fallback se o char não tiver ciclo próprio
const MeleeSkillValue : int = 6			# dano básico da skill do auto-combat

# Mecânica ativa: interromper o cast do boss (janela de timing 0.0–1.0 do ciclo
# de ataque). Acerto perfeito [0.4–0.6] = 1.5x dano; bom [0.25–0.75] = 1.25x;
# fora = 1.0x. Puro e determinístico (testável sem RNG, sem cena).
const InterruptPerfectMin : float = 0.4
const InterruptPerfectMax : float = 0.6
const InterruptGoodMin : float = 0.25
const InterruptGoodMax : float = 0.75
const InterruptPerfectMult : float = 1.5
const InterruptGoodMult : float = 1.25

static func InterruptBonus(timing : float, bossIndex : int = -1) -> float:
	if InterruptQuality(timing, bossIndex) == "perfect":
		return InterruptPerfectMult
	if InterruptQuality(timing, bossIndex) == "good":
		return InterruptGoodMult
	return 1.0

# Classificação textual do mesmo timing (fonte única de verdade p/ caminho live
# e sim): o servidor usa na hora do toque p/ o feedback da UI; o sim só aplica
# o multiplicador. timing ∈ [0,1] = fase da janela aberta.
# bossIndex >= 0 usa a janela daquele boss (mais estreita na perna nova); sem
# índice (ou índice fora da escada) vale a janela legacy das constantes acima —
# é o contrato que o /boss, o IdlePolicy e as suítes antigas já exercitam.
static func InterruptQuality(timing : float, bossIndex : int = -1) -> String:
	var perfectHalf : float = InterruptPerfectMax - 0.5
	var goodHalf : float = InterruptGoodMax - 0.5
	if bossIndex >= 0 and bossIndex < BossInterruptPerfectHalfWindow.size():
		perfectHalf = BossInterruptPerfectHalfWindow[bossIndex]
		goodHalf = BossInterruptGoodHalfWindow[bossIndex]
	if absf(timing - 0.5) <= perfectHalf:
		return "perfect"
	if absf(timing - 0.5) <= goodHalf:
		return "good"
	return "miss"

# ------------------------------------------------------------------ escada: acesso e sala

# Sala da arena do boss i (nome de mapa real do MapsDB). "" fora da escada.
static func GetBossArena(index : int) -> String:
	return BossArenas[index] if index >= 0 and index < BossArenas.size() else ""

# Custo de chave do duelo — a escada cobra 1 chave por boss, e a perna nova não
# infla o sink: o que aperta é o piso de nível, a janela de interrupt e o HP.
static func GetBossKeyCost(index : int) -> int:
	return 1

# Janela efetiva (meia-largura) dos dois graus de timing do boss i.
static func GetInterruptWindow(index : int) -> Dictionary:
	if index >= 0 and index < BossInterruptPerfectHalfWindow.size():
		return {"perfect" = BossInterruptPerfectHalfWindow[index], "good" = BossInterruptGoodHalfWindow[index]}
	return {"perfect" = InterruptPerfectMax - 0.5, "good" = InterruptGoodMax - 0.5}

static func GetBossCount() -> int:
	return BossNames.size()

static func GetBossName(index : int) -> String:
	return BossNames[index] if index >= 0 and index < BossNames.size() else ""

# SOM-IDLE: hash da entidade do boss (para spawnar a luta ao vivo). Procurado
# pelo _name do preset (Dorian/Gabriel/Marvin/Splatyna são entidades reais com
# sprite+animação próprios). Cache por índice com TTL para acomodar hotfixes de
# balance que alterem EntitiesDB pós-boot.
const ENTITY_HASH_CACHE_TTL_SEC : int = 300
static var _entityHashCache : Dictionary = {}
static var _entityHashCacheTimestamp : int = 0
static func GetBossEntityHash(index : int) -> int:
	if index < 0 or index >= BossNames.size():
		return DB.UnknownHash
	var now : int = SQLCommons.Timestamp()
	if _entityHashCache.has(index) and now - _entityHashCacheTimestamp < ENTITY_HASH_CACHE_TTL_SEC:
		return int(_entityHashCache[index])
	var want : String = BossNames[index]
	var found : int = DB.UnknownHash
	for hash in DB.EntitiesDB:
		var data : EntityData = DB.EntitiesDB[hash]
		if data != null and data._name == want:
			found = int(hash)
			break
	_entityHashCache[index] = found
	_entityHashCacheTimestamp = now
	return found

static func GetBossFloorLevel(index : int) -> int:
	return BossFloorLevel[index] if index >= 0 and index < BossFloorLevel.size() else 1

# Roll determinístico de drop de chave (chamador passa um rng em [0,1)).
static func RollsKeyDrop(rng : float) -> bool:
	return rng < float(KeyDropPPM) / 1000000.0

# ------------------------------------------------------------------ boss scaling

static func GetBossLevel(playerLevel : int, index : int) -> int:
	return maxi(playerLevel, GetBossFloorLevel(index))

static func GetBossMaxHealth(level : int) -> int:
	return (BossHpBase + BossHpPerLevel * level) * BossHpMult

static func GetBossAttack(level : int) -> int:
	return BossAtkBase + BossAtkPerLevel * level

static func GetBossDefense(level : int) -> int:
	return BossDefBase + BossDefPerLevel * level

# ------------------------------------------------------------------ duel sim

# Resolve o duelo char-vs-boss como corrida de TTK. `player` é um dicionário com
# attack/defense/maxHealth/cycle (vindo do stat.current do agent online, ou de um
# snapshot em teste). Determinístico: sem RNG, sem críticos, dmg min 1.
# `interruptMult` (default 1.0) é o bônus da mecânica ativa de interrupt —
# ver InterruptBonus(timing). Chamadas antigas sem o 3º arg não mudam.
static func Resolve(player : Dictionary, bossLevel : int, interruptMult : float = 1.0) -> Dictionary:
	var bossHP : int = GetBossMaxHealth(bossLevel)
	var bossAtk : int = GetBossAttack(bossLevel)
	var bossDef : int = GetBossDefense(bossLevel)

	var playerAtk : int = int(player.get("attack", 1))
	var playerDef : int = int(player.get("defense", 0))
	var playerHP : int = maxi(1, int(player.get("maxHealth", 1)))
	var playerCycle : float = float(player.get("cycle", PlayerAttackCycle))

	var dmgToBoss : int = maxi(1, int(float(maxi(1, playerAtk + MeleeSkillValue - bossDef)) * maxf(1.0, interruptMult)))
	var dmgToPlayer : int = maxi(1, bossAtk - playerDef)

	var playerTTK : float = (float(bossHP) / float(dmgToBoss)) * playerCycle
	var bossTTK : float = (float(playerHP) / float(dmgToPlayer)) * BossAttackCycle

	var win : bool = playerTTK <= bossTTK
	return {
		"win" = win,
		"bossLevel" = bossLevel,
		"bossHP" = bossHP,
		"duration" = playerTTK if win else bossTTK,
		"playerTTK" = playerTTK,
		"bossTTK" = bossTTK,
		"interruptMult" = interruptMult,
	}

# Conveniência: resolve aplicando o bônus de timing diretamente. `bossIndex >= 0`
# pontua contra a janela DAQUELE boss (a escada aperta índice a índice); sem
# índice vale a janela legacy — mesmo contrato das chamadas antigas.
static func ResolveWithInterrupt(player : Dictionary, bossLevel : int, timing : float, bossIndex : int = -1) -> Dictionary:
	return Resolve(player, bossLevel, InterruptBonus(timing, bossIndex))

# Snapshot das stats do jogador para Resolve(). cycle = castDelay + cooldownAttack
# (o ciclo real do auto-combat), com fallback para PlayerAttackCycle.
static func PlayerFightSnapshot(player) -> Dictionary:
	if player == null or player.stat == null:
		return {}
	var cur = player.stat.current
	var cycle : float = float(cur.castAttackDelay) + float(cur.cooldownAttackDelay)
	if cycle <= 0.0:
		cycle = PlayerAttackCycle
	return {
		"attack" = int(cur.attack),
		"defense" = int(cur.defense),
		"maxHealth" = int(cur.maxHealth),
		"cycle" = cycle,
	}

# ------------------------------------------------------------------ rewards

# xp bruto de uma vitória, dado o xpPerKill da zona do char (o chamador aplica
# newbie boost/VIP e entrega; aqui é só a referência "N kills de farm").
static func VictoryXp(zoneXpPerKill : int) -> int:
	return maxi(1, zoneXpPerKill * BossXpKills)

static func VictoryGold(zoneXpPerKill : int) -> int:
	var xp : int = VictoryXp(zoneXpPerKill)
	return maxi(1, roundi(float(xp) / float(FarmZoneData.GoldPerKillDiv) * BossGoldBonus))

static func ConsolationXp(zoneXpPerKill : int) -> int:
	return maxi(1, zoneXpPerKill * ConsolationXpKills)
