extends SceneTree

# FAIXA DECLARADA dos knobs do catálogo base (JUIZ ECONOMIA 2026-09-27 → corte da
# auditoria 2026-09-28). O gap era este: `data/conf/economy_base_catalog.json` já
# era dados, mas `ValidateBaseCatalog` travava QUALQUER divergência contra o const
# — a antiga linha 243 de `sources/economy/EconomyBaseCatalog.gd`,
# `if int(value) != int(BASE_KNOBS_REF[name])`, na frase "catálogo base é
# representação, não rebalance". Resultado: o JSON era uma cópia dos consts e um
# rebalance ainda exigia editar código e shippar build. Agora cada knob traz uma
# FAIXA aceita em `_knob_ranges`, e o validador cobra a faixa, não a igualdade:
# dentro dela um número diferente do default passa; fora, ou sem banda, é erro;
# o const virou o default documentado (fallback de quando o arquivo não entra).
#
# O que esta suíte prova, nas FUNÇÕES REAIS (sem reimplementar nada):
#   (a) um knob DENTRO da banda mas diferente do const agora valida (é o rebalance
#       que faltava — o ponto do corte, e a exata regressão que a jaula causava);
#   (b) knob ACIMA/ABAIXO da banda falha (o dedão-no-teclado que a igualdade
#       impedia vira recusa pela borda certa, a faixa);
#   (c) knob SEM banda declarada falha (fail-closed: sem teto dito, o validador
#       não adivinha rebalance);
#   (d) o `data/conf/economy_base_catalog.json` do repo valida limpo (controle
#       positivo do boot; os números vivos NÃO são tocados por este harness);
#   (e) malformação e chave desconhecida continuam caindo fechadas — tipo do knob,
#       raiz estranha, knob estranho, banda estranha, banda {min>max} — e a
#       validação de tipo/positividade prévia à banda permanece.
#
# Contrato dos scripts `-s` do repo (ver `tests/season_liveops_test.gd`,
# `tests/balance_test.gd`): o script compila ANTES dos autoloads, então nada de
# `class_name`/`EconomyCatalog`/`EconomyBaseCatalog` em tempo de parse — a classe
# entra por `load()` e as funções por `.call()`/`.get()`. Diferente daqueles: este
# é totalmente puro (texto entra, lista de erros sai) e NÃO toca banco, janela nem
# o `EconomyCatalog` que carrega estado — é exatamente a disciplina da metade nova
# do `LiveOpsCalendar`/`SeasonConfig`. Saída = contagem de falhas; a régua do gate
# é a última linha.

const BaseCatalogScriptPath : String = "res://sources/economy/EconomyBaseCatalog.gd"

var checks : int = 0
var failures : int = 0

var _base : GDScript = null
var _shopRef : Array = []
var _defaults : Dictionary = {}
var _shippedRanges : Dictionary = {}
var _orderings : Dictionary = {}
var _shippedRaw : String = ""

func _initialize():
	_run()

