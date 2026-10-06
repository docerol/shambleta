extends RefCounted
class_name EconomyCatalog

# SOM-IDLE / ROADMAP_COMERCIAL S3: catálogo de dados puros + helpers puros
# extraídos de EconomyService.gd (fatia 1 — zero mudança de comportamento).
# EconomyService mantém aliases/wrappers p/ compatibilidade.

# (de EconomyService.gd, antes da divisao)
const LedgerKindGold : String = "gold"

# (de EconomyService.gd, antes da divisao)
const LedgerKindXP : String = "xp"

# (de EconomyService.gd, antes da divisao)
const LedgerKindItem : String = "item"

# (de EconomyService.gd, antes da divisao)
const LedgerKindGems : String = "gems"

# (de EconomyService.gd, antes da divisao)
const LedgerKindBossKey : String = "boss_key"

# (de EconomyService.gd, antes da divisao)
const LedgerKindEssence : String = "essence"

# (de EconomyService.gd, antes da divisao)
const SHARD_COUNT : int = 8

# (de EconomyService.gd, antes da divisao)
const GrantPollSec : float = 30.0

# (de EconomyService.gd, antes da divisao)
const TradeFeeGems : int = 10

# (de EconomyService.gd, antes da divisao)
const TradeRequireVerifiedEmail : bool = true

# (de EconomyService.gd, antes da divisao)
const ChestPityEvery : int = 10		# guaranteed rare (T3+) every N opens

# (de EconomyService.gd, antes da divisao)
const VIP1CostGems : int = 440

# (de EconomyService.gd, antes da divisao)
const VIP2CostGems : int = 880

# (de EconomyService.gd, antes da divisao)
const VIPDays : int = 30

# Os cinco primeiros são dinheiro entrando. `chargeback` é o reverso (P1-6): o
# companion enfileira a linha quando o webhook chega `charged_back`, e o consumo
# está em `CheckoutService._ApplyGrantRaw`. Faltava aqui, e a régua de aceitação
# de `EnqueueGrant` barrava o clawback justamente na porta por onde o operador
# re-enfileira um payment à mão — a fila só andava no caminho do companion, que
# escreve o INSERT direto no banco e não passa por esta lista.
const GrantKinds : Array[String] = ["gems", "gold", "vip_days", "pass_premium", "cosmetic", "chargeback"]

# (de EconomyService.gd, antes da divisao)
const VIP_GRANT_TIERS : Dictionary = {
	"vip.1mo": 1, "vip.3mo": 2, "founder.pack": 1, "starter.pack": 1,
}

# FATIA 13 (gate anti-god-node): os botões base (`ChestCostGemsRef`,
# `MaxChestsPerPurchaseRef`, `TradeCooldownSecRef`, `TradeDailyCapRef`,
# `TradeDailyCapVIPRef`, `BASE_KNOBS_REF`) e o espelho do catálogo cobrável
# (`ShopCatalogRef`) — que eram consts aqui, linha a linha os mesmos números de
# antes do corte — passaram a morar em `EconomyBaseCatalog.gd`, junto do
# validador fail-closed que os amarra a `data/conf/economy_base_catalog.json`.
# O que eles SÃO mudou depois disso, e a palavra "congelada" já não descrevia:
# o número cobrável hoje é o do arquivo, e o que o `ValidateBaseCatalog` confere
# é a FAIXA declarada em `_knob_ranges` (um rebalance entra sem tocar no código);
# `ShopCatalogRef` é a exceção, essa continua amarrada por igualdade. Estes
# consts ficaram sendo o DEFAULT de cada knob — o valor de reserva do processo
# que nunca carregou o catálogo — e a lista de nomes que tem leitor, que é o que
# recusa banda de knob órfão e o que faz a régua de ordem entre pares
# (`KnobOrderings`: quem paga não pode receber menos troca que quem não paga).
# O que paga continua saindo daqui pelo estado em runtime abaixo.
const ChestCostGemsRef : int = EconomyBaseCatalog.ChestCostGemsRef

const MaxChestsPerPurchaseRef : int = EconomyBaseCatalog.MaxChestsPerPurchaseRef

const TradeCooldownSecRef : int = EconomyBaseCatalog.TradeCooldownSecRef

const TradeDailyCapRef : int = EconomyBaseCatalog.TradeDailyCapRef

const TradeDailyCapVIPRef : int = EconomyBaseCatalog.TradeDailyCapVIPRef

const BASE_KNOBS_REF : Dictionary = EconomyBaseCatalog.BASE_KNOBS_REF

const ShopCatalogRef : Array = EconomyBaseCatalog.ShopCatalogRef

# Estado em runtime: os consumidores (`Storefront`, `CheckoutService`,
# `ShopService`, `EconomyService.GetEconomyState`) leem daqui e passam a ler o
# arquivo depois de `LoadBaseCatalog()`. O default é a referência do código
# (o fallback descrito acima), então um processo que nunca carrega o catálogo
# (ferramenta de janela, harness isolado) continua com os números do código —
# nunca com lista vazia. `LoadBaseCatalog` só sobrescreve quando o validador
# devolveu zero erros (fail-closed: arquivo inválido não entra, e o erro vai
# para o log).
static var ChestCostGems : int = ChestCostGemsRef

static var MaxChestsPerPurchase : int = MaxChestsPerPurchaseRef

static var SHOP_CATALOG : Array = ShopCatalogRef

