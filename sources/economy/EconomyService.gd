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
# FATIA 13: os 13 domínios extraídos (Fatia 2..12) + a projeção que a janela de
# economia lê (EconomyStateView) são montados em `EconomyDomainBinding.Bind`, que
# roda no boot abaixo. Os campos ficam aqui porque é por eles que o hub delega:
# os 11 serviços leem `_eco.<campo>` (settleMutex e helpers raw continuam sendo
# os deste objeto) e cada wrapper do fachada resolve o seu. O que cada domínio é
# está escrito no módulo que o implementa.
var guildService : GuildService = null
var checkoutService : CheckoutService = null
var seasonService : SeasonService = null
var passService : PassService = null
var ahService : AuctionHouseService = null
var shopService : ShopService = null
var itemForgeService : ItemForgeService = null
var bossProgressionService : BossProgressionService = null
var adsCosmeticsService : AdsCosmeticsService = null
var tournamentArenaService : TournamentArenaService = null
var communityService : CommunityService = null
var tradeChestService : TradeChestService = null
var kernel : EconomyKernel = null
var stateView : EconomyStateView = null
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
	# FATIA 13: a montagem dos 13 domínios (ordem, null-check e back-reference) está
	# em `EconomyDomainBinding.Bind`; o lock continua neste objeto, então os filhos
	# continuam compartilhando o settleMutex do fachada.
	EconomyDomainBinding.Bind(self)
	# §10 (Bloco 1) + JUIZ ECONOMIA 2026-09-27: os dois catálogos de dados são
	# validados no boot, fail-closed, e nenhum dos dois derruba o server de
	# propósito — o erro é do arquivo, o resto do jogo continua e a divergência
	# fica no log com a chave/SKU. O regime de cada um está escrito onde ele é
	# conferido: `EconomyBaseCatalog` (anúncio × JSON × companion no pago; os
	# números dos botões base × `data/conf/economy_base_catalog.json` no base).
	for baseDrift : String in EconomyCatalog.LoadBaseCatalog():
		push_error("catálogo base divergente: %s" % baseDrift)
	ApplyVelocityKnobs()
	if "--server" in OS.get_cmdline_args():
		for drift : String in EconomyCatalog.ValidatePaidCatalogFile():
			push_error("catálogo pago divergente: %s" % drift)
		for passErr : String in EconomyCatalog.ValidatePassTables():
			push_error("passe premium com cosmético invisível: %s" % passErr)
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

func _DecayStackRaw(charID : int, itemID : int, count : int) -> bool:
	return kernel._DecayStackRaw(charID, itemID, count)

func _GrantStackRaw(charID : int, accountID : int, itemID : int, count : int, ledgerReason : String, grantReason : String = "", bound : int = 0, parentUID : int = 0, creatorAccountID : int = 0) -> int:
	return kernel._GrantStackRaw(charID, accountID, itemID, count, ledgerReason, grantReason, bound, parentUID, creatorAccountID)


# Executes a direct character-to-character item trade: all-or-nothing escrow
# (invariant 3), fee burned from the initiating account's gems (ECONOMY_STUDY
# §6: trade fee é o sink primário; gems não-cashable). Items are stack rows
# {item_id, count} validated against the FROM character's inventory.
# SOM-IDLE D3: velocity knobs (static var = sintonizável sem rebuild). O default de
# cada um vem de dados e é conferido onde os dados entram: `EconomyBaseCatalog`
# contra `data/conf/economy_base_catalog.json`, `LoadBaseCatalog` no boot. O ASSENTO
# fica nestas três linhas porque `TradeChestService` lê e `tests/IdleTests.gd`
# escreve estes nomes pela classe — mover o assento moveria a superfície de tuning.
static var TradeCooldownSec : int = 60
static var TradeDailyCap : int = 20
# ROADMAP_COMERCIAL S2: VIP = QoL — cap diário maior, mesma taxa e cooldown.
# Nunca power direto; F2P mantém 20/dia.
static var TradeDailyCapVIP : int = 40

# Passa os knobs do catálogo base para os assentos em runtime. Só roda com o
# arquivo validado (`ApplyBaseCatalog` não aplica nada com erro): JSON quebrado não
# afrouxa fricção nenhuma, o que fica de pé é o default do código.
static func ApplyVelocityKnobs() -> void:
	TradeCooldownSec = EconomyCatalog.BaseKnob("trade_cooldown_sec", EconomyCatalog.TradeCooldownSecRef)
	TradeDailyCap = EconomyCatalog.BaseKnob("trade_daily_cap", EconomyCatalog.TradeDailyCapRef)
	TradeDailyCapVIP = EconomyCatalog.BaseKnob("trade_daily_cap_vip", EconomyCatalog.TradeDailyCapVIPRef)

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

# Estado consolidado das janelas de economia (Shop/Chests) numa RPC única — o
# payload está documentado onde é montado (`EconomyStateView.Build`), que é também
# por onde os números do catálogo base validado chegam ao jogador. Wrapper de
# delegação: callers (Server RPC, Gui, suítes) não mudam.

# Fatia 2 → CheckoutService.gd (wrappers de delegação; locking no serviço).

func GetStarterOfferState(accountID : int) -> Dictionary:
	return checkoutService.GetStarterOfferState(accountID)

func GetPendingGrants(accountID : int) -> Array:
	return checkoutService.GetPendingGrants(accountID)

func GetCheckoutIntent(accountID : int, sku : String) -> Dictionary:
	return checkoutService.GetCheckoutIntent(accountID, sku)

func GetPassCheckoutIntent(accountID : int, tier : String) -> Dictionary:
	return checkoutService.GetPassCheckoutIntent(accountID, tier)

