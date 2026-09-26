extends ServiceBase
class_name EconomyService

# SOM-IDLE: economy service (TECH_SPEC_CORE.md §4-§5 + ECONOMY_STUDY.md).
# Ledger de ouro/XP/gems/itens, trade P2P (fee burn), baús provably-fair com
# pity, boss economy e grants de pagamento. ExecuteTrade/OpenChest saíram de
# stub (F4) para implementação completa — ver ECONOMY_STUDY.md §2-§3.


# P4 — escalabilidade: sharding do mutex por conta para reduzir serialização.
# Antes: 1 mutex global (settleMutex) serializa todas as transações.
# Agora: dicionário de mutexes derivado por hash(accountID), com fallback para mutex global.
var settleMutex : Mutex = Mutex.new()
var settleMutexes : Dictionary[int, Mutex] = {}
# SOM-IDLE Fatia 2: domínio de guild extraído (composição com back-reference;
# usa este mesmo settleMutex + helpers raw — locking idêntico ao pré-fatiamento).
var guildService : GuildService = null
# SOM-IDLE Fatia 2: domínios de checkout (grant queue/VIP/refund) e seasons
# extraídos — mesma composição, callers públicos ficam nos wrappers abaixo.
var checkoutService : CheckoutService = null
var seasonService : SeasonService = null
var passService : PassService = null
# SOM-IDLE Fatia 4: domínio de auction house (listings + bot seed) extraído.
var ahService : AuctionHouseService = null
# SOM-IDLE Fatia 5: domínio de loja (baús por gems, daily shop, vendor) extraído.
var shopService : ShopService = null
# SOM-IDLE Fatia 6: domínio de forja (sinks de item + crafting Fase H) extraído.
var itemForgeService : ItemForgeService = null
# SOM-IDLE Fatia 7: domínio de progressão de boss (rebirth + escada + tormento/rush) extraído.
var bossProgressionService : BossProgressionService = null
# SOM-IDLE Fatia 8: domínio de monetização de janela (rewarded ads + cosméticos/entitlements) extraído.
var adsCosmeticsService : AdsCosmeticsService = null
# SOM-IDLE Fatia 9: dominio de competicao (Fase F torneios + R4 arena assimetrica) extraido.
var tournamentArenaService : TournamentArenaService = null
# SOM-IDLE Fatia 10: dominio de comunidade (R3 live events + boards, conquistas, R1 referral/anti-fraude) extraido.
var communityService : CommunityService = null
# SOM-IDLE Fatia 11: dominio de troca + baus extraido (ultimo do god-node).
var tradeChestService : TradeChestService = null
# SOM-IDLE Fatia 12: kernel compartilhado (carteira, ledger, ops de item raw, baús de chave) extraido.
var kernel : EconomyKernel = null
var _shardInitMutex : Mutex = Mutex.new()

func _get_settle_mutex(accountID : int) -> Mutex:
	var shardID : int = absi(hash(accountID)) % EconomyCatalog.SHARD_COUNT
	if not settleMutexes.has(shardID):
		_shardInitMutex.lock()
		if not settleMutexes.has(shardID):
			settleMutexes[shardID] = Mutex.new()
		_shardInitMutex.unlock()
	return settleMutexes[shardID]

# SOM-IDLE C1: companion grant poll (main thread, vazio = no-op barato).
var _grantPollAccum : float = 0.0

func _process(delta : float) -> void:
	if not isInitialized:
		return
	# ROADMAP_COMERCIAL S2: AH bot seed no boot (server; uma vez por processo).
	if Launcher.SQL != null and Launcher.SQL.isInitialized:
		_trySeedAuctionBots()
	_grantPollAccum += delta
	if _grantPollAccum >= EconomyCatalog.GrantPollSec:
		_grantPollAccum = 0.0
		ProcessPendingGrants(20)

#
func _post_launch():
	if guildService == null:
		guildService = GuildService.new()
		guildService._eco = self
	if checkoutService == null:
		checkoutService = CheckoutService.new()
		checkoutService._eco = self
	if seasonService == null:
		seasonService = SeasonService.new()
		seasonService._eco = self
	if passService == null:
		passService = PassService.new()
		passService._eco = self
	if ahService == null:
		ahService = AuctionHouseService.new()
		ahService._eco = self
	if shopService == null:
		shopService = ShopService.new()
		shopService._eco = self
	if itemForgeService == null:
		itemForgeService = ItemForgeService.new()
		itemForgeService._eco = self
	if bossProgressionService == null:
		bossProgressionService = BossProgressionService.new()
		bossProgressionService._eco = self
	if adsCosmeticsService == null:
		adsCosmeticsService = AdsCosmeticsService.new()
		adsCosmeticsService._eco = self
	if tournamentArenaService == null:
		tournamentArenaService = TournamentArenaService.new()
		tournamentArenaService._eco = self
	if communityService == null:
		communityService = CommunityService.new()
		communityService._eco = self
	if tradeChestService == null:
		tradeChestService = TradeChestService.new()
		tradeChestService._eco = self
	if kernel == null:
		kernel = EconomyKernel.new()
		kernel._eco = self
	# §10 (Bloco 1): o catálogo pago é validado no boot do servidor. A CI amarra as
	# três pontas (anúncio / JSON / fallback do companion); isto pega o JSON editado
	# na máquina do operator — um `kind` novo ou preço trocado de um lado só é
	# dinheiro aceito e mercadoria nunca entregue dias depois, com a fila de grant
	# parada em `pending`. Não derruba o server de propósito: o erro é do catálogo,
	# o resto do jogo continua e a divergência fica no log com o SKU.
	if "--server" in OS.get_cmdline_args():
		for drift : String in EconomyCatalog.ValidatePaidCatalogFile():
			push_error("catálogo pago divergente: %s" % drift)
	isInitialized = true

