extends SceneTree

# nginx_hardening_test.gd — cerca do proxy da fronteira do dinheiro.
#
# O que prendeu aqui, na ordem em que o juíz achou:
#  `deploy/web/nginx.conf` era o ÚNICO caminho de entrada do /checkout/ e do
#  /webhooks/payments e não tinha rate-limit, nem teto de corpo, nem CSP, nem
#  X-Frame-Options, nem `server_tokens off` — enquanto o companion lê
#  `Content-Length` e aloca o buffer inteiro sem plafond (companion/server.py:1405
#  e :1467). Ou seja: não havia NENHUM teto de alocação no caminho do dinheiro.
#
# ESCOPO DA VALIDAÇÃO (declarado, não implícito): o harness LÊ o arquivo, faz parse
# de blocos/diretivas (comentário e aspas tratados) e assesta diretiva por diretiva —
# inclusive qual `location` gana cada URI, na precedência real do nginx
# (`=` > `^~` > regex > prefixo), porque endurecer duas rotas é exatamente o tipo
# de edição que come a terceira, e julga o CONTEXTO da diretiva: o que o nginx só
# aceita em `http|server` nunca pode aparecer num bloco de rota. Essa metade existe
# porque `nginx -t` não roda em host sem binário, e foi assim que
# `client_header_timeout` viveu em quatro `location` até o build da imagem web
# recusar o arquivo inteiro, em 2026-09-30. Além disso há `nginx -t`, e a suíte E diz QUAL dos
# três estados ocorreu neste run:
#   1. binário no host  -> `nginx -t` roda aqui, num invólucro temporário, e o
#      veredito dele é uma check;
#   2. binário ausente  -> nada é validado neste host e isto é dito por NOME
#      (`[SKIP] nginx -t neste host` + a linha `== NGINX HARDENING SKIPS: … ==`),
#      com a validação cobrada no build: `deploy/web/Dockerfile` tem de ter a linha
#      executável `RUN nginx -t` (sem `|| true`). Faltar as duas coisas é VERMELHO,
#      não "degradar para ler o próprio doc" — era isso a suíte E antes do #89;
#   3. em CI            -> o job `container-images` roda `nginx -t` DENTRO da imagem
#      web buildada; a presença desse step no grafo é o que scripts/check_ci.sh
#      confere (com canário plantado), porque a régua que sobrevive num host sem
#      nginx tem de ser estrutural, e não prosa.
# Arquivo validado != servidor vivo, e a suíte E diz qual dos estados foi medido.
#
# Uso:
#   XDG_DATA_HOME=/tmp/impl-sec/.data XDG_CACHE_HOME=/tmp/impl-sec/.cache \
#     timeout 300 godot --headless --path . -s tests/nginx_hardening_test.gd
# Saída: "== NGINX HARDENING: <n> checks, <m> failures ==" (exit code = <m>).

# Alvo da leitura. Por padrão o conf do repo; o env override é a porta de quem
# revisa: roda-se a mesma suíte contra um conf DESPROVIDO do hardening, e ela tem
# de ficar vermelha. Nada no repo usa a porta hoje — o que prova a mordida sem
# binário no host são os controles injetados (B, C, F, G), que plantam na própria
# função julgada o que a assersão precisa acusar.
const CONF_DEFAULT : String = "res://deploy/web/nginx.conf"
var CONF : String = CONF_DEFAULT

var checks : int = 0
var failures : int = 0
var suitesDone : int = 0
var skips : int = 0
var skipNames : PackedStringArray = PackedStringArray()
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

# As diretivas cujo contexto é http|server e NUNCA `location`. Lista fechada de
# propósito: ela só enfileira cujo contexto se enuncia sem consulta — um item
# errado numa régua de contexto faz config válido virar vermelho, e isso é a mesma
# doença que a régua combate. O resto da superfície continua coberto pelo
# `nginx -t` (suíte E, e o build da imagem).
const NO_LOCATION_CONTEXT : Array[String] = [
	"client_header_timeout", "client_header_buffer_size", "large_client_header_buffers",
	"server_tokens", "limit_req_status",
]

