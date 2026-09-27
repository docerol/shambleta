extends RefCounted
class_name SQLReadRules

# Decisor puro de roteamento de leitura. O WAL do SQLite permite leitores
# concorrentes com o writer; o mutex único de `SQL.gd` não. A regra vive separada
# do pool para ser testável sem banco, sem thread e sem handle — é aqui que mora o
# risco de corromper leitura de dinheiro, então ela tem que ser a parte mais chata
# e mais verificável do diretório.
#
# A decisão é por SEMÂNTICA da statement, nunca por conveniência do chamador:
#
#  1. `txnDepth > 0` -> NUNCA roteia. Dentro de uma transação de escrita a
#     leitura tem que sair do handle da própria transação (`db`): no handle do
#     pool ela veria o snapshot do último commit e não o trabalho ainda não
#     cometido do lambda — é exatamente assim que se perde estado de dinheiro
#     (`GetGemsRaw`, `EconomyKernel.GetBalance`, leituras de ledger feitas dentro
#     de `Transaction()`). A regra vale para QUALQUER thread, não só para a dona
#     da transação: enquanto houver escrita em aberto o pool não é retrato
#     honesto do estado que o servidor autoritativo acabou de decidir.
#  2. Statement que não seja leitura pura e determinável -> NUNCA roteia. O
#     critério é whitelist de forma, não lista de palavras proibidas: só passa
#     SELECT/WITH de UMA única statement sem nenhum verbo de escrita em token de
#     identificador (literais e comentários são removidos antes; aspas ou
#     comentário não terminados reprovam). Isso mantém no handle do writer tudo
#     o que ele hoje já usa e não pode sair de lá: os `PRAGMA` e o DDL das
#     migrations (`Query` do gdsqlite executa script multi-statement), o
#     `PRAGMA table_info` de `_SchemaOf`, `SetVersion`, e os UPDATE/DELETE
#     interpolados de `SQL.gd`. Forma nenhuma desqualifica `SELECT changes()`,
#     porque ela É um SELECT puro — estado de conexão sai por nome
#     (`ConnectionStateFuncs`), não por semântica de statement.
#  3. Pool fechado ou desabilitado -> caminho de sempre (mutex único + `db`).
#
# Direção do erro: qualquer dúvida devolve "não roteie", que é o comportamento
# histórico. O pool nunca é fonte de verdade quando falha — `SQLReadPool.ExecuteRead`
# devolve vazio e o chamador reexecuta no handle do writer.

# Palavras que desqualificam uma statement como leitura. Comparadas como token
# inteiro de identificador, então `created_at`, `is_deleted`, `drop_chance` e
# `updated_rows` não casam — e `ON CONFLICT DO UPDATE` casa, que é o desejado:
# upsert é escrita.
const WriteVerbs : Dictionary[String, bool] = {
	"INSERT": true, "UPDATE": true, "DELETE": true, "REPLACE": true,
	"CREATE": true, "DROP": true, "ALTER": true, "TRUNCATE": true,
	"BEGIN": true, "COMMIT": true, "ROLLBACK": true, "SAVEPOINT": true,
	"RELEASE": true, "VACUUM": true, "ATTACH": true, "DETACH": true,
	"REINDEX": true, "ANALYZE": true, "PRAGMA": true, "GRANT": true,
	"REVOKE": true, "SET": true, "CALL": true, "EXECUTE": true, "RETURNING": true
}

# Funções que leem ESTADO DA CONEXÃO, não o banco. `changes()` responde quantas
# linhas a ÚLTIMA statement daquela handle alterou; `last_insert_rowid()` é o
# rowid do último INSERT daquela handle. São por conexão: no handle do pool, que
# não executou nenhum dos dois, a resposta é um linha válida com `0` — e como vem
# linha, o fallback de "pool devolveu vazio" não dispara. O dano é silencioso e
# não é cosmético: é exatamente assim que `AdsCosmeticsService._ConsumeAdSlot`
# passou a ler `bad_token` num slot recém-mintado, que `SQL.ConsumeTwoFactorToken`
# leria replay em token válido, e que o CAS de `update_row*` leria "não casou
# linha" em UPDATE que comitou. Whitelist de forma nenhuma cobre isso: a statement
# é um SELECT puro. A exclusão tem de ser nominal.
const ConnectionStateFuncs : Dictionary[String, bool] = {
	"CHANGES": true, "TOTAL_CHANGES": true, "LAST_INSERT_ROWID": true
}

