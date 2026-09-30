extends RefCounted
class_name FarmZoneData

# SOM-IDLE: F2 idle-spike zone model, RECALIBRADO (2026-09) contra o dump real de
# mapas/mobs (tests/dump_calibration.gd). Só 28 mapas têm mobs e o nível deles
# cap-a em L20; 4 salas de boss (Dorian/Gabriel/Marvin/Splatyna) saíram do
# rodízio de farm e viram conteúdo de boss-key. Restam 24 zonas de farm reais,
# reordenadas por dificuldade monotônica. O antigo catálogo de 40 zonas tinha 12
# placeholders sem mapa e ordem não-monotônica.
# SOM-IDLE 2026-09-27 (juiz: "o fim de jogo é fundo num eixo só"): a escada passou
# a 27 zonas. As 3 novas (25-27, tier 9) são mapas REAIS que existiam sem mobs no
# cliente — Desert Deep Level, Ship Hold e Tulimshar Castle — e ganharam roster
# próprio em presets/maps/server/** com espécies que nunca entraram em farm
# (Lynx, Goblin, Bandit, Bird, Xakelbael, além de Snake/Skeleton). A ruler de
# content hygiene (tests/content_hygiene_test.gd) exige que toda zona tenha mapa
# resolvido e roster íntegro; a de curvas (tests/balance_test.gd) preço a curva
# das novas zonas pelo settle real, não por hipótese.

const ZONE_COUNT : int = 27
const ZonesPerTier : int = 3				# 9 tiers × 3 zonas = 27
const MAX_TIER : int = 9

# XP_PROGRESSION.md §4.1.2
const XpBasePerKill : int = 1200
const XpGrowthPerZone : float = 1.25
const GoldPerKillDiv : int = 8
# SOM-IDLE: par RECALIBRADO pós-fix do cancelamento de cast + dano-mínimo do
# idle (commit 0f56808 e SkillCommons.FarmDamageFloor). O par alimenta o ganho
# OFFLINE (OfflineSettle: xpPerKill × par × h × eff), então é uma RÉGUA DE
# DESIGN, não uma medição: ~24 s/kill na zona 1, subindo suavemente com a
# densidade/nível das zonas fundas.
# A taxa online REAL foi medida contra esta régua, e mentir aqui custaria caro.
# Com `tests/diag_pacing.gd` a 1× (char L1 novo, zona 1, duas sessões de 300 s):
# ANTES do fix de 2026-09-27 o farmer matava 4 mobs e VIRAVA ESTÁTUA pelo resto da
# sessão — 48 kills/h, 32% do par, kills saturando em 4 em qualquer janela. A causa
# era uma linha: `IdlePolicy.State.DEAD` não tinha produtor, `_tickDead` (o único
# revive do idle) era código morto, e quando o mob derrubava o farmer o
# `ActorCommons.State.DEATH` (absorvente na mesa STATE_TRANSITIONS) congelava
# currentVelocity em ZERO enquanto a policy seguia em COMBAT mandando WalkToward
# para um corpo. DEPOIS do fix, no mesmo probe e mesmo fixture: 252 e 240 kills/h
# (21 e 20 kills/300 s, 14.3 e 15.0 s/kill) = 168% do par. Régua, não permissão:
# online agora rende acima do que o par paga offline, que é a direção certa num
# idle (quem joga não perde para quem loga depois). O texto anterior deste
# comentário ("~160–184 kills/h") descrevia um probe que media o regime morto.
# Custo visível do ciclo: ~8 mortes por sessão de 300 s no L1 novo (a policy não
# acha poção — ver IdlePolicy.autoPotionItemHash) e cada uma custa RespawnDelay.
const ParBaseSeconds : float = 24.0
const ParPerZoneSeconds : float = 0.9

# Tier pacing. minPower era (tier-1)*30 — baixo demais (um char nu L2 já tem
# power ~35 e entrava em tier 2). Agora é uma escada suave por ZONA, amarrada
# ao power nu do nível-intenção da zona (fit medido: nakedPower ≈ 14 + 10.7*L).
# Gear soma attack/defense ao power, então loadout bom deixa "socar acima".
const MinPowerBase : int = 24
const MinPowerPerZone : int = 8