# As violações do tipo "diretiva de http|server plantada dentro de uma rota". É a
# função que a suíte B cobra E que o controle injeta: medir uma cópia dela seria a
# régua aprovando o próprio desenho. `limit_except` e qualquer bloco dentro de
# `location` contam como contexto de rota, porque é o que ele é.
func _Misplaced(tree : Dictionary, inLocation : bool = false) -> Array[String]:
	var out : Array[String] = []
	var here : bool = inLocation or str(tree["header"]).begins_with("location")
	if here:
		for name in NO_LOCATION_CONTEXT:
			if _dir(tree, name) != "":
				out.append("%s: `%s` (contexto http|server apenas)" % [str(tree["header"]), name])
	for c in tree["children"]:
		out.append_array(_Misplaced(c, here))
	return out

# Uma diretiva de várias linhas chega do `_parse()` em FRAGMENTOS: o parser
# reinicia o `pending` a cada `\n` (é o que lhe deixa tratar bloco e comentário),
# então julgar o conteúdo de um `gzip_types` de duas linhas pelo primeiro
# fragmento é ler a metade e chamar isso de asserção. Aqui as linhas são juntadas
# até o `;`, no texto já sem comentário.
func _stmt(prefix : String) -> String:
	var out : String = ""
	var aberto : bool = false
	for raw in stripped.split("\n", false):
		var s : String = String(raw).strip_edges()
		if not aberto:
			if not s.begins_with(prefix):
				continue
			aberto = true
		out += s + " "
		if s.ends_with(";"):
			break
	return out.strip_edges()

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
	if h.contains("push"):
		return "push"
	if h.contains("catalog"):
		return "catalog"
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
	var proxied : Array = []
	for loc in locations:
		if _dir(loc, "proxy_pass") != "":
			proxied.append(_classify(loc))
			continue
		var hh : String = str(loc["header"])
		_check(_hasAny(loc, "Cross-Origin-Opener-Policy") and _hasAny(loc, "Cross-Origin-Embedder-Policy"),
			"%s conserva COOP+COEP" % hh.replace("location ", ""))
		if hh.contains(".html") or hh.contains(".js") or hh.contains("landing") or hh.strip_edges() == "location /":
			docs.append(loc)
	# Lista, não contagem: "3 proxied" passa igual quando o bloco do dinheiro sai e
	# entra um terceiro caminho qualquer. O que se quer é exatamente este conjunto.
	# `catalog` entrou em 2026-09-28: é a primeira rota proxied que é LEITURA DE
	# PREÇO — nem dinheiro (checkout/webhooks), nem prontidão (push). A suíte G
	# confere que ela não virou porta de escrita.
	var wantProxied : Array = ["catalog", "checkout", "push", "webhooks"]
	proxied.sort()
	_check(proxied == wantProxied,
		"os blocos proxied são exatamente catalog + checkout + push/vapid + webhooks: %s" % str(proxied))
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
	# Contexto é o que o `nginx -t` sabe e este host não tem binário a quem perguntar.
	# Em 2026-09-30 o build da imagem web recusou o arquivo: `client_header_timeout`
	# vivia em quatro `location`, e o nginx respondeu `"client_header_timeout"
	# directive is not allowed here`. A suíte E declara o SKIP do binário ausente em
	# vez de fingir validação — o que faltava era uma régua que não dependesse de ter
	# o nginx na mão, porque foi exatamente a classe que chegou ao prod quebrada.
	var misplaced : Array[String] = _Misplaced(froot)
	var rotas : int = 0
	for blk in _allBlocks(froot, []):
		if str(blk["header"]).begins_with("location"):
			rotas += 1
	_check(rotas >= 8, "a varredura de contexto julga %d blocos de rota — abaixo disso é varredura muda, não inocência" % rotas)
	_check(misplaced.is_empty(), "nenhuma diretiva de contexto http|server dentro de rota: %s" % str(misplaced))
	_check(_dir(server, "client_header_timeout") != "", "o teto de cabeçalho lento mora no `server` (%s)" % _dir(server, "client_header_timeout"))
	# Mordida, nos dois lados: a rota plantada com duas diretivas de http|server — uma
	# delas dentro de `limit_except`, que é contexto de rota — tem de ser acusada nas
	# duas, e a lícita no contexto (`client_body_timeout`) tem de sair limpa. Sem o
	# lado limpo, "acusou" pode ser só um predicado que acusa tudo.
	var plantada : Dictionary = _parse("location = /x {\n\tclient_header_timeout 10s;\n\tclient_body_timeout 10s;\n\tlimit_except GET {\n\t\tserver_tokens off;\n\t}\n}\n")
	var mordidas : Array[String] = _Misplaced(plantada)
	_check(mordidas.size() == 2, "controle: `client_header_timeout` na rota e `server_tokens` dentro de `limit_except` são ambas acusadas: %s" % str(mordidas))
	_check(not mordidas.any(func(v): return str(v).contains("client_body_timeout")),
			"controle: `client_body_timeout` em rota NÃO é acusada — essa tem contexto em location")
	# `text/html` não se lista em `gzip_types`: o nginx comprime text/html sempre, e a
	# listagem rende o `[warn] duplicate MIME type "text/html"` que o build imprime.
	# Config que grita sobre linha inócua é config que passa a ser lido como ruído nas
	# linhas que importam.
	var gz : String = _stmt("gzip_types ")
	_check(gz.contains(";"), "o conf declara `gzip_types` (%s)" % gz)
	_check(not gz.contains("text/html"), "`gzip_types` não lista text/html, que o nginx já comprime sempre: %s" % gz)
	# O `gzip_types` do conf ocupa DUAS linhas, e `_parse()` corta a diretiva no
	# primeiro `\n`. Sem o `_stmt` acima a assersão de `text/html` teria olhado só a
	# metade de cima — o fixture prova que a segunda linha é vista, e prova também
	# que a leitura não engole a statement seguinte.
	var guardado : String = stripped
	stripped = "    gzip_types application/wasm application/json\n               application/octet-stream text/html;\n    gzip_min_length 1024;\n"
	var junta : String = _stmt("gzip_types ")
	stripped = guardado
	_check(junta.contains("text/html;") and not junta.contains("gzip_min_length"),
			"controle: `_stmt` alcança a segunda linha da diretiva e para no `;` (%s)" % junta)
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
		# O teto de CABEÇALHO não se declara aqui em cima: `client_header_timeout` tem
		# contexto http|server e posto dentro de `location` o nginx recusa o arquivo
		# inteiro. A suíte B cobra o valor no `server` e proíbe a linha em toda rota.
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
		# Zona órfã é rate-limit de fachada — e a régua tem de olhar TODAS as
		# locations, não só as do dinheiro: desde que a rota de prontidão do push
		# entrou, uma zona declarada e usada apenas por ela passaria como morta.
		var usedSomewhere : bool = usedZones.has(nm)
		for loc in server["children"]:
			if _zoneName(_dir(loc, "limit_req ")) == nm:
				usedSomewhere = true
		_check(usedSomewhere, "zona %s é usada por alguma location (zona declarada e não usada é enfeite)" % nm)
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
		# A rota de prontidão é exata; o resto de /push/ tem de continuar sendo o
		# SPA. É esta dupla que prova que abrir uma rota não abriu a fila.
		["/push/vapid", "push"],
		["/push/test", "catchall"],
		["/push/queue", "catchall"],
		# O catálogo é exato pelo mesmo motivo do vapid: `= /catalog` leva só a leitura
		# de preço ao companion. Estas duas linhas são o que impede um `^~ /catalog`
		# de fachada — com prefixo, qualquer caminho novo embaixo dele alcançaria o
		# processo que segura o SQLite.
		["/catalog", "catalog"],
		["/catalog/", "catchall"],
		["/catalogx", "catchall"],
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

