extends SceneTree

# gate-marker: == RESULT:

# season_race_delta_test.gd — o placar de temporada conta a JANELA, não a vida do
# personagem.
#
# Uso:  bash scripts/test.sh one season_race_delta_test 300
# Saída: "== RESULT: <n> checks, <m> failures =="  (exit code = <m>)
#
# Por que existe: a rodada 3 nomeou Meta Game 7,5 com um achado conferido antes de
# gravar — `power_score`, `bosses_beaten` e `guild.points` são contadores correntes
# sem histórico, então congelar o valor no fechamento congelava junto tudo o que o
# jogador fez ANTES da temporada, e o prêmio ia para quem chegou grande, não para
# quem subiu na janela. A única corrida certa era `spend`, porque nasce do
# `ledger_transaction` e já tinha teto em `ends_at`.
#
# O conserto é o marco zero da migration 064: no instante em que a temporada abre,
# o estado vigente é gravado na mesma transação do INSERT e subtraído no
# fechamento. Esta suíte é a régua disso, e fala com o produto pelo facade
# (`EconomyService`) — nunca escreve `season_score` à mão:
#   S1 — abrir carimba `season.baselines_at` e grava as três linhas de marco com o
#        valor vigente, lido da tabela; e a vitrine confessa `scoring = "delta"`
#        para essa temporada carimbada.
#   S2 — quem sobe dentro da janela entra no placar pela SUBIDA, não pelo total.
#   S3 — quem nasce depois da abertura não tem marco e entra pelo total, que é o
#        número certo para ele.
#   S4 — quem CAI dentro da janela congela em zero e sai do placar; nunca negativo,
#        porque uma corrida que paga prêmio não pode dever.
#   S5 — o teto `limit` é ordenado pelo delta: um absoluto alto com delta baixo não
#        desloca um absoluto baixo com delta alto do único lugar que havia.
#   S6 — o prêmio sai do congelado, na ordem do delta.
#   S7 — controle negativo plantado: uma linha SEM marco (o estado de todo `season`
#        anterior à 064, fabricada pelo mesmo INSERT cru que o boot de um banco
#        velho já viu) volta a congelar o valor corrente E a vitrine confessa
#        `scoring = "current"`. Se alguém tirar a coluna da leitura, é S7 que muda
#        de cor — é ele que prova que `baselines_at` tem leitor e não é decoração.
#   S8 — as outras duas corridas de estado corrente (`boss_kills`, `guild_points`)
#        subtraem o mesmo marco.
#   S9 — o avesso de S1: uma abertura que NÃO cometeu o marco devolve 0. Com o id
#        lido fora do commit, o ROLLBACK levava a linha `season` e a facade
#        entregava o número de uma temporada que não existe.

const PreOpenPower : int = 500
const PreOpenKills : int = 3
const PreOpenGuildPoints : int = 42
const InWindowPower : int = 750
const InWindowKills : int = 5
const InWindowGuildPoints : int = 90
const BornAfterOpenPower : int = 900
const HighFloorAbsolute : int = 10000
const HighFloorDelta : int = 1
const LowFloorAbsolute : int = 1000
const LowFloorDelta : int = 800
const FellFrom : int = 300
const FellTo : int = 100

var checks : int = 0
var failures : int = 0
var _launcher : Node
var _sql : Node
var _eco : Node
var _tag : int = 0

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(got : int, want : int, label : String) -> bool:
	return _check(got == want, "%s: %d vs %d" % [label, got, want])

func _value(board : Array, subjectID : int) -> int:
	for row in board:
		if int((row as Dictionary)["subject_id"]) == subjectID:
			return int((row as Dictionary)["value"])
	return -1

