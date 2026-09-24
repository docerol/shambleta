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
	# habilitam explicitamente aqui (o beta real nunca seta esta env).
	OS.set_environment("SHAMBLETA_ENABLE_SEASONS", "1")
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
				# Fase B: VIP cap 12/24/36h + loja diária/ofertas
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
			# Fase E: rewarded ads (tokens, caps, 4 placements, 2×/4×)
			suites.SuiteAds(sql)
			# Fase F: guild premium + AH premium + 4 corridas + torneios
			suites.SuiteGuildPremium(sql)
			suites.SuiteMarketplace(sql)
			suites.SuiteSeasonRaces(sql)
			suites.SuiteTournamentDonation(sql)
			suites.SuiteSeasonLock(sql)
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
		suites.SuiteLGPD(sql)
		suites.SuiteRefund(sql)
		suites.SuiteConcurrency(sql)
		suites.SuiteOpsA2(sql)

		# §7.4 deterministic live farm sim (zone 1) — after the DB suites so the
		# fixture character is already leveled by the settle
		await suites.SuiteIdlePolicySim(suites.lastCharID)
		# SOM-IDLE: D1 pacing (harness fast; real-time probe ~5min, binding gate)
		suites.SuiteFaucetHarness(sql)
		await suites.SuiteOnboarding(sql)
		await suites.SuiteBossLadder(sql, economy)
		# SOM-IDLE: arena do interrupt AO VIVO (drena o _consumeBossInterrupt real
		# contra um mob da instância; mesmo harness de agente do ladder)
		await suites.SuiteBossInterruptLive(sql, economy)
	else:
		print("FATAL: DB not initialized — DB-backed suites skipped")

	print("== RESULT: %d checks, %d failures ==" % [suites.checks, suites.failures])
	quit(suites.failures if suites.failures > 0 else 0)
