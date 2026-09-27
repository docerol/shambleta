extends SceneTree

# AUDITORIA_2026-09-27 §13 (UX/UI 4/10): "reason tokens do servidor vazando no
# toast — `Shop rejected: insufficient_gems`, ~25 códigos sem i18n".
# `sources/util/PlayerReasons.gd` existe só para fechar isso e promete, no cabeçalho
# dele, uma coisa forte: **um token cru nunca chega à tela do jogador** — sem linha
# no catálogo, o toast degrada para a frase genérica e o código vai para o log do
# operador. Promessa sem régua é intenção. Este harness mede a promessa nos dois
# sentidos:
#
#  1. enumerate o que o servidor EMITE (varrendo `result["reason"] = "<token>"` em
#     `sources/`), em vez de testar três exemplos escolhidos por quem escreveu o
#     teste — é a diferença entre "o autor do teste conhecia esses códigos" e
#     "nenhum código do servidor vaza";
#  2. nenhum token emitido pode voltar cru, nos dois formatos que a árvore produz
#     (`"<algo> rejected: <token>"` e `"<algo> rejected (<token>)"`) e nos dois
#     idiomas do catálogo;
#  3. texto de jogador (nome, frase, URL) tem que voltar INTACTO — a outra metade
#     do contrato: reescrever `Player Rook not found` seria trocar um defeito de
#     legibilidade por um de verdade;
#  4. o caminho de fallback é exercido de propósito com um token que não existe no
#     catálogo, porque é exatamente aí que um `return code` disfarçado de
#     implementação passaria verde.
#
# Uso:   godot --headless --path . -s tests/reason_toast_test.gd
#        (XDG_DATA_HOME próprio — ver scripts/test.sh.)
# Saída: == RESULT: N checks, M failures ==   e exit code = nº de falhas.
#
# Como os harnesses irmãos, este arquivo é duck-typed: um main-loop `-s` compila
# antes dos autoloads e dos `class_name` do projeto existirem, então `PlayerReasons`
# e `ReasonCodes` entram por `load()` e tudo que vem deles é chamado por `call()`.

var checks : int = 0
var failures : int = 0
var _trEn : Translation = null
var _trPt : Translation = null

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func CheckEqInt(value : int, expected : int, label : String) -> bool:
	return Check(value == expected, "%s (got %d, want %d)" % [label, value, expected])

func CheckAtLeast(value : int, floor : int, label : String) -> bool:
	return Check(value >= floor, "%s (got %d, want >= %d)" % [label, value, floor])

func CheckSame(value : String, expected : String, label : String) -> bool:
	return Check(value == expected, "%s (got '%s', want '%s')" % [label, value, expected])

func _finish() -> void:
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

func _initialize() -> void:
	print("== REASON: toast do jogador sem vocabulário do servidor ==")
	var reasonsScript : GDScript = load("res://sources/util/PlayerReasons.gd")
	var codesScript : GDScript = load("res://sources/ops/ReasonCodes.gd")
	if not Check(reasonsScript != null, "PlayerReasons.gd carrega"):
		_finish()
		return
	if not Check(codesScript != null, "ReasonCodes.gd carrega"):
		_finish()
		return
	var reasons : Object = reasonsScript.new()
	var codes : Object = codesScript.new()

	# Catálogo: os dois idiomas compilados, adicionados explicitamente. Num `-s`
	# main-loop o `Localizer` (autoload) não roda, então quem traduz aqui é só o
	# TranslationServer — dependesse o harness do autoload, estaria provando boot,
	# não o contrato.
	var trEn : Translation = load("res://data/i18n/ui.en.translation")
	var trPt : Translation = load("res://data/i18n/ui.pt_BR.translation")
	if not Check(trEn != null and trPt != null, "os dois catálogos compilados existem (en e pt_BR)"):
		_finish()
		return
	# O engine já registra os `.translation` do ProjectSettings; guardar as duas
	# instâncias é o que permite cobrar "tem linha" sem depender do idioma ativo.
	_trEn = trEn
	_trPt = trPt

	_isReasonTokenGate(codes)
	# Ordem dos idiomas fixa o que cada passada afirma: `ToToast` traduz pela língua
	# corrente, então o census roda duas vezes, uma por idioma do produto.
	for language in ["pt_BR", "en"]:
		TranslationServer.set_locale(language)
		_census(reasons, codes, language)
	TranslationServer.set_locale("pt_BR")
	_passthrough(reasons)
	_parens(reasons, codes)
	_fallback(reasons, codes)
	_labels(reasons)
	_bilingual(reasons)

	# Chegada: um harness que não olhou a superfície inteira não mede o que promete.
	CheckAtLeast(checks, 120, "a régua percorreu uma superfície real de códigos (não três exemplos)")
	_finish()

