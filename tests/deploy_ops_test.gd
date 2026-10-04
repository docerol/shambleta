extends SceneTree

# Gate de deploy conferido contra o MOTOR, não contra o doc.
#
# Uso:  godot --headless --path . -s tests/deploy_ops_test.gd
#       (`harnesses_extra()` (`scripts/test.sh:@harnesses_extra`) descobre
#        `tests/*_test.gd` sozinho e `harness_marker()` (`scripts/test.sh:@harness_marker`)
#        lê o marcador da própria linha `== RESULT:` abaixo — nada precisa ser
#        acrescentado em arquivo de outro dono. Os dois números são conferidos pela
#        régua de identidade de ponteiro (seção 23 de `scripts/check_doc_drift.sh`),
#        não copiados de memória.)
#
# O que só este harness sabe responder é o caminho absoluto que o Godot produz
# para `user://`. Todo o resto do deploy depende dele: `deploy/server/Dockerfile`
# declara `ENV HOME=/data`, o compose monta `game-data:/data`, e
# `deploy/companion/Dockerfile` abre `/data/.local/share/Shambleta/live.db` — se o
# layout for o do Godot 3 (`godot/app_userdata/`) ou se `XDG_DATA_HOME` aparecer
# na imagem, o companion abre um banco que não é o do jogo e cada compra paga cai
# numa fila que ninguém consome. Grep nenhum prova isso; a engine, sim.
#
# Nada de `load()` de scripts do projeto aqui: o boot já compila os autoloads e
# refs estáticas forçam Parse Error de arquivo alheio no log — e é exatamente o
# que scripts/ci_gate_log.sh:24 rejeita.

var checks: int = 0
var failures: int = 0

func Check(condition: bool, message: String) -> bool:
	checks += 1
	if condition:
		print("  [PASS] %s" % message)
		return true
	failures += 1
	print("  [FAIL] %s" % message)
	return false

func _Finish() -> void:
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

func _read(path: String) -> String:
	var fa: FileAccess = FileAccess.open(path, FileAccess.READ)
	if fa == null:
		push_warning("deploy_ops_test: não li %s" % path)
		return ""
	var text: String = fa.get_as_text()
	fa.close()
	return text

func _regex(text: String, pattern: String) -> String:
	var rx: RegEx = RegEx.create_from_string(pattern)
	var m: RegExMatch = rx.search(text)
	return m.get_string(1) if m != null else ""