# F) a rota de prontidão do push — aberta em 2026-09-27 para `GET /push/vapid`
# chegar a um browser (peças 2 e 3 de `WebPushDelivery.DeliverParts()`). Ela é a
# primeira rota proxied que NÃO é o dinheiro, e por isso o risco aqui é o oposto
# do de C: não a falta de cerca, e sim ela virar porta para a fila. As duas
# checks que importam mais que as demais são `= /push/vapid` (exata) e a
# ausência de qualquer prefixo `/push` no proxy.
func _suitePushRoute() -> void:
	print("-- F) prontidão do push: uma rota exata, GET-only, e nada além dela")
	var push : Dictionary = _matchLocation("/push/vapid")
	_check(_classify(push) == "push", "existe um bloco para /push/vapid (%s)" % str(push.get("header", "nenhum")))
	if _classify(push) != "push":
		suitesDone += 1
		return
	var tag : String = str(push["header"]).replace("location ", "")
	_check(tag.begins_with("= "), "%s é EXATO (`=`): `^~ /push/` ou prefixo levaria POST /push/test para o companion por cima do token de admin" % tag)
	_check(_dir(push, "proxy_pass").contains("$shambleta_companion"), "%s: proxy por variável + resolver (companion atrasado não derruba o boot)" % tag)
	_check(_dir(push, "resolver").contains("127.0.0.11"), "%s: resolver da rede do compose" % tag)
	_check(_dir(push, "limit_req ") != "", "%s: tem rate-limit — é a rota batida a cada boot de aba" % tag)
	var zone : String = _zoneName(_dir(push, "limit_req "))
	_check(zone.contains("push"), "%s: usa zona própria (%s), não a do webhook de 25 r/s" % [tag, zone])
	_check(_dirs(froot, "limit_req_zone").any(func(z): return _zoneName(str(z)) == zone),
		"%s: zona %s declarada no nível http (limit_req de zona inexistente é nginx que não sobe)" % [tag, zone])
	_check(_dir(push, "limit_req ").contains("nodelay"), "%s: nodelay (burst não vira latência no boot)" % tag)
	var le : Dictionary = {}
	for child in push["children"]:
		if str(child["header"]).begins_with("limit_except"):
			le = child
	_check(not le.is_empty(), "%s: `limit_except` presente — sem ele qualquer método alcançaria o companion" % tag)
	if not le.is_empty():
		_check(str(le["header"]).contains("GET"), "%s: a lista de métodos lícitos é GET (`limit_except GET` trava os outros)" % tag)
		_check(_hasAny(le, "deny all"), "%s: `deny all` dentro de limit_except (lista sem trava é decorativa)" % tag)
	_check(_dir(push, "client_max_body_size") != "", "%s: teto de corpo declarado mesmo em GET (o único plafond do caminho é o proxy)" % tag)
	_check(_sizeToBytes(_dir(push, "client_max_body_size")) <= 4096, "%s: teto de corpo pequeno — a rota não tem escrita" % tag)
	_check(_dir(push, "client_body_timeout") != "", "%s: timeout de corpo (slow-loris não segura worker; o de cabeçalho é do `server`, suíte B)" % tag)
	_check(_dir(push, "add_header Content-Security-Policy").contains("default-src 'none'"), "%s: CSP fechada (a resposta é JSON de estado)" % tag)
	_check(_dir(push, "add_header X-Content-Type-Options").contains("nosniff"), "%s: nosniff" % tag)
	_check(_dir(push, "add_header Referrer-Policy") != "", "%s: Referrer-Policy" % tag)
	_check(_dir(push, "add_header Cache-Control").contains("max-age"), "%s: Cache-Control com max-age (sem teto, cada aba bate no companion; sem cache, o toggle abre devagar)" % tag)
	_check(_dir(push, "add_header Cache-Control").contains("always"), "%s: headers com `always` (somem no 4xx/5xx sem isso)" % tag)
	_check(_dir(push, "sub_filter") == "", "%s: nenhum sub_filter (reescrever o corpo quebraria o JSON lido por `ObserveCompanionPushResponse`)" % tag)
	# A cerca inversa: nenhum OUTRO caminho /push pode estar proxied.
	var leaked : Array = []
	for loc in server["children"]:
		var h : String = str(loc["header"])
		if not h.begins_with("location "):
			continue
		if _dir(loc, "proxy_pass") == "":
			continue
		var spec : String = h.substr(9).strip_edges()
		if spec.contains("/push") and not spec.contains("/push/vapid"):
			leaked.append(h)
	_check(leaked.is_empty(), "nenhum prefixo /push* proxied além da rota exata (fila fora da fronteira pública): %s" % str(leaked))
	for uri in ["/push/test", "/push/queue", "/push/send"]:
		var other : Dictionary = _matchLocation(uri)
		_check(_dir(other, "proxy_pass") == "", "%s cai em bloco servido, não no companion (%s)" % [uri, str(other.get("header", "nenhum"))])
	suitesDone += 1