func Destroy():
	isInitialized = false

# ------------------------------------------------------------------ kernel compartilhado (Fatia 12 -> EconomyKernel.gd)
func GetBalance(accountID : int) -> int:
	return kernel.GetBalance(accountID)

func GetGoldLedgerSum(accountID : int) -> int:
	return kernel.GetGoldLedgerSum(accountID)

func LedgerAppend(charID : int, accountID : int, kind : String, amount : int, balanceAfter : int, reason : String = "") -> bool:
	return kernel.LedgerAppend(charID, accountID, kind, amount, balanceAfter, reason)

func GrantItem(accountID : int, itemHash : int, count : int, reason : String = "") -> bool:
	return kernel.GrantItem(accountID, itemHash, count, reason)

# Não há RemoveItem aqui de propósito: tirar item do inventário é
# Inventory.RemoveItem → SQL.RemoveItem, e os movimentos econômicos de item
# (listar no leilão, grant de compra, fee) entram assinados em ledger pelos
# domínios. O stub `RemoveItem(uid) -> false` que existia aqui não tinha
# chamador nenhum e devolver false para uma remoção seria um sumiço silencioso.

func GetGems(accountID : int) -> int:
	return kernel.GetGems(accountID)

func AddGems(accountID : int, amount : int, reason : String) -> bool:
	return kernel.AddGems(accountID, amount, reason)

func GrantBossKey(charID : int, amount : int, reason : String) -> int:
	return kernel.GrantBossKey(charID, amount, reason)

# ------------------------------------------------------------------ rebirth (B+C) (Fatia 7 -> BossProgressionService.gd)
func GetRebirthMults(charID : int) -> Dictionary:
	return bossProgressionService.GetRebirthMults(charID)

func InvalidateRebirthCache(charID : int) -> void:
	bossProgressionService.InvalidateRebirthCache(charID)

func AddEssence(charID : int, amount : int, reason : String) -> int:
	return bossProgressionService.AddEssence(charID, amount, reason)

func BuyRebirthUpgrade(charID : int, upgradeID : String) -> Dictionary:
	return bossProgressionService.BuyRebirthUpgrade(charID, upgradeID)

func Rebirth(charID : int, player) -> Dictionary:
	return bossProgressionService.Rebirth(charID, player)

func GetRebirthState(charID : int) -> Dictionary:
	return bossProgressionService.GetRebirthState(charID)

func SpendBossKey(charID : int, amount : int, reason : String) -> bool:
	return bossProgressionService.SpendBossKey(charID, amount, reason)

func GetBossState(charID : int, playerLevel : int) -> Dictionary:
	return bossProgressionService.GetBossState(charID, playerLevel)

func ChallengeBoss(charID : int, player) -> Dictionary:
	return bossProgressionService.ChallengeBoss(charID, player)

func SettleBossResult(charID : int, player, index : int, win : bool) -> Dictionary:
	return bossProgressionService.SettleBossResult(charID, player, index, win)

# ------------------------------------------------------------------ helpers raw do kernel (Fatia 12 -> EconomyKernel.gd)
func _LedgerAppendLocked(accountID : int, charID : int, kind : String, amount : int, balanceAfter : int, reason : String) -> bool:
	return kernel._LedgerAppendLocked(accountID, charID, kind, amount, balanceAfter, reason)

func _AccountIDForCharacterRaw(charID : int) -> int:
	return kernel._AccountIDForCharacterRaw(charID)

func _ItemCountRaw(charID : int, itemID : int) -> int:
	return kernel._ItemCountRaw(charID, itemID)

func _MoveStack(charFrom : int, charTo : int, itemID : int, count : int) -> bool:
	return kernel._MoveStack(charFrom, charTo, itemID, count)

func _MoveStackUIDs(charFrom : int, charTo : int, itemID : int, count : int) -> Dictionary:
	return kernel._MoveStackUIDs(charFrom, charTo, itemID, count)

func _UIDList(uids : Array) -> String:
	return kernel._UIDList(uids)

