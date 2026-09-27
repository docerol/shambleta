extends SceneTree

# SOM-IDLE AUTH-P0 (AUDITORIA_2026-09-27 §10 e §22-P0-2): "takeover de conta via
# brute-force do código de reset". Este harness prende as quatro regras que fecham
# o furo, em nível unitário e sem tocar rede:
#
#  1. o código tem entropia DECLARADA (alfabeto base32 não ambíguo ^ 6 posições =
#     30 bits ≈ 1,07 × 10⁹, não os 10⁶ de dígito decimal);
#  2. tentativa errada consome budget: a N-ésima (N = ResetCodeMaxAttempts) apaga o
#     pending, e depois disso nem a tentativa correta passa;
#  3. pending único por conta: uma nova solicitação substitui a anterior, e o
#     código velho deixa de validar com o contador zerado;
#  4. limite de solicitações por CONTA em janela rolante, com o contador durável no
#     ledger `password_reset_request` (migration 050) — sobrevive ao restart.
#
# Uso: godot --headless --path . -s tests/accounts_fix_test.gd
# Exit code: número de checks falhos (0 = verde).
#
# Igual ao run_idle_tests: `-s` compila este arquivo ANTES dos global class_name e
# dos autoloads estarem registrados, então nada de identificador de projeto aqui —
# tudo via load()/call()/set()/get(). Os autoloads continuam bootando (EmailService
# usa `Util`, que é um global class, e só resolve depois do load do próprio
# EmailService, que acontece neste runtime).

# Relógio de teste: tempo fixo, para o harness provar TTL e janela sem dormir.
const BaseNow : int = 1700000000
const Minute : int = 60
# Piso de checks da corrida completa (o total real medido é 130, incluindo a
# própria guarda abaixo). Sem a guarda, um suite que morre no meio devolve
# "0 failures" com metade das checks feitas — o CI assinaria o que não rodou.
const ExpectedChecks : int = 120

var checks : int = 0
var failures : int = 0

var hasherScript : GDScript = null
var commonsScript : GDScript = null
var emailScript : GDScript = null
var serverScript : GDScript = null

var hasher : Object = null
var commons : Object = null

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(got : Variant, want : Variant, label : String) -> bool:
	checks += 1
	# Tipos diferentes abortam a comparação em GDScript 4 (`Invalid operands`), e a
	# suíte perdia a check sem contá-la como falha — `== RESULT:` continuava
	# dizendo zero falhas. `and` corta antes do `==`, então a comparação só roda
	# quando os tipos batem.
	var same : bool = typeof(got) == typeof(want) and got == want
	if not same:
		failures += 1
		print("  [FAIL] " + label + " (got " + str(got) + ", want " + str(want) + ")")
		return false
	print("  [ok] " + label)
	return true

func _initialize():
	_run()

func _getAutoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _run():
	print("== SOM-IDLE AUTH-P0 accounts harness ==")
	# Espera o boot: os global class_name do projeto precisam estar registrados
	# antes do load() dos scripts alvo (é o `load()` que os compila).
	var waited : int = 0
	while _getAutoload("Launcher") == null and waited < 30000:
		await create_timer(0.1).timeout
		waited += 100
	print("== boot wait done (waited %d ms) ==" % waited)

	hasherScript = load("res://sources/util/Hasher.gd")
	Check(hasherScript != null and hasherScript.can_instantiate(), "Hasher compila e instancia")
	commonsScript = load("res://sources/network/NetworkCommons.gd")
	Check(commonsScript != null and commonsScript.can_instantiate(), "NetworkCommons compila e instancia")
	emailScript = load("res://sources/network/server/EmailService.gd")
	Check(emailScript != null and emailScript.can_instantiate(), "EmailService compila e instancia")
	serverScript = load("res://sources/network/server/Server.gd")
	# `Server.gd` é checado só como carregaável: ele está na cauda de dependência de
	# scripts de OUTROS agentes (Formula/PlayerAgent/Peers), e um cascade de "Failed
	# to compile depended scripts" alheio não pode fingir que o corte de reset quebrou
	# — o contrato do handler de reset é medido no fonte, em `_SuiteSourceContract`.
	Check(serverScript != null, "Server carrega (o contrato dele é medido no fonte, abaixo)")
	if hasherScript == null or commonsScript == null or emailScript == null or serverScript == null:
		_finish()
		return

	hasher = hasherScript.new()
	commons = commonsScript.new()

	_SuiteCodeFormat()
	_SuiteSecureEquals()
	_SuiteAttemptConsumption()
	_SuiteSinglePending()
	_SuiteExpiry()
	_SuiteRequestBudget()
	_SuiteSourceContract()

	_finish()