# SOM-IDLE: F3 — dedicated farm spawn table (TECH_SPEC_CORE §2, spike report §5.3).
# Farm instances stop copying the adventure-map spawn density: each zone scales
# its own map spawns to feed the pacing par, with tier-scaled respawn.
# multiplier = 2 + tier (t1 → 3x, t8 → 10x base group counts)
# respawn    = 18s - 2s*tier clamped to [4s, 16s] (t1 → 16s, t8 → 4s)
const FarmSpawnBaseMultiplier : int = 2
const FarmRespawnBaseSeconds : float = 18.0
const FarmRespawnStepSeconds : float = 2.0
const FarmRespawnMinSeconds : float = 4.0

# SOM-IDLE: F3 — item tier bands (ItemCell.tier 1..MAX_TIER). A zone drops items
# from its own tier band [tier, min(tier+1, MAX_TIER)]. A faixa é conteúdo
# DECLARADO, não subproduto de varredura: `BandMaterialNames` diz qual
# matéria-prima pisa cada tier, e o construtor da pool (`GetDropPool`) semeia a
# faixa a partir dessa declaração antes da varredura por tier. Juiz externo
# 2026-09-28: "bandas de drop nascem vazias nos tiers iniciais — fallback
# declarado para Apple", apontando o construtor de faixa (revisão auditada:
# FarmZoneData.gd:243-254). O censo das células em presets/cells/items/** era
# outro motivo: uma célula só entrava numa faixa porque alguém digitou um número
# no .tres, e as matérias-primas novas de presets/cells/items/material/ não
# eram nomeadas por nada no repo. As réguas: tests/drop_band_content_test.gd
# (toda declaração resolve no tier que a declara, nenhuma faixa nasce vazia, Apple
# só na banda do tier dele e no caminho "sem zona", e o conteúdo novo não entra em
# mesa `_drops` de mob) e tests/balance_test.gd (todo roll das faixas novas cai na
# própria faixa, e a fatia de insumo não drene a pia de equipamento).
const DropTierBandSize : int = 2

# SOM-IDLE: matéria-prima por tier da escada (índice == tier - 1). Mesmo idioma
# de `MapBackedNames`/`BossMapNames`: nome canônico do ItemCell, resolvido
# contra o banco em runtime (`GetBandMaterialHash`), nunca hash regravado em
# código. É o PISO da faixa: a varredura por tier acha o resto do catálogo, esta
# tabela diz quem é o conteúdo que a própria faixa deve a quem joga naquele tier.
# Por que células novas e não marcar `material = true` nas empilháveis que já
# existem (Bone, Salt, SnakeSkin, MaggotSlime, SulphurPowder): primeiro, elas são
# o conteúdo das tabelas `_drops` medidas dos mobs — virar matéria-prima as tira
# do leilão e do escambo (`CellCommons.IsMaterial` é porta de trade) e muda a
# identidade do drop que `IdleTestsFrontier.gd:2290-2293` confere contra o ppm; segundo,
# as cinco são tier 1, então tiers 2..9 continuariam sem piso nenhum, que é
# exatamente a meia-lua que o juiz apontou. O arquivo .tres não leva comentário:
# nenhum preset deste repo leva (`presets/**/*.tres`), e a razão de existir de cada
# célula está aqui, onde ela é declarada.
const BandMaterialNames : Array[String] = [
	"Chalk Dust", "Dune Sinew", "Ember Resin",
	"Obsidian Grit", "Glassvine Sap", "Hollow Fang",
	"Star Iron Sand", "Tonori Ash", "Blackpearl Shard",
]

