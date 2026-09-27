extends SceneTree

# perf_fix_test.gd — harness autocontido (P1-5 footprint gate, write serialization
# do BackupPlayers, presença O(1), índice AH, e os comentário/constantes ligados).
#
# Uso:  godot --headless --path . -s tests/perf_fix_test.gd
# Saída: "== RESULT: <n> checks, <m> failures =="  (exit code = <m>)
#
# Igual a benchmarks.gd / run_rpc_identity_test.gd: `-s` compila antes dos
# autoloads/class_name do projeto estarem registrados, então NÃO se referencia
# NetworkCommons / Peers / World como identificador global aqui — tudo via
# load(), get_node_or_null(), .get/.set/.call. Os métodos chamados por `.call`
# viram dispatch dinâmico (só aviso unsafe, não erro) — mesma regra de benchmarks.

const SeedChars : int = 200			# fila sintética do passe (> MaxPlayerCount, p/ stress do slice)

# ---------------------------------------------------------------------------
# Régua de REGRESSÃO do chunk, não cerca de sanidade.
#
# O teto anterior era `BudgetChunkMs = 250` contra um pior chunk medido de 0,56 ms
# — 446× de folga: um chunk 400× mais lento continuava verde. Trocado por baseline
# gravado + fator de folga, com os dois impressos no run.
#
# Baseline gravado (2026-09-27, 09:14): 8 runs de
# `godot --headless --path . -s tests/perf_fix_test.gd` numa máquina ociosa (12
# núcleos, load 0,31); o mais quieto deles deu **pior chunk 0,54 ms** (faixa das 8
# passadas: 0,54–0,57 ms, 1,06× de run a run). Recalcule com
# `godot --headless --path . -s tests/perf_baseline.gd`.
const BaselineChunkUs : int = 540
# 4× pega um regresso de 5× (2700 µs > 2160 µs) e continua acima do ruído medido
# da máquina uma vez normalizado pelo controle de CPU (ver benchmarks.gd, que usa
# o mesmo método e o mesmo baseline de controle — medidos na mesma máquina).
const RegressionHeadroom : int = 4
const BaselineControlUs : int = 42033
const ControlWork : int = 2000000
const ControlReps : int = 3

var checks : int = 0
var failures : int = 0
var _controlSink : int = 0

# Laço puro de CPU (sem SQL, sem syscall): mede o quanto a máquina está ocupada
# para o teto não virar flake de CI quando um vizinho satura os núcleos.
func _measureControl() -> int:
	var best : int = 1 << 60
	for rep in range(ControlReps):
		var start : int = Time.get_ticks_usec()
		var acc : int = 0
		for i in range(ControlWork):
			acc = (acc * 31 + 7) & 0x7FFFFFFF
		_controlSink = acc
		best = mini(best, Time.get_ticks_usec() - start)
	return best

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func _initialize():
	print("== Perf fixes (footprint gate / backup slicing / presence / AH index) ==")
	var launcher : Node = root.get_node_or_null(NodePath("Launcher"))
	if launcher == null:
		print("FATAL: autoload Launcher ausente")
		quit(1)
		return

	# Espera SQL + World inicializarem (mesma régua de benchmarks.gd).
	var waited : int = 0
	var sql : Node = null
	var world : Node = null
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		sql = launcher.get("SQL")
		world = launcher.get("World")
		if sql != null and world != null \
				and bool(sql.get("isInitialized")) and bool(world.get("isInitialized")):
			break
	if sql == null or world == null or not bool(sql.get("isInitialized")) or not bool(world.get("isInitialized")):
		print("FATAL: serviços não inicializaram dentro do timeout")
		quit(1)
		return
	print("Serviços prontos após %d ms" % waited)

	_check_footprint_gate_constant()
	_check_footprint_gate_behavior()
	_check_footprint_callsites()
	_check_presence_o1()
	_check_backupplayers_cycle()
	_check_backup_slicing_and_timing(sql, world)
	_check_migration_ah_index()

	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