func _finish():
	# Guarda contra corrida truncada: um SCRIPT ERROR no meio de um suite derruba o
	# `_run()` e o RESULT sairia "0 failures" com metade das checks contadas. O piso
	# é o total da corrida verde com folga — medir, não supor.
	Check(checks >= ExpectedChecks, "o harness rodou inteiro (>= %d checks; saiu %d)" % [ExpectedChecks, checks])
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

# Helpers -------------------------------------------------------------------

# Constante de script lida do GDScript compilado (o `-s` não enxerga o class_name).
func _Const(script : GDScript, name : String) -> Variant:
	return script.get_script_constant_map().get(name, null)

func _Hash(code : String) -> String:
	return str(hasher.call("HashPassword", code))

func _Normalize(code : String) -> String:
	return str(hasher.call("NormalizeResetCode", code))

func _IsValid(code : String) -> bool:
	return bool(hasher.call("IsValidResetCode", code))

func _Generate() -> String:
	return str(hasher.call("GenerateResetCode"))

func _Bits(space : float) -> int:
	return int(round(log(space) / log(2.0)))

# Instância fora da árvore: `_ready()` nunca roda, então nem `Conf` nem
# `HTTPRequest` são tocados — só a máquina de estado do reset importa aqui.
func _NewEmailService(store : Object, now : int) -> Node:
	var email : Node = emailScript.new()
	email.set("resetStore", store)
	email.set("nowOverride", now)
	return email

func _Source(path : String) -> String:
	return FileAccess.get_file_as_string(path)

# Corpo de uma função do fonte: do `func <name>(` (com ou sem `static`/`const`)
# até a próxima função no canto zero. Usado nos contratos de fonte — o que este
# harness não exercita por RPC (resposta única do handler, ordem dentro da
# transação) é medido no texto que o servidor executa.
func _FunctionBody(source : String, funcName : String) -> String:
	var start : int = source.find("func " + funcName + "(")
	if start < 0:
		return ""
	var rest : String = source.substr(start)
	var next : int = -1
	for boundary : String in ["\nfunc ", "\nstatic func ", "\nclass ", "\nvar ", "\nconst "]:
		var at : int = rest.find(boundary, 1)
		if at >= 0 and (next < 0 or at < next):
			next = at
	if next < 0:
		return rest
	return rest.substr(0, next)

func _Count(haystack : String, needle : String) -> int:
	var count : int = 0
	var from : int = 0
	while true:
		var at : int = haystack.find(needle, from)
		if at < 0:
			break
		count += 1
		from = at + needle.length()
	return count

# Recuo (em tabs) da primeira linha do corpo de função que contém `needle`.
# `-1` quando a linha não existe — usado para provar IRMANDADE de um `elif` com o
# `if` dele, coisa que `contains()` nenhum responde.
func _LineIndent(body : String, needle : String) -> int:
	for line in body.split("\n"):
		if line.contains(needle):
			var indent : int = 0
			while indent < line.length() and line[indent] == "\t":
				indent += 1
			return indent
	return -1

# 1. Formato e entropia declarada ------------------------------------------