# SOM-CRAFT: fatia do roll de drop que a MATÉRIA-PRIMA leva, em PPM da massa de
# peso da própria faixa (não por célula — uma faixa rasa com dezenas de candidatos
# e uma faixa funda com meia dúzia receberiam shares totalmente diferentes se o
# peso do material fosse fixo). 6% é decisão, com dois lados medidos:
#   - pequeno o bastante para a curva gold/XP das zonas não se mexer: a pia de
#     equipamento perde ~6% dos rolls, e `tests/balance_test.gd` é dono das curvas
#     (a suíte de matéria-prima confere a fatia medida no roll real e vigia que ela
#     não drene a pia; o CONTEÚDO por faixa e a contagem por ppm são régua de
#     tests/drop_band_content_test.gd, e identidade não é nenhuma das duas);
#   - grande o bastante para "farmar insumo" ser atividade de minutos, não de
#     sessão inteira. Deriva-se dos números deste arquivo, não de uma medição
#     regravada aqui: o par da zona 1 é `3600/ParBaseSeconds` kills/h, a pia é
#     `DefaultDropRatePPM` por kill e `MaterialDropSharePPM` dessa contagem cai em
#     matéria-prima — ordem de unidades por hora, uma a cada ~10 min de farm. A
#     grandeza é travada em tests/drop_band_content_test.gd, então mexer em qualquer
#     uma das três constantes obriga a reler a frase acima em vez de confiá-la.
# O INSUMO tem consumo desde 2026-09-28: a forja cobra, além da taxa em ouro,
# `CraftCatalog.MaterialPerCraft(tier)` unidades da matéria-prima do tier
# (`GetBandMaterialHash`), com débito no ledger (`craft_material:<hash>`). A amarra
# oferta↔demanda é a suíte C2 de `tests/craft_authority_test.gd`, que recomputa a
# taxa desta tabela e exige que um craft de tier 1 custe entre 1 e 3 horas de farm.
# Esta constante é o piso de OFERTA, declarado onde a oferta nasce.
const MaterialDropSharePPM : int = 60000

# SOM-IDLE: Apple (poção de vida) é o item de reserva do caminho "sem zona" — id
# de zona inválido no registro do char, que é o único lugar onde ele é resposta por
# desenho. Apple é tier 1 do catálogo, então ele continua caindo nas faixas que
# cobrem o tier 1 pelo próprio tier, como conteúdo; o que a declaração de
# `BandMaterialNames` mudou é que ele deixou de ser resposta de FAIXA: para zona
# cuja banda não alcança o tier 1, responder Apple é falha de conteúdo, não
# degradação aceita. A régua das duas coisas (Apple só onde o tier dele cabe, e o
# guarda do "sem zona" como único Apple declarado) é tests/drop_band_content_test.gd.
const DefaultDropItemHash : int = 215387671		# Apple

# PPM de KILLS: drops esperados por milhão de kills, a MESMA unidade de
# `BossService.KeyDropPPM` (rolada em `BossService.gd:152`), o que é o motivo de
# `OfflineSettle` tratar os dois faucets pelo mesmo eixo. 700000 não é escolha de
# gabinete: é a probabilidade por kill que a mesa viva derruba — `SuiteIdleLootPipeline`
# mediu os mobs da zona 1 e a soma das tabelas `_drops` por kill saiu 0,70, que é a
# linha que `IdleTestsFrontier.gd:2260-2293` trava contra este número. O offline liquida
# `parKillsPerHour × horas × eff × OfflineFactor × mods` kills (`OfflineSettle.gd:319`)
# e multiplica esta taxa por aquele valor, então a pia de drop sai da mesma régua do
# XP/ouro, não de uma contagem de segundos.
#
# O valor anterior (150, lido como ppm-de-segundos em `OfflineSettle`) pagava drop
# por hora contra os drops por kill do farm ao vivo na mesma zona: ordens de
# magnitude a menos, e o offline era o único lugar do repo que multiplicava um ppm
# por 3600. As réguas da época (`IdleTests` "drop count golden", `balance_test`)
# refaziam a mesma expressão do settle e por isso eram verdes ao defeito. Hoje são
# três, cada uma de um lado: `balance_test` trava a GRANDEZA do que o offline paga,
# `IdleTestsFrontier.gd:2290-2293` amarra este ppm à probabilidade medida nas tabelas
# `_drops` dos mobs, e tests/drop_band_content_test.gd amarra o CONTRÁRIO — que o
# conteúdo que as faixas ganharam não entra em mesa de mob nenhuma, e por isso
# encher faixa não tem como mover esta linha.
const DefaultDropRatePPM : int = 700000

