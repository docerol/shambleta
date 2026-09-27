extends SceneTree

# Gate de fatos de documentação — a doc é conferida contra o QUE RODA.
#
# Uso:  godot --headless --path . -s tests/doc_facts_test.gd
#       (`scripts/test.sh` descobre este arquivo por nome — `harnesses_extra()` —
#        e `harness_marker()` lê o marcador da linha `== RESULT:` abaixo.)
#
# Por que isto existe e não é o `scripts/check_doc_drift.sh` repetido: o gate de
# drift é bash e compara texto com texto. Há fatos cuja única fonte é o runtime —
# o `enum` que gera o nome do diretório de backup, as colunas que o schema tem
# DEPOIS de todas as migrations rodarem, o autoload que `project.godot` registra.
# A varredura de 2026-09-27 achou doc que "já foi verdade" nesses exatamente cinco
# lugares. Aqui cada assERÇÃO é (a) o fato medido no código/schema/engine e (b) a
# frase da doc que o afirma, lida do arquivo — se um dos dois divergir, o gate
# imprime esperado vs. atual e falha.
#
# Nada de identificador de projeto em parse: `-s` compila este arquivo antes dos
# `class_name` globais estarem registrados, então tudo é `load()`/`call()`/`get()`.

var checks : int = 0
var failures : int = 0
var dbScript : GDScript = null

# Piso de checks: medido na corrida verde (66), com folga. Sem a guarda, um SCRIPT
# ERROR no meio derruba o `_run()` e o RESULT sairia "0 failures" com metade das
# checks feitas — o CI assinaria o que não rodou.
const ExpectedChecks : int = 60

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if condition:
		print("  [ok] " + label)
		return true
	failures += 1
	print("  [FAIL] " + label)
	return false

func CheckEq(got : Variant, want : Variant, label : String) -> bool:
	# `String == int` aborta a expressão em GDScript 4 com `Invalid operands`, e uma
	# check abortada não é contada como falha: `== RESULT:` seguia dizendo zero
	# falhas com a check perdida no meio. Achado por `scripts/ci_gate_log.sh` no run
	# de 2026-09-27, na régua que compara a contagem de autoload afirmada na doc com
	# a do `project.godot`. Tipo diferente vira falha contada, não exceção.
	if typeof(got) != typeof(want):
		return Check(false, "%s — tipos diferentes: esperado [%s] (%s), atual [%s] (%s)" % [
			label, str(want), type_string(typeof(want)), str(got), type_string(typeof(got))])
	return Check(got == want, "%s — esperado [%s], atual [%s]" % [label, str(want), str(got)])

func _read(path : String) -> String:
	if not FileAccess.file_exists(path):
		push_warning("doc_facts_test: não li %s" % path)
		return ""
	var fa : FileAccess = FileAccess.open(path, FileAccess.READ)
	if fa == null:
		push_warning("doc_facts_test: aberto falhou em %s" % path)
		return ""
	var text : String = fa.get_as_text()
	fa.close()
	return text

# Só as linhas de código: comentário não é afirmação executável.
func _code_only(text : String) -> String:
	var out : String = ""
	for line in text.split("\n"):
		var t : String = line.strip_edges()
		if t.begins_with("#"):
			continue
		out += line + "\n"
	return out

func _initialize():
	_run()

func _run():
	print("== doc facts (code is the source of truth) ==")

	var launcher : Node = root.get_node_or_null(^"Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload ausente")
		quit(1)
		return

	# Espera o boot dos serviços (mesma espera dos harnesses de schema): sem SQL
	# inicializado não há PRAGMA a ler.
	var waited : int = 0
	var sql : Node = null
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		sql = launcher.get("SQL")
		if sql != null and bool(sql.get("isInitialized")):
			break
	print("== boot wait done (%d ms) ==" % waited)

	# O boot do Launcher dispara `DB.Preload()`, que pede centenas de presets ao
	# `ResourceLoader.load_threaded_request()`. SQL inicializado NÃO implica que
	# eles terminaram: sem juntar aqui, os `load()` abaixo e o próprio `quit()`
	# caem no meio dos parses em thread de trabalho e o processo morre em
	# `Launcher._exit_tree` com os checks verdes (a corrida que este contrato
	# existe para não repetir).
	dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for dbTick in 40:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	Check(dbReady, "preload threadado do DB drenado antes de qualquer load()/quit")

	_FactBackupDirs()
	await _FactGrantQueue(sql)
	_FactComposeServices()
	_FactOffsiteDefault()
	_FactAutoloads()
	_FactHealthzBind()
	_FactHotkeys()
	_FactReconcileTimer()
	_FactComposeGateIsWired()
	_FactLogGroups()
	_FactCompanionErrorLiteral()

	_finish()

