extends SceneTree
# SOM-W5 harness — entrega web + anúncios honestos no cliente web.
#
# Três famílias de checagem:
#  1. FONTE (posse deploy/web/*, template do export, migration, companion): o
#     Dockerfile copia a ponte de ads e o worker fino; o nginx serve os dois
#     no-cache e proxya APENAS o caminho exato `GET /push/vapid` (a prontidão),
#     mantendo `/push/test` e a fila fora da fronteira pública; `ads_bridge.js`
#     não finge mais nada por default; `sw.js` não tem handler de `fetch` e abre
#     `event.data.json()` com fallback; a migration *_web_push.sql existe e
#     declara as duas tabelas; o companion declara os quatro modos CLI e o sender
#     plugável; e a ponte `ShambletaPush` do template do export tem
#     `pushManager.subscribe()` com a chave vindo do JOGO (nenhum segredo de 87
#     caracteres morando no HTML).
#  2. O GATE, PEÇA POR PEÇA. `WebPushDelivery.CanDeliver()` não é mais um
#     `return false`: é a E de peças nomeadas — `SenderImplemented`,
#     `CompanionReportsPushReady`, `VapidKeyConfigured`, `BrowserCanSubscribe`,
#     `ServerPersistsSubscriptions`, `ClientSubmitWired`. Cada peça tem asserção
#     própria, motivo próprio e valor medido aqui — no dia em que uma nascer, só
#     a asserção dela muda (e a implicação "companion não pronto ⇒ nenhuma chave
#     observada" é asserrada junto, porque as duas pontas entram pela mesma
#     resposta). A régua antiga (exigir `NotImplementedError` no companion e
#     `CanDeliver() == false`) media o texto de uma confissão vencida, não o
#     mundo.
#  3. EXECUÇÃO. Um único subprocess `python3`: (a) nenhum dos quatro módulos do
#     sender confessa `NotImplementedError` e `send()` existe; (b) GERA UM PAR
#     P-256 EM RUNTIME, sobe um push service de mentira em 127.0.0.1 e exige que
#     `send()` produza POST com `Authorization: vapid` + corpo `aes128gcm` que o
#     receptor abre, e que 410 vire `SubscriptionGone`; (c) lê o banco que o
#     PRÓPRIO processo Godot escreveu (snapshot `VACUUM INTO` da linha gravada
#     por `Launcher.SQL` através de `WebPushSubscription.Register`), faz
#     `sweep -> drain` com um sender FAKE (nenhum endpoint real é discado) até
#     estado terminal, e mostra o `failed` honesto
#     `push_subscription_gone_410` com a subscription apagada quando o provedor
#     devolve 410; (d) roda o caminho CLI de sempre (register/sweep/drain
#     keyless -> `vapid_sender_unimplemented`, stdout -> `sent`).
#  4. A FIAÇÃO DO LADO DO SERVIDOR (peça 6). Não basta a sonda responder true: a
#     suíte D1b lê o CORPO de `Network.gd`/`Server.gd` (método até o próximo
#     `func`, para comentário não sustentar check verde), exige que os dois lados
#     tenham a mesma assinatura, que o wrapper mande só os três campos do material,
#     que o canal seja CONNECT e que a conta saia de `Peers.GetAccount(peerID)` —
#     nunca do payload. E executa a sonda nos três estados do nó: com o RPC
#     (true), sem nó (`no_network_node`), com nó sem o RPC
#     (`rpc_not_landed:<rpc>`), trocando o NOME do autoload (não realocar o nó,
#     que dispararia `_exit_tree` do caminho de rede por causa de um teste).
#  5. A Perna do NAVEGADOR (suíte G). `isWeb` é `static var`, então o ramo
#     `no_bridge` do contrato é medível sem browser: cada chamada do `WebPush`
#     tem de responder NÃO com motivo próprio em vez de chamar método inexistente
#     — é o ramo de um deploy cujo `head_include` não carregou a ponte. E o
#     `Unsubscribe()` sem navegador confirmado não pode apagar a linha no
#     servidor (medido por contagem antes/depois).
#
# Uso:  XDG_DATA_HOME=/tmp/pushw/data XDG_CACHE_HOME=/tmp/pushw/cache \
#         godot --headless --path . -s tests/web_delivery_test.gd
# Gate: bash scripts/ci_gate_log.sh <log> "== WEB DELIVERY:" <exit-code>

const PY_E2E := "
import glob, json, os, re, sqlite3, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = sys.argv[1]
snap = sys.argv[2]
acct = int(sys.argv[3])
g_endpoint = sys.argv[4]
g_p256dh = sys.argv[5]
g_auth = sys.argv[6]
ghost = int(sys.argv[7])
marker_path = sys.argv[8]
log = []

companion = os.path.join(root, 'companion')
sys.path.insert(0, companion)

# ---- (1) estatica honesta: os quatro modulos do sender ---------------------
for m in ['push_common.py', 'push_p256.py', 'push_aesgcm.py', 'push_vapid.py']:
    src = open(os.path.join(companion, m), encoding='utf-8').read()
    assert 'NotImplementedError' not in src, m + ' ainda confessa NotImplementedError'
facade = open(os.path.join(companion, 'push_vapid.py'), encoding='utf-8').read()
assert 'def send(' in facade, 'push_vapid.send() nao existe'
assert 'def vapid_authorization(' in facade and 'def build_request(' in facade
assert 'def decrypt_message(' in open(os.path.join(companion, 'push_aesgcm.py'),
                                     encoding='utf-8').read()
log.append('PYSTATIC: OK')

# ---- (2) execucao: POST real + VAPID + aes128gcm aberto pelo receptor ------
import push_vapid as pv
import server as srv

priv, pub = pv.generate_keypair()
rpriv, rpub = pv.generate_keypair()
auth_secret = pv.b64u_encode(os.urandom(16))


