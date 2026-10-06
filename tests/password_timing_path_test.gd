extends SceneTree

# password_timing_path_test.gd — dono: trilha "senha: comparação em tempo
# constante" (Segurança, auditoria 2026-09-27).
#
# Duas coisas presas aqui, e as duas eram o mesmo buraco lido de pontas:
#
#  1. `Hasher.VerifyPassword` comparava hash de senha com `==`. `==` em GDScript
#     curto-circuita no primeiro byte diferente, então a latência do login carrega
#     informação sobre o prefixo do hash. O arquivo já tinha `SecureEquals` (o P2
#     da mesma auditoria) e o comentário dela confessava que só o reset usava.
#     Aqui: os dois ramos de versão de hash convergem para o MESMO comparador, a
#     primitiva não tem saída antecipada, e o resultado é idêntico ao de `==` para
#     qualquer par de strings — ou seja, a troca não mudou a decisão, só o canal.
#
#  2. "tentativa com senha errada" e "tentativa em conta que não existe" têm de
#     percorrer o MESMO caminho de custo. A conta inexistente sai de
#     `ValidateAuthPassword` com `null` antes de qualquer KDF, e a rota de login
#     compensa com `SQLSecurity.BurnKdfTime` — que é um `HashPasswordV2` cujo
#     resultado é jogado fora. Isto MEDe os dois lados em `Time.get_ticks_usec()`
#     interleirados e exige que a razão fique numa banda estreita, com uma calibração
#     que prova que o relógio tem resolução para distinguir os dois (se o
#     `BurnKdfTime` virar `pass`, a razão despenca e a check cai).
#
# Não confundir com `tests/login_hardening_test.gd:500`, que confere por FONTE que
# a rota chama `BurnKdfTime`. Fonte que chama ≠ custo igual: esta é a medida.
#
# Uso:
#   XDG_DATA_HOME=/tmp/impl-sec/.data XDG_CACHE_HOME=/tmp/impl-sec/.cache \
#     timeout 300 godot --headless --path . -s tests/password_timing_path_test.gd
# Saída: "== RESULT: <n> checks, <m> failures ==" (exit code = <m>).

var checks : int = 0
var failures : int = 0
var suitesDone : int = 0

var hasher : GDScript = null
var sec : GDScript = null

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
	var same : bool = typeof(got) == typeof(want) and got == want
	if not same:
		failures += 1
		print("  [FAIL] " + label + " (got " + str(got) + ", want " + str(want) + ")")
		return false
	print("  [ok] " + label)
	return true

func _initialize():
	_run()

func _hasher(fn : String, args : Array) -> Variant:
	return hasher.callv(fn, args)

func _fnBody(source : String, fnName : String) -> String:
	var start : int = source.find("func " + fnName + "(")
	if start < 0:
		return ""
	var nl : int = source.find("\n", start)
	var body : String = ""
	var i : int = nl + 1
	while i < source.length():
		var line : String = source.substr(i, source.find("\n", i) - i)
		if line.strip_edges() != "" and not line.begins_with("\t") and not line.begins_with(" "):
			break
		body += line + "\n"
		var nxt : int = source.find("\n", i)
		if nxt < 0:
			break
		i = nxt + 1
	return body

# --- 1) semântica da comparação --------------------------------------------