func _SuiteCodeFormat():
	print("[suite] formato e entropia do código de reset")
	var alphabet : String = str(_Const(hasherScript, "ResetCodeAlphabet"))
	var length : int = int(_Const(hasherScript, "DefaultResetCodeLength"))

	CheckEq(alphabet.length(), 32, "alfabeto do código tem 32 símbolos (base32)")
	CheckEq(length, 6, "comprimento do código é 6 caracteres")
	Check(alphabet.find("0") < 0 and alphabet.find("O") < 0 and alphabet.find("1") < 0 and alphabet.find("I") < 0, "alfabeto sem ambíguos (nem 0/O nem 1/I)")
	CheckEq(256 % alphabet.length(), 0, "256 % |alfabeto| == 0 → byte mapeado sem viés e sem rejeição")
	CheckEq(int(_Const(commonsScript, "ResetCodeSize")), length, "NetworkCommons.ResetCodeSize espelha Hasher.DefaultResetCodeLength")
	CheckEq(int(_Const(commonsScript, "ResetCodeMaxAttempts")), 5, "budget de tentativas por pending é 5")

	# A alegação de entropia conferida no número, não no comentário.
	var space : float = pow(float(alphabet.length()), float(length))
	Check(space >= 1000000000.0, "espaço do código é >= 1e9 (32^6 = %s, contra os 10^6 antigos)" % str(int(space)))
	CheckEq(_Bits(space), 30, "entropia declarada do formato é 30 bits")
	# O que o auditorio mediu: ~1.100 conexões cobriam 10^6 dentro da janela de
	# 15 min. Agora: 5 tentativas por pending × 5 pendings por janela / 2^30.
	var odds : float = float(int(_Const(commonsScript, "ResetCodeMaxAttempts")) * int(_Const(commonsScript, "ResetRequestWindowMax"))) / space
	Check(odds < 0.000001, "chance de adivinhar numa janela é < 1e-6 (%.10f)" % odds)

	# Amostra: 200 códigos têm que caber no formato e não podem repetir.
	var seen : Dictionary = {}
	var digitOnly : int = 0
	var allValid : bool = true
	var wrongLength : bool = false
	for i in 200:
		var code : String = _Generate()
		if code.length() != length:
			wrongLength = true
		if not _IsValid(code):
			allValid = false
		if code.is_valid_int():
			digitOnly += 1
		seen[code] = true
	Check(not wrongLength, "os 200 códigos gerados têm o comprimento declarado")
	Check(allValid, "os 200 códigos gerados passam no validador do próprio formato")
	CheckEq(seen.size(), 200, "os 200 códigos gerados são todos distintos")
	# Probabilidade de um código só-dígitos: (8/32)^6 ≈ 2,4e-4 → 200 amostras
	# trazem letras em massa. É a prova operacional de que o espaço não é decimal.
	Check(digitOnly < 12, "letras aparecem nos códigos gerados (só-dígitos em %d/200 amostras)" % digitOnly)

	# Normalização: o que o usuário digita/cola vs. o que o hash guarda.
	CheckEq(_Normalize(" ab-cd ef "), "ABCDEF", "normalizar remove espaço e hífen e sobe para maiúsculo")
	CheckEq(_Normalize("\r\nA2b3C4 \n"), "A2B3C4", "normalizar sobrevive a quebra de linha de e-mail")
	Check(_IsValid("ABCDEF"), "ABCDEF é código válido (letras contam, não só dígitos)")
	Check(not _IsValid("123456"), "'123456' (código do espaço decimal antigo) é rejeitado")
	Check(not _IsValid("23456"), "5 caracteres é rejeitado")
	Check(not _IsValid("2345678"), "7 caracteres é rejeitado")
	Check(not _IsValid("2345IO"), "símbolos ambíguos fora do alfabeto são rejeitados")
	Check(not _IsValid("a2b3c4"), "minúscula crua não é código válido (normaliza antes)")
	Check(bool(commons.call("CheckResetCode", "a2b3c4")), "CheckResetCode normaliza: minúscula digitada é aceita")
	Check(bool(commons.call("CheckResetCode", "A2B3C4")), "CheckResetCode aceita o formato novo")
	Check(bool(commons.call("CheckResetCode", " A2 B3 C4 ")), "CheckResetCode aceita o código colado com espaço")
	Check(not bool(commons.call("CheckResetCode", "123456")), "CheckResetCode não aceita o espaço decimal antigo")
	Check(not bool(commons.call("CheckResetCode", "")), "código vazio é rejeitado")