# --- 1. o nome do diretório de backup vem do enum, não da memória do autor -----
func _FactBackupDirs() -> void:
	var commons : GDScript = load("res://sources/sql/SQLCommons.gd")
	var keys : Array = []
	if commons != null:
		var consts : Dictionary = commons.get_script_constant_map()
		var enumValue : Variant = consts.get("BackupFrequency", null)
		if enumValue is Dictionary:
			for k in (enumValue as Dictionary).keys():
				keys.append(str(k))
	CheckEq(keys, ["DAILY", "WEEKLY", "MONTHLY"],
		"SQLCommons.BackupFrequency.keys() é a fonte dos nomes de diretório")
	# É isso que SQLBackups monta, e não um literal no meio do código.
	var backups : String = _read("res://sources/sql/SQLBackups.gd")
	Check(backups.contains("BackupFrequency.keys()"),
		"SQLBackups.gd constrói o diretório a partir de BackupFrequency.keys()")
	for doc in ["res://deploy/BACKUP_RUNBOOK.md", "res://deploy/COOLIFY.md", "res://deploy/ROLLBACK.md"]:
		var text : String = _read(doc)
		Check(not text.contains("sql-backups/daily") and not text.contains("sql-backups/weekly") and not text.contains("sql-backups/monthly"),
			"%s não manda o operator fazer ls num diretório minúsculo" % doc)
	Check(_read("res://deploy/BACKUP_RUNBOOK.md").contains("sql-backups/{DAILY,WEEKLY,MONTHLY}"),
		"BACKUP_RUNBOOK.md cita os três diretórios com o nome que o enum produz")

# --- 2. as colunas que o schema TEM, depois de todas as migrations -------------
func _FactGrantQueue(sql : Node) -> void:
	if sql == null or not bool(sql.get("isInitialized")):
		Check(false, "SQL inicializado para ler PRAGMA table_info(grant_queue)")
		return
	var cols : Array[String] = []
	var rows : Array = sql.call("QueryBindings", "PRAGMA table_info(grant_queue);", [])
	for row in rows:
		cols.append(str((row as Dictionary).get("name", "")))
	Check(cols.size() > 5, "grant_queue tem colunas lidas do schema vivo (%d)" % cols.size())
	Check(not cols.has("granted_at"),
		"grant_queue NÃO tem granted_at (é coluna de cosmetic_grant, migration 023) — colunas: %s" % [cols])
	Check(cols.has("status") and cols.has("created_at") and cols.has("processed_at"),
		"grant_queue tem status/created_at/processed_at, que é o que o runbook consulta")
	var rollback : String = _read("res://deploy/ROLLBACK.md")
	Check(rollback.contains("FROM grant_queue WHERE status"),
		"ROLLBACK.md filtra grant_queue por status (a coluna real)")
	Check(not rollback.contains("granted_at IS NULL"),
		"ROLLBACK.md não ensina a query que quebra em no such column")
	# Cada `FROM <tabela> WHERE <coluna>` ensinada em runbook tem que bater com o
	# schema vivo — é a classe do defeito, não a linha específica.
	for doc in ["res://deploy/ROLLBACK.md", "res://deploy/OPS_RUNBOOK.md", "res://deploy/COOLIFY.md"]:
		var text : String = _read(doc)
		var rx : RegEx = RegEx.create_from_string("FROM ([a-z_]+) WHERE ([a-z_]+)")
		for m in rx.search_all(text):
			var table : String = m.get_string(1)
			var column : String = m.get_string(2)
			var tcols : Array[String] = []
			var trows : Array = sql.call("QueryBindings", "PRAGMA table_info(%s);" % table, [])
			for row in trows:
				tcols.append(str((row as Dictionary).get("name", "")))
			Check(tcols.has(column),
				"%s consulta %s.%s e o schema vivo tem essa coluna (%d colunas)" % [doc, table, column, tcols.size()])