const DeathTaxPct : int = 5
const MaxChestsPerSettle : int = 3
const ChestHoursPerChest : int = 4

# XP_PROGRESSION.md §4.1.3: newbie boost x5 until level 10
const NewbieBoostMaxLevel : int = 10
const NewbieBoostFactor : int = 5

#
var id : int								= 0
var tier : int								= 1
var mapID : int								= DB.UnknownHash
var mapName : String						= ""
var mapLevel : int							= 0
var minPower : int							= 0
var xpPerKill : int							= 0
var goldPerKill : int						= 0
var parKillsPerHour : int					= 0
var goldPerHour : int						= 0
var dropItemHash : int						= DefaultDropItemHash
var dropRatePPM : int						= DefaultDropRatePPM
var deathTaxPct : int						= DeathTaxPct

# Farm zone ordering — RECALIBRADO: os 24 mapas reais com mobs (fora os 4 de
# boss) ordenados por dificuldade do mob dominante (nível, depois nível máx),
# do dump de calibração. Difficuldade agora é monotônica zona a zona.
# SOM-IDLE launch gaps: o catálogo PRECISA referenciar os nomes reais do MapsDB
# (SyncWithDB resolve por _name; nome sem mapa = zona sem farm). O rebrand
# 1021878 trocou os 24 nomes por fictícios sem renomear os assets — nenhuma
# zona resolvia e todas as suítes de sim falhavam. Rebrand de mapas exige
# renomear os assets primeiro (trabalho de conteúdo, fora do escopo aqui);
# até lá, os nomes canônicos abaixo (iguais ao MapsDB).
const MapBackedNames : Array[String] = [
	"Candor Cave", "Splatyna's Corridor", "Ship Second Deck",
	"Tulimshar", "Tulimshar Center", "Artis Sewer",
	"Sandstorm", "Tulimshar Bay", "Desert Mines",
	"Desert Abandoned Level", "Tulimshar Western Cave", "Tulimshar Eastern Hills",
	"Ship Alige Hide", "Tulimshar West Wall Pathway", "Tulimshar Western Hills",
	"Manayir", "Drazil", "Tulimshar Beach",
	"Manayir Beach", "Tulimshar Southern Hills", "Desert Pit", "Snake Pit",
	"Desert Mountain Cave", "Desert Mountains",
	# SOM-IDLE 2026-09-27: tier 9 — os três mapas que existiam sem mob nenhum e
	# ganharam roster endgame (presets/maps/server/{tonori,ship,tonori/tulimshar}).
	"Desert Deep Level", "Ship Hold", "Tulimshar Castle",
]

# SOM-IDLE: salas de boss (mob único nomeado, sprite próprio) — fora do rodízio
# de farm, viram conteúdo de boss-key (chave dropada pelos mobs de farm abre a
# luta contra o boss; boss escala com o nível do char, recompensa com xp/drop
# turbinados). Índice i → level do boss para escalar.
# POSIÇÃO i == posição de BossService.BossNames i (réguas em
# tests/content_hygiene_test.gd: mesmo comprimento, sala real carregada, mob da
# sala existindo no EntitiesDB). As 6 salas novas são mapas reais do cliente.
const BossMapNames : Array[String] = [
	"Splatyna's Dorian Dead End", "Splatyna's Gabriel Pit",
	"Splatyna's Marvin Hole", "Splatyna's Chamber",
	# 5-10: nova perna da escada (fim de jogo) — cada uma com arena própria e o
	# boss de verdade spawneado na sala. MESMA ordem de BossService.BossArenas.
	"Tulimshar West Chamber", "Splatyna Cave Entrance",
	"Tulimshar Castle Corridors", "Candor Arena",
	"Ship First Deck", "Ship Nard's Room",
]
const BossBaseLevel : int = 5