# Os três `static var` de velocity de troca (`EconomyService.gd:177/178/181`)
# continuam lá (são sintonizáveis em runtime por decisão do SOM-IDLE D3); o
# que mudou é a ORIGEM do default, agora lida daqui por `ApplyVelocityKnobs`.
static func BaseKnob(key : String, fallback : int) -> int:
	if not BaseKnobs.has(key):
		return fallback
	return int(BaseKnobs.get(key, fallback))

static var BaseKnobs : Dictionary = {
	"chest_cost_gems": ChestCostGemsRef,
	"max_chests_per_purchase": MaxChestsPerPurchaseRef,
	"trade_cooldown_sec": TradeCooldownSecRef,
	"trade_daily_cap": TradeDailyCapRef,
	"trade_daily_cap_vip": TradeDailyCapVIPRef,
}

# ------------------------------------------------------------------ AH: profundidade de mercado
# JUIZ MARKETPLACE 2026-09-27: a vitrine era uma janela de 40 linhas sem OFFSET
# (leitura, não página) e o histórico de venda morava na memória do client. Os
# três números abaixo são o esqueleto do mercado: tamanho de página (a janela
# antiga de 40, preservada como página), janela do "recentemente vendido" lida
# do servidor e o cap de ordens de compra abertas por conta — espelho do cap de
# anúncios (`AHMaxOpenPerAccount`), porque uma bid é gold travado e gold
# travado sem teto é um balde de escrow para encher o banco.
const AHBrowsePageSize : int = 40

const AHSoldHistoryWindow : int = 10

const AHMaxBuyOrdersPerAccount : int = 3

# Tetos de uma ordem de compra. `AHMaxBidQuantity`/`AHMaxBidUnitPrice` limitam o
# produto antes da multiplicação (o escrow é `quantity × unit_price`, e overflow
# de int num depósito é dinheiro criado); `AHMaxBuyOrderGold` é o teto absoluto
# do depósito de uma ordem só; `AHMaxBidFillRounds` é o teto do laço que cruza a
# ordem contra a vitrine — uma ordem nunca pode prender o main thread do server
# varrendo um mercado grande.
const AHMaxBidQuantity : int = 99

const AHMaxBidUnitPrice : int = 100000000

const AHMaxBuyOrderGold : int = 1000000000

const AHMaxBidFillRounds : int = 25

# (de EconomyService.gd, antes da divisao)
const STARTER_SKU : String = "starter.pack"

# (de EconomyService.gd, antes da divisao)
const STARTER_MAX_AGE_SEC : int = 3 * 86400

# (de EconomyService.gd, antes da divisao)
const DAILY_REROLL_COST : int = 20

# (de EconomyService.gd, antes da divisao)
const DAILY_REROLLS_MAX : int = 3

# (de EconomyService.gd, antes da divisao)
const DAILY_OFFERS_SHOWN : int = 3

# (de EconomyService.gd, antes da divisao)
const SHOP_DAY_UTC_OFFSET : int = 6 * 3600

# (de EconomyService.gd, antes da divisao)
const DAILY_POOL : Array = [
	{"id": "deal_chest1", "label": "1 chest", "kind": "chests", "count": 1, "cost": 120},
	{"id": "deal_chests5", "label": "5 chests (save 120)", "kind": "chests", "count": 5, "cost": 480},
	{"id": "deal_chests10", "label": "10 chests (save 240)", "kind": "chests", "count": 10, "cost": 960},
	{"id": "deal_vip3", "label": "VIP 3-day trial", "kind": "vip_days", "count": 3, "cost": 150},
]

# (de EconomyService.gd, antes da divisao)
const BOSS_PACK_COST : int = 240

# (de EconomyService.gd, antes da divisao)
const BOSS_PACK_CHESTS : int = 3

# (de EconomyService.gd, antes da divisao)
const FINALE_CHESTS : int = 5

# (de EconomyService.gd, antes da divisao)
const FINALE_COST : int = 400

# (de EconomyService.gd, antes da divisao)
const FINALE_WINDOW_SEC : int = 2 * 86400

# (de EconomyService.gd, antes da divisao)
const VENDOR_STOCK_PER_DAY : int = 20

# (de EconomyService.gd, antes da divisao)
# #174: `item` é o NOME DE EXIBIÇÃO da célula, não o basename do arquivo —
# `ParseCellDB` chaveia o `ItemsDB` por `SetCellHash(cell.name)` e os três leitores
# desta tabela (`BuyVendorOffer`, `EnsureAuctionBots`, `AHVendorUnitPrice`) fazem
# `str(offer.item).hash()`. Escrito com o basename, a oferta vira item fantasma.
# A régua é `_suiteMarketItemNames` (`tests/content_hygiene_test.gd:@_suiteMarketItemNames`).
# #173: `cost` também é conteúdo medido — `_suiteVendorCureLadder`
# (`tests/content_hygiene_test.gd:@_suiteVendorCureLadder`) exige que pagar mais nunca
# compre menos cura. Pitaya custava 350 gp curando 15 hp ao lado de um drink de 75 hp
# por 200; agora 40, que é a mesma taxa por hp do drink (2,67 gp/hp).
const VENDOR_CATALOG : Array = [
	{"id": "apple", "label": "Apple x1", "item": "Apple", "count": 1, "cost": 50},
	{"id": "water", "label": "Water Bottle x1", "item": "Water Bottle", "count": 1, "cost": 80},
	{"id": "candy", "label": "Cactus Sour Candy x1", "item": "Cactus Sour Candy", "count": 1, "cost": 150},
	{"id": "croissant", "label": "Croissant x1", "item": "Croissant", "count": 1, "cost": 120},
	{"id": "drink", "label": "Cactus Drink x1", "item": "Cactus Drink", "count": 1, "cost": 200},
	{"id": "pitaya", "label": "Pitaya x1", "item": "Pitaya", "count": 1, "cost": 40},
	{"id": "potion", "label": "Cactus Potion x1", "item": "Cactus Potion", "count": 1, "cost": 500},
]

