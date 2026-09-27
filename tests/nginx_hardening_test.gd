extends SceneTree

# nginx_hardening_test.gd — cerca do proxy da fronteira do dinheiro.
#
# O que prendeu aqui, na ordem em que o juíz achou:
#  `deploy/web/nginx.conf` era o ÚNICO caminho de entrada do /checkout/ e do
#  /webhooks/payments e não tinha rate-limit, nem teto de corpo, nem CSP, nem
#  X-Frame-Options, nem `server_tokens off` — enquanto o companion lê
#  `Content-Length` e aloca o buffer inteiro sem plafond (companion/server.py:1239
#  e :1457). Ou seja: não havia NENHUM teto de alocação no caminho do dinheiro.
#
# ESCOPO DA VALIDAÇÃO (declarado, não implícito): esta máquina não tem o binário do
# nginx, então nada aqui é `nginx -t`. O harness LÊ o arquivo, faz parse de
# blocos/diretivas (comentário e aspas tratados) e assesta diretiva por diretiva —
# inclusive qual `location` gana cada URI, na precedência real do nginx
# (`=` > `^~` > regex > prefixo), porque endurecer duas rotas é exatamente o tipo
# de edição que come a terceira. Se o binário EXISTIR no host, o mesmo harness roda
# `nginx -t` num invólucro temporário e o veredito dele vira mais uma check.
# Arquivo validado != servidor vivo, e a suíte E diz qual dos dois foi medido.
#
# Uso:
#   XDG_DATA_HOME=/tmp/impl-sec/.data XDG_CACHE_HOME=/tmp/impl-sec/.cache \
#     timeout 300 godot --headless --path . -s tests/nginx_hardening_test.gd
# Saída: "== NGINX HARDENING: <n> checks, <m> failures ==" (exit code = <m>).

# Alvo da leitura. Por padrão o conf do repo; o env override existe para o
# autoteste de mutação (tests/repo_layout_test.gd e o script de self-test da
# rodada): a mesma suíte roda contra um conf DESPROVIDO do hardening e tem de
# ficar vermelha — sem isso não há prova de que o harness mede alguma coisa.
const CONF_DEFAULT : String = "res://deploy/web/nginx.conf"
var CONF : String = CONF_DEFAULT