# 2. Comparação em tempo constante -----------------------------------------

func _SuiteSecureEquals():
	print("[suite] SecureEquals (o P2 de `==` em hash, no mesmo lane)")
	Check(bool(hasher.call("SecureEquals", "aaaa", "aaaa")), "iguais → true")
	Check(not bool(hasher.call("SecureEquals", "aaaa", "aaab")), "diferente no último byte → false")
	Check(not bool(hasher.call("SecureEquals", "aaaa", "aaaaaa")), "comprimentos diferentes → false")
	Check(bool(hasher.call("SecureEquals", "", "")), "vazios → true")
	var hashA : String = _Hash("A2B3C4")
	CheckEq(hashA.length(), 64, "HashPassword devolve SHA-256 hex")
	Check(bool(hasher.call("SecureEquals", hashA, _Hash("A2B3C4"))), "hash do mesmo código bate")
	Check(not bool(hasher.call("SecureEquals", hashA, _Hash("A2B3C5"))), "hash de código diferente não bate")

# 3. Consumo de tentativa --------------------------------------------------

func _SuiteAttemptConsumption():
	print("[suite] tentativa errada consome o pending")
	var accountID : int = 4101
	var email : Node = _NewEmailService(FakeResetStore.new(), BaseNow)
	var code : String = _Generate()
	var wrong : String = _Generate()
	while wrong == code:
		wrong = _Generate()
	var codeHash : String = _Hash(code)
	var wrongHash : String = _Hash(wrong)
	var maxAttempts : int = int(_Const(commonsScript, "ResetCodeMaxAttempts"))

	email.call("CreateReset", accountID, codeHash)
	Check(bool(email.call("HasPendingReset", accountID)), "CreateReset abre um pending")
	CheckEq(int(email.call("ResetAttempts", accountID)), 0, "pending novo começa com zero tentativas")
	Check(bool(email.call("ValidateReset", accountID, codeHash)), "código correto valida")
	Check(bool(email.call("HasPendingReset", accountID)), "acerto NÃO consome o pending (quem apaga é o chamador, pós-commit)")

	# N-1 erradas: o pending continua vivo e o contador anda.
	for attempt in range(1, maxAttempts):
		Check(not bool(email.call("ValidateReset", accountID, wrongHash)), "tentativa errada %d falha" % attempt)
		CheckEq(int(email.call("ResetAttempts", accountID)), attempt, "tentativa errada %d contou contra o pending" % attempt)
		Check(bool(email.call("HasPendingReset", accountID)), "tentativa errada %d ainda não consumiu o pending" % attempt)

	# A N-ésima consome. Depois disso a correta também não passa — é exatamente
	# isto que tira o sentido de martelar o endpoint.
	Check(not bool(email.call("ValidateReset", accountID, wrongHash)), "tentativa errada %d falha" % maxAttempts)
	Check(not bool(email.call("HasPendingReset", accountID)), "na 5ª errada o pending é apagado (nova solicitação obrigatória)")
	Check(not bool(email.call("ValidateReset", accountID, codeHash)), "depois do consumo nem o código correto valida (6ª tentativa)")
	Check(not bool(email.call("ValidateReset", accountID, wrongHash)), "7ª tentativa contra pending morto continua false")

	# E o fluxo sobrevive: nova solicitação reabre o direito às 5 tentativas.
	email.call("CreateReset", accountID, codeHash)
	Check(bool(email.call("HasPendingReset", accountID)), "nova solicitação reabre o pending")
	CheckEq(int(email.call("ResetAttempts", accountID)), 0, "o novo pending zera o contador")
	Check(bool(email.call("ValidateReset", accountID, codeHash)), "o dono recupera a conta depois do exhaustion")

	# O cenário do usuário legítimo: três erradas (digitou torto) e depois o acerto.
	var accountTwo : int = 4102
	email.call("CreateReset", accountTwo, codeHash)
	for attempt in 3:
		Check(not bool(email.call("ValidateReset", accountTwo, wrongHash)), "conta B: tentativa errada %d falha" % (attempt + 1))
	Check(bool(email.call("ValidateReset", accountTwo, codeHash)), "conta B: código correto depois de 3 erradas ainda valida")
	email.free()