# G) a rota de leitura de preço — `GET /catalog`, aberta em 2026-09-28. O risco é o
# mesmo da F e por um motivo novo: é a primeira rota proxied cujo corpo é montado
# contra o SQLite do companion. Se ela deixar de ser exata, ou deixar de ser
# GET-only, o browser alcança caminhos que hoje só existem atrás do rate-limit do
# dinheiro. A segunda metade da suíte é a identidade: o `/catalog` que a página lê
# tem de ser o MESMO gate que o checkout usa, senão a vitrine volta a anunciar o
# passe de uma temporada que o `POST /checkout/intents` recusa.
func _suiteCatalogRoute() -> void:
	print("-- G) leitura de preço: uma rota exata, GET-only, e o mesmo gate do checkout")
	var cat : Dictionary = _matchLocation("/catalog")
	_check(_classify(cat) == "catalog", "existe um bloco para /catalog (%s)" % str(cat.get("header", "nenhum")))
	if _classify(cat) != "catalog":
		suitesDone += 1
		return
	var tag : String = str(cat["header"]).replace("location ", "")
	_check(tag.begins_with("= "), "%s é EXATO (`=`): prefixo levaria qualquer caminho novo abaixo de /catalog ao companion" % tag)
	_check(_dir(cat, "proxy_pass").contains("$shambleta_companion"), "%s: proxy por variável + resolver" % tag)
	_check(_dir(cat, "resolver").contains("127.0.0.11"), "%s: resolver da rede do compose" % tag)
	var zone : String = _zoneName(_dir(cat, "limit_req "))
	_check(zone.contains("catalog"), "%s: usa zona própria (%s), não a do webhook de 25 r/s" % [tag, zone])
	_check(_dirs(froot, "limit_req_zone").any(func(z): return _zoneName(str(z)) == zone),
		"%s: zona %s declarada no nível http" % [tag, zone])
	_check(_dir(cat, "limit_req ").contains("nodelay"), "%s: nodelay" % tag)
	var le : Dictionary = {}
	for child in cat["children"]:
		if str(child["header"]).begins_with("limit_except"):
			le = child
	_check(not le.is_empty(), "%s: `limit_except` presente — sem ele POST/PUT alcançariam o companion" % tag)
	if not le.is_empty():
		_check(str(le["header"]).contains("GET"), "%s: a lista de métodos lícitos é GET" % tag)
		_check(_hasAny(le, "deny all"), "%s: `deny all` dentro de limit_except" % tag)
	_check(_sizeToBytes(_dir(cat, "client_max_body_size")) <= 4096,
		"%s: teto de corpo pequeno, a rota não tem escrita (%s)" % [tag, _dir(cat, "client_max_body_size")])
	_check(_dir(cat, "client_body_timeout") != "",
		"%s: timeout de corpo (o de cabeçalho é do `server`, suíte B)" % tag)
	_check(_dir(cat, "add_header Content-Security-Policy").contains("default-src 'none'"),
		"%s: CSP fechada (a resposta é JSON de preço)" % tag)
	_check(_dir(cat, "add_header X-Content-Type-Options").contains("nosniff"), "%s: nosniff" % tag)
	_check(_dir(cat, "add_header Cache-Control").contains("max-age"),
		"%s: Cache-Control com max-age (sem teto, cada aba bate no SQLite; sem cache, preço velho nunca refresca)" % tag)
	_check(_dir(cat, "sub_filter") == "", "%s: nenhum sub_filter (reescrever o corpo quebraria o JSON)" % tag)
	var leaked : Array = []
	for loc in server["children"]:
		var h : String = str(loc["header"])
		if not h.begins_with("location ") or _dir(loc, "proxy_pass") == "":
			continue
		var spec : String = h.substr(9).strip_edges()
		if spec.contains("catalog") and not spec.begins_with("= /catalog"):
			leaked.append(spec)
	_check(leaked.is_empty(), "nenhum OUTRO caminho com `catalog` está proxied: %s" % str(leaked))
	# Identidade das camadas: a marcação de temporada do `/catalog` é o MESMO gate do
	# checkout. Se `public_catalog` parar de chamar `season_offer_status`, a vitrine
	# volta a ser um texto que a frente do dinheiro desmente — e nada neste arquivo
	# perceberia, porque o conf continua verde.
	var py : String = _read("res://companion/server.py")
	_check(not py.is_empty(), "companion/server.py foi lido para a régua de identidade")
	if not py.is_empty():
		_check(py.contains("def public_catalog("), "o companion tem a função que monta o corpo de /catalog")
		_check(py.contains("season_offer_status(con, catalog, sku)"),
			"e `public_catalog` marca o passe com o MESMO gate que o checkout usa, não com uma régua paralela")
		_check(py.contains("\"store_unavailable\""),
			"banco inacessível marca o passe como indisponível (display fail-closed, como o gate)")
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