var checks : int = 0
var failures : int = 0
var suitesDone : int = 0
var text : String = ""
var stripped : String = ""
var lines : PackedStringArray = []
var froot : Dictionary = {}
var server : Dictionary = {}

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func _read(path : String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var body : String = f.get_as_text()
	f.close()
	return body

func _initialize():
	_run()

# --- parse ------------------------------------------------------------------
#
# Duas passadas: (1) corta comentário por linha respeitando aspa, (2) varre o
# texto resultante montando blocos. O resultado é uma árvore de
# {header, line, directives:[{text,line}], children:[]} — o nó raiz é o nível
# `http`, porque este arquivo é copiado para /etc/nginx/conf.d/default.conf e o
# nginx.conf da imagem o lê DENTRO de `http`.

func _strip_comment(line : String) -> String:
	var out : String = ""
	var inq : String = ""
	for i in line.length():
		var c : String = line[i]
		if inq != "":
			out += c
			if c == inq:
				inq = ""
			continue
		if c == '"' or c == "'":
			inq = c
			out += c
			continue
		if c == "#":
			return out
		out += c
	return out

func _parse(stripped : String) -> Dictionary:
	var r : Dictionary = {"header" = "<file>", "line" = 1, "directives" = [], "children" = []}
	var stack : Array = [r]
	var pending : String = ""
	var pendingLine : int = 1
	var lineno : int = 1
	var inq : String = ""
	for i in stripped.length():
		var c : String = stripped[i]
		if c == "\n":
			lineno += 1
			if inq == "":
				pending = ""
			continue
		if pending.strip_edges() == "" and inq == "":
			pendingLine = lineno
		if inq != "":
			pending += c
			if c == inq:
				inq = ""
			continue
		if c == '"' or c == "'":
			inq = c
			pending += c
			continue
		if c == "{":
			var blk : Dictionary = {"header" = pending.strip_edges(), "line" = pendingLine, "directives" = [], "children" = []}
			stack.back()["children"].append(blk)
			stack.append(blk)
			pending = ""
			continue
		if c == "}":
			if pending.strip_edges() != "":
				stack.back()["directives"].append({"text" = pending.strip_edges(), "line" = pendingLine})
			if stack.size() > 1:
				stack.pop_back()
			pending = ""
			continue
		if c == ";":
			if pending.strip_edges() != "":
				stack.back()["directives"].append({"text" = pending.strip_edges(), "line" = pendingLine})
			pending = ""
			continue
		pending += c
	return r

func _allBlocks(blk : Dictionary, out : Array) -> Array:
	out.append(blk)
	for c in blk["children"]:
		_allBlocks(c, out)
	return out

func _dir(blk : Dictionary, prefix : String) -> String:
	for d in blk["directives"]:
		if str(d["text"]).begins_with(prefix):
			return str(d["text"])
	return ""

func _dirs(blk : Dictionary, prefix : String) -> Array:
	var out : Array = []
	for d in blk["directives"]:
		if str(d["text"]).begins_with(prefix):
			out.append(str(d["text"]))
	return out

func _hasAny(blk : Dictionary, needle : String) -> bool:
	for d in blk["directives"]:
		if str(d["text"]).contains(needle):
			return true
	return false

func _zoneName(stmt : String) -> String:
	var idx : int = stmt.find("zone=")
	if idx < 0:
		return ""
	var rest : String = stmt.substr(idx + 5)
	var end : int = 0
	while end < rest.length() and rest[end] != ":" and rest[end] != " " and rest[end] != ";":
		end += 1
	return rest.substr(0, end)

func _sizeToBytes(directive : String) -> int:
	var m : RegEx = RegEx.create_from_string("([0-9]+)\\s*([kKmMgG]?)")
	if m == null:
		return -1
	var r : RegExMatch = m.search(directive)
	if r == null:
		return -1
	var n : int = int(r.get_string(1))
	var suf : String = r.get_string(2).to_lower()
	if suf == "k":
		return n * 1024
	if suf == "m":
		return n * 1024 * 1024
	return n

# Precedência real de location: `=` exato > `^~` prefixo mais longo > regex na
# ordem do arquivo > prefixo simples mais longo.
func _matchLocation(uri : String) -> Dictionary:
	var exact : Dictionary = {}
	var caret : Dictionary = {}
	var caretLen : int = -1
	var plain : Dictionary = {}
	var plainLen : int = -1
	var regexHit : Dictionary = {}
	for loc in server["children"]:
		var h : String = str(loc["header"])
		if not h.begins_with("location "):
			continue
		var spec : String = h.substr(9).strip_edges()
		if spec.begins_with("= "):
			if uri == spec.substr(2).strip_edges() and exact.is_empty():
				exact = loc
		elif spec.begins_with("^~ "):
			var p : String = spec.substr(3).strip_edges()
			if uri.begins_with(p) and p.length() > caretLen:
				caret = loc
				caretLen = p.length()
		elif spec.begins_with("~"):
			var pat : String = spec.substr(2).strip_edges() if spec.begins_with("~*") else spec.substr(1).strip_edges()
			var re : RegEx = RegEx.create_from_string(pat)
			if re != null and re.search(uri) != null and regexHit.is_empty():
				regexHit = loc
		else:
			if uri.begins_with(spec) and spec.length() > plainLen:
				plain = loc
				plainLen = spec.length()
	if not exact.is_empty():
		return exact
	if not caret.is_empty():
		return caret
	if not regexHit.is_empty():
		return regexHit
	return plain

func _classify(loc : Dictionary) -> String:
	var h : String = str(loc.get("header", ""))
	if h == "":
		return "nenhuma"
	if h.contains("webhooks"):
		return "webhooks"
	if h.contains("checkout"):
		return "checkout"
	if h.contains("= /index.html"):
		return "index"
	if h.contains("= /sw.js"):
		return "sw"
	if h.contains("= /ads_bridge.js"):
		return "ads"
	if h.contains("worklet"):
		return "workers"
	if h.contains("/music/"):
		return "music"
	if h.contains("/landing/"):
		return "landing"
	if h == "location /":
		return "catchall"
	return "outro:" + h

# --- suítes -----------------------------------------------------------------

func _suiteShape() -> void:
	print("-- A) forma do arquivo (parse sem nginx: blocos, chaves, aspas)")
	# A contagem é feita sobre o texto JÁ sem comentários (`stripped`), com a mesma
	# regra de aspa do parser: contar `{` no texto cru soma os de comentário (e o
	# conf tem `/checkout/{intents,...}` num comentário desde antes desta rodada),
	# o que daria um falso vermelho.
	var opens : int = 0
	var closes : int = 0
	var inq : String = ""
	for i in stripped.length():
		var c : String = stripped[i]
		if inq != "":
			if c == inq:
				inq = ""
			continue
		if c == '"' or c == "'":
			inq = c
			continue
		if c == "{":
			opens += 1
		elif c == "}":
			closes += 1
	var blocks : Array = _allBlocks(froot, [])
	_check(not server.is_empty(), "o arquivo tem um bloco server (proxy único do jogo)")
	var servers : int = 0
	for blk in froot["children"]:
		if str(blk["header"]).begins_with("server"):
			servers += 1
	_check(servers == 1, "exatamente um bloco server: %d" % servers)
	# Comentario/aspas: a contagem de chaves é feita com o MESMO par que monta os
	# blocos; se divergirem, o parse dos blocos abaixo não é confiável.
	_check(opens == closes, "toda `{` tem um `}` fora de comentário e aspas (%d/%d)" % [opens, closes])
	_check(blocks.size() - 1 == opens, "o parser fechou todos os blocos que abriu (%d blocos / %d `{`)" % [blocks.size() - 1, opens])
	var locations : Array = []
	for loc in server["children"]:
		if str(loc["header"]).begins_with("location "):
			locations.append(loc)
	_check(locations.size() >= 8, "todas as locations continuam de pé (%d)" % locations.size())
	# O `add_header` do nginx NÃO herda entre blocos (comentário na linha 6 do
	# conf): mover COOP/COEP para o server e achatar as locations derruba o boot
	# do client web (SharedArrayBuffer) — o defeito original que o arquivo carrega.
	var docs : Array = []
	var proxied : int = 0
	for loc in locations:
		if _dir(loc, "proxy_pass") != "":
			proxied += 1
			continue
		var hh : String = str(loc["header"])
		_check(_hasAny(loc, "Cross-Origin-Opener-Policy") and _hasAny(loc, "Cross-Origin-Embedder-Policy"),
			"%s conserva COOP+COEP" % hh.replace("location ", ""))
		if hh.contains(".html") or hh.contains(".js") or hh.contains("landing") or hh.strip_edges() == "location /":
			docs.append(loc)
	_check(proxied == 2, "dois blocos proxied (checkout + webhooks): %d" % proxied)
	for loc in docs:
		var hh2 : String = str(loc["header"]).replace("location ", "")
		_check(_hasAny(loc, "X-Frame-Options") and _hasAny(loc, "Content-Security-Policy"),
			"%s (documento/roteiro) tem X-Frame-Options + CSP" % hh2)
	suitesDone += 1

func _suiteHttpLevel() -> void:
	print("-- B) contexto: o que só pode viver em `http`")
	var zones : Array = _dirs(froot, "limit_req_zone")
	_check(zones.size() >= 2, "as zonas de rate-limit estão no nível do arquivo (http), não dentro do server: %d" % zones.size())
	_check(_dirs(server, "limit_req_zone").is_empty(), "nenhum `limit_req_zone` dentro do server (contexto errado = nginx não sobe)")
	_check(_dir(server, "server_tokens") == "server_tokens off", "`server_tokens off` no server (%s)" % _dir(server, "server_tokens"))
	_check(_dir(server, "limit_req_status").contains("429"), "estouro de zona responde 429 (retry-able), não o 503 mudo")
	var names : Dictionary = {}
	for z in zones:
		var nm : String = _zoneName(str(z))
		if nm == "":
			continue
		names[nm] = true
		_check(str(z).contains("rate="), "zona %s declara rate= (sem taxa ela não limita nada)" % nm)
		_check(str(z).contains("$binary_remote_addr"), "zona %s é por peer TCP, não por header forjável" % nm)
	_check(names.has("shambleta_checkout"), "zona do checkout declarada")
	_check(names.has("shambleta_webhook"), "zona do webhook declarada")
	suitesDone += 1

func _suiteMoneyRoutes() -> void:
	print("-- C) as rotas do dinheiro: taxa, corpo, headers, corpo intacto")
	var money : Array = []
	for loc in server["children"]:
		var h : String = str(loc["header"])
		if h.contains("webhooks") or h.contains("checkout"):
			money.append(loc)
	_check(money.size() == 2, "exatamente dois blocos de proxy do dinheiro: %d" % money.size())
	var usedZones : Dictionary = {}
	for loc in money:
		var tag : String = str(loc["header"]).replace("location ", "")
		var lr : String = _dir(loc, "limit_req ")
		_check(lr != "", "%s limita requisição (%s)" % [tag, lr])
		var used : String = _zoneName(lr)
		usedZones[used] = true
		_check(_dirs(froot, "limit_req_zone").any(func(z): return _zoneName(str(z)) == used),
			"%s usa zona DECLARADA (%s) — zona órfã é rate-limit de fachada" % [tag, used])
		_check(lr.contains("nodelay"), "%s usa nodelay (burst não vira latência no caminho do pagamento)" % tag)
		var body : String = _dir(loc, "client_max_body_size")
		_check(body != "", "%s tem teto de corpo (%s)" % [tag, body])
		var kb : int = _sizeToBytes(body)
		_check(kb > 0 and kb <= 65536, "%s: teto de corpo cabe JSON (<= 64 KiB): %d bytes" % [tag, kb])
		_check(_dir(loc, "client_body_timeout") != "", "%s limita corpo lento (slow-loris não segura worker)" % tag)
		_check(_dir(loc, "client_header_timeout") != "", "%s limita cabeçalho lento" % tag)
		var csp : String = _dir(loc, "add_header Content-Security-Policy")
		_check(csp.contains("default-src 'none'"), "%s: CSP default-src 'none' (a resposta é JSON, nada deve carregar)" % tag)
		_check(csp.contains("frame-ancestors 'none'"), "%s: CSP proíbe enquadramento" % tag)
		_check(csp.contains("always"), "%s: CSP com `always` (sem isso o header sumiria no 4xx/5xx)" % tag)
		_check(_dir(loc, "add_header X-Frame-Options").contains("DENY"), "%s: X-Frame-Options DENY" % tag)
		_check(_dir(loc, "add_header X-Content-Type-Options").contains("nosniff"), "%s: nosniff" % tag)
		_check(_dir(loc, "add_header Referrer-Policy") != "", "%s: Referrer-Policy (token de retorno não vaza em Referer)" % tag)
		# O proxy não pode reescrever o caminho do dinheiro: a assinatura do
		# provedor é HMAC do corpo e o companion roteia por path.
		_check(_dir(loc, "proxy_pass").contains("$shambleta_companion"), "%s: proxy_pass por variável + resolver (companion atrasado não derruba o boot)" % tag)
		_check(_dir(loc, "resolver").contains("127.0.0.11"), "%s: resolver da rede do compose" % tag)
		_check(_dir(loc, "proxy_http_version").contains("1.1"), "%s: HTTP/1.1 explícito" % tag)
		_check(_dir(loc, "proxy_set_header Host").contains("$host"), "%s: Host repassado" % tag)
		_check(_dir(loc, "proxy_set_header X-Forwarded-Proto").contains("$scheme"), "%s: X-Forwarded-Proto repassado (o companion decide TLS por ele)" % tag)
		_check(not _hasAny(loc, "sub_filter"), "%s: nenhum sub_filter (reescrever corpo quebraria o HMAC)" % tag)
		_check(not _hasAny(loc, "proxy_set_header Content-Type"), "%s: Content-Type do request não é reescrito" % tag)
		_check(not _hasAny(loc, "if "), "%s: nenhum `if` de IP (a autenticação é o HMAC; cerca de faixa não medida seria fachada)" % tag)
		_check(str(loc["header"]).contains("^~"), "%s: prefixo com `^~` (regex posterior não rouba a rota)" % tag)
	for z in _dirs(froot, "limit_req_zone"):
		var nm : String = _zoneName(str(z))
		_check(usedZones.has(nm), "zona %s é usada por alguma location (zona declarada e não usada é enfeite)" % nm)
	suitesDone += 1

func _suiteRouting() -> void:
	print("-- D) precedência: qual location gana cada URI (endurecer não pode comer rota)")
	var cases : Array = [
		["/checkout/intents", "checkout"],
		["/checkout/simulate", "checkout"],
		["/webhooks/payments", "webhooks"],
		["/webhooks/payments?topic=payment", "webhooks"],
		["/index.html", "index"],
		["/index.wasm", "catchall"],
		["/index.service.worker.js", "workers"],
		["/checkout_return.html", "catchall"],
		["/music/tema.ogg", "music"],
		["/landing/index.html", "landing"],
		["/ads_bridge.js", "ads"],
		["/sw.js", "sw"],
	]
	for c in cases:
		var uri : String = str(c[0])
		var loc : Dictionary = _matchLocation(uri.split("?")[0])
		var got : String = _classify(loc)
		_check(got == str(c[1]), "%s -> %s (esperado %s)" % [uri, got, str(c[1])])
	var ret : Dictionary = _matchLocation("/checkout_return.html")
	_check(_dir(ret, "proxy_pass") == "", "/checkout_return.html é SERVIDO, não proxado — é a back_url do painel do provedor")
	var wh : Dictionary = _matchLocation("/webhooks/payments")
	_check(_dir(wh, "limit_req ") != "", "o caminho que o provedor POSTA está de fato sob o rate-limit")
	var co : Dictionary = _matchLocation("/checkout/intents")
	_check(_dir(co, "client_max_body_size") != "", "o caminho que o browser POSTA está sob o teto de corpo")
	suitesDone += 1

func _nginxBinary() -> String:
	# `which` é a sonda honesta: `OS.execute` de um binário ausente devolve código
	# que varia por plataforma e não prova nada sobre o nginx.
	var out : PackedStringArray = []
	if OS.execute("which", ["nginx"], out, true) == 0 and out.size() > 0:
		var p : String = out[0].strip_edges()
		if p != "":
			return p
	return ""

func _suiteHonestScope() -> void:
	print("-- E) o que este harness NÃO fez (e o arquivo não pode fingir que fez)")
	var bin : String = _nginxBinary()
	if bin == "":
		_check(text.contains("nginx -t") and text.contains("VALIDADO ONDE"),
			"nginx AUSENTE neste host: o conf declara que a validação é de diretiva, não de servidor vivo")
		print("       (nada aqui foi validado por `nginx -t`; parse de arquivo apenas)")
	else:
		# Saída única de propósito: com dois `return` no meio, a guarda de
		# conclusão lá embaixo não rodava no ramo mais comum (nginx ausente) e
		# o harness se auto-declarava incompleto num run perfeito.
		var dir : String = ProjectSettings.globalize_path("user://nginx-t")
		DirAccess.make_dir_recursive_absolute(dir)
		var wrapper : String = dir + "/nginx.conf"
		var wf : FileAccess = FileAccess.open(wrapper, FileAccess.WRITE)
		if wf == null:
			_check(false, "não gravei o invólucro de `nginx -t` em " + wrapper)
		else:
			wf.store_string("pid %s/nginx.pid;\nerror_log %s/error.log warn;\nevents { worker_connections 16; }\nhttp {\n  access_log off;\n  include %s;\n}\n" % [dir, dir, ProjectSettings.globalize_path(CONF)])
			wf.close()
			var out : PackedStringArray = []
			var code : int = OS.execute(bin, ["-t", "-p", dir, "-c", wrapper], out, true)
			_check(code == 0, "`nginx -t` aceitou o arquivo (exit %d)" % code)
			if code != 0:
				for l in out:
					print("       " + str(l))
	suitesDone += 1

func _run() -> void:
	var override : String = OS.get_environment("SHAMBLETA_NGX_CONF")
	if override != "":
		CONF = override
		print("       alvo: %s (override de autoteste)" % CONF)
	text = _read(CONF)
	if text == "":
		_check(false, "li %s" % CONF)
		print("== NGINX HARDENING: %d checks, %d failures ==" % [checks, failures])
		quit(failures)
		return
	lines = text.split("\n", false)
	stripped = ""
	for ln in lines:
		stripped += _strip_comment(ln) + "\n"
	froot = _parse(stripped)
	for blk in froot["children"]:
		if str(blk["header"]).begins_with("server"):
			server = blk
	_suiteShape()
	_suiteHttpLevel()
	_suiteMoneyRoutes()
	_suiteRouting()
	_suiteHonestScope()
	_check(suitesDone == 5, "as 5 suítes rodaram até o fim (run cortado no meio não pode imprimir verde; o log é lido pelo ci_gate_log, esta linha lê o próprio verde)")
	print("== NGINX HARDENING: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
