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

func CheckSame(value : String, expected : String, label : String) -> bool:
	return Check(value == expected, "%s (got \"%s\", want \"%s\")" % [label, value, expected])

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

# ==================================================================================
# HORIZONTE DE RETENÇÃO (WorkOrder #164)
# ==================================================================================

const DaySec : int						= 86400
const HourSec : int						= 3600
# Folga exigida do horizonte sobre a maior janela que o fonte declara em segundos.
const HorizonSlackFactor : int			= 2

# Tabela nome → valor, derivada de duas formas só: `const NOME : int = <expr>` no
# GDScript e `NOME = <expr>` no python. `<expr>` é produto de literais e nomes
# (fixpoint, então `HorizonSec = 90 * DaySec` casa na segunda passada). Comentário
# depois do valor é do leitor do fonte, não da expressão: `const FingerprintWindowSec
# : int = 7 * 86400  # janela dos logins` resolve 604800, e o que está depois do `#`
# não entra na conta.
static func NumTable(entries : Array) -> Dictionary:
	var raw : Dictionary = {}
	for e in entries:
		var text : String = str(e["text"])
		for m in RegEx.create_from_string(r'\bconst\s+([A-Za-z_]\w*)\s*:\s*int\s*=\s*([0-9][^#\n]*)').search_all(text):
			if not raw.has(m.get_string(1)):
				raw[m.get_string(1)] = m.get_string(2).strip_edges()
		for m in RegEx.create_from_string(r'(?m)^[ \t]*([A-Z][A-Z0-9_]*)[ \t]*=[ \t]*([0-9][0-9\s*]*)[ \t]*$').search_all(text):
			if not raw.has(m.get_string(1)):
				raw[m.get_string(1)] = m.get_string(2)
	var nums : Dictionary = {}
	for _pass in raw.size() + 2:
		var grew : bool = false
		for name in raw.keys():
			if nums.has(name):
				continue
			var v : int = NumOf(str(raw[name]), nums, 4)
			if v > 0:
				nums[name] = v
				grew = true
		if not grew:
			break
	return nums

# Produto de literais e nomes conhecidos. `-1` = não resolvido (nunca "chuta").
static func NumOf(expr : String, nums : Dictionary, depth : int = 0) -> int:
	var t : String = expr.strip_edges()
	if t.is_empty() or depth < 0:
		return -1
	if RegEx.create_from_string(r"^\d+$").search(t) != null:
		return int(t)
	if nums.has(t):
		return int(nums[t])
	if depth > 4 or RegEx.create_from_string(r"^[\w\s*]+$").search(t) == null:
		return -1
	var total : int = 1
	for factor in t.split("*"):
		var f : String = factor.strip_edges()
		if f.is_empty():
			return -1
		var sub : int = NumOf(f, nums, depth - 1)
		if sub <= 0:
			return -1
		total *= sub
	return total

# Função que envolve um offset do texto: é o que dá a lista de parâmetros DAQUELA
# consulta (sem ela, a janela de uma função vazaria para a seguinte).
static func FuncContextAt(text : String, offset : int) -> Dictionary:
	var head := RegEx.create_from_string("^\\s*(?:static\\s+)?func\\s+([A-Za-z_]\\w*)\\(([^)]*)\\)")
	var cur : Dictionary = {"name": "", "params": PackedStringArray()}
	var acc : int = 0
	for line in text.split("\n"):
		var m := head.search(line)
		if m != null:
			cur = {"name": m.get_string(1), "params": ParamNames(m.get_string(2))}
		acc += line.length() + 1
		if acc > offset:
			return cur
	return cur

# Chamadas SEM argumento cujo corpo é rotação de calendário (`_AdDayStart()`,
# `ShopDay(...)`). A janela de uma rotação é um dia — derivado do corpo, não do nome:
# `FuncContextAt` + o predicado abaixo são o que diz que "hoje à 00:00" não é 90 dias.
static func RotationsIn(text : String) -> Dictionary:
	var shape := RegEx.create_from_string(r"DayStart\(|ShopDay\(|PassDayStartTS\(|/\s*86400|/ 86400|unixepoch")
	var out : Dictionary = {}
	for b in Bodies(text):
		if not str(b["params"]).strip_edges().is_empty():
			continue
		if shape.search(str(b["body"])) != null:
			out[str(b["name"])] = DaySec
	return out

# ------------------------------------------------------------------ a chamada que carrega o bound
# A grandeza de uma janela NÃO está no literal SQL: está no array de bindings da
# CHAMADA. Picar o texto por `;` separa consultas, mas uma peça atravessa funções —
# o `;` que fecha um literal SQL não é o `;` que fecha uma statement do banco, e
# `Flush()` tem sete deles dentro da string do `INSERT` — e o primeiro `[...]` depois
# do `?` tantas vezes é o `("account_id")` de um `GhostClause` ou o `json_extract(` do
# próprio SQL quanto o array de bindings. Acusar isso é acusar o parser do harness.
# A derivação é então pela POSIÇÃO do bound, e ela exige saber o que é CÓDIGO: a
# máscara troca comentário e interior de string por espaço, posição por posição, e
# sobre ela só existem os parênteses do fonte. Duas coisas caem daí por construção: um
# `created_at < ?` citado em prosa não é leitor de nada, e o `IN (` de um SQL não é
# chamada de GDScript. É troca de ESCOPO, não de métrica: todo bound escrito em código
# continua obrigado a declarar a própria janela, e os controles plantados abaixo provam
# que a régua continua mordendo o que se esconde em variável e o que não confessa nome.

# Fim da string que abre em `openIx` (aspas simples, duplas, triplas e escapes). Sem
# isto, o `(` de `json_extract(meta, '$.eff')` seria lido como argumento GDScript.
static func _SkipString(text : String, openIx : int) -> int:
	var q : String = text[openIx]
	var triple : bool = openIx + 2 < text.length() and text[openIx + 1] == q and text[openIx + 2] == q
	var i : int = openIx + (3 if triple else 1)
	var n : int = text.length()
	while i < n:
		if text[i] == "\\":
			i += 2
			continue
		if text[i] == q:
			if not triple:
				return i + 1
			if i + 2 < n and text[i + 1] == q and text[i + 2] == q:
				return i + 3
		i += 1
	return n

static func _CommentEnd(text : String, at : int) -> int:
	if text[at] == "/":
		var close : int = text.find("*/", at + 2)
		return text.length() if close < 0 else close + 2
	var nl : int = text.find("\n", at)
	return text.length() if nl < 0 else nl