# `IsReasonToken` é o que separa "motivo do servidor" de "frase do jogador". Se ele
# afrouxar, `ToToast` reescreve texto de verdade; se apertar, token cru escapa.
func _isReasonTokenGate(codes : Object) -> void:
	for good in ["insufficient_gems", "daily_cap_reached", "a1b", "reroll_cap", "locked"]:
		Check(bool(codes.call("IsReasonToken", good)), "IsReasonToken aceita o formato de código '%s'" % good)
	for bad in ["ab", "Gems", "1gems", "gems or count 1..10", "Player Rook", "http://x.y/z", "insufficient gems", ""]:
		Check(not bool(codes.call("IsReasonToken", bad)), "IsReasonToken recusa '%s' (não é código do servidor)" % bad)

# Varre `sources/` atrás de `result["reason"] = "<token>"` — a forma exata como o
# servidor devolve motivo. Enumerar do código é o que torna "nenhum token vaza" uma
# afirmação sobre o produto de hoje, não sobre a lista que alguém lembrava.
func _collectTokens(dirPath : String, rx : RegEx, found : Dictionary) -> void:
	var dir : DirAccess = DirAccess.open(dirPath)
	if dir == null:
		return
	dir.list_dir_begin()
	var names : Array[String] = []
	var name : String = dir.get_next()
	while name != "":
		names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	for n : String in names:
		var full : String = dirPath.path_join(n)
		if DirAccess.dir_exists_absolute(full):
			_collectTokens(full, rx, found)
		elif n.ends_with(".gd"):
			var text : String = FileAccess.get_file_as_string(full)
			for m : RegExMatch in rx.search_all(text):
				found[str(m.get_string(1))] = true

func _census(reasons : Object, codes : Object, language : String) -> void:
	var found : Dictionary = {}
	var rx : RegEx = RegEx.new()
	if rx.compile("result\\[\"reason\"\\][[:space:]]*=[[:space:]]*\"([a-z][a-z0-9_]{2,40})\"") != OK:
		Check(false, "o padrão de varredura compila")
		return
	_collectTokens("res://sources", rx, found)
	var tokens : Array[String] = []
	for key : String in found:
		tokens.append(key)
	tokens.sort()
	if language == "pt_BR":
		_censusSize = tokens.size()
		CheckAtLeast(tokens.size(), 40, "o censo encontrou os códigos que o servidor emite (%d)" % tokens.size())
		# O varredor tem que ter lido arquivos de verdade: estes dois tokens são os que
		# a auditoria citou nominalmente, um em cada formato de toast.
		Check(tokens.has("insufficient_gems"), "o varredor achou `insufficient_gems` (o código da auditoria)")
		Check(tokens.has("reroll_cap"), "o varredor achou `reroll_cap` (o formato com parênteses)")
	else:
		# O censo é o mesmo nos dois idiomas; o que muda é o que a tabela devolve.
		CheckEqInt(tokens.size(), _censusSize, "o censo de códigos é estável entre idiomas")
	var unmapped : Array[String] = []
	for token : String in tokens:
		if not bool(codes.call("IsReasonToken", token)):
			continue
		var toast : String = String(reasons.call("ToToast", "Shop rejected: " + token))
		# Medido na cauda, não em `contains`: `locked` traduz para "still locked" e
		# `pending` para "already pending approval" — substring acusaria um toast
		# corretamente traduzido de vazamento. Cru é a cauda ainda sendo o token.
		var cut : int = toast.rfind(": ")
		var tail : String = toast.substr(cut + 2) if cut >= 0 else toast
		Check(tail != token and not toast.is_empty(), "'%s' não chega cru nem vazio em %s (%s)" % [token, language, toast])
		# Tradução própria é o que separa "proteção" de "uma genérica para tudo":
		# genérica universal seria verde e inútil.
		var cat : Translation = _trPt if language == "pt_BR" else _trEn
		if cat.get_message("reason/" + token) == "":
			unmapped.append(token)
	Check(unmapped.is_empty(), "cada código emitido tem linha própria em %s, não só a genérica (%s)" % [language, " | ".join(unmapped)])