func _suiteSemantics() -> void:
	print("-- A) VerifyPassword decide igual a `==`, com comparador constante")
	var salt : String = "A1B2C3D4E5F60718293A4B5C6D7E8F90"
	var pw : String = "SenhaForte!2026"
	var h1 : String = str(_hasher("HashPasswordV1", [pw, salt]))
	CheckEq(h1.length(), 64, "KDF v1 produz 64 hex")
	Check(bool(_hasher("VerifyPassword", [pw, salt, h1, 1])), "senha certa (ver 1) aceita")
	Check(not bool(_hasher("VerifyPassword", ["errada", salt, h1, 1])), "senha errada (ver 1) recusada")
	var h0 : String = str(_hasher("HashPassword", [pw, salt]))
	Check(bool(_hasher("VerifyPassword", [pw, salt, h0, 0])), "legado ver 0 aceita")
	Check(not bool(_hasher("VerifyPassword", ["errada", salt, h0, 0])), "legado ver 0 recusa")
	# Varredura de posição: hash que difere em UM caractere em cada uma das 64
	# posições tem de ser recusado nas 64. Com `==` isto também passaria — o que
	# esta varredura garante é que a troca para `SecureEquals` não afrouxou nada
	# (um comparador que ignorasse bytes sairia aqui, não no timing).
	var bad : int = 0
	for pos in 64:
		var mutated : String = h0.substr(0, pos) + ("0" if h0[pos] != "0" else "1") + h0.substr(pos + 1)
		if bool(_hasher("VerifyPassword", [pw, salt, mutated, 0])):
			bad += 1
	CheckEq(bad, 0, "64 hashes com 1 byte mutado todos recusados (posições 0..63)")
	# Comprimento diferente e vazio: o comparador antigo saía no `size() !=`; o novo
	# percorre até o maior e ainda recusa. Mesma decisão, caminho único.
	Check(not bool(_hasher("VerifyPassword", [pw, salt, h0.substr(0, 63), 0])), "hash truncado em 1 recusado")
	Check(not bool(_hasher("VerifyPassword", [pw, salt, h0 + "a", 0])), "hash alongado em 1 recusado")
	Check(not bool(_hasher("VerifyPassword", ["senhaqualquer", "", "", 0])), "hash vazio recusado (o `storedHash` do dump nunca bate)")

	# ver 2 (P1-H, auditoria 2026-10-06): o custo é lido do registro, o output é
	# de 32 bytes cheios, e a primeira geração (62 hex, o slice truncado) continua
	# logando — escolendo a rama pela FORMA do stored hash, não por um segundo
	# PBKDF2. NeedsRehash é a ponte: quem casa pela rama velha sai do banco
	# ver-2-correto no login seguinte.
	var pw2 : String = "SenhaForte!2026v2"
	var salt2 : String = str(_hasher("GenerateSalt", [16]))
	var h2 : String = str(_hasher("HashPasswordV2", [pw2, salt2]))
	CheckEq(str((_hasher("HashPasswordV2_Parse", [h2]) as Dictionary).get("hash", "")).length(), 64, "ver-2 novo grava 64 hex (32 bytes, sem o off-by-one)")
	Check(bool(_hasher("VerifyPassword", [pw2, "", h2, 2])), "ver-2 certo aceita")
	Check(not bool(_hasher("VerifyPassword", ["errada", "", h2, 2])), "ver-2 errado recusa")
	var p2 : PackedStringArray = h2.split("$")
	var legacy62 : String = "pbkdf2_sha256$%s$%s$%s" % [p2[1], p2[2], str(p2[3]).substr(0, 62)]
	Check(bool(_hasher("VerifyPassword", [pw2, "", legacy62, 2])), "rama legada de 62 hex aceita pela mesma derivação truncada")
	Check(bool(_hasher("NeedsRehash", [legacy62, 2])), "NeedsRehash marca a legada para upgrade transparente no login")
	Check(not bool(_hasher("NeedsRehash", [h2, 2])), "linha corrente (210k, 64 hex) não pede re-hash")
	var h2low : String = str(_hasher("HashPasswordV2", [pw2, salt2, 1000]))
	Check(bool(_hasher("VerifyPassword", [pw2, "", h2low, 2])), "custo confesso no registro é o custo da verificação (210k não é lido do código)")
	Check(bool(_hasher("NeedsRehash", [h2low, 2])), "e custo divergente do corrente pede re-hash para subir à política nova")
	Check(not bool(_hasher("VerifyPassword", ["errada", "", h2low, 2])), "ver-2 barato confesso continua recusando senha errada")
	# Identidade com `==` em 400 pares aleatórios (mesmo tamanho) — a comparação
	# nova não pode discordar da antiga em NENHUM caso, senão é mudança de
	# autenticação disfarçada de hardening.
	var mismatches : int = 0
	for t in 400:
		var a : String = str(_hasher("GenerateSalt", [16]))
		var b : String = a if (t % 2) == 0 else str(_hasher("GenerateSalt", [16]))
		var viaEq : bool = a == b
		var viaConst : bool = bool(_hasher("SecureEquals", [a, b]))
		if viaEq != viaConst:
			mismatches += 1
	CheckEq(mismatches, 0, "400 pares: SecureEquals devolve exatamente o que `==` devolveria")

	suitesDone += 1
# --- 2) contrato de fonte (a troca não pode ser desfeita em silêncio) -------

func _suiteSourceContract() -> void:
	print("-- B) contrato de fonte do Hasher")
	var src : String = FileAccess.get_file_as_string("res://sources/util/Hasher.gd")
	Check(src.length() > 500, "Hasher.gd lido por inteiro (%d bytes)" % src.length())
	var vp : String = _fnBody(src, "VerifyPassword")
	Check(vp.length() > 0, "func VerifyPassword encontrada")
	var re : RegEx = RegEx.create_from_string("==\\s*storedHash|storedHash\\s*==")
	Check(not (re.search(vp) != null), "VerifyPassword não compara com `== storedHash`")
	CheckEq(vp.count("SecureEquals("), 3, "os três ramos de versão (ver 0, 1 e 2) usam o comparador constante")
	var se : String = _fnBody(src, "SecureEquals")
	Check(se.length() > 0, "func SecureEquals encontrada")
	Check(not se.contains("return false"), "SecureEquals não tem saída antecipada (percorre o comparando inteiro)")
	Check(se.contains("maxi(") or se.contains("max("), "SecureEquals varre até o maior comprimento (vazamento de tamanho fechado)")
	# Nada mais no arquivo compara hash com `==` fora da própria primitiva.
	var allEq : RegEx = RegEx.create_from_string("HashPassword(V1)?\\([^)]*\\)\\s*==")
	Check(allEq.search(src) == null, "nenhum `HashPassword...() ==` solto no arquivo")
	# A comparação do reset continua na primitiva (era o único usuário dela antes).
	var email : String = FileAccess.get_file_as_string("res://sources/network/server/EmailService.gd")
	Check(email.contains("Hasher.SecureEquals"), "reset continua comparando código pela primitiva (não regrediu para `==`)")
	# E o igualador de timing é o MESMO KDF, não um `pass` decorado.
	var secsrc : String = FileAccess.get_file_as_string("res://sources/sql/SQLSecurity.gd")
	var burn : String = _fnBody(secsrc, "BurnKdfTime")
	Check(burn.contains("HashPasswordV2"), "BurnKdfTime chama o mesmo KDF do login (PBKDF2 210.000 iterações, não um `pass`)")
	Check(not burn.contains("KdfIterations"), "BurnKdfTime não escolhe iterações por fora: usa o mesmo HashPasswordV2 do login, com o mesmo teto")
	# A rota de login chama o igualador no ramo "conta inexistente" (as duas rotas).
	var srv : String = FileAccess.get_file_as_string("res://sources/network/server/Server.gd")
	CheckEq(srv.count("SQLSecurity.BurnKdfTime(password)"), 2, "as duas rotas de credencial (login e consentimento) queimam o KDF na conta inexistente")
	var sql : String = FileAccess.get_file_as_string("res://sources/sql/SQL.gd")
	Check(sql.contains("Hasher.VerifyPassword("), "SQL.gd verifica pela porta do Hasher (comparação não reimplementada no SQL)")
	Check(not sql.contains("password, salt) ==") and not sql.contains("storedHash =="), "SQL.gd não compara hash de senha com `==`")

	suitesDone += 1