# Máscara do fonte: MESMO comprimento, comentário e interior de string trocados por
# espaço. As posições continuam valendo para o texto original, então um offset achado
# num acha no outro. `{mask, strings, comments}`, com as listas de ranges em
# `[abre, fecha)`.
static func MaskRanges(text : String) -> Dictionary:
	var parts : PackedStringArray = PackedStringArray()
	var strings : Array = []
	var comments : Array = []
	var i : int = 0
	var n : int = text.length()
	while i < n:
		var c : String = text[i]
		if c == "#" or (c == "-" and i + 1 < n and text[i + 1] == "-") or (c == "/" and i + 1 < n and text[i + 1] == "*"):
			var e : int = _CommentEnd(text, i)
			comments.append([i, e])
			parts.append(" ".repeat(e - i))
			i = e
			continue
		if c == "\"" or c == "'":
			var f : int = _SkipString(text, i)
			strings.append([i, f])
			parts.append(" ".repeat(f - i))
			i = f
			continue
		parts.append(c)
		i += 1
	return {"mask": "".join(parts), "strings": strings, "comments": comments}

static func InRanges(ranges : Array, at : int) -> bool:
	for r in ranges:
		if at >= int(r[0]) and at < int(r[1]):
			return true
	return false

# Para cada `(` da máscara, o `)` que o fecha. Uma passada, porque procurá-lo sobe o
# arquivo inteiro a cada bound e a régua lê o corpus todo.
static func ParenPairs(mask : String) -> Dictionary:
	var stack : Array[int] = []
	var pairs : Dictionary = {}
	for i in mask.length():
		if mask[i] == "(":
			stack.append(i)
		elif mask[i] == ")" and not stack.is_empty():
			pairs[stack.pop_back()] = i
	return pairs

static func _SplitTopArgs(inner : String) -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	var depth : int = 0
	var start : int = 0
	var i : int = 0
	var n : int = inner.length()
	while i < n:
		var c : String = inner[i]
		if c == "\"" or c == "'":
			i = _SkipString(inner, i)
			continue
		if c == "(" or c == "[":
			depth += 1
		elif c == ")" or c == "]":
			depth -= 1
		elif c == "," and depth == 0:
			out.append(inner.substr(start, i - start).strip_edges())
			start = i + 1
		i += 1
	out.append(inner.substr(start).strip_edges())
	return out

# Chamadas que ENCARREIRAM o offset, da mais perto para a mais longe. O nome não é
# filtrado: `QueryBindings`, `ExecNoLock`, `_Scalar` e o `execute` do companion são
# executores diferentes da mesma coisa, e o que diz o que um bound poda é o argumento
# de SQL da chamada, não o nome que o autor deu a ela.
static func CallSpans(mask : String, pairs : Dictionary, offset : int) -> Array:
	var out : Array = []
	var callRe := RegEx.create_from_string(r"[A-Za-z_]\w*[ \t]*\(")
	var ms : Array = callRe.search_all(mask)
	for mi in range(ms.size() - 1, -1, -1):
		var openIx : int = ms[mi].get_end() - 1
		if openIx > offset:
			continue
		var closeIx : int = int(pairs.get(openIx, -1))
		if closeIx > offset:
			out.append({"open": openIx, "close": closeIx})
	return out

static func ArgsOf(mask : String, text : String, openIx : int, closeIx : int) -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	var depth : int = 0
	var start : int = openIx + 1
	for i in range(openIx + 1, closeIx):
		var c : String = mask[i]
		if c == "(" or c == "[":
			depth += 1
		elif c == ")" or c == "]":
			depth -= 1
		elif c == "," and depth == 0:
			out.append(text.substr(start, i - start).strip_edges())
			start = i + 1
	out.append(text.substr(start, closeIx - start).strip_edges())
	return out

static func LineOf(text : String, at : int) -> String:
	var i : int = at
	while i > 0 and text[i - 1] != "\n":
		i -= 1
	var e : int = text.find("\n", at)
	return text.substr(i, (text.length() if e < 0 else e) - i)

# Tabelas que um trecho de SQL toca. `FROM (` de subselecta não casa identificador e
# o search_all acha o nome dentro do próprio subselect.
static func TablesOf(sql : String) -> Array[String]:
	var out : Array[String] = []
	for m in RegEx.create_from_string(r"(?i)\b(?:from|into|update|join)\s+([a-z_][a-z0-9_]*)").search_all(sql):
		var t : String = m.get_string(1).to_lower()
		if not out.has(t):
			out.append(t)
	return out

# Expressão de SQL do primeiro argumento de uma chamada, resolvida até onde o fonte
# resolve: identificador vira o inicializador da variável, e um fragmento montado por
# um builder do MESMO arquivo (`_CensusFamilySql(" AND created_at >= ?")`) vira o corpo
# do builder, porque é lá que a tabela mora.
static func SqlExprOf(args : PackedStringArray, body : String, bodies : Dictionary) -> String:
	if args.is_empty():
		return ""
	var head : String = args[0]
	if RegEx.create_from_string(r"^[A-Za-z_]\w*$").search(head) != null:
		head = VarInitOf(body, head)
	if not TablesOf(head).is_empty():
		return head
	for m in RegEx.create_from_string(r"\b([A-Za-z_]\w*)\s*\(").search_all(head):
		var hop : String = str(bodies.get(m.get_string(1), ""))
		if not TablesOf(hop).is_empty():
			return hop
	return head

# Os bindings de uma consulta são o ÚLTIMO argumento: é a forma da assinatura
# (`QueryBindings(query, bindings)`, `execute(sql, params)`), e o que o driver entrega
# ao SQLite. Aceita também o nome de uma variável (`QueryBindings(sql, bindings)`),
# cuja grandeza a régua então lê no inicializador dela no mesmo corpo.
static func BindingsOf(args : PackedStringArray) -> String:
	if args.size() < 2:
		return ""
	return args[args.size() - 1].strip_edges()

# Inicializador de uma variável local (`var bindings : Array = [sinceSec]`), lido do
# CORPO da função que faz a consulta — não do arquivo inteiro, senão um `var bindings`
# seguro de uma função serviria de álibi para o de outra.
static func VarInitOf(body : String, name : String) -> String:
	var re := RegEx.create_from_string(r"(?m)^[ \t]*var\s+" + name + r"\b[^=\n]*=\s*([^\n]*)")
	var m := re.search(body)
	if m == null:
		return ""
	return m.get_string(1).strip_edges()