# 4. Pending único por conta -----------------------------------------------

func _SuiteSinglePending():
	print("[suite] pending único: nova solicitação substitui a anterior")
	var accountID : int = 4103
	var email : Node = _NewEmailService(FakeResetStore.new(), BaseNow)
	var codeA : String = _Generate()
	var codeB : String = _Generate()
	while codeB == codeA:
		codeB = _Generate()

	email.call("CreateReset", accountID, _Hash(codeA))
	for attempt in 3:
		email.call("ValidateReset", accountID, _Hash("ZZZZZZ"))
	CheckEq(int(email.call("ResetAttempts", accountID)), 3, "o pending da primeira solicitação queimou 3 tentativas")

	email.call("CreateReset", accountID, _Hash(codeB))
	CheckEq(int(email.call("ResetAttempts", accountID)), 0, "a substituição zera o contador (código novo, budget novo)")
	Check(not bool(email.call("ValidateReset", accountID, _Hash(codeA))), "o código ANTERIOR deixa de validar depois da nova solicitação")
	Check(bool(email.call("ValidateReset", accountID, _Hash(codeB))), "o código da solicitação mais recente valida")
	CheckEq((email.get("pendingResets") as Dictionary).size(), 1, "existe um único pending por conta")
	CheckEq((email.get("resetRequests") as Dictionary).size(), 0, "CreateReset sozinho não consome budget de solicitação")

	# O armazenamento é o hash, nunca o código em claro.
	var entry : Dictionary = (email.get("pendingResets") as Dictionary).get(accountID, {})
	var keys : Array = entry.keys()
	keys.sort()
	CheckEq(str(keys), '["attempts", "code_hash", "created", "expires"]', "a entrada guarda hash + created + expires + attempts")
	Check(str(entry.get("code_hash", "")) != codeB, "o código em claro não é armazenado")
	CheckEq(str(entry.get("code_hash", "")).length(), 64, "o valor guardado é um SHA-256 hex")
	Check(_Count(str(entry.get("code_hash", "")), codeB) == 0, "nenhum pedaço do hash é o código")
	email.free()

# 5. Expiração / TTL --------------------------------------------------------

func _SuiteExpiry():
	print("[suite] TTL do pending")
	var accountID : int = 4104
	var email : Node = _NewEmailService(FakeResetStore.new(), BaseNow)
	var code : String = _Generate()
	email.call("CreateReset", accountID, _Hash(code))
	var entry : Dictionary = (email.get("pendingResets") as Dictionary).get(accountID, {})
	var expiryMinutes : int = int(_Const(commonsScript, "ResetCodeExpiryMinutes"))
	CheckEq(int(entry.get("expires", 0)) - int(entry.get("created", 0)), expiryMinutes * Minute, "TTL do pending = ResetCodeExpiryMinutes (%d min)" % expiryMinutes)
	Check(bool(email.call("ValidateReset", accountID, _Hash(code))), "dentro do TTL valida")
	email.set("nowOverride", BaseNow + expiryMinutes * Minute)
	Check(not bool(email.call("ValidateReset", accountID, _Hash(code))), "no segundo exato do vencimento já não valida (fronteira fechada)")
	Check(not bool(email.call("HasPendingReset", accountID)), "o pending vencido sai da memória no primeiro toque")

	# Reemissão depois do vencimento volta com TTL novo.
	email.set("nowOverride", BaseNow + 2 * expiryMinutes * Minute)
	email.call("CreateReset", accountID, _Hash(code))
	Check(bool(email.call("ValidateReset", accountID, _Hash(code))), "reemissão depois do vencimento volta a validar")

	# Higiene: um pedido de OUTRA conta poda os pendings vencidos de todas.
	email.call("CreateReset", 4105, _Hash("BBBBBB"))
	email.set("nowOverride", BaseNow + 100 * expiryMinutes * Minute)
	email.call("BeginResetRequest", 4199)
	CheckEq((email.get("pendingResets") as Dictionary).size(), 0, "BeginResetRequest poda pendings vencidos (não vaza memória por conta abandonada)")
	email.free()

