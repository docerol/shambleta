extends RefCounted
class_name SQLReadPool

# Pool de leitores do SQL.gd: conexões SQLite SEPARADAS do handle de escrita,
# cada uma com `PRAGMA query_only=1`, usadas só para leitura pura fora de
# transação de escrita (ver `SQLReadRules`). É isso que o WAL compra: leitores
# concorrentes com o writer sem esperar o `queryMutex` único do processo — e,
# quando existir leitor fora da main thread, sem esperar uns pelos outros.
#
# O que este arquivo NÃO é: fonte de verdade. Uma leitura que falha aqui devolve
# `ok = false` e o chamador (`SQL.QueryBindings` / `SQL.Query`) reexecuta no
# handle do writer sob o mutex. `[]` do pool nunca significa "zero linhas".
#
# Por que `read_only = true` da engine não é usado: medido neste repositório com
# Godot 4.7.2 + libgdsqlite (2026-09-27), abrir com a flag e fazer um SELECT em
# banco WAL devolve `unable to open database file` (a conexão READONLY da engine
# não consegue inicializar o -shm do WAL). Quem funciona é `PRAGMA query_only=1`
# numa conexão normal: escrita é recusada com "attempt to write a readonly
# database" e a leitura vê todo commit. Ver tests/read_pool_test.gd, que reafirma
# as duas coisas.

# Cada slot é {"db": SQLite, "mutex": Mutex}. Um handle do gdsqlite NÃO é
# reentrante: as duas threads do processo (main e o worker de backup) podem bater
# no mesmo slot, então a mutex do slot é o que garante "um handle, uma thread por
# vez" — e é ela que também protege a leitura de `query_result`, que é property do
# handle e é copiada para fora ainda sob a lock.
var entries : Array = []
var dbPath : String = ""
var isOpen : bool = false
var slotCursor : int = 0

# Contadores de observabilidade (o gate de benchmark lê daqui).
var readCount : int = 0
var failureCount : int = 0
var stuckSlotResets : int = 0
var lastError : String = ""

# Slots com conexão viva de verdade (um handle pode ter caído; slot vazio não é
# leitor). `Ready()` continua O(1) porque é chamado em toda leitura roteada.
func ActiveSlots() -> int:
	var live : int = 0
	for entry in entries:
		if entry["db"] != null:
			live += 1
	return live

func Ready() -> bool:
	return isOpen and not entries.is_empty()

# Abre `size` conexões de leitura sobre `path`. Falha fechada: se QUALQUER
# verificação de segurança pegar mal (banco não está em WAL, query_only não
# pegou, SELECT de prova falhou), o pool volta a zero e o processo inteiro fica
# no caminho histórico de mutex único. Não existe "pool meio aberto".
func Open(path : String, size : int) -> bool:
	Close()
	if path.is_empty() or size <= 0:
		return false
	dbPath = path
	for _slot in size:
		var handle : SQLite = SQLite.new()
		handle.path = path
		handle.read_only = false
		handle.verbosity_level = SQLCommons.ReadPoolVerbosity
		if not handle.open_db():
			lastError = "open_db: " + str(handle.error_message)
			Close()
			return false
		var entry : Dictionary = {"db": handle, "mutex": Mutex.new()}
		entries.append(entry)
		# busy_timeout antes de qualquer outra coisa: um leitor em WAL quase nunca
		# espera, mas se esperar ele espera com prazo e devolve falha — não trava.
		_SlotQuery(entry, "PRAGMA busy_timeout=%d;" % SQLCommons.ReadPoolBusyTimeoutMs)
		_SlotQuery(entry, "PRAGMA query_only=1;")
		if not _VerifySlot(entry):
			Close()
			return false
	isOpen = true
	return true