var _censusSize : int = 0

# O segundo formato que a árvore produz: `"%s rejected (%s)"` (Server.gd).
func _parens(reasons : Object, codes : Object) -> void:
	var cases : Array[String] = ["Daily offer rejected (reroll_cap)", "Arena rejected (not_open)",
		"Shop rejected (daily_cap_reached)", "Chest rejected (insufficient_gems)"]
	for text : String in cases:
		var out : String = String(reasons.call("ToToast", text))
		var token : String = text.substr(text.rfind("(") + 1, text.length() - text.rfind("(") - 2)
		# Mesma régua do census: comparado pelo conteúdo do parêntese, não por
		# substring — uma tradução que por acaso contenha o token não é vazamento.
		var open2 : int = out.rfind("(")
		var close2 : int = out.rfind(")")
		var inside : String = out.substr(open2 + 1, close2 - open2 - 1) if open2 >= 0 and close2 > open2 else out
		Check(inside != token and not out.is_empty(), "formato com parênteses não vaza o código: '%s' -> '%s'" % [text, out])
		Check(out.ends_with(")"), "e mantém a forma da frase (%s)" % out)
	# Entre parênteses só token puro conta: "(gems or count 1..10)" é texto legível
	# e reescrevê-lo seria o defeito novo disfarçado de correção.
	Check(String(reasons.call("ToToast", "Purchase rejected (gems or count 1..10)"))
		== "Purchase rejected (gems or count 1..10)", "parênteses com texto de humano volta intacto")

func _passthrough(reasons : Object) -> void:
	for plain in ["Player Rook not found", "https://example.com/pay?id=7", "Sem conexão com o servidor",
		"Guild invite for Thiago", "You earned 250 gold", "Saldo atual: 12 gems"]:
		CheckSame(String(reasons.call("ToToast", plain)), plain, "texto de jogador volta intacto: '%s'" % plain)
	CheckSame(String(reasons.call("ToToast", "")), "", "string vazia não vira texto inventado")

func _fallback(reasons : Object, codes : Object) -> void:
	# Um código que o catálogo não conhece: é AQUI que um `return token` disfarçado
	# passaria verde. A promessa é genérica + log do operador, nunca cru na tela.
	var ghost : String = "zzz_not_in_catalog"
	var toast : String = String(reasons.call("ToToast", "Shop rejected: " + ghost))
	Check(not toast.contains(ghost), "código sem linha no catálogo não vaza no toast (%s)" % toast)
	Check(not toast.is_empty(), "e o toast degradado não fica vazio")
	Check(not String(reasons.call("Describe", ghost)).contains(ghost), "Describe() também não devolve o cru")
	Check(not String(reasons.call("GenericText")).contains(ghost), "a frase genérica não é o próprio token")
	Check(not String(reasons.call("GenericText")).is_empty(), "a frase genérica existe (toast vazio é incidente, não detalhe)")

func _labels(reasons : Object) -> void:
	# `Describe()` é o que os painéis usam para labels soltos ("Defense rejected: <x>").
	Check(not String(reasons.call("Describe", "insufficient_gems")).contains("insufficient_gems"),
		"Describe() de código mapeado devolve frase, não chave")
	Check(not String(reasons.call("Describe", "gems or count 1..10")).contains("gems or count"),
		"Describe() de um texto interno do server não vai para a tela")
	Check(not String(reasons.call("Describe", "")).is_empty(), "Describe() vazio devolve a genérica, não silêncio")

# O produto é brasileiro: se a tabela pt_BR estiver muda, o jogador lê o inglês cru
# do motivo e uma régua de um idioma só passaria verde do mesmo jeito.
func _bilingual(reasons : Object) -> void:
	TranslationServer.set_locale("pt_BR")
	var pt : String = String(reasons.call("ToToast", "Shop rejected: locked"))
	TranslationServer.set_locale("en")
	var en : String = String(reasons.call("ToToast", "Shop rejected: locked"))
	TranslationServer.set_locale("pt_BR")
	Check(not pt.contains("locked"), "pt_BR traduz o toast, não só o en (%s)" % pt)
	Check(pt != en, "os dois idiomas produzem textos diferentes (a tabela é bilíngue de fato)")
	Check(not pt.is_empty() and not en.is_empty(), "nem um idioma nem o outro devolvem vazio")
