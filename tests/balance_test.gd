extends SceneTree

# SOM-IDLE: harness autônomo dos três fixes de game-design/retenção do
# AUDITORIA_2026-09-27 (§4/§6). A régua do fix 1 NÃO é snapshot de um level: é
# uma varredura de nível com invariante — "jogar nunca paga menos por hora que
# esperar" para XP e para gold, em todo nível varrido — que FAILA sozinha se a
# inversão newbie voltar (gold offline ×5) ou se o gate de nível regredir.
# Fix 2: enumeração em runtime do Modifier (peso > 0 para todo membro) + recusa
# comportamental de forja acima do budget pela função real.
# Fix 3: streak diário server-side (dia = ShopDay do relógio do servidor,
# mesmo divisor UTC dos resets), cap F2P entregando as 8h documentadas e a
# disciplina de ledger intacta (todo grant com reason "login_streak").
#
# Mesmo contrato dos harnesses descobertos por `scripts/test.sh`: o script `-s`
# compila ANTES dos autoloads; classes do projeto entram por load() depois do
# boot; DB.gd dreina os preloads antes de quit (senão o exit SIGSEGVa); a régua
# do gate é a última linha `== RESULT: N checks, M failures ==` e o exit code.

var checks : int = 0
var failures : int = 0

func _initialize():
	_run()

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

