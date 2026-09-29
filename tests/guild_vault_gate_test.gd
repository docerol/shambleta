extends SceneTree

# AUDITORIA 2026-09-27 §14, metade do SERVIDOR: o portão anti-dreno do vault.
#
# O buraco: `GuildWithdrawGate` existia só no cliente, e o cabeçalho do próprio
# arquivo admitia que "o limite de verdade é do servidor". Um oficial com cliente
# modado nunca passava por aquele portão — dava para drenar o vault inteiro num
# clique. Este harness é a prova executável de que o servidor segura sozinho, e de
# que o freio do cliente continua dando a mensagem antes do clique.
#
# Blocos na ordem (eles consomem a MESMA janela, e é isso que torna cada um lido):
#   1. teto por ação recusado antes de qualquer transação (zero linha no rastro);
#   2. dreno por chamada direta ao service (cliente modado) para em 3 ações;
#   3. um portão de cliente zerado autoriza, e o servidor ainda recusa;
#   4. a janela é do rastro: retrodatar reabre, e reabre exatamente 3 ações;
#   5. crédito é por CONTA (B não herda o bloqueio de A) e recusa por rank não gasta;
#   6. depósito não consome orçamento de saque;
#   7. painel recusa o 4º clique com a mensagem da janela SEM ir ao banco — e as
#      duas metades são independentes: rastro retrodatado libera o service, o
#      carimbo do painel continua cheio;
#   8. aritmética da janela com relógio injetado (fronteira estrita nos dois lados);
#   9. o índice existe, foi aplicado pela migration e o plano é SEARCH — sem ele o
#      gate pagaria um SCAN num log append-only dentro do settleMutex; fonte única
#      dos três números; vault == rastro;
#  10. leitura da janela quebrada devolve recusa (999), nunca licença.
#
# Uso: godot --headless --path . -s tests/guild_vault_gate_test.gd
# Exit code = checks falhos. Última linha: `== VAULT GATE: N checks, M failures ==`.
#
# Regra dos harnesses `-s` (run_idle_tests.gd:1, social_fix_test.gd:14): o main-loop
# compila antes de autoloads e class_names existirem — nada de identificador de
# autoload ou `class_name` em anotação de tipo aqui; tudo via load()/get()/call().

var checks : int = 0
var failures : int = 0
var dbScript : GDScript = null

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _initialize():
	_runTests()