func _GrantStackRaw(charID : int, accountID : int, itemID : int, count : int, ledgerReason : String, grantReason : String = "", bound : int = 0, parentUID : int = 0, creatorAccountID : int = 0) -> int:
	return kernel._GrantStackRaw(charID, accountID, itemID, count, ledgerReason, grantReason, bound, parentUID, creatorAccountID)


# Executes a direct character-to-character item trade: all-or-nothing escrow
# (invariant 3), fee burned from the initiating account's gems (ECONOMY_STUDY
# §6: trade fee é o sink primário; gems não-cashable). Items are stack rows
# {item_id, count} validated against the FROM character's inventory.
# SOM-IDLE D3: velocity knobs (static var = sintonizável sem rebuild).
static var TradeCooldownSec : int = 60
static var TradeDailyCap : int = 20
# ROADMAP_COMERCIAL S2: VIP = QoL — cap diário maior, mesma taxa e cooldown.
# Nunca power direto; F2P mantém 20/dia.
static var TradeDailyCapVIP : int = 40

# ------------------------------------------------------------------ F4: troca + baus (Fatia 11 -> TradeChestService.gd)
func GetTradeFeeState(accountID : int) -> Dictionary:
	return tradeChestService.GetTradeFeeState(accountID)

func ExecuteTrade(charIDFrom : int, charIDTo : int, itemsFrom : Array, itemsTo : Array) -> bool:
	return tradeChestService.ExecuteTrade(charIDFrom, charIDTo, itemsFrom, itemsTo)

func OpenChest(charID : int, chestID : int) -> Dictionary:
	return tradeChestService.OpenChest(charID, chestID)

func GetChestOdds(zoneID : int) -> Dictionary:
	return tradeChestService.GetChestOdds(zoneID)

func GetChestOddsForCharacter(charID : int) -> Dictionary:
	return tradeChestService.GetChestOddsForCharacter(charID)

func GetChestPityStatus(charID : int) -> Dictionary:
	return tradeChestService.GetChestPityStatus(charID)

func FormatChestOdds(odds : Dictionary) -> String:
	return tradeChestService.FormatChestOdds(odds)

func _RollChestItem(zoneID : int, roll : int, pity : bool) -> int:
	return tradeChestService._RollChestItem(zoneID, roll, pity)


# ------------------------------------------------------------------ F4: VIP checkout (Fatia 2 → CheckoutService.gd)
# Placeholder pricing (tuning pós-beta; MONETIZATION: R$19.90 / R$39.90 tiers).
# Wrapper de delegação — corpo e locking no serviço (back-reference _eco).

func PurchaseVIP(accountID : int, tier : int) -> bool:
	return checkoutService.PurchaseVIP(accountID, tier)

# ------------------------------------------------------------------ C1: companion grants (Fatia 2 → CheckoutService.gd)
# Fila idempotente pós-webhook (a assinatura é validada no companion,
# `companion/server.py`) — kinds, tier por SKU e
# apply raw vivem no serviço; wrappers no fim do arquivo.

# ------------------------------------------------------------------ beta GUI: shop (Fatia 5 → ShopService.gd)
# Baús por gems (origin 'shop'): débito + ledger + rows no MESMO Transaction,
# path raw com o mesmo mutex. Placeholder pricing (mesmo regime do VIP).

func BuyChests(accountID : int, charID : int, count : int) -> Dictionary:
	return shopService.BuyChests(accountID, charID, count)

# Estado consolidado das janelas de economia (Shop/Chests): wallet, baús
# fechados, odds públicas (texto pré-formatado, compliance loot box) e preços.
# Uma RPC única — as janelas pedem ao abrir e as ações devolvem o estado novo.
#
# Fase A (checkout sandbox): inclui `catalog` (espelho DISPLAY-ONLY do catálogo
# pago — `EconomyCatalog.SHOP_CATALOG`, amarrado a data/conf/paid_catalog.json por
# `ValidatePaidCatalog`; o grant autoritativo vive no companion; preço aqui nunca
# vira crédito), `starter_offer` (elegibilidade one-time D0–D3, sem
# migração: idade via account.created_timestamp + compra prévia via
# grant_queue payload) e `pending_grants` (fila do companion p/ esta conta).
#
# Espelho do catálogo: validado contra data/conf/paid_catalog.json no boot do
# servidor e em SuiteCatalogConsistency — não é mais "manter sincronizado à mão".

# Fatia 2 → CheckoutService.gd (wrappers de delegação; locking no serviço).

func GetStarterOfferState(accountID : int) -> Dictionary:
	return checkoutService.GetStarterOfferState(accountID)

func GetPendingGrants(accountID : int) -> Array:
	return checkoutService.GetPendingGrants(accountID)

func GetCheckoutIntent(accountID : int, sku : String) -> Dictionary:
	return checkoutService.GetCheckoutIntent(accountID, sku)