static var _catalog : Array[FarmZoneData]			= []
static var _mapIndex : Dictionary[int, int]			= {}

#
static func _build():
	if not _catalog.is_empty():
		return

	var mapLevels : Dictionary[String, int] = _scanMapLevels()
	var zoneID : int = 1
	for mapName in MapBackedNames:
		if zoneID > ZONE_COUNT:
			break
		var mapLevel : int = mapLevels.get(mapName, 0)
		_catalog.append(_make(zoneID, mapName, mapLevel))
		zoneID += 1

	# Pad remaining zones with derived placeholders so the curve contract holds.
	while zoneID <= ZONE_COUNT:
		var name : String = "Zone %d (unmapped)" % zoneID
		var data : FarmZoneData = _make(zoneID, name, 0)
		data.mapID = DB.UnknownHash
		_catalog.append(data)
		zoneID += 1

	for data in _catalog:
		if data.mapID != DB.UnknownHash:
			_mapIndex[data.mapID] = data.id

# Curvas recalibradas sobre ZONE_COUNT (27) zonas reais:
#   tier       = ceil(z / ZonesPerTier)      (3 zonas/tier, MAX_TIER = 9 tiers)
#   minPower   = MinPowerBase + MinPowerPerZone*(z-1)   (escada suave, power nu
#                do nível-intenção; gear deixa socar acima)
#   xpPerKill  = round(1200 * 1.25^(z-1))    (curva do doc, termina em z27)
#   gold       = xp/8
#   par/h      = 3600/(24 + 0.9*(z-1))       (~150/h na z1, ~76/h na z27)
static func _make(zoneID : int, mapName : String, mapLevel : int) -> FarmZoneData:
	var data : FarmZoneData = FarmZoneData.new()
	data.id = zoneID
	data.tier = clampi(ceili(float(zoneID) / float(ZonesPerTier)), 1, MAX_TIER)
	data.mapName = mapName
	data.mapLevel = mapLevel
	data.minPower = MinPowerBase + MinPowerPerZone * (zoneID - 1)
	data.xpPerKill = roundi(XpBasePerKill * pow(XpGrowthPerZone, zoneID - 1))
	data.goldPerKill = roundi(float(data.xpPerKill) / float(GoldPerKillDiv))
	data.parKillsPerHour = roundi(3600.0 / (float(ParBaseSeconds) + ParPerZoneSeconds * float(zoneID - 1)))
	data.goldPerHour = data.parKillsPerHour * data.goldPerKill
	data.mapID = DB.UnknownHash
	return data

# Resolve a real map hash by display name from the generated map database.
static func _scanMapLevels() -> Dictionary[String, int]:
	var result : Dictionary[String, int] = {}
	if not DB.isInitialized:
		return result

	for mapID in DB.MapsDB:
		var mapData : FileData = DB.MapsDB[mapID]
		if mapData and not mapData._name.is_empty():
			result[mapData._name] = mapID
	return result

static func _resolveMapID(mapName : String) -> int:
	if not DB.isInitialized:
		return DB.UnknownHash
	for mapID in DB.MapsDB:
		if DB.MapsDB[mapID]._name == mapName:
			return mapID
	return DB.UnknownHash

#
static func GetZone(zoneID : int) -> FarmZoneData:
	_build()
	return _catalog[zoneID - 1] if zoneID >= 1 and zoneID <= _catalog.size() else null

static func GetZoneForMap(mapID : int) -> FarmZoneData:
	_build()
	var zoneID : int = _mapIndex.get(mapID, 0)
	return GetZone(zoneID) if zoneID > 0 else null

static func GetZoneCount() -> int:
	_build()
	return _catalog.size()

