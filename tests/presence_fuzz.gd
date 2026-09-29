extends SceneTree

# presence_fuzz.gd — harness da presença durável (AUDITORIA_2026-09-27 §12): a
# migration 057 criou `presence_session` e escreveu no próprio cabeçalho que
# `Presence.Prune` poda, que o custo marginal é limitado pelo heartbeat e que três
# planos de `EXPLAIN QUERY PLAN` existem. Comentário de schema não é evidência: este
# arquivo EXECUTA cada uma dessas frases e imprime o número que ela mede.
#
# Uso:    ./scripts/test.sh fixation   (descoberto pelo glob `tests/*_fuzz.gd`)
# Saída:  "== PRESENCE: <n> checks, <m> failures =="   (exit code = <m>)
#
# O que ele responde, na ordem:
#   1) VERDADE DO TEXTO — os símbolos que `057_presence_durable.sql` nomeia no
#      cabeçalho têm que existir no fonte. É a régua que impede a próxima migration
#      de prometer comportamento que ninguém implementa (foi exatamente o estado em
#      que este arquivo nasceu: a tabela existia, o leitor dela não).
#   2) ONDE A PROMESSA VIRA ESCRITA — os ganchos têm que estar nos fontes que rodam
#      em produção (`Server.gd`, `World.gd`, `SQL.gd`) e `presence_session` tem que
#      ter UM único módulo SQL na árvore. Um harness `-s` nunca executa
#      `ConnectCharacter`, então sem esta suíte a tabela continuaria verde sem
#      nenhum escritor.
#   3) OS TRÊS PLANOS: prune em `idx_presence_seen`, cauda por servidor em
#      `idx_presence_server`, nick em `idx_presence_nick` — SEARCH, nunca SCAN, e no
#      TEXTO de SQL extraído de `sources/network/server/Presence.gd`, não numa cópia
#      deste harness (precedente: tests/scale_test.gd, tests/read_pool_test.gd).
#   4) O UPSERT: duas batidas, uma linha, `connected_at` da primeira, `last_seen_at`
#      da segunda.
#   5) O TTL nas duas direções do relógio, com a contagem exata do que saiu.
#   6) O FANTASMA: linha de processo morto sai por `ReclaimServer` e, de forma
#      independente, sai por TTL.
#   7) A CLAIM LITERAL da migration: DOIS `SQLService` sobre o MESMO arquivo, e o
#      segundo lendo o que o primeiro escreveu — medido, não afirmado em prosa.
#   8) O CUSTO: 1000 personagens, µs medidos e UMA statement por tick contada em
#      `SQL.QueryCount()`.
#   9) A CONCORDÂNCIA das duas metades: `OnlineList.byNick` (quente) e
#      `Presence.IsOnlineDurable` (durável) sobre o mesmo nick no mesmo instante.
#
# A mesa é um arquivo em /tmp criado para este run (`_FreshScratch`, o mesmo critério
# de tests/scale_test.gd: `DirAccess.make_dir_absolute` é o teste atômico que deixa
# duas execuções coexistirem) e um SEGUNDO `SQLService` sobre ela. O `testing.db` do
# sandbox não recebe uma linha daqui: presença é tabela de estado miúda, e um harness
# que acumula linha a cada execução do gate vira relógio de areia.
var ScratchRoot : String = _FreshScratch("shambleta-presence")
var ScratchDB : String = ScratchRoot + "/presence.db"

const PresenceModulePath : String	= "res://sources/network/server/Presence.gd"
const MigrationPath : String		= "res://data/conf/migrations/057_presence_durable.sql"
const HarnessPath : String			= "res://tests/presence_fuzz.gd"

# Os três fontes onde a presença durável tem que ser escrita, e as digital do SQL
# que só um módulo da árvore pode carregar.
const ServerSourcePath : String		= "res://sources/network/server/Server.gd"
const WorldSourcePath : String		= "res://sources/world/World.gd"
const SqlSourcePath : String		= "res://sources/sql/SQL.gd"
const SourcesRootPath : String		= "res://sources"
const WriterFingerprints : PackedStringArray = [
	"INTO presence_session", "UPDATE presence_session", "FROM presence_session"]