# Teto de comprimento: statement gigante não é caminho quente de leitura. Devolver
# false manda para o handle do writer sem varrer megabytes no caminho rápido.
const MaxStatementChars : int = 4096

# As duas palavras que podem abrir uma leitura roteável. Comparação direta, sem
# array constante: `PackedStringArray([...])` não é expressão constante no 4.7 e
# estouraria o parse de quem só queria classificar um SELECT.
const ReadStarterSelect : String = "SELECT"
const ReadStarterWith : String = "WITH"

# Branch de `String.lstrip`: exatamente o que separa espaço de primeira palavra.
const LeadingBlanks : String = " \t\r\n\f\v"

# Memória da decisão: a regra é função PURA do texto da statement, então a
# resposta de um texto visto uma vez vale para sempre. É o que tira o
# classificador do gargalo — medido em `tests/read_pool_test.gd`: ~0,5 us por
# chamada repetida contra ~210 us do scanner byte a byte. O dicionário é
# compartilhado pelas duas threads do processo (main e worker de backup), então
# cada acesso passa pela mutex da cache: um lock curto aqui custa ordens de
# magnitude menos que a queryMutex única que o pool existe para evitar.
const MaxCachedStatements : int = 512
static var verdictMutex : Mutex = Mutex.new()
static var verdictCache : Dictionary[String, int] = {}

# Contadores dos três caminhos. Observabilidade pura: podem perder incremento sob
# thread e nunca participam de decisão.
static var cacheHits : int = 0
static var fastPathHits : int = 0
static var scannerPathHits : int = 0

# Uma única expressão com todos os nomes que desqualificam uma leitura, compilada
# na carga do script. Entra por `_static_init` (e não por lazy init) porque as
# duas threads classificam ao mesmo tempo e compilar duas vezes seria corrida.
static var blockPattern : RegEx = null

static func _static_init() -> void:
	var words : String = ""
	for verb in WriteVerbs:
		words += str(verb) + "|"
	for fn in ConnectionStateFuncs:
		words += str(fn) + "|"
	if words.length() <= 1:
		return
	blockPattern = RegEx.new()
	if blockPattern.compile("\\b(?:%s)\\b" % words.substr(0, words.length() - 1)) != OK:
		blockPattern = null

static func PathStats() -> Dictionary:
	return {
		"cache": cacheHits,
		"fast": fastPathHits,
		"scanner": scannerPathHits,
		"cached": verdictCache.size(),
		"patternReady": blockPattern != null
	}

static func ResetDecisionMemory() -> void:
	verdictMutex.lock()
	verdictCache.clear()
	verdictMutex.unlock()
	cacheHits = 0
	fastPathHits = 0
	scannerPathHits = 0

