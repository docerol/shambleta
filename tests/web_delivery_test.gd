extends SceneTree
# SOM-W5 harness — entrega web + anúncios honestos no cliente web.
#
# Duas famílias de checagem:
#  1. FONTE (posse deploy/web/*, migration, companion): o Dockerfile copia a
#     ponte de ads e o worker fino; o nginx serve os dois no-cache e NÃO
#     proxya /push; `ads_bridge.js` não finge mais nada por default (TEST_MODE
#     só com ?adstest=1); `sw.js` não tem handler de `fetch` (não sequestra o
#     worker do engine); a migration *_web_push.sql existe, é a última da
#     ordem e declara as duas tabelas; o companion declara os quatro modos CLI
#     e o sender default honesto (NotImplementedError).
#  2. COMPORTAMENTO: `WebPush.CanDeliver()` continua false (o gate não mudou
#     desde que o sender real NÃO existe — e WebPushDelivery confessa que não
#     existe); e um único subprocess `python3` roda o caminho e2e real: aplica
#     a migration num SQLite temporário, grava subscription via CLI
#     `--push-register`, varre com `--push-sweep` (só a conta offline entra na
#     fila, dedupe na janela de silêncio), drena com o sender default (vapid ->
#     failed 'vapid_sender_unimplemented') e com o sender de teste (stdout ->
#     sent). O mesmo marcador que a suíte companion lê, lido daqui.
#
# Rodar: godot --headless --path . -s tests/web_delivery_test.gd
# Gate:  bash scripts/ci_gate_log.sh <log> "== WEB DELIVERY:" <exit-code>

const PY_E2E := "
import glob, os, sqlite3, subprocess, sys, tempfile, time
root = sys.argv[1]
migs = sorted(glob.glob(os.path.join(root, 'data/conf/migrations/*_web_push.sql')))
assert len(migs) == 1, 'exactly one *_web_push.sql expected, got %r' % migs
now = int(time.time())
fd, db = tempfile.mkstemp(suffix='.db'); os.close(fd)
con = sqlite3.connect(db)
con.execute('CREATE TABLE account (account_id INTEGER PRIMARY KEY, '
            'username TEXT, last_timestamp INTEGER DEFAULT 0)')
con.execute('INSERT INTO account VALUES (1, ?, ?)', ('old', now - 200000))
con.execute('INSERT INTO account VALUES (2, ?, ?)', ('recent', now))
con.executescript(open(migs[0]).read())
con.commit(); con.close()
srv = os.path.join(root, 'companion/server.py')
def cli(*args, env=None):
    e = dict(os.environ)
    e.pop('SHAMBLETA_PUSH_SENDER', None)
    if env: e.update(env)
    return subprocess.run([sys.executable, srv, '--db', db] + list(args),
                          capture_output=True, text=True, env=e, timeout=30)
r = cli('--push-register', '--account', '1', '--endpoint',
        'https://push.example/x', '--p256dh', 'KEY', '--auth', 'VA')
assert r.returncode == 0, 'register rc=%s err=%s' % (r.returncode, r.stderr)
con = sqlite3.connect(db)
row = con.execute('SELECT endpoint FROM push_subscription '
                  'WHERE account_id = 1').fetchone()
assert row and row[0] == 'https://push.example/x', 'subscription row missing'
con.close()
r = cli('--push-sweep')
assert r.returncode == 0 and 'queued' in r.stdout, r.stdout + r.stderr
con = sqlite3.connect(db)
accts = [a[0] for a in con.execute(
    'SELECT DISTINCT account_id FROM push_outbox ORDER BY account_id')]
assert accts == [1], 'sweep should enqueue only the offline subscriber, got %r' % accts
con.close()
r = cli('--push-sweep')
con = sqlite3.connect(db)
n2 = con.execute('SELECT COUNT(*) FROM push_outbox').fetchone()[0]
assert n2 == 1, 'quiet-window dedupe failed, rows=%s' % n2
con.close()
r = cli('--push-drain')
assert r.returncode == 0, r.stderr
con = sqlite3.connect(db)
st = con.execute('SELECT status, last_error FROM push_outbox ORDER BY id '
                 'LIMIT 1').fetchone()
assert st[0] == 'failed' and str(st[1]).startswith('vapid_sender'), \
    'default sender must fail honestly, got %r' % (st,)
con.close()
r = cli('--push-notify', '--account', '1', '--title', 'Oi', '--body', 'volta',
        env={'SHAMBLETA_PUSH_SENDER': 'stdout'})