func _mk(name : String) -> Dictionary:
	var acctName : String = "%s_%d_acct" % [name, _tag]
	var nc : GDScript = load("res://sources/network/NetworkCommons.gd")
	var consts : Dictionary = nc.get_script_constant_map()
	var ac : GDScript = load("res://sources/actor/ActorCommons.gd")
	if not bool(_sql.call("AddAccount", acctName, "senha-de-marco-123", "%s_%d@marco.test.local" % [name, _tag],
			consts.get("AgreementTosVersion"), consts.get("AgreementPrivacyVersion"), "203.0.113.9")):
		_check(false, "conta criada (%s)" % acctName)
		return {}
	var accountID : int = int(_sql.call("GetAccountID", acctName))
	if not bool(_sql.call("AddCharacter", accountID, "%s_%d" % [name, _tag], ac.get("DefaultStats"),
			ac.get("DefaultTraits"), ac.get("DefaultAttributes"))):
		_check(false, "personagem criado (%s)" % acctName)
		return {}
	return {"accountID" = accountID, "charID" = int(_sql.call("GetCharacterID", accountID, "%s_%d" % [name, _tag]))}

func _setPower(charID : int, power : int) -> void:
	_sql.call("UpdateRowsRaw", "character", "char_id = %d" % charID, {"power_score" = power})

func _board(seasonID : int, kind : String) -> Array:
	return _eco.call("GetSeasonBoard", seasonID, kind, 50)

func _rowCount(seasonID : int, kind : String) -> int:
	var rows : Array = _sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM season_score WHERE season_id = ? AND kind = ?;", [seasonID, kind])
	return int((rows[0] as Dictionary)["n"]) if not rows.is_empty() else -1

func _baselineValue(seasonID : int, kind : String, subjectID : int) -> int:
	var rows : Array = _sql.call("QueryBindings",
		"SELECT value FROM season_score_baseline WHERE season_id = ? AND kind = ? AND subject_id = ?;",
		[seasonID, kind, subjectID])
	return int((rows[0] as Dictionary)["value"]) if not rows.is_empty() else -1

func _initialize():
	print("== Placar de temporada por janela (migration 064) ==")
	OS.set_environment("SHAMBLETA_ENABLE_SEASONS", "1")
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	if _launcher == null:
		print("FATAL: autoload Launcher ausente")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.get("SQL")
		_eco = _launcher.get("Economy")
		if _sql != null and _eco != null \
				and bool(_sql.get("isInitialized")) and bool(_eco.get("isInitialized")):
			break
	if _sql == null or _eco == null or not bool(_sql.get("isInitialized")):
		print("FATAL: SQL/Economy não inicializaram")
		quit(1)
		return
	# O catálogo de conteúdo NÃO sobe junto com `SQL.isInitialized`: `DB.Preload()`
	# empilha os `load_threaded_request` (`sources/db/DB.gd:224`) e o `PreloadUpdate()`
	# (`sources/db/DB.gd:@PreloadUpdate`) fecha o preload, chama `Load()` e acende `isInitialized`,
	# re-armado a cada `process_frame` — portanto precisa de FRAMES. Esperar só o SQL e medir com o
	# catálogo ainda vazio: aqui os frames caem antes do `quit()`, no runner da CI não,
	# e o MESMO run vale ~30 ou ~1700 objetos conforme a máquina. O check nomeado é o
	# ponto — boot leve é vermelho visível, não medição parcial silenciosa.
	# Padrão de tests/content_hygiene_test.gd.
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 80:
		if bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (entities/maps/items carregados)"):
		print("== RESULT: %d checks, %d failures ==" % [checks, failures])
		var dbAbort : Node = _launcher.get("DB")
		if dbAbort != null:
			dbAbort.call("DrainPendingPreloads")
		quit(failures)
		return
	_run()
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	var db : Node = _launcher.get("DB")
	if db != null:
		db.call("DrainPendingPreloads")
	quit(failures)