# --- 3. quantos serviços o compose declara ------------------------------------
func _FactComposeServices() -> void:
	var compose : String = _read("res://deploy/docker-compose.yml")
	var services : Array[String] = []
	var inside : bool = false
	for line in compose.split("\n"):
		if line.begins_with("services:"):
			inside = true
			continue
		# Linha em branco ou comentário de coluna 0 NÃO encerra o bloco: no arquivo
		# real há uma linha vazia entre `web:` e `game`, e fechar nela fazia o
		# parser enxergar 1 serviço. Mesma regra do awk de check_doc_drift.sh
		# (`/^[^[:space:]#]/`), que lê os quatro.
		if line.strip_edges().is_empty() or line.begins_with("#"):
			continue
		if inside and not line.begins_with(" "):
			inside = false
		if inside:
			var m : RegExMatch = RegEx.create_from_string("^  ([a-z0-9_-]+):$").search(line)
			if m != null:
				services.append(m.get_string(1))
	CheckEq(services.size(), 4, "deploy/docker-compose.yml declara 4 serviços")
	Check(services.has("cloudflared"),
		"cloudflared É serviço do compose (serviços: %s)" % [services])
	var coolify : String = _read("res://deploy/COOLIFY.md")
	var stated : String = RegEx.create_from_string("Stack: ([0-9]+) servi").search(coolify).get_string(1) if RegEx.create_from_string("Stack: ([0-9]+) servi").search(coolify) != null else "?"
	CheckEq(stated, str(services.size()),
		"COOLIFY.md diz a contagem de serviços que o arquivo tem")
	Check(coolify.contains("`cloudflared`"),
		"COOLIFY.md nomeia o quarto serviço em vez de omiti-lo")

# --- 4. o default do offsite é o que o gate exige ------------------------------
func _FactOffsiteDefault() -> void:
	var compose : String = _read("res://deploy/docker-compose.yml")
	var matcher : RegExMatch = RegEx.create_from_string(r"SHAMBLETA_OFFSITE_BACKUPS: \$\{SHAMBLETA_OFFSITE_BACKUPS:-([^}]*)\}").search(compose)
	var compose_default : String = matcher.get_string(1) if matcher != null else "<sem default>"
	var checker : String = _read("res://scripts/check_compose.sh")
	var required : String = RegEx.create_from_string(r'offsite == "([^"]+)"').search(checker).get_string(1) if RegEx.create_from_string(r'offsite == "([^"]+)"').search(checker) != null else "<gate não exige>"
	CheckEq(compose_default, required,
		"o default do compose é exatamente o que scripts/check_compose.sh exige")
	Check(not compose_default.is_empty(),
		"o default não é vazio — vazio desliga o push (SQLBackups.PushOffsite sai na 1a linha)")
	var coolify : String = _read("res://deploy/COOLIFY.md")
	Check(coolify.contains("`/data-backups`") and not coolify.contains("SHAMBLETA_OFFSITE_BACKUPS` = vazio"),
		"COOLIFY.md manda deixar /data-backups, não vazio")