# ------------------------------------------------------------------ contagem

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(value : int, expected : int, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: %d vs %d" % [label, value, expected])
		return false
	return true

func _checkNear(value : float, expected : float, tolerance : float, label : String) -> bool:
	checks += 1
	if absf(value - expected) > tolerance:
		failures += 1
		print("  [FAIL] %s: %f vs %f (±%f)" % [label, value, expected, tolerance])
		return false
	return true

# ------------------------------------------------------------------ boot

var _launcher : Node = null
var _sql : Node = null
var _economy : Node = null
var _dbScript : GDScript = null
var _offline : GDScript = null
var _farmZone : GDScript = null
var _cellCommons : GDScript = null
var _craft : GDScript = null
var _catalog : GDScript = null
var _streak : GDScript = null
var _networkCommons : GDScript = null
var _actorCommons : GDScript = null
var _skillCommons : GDScript = null
var _sqlCommons : GDScript = null

# Timestamp sem nenhuma janela do calendário de live ops (2024-01-01T00:00Z; a
# única campanha declarada abre em 2026). Pinar o relógio aqui é o que
# transforma a varredura em invariante reproduzível, não fotografia do dia.
const DEAD_TS : int = 1704067200

func _run():
	print("== balance harness (newbie invariant + craft ceiling + return triggers) ==")
	_launcher = _autoload("Launcher")
	if _launcher == null:
		print("FATAL: Launcher autoload missing")
		_finish()
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.SQL
		_economy = _launcher.Economy
		if _sql != null and _sql.isInitialized and _economy != null:
			break
	print("== boot wait done (waited %d ms) ==" % waited)
	_dbScript = load("res://sources/db/DB.gd")
	_offline = load("res://sources/idle/OfflineSettle.gd")
	_farmZone = load("res://sources/idle/FarmZoneData.gd")
	_cellCommons = load("res://sources/cell/CellCommons.gd")
	_craft = load("res://sources/economy/CraftCatalog.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	_streak = load("res://sources/idle/StreakService.gd")
	_networkCommons = load("res://sources/network/NetworkCommons.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	_skillCommons = load("res://sources/skill/SkillCommons.gd")
	_sqlCommons = load("res://sources/sql/SQLCommons.gd")
	var dbReady : bool = false
	for i in 40:
		if bool(_dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (items/maps preloaded)"):
		_finish()
		return

	_suiteSchemaAndHook()
	_suiteNewbieInvariant()
	_suiteCraftCeiling()
	_suiteCapDocumented()
	_suiteStreak()
	_suiteLadderCurves()
	_suiteNewZoneFaucet()

	_finish()

func _finish():
	# O drain ANTES do quit: Preload() dispara ~333 loads em threads; sem
	# juntá-las o Launcher._exit_tree estoura SIGSEGV no fim do processo.
	if _dbScript != null:
		_dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ fixture

func _createFixture(accountName : String, nickname : String, gp : int = 10000) -> int:
	_sql.db.delete_rows("character", "nickname = '%s';" % nickname)
	_sql.db.delete_rows("account", "username = '%s';" % accountName)
	if not _sql.AddAccount(accountName, "testpass", accountName + "@test.local", _networkCommons.AgreementTosVersion, _networkCommons.AgreementPrivacyVersion, "203.0.113.1"):
		return 0
	var accountID : int = _sql.GetAccountID(accountName)
	if accountID < 0:
		return 0
	if not _sql.AddCharacter(accountID, nickname, _actorCommons.DefaultStats, _actorCommons.DefaultTraits, _actorCommons.DefaultAttributes):
		return 0
	var charID : int = _sql.GetCharacterID(accountID, nickname)
	if charID < 0:
		return 0
	_sql.SetSkill(charID, _skillCommons.SkillMeleeName.hash(), 1)
	_sql.db.update_rows("stat", "char_id = %d" % charID, {"gp" = gp})
	return charID

func _dropFixture(accountName : String, nickname : String):
	_sql.db.delete_rows("character", "nickname = '%s'" % nickname)
	_sql.db.delete_rows("account", "username = '%s'" % accountName)

func _setLevel(charID : int, level : int):
	_sql.db.update_rows("stat", "char_id = %d" % charID, {"level" = level, "experience" = 0})

func _gpOf(charID : int) -> int:
	var rows : Array = _sql.db.select_rows("stat", "char_id = %d" % charID, ["gp"])
	return int(rows[0]["gp"]) if not rows.is_empty() and rows[0].get("gp", null) != null else 0

func _ledgerRows(charID : int, reason : String) -> Array[Dictionary]:
	return _sql.QueryBindings("SELECT amount, balance_after FROM ledger_transaction WHERE char_id = ? AND reason = ?;", [charID, reason])

# ------------------------------------------------------------------ suite 0: schema + hook

func _suiteSchemaAndHook():
	print("[suite] 0: tabela do streak aplicada pela migration 058 + hook no funil de login")
	var cols : Array[Dictionary] = _sql.Query("PRAGMA table_info(login_streak);")
	_checkEq(cols.size(), 5, "login_streak existe com 5 colunas no banco do boot (migration 058 aplicada; 0 = schema faltando)")
	var names : Array[String] = []
	for c in cols:
		names.append(str(c["name"]))
	for wanted : String in ["char_id", "current_streak", "best_streak", "last_day", "updated_at"]:
		_check(wanted in names, "coluna %s presente na login_streak" % wanted)
	var migText : String = FileAccess.get_file_as_string("res://data/conf/migrations/058_login_streak.sql")
	_check(migText.contains("CREATE TABLE IF NOT EXISTS login_streak"), "migration 058 é idempotente (re-aplicar não rasga estado)")
	var policySrc : String = FileAccess.get_file_as_string("res://sources/idle/IdlePolicyService.gd")
	_check(policySrc.contains("StreakService.RecordLogin("), "o funil de login server-side (AutoFarmOnLogin) carimba o streak — sem esta linha não há gatilho de retorno")
	var svcSrc : String = FileAccess.get_file_as_string("res://sources/idle/StreakService.gd")
	var sig : String = ""
	for line in svcSrc.split("\n"):
		if String(line).begins_with("static func RecordLogin"):
			sig = String(line)
			break
	_check(sig.contains("charID : int") and sig.contains("accountID : int") and not sig.contains("day :") and not sig.contains("date"),
		"RecordLogin não recebe data nenhuma do chamador — o dia sai do relógio do servidor (ShopDay(_now()))")

# ------------------------------------------------------------------ suite 1: invariante newbie

# Online-por-hora = a aritmética de Formula.ApplyXp no par projetado da zona
# (damageRatio 1.0, sem favor/tormento — os multiplicadores que existem dos
# dois lados cancelam no baseline F2P; par é por definição a kills/h do farm
# ativo, FarmZoneData.ParBaseSeconds). Offline-por-hora = o BuildReport REAL
# (mesma função que liquida). Se o ×5 voltar ao gold offline (inversão P1-3),
# o eixo gold quebra em todo nível < 10; se o gate regredir (a leitura velha
# caía no fallback 1 porque `character` não tem coluna `level`), o eixo XP
# quebra em todo nível ≥ 10.
func _suiteNewbieInvariant():
	print("[suite] 1: jogar nunca paga menos por hora que esperar (XP e gold, 1..40)")
	var charID : int = _createFixture("bal_newbie_account", "BalNewbieChar")
	if not _check(charID != 0, "fixture newbie criada"):
		return
	_sql.SetCharacterFarmZone(charID, 1)
	var zone = _farmZone.GetZone(1)
	var par : float = float(zone.parKillsPerHour)
	var nbFactor : int = int(_farmZone.NewbieBoostFactor)
	var nbMax : int = int(_farmZone.NewbieBoostMaxLevel)
	var offlineByLevel : Dictionary = {}
	for level : int in [1, 2, 9, 10, 11, 20, 40]:
		_setLevel(charID, level)
		_sql.UpdateSettleAnchor(charID, DEAD_TS - 3600, 1.0)
		_offline.nowOverride = DEAD_TS
		var report = _offline.BuildReport(charID, DEAD_TS)
		_offline.nowOverride = 0
		if not _check(report != null and report.hours > 0.99 and report.hours < 1.01, "nível %d: BuildReport liquida a janela de 1h (hours=%s)" % [level, str(report.hours)]):
			continue
		offlineByLevel[level] = {"xp" = int(report.xpEarned), "gold" = int(report.goldEarned)}
		var onlineXpPerHr : float = float(zone.xpPerKill * (nbFactor if level < nbMax else 1)) * par
		var onlineGoldPerHr : float = float(zone.goldPerKill) * par
		_check(onlineXpPerHr >= float(report.xpEarned) - 0.5,
			"nível %d: XP online/hora %d >= offline/hora %d" % [level, int(onlineXpPerHr), int(report.xpEarned)])
		_check(onlineGoldPerHr >= float(report.goldEarned) - 0.5,
			"nível %d: gold online/hora %d >= offline/hora %d (a inversão P1-3 está viva se este falhar)" % [level, int(onlineGoldPerHr), int(report.goldEarned)])
	if offlineByLevel.has(1) and offlineByLevel.has(10):
		var xpRatio : float = float(offlineByLevel[1]["xp"]) / maxf(1.0, float(offlineByLevel[10]["xp"]))
		var goldRatio : float = float(offlineByLevel[1]["gold"]) / maxf(1.0, float(offlineByLevel[10]["gold"]))
		_checkNear(xpRatio, float(nbFactor), 0.05, "XP offline carrega o ×%d do boost até o gate (razão L1/L10 medida)" % nbFactor)
		_checkNear(goldRatio, 1.0, 0.05, "gold offline NÃO carrega o boost — simetria com o online (razão L1/L10 medida)")
	if offlineByLevel.has(20) and offlineByLevel.has(40):
		_checkEq(int(offlineByLevel[20]["xp"]), int(offlineByLevel[40]["xp"]), "XP offline L20 == L40 (boost desligado acima do gate — leitura em stat.level)")
		_checkEq(int(offlineByLevel[20]["gold"]), int(offlineByLevel[40]["gold"]), "gold offline L20 == L40")
	# Trava textual das linhas que carregam o fix (a varredura é a régua; isto é
	# o alarme cedo se alguém reescrever a fórmula fora do eixo testado).
	var formulaSrc : String = FileAccess.get_file_as_string("res://sources/actor/stat/Formula.gd")
	var boostLines : int = 0
	for line in formulaSrc.split("\n"):
		var l : String = String(line)
		if l.contains("NewbieBoostFactor"):
			boostLines += 1
			_check(l.contains("zoneXp"), "fórmula online: boost só toca zoneXp — linha: %s" % l.strip_edges())
		elif l.contains("zoneGold") and l.contains("Newbie"):
			_check(false, "fórmula online: boost vazou para o gold na linha %s" % l.strip_edges())
	_check(boostLines > 0, "a fórmula online ainda declara o boost de XP (linhas lidas: %d)" % boostLines)
	var settleSrc : String = FileAccess.get_file_as_string("res://sources/idle/OfflineSettle.gd")
	for line in settleSrc.split("\n"):
		var l : String = String(line)
		if l.contains("report.goldEarned =") and l.contains("newbieMult"):
			_check(false, "settle: goldEarned voltou a multiplicar newbieMult — a inversão P1-3 regressou")
		elif l.begins_with("\treport.xpEarned =") and not l.contains("newbieMult"):
			_check(false, "settle: xpEarned perdeu o newbieMult (o boost de XP tem que ser simétrico com o online)")
	_dropFixture("bal_newbie_account", "BalNewbieChar")

# ------------------------------------------------------------------ suite 2: teto do craft

func _suiteCraftCeiling():
	print("[suite] 2: todo Modifier do enum pesa no budget + forja acima do budget recusada")
	var modifierEnum : Dictionary = _cellCommons.Modifier
	var count : int = int(modifierEnum["Count"])
	var table : Array = _craft.MOD_WEIGHTS
	_checkEq(table.size(), count, "MOD_WEIGHTS cobre o enum inteiro (Count = %d)" % count)
	var zero : Array[String] = []
	for key in modifierEnum.keys():
		var name : String = String(key)
		if name == "None" or name == "Count":
			continue
		var idx : int = int(modifierEnum[key])
		if idx >= table.size() or float(table[idx]) <= 0.0:
			zero.append(name)
	_checkEq(zero.size(), 0, "todo membro 1..Count-1 tem peso > 0 (zerados: %s)" % str(zero))
	# Os citados na auditoria, um a um — a tabela velha parava em 22 e eles
	# caíam no `else 0.0` do lookup do ItemForgeService.
	for wanted : String in ["FireDamage", "BurnChance", "BurnPower", "PoisonChance", "PoisonPower", "BleedChance", "BleedPower", "Penetration", "DeadlyChance"]:
		var w : float = float(table[int(modifierEnum[wanted])]) if modifierEnum.has(wanted) else -1.0
		_check(w > 0.0, "modifier da auditoria %s tem peso real no budget (%f)" % [wanted, w])
	_checkEq(_craft.ValidateModWeights().size(), 0, "validação fail-closed do boot limpa na tabela corrente")
	# Comportamental pela FUNÇÃO REAL: acima do budget é recusado; com peso 0 o
	# mesmo rolo daria passagem livre (era o buraco).
	var charID : int = _createFixture("bal_craft_account", "BalCraftChar")
	if not _check(charID != 0, "fixture craft criada"):
		return
	var accountID : int = _sql.GetAccountIDForCharacter(charID)
	var slot : int = int(_actorCommons.Slot.WEAPON)
	var baseHash : int = 0
	var baseTier : int = 1
	for tier : int in [1, 3, 4, 5]:
		for itemHash in _dbScript.ItemsDB.keys():
			var item = _dbScript.ItemsDB[itemHash]
			if item != null and item.slot == slot and item.tier == tier and int(itemHash) > 0:
				baseHash = int(itemHash)
				baseTier = tier
				break
		if baseHash != 0:
			break
	_check(baseHash != 0, "base weapon craftável encontrada no ItemsDB")
	if baseHash == 0:
		_dropFixture("bal_craft_account", "BalCraftChar")
		return
	var cap : int = int(_craft.BudgetCap(baseTier, slot))
	_check(cap > 0, "a faixa (tier %d, slot weapon) tem budget cap %d" % [baseTier, cap])
	var res : Dictionary = _economy.SubmitCraft(charID, accountID, slot, baseHash, "Bal Firefang", {"FireDamage": 99999})
	_check(not bool(res.get("ok", false)), "FireDamage 99999 não passa na forja")
	_check(str(res.get("reason", "")) == "budget_exceeded", "motivo da recusa é budget_exceeded (peso 0 daria passagem livre)")
	var res2 : Dictionary = _economy.SubmitCraft(charID, accountID, slot, baseHash, "Bal Deathfang", {"DeadlyChance": maxi(2, cap + 1)})
	_check(str(res2.get("reason", "")) == "budget_exceeded", "DeadlyChance acima do cap estoura o budget (era peso 0 → livre)")
	var res3 : Dictionary = _economy.SubmitCraft(charID, accountID, slot, baseHash, "Bal Tinyfang", {"PoisonPower": 1})
	_check(str(res3.get("reason", "")) != "budget_exceeded", "rolo dentro do budget não é barrado no budget (cap da faixa = %d)" % cap)
	_dropFixture("bal_craft_account", "BalCraftChar")

# ------------------------------------------------------------------ suite 3a: cap documentado

# §6: o cap F2P documentado é 8h (comentário de BaseCapHours — banda de
# retenção da categoria; o cap HISTÓRICO da economia era 12h, régua com que o
# teto diário de baús foi calibrado). A suíte mede o cap entregue, não o
# prometido, e confere que o piso novo não afrouxa nenhum cap próprio.
func _suiteCapDocumented():
	print("[suite] 3a: o teto F2P liquida as horas documentadas (8h) sem afrouxar caps")
	_checkNear(float(_offline.BaseCapHours), 8.0, 0.001, "BaseCapHours documentado = 8h (banda de tolerância do gênero; cap histórico era 12h)")
	var now : int = _sqlCommons.Timestamp()
	_checkNear(float(_offline.CapHoursForAccount(0, now)), 8.0, 0.001, "sem conta → teto base de 8h")
	var charID : int = _createFixture("bal_cap_account", "BalCapChar")
	if not _check(charID != 0, "fixture cap criada"):
		return
	var accountID : int = _sql.GetAccountIDForCharacter(charID)
	_sql.SetCharacterFarmZone(charID, 1)
	_checkNear(float(_offline.CapHoursForAccount(accountID, now)), 8.0, 0.001, "F2P sem VIP → 8h (cap por conta)")
	# Janela de 30h com cap de 8h: entrega exatamente 8h. O nowOverride pinado
	# em DEAD_TS zera multiplicadores de calendário — o número medido abaixo é
	# o do baseline F2P, não o de uma janela promocional do dia.
	_sql.UpdateSettleAnchor(charID, now - 30 * 3600, 1.0)
	_offline.nowOverride = DEAD_TS
	var report = _offline.BuildReport(charID, now)
	_offline.nowOverride = 0
	_checkNear(float(report.hours), 8.0, 0.001, "30h de janela liquidam as 8h do teto (cap entregue = cap declarado)")
	_checkEq(int(report.goldEarned), 108000, "medida: ouro de UMA liquidação F2P z1 no cap = 150 gp/kill × 150 par × 8h × 0,6")
	_checkEq(int(report.xpEarned), 4320000, "medida: XP da mesma liquidação (newbie ×5 no eixo de XP)")
	_checkEq(int(report.chests), 2, "8h de cap pagam floor(8/4) = 2 baús")
	_checkEq(int(report.bossKeysEarned), 1, "1 chave na liquidação cheia (720 kills-equivalentes × 2000 ppm)")
	_check(int(report.chests) <= int(_catalog.ChestsPerDayFromSettle), "baús do settle continuam sob o teto diário de %d" % int(_catalog.ChestsPerDayFromSettle))
	# VIP não é engolido pelo novo piso: 24h seguem acima, expirado volta ao base.
	_sql.SetVIPUntil(accountID, now + 30 * 86400)
	_sql.SetVIPTier(accountID, 2)
	_checkNear(float(_offline.CapHoursForAccount(accountID, now)), 24.0, 0.001, "VIP2 → 24h (o degrau pago continua comprável)")
	_sql.SetVIPUntil(accountID, now - 10)
	_checkNear(float(_offline.CapHoursForAccount(accountID, now)), 8.0, 0.001, "VIP expirado → volta ao piso de 8h")
	# Faucet do streak vs. faucet do cap: um ciclo inteiro da escada tem que ser
	# fração pequena de UMA liquidação — o gatilho de retorno não infla a moeda.
	var cycle : int = int(_streak.LadderCycleTotal())
	_check(cycle > 0, "escada declarada com ciclo positivo (%d ouro/semana)" % cycle)
	_check(cycle * 10 <= int(report.goldEarned), "ciclo semanal do streak (%d) <= 10%% de uma liquidação F2P no cap (%d)" % [cycle, int(report.goldEarned)])
	for s : int in range(1, 15):
		_check(int(_streak.LadderReward(s)) <= 1000, "degrau %d limitado ao teto da escada (1000)" % s)
	_dropFixture("bal_cap_account", "BalCapChar")

# ------------------------------------------------------------------ suite 3b: streak

func _suiteStreak():
	print("[suite] 3b: streak diário — dia do servidor, escada limitada, tudo pelo ledger")
	var charID : int = _createFixture("bal_streak_account", "BalStreakChar", 10000)
	if not _check(charID != 0, "fixture streak criada"):
		return
	var accountID : int = _sql.GetAccountIDForCharacter(charID)
	_streak.sqlOverride = _sql
	_streak.economyOverride = _economy
	var granted : int = 0
	var logins : int = 0
	var daySpan : int = 86400
	var ts : int = DEAD_TS
	_streak.nowOverride = ts
	var first : Dictionary = _streak.RecordLogin(charID, accountID)
	_check(bool(first.get("ok", false)) and int(first.get("streak", 0)) == 1, "dia 1 → streak 1")
	_checkEq(int(first.get("reward", 0)), 100, "dia 1 paga o degrau 100")
	granted += int(first.get("reward", 0))
	logins += 1
	var dup : Dictionary = _streak.RecordLogin(charID, accountID)
	_check(str(dup.get("reason", "")) == "same_day" and int(dup.get("reward", -1)) == 0, "reentrada no MESMO dia não concede (idempotência por ShopDay do servidor)")
	_checkEq(_gpOf(charID), 10000 + granted, "wallet = fixture + degrau pago")
	for day : int in range(2, 11):
		ts += daySpan
		_streak.nowOverride = ts
		var r : Dictionary = _streak.RecordLogin(charID, accountID)
		if not _check(bool(r.get("ok", false)), "login do dia %d registrado" % day):
			continue
		_checkEq(int(r.get("streak", 0)), day, "contagem consecutiva no dia %d" % day)
		_checkEq(int(r.get("reward", -1)), int(_streak.LadderReward(day)), "degrau do dia %d == escada((d-1) %% 7)" % day)
		granted += int(r.get("reward", 0))
		logins += 1
	# Gap → sequência zera para 1 (a melhor marca fica).
	_streak.nowOverride = ts + 3 * daySpan
	var afterGap : Dictionary = _streak.RecordLogin(charID, accountID)
	_checkEq(int(afterGap.get("streak", -1)), 1, "dia pulado zera a sequência (volta ao degrau 1)")
	granted += int(afterGap.get("reward", 0))
	logins += 1
	var peek : Dictionary = _streak.PeekStreak(charID)
	_checkEq(int(peek.get("best_streak", 0)), 10, "best_streak preserva a maior sequência (10)")
	# Fronteira UTC: duas chamadas a ±1 s do divisor ShopDay+offset são dias
	# DIFERENTES (e o dia vira às 06:00 UTC — o mesmo reset da loja/passe).
	var dayStart : int = int(_catalog.ShopDay(ts + 3 * daySpan)) * 86400 + int(_catalog.SHOP_DAY_UTC_OFFSET)
	_streak.nowOverride = dayStart - 1
	var beforeEdge : Dictionary = _streak.RecordLogin(charID, accountID)
	_streak.nowOverride = dayStart + 1
	var afterEdge : Dictionary = _streak.RecordLogin(charID, accountID)
	_check(str(beforeEdge.get("reason", "")) == "logged" and str(afterEdge.get("reason", "")) == "logged",
		"virada UTC do relógio do servidor carimba dia novo (±1 s em torno do divisor ShopDay)")
	granted += int(beforeEdge.get("reward", 0)) + int(afterEdge.get("reward", 0))
	logins += 2
	# Disciplina de ledger (§7.3): UMA linha "login_streak" por concessão e a
	# soma da moeda concedida fecha com a wallet — nenhum grant por fora.
	var rows : Array[Dictionary] = _ledgerRows(charID, "login_streak")
	_checkEq(rows.size(), logins, "uma linha de ledger por login que concedeu (%d)" % logins)
	var ledgerSum : int = 0
	var lastBalance : int = 0
	for r in rows:
		ledgerSum += int(r["amount"])
		lastBalance = maxi(lastBalance, int(r["balance_after"]))
	_checkEq(ledgerSum, granted, "ledger login_streak == ouro creditado na wallet (%d)" % granted)
	_check(_gpOf(charID) == 10000 + granted, "conservação: wallet fechou com fixture + escada (sem mutação nua)")
	_check(lastBalance <= _gpOf(charID) + 1, "balance_after do ledger acompanha a wallet (nunca adiante dela)")
	# Seams de volta ao neutro para não vazar para outras suítes do processo.
	_streak.nowOverride = 0
	_streak.sqlOverride = null
	_streak.economyOverride = null
	_dropFixture("bal_streak_account", "BalStreakChar")

# ------------------------------------------------------------------ suite 4: curvas da escada

# JUÍZ 2026-09-27: "depois das 24 zonas e dos 4 bosses, só boss-rush e tormento
# sobre o mesmo roster de ~24 espécies". A escada cresceu para 27 zonas / 9 tiers
# e conteúdo novo que não tem preço não é conteúdo: é decoração. Estas duas
# suítes cobrem exatamente isso — (4) a curva fechada de CADA zona da escada
# inteira, monotônica e map-backed, e (5) o faucet/sink das zonas novas medido no
# BuildReport REAL mais a curva de drop liquidada pelo mesmo caminho.
#
# Formas fechadas (FarmZoneData._make): tier = clamp(ceil(z/3),1,9);
# minPower = 24+8(z-1); xp = round(1200*1,25^(z-1)); gold = round(xp/8);
# par = round(3600/(24+0,9(z-1))); gold/h = par*gold.

func _expectedXpPerKill(zoneID : int) -> int:
	return roundi(float(_farmZone.XpBasePerKill) * pow(float(_farmZone.XpGrowthPerZone), float(zoneID - 1)))

func _expectedPar(zoneID : int) -> int:
	return roundi(3600.0 / (float(_farmZone.ParBaseSeconds) + float(_farmZone.ParPerZoneSeconds) * float(zoneID - 1)))

# Razão liquidada entre duas zonas com o par descontado: o que sobra tem de ser
# exatamente 1,25^(zonas de distância) — e 1,25 é a CONSTANTE da curva, não um
# número escolhido por zona. É a régua de que a perna nova é preço, não
# decoração: zona nova com curva à parte (mais generosa, mais mesquinha) quebra.
func _growthRatio(measured : Dictionary[int, int], zoneA : int, zoneB : int, steps : int) -> void:
	if not measured.has(zoneA) or not measured.has(zoneB):
		_check(false, "zona %d/%d liquidada na régua de crescimento (medida ausente do settle)" % [zoneA, zoneB])
		return
	var ratio : float = (float(measured[zoneA]) / float(measured[zoneB])) / (float(_expectedPar(zoneA)) / float(_expectedPar(zoneB)))
	_checkNear(ratio, pow(float(_farmZone.XpGrowthPerZone), float(steps)), 0.01,
		"zona %d/%d: liquidado segue 1,25^%d com o par descontado" % [zoneA, zoneB, steps])

func _suiteLadderCurves():
	print("[suite] 4: curvas fechadas de toda a escada (monotônicas, map-backed, tier fechado)")
	_farmZone.SyncWithDB()
	var zoneCount : int = int(_farmZone.ZONE_COUNT)
	var perTier : int = int(_farmZone.ZonesPerTier)
	var maxTier : int = int(_farmZone.MAX_TIER)
	_checkEq(int(_farmZone.GetZoneCount()), zoneCount, "catálogo construído com ZONE_COUNT zonas")
	_checkEq(int(_farmZone.MapBackedNames.size()), zoneCount, "toda zona tem mapa no catálogo (zero placeholder 'unmapped')")
	_checkEq(maxTier, int(ceilf(float(zoneCount) / float(perTier))), "MAX_TIER fecha a escada (%d zonas / %d por tier)" % [zoneCount, perTier])
	_check(zoneCount >= 27, "a perna nova existe: escada >= 27 zonas (medido %d)" % zoneCount)
	_check(_farmZone.GetZone(zoneCount + 1) == null, "GetZone(de fora da escada) devolve null (sem zona fantasma)")
	_check(float(_farmZone.FarmRespawnMinSeconds) <= float(_farmZone.FarmRespawnBaseSeconds), "banda de respawn declarada (min <= base)")
	var tierHits : Dictionary = {}
	var mapNames : Dictionary = {}
	var prevXp : int = 0
	var prevPar : int = 0
	var prevGoldHr : int = 0
	var prevMinPower : int = 0
	var prevRespawn : float = 0.0
	for z in range(1, zoneCount + 1):
		var zone = _farmZone.GetZone(z)
		if not _check(zone != null, "zona %d existe no catálogo" % z):
			continue
		var tier : int = int(zone.tier)
		_checkEq(tier, clampi(ceili(float(z) / float(perTier)), 1, maxTier), "zona %d: tier = clamp(ceil(z/%d),1,%d)" % [z, perTier, maxTier])
		tierHits[tier] = int(tierHits.get(tier, 0)) + 1
		_checkEq(int(zone.minPower), int(_farmZone.MinPowerBase) + int(_farmZone.MinPowerPerZone) * (z - 1), "zona %d: minPower = 24+8(z-1)" % z)
		_checkEq(int(zone.xpPerKill), _expectedXpPerKill(z), "zona %d: xpPerKill = round(1200*1,25^(z-1))" % z)
		_checkEq(int(zone.goldPerKill), roundi(float(zone.xpPerKill) / float(_farmZone.GoldPerKillDiv)), "zona %d: goldPerKill = xp/8 (sink amarrado ao faucet)" % z)
		_checkEq(int(zone.parKillsPerHour), _expectedPar(z), "zona %d: par = round(3600/(24+0,9(z-1)))" % z)
		_checkEq(int(zone.goldPerHour), int(zone.parKillsPerHour) * int(zone.goldPerKill), "zona %d: gold/hora = par × gold/kill" % z)
		_check(not str(zone.mapName).is_empty(), "zona %d tem nome de mapa" % z)
		_check(not mapNames.has(str(zone.mapName)), "zona %d: mapa '%s' não se repete na escada (roster novo, não o mesmo de antes)" % [z, str(zone.mapName)])
		mapNames[str(zone.mapName)] = true
		_check(int(zone.mapID) != int(_dbScript.UnknownHash), "zona %d (%s) resolve para mapa real do MapsDB" % [z, str(zone.mapName)])
		_checkEq(int(_farmZone.GetFarmSpawnMultiplier(z)), int(_farmZone.FarmSpawnBaseMultiplier) + tier, "zona %d: multiplicador de spawn = 2 + tier" % z)
		var respawn : float = float(_farmZone.GetFarmRespawnDelay(z))
		_check(respawn >= float(_farmZone.FarmRespawnMinSeconds) - 0.001 and respawn <= float(_farmZone.FarmRespawnBaseSeconds) + 0.001,
			"zona %d: respawn na banda [%.0f, %.0f] (medido %.1f)" % [z, float(_farmZone.FarmRespawnMinSeconds), float(_farmZone.FarmRespawnBaseSeconds), respawn])
		if z > 1:
			_check(int(zone.xpPerKill) > prevXp, "zona %d: xp/kill estritamente crescente (%d > %d)" % [z, int(zone.xpPerKill), prevXp])
			_check(int(zone.parKillsPerHour) < prevPar, "zona %d: par/h estritamente decrescente (%d < %d)" % [z, int(zone.parKillsPerHour), prevPar])
			_check(int(zone.goldPerHour) > prevGoldHr, "zona %d: gold/hora crescente (fundo não paga menos que a entrada)" % z)
			_check(int(zone.minPower) > prevMinPower, "zona %d: gate de power crescente" % z)
			_check(respawn <= prevRespawn + 0.001, "zona %d: respawn não afrouxa com a profundidade" % z)
		prevXp = int(zone.xpPerKill)
		prevPar = int(zone.parKillsPerHour)
		prevGoldHr = int(zone.goldPerHour)
		prevMinPower = int(zone.minPower)
		prevRespawn = respawn
	for t in range(1, maxTier + 1):
		_checkEq(int(tierHits.get(t, 0)), perTier, "tier %d tem exatamente %d zonas (fim de jogo em %d tiers, não %d)" % [t, perTier, maxTier, maxTier - 1])
	# A perna nova: as 3 últimas zonas são o tier fundo, e as faixas de drop delas
	# têm conteúdo (a raiz do "band nasce vazia" apareceria aqui como pool vazia).
	for dz in range(zoneCount - perTier + 1, zoneCount + 1):
		var deep = _farmZone.GetZone(dz)
		if deep == null:
			continue
		_checkEq(int(deep.tier), maxTier, "zona %d: perna nova no tier fundo (%d)" % [dz, maxTier])
		_check(not _farmZone.GetDropPool(dz).is_empty(), "zona %d (tier %d): pool de drop não vazia (sem fallback)" % [dz, maxTier])

# ------------------------------------------------------------------ suite 5: faucet das zonas novas

# Mesma função que liquida de verdade (OfflineSettle.BuildReport), char nível 20
# (acima do gate newbie, então o ×5 não contamina a leitura da curva), relógio
# pinado em DEAD_TS (nenhuma janela de live ops no ar). O que se assere aqui é a
# IDENTIDADE entre o número liquidado e a curva da zona — se a zona nova for
# decorativa (curva à parte, gold fora do xp/8, loot fora da faixa), quebra.
func _suiteNewZoneFaucet():
	print("[suite] 5: a perna nova é liquidada pelo settle real (faucet/sink + curva de drop)")
	var charID : int = _createFixture("bal_ladder_account", "BalLadderChar")
	if not _check(charID != 0, "fixture da escada criada"):
		return
	_setLevel(charID, 20)
	_farmZone.SyncWithDB()
	var ladderZones : Array[int] = [1, 24, 25, 26, 27]
	var measuredXp : Array[int] = []
	var measuredGold : Array[int] = []
	var byZoneXp : Dictionary[int, int] = {}
	var byZoneGold : Dictionary[int, int] = {}
	var off : float = float(_offline.OfflineFactor)
	for z : int in ladderZones:
		var zone = _farmZone.GetZone(z)
		if not _check(zone != null, "zona %d existe para o settle" % z):
			continue
		_sql.SetCharacterFarmZone(charID, z)
		_sql.UpdateSettleAnchor(charID, DEAD_TS - 3600, 1.0)
		_offline.nowOverride = DEAD_TS
		var report = _offline.BuildReport(charID, DEAD_TS)
		_offline.nowOverride = 0
		if not _check(report != null and report.hours > 0.99 and report.hours < 1.01,
			"zona %d: BuildReport liquida a janela de 1h (hours=%s)" % [z, str(report.hours)]):
			continue
		_checkEq(int(report.zoneID), z, "zona %d: o settle liquidou a zona pedida" % z)
		var h : float = float(report.hours)
		var eff : float = float(report.efficiency)
		var mods : float = float(report.mods)
		var kills : float = float(zone.parKillsPerHour) * h * eff
		var expXp : int = roundi(float(zone.xpPerKill) * kills * off * mods)
		var expGold : int = roundi(float(zone.goldPerKill) * kills * off * mods)
		_checkEq(int(report.xpEarned), expXp, "zona %d: faucet liquidado == xp/kill × par × h × eff × 0,6 × mods" % z)
		_checkEq(int(report.goldEarned), expGold, "zona %d: sink liquidado == gold/kill (= xp/8) na mesma fórmula" % z)
		_checkNear(float(report.goldEarned) / maxf(1.0, float(report.xpEarned)), 0.125, 0.001,
			"zona %d: gold/xp liquidado = 1/8 (medido %d/%d)" % [z, int(report.goldEarned), int(report.xpEarned)])
		measuredXp.append(int(report.xpEarned))
		measuredGold.append(int(report.goldEarned))
		byZoneXp[z] = int(report.xpEarned)
		byZoneGold[z] = int(report.goldEarned)
	var steps : int = measuredXp.size()
	_checkEq(steps, ladderZones.size(), "as %d zonas da régua liquidaram (1, 24, 25, 26, 27)" % ladderZones.size())
	for i in range(1, steps):
		_check(measuredXp[i] > measuredXp[i - 1], "zona da régua %d: XP/h liquidado cresce com a profundidade (%d > %d)" % [i, measuredXp[i], measuredXp[i - 1]])
		_check(measuredGold[i] > measuredGold[i - 1], "zona da régua %d: gold/h liquidado cresce com a profundidade (%d > %d)" % [i, measuredGold[i], measuredGold[i - 1]])
	# A perna nova obedece à MESMA constante de crescimento (1,25 por zona) que as
	# velhas, descontado o par (que recua 0,9 s/kill zona a zona): zona nova não
	# imprime inflação nem fica atrás do ritmo da escada.
	_growthRatio(byZoneXp, 25, 24, 1)
	_growthRatio(byZoneXp, 26, 25, 1)
	_growthRatio(byZoneXp, 27, 26, 1)
	_growthRatio(byZoneXp, 27, 24, 3)
	_growthRatio(byZoneGold, 27, 25, 2)
	_growthRatio(byZoneGold, 27, 24, 3)
	# Curva de drop pelo MESMO caminho: 8h (o cap F2P) numa zona nova liquidam
	# drops de verdade e todo item cai na própria faixa de tier. Pool vazia ou
	# item fora da faixa é o fallback de conteúdo voltando a existir.
	var apple : int = int(_farmZone.DefaultDropItemHash)
	var craftSet : Dictionary = {}
	var rows : Array = _sql.QueryBindings("SELECT item_hash FROM craft_item_template;", [])
	for row in rows:
		craftSet[int(row.get("item_hash", 0))] = true
	for dz2 : int in [24, 25, 26, 27]:
		var zone8 = _farmZone.GetZone(dz2)
		if zone8 == null:
			continue
		_sql.SetCharacterFarmZone(charID, dz2)
		_sql.UpdateSettleAnchor(charID, DEAD_TS - 8 * 3600, 1.0)
		_offline.nowOverride = DEAD_TS
		var report8 = _offline.BuildReport(charID, DEAD_TS)
		_offline.nowOverride = 0
		if report8 == null:
			_check(false, "zona %d: settle de 8h devolve relatório" % dz2)
			continue
		_checkNear(float(report8.hours), 8.0, 0.001, "zona %d: 8h liquidados (cap F2P)" % dz2)
		var dropTotal : int = 0
		for dkey in report8.drops.keys():
			dropTotal += int(report8.drops[dkey])
		var expDrop : float = float(zone8.dropRatePPM) * float(report8.hours) * 3600.0 * float(report8.efficiency) * off / 1000000.0
		var expCount : int = floori(expDrop)
		if expDrop - float(expCount) >= 0.5:
			expCount += 1
		_checkEq(dropTotal, expCount, "zona %d: n. de drops liquidado == ppm x h x 3600 x eff x 0,6 / 1e6 (medido %d, formula %.3f)" % [dz2, dropTotal, expDrop])
		_check(dropTotal > 0, "zona %d: a liquidação entrega drop (%d itens em 8h)" % [dz2, dropTotal])
		var tierLo : int = int(zone8.tier)
		var tierHi : int = mini(tierLo + int(_farmZone.DropTierBandSize) - 1, int(_farmZone.MAX_TIER))
		for dkey2 in report8.drops.keys():
			var hsh : int = int(dkey2)
			if craftSet.has(hsh):
				continue
			var cell = _dbScript.ItemsDB.get(hsh, null)
			if not _check(cell != null, "zona %d: drop %d é item do catálogo (não um hash órfão)" % [dz2, hsh]):
				continue
			_check(int(cell.tier) >= tierLo and int(cell.tier) <= tierHi,
				"zona %d: drop '%s' tier %d dentro da faixa [%d,%d]" % [dz2, str(cell.name), int(cell.tier), tierLo, tierHi])
			_check(not (hsh == apple and tierLo > 1), "zona %d: loot não é o stand-in Apple do fallback deletado" % dz2)
	_dropFixture("bal_ladder_account", "BalLadderChar")
