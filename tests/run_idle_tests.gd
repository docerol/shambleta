extends SceneTree

# SOM-IDLE: F2 idle-spike headless test runner
# Boots the project (autoloads + offline server services), waits for readiness,
# then executes the IdleTests suites against the real database and world.
# Usage: godot --headless --path . -s tests/run_idle_tests.gd
# Exit code: number of failed checks (0 = green).
#
# NOTE: the -s main-loop script is compiled BEFORE autoload globals are
# registered, so this file must be fully duck-typed: no class_name references
# and no autoload identifiers (Launcher/DB/...) at parse time. Project classes
# are loaded dynamically after the boot completes.

func _initialize():
	_run_tests()

func _getAutoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _run_tests():
	print("== SOM-IDLE F2 test runner ==")

	# The autoloads boot themselves in -s mode (Launcher._ready starts the
	# offline server + client in debug builds) — just wait for readiness.
	var launcher : Node = _getAutoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload missing")
		quit(1)
		return

	# Wait for DB + World services to finish initializing (max ~30s)
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = launcher.SQL
		var worldNode : Node = launcher.World
		if sqlNode != null and sqlNode.isInitialized and worldNode != null and worldNode.isInitialized:
			break

	print("== boot wait done (waited %d ms) ==" % waited)

	# SOM-IDLE beta fechado (T5): Seasons travadas por padrão; os testes
	# habilitam explicitamente aqui. G1 ligou a mesma env no deploy do beta
	# (`deploy/docker-compose.yml`) — o par ligado/desligado é provado em
	# `SuiteSeasonLock` e a ativação em si, em `SuiteSeasonBootstrap`.
	OS.set_environment("SHAMBLETA_ENABLE_SEASONS", "1")
	# SOM-IDLE M2: o stub de rewarded ad é fechado por default no servidor; a suíte
	# de ads roda o caminho do beta (que liga a env no compose). O par
	# ligado/desligado é provado dentro do próprio SuiteAds.
	OS.set_environment("SHAMBLETA_AD_STUB", "1")
	var sql : Node = launcher.SQL
	var economy : Node = launcher.Economy

	# SOM-IDLE: janitor de órfãos entre runs (testing.db persiste; char_ids
	# reciclados ressuscitariam stacks pré-lots e guilds fantasmas).
	# Ledger/telemetria são append-only e ficam (reconcile tem escopo p/ vivos).
	sql.ExecuteBindings("DELETE FROM item WHERE char_id NOT IN (SELECT char_id FROM character);", [])
	sql.ExecuteBindings("DELETE FROM item_instance WHERE char_id NOT IN (SELECT char_id FROM character);", [])
	sql.ExecuteBindings("DELETE FROM chest_instance WHERE char_id NOT IN (SELECT char_id FROM character);", [])
	sql.ExecuteBindings("DELETE FROM guild_member WHERE guild_id IN (SELECT guild_id FROM guild WHERE leader_account NOT IN (SELECT account_id FROM account));", [])
	sql.ExecuteBindings("DELETE FROM guild_vault WHERE guild_id IN (SELECT guild_id FROM guild WHERE leader_account NOT IN (SELECT account_id FROM account));", [])
	sql.ExecuteBindings("DELETE FROM guild_vault_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE leader_account NOT IN (SELECT account_id FROM account));", [])
	sql.ExecuteBindings("DELETE FROM guild WHERE leader_account NOT IN (SELECT account_id FROM account);", [])
	sql.ExecuteBindings("DELETE FROM auction_listing WHERE status = 'open' AND seller_char NOT IN (SELECT char_id FROM character);", [])
	# SOM-IDLE Fase H: crafting submissions orphaned by stale fixtures
	sql.ExecuteBindings("DELETE FROM craft_name_blocklist;", [])
	sql.ExecuteBindings("DELETE FROM craft_submission WHERE char_id NOT IN (SELECT char_id FROM character);", [])
	sql.ExecuteBindings("DELETE FROM craft_item_template WHERE creator_account_id NOT IN (SELECT account_id FROM account);", [])

	# Load suites dynamically (post-boot, so project classes compile fine)
	# SOM-IDLE: elemental combat — pre-load ElementCommons so the class_name
	# is registered before IdleTests.gd parses (it uses ElementCommons directly).
	load("res://sources/combat/ElementCommons.gd")
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()

	suites.SuiteXpCurve()
	suites.SuiteZoneCatalog()
	suites.SuiteFormatter()

	# DB is a static class (not an autoload) — load it dynamically (post-boot,
	# when the autoload globals exist so it can compile) and poll the static var
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 40:
		if dbScript.isInitialized:
			dbReady = true
			break
		await create_timer(0.25).timeout

	if suites.Check(dbReady, "DB initialized (maps/items/skills loaded)"):
		suites.SuiteDBBacked(sql, economy)

		# SOM-IDLE D1: realtime pacing PRIMEIRO (processo fresco). O probe usa
		# fixture L1 própria; no fim da suíte o physics starvation derruba a
		# leitura (12/h vs 60/h standalone) e o gate vira loteria.
		await suites.SuiteIdlePolicyRealTime(sql)

		# SOM-IDLE: F3 suites (tiers, spawn table, VIP, leaderboard, slots)
		suites.SuiteItemTiers()
		suites.SuiteItemSets()
		suites.SuiteFarmSpawnTable()
		suites.SuiteBossService()
		suites.SuiteElementalCombat()
		var f3char : int = suites.CreateFixture(sql, "idle_f3_account", "IdleF3Tester")
		if suites.Check(f3char != 0, "F3 fixture created (charID %d)" % f3char):
			suites.SuiteVIPMods(sql, f3char, sql.GetAccountIDForCharacter(f3char))
			suites.SuiteLeaderboard(sql, f3char)
			suites.SuiteFormationSlots(sql, f3char, sql.GetAccountIDForCharacter(f3char))

		# SOM-IDLE: F4 suites (trade, chests, VIP checkout)
		var f4a : int = suites.CreateFixture(sql, "idle_f4_account_a", "IdleF4TradeA")
		var f4b : int = suites.CreateFixture(sql, "idle_f4_account_b", "IdleF4TradeB")
		if suites.Check(f4a != 0 and f4b != 0, "F4 fixtures created (%d, %d)" % [f4a, f4b]):
			var acctA : int = sql.GetAccountIDForCharacter(f4a)
			var acctB : int = sql.GetAccountIDForCharacter(f4b)
			suites.SuiteTrade(sql, f4a, f4b, acctA, acctB)
			suites.SuiteChests(sql, f4a, acctA)
			# SOM-IDLE Fase H: crafting submission (fee sink + validation + cap)
			suites.SuiteCrafting(sql, f4a, acctA)
			suites.SuiteCraftDrops(sql, f4a, acctA)
			suites.SuiteCraftFee(sql, f4a, acctA)
			suites.SuiteVIPCheckout(sql, f4a, acctA)
			# SOM-IDLE beta GUI: shop (BuyChests + consolidated economy state)
			var guiChar : int = suites.CreateFixture(sql, "idle_gui_account", "IdleGuiTester")
			if suites.Check(guiChar != 0, "GUI economy fixture created (charID %d)" % guiChar):
				suites.SuiteEconomyShop(sql, guiChar, sql.GetAccountIDForCharacter(guiChar))
				# Fase A: checkout sandbox (catalogo, starter, intents, bundles)
				var coChar : int = suites.CreateFixture(sql, "idle_co_account", "IdleCoTester")
				if suites.Check(coChar != 0, "checkout fixture created (charID %d)" % coChar):
					suites.SuiteCheckout(sql, coChar, sql.GetAccountIDForCharacter(coChar))
				# Fase B: cap offline 1h/24h/24h + loja diária/ofertas
				var capChar : int = suites.CreateFixture(sql, "idle_cap_account", "IdleCapTester")
				if suites.Check(capChar != 0, "vip cap fixture created (charID %d)" % capChar):
					suites.SuiteVIPCap(sql, capChar, sql.GetAccountIDForCharacter(capChar))
				var dsChar : int = suites.CreateFixture(sql, "idle_ds_account", "IdleDsTester")
				if suites.Check(dsChar != 0, "daily shop fixture created (charID %d)" % dsChar):
					suites.SuiteDailyShop(sql, dsChar, sql.GetAccountIDForCharacter(dsChar))
			# SOM-IDLE: B1 item lots + B2 chest odds + B3 wipe baseline + C1 grants + D2 telemetry
			suites.SuiteItemLots(sql)
			suites.SuiteChestOdds(sql)
			suites.SuiteWipeB3(sql)
			suites.SuiteGrantQueue(sql)
			suites.SuiteTelemetry(sql)
			# K1: o funil de dinheiro e a coorte de retenção. Prova que cada evento
			# sai do caminho real (intenção → entrega → mercado → troca) e que a view
			# da migration 045 marca D1/D7/D30 em dia calendário, não em janela móvel.
			suites.SuiteMoneyFunnel(sql)
			suites.SuiteFraud(sql)
			# SOM-IDLE: E guilds + AH/seasons
			suites.SuiteGuilds(sql)
			suites.SuiteSeasonAH(sql)
			suites.SuiteSeasonPayout(sql)
			# Fase C: passe de temporada S1 (PT, missões, premium, skip, auto-claim)
			suites.SuiteSeasonPass(sql)
			# Follow-up Deluxe: premium + 10 níveis + emote + 150 gems
			suites.SuitePassDeluxe(sql)
			# Fase D: cosméticos (catálogo, vitrine, backfill, títulos)
			suites.SuiteCosmetics(sql)
			# Fase E: rewarded ads (tokens, caps por placement, afkhoras)
			suites.SuiteAds(sql)
			# Offline comprado com anúncio (C1): o placement afkhoras, as horas
			# ganhas por personagem e o cap composto. Colado no SuiteAds porque é
			# o mesmo domínio e herda a env do stub que ele liga.
			suites.SuiteOfflineAdHours(sql)
			# Fase F: guild premium + AH premium + 4 corridas + torneios
			suites.SuiteGuildPremium(sql)
			suites.SuiteMarketplace(sql)
			suites.SuiteSeasonRaces(sql)
			suites.SuiteTournamentDonation(sql)
			suites.SuiteSeasonLock(sql)
			# G1: ativação da espinha sazonal (deploy + relógio + ciclo com
			# congelamento do placar). Depois de SuiteSeasonLock porque ela é a
			# única que fala do ciclo completo habilitado e limpa a tabela season.
			suites.SuiteSeasonBootstrap(sql)
			suites.SuiteReferral(sql)
			suites.SuiteVendor(sql)
			suites.SuiteLiveEvents(sql)
			suites.SuiteArena(sql)
			suites.SuiteItemSinks(sql)
			suites.SuiteClasses(sql)
			suites.SuiteAutoIdle()
			suites.SuiteMobVariants(sql)
			suites.SuiteAchievements(sql)
			await suites.SuiteTormentRush(sql, economy)
			# SOM-IDLE: rebirth (híbrido B+C, XP_PROGRESSION §4.2) — awaited: a
			# metade B exige agente vivo no cap (o motor de renascimento é async).
			var rebChar : int = suites.CreateFixture(sql, "idle_rebirth_account", "IdleRebirth")
			if suites.Check(rebChar != 0, "rebirth fixture created (charID %d)" % rebChar):
				await suites.SuiteRebirth(sql, rebChar, economy)
			suites.SuiteI18n(sql)
			suites.SuiteUIScale()

		# SOM-IDLE: P4 regression — Network facade dispatch (sem DB, sempre roda)
		suites.SuiteNetworkDispatch(self.root)

		# ROADMAP_COMERCIAL S2: AH bot seed (gated; DB + reconcile invariants)
		suites.SuiteAHBots(sql, economy)

		# SOM-IDLE: A1 auth hardening + A2 ops hardening
		suites.SuiteAuthHardening(sql)
		suites.SuiteTwoFactor(sql)
		# SOM-IDLE M1: handlers de setup do 2FA no NetServer (o facade existia sem
		# implementação — o painel de conta nunca respondeu).
		suites.SuiteTwoFactorSetup(sql)
		# SOM-IDLE V2: TOTP contra os vetores do RFC 6238 e contra o raio real da
		# janela de tolerância (puro, sem DB).
		suites.SuiteTwoFactorVectors()
		# SOM-IDLE C1/C1b: chat e balão de fala — markup de terceiros inerte no
		# sink, teto de tamanho no servidor, nick validado no servidor.
		suites.SuiteChatHardening()
		# SOM-IDLE C1c: denúncia e mute no envio — os dois portais de saída cobram a
		# sanção, a prova da denúncia é o trecho que o servidor viu, e a fila fecha.
		suites.SuiteChatModeration(sql)
		suites.SuiteLGPD(sql)
		suites.SuiteRefund(sql)
		suites.SuiteConcurrency(sql)
		suites.SuiteOpsA2(sql)

		# SOM-IDLE D1: modo de lançamento (live.db/porta/feature tag) amarrado
		# aos arquivos do deploy — só lê res://, então roda fora do bloco do DB.
		suites.SuiteDeployMode()

		# SOM-IDLE L1: /healthz e /metrics ao vivo (HTTP na loopback) + o probe do
		# compose amarrado à porta que o servidor binda. Awaited: conversa de verdade
		# com o _process do serviço entre frames.
		await suites.SuiteMetrics()

		# SOM-IDLE M3: as três listas de preço (anúncio do servidor, catálogo do gateway
		# e fallback do companion) têm que bater SKU a SKU e centavo a centavo — pass.s1
		# estava cobrável e não anunciado, e o botão do passe virava unknown_sku.
		suites.SuiteCatalogConsistency(sql)

		# S1: identidade do chamador vem do transporte. Varre o facade por source
		# guard — não precisa de DB, então fica junto do SuiteDeployMode.
		suites.SuiteRpcIdentity(_getAutoload("Network"))

		# §7.4 deterministic live farm sim (zone 1) — after the DB suites so the
		# fixture character is already leveled by the settle
		await suites.SuiteIdlePolicySim(suites.lastCharID)
		# Agent lifecycle: the instance list is the authority, not the tree, and an
		# empty instance closes by identity. Both regressions are use-after-free in
		# teardown, so they run right after the sim that exercises the same path.
		await suites.SuiteAgentLifecycle(sql)
		# R1: chamada de autoload apontando para função que não existe só explode em
		# runtime no client — o runner é server-only, então a varredura é o exame.
		suites.SuiteAutoloadSurface()
		# SOM-IDLE beta: mesma varredura para os campos de serviço do Launcher
		# (tipados na base — nada no compilador checa `Launcher.SQL.<método>`).
		suites.SuiteServiceSurface()
		# SOM-IDLE: D1 pacing (harness fast; real-time probe ~5min, binding gate)
		suites.SuiteFaucetHarness(sql)
		await suites.SuiteOnboarding(sql)
		await suites.SuiteBossLadder(sql, economy)
		# SOM-IDLE: arena do interrupt AO VIVO (drena o _consumeBossInterrupt real
		# contra um mob da instância; mesmo harness de agente do ladder)
		await suites.SuiteBossInterruptLive(sql, economy)
		# SOM-IDLE beta: jornada de painéis. Por último — EnsureCharacterHub
		# absorve status/skills/progresso/formação no TabContainer do hub e
		# reorganiza o GUI ao vivo; nada depois dela depende dos painéis originais.
		suites.SuiteGuiPanels()
		# Hotkeys depois do hub: F2/F4/F5 agora apontam para o TabContainer que
		# SuiteGuiPanels montou, e a suíte aperta as teclas de verdade no `_input`
		# do serviço — nada nesta casa provava que um atalho anunciado abria algo.
		suites.SuiteInputHotkeys()
		# Ponteiros de evidência por último: não toca estado nenhum, só relê a
		# documentação do beta contra a árvore atual.
		suites.SuiteEvidencePointers()
		# Depois da régua de ponteiros, no mesmo espírito: leitura da árvore, nenhum
		# estado tocado. Varre `sources/` procurando navegação externa sem o ramo Web.
		suites.SuiteExternalLinksWebBranch()
		# Vitrine por último: é a única suíte que mexe em `season` depois da régua
		# de ponteiros, e fecha toda temporada ativa ao sair — nada herda o estado.
		suites.SuiteStorefrontHonesty(sql)
	else:
		print("FATAL: DB not initialized — DB-backed suites skipped")

	print("== RESULT: %d checks, %d failures ==" % [suites.checks, suites.failures])
	quit(suites.failures if suites.failures > 0 else 0)