# Mesa do teste de custo: 1000 personagens é a vizinhança do teto de 5–10k CCU
# declarado no §12, por um servidor.
const CostChars : int				= 1000
const SeedLive : int				= 40
const SeedExpired : int				= 6
const GhostServer : String			= "ghost-node-que-morreu"

# Orçamento do tick de heartbeat. Medido NESTE arquivo nesta máquina (AMD Ryzen 5
# 5500, Godot 4.7.2.stable.arch_linux, a partir do fonte, WAL + synchronous=NORMAL):
# 1.463 a 1.664 µs em seis execuções do run completo (mediana ~1.48), para 1.000
# personagens no `server_id` deste processo, com UMA statement. O budget abaixo é
# ~5× o pior medido — folga para máquina mais lenta e para o jitter de fsync, não
# chute. Cruzá-lo é regression de caminho quente, e a régua foi conferida por
# contra-prova: com `Touch` reescrito de propósito no modo por-personagem que o
# cabeçalho da migration 057 diz que NÃO é o desenho, o mesmo tick mediu 27.732 µs
# em 1.001 statements e as três checks abaixo caíram juntas. É a frase "o custo
# marginal de presença é contado e limitado pelo heartbeat" em forma de gate.
const BudgetHeartbeatTickUs : int	= 8000

var checks : int = 0
var failures : int = 0
var sql = null
var reader = null
var serverID : String = Presence.ServerID()

static func _FreshScratch(prefix : String) -> String:
	var base : String = OS.get_temp_dir().rstrip("/")
	for attempt in 64:
		var cand : String = "%s/%s-%d-%d" % [base, prefix, Time.get_unix_time_from_system(), randi()]
		if DirAccess.make_dir_absolute(cand) == OK:
			return cand
	return ""