# 6. Orçamento de solicitações (memória + ledger durável) ------------------

func _SuiteRequestBudget():
	print("[suite] limite de solicitações por conta, em janela rolante")
	var accountID : int = 4106
	var store : FakeResetStore = FakeResetStore.new()
	var email : Node = _NewEmailService(store, BaseNow)
	var windowMax : int = int(_Const(commonsScript, "ResetRequestWindowMax"))

	for request in range(1, windowMax + 1):
		Check(bool(email.call("BeginResetRequest", accountID)), "solicitação %d de %d é aceita" % [request, windowMax])
	Check(not bool(email.call("BeginResetRequest", accountID)), "solicitação %d passa a ser recusada (budget da janela)" % (windowMax + 1))
	CheckEq(store.inserts, windowMax, "cada aceite escreve uma linha no ledger password_reset_request")
	CheckEq(store.counts, windowMax + 1, "cada aceite consulta o ledger (o teto não é só memória)")

	# "Restart do processo": memória zerada, MESMO ledger → a recusa continua.
	var revived : Node = _NewEmailService(store, BaseNow)
	Check((revived.get("resetRequests") as Dictionary).is_empty(), "o processo novo começa com a memória de pedidos vazia")
	Check(not bool(revived.call("BeginResetRequest", accountID)), "e mesmo assim continua recusando: o budget vive no ledger (migration 050)")
	revived.free()

	# Janela rolante: passado o window, volta o direito.
	var windowMinutes : int = int(_Const(commonsScript, "ResetRequestWindowMinutes"))
	email.set("nowOverride", BaseNow + (windowMinutes + 1) * Minute)
	Check(bool(email.call("BeginResetRequest", accountID)), "passada a janela de %d min o budget volta" % windowMinutes)

	# O teto é por conta: outra conta não herda a recusa.
	Check(bool(email.call("BeginResetRequest", accountID + 1)), "o limite é por CONTA, não global")

	# A regra de memória vale sozinha: base que não devolve nada ainda é capada.
	var blind : FakeResetStore = FakeResetStore.new()
	blind.reportZero = true
	var memoryOnly : Node = _NewEmailService(blind, BaseNow)
	var accepted : int = 0
	for request in 12:
		if bool(memoryOnly.call("BeginResetRequest", 4107)):
			accepted += 1
	CheckEq(accepted, windowMax, "sem ledger disponível a memória ainda capa em %d solicitações" % windowMax)
	Check(blind.deletes > 0, "a escrita do ledger poda o passado (DELETE no mesmo caminho do INSERT)")

	# Tentativa errada contra um pending NÃO come budget de solicitação: errar 5
	# vezes e pedir de novo custa um pedido, não cinco.
	var spent : Node = _NewEmailService(FakeResetStore.new(), BaseNow)
	var code : String = _Generate()
	Check(bool(spent.call("BeginResetRequest", 4108)), "primeiro pedido aceito")
	spent.call("CreateReset", 4108, _Hash(code))
	for attempt in windowMax:
		spent.call("ValidateReset", 4108, _Hash("ZZZZZZ"))
	Check(not bool(spent.call("HasPendingReset", 4108)), "as 5 erradas consumiram o pending")
	Check(bool(spent.call("BeginResetRequest", 4108)), "e não consumiram o budget de solicitações (2º pedido aceito)")
	spent.free()
	email.free()