# (de EconomyService.gd, antes da divisao)
const LIVE_EVENT_DEFAULT_MOD : float = 1.0

# #27 (AUDITORIA item 7 / G2): o mecanismo de live events existia, o catálogo de
# datas não — sem linha em `live_event` nenhum evento dispara nunca, e o motor
# ficava ligado sobre vazio. Estes são os dois únicos kinds que o código honra
# (`drops_mod` em OfflineSettle, `fee_mod` na taxa de crafting). Números da
# proposta R3 que já estava documentada: fim de semana ×2 drop, semana do ferreiro
# −50% na taxa de submissão. Calendário é derivado do relógio UTC, nunca datas
# fixas, então a rotação não precisa de operador.
const LIVE_EVENT_WEEKEND_MOD : float = 2.0
const LIVE_EVENT_SMITH_FEE_MOD : float = 0.5
const LIVE_EVENT_SEED_WEEKS : int = 2

# ROADMAP_COMERCIAL S2: seed de bots na AH no lançamento (a AH nasce morta sem
# oferta; OSRS/Albion seedam o GE via NPCs). Vende consumíveis do vendor com
# ~20% de margem — preço-âncora honesto, sem farm infinito (bots não recompram;
# quando o estoque zera, some da vitrine). Gold do vendedor é creditado no
# BuyListing normal do motor (sem caminho paralelo).
const AH_BOT_ACCOUNTS : Array[String] = ["ah_bot_trader", "ah_bot_farmhand", "ah_bot_merchant"]
const AH_BOT_LISTINGS : Array = [
	{"item": "Apple", "count": 5, "price": 60},
	{"item": "Water Bottle", "count": 5, "price": 95},
	{"item": "Croissant", "count": 5, "price": 145},
	{"item": "Cactus Sour Candy", "count": 5, "price": 180},
	{"item": "Cactus Drink", "count": 5, "price": 240},
	{"item": "Cactus Potion", "count": 3, "price": 600},
]

# (de EconomyService.gd, antes da divisao)
const ARENA_TICKETS_PER_DAY : int = 3

# (de EconomyService.gd, antes da divisao)
const ARENA_TICKETS_VIP_BONUS : int = 1

# (de EconomyService.gd, antes da divisao)
const ARENA_BASE_ELO : int = 1000

# (de EconomyService.gd, antes da divisao)
const ARENA_ELO_K : int = 32

# (de EconomyService.gd, antes da divisao)
const CORRUPT_FEE_BASE : int = 500		# gold × tier², queimado mesmo se brickar

# (de EconomyService.gd, antes da divisao)
const CORRUPT_BRICK_W : float = 0.25

# (de EconomyService.gd, antes da divisao)
const CORRUPT_SEALED_W : float = 0.30

# (de EconomyService.gd, antes da divisao)
const CORRUPT_BLESSED_W : float = 0.30

# (de EconomyService.gd, antes da divisao)
const CUBE_COUNT : int = 3

# (de EconomyService.gd, antes da divisao)
const SALVAGE_GOLD_PER_TIER2 : int = 25	# gold = tier² × 25

# (de EconomyService.gd, antes da divisao)
const SALVAGE_ESSENCE_TIER_MIN : int = 4

# (de EconomyService.gd, antes da divisao)
const SALVAGE_ESSENCE_PER_TIER : int = 2	# essência (loop do rebirth)

# (de EconomyService.gd, antes da divisao)
const FRONTIER_KEY_CHANCE : float = 0.30

# (de EconomyService.gd, antes da divisao)
const BOSS_KEY_GOLD_PRICE : int = 10000

# (de EconomyService.gd, antes da divisao)
const BOSS_RUSH_ESCALATION : int = 2

# (de EconomyService.gd, antes da divisao)
const RefundWindowSeconds : int = 7 * 86400

# (de EconomyService.gd, antes da divisao)
const GuildCreateCostGold : int = 5000

# (de EconomyService.gd, antes da divisao)
const GuildMaxLevel : int = 10

# (de EconomyService.gd, antes da divisao)
const GuildLevelCostGold : Array[int] = [0, 5000, 15000, 40000, 100000, 250000, 600000, 1500000, 4000000, 10000000]

# (de EconomyService.gd, antes da divisao)
const GuildLevelCostGems : Array[int] = [0, 50, 120, 300, 700, 1500, 3000, 6000, 12000, 25000]

# (de EconomyService.gd, antes da divisao)
const GuildBuffPerLevel : float = 0.02

# (de EconomyService.gd, antes da divisao)
const GUILD_POINT_PER_SETTLE_HOUR : int = 1

# (de EconomyService.gd, antes da divisao)
const GUILD_POINT_PER_BOSS_WIN : int = 5