# ------------------------------------------------------------------ Fase B: loja diária + ofertas (Fatia 5 → ShopService.gd)
# Rotação determinística server-side, reroll pago em gems (3×/dia) e ofertas
# one-time (packs de boss, fim de temporada). Wrappers preservam Server RPC,
# Gui e testes; _DailyRow/_DoReroll continuam expostos p/ rewarded ads (Fase E).

static func ShopDay(now : int) -> int:
	return ShopService.ShopDay(now)

func _DailyRow(accountID : int, day : int) -> Dictionary:
	return shopService._DailyRow(accountID, day)

func _DoReroll(accountID : int, day : int, row : Dictionary) -> Dictionary:
	return shopService._DoReroll(accountID, day, row)

func GetDailyShop(accountID : int) -> Dictionary:
	return shopService.GetDailyShop(accountID)

func RerollDailyShop(accountID : int) -> Dictionary:
	return shopService.RerollDailyShop(accountID)

func BuyDailyOffer(accountID : int, charID : int, offerID : String) -> Dictionary:
	return shopService.BuyDailyOffer(accountID, charID, offerID)

func GetEconomyState(accountID : int, charID : int) -> Dictionary:
	var chestIDs : Array = []
	for chest in Launcher.SQL.GetClosedChests(charID):
		chestIDs.append(int(chest["id"]))
	var until : int = Launcher.SQL.GetVIPUntil(accountID)
	var now : int = SQLCommons.Timestamp()
	var vipActive : bool = until > now
	var odds : Dictionary = GetChestOddsForCharacter(charID)
	# O cap exibido na Loja é o do PERSONAGEM que pediu o estado: 1h de base +
	# hora comprada em anúncio + perk de VIP. O anchor (last_settled_at) é o que
	# separa hora ganha de hora já liquidada — sem ele a vitrine ofereceria de
	# novo o que o jogador já coletou.
	var anchor : int = int(Launcher.SQL.GetCharacter(charID).get("last_settled_at", 0))
	# A vitrine segue a temporada: sem linha `active` na tabela, o companion recusa
	# intent/preferência/sandbox do passe, então a Loja não oferece o botão.
	var seasonActive : bool = not ActiveSeason().is_empty()
	return {
		"gems" = GetGems(accountID),
		"chests" = chestIDs,
		"odds" = odds,
		"odds_text" = FormatChestOdds(odds),
		"pity" = GetChestPityStatus(charID),
		"chest_cost" = EconomyCatalog.ChestCostGems,
		"vip" = {"active" = vipActive, "until" = until, "mods" = OfflineSettle.VIPModFactor if vipActive else 1.0,
			"tier" = Launcher.SQL.GetVIPTier(accountID) if vipActive else 0,
			"cap_hours" = OfflineSettle.CapHoursForCharacter(charID, accountID, anchor, now)},
		"vip1_cost" = EconomyCatalog.VIP1CostGems,
		"vip2_cost" = EconomyCatalog.VIP2CostGems,
		"catalog" = Storefront.ShopCatalog(seasonActive),
		"season_active" = seasonActive,
		"starter_offer" = GetStarterOfferState(accountID),
		"pending_grants" = GetPendingGrants(accountID),
		"vendor" = GetVendorState(accountID),
	}

# ------------------------------------------------------------------ R2: vendor gold (Fatia 5 → ShopService.gd)
# Consumíveis por gold, estoque diário por oferta, sem poder permanente.

func GetVendorState(accountID : int) -> Dictionary:
	return shopService.GetVendorState(accountID)

func BuyVendorOffer(accountID : int, charID : int, offerID : String) -> Dictionary:
	return shopService.BuyVendorOffer(accountID, charID, offerID)

# ------------------------------------------------------------------ R3: live events (Fatia 10 -> CommunityService.gd)
func EnsureCalendarLiveEvents() -> int:
	return communityService.EnsureCalendarLiveEvents()

func TickLiveEvents() -> Dictionary:
	return communityService.TickLiveEvents()

func _ApplyLiveEventActivation(kind : String, params : Dictionary, active : bool) -> void:
	communityService._ApplyLiveEventActivation(kind, params, active)

func _ApplyLiveEventMods(kind : String, params : Dictionary, active : bool) -> void:
	communityService._ApplyLiveEventMods(kind, params, active)

func GetActiveEventsState(accountID : int) -> Dictionary:
	return communityService.GetActiveEventsState(accountID)

func GetLiveEventMods(accountID : int) -> float:
	return communityService.GetLiveEventMods(accountID)

func GetLiveEventCraftingFeeMod() -> float:
	return communityService.GetLiveEventCraftingFeeMod()

func GetSeasonBoardsState(limit : int = 10) -> Dictionary:
	return communityService.GetSeasonBoardsState(limit)


# ------------------------------------------------------------------ R4: async arena (Fatia 9 -> TournamentArenaService.gd)
func TickArenaTickets() -> Dictionary:
	return tournamentArenaService.TickArenaTickets()

