extends RefCounted
class_name ReasonCodes

# OPS-4 (AUDITORIA_2026-09-27 §13 UX 4/10: "reason tokens do servidor vazando no
# toast — `Shop rejected: insufficient_gems`, ~25 códigos sem i18n"). O servidor é
# autoritativo e fala em tokens estáveis de propósito: é o que o log, o `/metrics`
# e o teste conseguem conferir. O problema nunca foi o token existir, foi ele ser a
# última coisa que o jogador lê.
#
# A tabela mora em `data/i18n/ui.csv` com a chave prefixada `reason/<token>`, e não
# num `const Dictionary` daqui: o CSV é o que o `Localizer` e o `tr()` já leem, é o
# que o tradutor edita, e um mapa duplicado em código driftaria do CSV em duas
# semanas. Consequência honesta do desenho: **não há lista de códigos neste
# arquivo** — o que tem ou não tem tradução é respondido pelo
# `TranslationServer`, e um código novo do servidor simplesmente continua cru até
# alguém adicionar a linha.
#
# Nunca quebra o fluxo: sem chave, sem formato reconhecido, sem tradução ou com
# `TranslationServer` mudo, o texto original volta intacto. Toast ilegível é
# problema de produto; toast vazio é incidente.

# Prefixo de namespace no CSV. Evita colisão com texto de UI de verdade: códigos
# como `expired`, `rejected` e `maxed` são palavras que um rótulo qualquer pode
# ter, e o `Localizer` traduz um rótulo pelo valor exato do texto — uma chave
# solta trocaria o rótulo de uma cena por uma frase de motivo.
const KeyPrefix : String = "reason/"

# Tokens que este processo EMITE e que não nascem de um toast: vivem em coluna de
# banco lida por operador (`grant_queue.error`) e em `fraud_flag.kind`. Não é
# "lista de códigos" — a tabela de texto continua em data/i18n/ui.csv e um código
# sem linha lá continua cru de propósito (ver o cabeçalho). A constante existe por
# um motivo diferente do `tr()`: o MESMO token é escrito por quem detecta (checkout)
# e conferido por quem lê a régua (tests/fraud_test.gd), e duplicá-lo como string
# solta nos dois é como ele vira dois códigos diferentes em duas semanas.
const ChargebackShortfall : String = "chargeback_shortfall"

# Formato do token que o servidor emite: minúsculas, dígitos e underscore, sem
# pontuação. É isso que distingue "motivo" de "frase que já é legível", e é o que
# impede a substituição de mexer em texto de jogador, nome de personagem ou URL.
static func IsReasonToken(token : String) -> bool:
	if token.length() < 3 or token.length() > 40:
		return false
	var first : bool = true
	for byte in token.to_utf8_buffer():
		var ok : bool = (byte >= 97 and byte <= 122) or (not first and byte >= 48 and byte <= 57) or byte == 95
		if not ok:
			return false
		first = false
	return true

# Tradução de um token solto. "" quando não há chave (o chamador mantém o cru).
static func Translate(code : String) -> String:
	if not IsReasonToken(code):
		return ""
	var key : String = KeyPrefix + code
	var message : String = TranslationServer.translate(key)
	# `translate()` devolve a própria chave quando não conhece a mensagem — sem
	# este teste o toast ganharia um "reason/insufficient_gems", que é pior do que
	# o defeito que estamos corrigindo.
	if message == key or message.is_empty():
		return ""
	return message

# Texto de toast completo → texto com o motivo traduzido, se houver chave.
# Aceita os dois formatos que a árvore produz hoje:
#   "Shop rejected: insufficient_gems"   (prefixo legível + token)
#   "insufficient_gems"                  (token solto)
# Qualquer outra coisa volta intacta.
static func Localize(text : String) -> String:
	if text.is_empty():
		return text
	var tail : String = text
	var head : String = ""
	var cut : int = text.rfind(": ")
	if cut >= 0:
		head = text.substr(0, cut + 2)
		tail = text.substr(cut + 2)
	if not IsReasonToken(tail):
		return text
	var translated : String = Translate(tail)
	if translated.is_empty():
		return text
	return head + translated