class Receiver(BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        Receiver.seen.append({'path': self.path, 'headers': dict(self.headers),
                              'body': raw})
        code = 410 if self.path.startswith('/gone') else 201
        self.send_response(code)
        self.send_header('Content-Length', '0')
        self.end_headers()


httpd = ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()
os.environ[pv.VAPID_PRIVATE_ENV] = priv
os.environ[pv.VAPID_PUBLIC_ENV] = pub
os.environ[pv.VAPID_SUBJECT_ENV] = 'mailto:push@shambleta.test'
assert pv.push_ready()[0] is True, 'chave gerada em runtime nao deixou o sender pronto'
assert pub == pv.public_key_from_private(priv)
status = pv.send({'endpoint': 'http://127.0.0.1:%d/live' % port,
                  'p256dh': rpub, 'auth': auth_secret}, 'Titulo', 'corpo')
assert int(status) == 201, 'receiver devolveu %s' % status
assert len(Receiver.seen) == 1, 'um POST por mensagem'
hdr = Receiver.seen[0]['headers']
assert hdr.get('Content-Encoding') == 'aes128gcm', 'Content-Encoding ausente'
assert hdr.get('TTL') is not None, 'TTL (RFC 8030 5.2) ausente'
assert re.fullmatch('vapid t=[A-Za-z0-9-._]+, k=[A-Za-z0-9_-]{87}',
                    hdr.get('Authorization', '')), 'forma do assertion VAPID'
assert priv not in json.dumps(hdr), 'a privada nao viaja em header'
opened = json.loads(pv.decrypt_message(Receiver.seen[0]['body'], rpriv, auth_secret))
assert opened.get('title') == 'Titulo' and opened.get('body') == 'corpo', \\
    'corpo nao abre com a privada do receptor'
assert opened.get('icon') == 'index.144x144.png' and opened.get('url') == '/'
try:
    pv.send({'endpoint': 'http://127.0.0.1:%d/gone' % port,
             'p256dh': rpub, 'auth': auth_secret}, 't', 'b')
    raise AssertionError('410 deveria levantar SubscriptionGone')
except pv.SubscriptionGone as exc:
    assert int(exc.status) == 410, 'status do SubscriptionGone'
httpd.shutdown()
log.append('PYSENDER: OK')

# ---- (3) a linha escrita pelo SERVIDOR DE JOGO: sweep -> drain -> 410 ------
assert os.path.exists(snap), 'snapshot do banco do jogo nao existe'
con = sqlite3.connect(snap)
row = con.execute('SELECT endpoint, p256dh, auth, updated_at FROM push_subscription '
                  'WHERE account_id = ?', (acct,)).fetchone()
assert row is not None, 'Launcher.SQL nao gravou nenhuma push_subscription'
assert row[0] == g_endpoint and row[1] == g_p256dh and row[2] == g_auth, \\
    'campos gravados divergem do que o client entregou'
assert int(row[3]) > 0, 'updated_at do servidor ausente'
assert con.execute('SELECT COUNT(*) FROM push_subscription WHERE account_id = ?',
                   (ghost,)).fetchone()[0] == 0, \\
    'o account_id do payload virou conta no banco (autoridade de sessao furada)'
store = srv.Store(snap)
calls = []


def fake_sender(sub, title, body):
    calls.append((int(sub['account_id']), str(sub['endpoint']), str(title)))
    return True


def gone_sender(sub, title, body):
    raise srv.PushSubscriptionGone(410, '127.0.0.1')


assert store.push_sweep(con) >= 1, 'sweep nao enfileirou a conta do jogo'
enq = [r[0] for r in con.execute('SELECT DISTINCT account_id FROM push_outbox')]
assert acct in enq, 'conta do jogo fora da fila: %r' % enq
assert store.push_sweep(con) == 0, 'dedupe da janela de silencio falhou'
drained = store.push_drain(con, sender=fake_sender)
assert drained['sent'] >= 1, 'drain com sender fake nao entregou: %r' % drained
state = con.execute('SELECT status, last_error FROM push_outbox WHERE account_id = ? '
                    'ORDER BY id LIMIT 1', (acct,)).fetchone()
assert state[0] == 'sent', 'fila nao chegou em estado terminal: %r' % (state,)
assert calls and calls[0][1] == g_endpoint, 'o drain nao usou a linha do jogo'
assert len(Receiver.seen) == 2, \\
    'o sender fake discou alguma coisa (POSTs vistos=%d)' % len(Receiver.seen)
store.push_enqueue(con, acct, title='Morta', body='410')
assert store.push_drain(con, sender=gone_sender)['failed'] >= 1, '410 nao virou failed'
last = con.execute('SELECT status, last_error FROM push_outbox WHERE account_id = ? '
                   'ORDER BY id DESC LIMIT 1', (acct,)).fetchone()
assert last[0] == 'failed', 'linha do 410 ficou %r' % (last,)
assert str(last[1]).startswith('push_subscription_gone_410'), \\
    'motivo do 410 nao e push_subscription_gone_<status>: %r' % (last[1],)
assert con.execute('SELECT COUNT(*) FROM push_subscription WHERE account_id = ?',
                   (acct,)).fetchone()[0] == 0, '410 nao apagou a subscription'
con.close()
log.append('PYQUEUE: OK')

# ---- (4) caminho CLI de sempre, num SQLite temporario proprio --------------
migs = sorted(glob.glob(os.path.join(root, 'data/conf/migrations/*_web_push.sql')))
assert len(migs) == 1, 'exactly one *_web_push.sql expected, got %r' % migs
now = int(time.time())
fd, db = tempfile.mkstemp(suffix='.db')
os.close(fd)
con = sqlite3.connect(db)
con.execute('CREATE TABLE account (account_id INTEGER PRIMARY KEY, '
            'username TEXT, last_timestamp INTEGER DEFAULT 0)')
con.execute('INSERT INTO account VALUES (1, ?, ?)', ('old', now - 200000))
con.execute('INSERT INTO account VALUES (2, ?, ?)', ('recent', now))
con.executescript(open(migs[0]).read())
con.commit()
con.close()
srvpy = os.path.join(companion, 'server.py')


def cli(*args, env=None):
    e = dict(os.environ)
    for k in ('SHAMBLETA_PUSH_SENDER', pv.VAPID_PRIVATE_ENV, pv.VAPID_PUBLIC_ENV,
              pv.VAPID_SUBJECT_ENV):
        e.pop(k, None)
    if env:
        e.update(env)
    return subprocess.run([sys.executable, srvpy, '--db', db] + list(args),
                          capture_output=True, text=True, env=e, timeout=30)


r = cli('--push-register', '--account', '1', '--endpoint',
        'https://push.example/x', '--p256dh', 'KEY', '--auth', 'VA')
assert r.returncode == 0, 'register rc=%s err=%s' % (r.returncode, r.stderr)
con = sqlite3.connect(db)
assert con.execute('SELECT endpoint FROM push_subscription '
                   'WHERE account_id = 1').fetchone()[0] == 'https://push.example/x'
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
assert con.execute('SELECT COUNT(*) FROM push_outbox').fetchone()[0] == 1, \\
    'quiet-window dedupe failed'
con.close()
r = cli('--push-drain')
assert r.returncode == 0, r.stderr
con = sqlite3.connect(db)
st = con.execute('SELECT status, last_error FROM push_outbox ORDER BY id '
                 'LIMIT 1').fetchone()
assert st[0] == 'failed' and str(st[1]).startswith('vapid_sender'), \\
    'deploy sem chave tem que falhar honesto, got %r' % (st,)
con.close()
r = cli('--push-notify', '--account', '1', '--title', 'Oi', '--body', 'volta',
        env={'SHAMBLETA_PUSH_SENDER': 'stdout'})
assert r.returncode == 0 and 'sent' in r.stdout, r.stdout + r.stderr
con = sqlite3.connect(db)
sent = con.execute('SELECT status FROM push_outbox ORDER BY id DESC LIMIT 1').fetchone()[0]
assert sent == 'sent', 'stdout sender must mark sent, got %s' % sent
con.close()
os.unlink(db)
log.append('PYCLI: OK')

open(marker_path, 'w').write('\\n'.join(log) + '\\n')
print('WEBPUSH_PY: OK')
"

# Fixture: conta propria + subscription FAKE apontando para um porta que nada
# escuta (1/tcpmux). O sender do passo (3) e um FAKE em processo: nenhum
# endpoint real e discado, e isso e asserrado pelo contador do receiver.
const GhostAccount : int = 987654
const FixtureUser : String = "psh_webpush"
const FakeEndpoint : String = "http://127.0.0.1:1/sw/push"
const FakeP256dh : String = "BDfakep256dhmaterial-SOM-W5"
const FakeAuth : String = "ZmFrZXJ0aDE2"

var checks : int = 0
var failures : int = 0
var _launcher : Node = null
var _sql : Object = null

func _read(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()

# Comentario de nginx e `#` ate o fim da linha. A régua de proxy tem de medir
# DIRETIVA, nao prosa: o conf documenta `POST /push/test` dentro de um comentario
# exatamente para explicar por que a fila fica fora, e procurar a palavra no texto
# cru daria vermelho num arquivo correto (e verde facil de forjar com comentario).
# Nenhuma string de diretiva deste conf contem `#`, entao cortar a linha no primeiro
# `#` e seguro sem maquina de aspas.
func _stripHash(text : String) -> String:
	var out : String = ""
	for line : String in text.split("\n", false):
		var hash : int = line.find("#")
		out += (line.substr(0, hash) if hash >= 0 else line) + "\n"
	return out

func _check(cond : bool, label : String) -> bool:
	checks += 1
	if cond:
		print("  [ok] " + label)
		return true
	failures += 1
	print("  [FAIL] " + label)
	return false

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

# ---------------------------------------------------------------- template
# O `html/head_include` do export web e uma string multi-linha do INI, com `"`
# interno escapado. Extrair sem parser de INI e proposital: a regua precisa
# enxergar EXATAMENTE o octeto que vai para o HTML do jogador.
func _head_include(presets : String) -> String:
	var key : String = "html/head_include="
	var at : int = presets.find(key)
	if at < 0:
		return ""
	var i : int = at + key.length()
	if i >= presets.length() or presets[i] != "\"":
		return ""
	i += 1
	var out : String = ""
	while i < presets.length():
		var c : String = presets[i]
		if c == "\\":
			if i + 1 < presets.length():
				out += presets[i + 1]
				i += 2
				continue
		if c == "\"":
			return out
		out += c
		i += 1
	return ""

func _inline_script(head : String) -> String:
	var openAt : int = head.find("<script>")
	if openAt < 0:
		return ""
	openAt += "<script>".length()
	var closeAt : int = head.find("</script>", openAt)
	if closeAt < 0:
		return ""
	return head.substr(openAt, closeAt - openAt)

# Maior corrida de caracteres de base64url no texto. Uma publica VAPID tem 87;
# o identificador JS mais longo do template hoje tem 26. E a regua de "nenhum
# segredo morando no HTML" — hardcode a chave aqui e esta linha cai.
func _longest_b64u_run(text : String) -> int:
	var best : int = 0
	var run : int = 0
	for i : int in range(text.length()):
		var c : int = text.unicode_at(i)
		var okChar : bool = (c >= 97 and c <= 122) or (c >= 65 and c <= 90) \
			or (c >= 48 and c <= 57) or c == 45 or c == 95
		if okChar:
			run += 1
			if run > best:
				best = run
		else:
			run = 0
	return best

func _boot_ready() -> bool:
	if _launcher == null:
		return false
	var sql : Variant = _launcher.get("SQL")
	return sql != null and bool(sql.isInitialized)

func _initialize():
	_run()

# --------------------------------------------------------------------------
# peça 6 — `RegisterPushSubscription` landed?
# --------------------------------------------------------------------------

# corpo de um metodo: do `func` ate o proximo `func` de topo. E a forma que
# `tests/guild_vault_gate_test.gd` usa para nao deixar uma ruler ler COMENTARIO:
# regra que procura texto no arquivo inteiro da verde quando o handler e apagado e
# a frase sobrevive na doc de quem o descreve.
func _bodyOf(src : String, signature : String) -> String:
	var at : int = src.find(signature)
	if at < 0:
		return ""
	var rest : String = src.substr(at)
	var next : int = rest.find("\nfunc ", 1)
	return rest.substr(0, next) if next > 0 else rest

# O `@rpc` que ANTECEDE a assinatura — o canal é decisão de protocolo (CONNECT não
# compete com o burst de ACTION), e sem ler a linha de cima a ruler não vê a
# diferença entre registrar no canal certo e no canal errado.
func _annotationOf(src : String, signature : String) -> String:
	var at : int = src.find(signature)
	if at < 0:
		return ""
	var before : String = src.substr(0, at)
	var last : int = before.rfind("@rpc")
	if last < 0:
		return ""
	return before.substr(last)

# Sonda de runtime com dois motivos de falha (`no_network_node`,
# `rpc_not_landed:<rpc>`). Medir só o true do nó de produto não prova que a sonda
# distingue as coisas: é isto abaixo que prova, e é por isto que ela volta ao
# mundo real no fim.
func _suitePiece6Landed(wpd : Object) -> void:
	print("-- (D1b) peca 6: o RPC landed nos dois lados e a identidade vem do peer")
	var consts : Dictionary = wpd.get_script_constant_map()
	var rpcReg : String = str(consts.get("RpcRegister", ""))
	var rpcUnreg : String = str(consts.get("RpcUnregister", ""))
	_check(rpcReg == "RegisterPushSubscription" and rpcUnreg == "UnregisterPushSubscription",
		"o contrato nomeia os dois RPCs (%s, %s) — a sonda e o fonte tem de concordar" % [rpcReg, rpcUnreg])
	var netSrc : String = _read("res://sources/network/Network.gd")
	var srvSrc : String = _read("res://sources/network/server/Server.gd")
	var netSig : String = "func RegisterPushSubscription(endpoint : String, p256dh : String, auth : String, peerID : int"
	var srvSig : String = "func RegisterPushSubscription(endpoint : String, p256dh : String, auth : String, peerID : int)"
	_check(netSrc.contains(netSig), "Network.gd declara o wrapper client->server da subscription")
	_check(srvSrc.contains(srvSig), "Server.gd declara o handler com a MESMA assinatura")
	var netBody : String = _bodyOf(netSrc, netSig)
	_check(netBody.contains("CallServer(\"RegisterPushSubscription\", [endpoint, p256dh, auth]"),
		"o wrapper envia os tres campos e NENHUM outro (nem conta, nem account_id)")
	_check(netBody.contains("AuthPeerID(peerID)"),
		"o wrapper passa pelo AuthPeerID (a borda que transforma peer em identidade)")
	_check(_annotationOf(netSrc, netSig).contains("EChannel.CONNECT"),
		"o RPC de registro usa o canal CONNECT, nao ACTION (registro de sessao nao compete com o burst de acao)")
	var srvBody : String = _bodyOf(srvSrc, srvSig)
	_check(srvBody.contains("Peers.GetAccount(peerID)"),
		"o handler tira a conta do PEER (%s)" % rpcReg)
	_check(not srvBody.contains("account_id") and not srvBody.contains("\"account\""),
		"o handler nao le conta do payload — se lesse, um client alterado escreveria subscription na caixa de outro")
	_check(srvBody.contains("WebPushSubscription.RegisterAndReport(accountID, endpoint, p256dh, auth, peerID)"),
		"o handler delega ao servico (um ponto de validacao, nao duas implementations)")
	var srvUnreg : String = _bodyOf(srvSrc, "func UnregisterPushSubscription(peerID : int):")
	_check(srvUnreg.contains("Peers.GetAccount(peerID)") and srvUnreg.contains("ReportUnregister"),
		"o par do toggle Off landed (sem ele, recusar deixa a linha no banco e o sweep segue notificando quem disse nao)")
	# A sonda nos dois motivos, executada contra o autoload `Network` de verdade.
	# Realocar o nó (remove_child/add_child) dispararia `_exit_tree`/`_enter_tree`
	# do caminho de rede por causa de um teste; trocar o NOME não dispara nada e é
	# revertido na mesma função — a régua mexe só no caminho que a sonda olha.
	var real : Node = root.get_node_or_null(NodePath("Network"))
	_check(real != null, "o autoload Network esta na arvore — a sonda mede o no de produto, nao um nosso")
	if real == null:
		return
	_check(bool(wpd.call("ClientSubmitWired")) == true,
		"com o Network de produto no lugar, a sonda responde true (peca 6 landed de verdade)")
	real.name = "NetworkHiddenByHarness"
	var gone : bool = bool(wpd.call("ClientSubmitWired"))
	var goneWhy : String = str(wpd.call("LastReason"))
	_check(gone == false and goneWhy == "no_network_node",
		"sem no, a sonda devolve false com o motivo no_network_node, nao um false mudo (%s)" % goneWhy)
	var bare : Node = Node.new()
	bare.name = "Network"
	root.add_child(bare)
	var bareWhy : String = ""
	var bareWired : bool = bool(wpd.call("ClientSubmitWired"))
	bareWhy = str(wpd.call("LastReason"))
	_check(bareWired == false and bareWhy == ("rpc_not_landed:%s" % rpcReg),
		"um Network SEM o metodo devolve false com rpc_not_landed — a sonda nao confunde no com RPC (%s)" % bareWhy)
	root.remove_child(bare)
	bare.free()
	real.name = "Network"
	_check(bool(wpd.call("ClientSubmitWired")) == true,
		"com o no de volta a sonda volta a true: a arvore foi restaurada, nao so o veredito")

func _finish():
	print("== WEB DELIVERY: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

func _run() -> void:
	print("== SOM-W5 web delivery harness ==")
	var dockerfile : String = _read("res://deploy/web/Dockerfile")
	var nginx : String = _read("res://deploy/web/nginx.conf")
	var bridge : String = _read("res://deploy/web/ads_bridge.js")
	var worker : String = _read("res://deploy/web/sw.js")
	var companion : String = _read("res://companion/server.py")
	var pushfacade : String = _read("res://companion/push_vapid.py")

	# --- (A) anuncios sem mentira ---
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

	# --- (B) worker coexistente, escopo estreito, dados lidos com fallback ---
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
	_check(worker.contains("if (event.data)") and worker.contains("event.data.json()")
		and worker.contains("event.data.text()"),
		"sw.js le event.data com guarda + json() em try + text() (payload vazio/nao-json nao derruba o push)")
	_check(worker.contains("/sw/"),
		"sw.js documenta o escopo estreito /sw/ (no deslocar o worker do engine)")
	_check(not worker.contains("ainda false"),
		"sw.js nao confessa mais um CanDeliver() 'ainda false' (a regex de 2026-09-26 morre aqui)")

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
	# Ordem e contrato: ApplyMigrations usa o INDICE do array ordenado como
	# versao. O que nao pode existir e numero repetido (dois patches na mesma
	# posicao) — colisao de agentes paralelos, nao furo de ordem.
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

	# --- (C2) companion: mecanica existe e o sender e de verdade ---
	for flag in ["--push-register", "--push-sweep", "--push-drain", "--push-notify"]:
		_check(companion.contains('"' + flag + '"'),
			"companion conhece o modo CLI " + flag)
	_check(companion.contains("def vapid_webpush_send")
		and companion.contains("pv.send(") and companion.contains("PUSH_SENDERS"),
		"sender VAPID do companion e real: o wrapper delega em push_vapid.send()")
	_check(pushfacade.contains("def send(") and pushfacade.contains("def vapid_authorization("),
		"push_vapid tem send() + vapid_authorization() (o que a regex antiga negava)")
	_check(not pushfacade.contains("NotImplementedError"),
		"push_vapid nao confessa NotImplementedError (so ConfigError sem chave)")
	_check(companion.contains("vapid_sender_unimplemented"),
		"deploy sem chave continua fail-closed com rotulo proprio (configuracao, nao ausencia)")
	_check(companion.contains("push/test") and companion.contains("push_admin_token"),
		"POST /push/test interno, atras de token admin")
	# A régua antiga era `not nginx.contains("/push")` e passou a ser FALSA em
	# 2026-09-27, quando a rota de prontidão entrou no proxy: sem ela um browser
	# nunca recebe `GET /push/vapid` (a origem da página é o único companion que
	# ele conhece) e as peças 2/3 do contrato ficam presas em `bad_response`. O
	# medo continua válido, só que é outro medo: o que não pode virar rota pública
	# é a FILA. Daí a forma exata — a cerca passa a medir caminho, não a palavra.
	var nginx_code : String = _stripHash(nginx)
	_check(nginx_code.contains("location = /push/vapid"),
		"nginx tem a rota EXATA de prontidao /push/vapid (o browser consegue perguntar se o sender esta pronto)")
	var pushBlock : String = nginx_code.substr(nginx_code.find("location = /push/vapid"))
	var nextLoc : int = pushBlock.find("location ", 1)
	pushBlock = pushBlock.substr(0, nextLoc) if nextLoc > 0 else pushBlock
	_check(pushBlock.contains("limit_except GET"),
		"a rota de prontidao so tem GET (POST/PUT nela seria escrita alcancavel pela fronteira publica)")
	_check(pushBlock.contains("deny all"),
		"limit_except vem com `deny all` (lista de metodos sem trava no bloqueia nada)")
	_check(not nginx_code.contains("/push/test"),
		"nginx NAO proxya /push/test (a fila continua fora da fronteira publica)")
	_check(not nginx_code.contains("location ^~ /push") and not nginx_code.contains("location /push"),
		"nenhum prefixo `/push` no proxy: so o caminho exato da prontidao vai ao companion")

	# --- (C3) a ponte do navegador, no template do export ---
	var presets : String = _read("res://export_presets.cfg")
	var head : String = _head_include(presets)
	_check(head.contains("ShambletaPush"),
		"template do export carrega a ponte ShambletaPush (head_include parseado do INI)")
	var js : String = _inline_script(head)
	_check(js.contains("pushManager.subscribe"),
		"ponte chama pushManager.subscribe() (a peca que fazia o browser nunca assinar)")
	_check(js.contains("applicationServerKey") and js.contains("userVisibleOnly"),
		"subscribe passa applicationServerKey + userVisibleOnly")
	_check(js.contains("getSubscription"),
		"ponte rele a subscription existente (rerun nao cria segunda)")
	_check(js.contains("unsubscribe()"),
		"ponte tem unsubscribe() do lado do navegador")
	_check(js.contains("endpoint") and js.contains("p256dh") and js.contains("auth"),
		"ponte devolve endpoint/p256dh/auth ao Godot (material da subscription)")
	_check(js.contains("can_subscribe") and js.contains("subscribe_error"),
		"ponte expoe a sonda que WebPushDelivery.BrowserCanSubscribe() consulta")
	_check(js.contains("register_sw") and js.contains("get_permission")
		and js.contains("show_notification"),
		"ponte mantem register_sw/get_permission/show_notification (nada regrediu)")
	_check(js.contains("scope") and js.contains("/sw/"),
		"register_sw aceita escopo e usa /sw/ (estreito, nao o '/' do engine)")
	var run : int = _longest_b64u_run(js)
	_check(run < 40,
		"nenhuma chave VAPID morando no template (maior corrida b64url = %d; publica teria 87)" % run)
	var webpush_src : String = _read("res://sources/web/WebPush.gd")
	_check(webpush_src.contains("js.subscribe(WebPushDelivery.VapidPublicKey())"),
		"a chave chega ao navegador PELO JOGO (WebPushDelivery.VapidPublicKey), nunca hardcoded")
	_check(webpush_src.contains("WebPushDelivery.VapidKeyConfigured()"),
		"WebPush.Subscribe() so pergunta ao navegador com chave observada")
	_check(webpush_src.contains("register_sw(\"/sw.js\", \"/sw/\")"),
		"WebPush registra o worker no escopo estreito /sw/")

	# --- gate do client: delegacao de verdade, sem segundo literal ---
	_check(webpush_src.contains("static func CanDeliver() -> bool:")
		and webpush_src.contains("return WebPushDelivery.CanDeliver()"),
		"WebPush.CanDeliver() delega a declaracao unica (fonte)")

	# ---------------------------------------------------------------- boot
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	var waited : int = 0
	while _launcher != null and not _boot_ready() and waited < 30000:
		await create_timer(0.1).timeout
		waited += 100
	if not _boot_ready():
		_check(false, "boot: Launcher.SQL pronto (waited %d ms) — sem SQL nada do caminho e executado" % waited)
		_finish()
		return
	_sql = _launcher.get("SQL")

	var wpd : Object = load("res://sources/web/WebPushDelivery.gd")
	var wps : Object = load("res://sources/web/WebPush.gd")
	var wpsub : Object = load("res://sources/web/WebPushSubscription.gd")
	if not _check(wpd != null and wps != null and wpsub != null,
		"os tres modulos de web push compilam (conjuncao + persistencia + gate)"):
		_finish()
		return

	# --- (D1) cada peca da conjuncao, com assercao propria e motivo proprio ---
	var parts : Dictionary = wpd.call("DeliverParts")
	print("  . pecas medidas nesta maquina: " + str(parts))
	_check(parts.size() >= 5 and parts.has("sender_implemented")
		and parts.has("vapid_key_configured") and parts.has("browser_can_subscribe")
		and parts.has("server_persists") and parts.has("client_submit_wired"),
		"a conjuncao tem uma chave por peca nomeada (%d chaves)" % parts.size())
	_check(bool(parts.get("sender_implemented", false)) == true
		and bool(wpd.call("SenderImplemented")) == true,
		"peca 1 SenderImplemented() e true (o passo python abaixo e a prova de execucao)")

	# Peca 2 — prontidao do companion. Nao e opiniao: e o que uma resposta
	# `GET /push/vapid` disse a este processo. Sem companion na maquina, o unico
	# veredito honesto e "nao sondado".
	var companionReady : bool = bool(parts.get("companion_ready", true))
	_check(companionReady == false
		and companionReady == bool(wpd.call("CompanionReportsPushReady")),
		"peca 2 CompanionReportsPushReady() e false sem companion observado (%s)"
		% str(wpd.call("LastReason")))
	_check(str(wpd.call("CompanionReadyReason")) == "companion_not_probed",
		"peca 2 comeca no estado honesto: %s (nada de 'assume pronto')"
		% str(wpd.call("CompanionReadyReason")))
	var probeKey : String = "BD" + "b".repeat(85)
	var goodBody : String = '{"ready": true, "public_key": "' + probeKey + '"}'
	var parsedGood : Dictionary = wps.call("ObserveCompanionPushResponse", goodBody)
	_check(bool(parsedGood.get("ready", false))
		and bool(wpd.call("CompanionReportsPushReady"))
		and bool(wpd.call("VapidKeyConfigured")),
		"peca 2 vira true pela RESPOSTA do companion, e a publica dela alimenta a peca 3")
	var resetBody : String = '{"ready": false, "reason": "harness_reset"}'
	wps.call("ObserveCompanionPushResponse", resetBody)
	_check(not bool(wpd.call("CompanionReportsPushReady"))
		and not bool(wpd.call("VapidKeyConfigured")),
		"implicacao que nunca pode furar: ready=false limpa a publica observada (nunca chave orfa)")
	var lieBody : String = '{"ready": true}'
	var parsedLie : Dictionary = wps.call("ObserveCompanionPushResponse", lieBody)
	_check(not bool(parsedLie.get("ready", false))
		and str(parsedLie.get("reason", "")) == "ready_without_public_key",
		"resposta dizendo pronto sem publica e recusada (ready_without_public_key), nunca assumida")
	var badJson : Dictionary = wps.call("ObserveCompanionPushResponse", "<html>404</html>")
	_check(not bool(badJson.get("ok", false)) and str(badJson.get("reason", "")) == "bad_response",
		"corpo que nao e JSON vira bad_response (HTML de SPA ou erro de proxy continua sendo 'nao pronto', nunca 'assume pronto')")
	_check(str(wps.call("CompanionPushStatusURL")).ends_with("/push/vapid")
		or str(wps.call("CompanionPushStatusURL")).is_empty(),
		"a pergunta sai para <base do companion>/push/vapid (base vinda de NetworkCommons, nao hardcoded): %s"
		% str(wps.call("CompanionPushStatusURL")))
	wps.call("ObserveCompanionPushResponse", resetBody)

	_check(str(wpd.call("VapidPublicKey")).is_empty()
		and bool(parts.get("vapid_key_configured", true)) == false,
		"peca 3 VapidKeyConfigured() e false sem publica observada")
	wpd.call("ObserveVapidPublicKey", "BD" + "a".repeat(85))
	_check(bool(wpd.call("VapidKeyConfigured")) == true,
		"peca 3 vira true SOZINHA quando a publica de 87 chars e observada")
	wpd.call("ObserveVapidPublicKey", "BD" + "a".repeat(84))
	_check(not bool(wpd.call("VapidKeyConfigured")),
		"peca 3 recusa 86 chars (87 e o tamanho X9.62 em base64url)")
	wpd.call("ObserveVapidPublicKey", "BD" + "a".repeat(84) + "!")
	_check(not bool(wpd.call("VapidKeyConfigured")),
		"peca 3 recusa caractere fora de base64url")
	wpd.call("ObserveVapidPublicKey", "")
	var canBrowser : bool = bool(wpd.call("BrowserCanSubscribe"))
	var browserReason : String = str(wpd.call("LastReason"))
	_check(canBrowser == false and canBrowser == bool(parts.get("browser_can_subscribe", true)),
		"peca 4 BrowserCanSubscribe() e false em headless, igual a conjuncao")
	_check(browserReason == "not_web",
		"peca 4 diz POR QUE: %s (fora do Web nem se pergunta ao navegador)" % browserReason)
	_check(bool(parts.get("server_persists", false)) == true
		and bool(wpd.call("ServerPersistsSubscriptions", _sql)) == true,
		"peca 5 ServerPersistsSubscriptions() e true no Launcher.SQL real (migration 052 aplicada)")
	_check(bool(wpd.call("ServerPersistsSubscriptions", null)) == false,
		"peca 5 com handle nulo devolve false (sonda recusa, nao chora)")
	var wired : bool = bool(wpd.call("ClientSubmitWired"))
	_check(wired == true and wired == bool(parts.get("client_submit_wired", false)),
		"peca 6 ClientSubmitWired() e TRUE no Network real do processo (o RPC landed) e bate com a conjuncao (parts=%s)"
		% str(parts.get("client_submit_wired", "?")))
	# TRUE AQUI é a sonda respondendo pelo nó de produto, não pelo nosso. Cabe ao
	# harness mostrar o contrário também: abaixo a ruler de fonte confere que o RPC
	# esta nos dois arquivos e que a conta sai do PEER, e a sonda é forçada aos dois
	# motivos de falha (no ausente, no sem o metodo) antes de voltar ao mundo real.
	_suitePiece6Landed(wpd)

	# --- (D2) CanDeliver() E das pecas, nao um literal ---
	var conj : bool = true
	for k in parts:
		conj = conj and bool(parts[k])
	_check(bool(wpd.call("CanDeliver")) == conj,
		"CanDeliver() == E das %d pecas medidas (nenhum veredito proprio)" % parts.size())
	_check(bool(wps.call("CanDeliver")) == bool(wpd.call("CanDeliver")),
		"gate e contrato respondem igual (WebPush delega, nao re-inventa)")
	_check(bool(wpd.call("CanOfferToPlayer")) == bool(wpd.call("CanDeliver")),
		"o que se pode oferecer ao jogador == o que se pode entregar")
	_check(not bool(wpd.call("CanDeliver")),
		"gate ainda fechado nesta maquina (peca(s) false acima) — nenhum toggle promete push")

	# --- (D3) persistencia EXECUTADA no SQL do processo ---
	var accountID : int = _fixtureAccount()
	if not _check(accountID > 0, "fixture: conta de teste criada via Launcher.SQL.AddAccount"):
		_finish()
		return
	var payload : Dictionary = {"account_id": GhostAccount, "endpoint": FakeEndpoint,
		"p256dh": FakeP256dh, "auth": FakeAuth}
	var reg : Dictionary = wpsub.call("Register", _sql, accountID, payload)
	_check(bool(reg.get("ok", false)),
		"Register() da sessao grava (reason=%s)" % str(reg.get("reason", "?")))
	var row : Dictionary = wpsub.call("Read", _sql, accountID)
	_check(str(row.get("endpoint", "")) == FakeEndpoint
		and str(row.get("p256dh", "")) == FakeP256dh
		and str(row.get("auth", "")) == FakeAuth
		and int(row.get("updated_at", 0)) > 0,
		"a linha existe com os quatro campos (endpoint/p256dh/auth/updated_at do servidor)")
	var ghostRows : Array = _sql.QueryBindings(
		"SELECT account_id FROM push_subscription WHERE account_id = ?;", [GhostAccount])
	_check(ghostRows.is_empty(),
		"account_id=%d no payload NAO virou linha (autoridade da sessao segura)" % GhostAccount)
	var ownID : Array = _sql.QueryBindings(
		"SELECT account_id FROM push_subscription WHERE account_id = ?;", [accountID])
	_check(ownID.size() == 1 and int(ownID[0]["account_id"]) == accountID,
		"a linha gravada e a da SESSAO (%d), nunca a que o client mandou" % accountID)
	var upsert : Dictionary = wpsub.call("RegisterStrings", _sql, accountID,
		FakeEndpoint, FakeP256dh + "B", FakeAuth)
	var countRow : Array = _sql.QueryBindings(
		"SELECT COUNT(*) AS n FROM push_subscription WHERE account_id = ?;", [accountID])
	_check(bool(upsert.get("ok", false)) and int(countRow[0]["n"]) == 1,
		"re-assinar faz UPSERT (uma linha por conta), nao duplicata")
	_check(not bool(wpsub.call("Register", _sql, 0, payload).get("ok", false)),
		"sessao zero recusada (no_session)")
	_check(not bool(wpsub.call("Register", _sql, -3, payload).get("ok", false)),
		"sessao negativa recusada (no_session)")
	var unknown : Dictionary = wpsub.call("Register", _sql, GhostAccount, payload)
	_check(str(unknown.get("reason", "")) == "unknown_account",
		"sessao de conta que nao existe recusada (unknown_account)")
	var noMaterial : Dictionary = wpsub.call("Register", _sql, accountID,
		{"endpoint": FakeEndpoint, "p256dh": "", "auth": FakeAuth})
	_check(not bool(noMaterial.get("ok", false))
		and str(noMaterial.get("reason", "")) == "missing_p256dh",
		"subscription incompleta recusada com motivo fino: %s" % str(noMaterial.get("reason", "?")))
	var noEndpoint : Dictionary = wpsub.call("Register", _sql, accountID,
		{"endpoint": "", "p256dh": FakeP256dh, "auth": FakeAuth})
	_check(str(noEndpoint.get("reason", "")) == "missing_endpoint",
		"endpoint vazio recusado com missing_endpoint")
	var noAuth : Dictionary = wpsub.call("Register", _sql, accountID,
		{"endpoint": FakeEndpoint, "p256dh": FakeP256dh, "auth": "   "})
	_check(str(noAuth.get("reason", "")) == "missing_auth",
		"auth em branco recusado com missing_auth (nao e so 'campo vazio')")
	var badScheme : Dictionary = wpsub.call("Register", _sql, accountID,
		{"endpoint": "http://push.example/x", "p256dh": FakeP256dh, "auth": FakeAuth})
	_check(str(badScheme.get("reason", "")) == "endpoint_not_https",
		"http para host de verdade recusado (assertion VAPID nunca viaja em claro)")
	var v6 : Dictionary = wpsub.call("Normalize", accountID,
		{"endpoint": "http://[::1]:9/x", "p256dh": FakeP256dh, "auth": FakeAuth})
	_check(bool(v6.get("ok", false)),
		"IPv6 loopback entre colchetes aceito (mesma lista do companion: ::1)")
	var junk : Dictionary = wpsub.call("Register", _sql, accountID,
		{"endpoint": FakeEndpoint, "p256dh": "not*base64", "auth": FakeAuth})
	_check(str(junk.get("reason", "")) == "material_not_base64url",
		"material fora de base64url recusado")
	var inflated : Dictionary = wpsub.call("Register", _sql, accountID,
		{"endpoint": FakeEndpoint, "p256dh": "A".repeat(600), "auth": FakeAuth})
	_check(str(inflated.get("reason", "")) == "too_long_material",
		"material inflado recusado (teto 512)")
	var longEndpoint : Dictionary = wpsub.call("Register", _sql, accountID,
		{"endpoint": "https://x/" + "a".repeat(3000), "p256dh": FakeP256dh, "auth": FakeAuth})
	_check(str(longEndpoint.get("reason", "")) == "too_long_endpoint",
		"endpoint gigante recusado (teto 2048)")
	_check(str(wpsub.call("TargetLabel", FakeEndpoint)) == "http://127.0.0.1:1",
		"TargetLabel so mostra esquema+host:porta (endpoint e credencial bearer, nunca log)")
	_check(str(wpsub.call("TargetLabel", "https://push.example.com/s/abcdef?token=x"))
		== "https://push.example.com",
		"resposta ao client nao vaza caminho nem token do endpoint")
	var submit : Dictionary = wpsub.call("SubmitToServer", FakeEndpoint, FakeP256dh, FakeAuth)
	_check(not bool(submit.get("ok", false)) and str(submit.get("reason", "")) == "not_web",
		"fora de browser o envio e recusado com o motivo CERTO (not_web, nao rpc_not_landed) — reason=%s"
		% str(submit.get("reason", "?")))
	var removed : Dictionary = wpsub.call("Remove", _sql, accountID)
	_check(bool(removed.get("ok", false)),
		"Remove() da propria sessao apaga a linha (unsubscribe do jogador)")
	wpsub.call("Register", _sql, accountID,
		{"endpoint": FakeEndpoint, "p256dh": FakeP256dh + "B", "auth": FakeAuth})

	# --- (E) execucao python: sender real + fila em cima da linha do jogo ---
	var snapshot : String = ProjectSettings.globalize_path("user://web_push_snapshot.db")
	DirAccess.remove_absolute(snapshot)
	_check(_snapshot(snapshot),
		"snapshot do banco real do processo gravado para o python ler a linha do jogo")
	var result_path : String = ProjectSettings.globalize_path("user://web_delivery_py.result")
	var e2e_file : FileAccess = FileAccess.open("user://web_delivery_py_e2e.py", FileAccess.WRITE)
	_check(e2e_file != null, "harness consegue gravar o script e2e em user://")
	if e2e_file == null:
		_finish()
		return
	e2e_file.store_string(PY_E2E)
	e2e_file.close()
	DirAccess.remove_absolute(result_path)
	var rootPath : String = ProjectSettings.globalize_path("res://")
	var e2e_path : String = ProjectSettings.globalize_path("user://web_delivery_py_e2e.py")
	var code : int = OS.execute("python3", [e2e_path, rootPath, snapshot, str(accountID),
		FakeEndpoint, FakeP256dh + "B", FakeAuth, str(GhostAccount), result_path],
		PackedStringArray(), true)
	var py_text : String = _read(result_path)
	print("  . python: " + py_text.replace("\n", " ").strip_edges())
	_check(code == 0, "e2e python (estatica + sender + fila + CLI) exit 0 (rc=%d)" % code)
	_check(py_text.contains("PYSTATIC: OK"),
		"nenhum dos quatro modulos confessa NotImplementedError e send() existe")
	_check(py_text.contains("PYSENDER: OK"),
		"send() EXECUTADO: POST com Authorization: vapid + corpo aes128gcm aberto pelo receiver; 410 -> SubscriptionGone")
	_check(bool(parts.get("sender_implemented", false)) and py_text.contains("PYSENDER: OK"),
		"peca 1 declarada E provada por execucao (a regex antiga exigia o contrario)")
	_check(py_text.contains("PYQUEUE: OK"),
		"linha gravada por Launcher.SQL passou por sweep -> drain (sender fake, estado terminal) e 410 -> push_subscription_gone_410 + subscription apagada")
	_check(py_text.contains("PYCLI: OK"),
		"caminho CLI inteiro (register/sweep/dedup/drain keyless/notify stdout) continua verde")

	# --- (G) a perna do navegador, EXECUTADA ---
	_suiteBrowserLeg(wpd, wps, wpsub, accountID)

	_finish()

# --------------------------------------------------------------------------
# (G) a perna do navegador
# --------------------------------------------------------------------------
#
# `BrowserCanSubscribe()` tem três ramos (not_web / no_bridge / resposta da
# ponte) e até aqui o harness media só o primeiro — `LauncherCommons.isWeb` é
# `static var`, então o segundo é medível nesta máquina sem browser nenhum. Vale
# medir porque é o ramo do mundo real com deploy mal montado: export web cujo
# `head_include` não carregou a ponte. A pergunta honesta desse caso não é "o
# push chegou?", é "esse client caiu no meio do boot ou respondeu não com
# motivo?". O terceiro ramo precisa de um browser de verdade, e esta suíte
# continua sem fingir que o teve — é por ele, e só por ele, que `CanDeliver()`
# ainda fecha em browser. Fica por último de propósito: mexe em estado estático
# (isWeb, publica observada) e restaura antes de sair.
func _suiteBrowserLeg(wpd : Object, wps : Object, wpsub : Object, accountID : int) -> void:
	print("-- (G) perna do navegador: sem ponte cada chamada diz nao com motivo proprio")
	var lc : Object = load("res://sources/launcher/LauncherCommons.gd")
	var probeEndpoint : String = "https://push.example.invalid/s/webdelivery-probe"
	var probeP256dh : String = "BFkU214PYUHq21IuLfahO-BkbVL3rtVMXrCPMNjBS_jzDZtPNeAvNYQHGdmCb"
	var probeAuth : String = "8_kWq9VJ0OZUuBIz1zLvVQ"
	lc.set("isWeb", true)
	_check(bool(wpd.call("BrowserCanSubscribe")) == false and str(wpd.call("LastReason")) == "no_bridge",
		"em browser SEM a ponte a peca 4 responde no_bridge — nem not_web (aqui somos browser), nem true (%s)"
		% str(wpd.call("LastReason")))
	var noKey : Dictionary = wps.call("Subscribe")
	_check(not bool(noKey.get("ok", false)) and str(noKey.get("reason", "")) == "vapid_key_not_observed",
		"Subscribe() recusa ANTES de tocar na ponte quando nao ha publica observada (%s)"
		% str(noKey.get("reason", "?")))
	wpd.call("ObserveVapidPublicKey", "BD" + "a".repeat(85))
	var noBridge : Dictionary = wps.call("Subscribe")
	_check(not bool(noBridge.get("ok", false)) and str(noBridge.get("reason", "")) == "no_bridge",
		"com publica observada e sem ponte, Subscribe() para em no_bridge em vez de chamar metodo que nao existe (%s)"
		% str(noBridge.get("reason", "?")))
	var poll : Dictionary = wps.call("PollSubscription")
	_check(str(poll.get("reason", "")) == "no_bridge",
		"PollSubscription() sem ponte devolve no_bridge, nao um 'pending' que a UI esperaria para sempre (%s)"
		% str(poll.get("reason", "?")))
	var perm : String = str(wps.call("RequestPermission"))
	_check(perm == "unsupported", "RequestPermission() sem ponte devolve unsupported (%s)" % perm)
	# O "Off" do toggle nao pode mentir ao servidor: sem navegador confirmado, a
	# linha do jogador fica onde esta. Medido por contagem antes/depois, nao por
	# confianca no comentario de quem escreveu a funcao.
	var rows : Array = _sql.QueryBindings("SELECT count(*) AS n FROM push_subscription WHERE account_id = ?;", [accountID])
	var before : int = int(rows[0].get("n", -1))
	var un : Dictionary = wps.call("Unsubscribe")
	var rowsAfter : Array = _sql.QueryBindings("SELECT count(*) AS n FROM push_subscription WHERE account_id = ?;", [accountID])
	var after : int = int(rowsAfter[0].get("n", -1))
	_check(str(un.get("reason", "")) == "no_bridge" and after == before,
		"desassinar sem browser devolve no_bridge e NAO apaga linha no servidor (%d -> %d): o Off so confirma quando o navegador confirma"
		% [before, after])
	# A ponta do client para a peca 6: com o RPC landed, o hand-off do material do
	# navegador nao e mais um `rpc_not_landed` declarado — e a propria porta do
	# WebPushSubscription que responde.
	var sent : Dictionary = wpsub.call("SubmitToServer", probeEndpoint, probeP256dh, probeAuth)
	_check(bool(sent.get("ok", false)) and str(sent.get("reason", "")) == "submitted",
		"em browser o hand-off sai por um RPC que EXISTE no no (motivo=%s)" % str(sent.get("reason", "?")))
	_sql.ExecuteBindings("DELETE FROM push_subscription WHERE endpoint = ?;", [probeEndpoint])
	var cleaned : Array = _sql.QueryBindings("SELECT count(*) AS n FROM push_subscription WHERE endpoint = ?;", [probeEndpoint])
	_check(int(cleaned[0].get("n", -1)) == 0, "a sonda nao deixou linha orfa no banco do processo")
	lc.set("isWeb", false)
	wpd.call("ObserveVapidPublicKey", "")
	_check(bool(wpd.call("BrowserCanSubscribe")) == false and str(wpd.call("LastReason")) == "not_web",
		"isWeb e a publica restaurados: a sonda volta a not_web (a suite nao deixou estado para as proximas checks) — %s"
		% str(wpd.call("LastReason")))

# Copia consistente do banco que este processo esta usando. `VACUUM INTO` com
# bind (nada de caminho concatenado dentro do SQL); se a engine recusar o bind,
# checkpoint + copy do arquivo real.
func _snapshot(dst : String) -> bool:
	if bool(_sql.ExecuteBindings("VACUUM INTO ?;", [dst])) and FileAccess.file_exists(dst):
		return true
	_sql.Query("PRAGMA wal_checkpoint(TRUNCATE);")
	var commons : Object = load("res://sources/sql/SQLCommons.gd")
	var relative : String = str(commons.call("GetDBPath"))
	var src : String = ProjectSettings.globalize_path(relative)
	if src.is_empty():
		return false
	return DirAccess.copy_absolute(src, dst) and FileAccess.file_exists(dst)

# Conta de teste SEMPRE com prefixo psh_ (rerun limpa a propria bagunca; nada
# aqui depende de contagem global do banco compartilhado com outros harness). O
# last_timestamp vai para o passado de proposito: e exatamente o que o
# `--push-sweep` do companion procura (conta offline, > 0 e velho).
func _fixtureAccount() -> int:
	var now : int = int(Time.get_unix_time_from_system())
	if not bool(_sql.HasAccount(FixtureUser)):
		var nc : Object = load("res://sources/network/NetworkCommons.gd")
		if not bool(_sql.AddAccount(FixtureUser, "senha-de-teste-1",
				FixtureUser + "@push.test.local", nc.get("AgreementTosVersion"),
				nc.get("AgreementPrivacyVersion"), "203.0.113.9")):
			return -1
	var accountID : int = int(_sql.GetAccountID(FixtureUser))
	if accountID <= 0:
		return -1
	_sql.ExecuteBindings("UPDATE account SET last_timestamp = ? WHERE account_id = ?;",
		[now - 200000, accountID])
	_sql.ExecuteBindings("DELETE FROM push_subscription WHERE account_id = ?;", [accountID])
	_sql.ExecuteBindings("DELETE FROM push_outbox WHERE account_id = ?;", [accountID])
	return accountID