func _run() -> void:
	_tag = int(Time.get_unix_time_from_system()) % 1000000
	# O sandbox é reaproveitado entre runs: zerar os contadores correntes é o que
	# faz "quatro linhas no placar" significar quatro LINHAS DESTE RUN, e não a
	# soma do que este harness já plantou em execuções anteriores.
	_sql.call("ExecuteBindings", "UPDATE character SET power_score = 0, bosses_beaten = 0;", [])
	_sql.call("ExecuteBindings", "UPDATE guild SET points = 0;", [])
	_sql.call("ExecuteBindings", "DELETE FROM season_score;", [])
	_sql.call("ExecuteBindings", "DELETE FROM season_score_baseline;", [])
	_sql.call("ExecuteBindings", "UPDATE season SET status = 'settled' WHERE status != 'settled';", [])

	var a : Dictionary = _mk("srd_a")
	var high : Dictionary = _mk("srd_highfloor")
	var low : Dictionary = _mk("srd_lowfloor")
	var fell : Dictionary = _mk("srd_fell")
	if a.is_empty() or high.is_empty() or low.is_empty() or fell.is_empty():
		_check(false, "os quatro personagens pré-abertura existem")
		return
	_setPower(int(a["charID"]), PreOpenPower)
	_setPower(int(high["charID"]), HighFloorAbsolute)
	_setPower(int(low["charID"]), LowFloorAbsolute)
	_setPower(int(fell["charID"]), FellFrom)
	_sql.call("SetCharacterBossesBeaten", int(a["charID"]), PreOpenKills)
	var gid : int = 0
	if bool(_eco.call("MoveGold", int(a["charID"]), 50000, "srd_mint")):
		gid = int(_eco.call("CreateGuild", int(a["accountID"]), int(a["charID"]), "srd_guild_%d" % _tag))
	_check(gid > 0, "guilda criada para a corrida de pontos")
	if gid <= 0:
		return
	_sql.call("ExecuteBindings", "UPDATE guild SET points = ? WHERE guild_id = ?;", [PreOpenGuildPoints, gid])

	var seasonID : int = int(_eco.call("CreateSeason", 30))
	_check(seasonID > 0, "temporada aberta (%d)" % seasonID)
	if seasonID <= 0:
		return

	# S1 — o marco zero foi gravado com o valor vigente, e a linha sabe disso.
	var stamped : Array = _sql.call("QueryBindings", "SELECT baselines_at FROM season WHERE season_id = ?;", [seasonID])
	_check(not stamped.is_empty() and int((stamped[0] as Dictionary)["baselines_at"]) > 0,
		"S1: abrir carimba `season.baselines_at` — sem o carimbo, delta e vida são indistinguíveis")
	_checkEq(_baselineValue(seasonID, "power", int(a["charID"])), PreOpenPower, "S1: marco de power é o valor vigente na abertura")
	_checkEq(_baselineValue(seasonID, "boss_kills", int(a["charID"])), PreOpenKills, "S1: marco de boss_kills idem")
	_checkEq(_baselineValue(seasonID, "guild_points", gid), PreOpenGuildPoints, "S1: marco de guild_points idem")

	# O outro lado da confissão de regime. S7 amarra "current" para a linha sem
	# marco; sem esta linha, uma facade que devolvesse "current" para TODAS as
	# temporadas passaria 25/25 — a régua de um lado só não tem mordida.
	var stampedState : Dictionary = _eco.call("GetSeasonBoardsState", 10)
	_checkEq(int(stampedState.get("season_id", 0)), seasonID, "S1: a vitrine está olhando a temporada recém-aberta")
	_check(str(stampedState.get("scoring", "")) == "delta",
		"S1: a vitrine confessa o regime da temporada com marco (%s)" % str(stampedState.get("scoring", "")))

	# S2/S3/S4/S5 — a janela acontece.
	_setPower(int(a["charID"]), InWindowPower)
	_sql.call("SetCharacterBossesBeaten", int(a["charID"]), InWindowKills)
	_sql.call("ExecuteBindings", "UPDATE guild SET points = ? WHERE guild_id = ?;", [InWindowGuildPoints, gid])
	var born : Dictionary = _mk("srd_born")
	_check(not born.is_empty(), "S3: personagem nascido depois da abertura")
	if not born.is_empty():
		_setPower(int(born["charID"]), BornAfterOpenPower)
		_sql.call("SetCharacterBossesBeaten", int(born["charID"]), 4)
	_setPower(int(high["charID"]), HighFloorAbsolute + HighFloorDelta)
	_setPower(int(low["charID"]), LowFloorAbsolute + LowFloorDelta)
	_setPower(int(fell["charID"]), FellTo)

	_checkEq(int(_eco.call("SnapshotSeasonPower", seasonID)), 4, "S2/S4: quatro linhas no placar de power (quem caiu sai, quem nasceu entra)")
	var power : Array = _board(seasonID, "power")
	_checkEq(_value(power, int(a["charID"])), InWindowPower - PreOpenPower,
		"S2: power na janela é a SUBIDA (%d), não o total (%d)" % [InWindowPower - PreOpenPower, InWindowPower])
	_checkEq(_value(power, int(born["charID"])), BornAfterOpenPower, "S3: sem marco, o total é o número certo")
	_checkEq(_value(power, int(fell["charID"])), -1, "S4: quem caiu dentro da janela não aparece no placar")

	# S5 — a ordenação do `limit` é pelo delta. Com teto de UMA linha, o absoluto
	# alto (10.001) não pode desalojar o delta alto (900): era assim que a corrida
	# ficava reservada a quem já era forte antes de a temporada existir.
	var one : Array = _eco.call("GetSeasonBoard", seasonID, "power", 1)
	_checkEq(one.size(), 1, "S5: o teto de uma linha é respeitado")
	if one.size() == 1:
		var winner : int = int((one[0] as Dictionary)["subject_id"])
		_check(winner == int(born["charID"]),
			"S5: o topo é quem mais SUBIU (%d, delta %d), não quem tem maior absoluto (%d, %d)" % [winner, BornAfterOpenPower, int(high["charID"]), HighFloorAbsolute + HighFloorDelta])

	# S8 na numeração original — mesma subtração para as outras duas corridas.
	_checkEq(int(_eco.call("SnapshotSeasonBossKills", seasonID)), 2, "duas linhas no placar de boss_kills")
	_checkEq(_value(_board(seasonID, "boss_kills"), int(a["charID"])), InWindowKills - PreOpenKills, "boss_kills na janela é a diferença")
	_checkEq(int(_eco.call("SnapshotSeasonGuildPoints", seasonID)), 1, "uma linha no placar de guild_points")
	_checkEq(_value(_board(seasonID, "guild_points"), gid), InWindowGuildPoints - PreOpenGuildPoints, "ponto de guilda na janela é a diferença")

	# S6 — o prêmio sai do congelado: o primeiro a receber é o dono do maior delta.
	_check(bool(_eco.call("CloseSeason", seasonID)), "temporada fechada")
	var settled : Dictionary = _eco.call("SettleSeasonPrizes", seasonID)
	_check(bool(settled.get("ok", false)), "S6: temporada liquidada (%s)" % str(settled.get("reason", "")))
	var prizeRows : Array = _sql.call("QueryBindings",
		"SELECT reason FROM ledger_transaction WHERE reason LIKE ? GROUP BY reason ORDER BY MIN(id);",
		["season_prize:%d:power:%%" % seasonID])
	_check(not prizeRows.is_empty(), "S6: a corrida de power pagou prêmio (%d linhas)" % prizeRows.size())
	if not prizeRows.is_empty():
		var topReason : String = str((prizeRows[0] as Dictionary)["reason"])
		_check(topReason.ends_with(":%d" % int(born["charID"])),
			"S6: o primeiro prêmio de power vai para quem subiu na janela (%s deveria terminar em %d)" % [topReason, int(born["charID"])])

	# S7 — controle negativo plantado: a linha anterior à 064, sem carimbo e sem
	# marco, ativa para a vitrine ler.
	var legacy : int = _openLegacyRow()
	_check(legacy > 0, "S7: linha de temporada pré-064 fabricada (sem `baselines_at`, sem marco)")
	if legacy > 0:
		_checkEq(int(_eco.call("SnapshotSeasonPower", legacy)), 5,
			"S7: sem marco o congelado volta a ser o estado corrente — cinco personagens com power > 0, inclusive quem caiu")
		_checkEq(_value(_board(legacy, "power"), int(high["charID"])), HighFloorAbsolute + HighFloorDelta,
			"S7: o valor é o absoluto, que é o que a linha legada significa; não um delta inventado a posteriori")
		var boards : Dictionary = _eco.call("GetSeasonBoardsState", 10)
		_check(str(boards.get("scoring", "")) == "current",
			"S7: a vitrine confessa o regime (`scoring` = \"%s\") — tirada a coluna da leitura, `current` vira `delta` e o jogador lê a vida como se fosse a temporada" % str(boards.get("scoring", "")))
		_sql.call("ExecuteBindings", "UPDATE season SET status = 'closed' WHERE season_id = ?;", [legacy])

	# S9 — o outro lado da mesma transação que S1 amarra por cima. S1 prova que o
	# marco é gravado junto do INSERT; nada provava ainda que um INSERT sem marco
	# cometido NÃO devolve temporada. É a perna que falta porque o defeito morava
	# exatamente aí: `_CreateSeasonWindow` lia `out["id"]` depois do `if` da
	# transação, e não dentro do ramo que cometeu, então quando a escrita do marco
	# falhava o ROLLBACK levava a linha `season` e a função devolvia o número de uma
	# temporada que não existe — que `EnsureSeason` ainda anunciava no log como aberta.
	_testAbortedOpening()