# (de EconomyService.gd, antes da divisao)
const GUILD_VAULT_BASE_SLOTS : int = 10

# (de EconomyService.gd, antes da divisao)
const GUILD_VAULT_PER_LEVEL : int = 2

# (de EconomyService.gd, antes da divisao)
const GUILD_VAULT_SLOT_COST : int = 200

# (de EconomyService.gd, antes da divisao)
const GUILD_VAULT_SLOTS_MAX : int = 20

# (de EconomyService.gd, antes da divisao)
const GUILD_PRIZE_GEMS : Array[int] = [1000, 600, 300]

# (de EconomyService.gd, antes da divisao)
const SeasonsBetaLock : bool = true

# (de EconomyService.gd, antes da divisao)
const SEASON_KINDS : Array[String] = ["power", "spend", "boss_kills", "guild_points"]

# (de EconomyService.gd, antes da divisao)
const SeasonPrizeGems : Array[int] = [3000, 1800, 1200, 700, 500, 400, 300, 300, 200, 200]

# (de EconomyService.gd, antes da divisao)
const AD_CHEST : String = "chest"

# (de EconomyService.gd, antes da divisao)
const AD_REROLL : String = "reroll"

# (de EconomyService.gd, antes da divisao)
const AD_BOSSKEY : String = "bosskey"

# Regra do dono 2026-09-25: o rewarded ad do AFK passou a COMPRAR HORA de
# offline, e o placement que dobrava loot de uma liquidação (afk2x) saiu — o
# único multiplicador que restou é o ×2 do tier 2, que não vem de anúncio.
const AD_AFKHOURS : String = "afkhoras"

# (de EconomyService.gd, antes da divisao)
const AD_PLACEMENTS : Array[String] = ["afkhoras", "chest", "reroll", "bosskey"]

# Horas de offline por view de afkhoras.
const AD_OFFLINE_HOURS_PER_AD : float = 1.0

# Teto de baús nascidos do settle por personagem/dia. Com cap de 1h e piso de 1
# baú por coleta, ClaimOfflineSettle (gate de pegada 60s em Server.gd:490)
# pagaria um baú por minuto; 6/dia é o que floor(h/4) com cap de 12h já produzia,
# então o patamar do faucet não muda — muda a origem da hora.
# Banda nova (P1-retenção, AUDITORIA_2026-09-27): o cap F2P subiu de 1h para 8h
# (OfflineSettle.BaseCapHours); floor(8/4) = 2 baús por coleta, e o teto diário
# de 6 continua sendo o mesmo patamar que a janela de 12h de antes produzia —
# o faucet de baú não se move com o cap novo.
const ChestsPerDayFromSettle : int = 6

# Teto de views por placement/dia. Coberto inteiro desde C2 (auditoria
# 2026-09-24): antes só `chest` e `bosskey` estavam aqui, e a ausência de
# `afkhoras` era o faucet — hora offline não tem cap próprio além do inventário
# de anúncios, que sem verificação no servidor é infinito. 12 é o teto que a
# economia já tinha antes da hora vir de anúncio (o cap de settle era 12h, e
# `ChestsPerDayFromSettle = 6` é o que floor(12/4) produzia): o número não
# afrouxa o faucet, só devolve a origem da hora. `reroll` = 3 é o
# `DAILY_REROLLS_MAX` compartilhado com a versão paga — o ad não compra
# rotação extra, só a mesma sem gems.
const AD_PLACEMENT_CAPS : Dictionary = {"chest": 1, "bosskey": 2, "afkhoras": 12, "reroll": 3}

# SOM-IDLE M2 → C2: esta env continua sendo o interruptor do servidor para
# "acredito na declaração de exibição do client", e continua com default
# fechado. O que mudou é o que ela liga: antes habilitava um formato de token
# público e infinitamente reutilizável ("stub:<placement>:<dia>"); agora o
# servidor minta um nonce de uso único por exibição (`ad_slot`) e a env só
# autoriza a mintagem. Sem a env, `MintAdSlot` recusa e nenhum placement
# credita — em produção o default é este. Antes era `const AdStubEnabled =
# true`, i.e. compilar era a única forma de fechar. `SHAMBLETA_AD_PROVIDER`
# (client) escolhe se o anúncio mostrado é stub ou SDK do portal; não tem poder
# nenhum sobre o servidor.
static func AdStubEnabled() -> bool:
	return OS.get_environment("SHAMBLETA_AD_STUB").strip_edges() == "1"

# Validade de um slot mintado. Curado de propósito: o slot é a autorização para
# MOSTRAR um anúncio, não para receber prêmio. Passado o prazo (anúncio fechado
# antes do fim, janela perdida, client morto) a linha vence, sai da contagem de
# pendentes e a cota do placement volta a estar disponível no próximo clique.
const AD_SLOT_TTL_SECONDS : int = 300