static func ReachesParam(expr : String, body : String, params : PackedStringArray, depth : int) -> bool:
	if depth <= 0:
		return false
	for m in RegEx.create_from_string(r"[A-Za-z_]\w*").search_all(expr):
		var name : String = m.get_string(0)
		for pname in params:
			if name == str(pname):
				return true
		var init : String = VarInitOf(body, name)
		if not init.is_empty() and ReachesParam(init, body, params, depth - 1):
			return true
	return false

# Veredito de tempo de uma expressão de binding. Prioridade: janela resolvida (a
# grandeza está escrita em segundos no fonte) > rotação de dia (um dia no pior caso) >
# parâmetro (a grandeza mora no call site, e é anotada, não acusada — a régua não
# inventa unidade) > `none` (órfão: nenhum número do fonte manda nesta janela).
static func BindVerdict(expr : String, body : String, params : PackedStringArray, rotations : Dictionary, nums : Dictionary, depth : int) -> Dictionary:
	var t : String = expr.strip_edges()
	if t.is_empty() or depth <= 0:
		return {"kind": "none"}
	if (t.begins_with("[") and t.ends_with("]")) or (t.begins_with("(") and t.ends_with(")")):
		var best : Dictionary = {"kind": "none"}
		for tok in _SplitTopArgs(t.substr(1, t.length() - 2)):
			var v : Dictionary = BindVerdict(tok, body, params, rotations, nums, depth - 1)
			var rv : int = _VerdictRank(v)
			var rb : int = _VerdictRank(best)
			# Maior tempo ganha; entre iguais, o que sabe POR QUE falha é mais útil que
			# o mudo — acusação sem motivo não é acusação, é ruído.
			if rv > rb or (rv == rb and (int(v.get("seconds", 0)) > int(best.get("seconds", 0))
			or (not str(v.get("why", "")).is_empty() and str(best.get("why", "")).is_empty()))):
				best = v
		return best
	var clock := RegEx.create_from_string(r"(?i)(?:\bnow\b|\bts\b|\bstamp\b|Timestamp\s*\(\s*\)|time\.time\s*\(\s*\))\s*-\s*([\w\s*().]+)")
	var sub := clock.search(t)
	if sub != null:
		var seconds : int = NumOf(sub.get_string(1), nums, 4)
		if seconds > 0:
			return {"kind": "window", "seconds": seconds}
		return {"kind": "none", "why": "subtração de relógio cuja grandeza o fonte não escreve em segundos (%s)" % sub.get_string(1).strip_edges()}
	for rname in rotations.keys():
		if t == str(rname) or t.contains(str(rname) + "("):
			return {"kind": "rotation", "seconds": DaySec}
	for pname in params:
		if RegEx.create_from_string(r"\b" + str(pname) + r"\b").search(t) != null:
			return {"kind": "param"}
	if RegEx.create_from_string(r"^[A-Za-z_]\w*$").search(t) != null:
		var init : String = VarInitOf(body, t)
		if not init.is_empty():
			var nested : Dictionary = BindVerdict(init, body, params, rotations, nums, depth - 1)
			if str(nested.get("kind")) != "none":
				return nested
			if ReachesParam(t, body, params, 3):
				return {"kind": "param"}
			var why : String = str(nested.get("why", ""))
			if not why.is_empty():
				return {"kind": "none", "why": why}
			return {"kind": "none", "why": "%s é inicializado por %s, e nada aí escreve a janela em segundos, nem vem de parâmetro" % [t, init]}
	if ReachesParam(t, body, params, 3):
		return {"kind": "param"}
	return {"kind": "none"}

static func _VerdictRank(v : Dictionary) -> int:
	match str(v.get("kind")):
		"window":
			return 3
		"rotation":
			return 2
		"param":
			return 1
	return 0

# Julga UM bound de tempo pela chamada que o CARREGA, e só por ela: é o argumento de
# SQL que diz se esta consulta lê `telemetry_event`, e é o argumento de bindings que diz
# que grandeza ela pede. Devolve `{"class": ..., "entry": ...}`, ou vazio quando o bound
# comprovadamente pertence a outra consulta (o ledger também tem `created_at < ?`, e um
# `;` caído no meio do arquivo faz a peça ao redor citar as duas tabelas — julgar pela
# peça denunciaria a podagem do ledger como se fosse leitura de telemetria). Um bound
# caído dentro de comentário não é consulta nenhuma: é prosa citando o predicado.
static func JudgeBound(text : String, mask : String, ranges : Dictionary, pairs : Dictionary, path : String, at : int, bodies : Dictionary, rotations : Dictionary, nums : Dictionary) -> Dictionary:
	if InRanges(ranges["comments"] as Array, at):
		return {}
	var ctx : Dictionary = FuncContextAt(text, at)
	var params : PackedStringArray = ctx["params"] as PackedStringArray
	var body : String = str(bodies.get(str(ctx["name"]), text))
	var entry : Dictionary = {"path": path, "func": str(ctx["name"])}
	var sql : String = ""
	var bindings : String = ""
	for call in CallSpans(mask, pairs, at):
		var args : PackedStringArray = ArgsOf(mask, text, int(call["open"]), int(call["close"]))
		var cand : String = SqlExprOf(args, body, bodies)
		if not TablesOf(cand).is_empty():
			sql = cand
			bindings = BindingsOf(args)
			break
	if sql.is_empty():
		# Nenhuma chamada encarreira o bound: ele está num literal solto (`var query :
		# String = "SELECT … FROM chest_instance …"`). A própria linha ainda diz o que a
		# consulta lê; não dizer nada é que é o defeito.
		sql = LineOf(text, at)
		if TablesOf(sql).is_empty():
			entry["why"] = "bound de `created_at` que nem uma chamada nem a própria linha declaram como consulta: nenhum fonte manda nesta janela"
			return {"class": "unowned", "entry": entry}
	entry["args"] = bindings
	if not TablesOf(sql).has("telemetry_event"):
		return {}
	if RegEx.create_from_string(r"(?i)INSERT\s+INTO\s+telemetry_event").search(sql) != null:
		return {}
	if RegEx.create_from_string(r"(?i)DELETE\s+FROM\s+telemetry_event").search(sql) != null:
		# O bound está no TEXTO do DELETE, que é a única coisa que separa poda de
		# erasure: quem montar a janela por concatenação de fragmento sai daqui e cai
		# na lista de erasures, porque a régua lê o que roda, não a intenção do autor.
		return {"class": "prunes", "entry": entry}
	if bindings.is_empty():
		entry["why"] = "a consulta tem `?` de tempo mas nenhum argumento de bindings: a janela não vem de lugar nenhum"
		return {"class": "unowned", "entry": entry}
	var verdict : Dictionary = BindVerdict(bindings, body, params, rotations, nums, 5)
	match str(verdict.get("kind")):
		"window":
			entry["seconds"] = int(verdict.get("seconds", 0))
			return {"class": "windows", "entry": entry}
		"rotation":
			entry["seconds"] = DaySec
			return {"class": "rotations", "entry": entry}
		"param":
			return {"class": "params", "entry": entry}
		_:
			entry["why"] = str(verdict.get("why", "bound de janela que não é segundos do fonte, rotação de dia nem parâmetro"))
			return {"class": "unowned", "entry": entry}
	return {"class": "unowned", "entry": entry}