# ---------------------------------------------------------------------------
# 1) P1-5 — o limiar vivo do gate de pegada é 60000 ms (60 s), não 60 ms.
# ---------------------------------------------------------------------------
func _check_footprint_gate_constant():
	print("-- Footprint gate: constante em unidades corretas")
	var net : GDScript = load("res://sources/network/NetworkCommons.gd")
	var consts : Dictionary = net.get_script_constant_map()
	var gate : int = int(consts.get("FootprintGateMs", -1))
	Check(gate == 60000, "NetworkCommons.FootprintGateMs == 60000 (60 s em ms), valor lido: %d" % gate)
	Check(gate != 60, "o gate não é o literal 60 (que seria 60 ms)")
	# DelayMinute é o parentesco de unidade (60000) já consagrado no repo.
	Check(int(consts.get("DelayMinute", -1)) == 60000, "NetworkCommons.DelayMinute == 60000 (referência de unidade)")

func _check_footprint_gate_behavior():
	print("-- Footprint gate: semântica temporal (ms vs s) medida")
	var peers : GDScript = load("res://sources/network/server/Peers.gd")
	var pid : int = 987654321
	peers.call("AddPeer", pid, 0)  # TransportType.OFFLINE = 0

	# Janela grande (FootprintGateMs): primeira passa, segunda imediata é bloqueada.
	Check(bool(peers.call("Footprint", pid, &"big", 60000)), "gate 60000: primeira chamada passa")
	Check(not bool(peers.call("Footprint", pid, &"big", 60000)), "gate 60000: segunda imediata bloqueada")
	# Janela pequena (60) com o MESMO peer, chave diferente: primeira passa.
	Check(bool(peers.call("Footprint", pid, &"small", 60)), "gate 60: primeira chamada passa")

	OS.delay_msec(80)  # 80 ms depois: maior que 60, muito menor que 60000.

	# Prova de unidade: aos 80 ms a janela de 60 (ms) REABRE, a de 60000 (ms=60 s)
	# CONTINUA fechada. Se o gate vivesse em segundos, os dois se comportariam igual.
	Check(bool(peers.call("Footprint", pid, &"small", 60)), "gate 60 significa 60 ms: reabre após 80 ms")
	Check(not bool(peers.call("Footprint", pid, &"big", 60000)), "gate 60000 significa 60 s: ainda bloqueado após 80 ms")

	peers.call("RemovePeer", pid)

# ---------------------------------------------------------------------------
# 2) As call-sites em Server.gd usam a constante com unidade correta (não 60).
# ---------------------------------------------------------------------------
func _check_footprint_callsites():
	print("-- Footprint gate: call-sites de Server.gd")
	var src : String = FileAccess.get_file_as_string("res://sources/network/server/Server.gd")
	Check(src.contains("Peers.Footprint(peerID, \"claim_settle\", NetworkCommons.FootprintGateMs)"), "ClaimOfflineSettle usa FootprintGateMs")
	Check(src.contains("Peers.Footprint(peerID, \"open_chest\", NetworkCommons.FootprintGateMs)"), "OpenChest usa FootprintGateMs")
	Check(not src.contains("\"claim_settle\", 60"), "ClaimOfflineSettle não passa mais o literal 60")
	Check(not src.contains("\"open_chest\", 60"), "OpenChest não passa mais o literal 60")

# ---------------------------------------------------------------------------
# 3) Presença é O(1) pelo dicionário account-keyed (Peers.accounts).
# ---------------------------------------------------------------------------
func _check_presence_o1():
	print("-- Presença O(1) por conta")
	var peers : GDScript = load("res://sources/network/server/Peers.gd")
	var accounts : Dictionary = peers.get("accounts")
	var acct : int = 555000111
	var pid : int = 987654322
	var unknown : int = int(load("res://sources/network/NetworkCommons.gd").get_script_constant_map().get("PeerUnknownID", -2))

	Check(not bool(peers.call("IsAccountOnline", acct)), "conta inexistente: offline")
	# Vincula conta → peer como o SetAccount faria (mutação in-place do dict estático).
	accounts[acct] = pid
	Check(bool(peers.call("IsAccountOnline", acct)), "conta vinculada: online (O(1), sem varrer peers)")
	Check(int(peers.call("GetAccountPeer", acct)) == pid, "GetAccountPeer devolve o peer da conta")
	accounts.erase(acct)
	Check(not bool(peers.call("IsAccountOnline", acct)), "após erase: volta a offline")
	Check(int(peers.call("GetAccountPeer", unknown)) == unknown, "GetAccountPeer(conta-desconhecida) == PeerUnknownID")