# (de EconomyService.gd, antes da divisao)
const COSMETIC_CATALOG : Dictionary = {
	# Passe S1 (fonte: trilha; volta na Loja do Legado após ≥2 temporadas —
	# live-ops futuro, por isso price 0 aqui).
	"skin_manto": {"type": "formation_skin", "label": "Manto do Descobridor", "price": 0, "req_rebirths": 0},
	"fx_faisca": {"type": "drop_fx", "label": "Faísca de Mana", "price": 0, "req_rebirths": 0},
	"frame_sazonal": {"type": "frame", "label": "Moldura Sazonal S1", "price": 0, "req_rebirths": 0},
	"skin_mascara": {"type": "formation_skin", "label": "Máscara Ritual de Tulimshar", "price": 0, "req_rebirths": 0},
	"emote_guilda": {"type": "emote", "label": "Sinal da Guilda", "price": 0, "req_rebirths": 0},
	"emote_tocha": {"type": "emote", "label": "Tocha do Explorador", "price": 0, "req_rebirths": 0},
	"title_redescobridor": {"type": "title", "label": "Redescobridor", "price": 0, "req_rebirths": 0},
	"title_veterano": {"type": "title", "label": "Veterano da Redescoberta", "price": 0, "req_rebirths": 0},
	"banner_guilda": {"type": "guild_banner", "label": "Estandarte da Redescoberta", "price": 0, "req_rebirths": 0},
	# Vitrine do renascimento (MONETIZATION §2.7): básico grátis no 1º ciclo,
	# estilo à venda em gems — sempre gems/passe, nunca essência (§0.1).
	"rebirth_t1": {"type": "title", "label": "Renascido I", "price": 0, "req_rebirths": 1},
	"rebirth_f1": {"type": "frame", "label": "Moldura do Primeiro Ciclo", "price": 0, "req_rebirths": 1},
	"rebirth_t3": {"type": "title", "label": "Renascido III", "price": 150, "req_rebirths": 3},
	"rebirth_f5": {"type": "frame", "label": "Moldura do Quinto Ciclo", "price": 300, "req_rebirths": 5},
	"rebirth_f10": {"type": "frame", "label": "Moldura do Décimo Ciclo", "price": 600, "req_rebirths": 10},
	"rebirth_fx": {"type": "rebirth_fx", "label": "Partículas do Renascimento", "price": 250, "req_rebirths": 1},
	# Apoio (backfill de compras Fase A; títulos prometidos nos payloads).
	"title_recruta": {"type": "title", "label": "Recruta", "price": 0, "req_rebirths": 0},
	"title_fundador": {"type": "title", "label": "Fundador", "price": 0, "req_rebirths": 0},
	# Fase F: campeão da copa semanal + apoiador (doação via companion).
	"title_campeao": {"type": "title", "label": "Campeão", "price": 0, "req_rebirths": 0},
	"title_apoiador": {"type": "title", "label": "Apoiador", "price": 0, "req_rebirths": 0},
	# Passe Deluxe (BATTLE_PASS_S1 §4): exclusivo vitalício, nunca retorna nem
	# na Loja do Legado.
	"emote_coroa": {"type": "emote", "label": "Coroa do Sol", "price": 0, "req_rebirths": 0},
}

# (de EconomyService.gd, antes da divisao)
const PASS_DAILY_PT : int = 40

# (de EconomyService.gd, antes da divisao)
const PASS_WEEKLY_PT : int = 120

# (de EconomyService.gd, antes da divisao)
const PASS_MILESTONE_PT : int = 50

# (de EconomyService.gd, antes da divisao)
const PASS_SKIP_COST : int = 50

# (de EconomyService.gd, antes da divisao)
const PASS_SKIP_MAX : int = 10

# (de EconomyService.gd, antes da divisao)
const PASS_MAX_LEVEL : int = 40

# (de EconomyService.gd, antes da divisao)
const PASS_BONUS_START : int = 31

# (de EconomyService.gd, antes da divisao)
const PASS_BONUS_GEMS : int = 20

# (de EconomyService.gd, antes da divisao)
const PASS_DOUBLEXP_LAST_DAYS : int = 3

# (de EconomyService.gd, antes da divisao)
const PASS_FREE : Dictionary = {
	3: {"gems": 10}, 5: {"chests": 1}, 8: {"gems": 10},
	10: {"cosmetics": ["emote_tocha"]}, 13: {"gems": 15}, 16: {"chests": 1},
	20: {"gems": 15}, 24: {"chests": 2}, 27: {"gems": 20},
	30: {"gems": 30, "cosmetics": ["title_redescobridor"]},
}

# (de EconomyService.gd, antes da divisao)
const PASS_PREMIUM : Dictionary = {
	1: {"cosmetics": ["skin_manto"]}, 3: {"gems": 25}, 5: {"vip_days": 3},
	6: {"gems": 25}, 8: {"gems": 25}, 9: {"gems": 25},
	11: {"chests": 2}, 12: {"gems": 25}, 14: {"chests": 2},
	15: {"gems": 50}, 17: {"cosmetics": ["skin_mascara"]}, 18: {"gems": 25},
	21: {"chests": 3}, 22: {"gems": 25}, 24: {"gems": 25},
	26: {"gems": 25}, 28: {"gems": 50},
	30: {"gems": 100, "cosmetics": ["title_veterano"]},
}

# (de EconomyService.gd, antes da divisao)
const PASS_DAILY_POOL : Array = [
	{"id": "d_settle2", "label": "Collect AFK 2×", "goal": 2},
	{"id": "d_chest1", "label": "Open 1 chest", "goal": 1},
	{"id": "d_level1", "label": "Gain 1 level (SUB equip)", "goal": 1},
	{"id": "d_farm2h", "label": "Settle 2h (SUB kills)", "goal": 2},
	{"id": "d_vault1", "label": "Deposit 1 item in guild vault", "goal": 1},
	{"id": "d_trade1", "label": "Complete 1 trade", "goal": 1},
	{"id": "d_ahlist1", "label": "List 1 item on AH (SUB reforge)", "goal": 1},
	{"id": "d_shop1", "label": "Open the shop (SUB ad)", "goal": 1},
]