# Censo do que cada LEITOR de `telemetry_event` pede de tempo. Duas varreduras de um
# mesmo arquivo: os BOUNDs de tempo, julgados um a um pela chamada que os carrega
# (`JudgeBound` — não pelo primeiro colchete à direita, nem pela peça em que o `;` os
# deixou cair), e as PEÇAS sem bound algum, que só podem estar declarando evidência de
# dia-zero, última linha ou cegueira de janela. Classificação:
#   window    : bound escrito em segundos na própria expressão (`now - 7 * DAY`,
#               `ts - FingerprintWindowSec`) ou no inicializador da variável de
#               bindings → grandeza resolvida;
#   rotation  : bound é rotação de dia/chamada sem-argumento cujo corpo roda dia →
#               um dia de lookback no pior caso;
#   param     : bound é parâmetro da função (a grandeza mora no call site);
#   unowned   : nada acima → ACUSAÇÃO (janela que nem o fonte declara);
#   evidence  : sem bound de tempo, mas `MIN(`/`MAX(` de `created_at` — é a evidência
#               do dia-zero do cohort, que a poda tem de congelar antes de matar;
#   latest    : sem bound, `ORDER BY id DESC` — a poda é por PREFIXO de id, então a
#               última linha só sai junto com a conta;
#   timeblind : sem bound e sem nenhuma das formas acima → ACUSAÇÃO.
# O bound vale nos dois sentidos (`>=`/`>` do lookback e `<=`/`<` da idade), porque é
# o sentido da poda.
static func ReaderCensus(entries : Array, nums : Dictionary) -> Dictionary:
	var out : Dictionary = {"windows": [], "rotations": [], "params": [], "unowned": [], "evidence": [], "latest": [], "timeblind": [], "erasure": [], "prunes": []}
	var boundRe := RegEx.create_from_string(r"(?i)created_at\s*(?:>=|>|<=|<)\s*\?")
	var minRe := RegEx.create_from_string(r"(?i)(?:min|max)\s*\(\s*[\w.]*created_at")
	var lastRe := RegEx.create_from_string(r"(?i)order\s+by\s+[\w.]*id\s+desc")
	for e in entries:
		var text : String = str(e["text"])
		var path : String = str(e["path"])
		var rotations : Dictionary = RotationsIn(text)
		var bodies : Dictionary = {}
		for b in Bodies(text):
			if not bodies.has(str(b["name"])):
				bodies[str(b["name"])] = str(b["body"])
		var liveBounds : Dictionary = {}
		var boundHits : Array = boundRe.search_all(text)
		if not boundHits.is_empty():
			var masked : Dictionary = MaskRanges(text)
			var mask : String = str(masked["mask"])
			var pairs : Dictionary = ParenPairs(mask)
			for bnd in boundHits:
				var at : int = int(bnd.get_start())
				if InRanges(masked["comments"] as Array, at):
					continue
				liveBounds[at] = true
				var verdict : Dictionary = JudgeBound(text, mask, masked, pairs, path, at, bodies, rotations, nums)
				if verdict.is_empty():
					continue
				out[str(verdict["class"])].append(verdict["entry"])
		var pieces : PackedStringArray = PackedStringArray(text.split(";"))
		var offsets : PackedInt64Array = PackedInt64Array()
		var acc : int = 0
		for piece in pieces:
			offsets.append(acc)
			acc += piece.length() + 1
		for ix in pieces.size():
			var piece : String = pieces[ix]
			# Leitor é quem CONSULTA a tabela: `FROM telemetry_event`, ou o `DELETE`
			# nela. Citar o nome não é consultar — o DDL de 016 declara
			# `created_at INTEGER NOT NULL` e a prosa da 065 discute índice; nenhum dos
			# dois pede janela, e acusá-los seria bater em quem não lê nada. O escopo é
			# da consulta, nunca da métrica: toda peça que lê `telemetry_event` continua
			# obrigada a declarar a própria janela.
			var isDelete : bool = RegEx.create_from_string(r"(?i)DELETE\s+FROM\s+telemetry_event").search(piece) != null
			if not isDelete and RegEx.create_from_string(r"(?i)\bFROM\s+telemetry_event").search(piece) == null:
				continue
			if RegEx.create_from_string(r"(?i)INSERT\s+INTO\s+telemetry_event").search(piece) != null:
				continue
			var hasLive : bool = false
			for m in boundRe.search_all(piece):
				if liveBounds.has(int(offsets[ix]) + int(m.get_start())):
					hasLive = true
					break
			if hasLive:
				continue			# os bounds VIVOS desta peça já foram julgados um a um acima
			var ctx : Dictionary = FuncContextAt(text, int(offsets[ix]) + piece.length() / 2)
			if isDelete:
				var rec : Dictionary = {"path": path, "func": str(ctx["name"]), "byTime": minRe.search(piece) != null}
				(out["prunes"] if bool(rec["byTime"]) else out["erasure"]).append(rec)
				continue
			if minRe.search(piece) != null:
				out["evidence"].append({"path": path, "func": str(ctx["name"])})
			elif lastRe.search(piece) != null:
				out["latest"].append({"path": path, "func": str(ctx["name"])})
			elif piece.contains("created_at"):
				out["timeblind"].append({"path": path, "func": str(ctx["name"]), "why": "menciona created_at sem predicado de janela"})
	return out

static func MaxWindow(windows : Array) -> int:
	var best : int = 0
	for w in windows:
		best = maxi(best, int(w.get("seconds", 0)))
	return best

static func WindowFiles(windows : Array) -> Array[String]:
	var seen : Dictionary = {}
	var out : Array[String] = []
	for w in windows:
		if not seen.has(str(w["path"])):
			seen[str(w["path"])] = true
			out.append(str(w["path"]))
	out.sort()
	return out