func _runTests():
	print("== vault gate: §14 metade do servidor ==")
	var launcher : Node = _autoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return

	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = launcher.get("SQL")
		var worldNode : Node = launcher.get("World")
		if sqlNode != null and sqlNode.get("isInitialized") and worldNode != null and worldNode.get("isInitialized"):
			break
	print("== boot wait done (%d ms) ==" % waited)

	# SQL+World prontos NÃO implicam o preload threadado do DB drenado; `load()` e
	# `quit()` no meio dos parses em thread de trabalho derrubam o processo com os
	# checks verdes (SIGABRT de teardown, mesmo probe de social_fix_test.gd:86).
	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for dbTick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	Check(dbReady, "preload threadado do DB drenado antes de qualquer load()/quit")

	var sql : Node = launcher.get("SQL")
	var economy : Node = launcher.get("Economy")
	if not Check(sql != null and economy != null, "SQL + Economy booteds") or sql == null or economy == null:
		_finish()
		return
	if economy.get("guildService") == null:
		economy.call("_post_launch")
	var guildService : Object = economy.get("guildService")
	if not Check(guildService != null, "GuildService mounted on Economy") or guildService == null:
		_finish()
		return

	# O índice precisa ter sido APLICADO, não apenas existir no disco: o plano do
	# bloco 9 depende dele, e `db_version` é a única voz da base.
	Check(int(sql.call("GetVersion")) >= 60, "base alcançou a migration 060 (db_version >= 60)")

	var limits : GDScript = load("res://sources/economy/GuildVaultLimits.gd")
	var consts : Dictionary = limits.get_script_constant_map()
	var perAction : int = int(consts.get("MaxWithdrawPerAction", -1))
	var windowMax : int = int(consts.get("MaxWithdrawActionsInWindow", -1))
	var windowSec : int = int(consts.get("WindowSec", -1))
	Check(perAction == 10 and windowMax == 3 and windowSec == 300, "GuildVaultLimits declara 10/3/300 (got %d/%d/%d)" % [perAction, windowMax, windowSec])

	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()
	var farmScript : GDScript = load("res://sources/idle/FarmZoneData.gd")
	var apple : int = int(farmScript.get_script_constant_map().get("DefaultDropItemHash", 215387671))

	var guildName : String = "Vault Gate Guild"
	_janitor(sql, guildName)
	var charA : int = int(suites.call("CreateFixture", sql, "vault_gate_a", "VaultGateA"))
	var charB : int = int(suites.call("CreateFixture", sql, "vault_gate_b", "VaultGateB"))
	if not Check(charA != 0 and charB != 0, "fixtures criados (%d, %d)" % [charA, charB]):
		_finish()
		return
	var acctA : int = int(sql.call("GetAccountIDForCharacter", charA))
	var acctB : int = int(sql.call("GetAccountIDForCharacter", charB))
	var guildID : int = int(economy.call("CreateGuild", acctA, charA, guildName))
	Check(guildID > 0, "A fundou a guild #%d" % guildID)
	Check(bool(economy.call("JoinGuild", acctB, guildID)), "B entrou na guild")

	suites.call("_SetInventory", sql, charA, apple, 50)
	Check(bool(economy.call("DepositToVault", acctA, charA, apple, 50)), "A depositou 50 no vault")
	CheckEq(_vaultOf(sql, guildID, apple), 50, "vault tem 50 antes dos saques")
	CheckEq(int(suites.call("_CountItem", sql, charA, apple)), 0, "o depósito esvaziou o inventário de A")

	# ---------------------------------------------------------------- 1. teto por ação
	CheckEq(_withdrawRows(sql, acctA), 0, "A começa sem nenhum saque no rastro")
	Check(not bool(economy.call("WithdrawFromVault", acctA, charA, apple, perAction + 1)), "service recusa saque de %d (acima do teto)" % (perAction + 1))
	Check(not bool(economy.call("WithdrawFromVault", acctA, charA, apple, 1000000)), "o 10^6 do cliente modado é recusado sem abrir transação")
	CheckEq(_withdrawRows(sql, acctA), 0, "recusa por teto NÃO escreve no rastro")
	CheckEq(int(suites.call("_CountItem", sql, charA, apple)), 0, "e não mexe no inventário")
	Check(bool(economy.call("WithdrawFromVault", acctA, charA, apple, perAction)), "saque exatamente no teto passa")
	CheckEq(int(suites.call("_CountItem", sql, charA, apple)), perAction, "crédito do saque aceito cai no personagem")

	# ---------------------------------------------------------------- 2. dreno modado
	_backdate(sql, acctA, windowSec + 5)
	var attempts : int = 0
	var moved : int = 0
	for attempt in 12:
		attempts += 1
		if bool(economy.call("WithdrawFromVault", acctA, charA, apple, perAction)):
			moved += perAction
	CheckEq(attempts, 12, "as 12 tentativas do loop rodaram inteiras")
	CheckEq(moved, perAction * windowMax, "dreno direto ao service parou em %d unidades (%d ações)" % [perAction * windowMax, windowMax])
	CheckEq(int(suites.call("_CountItem", sql, charA, apple)), perAction + perAction * windowMax, "inventário não recebeu nada além do permitido")
	CheckEq(_withdrawsInWindow(sql, acctA, windowSec), windowMax, "rastro na janela == saques aceitos na janela")

	# ---------------------------------------------------------------- 3. portão novo não reabre crédito
	var gateScript : GDScript = load("res://sources/gui/GuildWithdrawGate.gd")
	var freshGate : Object = gateScript.new()
	Check(str(freshGate.call("Reason", perAction)) == "", "portão de cliente zerado autoriza o saque (ele não é a verdade)")
	Check(not bool(economy.call("WithdrawFromVault", acctA, charA, apple, perAction)), "servidor recusa com o cliente sem memória — a verdade é o rastro")

	# ---------------------------------------------------------------- 4. janela durável
	Check(not bool(economy.call("WithdrawFromVault", acctB, charB, apple, perAction)), "B ainda 'member' é recusado pelo rank")
	# Reabastece o vault antes de reabrir a janela: sem estoque suficiente a recusa
	# seguinte viria de "não tem" e não do portão, e o número abaixo não provaria nada.
	suites.call("_SetInventory", sql, charA, apple, 60)
	Check(bool(economy.call("DepositToVault", acctA, charA, apple, 60)), "vault reabastecido para o teste de durabilidade")
	_backdate(sql, acctA, windowSec + 5)
	var reopened : int = 0
	for attempt2 in windowMax + 2:
		if bool(economy.call("WithdrawFromVault", acctA, charA, apple, perAction)):
			reopened += 1
	CheckEq(reopened, windowMax, "retrodatar o rastro reabre EXATAMENTE a janela (%d ações), não o vault todo" % windowMax)

	# ---------------------------------------------------------------- 5. crédito por conta
	CheckEq(_withdrawRows(sql, acctB), 0, "recusa por rank não consome crédito de janela")
	Check(bool(economy.call("PromoteMember", acctA, acctB)), "A promoveu B a officer")
	Check(bool(economy.call("WithdrawFromVault", acctB, charB, apple, perAction)), "B saca com A bloqueado — crédito é por CONTA, não por guild")
	CheckEq(int(suites.call("_CountItem", sql, charB, apple)), perAction, "o crédito foi para o personagem de B")

	# ---------------------------------------------------------------- 6. depósito não gasta o orçamento
	_backdate(sql, acctA, windowSec + 5)
	suites.call("_SetInventory", sql, charA, apple, 50)
	for deposit in 4:
		Check(bool(economy.call("DepositToVault", acctA, charA, apple, 10)), "depósito %d de 4 aceito" % (deposit + 1))
	Check(bool(economy.call("WithdrawFromVault", acctA, charA, apple, perAction)), "os 4 depósitos não comeram crédito de saque")

	# ---------------------------------------------------------------- 7. painel = antecedência
	_backdate(sql, acctA, windowSec + 5)
	suites.call("_SetInventory", sql, charA, apple, 50)
	Check(bool(economy.call("DepositToVault", acctA, charA, apple, 50)), "vault reabastecido para o caminho do painel")
	var panelScript : GDScript = load("res://sources/gui/GuildPanel.gd")
	var panel : Object = panelScript.new()
	panel.call("SetLocalIDs", acctA, charA)
	var vaultBefore : int = _vaultOf(sql, guildID, apple)
	var windowBefore : int = _withdrawsInWindow(sql, acctA, windowSec)
	var pulled : int = 0
	for click in 5:
		if bool(panel.call("WithdrawItem", apple, perAction)):
			pulled += perAction
	CheckEq(pulled, perAction * windowMax, "painel: 3 saques de %d e nem um a mais" % perAction)
	CheckEq(_vaultOf(sql, guildID, apple), vaultBefore - pulled, "o vault baixou exatamente o que o painel entregou")
	CheckEq(_withdrawsInWindow(sql, acctA, windowSec), windowBefore + windowMax, "painel carimba o rastro na mesma cadência do portão")
	# As duas metades são independentes, e é isto que prova que a recusa do 4º clique
	# veio do portão do cliente e não do banco: o rastro vai para fora da janela (o
	# servidor libera) e o carimbo do painel continua cheio.
	_backdate(sql, acctA, windowSec + 5)
	CheckEq(_withdrawsInWindow(sql, acctA, windowSec), 0, "rastro de A fora da janela: o servidor está livre")
	Check(not bool(panel.call("WithdrawItem", apple, perAction)), "painel ainda recusa o 4º (portão do cliente, não o banco)")
	Check(str(panel.call("WithdrawGateReason", perAction)).find("too many withdrawals") >= 0, "a recusa do painel traz a mensagem legível da janela")
	CheckEq(_withdrawsInWindow(sql, acctA, windowSec), 0, "a recusa do painel NÃO foi ao banco (zero linha nova)")
	Check(bool(economy.call("WithdrawFromVault", acctA, charA, apple, perAction)), "e o service, no mesmo instante, aceita — as metades não são a mesma conta")

	# ---------------------------------------------------------------- 8. aritmética com relógio injetado
	var unitGate : Object = gateScript.new()
	var t0 : int = 1700000000
	Check(str(unitGate.call("Reason", perAction, t0)) == "", "janela vazia autoriza em t0")
	unitGate.call("Record", t0)
	unitGate.call("Record", t0 + 1)
	unitGate.call("Record", t0 + 2)
	CheckEq(int(unitGate.call("CountInWindow", t0 + 2)), windowMax, "três carimbos contam na janela")
	Check(str(unitGate.call("Reason", perAction, t0 + windowSec - 1)) != "", "em WindowSec-1 o primeiro saque ainda pesa (fronteira estrita)")
	Check(str(unitGate.call("Reason", perAction, t0 + windowSec)) == "", "em WindowSec o primeiro saiu da janela")
	Check(str(unitGate.call("Reason", perAction + 1, t0 + windowSec)) != "", "teto por ação é checável com a janela livre")
	CheckEq(int(unitGate.call("CountInWindow", t0 + windowSec)), windowMax - 1, "em WindowSec exatamente UM carimbo sai da janela (sobram %d de %d)" % [windowMax - 1, windowMax])

	# ---------------------------------------------------------------- 9. índice, plano, fonte única
	var plan : Array = sql.call("Query", "EXPLAIN QUERY PLAN SELECT COUNT(*) AS n FROM guild_vault_log WHERE account_id = 1 AND kind = 'withdraw' AND created_at >= 0;")
	var detail : String = ""
	for row in plan:
		detail += str((row as Dictionary).get("detail", "")) + " | "
	Check(detail.find("SEARCH") >= 0 and detail.find("idx_vault_log_window") >= 0, "plano faz SEARCH no idx_vault_log_window (%s)" % detail.strip_edges())
	var migText : String = FileAccess.get_file_as_string("res://data/conf/migrations/060_vault_withdraw_gate.sql")
	Check(migText.contains("CREATE INDEX IF NOT EXISTS idx_vault_log_window ON guild_vault_log(account_id, kind, created_at);"), "a migration 060 declara exatamente o índice consultado")
	var gateSrc : String = FileAccess.get_file_as_string("res://sources/gui/GuildWithdrawGate.gd")
	var svcSrc : String = _methodSource(FileAccess.get_file_as_string("res://sources/economy/GuildService.gd"), "WithdrawFromVault")
	var helperSrc : String = _methodSource(FileAccess.get_file_as_string("res://sources/economy/GuildService.gd"), "_WithdrawsInWindowLocked")
	Check(not gateSrc.contains("MaxWithdrawPerAction : int ="), "o portão não redeclara os números (fonte única em GuildVaultLimits)")
	Check(svcSrc.contains("GuildVaultLimits.MaxWithdrawPerAction") and svcSrc.contains("GuildVaultLimits.MaxWithdrawActionsInWindow"), "o service checa as DUAS metades pelo mesmo módulo")
	Check(helperSrc.contains("GuildVaultLimits.WindowSec") and gateSrc.contains("GuildVaultLimits.WindowSec"), "as duas metades leem o MESMO WindowSec")
	CheckEq(_vaultTotal(sql, guildID), _trailNet(sql, guildID), "vault == rastro (depósitos - saques) da guild")

	# ---------------------------------------------------------------- 10. fail-closed
	# `ALTER` é verbo de escrita para `SQLReadRules`, então esta DDL sai no handle do
	# writer — mesma conexão que o gate consulta.
	sql.call("Query", "ALTER TABLE guild_vault_log RENAME TO guild_vault_log_bak;")
	CheckEq(int(guildService.call("_WithdrawsInWindowLocked", sql, acctA)), 999, "SELECT da janela quebrada devolve 999, nunca 0")
	Check(not bool(economy.call("WithdrawFromVault", acctA, charA, apple, perAction)), "sem rastro legível o saque é recusado (falha de leitura não é licença)")
	sql.call("Query", "ALTER TABLE guild_vault_log_bak RENAME TO guild_vault_log;")
	_backdate(sql, acctA, windowSec + 5)
	CheckEq(int(guildService.call("_WithdrawsInWindowLocked", sql, acctA)), 0, "com o rastro de volta a leitura conta 0 e o índice seguiu a tabela")
	Check(bool(economy.call("WithdrawFromVault", acctA, charA, apple, perAction)), "e o saque passa de novo (renomear não deixou destroço)")

	# ---------------------------------------------------------------- limpeza
	panel.free()
	_janitor(sql, guildName)
	sql.call("ExecuteBindings", "DELETE FROM character WHERE nickname = ? OR nickname = ?;", ["VaultGateA", "VaultGateB"])
	sql.call("ExecuteBindings", "DELETE FROM account WHERE username = ? OR username = ?;", ["vault_gate_a", "vault_gate_b"])
	_finish()