# (de EconomyService.gd, antes da divisao)
const PASS_WEEKLY_POOL : Array = [
	{"id": "w_boss1", "label": "Defeat 1 zone boss", "goal": 1},
	{"id": "w_eff3", "label": "3 sessions ≥ 90% efficiency", "goal": 3},
	{"id": "w_spend100", "label": "Spend 100 gems", "goal": 100},
	{"id": "w_dailies15", "label": "Claim 15 dailies", "goal": 15},
	{"id": "w_guild1", "label": "Guild level-up or 3 vault deposits", "goal": 1},
	{"id": "w_farm8h", "label": "Settle 8h", "goal": 8},
]

# (de EconomyService.gd, antes da divisao)
const AHListFeeGems : int = 5

# P1-D (auditoria 2026-10-06): a listagem também queima gold — 1% do preço,
# mínimo 1, afundado no commit do anúncio. O AH era o "sink primário" alegado
# do roadmap e não destruía grão de ouro; sem custo em gold, listar é grátis e
# o mercado vira calha de RMT. Bots são isentos por construção (sem carteira,
# caminho de seed próprio).
# C-10 (2026-10-06), política ESCRITA, não coincidência de duas ondas: item
# CRAFTADO por terceiro paga as duas taxas na mesma venda — 1% de criador
# (`CraftCatalog.CREATOR_FEE_PCT`, queimado no settle) + 1% de anúncio daqui
# (queimado no list) = 2% do volume destruído por leilão. É decisão, e o
# número da régua é esse: as duas morfam por motivos diferentes (patrocínio
# do criador vs. custo de mesa), não são a mesma taxa escrita duas vezes.
# Mudar qualquer uma das duas exige mexer NAQUIA e no censo `ah_burn`, e é o
# `tests/IdleTests.gd` (rota do middleman) que mede a soma.
const AHGoldFeePct : int = 1

# C-6 (2026-10-06): vão do ciclo de lavagem. A lavagem precisa que o MESMO item
# atravesse o MESMO par nos dois sentidos — o funil permite UM round trip
# completo por par/item dentro do vão (devolver mercadoria, vender de volta ao
# amigo é comércio legítimo) e recusa a PERNA SEGUINTE: a esteira que o
# detector só via depois de rodar é cortada onde o dinheiro vira a mão. O vão
# é o MESMO de `FraudeReview.AHWashWindowSec`: portão e detector julgam a
# mesma janela; trocar um número sem o outro é decisão, não typo.
const AHWashWindowSec : int = 7 * 86400

# (de EconomyService.gd, antes da divisao)
const AHMaxOpenPerAccount : int = 5

# (de EconomyService.gd, antes da divisao)
const AHHighlightFeeGems : int = 15

# (de EconomyService.gd, antes da divisao)
const AHSlotBaseCost : int = 50

# (de EconomyService.gd, antes da divisao)
const AHSlotsMaxExtra : int = 5

# (de EconomyService.gd, antes da divisao)
const TOURNAMENT_ENTRY_GOLD : int = 1000

# (de EconomyService.gd, antes da divisao)
const TOURNAMENT_DAYS : int = 7

# (de EconomyService.gd, antes da divisao)
const TOURNAMENT_PRIZES : Array[int] = [2000, 1200, 800, 500, 300]

# (de EconomyService.gd, antes da divisao)
const TOURNAMENT_CHAMPION_TITLE : String = "title_campeao"

# (de EconomyService.gd, antes da divisao)
const ACHIEVEMENTS : Array = [
	{"id": "slayer_100", "label": "Exterminador iniciante", "desc": "Derrote 100 monstros", "counter": "kills_total", "goal": 100, "gems": 25},
	{"id": "slayer_1000", "label": "Exterminador", "desc": "Derrote 1.000 monstros", "counter": "kills_total", "goal": 1000, "gems": 50, "cosmetic": "emote_tocha"},
	{"id": "slime_100", "label": "Caça-slimes", "desc": "Derrote 100 Slimes", "counter": "kills_mob", "mob": "Slime", "goal": 100, "gems": 30},
	{"id": "chest_10", "label": "Abre-baús", "desc": "Abra 10 baús", "counter": "chests", "goal": 10, "gems": 20},
	{"id": "chest_100", "label": "Mestre dos baús", "desc": "Abra 100 baús", "counter": "chests", "goal": 100, "gems": 60},
	{"id": "boss_1", "label": "Caçador de chefes", "desc": "Vença 1 chefe", "counter": "bosses", "goal": 1, "gems": 30},
	{"id": "boss_10", "label": "Lenda viva", "desc": "Vença 10 chefes", "counter": "bosses", "goal": 10, "gems": 100},
	{"id": "level_20", "label": "Veterano", "desc": "Alcance o nível 20", "counter": "level", "goal": 20, "gems": 25},
	{"id": "level_40", "label": "Elite", "desc": "Alcance o nível 40", "counter": "level", "goal": 40, "gems": 60},
	{"id": "rebirth_1", "label": "Renascer", "desc": "Renasça 1 vez", "counter": "rebirths", "goal": 1, "gems": 50},
]

# (de EconomyService.gd, antes da divisao)
const REFERRAL_BONUS_GEMS : int = 200