func _initialize() -> void:
	print("== Deploy ops (engine) ==")

	# --- 1. o layout real de user:// ------------------------------------------
	var user_dir: String = ProjectSettings.globalize_path("user://")
	var home: String = OS.get_environment("HOME")
	var xdg: String = OS.get_environment("XDG_DATA_HOME")
	var app_name: String = str(ProjectSettings.get_setting("application/config/custom_user_dir_name", ""))
	var uses_custom: bool = bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false))
	# A regra, nas duas pernas: com XDG_DATA_HOME definido ele manda; sem ele, o
	# fallback é $HOME/.local/share (não $HOME/godot/app_userdata, do Godot 3).
	var expected_root: String = (xdg if not xdg.is_empty() else home + "/.local/share")
	var expected_user: String = expected_root.path_join(app_name if uses_custom else "Godot") + "/"
	Check(user_dir == expected_user,
		"user:// = %s (regra XDG/HOME; esperado %s)" % [user_dir, expected_user])
	Check(not user_dir.contains("godot/app_userdata"),
		"o layout NÃO é o do Godot 3 (godot/app_userdata/) — user://=%s" % user_dir)

	# --- 2. a perna do container: HOME=/data, sem XDG_DATA_HOME ---------------
	var compose: String = _read("res://deploy/docker-compose.yml")
	var server_dockerfile: String = _read("res://deploy/server/Dockerfile")
	var companion_dockerfile: String = _read("res://deploy/companion/Dockerfile")
	var sql_commons: String = _read("res://sources/sql/SQLCommons.gd")

	var env_home: String = _regex(server_dockerfile, r'ENV\s+HOME=(\S+)')
	Check(env_home == "/data",
		"deploy/server/Dockerfile define ENV HOME=/data (encontrado \"%s\")" % env_home)
	Check(not server_dockerfile.contains("XDG_DATA_HOME"),
		"deploy/server/Dockerfile não define XDG_DATA_HOME (definir mudaria o root de user://)")
	var live_db: String = _regex(sql_commons, r'const\s+DBName\s*:\s*String\s*=\s*"([^"]+)"')
	Check(live_db == "live.db", "SQLCommons.DBName = live.db (encontrado \"%s\")" % live_db)
	# Substituindo a perna HOME da regra medida acima pelo /data do container:
	var container_db: String = (user_dir.replace(expected_root + "/", env_home + "/.local/share/")) + live_db
	var companion_db: String = _regex(companion_dockerfile, r'"--db",\s*"([^"]+)"')
	Check(companion_db == container_db,
		"o --db do companion (%s) É o live.db que o game abre (%s)" % [companion_db, container_db])

	# --- 2b. o fechamento de imports do sender VAPID tem que estar NA IMAGEM ----
	# companion/server.py:877 faz `import push_vapid` por nome nu, na mesma pasta de
	# companion/server.py; push_vapid importa push_common/push_p256/push_aesgcm, que se
	# importam entre si. `load_push_vapid()` só devolve o módulo se TODOS estiverem
	# no WORKDIR — falta um, ele devolve None e o sender levanta NotImplementedError
	# MESMO com chave VAPID configurada: entrega morta na origem do deploy, não do
	# runtime. A régua DERIVA o fechamento transitivo dos `import`/`from push_*` e
	# exige que o Dockerfile COPY cada arquivo — assim um quinto módulo novo sem
	# cópia quebra o gate, e não o contrário.
	var import_re: RegEx = RegEx.create_from_string(r'(?:import|from)\s+(push_[a-z0-9_]+)')
	var comp_src: String = _read("res://companion/server.py")
	var push_closure: Dictionary = {}
	var frontier: Array[String] = []
	for m in import_re.search_all(comp_src):
		frontier.append(m.get_string(1))
	while not frontier.is_empty():
		var mod: String = String(frontier.pop_back())
		if push_closure.has(mod):
			continue
		push_closure[mod] = true
		var mod_src: String = _read("res://companion/%s.py" % mod)
		for c in import_re.search_all(mod_src):
			if not push_closure.has(c.get_string(1)):
				frontier.append(c.get_string(1))
	var mods: Array = push_closure.keys()
	mods.sort()
	Check(not mods.is_empty(),
		"o companion importa o sender push (fechamento derivado: %s)" % [mods])
	var not_copied: Array[String] = []
	for mod in mods:
		if not companion_dockerfile.contains(String(mod) + ".py"):
			not_copied.append(String(mod))
	Check(not_copied.is_empty(),
		"deploy/companion/Dockerfile COPY cada módulo do fechamento push; faltando na imagem: %s" % [not_copied])

	# --- 3. estado e backup no mesmo lugar (e o segundo volume, separado) -----
	var backup_dir: String = _regex(sql_commons, r'const\s+BackupPath\s*:\s*String\s*=\s*"([^"]+)"')
	Check(not backup_dir.is_empty() and user_dir.length() > 0,
		"SQLCommons.BackupPath = \"%s\" — caminho relativo a user://, logo dentro do volume /data" % backup_dir)
	Check(ProjectSettings.globalize_path("user://" + backup_dir).begins_with(user_dir),
		"backup globalizado (%s) está DENTRO de user:// (%s)" % [ProjectSettings.globalize_path("user://" + backup_dir), user_dir])
	var mounts: RegEx = RegEx.create_from_string(r'-\s+([A-Za-z0-9_.-]+):(/[A-Za-z0-9_.-]+)')
	var found_targets: Array[String] = []
	var by_target: Dictionary = {}
	for mm in mounts.search_all(compose):
		found_targets.append(mm.get_string(2))
		by_target[mm.get_string(2)] = mm.get_string(1)
	Check(found_targets.has("/data"), "compose monta /data (encontrados: %s)" % [found_targets])
	Check(found_targets.has("/data-backups"),
		"compose monta /data-backups em volume PRÓPRIO — sem isso o histórico morre junto do banco")
	Check(by_target.get("/data") != by_target.get("/data-backups"),
		"volume do backup (%s) != volume do banco (%s)" % [by_target.get("/data-backups"), by_target.get("/data")])

	# --- 4. healthcheck: a porta e o bind que o compose probeia são os do código
	var metrics: String = _read("res://sources/system/MetricsServer.gd")
	var metrics_port: String = _regex(metrics, r'const\s+DefaultPort\s*:\s*int\s*=\s*(\d+)')
	var metrics_bind: String = _regex(metrics, r'const\s+BindAddress\s*:\s*String\s*=\s*"([^"]+)"')
	var hc_test: String = _regex(compose, r'test:\s*\[([^\]]*healthz[^\]]*)\]')
	Check(hc_test.contains(":" + metrics_port),
		"o /healthz do compose usa a porta declarada no código (%s); test=%s" % [metrics_port, hc_test])
	Check(hc_test.contains(metrics_bind),
		"e usa o bind real do MetricsServer (%s) — `localhost` com ::1 em /etc/hosts erra o primeiro try" % metrics_bind)

	# --- 5. stop_grace_period >= drain do canary + join do worker -------------
	var canary: String = _read("res://sources/world/ShutdownCanary.gd")
	var drain: float = 0.0
	var delays: String = _regex(canary, r'shutdownDelays[^=]*=\s*\[([^\]]*)\]')
	for d in delays.split(","):
		drain += float(d.strip_edges()) if d.strip_edges().is_valid_float() else 0.0
	var join: int = int(_regex(sql_commons, r'BackupCheckIntervalSec\s*:\s*int\s*=\s*(\d+)'))
	var grace_raw: String = _regex(compose, r'stop_grace_period:\s*(\d+)s')
	var grace: int = int(grace_raw)
	Check(grace_raw.is_valid_int() and grace >= drain + float(join),
		"stop_grace_period=%ss cobre drain (%.0fs) + join do worker de backup (%ds)" % [grace_raw, drain, join])

	# --- 6. alerta: toda métrica citada por regra existe no corpo do /metrics ---
	# AUDITORIA §18 pedia "divergência de reconcile não gera métrica nem sinal".
	# Os dois halves são conferidos aqui, e o segundo é o que costuma faltar: uma
	# regra apontando para um nome que o server nunca emite não é alerta quebrado,
	# é alerta ABSURDO — dispara nunca, e ninguém descobre porque a ausência de
	# incêndio é indistinguível de não ter fogo.
	var alerts: String = _read("res://deploy/alerts.rules.yml")
	Check(not alerts.is_empty(), "deploy/alerts.rules.yml existe e foi lido")
	var emitted: Dictionary = {}
	for e in RegEx.create_from_string(r'body \+= "(shambleta_[a-z0-9_]+) ').search_all(metrics):
		emitted[e.get_string(1)] = true
	Check(emitted.size() >= 8,
		"o /metrics emite %d séries: %s" % [emitted.size(), emitted.keys()])
	var referenced: Dictionary = {}
	for r in RegEx.create_from_string(r'(shambleta_[a-z0-9_]+)').search_all(alerts):
		referenced[r.get_string(1)] = true
	Check(referenced.has("shambleta_reconcile_divergences"),
		"a divergência do reconcile é citada por uma regra (não mora só em coluna de tabela)")
	Check(referenced.has("shambleta_reconcile_age_seconds"),
		"há regra sobre a IDADE do reconcile — sem ela, \"0 divergências\" de um job parado lê-se verde")
	# WorkOrder #185: o censo de oferta entrou no `/metrics` com as duas pernas que a
	# auditoria do reconcile já exigia — o número E a idade dele. As duas checks abaixo
	# mordem na ausência da regra correspondente: métrica sem regra é dashboard que
	# ninguém abre às 3h, e métrica com idade sem regra é job morto lendo verde.
	Check(referenced.has("shambleta_supply_census_gold_unattested"),
		"a carteira acima do atesto de ledger é citada por uma regra (#185)")
	Check(referenced.has("shambleta_supply_census_age_seconds"),
		"há regra sobre a IDADE do censo de oferta — sem ela, zeros de um job que nunca rodou lê-se verde")
	Check(referenced.has("shambleta_supply_census_untracked_gold"),
		"o flush que desceu sem família declarada é citado por uma regra (#185)")
	for name in referenced:
		Check(emitted.has(name),
			"a regra cita %s, e o server emite %s" % [name, "sim" if emitted.has(name) else "NÃO"])
	# Os três nomes que a auditoria pediu têm que estar no corpo, não só no yaml.
	for name in ["shambleta_reconcile_divergences", "shambleta_reconcile_age_seconds", "shambleta_fraud_flags_open"]:
		Check(emitted.has(name), "o /metrics emite %s" % name)

	_Finish()