# ---------------------------------------------------------------------------
# 4) BackupPlayersSec mantém a intenção (600 s) e o comentário mentiroso saiu.
# ---------------------------------------------------------------------------
func _check_backupplayers_cycle():
	print("-- Cadência do passe de backup (SQLCommons)")
	var sqlc : GDScript = load("res://sources/sql/SQLCommons.gd")
	var sec : int = int(sqlc.get_script_constant_map().get("BackupPlayersSec", -1))
	Check(sec == 600, "BackupPlayersSec == 600 (10 min) — valor preservado, lido: %d" % sec)
	var src : String = FileAccess.get_file_as_string("res://sources/sql/SQLCommons.gd")
	Check(not src.contains("Every minute"), "comentário errado \"Every minute\" removido")

# ---------------------------------------------------------------------------
# 5) Backup chunked: invariante de slicing + completude + tempo de um chunk.
# ---------------------------------------------------------------------------
func _check_backup_slicing_and_timing(sql : Node, world : Node):
	print("-- BackupPlayers fatiado (slicing + tempo por chunk, DB temporário)")
	var commons : GDScript = load("res://sources/actor/ActorCommons.gd")
	var ws : GDScript = world.get_script()
	var chunk : int = int(ws.get_script_constant_map().get("BackupChunkSize", -1))
	Check(chunk == 16, "World.BackupChunkSize == 16, lido: %d" % chunk)

	# Semeia personagens reais no DB de teste para dar trabalho verdadeiro por item.
	var user : String = "perf_bk_user"
	sql.call("AddAccount", user, "testpass", "perf_bk@test.local")
	var acct : int = int(sql.call("GetAccountID", user))
	var ids : Array = []
	for i in range(SeedChars):
		var nick : String = "PerfBk%d" % i
		sql.call("AddCharacter", acct, nick, commons.DefaultStats, commons.DefaultTraits, commons.DefaultAttributes)
		ids.append(int(sql.call("GetCharacterID", acct, nick)))
	Check(ids.size() == SeedChars, "seed de %d personagens ok (%d)" % [SeedChars, ids.size()])

	# saveFn = um SELECT real por item (proxy do RefreshCharacter, custo por item
	# idêntico no chunk e no burst → o comparativo chunk-vs-burst é honesto).
	var counter : Array = [0]
	var saveFn : Callable = func(charID): counter[0] += 1; sql.call("GetCharacter", charID)

	world.set("_backupQueue", ids)
	world.set("_backupCursor", 0)
	world.set("_backupActive", true)
	counter[0] = 0

	# Primeiro chunk avança exatamente min(chunk, N) e o passe segue ativo.
	var controlBefore : int = _measureControl()
	var t0 : int = Time.get_ticks_usec()
	var done : bool = bool(world.call("_RunBackupChunk", saveFn))
	var firstMs : float = (Time.get_ticks_usec() - t0) / 1000.0
	Check(int(world.get("_backupCursor")) == mini(chunk, SeedChars), "1º chunk avança exatamente %d" % chunk)
	Check(counter[0] == mini(chunk, SeedChars), "1º chunk chamou saveFn %d vezes" % chunk)
	Check(not done, "passe ainda ativo após 1º chunk (%d > %d)" % [SeedChars, chunk])

	# Drena o resto contando passos e o pior chunk.
	var steps : int = 1
	var maxMs : float = firstMs
	var prevCursor : int = mini(chunk, SeedChars)
	var perStepOk : bool = true
	while not done:
		var ct : int = Time.get_ticks_usec()
		done = bool(world.call("_RunBackupChunk", saveFn))
		var dms : float = (Time.get_ticks_usec() - ct) / 1000.0
		if dms > maxMs:
			maxMs = dms
		var cur : int = int(world.get("_backupCursor"))
		if cur - prevCursor > chunk:
			perStepOk = false
		prevCursor = cur
		steps += 1

	Check(perStepOk, "nenhum chunk processa mais que %d itens" % chunk)
	var expectedSteps : int = int(ceil(SeedChars / float(chunk)))
	Check(steps == expectedSteps, "passe completou em ceil(%d/%d)=%d chunks (%d)" % [SeedChars, chunk, expectedSteps, steps])
	Check(counter[0] == SeedChars, "todos os %d persistidos dentro do passe (%d)" % [SeedChars, counter[0]])

	var controlAfter : int = _measureControl()
	# Crédito só pelo controle mais QUIETO adjacente ao passe: "a máquina estava
	# ocupada" não pode virar licença para ignorar a régua.
	var loadFactor : float = maxf(1.0, float(mini(controlBefore, controlAfter)) / float(BaselineControlUs))
	var worstUs : int = int(maxMs * 1000.0)
	var worstAdjUs : int = int(float(worstUs) / loadFactor)
	var ceilingUs : int = BaselineChunkUs * RegressionHeadroom
	print("  régua de regressão do chunk: baseline gravado %d µs (pior chunk do run mais quieto de 8, máquina ociosa, load 0,31, 12 núcleos, 2026-09-27) × folga %d× = teto %d µs | medido agora %d µs, normalizado %d µs (%.2f× o baseline) | controle %d/%d µs vs %d gravados → máquina a %.2f×" % [BaselineChunkUs, RegressionHeadroom, ceilingUs, worstUs, worstAdjUs, float(worstAdjUs) / float(BaselineChunkUs), controlBefore, controlAfter, BaselineControlUs, loadFactor])
	Check(worstAdjUs <= ceilingUs, "pior chunk (%d µs normalizado) dentro da régua de regressão (teto %d µs = %d µs × %d)" % [worstAdjUs, ceilingUs, BaselineChunkUs, RegressionHeadroom])

	# Comparativo before/after: um burst síncrono (todos N numa passada) custa mais
	# que o maior chunk. É o número da regressão original.
	var bt : int = Time.get_ticks_usec()
	for id in ids:
		sql.call("GetCharacter", id)
	var burstMs : float = (Time.get_ticks_usec() - bt) / 1000.0
	Check(maxMs < burstMs, "chunk (%.2f ms) < burst síncrono de %d itens (%.2f ms)" % [maxMs, SeedChars, burstMs])
	print("  números: pior chunk=%.2f ms | burst síncrono=%.2f ms | x%.1f" % [maxMs, burstMs, burstMs / max(0.001, maxMs)])

	# Limpa o estado de teste para o _process do World não drenar a fila sintética.
	world.set("_backupActive", false)
	world.set("_backupQueue", [])
	world.set("_backupCursor", 0)
	sql.db.delete_rows("character", "account_id = %d" % acct)
	sql.db.delete_rows("account", "username = '%s'" % user)

# ---------------------------------------------------------------------------
# 6) Migration 051: índice AH por vendedor, no formato de 041/047, na base viva.
# ---------------------------------------------------------------------------
func _check_migration_ah_index():
	print("-- Índice AH (seller_account)")
	var files : PackedStringArray = DirAccess.get_files_at("res://data/conf/migrations")
	var found : bool = false
	for f in files:
		if f.begins_with("051_") and f.ends_with(".sql"):
			found = true
	Check(found, "existe data/conf/migrations/051_*.sql")

	# O índice precisa estar APLICADO na base viva (o boot roda ApplyMigrations).
	var sql : Node = root.get_node_or_null(NodePath("Launcher")).get("SQL")
	var rows : Array = sql.call("Query", "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='auction_listing' AND name='idx_auction_listing_seller_account';")
	Check(not rows.is_empty(), "idx_auction_listing_seller_account presente na base viva")