# 7. Contratos de fonte (o que o harness não exercita por RPC) -------------

func _SuiteSourceContract():
	print("[suite] contratos de fonte do handler, do gerador e do storage")
	var serverSource : String = _Source("res://sources/network/server/Server.gd")
	var emailSource : String = _Source("res://sources/network/server/EmailService.gd")
	var hasherSource : String = _Source("res://sources/util/Hasher.gd")
	var commonsSource : String = _Source("res://sources/network/NetworkCommons.gd")
	Check(not serverSource.is_empty() and not emailSource.is_empty() and not hasherSource.is_empty() and not commonsSource.is_empty(), "os quatro fontes são lidos do projeto")

	var request : String = _FunctionBody(serverSource, "RequestPasswordReset")
	var confirm : String = _FunctionBody(serverSource, "ConfirmPasswordReset")
	Check(not request.is_empty() and not confirm.is_empty(), "os dois handlers de reset existem no servidor")

	# Anti-enumeration: o handler responde igual em todos os ramos de conta.
	CheckEq(_Count(request, "Network.AuthError("), 2, "RequestPasswordReset responde em dois pontos só (serviço indisponível + resposta única)")
	CheckEq(_Count(request, "ERR_RESET_"), 2, "só dois códigos de reset saem do handler")
	Check(request.find("ERR_RESET_EMAIL_SENT") > request.find("GetAccountID"), "conta inexistente, e-mail vazio e budget estourado caem na MESMA resposta genérica")
	Check(not request.contains("HasRecentReset"), "o throttle antigo (ignorava o pedido em silêncio) saiu do fluxo")
	Check(request.contains("BeginResetRequest"), "o teto agora é por conta, na janela do ledger")
	Check(request.contains("NormalizeResetCode"), "o código emitido é normalizado antes de virar hash")

	# Transação: sucesso reportado só com os dois writers verdes, e pending apagado
	# depois do commit — não antes.
	Check(confirm.contains("NormalizeResetCode"), "ConfirmPasswordReset normaliza antes de validar e de hashar")
	Check(confirm.find("NormalizeResetCode") < confirm.find("CheckResetCode"), "a normalização acontece antes do validador")
	Check(confirm.contains("return updated and revoked"), "o veredito da transação é o resultado dos writers, não `true` constante")
	Check(confirm.find("Transaction(") < confirm.find("RemoveReset"), "o pending só é apagado depois do commit")
	Check(not confirm.contains("RemoveReset(accountID, ") and _Count(confirm, "RemoveReset") == 1, "RemoveReset acontece uma única vez, fora do lambda")
	Check(not confirm.contains("RecordFailedLogin"), "tentativa de reset errada não vira lockout de conta (seria DoS contra o dono)")
	Check(confirm.contains("RemoveAllAuthTokens"), "reset bem-sucedido continua revogando as sessões")
	Check(confirm.contains("ERR_RESET_INVALID_CODE"), "código errado e conta inexistente compartilham o mesmo código de erro")

	# O gancho de telemetria do exhaustion tem de estar no RAMO ERRADO. Acoplado ao
	# `if Transaction` (dentro do ramo do acerto) ele é código morto: `ValidateReset`
	# devolve false nas 5 tentativas erradas e a branch inteira é pulada — foi o bug
	# que a suite de login de outro agente pegou (`sec_reset_exhausted` sempre 0).
	var hookIndent : int = _LineIndent(confirm, "elif hadPending")
	var verdictIndent : int = _LineIndent(confirm, "if Launcher.Email.ValidateReset(")
	Check(hookIndent >= 0 and verdictIndent >= 0 and hookIndent == verdictIndent, "o `elif` do exhaustion é irmão do `if ValidateReset`, não neto do `if Transaction` (%d vs %d)" % [hookIndent, verdictIndent])
	Check(confirm.contains("EventResetExhausted") and confirm.contains("LogSecurityEvent"), "a rota emite a métrica do pending consumido")
	# Esta régua era `confirm.contains("ResetCodeMaxAttempts")` — escrita contra o
	# handler que recalculava a aritmética do teto. A Frente 4 trocou a contagem
	# duplicada pelo sinal "havia pending e a tentativa errada o sumiu", e
	# `login_hardening_test.gd:508` já jurava por essa forma; a daqui ficou pedindo
	# a cópia que o próprio refactor removeu. O que tem de valer é o inverso: o teto
	# mora em `EmailService` (dono do pending) e o handler não reimplementa a conta —
	# duas cópias da mesma disciplina divergem na primeira mudança de N.
	Check(confirm.contains("elif hadPending") and confirm.contains("HasPendingReset"), "esgotamento discriminado pelo pending consumido, não por contagem própria")
	Check(not confirm.contains("ResetCodeMaxAttempts"), "nenhum handler reimplementa o teto de tentativas (dono único: EmailService)")

	# O espaço decimal morreu junto com a linha que o produzia.
	var generator : String = _FunctionBody(hasherSource, "GenerateResetCode")
	Check(not generator.contains("% 10"), "GenerateResetCode não reduz byte a dígito decimal")
	Check(generator.contains("ResetCodeAlphabet["), "GenerateResetCode indexa o alfabeto base32")
	Check(generator.contains("generate_random_bytes"), "GenerateResetCode consome bytes do Crypto do engine")
	Check(not commonsSource.contains("code.is_valid_int()"), "NetworkCommons não valida mais o formato decimal")
	Check(commonsSource.contains("ResetCodeMaxAttempts"), "o budget de tentativa mora em NetworkCommons")
	Check(not emailSource.contains("ResetCodeCooldownMinutes"), "a constante de cooldown antiga saiu do EmailService")
	Check(emailSource.contains("SecureEquals"), "a comparação do hash é em tempo constante")
	Check(emailSource.contains("NetworkCommons.ResetCodeMaxAttempts"), "EmailService lê o budget de NetworkCommons")
	var validate : String = _FunctionBody(emailSource, "ValidateReset")
	Check(validate.contains("RemoveReset"), "ValidateReset consome o pending no exhaustion")
	Check(validate.contains("expires"), "ValidateReset recusa pending vencido")
	Check(not emailSource.contains("func HasRecentReset"), "HasRecentReset saiu de cena (substituído pelo budget de janela)")
	Check(_FunctionBody(emailSource, "CreateReset").contains("attempts"), "CreateReset grava o contador de tentativas no pending")

	# Lockout de login: já existia (SQL.RecordFailedLogin / IsLockedOut) e não foi
	# duplicado aqui — o que faltava era o caminho do reset, e é nele que mexemos.
	var login : String = _FunctionBody(serverSource, "LoginWithPassword")
	Check(login.contains("IsLockedOut"), "login por senha continua no lockout de conta pré-050")

# Ledger fake: os três statements que o EmailService emite, com os mesmos WHERE da
# query da migration 050. Autocontido — nada de testing.db neste harness.
class FakeResetStore extends RefCounted:
	var ledger : Array = []
	var inserts : int = 0
	var deletes : int = 0
	var counts : int = 0
	var reportZero : bool = false

	func QueryBindings(query : String, params : Array) -> Array:
		counts += 1
		if reportZero:
			return [{ "n" = 0 }]
		var total : int = 0
		for row in ledger:
			if int(row["account_id"]) == int(params[0]) and int(row["requested_at"]) > int(params[1]):
				total += 1
		return [{ "n" = total }]

	func ExecuteBindings(query : String, params : Array) -> bool:
		if query.find("INSERT") >= 0:
			inserts += 1
			ledger.append({ "account_id" = int(params[0]), "requested_at" = int(params[1]) })
			return true
		if query.find("DELETE") >= 0:
			deletes += 1
			var kept : Array = []
			for row in ledger:
				if int(row["requested_at"]) >= int(params[0]):
					kept.append(row)
			ledger = kept
			return true
		return false