func Note(text : String) -> void:
	print("  . " + text)

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func CheckEq(actual : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	# Tipo diferente não compara: ver tests/scale_test.gd — check abortada não era
	# contada como falha e a linha de resultado continuava limpa.
	var same : bool = typeof(actual) == typeof(expected) and actual == expected
	if not same:
		failures += 1
		print("  [FAIL] " + label + " (esperado " + str(expected) + ", atual " + str(actual) + ")")
		return false
	return true

func Finish(dbs : GDScript) -> void:
	if dbs != null:
		dbs.call("DrainPendingPreloads")
	CloseTable()
	for suffix in ["", "-wal", "-shm"]:
		DirAccess.remove_absolute(ScratchDB + suffix)
	DirAccess.remove_absolute(ScratchRoot)
	print("== PRESENCE: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

func OneInt(query : String, params : Array = []) -> int:
	var rows : Array = sql.QueryBindings(query, params)
	return int(rows[0].values()[0]) if not rows.is_empty() else -1

func PlanDetail(query : String, params : Array) -> String:
	var rows : Array = sql.QueryBindings("EXPLAIN QUERY PLAN " + query, params)
	var joined : String = ""
	for row in rows:
		joined += str(row.get("detail", "")) + " | "
	return joined

# O TEXTO que roda em produção, extraído do fonte do módulo — não uma cópia digitada
# aqui. É a diferença entre "o índice que a migration criou é usado" e "alguma query
# parecida com a de presença usa um índice".
func FirstLiteral(functionSignature : String) -> String:
	var file : FileAccess = FileAccess.open(PresenceModulePath, FileAccess.READ)
	if file == null:
		return ""
	var text : String = String(file.get_as_text())
	file.close()
	var at : int = text.find(functionSignature)
	if at < 0:
		return ""
	var nextFunc : int = text.find("\nstatic func ", at + functionSignature.length())
	var chunk : String = text.substr(at) if nextFunc < 0 else text.substr(at, nextFunc - at)
	var open : int = chunk.find("\"")
	if open < 0:
		return ""
	var close : int = chunk.find("\"", open + 1)
	return "" if close < 0 else chunk.substr(open + 1, close - open - 1)

# Varredura da árvore, mesma forma de tests/repo_layout_test.gd: `list_dir_begin`
# + `get_next`, porque `DirAccess.get_files()` não existe no Godot 4.
func ListDir(path : String, wantDirs : bool) -> Array[String]:
	var out : Array[String] = []
	var dir : DirAccess = DirAccess.open(path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name : String = dir.get_next()
	while name != "":
		if name != "." and name != ".." and dir.current_is_dir() == wantDirs:
			out.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return out

func WalkGD(path : String, out : Array[String]) -> void:
	for name in ListDir(path, false):
		if name.get_extension() == "gd":
			out.append(path + "/" + name)
	for sub in ListDir(path, true):
		WalkGD(path + "/" + sub, out)

func _initialize():
	print("== Presenca duravel (AUDITORIA 2026-09-27 §12): o que a migration 057 promete, medida ==")
	var dbs : GDScript = load("res://sources/db/DB.gd")
	if not Check(ScratchRoot != "", "este run tem diretório privativo em /tmp (%s)" % ScratchRoot):
		Finish(dbs)
		return
	sql = OpenHandle("writer")
	if not Check(sql != null, "SQLService da mesa abre %s com as migrations reais" % ScratchDB):
		Finish(dbs)
		return

	SuiteTextTruth()
	SuiteWiring()
	SuitePlans()
	SuiteUpsert()
	SuiteTTL()
	SuiteGhost()
	SuiteTwoProcesses()
	SuiteHeartbeatCost()
	SuiteMemoryAgreement()
	Finish(dbs)

# ---------------------------------------------------------------------------
# mesa: template + migrations reais, em arquivo próprio
# ---------------------------------------------------------------------------
func OpenHandle(role : String):
	if role == "writer":
		DirAccess.make_dir_recursive_absolute(ScratchRoot)
		for suffix in ["", "-wal", "-shm"]:
			DirAccess.remove_absolute(ScratchDB + suffix)
		var commons : GDScript = load("res://sources/sql/SQLCommons.gd")
		if not bool(commons.call("CopyDatabase", ScratchDB)):
			Note("mesa nao nasceu do template")
			return null
	# Um handle novo sobre o MESMO arquivo: é assim que o segundo processo do §12
	# chega, e é por isso que `reader` abaixo não herda o `db` do writer.
	var handle : SQLite = SQLite.new()
	handle.path = ScratchDB
	handle.verbosity_level = SQLite.QUIET
	if not handle.open_db():
		Note("%s nao abriu em %s: %s" % [role, ScratchDB, String(handle.error_message)])
		return null
	var node = load("res://sources/sql/SQL.gd").new()
	node.db = handle
	node.Query("PRAGMA journal_mode=WAL;")
	node.Query("PRAGMA busy_timeout=5000;")
	# Só o writer mexe em schema: quem altera tabela é o handle de escrita, e o
	# leitor que abrisse no meio do patch veria o schema anterior.
	if role == "writer":
		node.ApplyMigrations()
	return node

func CloseTable() -> void:
	for handle in [reader, sql]:
		if handle != null:
			handle.db.close_db()
			handle.free()
	sql = null
	reader = null

func CountRows() -> int:
	return OneInt("SELECT COUNT(*) AS n FROM presence_session;", [])

func ClearCorpus() -> void:
	sql.ExecuteBindings("DELETE FROM presence_session;", [])

func Seed(nick : String, charID : int, seenAt : int, server : String = "", zoneID : int = 1) -> bool:
	return Presence.Report(sql, charID, 900000 + charID, nick, zoneID, seenAt, server)

# Corpus do tamanho do problema: plano de índice com tabela vazia não é plano, é
# palpite do planejador sobre nada.
func SeedCorpus(now : int) -> void:
	ClearCorpus()
	for i in SeedLive:
		Seed("pres_%d" % i, 776100 + i, now - (i % maxi(Presence.TTLSec(), 1)))
	for i in SeedExpired:
		Seed("pres_old_%d" % i, 776200 + i, now - Presence.TTLSec() - 10 - i)

# ---------------------------------------------------------------------------
# 1) verdade do texto da migration
# ---------------------------------------------------------------------------
func SuiteTextTruth() -> void:
	print("-- 1) o que o cabecalho da migration 057 nomeia --")
	var migration : String = FileAccess.get_file_as_string(MigrationPath)
	if not Check(migration != "", "migration 057 lee de %s" % MigrationPath):
		return
	var module : String = FileAccess.get_file_as_string(PresenceModulePath)
	Check(module != "", "Presence.gd existe e lee (%s)" % PresenceModulePath)
	Check(FileAccess.file_exists(HarnessPath), "o harness que a migration nomeia existe (tests/presence_fuzz.gd)")

	# Símbolos nomeados no comentário, extraídos e não listados à mão: se a próxima
	# migration prometer `Presence.AlgoNovo`, esta suíte passa a exigir o algo novo.
	# `[A-Z]` no começo é o que separa a promessa do caminho de arquivo: o cabeçalho
	# cita `sources/network/server/Presence.gd`, e "gd" não é símbolo de nada.
	var rx : RegEx = RegEx.new()
	rx.compile("Presence\\.([A-Z][A-Za-z0-9_]*)")
	var promises : Array[String] = []
	for m in rx.search_all(migration):
		var symbol : String = String(m.get_string(1))
		if not promises.has(symbol):
			promises.append(symbol)
	CheckEq(promises.size() >= 2, true, "o cabecalho nomeia ao menos dois simbolos de Presence (%s)" % ", ".join(promises))
	for symbol in promises:
		Check(module.find("static func " + symbol + "(") >= 0,
			"Presence.%s prometido em 057 existe como func em Presence.gd" % symbol)
	Check(migration.contains("tests/presence_fuzz.gd"), "a migration aponta para este harness pelo caminho")
	Check(migration.contains("sources/network/server/Presence.gd"), "a migration aponta para o modulo pelo caminho")

	CheckEq(OneInt("SELECT COUNT(*) AS n FROM sqlite_master WHERE name = ? AND type = 'table';", ["presence_session"]), 1,
		"tabela presence_session criada pela migration 057")
	for index in ["idx_presence_seen", "idx_presence_server", "idx_presence_nick"]:
		CheckEq(OneInt("SELECT COUNT(*) AS n FROM sqlite_master WHERE name = ? AND type = 'index';", [index]), 1,
			"indice %s criado pela migration 057" % index)

# ---------------------------------------------------------------------------
# 2) onde a promessa vira escrita
# ---------------------------------------------------------------------------
# Este harness roda sem `--server`, então `Server.ConnectCharacter` nunca é
# executado daqui: a régua textual é o que impede a metade durável de voltar ao
# estado em que a migration 057 a deixou — tabela, índices e planos perfeitos, e
# nenhum caminho de código que os escreva. O `load` abaixo é o passo seguinte:
# carrega no runtime, depois dos autoloads registrados, e prova que o fonte do
# gancho compila junto com Presence (referência ESTÁTICA do harness a esses
# fontes não compila, e é por isso que a metade em memória vem por `load` no item 9).
func SuiteWiring() -> void:
	print("-- 2) onde a presenca duravel e escrita --")
	for path in [ServerSourcePath, WorldSourcePath, SqlSourcePath]:
		var module : GDScript = load(path)
		Check(module != null and module.can_instantiate(), "%s compila no processo que roda Presence" % path)

	var serverText : String = FileAccess.get_file_as_string(ServerSourcePath)
	CheckEq(serverText.count("Presence.Report("), 2,
		"Server.gd reporta no login e na mudanca de zona (connect + SetFarmZone)")
	CheckEq(serverText.count("Presence.Forget("), 1, "Server.gd esquece no DisconnectCharacter")
	var worldText : String = FileAccess.get_file_as_string(WorldSourcePath)
	CheckEq(worldText.count("Presence.Tick("), 1, "World.gd chama o tick uma vez, no bloco de um segundo")
	# O tick tem que herdar o relógio que já existe: um cronômetro próprio seria
	# segundo heartbeat accumulating invisível para o resto do mundo.
	Check(worldText.contains("Presence.Tick(Launcher.SQL, _autoIdleAccum"),
		"o tick reusa o acumulador de um segundo de World._process, nao um timer novo")
	var sqlText : String = FileAccess.get_file_as_string(SqlSourcePath)
	CheckEq(sqlText.count("Presence.ReclaimServer("), 1,
		"SQL.gd reclama o server_id no boot, no mesmo ponto da expiracao de tokens")

	# Escrita única: as frases SQL da tabela só podem viver em Presence.gd. É a
	# cláusula "continua sendo um escritor só" de deploy/SCALING.md em forma de gate —
	# se alguém colar um DELETE de presença num serviço qualquer, esta check pega.
	var writers : Array[String] = []
	var files : Array[String] = []
	WalkGD(SourcesRootPath, files)
	Check(not files.is_empty(), "a varredura de %s encontrou fontes (%d)" % [SourcesRootPath, files.size()])
	for file in files:
		var body : String = FileAccess.get_file_as_string(file)
		for fingerprint in WriterFingerprints:
			if body.contains(fingerprint):
				if not writers.has(file):
					writers.append(file)
				break
	CheckEq(writers.size(), 1, "um unico modulo SQL fala com presence_session (%s)" % ", ".join(writers))
	CheckEq(writers.has(PresenceModulePath), true, "o modulo que fala com a tabela e Presence.gd")

# ---------------------------------------------------------------------------
# 3) os três planos prometidos
# ---------------------------------------------------------------------------
func SuitePlans() -> void:
	print("-- 3) EXPLAIN QUERY PLAN dos tres indices prometidos --")
	var now : int = int(Time.get_unix_time_from_system())
	SeedCorpus(now)
	var cases : Array[Dictionary] = [
		{"label": "Prune", "signature": "static func Prune(", "index": "idx_presence_seen",
			"params": [now - Presence.TTLSec()]},
		{"label": "QueryOnline", "signature": "static func QueryOnline(", "index": "idx_presence_server",
			"params": [serverID, now - Presence.TTLSec()]},
		{"label": "IsOnlineDurable", "signature": "static func IsOnlineDurable(", "index": "idx_presence_nick",
			"params": ["pres_1", now - Presence.TTLSec()]},
	]
	for entry in cases:
		var label : String = String(entry["label"])
		var statement : String = FirstLiteral(String(entry["signature"]))
		if not Check(statement.contains("presence_session"), "%s: statement extraido de Presence.gd (%s)" % [label, statement]):
			continue
		var plan : String = PlanDetail(statement, Array(entry["params"]))
		Note("%s plano: %s" % [label, plan])
		Check(plan.contains(String(entry["index"])), "%s usa %s (promessa de 057)" % [label, String(entry["index"])])
		Check(plan.contains("SEARCH"), "%s e SEARCH, nao SCAN (%s)" % [label, plan])

# ---------------------------------------------------------------------------
# 4) UPSERT de uma statement por personagem
# ---------------------------------------------------------------------------
func SuiteUpsert() -> void:
	print("-- 4) upsert de uma statement por personagem --")
	var now : int = int(Time.get_unix_time_from_system())
	var charID : int = 777001
	Check(Presence.Forget(sql, charID), "mesa limpa do personagem do teste")
	var first : int = now - 500
	Check(Seed("upsert_nick", charID, first), "primeira batida (conectou em %d)" % first)
	Check(Seed("upsert_nick_renomeado", charID, now), "segunda batida (mesmo char_id, outro apelido)")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session WHERE char_id = ?;", [charID]), 1,
		"duas batidas, uma linha (ON CONFLICT na PK char_id)")
	CheckEq(OneInt("SELECT connected_at FROM presence_session WHERE char_id = ?;", [charID]), first,
		"connected_at ficou da primeira insercao")
	CheckEq(OneInt("SELECT last_seen_at FROM presence_session WHERE char_id = ?;", [charID]), now,
		"last_seen_at avancou para a segunda batida")
	CheckEq(OneInt("SELECT zone_id FROM presence_session WHERE char_id = ?;", [charID]), 1,
		"zone_id reescrito pela clausula DO UPDATE")
	Check(Presence.Forget(sql, charID), "Forget devolve sucesso")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session WHERE char_id = ?;", [charID]), 0,
		"Forget tira a linha (desconexao limpa nao deixa rastro)")

# ---------------------------------------------------------------------------
# 5) TTL nas duas direções do relógio
# ---------------------------------------------------------------------------
func SuiteTTL() -> void:
	print("-- 5) TTL: mover o relogio nos dois sentidos --")
	var now : int = int(Time.get_unix_time_from_system())
	var ttl : int = Presence.TTLSec()
	CheckEq(ttl, Presence.HeartbeatSec() * 3, "TTL e tres batidas do heartbeat (%ds)" % ttl)
	ClearCorpus()
	# Vivos e vencidos misturados: a contagem do que sai tem que ser exata — uma
	# linha a mais apaga gente online, uma a menos deixa fantasma.
	for i in SeedLive:
		Seed("live_%d" % i, 777100 + i, now - (i % ttl))
	for i in SeedExpired:
		Seed("old_%d" % i, 777200 + i, now - ttl - 10 - i)
	CheckEq(CountRows(), SeedLive + SeedExpired, "corpus semeado (%d vivos + %d vencidos)" % [SeedLive, SeedExpired])

	Check(Presence.Prune(sql, now - (2 * ttl), ttl), "prune com o relogio ATRAS do corpus")
	CheckEq(CountRows(), SeedLive + SeedExpired, "relogio atrasado nao poda nada (sentido da desigualdade)")
	Check(Presence.Prune(sql, now, ttl), "prune com o relogio de agora")
	CheckEq(CountRows(), SeedLive, "sairam exatamente os %d vencidos" % SeedExpired)
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session WHERE nick LIKE 'old_%';", []), 0,
		"nenhum vencido sobrou")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session WHERE nick LIKE 'live_%';", []), SeedLive,
		"nenhum vivo saiu na poda")

	# A fronteira em si: `ttl` segundos de atraso ainda é online, um a mais não é.
	Seed("edge_exato", 777301, now - ttl)
	Seed("edge_um_a_mais", 777302, now - ttl - 1)
	Check(Presence.IsOnlineDurable(sql, "edge_exato", now), "linha com o ttl exatos ainda conta como online")
	Check(not Presence.IsOnlineDurable(sql, "edge_um_a_mais", now), "um segundo depois do ttl nao conta")
	Check(Presence.Prune(sql, now, ttl), "poda da fronteira")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session WHERE char_id = 777302;", []), 0,
		"a fronteira vencida saiu")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session WHERE char_id = 777301;", []), 1,
		"a fronteira viva ficou")
	ClearCorpus()