# (de EconomyService.gd, antes da divisao)
const REFERRAL_MIN_LEVEL : int = 10

# (de EconomyService.gd, antes da divisao)
const REFERRAL_WINDOW_SEC : int = 3 * 86400

# (de EconomyService.gd, antes da divisao)
const REFERRAL_WEEKLY_CAP : int = 10

# (de EconomyService.gd, antes da divisao)
const FraudTradeBurstPerDay : int = 10

# (de EconomyService.gd, antes da divisao)
const FraudLevelJump : int = 20

# (de EconomyService.gd, antes da divisao)
const FraudLevelJumpHours : float = 2.0

# Fatia do forjeiro movida inteira para `CraftCatalog.gd` em 2026-09-27: budget
# por (tier, slot), pesos de modifier (com a validação fail-closed contra o enum
# Modifier), bandas de raridade, taxa de submissão e as puras de comparação de
# nome. Nisto aqui só fica o que é contrato entre domínios — o forjeiro tem dono
# de decisão próprio agora.

# (de EconomyService.gd, antes da divisao)
static func ShopDay(now : int) -> int:
	return (now - SHOP_DAY_UTC_OFFSET) / 86400


# (de EconomyService.gd, antes da divisao)
static func PassThresholds() -> Array:
	var cum : Array = []
	var total : int = 0
	for lvl in range(1, PASS_MAX_LEVEL + 1):
		var step : int = 100 if lvl <= 10 else (120 if lvl <= 20 else 140)
		total += step
		cum.append(total)
	return cum


# (de EconomyService.gd, antes da divisao)
static func PassLevelForPT(pt : int) -> int:
	var cum : Array = PassThresholds()
	var level : int = 0
	for t in cum:
		if pt >= int(t):
			level += 1
		else:
			break
	return level

# Linha da conta/temporada (cria zerada). Leitura crua p/ uso em transações.

# (de EconomyService.gd, antes da divisao)
static func PassDailies(day : int) -> Array:
	var out : Array = []
	var n : int = PASS_DAILY_POOL.size()
	var start : int = (day * 5) % n
	for k in 3:
		out.append((PASS_DAILY_POOL[(start + k) % n] as Dictionary).duplicate())
	return out


# (de EconomyService.gd, antes da divisao)
static func PassWeeklies(weekIdx : int) -> Array:
	var out : Array = []
	var n : int = PASS_WEEKLY_POOL.size()
	var start : int = (weekIdx * 3) % n
	for k in 3:
		out.append((PASS_WEEKLY_POOL[(start + k) % n] as Dictionary).duplicate())
	return out


# (de EconomyService.gd, antes da divisao)
static func PassWeekIndex(season : Dictionary, now : int) -> int:
	return maxi(0, (ShopDay(now) - ShopDay(int(season.get("starts_at", now)))) / 7)


# (de EconomyService.gd, antes da divisao)
static func PassDayStartTS(day : int) -> int:
	return day * 86400 + SHOP_DAY_UTC_OFFSET


# (de EconomyService.gd, antes da divisao)
static func CosmeticLabel(cosmeticID : String) -> String:
	if COSMETIC_CATALOG.has(cosmeticID):
		return str((COSMETIC_CATALOG[cosmeticID] as Dictionary).get("label", cosmeticID))
	return ""


# (de EconomyService.gd, antes da divisao)
static func SeasonS1Rules() -> String:
	return JSON.stringify({
		"season" = "S1", "days" = 30,
		"kinds" = ["power", "spend", "boss_kills", "guild_points"],
		"prizes" = "gems+cosmetics, non-cashable",
		"frozen" = true,
	})


# (de EconomyService.gd, antes da divisao)
static func ReferralCodeFor(accountID : int, username : String) -> String:
	return "%s#%04d" % [username, accountID % 10000]