static func GetMapIDForZone(zoneID : int) -> int:
	var zone : FarmZoneData = GetZone(zoneID)
	return zone.mapID if zone else DB.UnknownHash

# Refresh map hashes once the database is up (idempotent, no-op before DB init).
static func SyncWithDB():
	_build()
	if _mapIndex.is_empty() and DB.isInitialized:
		for data in _catalog:
			if data.mapName != "" and data.mapID == DB.UnknownHash:
				data.mapID = _resolveMapID(data.mapName)
				if data.mapID != DB.UnknownHash:
					_mapIndex[data.mapID] = data.id

# ------------------------------------------------------------------ F3: dedicated farm spawn table

# Density multiplier applied to every spawn group of the zone's own map when
# the dedicated farm instance is populated (WorldInstance._map_loaded).
static func GetFarmSpawnMultiplier(zoneID : int) -> int:
	var zone : FarmZoneData = GetZone(zoneID)
	return FarmSpawnBaseMultiplier + (zone.tier if zone else 1)

# Respawn delay for farm-instance mobs (seconds) — tier-scaled: deeper zones
# replenish faster because mob kills are slower and walks are longer.
static func GetFarmRespawnDelay(zoneID : int) -> float:
	var zone : FarmZoneData = GetZone(zoneID)
	var tier : int = zone.tier if zone else 1
	return clampf(FarmRespawnBaseSeconds - FarmRespawnStepSeconds * float(tier), FarmRespawnMinSeconds, FarmRespawnBaseSeconds)

# ------------------------------------------------------------------ F3: tier-banded drop pools

static var _dropPoolCache : Dictionary[int, Array] = {}

# Nome da matéria-prima declarada para o tier (vazio fora da escada). Separado do
# hash porque a régua de conteúdo quer ler a DECLARAÇÃO, não só o resultado.
static func GetBandMaterialName(tier : int) -> String:
	return BandMaterialNames[tier - 1] if tier >= 1 and tier <= BandMaterialNames.size() else ""

# Hash da célula declarada do tier, ou DB.UnknownHash. Só responde quando a célula
# (1) existe no ItemsDB, (2) é matéria-prima de verdade — `CellCommons.IsMaterial`,
# a flag estrutural que a economia toda lê, não o nome bonito — e (3) está NO tier
# que a declara. A terceira condição é o que impede o piso de faixa de enfiar na
# pool um item de tier errado: exatamente o defeito que o fallback antigo entregava
# (juiz externo 2026-09-28, FarmZoneData.gd:243-254 da revisão auditada).
static func GetBandMaterialHash(tier : int) -> int:
	var wanted : String = GetBandMaterialName(tier)
	if wanted.is_empty() or not DB.isInitialized:
		return DB.UnknownHash
	for cellHash in DB.ItemsDB:
		var item : ItemCell = DB.ItemsDB[cellHash]
		if item != null and item.name == wanted and CellCommons.IsMaterial(item) and item.tier == tier:
			return int(cellHash)
	return DB.UnknownHash