# A régua do horizonte: folga sobre a maior janela RESOLVIDA, e toda peça que não
# declara janela tem de ser evidência de dia-zero ou leitura de última linha — as
# duas formas que uma poda por prefixo não pode quebrar sem confessar.
static func HorizonShortfall(horizonSec : int, windows : Array, slack : int = HorizonSlackFactor) -> Array[String]:
	var out : Array[String] = []
	if horizonSec <= 0:
		out.append("nenhum horizonte declarado (TelemetryHorizonSec ausente ou <= 0): a tabela cresce para sempre")
		return out
	var best : int = MaxWindow(windows)
	if best > 0 and horizonSec < best * slack:
		out.append("horizonte %d s não tem folga de %dx sobre a maior janela resolvida (%d s, %s)" % [horizonSec, slack, best, str(windows)])
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

	# ------------------------------------- 6. horizonte de retenção (WorkOrder #164)
	# 6a — a régua deriva do fonte o que cada leitor pede, e confere a folga.
	var nums : Dictionary = NumTable(corpus)
	var rc : Dictionary = ReaderCensus(corpus, nums)
	var windows : Array = rc["windows"]
	var retentionScript : GDScript = load("res://sources/sql/SQLRetention.gd")
	var rconsts : Dictionary = retentionScript.call("get_script_constant_map")
	var horizon : int = int(rconsts.get("TelemetryHorizonSec", 0))
	var batch : int = int(rconsts.get("TelemetryBatchRows", 0))
	var shortfall : Array[String] = HorizonShortfall(horizon, windows)
	print("== HORIZONTE: horizonte %d s; janelas resolvidas %d (maior %d s em %d arquivos), rotações de dia %d, janelas por parâmetro %d, evidências de dia-zero %d, últimas-linhas %d, NÃO dominadas %d, cegas %d, poda %d, erasure %d ==" % [
		horizon, windows.size(), MaxWindow(windows), WindowFiles(windows).size(),
		rc["rotations"].size(), rc["params"].size(), rc["evidence"].size(), rc["latest"].size(),
		rc["unowned"].size(), rc["timeblind"].size(), rc["prunes"].size(), rc["erasure"].size()])
	for w in windows:
		print("  [janela] %s:%s = %d s" % [str(w["path"]), str(w["func"]), int(w.get("seconds", 0))])
	for w in rc["rotations"]:
		print("  [rotação] %s:%s = %d s" % [str(w["path"]), str(w["func"]), int(w.get("seconds", 0))])
	for w in rc["params"]:
		print("  [parâmetro] %s:%s (%s)" % [str(w["path"]), str(w["func"]), str(w["args"])])
	for w in rc["evidence"]:
		print("  [dia-zero] %s:%s" % [str(w["path"]), str(w["func"])])
	for w in rc["unowned"] + rc["timeblind"]:
		print("  [acuso] %s:%s — %s | args=%s" % [str(w["path"]), str(w["func"]), str(w.get("why", "")), str(w.get("args", ""))])
	Check(horizon > 0, "o produto declara um horizonte de telemetria (`TelemetryHorizonSec` = %d s)" % horizon)
	Check(windows.size() >= 4 and WindowFiles(windows).size() >= 2, "a derivação acha janelas resolvidas em >=2 arquivos (verde por inanição não é verde): %d em %d" % [windows.size(), WindowFiles(windows).size()])
	for f in WindowFiles(windows):
		Check(true, "a janela de %s é resolvida do fonte" % f)
	CheckEq(shortfall.size(), 0, "o horizonte tem folga de %dx sobre a maior janela que o fonte declara em segundos" % HorizonSlackFactor)
	CheckEq(rc["unowned"].size(), 0, "toda janela de leitura de telemetria é dominada: segundos do fonte, rotação de dia ou parâmetro — nada de bound órfão")
	CheckEq(rc["timeblind"].size(), 0, "nenhuma consulta a `telemetry_event` menciona `created_at` sem ser janela, evidência de dia-zero ou última linha")

	# 6b — a poda mora num lugar só, e a erasure continua morando no outro.
	var prunePaths : Array[String] = []
	for p in rc["prunes"]:
		prunePaths.append(str(p["path"]))
	prunePaths.sort()
	CheckEq(prunePaths.size(), 1, "existe UM caminho de poda temporal de telemetria (DELETE com predicado de tempo)")
	Check(prunePaths.size() == 1 and prunePaths[0] == "res://sources/sql/SQLRetention.gd", "a poda temporal mora na retenção, não espalhada em leitor esquecido (%s)" % str(prunePaths))
	var erasureFound : bool = false
	for p in rc["erasure"]:
		if str(p["path"]) == "res://sources/sql/SQL.gd":
			erasureFound = true
	Check(erasureFound, "a erasure LGPD por conta continua existindo: poda por tempo não é apagar conta")

	# 6c — wiring: o job chama a poda DEPOIS do botão, e o log confessa os números.
	var rsrc : String = FileAccess.get_file_as_string("res://sources/sql/SQLRetention.gd")
	var jobBody : String = ""
	var gateLine : int = -1
	var callLine : int = -1
	var lineIx : int = 0
	for line in rsrc.split("\n"):
		lineIx += 1
		if line.strip_edges().begins_with("static func RunRetentionJob"):
			jobBody = line + "\n"
		elif not jobBody.is_empty():
			if lineIx > 0 and RegEx.create_from_string("^\\s*(?:static\\s+)?func\\s+").search(line) != null and not line.strip_edges().begins_with("static func RunRetentionJob"):
				break
			jobBody += line + "\n"
		if jobBody.is_empty():
			continue
		if gateLine < 0 and jobBody.contains("RetentionEnabled()"):
			gateLine = jobBody.length()
		if callLine < 0 and jobBody.contains("PruneTelemetry("):
			callLine = jobBody.length()
	Check(not jobBody.is_empty(), "`RunRetentionJob` lido do próprio fonte para a ordem dos passes")
	Check(gateLine > 0 and callLine > 0 and gateLine < callLine, "a poda de telemetria roda DEPOIS do `RetentionEnabled()`: desligar a poda desliga as duas")
	var backupsSrc : String = FileAccess.get_file_as_string("res://sources/sql/SQLBackups.gd")
	Check(backupsSrc.contains("retention.get(\"telemetry\"") or backupsSrc.contains("retention.get(\"telemetry\", {}"), "o worker de backup lê o dicionário da telemetria (sem isto o passe rodaria mudo)")
	Check(backupsSrc.contains("telemetry.get(\"rows_deleted\"") or backupsSrc.contains("tele.get(\"rows_deleted\""), "o log do worker confessa quantas linhas de telemetria a poda derrubou")

	# 6d — CONTROLES PLANTADOS no mesmo predicado do caso real.
	var wideCorpus : Array = [{"path": "synthetic/sources/Wide.gd", "text": "" \
		+ "const DAY : int = 86400\n" \
		+ "func Read(now : int) -> int:\n" \
		+ "\treturn int(Launcher.SQL.QueryBindings(\"SELECT COUNT(*) AS n FROM telemetry_event WHERE created_at >= ?;\", [now - 400 * DAY])[0][\"n\"])\n"}]
	var wideNums : Dictionary = NumTable(wideCorpus)
	var wideWindows : Array = ReaderCensus(wideCorpus, wideNums)["windows"]
	CheckEq(wideWindows.size(), 1, "CONTROLE: a janela injetada de 400 dias é resolvida pelo MESMO predicado (%s)" % str(wideWindows))
	CheckEq(HorizonShortfall(horizon, wideWindows).size(), 1, "CONTROLE: horizonte de %d s contra janela de 400 dias é ACUSADO (a folga se mede, não a boa vontade)" % horizon)
	var narrowCorpus : Array = [{"path": "synthetic/sources/Narrow.gd", "text": "" \
		+ "const WINDOW : int = 7 * 86400\n" \
		+ "func Read(now : int) -> int:\n" \
		+ "\treturn int(Launcher.SQL.QueryBindings(\"SELECT COUNT(*) AS n FROM telemetry_event WHERE created_at >= ?;\", [now - WINDOW])[0][\"n\"])\n"}]
	CheckEq(HorizonShortfall(horizon, ReaderCensus(narrowCorpus, NumTable(narrowCorpus))["windows"]).size(), 0, "CONTROLE: a MESMA régua devolve ZERO para janela de 7 dias")
	var orphanCorpus : Array = [{"path": "synthetic/sources/Orphan.gd", "text": "" \
		+ "func Read() -> int:\n" \
		+ "\treturn int(Launcher.SQL.QueryBindings(\"SELECT COUNT(*) AS n FROM telemetry_event WHERE created_at >= ?;\", [SomeGlobalNotInSource])[0][\"n\"])\n"}]
	var orphanCensus : Dictionary = ReaderCensus(orphanCorpus, NumTable(orphanCorpus))
	CheckEq(orphanCensus["unowned"].size(), 1, "CONTROLE: bound que não é segundos do fonte, rotação nem parâmetro é ACUSADO (%s)" % str(orphanCensus["unowned"]))
	var blindCorpus : Array = [{"path": "synthetic/sources/Blind.gd", "text": "" \
		+ "func Read() -> int:\n" \
		+ "\treturn int(Launcher.SQL.QueryBindings(\"SELECT COUNT(*) AS n FROM telemetry_event WHERE created_at BETWEEN a AND b;\", [])[0][\"n\"])\n"}]
	CheckEq(ReaderCensus(blindCorpus, NumTable(blindCorpus))["timeblind"].size(), 1, "CONTROLE: leitura que menciona created_at sem janela nem forma protegida é ACUSADA")
	# A grandeza é derivada da CHAMADA, não do primeiro colchete à direita do `?`. Isso
	# só é régua de verdade se continuar mordendo quando o tempo é içado para uma
	# variável — `QueryBindings(sql, cutoffs)` não tem colchete nenhum depois do bound,
	# e era exatamente assim que um leitor de 400 dias passaria verde sob a régua velha.
	var hoistedCorpus : Array = [{"path": "synthetic/sources/Hoisted.gd", "text": "" \
		+ "const DAY : int = 86400\n" \
		+ "func Read(now : int) -> int:\n" \
		+ "\tvar cutoffs : Array = [now - 400 * DAY]\n" \
		+ "\treturn int(Launcher.SQL.QueryBindings(\"SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = ? AND created_at >= ?\", cutoffs)[0][\"n\"])\n"}]
	var hoistedCensus : Dictionary = ReaderCensus(hoistedCorpus, NumTable(hoistedCorpus))
	var hoistedWindows : Array = hoistedCensus["windows"]
	CheckEq(hoistedWindows.size(), 1, "CONTROLE: janela içada para uma variável é resolvida pelo inicializador dela (%s)" % str(hoistedWindows))
	CheckEq(HorizonShortfall(horizon, hoistedWindows).size(), 1, "CONTROLE: e a MESMA folga acusa os 400 dias escondidos na variável (%s)" % str(hoistedWindows))
	var hoistedOrphanCorpus : Array = [{"path": "synthetic/sources/HoistedOrphan.gd", "text": "" \
		+ "func Read() -> int:\n" \
		+ "\tvar cutoffs : Array = [Config.CutoffSomewhereElse]\n" \
		+ "\treturn int(Launcher.SQL.QueryBindings(\"SELECT COUNT(*) AS n FROM telemetry_event WHERE created_at >= ?\", cutoffs)[0][\"n\"])\n"}]
	var hoistedOrphan : Dictionary = ReaderCensus(hoistedOrphanCorpus, NumTable(hoistedOrphanCorpus))
	CheckEq(hoistedOrphan["unowned"].size(), 1, "CONTROLE: variável de bindings cujo inicializador não confessa tempo é ACUSADA (%s)" % str(hoistedOrphan["unowned"]))
	# O escopo novo (comentário não é leitor, e linha sem chamada ainda declara tabela)
	# só é honesto se continuar mordendo com a prosa ao lado: o MESMO arquivo planta um
	# `created_at < ?` em comentário E um leitor órfão de verdade, e a régua tem de
	# acusar exatamente um — nem os dois (prosa virou consulta), nem zero (leitor sumiu).
	var proseCorpus : Array = [{"path": "synthetic/sources/Prose.gd", "text": "" \
		+ "# a poda exige o `created_at < ?` na própria peça\n" \
		+ "func Read() -> int:\n" \
		+ "\treturn int(Launcher.SQL.QueryBindings(\"SELECT COUNT(*) AS n FROM telemetry_event WHERE created_at >= ?;\", [SomeGlobalNotInSource])[0][\"n\"])\n"}]
	var proseCensus : Dictionary = ReaderCensus(proseCorpus, NumTable(proseCorpus))
	CheckEq(proseCensus["unowned"].size(), 1, "CONTROLE: prosa citando o predicado não desarma a acusação do leitor real ao lado (%s)" % str(proseCensus["unowned"]))
	# E a queda para a LINHA (consulta montada fora de chamada, `var q : String =
	# "SELECT … FROM chest_instance …"`) só silencia quem confessa a tabela: sem nome de
	# tabela na linha nem na chamada, o bound é órfão do mesmo jeito.
	var looseCorpus : Array = [{"path": "synthetic/sources/Loose.gd", "text": "" \
		+ "func Build() -> String:\n" \
		+ "\tvar where : String = \" AND created_at >= ?\"\n" \
		+ "\treturn where\n"}]
	CheckEq(ReaderCensus(looseCorpus, NumTable(looseCorpus))["unowned"].size(), 1, "CONTROLE: bound sem chamada E sem tabela na própria linha é ACUSADO")

	# 6e — a poda medida no banco que o boot migrou.
	_horizonBehavior(_autoload("Launcher"), retentionScript, horizon, batch)
	_finish()