func _dockerfileRunLines(text : String) -> PackedStringArray:
	# Só linha executável de Dockerfile: comentário não builda nada. `RUN` é o
	# degrau que executa no build; o que importa aqui é existir e não ser
	# desarmado por `|| true` (smoke que não barra é o smoke que não existe).
	var out : PackedStringArray = PackedStringArray()
	for l in text.split("\n", false):
		var s : String = l.strip_edges()
		if s == "" or s.begins_with("#"):
			continue
		if s.begins_with("RUN "):
			out.append(s)
	return out


func _skip(label : String) -> void:
	# Skip com nome, impresso em toda passada e contabilizado na linha própria
	# abaixo. `[ok]` silencioso é o defeito #89: um run que não mediu nada e disse
	# que mediu é pior que um run vermelho, porque ninguém vai olhar.
	skips += 1
	skipNames.append(label)
	print("[SKIP] " + label)


func _buildSideValidation() -> bool:
	# A metade de fora deste host: o `nginx -t` que valida o conf é o do BUILD da
	# imagem. Prova disso é a linha `RUN nginx -t` do Dockerfile — código, não a
	# frase de um README — e o job `container-images` da CI (com o step que roda
	# `nginx -t` na imagem) é conferido por scripts/check_ci.sh, que tem canário
	# plantado provando que a régua morre se o step for arrancado.
	var df : String = _read("res://deploy/web/Dockerfile")
	if df == "":
		_check(false, "deploy/web/Dockerfile foi lido (sem ele não há validação de build nenhuma)")
		return false
	var found : bool = false
	for run in _dockerfileRunLines(df):
		if run.contains("nginx -t") or run.contains("nginx --test"):
			found = true
			_check(not run.contains("|| true"),
				"o `RUN nginx -t` do build não está desarmado por `|| true` (%s)" % run.substr(0, 48))
			break
	_check(found, "deploy/web/Dockerfile roda `nginx -t` no build da imagem web")
	return found