func ArenaSetDefense(charID : int) -> Dictionary:
	return tournamentArenaService.ArenaSetDefense(charID)

func _EnsureArenaLadder(accountID : int) -> void:
	tournamentArenaService._EnsureArenaLadder(accountID)

func ArenaAttack(attackerCharID : int, defenderAccountID : int) -> Dictionary:
	return tournamentArenaService.ArenaAttack(attackerCharID, defenderAccountID)

func ArenaBoard(accountID : int, limit : int = 10) -> Dictionary:
	return tournamentArenaService.ArenaBoard(accountID, limit)

# ------------------------------------------------------------------ item sinks (Fatia 6 → ItemForgeService.gd)
# Altar de corrupção (risco vaal), cubagem 3:1 e desmanche: sumidouros
# voluntários server-side e atômicos. Sem wipe de temporada — itens só saem do
# jogo pela decisão do jogador. _BurnGoldRaw/_RollUpgradeReward vivem no serviço.

func CorruptItem(charID : int, itemID : int, forceOutcome : String = "") -> Dictionary:
	return itemForgeService.CorruptItem(charID, itemID, forceOutcome)

func CubeUpcycle(charID : int, itemID : int, forceResultID : int = 0) -> Dictionary:
	return itemForgeService.CubeUpcycle(charID, itemID, forceResultID)

func SalvageItem(charID : int, itemID : int) -> Dictionary:
	return itemForgeService.SalvageItem(charID, itemID)

# ------------------------------------------------------------------ tormento + boss rush (Fatia 7 -> BossProgressionService.gd)
func SetTorment(charID : int, player, level : int) -> Dictionary:
	return bossProgressionService.SetTorment(charID, player, level)

func BuyBossKey(charID : int) -> Dictionary:
	return bossProgressionService.BuyBossKey(charID)

func RunBossRush(charID : int, player) -> Dictionary:
	return bossProgressionService.RunBossRush(charID, player)


# ------------------------------------------------------------------ boards nomeados (Fatia 10 -> CommunityService.gd)
func _NamedSeasonBoard(seasonID : int, kind : String, limit : int) -> Array:
	return communityService._NamedSeasonBoard(seasonID, kind, limit)



# ------------------------------------------------------------------ C1/CDC: grants + refund (Fatia 2 → CheckoutService.gd)
# Wrappers de delegação: callers (Server.gd, testes) não
# mudam. O serviço usa o MESMO settleMutex + helpers raw daqui (composição com
# back-reference), então a semântica de locking é idêntica à pré-fatiamento.

func EnqueueGrant(accountID : int, kind : String, amount : int, idempotencyKey : String, payload : String = "{}") -> bool:
	return checkoutService.EnqueueGrant(accountID, kind, amount, idempotencyKey, payload)

func ProcessPendingGrants(limit : int = 50) -> Dictionary:
	return checkoutService.ProcessPendingGrants(limit)

func RequestGemRefund(accountID : int, idempotencyKey : String) -> Dictionary:
	return checkoutService.RequestGemRefund(accountID, idempotencyKey)

# ------------------------------------------------------------------ E1: guilds (Fatia 2 → GuildService.gd)
# Wrappers de delegação: callers (Server.gd, WorldCommands.gd, Client, testes)
# não mudam. O serviço usa o MESMO settleMutex + helpers raw daqui (composição
# com back-reference), então a semântica de locking é idêntica à pré-fatiamento.

# ------------------------------------------------------------------ _CharGoldRaw (Fatia 12 -> EconomyKernel.gd)
func _CharGoldRaw(charID : int) -> int:
	return kernel._CharGoldRaw(charID)


func GetGuildForAccount(accountID : int) -> int:
	return guildService.GetGuildForAccount(accountID)

func GetGuild(guildID : int) -> Dictionary:
	return guildService.GetGuild(guildID)

func GetMemberRank(accountID : int) -> String:
	return guildService.GetMemberRank(accountID)

func GuildBuffForAccount(accountID : int) -> float:
	return guildService.GuildBuffForAccount(accountID)

func GetGuildLeaderboard(limit : int = 10) -> Array[Dictionary]:
	return guildService.GetGuildLeaderboard(limit)

func CreateGuild(accountID : int, charID : int, guildName : String) -> int:
	return guildService.CreateGuild(accountID, charID, guildName)

func JoinGuild(accountID : int, guildID : int) -> bool:
	return guildService.JoinGuild(accountID, guildID)

func LeaveGuild(accountID : int) -> bool:
	return guildService.LeaveGuild(accountID)

func DepositToVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	return guildService.DepositToVault(accountID, charID, itemID, count)

func WithdrawFromVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	return guildService.WithdrawFromVault(accountID, charID, itemID, count)

func LevelUpGuild(accountID : int, charID : int) -> bool:
	return guildService.LevelUpGuild(accountID, charID)