# ------------------------------------------------------------------ helpers da perna 6
func _x(sql : Node, query : String, bindings : Array) -> bool:
	return bool(sql.callv("ExecuteBindings", [query, bindings]))

func _n(sql : Node, query : String, bindings : Array) -> int:
	var rows : Array = sql.callv("QueryBindings", [query, bindings])
	return int((rows[0] as Dictionary).get("n", 0)) if not rows.is_empty() else 0

func _scalar(sql : Node, query : String, bindings : Array, fallback : int) -> int:
	var rows : Array = sql.callv("QueryBindings", [query, bindings])
	if rows.is_empty():
		return fallback
	var keys : Array = (rows[0] as Dictionary).keys()
	if keys.is_empty():
		return fallback
	return int((rows[0] as Dictionary)[keys[0]])

# Plano de execução do TEXTO que roda em produção, não de uma cópia daqui: as duas
# statement da poda são lidas de `SQLRetention.gd` e executadas como
# `EXPLAIN QUERY PLAN`. Copiar a query para o harness é o jeito de a régua continuar
# verde depois de alguém trocar o índice por um SCAN no produto.
func _pruneStatements() -> Array[String]:
	var text : String = FileAccess.get_file_as_string("res://sources/sql/SQLRetention.gd")
	var out : Array[String] = []
	for m in RegEx.create_from_string(r'"((?:SELECT|DELETE)[^"]*id IN \(SELECT id FROM telemetry_event[^"]*)"').search_all(text):
		out.append(m.get_string(1))
	return out