# ---------------------------------------------------------------------------
# 6) fantasma de processo morto
# ---------------------------------------------------------------------------
func SuiteGhost() -> void:
	print("-- 6) fantasma: processo que nao passou por DisconnectCharacter --")
	var now : int = int(Time.get_unix_time_from_system())
	ClearCorpus()
	# O processo fantasma escreveu e morreu; ele nunca mais chama nada.
	Seed("ghost_1", 777401, now, GhostServer, 3)
	Seed("ghost_2", 777402, now, GhostServer, 3)
	Seed("vivo_1", 777403, now, serverID, 3)
	CheckEq(Presence.QueryOnline(sql, GhostServer, now).size(), 2, "o id do processo morto tem cauda viva")
	Check(Presence.IsOnlineDurable(sql, "ghost_1", now), "e o nick dele consta como online")

	# Conserto 1: o mesmo id renasce e reclama a própria cauda no boot.
	Check(Presence.ReclaimServer(sql, GhostServer), "ReclaimServer do id morto")
	CheckEq(Presence.QueryOnline(sql, GhostServer, now).size(), 0, "reclamar no boot apaga o fantasma")
	Check(not Presence.IsOnlineDurable(sql, "ghost_1", now), "e o nick deixa de constar")
	CheckEq(Presence.QueryOnline(sql, serverID, now).size(), 1,
		"ReclaimServer NAO toca a cauda de outro server_id")

	# Conserto 2, independente: ninguém renasce com aquele id; o TTL vence e a poda
	# global (idx_presence_seen) recolhe.
	var ahead : int = Presence.TTLSec() + 1
	Seed("ghost_3", 777404, now, GhostServer, 3)
	Check(Presence.IsOnlineDurable(sql, "ghost_3", now), "ghost_3 online agora")
	Check(not Presence.IsOnlineDurable(sql, "ghost_3", now + ahead), "ghost_3 nao esta mais online depois do TTL")
	Check(Presence.Prune(sql, now + ahead, Presence.TTLSec()), "poda no relogio futuro")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session WHERE server_id = ?;", [GhostServer]), 0,
		"TTL sozinho remove o fantasma, sem ReclaimServer")
	ClearCorpus()