# ------------------------------------------------------------------ contagem (house pattern)

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(value : int, expected : int, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: %d vs %d" % [label, value, expected])
		return false
	return true

func _checkHas(errors : PackedStringArray, needle : String, label : String) -> bool:
	for e in errors:
		if str(e).contains(needle):
			return _check(true, label)
	return _check(false, "%s (esperado achar \"%s\" em %s)" % [label, needle, str(errors)])

# ------------------------------------------------------------------ fixtures

# Doc completo e válido, com `knobs` e `_knob_ranges` que o chamador escolher; a
# `shop` é sempre a cópia do `ShopCatalogRef` para a metade da loja não poluir as
# contagens — o que se testa aqui é a BANDA do knob, não o SKU.
func _docWithRanges(knobs : Dictionary, ranges : Variant) -> String:
	var doc : Dictionary = {
		"_note": "fixture do harness de banda",
		"_source": "fixture",
		"_knob_ranges": ranges,
		"knobs": knobs,
		"shop": _shopClone(),
	}
	return JSON.stringify(doc)

# Igual a acima mas SEM `_knob_ranges`: cada knob cai em "sem banda declarada".
func _docNoRanges(knobs : Dictionary) -> String:
	var doc : Dictionary = {
		"_note": "fixture do harness de banda",
		"_source": "fixture",
		"knobs": knobs,
		"shop": _shopClone(),
	}
	return JSON.stringify(doc)

func _shopClone() -> Array:
	var shop : Array = []
	for line in _shopRef:
		shop.append((line as Dictionary).duplicate(true))
	return shop

func _defaultsCopy() -> Dictionary:
	return _defaults.duplicate(true)

func _bandLo(name : String) -> int:
	if not _shippedRanges.has(name):
		return -1
	return int((_shippedRanges[name] as Dictionary).get("min", 0))

func _bandHi(name : String) -> int:
	if not _shippedRanges.has(name):
		return -1
	return int((_shippedRanges[name] as Dictionary).get("max", 0))

func _validate(raw : String) -> PackedStringArray:
	# O retorno de `.call()` é Variant; a amarra ao tipo é a MESMA atribuição
	# tipada que os harnesses do repo fazem (`var entries : Array = _cfg.call(...)`),
	# então `errors` sai já como PackedStringArray e o `return` não converte nada.
	var errors : PackedStringArray = _base.call("ValidateBaseCatalog", raw)
	return errors

# ------------------------------------------------------------------ run

func _run():
	print("== economia base harness: banda declarada dos knobs ==")
	_base = load(BaseCatalogScriptPath)
	if not _check(_base != null, "EconomyBaseCatalog carrega por load()"):
		_finish()
		return
	_shopRef = _base.get("ShopCatalogRef")
	_defaults = _base.get("BASE_KNOBS_REF")
	if not _check(typeof(_shopRef) == TYPE_ARRAY and typeof(_defaults) == TYPE_DICTIONARY, "consts do catálogo (ShopCatalogRef/BASE_KNOBS_REF) resolvem"):
		_finish()
		return
	var path : String = _base.get("BaseCatalogPath")
	_check(not path.is_empty(), "BaseCatalogPath declarado (o harness lê o MESMO caminho do boot)")
	_shippedRaw = FileAccess.get_file_as_string(path)
	var parsed : Variant = JSON.parse_string(_shippedRaw)
	if not _check(typeof(parsed) == TYPE_DICTIONARY, "o catálogo base do repo é um objeto JSON"):
		_finish()
		return
	_shippedRanges = (parsed as Dictionary).get("_knob_ranges", {})
	var ordVar : Variant = _base.get("KnobOrderings")
	if typeof(ordVar) == TYPE_DICTIONARY:
		_orderings = ordVar
	# Precondition: todo knob conhecido tem banda no arquivo. É a asserção mais
	# forte do corte (a régua que a jaula de igualdade não dava) e o que libera as
	# sondas abaixo de ler `_shippedRanges[name]` sem medo.
	for want : String in _defaults.keys():
		_check(_shippedRanges.has(want), "o catálogo do repo declara banda para %s (senão nem o default passa)" % want)
	_suiteBandAcceptsNonConst()
	_suiteBandRejectsOutside()
	_suiteBandMissing()
	_suiteShippedFile()
	_suiteFailClosed()
	_suiteOrdering()
	_finish()

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ suite (a): banda aceita o diferente do const

# O ponto do corte. A jaula da linha 243 rejeitava QUALQUER valor != BASE_KNOBS_REF,
# então rebalance sem código era impossível. Dentro da banda isso tem de passar.
func _suiteBandAcceptsNonConst():
	print("[suite] A: knob dentro da banda mas diferente do const valida (o rebalance que faltava)")
	_check(not _shippedRanges.is_empty(), "o catálogo do repo declara _knob_ranges (sem isso não há banda a conferir)")
	# Para cada knob, um valor da faixa (inclusive) que NÃO é o default. A sonda é a
	# primeira aresta que também não inverte um par declarado em `KnobOrderings`: a
	# banda é uma das leis do arquivo, não a única, e uma sonda que só obedece à
	# banda poderia validar o fixture cometendo o defeito da suite F.
	for name in _defaults.keys():
		var def : int = int(_defaults[name])
		var lo : int = _bandLo(String(name))
		var hi : int = _bandHi(String(name))
		var probe : int = -1
		for cand : int in [lo, hi]:
			if cand != def and _probeKeepsOrder(String(name), cand):
				probe = cand
				break
		if not _check(probe >= lo and probe <= hi and probe != def,
			"%s: existe aresta de banda != default (%d) que respeita a ordem declarada [%d, %d]" % [name, def, lo, hi]):
			continue
		var knobs : Dictionary = _defaultsCopy()
		knobs[name] = probe
		var errors : PackedStringArray = _validate(_docWithRanges(knobs, _shippedRanges.duplicate(true)))
		_checkEq(errors.size(), 0, "%s = %d (dentro da banda, != const %d) valida limpo: %s" % [name, probe, def, str(errors)])
	# E o topo da faixa, inclusive — fronteira simétrica da banda.
	var topName : String = "chest_cost_gems"
	if _shippedRanges.has(topName):
		var knobs2 : Dictionary = _defaultsCopy()
		knobs2[topName] = _bandHi(topName)
		var e2 : PackedStringArray = _validate(_docWithRanges(knobs2, _shippedRanges.duplicate(true)))
		_checkEq(e2.size(), 0, "%s no teto da banda (%d, != default) valida: %s" % [topName, _bandHi(topName), str(e2)])

# ------------------------------------------------------------------ suite (b): banda recusa fora

# O dedão-no-teclado que a igualdade barrava por acidente (qualquer diferença) é
# barrado agora pelo motivo certo: fora da faixa declarada.
func _suiteBandRejectsOutside():
	print("[suite] B: knob acima/abaixo da banda falha")
	var name : String = "chest_cost_gems"
	var lo : int = _bandLo(name)
	var hi : int = _bandHi(name)
	var knobsAbove : Dictionary = _defaultsCopy()
	knobsAbove[name] = hi + 1
	var eAbove : PackedStringArray = _validate(_docWithRanges(knobsAbove, _shippedRanges.duplicate(true)))
	_checkHas(eAbove, "fora da banda", "%s = %d acima do teto (%d) é recusado" % [name, hi + 1, hi])
	_checkHas(eAbove, name, "e o erro nomeia o knob que passou da faixa")
	# Abaixo: usa um piso > 1 para a sonda não cair antes na checagem de positividade.
	var belowProbe : int = lo - 1
	if _check(belowProbe > 0, "%s: sonda abaixo da banda (%d) ainda é positiva (senão cai na régua de faucet antes)" % [name, belowProbe]):
		var knobsBelow : Dictionary = _defaultsCopy()
		knobsBelow[name] = belowProbe
		var eBelow : PackedStringArray = _validate(_docWithRanges(knobsBelow, _shippedRanges.duplicate(true)))
		_checkHas(eBelow, "fora da banda", "%s = %d abaixo do piso (%d) é recusado" % [name, belowProbe, lo])

# ------------------------------------------------------------------ suite (c): sem banda declarada

# Fail-closed: um knob sem faixa não tem como ser distinguido de um rebalance
# silencioso, então o validador recusa em vez de usar o default calado.
func _suiteBandMissing():
	print("[suite] C: knob sem banda declarada falha")
	var name : String = "chest_cost_gems"
	# Remove só a banda deste knob (o valor continua o default — prova que é a
	# AUSÊNCIA de banda, não o número, que derruba).
	var ranges : Dictionary = _shippedRanges.duplicate(true)
	ranges.erase(name)
	var errors : PackedStringArray = _validate(_docWithRanges(_defaultsCopy(), ranges))
	_checkHas(errors, "sem banda declarada", "%s sem faixa em _knob_ranges é recusado (default %d)" % [name, int(_defaults[name])])
	_checkHas(errors, name, "e o erro nomeia o knob órfão de banda")
	# Sem `_knob_ranges` nenhum: todo knob cai em "sem banda".
	var errorsNone : PackedStringArray = _validate(_docNoRanges(_defaultsCopy()))
	_check(errorsNone.size() > 0, "arquivo sem _knob_ranges nenhum é recusado")
	_checkHas(errorsNone, "sem banda declarada", "e cada knob é reportado como sem faixa")

# ------------------------------------------------------------------ suite (d): o arquivo do repo

func _suiteShippedFile():
	print("[suite] D: o data/conf/economy_base_catalog.json do repo valida limpo")
	var errors : PackedStringArray = _validate(_shippedRaw)
	_checkEq(errors.size(), 0, "o catálogo base vivo valida sem erro (controle positivo do boot): %s" % [str(errors)])
	# Os números vivos estão dentro das próprias bandas (o default é centro da faixa).
	var knobsShipped : Dictionary = (JSON.parse_string(_shippedRaw) as Dictionary).get("knobs", {})
	for name in knobsShipped.keys():
		var n : String = String(name)
		var v : int = int(knobsShipped[name])
		_check(_shippedRanges.has(n), "%s tem banda declarada no arquivo do repo" % n)
		if _shippedRanges.has(n):
			_check(v >= _bandLo(n) and v <= _bandHi(n), "%s = %d está na banda [%d, %d] do repo" % [n, v, _bandLo(n), _bandHi(n)])

# ------------------------------------------------------------------ suite (e): fail-closed antigo preservado

# A banda substitui só a IGUALDADE; tipo, chave-desconhecida e malformação
# continuam caindo fechadas. Se alguma dessas sumiu, o rebalance virou porta
# para lixo no catálogo.
func _suiteFailClosed():
	print("[suite] E: malformação e chave desconhecida continuam fechadas")
	_check(_validate("").size() > 0, "arquivo ausente/vazio é erro")
	_checkHas(_validate("[1,2]"), "não é um objeto JSON", "topo não-objeto é erro")
	_checkHas(_validate("{\"knobs\": 5}"), "não é um objeto", "knobs que não é objeto é erro")
	# Raiz desconhecida.
	var junk : Dictionary = {
		"_note": "x", "_source": "x", "_knob_ranges": _shippedRanges.duplicate(true),
		"knobs": _defaultsCopy(), "shop": _shopClone(), "rootjunk": 1,
	}
	_checkHas(_validate(JSON.stringify(junk)), "raiz: chave desconhecida", "chave na raiz sem leitor é erro")
	# Knob desconhecido.
	var badKnob : Dictionary = _defaultsCopy()
	badKnob["bogus_knob"] = 5
	_checkHas(_validate(_docWithRanges(badKnob, _shippedRanges.duplicate(true))), "chave desconhecida", "knob que nenhum leitor conhece é erro")
	# Banda para knob inexistente.
	var badRanges : Dictionary = _shippedRanges.duplicate(true)
	badRanges["bogus_knob"] = {"min": 1, "max": 2}
	_checkHas(_validate(_docWithRanges(_defaultsCopy(), badRanges)), "nenhum leitor conhece", "faixa de um knob que ninguém lê é erro")
	# Tipo/positividade do knob (prévias à banda) permanecem.
	var strKnob : Dictionary = _defaultsCopy()
	strKnob["chest_cost_gems"] = "60"
	_checkHas(_validate(_docWithRanges(strKnob, _shippedRanges.duplicate(true))), "número inteiro", "knob string não passa na régua de tipo")
	var floatKnob : Dictionary = _defaultsCopy()
	floatKnob["chest_cost_gems"] = 19.9
	_checkHas(_validate(_docWithRanges(floatKnob, _shippedRanges.duplicate(true))), "tem que ser inteiro", "knob fracionado (preço no bloco errado) é erro")
	var zeroKnob : Dictionary = _defaultsCopy()
	zeroKnob["chest_cost_gems"] = 0
	_checkHas(_validate(_docWithRanges(zeroKnob, _shippedRanges.duplicate(true))), "não é positivo", "knob zero é faucet gratuito, recusado antes da banda")
	# Forma da banda: min>max, min<=0 e chave estranha.
	var emptyBand : Dictionary = _shippedRanges.duplicate(true)
	emptyBand["chest_cost_gems"] = {"min": 200, "max": 60}
	_checkHas(_validate(_docWithRanges(_defaultsCopy(), emptyBand)), "banda vazia", "banda min>max é recusada")
	var zeroBand : Dictionary = _shippedRanges.duplicate(true)
	zeroBand["chest_cost_gems"] = {"min": 0, "max": 240}
	_checkHas(_validate(_docWithRanges(_defaultsCopy(), zeroBand)), "min", "banda com piso não-positivo é recusada")
	var extraKey : Dictionary = _shippedRanges.duplicate(true)
	extraKey["chest_cost_gems"] = {"min": 60, "max": 240, "meio": 100}
	_checkHas(_validate(_docWithRanges(_defaultsCopy(), extraKey)), "chave desconhecida", "chave estranha dentro da banda é erro")
	# `_knob_ranges` não-objeto.
	_checkHas(_validate(_docWithRanges(_defaultsCopy(), "nao-eh-objeto")), "_knob_ranges", "_knob_ranges que não é objeto é erro")
	# Uma knob que sumiu do arquivo continua erro (a banda não apaga o leitor).
	var missingKnob : Dictionary = _defaultsCopy()
	missingKnob.erase("trade_daily_cap")
	_checkHas(_validate(_docWithRanges(missingKnob, _shippedRanges.duplicate(true))), "sumiu do arquivo", "knob que o código espera e o arquivo não declara é erro")

# ------------------------------------------------------------------ suite (f): ordem ENTRE knobs

# A banda é o que libera o rebalance, e junto abriu uma forma de erro que a jaula de
# igualdade tornava impossível de escrever: cada knob dentro da própria faixa e o PAR
# invertido. `trade_daily_cap` sobe para 100 (banda permite), `trade_daily_cap_vip`
# fica em 40 — quem paga passa a ter MENOS troca por dia que quem não paga. Nenhuma
# régua de faixa isolada vê isso; a invariante é entre knobs.
func _suiteOrdering():
	print("[suite] F: par declarado em KnobOrderings não pode ser invertido pela banda")
	if not _check(not _orderings.is_empty(), "KnobOrderings declara ao menos um par (sem par, esta suite é decorativa)"):
		return
	for upperKey in _orderings.keys():
		var upper : String = String(upperKey)
		var lower : String = String(_orderings[upperKey])
		if not _check(_defaults.has(upper) and _defaults.has(lower),
			"KnobOrderings.%s → %s: os dois lados são knobs do catálogo (nome errado desligaria a régua em silêncio)" % [upper, lower]):
			continue
		var lowerDefault : int = int(_defaults[lower])
		var upperDefault : int = int(_defaults[upper])
		var uLo : int = _bandLo(upper)
		var uHi : int = _bandHi(upper)
		# (i) A ordem do arquivo do repo é de fato ordem — não é acidental: se um dia
		# o default inverter, o boot reclama (e a suite D, que valida o arquivo, junto).
		_check(upperDefault >= lowerDefault, "default do código: %s (%d) >= %s (%d)" % [upper, upperDefault, lower, lowerDefault])
		# (ii) Sonda desordenada DENTRO da banda: é o caso que a banda sozinha deixava
		# passar. Se a banda do `upper` nem alcança o piso do `lower`, a desordem é
		# impossível por construção — e aí o que prova a régua é a própria banda, então
		# dizemos isso em vez de fingir que rodamos o caso.
		if uLo < lowerDefault:
			var badKnobs : Dictionary = _defaultsCopy()
			badKnobs[upper] = uLo
			var badErrors : PackedStringArray = _validate(_docWithRanges(badKnobs, _shippedRanges.duplicate(true)))
			_checkHas(badErrors, "abaixo de knobs.%s" % lower,
				"%s = %d (na banda [%d, %d]) abaixo de %s = %d é recusado" % [upper, uLo, uLo, uHi, lower, lowerDefault])
			_checkHas(badErrors, "quem paga recebe", "e o erro diz o motivo do produto, não só o número")
			# (iii) Empate é aceito: paridade num eixo é decisão de produto (o VIP pode
			# valer por outro eixo), inversão é defeito. Distinguir os dois é o contrato.
			var tieKnobs : Dictionary = _defaultsCopy()
			tieKnobs[upper] = lowerDefault
			var tieErrors : PackedStringArray = _validate(_docWithRanges(tieKnobs, _shippedRanges.duplicate(true)))
			_checkEq(tieErrors.size(), 0, "%s == %s (%d) é aceito (empate é escolha, não inversão): %s" % [upper, lower, lowerDefault, str(tieErrors)])
		else:
			_check(uLo >= lowerDefault, "%s: a própria banda já impede a desordem contra %s = %d (piso %d >= %d)" % [upper, lower, lowerDefault, uLo, lowerDefault])
				# (iv) O outro lado do par: subir o piso acima do `upper` é a mesma inversão
		# escrita do lado de baixo, e tem de ser recusa do mesmo jeito.
		# A mensagem do produto tem UMA forma só: nomeia `upper` como o que está em
		# baixo e `lower` como o piso declarado, com os dois VALORES — porque quem
		# decide quem está embaixo é o número, não a caneta que editou o arquivo. Por
		# isso a agulha aqui não pode ser "abaixo de knobs.<upper>" (isso inverteria a
		# convenção e a régua passaria a acusar o knob certo de ser o piso): ela exige
		# o piso com o número NOVO, o que só acontece se a recusa veio do teto subido.
		var lHi : int = _bandHi(lower)
		if lHi > upperDefault:
			var flipKnobs : Dictionary = _defaultsCopy()
			flipKnobs[lower] = lHi
			var flipErrors : PackedStringArray = _validate(_docWithRanges(flipKnobs, _shippedRanges.duplicate(true)))
			_checkHas(flipErrors, "abaixo de knobs.%s = %d" % [lower, lHi],
				"%s = %d (teto da banda) acima de %s = %d é recusado pelo mesmo motivo, do outro lado" % [lower, lHi, upper, upperDefault])
			_checkHas(flipErrors, "knobs.%s: %d " % [upper, upperDefault],
				"e a recusa do outro lado continua apontando para o knob que ficou para trás, com o valor dele")
		else:
			_check(lHi <= upperDefault, "%s: teto da banda (%d) não alcança %s = %d (desordem impossível por aqui)" % [lower, lHi, upper, upperDefault])

# A aresta de banda escolhida pelas sondas de (A) só serve se, com os OUTROS knobs no
# default, ela não inverte nenhum par declarado — a banda é uma das leis do arquivo,
# não a única. Sem este filtro a suite A "provaria" o rebalance escrevendo o defeito
# da suite F, e o veredito diria "0 erros" para um fixture que o validador recusa.
func _probeKeepsOrder(name : String, value : int) -> bool:
	for upperKey in _orderings.keys():
		var upper : String = String(upperKey)
		var lower : String = String(_orderings[upperKey])
		if not _defaults.has(upper) or not _defaults.has(lower):
			continue
		var uVal : int = int(_defaults[upper])
		var lVal : int = int(_defaults[lower])
		if name == upper:
			uVal = value
		elif name == lower:
			lVal = value
		if uVal < lVal:
			return false
	return true