func PromoteMember(leaderAccount : int, targetAccount : int) -> bool:
	return guildService.PromoteMember(leaderAccount, targetAccount)

func SetGuildTag(accountID : int, tag : String) -> Dictionary:
	return guildService.SetGuildTag(accountID, tag)

func AddGuildPoints(guildID : int, points : int) -> bool:
	return guildService.AddGuildPoints(guildID, points)

func GuildSettlePoints(accountID : int, hours : float) -> void:
	guildService.GuildSettlePoints(accountID, hours)

func VaultSlotsForGuild(guildID : int) -> Dictionary:
	return guildService.VaultSlotsForGuild(guildID)

func GetGuildState(accountID : int) -> Dictionary:
	return guildService.GetGuildState(accountID)

func LevelUpGuildFast(accountID : int, charID : int) -> Dictionary:
	return guildService.LevelUpGuildFast(accountID, charID)

func BuyVaultSlots(accountID : int, charID : int) -> Dictionary:
	return guildService.BuyVaultSlots(accountID, charID)

# ------------------------------------------------------------------ E2: seasons (Fatia 2 → SeasonService.gd)
# Corridas power/spend/boss_kills/guild_points + premiação automática.
# Wrappers de delegação — o serviço usa o MESMO settleMutex daqui; a trava T5
# (SeasonsEnabled) segue idêntica.

func ActiveSeason() -> Dictionary:
	return seasonService.ActiveSeason()

static func SeasonsEnabled() -> bool:
	return SeasonService.SeasonsEnabled()

func CreateSeason(days : int, rules : String = "{}") -> int:
	return seasonService.CreateSeason(days, rules)

func CloseSeason(seasonID : int) -> bool:
	return seasonService.CloseSeason(seasonID)

# ROADMAP_COMERCIAL S3 fatia 1: wrappers p/ helpers puros em EconomyCatalog
# (compatibilidade — chamadas externas via instância/autoload continuam funcionando).
static func PassThresholds() -> Array:
	return EconomyCatalog.PassThresholds()
# Curva cumulativa: L1–10:100 · L11–20:120 · L21–30:140 · L31–40:140.
static func PassLevelForPT(pt : int) -> int:
	return EconomyCatalog.PassLevelForPT(pt)
static func PassDailies(day : int) -> Array:
	return EconomyCatalog.PassDailies(day)
static func PassWeeklies(weekIdx : int) -> Array:
	return EconomyCatalog.PassWeeklies(weekIdx)
static func PassWeekIndex(season : Dictionary, now : int) -> int:
	return EconomyCatalog.PassWeekIndex(season, now)
static func PassDayStartTS(day : int) -> int:
	return EconomyCatalog.PassDayStartTS(day)
static func SeasonS1Rules() -> String:
	return EconomyCatalog.SeasonS1Rules()
static func ReferralCodeFor(accountID : int, username : String) -> String:
	return EconomyCatalog.ReferralCodeFor(accountID, username)
static func IsValidGuildTag(tag : String) -> bool:
	return EconomyCatalog.IsValidGuildTag(tag)
static func AchievementByID(achievementID : String) -> Dictionary:
	return EconomyCatalog.AchievementByID(achievementID)
static func CraftBudgetCap(tier : int, slot : int) -> int:
	return EconomyCatalog.CraftBudgetCap(tier, slot)
static func CraftRarityForUsage(pct : float) -> String:
	return EconomyCatalog.CraftRarityForUsage(pct)
static func CraftSubmitFee(tier : int) -> int:
	return EconomyCatalog.CraftSubmitFee(tier)
static func CraftNormName(name : String) -> String:
	return EconomyCatalog.CraftNormName(name)
static func CraftEditDistance(a : String, b : String) -> int:
	return EconomyCatalog.CraftEditDistance(a, b)

func EnsureSeasonS1() -> int:
	return seasonService.EnsureSeasonS1()

# ------------------------------------------------------------------ ROADMAP_COMERCIAL S2: AH bot seed (Fatia 4 → AuctionHouseService.gd)
# Trava T5-style: SHAMBLETA_AH_BOTS=1 (staging/soft-launch liga; beta off).
# AHBotsEnabled é estático (testes chamam por instância) -> delega no estático do serviço.

static func AHBotsEnabled() -> bool:
	return AuctionHouseService.AHBotsEnabled()

func _trySeedAuctionBots():
	ahService._trySeedAuctionBots()

func EnsureAuctionBots() -> int:
	return ahService.EnsureAuctionBots()

func SnapshotSeasonPower(seasonID : int, limit : int = 100) -> int:
	return seasonService.SnapshotSeasonPower(seasonID, limit)

func SnapshotSeasonSpend(seasonID : int) -> int:
	return seasonService.SnapshotSeasonSpend(seasonID)

func SnapshotSeasonBossKills(seasonID : int) -> int:
	return seasonService.SnapshotSeasonBossKills(seasonID)