# (de EconomyService.gd, antes da divisao)
static func IsValidGuildTag(tag : String) -> bool:
	if tag.length() < 2 or tag.length() > 5:
		return false
	for c in tag:
		if not ((c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
			return false
	return true


# (de EconomyService.gd, antes da divisao; renomeado sem underscore)
static func AchievementByID(achievementID : String) -> Dictionary:
	for entry in ACHIEVEMENTS:
		if str(entry.get("id", "")) == achievementID:
			return entry
	return {}

# ------------------------------------------------------------------ catálogo pago (fonte única)
#
# ROADMAP Bloco 1 item 10: `data/conf/paid_catalog.json` é o catálogo cobrável e
# está nos dois lados da fronteira — o companion cobra dele, o jogo anuncia o
# `SHOP_CATALOG` abaixo e aplica o grant por `kind`. A VALIDAÇÃO saiu daqui na
# FATIA 13 e mora em `EconomyBaseCatalog.gd`, junto da validação do catálogo base
# e da referência congelada que as duas amarram ao disco; os dois caminhos
# públicos continuam nestas linhas porque é por `EconomyCatalog.ValidatePaidCatalog*`
# que o boot do servidor (`EconomyService._post_launch`) e a suíte chamam. O
# validador recebe as tabelas deste arquivo como parâmetro — não lê `EconomyCatalog`
# —, então a dependência corre num sentido só e não há ciclo.
static func ValidatePaidCatalog(raw : String) -> PackedStringArray:
	return EconomyBaseCatalog.ValidatePaidCatalog(raw, COSMETIC_CATALOG, SHOP_CATALOG)

static func ValidatePaidCatalogFile() -> PackedStringArray:
	return EconomyBaseCatalog.ValidatePaidCatalogFile(COSMETIC_CATALOG, SHOP_CATALOG)


# A trilha premium COBRA por cosmético; cosmético sem renderizador é cobrar por
# produto que o jogo não mostra (o critério está declarado em `Storefront`). A
# trilha grátis não entra: sem dinheiro na ponta, o grant cruft é registro, não
# fraude. Régua de boot (fail-closed no log pelo regime dos outros validadores)
# e dupla no grant (`PassService._GrantPassRewardRaw`) — a do grant não deveria
# jamais morder, e se morder é o boot que deixou passar.
static func ValidatePassTables() -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	for level : int in PASS_PREMIUM:
		var reward : Dictionary = PASS_PREMIUM[level]
		for cid in reward.get("cosmetics", []):
			if not Storefront.IsRenderedCosmetic(str(cid)):
				errors.append("pass.premium.%d: cosmético '%s' não tem renderizador" % [level, str(cid)])
	# C-7 origem, ponta do catálogo: VIP é produto pago; a trilha free não pode
	# carregar `vip_days` nem por edição futura deste arquivo.
	for level : int in PASS_FREE:
		if int((PASS_FREE[level] as Dictionary).get("vip_days", 0)) > 0:
			errors.append("pass.free.%d: vip_days na trilha free (C-7: tempo de VIP não sai de graça)" % level)
	return errors


# ------------------------------------------------------------------ catálogo base (fonte única)
#
# JUIZ ECONOMIA 2026-09-27 (nota 9.4, teto declarado na própria ficha): "os
# botões base são constants de código enquanto o catálogo pago já é dados E
# validado". `data/conf/economy_base_catalog.json` é o preço do baú, o teto de
# compra por vez e a fricção da troca direta; o regime é o MESMO de
# `ValidatePaidCatalog` — chave desconhecida, preço não-positivo e SKU que
# nenhum leitor conhece são erros de boot, e um arquivo com um número trocado
# em relação à referência congelada do código também é. A terceira regra é o
# ponto do corte: sem ela, "passar para dados" abre uma porta de rebalance
# silencioso (alguém edita o JSON no servidor e o baú passa de 120 para 60 gems
# sem um commit, sem review e sem harness). Não derruba o servidor: com erro,
# nada do arquivo entra e os números do código continuam valendo, com o desvio
# no log — exatamente a disciplina do catálogo pago acima.
#
# O `static func ValidateBaseCatalog` abaixo é a mesma régua de sempre, agora
# delegada: corpo em `EconomyBaseCatalog.gd`, junto do `ValidatePaidCatalog` e da
# tabela que ele confere. Ficam aqui o estado em runtime que os consumidores leem
# e os três pontos de carga que o escrevem.
static func ValidateBaseCatalog(raw : String) -> PackedStringArray:
	return EconomyBaseCatalog.ValidateBaseCatalog(raw)

# Erros da última carga (vazio = arquivo válido aplicado, ou nada tentado).
static var BaseCatalogErrors : PackedStringArray = PackedStringArray()

# Lê, valida e aplica. Retorna os erros (vazio = aplicado).
static func LoadBaseCatalog() -> PackedStringArray:
	if not FileAccess.file_exists(EconomyBaseCatalog.BaseCatalogPath):
		BaseCatalogErrors = PackedStringArray(["%s não existe — o servidor segue com os números do código" % EconomyBaseCatalog.BaseCatalogPath])
		return BaseCatalogErrors
	return ApplyBaseCatalog(FileAccess.get_file_as_string(EconomyBaseCatalog.BaseCatalogPath))

# Seam do harness: texto entra, estado sai, nenhum disco — é como a suíte prova
# o ramo fail-closed (arquivo inválido NÃO pode sobrescrever nada) sem editar
# `data/conf`.
static func ApplyBaseCatalog(raw : String) -> PackedStringArray:
	BaseCatalogErrors = ValidateBaseCatalog(raw)
	if not BaseCatalogErrors.is_empty():
		return BaseCatalogErrors
	var doc : Dictionary = JSON.parse_string(raw)
	var knobs : Dictionary = doc.get("knobs", {})
	BaseKnobs = knobs.duplicate(true)
	ChestCostGems = int(knobs.get("chest_cost_gems", ChestCostGemsRef))
	MaxChestsPerPurchase = int(knobs.get("max_chests_per_purchase", MaxChestsPerPurchaseRef))
	var lines : Array = []
	for entry in (doc.get("shop", []) as Array):
		lines.append((entry as Dictionary).duplicate(true))
	SHOP_CATALOG = lines
	return BaseCatalogErrors

# Voltar ao estado congelado do código (harness troca o arquivo e devolve).
static func ResetBaseCatalog() -> void:
	BaseKnobs = BASE_KNOBS_REF.duplicate(true)
	ChestCostGems = ChestCostGemsRef
	MaxChestsPerPurchase = MaxChestsPerPurchaseRef
	var lines : Array = []
	for entry in ShopCatalogRef:
		lines.append((entry as Dictionary).duplicate(true))
	SHOP_CATALOG = lines
	BaseCatalogErrors = PackedStringArray()

# P1-4: a validação fail-closed dos pesos de forja mora em `CraftCatalog.gd`
# (`ValidateModWeights`), junto da tabela que ela amarra ao enum Modifier.
