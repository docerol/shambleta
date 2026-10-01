extends SceneTree

# SOM-IDLE #85 (auditoria 2026-09-29): `Admission.windows` é a cesta pré-auth — endereço
# -> [balde, contagem] — e ela é ESCRITA ANTES de qualquer credencial. Até hoje nada a
# podava: um spray de endereços distintos comprava uma entrada de dicionário por endereço,
# sem teto, dentro do processo que já segura o mundo. O custo da casa era o da RAM; o do
# atacante, zero.
#
# Esta suíte não acredita em prosa, mede:
#
#   S1  TETO. N = 3 × teto de endereços DISTINTOS injetados; a cesta é conferida a CADA
#       tentativa (o MÁXIMO observado, não o tamanho final) contra `MaxAddressWindows`.
#       A poda é recriada em memória com a linha de poda arrancada do texto, e a mesma
#       injeção serve às duas: a do produto passa, a do controle ia a VERMELHO. O
#       crescimento de RAM (`OS.get_static_memory_usage()`, a mesma régua que
#       `tests/multi_instance_tick_test.gd` chama de `staticMb`) sai impresso por
#       faixa de 1024 endereços e
#       em KiB por 1k endereços, produto contra controle — o dado, não a frase. O
#       bytes/entrada MEDIDO no controle (que é linear, portanto mensurável) é o número
#       conferido contra os 512 B/entrada que o comentário do produto afirma.
#   S2  IDADE. Virou o balde, o ocioso sai; o endereço esquecido recomeça em zero, que é
#       exatamente o que a janela já fazia por semântica (`admission_gate_test` S2/3 mede
#       o reinício pelo lado da cota; aqui se mede pelo lado da memória).
#   S3  LRU. Evapora quem PAROU de bater, nunca o agressor ativo. O controle arranca o
#       toque (`windows.erase(address)`) do corpo de `Verdict` e mostra o agressor sendo
#       solto pela poda — levando o próprio contador junto, ou seja: a poda financiando o
#       spray.
#   S4  CUSTO. Com a cesta encostada no teto, o preço por tentativa é MEDIDO em µs. Sem
#       histerese a poda seria O(N) por tentativa e o antídoto viraria o segundo DoS.
#   S5  FIAÇÃO. O guard mora na escrita (`Verdict`), `PruneWindows` tem corpo, recusa
#       também é cobrada com teto, e as três mutações em memória — poda fora, LRU fora,
#       teto = MAX_INT — são pegas. Uma poda órfã na classe é o mesmo buraco com nome novo.
#   S6  CONTA. 4096 = 32 × `ConnectionCeiling()`; 4096 × 512 B = 2 MiB <= 6 MiB = 1/256
#       dos `mem_limit: 1536M` do serviço `game` (deploy/docker-compose.yml:123).
#
# Uso: bash scripts/test.sh one preauth_ledger_test 600
# Exit code: número de checks falhos. Última linha: `== PREAUTH LEDGER: N checks, M failures ==`.
#
# O controle negativo EXISTE SÓ EM MEMÓRIA (`GDScript.source_code` + `reload()`): nenhum
# arquivo do repo é tocado, nada vai a disco, e não há artefato a remover depois — a
# classe mutada morre com o processo.
#
# Como todo harness `-s`: nada de identificador de autoload ou class_name de projeto —
# tudo via load()/get()/call().

const FIX_SEC : int					= 1750000000	# relógio injetado: segundo arbitrário fixo
const INJECT : int					= 12288			# 3 × teto; spray de endereços distintos
const HOT_ATTEMPTS : int				= 6000			# S3/S4: marteladas no endereço ativo
const EVICT_SPRAY : int				= 2048			# S3: pressão de evicção depois do hot
const COST_ATTEMPTS : int				= 12000			# S4: tentativas no regime de teto
const MAX_BUDGET_BYTES : int				= 6 * 1024 * 1024	# 1/256 do mem_limit do `game` (S6)
const PER_ENTRY_BUDGET : int				= 512			# o que o comentário do produto afirma
const DB_BOOT_BUDGET_MS : int				= 20000			# ver _tickBootWait (mesma régua dos irmãos)