func SnapshotSeasonGuildPoints(seasonID : int) -> int:
	return seasonService.SnapshotSeasonGuildPoints(seasonID)

func GetSeasonBoard(seasonID : int, kind : String, limit : int = 20) -> Array[Dictionary]:
	return seasonService.GetSeasonBoard(seasonID, kind, limit)

func TickSeasonLifecycle() -> Dictionary:
	return seasonService.TickSeasonLifecycle()

func SettleSeasonPrizes(seasonID : int) -> Dictionary:
	return seasonService.SettleSeasonPrizes(seasonID)

# ------------------------------------------------------------------ Fase E: rewarded ads (Fatia 8 -> AdsCosmeticsService.gd)
func _AdDayStart() -> int:
	return adsCosmeticsService._AdDayStart()

func AdViewsToday(accountID : int, placement : String = "") -> int:
	return adsCosmeticsService.AdViewsToday(accountID, placement)

func _ValidAdToken(token : String, placement : String) -> bool:
	return adsCosmeticsService._ValidAdToken(token, placement)

func _AdAllowed(accountID : int, placement : String) -> Dictionary:
	return adsCosmeticsService._AdAllowed(accountID, placement)

func _RecordAdView(accountID : int, charID : int, placement : String) -> bool:
	return adsCosmeticsService._RecordAdView(accountID, charID, placement)

func WatchAd(accountID : int, charID : int, placement : String, token : String) -> Dictionary:
	return adsCosmeticsService.WatchAd(accountID, charID, placement, token)

func AfkHoursEarned(accountID : int, charID : int, anchorTs : int) -> float:
	return adsCosmeticsService.AfkHoursEarned(accountID, charID, anchorTs)

func ClaimAdChest(accountID : int, charID : int, token : String) -> Dictionary:
	return adsCosmeticsService.ClaimAdChest(accountID, charID, token)

func RerollDailyShopAd(accountID : int, token : String) -> Dictionary:
	return adsCosmeticsService.RerollDailyShopAd(accountID, token)

func ClaimAdBossKey(accountID : int, charID : int, token : String) -> Dictionary:
	return adsCosmeticsService.ClaimAdBossKey(accountID, charID, token)

static func CosmeticLabel(cosmeticID : String) -> String:
	return AdsCosmeticsService.CosmeticLabel(cosmeticID)

func HasCosmetic(accountID : int, cosmeticID : String) -> bool:
	return adsCosmeticsService.HasCosmetic(accountID, cosmeticID)

func GrantCosmetic(accountID : int, cosmeticID : String, source : String) -> bool:
	return adsCosmeticsService.GrantCosmetic(accountID, cosmeticID, source)

func _MaxRebirths(accountID : int) -> int:
	return adsCosmeticsService._MaxRebirths(accountID)

func _BackfillSupportTitles(accountID : int) -> void:
	adsCosmeticsService._BackfillSupportTitles(accountID)

func GetCosmetics(accountID : int) -> Dictionary:
	return adsCosmeticsService.GetCosmetics(accountID)

func EquipCosmetic(accountID : int, cosmeticID : String) -> Dictionary:
	return adsCosmeticsService.EquipCosmetic(accountID, cosmeticID)

func UnequipCosmetic(accountID : int, slot : String) -> Dictionary:
	return adsCosmeticsService.UnequipCosmetic(accountID, slot)

func BuyCosmetic(accountID : int, charID : int, cosmeticID : String) -> Dictionary:
	return adsCosmeticsService.BuyCosmetic(accountID, charID, cosmeticID)

func _RebirthVitrine(accountID : int, rebirths : int) -> void:
	adsCosmeticsService._RebirthVitrine(accountID, rebirths)

func EquippedTitleLabel(accountID : int) -> String:
	return adsCosmeticsService.EquippedTitleLabel(accountID)

# ------------------------------------------------------------------ Fase C: passe de temporada (Fatia 3 → PassService.gd)
# Wrappers de delegação: callers (Server.gd RPC, SeasonPass.gd, testes, hooks
# de settle/challenge e do SeasonService/CheckoutService) não mudam. O serviço
# usa o MESMO settleMutex + helpers raw daqui (composição com back-reference),
# então a semântica de locking é idêntica à pré-fatiamento.

func _PassStateRaw(accountID : int, seasonID : int) -> Dictionary:
	return passService._PassStateRaw(accountID, seasonID)

func GetSeasonPass(accountID : int) -> Dictionary:
	return passService.GetSeasonPass(accountID)

func ClaimMission(accountID : int, missionID : String) -> Dictionary:
	return passService.ClaimMission(accountID, missionID)

func ClaimPassReward(accountID : int, charID : int, level : int, track : String) -> Dictionary:
	return passService.ClaimPassReward(accountID, charID, level, track)

func SkipPassLevel(accountID : int) -> Dictionary:
	return passService.SkipPassLevel(accountID)