func _plan(sql : Node, query : String, bindings : Array) -> String:
	var joined : String = ""
	for row in sql.callv("QueryBindings", ["EXPLAIN QUERY PLAN " + query, bindings]):
		joined += str((row as Dictionary).get("detail", "")) + " | "
	return joined

# A perna comportamental: planta corpo velho e novo, poda pelo caminho do produto e
# confere quem morreu. O controle mais importante é o do horizonte 0: se a janela
# declarada some, a MESMA fixture tem de continuar com as linhas velhas — é o que
# prova que foi a poda que as derrubou, e não o acaso da montagem do banco.
func _horizonBehavior(launcher : Node, retention : GDScript, horizon : int, batch : int) -> void:
	print("[perna 6e] poda de telemetria medida no banco")
	if not Check(horizon > 0 and batch > 0, "números do produto antes de medir (horizonte %d, lote %d)" % [horizon, batch]):
		return
	var sql : Node = launcher.get("SQL")
	var tele : Node = launcher.get("Telemetry")
	if not Check(sql != null and tele != null, "SQL e Telemetry bootados para a perna comportamental"):
		return
	var now : int = int(Time.get_unix_time_from_system())
	var cutoff : int = int(retention.call("TelemetryCutoffAt", now, horizon))
	Check(cutoff < now and cutoff > now - horizon - DaySec * 2, "o corte cai no horizonte alinhado ao dia (%d vs now %d)" % [cutoff, now])
	var legacyUser : String = "hzn_leg_%d" % now
	var corpusUser : String = "hzn_cor_%d" % now
	var cappedUser : String = "hzn_cap_%d" % now
	var ids : Array = []
	for user in [legacyUser, corpusUser, cappedUser]:
		var created : bool = bool(sql.call("AddAccount", user, "hznfixture", user + "@hzn.test.local"))
		var accountID : int = int(sql.call("GetAccountID", user))
		if not Check(created and accountID > 0, "fixture: conta %s pelo caminho real" % user):
			return
		ids.append(accountID)
	var legacyID : int = int(ids[0])
	var corpusID : int = int(ids[1])
	var cappedID : int = int(ids[2])
	_x(sql, "UPDATE account SET created_timestamp = 0 WHERE account_id IN (?, ?, ?);", [legacyID, corpusID, cappedID])
	# Conta legada: o dia-zero dela SÓ existe na linha que a poda vai derrubar.
	var loginA : int = cutoff - 30
	var loginB : int = cutoff + 60
	_x(sql, "INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, 0, 'login', 1, '{}');", [loginA, legacyID])
	_x(sql, "INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, 0, 'login', 1, '{}');", [loginB, legacyID])
	# Corpus: um morto e um vivo de cada lado do corte, mais o ponto exato da fronteira.
	var stamps : Array = [cutoff - 5 * DaySec, cutoff - 1, cutoff, cutoff + 1, now - DaySec, now]
	for stamp in stamps:
		_x(sql, "INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, 0, 'settle', 1, '{}');", [int(stamp), corpusID])
	var d1Before : bool = bool(tele.call("IsD1Return", legacyID, loginB))
	var cohortBefore : int = _scalar(sql, "SELECT cohort_day FROM cohort_retention WHERE account_id = ?;", [legacyID], -1)
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM telemetry_event WHERE account_id = ? AND created_at < ?;", [corpusID, cutoff]), 2, "dois corpos velhos plantados abaixo do corte")
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM telemetry_event WHERE account_id = ? AND created_at >= ?;", [corpusID, cutoff]), 4, "quatro corpos plantados no lado vivo (inclui a fronteira exata)")
	Check(d1Before, "antes da poda o dia-zero da conta legada vem do login velho e o retorno dele é D1 (fixture viva)")
	CheckEq(cohortBefore, loginA / DaySec, "a view `cohort_retention` lê o MESMO dia-zero que o predicado")
	var result : Dictionary = retention.call("PruneTelemetry", sql, now)
	print("  [poda] %s" % str(result))
	Check(bool(result.get("ok", false)), "a rodada de poda completou (%s)" % str(result.get("skipped", "")))
	CheckEq(int(result.get("cutoff_at", -1)), cutoff, "o corte usado pela poda é o corte declarado")
	CheckEq(int(result.get("backfilled", 0)), 1, "só a conta cujo dia-zero vive na linha que ia morrer é congelada")
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM account WHERE account_id IN (?, ?) AND created_timestamp = 0;", [corpusID, cappedID]), 2,
		"as outras duas legadas, sem login nenhum, continuam sem carimbo — congelar não é inventar")
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM telemetry_event WHERE account_id = ? AND created_at < ?;", [corpusID, cutoff]), 0, "corpo abaixo do corte morreu")
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM telemetry_event WHERE account_id = ? AND created_at >= ?;", [corpusID, cutoff]), 4, "corpo dentro do corte viveu — inclusive a linha do ponto exato")
	CheckEq(_scalar(sql, "SELECT created_timestamp FROM account WHERE account_id = ?;", [legacyID], -1), loginA, "o dia-zero congelado É o login mais antigo, não uma adivinhação")
	CheckEq(_scalar(sql, "SELECT cohort_day FROM cohort_retention WHERE account_id = ?;", [legacyID], -1), cohortBefore, "a poda não moveu o dia-zero da view (era este o buraco: sem congelar, a view passava a ler o corpo vivo como origem)")
	Check(bool(tele.call("IsD1Return", legacyID, loginB)), "e o predicado continua dando o mesmo D1 depois da poda (uma régua, duas leituras)")
	var second : Dictionary = retention.call("PruneTelemetry", sql, now)
	CheckEq(int(second.get("rows_deleted", -1)), 0, "segunda poda derruba zero: o trabalho é proporcional ao corpo novo, não à tabela inteira")
	Check(int(second.get("passes", 0)) >= 1, "a passada vazia existe (é ela que prova a fila seca)")
	# Lote: a poda é limitada por `batchRows`, e é o teto que impede um único disparo
	# de varrer a tabela dentro do processo que segura o mundo. As sete linhas são
	# plantadas ABAIXO do corte e DEPOIS das vivas em id — é o caso que uma varredura
	# pela PK não resolve: a linha morta escondida atrás de uma viva nunca seria
	# alcançada. Se a janela deixar de ser por tempo, esta perna fica vermelha.
	for offset in 7:
		_x(sql, "INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, 0, 'settle', 1, '{}');", [cutoff - 30 - 60 * int(offset), cappedID])
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM telemetry_event WHERE account_id = ? AND created_at < ?;", [cappedID, cutoff]), 7, "sete corpos velhos plantados atrás das linhas vivas")
	# O controle do horizonte vem com corpo velho EXISTENTE no banco: se ele corresse
	# depois da drenagem, "não derrubou nada" seria verdade por acaso de fixture.
	var guarded : Dictionary = retention.call("PruneTelemetry", sql, now, 0, batch)
	CheckEq(int(guarded.get("rows_deleted", -1)), 0, "CONTROLE: horizonte 0 não derruba nada, com sete linhas mortas na mesa")
	CheckSame(str(guarded.get("skipped", "")), "no_horizon", "e confessa o motivo: `no_horizon`, não silêncio verde")
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM telemetry_event WHERE account_id = ? AND created_at < ?;", [cappedID, cutoff]), 7, "e as sete continuam lá — quem as poupou foi a janela declarada, não a poda")
	var capped : Dictionary = retention.call("PruneTelemetry", sql, now, horizon, 2, 3)
	CheckEq(int(capped.get("rows_deleted", -1)), 6, "com lote 2 e teto 3 passadas, a poda derruba 6 e não 7 (o teto é de escrita, não de prosa)")
	CheckEq(int(capped.get("passes", -1)), 3, "e para na passada pedida em vez de girar até o mundo acabar")
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM telemetry_event WHERE account_id = ? AND created_at < ?;", [cappedID, cutoff]), 1, "sobrou exatamente a linha que o teto deixou para a próxima rodada")
	# Custo físico da decisão: as statement são as do produto, executadas no banco real.
	# Um índice que existe mas não é usado é a mesma mentira de um índice que não
	# existe, com o custo do escrito a mais.
	var stmts : Array[String] = _pruneStatements()
	if CheckEq(stmts.size(), 2, "a poda é uma dupla COUNT + DELETE declarada no produto"):
		var counted : String = stmts[0].substr(stmts[0].find("id IN ("))
		var dropped : String = stmts[1].substr(stmts[1].find("id IN ("))
		CheckSame(counted.left(140), dropped.left(140), "contar e apagar são o MESMO conjunto — `rows_deleted` é o número do DELETE, não um palpite")
		var plan : String = _plan(sql, stmts[1], [cutoff, batch])
		print("  [plano] %s" % plan)
		Check(plan.contains("idx_telemetry_created_at"), "a poda busca pelo índice de tempo da migration 065 (%s)" % plan.left(220))
		Check(not plan.contains("TEMP B-TREE"), "e ordena pelo índice em vez de montar um b-tree temporário a cada passada")
		Check(not plan.contains("SCAN telemetry_event"), "e não varre a tabela inteira a cada gatilho de 6 h (%s)" % plan.left(220))
	var restock : Dictionary = retention.call("PruneTelemetry", sql, now)
	CheckEq(int(restock.get("rows_deleted", -1)), 1, "a passada seguinte limpa o que o teto deixou (a fila é drenada em rodadas)")
	_x(sql, "INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, 0, 'settle', 1, '{}');", [cutoff - 10, cappedID])
	var off : Dictionary = {}
	var envName : String = str((load("res://sources/sql/SQLCommons.gd").call("get_script_constant_map") as Dictionary).get("LedgerRetentionEnv", ""))
	OS.set_environment(envName, "0")
	off = retention.call("RunRetentionJob", sql, now, 1)
	OS.set_environment(envName, "")
	CheckSame(str(off.get("skipped", "")), "disabled", "CONTROLE: o botão de ops desliga a poda inteira (ledger E telemetria) sem recompilar")
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM telemetry_event WHERE account_id = ? AND created_at < ?;", [cappedID, cutoff]), 1, "e com ele desligado a linha velha continua lá — foi a poda que matou as outras, não o destino")
	var alive : Dictionary = retention.call("RunRetentionJob", sql, now, 1)
	CheckEq(int((alive.get("telemetry", {}) as Dictionary).get("rows_deleted", -1)), 1, "religado, o MESMO job derruba a linha (o passe vive dentro de `RunRetentionJob`, não num caminho paralelo)")
	_x(sql, "DELETE FROM telemetry_event WHERE account_id IN (?, ?, ?);", [legacyID, corpusID, cappedID])
	_x(sql, "DELETE FROM account WHERE account_id IN (?, ?, ?);", [legacyID, corpusID, cappedID])
	CheckEq(_n(sql, "SELECT COUNT(*) AS n FROM telemetry_event WHERE account_id IN (?, ?, ?);", [legacyID, corpusID, cappedID]), 0, "fixture limpa: a poda não deixa rastro no banco do próximo harness")


func _finish() -> void:
	print("== TELEMETRY CENSUS: %d checks, %d failures ==" % [checks, failures])
	quit(0 if failures == 0 else 1)
