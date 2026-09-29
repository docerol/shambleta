extends SceneTree

# OPS-2 (terceira metade): o calendário passou a declarar o passe de cada
# temporada (`premium_sku`), o catálogo passou a cobrar passe de duas temporadas
# (`pass.s1`, `pass.s1.deluxe`, `pass.s2`) e o transport continuou escolhendo o
# SKU por literal — `BuyPass` pedia `pass.s1` com a sucessora agendada no ar. O
# grant de `pass_premium` escreve premium na temporada ATIVA, então o efeito
# colateral é dinheiro: R$ 24,90 pagos por um passe de temporada encerrada e
# creditados na nova. A vitrine tinha o mesmo defeito do outro lado: anunciava os
# três SKUs de passe sempre que houvesse qualquer temporada ativa.
#
# Este harness é a régua do casamento, medida sem banco:
#  1. `SeasonConfig.PremiumSku`/`PremiumSkuOfRow`: a linha congelada manda, o
#     default do catálogo vale só para linha que não declarou nada, e
#     `rules_frozen` ilegível é recusa ("" = não vender), não chute;
#  2. `Storefront.ShopCatalog(sku)`: a vitrine mostra exatamente o passe da
#     temporada em curso, mais o deluxe SE o catálogo o declarar, e nenhum de
#     outra temporada — filtrar de mais também é defeito, então o resto do
#     catálogo é contado;
#  3. o contrato entre as duas linguagens: `DEFAULT_PREMIUM_SKU` do companion é o
#     `DefaultPremiumSku` do jogo, e para TODA entrada do calendário embarcado o
#     que `RulesJSONForEntry` congela é lido pelo companion como o mesmo SKU que o
#     servidor resolve. Se o congelado perder a chave, o companion cai no default
#     e cobra o passe da temporada errada — o defeito original pela metade do
#     dinheiro, e é aqui que isso aparece como falha;
#  4. controle negativo de texto: `BuyPass` e `GetPassCheckoutIntent` não podem
#     ter SKU de passe literal. Linhas de comentário caem antes da varredura: os
#     próprios arquivos explicam o defeito citando o literal, e a régua mede código.
#
# Contrato dos scripts `-s` do repo: o main-loop compila antes dos autoloads e dos
# `class_name`, então as classes entram por `load()` e tudo que vem delas é chamado
# por `call()`/`get()`. Não toca banco, rede, mundo nem escreve disco.
# Saída = contagem de falhas; a régua do gate é a última linha.
#
# Uso:   godot --headless --path . -s tests/pass_season_alignment_test.gd
#        (XDG_DATA_HOME próprio — ver scripts/test.sh.)

const CompanionResPath : String		= "res://companion/server.py"
const ServerResPath : String		= "res://sources/network/server/Server.gd"
const CheckoutResPath : String		= "res://sources/economy/CheckoutService.gd"
# O prefixo comum dos SKUs de passe: é a convenção de nome que as duas camadas
# compartilham para o deluxe (`base` + ".deluxe"), medida e não presumida.
const DeluxeSuffix : String			= ".deluxe"

var checks : int = 0
var failures : int = 0

var _cfg : GDScript = null
var _store : GDScript = null
var _catalog : GDScript = null

func _initialize():
	_cfg = load("res://sources/season/SeasonConfig.gd")
	_store = load("res://sources/economy/Storefront.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	if _check(_cfg != null and _store != null and _catalog != null,
			"as três classes que a régua mede carregam"):
		_checkCalendarEntries()
		_checkShopCatalog()
		_checkCompanionContract()
		_checkNoLiteralSku()
	print("== PASS SEASON: %d checks, %d failures ==" % [checks, failures])
	quit(failures)

# ------------------------------------------------------------------ contagem

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkStr(value : String, expected : String, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: \"%s\" vs \"%s\"" % [label, value, expected])
		return false
	return true

