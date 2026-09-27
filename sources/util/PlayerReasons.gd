extends RefCounted
class_name PlayerReasons

# AUDITORIA_2026-09-27 §13 (UX 4/10): "reason tokens do servidor vazando no toast
# — `Shop rejected: insufficient_gems`, ~25 códigos sem i18n". O contrato deste
# módulo é o espelho duro do `ReasonCodes` (ops): lá, código sem linha no CSV
# continua cru DE PROPÓSITO; aqui — a última fronteira antes do olho do jogador
# — um token cru nunca pode aparecer. Sem linha, o toast degrada para a mensagem
# genérica do catálogo e o código bruto vai para o log do operador
# (`push_warning` + `LastUnmappedCode`), nunca para a tela.
#
# A tabela é o `data/i18n/ui.csv` no namespace `reason/<token>` (mesma chave do
# `ReasonCodes`, para os dois lerem o MESMO catálogo compilado). Não há dicionário
# de texto em código: duplicar o CSV é como um mapa vira dois.
#
# Formatos reconhecidos (os dois que a árvore produz, medidos em Client.gd):
#   "Shop rejected: insufficient_gems"           — token depois do último ": "
#   "Shop rejected: daily offer rejected (reroll_cap)" — token em parênteses no fim
# Qualquer outra coisa volta intacta: nome de jogador, frase legível, URL.

const ReasonKeyPrefix : String = "reason/"
# Fallback final SEM dependência de catálogo: se até a linha `reason/unknown`
# sumir do compilado, o toast ainda não pode mostrar o token cru.
const EmergencyGeneric : String = "the action could not be completed"

# Diagnóstico de operador (o harness e o log leem; o jogador não vê).
static var LastUnmappedCode : String = ""
static var UnmappedCount : int = 0

# "" quando não há linha no catálogo compilado — quem chama decide o fallback.
static func _translateCode(code : String) -> String:
	var key : String = ReasonKeyPrefix + code
	var message : String = TranslationServer.translate(key)
	# `translate()` devolve a própria chave quando não a conhece.
	if message == key or message.is_empty():
		return ""
	return message

static func _recordUnmapped(code : String) -> void:
	LastUnmappedCode = code
	UnmappedCount += 1
	push_warning("PlayerReasons: unmapped server reason code '%s' degraded to generic text" % code)

# Mensagem genérica do catálogo; o token cru jamais escapa por aqui.
static func GenericText() -> String:
	var message : String = _translateCode("unknown")
	if message.is_empty():
		# Última rede: o texto de emergência também passa pelo catálogo (chave =
		# o próprio texto). Sem linha, `translate` devolve a chave em inglês —
		# legível de qualquer forma, e nunca um token do servidor.
		return TranslationServer.translate(EmergencyGeneric)
	return message

# Um código sozinho (labels de painel: "Defense rejected: <x>"). Token mapeado →
# texto do catálogo; token sem linha → genérica + log; não-token → genérica
# também, porque um "?" ou um texto interno do server na tela é o defeito pai.
static func Describe(code : String) -> String:
	if ReasonCodes.IsReasonToken(code):
		var mapped : String = _translateCode(code)
		if not mapped.is_empty():
			return mapped
		_recordUnmapped(code)
		return GenericText()
	return GenericText()

# Texto de toast completo → texto sem vocabulário do servidor. Ver o cabeçalho
# para os dois formatos aceitos; qualquer outra coisa volta intacta.
static func ToToast(text : String) -> String:
	if text.is_empty():
		return text
	return _tailOrParens(text)

static func _tailOrParens(text : String) -> String:
	var cut : int = text.rfind(": ")
	if cut >= 0:
		var head : String = text.substr(0, cut + 2)
		var tail : String = text.substr(cut + 2)
		if ReasonCodes.IsReasonToken(tail):
			var mapped : String = _translateCode(tail)
			if not mapped.is_empty():
				return head + mapped
			_recordUnmapped(tail)
			return head + GenericText()
	var paren : RegEx = RegEx.new()
	# `(...token)$` — o padrão `"%s rejected (%s)"` do Server.gd. Entre parênteses
	# só um token puro conta; "(gems or count 1..10)" tem espaço e não é token.
	paren.compile("\\(([a-z][a-z0-9_]{2,40})\\)$")
	var matchParen : RegExMatch = paren.search(text)
	if matchParen != null:
		var code : String = String(matchParen.get_string(1))
		var mapped2 : String = _translateCode(code)
		var replacement : String
		if not mapped2.is_empty():
			replacement = mapped2
		else:
			_recordUnmapped(code)
			replacement = GenericText()
		return text.substr(0, matchParen.get_start(0) - 1).rstrip(" ") + " (" + replacement + ")"
	return text