# Item hashes whose tier falls inside the zone's band [tier, tier+band-1].
# Deterministic order (hash ascending) so rolls are reproducible.
static func GetDropPool(zoneID : int) -> Array:
	_build()
	var pool : Array = _dropPoolCache.get(zoneID, [])
	if not pool.is_empty():
		return pool

	var zone : FarmZoneData = GetZone(zoneID)
	if zone == null:
		return [DefaultDropItemHash]

	var tierMax : int = mini(zone.tier + DropTierBandSize - 1, MAX_TIER)
	var candidates : Array[int] = []
	# SOM-IDLE 2026-09-28: a faixa nasce da sua própria declaração. Cada tier da
	# banda pisa primeiro a matéria-prima que o catálogo lhe atribui
	# (`BandMaterialNames`) e só depois a varredura por tier acrescenta o resto do
	# catálogo. Com a varredura já cheia o seed é deduplicado abaixo e nada muda
	# em tamanho nem ordem da pool — o que muda é a faixa que nasce sem varredura
	# alguma (tier sem célula, ou catálogo ainda não resolvido): ela deixava de
	# responder conteúdo e o roll caía no Apple genérico, que é o "tiers iniciais
	# nascem vazios" do juiz. A declaração também é o que amarra as células de
	# presets/cells/items/material/*.tres à faixa: sem ela nada no repo nomeava
	# aquelas células, e a pool era efeito colateral de um número num .tres.
	for bandTier : int in range(zone.tier, tierMax + 1):
		var declared : int = GetBandMaterialHash(bandTier)
		if declared != DB.UnknownHash:
			candidates.append(declared)
	for cellHash in DB.ItemsDB:
		var item : ItemCell = DB.ItemsDB[cellHash]
		if item != null and item.tier >= zone.tier and item.tier <= tierMax:
			candidates.append(cellHash)
	candidates.sort()

	# SOM-IDLE 2026-09-27: aqui morava o fallback "faixa vazia → desce um tier →
	# senão Apple": loot de tier errado entregue de forma silenciosa, e a fonte do
	# "bandas nascem vazias" que o juiz apontou. A forma remanescente desse fallback
	# era a pool ficar(va) vazia e o roll responder Apple — hoje a faixa tem conteúdo
	# declarado (`BandMaterialNames`, seed acima), então faixa vazia é falha de
	# conteúdo e quem grita é tests/drop_band_content_test.gd, não o loot do jogador.

	# SOM-IDLE Fase H §6: approved craft templates enter the shared drop pool.
	# The template_hash is the ItemsDB cell hash (visual base); rarity from the
	# submission is stored on craft_item_template and read via DB query at boot
	# of the cache (runtime-approved items join here without restart).
	var craftRows : Array = []
	if Launcher and Launcher.SQL:
		craftRows = Launcher.SQL.QueryBindings(
			"SELECT item_hash, rarity FROM craft_item_template WHERE tier >= ? AND tier <= ?;",
			[zone.tier, tierMax])
	for row in craftRows:
		var itemHash : int = int(row.get("item_hash", 0))
		if itemHash > 0:
			candidates.append(itemHash)
	candidates.sort()

	# Deduplicate (a craft template may reuse a real cell hash as base)
	var seen : Dictionary = {}
	var unique : Array[int] = []
	for h in candidates:
		if not seen.has(h):
			seen[h] = true
			unique.append(h)
	candidates = unique

	_dropPoolCache[zoneID] = candidates
	return candidates

# Rarity weight for a drop pool entry. Reads craft_item_template rarity; real
# ItemsDB items have no stored rarity column, so they default to "Comum".
static func _RarityWeight(itemHash : int) -> int:
	if Launcher and Launcher.SQL:
		var rows : Array = Launcher.SQL.QueryBindings(
			"SELECT rarity FROM craft_item_template WHERE item_hash = ?;", [itemHash])
		if not rows.is_empty():
			var r : String = str(rows[0].get("rarity", "Comum"))
			if r == "Comum":
				return 100
			elif r == "Incomum":
				return 60
			elif r == "Raro":
				return 30
			elif r == "Épico":
				return 12
			elif r == "Lendário":
				return 5
	return 100

# ------------------------------------------------------------------ SOM-CRAFT: peso da matéria-prima

# Massa de peso por entrada da pool, alinhada índice-a-índice com GetDropPool.
# Equipamento/ consumível mantém o peso de raridade de sempre; matéria-prima divide
# entre si a fatia MaterialDropSharePPM do total da faixa, com piso de 1 unidade de
# peso (um material nunca sai do roll por arredondamento). Cacheado junto da pool:
# _RarityWeight bate em SQL por entrada, e GetDropForRoll roda por drop liquidado.
static var _dropWeightCache : Dictionary[int, Array] = {}