func _PassMilestoneCredit(accountID : int, bossIndex : int) -> void:
	passService._PassMilestoneCredit(accountID, bossIndex)

func _AutoClaimPass(seasonID : int) -> Dictionary:
	return passService._AutoClaimPass(seasonID)


# ------------------------------------------------------------------ E2: auction house (Fatia 4 → AuctionHouseService.gd)
# Escrow em lots, taxa flat queimada, destaque pago + slots extras; guards RMT
# inalterados. Wrappers preservam todos os callers (WorldCommands, Server, testes).

func AHOpenCap(accountID : int) -> int:
	return ahService.AHOpenCap(accountID)

func BuyAHSlot(accountID : int) -> Dictionary:
	return ahService.BuyAHSlot(accountID)

func HighlightListing(accountID : int, listingID : int) -> Dictionary:
	return ahService.HighlightListing(accountID, listingID)

func BrowseListings(limit : int = 20) -> Array[Dictionary]:
	return ahService.BrowseListings(limit)

func ListItemForSale(sellerChar : int, itemID : int, count : int, priceGold : int) -> int:
	return ahService.ListItemForSale(sellerChar, itemID, count, priceGold)

func BuyListing(buyerChar : int, listingID : int) -> bool:
	return ahService.BuyListing(buyerChar, listingID)

func CancelListing(charID : int, listingID : int) -> bool:
	return ahService.CancelListing(charID, listingID)

# ------------------------------------------------------------------ Fase F: torneios (Fatia 9 -> TournamentArenaService.gd)
func ActiveTournament() -> Dictionary:
	return tournamentArenaService.ActiveTournament()

func EnsureWeeklyTournament() -> int:
	return tournamentArenaService.EnsureWeeklyTournament()

func GetTournaments(accountID : int) -> Dictionary:
	return tournamentArenaService.GetTournaments(accountID)

func EnterTournament(accountID : int, charID : int, tournamentID : int) -> Dictionary:
	return tournamentArenaService.EnterTournament(accountID, charID, tournamentID)

func SettleTournament(tournamentID : int) -> Dictionary:
	return tournamentArenaService.SettleTournament(tournamentID)

func TickTournaments() -> Dictionary:
	return tournamentArenaService.TickTournaments()

func ReconcileDaily() -> int:
	return tournamentArenaService.ReconcileDaily()

func RunReconcileJob() -> int:
	return tournamentArenaService.RunReconcileJob()

# ------------------------------------------------------------------ conquistas + R1 referral (Fatia 10 -> CommunityService.gd)
func AchievementProgress(accountID : int, entry : Dictionary) -> int:
	return communityService.AchievementProgress(accountID, entry)

func GetAchievements(accountID : int) -> Array:
	return communityService.GetAchievements(accountID)

func ClaimAchievement(accountID : int, achievementID : String) -> Dictionary:
	return communityService.ClaimAchievement(accountID, achievementID)

func GetReferralState(accountID : int) -> Dictionary:
	return communityService.GetReferralState(accountID)

func SetReferralCode(accountID : int, code : String) -> Dictionary:
	return communityService.SetReferralCode(accountID, code)

func _ReferralMaxLevel(accountID : int) -> int:
	return communityService._ReferralMaxLevel(accountID)

func GrantReferralBonuses() -> int:
	return communityService.GrantReferralBonuses()

func RunFraudScan() -> int:
	return communityService.RunFraudScan()

func _FlagOpen(accountID : int, charID : int, kind : String, detail : String) -> bool:
	return communityService._FlagOpen(accountID, charID, kind, detail)

func FlagMultiAccount(accountID : int, detail : String) -> bool:
	return communityService.FlagMultiAccount(accountID, detail)

func _FlagTradeBursts(now : int) -> int:
	return communityService._FlagTradeBursts(now)

func _FlagLevelVelocity(now : int) -> int:
	return communityService._FlagLevelVelocity(now)

func _FlagFlipTrades(now : int) -> int:
	return communityService._FlagFlipTrades(now)

# ------------------------------------------------------------------ Fase H: criação de itens (Fatia 6 → ItemForgeService.gd)
# Teto = melhor item real por (tier, slot), budget 1:1, aprovação GM com template
# paralelo ao ItemsDB e creator_account_id para o fee de 1% na AH.

func SubmitCraft(charID : int, accountID : int, slot : int, baseItemHash : int, name : String, modifiers : Dictionary) -> Dictionary:
	return itemForgeService.SubmitCraft(charID, accountID, slot, baseItemHash, name, modifiers)

func ApproveCraftSubmission(gm : PlayerAgent, submissionID : int) -> bool:
	return itemForgeService.ApproveCraftSubmission(gm, submissionID)

func RejectCraftSubmission(gm : PlayerAgent, submissionID : int, reason : String) -> bool:
	return itemForgeService.RejectCraftSubmission(gm, submissionID, reason)