# ---------------------------------------------------------------------------
# 7) a claim literal: dois processos sobre o mesmo arquivo
# ---------------------------------------------------------------------------
func SuiteTwoProcesses() -> void:
	print("-- 7) dois SQLService sobre o mesmo arquivo --")
	var now : int = int(Time.get_unix_time_from_system())
	ClearCorpus()
	reader = OpenHandle("reader")
	if not Check(reader != null, "segundo handle abre o MESMO %s (processo B)" % ScratchDB):
		return
	Check(Presence.Report(sql, 777501, 1, "do_processos_A", 2, now), "processo A reporta")
	Check(Presence.Report(reader, 777502, 1, "do_processos_B", 2, now), "processo B reporta")
	CheckEq(Presence.QueryOnline(reader, serverID, now).size(), 2,
		"B ve A: a cauda viva do servidor devolve as duas linhas")
	CheckEq(Presence.QueryOnline(sql, serverID, now).size(), 2,
		"A ve B: a mesma consulta no writer devolve os dois jogadores")
	Check(Presence.IsOnlineDurable(reader, "do_processos_A", now),
		"B responde 'online?' sobre um nick que nunca escreveu")
	Check(Presence.IsOnlineDurable(sql, "do_processos_B", now),
		"e A responde sobre o nick de B")
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session;", []), 2,
		"uma linha por personagem, nao por processo")
	CloseHandle(reader)
	reader = null
	Check(Presence.IsOnlineDurable(sql, "do_processos_A", now), "o writer continua lendo a mesa sozinho")