# --- 3) custo igual, medido ------------------------------------------------

func _timeOf(fn : Callable) -> int:
	var t0 : int = Time.get_ticks_usec()
	fn.call()
	return Time.get_ticks_usec() - t0

func _suiteSameCost() -> void:
	print("-- C) conta existente com senha errada vs conta inexistente: MESMO custo")
	var salt : String = "0F1E2D3C4B5A69788796A5B4C3D2E1F0"
	var stored : String = str(_hasher("HashPasswordV2", ["SenhaBoa!2026"]))
	var wrong : String = "SenhaErrada!2026"
	var samples : int = 7
	var existBest : int = 1 << 60
	var ghostBest : int = 1 << 60
	var ghostResult : Variant = null
	for s in samples:
		# interleirado: o host está rodando outros gates, e amostras em bloco
		# pegariam janelas de carga diferentes nos dois lados.
		var a : int = _timeOf(func(): _hasher("VerifyPassword", [wrong, salt, stored, 2]))
		var b : int = _timeOf(func(): sec.call("BurnKdfTime", wrong))
		existBest = mini(existBest, a)
		ghostBest = mini(ghostBest, b)
		ghostResult = sec.call("BurnKdfTime", wrong)
	Check(bool(_hasher("VerifyPassword", [wrong, salt, stored, 2])) == false, "lado A: senha errada recusada")
	CheckEq(ghostResult, null, "lado B: BurnKdfTime devolve void (não vira oracle de booleano)")
	print("       medido (mínimo de %d amostras interleiradas): A=%d us  B=%d us" % [samples, existBest, ghostBest])
	# Calibração: sem ela, "razão ~= 1" pode ser só um relógio que não resolve nada.
	var noop : int = 1 << 60
	for s in samples:
		noop = mini(noop, _timeOf(func(): str(wrong).length()))
	Check(noop < existBest / 20, "o relógio resolve a diferença entre um `pass` e um KDF (%d us vs %d us)" % [noop, existBest])
	Check(existBest > 200, "o KDF de verdade rodou nos dois lados (%d us no mínimo)" % existBest)
	var ratio : float = float(existBest) / float(maxi(ghostBest, 1))
	print("       razão A/B = %.2f (banda aceita 0.70..1.45)" % ratio)
	Check(ratio >= 0.70 and ratio <= 1.45, "conta inexistente paga o mesmo KDF que a existente (razão %.2f)" % ratio)
	# O caminho de hash legado (ver 0) também queima? Não: a igualdade medida acima
	# é do ver 1, que é o que toda conta nova usa. Registrar o residual é o que
	# impede a check de virar promessa que ela não fez.
	print("       residual confessado: conta legada ver 0 tem custo menor; o upgrade acontece no primeiro login bem-sucedido (SQL.gd:244-247)")
	suitesDone += 1

func _run() -> void:
	hasher = load("res://sources/util/Hasher.gd")
	sec = load("res://sources/sql/SQLSecurity.gd")
	if hasher == null or sec == null:
		Check(false, "carreguei Hasher.gd e SQLSecurity.gd")
		print("== RESULT: %d checks, %d failures ==" % [checks, failures])
		quit(failures)
		return
	Check(true, "carreguei Hasher.gd e SQLSecurity.gd (estáticos puros, sem autoload)")
	_suiteSemantics()
	_suiteSourceContract()
	_suiteSameCost()
	Check(suitesDone == 3, "as 3 suítes rodaram até o fim (run cortado no meio não pode imprimir verde; o log é lido pelo ci_gate_log, esta linha lê o próprio verde)")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
