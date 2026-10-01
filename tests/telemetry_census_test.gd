extends SceneTree

# AUDITORIA rodada 3 (ANALYTICS) — censo de `telemetry_event`.
#
# O buraco, medido antes desta passada: a tabela aceita QUALQUER string no `kind`
# (`Record` não valida nada; `RecordFunnel` só confere `FUNNEL_KINDS`), e nada no
# repo conferia "este kind que eu escrevo é lido por alguém". Censo do fonte, na
# mão: kinds escritos que nenhum leitor consumia — `flag_change`, `fraud_metrics`,
# os seis `sec_*` escritos por `Server.gd` e lidos só por um
# `SQLSecurity.CountSecurityEvents` sem chamador, e os eventos de marketplace/passe
# (`ah_list`, `ah_buy`, `ah_cancel`, `pass_claim`, `rebirth`) — mais `ah_list_reject`
# e os quatro de lance (`ah_bid`, `ah_bid_fill`, `ah_bid_cancel`, `ah_expire`), que
# os writers anunciavam e o PRÓPRIO gate do emissor deitava fora antes de a linha
# cair na tabela. Com `flag_change` como exemplo:
# `sources/ops/OpsCommands.gd:104` escrevia, nenhum leitor existia, e o dashboard
# podia anunciar "telemetria de operação" medindo outra coisa. As contas desta corrida
# são as que o harness imprime (`== CENSO: … ==`), nunca as deste cabeçalho.
#
# O formato é o precedente que a casa já aceitou no caminho de live ops —
# `LiveOpsCalendar.ImplementedKinds`: kind declarado sem consumidor é recusado.
# Mesmo formato, outro objeto. A diferença é que AQUI A RÉGUA NÃO TEM LISTA DE
# "KINDS BONS": os dois censos são derivados do fonte (escritores = chamadas às
# portas de emissão, com resolução de const/variável e 2 hops por forwarder tipo
# `_RecordAH`; leitores = predicados `kind` dentro de uma consulta que menciona
# `telemetry_event`). Nada é memorizado: um kind novo escrito sem leitor cai
# vermelha, e um kind lido que ninguém escreve é anotado, não acusado.
#
# Blocos:
#   1. o censo derivado (escritos × lidos × aceitos pelo gate), com os números da
#      mão do harness — nunca os números deste cabeçalho;
#   2. régua 1: todo kind escrito tem leitor (a acusação que faltava);
#   3. régua 2: todo kind entregue a um emissor validado é aceito por ele
#      (kind recusado em silêncio é linha que nunca existiu);
#   4. o leitor é servido: `MetricsServer.MetricsBody()` anexa o censo e
#      `KindCoverageGaugeLines` emite uma linha por kind declarado, e o SUMÁRIO lê
#      a tabela de verdade (uma linha gravada por `flag_change` aparece contada);
#   5. CONTROLES PLANTADOS no mesmo predicado: corpus sintético com kind escrito
#      sem leitor (exige acusação nomeada) e com leitor (exige zero).
#
# Uso: godot --headless --path . -s tests/telemetry_census_test.gd
# Exit code = checks falhos. Última linha: `== TELEMETRY CENSUS: N checks, M failures ==`.

const Roots : Array[String] = ["res://sources", "res://companion", "res://data/conf/migrations"]
# Emissoras de escrita: (método, índice do argumento que é o kind).
const Emitters : Array[String] = ["Record", "RecordFunnel", "RecordMoney", "LogSecurityEvent"]
const EmitterArgIndex : Dictionary = {"Record": 0, "RecordFunnel": 0, "RecordMoney": 0, "LogSecurityEvent": 1}

var checks : int = 0
var failures : int = 0

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

func _autoload(name : String) -> Node:
	return root.get_node_or_null(NodePath(name))

func _rx(pattern : String) -> RegEx:
	var r := RegEx.new()
	r.compile(pattern)
	return r