# Caminho rápido: certifica "leitura pura" SEM tokenizar — uma cópia em
# maiúsculas, duas varreduras nativas de String e UMA busca de regex. Ele só pode
# responder "sim"; qualquer dúvida devolve false e a decisão cai no scanner
# preciso abaixo. Argumento de segurança:
#   * o primeiro token é SELECT/WITH seguido de caractere que não é de
#     identificador, então não é `SELECTX` nem `WITHDRAW...`;
#   * existe no máximo UM ";" no texto inteiro e ele é o último caractere, então
#     não há segunda statement escondida (nem em literal, nem em comentário: não
#     existe outro ";");
#   * a regex não acha nenhum verbo de escrita nem função de estado de conexão
#     como PALAVRA em lugar nenhum do texto. Uma segunda statement ou um CTE de
#     escrita (`WITH d AS (DELETE ...)`) precisaria de um deles; `changes()` e
#     `last_insert_rowid()` são por conexão e mentiriam no handle do pool.
#   * o texto não tem NENHUM marcador de literal ou de comentário (`'`, `"`,
#     `--`, `/*`, `*/`). É o que sustenta os dois itens acima: sem aspas nem
#     comentário, o `count(";")` e a regex são varreduras do texto que o scanner
#     também veria. Com eles presentes, o caminho rápido NÃO tem como saber o que
#     é código e o que é conteúdo — um `;` dentro de literal passaria despercebido
#     e um `SELECT 'aspas nao terminadas` seria certificado como leitura. Isso não
#     é perda: a query com literal vai para o scanner, onde já ia de qualquer
#     forma por causa do verbo que o literal costuma carregar. Os dois caminhos são
#     obrigados a concordar em todas as fixtures de `tests/read_pool_test.gd`.
# Over-rejection é o único erro possível daqui (`created_at` não casa; um verbo
# dentro de literal casa e cai no scanner, que decide certo), e regex ausente
# significa caminho rápido fechado, não decisão por palpite.
static func _FastCertify(upper : String) -> bool:
	if blockPattern == null:
		return false
	if upper.find("'") >= 0 or upper.find("\"") >= 0:
		return false
	if upper.contains("--") or upper.contains("/*") or upper.contains("*/"):
		return false
	var head : String = upper.lstrip(LeadingBlanks)
	var prefix : int = 0
	if head.begins_with(ReadStarterSelect):
		prefix = ReadStarterSelect.length()
	elif head.begins_with(ReadStarterWith):
		prefix = ReadStarterWith.length()
	else:
		return false
	if head.length() > prefix:
		var next : int = head.unicode_at(prefix)
		if (next >= 65 and next <= 90) or (next >= 48 and next <= 57) or next == 95:
			return false
	var body : String = head.strip_edges()
	var separators : int = body.count(";")
	if separators > 1:
		return false
	if separators == 1 and not body.ends_with(";"):
		return false
	return blockPattern.search(upper) == null

static func _IsIdentByte(byte : int) -> bool:
	return (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57) or byte == 95

static func _IsAlphaByte(byte : int) -> bool:
	return (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)

static func _IsDigitByte(byte : int) -> bool:
	return byte >= 48 and byte <= 57

static func _IsSpaceByte(byte : int) -> bool:
	return byte == 32 or byte == 9 or byte == 10 or byte == 13 or byte == 12

# Remove comentários (`--…`, `/*…*/`) e literais (`'…'`, `"…`) e devolve só o
# código. `ok` sai false em aspas ou comentário não terminado — forma ambígua,
# justamente a que não pode ser roteada por palpite.
static func CodeOnly(statement : String) -> Dictionary:
	var bytes : PackedByteArray = statement.to_utf8_buffer()
	var out : PackedByteArray = PackedByteArray()
	out.resize(bytes.size())
	var written : int = 0
	var i : int = 0
	while i < bytes.size():
		var byte : int = bytes[i]
		if byte == 45 and i + 1 < bytes.size() and bytes[i + 1] == 45: # "--"
			while i < bytes.size() and bytes[i] != 10:
				i += 1
			continue
		if byte == 47 and i + 1 < bytes.size() and bytes[i + 1] == 42: # "/*"
			var end : int = -1
			var j : int = i + 2
			while j + 1 < bytes.size():
				if bytes[j] == 42 and bytes[j + 1] == 47:
					end = j
					break
				j += 1
			if end < 0:
				return {"code": "", "ok": false}
			i = end + 2
			out[written] = 32
			written += 1
			continue
		if byte == 39 or byte == 34: # aspas simples / duplas
			var quote : int = byte
			var k : int = i + 1
			var closed : bool = false
			while k < bytes.size():
				if bytes[k] == quote:
					if k + 1 < bytes.size() and bytes[k + 1] == quote:
						k += 2 # '' / "" é escape de conteúdo, não fim de literal
						continue
					closed = true
					break
				k += 1
			if not closed:
				return {"code": "", "ok": false}
			i = k + 1
			out[written] = 32 # espaço no lugar do literal: `a='x'b` não vira `ab`
			written += 1
			continue
		out[written] = byte
		written += 1
		i += 1
	return {"code": out.slice(0, written).get_string_from_utf8(), "ok": true}