# A prótese é verdadeira de propósito: em vez de fingir um retorno false, tira do
# banco a tabela que `_StampRaceBaselines` escreve, para a abertura falhar pelo
# mesmo caminho que falharia num banco sem a migration 064 aplicada. As duas pernas
# abaixo são o par: a primeira é a régua, a segunda é o controle de que a prótese não
# deixou `CreateSeason` quebrado para sempre (sem ela, "devolve 0" seria verdade até
# com a facade morta).
# Consequência lida no log: este bloco imprime `ERROR: --> SQL error: no such table:
# season_score_baseline` com o portão verde. É a prótese falando, e não um defeito
# de produto nem um vazamento de erro — é exatamente a linha que uma abertura contra
# um banco pré-064 produziria, e é ela que faz o ROLLBACK acontecer.
func _testAbortedOpening() -> void:
	if not _check(bool(_sql.call("ExecuteBindings",
			"ALTER TABLE season_score_baseline RENAME TO srd_baseline_gone;", [])),
			"S9: a tabela de marco sai de cena, para a escrita do marco falhar de verdade"):
		return
	var before : Array = _sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM season;", [])
	var beforeCount : int = int((before[0] as Dictionary)["n"]) if not before.is_empty() else -1
	var phantom : int = int(_eco.call("CreateSeason", 30))
	_checkEq(phantom, 0,
		"S9: abertura que não cometeu devolve 0 — id de linha rolada para trás é uma temporada fantasma")
	var after : Array = _sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM season;", [])
	_checkEq((int((after[0] as Dictionary)["n"]) if not after.is_empty() else -1), beforeCount,
		"S9: o ROLLBACK levou a linha `season` — nada órfão ficou no banco")
	if not _check(bool(_sql.call("ExecuteBindings",
			"ALTER TABLE srd_baseline_gone RENAME TO season_score_baseline;", [])),
			"S9 controle: a tabela de marco volta ao lugar, para a prótese não virar estado"):
		return
	var revived : int = int(_eco.call("CreateSeason", 30))
	_check(revived > 0,
		"S9 controle: com a tabela de volta a MESMA abertura comete e devolve id (%d)" % revived)
	if revived > 0:
		var stampedRevived : Array = _sql.call("QueryBindings",
			"SELECT baselines_at FROM season WHERE season_id = ?;", [revived])
		_check(not stampedRevived.is_empty() and int((stampedRevived[0] as Dictionary)["baselines_at"]) > 0,
			"S9 controle: a temporada cometida é a carimbada, não uma linha sem marco")
		# O sandbox é compartilhado: uma temporada ativa sobreviveria a este run e
		# mudaria a leitura do harness de temporada que vier depois.
		_sql.call("ExecuteBindings", "UPDATE season SET status = 'settled' WHERE season_id = ?;", [revived])

func _openLegacyRow() -> int:
	var now : int = int(Time.get_unix_time_from_system())
	var out : Dictionary = {"id" = 0}
	# O INSERT é cru de propósito: a linha pré-064 precisa nascer SEM `baselines_at`,
	# e nenhuma facade do produto insere `season` sem carimbar o marco.
	var ok : bool = bool(_sql.call("Transaction", func() -> bool:
		if not bool(_sql.call("ExecuteBindings",
				"INSERT INTO season (starts_at, ends_at, rules_frozen, status) VALUES (?, ?, '{}', 'active');",
				[now, now + 30 * 86400])):
			return false
		out["id"] = int(_sql.call("LastInsertRowIDRaw"))
		return int(out["id"]) > 0))
	return int(out["id"]) if ok and int(out["id"]) > 0 else 0
