extends RefCounted
class_name EconomyDomainBinding

# FATIA 13: a raiz de composição do fachada. `EconomyService` é o hub: 13 domínios
# extraídos (Fatia 2..12) + a projeção da janela (EconomyStateView) vivem como
# objetos filhos com back-reference `_eco`, e eram ligados um por um dentro de
# `_post_launch`. Esta lista de montagem é a única parte do boot que não é
# política econômica, e ela sai daqui sem mudar nada: mesma ordem, mesma
# null-check (idempotente — o boot roda uma vez por processo), mesmo `self`
# injetado. O lock continua no fachada (`eco.settleMutex` / `eco._get_settle_mutex`),
# então a semântica de locking é idêntica à de antes da fatia.
#
# `static func` em RefCounted: não há estado aqui, só a montagem do grafo.

static func Bind(eco : EconomyService) -> void:
	# SOM-IDLE Fatia 2: domínio de guild extraído (composição com back-reference;
	# usa este mesmo settleMutex + helpers raw — locking idêntico ao pré-fatiamento).
	if eco.guildService == null:
		eco.guildService = GuildService.new()
		eco.guildService._eco = eco
	# SOM-IDLE Fatia 2: domínios de checkout (grant queue/VIP/refund) e seasons
	# extraídos — mesma composição, callers públicos ficam nos wrappers do fachada.
	if eco.checkoutService == null:
		eco.checkoutService = CheckoutService.new()
		eco.checkoutService._eco = eco
	if eco.seasonService == null:
		eco.seasonService = SeasonService.new()
		eco.seasonService._eco = eco
	if eco.passService == null:
		eco.passService = PassService.new()
		eco.passService._eco = eco
	# SOM-IDLE Fatia 4: domínio de auction house (listings + bot seed) extraído.
	if eco.ahService == null:
		eco.ahService = AuctionHouseService.new()
		eco.ahService._eco = eco
	# SOM-IDLE Fatia 5: domínio de loja (baús por gems, daily shop, vendor) extraído.
	if eco.shopService == null:
		eco.shopService = ShopService.new()
		eco.shopService._eco = eco
	# SOM-IDLE Fatia 6: domínio de forja (sinks de item + crafting Fase H) extraído.
	if eco.itemForgeService == null:
		eco.itemForgeService = ItemForgeService.new()
		eco.itemForgeService._eco = eco
	# SOM-IDLE Fatia 7: domínio de progressão de boss (rebirth + escada + tormento/rush) extraído.
	if eco.bossProgressionService == null:
		eco.bossProgressionService = BossProgressionService.new()
		eco.bossProgressionService._eco = eco
	# SOM-IDLE Fatia 8: domínio de monetização de janela (rewarded ads + cosméticos/entitlements) extraído.
	if eco.adsCosmeticsService == null:
		eco.adsCosmeticsService = AdsCosmeticsService.new()
		eco.adsCosmeticsService._eco = eco
	# SOM-IDLE Fatia 9: dominio de competicao (Fase F torneios + R4 arena assimetrica) extraido.
	if eco.tournamentArenaService == null:
		eco.tournamentArenaService = TournamentArenaService.new()
		eco.tournamentArenaService._eco = eco
	# SOM-IDLE Fatia 10: dominio de comunidade (R3 live events + boards, conquistas, R1 referral/anti-fraude) extraido.
	if eco.communityService == null:
		eco.communityService = CommunityService.new()
		eco.communityService._eco = eco
	# SOM-IDLE Fatia 11: dominio de troca + baus extraido (ultimo do god-node).
	if eco.tradeChestService == null:
		eco.tradeChestService = TradeChestService.new()
		eco.tradeChestService._eco = eco
	# SOM-IDLE Fatia 12: kernel compartilhado (carteira, ledger, ops de item raw, baús de chave) extraido.
	if eco.kernel == null:
		eco.kernel = EconomyKernel.new()
		eco.kernel._eco = eco
	# FATIA 13: a projeção que a janela de economia lê numa RPC única.
	if eco.stateView == null:
		eco.stateView = EconomyStateView.new()
		eco.stateView._eco = eco