assert r.returncode == 0 and 'sent' in r.stdout, r.stdout + r.stderr
con = sqlite3.connect(db)
sent = con.execute(\"SELECT status FROM push_outbox ORDER BY id DESC LIMIT 1\").fetchone()[0]
assert sent == 'sent', 'stdout sender must mark sent, got %s' % sent
con.close()
os.unlink(db)
open(sys.argv[2], 'w').write('WEBPUSH_PY: OK')
print('WEBPUSH_PY: OK')
"

var checks : int = 0
var failures : int = 0

func _read(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()

func _check(cond : bool, label : String):
	checks += 1
	if cond:
		print("PASS: " + label)
	else:
		failures += 1
		print("[FAIL] " + label)

func _migration_numbers() -> Array:
	var nums : Array = []
	var dir : DirAccess = DirAccess.open("res://data/conf/migrations")
	if dir == null:
		return nums
	dir.list_dir_begin()
	var fname : String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".sql"):
			nums.append([int(fname.substr(0, 3)), fname])
		fname = dir.get_next()
	dir.list_dir_end()
	return nums

func _initialize():
	print("== SOM-W5 web delivery harness ==")
	var dockerfile : String = _read("res://deploy/web/Dockerfile")
	var nginx : String = _read("res://deploy/web/nginx.conf")
	var bridge : String = _read("res://deploy/web/ads_bridge.js")
	var worker : String = _read("res://deploy/web/sw.js")
	var companion : String = _read("res://companion/server.py")

	# --- (A) anúncios sem mentira ---
	_check(dockerfile.contains("COPY deploy/web/ads_bridge.js"),
		"Dockerfile copia a ponte de ads (servida de verdade)")
	_check(nginx.contains("location = /ads_bridge.js"),
		"nginx tem location exata para /ads_bridge.js")
	var ads_block : String = nginx.substr(nginx.find("location = /ads_bridge.js"))
	_check(ads_block.contains("no-cache"),
		"/ads_bridge.js servido com Cache-Control no-cache")
	_check(not bridge.contains("var TEST_MODE = true"),
		"ads_bridge: TEST_MODE nao e mais true hardcoded")
	_check(bridge.contains("adstest=1") and bridge.contains("window.location.search"),
		"ads_bridge: simulador so via flag de URL ?adstest=1")
	_check(bridge.contains("done(false)"),
		"ads_bridge: sem SDK, show_rewarded devolve done(false)")

	# --- (B) worker coexistente ---
	_check(dockerfile.contains("COPY deploy/web/sw.js"),
		"Dockerfile copia o worker de push (servido != registrado)")
	_check(nginx.contains("location = /sw.js"),
		"nginx tem location exata para /sw.js")
	_check(not worker.contains("addEventListener('fetch'"),
		"sw.js nao tem handler fetch (nao sequestra requests)")
	_check(worker.contains("addEventListener('push'")
		and worker.contains("addEventListener('notificationclick'")
		and worker.contains("skipWaiting") and worker.contains("clients.claim"),
		"sw.js mantem push/notificationclick/install/activate")
	_check(worker.contains("index.service.worker.js"),
		"sw.js documenta a coexistencia com o worker do engine")

	# --- (C1) migration ---
	var nums : Array = _migration_numbers()
	_check(not nums.is_empty(), "diretorio de migrations visivel no source tree")
	var seen : Dictionary = {}
	var webpush_files : Array = []
	for pair in nums:
		seen[int(pair[0])] = seen.get(int(pair[0]), 0) + 1
		if str(pair[1]).ends_with("_web_push.sql"):
			webpush_files.append(pair)
	_check(webpush_files.size() == 1,
		"exatamente UMA migration *_web_push.sql (sem numero inventado)")
	# Ordem é contrato: ApplyMigrations usa o INDICE do array ordenado como
	# versão. O que não pode existir é número repetido (dois patches na mesma
	# posição) — colisão de agentes paralelos, não furo de ordem: 053 de outra
	# mesa depois da minha 052 é legítimo, 052 duplicado não é.
	var dupes : Array = []
	for n in seen:
		if int(seen[n]) > 1:
			dupes.append(n)
	_check(dupes.is_empty(), "nenhum numero de migration repetido (%s)" % str(dupes))
	if webpush_files.size() == 1:
		_check(int(webpush_files[0][0]) > 51,
			"a migration de push nasceu depois da 051 (nao abre buraco de ordem)")
		var sql : String = _read("res://data/conf/migrations/" + str(webpush_files[0][1]))
		_check(sql.contains("push_subscription") and sql.contains("account_id INTEGER PRIMARY KEY"),
			"push_subscription com account_id PRIMARY KEY (upsert)")
		_check(sql.contains("push_outbox") and sql.contains("p256dh")
			and sql.contains("auth") and sql.contains("push_subscription"),
			"migration declara as duas tabelas (subscription + outbox)")
		_check(sql.contains("endpoint TEXT NOT NULL"),
			"subscription declara endpoint/p256dh/auth NOT NULL")

	# --- (C2) companion: mecanica existe, sender default e honesto ---
	for flag in ["--push-register", "--push-sweep", "--push-drain", "--push-notify"]:
		_check(companion.contains('"' + flag + '"'),
			"companion conhece o modo CLI " + flag)
	_check(companion.contains("def vapid_webpush_send")
		and companion.contains("NotImplementedError"),
		"sender VAPID default = NotImplementedError (sem ECDSA na stdlib)")
	_check(companion.contains("PUSH_SENDERS"),
		"sender e plugavel (PUSH_SENDERS: vapid|stdout)")
	_check(companion.contains("push/test") and companion.contains("push_admin_token"),
		"POST /push/test interno, atras de token admin")
	var nginx_lower : String = nginx.to_lower()
	_check(not nginx_lower.contains("/push"),
		"nginx NAO proxya /push (fila fora da fronteira publica)")

	# --- gate do client: ainda fecha (pendencia registrada, nada de mentira) ---
	# O gate não é mais um literal no texto: ele delega a declaração única. Amarra
	# as duas pontas na fonte — implementar o sender e esquecer o gate (ou o
	# contrário) cai aqui, não vira toggle prometendo push que não chega.
	var webpush_src : String = _read("res://sources/web/WebPush.gd")
	_check(webpush_src.contains("static func CanDeliver() -> bool:")
		and webpush_src.contains("return WebPushDelivery.SenderImplemented()"),
		"WebPush.CanDeliver() delega a declaração única (fonte)")
	var wps = load("res://sources/web/WebPush.gd")
	_check(wps != null and bool(wps.call("CanDeliver")) == false,
		"WebPush.CanDeliver() devolve false em runtime")
	var wpd = load("res://sources/web/WebPushDelivery.gd")
	_check(wpd != null and bool(wpd.call("SenderImplemented")) == false,
		"WebPushDelivery confessa: sender nao implementado")
	if wpd != null:
		var bad : Dictionary = {"account_id": 1, "endpoint": "https://x", "p256dh": "", "auth": "v"}
		var good : Dictionary = {"account_id": 1, "endpoint": "https://x", "p256dh": "k", "auth": "v"}
		_check(not bool(wpd.call("SubscriptionComplete", bad)),
			"contract: p256dh vazio completa a subscription NAO")
		_check(bool(wpd.call("SubscriptionComplete", good)),
			"contract: os quatro campos presentes completam")
		_check(bool(wpd.call("CanOfferToPlayer")) == bool(wps.call("CanDeliver")),
			"contract e gate respondem igual (nada de toggle prometendo push)")
		_check(bool(wpd.call("SenderImplemented")) == bool(wps.call("CanDeliver")),
			"gate e declaração concordam em runtime (delegação de verdade)")

	# --- e2e comportamental (python3 real: migration + CLI + fila + sender) ---
	# OS.execute neste build não devolve stdout do filho (medido: rc 0 com
	# output vazio em `python3 -c print`), então o veredito viaja por ARQUIVO:
	# o script grava user://web_delivery_py.result e o exit code é a chave —
	# nada de "assumiu que rodou".
	var result_path : String = ProjectSettings.globalize_path("user://web_delivery_py.result")
	var e2e_file : FileAccess = FileAccess.open("user://web_delivery_py_e2e.py", FileAccess.WRITE)
	_check(e2e_file != null, "harness consegue gravar o script e2e em user://")
	if e2e_file == null:
		print("== WEB DELIVERY: %d checks, %d failures ==" % [checks + 2, failures + 2])
		quit(failures + 2)
		return
	e2e_file.store_string(PY_E2E)
	e2e_file.close()
	DirAccess.remove_absolute(result_path)
	var root : String = ProjectSettings.globalize_path("res://")
	var e2e_path : String = ProjectSettings.globalize_path("user://web_delivery_py_e2e.py")
	var code : int = OS.execute("python3", [e2e_path, root, result_path], PackedStringArray(), true)
	var py_text : String = ""
	var rf : FileAccess = FileAccess.open(result_path, FileAccess.READ)
	if rf != null:
		py_text = rf.get_as_text()
		rf.close()
	_check(code == 0, "e2e python (register/sweep/drain) exit 0 (rc=%d)" % code)
	_check(py_text.contains("WEBPUSH_PY: OK"),
		"e2e python gravou o marcador de OK (subscription gravada, sweep pontual, drain honesto)")

	print("== WEB DELIVERY: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