func ActivePassSku() -> String:
	return checkoutService.ActivePassSku()

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
	return stateView.Build(accountID, charID)

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

func EnqueueGrant(accountID : int, kind : String, amount : int, idempotencyKey : String, payload : String = "{}", pricePaid : int = 0, currency : String = "") -> bool:
	return checkoutService.EnqueueGrant(accountID, kind, amount, idempotencyKey, payload, pricePaid, currency)

func ProcessPendingGrants(limit : int = 50) -> Dictionary:
	return checkoutService.ProcessPendingGrants(limit)

func RequestPurchaseRefund(accountID : int, idempotencyKey : String) -> Dictionary:
	return checkoutService.RequestPurchaseRefund(accountID, idempotencyKey)

# Alias histórico (work order #97): a reversão deixou de conhecer só gemas, mas o
# nome continua o portão citado no handoff e na suíte — um só caminho por baixo.
func RequestGemRefund(accountID : int, idempotencyKey : String) -> Dictionary:
	return checkoutService.RequestPurchaseRefund(accountID, idempotencyKey)

# ------------------------------------------------------------------ E1: guilds (Fatia 2 → GuildService.gd)
# Wrappers de delegação: callers (Server.gd, WorldCommands.gd, Client, testes)
# não mudam. O serviço usa o MESMO settleMutex + helpers raw daqui (composição
# com back-reference), então a semântica de locking é idêntica à pré-fatiamento.

# ------------------------------------------------------------------ _CharGoldRaw (Fatia 12 -> EconomyKernel.gd)
func _CharGoldRaw(charID : int) -> int:
	return kernel._CharGoldRaw(charID)

# Gold: caminho único do kernel (stat.gp + ledger + espelho no agente carregado).
func MoveGold(charID : int, amount : int, reason : String) -> bool:
	return kernel.MoveGold(charID, amount, reason)

func ReconcileWalletDaily(nowSec : int = 0) -> Dictionary:
	return kernel.ReconcileWalletDaily(nowSec)

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

# Administração de roster (AUDITORIA 2026-09-28): a política está em `GuildRoster.gd`,
# a ESCRITA continua no dono da tabela. A fachada existe para o chamador não depender do
# campo interno `guildService` — mesma forma de `PromoteMember` acima.
func DemoteMember(leaderAccount : int, targetAccount : int) -> bool:
	return guildService.DemoteMember(leaderAccount, targetAccount)

func RemoveMember(guildID : int, targetAccount : int) -> bool:
	return guildService.RemoveMember(guildID, targetAccount)

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

func MintAdSlot(accountID : int, placement : String) -> Dictionary:
	return adsCosmeticsService.MintAdSlot(accountID, placement)

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

# JUIZ MARKETPLACE 2026-09-27 (b): página de verdade — OFFSET do servidor e
# filtro (teto de preço, item) aplicados no SQL, com o total para a régua de
# páginas. A janela de 40 linhas de antes sobrevive como tamanho de página.
func BrowseListingsPage(limit : int, offset : int, maxPrice : int, itemID : int) -> Dictionary:
	return ahService.BrowseListingsPage(limit, offset, maxPrice, itemID)

# (a) preço realizado no servidor — o painel lê daqui, não da memória da sessão.
func RecentSoldPrices(itemID : int, limit : int) -> Array[Dictionary]:
	return ahService.RecentSoldPrices(itemID, limit)

func RecentSoldSummary(itemID : int, limit : int) -> Dictionary:
	return ahService.RecentSoldSummary(itemID, limit)

# (c) ordem de compra com gold em escrow, cancelamento e lista da própria conta.
func PlaceBuyOrder(buyerChar : int, itemID : int, count : int, unitPrice : int) -> int:
	return ahService.PlaceBuyOrder(buyerChar, itemID, count, unitPrice)

func CancelBuyOrder(charID : int, orderID : int) -> bool:
	return ahService.CancelBuyOrder(charID, orderID)

func BuyOrdersFor(charID : int, limit : int) -> Array[Dictionary]:
	return ahService.BuyOrdersFor(charID, limit)

func BuyOrderCount(accountID : int) -> int:
	return ahService.BuyOrderCount(accountID)

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
	return _rec().ReconcileDaily()

func ReconcileDetail() -> Array[Dictionary]:
	return _rec().ReconcileDetail()

# P-3 (2026-10-06): as pernas que somam, nomeiam e carimbam `reconcile_run`
# saíram para `EconomyReconcile.gd` pelo caminho que o `repo_layout_test`
# registrou como saída da cerca; o seam contratual continua `Launcher.Economy`.
func RunReconcileJob() -> int:
	return _rec().RunReconcileJob()

# ------------------------------------------------------------------ censo de oferta (WorkOrder #185)
# O reconcile acima responde "a carteira bate com o ledger DESDE o último atesto";
# o censo responde a pergunta que ele não pode fazer — "quanto dinheiro existe e
# quem o criou". A fachada existe porque o contrato do seam diário é
# `Launcher.Economy` (`SQLBackups.@Run`), e o kernel é quem sabe montar o censo.
func RunSupplyCensusJob() -> Dictionary:
	return kernel.RunSupplyCensusJob()

func SupplyCensusStats() -> Dictionary:
	return kernel.CensusJobStats()

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

func FlagMultiAccount(accountID : int, detail : String) -> bool:
	return communityService.FlagMultiAccount(accountID, detail)

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

# Construído a pedido: o reconcílio roda de minuto em hora, não por frame, e a
# injeção por `self` dispensa o membro vivo na fachada.
func _rec() -> EconomyReconcile:
	var r : EconomyReconcile = EconomyReconcile.new()
	r._eco = self
	return r