func _withdrawRows(sql : Node, accountID : int) -> int:
	return _countRows(sql, "SELECT COUNT(*) AS n FROM guild_vault_log WHERE account_id = ? AND kind = 'withdraw';", [accountID])

# Contagem na MESMA janela do servidor (`created_at >= agora - WindowSec`), para que
# "aceito" no rastro e "conta" no portão sejam a mesma pergunta.
func _withdrawsInWindow(sql : Node, accountID : int, windowSec : int) -> int:
	return _countRows(sql, "SELECT COUNT(*) AS n FROM guild_vault_log WHERE account_id = ? AND kind = 'withdraw' AND created_at >= ?;", [accountID, _now() - windowSec])

func _countRows(sql : Node, query : String, params : Array) -> int:
	var rows : Array = sql.call("QueryBindings", query, params)
	return int((rows[0] as Dictionary).get("n", -1)) if not rows.is_empty() else -1

func _now() -> int:
	return int(Time.get_unix_time_from_system())

func _vaultOf(sql : Node, guildID : int, itemID : int) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT count FROM guild_vault WHERE guild_id = ? AND item_id = ?;", [guildID, itemID])
	return int((rows[0] as Dictionary).get("count", 0)) if not rows.is_empty() else 0

func _vaultTotal(sql : Node, guildID : int) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT COALESCE(SUM(count), 0) AS n FROM guild_vault WHERE guild_id = ?;", [guildID])
	return int((rows[0] as Dictionary).get("n", 0)) if not rows.is_empty() else 0