func _VerifySlot(entry : Dictionary) -> bool:
	var handle : SQLite = entry["db"]
	# 1) WAL é pré-condição, não otimização. Sem WAL, um leitor em conexão própria
	#    vê o arquivo principal e pode NÃO ver o commit do writer (e pode apanhar
	#    SQLITE_BUSY no meio de uma transação de escrita): é o caminho que devolve
	#    leitura errada em vez de lenta. Recusar aqui é o gate.
	if not _SlotQuery(entry, "SELECT * FROM pragma_journal_mode;"):
		lastError = "journal_mode: " + str(handle.error_message)
		return false
	var modeRows : Array = handle.query_result
	var mode : String = str(modeRows[0].get("journal_mode", "")) if not modeRows.is_empty() else ""
	if mode.to_lower() != "wal":
		lastError = "journal_mode = " + mode + " (exigido wal)"
		return false
	# 2) query_only confirmado na própria conexão: é o cinto que impede qualquer
	#    caminho futuro de escrever por aqui.
	if not _SlotQuery(entry, "SELECT * FROM pragma_query_only;"):
		lastError = "query_only: " + str(handle.error_message)
		return false
	var onlyRows : Array = handle.query_result
	if onlyRows.is_empty() or int(onlyRows[0].get("query_only", 0)) != 1:
		lastError = "query_only não pegou"
		return false
	# 3) o SELECT de prova usa a mesa vazia `sqlite_master`: se a conexão não lê o
	#    arquivo, o pool não abre.
	return _SlotQuery(entry, "SELECT count(*) AS c FROM sqlite_master;")

# Executa uma statement sob a mutex do slot e copia o resultado para fora ainda
# sob a lock. `{"ok": false}` é ordem para o chamador reexecutar no writer.
func ExecuteRead(statement : String, params : Array) -> Dictionary:
	if not Ready():
		return {"ok": false, "rows": []}
	var attempts : int = entries.size()
	for _attempt in attempts:
		var slot : int = slotCursor % entries.size()
		slotCursor += 1
		var entry : Dictionary = entries[slot]
		var result : Dictionary = _ReadOnSlot(entry, statement, params)
		if bool(result["ok"]):
			return result
		# slot viciado (preso em txn, handle caído) é recuperado no próprio
		# _ReadOnSlot; a contagem de falhas é o que faz o gate enxergar pool
		# degenerado indo para o fallback
		lastError = String(result.get("error", ""))
	return {"ok": false, "rows": []}

func _ReadOnSlot(entry : Dictionary, statement : String, params : Array) -> Dictionary:
	var mutex : Mutex = entry["mutex"]
	mutex.lock()
	var handle : SQLite = entry["db"]
	if handle == null:
		# slot sem conexão (handle liberado depois de um erro de runtime): conta a
		# falha e devolve a ordem de fallback em vez de chamar método em null e
		# derrubar quem só queria ler uma linha
		failureCount += 1
		mutex.unlock()
		return {"ok": false, "rows": [], "error": "slot sem conexao"}
	if int(handle.get_autocommit()) == 0:
		# leitura em aberto nunca deveria deixar txn; se deixar, o snapshot do slot
		# está congelado e ele passaria a ler o passado para sempre. Desarma.
		handle.query("ROLLBACK;")
		stuckSlotResets += 1
	var ok : bool = false
	if params.is_empty():
		ok = handle.query(statement)
	else:
		ok = handle.query_with_bindings(statement, params)
	# Lido sob a lock do slot. Não duplica: o gdsqlite REATRIBUI `query_result` a
	# cada query (medido em tests/read_pool_test.gd, check "aliasing"), e é o que
	# o caminho do writer já faz hoje — `SQL.Query` devolve a referência cru de
	# `db.query_result`. Quem segura a referência antiga continua válido.
	var rows : Array = handle.query_result if ok else []
	var error : String = "" if ok else str(handle.error_message)
	# contagem sob a mutex do slot: é o que faz `readCount` ser o número de round
	# trips de verdade (o gate de benchmark soma isso ao contador do writer)
	if ok:
		readCount += 1
	else:
		failureCount += 1
	mutex.unlock()
	return {"ok": ok, "rows": rows, "error": error}

# Query de manutenção do slot (PRAGMA/verificação), também serializada pela mutex.
func _SlotQuery(entry : Dictionary, statement : String) -> bool:
	var mutex : Mutex = entry["mutex"]
	mutex.lock()
	var ok : bool = (entry["db"] as SQLite).query(statement)
	mutex.unlock()
	return ok

func Close() -> void:
	isOpen = false
	for entry in entries:
		var mutex : Mutex = entry["mutex"]
		mutex.lock()
		var handle : SQLite = entry["db"]
		if handle != null:
			if int(handle.get_autocommit()) == 0:
				handle.query("ROLLBACK;")
			handle.close_db()
			entry["db"] = null
		mutex.unlock()
	entries = []

func Stats() -> Dictionary:
	return {
		"open": isOpen,
		"slots": ActiveSlots(),
		"reads": readCount,
		"failures": failureCount,
		"stuckResets": stuckSlotResets,
		"lastError": lastError
	}

func ResetStats() -> void:
	readCount = 0
	failureCount = 0
	stuckSlotResets = 0
	lastError = ""