func CloseHandle(handle) -> void:
	if handle == null:
		return
	handle.db.close_db()
	handle.free()

# ---------------------------------------------------------------------------
# 8) custo do heartbeat
# ---------------------------------------------------------------------------
func SuiteHeartbeatCost() -> void:
	print("-- 8) custo medido do tick --")
	var now : int = int(Time.get_unix_time_from_system())
	ClearCorpus()
	for i in CostChars:
		if not Seed("char_%d" % i, 778000 + i, now, serverID, 1 + (i % 40)):
			Check(false, "semear personagem %d da mesa de custo" % i)
			return
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session WHERE server_id = ?;", [serverID]), CostChars,
		"mesa de %d personagens no id deste processo" % CostChars)

	# UMA statement por tick, contada no próprio contador de round trips do SQLService.
	Presence.ResetTickState()
	sql.ResetCounters()
	var before : int = sql.QueryCount()
	var started : int = Time.get_ticks_usec()
	Presence.Tick(sql, float(Presence.HeartbeatSec()), now + 1)
	var tickUs : int = Time.get_ticks_usec() - started
	CheckEq(sql.QueryCount() - before, 1, "um tick de heartbeat = UMA statement para %d personagens" % CostChars)
	Check(tickUs < BudgetHeartbeatTickUs, "tick de %d chars em %d us (< orcamento %d us)" % [CostChars, tickUs, BudgetHeartbeatTickUs])
	# Uma statement contada não é uma statement que trabalhou: o `UPDATE ... WHERE
	# server_id = ?` tem que ter renovado os 1000, senão o heartbeat barato é barato
	# porque não fez nada (e a cauda vence).
	CheckEq(OneInt("SELECT COUNT(*) AS n FROM presence_session WHERE last_seen_at = ?;", [now + 1]), CostChars,
		"a unica statement do tick renovou os %d personagens" % CostChars)
	Note("custo do tick: %d us para %d personagens (orcamento %d us)" % [tickUs, CostChars, BudgetHeartbeatTickUs])

	# O tick que junta poda é o único que paga duas statements — é a cadência
	# separada que faz o custo de presença ser ~1 statement por minuto por servidor,
	# não por jogador.
	Presence.ResetTickState()
	before = sql.QueryCount()
	Presence.Tick(sql, float(Presence.PruneEverySec()), now + 2)
	CheckEq(sql.QueryCount() - before, 2, "o tick quinquenal junta heartbeat + poda em duas statements")

	# Escrita de sessão individual: connect/disconnect custa uma statement cada,
	# independentemente da população.
	before = sql.QueryCount()
	Seed("individual", 779999, now)
	CheckEq(sql.QueryCount() - before, 1, "Report de um personagem = 1 statement")
	before = sql.QueryCount()
	Presence.Forget(sql, 779999)
	CheckEq(sql.QueryCount() - before, 1, "Forget de um personagem = 1 statement")
	Presence.ResetTickState()