var checks : int					= 0
var failures : int					= 0
var frames : int					= 0
var admissionScript : GDScript				= null
var admissionText : String				= ""
var commons : GDScript				= null
var ceiling : int					= 0
var windowSec : int					= 60
var proto : int						= 0
var productGrowthBytes : int				= 0
var controlGrowthBytes : int				= 0
var controlEntries : int				= 0
var dbScript : GDScript				= null
var waitingForBoot : bool				= false
var bootStartMs : int					= 0
var bootDeadlineMs : int				= 0

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEq(got : Variant, want : Variant, label : String) -> bool:
	return Check(got == want, "%s (got %s, want %s)" % [label, str(got), str(want)])

func _read(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()

func _const(script : Object, name : String) -> Variant:
	return script.call("get_script_constant_map").get(name, null)

# Endereço distinto por índice. O formato não importa para a cesta; o que importa é que
# sejam N chaves diferentes, como num spray real de /24 em diante.
func _addr(i : int) -> String:
	return "10.%d.%d.%d" % [(i >> 16) & 255, (i >> 8) & 255, i & 255]

# Gate pronto para o spray: relógio fixo e cota alta — a régua aqui é a cesta, não a cota.
func _gate(script : Object) -> Object:
	var gate : Object = script.new()
	gate.set("ClockOverride", FIX_SEC)
	gate.set("PerAddress", 1000000)
	gate.set("Ceiling", 100000)
	return gate

func _size(gate : Object) -> int:
	return int(gate.call("WindowsSize"))

func _attempts(gate : Object, address : String) -> int:
	return int(gate.call("AttemptsFor", address))

func _counter(gate : Object, name : String) -> int:
	return int(gate.get(name))

# Injeta `count` endereços distintos a partir de `start` e devolve a MAIOR cesta vista.
func _spray(gate : Object, count : int, start : int) -> int:
	var worst : int = 0
	for i in range(start, start + count):
		gate.call("Verdict", _addr(i), 0, proto, FIX_SEC)
		var size : int = _size(gate)
		if size > worst:
			worst = size
	return worst

func _scriptFrom(text : String) -> GDScript:
	var script : GDScript = GDScript.new()
	# `class_name` renomeado: o nome verdadeiro continua registrado e nada neste caminho
	# o usa; deixar as duas declarações iguais é que faria a compilação reclamar.
	script.source_code = text.replace("class_name Admission", "class_name AdmissionControl")
	if int(script.reload()) != 0:
		failures += 1
		checks += 1
		print("  [CONTROLE CEGO] o texto mutado não compilou")
		return null
	return script

# Classe mutada em memória por substituição exata de trecho. Se o trecho não é achado, o
# controle está cego — e cego aqui É falha (check a mais, vermelho no veredito), nunca
# "verde por ausência de régua".
func _mutated(from : String, to : String, label : String) -> GDScript:
	var mutated : String = admissionText.replace(from, to)
	if mutated == admissionText:
		failures += 1
		checks += 1
		print("  [CONTROLE CEGO] %s: o trecho a arrancar não foi achado no texto" % label)
		return null
	return _scriptFrom(mutated)

func _free(_script : GDScript) -> void:
	# GDScript herda de RefCounted em Godot 4, e `free()` num RefCounted devolve o
	# "SCRIPT ERROR: Attempted to free a RefCounted object" que o gate §24-8 (zero
	# SCRIPT ERROR) lê como vermelho — foi exatamente assim que `preauth_ledger_test`
	# fechou o gate de 2026-09-29, com as 32 checks do resto do arquivo verdes. Não há
	# nada a liberar à mão: a referência que este argumento é morre no `return` do
	# chamador, e o refcount faz o resto.
	pass

func _mem() -> int:
	return int(OS.get_static_memory_usage())

func _initialize():
	print("== SOM-#85: cesta pré-auth com teto, poda por idade, LRU e custo medido ==")
	admissionScript = load("res://sources/network/server/Admission.gd")
	commons = load("res://sources/network/NetworkCommons.gd")
	admissionText = _read("res://sources/network/server/Admission.gd")
	if not Check(admissionScript != null and commons != null and admissionText.length() > 400,
			"Admission.gd carregado como script E como texto (a régua de fiação lê o disco)"):
		_finish(1)
		return
	ceiling = int(_const(admissionScript, "MaxAddressWindows"))
	windowSec = int(_const(commons, "PreAuthWindowSec"))
	proto = int(commons.get("ProtocolVersion"))
	if not Check(ceiling > 0 and windowSec > 0, "números lidos do produto: teto=%d entradas, balde=%ds, ProtocolVersion=%d" % [ceiling, windowSec, proto]):
		_finish(2)
		return
	print("medido: teto=%d | ConnectionCeiling=%d | spray=%d endereços distintos" % [ceiling, int(commons.call("ConnectionCeiling")), INJECT])
	_suiteCeiling()
	_suiteAge()
	_suiteLRU()
	_suiteCost()
	_suiteWiring()
	_suiteAccount()
	_finish(0)

# --------------------------------------------------------- S1) teto + crescimento medido
func _suiteCeiling() -> void:
	print("-- S1) teto duro: spray de endereços distintos não compra cesta ilimitada")
	var real : Object = _gate(admissionScript)
	var base : int = _mem()
	var minReal : int = base
	var worstReal : int = 0
	var done : int = 0
	while done < INJECT:
		var take : int = mini(1024, INJECT - done)
		var before : int = _mem()
		worstReal = maxi(worstReal, _spray(real, take, done))
		done += take
		var after : int = _mem()
		if after < minReal:
			minReal = after
		print("    spray=%5d  mem %d -> %d B (%+d B)  cesta=%d" % [done, before, after, after - before, _size(real)])
	productGrowthBytes = minReal - base
	print("  PRODUTO (com poda): base=%d B, amostra mais favorável=%d B, delta=%d B | cesta máxima=%d (teto %d) | PrunedByAge=%d PrunedByCeiling=%d PrunePasses=%d" % [base, minReal, productGrowthBytes, worstReal, ceiling, _counter(real, "PrunedByAge"), _counter(real, "PrunedByCeiling"), _counter(real, "PrunePasses")])
	Check(worstReal <= ceiling, "S1 a cesta nunca ultrapassou o teto em %d tentativas (máximo observado %d <= %d)" % [INJECT, worstReal, ceiling])
	Check(_size(real) <= ceiling, "S1 tamanho final dentro do teto (%d <= %d)" % [_size(real), ceiling])
	Check(_counter(real, "PrunedByCeiling") > 0, "S1 o spray foi expulso pelo TETO, não só pela idade (PrunedByCeiling=%d)" % _counter(real, "PrunedByCeiling"))

	var controlScript : GDScript = _mutated(
			"\tif bucket != LastPruneBucket or windows.size() > MaxAddressWindows:\n\t\tPruneWindows(bucket)\n",
			"\tLastPruneBucket = bucket\n", "poda fora")
	if controlScript != null:
		var control : Object = _gate(controlScript)
		var cBase : int = _mem()
		var worstControl : int = _spray(control, INJECT, 0)
		controlGrowthBytes = _mem() - cBase
		controlEntries = worstControl
		print("  CONTROLE (poda arrancada do texto): cesta=%d (teto %d) | delta=%d B | %.1f B/entrada" % [worstControl, ceiling, controlGrowthBytes, float(controlGrowthBytes) / float(maxi(worstControl, 1))])
		CheckEq(worstControl, INJECT, "S1 controle NEGATIVO: sem a poda a cesta cresce uma entrada por endereço; a régua de cima estaria VERMELHA")
		_free(controlScript)
	print("  CRESCIMENTO por 1k endereços injetados: produto=%.1f KiB, sem poda=%.1f KiB" % [float(productGrowthBytes) / 1024.0 / float(INJECT) * 1000.0, float(controlGrowthBytes) / 1024.0 / float(INJECT) * 1000.0])
	Check(controlGrowthBytes > 0, "S1 a medição de memória do controle é positiva (%d B para %d entradas) — sem medição a régua abaixo é prosa" % [controlGrowthBytes, controlEntries])
	var perEntry : float = float(controlGrowthBytes) / float(maxi(controlEntries, 1))
	Check(perEntry <= float(PER_ENTRY_BUDGET), "S1 o bytes/entrada MEDIDO cabe na folga afirmada pelo produto (%.1f B <= %d B)" % [perEntry, PER_ENTRY_BUDGET])
	Check(productGrowthBytes <= ceiling * PER_ENTRY_BUDGET, "S1 o que a cesta do produto ocupa cabe no orçamento dela (%d B <= %d B)" % [productGrowthBytes, ceiling * PER_ENTRY_BUDGET])

# --------------------------------------------------------------------- S2) poda por idade
func _suiteAge() -> void:
	print("-- S2) idade: virou o balde, o ocioso sai")
	var gate : Object = _gate(admissionScript)
	_spray(gate, 4000, 20000)
	var before : int = _size(gate)
	CheckEq(before, 4000, "S2 cesta de um balde só, antes da virada")
	gate.call("Verdict", _addr(900000), 0, proto, FIX_SEC + windowSec)
	var after : int = _size(gate)
	print("  virada de balde: %d -> %d entradas | PrunedByAge=%d | PrunePasses=%d" % [before, after, _counter(gate, "PrunedByAge"), _counter(gate, "PrunePasses")])
	CheckEq(after, 1, "S2 sobra só o endereço que acabou de bater")
	Check(_counter(gate, "PrunedByAge") >= before - 1, "S2 as %d saíram CONTABILIZADAS por idade (%d)" % [before - 1, _counter(gate, "PrunedByAge")])
	CheckEq(_attempts(gate, _addr(20000)), 0, "S2 endereço esquecido recomeça em zero — a mesma semântica da janela, com a memória devolvida")

# --------------------------------------------------------------------------- S3) LRU real
func _suiteLRU() -> void:
	print("-- S3) evicção: sai quem parou de bater, nunca o agressor ativo")
	var hot : String = "2001:db8::hot"
	var oldest : String = _addr(400000)
	var gate : Object = _gate(admissionScript)
	# Ataque realista: um endereço quente E spray de endereços novos, intercalados, sem fim.
	for i in range(HOT_ATTEMPTS):
		gate.call("Verdict", hot, 0, proto, FIX_SEC)
		gate.call("Verdict", _addr(400000 + i), 0, proto, FIX_SEC)
	_spray(gate, EVICT_SPRAY, 600000)
	var hotKept : int = _attempts(gate, hot)
	print("  produto: agressor ativo ficou com %d/%d tentativas na cesta; o endereço mais antigo ficou com %d; cesta=%d (teto %d)" % [hotKept, HOT_ATTEMPTS, _attempts(gate, oldest), _size(gate), ceiling])
	CheckEq(hotKept, HOT_ATTEMPTS, "S3 o LRU protege quem bate sem parar (a poda não financia o spray)")
	CheckEq(_attempts(gate, oldest), 0, "S3 quem parou de bater é que sai")

	var noTouch : GDScript = _mutated("\twindows.erase(address)\n\twindows[address] = state\n", "\twindows[address] = state\n", "LRU fora")
	if noTouch != null:
		var gate2 : Object = _gate(noTouch)
		for i in range(HOT_ATTEMPTS):
			gate2.call("Verdict", hot, 0, proto, FIX_SEC)
			gate2.call("Verdict", _addr(400000 + i), 0, proto, FIX_SEC)
		_spray(gate2, EVICT_SPRAY, 600000)
		var hot2 : int = _attempts(gate2, hot)
		print("  controle (toque LRU arrancado): o agressor ficou com %d tentativas em vez de %d" % [hot2, HOT_ATTEMPTS])
		Check(hot2 < HOT_ATTEMPTS, "S3 controle NEGATIVO: sem o toque a evicção solta o agressor primeiro e leva o contador dele junto (a régua de cima estaria VERMELHA)")
		_free(noTouch)

# ---------------------------------------------------------------------------- S4) custo
func _suiteCost() -> void:
	print("-- S4) custo da poda em regime de teto: amortizado, não O(N) por tentativa")
	var gate : Object = _gate(admissionScript)
	_spray(gate, ceiling, 1000000)
	var t0 : int = Time.get_ticks_usec()
	var worst : int = _spray(gate, COST_ATTEMPTS, 2000000)
	var usec : int = Time.get_ticks_usec() - t0
	var perAttempt : float = float(usec) / float(COST_ATTEMPTS)
	print("  %d tentativas com a cesta no teto: %d us no total, %.3f us por tentativa | cesta máxima=%d | PrunePasses=%d" % [COST_ATTEMPTS, usec, perAttempt, worst, _counter(gate, "PrunePasses")])
	Check(perAttempt < 200.0, "S4 o preço por tentativa no regime de teto é amortizado (%.3f us < 200 us)" % perAttempt)
	Check(worst <= ceiling, "S4 o teto continua de pé depois de %d tentativas novas (%d)" % [COST_ATTEMPTS, worst])

# --------------------------------------------------------- S5) fiação, recusa e mutações
func _suiteWiring() -> void:
	print("-- S5) fiação: o guard está na escrita, e as mutações são todas pegas")
	var body : Array = _funcBody(admissionText, "Verdict")
	var joined : String = ""
	for line in body:
		joined += String(line) + "\n"
	Check(not body.is_empty(), "S5 corpo de Verdict localizado no produto")
	Check(joined.contains("PruneWindows("), "S5 Verdict CHAMA a poda (não é método órfão da classe)")
	Check(joined.contains("windows.erase(address)"), "S5 Verdict toca o LRU antes de reescrever")
	Check(joined.contains("MaxAddressWindows"), "S5 a condição do teto está na escrita, não só na constante")
	Check(not _funcBody(admissionText, "PruneWindows").is_empty(), "S5 PruneWindows existe com corpo")

	# fail-closed: recusa também é tentativa, e tentativa é o que faz a cesta crescer.
	# A cota é POR ENDEREÇO DENTRO DA JANELA (`state[1] > PerAddress`, em `Verdict`): com
	# `PerAddress` = 1 e 500 endereços DISTINTOS, cada batida é a primeira do seu próprio
	# endereço, nenhuma passa de 1 e a recusa é ZERO por construção — a régua acusaria um
	# vazio e o teto de abaixo continuaria sendo conferido sem recusa nenhuma, ou seja,
	# sem o regime que ela jurava medir. O caminho que recusa é o MESMO endereço batendo
	# duas vezes na janela; endereço novo continua entrando (contra spray de endereços
	# distintos a proteção é a cesta podada, não a cota) — e é exatamente isso que a
	# segunda régua confere, agora com as duas coisas acontecendo ao mesmo tempo.
	var gate : Object = _gate(admissionScript)
	gate.set("PerAddress", 1)
	var refused : int = 0
	var admitted : int = 0
	for i in range(500):
		if String(gate.call("Verdict", _addr(3000000 + (i % 8)), 0, proto, FIX_SEC)) == String(_const(admissionScript, "ReasonAdmitted")):
			admitted += 1
		else:
			refused += 1
	Check(refused > 0, "S5 %d tentativas recusadas por cota (mesmo endereço, segunda batida na janela)" % refused)
	CheckEq(admitted, 8, "S5 com cota 1 cada um dos 8 endereços entra exatamente uma vez (a recusa não engole a primeira)")
	CheckEq(int(gate.call("RefusalCount", String(_const(admissionScript, "ReasonAddressBudget")))), refused, "S5 a recusa sai CONTABILIZADA no motivo da cota")
	CheckEq(int(gate.get("Admissions")), int(gate.get("Attempts")) - refused, "S5 tentativa é ou admissão ou recusa: a soma fecha")

	# Recusa ativa E cesta cheia: metade das batidas são endereços novos (crescem a
	# cesta até o teto), metade são o mesmo endereço (recusadas). O teto tem de continuar
	# de pé no regime misto, não só no spray limpo de S1/S4.
	var worstUnderRefusal : int = 0
	for i in range(3 * ceiling):
		if i % 2 == 0:
			gate.call("Verdict", _addr(5000000 + (i >> 1)), 0, proto, FIX_SEC)
		else:
			gate.call("Verdict", _addr(5000000), 0, proto, FIX_SEC)
		var live : int = _size(gate)
		if live > worstUnderRefusal:
			worstUnderRefusal = live
	Check(worstUnderRefusal > 0, "S5 o regime misto mexeu na cesta (%d entradas no pico)" % worstUnderRefusal)
	Check(_size(gate) <= ceiling and worstUnderRefusal <= ceiling, "S5 sob recusa a cesta também respeita o teto (pico %d <= %d)" % [worstUnderRefusal, ceiling])

	var loose : GDScript = _loosenedCeiling()
	if loose != null:
		var gate2 : Object = _gate(loose)
		var worst : int = _spray(gate2, 20000, 4000000)
		print("  controle (teto = MAX_INT): a cesta chegou a %d onde o produto exige <= %d" % [worst, ceiling])
		Check(worst > ceiling, "S5 controle NEGATIVO: com o teto inflado a cesta passa de %d — a régua S1 não é decorativa" % ceiling)
		_free(loose)

# O teto é uma constante alinhada com TAB no texto; substituir por string seria frágil,
# então a mutação é por LINHA (procura a declaração e troca o valor depois do `=`).
func _loosenedCeiling() -> GDScript:
	var lines : PackedStringArray = admissionText.split("\n")
	var hit : int = -1
	for i in range(lines.size()):
		if lines[i].begins_with("const MaxAddressWindows"):
			hit = i
			break
	if hit < 0:
		failures += 1
		checks += 1
		print("  [CONTROLE CEGO] S5: nenhuma linha `const MaxAddressWindows` no produto")
		return null
	var parts : PackedStringArray = lines[hit].split("=")
	lines[hit] = parts[0] + "= 2147483647"
	return _scriptFrom("\n".join(lines))

# -------------------------------------------------------------------------- S6) a conta
func _suiteAccount() -> void:
	print("-- S6) de onde veio o 4096: a conta escrita no produto é conferida aqui")
	CheckEq(ceiling, 32 * int(commons.call("ConnectionCeiling")), "S6 MaxAddressWindows == 32 × ConnectionCeiling() (%d × 32)" % int(commons.call("ConnectionCeiling")))
	CheckEq(ceiling * PER_ENTRY_BUDGET, 2 * 1024 * 1024, "S6 teto × 512 B/entrada == 2 MiB")
	Check(ceiling * PER_ENTRY_BUDGET <= MAX_BUDGET_BYTES, "S6 2 MiB <= 6 MiB = 1/256 dos 1536M do serviço game")
	Check(_read("res://deploy/docker-compose.yml").contains("mem_limit: 1536M"), "S6 a âncora mem_limit: 1536M continua em deploy/docker-compose.yml")
	CheckEq(int(_const(commons, "PreAuthPerAddress")), 32, "S6 PreAuthPerAddress == 32 (o multiplicador que fundamenta o teto de endereços)")

func _finish(code : int) -> void:
	# Mesma disciplina dos irmãos de harness: o veredito só é impresso quando o preload
	# threadado do DB fechou, senão o `quit()` deixa a contagem de vazamento no meio do
	# boot e o gate de teardown acusa quem não tem culpa (run_rpc_identity_test.gd:151).
	dbScript = load("res://sources/db/DB.gd")
	waitingForBoot = true
	bootStartMs = int(Time.get_ticks_msec())
	bootDeadlineMs = bootStartMs + DB_BOOT_BUDGET_MS
	if code != 0:
		quit(code)

func _process(_delta):
	frames += 1
	if not waitingForBoot:
		return false
	return _tickBootWait()

func _tickBootWait() -> bool:
	if dbScript != null and bool(dbScript.get("isInitialized")):
		Check(true, "boot do DB fechado antes do quit (%d ms de espera, %d frames)" % [int(Time.get_ticks_msec()) - bootStartMs, frames])
	elif int(Time.get_ticks_msec()) >= bootDeadlineMs:
		Check(false, "DB.isInitialized seguiu false por %d ms: o veredito seria lido no meio do preload" % DB_BOOT_BUDGET_MS)
	else:
		return false
	if dbScript != null:
		dbScript.call("DrainPendingPreloads")
	print("== PREAUTH LEDGER: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
	return true

func _funcBody(text : String, funcName : String) -> Array:
	var out : Array = []
	var needle : String = "func %s(" % funcName
	var capturing : bool = false
	for raw in text.split("\n"):
		var line : String = String(raw)
		if not capturing:
			if line.begins_with(needle):
				capturing = true
			continue
		if line.begins_with("func ") or line.begins_with("static func "):
			break
		out.append(line)
	return out