func _trailNet(sql : Node, guildID : int) -> int:
	var rows : Array = sql.call("QueryBindings", "SELECT COALESCE(SUM(CASE WHEN kind = 'deposit' THEN count ELSE -count END), 0) AS n FROM guild_vault_log WHERE guild_id = ?;", [guildID])
	return int((rows[0] as Dictionary).get("n", 0)) if not rows.is_empty() else 0

# Retrodata o rastro de saque da conta: é como se move uma janela de 300 s sem
# dormir 5 minutos dentro de um gate de CI.
func _backdate(sql : Node, accountID : int, seconds : int) -> void:
	sql.call("ExecuteBindings", "UPDATE guild_vault_log SET created_at = created_at - ? WHERE account_id = ? AND kind = 'withdraw';", [seconds, accountID])

func _janitor(sql : Node, guildName : String) -> void:
	sql.call("ExecuteBindings", "DELETE FROM guild_vault_log WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_vault WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild_member WHERE guild_id IN (SELECT guild_id FROM guild WHERE name = ?);", [guildName])
	sql.call("ExecuteBindings", "DELETE FROM guild WHERE name = ?;", [guildName])

# Só o corpo do método, para as réguas de fonte não casarem com um comentário de
# outro canto do arquivo.
func _methodSource(src : String, methodName : String) -> String:
	var start : int = src.find("func " + methodName + "(")
	if start < 0:
		return ""
	var next : int = src.find("\nfunc ", start + 1)
	return src.substr(start, next - start) if next > 0 else src.substr(start)

func _finish():
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	print("== VAULT GATE: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