# Tokens de identificador (maiúsculos) + ";" como token próprio. Números e
# operadores são descartados, mas quebram a palavra: `1delete` não vira `DELETE`.
static func _Tokens(code : String) -> PackedStringArray:
	var bytes : PackedByteArray = code.to_utf8_buffer()
	var tokens : PackedStringArray = PackedStringArray()
	var i : int = 0
	while i < bytes.size():
		var byte : int = bytes[i]
		if _IsSpaceByte(byte):
			i += 1
			continue
		if byte == 59: # ";"
			tokens.append(";")
			i += 1
			continue
		if _IsAlphaByte(byte):
			var start : int = i
			while i < bytes.size() and _IsIdentByte(bytes[i]):
				i += 1
			tokens.append(bytes.slice(start, i).get_string_from_utf8().to_upper())
			continue
		if _IsDigitByte(byte):
			while i < bytes.size() and _IsDigitByte(bytes[i]):
				i += 1
			continue
		i += 1
	return tokens

static func IsPureRead(statement : String) -> bool:
	if statement.is_empty() or statement.length() > MaxStatementChars:
		return false
	verdictMutex.lock()
	var cached : int = int(verdictCache.get(statement, -1))
	verdictMutex.unlock()
	if cached >= 0:
		cacheHits += 1
		return cached == 1
	var verdict : bool = DecideStatement(statement)
	verdictMutex.lock()
	if verdictCache.size() < MaxCachedStatements:
		verdictCache[statement] = 1 if verdict else 0
	verdictMutex.unlock()
	return verdict

# Decisão em dois degraus: certificação rápida (varredura nativa + uma regex) e,
# para o que ela não certifica, o scanner preciso.
static func DecideStatement(statement : String) -> bool:
	if _FastCertify(statement.to_upper()):
		fastPathHits += 1
		return true
	scannerPathHits += 1
	return PureReadScanner(statement)

# Scanner preciso: remove literais e comentários, tokeniza e exige forma de
# leitura. É a autoridade nos casos que o caminho rápido não certifica (comentário
# antes do SELECT, verbo dentro de literal, `;` solto). Os dois caminhos nunca
# podem discordar — `tests/read_pool_test.gd` confere isso em todas as fixtures.
static func PureReadScanner(statement : String) -> bool:
	if statement.is_empty() or statement.length() > MaxStatementChars:
		return false
	var stripped : Dictionary = CodeOnly(statement)
	if not bool(stripped["ok"]):
		return false
	var tokens : PackedStringArray = _Tokens(String(stripped["code"]))
	if tokens.is_empty():
		return false
	if tokens[0] != ReadStarterSelect and tokens[0] != ReadStarterWith:
		return false
	# Uma única statement: `Query()` do gdsqlite executa o script inteiro, então
	# "SELECT …; DELETE …" passaria no teste do primeiro token.
	var separators : int = 0
	for token in tokens:
		if token == ";":
			separators += 1
		elif WriteVerbs.has(token):
			return false
		elif ConnectionStateFuncs.has(token):
			return false
	return separators <= 1

# Regra mestra. `poolReady` é o estado do pool (aberto, WAL confirmado, slots
# vivos); `txnDepth` conta transações de escrita em aberto no processo.
static func ShouldRoute(statement : String, txnDepth : int, poolReady : bool, enabled : bool) -> bool:
	if not enabled or not poolReady:
		return false
	if txnDepth > 0:
		return false
	return IsPureRead(statement)