# ---------------------------------------------------------------------------
# 9) as duas metades concordam
# ---------------------------------------------------------------------------
func SuiteMemoryAgreement() -> void:
	print("-- 9) OnlineList.byNick e Presence.IsOnlineDurable --")
	var now : int = int(Time.get_unix_time_from_system())
	ClearCorpus()
	# `OnlineList` entra carregado AQUI, não por nome no topo do arquivo: um harness
	# `-s` é compilado antes de os autoloads existirem, e a referência estática a uma
	# classe que fala com `Network` derruba o `OnlineList` do processo (medido: com a
	# referência estática, o boot morreu em `Network._init` ao ligar
	# `OnlineList.OnPlayerConnected`, e o segfault veio logo depois — sem índice
	# nenhum para conferir, que é pior que um vermelho). GDScript não expõe
	# `get_named()` no 4.7, então a metade em memória é lida por instância: `get` de
	# um `static var` devolve o próprio Dictionary, e é essa identidade que a check
	# abaixo verifica antes de confiar nela.
	var onlineList : GDScript = load("res://sources/network/server/OnlineList.gd")
	if not Check(onlineList != null, "OnlineList.gd carrega em runtime"):
		return
	var view : RefCounted = onlineList.new()
	if not Check(view != null, "instancia de OnlineList existe (static var so e alcanca por handle)"):
		return
	var probe : Variant = view.get("byNick")
	if not CheckEq(typeof(probe), TYPE_DICTIONARY, "byNick e um Dictionary vivo na metade em memoria"):
		return
	var byNick : Dictionary = probe
	var isPlayerOnline : Callable = Callable(view, "IsPlayerOnline")
	# O índice é escrito no produto pelos eventos de login; aqui entra pelo MESMO
	# dicionário (Dictionary é referência), sem o push global — este harness não sobe
	# a árvore de rede.
	var nick : String = "metades_iguais"
	byNick[nick] = true
	Check(Seed(nick, 780001, now), "a metade duravel reporta o mesmo nick")
	Check(bool(isPlayerOnline.call(nick)) and Presence.IsOnlineDurable(sql, nick, now),
		"as duas metades dizem ONLINE no mesmo instante")
	Check(not bool(isPlayerOnline.call("so_duravel")) and not Presence.IsOnlineDurable(sql, "so_duravel", now),
		"nick inexistente: as duas metades dizem OFFLINE")
	# Durável vencido, memória ainda não: é o degrau que o §12 chama de "meia
	# populacao", e o motivo de os dois índices coexistirem em vez de um substituir
	# o outro.
	Seed(nick, 780001, now - Presence.TTLSec() - 5)
	Check(bool(isPlayerOnline.call(nick)) and not Presence.IsOnlineDurable(sql, nick, now),
		"divergencia honesta medida: memoria online, duravel vencido (TTL manda no banco)")
	byNick.erase(nick)
	Check(Presence.Prune(sql, now, Presence.TTLSec()), "poda final da suite")
	Check(not bool(isPlayerOnline.call(nick)) and not Presence.IsOnlineDurable(sql, nick, now),
		"as duas metades dizem OFFLINE depois do despejo")