func _hits(pattern : String, subject : String) -> Array[String]:
	var out : Array[String] = []
	for m in _rx(pattern).search_all(subject):
		out.append(m.get_string(1))
	return out

# ------------------------------------------------------------------ corpus
static func _walk(path : String, out : Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name : String = dir.get_next()
	while name != "":
		if not name.begins_with("."):
			var full : String = path + "/" + name
			if dir.current_is_dir():
				_walk(full, out)
			elif name.ends_with(".gd") or name.ends_with(".py") or name.ends_with(".sql"):
				var text : String = FileAccess.get_file_as_string(full)
				if not text.is_empty():
					out.append({"path": full, "text": text})
		name = dir.get_next()
	dir.list_dir_end()

func LoadCorpus() -> Array:
	var corpus : Array = []
	for rootPath in Roots:
		_walk(rootPath, corpus)
	return corpus

# ------------------------------------------------------------------ derivação
# Tabela nome → valores, derivada do fonte por quatro formas e só por elas:
#   `const X : String = "v"`;
#   `const|var X [: Array[String] ] = ["a", "b", …]` (>= 2 membros: é assim que
#     `FUNNEL_KINDS`, `OperationalKinds`, `GrantKinds` e o array de `FunnelSummary`
#     existem);
#   `var X : String = "a" if cond else "b"` — o literal do `=` e o do `else`, porque
#     um kind dinâmico do checkout (`eventKind`) é exatamente essa forma;
#   `x = "v"` (atribuição simples; `==` é comparação e NÃO é atribuição — a trava
#     `=(?!=)` é o que impede `if kind == "cosmetic"` de virar "kind escrito").
# A leitura é SEMPRE no escopo do arquivo, exceto para nomes de `const` (que são
# cross-file por projeto: `SQLSecurity.EventLoginLockout` é usado em `Server.gd`).
# Sem essa trava, uma variável homônima em outro arquivo injeta kinds de mentira —
# e a régua deixaria de acusar o que importa.
static func ConstNames(entries : Array) -> Dictionary:
	var out : Dictionary = {}
	for e in entries:
		for m in RegEx.create_from_string(r'\bconst\s+([A-Za-z_]\w*)\b').search_all(str(e["text"])):
			out[m.get_string(1)] = true
	return out

static func SymbolTable(entries : Array) -> Dictionary:
	var table : Dictionary = {}
	for e in entries:
		var text : String = str(e["text"])
		for m in RegEx.create_from_string(r'\bconst\s+([A-Za-z_]\w*)\s*:\s*String\s*=\s*"([a-z0-9_]+)"').search_all(text):
			var key : String = m.get_string(1)
			if not table.has(key):
				table[key] = {}
			table[key][m.get_string(2)] = true
		for m in RegEx.create_from_string(r'(?:const|var)\s+([A-Za-z_]\w*)\s*:\s*(?:Array\[String\])?\s*=\s*\[([^\]]*?)\]').search_all(text):
			var vals : Array[String] = []
			for lit in RegEx.create_from_string(r'"([a-z0-9_]+)"').search_all(m.get_string(2)):
				vals.append(lit.get_string(1))
			if vals.size() >= 2:
				var key2 : String = m.get_string(1)
				if not table.has(key2):
					table[key2] = {}
				for v in vals:
					table[key2][v] = true
		for m in RegEx.create_from_string(r'\b(?:var|const)\s+([a-z_]\w*)\s*:\s*String\s*=\s*([^\n]*)').search_all(text):
			var key3 : String = m.get_string(1)
			var rest : String = m.get_string(2)
			# O inicializador pode ser ternário (`= "chargeback" if … else "purchase"`):
			# vale o literal logo depois do `=` e o logo depois do `else` — e só. Varre-
			# los-index (`grant["kind"]`) na mesma linha NÃO é valor da variável.
			var picks : Array[String] = []
			var first := RegEx.create_from_string(r'^\s*"([a-z0-9_]+)"').search(rest)
			if first != null:
				picks.append(first.get_string(1))
			var elseIx : int = rest.find("else")
			if elseIx >= 0:
				var after := RegEx.create_from_string(r'^\s*"([a-z0-9_]+)"').search(rest.substr(elseIx + 4))
				if after != null:
					picks.append(after.get_string(1))
			for p in picks:
				if not table.has(key3):
					table[key3] = {}
				table[key3][p] = true
		for m in RegEx.create_from_string(r'(?:^|\n|\s)([a-z_]\w*)\s*=(?!=)\s*"([a-z0-9_]+)"').search_all(text):
			var key4 : String = m.get_string(1)
			if not table.has(key4):
				table[key4] = {}
			table[key4][m.get_string(2)] = true
	return table

# Escopo de resolução de um arquivo: o que ele declara + os `const` globais.
static func LookupFor(e : Dictionary, globalTable : Dictionary, constNames : Dictionary) -> Dictionary:
	var scoped : Dictionary = SymbolTable([e])
	for name in constNames.keys():
		if globalTable.has(name):
			if not scoped.has(name):
				scoped[name] = {}
			for v in (globalTable[name] as Dictionary).keys():
				scoped[name][v] = true
	return scoped

# Último identificador de um path (`SQLSecurity.EventLoginLockout` →
# `EventLoginLockout`). `String.get_slice(".", -1)` devolve VAZIO no Godot 4.7 — slice
# negativo não é suportado — e foi exatamente assim que o censo deixou de resolver os
# seis kinds de segurança (medido, não lembrado: `== DEBUG slice=[] ==` na corrida).
static func LastIdent(token : String) -> String:
	var dot : int = token.rfind(".")
	return token.substr(dot + 1) if dot >= 0 else token

static func Resolve(token : String, table : Dictionary) -> Array[String]:
	var out : Array[String] = []
	var tok : String = token.strip_edges()
	# literal GDScript (`"x"`) ou SQL (`'x'`, é como FraudeReview carimba
	# `fraud_metrics` no INSERT): valor explícito, não precisa de tabela.
	var lit := RegEx.create_from_string(r'^"([a-z0-9_]+)"$').search(tok)
	if lit == null:
		lit = RegEx.create_from_string(r"^'([a-z0-9_]+)'$").search(tok)
	if lit != null:
		out.append(lit.get_string(1))
		return out
	if RegEx.create_from_string(r'^[A-Za-z_][\w.]*$').search(tok) == null:
		return out
	var name : String = LastIdent(tok)
	if table.has(name):
		for v in (table[name] as Dictionary).keys():
			out.append(str(v))
	return out

# Corpo de função delimitado (de `func X(` até o próximo `func`): é o que impede a
# janela de uma função vazar para a seguinte e inventar forwarders.
static func Bodies(text : String) -> Array:
	var out : Array = []
	var name : String = ""
	var params : String = ""
	var body : String = ""
	var head := RegEx.create_from_string("^\\s*(?:static\\s+)?func\\s+([A-Za-z_]\\w*)\\(([^)]*)\\)")
	for line in text.split("\n"):
		var m := head.search(line)
		if m != null:
			if not name.is_empty():
				out.append({"name": name, "params": params, "body": body})
			name = m.get_string(1)
			params = m.get_string(2)
			body = line + "\n"
		elif not name.is_empty():
			body += line + "\n"
	if not name.is_empty():
		out.append({"name": name, "params": params, "body": body})
	return out

static func ParamNames(params : String) -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	for part in params.split(","):
		var trimmed : String = part.strip_edges()
		if not trimmed.is_empty():
			out.append(trimmed.get_slice(" ", 0))
	return out

# Forwarders: função cujo CORPO entrega um PRÓPRIO parâmetro a uma emissora
# (`func _RecordAH(kind : String … .Telemetry.RecordFunnel(kind, …)`). Devolve os
# nomes dos parâmetros (que NUNCA são kinds no call site direto) e o arquivo onde
# cada forwarder foi declarado (o hop só vale lá dentro).
static func Forwarders(entries : Array) -> Dictionary:
	var params : Dictionary = {}
	var names : Dictionary = {}
	for e in entries:
		for b in Bodies(str(e["text"])):
			var pnames : PackedStringArray = ParamNames(str(b["params"]))
			for em in RegEx.create_from_string(r'\.Telemetry\.(Record|RecordFunnel|RecordMoney)\(\s*([A-Za-z_]\w*)').search_all(str(b["body"])):
				if not pnames.has(em.get_string(2)):
					continue
				params[em.get_string(2)] = true
				if not names.has(str(b["name"])):
					names[str(b["name"])] = str(e["path"])
	return {"params": params, "names": names}

# Kinds ESCRITOS, derivados do fonte por três portas e só por elas:
#   1. `Launcher.Telemetry.Record|RecordFunnel|RecordMoney(KIND, …)` — o receiver é
#      obrigatório: `Record(` de qualquer outro objeto (ledger, métricas do
#      companion) não escreve em `telemetry_event` e não entra no censo;
#   2. `SQLSecurity.LogSecurityEvent(sql, KIND, …)` — escrita direta na tabela, kind
#      na segunda posição, resolve pelas `const Event* : String` do próprio fonte;
#   3. `INSERT INTO telemetry_event (…) VALUES (…)` com literal/const na posição da
#      coluna `kind`;
#   4. dois hops pelos FORWARDERS: função cujo corpo entrega um PRÓPRIO parâmetro a
#      uma emissora (`func _RecordAH(kind : String … .Telemetry.RecordFunnel(kind`)
#      tem seus call sites literais no mesmo arquivo contados como escrita. Sem este
#      hop o censo perderia os quatro eventos de marketplace, que é exatamente como
#      um kind escrito escapa de uma régua.
static func WrittenKinds(entries : Array) -> Dictionary:
	var globalTable : Dictionary = SymbolTable(entries)
	var constNames : Dictionary = ConstNames(entries)
	var fwd : Dictionary = Forwarders(entries)
	var forwarderParams : Dictionary = fwd["params"]
	var forwarders : Dictionary = fwd["names"]
	var written : Dictionary = {}
	var unresolved : Dictionary = {}
	for e in entries:
		var text : String = str(e["text"])
		var path : String = str(e["path"])
		var table : Dictionary = LookupFor(e, globalTable, constNames)
		for method in Emitters:
			var idx : int = int(EmitterArgIndex[method])
			var prefix : String = r'\.Telemetry\.' + method + r'\(' if method != "LogSecurityEvent" else r'\.LogSecurityEvent\('
			var pat : String = prefix + r'[^,]*,'.repeat(idx) + r'\s*("(?:[a-z0-9_]+)"|[A-Za-z_][\w.]*)'
			for m in RegEx.create_from_string(pat).search_all(text):
				var token : String = m.get_string(1).strip_edges()
				var tokenName : String = LastIdent(token)
				# kind entregue POR PARÂMETRO a um forwarder não é kind deste call site
				# (o nome do parâmetro resolve para os valores de OUTRA linha): quem define
				# o kind são os call sites literais do forwarder, no hop abaixo.
				if not token.begins_with("\"") and forwarderParams.has(tokenName):
					continue
				var vals : Array[String] = Resolve(token, table)
				if vals.is_empty():
					unresolved[token] = path
				for v in vals:
					written[v] = path
		for m in RegEx.create_from_string(r"INSERT INTO telemetry_event \(([^)]*)\) VALUES \(([^)]*)\)").search_all(text):
			var cols : PackedStringArray = m.get_string(1).split(",")
			var vals : PackedStringArray = m.get_string(2).split(",")
			if cols.size() != vals.size():
				continue
			var kindPos : int = cols.find("kind")
			if kindPos < 0:
				continue
			for v in Resolve(vals[kindPos], table):
				written[v] = path + ":insert"
		for fname in forwarders.keys():
			# hop só dentro do arquivo que DECLARA o forwarder: homônimo em outro
			# arquivo não escreve por aqui.
			if str(forwarders[fname]) != path:
				continue
			for m in RegEx.create_from_string(r'(?:^|[^.\w])' + fname + r'\(\s*"([a-z0-9_]+)"').search_all(text):
				written[m.get_string(1)] = path + ":" + fname
	return {"kinds": written, "unresolved": unresolved}

# Kinds LIDOS. O texto é picado por `;` — aqui `;` só existe no fim de statement SQL,
# então cada peça é uma consulta (com o código em volta), e o predicado `kind` só
# vale como leitor de telemetria se a MESMA peça menciona `telemetry_event`. É o que
# separa o `kind = 'gold'` do ledger do `kind = 'login'` do funil, e por que a régua
# não confia no nome "kind" sozinho. Três formas de predicado:
#   `kind = 'x'` e `kind IN ('x', …)` literais;
#   `kind IN (` enumerado por `_Placeholders(ARR)`/`join(ARR)`/`for kind in ARR` — os
#     membros do array são lidos (é como `FunnelDailyKinds`, `OperationalKinds` e o
#     array local de `FunnelSummary` consomem seus kinds);
#   `kind = ?` com literal no array de bindings.
# Array só vale se declarado NO MESMO arquivo da consulta, ou se for `const`
# (cross-file por projeto). Sem essa trava, um `var kinds = [...]` qualquer do fonte
# poderia dar leitor de mentira a um kind órfão — e falsa verde é a única acusação
# que uma régua não pode cometer.
static func ReadKinds(entries : Array) -> Dictionary:
	var globalTable : Dictionary = SymbolTable(entries)
	var constNames : Dictionary = ConstNames(entries)
	var read : Dictionary = {}
	for e in entries:
		var text : String = str(e["text"])
		var path : String = str(e["path"])
		var table : Dictionary = LookupFor(e, globalTable, constNames)
		for piece in text.split(";"):
			if not piece.contains("telemetry_event"):
				continue
			for m in RegEx.create_from_string(r"(?i)kind\s*=\s*'([a-z0-9_]+)'").search_all(piece):
				read[m.get_string(1)] = path
			for m in RegEx.create_from_string(r"(?i)kind\s+IN\s*\(([^)]*)\)").search_all(piece):
				for lit in RegEx.create_from_string(r"'([a-z0-9_]+)'").search_all(m.get_string(1)):
					read[lit.get_string(1)] = path + ":in"
				for tok in RegEx.create_from_string(r"\b([A-Za-z_]\w*)\b").search_all(m.get_string(1)):
					for v in (table.get(tok.get_string(1), {}) as Dictionary).keys():
						read[str(v)] = path + ":set"
			for m in RegEx.create_from_string(r"(?:_Placeholders|join)\(\s*([A-Za-z_]\w*)\s*\)|for\s+kind\s+in\s+([A-Za-z_]\w*)").search_all(piece):
				var arr : String = m.get_string(1) if not m.get_string(1).is_empty() else m.get_string(2)
				for v in (table.get(arr, {}) as Dictionary).keys():
					read[str(v)] = path + ":" + arr
			for m in RegEx.create_from_string(r"(?i)kind\s*=\s*\?").search_all(piece):
				var bindings := RegEx.create_from_string(r",\s*\[([^\]]*)\]").search(piece.substr(m.get_end(), 220))
				if bindings == null:
					continue
				for tok in bindings.get_string(1).split(","):
					for v in Resolve(tok, table):
						if v != "kind":
							read[v] = path + ":bound"
	return read

# Régua 1: kind escrito sem consumidor. É A régua que faltava.
static func Orphans(written : Dictionary, read : Dictionary) -> Array[String]:
	var out : Array[String] = []
	for kind in written.keys():
		if not read.has(kind):
			out.append("%s (escrito por %s, lido por ninguém)" % [kind, str(written[kind])])
	out.sort()
	return out

# Régua 2: kind entregue a um emissor validado que o gate recusa — linha que nunca
# cai na tabela. O gate é o próprio `FUNNEL_KINDS` do fonte, lido daqui; nada de
# lista na régua. Vale para o call site direto e para o forwarder.
static func RefusedAtGate(entries : Array) -> Array[String]:
	var globalTable : Dictionary = SymbolTable(entries)
	var constNames : Dictionary = ConstNames(entries)
	var fwd : Dictionary = Forwarders(entries)
	var gate : Dictionary = {}
	for e in entries:
		for m in RegEx.create_from_string(r'FUNNEL_KINDS\s*:\s*Array\[String\]\s*=\s*\[([^\]]*?)\]').search_all(str(e["text"])):
			for lit in RegEx.create_from_string(r'"([a-z0-9_]+)"').search_all(m.get_string(1)):
				gate[lit.get_string(1)] = true
	var seen : Dictionary = {}
	var out : Array[String] = []
	for e in entries:
		var text : String = str(e["text"])
		var path : String = str(e["path"])
		var table : Dictionary = LookupFor(e, globalTable, constNames)
		for method in ["RecordFunnel", "RecordMoney"]:
			for m in RegEx.create_from_string(r'\.Telemetry\.' + method + r'\(\s*("(?:[a-z0-9_]+)"|[A-Za-z_][\w.]*)').search_all(text):
				var tokenName : String = LastIdent(m.get_string(1).strip_edges())
				if (fwd["params"] as Dictionary).has(tokenName):
					continue
				for v in Resolve(m.get_string(1), table):
					if gate.has(v):
						continue
					var msg : String = "%s → %s recusado pelo gate FUNNEL_KINDS (%s)" % [v, method, path]
					if not seen.has(msg):
						seen[msg] = true
						out.append(msg)
		for b in Bodies(text):
			var names : PackedStringArray = ParamNames(str(b["params"]))
			var isForwarder : bool = false
			for em in RegEx.create_from_string(r'\.Telemetry\.(RecordFunnel|RecordMoney)\(\s*([A-Za-z_]\w*)').search_all(str(b["body"])):
				if names.has(em.get_string(2)):
					isForwarder = true
			if not isForwarder:
				continue
			for m in RegEx.create_from_string(r'(?:^|[^.\w])' + str(b["name"]) + r'\(\s*"([a-z0-9_]+)"').search_all(text):
				if gate.has(m.get_string(1)):
					continue
				var msg2 : String = "%s escrito por %s e recusado pelo gate (linha que nunca existiu) (%s)" % [m.get_string(1), str(b["name"]), path]
				if not seen.has(msg2):
					seen[msg2] = true
					out.append(msg2)
	out.sort()
	return out

func _initialize():
	_runTests()

func _runTests():
	print("== telemetry census: kind escrito sem consumidor é régua vermelha ==")
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
		if sqlNode != null and sqlNode.get("isInitialized"):
			break
	# O catálogo de conteúdo NÃO sobe junto com `SQL.isInitialized`: `DB.Preload()`
	# empilha os `load_threaded_request` de `Preload` (`sources/db/DB.gd:@Preload`) e o `PreloadUpdate()`
	# (`sources/db/DB.gd:@PreloadUpdate`) fecha o preload, chama `Load()` e acende `isInitialized`,
	# re-armado a cada `process_frame` — portanto precisa de FRAMES. Esperar só o SQL e medir com o
	# catálogo ainda vazio: aqui os frames caem antes do `quit()`, no runner da CI não,
	# e o MESMO run vale ~30 ou ~1700 objetos conforme a máquina. O check nomeado é o
	# ponto — boot leve é vermelho visível, não medição parcial silenciosa.
	# Padrão de tests/content_hygiene_test.gd.
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for tick in 80:
		if dbScript != null and bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not Check(dbReady, "DB initialized (entities/maps/items carregados)"):
		_finish()
		return
	var corpus : Array = LoadCorpus()
	Check(corpus.size() > 100, "censo varreu o fonte real (%d arquivos em %s)" % [corpus.size(), ", ".join(Roots)])
	var writtenInfo : Dictionary = WrittenKinds(corpus)
	var written : Dictionary = writtenInfo["kinds"]
	var unresolved : Dictionary = writtenInfo["unresolved"]
	var read : Dictionary = ReadKinds(corpus)
	var orphans : Array[String] = Orphans(written, read)
	print("== CENSO: %d kinds escritos, %d kinds lidos, %d órfãos, %d tokens não resolvidos (%s) ==" % [written.size(), read.size(), orphans.size(), unresolved.size(), str(unresolved.keys())])
	for o in orphans:
		print("  [acuso] " + o)
	CheckEq(orphans.size(), 0, "todo kind escrito pelo fonte tem um leitor no fonte (a régua que faltava)")
	Check(written.size() >= 25, "o censo acha os escritores (>=25 kinds; verde por inanição não é verde): %d" % written.size())
	for probe in ["login", "settle", "purchase", "flag_change"]:
		Check(read.has(probe), "o leitor %s é achado pelo censo" % probe)
	for probe in ["flag_change", "fraud_metrics", "sec_login_lockout", "ah_list_reject"]:
		Check(written.has(probe), "o escritor %s é achado pelo censo" % probe)

	# ------------------------------------------ 3. gate do emissor aceita o que escrevem
	var refused : Array[String] = RefusedAtGate(corpus)
	for r in refused:
		print("  [acuso] " + r)
	CheckEq(refused.size(), 0, "todo kind entregue a um emissor validado é aceito pelo gate (nada é escrito para ser jogado fora)")
	Check(unresolved.size() == 0, "nenhum token de kind ficou sem resolução no censo (%s)" % str(unresolved.keys()))

	# --------------------------------------------------- 4. o leitor é servido, e lê
	var tele : Node = launcher.get("Telemetry")
	if not Check(tele != null, "TelemetryService bootado"):
		_finish()
		return
	var declared : Array = tele.call("DeclaredKinds")
	Check(declared.size() >= 20, "o fonte declara %d kinds no censo (FUNNEL_KINDS ∪ OperationalKinds)" % declared.size())
	tele.call("Record", "flag_change", 0, 0, 1, "{\"key\":\"census_probe\"}")
	tele.call("Record", "sec_login_lockout", 0, 0, 1, "{}")
	var flushed : int = int(tele.call("Flush"))
	Check(flushed >= 2, "os dois eventos do probe caíram na tabela (flush %d)" % flushed)
	var summary : Dictionary = tele.call("KindCoverageSummary", 0)
	CheckEq(summary.size(), ((tele.get_script().call("get_script_constant_map") as Dictionary).get("OperationalKinds", []) as Array).size(), "o sumário devolve uma entrada por kind declarado (sem omissão silenciosa)")
	Check(int(summary.get("flag_change", 0)) >= 1, "o LEITOR lê a tabela de verdade: flag_change contado (%s)" % str(summary.get("flag_change", 0)))
	Check(int(summary.get("sec_login_lockout", 0)) >= 1, "o LEITOR lê a tabela de verdade: sec_login_lockout contado (%s)" % str(summary.get("sec_login_lockout", 0)))
	var gauges : String = String(tele.call("KindCoverageGaugeLines", 7))
	var opKinds : Array = (tele.get_script().call("get_script_constant_map") as Dictionary).get("OperationalKinds", [])
	var missing : int = 0
	for kind in opKinds:
		if not gauges.contains('shambleta_telemetry_kind_events{kind="%s"}' % str(kind)):
			missing += 1
	CheckEq(missing, 0, "o censo serve uma linha por kind declarado no /metrics (%d kinds)" % opKinds.size())
	var metricsSrc : String = FileAccess.get_file_as_string("res://sources/system/MetricsServer.gd")
	var bodyChunk : String = metricsSrc.substr(0, metricsSrc.find("metricsCache = body"))
	Check(bodyChunk.contains("_telemetryKindSection()"), "MetricsBody() chama a seção do censo (sem o anexo o leitor seria código morto)")
	Check(metricsSrc.contains("func _telemetryKindSection()") and metricsSrc.contains("KindCoverageGaugeLines("), "a seção anexa chama o censo de verdade (`_telemetryKindSection` → `KindCoverageGaugeLines`)")

	# ------------------------------------------------- 5. controles plantados
	var ghost : String = "ghost_kind_no_reader"
	var kept : String = "kept_kind_with_reader"
	var writerCorpus : Array = [{"path": "synthetic/sources/Writer.gd", "text": "" \
		+ "func Emit() -> void:\n\tLauncher.Telemetry.Record(\"" + ghost + "\", 0, 0, 1, \"{}\")\n" \
		+ "\tLauncher.Telemetry.Record(\"" + kept + "\", 0, 0, 1, \"{}\")\n"}]
	var readerCorpus : Array = [{"path": "synthetic/sources/Reader.gd", "text": "" \
		+ "func Read() -> int:\n\treturn int(Launcher.SQL.QueryBindings(\"SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = '" + kept + "';\", [])[0][\"n\"])\n"}]
	var syntheticWritten : Dictionary = WrittenKinds(writerCorpus)["kinds"]
	CheckEq(syntheticWritten.size(), 2, "CONTROLE: o censo derivado acha os dois kinds injetados na memória (%s)" % str(syntheticWritten.keys()))
	var controlOrphans : Array[String] = Orphans(syntheticWritten, ReadKinds(readerCorpus))
	CheckEq(controlOrphans.size(), 1, "CONTROLE: kind escrito SEM leitor é ACUSADO pelo mesmo predicado do caso real")
	Check(controlOrphans.size() == 1 and controlOrphans[0].contains(ghost), "CONTROLE: a acusação nomeia exatamente o kind injetado (%s)" % str(controlOrphans))
	var bothRead : Dictionary = ReadKinds(readerCorpus)
	bothRead[ghost] = "synthetic/control"
	CheckEq(Orphans(syntheticWritten, bothRead).size(), 0, "CONTROLE: o MESMO kind com leitor devolve ZERO acusação (a régua não acusa por estar com raiva)")
	# controle da régua 2: kind injetado num call site que o gate não aceita.
	var gateCorpus : Array = [{"path": "synthetic/sources/Gate.gd", "text": "" \
		+ "const FUNNEL_KINDS : Array[String] = [\"purchase\", \"refund\"]\n" \
		+ "func Emit() -> void:\n\tLauncher.Telemetry.RecordFunnel(\"never_accepted_kind\", 0, 0, \"{}\")\n"}]
	var gateRefused : Array[String] = RefusedAtGate(gateCorpus)
	CheckEq(gateRefused.size(), 1, "CONTROLE: kind entregue a um emissor validado que o gate recusa é acusado (%s)" % str(gateRefused))
	var gateOkCorpus : Array = [{"path": "synthetic/sources/Gate.gd", "text": "" \
		+ "const FUNNEL_KINDS : Array[String] = [\"purchase\", \"refund\"]\n" \
		+ "func Emit() -> void:\n\tLauncher.Telemetry.RecordFunnel(\"refund\", 0, 0, \"{}\")\n"}]
	CheckEq(RefusedAtGate(gateOkCorpus).size(), 0, "CONTROLE: kind aceito pelo gate devolve ZERO")
	_finish()

func _finish() -> void:
	print("== TELEMETRY CENSUS: %d checks, %d failures ==" % [checks, failures])
	quit(0 if failures == 0 else 1)