func _suiteHonestScope() -> void:
	print("-- E) o que este harness NÃO fez (e o arquivo não pode fingir que fez)")
	var bin : String = _nginxBinary()
	if bin == "":
		# Finding #89: aqui morava o `_check(text.contains("nginx -t") and
		# text.contains(…da doc…))` — o harness grepava no próprio nginx.conf a frase
		# que declara que a validação é de build. Régua que lê a declaração do autor
		# é régua que dá verde ao que ninguém mediu: o run estava verde com o conf
		# quebrado e com o Dockerfile sem validação nenhuma. Agora: nada de doc. Sem
		# binário, o skip é NOMEADO e a suíte cobra a validação de build como CÓDIGO
		# (o `RUN nginx -t` do Dockerfile). Se nenhuma das duas existir, o veredito é
		# VERMELHO — "não medimos" não pode ser lido como "está certo".
		_skip("nginx -t neste host (binário ausente)")
		if not _buildSideValidation():
			_check(false,
				"nenhuma validação `nginx -t` existe neste run: sem binário local e sem validação no build da imagem")
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
		# Com o binário presente a validação de build continua obrigatória: o host
		# local não é o runner da CI nem o container que sobe em produção, e a
		# régua que protege o deploy é a que roda no build da imagem.
		_buildSideValidation()
	suitesDone += 1
	# Contabilidade impressa SEMPRE, inclusive em zero — a mesma doutrina das linhas
	# `== FLAKES: none ==` e `== GATES COM RUÍDO: none ==` do scripts/test.sh: "ninguém
	# marcou skip" e "nenhum skip" são frases diferentes, e só a segunda autoriza um
	# lançamento. Quem lê o log vê o nome do que não foi medido neste host.
	print("== NGINX HARDENING SKIPS: %d (%s) ==" % [skips, ", ".join(skipNames) if skips > 0 else "nenhum"])

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
	_suitePushRoute()
	_suiteCatalogRoute()
	_suiteHonestScope()
	_check(suitesDone == 7, "as 7 suítes rodaram até o fim (run cortado no meio não pode imprimir verde; o log é lido pelo ci_gate_log, esta linha lê o próprio verde)")
	print("== NGINX HARDENING: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