func _checkEqInt(value : int, expected : int, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: %d vs %d" % [label, value, expected])
		return false
	return true

# ------------------------------------------------------------------ helpers

func _read(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()

func _shopSkus() -> Array:
	var out : Array = []
	for line in _catalog.get("SHOP_CATALOG"):
		out.append(str((line as Dictionary).get("sku", "")))
	return out

func _passSkus() -> Array:
	var out : Array = []
	for sku in _store.get("PassSkus"):
		out.append(String(sku))
	return out

func _skusOf(catalog : Array) -> Array:
	var out : Array = []
	for line in catalog:
		out.append(str((line as Dictionary).get("sku", "")))
	return out

func _entries() -> Array:
	return _cfg.call("Entries")

# Linhas de comentário fora, para a varredura de texto medir código e não prosa.
func _codeOf(text : String) -> String:
	var out : String = ""
	for rawLine in text.split("\n"):
		var line : String = String(rawLine).strip_edges()
		if line.begins_with("#"):
			continue
		out += line + "\n"
	return out

func _fnBody(text : String, signature : String) -> String:
	var at : int = text.find(signature)
	if at < 0:
		return ""
	var end : int = text.find("\nfunc ", at)
	return text.substr(at, end - at) if end > at else text.substr(at)

# ------------------------------------------------------------------ 1. resolução pela temporada

func _checkCalendarEntries():
	var entries : Array = _entries()
	if not _check(entries.size() >= 2, "o calendário embarcado declara mais de uma temporada (%d)" % entries.size()):
		return
	var default : String = String(_cfg.get("DefaultPremiumSku"))
	var skus : Array = _shopSkus()
	var passSkus : Array = _passSkus()
	for entry in entries:
		var e : Dictionary = entry
		var id : String = str(e.get("id", "?"))
		var declared : String = String(_cfg.call("PremiumSku", e))
		# Reafirmado aqui (o boot também valida) porque É esta régua que impede o
		# botão de apontar para um SKU que o companion devolve `unknown_sku`.
		_check(skus.has(declared), "%s declara um SKU cobrável no catálogo (%s)" % [id, declared])
		_check(passSkus.has(declared), "%s declara um SKU que a vitrine sabe ser passe (%s)" % [id, declared])
		if e.has("premium_sku"):
			_checkStr(declared, str(e["premium_sku"]), "%s: o declarado é o resolvido" % id)
		else:
			_checkStr(declared, default, "%s sem `premium_sku` vende o passe do catálogo" % id)
		# A temporada de rotação é a que vende o default: é ela que está no ar
		# enquanto o beta mede, e é também o destino de qualquer linha legada do
		# outro lado da fronteira (o companion resolve por default, não por
		# calendário). Divergir aqui é as duas camadas venderem passes diferentes.
		if not bool(_cfg.call("IsScheduled", e)):
			_checkStr(declared, default, "a rotação do calendário vende o default das duas camadas")
	# Controle negativo: uma entrada que declara a sucessora resolve a sucessora, e
	# uma entrada muda recai no default — NUNCA no passe de outra temporada.
	_checkStr(String(_cfg.call("PremiumSku", {"id": "sX", "premium_sku": "pass.s2"})), "pass.s2",
			"entrada que declara a sucessora resolve a sucessora")
	_checkStr(String(_cfg.call("PremiumSku", {"id": "sY"})), default,
			"entrada muda recai no default do catálogo")

# ------------------------------------------------------------------ 2. vitrine por temporada

func _checkShopCatalog():
	var total : Array = _catalog.get("SHOP_CATALOG")
	var allSkus : Array = _shopSkus()
	var passSkus : Array = _passSkus()
	var none : Array = _skusOf(_store.call("ShopCatalog", ""))
	_checkEqInt(none.size(), total.size() - passSkus.size(),
			"sem passe à venda, só os SKUs de passe somem da vitrine")
	for sku in passSkus:
		_check(not none.has(sku), "%s não é anunciado sem temporada" % sku)
	for entry in _entries():
		var declared : String = String(_cfg.call("PremiumSku", entry))
		var shown : Array = _skusOf(_store.call("ShopCatalog", declared))
		var own : int = 0
		for sku in passSkus:
			if sku == declared or sku == declared + DeluxeSuffix:
				own += 1
		_check(shown.has(declared), "%s: o passe da temporada é anunciado" % declared)
		_check(shown.has(declared + DeluxeSuffix) == allSkus.has(declared + DeluxeSuffix),
				"%s: o deluxe aparece exatamente quando o catálogo o declara" % declared)
		for sku in passSkus:
			if sku != declared and sku != declared + DeluxeSuffix:
				_check(not shown.has(sku), "%s: passe de outra temporada fica de fora (%s)" % [declared, sku])
		# A metade silenciosa: filtrar demais esconde produto pagável.
		_checkEqInt(shown.size(), total.size() - passSkus.size() + own,
				"%s: nada além dos passes de outra temporada foi filtrado" % declared)
	# Uma vitrine que recebe um SKU que não existe no catálogo não inventa botão.
	var ghost : Array = _skusOf(_store.call("ShopCatalog", "pass.s9"))
	_checkEqInt(ghost.size(), total.size() - passSkus.size(), "SKU de passe inexistente na temporada = nenhum passe")

# ------------------------------------------------------------------ 3. contrato companion ⇄ jogo

# Espelho de `companion/server.py season_offer_status`: a linha congelada manda,
# linha sem chave recai no default do PYTHON, JSON ilegível é recusa. Python não
# lê o calendário de temporadas (no container não tem o arquivo), então o que se
# amarra aqui é concordância de RESULTADO, não de caminho.
func _companionSkuOfRow(frozen : String, pyDefault : String) -> Dictionary:
	var raw : String = frozen.strip_edges()
	if raw.is_empty():
		return {"readable": true, "sku": pyDefault}
	var parsed : Variant = _parse(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"readable": false, "sku": ""}
	var obj : Dictionary = parsed
	if not obj.has("premium_sku"):
		return {"readable": true, "sku": pyDefault}
	# Chave presente e ilegível (null, número, texto vazio) é recusa também. Sem
	# este ramo o mirror e o `PremiumSkuOfRow` divergem justamente onde o Python
	# inventaria "None": `str(null)` aqui daria "<null>" e a régua passaria verde
	# sobre uma linha que não declara passe nenhum.
	var declared : Variant = obj["premium_sku"]
	if not (declared is String) or String(declared).strip_edges().is_empty():
		return {"readable": false, "sku": ""}
	return {"readable": true, "sku": String(declared).strip_edges()}

# Parse silencioso: o harness quebra JSON de propósito para medir o fail-closed, e
# `JSON.parse_string` imprime `ERROR:` no stderr a cada mutação deliberada.
func _parse(raw : String) -> Variant:
	var json : JSON = JSON.new()
	return json.data if json.parse(raw) == OK else null

func _checkCompanionContract():
	var companionSrc : String = _read(CompanionResPath)
	if not _check(not companionSrc.is_empty(), "companion/server.py foi lido"):
		return
	var pyDefault : String = _pyStringLiteral(companionSrc, "DEFAULT_PREMIUM_SKU")
	if not _check(not pyDefault.is_empty(), "o companion declara DEFAULT_PREMIUM_SKU como literal"):
		return
	var default : String = String(_cfg.get("DefaultPremiumSku"))
	_checkStr(pyDefault, default, "as duas camadas têm o MESMO default de passe (Python e GDScript)")
	_check(_shopSkus().has(pyDefault), "o default do companion é um SKU cobrável do catálogo")
	_check(_passSkus().has(pyDefault), "o default do companion é um passe reconhecido pela vitrine")

	var now : int = int(Time.get_unix_time_from_system())
	for entry in _entries():
		var e : Dictionary = entry
		var id : String = str(e.get("id", "?"))
		var frozen : String = String(_cfg.call("RulesJSONForEntry", e))
		var row : Dictionary = {"season_id": 1, "starts_at": now, "rules_frozen": frozen}
		var server : String = String(_cfg.call("PremiumSkuOfRow", row))
		var companion : Dictionary = _companionSkuOfRow(frozen, pyDefault)
		var parsed : Variant = _parse(frozen)
		if not _check(typeof(parsed) == TYPE_DICTIONARY, "%s: o congelado parseia para as duas camadas" % id):
			continue
		_check(bool(companion["readable"]), "%s: o companion lê o congelado" % id)
		_checkStr(str(companion["sku"]), server,
				"%s: companion e servidor resolvem o mesmo passe para a mesma linha" % id)
		# Se a temporada não vende o default, a chave TEM que estar no congelado:
		# sem ela o companion cai no default em silêncio e cobra o passe errado.
		if server != default:
			_check((parsed as Dictionary).has("premium_sku"),
					"%s: congelou o próprio SKU, senão o companion vende %s" % [id, default])
	# Linha legada (toda temporada aberta antes do OPS-2): sem a chave no
	# congelado, as duas camadas vendem o default.
	var legacy : Dictionary = {"season_id": 2, "starts_at": now, "rules_frozen": "{}"}
	_checkStr(str(_companionSkuOfRow("{}", pyDefault)["sku"]), pyDefault, "linha legada: companion usa o default")
	_checkStr(String(_cfg.call("PremiumSkuOfRow", legacy)), default, "linha legada: servidor usa o default")
	# Fail-closed: `rules_frozen` que não é objeto, e objeto cuja chave de passe é
	# null / número / texto vazio, não viram venda em camada nenhuma. Os três
	# valores ilegíveis são exatamente onde um `str(...)` solto inventaria SKU
	# ("<null>" de um lado, "None" do outro) e as duas camadas cobrariam um passe
	# que nenhuma temporada declarou.
	for broken in ["nada de json", "[]", "{\"premium_sku\": ]", "{\"premium_sku\": null}",
			"{\"premium_sku\": \"\"", "{\"premium_sku\": \"  \"}", "{\"premium_sku\": 7}"]:
		var brokenRow : Dictionary = {"season_id": 3, "starts_at": now, "rules_frozen": broken}
		_checkStr(String(_cfg.call("PremiumSkuOfRow", brokenRow)), "",
				"regras ilegíveis (%s) = nenhum passe à venda" % broken)
		_check(not bool(_companionSkuOfRow(broken, pyDefault)["readable"]),
				"e o companion também recusa (%s)" % broken)
	_checkStr(String(_cfg.call("PremiumSkuOfRow", {})), "", "sem linha ativa não há passe")
	# O mirror acima é escrito à mão: ele só prova alguma coisa enquanto o fonte do
	# companion mantiver os ramos que o mirror imita. Podar um deles passa a ser
	# gate vermelho aqui, e não régua que envelhece em silêncio.
	_check(companionSrc.contains("if not isinstance(parsed, dict):"),
			"o companion ainda recusa congelado que não é objeto")
	_check(companionSrc.contains("isinstance(value, str)"),
			"e o companion ainda recusa premium_sku que não é texto legível")
	_check(companionSrc.contains("ORDER BY season_id DESC"),
			"e lê a linha de temporada mais nova, não a primeira que aparecer")

func _pyStringLiteral(text : String, name : String) -> String:
	var at : int = text.find(name + " = ")
	if at < 0:
		return ""
	var open : int = at + name.length() + 3
	if open >= text.length() or (text[open] != "\"" and text[open] != "'"):
		return ""
	var quote : String = text[open]
	var close : int = text.find(quote, open + 1)
	return text.substr(open + 1, close - open - 1) if close > open else ""

# ------------------------------------------------------------------ 4. nenhum SKU literal no caminho do botão

func _checkNoLiteralSku():
	var serverSrc : String = _read(ServerResPath)
	var checkoutSrc : String = _read(CheckoutResPath)
	if not _check(not serverSrc.is_empty() and not checkoutSrc.is_empty(), "as duas fontes do botão foram lidas"):
		return
	var buy : String = _codeOf(_fnBody(serverSrc, "func BuyPass("))
	if not _check(not buy.is_empty(), "BuyPass localizada em Server.gd"):
		return
	_check(buy.contains("GetPassCheckoutIntent"), "BuyPass pede o passe da temporada (`GetPassCheckoutIntent`)")
	for sku in _passSkus():
		_check(not buy.contains("\"" + sku + "\""), "BuyPass não carrega o SKU literal de passe (%s)" % sku)
	var resolve : String = _codeOf(_fnBody(checkoutSrc, "func GetPassCheckoutIntent("))
	if not _check(not resolve.is_empty(), "GetPassCheckoutIntent localizada em CheckoutService.gd"):
		return
	_check(resolve.contains("ActivePassSku"), "a intent resolve o SKU pela temporada ativa")
	_check(resolve.contains("GetCheckoutIntent(accountID"), "e cai na porta de dinheiro comum, não em preço próprio")
	for sku in _passSkus():
		_check(not resolve.contains("\"" + sku + "\""), "nem a resolução carrega SKU literal (%s)" % sku)