# --- 5. o que project.godot registra, e o que a prosa nomeia -------------------
func _FactAutoloads() -> void:
	var names : Array[String] = []
	var inside : bool = false
	for line in _read("res://project.godot").split("\n"):
		if line.begins_with("[autoload]"):
			inside = true
			continue
		if inside and line.begins_with("["):
			inside = false
		if inside:
			var m : RegExMatch = RegEx.create_from_string("^([A-Za-z0-9_]+)=").search(line)
			if m != null:
				names.append(m.get_string(1))
	CheckEq(names.size(), 6, "project.godot [autoload] registra seis nós")
	for wanted in ["Launcher", "Network", "FSM", "Monitoring", "WebPush", "PwaUpdate"]:
		Check(names.has(wanted), "o autoload %s está registrado" % wanted)
	# A prosa: todo nome que setup.md/debugging.md listam como autoload têm que
	# estar no registro, e a contagem afirmada tem que ser a do arquivo.
	var docs_com_contagem : int = 0
	for doc in ["res://docs/development/setup.md", "res://docs/development/debugging.md"]:
		var text : String = _read(doc)
		var stated : RegExMatch = RegEx.create_from_string("(?i)(s[ãa]o \\*{0,1}([a-z0-9]+)\\*{0,1}|os ([a-z0-9]+)) autoloads?").search(text)
		var word : String = ""
		if stated != null:
			word = stated.get_string(2) if not stated.get_string(2).is_empty() else stated.get_string(3)
		var numbers := {"um": 1, "dois": 2, "tres": 3, "três": 3, "quatro": 4, "cinco": 5, "seis": 6, "sete": 7}
		if not word.is_empty():
			docs_com_contagem += 1
			# `numbers.get(word, "?")` devolvia String e ia para `CheckEq` contra um
			# int: GDScript aborta a expressão com `Invalid operands 'String' and
			# 'int'`, a suíte perdia ESTA check sem contá-la como falha, e o
			# `== RESULT:` continuava dizendo `0 failures`. Descoberto pelo
			# `scripts/ci_gate_log.sh` no run de 2026-09-27 — o SCRIPT ERROR estava
			# no log, a contagem não. Palavra que a régua não sabe ler é falha, não
			# é ausência de afirmação.
			Check(numbers.has(word),
				"%s afirma \"%s\" autoloads — esperada uma palavra que esta régua lê (um..sete), atual: %s" % [doc, word, "lida" if numbers.has(word) else "ilegível"])
			if numbers.has(word):
				CheckEq(numbers[word], names.size(),
					"%s diz \"%s\" autoloads e o registro tem %d" % [doc, word, names.size()])
		for listed in RegEx.create_from_string("`([A-Z][A-Za-z0-9]+)`").search_all(text):
			var candidate : String = listed.get_string(1)
			if candidate in ["PwaUpdate", "WebPush", "Launcher", "Network", "FSM", "Monitoring"]:
				Check(names.has(candidate), "%s nomeia %s, que é autoload registrado" % [doc, candidate])
	Check(docs_com_contagem >= 1,
		"pelo menos uma doc afirma quantos autoloads existem — sem afirmação esta régua seria no-op")
	# E os guards que a doc dizia existirem: saíram do código.
	var fsm : String = _code_only(_read("res://sources/launcher/FSM.gd"))
	var network : String = _code_only(_read("res://sources/network/Network.gd"))
	Check(not fsm.contains("Engine.has_singleton"),
		"FSM.gd não tem guard Engine.has_singleton (a doc que o afirmava estava velha)")
	Check(not network.contains("Engine.has_singleton"),
		"Network.gd não tem guard Engine.has_singleton")

# --- 6. o bind que o probe tem que usar ---------------------------------------
func _FactHealthzBind() -> void:
	var metrics : String = _read("res://sources/system/MetricsServer.gd")
	var bind : String = RegEx.create_from_string(r'const BindAddress\s*:\s*String\s*=\s*"([^"]+)"').search(metrics).get_string(1) if RegEx.create_from_string(r'const BindAddress\s*:\s*String\s*=\s*"([^"]+)"').search(metrics) != null else "?"
	var port : String = RegEx.create_from_string(r"const DefaultPort\s*:\s*int\s*=\s*(\d+)").search(metrics).get_string(1) if RegEx.create_from_string(r"const DefaultPort\s*:\s*int\s*=\s*(\d+)").search(metrics) != null else "?"
	CheckEq(bind, "127.0.0.1", "MetricsServer binda IPv4 literal (BindAddress)")
	for doc in ["res://deploy/STAGING.md", "res://deploy/OPS_RUNBOOK.md", "res://deploy/BACKUP_RUNBOOK.md"]:
		Check(not _read(doc).contains("localhost:" + port),
			"%s não manda sonda em localhost:%s (bind é %s)" % [doc, port, bind])

# --- 7. tecla de atalho afirmada é tecla tratada -------------------------------
func _FactHotkeys() -> void:
	var gui : String = _code_only(_read("res://sources/gui/Gui.gd"))
	var handled : Array[String] = []
	for m in RegEx.create_from_string("KEY_F([0-9]+)").search_all(gui):
		handled.append("F" + m.get_string(1))
	CheckEq(handled, ["F12"], "sources/gui/Gui.gd trata exatamente uma tecla F")
	var readme : String = _read("res://README.md")
	Check(readme.contains("F12"), "README.md cita a tecla que existe")
	var positive : RegExMatch = RegEx.create_from_string("(?i)(use|para) `?F1`?[–-]`?F12").search(readme)
	Check(positive == null,
		"README.md não promete faixa F1–F12 (%s)" % ("ainda promete" if positive != null else "ok"))