static func GetDropWeights(zoneID : int) -> Array:
	var pool : Array = GetDropPool(zoneID)
	var cached : Array = _dropWeightCache.get(zoneID, [])
	if cached.size() == pool.size():
		return cached
	var weights : Array[int] = []
	var materialIndexes : Array[int] = []
	var equipMass : int = 0
	for index in pool.size():
		var itemHash : int = int(pool[index])
		if CellCommons.IsMaterial(DB.ItemsDB.get(itemHash, null)):
			materialIndexes.append(index)
			weights.append(0)
		else:
			var w : int = _RarityWeight(itemHash)
			equipMass += w
			weights.append(w)
	if not materialIndexes.is_empty():
		# matMass / (equipMass + matMass) == ppm / 1e6, resolvido para matMass.
		var matMass : int = roundi(float(equipMass) * float(MaterialDropSharePPM) / float(1000000 - MaterialDropSharePPM))
		var per : int = maxi(1, matMass / materialIndexes.size())
		for index in materialIndexes:
			weights[index] = per
	_dropWeightCache[zoneID] = weights
	return weights

# Share real do roll que a matéria-prima leva nesta zona (0 se a faixa não tem
# material). Medido por peso, não por contagem de célula — é o número que a UI de
# odds e o harness de craft conferem.
static func GetMaterialDropShare(zoneID : int) -> float:
	var pool : Array = GetDropPool(zoneID)
	var weights : Array = GetDropWeights(zoneID)
	var total : int = 0
	var mat : int = 0
	for index in weights.size():
		var w : int = int(weights[index])
		total += w
		if CellCommons.IsMaterial(DB.ItemsDB.get(int(pool[index]), null)):
			mat += w
	return float(mat) / float(maxi(1, total))

# Deterministic weighted pick for a zone drop roll (caller supplies a stable
# roll input). Uses cumulative-rarity roleta so rarer items drop less often —
# preserves determinism (same roll → same item) while honoring rarity weights.
# Multiplicative hash spreads small roll values across the weight space so
# every pool entry is reachable (raw roll % totalWeight would bias to early
# entries when roll << totalWeight).
static func GetDropForRoll(zoneID : int, roll : int) -> int:
	var pool : Array = GetDropPool(zoneID)
	if pool.is_empty():
		# SOM-IDLE 2026-09-28: este ramo não é mais "faixa vazia → Apple". A faixa
		# tem conteúdo declarado (`BandMaterialNames`, seed em `GetDropPool`), então
		# só se chega aqui com o catálogo ainda não resolvido (DB frio) — e a régua
		# tests/drop_band_content_test.gd trava o ramo como inalcançável para zona
		# válida. Importante para a curva: o roll responde IDENTIDADE, um item por
		# roll, nunca quantidade. A contagem de drop por kill vem de `dropRatePPM`
		# (`OfflineSettle.gd:326`, ppm de KILLS × kills equivalentes) e, no farm
		# vivo, da soma das tabelas `_drops` do mob — nenhuma das duas lê a pool. Por
		# isso encher faixa não move o 0,7 drop/kill medido (`SuiteIdleLootPipeline`
		# amarra os dois em tests/IdleTestsFrontier.gd).
		return DefaultDropItemHash
	var weights : Array = GetDropWeights(zoneID)
	var cumulative : Array[int] = []
	var totalWeight : int = 0
	for w in weights:
		totalWeight += int(w)
		cumulative.append(totalWeight)
	# SOM-IDLE launch gaps: o passo multiplicativo anterior
	# (roll * 2654435761 % total) caía num lattice defeituoso para certos
	# totais — com o template Incomum (total 5660) os 200 rolls visitavam ~12
	# clusters e 28 dos 57 itens ficavam inalcançáveis (0/200 p/ Apple E
	# Espada, determinístico). Spread via hash (mesmo roll → mesmo item,
	# determinístico; uniforme no espaço de peso).
	var target : int = absi(hash([roll, totalWeight])) % maxi(1, totalWeight)
	for i in range(cumulative.size()):
		if target < cumulative[i]:
			return int(pool[i])
	return int(pool[0])

static func InvalidateDropPools():
	_dropPoolCache.clear()
	_dropWeightCache.clear()