# --- 8. reconcile tem timer próprio -------------------------------------------
func _FactReconcileTimer() -> void:
	var backups : String = _read("res://sources/sql/SQLBackups.gd")
	var lines : PackedStringArray = backups.split("\n")
	var callAt : int = -1
	for i in lines.size():
		if lines[i].contains("RunReconcileJob()"):
			callAt = i
			break
	Check(callAt > 0, "SQLBackups.gd chama RunReconcileJob()")
	var guard : String = ""
	if callAt > 0:
		for i in range(maxi(0, callAt - 14), callAt):
			var m : RegExMatch = RegEx.create_from_string("SQLCommons\\.([A-Za-z0-9_]*IntervalSec)").search(lines[i])
			if m != null:
				guard = m.get_string(1)
	CheckEq(guard, "MetaJobIntervalSec",
		"o reconcile é guardado pelo timer próprio, não pelo do backup")
	var coolify : String = _read("res://deploy/COOLIFY.md")
	var row : String = ""
	for line in coolify.split("\n"):
		if line.contains("Reconciliação"):
			row = line
	Check(not row.to_lower().contains("pós-backup") and not row.to_lower().contains("depois do backup"),
		"COOLIFY.md não descreve o reconcile como \"diária pós-backup\" (%s)" % row)

# --- 9. o gate do compose já está ligado na CI --------------------------------
func _FactComposeGateIsWired() -> void:
	var workflow : String = _read("res://.github/workflows/godot-ci.yml")
	Check(workflow.contains("scripts/test.sh structure"),
		"a CI chama scripts/test.sh structure (o job existe e bloqueia)")
	var testsh : String = _read("res://scripts/test.sh")
	var body : String = ""
	var inside : bool = false
	for line in testsh.split("\n"):
		if line.begins_with("structure_gates()"):
			inside = true
		elif inside and line.strip_edges() == "}":
			inside = false
		if inside:
			body += line + "\n"
	Check(body.contains("check_compose.sh"),
		"structure_gates() roda check_compose.sh (é isto que a pendência falsa negava)")
	Check(not _read("res://deploy/OPS_RUNBOOK.md").contains("falta só a linha"),
		"OPS_RUNBOOK.md não lista o job do compose como pendência")

# --- 10. o grupo de log que o código emite ------------------------------------
func _FactLogGroups() -> void:
	var server : String = _read("res://sources/network/server/Server.gd")
	var group : String = "?"
	for line in server.split("\n"):
		if line.contains("TLS terminated upstream"):
			var m : RegExMatch = RegEx.create_from_string("Print(Log|Info)\\(\"([A-Za-z]+)\"").search(line)
			if m != null:
				group = m.get_string(2)
			break
	CheckEq(group, "Server", "a linha de proxy-TLS sai no grupo que o Util.PrintLog declara")
	for doc in ["res://deploy/COOLIFY.md", "res://deploy/TLS.md"]:
		var text : String = _read(doc)
		Check(text.contains("[Server] TLS terminated upstream"),
			"%s cita o log com o grupo certo" % doc)
		Check(not text.contains("[TLS] TLS terminated"),
			"%s não manda grepar um [TLS] que nenhum código emite" % doc)

# --- 11. o corpo de erro que o smoke test espera ------------------------------
func _FactCompanionErrorLiteral() -> void:
	var companion : String = _read("res://companion/server.py")
	Check(companion.contains('"missing_token"'),
		"companion/server.py devolve o literal missing_token")
	Check(not companion.contains('"missing auth_token"'),
		"não existe a frase \"missing auth_token\" no companion")
	var coolify : String = _read("res://deploy/COOLIFY.md")
	Check(coolify.contains('{"error": "missing_token"}'),
		"COOLIFY.md ensina a reconhecer o corpo real do 401")
	Check(not coolify.contains("missing auth_token"),
		"COOLIFY.md não cita corpo que o código não devolve")

func _finish():
	# Teardown: junta qualquer preload ainda em voo ANTES do quit(), senão o join
	# cai dentro de Launcher._exit_tree e o processo morre com os checks verdes.
	if dbScript != null and (dbScript.get("preloadPaths") as PackedStringArray).size() > 0:
		print("WARN: preload do DB ainda em voo no fim — drenando antes de quit()")
		dbScript.call("DrainPendingPreloads")
	Check(checks >= ExpectedChecks, "o harness rodou inteiro (>= %d checks; saiu %d)" % [ExpectedChecks, checks])
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)
