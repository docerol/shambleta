extends SceneTree

# gate-marker: == RESULT:

# gold_sink_scale_test.gd — o ACHADO #107: a pia de gold não lia zona nenhuma.
#
# As duas taxas de forja eram `base × tier²` e a fazenda paga ~1.25^zona por kill
# (`FarmZoneData`). Num tier 9 o mesmo preço era ~1,8 h de fazenda na zona 1 e ~38 s
# na zona 27: o sumidouro encolhia exatamente onde a torneira explode. Este harness
# mede a grandeza que o produto promete — MINUTOS DE FAZENDA PAR PARA PAGAR UMA AÇÃO
# DE FORJA, em todo par (zona, tier) alcançável — e amarra o número a sete coisas que
# não podem se soltar sozinhas:
#
#   A  monotonicidade na curva REAL: no mesmo tier a taxa é estritamente maior numa
#      zona alta que na zona 1, zona a zona, medida em `FarmZoneData.GetZone()`, e no
#      caminho do produto com dois chars de verdade (a zona vem do `character`);
#   B  a zona 1 é a constante de antes, BIT FOR BIT: `CORRUPT_FEE_BASE × tier²` e
#      `CraftCatalog.SubmitFee(tier)`, para qualquer elasticidade da banda, e paga de
#      verdade pelo caminho do produto (delta real de `stat.gp`), não por uma fórmula
#      reimplementada aqui;
#   C  a BANDA DECLARADA: "uma ação de forja de tier 9 custa entre 60 e 180 minutos de
#      fazenda par em toda zona onde o tier 9 é alcançável", escalada pelo próprio
#      tier² do preço (um tier T custa entre 60×(T/9)² e 180×(T/9)²). Todo par
#      alcançável é conferido, a tabela antes/depois das 27 zonas é impressa no maior
#      tier de cada zona, e o par mais apertado sai como PIOR CASO medido;
#   D  o knob vem do ARQUIVO: `EconomyCatalog.ApplyBaseCatalog` com uma elasticidade
#      diferente DENTRO da banda muda a taxa efetivamente cobrada; fora dela é recusado
#      com o erro do próprio validador e nada do arquivo entra no estado;
#   E  knob ausente ou não-inteiro é fail-closed: o validador nomeia o sumiço ("sumiu
#      do arquivo") e o não-inteiro, o arquivo recusado não sobrescreve nada, e o preço
#      cobrado não se move por default silencioso (o defeito do `SeasonConfig._IntOf`,
#      que devolvia default sem dizer);
#   F  depois de pagar a taxa escalada o ledger de gold ainda fecha: linhas `kind =
#      gold` de valor NEGATIVO, os motivos de sempre (`corrupt_fee:<item>` e
#      `craft_submit_fee:tier<slot>`), encadeamento `balance_after` linha a linha e
#      `origem + Σ amount == carteira`;
#   G  controle negativo plantado: a MESMA varredura roda contra a fórmula não escalada
#      (o estado de antes do corte) e volta VERMELHA, com a acusação nomeando o par
#      (zona, tier) e os minutos medidos; depois o predicado é reaplicado no estado
#      consertado e volta verde — prova de que foi a emenda que mordeu, não um
#      predicado sempre-falso.
#
# O default 886 (permille) não é gosto: é o MENOR inteiro que cabe na banda, medido
# aqui na curva real — a régua confere que 885 já fura o piso na zona topo. O teto da
# banda (1099) é onde a zona 27 estouraria os 180 min. A banda em
# `data/conf/economy_base_catalog.json` é exatamente essa janela, então o validador
# recusa o que esta régua recusaria.
#
# Uso: bash scripts/test.sh one gold_sink_scale_test 600
# Saída: última linha "== RESULT: <n> checks, <m> failures ==" (exit code = <m>).
#
# Como todo harness `-s` do repo: o script compila antes dos autoloads, então nada de
# identificador tipado do projeto em tempo de parse — classe entra por `load()` e
# função por `.call()`/`.get()`.

const BandTier9MinMinutes : float = 60.0
const BandTier9MaxMinutes : float = 180.0
const BandAnchorTier : int = 9

# Teto de tier do craft: `SubmitCraft` recusa `tier > 8`, então tier 9 só existe na
# corrupção. Lido do fonte no mesmo espírito da banda: se o produto liberar tier 9 de
# craft, esta linha é o que acusa a régua de ter ficado para trás.
const CraftMaxTier : int = 8

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _sql : Node = null
var _eco : Object = null
var _svc : Object = null
var _forge : GDScript = null
var _farm : GDScript = null
var _craft : GDScript = null
var _ecoCat : GDScript = null
var _baseCat : GDScript = null
var _dbScript : GDScript = null
var _actorCommons : GDScript = null
var _skillCommons : GDScript = null
var _networkCommons : GDScript = null

var _corruptBase : int = 0
var _craftBase : int = 0
var _knobKey : String = "forge_fee_zone_elasticity_permille"
var _knobRef : int = 0
var _maxZone : int = 0
var _maxTier : int = 0
var _bandSize : int = 2
var _highZone : int = 0

var _topTierItem : int = 0
var _topTier : int = 0
var _craftSlot : int = 0
var _craftItemHash : int = 0
var _craftTier : int = 0

# As duas sondas: (conta, char). A zona 0/1 é o controle bit-for-bit; a zona topo é
# onde a torneira explode e onde a banda aperta.
var _acctLow : int = 0
var _charLow : int = 0
var _acctHigh : int = 0
var _charHigh : int = 0

func _initialize():
	_run()

# ------------------------------------------------------------------ contagem (house pattern)

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _checkEq(value : Variant, expected : Variant, label : String) -> bool:
	checks += 1
	if value != expected:
		failures += 1
		print("  [FAIL] %s: %s vs %s" % [label, str(value), str(expected)])
		return false
	return true

func _checkHas(errors : PackedStringArray, needle : String, label : String) -> bool:
	for e in errors:
		if str(e).contains(needle):
			return _check(true, label)
	return _check(false, "%s (esperado achar \"%s\" em %s)" % [label, needle, str(errors)])

func _const(script : GDScript, constantName : String) -> int:
	var raw : Variant = script.get_script_constant_map().get(constantName, null)
	return int(raw) if (raw is int or raw is float) else -1

func _enumValue(script : GDScript, enumName : String, key : String) -> int:
	var raw : Variant = script.get_script_constant_map().get(enumName, {})
	if raw is Dictionary and (raw as Dictionary).has(key):
		return int((raw as Dictionary)[key])
	return -1

func _sourceText(path : String) -> String:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text : String = file.get_as_text()
	file.close()
	return text

# Ocorrências de um trecho literal no fonte — é assim que a régua confere "fonte
# única" sem reimplementar nada: conta os call sites do helper e a presença das
# fórmulas antigas.
func _count(haystack : String, needle : String) -> int:
	var hits : int = 0
	var at : int = haystack.find(needle)
	while at >= 0:
		hits += 1
		at = haystack.find(needle, at + needle.length())
	return hits

# ------------------------------------------------------------------ a curva, lida do produto

func _goldPerHour(zoneID : int) -> int:
	var zone : Object = _farm.call("GetZone", zoneID)
	return int(zone.get("goldPerHour")) if zone != null else -1

func _zoneTier(zoneID : int) -> int:
	var zone : Object = _farm.call("GetZone", zoneID)
	return int(zone.get("tier")) if zone != null else -1

# Os tiers que uma zona ALCANÇA: a banda de drop é [tier, tier + DropTierBandSize - 1]
# (`FarmZoneData.GetDropPool`), e o craft para em 8 porque `SubmitCraft` recusa
# `tier > 8` — nas zonas de tier 9 não há craft alcançável, e a régua diz isso medindo,
# não tapando. Nada aqui é número redigitado: tier, banda e teto vêm das constantes.
func _reachableTiers(zoneID : int, isCraft : bool) -> Array:
	var tier : int = _zoneTier(zoneID)
	if tier < 1:
		return []
	var cap : int = mini(tier + _bandSize - 1, _maxTier)
	if isCraft:
		cap = mini(cap, CraftMaxTier)
	var out : Array = []
	var t : int = tier
	while t <= cap:
		out.append(t)
		t += 1
	return out

func _fee(baseGold : int, tier : int, zoneID : int, permille : int) -> int:
	return int(_forge.call("ForgeFeeForZone", baseGold, tier, zoneID, permille))

# O knob COMO O PRODUTO O LÊ: o estado em runtime do catálogo validado, com o default
# documentado do código de reserva. É esta leitura, e não uma constante copiada aqui,
# que decide a elasticidade da régua.
func _elasticity() -> int:
	return int(_ecoCat.call("BaseKnob", _knobKey, _knobRef))

# ------------------------------------------------------------------ O PREDICADO DA BANDA
# Uma só implementação, chamada pela régua (suite C) e pelo controle negativo (suite G)
# — é isso que faz o plantado morder pelo MESMO caminho. Devolve "" quando o par cabe
# na banda e a acusação nomeada (zona, tier, minutos medidos, taxa, renda) quando não.
func _bandAccusation(zoneID : int, tier : int, fee : int, label : String) -> String:
	var income : int = _goldPerHour(zoneID)
	if income <= 0:
		return "%s: zona %d sem curva de renda medida (goldPerHour %d)" % [label, zoneID, income]
	var minutes : float = 60.0 * float(fee) / float(income)
	var scale : float = pow(float(tier) / float(BandAnchorTier), 2.0)
	var lo : float = BandTier9MinMinutes * scale
	var hi : float = BandTier9MaxMinutes * scale
	if minutes < lo:
		return "%s: ZONA %d TIER %d custa %.2f min de fazenda par, ABAIXO do piso %.2f (taxa %d gold, renda %d gold/h)" % [
			label, zoneID, tier, minutes, lo, fee, income]
	if minutes > hi:
		return "%s: ZONA %d TIER %d custa %.2f min de fazenda par, ACIMA do teto %.2f (taxa %d gold, renda %d gold/h)" % [
			label, zoneID, tier, minutes, hi, fee, income]
	return ""

# Varredura de todo par alcançável das duas pias com a taxa que o chamador fornecer.
# Devolve o número de violações e enche `worst` com o par mais apertado da banda.
func _sweepBand(feeFn : Callable, label : String, worst : Dictionary) -> int:
	var violations : int = 0
	for zoneID in range(1, _maxZone + 1):
		for isCraft : bool in [false, true]:
			for tierVar in _reachableTiers(zoneID, isCraft):
				var tier : int = int(tierVar)
				var base : int = _corruptBase if not isCraft else _craftBase
				var income : int = _goldPerHour(zoneID)
				if income <= 0:
					continue
				var fee : int = int(feeFn.call(base, tier, zoneID))
				var accusation : String = _bandAccusation(zoneID, tier, fee, label)
				var minutes : float = 60.0 * float(fee) / float(income)
				var scale : float = pow(float(tier) / float(BandAnchorTier), 2.0)
				# Folga = distância ao EDGE mais próximo da banda, em fração dos minutos.
				var margin : float = min(minutes - BandTier9MinMinutes * scale,
						BandTier9MaxMinutes * scale - minutes) / max(minutes, 0.001)
				if not worst.has("pair") or margin < float(worst.get("margin", 999.0)):
					worst["margin"] = margin
					worst["pair"] = "zona %d tier %d %s" % [zoneID, tier, "craft" if isCraft else "corrupção"]
					worst["minutes"] = minutes
					worst["fee"] = fee
				if accusation != "":
					violations += 1
					# O plantado viola muitos pares (é o defeito estrutural do achado): os
					# primeiros bastam, o total é o que a asserção conta.
					if violations <= 6:
						print("  [band] " + accusation)
	return violations

# ------------------------------------------------------------------ boot

func _run():
	print("== gold sink scale harness: a taxa de forja lê a zona do personagem (#107) ==")
	_launcher = root.get_node_or_null(^"Launcher")
	if _launcher == null:
		print("FATAL: Launcher autoload missing")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.get("SQL")
		_eco = _launcher.get("Economy")
		if _sql != null and bool(_sql.get("isInitialized")) and _eco != null:
			break
	_dbScript = load("res://sources/db/DB.gd")
	for i in 40:
		if _dbScript != null and bool(_dbScript.get("isInitialized")):
			break
		await create_timer(0.25).timeout
	_forge = load("res://sources/economy/ItemForgeService.gd")
	_farm = load("res://sources/idle/FarmZoneData.gd")
	_craft = load("res://sources/economy/CraftCatalog.gd")
	_ecoCat = load("res://sources/economy/EconomyCatalog.gd")
	_baseCat = load("res://sources/economy/EconomyBaseCatalog.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	_skillCommons = load("res://sources/skill/SkillCommons.gd")
	_networkCommons = load("res://sources/network/NetworkCommons.gd")
	_svc = _eco.get("itemForgeService")
	if not _check(_sql != null and _eco != null and _forge != null and _farm != null
			and _craft != null and _ecoCat != null and _baseCat != null and _svc != null,
			"forja, fazenda e os dois catálogos vivos no boot"):
		_finish()
		return
	_corruptBase = int(_ecoCat.get("CORRUPT_FEE_BASE"))
	_craftBase = int(_craft.get("SUBMIT_FEE_BASE"))
	_knobRef = int(_baseCat.get("ForgeFeeZoneElasticityPermilleRef"))
	_maxZone = int(_farm.call("GetZoneCount"))
	_maxTier = _const(_farm, "MAX_TIER")
	_bandSize = _const(_farm, "DropTierBandSize")
	_highZone = _maxZone
	if not _check(_corruptBase > 0 and _craftBase > 0 and _maxZone > 1 and _maxTier > 0 and _bandSize > 0,
			"constantes lidas por nome (corrupt %d, craft %d, zonas %d, tier %d, banda %d)" % [
				_corruptBase, _craftBase, _maxZone, _maxTier, _bandSize]):
		_finish()
		return
	# O knob tem leitor de VERDADE: o fonte que cobra a taxa nomeia a MESMA chave que o
	# catálogo valida, e está no dicionário dos knobs conhecidos. Sem isto a régua leria
	# um número que nenhum caminho usa (o knob órfão que o validador já recusa na banda).
	var forgeSrc : String = _sourceText("res://sources/economy/ItemForgeService.gd")
	_check(forgeSrc.contains("\"%s\"" % _knobKey),
		"ItemForgeService lê a chave \"%s\" do catálogo (régua e produto falam do mesmo knob)" % _knobKey)
	_check(((_baseCat.get("BASE_KNOBS_REF")) as Dictionary).has(_knobKey),
		"o knob está em BASE_KNOBS_REF (fora dele o validador não o conhece e o arquivo é órfão)")
	# O teto de craft que a régua usa é o que o serviço cobra, conferido no fonte: se
	# `SubmitCraft` vier a aceitar tier 9, esta linha acusa a varredura de ficar atrás.
	_check(forgeSrc.contains("if tier < 1 or tier > 8:"),
		"o teto de craft (%d) é o que o produto valida em SubmitCraft (`tier > 8` → invalid_tier)" % CraftMaxTier)
	# Fonte único, medido no fonte: os DOIS call sites de taxa chamam o mesmo helper, e
	# nenhuma das duas fórmulas antigas sobreviveu solta no serviço — é o que impede a
	# pia de voltar a ser duas contas diferentes e o achado de voltar por outro caminho.
	_checkEq(_count(forgeSrc, "_ForgeFee(charID, "), 2,
		"corrupção e craft passam pelo MESMO helper de taxa (2 call sites de `_ForgeFee`)")
	_checkEq(_count(forgeSrc, "CORRUPT_FEE_BASE * maxi("), 0,
		"a fórmula antiga de corrupção (base × tier² solta) não ficou viva no serviço")
	_checkEq(_count(forgeSrc, "var fee : int = CraftCatalog.SubmitFee(tier)"), 0,
		"a fórmula antiga de craft (SubmitFee cru no call site) não ficou viva no serviço")
	if not _setupFixture():
		_finish()
		return
	_suiteMonotonia()
	_suiteZona1()
	_suiteBanda()
	_suiteKnobDoArquivo()
	_suiteFailClosed()
	_suiteLedger()
	_suitePlantedControls()
	_finish()

func _finish():
	_dropFixture()
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ fixture

func _mkChar(user : String, nick : String, zoneID : int, gold : int) -> Dictionary:
	if not bool(_sql.call("AddAccount", user, "testpass", "%s@test.local" % user,
			_networkCommons.get("AgreementTosVersion"), _networkCommons.get("AgreementPrivacyVersion"), "203.0.113.1")):
		return {}
	var accountID : int = int(_sql.call("GetAccountID", user))
	if not bool(_sql.call("AddCharacter", accountID, nick, _actorCommons.get("DefaultStats"),
			_actorCommons.get("DefaultTraits"), _actorCommons.get("DefaultAttributes"))):
		return {}
	var charID : int = int(_sql.call("GetCharacterID", accountID, nick))
	_sql.call("SetSkill", charID, String(_skillCommons.get("SkillMeleeName")).hash(), 1)
	_sql.db.update_rows("stat", "char_id = %d" % charID, {"gp" = gold})
	_sql.db.update_rows("account", "account_id = %d" % accountID, {"email_verified" = 1})
	if zoneID > 0:
		_sql.db.update_rows("character", "char_id = %d" % charID, {"farm_zone" = zoneID})
	return {"account": accountID, "char": charID}

func _setupFixture() -> bool:
	_sql.db.delete_rows("character", "nickname = 'GssZonaUm'")
	_sql.db.delete_rows("character", "nickname = 'GssZonaTop'")
	_sql.db.delete_rows("account", "username = 'gss_low'")
	_sql.db.delete_rows("account", "username = 'gss_high'")
	# A sonda "zona 1" nasce SEM zona (0): é o estado real de um personagem novo, e é
	# assim que a perna B prova que o default do produto não mudou para quem não ancorou.
	var low : Dictionary = _mkChar("gss_low", "GssZonaUm", 0, 50000000)
	var high : Dictionary = _mkChar("gss_high", "GssZonaTop", _highZone, 50000000)
	if not _check(not low.is_empty() and not high.is_empty(), "os dois chars-sonda existem (zona 0 e zona %d)" % _highZone):
		return false
	_acctLow = int(low.get("account", 0))
	_charLow = int(low.get("char", 0))
	_acctHigh = int(high.get("account", 0))
	_charHigh = int(high.get("char", 0))
	if not _checkEq(int((_sql.call("GetCharacter", _charHigh) as Dictionary).get("farm_zone", 0)), _highZone,
			"a sonda de topo está ancorada na zona do fim da curva"):
		return false
	# Equipamento do maior tier que o catálogo tem célula: é o par que a banda aperta,
	# resolvido por varredura (nome de célula não é contrato).
	var items : Dictionary = _dbScript.get("ItemsDB")
	var noneSlot : int = _enumValue(_actorCommons, "Slot", "NONE")
	for cellHash in items.keys():
		var cell : Object = items.get(int(cellHash), null)
		if cell == null or int(cellHash) <= 0:
			continue
		var slot : int = int(cell.get("slot"))
		if slot == noneSlot or slot < 0:
			continue
		if int(cell.get("tier")) > _topTier:
			_topTier = int(cell.get("tier"))
			_topTierItem = int(cellHash)
	if not _check(_topTierItem != 0 and _topTier >= 2, "há célula de equipamento de tier alto no catálogo (tier %d)" % _topTier):
		return false
	# Base de craft: (tier, slot) com `BudgetCap` > 0, célula real E matéria-prima
	# declarada na faixa — os três predicados que `SubmitCraft` cobra, na ordem em que
	# ele os cobra. Do topo para baixo, para medir a pia mais cara que existe.
	_craftSlot = _enumValue(_actorCommons, "Slot", "WEAPON")
	for craftTier : int in range(CraftMaxTier, 0, -1):
		if _matHashFor(craftTier) == int(_dbScript.get("UnknownHash")):
			continue
		if int(_craft.call("MaterialPerCraft", craftTier)) <= 0:
			continue
		for cellHash in items.keys():
			var cell : Object = items.get(int(cellHash), null)
			if cell == null or int(cellHash) <= 0:
				continue
			if int(cell.get("slot")) != _craftSlot or int(cell.get("tier")) != craftTier:
				continue
			if int(_craft.call("BudgetCap", craftTier, _craftSlot)) <= 0:
				continue
			_craftItemHash = int(cellHash)
			_craftTier = craftTier
			break
		if _craftItemHash != 0:
			break
	if not _check(_craftItemHash != 0 and _craftTier > 0, "há base craftável com material na faixa (tier %d)" % _craftTier):
		return false
	_grantItem(_charLow)
	_grantItem(_charHigh)
	_grantMaterial(_charLow)
	_grantMaterial(_charHigh)
	return true

func _grantItem(charID : int) -> void:
	_sql.call("AddItemToCharacter", charID, _topTierItem, 1, "gss_fixture")

func _matHashFor(tier : int) -> int:
	return int(_farm.call("GetBandMaterialHash", tier))

func _matHash() -> int:
	return _matHashFor(_craftTier)

func _grantMaterial(charID : int) -> void:
	var mat : int = _matHash()
	if mat != int(_dbScript.get("UnknownHash")):
		_sql.call("AddItemToCharacter", charID, mat, int(_craft.call("MaterialPerCraft", _craftTier)) + 2, "gss_fixture")

func _dropFixture():
	if _sql == null or not is_instance_valid(_sql) or not bool(_sql.get("isInitialized")):
		return
	# `ledger_transaction` é append-only (009_idle_economy.sql: `ledger_transaction_no_delete`),
	# e as contas são novas a cada run: a série de gold de cada sonda é só desta passada,
	# que é exatamente o que a perna F exige. Apagar as linhas é o que a suíte pode apagar.
	_sql.db.delete_rows("craft_submission", "account_id = %d OR account_id = %d" % [_acctLow, _acctHigh])
	_sql.db.delete_rows("craft_item_template", "creator_account_id = %d OR creator_account_id = %d" % [_acctLow, _acctHigh])
	_sql.db.delete_rows("item", "char_id = %d OR char_id = %d" % [_charLow, _charHigh])
	_sql.DeleteRowsRaw("item_instance", "char_id = %d OR char_id = %d" % [_charLow, _charHigh])
	_sql.db.delete_rows("character", "char_id = %d OR char_id = %d" % [_charLow, _charHigh])
	_sql.db.delete_rows("account", "account_id = %d OR account_id = %d" % [_acctLow, _acctHigh])

# ------------------------------------------------------------------ leituras do produto

func _gp(charID : int) -> int:
	var rows : Array = _sql.db.select_rows("stat", "char_id = %d" % charID, ["gp"])
	return int(rows[0]["gp"]) if not rows.is_empty() and rows[0].get("gp", null) != null else 0

# A taxa que o PRODUTO cobraria deste char: a zona vem do `character` no banco e a
# elasticidade do catálogo validado — o mesmo caminho dos dois call sites de forja.
func _chargedFee(charID : int, baseGold : int, tier : int) -> int:
	return int(_svc.call("_ForgeFee", charID, baseGold, tier))

# Doc do repo com a elasticidade que o chamador escolher (banda inclusa). A metade de
# loja é copiada do arquivo real, então o único grau de liberdade é o knob sob prova.
func _shippedDoc() -> Dictionary:
	var parsed : Variant = JSON.parse_string(FileAccess.get_file_as_string(_baseCat.get("BaseCatalogPath")))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _docWithElasticity(value : Variant, bandLo : int, bandHi : int) -> String:
	var doc : Dictionary = _shippedDoc()
	if doc.is_empty():
		return ""
	var knobs : Dictionary = doc.get("knobs", {})
	knobs[_knobKey] = value
	doc["knobs"] = knobs
	var ranges : Dictionary = doc.get("_knob_ranges", {})
	ranges[_knobKey] = {"min": bandLo, "max": bandHi}
	doc["_knob_ranges"] = ranges
	return JSON.stringify(doc)

func _docWithoutKnob() -> String:
	var doc : Dictionary = _shippedDoc()
	if doc.is_empty():
		return ""
	var knobs : Dictionary = doc.get("knobs", {})
	knobs.erase(_knobKey)
	doc["knobs"] = knobs
	return JSON.stringify(doc)

func _bandFromDoc() -> Dictionary:
	return (_shippedDoc().get("_knob_ranges", {}) as Dictionary).get(_knobKey, {})

func _bandLoFromDoc() -> int:
	return int(_bandFromDoc().get("min", -1))

func _bandHiFromDoc() -> int:
	return int(_bandFromDoc().get("max", -1))

func _apply(raw : String) -> PackedStringArray:
	var errors : PackedStringArray = _ecoCat.call("ApplyBaseCatalog", raw)
	return errors

# Volta ao estado do boot: o congelado do código e por cima o arquivo do repo.
func _reset() -> void:
	_ecoCat.call("ResetBaseCatalog")
	_apply(FileAccess.get_file_as_string(_baseCat.get("BaseCatalogPath")))

# ------------------------------------------------------------------ A: monotonicidade

func _suiteMonotonia():
	print("[suite] A: no mesmo tier a taxa cresce com a zona — medida na curva real do FarmZoneData")
	var permille : int = _elasticity()
	_check(permille > 0, "a elasticidade efetiva é positiva (%d permille)" % permille)
	var steps : int = 0
	var regress : int = 0
	for tierVar in [1, 2, 5, _topTier]:
		var tier : int = int(tierVar)
		var previous : int = -1
		for zoneID in range(1, _maxZone + 1):
			var fee : int = _fee(_corruptBase, tier, zoneID, permille)
			if previous >= 0:
				if fee > previous:
					steps += 1
				else:
					regress += 1
					print("  [FAIL] tier %d: zona %d cobra %d, zona %d cobrava %d" % [tier, zoneID, fee, zoneID - 1, previous])
			previous = fee
	_checkEq(regress, 0, "a taxa de corrupção é estritamente crescente zona a zona em todo tier sondado (%d passos)" % steps)
	var lowFee : int = _fee(_corruptBase, _topTier, 1, permille)
	var highFee : int = _fee(_corruptBase, _topTier, _highZone, permille)
	_check(highFee > lowFee, "tier %d: zona %d cobra %d > zona 1 cobra %d" % [_topTier, _highZone, highFee, lowFee])
	var lowCraft : int = _fee(_craftBase, _craftTier, 1, permille)
	var highCraft : int = _fee(_craftBase, _craftTier, _highZone, permille)
	_check(highCraft > lowCraft, "craft tier %d: zona %d cobra %d > zona 1 cobra %d" % [_craftTier, _highZone, highCraft, lowCraft])
	# E no caminho do produto, com dois chars reais: a zona vem do banco, não do argumento.
	var chargedLow : int = _chargedFee(_charLow, _corruptBase, _topTier)
	var chargedHigh : int = _chargedFee(_charHigh, _corruptBase, _topTier)
	_check(chargedHigh > chargedLow, "pagando de verdade: char da zona %d paga %d, char da zona 1 paga %d" % [
		_highZone, chargedHigh, chargedLow])
	_checkEq(chargedHigh, highFee, "o char da zona topo paga exatamente a fórmula da curva (leitura de zona sem torta)")
	_checkEq(chargedLow, lowFee, "o char sem zona paga exatamente a fórmula da zona 1")
	# Monotonia no outro eixo também: mais tier ⇒ mais taxa, na mesma zona.
	var tierUp : int = 0
	for t in range(2, _topTier + 1):
		if _fee(_corruptBase, t, _highZone, permille) > _fee(_corruptBase, t - 1, _highZone, permille):
			tierUp += 1
	_checkEq(tierUp, _topTier - 1, "a taxa é estritamente crescente em tier na zona topo (%d passos)" % tierUp)

# ------------------------------------------------------------------ B: zona 1 bit-for-bit

func _suiteZona1():
	print("[suite] B: a zona 1 paga exatamente as constantes de antes, bit for bit")
	var probes : Array = [_knobRef, _bandLoFromDoc(), _bandHiFromDoc(), 1000]
	for probeVar in probes:
		var probe : int = int(probeVar)
		for tierVar in range(1, _maxTier + 1):
			var tier : int = int(tierVar)
			var expected : int = _corruptBase * tier * tier
			_checkEq(_fee(_corruptBase, tier, 1, probe), expected,
				"corrupção tier %d na zona 1 com elasticidade %d == CORRUPT_FEE_BASE × tier² (%d)" % [tier, probe, expected])
		for craftTierVar in range(1, CraftMaxTier + 1):
			var craftTier : int = int(craftTierVar)
			var expectedCraft : int = int(_craft.call("SubmitFee", craftTier))
			_checkEq(_fee(_craftBase, craftTier, 1, probe), expectedCraft,
				"craft tier %d na zona 1 com elasticidade %d == SubmitFee(tier) (%d)" % [craftTier, probe, expectedCraft])
	# Char sem zona (0) no produto: é `IdleTests` quem já confere isto no tier 1; aqui é
	# no tier topo do catálogo, com o ouro saindo de `stat.gp` de verdade (perna F).
	_checkEq(_chargedFee(_charLow, _corruptBase, _topTier), _corruptBase * _topTier * _topTier,
		"char sem zona ancora na 1 e paga %d gold de corrupção (a constante velha)" % (_corruptBase * _topTier * _topTier))
	_checkEq(_chargedFee(_charLow, _craftBase, _craftTier), int(_craft.SubmitFee(_craftTier)),
		"char sem zona paga no craft o SubmitFee de sempre (%d)" % int(_craft.SubmitFee(_craftTier)))
	var one : Dictionary = _mkChar("gss_z1", "GssZonaUnica", 1, 50000000)
	if _check(not one.is_empty(), "char com farm_zone = 1 declarada criado"):
		_checkEq(_chargedFee(int(one.get("char", 0)), _corruptBase, _topTier), _corruptBase * _topTier * _topTier,
			"zona 1 explícita == constante de antes (a âncora da curva é a própria zona 1, %d gold/h)" % _goldPerHour(1))
		_sql.db.delete_rows("character", "char_id = %d" % int(one.get("char", 0)))
		_sql.db.delete_rows("account", "account_id = %d" % int(one.get("account", 0)))

# ------------------------------------------------------------------ C: a banda

func _suiteBanda():
	print("[suite] C: minutos de fazenda par por ação de forja, em todo par alcançável")
	var permille : int = _elasticity()
	var lo : int = _bandLoFromDoc()
	var hi : int = _bandHiFromDoc()
	_check(lo > 0 and hi >= lo, "a banda do arquivo está declarada [%d, %d]" % [lo, hi])
	_check(permille >= lo and permille <= hi, "a elasticidade efetiva (%d) cabe na banda do arquivo [%d, %d]" % [permille, lo, hi])
	print("  zona | tier |    gold/h |   taxa antes | min antes |   taxa depois | min depois")
	for zoneID in range(1, _maxZone + 1):
		var tiers : Array = _reachableTiers(zoneID, false)
		var topReachable : int = int(tiers[tiers.size() - 1]) if not tiers.is_empty() else 1
		var income : int = _goldPerHour(zoneID)
		var before : int = _fee(_corruptBase, topReachable, zoneID, 0)
		var after : int = _fee(_corruptBase, topReachable, zoneID, permille)
		print("  %4d | %4d | %9d | %12d | %9.2f | %13d | %10.2f" % [
			zoneID, topReachable, income, before, 60.0 * float(before) / float(income),
			after, 60.0 * float(after) / float(income)])
	var scaled : Callable = func(baseGold : int, tier : int, zoneID : int) -> int:
		return _fee(baseGold, tier, zoneID, permille)
	var worst : Dictionary = {}
	var violations : int = _sweepBand(scaled, "banda", worst)
	_checkEq(violations, 0, "todo par (zona, tier) alcançável cabe na banda [%.0f, %.0f] min no tier 9" % [
		BandTier9MinMinutes, BandTier9MaxMinutes])
	print("  [pior caso] par mais apertado da banda: %s — taxa %d gold, %.2f min de fazenda par (folga %.1f%%)" % [
		str(worst.get("pair", "?")), int(worst.get("fee", 0)), float(worst.get("minutes", 0.0)),
		100.0 * float(worst.get("margin", 0.0))])
	# O default é o MENOR inteiro dentro da banda, medido: a aresta passa e o vizinho de
	# baixo já fura o piso. É a prova de que o número veio da conta, não do teclado.
	_checkEq(_sweepZero(lo), 0, "a aresta declarada (%d permille) cabe na banda do produto" % lo)
	# Exatamente UM par decide a aresta: é o da maior renda por hora da tabela. Se a
	# curva mudar de forma, este número muda junto e a régua pergunta de novo.
	_checkEq(_sweepZero(lo - 1), 1, "elasticidade %d (um abaixo da aresta) fura a banda em 1 par (zona topo, tier 9) — %d é o menor que passa" % [
		lo - 1, lo])
	# A outra aresta, medida pelo MESMO predicado: sem estas duas pernas o `max` do arquivo
	# seria um número digitado, e o registro não poderia dizer que a banda é justa.
	_checkEq(_sweepZero(hi), 0, "a aresta de topo declarada (%d permille) cabe na banda do produto" % hi)
	_checkEq(_sweepZero(hi + 1), 1, "elasticidade %d (um acima da aresta) estoura o teto em 1 par (zona topo, tier 9) — %d é o maior que passa" % [
		hi + 1, hi])
	# As duas arestas decidem no MESMO par, e isto é medido, não afirmado: o pior caso do
	# piso e o pior caso do topo têm de ser a mesma célula da tabela, porque é a zona de
	# maior renda que encosta nos dois limites ao mesmo tempo.
	var loWorst : Dictionary = {}
	var hiWorst : Dictionary = {}
	_sweepZeroInto(lo, loWorst)
	_sweepZeroInto(hi, hiWorst)
	_checkEq(str(loWorst.get("pair", "?")), str(hiWorst.get("pair", "?")),
		"piso e topo são decididos pelo mesmo par: %s" % str(loWorst.get("pair", "?")))

# Varre a banda com uma elasticidade fixa e devolve o NÚMERO de pares fora dela.
func _sweepZero(permille : int) -> int:
	var probe : Callable = func(baseGold : int, tier : int, zoneID : int) -> int:
		return _fee(baseGold, tier, zoneID, permille)
	return _sweepBand(probe, "sonda %d" % permille, {})

# A mesma varredura, mas devolvendo o par mais apertado em `worst`: é assim que as duas
# arestas da banda são comparadas célula a célula, sem reimplementar o predicado aqui.
func _sweepZeroInto(permille : int, worst : Dictionary) -> int:
	var probe : Callable = func(baseGold : int, tier : int, zoneID : int) -> int:
		return _fee(baseGold, tier, zoneID, permille)
	return _sweepBand(probe, "aresta %d" % permille, worst)

# ------------------------------------------------------------------ D: o knob vem do arquivo

func _suiteKnobDoArquivo():
	print("[suite] D: a elasticidade é lida de data/conf/economy_base_catalog.json")
	var shipped : int = _elasticity()
	var feeShipped : int = _chargedFee(_charHigh, _corruptBase, _topTier)
	var lo : int = _bandLoFromDoc()
	var hi : int = _bandHiFromDoc()
	_check(hi > shipped, "o teto da banda (%d) difere do default (%d) — a sonda abaixo muda alguma coisa" % [hi, shipped])
	var errors : PackedStringArray = _apply(_docWithElasticity(hi, lo, hi))
	_checkEq(errors.size(), 0, "elasticidade %d dentro da banda [%d, %d] aplica limpa: %s" % [hi, lo, hi, str(errors)])
	_checkEq(_elasticity(), hi, "ApplyBaseCatalog pôs o valor do arquivo no estado em runtime (o mesmo que o boot usa)")
	var feeTop : int = _chargedFee(_charHigh, _corruptBase, _topTier)
	_check(feeTop > feeShipped, "com o arquivo em %d a taxa COBRADA sobe (%d > %d): o knob é alavanca, não comentário" % [
		hi, feeTop, feeShipped])
	_checkEq(feeTop, _fee(_corruptBase, _topTier, _highZone, hi),
		"e sobe exatamente para a fórmula da curva com o valor lido do arquivo")
	_checkEq(_chargedFee(_charLow, _corruptBase, _topTier), _corruptBase * _topTier * _topTier,
		"mesmo com o knob no teto, a zona 1 não se move (a âncora não é knob)")
	# Fora da banda: recusa com o erro do PRÓPRIO validador, e nada do arquivo entra.
	var outErrors : PackedStringArray = _apply(_docWithElasticity(hi + 1, lo, hi))
	_check(outErrors.size() > 0, "elasticidade %d acima da banda [%d, %d] é RECUSADA (%d erros)" % [hi + 1, lo, hi, outErrors.size()])
	_checkHas(outErrors, "fora da banda", "a recusa usa a mensagem do validador de bandas, não um erro novo da régua")
	_checkHas(outErrors, _knobKey, "e o erro nomeia o knob que passou da faixa")
	_checkEq(_elasticity(), hi, "arquivo recusado NÃO sobrescreve o estado (a última aplicação boa continua de pé)")
	_checkEq(_chargedFee(_charHigh, _corruptBase, _topTier), feeTop, "e a taxa cobrada não se moveu com o número recusado")
	_reset()
	_checkEq(_elasticity(), shipped, "ResetBaseCatalog devolve o valor do arquivo do repo (%d)" % shipped)
	_checkEq(_chargedFee(_charHigh, _corruptBase, _topTier), feeShipped, "e a taxa do produto volta ao valor de antes da sonda")

# ------------------------------------------------------------------ E: fail-closed

func _suiteFailClosed():
	print("[suite] E: knob ausente ou não-inteiro é fail-closed, nunca default silencioso")
	var shipped : int = _elasticity()
	var feeShipped : int = _chargedFee(_charHigh, _corruptBase, _topTier)
	# (a) sumiu do arquivo: o validador tem de nomear o sumiço — é o que impede o default
	# do código mandar sozinho sem ninguém declarar (o `_IntOf` do SeasonConfig).
	var missingErrors : PackedStringArray = _apply(_docWithoutKnob())
	_checkHas(missingErrors, "sumiu do arquivo", "knob apagado do arquivo é recusado pelo nome")
	_checkHas(missingErrors, _knobKey, "e a acusação diz qual knob sumiu")
	_checkEq(_elasticity(), shipped, "o arquivo recusado não trocou o estado por default silencioso")
	_checkEq(_chargedFee(_charHigh, _corruptBase, _topTier), feeShipped, "e o preço cobrado não se moveu")
	# (b) não-inteiro: float de verdade e string — os dois ramos que o validador cobra.
	var fracErrors : PackedStringArray = _apply(_docWithElasticity(float(shipped) + 0.5, _bandLoFromDoc(), _bandHiFromDoc()))
	_checkHas(fracErrors, "tem que ser inteiro", "elasticidade 886.5 é recusada (o validador só admite inteiro)")
	var strErrors : PackedStringArray = _apply(_docWithElasticity("%d" % shipped, _bandLoFromDoc(), _bandHiFromDoc()))
	_checkHas(strErrors, "tem que ser número inteiro", "elasticidade como string é recusada")
	_checkEq(_elasticity(), shipped, "nem o float nem a string entraram no estado em runtime")
	_checkEq(_chargedFee(_charHigh, _corruptBase, _topTier), feeShipped, "e nenhuma das duas entrou no preço")
	# (c) zero fricção é a fórmula antiga disfarçada de rebalance.
	var zeroErrors : PackedStringArray = _apply(_docWithElasticity(0, _bandLoFromDoc(), _bandHiFromDoc()))
	_check(zeroErrors.size() > 0, "elasticidade 0 (a taxa de antes do corte) é recusada pela banda [%d, %d]" % [
		_bandLoFromDoc(), _bandHiFromDoc()])
	_checkEq(_chargedFee(_charHigh, _corruptBase, _topTier), feeShipped, "e a taxa do produto continua escalada")
	# (d) sem banda declarada para o knob: fail-closed pela mesma razão de sempre.
	var doc : Dictionary = _shippedDoc()
	(doc.get("_knob_ranges", {}) as Dictionary).erase(_knobKey)
	var noBandErrors : PackedStringArray = _apply(JSON.stringify(doc))
	_checkHas(noBandErrors, "sem banda declarada", "knob sem banda no arquivo é recusado (o validador não adivinha teto)")
	_checkEq(_elasticity(), shipped, "e o estado continua o do último arquivo bom")
	_reset()
	_checkEq(_elasticity(), shipped, "estado consertado no fim da perna E (%d)" % shipped)

# ------------------------------------------------------------------ F: ledger

func _suiteLedger():
	print("[suite] F: paga a taxa escalada, o ledger de gold ainda fecha linha a linha")
	var permille : int = _elasticity()
	var feeMod : float = float(_eco.call("GetLiveEventCraftingFeeMod"))
	var originHigh : int = _gp(_charHigh)
	var originLow : int = _gp(_charLow)
	# As sondas são recém-criadas e o ouro entrou por escritura direta de `stat.gp`
	# (fixture), então a série de gold delas é TODA desta passada — é o que dá à
	# conservação abaixo o direito de somar do zero.
	_checkEq(_goldRows(_charHigh).size(), 0, "o char da zona topo entra na perna F sem nenhum lançamento de gold")
	_checkEq(_goldRows(_charLow).size(), 0, "o char da zona 1 entra na perna F sem nenhum lançamento de gold")
	# Corrupção do char da zona topo: a taxa é a da curva, e o evento ao vivo (kind
	# `smith_week`) só modula o CRAFT — a corrupção não passa por ele.
	var expectedCorrupt : int = _fee(_corruptBase, _topTier, _highZone, permille)
	var brick : Dictionary = _eco.call("CorruptItem", _charHigh, _topTierItem, "brick")
	if not _check(bool(brick.get("ok", false)), "a corrupção do char da zona %d passou (%s)" % [
			_highZone, str(brick.get("reason", ""))]):
		return
	_checkEq(originHigh - _gp(_charHigh), expectedCorrupt,
		"saiu do char exatamente a taxa escalada (%d gold = %d × tier %d² × fator da zona %d)" % [
			expectedCorrupt, _corruptBase, _topTier, _highZone])
	var corruptRow : Dictionary = _lastLedger(_charHigh, "corrupt_fee:")
	if not _check(not corruptRow.is_empty(), "existe linha de ledger `corrupt_fee:<item>` no char da zona topo"):
		return
	_checkEq(str(corruptRow.get("kind", "")), "gold", "a pia continua no kind `gold` (motivo preservado, não renomeado)")
	_checkEq(int(corruptRow.get("amount", 0)), -expectedCorrupt,
		"e o valor é DÉBITO exato da taxa escalada (%s vs -%d)" % [str(corruptRow.get("amount", 0)), expectedCorrupt])
	_check(str(corruptRow.get("reason", "")).contains("corrupt_fee:%d" % _topTierItem),
		"a reason string continua `corrupt_fee:<item>`: %s" % str(corruptRow.get("reason", "")))
	# Craft do mesmo char, pelo caminho do produto, com a matéria-prima da faixa.
	_grantMaterial(_charHigh)
	var craftOrigin : int = _gp(_charHigh)
	var expectedCraft : int = maxi(1, roundi(float(_fee(_craftBase, _craftTier, _highZone, permille)) * feeMod))
	var sub : Dictionary = _eco.call("SubmitCraft", _charHigh, _acctHigh, _craftSlot, _craftItemHash,
		"Gss ZonaTopo Um", {"PoisonPower": 1})
	if not _check(bool(sub.get("ok", false)), "a submissão do char da zona topo passou (%s)" % str(sub.get("reason", ""))):
		_check(false, "sem craft pago a perna F fica incompleta (motivo acima)")
	else:
		_checkEq(craftOrigin - _gp(_charHigh), expectedCraft,
			"o craft cobrou a taxa escalada da zona do char (%d gold, mod de evento ao vivo %.2f)" % [expectedCraft, feeMod])
		var craftRow : Dictionary = _lastLedger(_charHigh, "craft_submit_fee:")
		_check(not craftRow.is_empty(), "existe linha de ledger `craft_submit_fee:tier...` no char da zona topo")
		_checkEq(str(craftRow.get("kind", "")), "gold", "o craft continua pia de gold no ledger")
		_checkEq(int(craftRow.get("amount", 0)), -expectedCraft,
			"e o débito é a taxa escalada (%s vs -%d)" % [str(craftRow.get("amount", 0)), expectedCraft])
		_check(str(craftRow.get("reason", "")).begins_with("craft_submit_fee:tier"),
			"a reason string continua `craft_submit_fee:tier<slot>`: %s" % str(craftRow.get("reason", "")))
	_chain(originHigh, _charHigh, "char da zona %d" % _highZone)
	# E o char da zona 1, pagando o preço de sempre: a série dele também tem de fechar.
	var lowFeeExpected : int = _corruptBase * _topTier * _topTier
	var lowBrick : Dictionary = _eco.call("CorruptItem", _charLow, _topTierItem, "brick")
	if _check(bool(lowBrick.get("ok", false)), "a corrupção do char da zona 1 passou (%s)" % str(lowBrick.get("reason", ""))):
		_checkEq(originLow - _gp(_charLow), lowFeeExpected, "o char da zona 1 pagou a constante de antes (%d)" % lowFeeExpected)
	_chain(originLow, _charLow, "char da zona 1")

func _lastLedger(charID : int, reasonPrefix : String) -> Dictionary:
	var rows : Array[Dictionary] = _sql.QueryBindings(
			"SELECT kind, amount, balance_after, reason FROM ledger_transaction WHERE char_id = ? AND reason LIKE ? ORDER BY id DESC LIMIT 1;",
			[charID, "%s%%" % reasonPrefix])
	return rows[0] if not rows.is_empty() else {}

func _goldRows(charID : int) -> Array[Dictionary]:
	return _sql.QueryBindings(
			"SELECT amount, balance_after FROM ledger_transaction WHERE char_id = ? AND kind = 'gold' ORDER BY id;", [charID])

# Conservação da série de gold do char: nenhum lançamento de pia pode ser crédito, o
# encadeamento `balance_after` tem de fechar com a carteira e `origem + Σ == carteira`.
func _chain(origin : int, charID : int, label : String) -> void:
	var rows : Array[Dictionary] = _goldRows(charID)
	var positives : int = 0
	var broken : int = 0
	var sum : int = 0
	var lastAfter : int = origin
	for row in rows:
		var amount : int = int(row.get("amount", 0))
		var after : int = int(row.get("balance_after", 0))
		if amount > 0:
			positives += 1
		if lastAfter + amount != after:
			broken += 1
			print("  [FAIL] %s: linha não encadeia (%d + %d != %d)" % [label, lastAfter, amount, after])
		lastAfter = after
		sum += amount
	_checkEq(positives, 0, "%s: nenhuma linha de pia de gold da série é crédito (%d linhas)" % [label, rows.size()])
	_checkEq(broken, 0, "%s: encadeamento `balance_after` fecha linha a linha" % label)
	_checkEq(origin + sum, _gp(charID), "%s: origem %d + Σ lançamentos %d == carteira %d" % [label, origin, sum, _gp(charID)])
	_checkEq(lastAfter, _gp(charID), "%s: o último balance_after É a carteira atual" % label)

# ------------------------------------------------------------------ G: controles plantados

# O house pattern de `faucet_census_test._suitePlantedControls`: plantar o estado
# quebrado, rodar o MESMO predicado, exigir que ele acuse por nome, e reparar.
func _suitePlantedControls() -> void:
	print("[suite] G: controles negativos plantados — a régua tem que morder")
	var permille : int = _elasticity()
	# (a) A FÓRMULA DE ANTES DO CORTE plantada: `base × tier²` cru, sem fator de zona.
	# É exatamente o achado #107; a varredura tem de voltar VERMELHA nela.
	var unscaled : Callable = func(baseGold : int, tier : int, zoneID : int) -> int:
		return baseGold * maxi(tier, 1) * maxi(tier, 1)
	var plantedWorst : Dictionary = {}
	var violations : int = _sweepBand(unscaled, "PLANTADO taxa sem fator de zona", plantedWorst)
	_check(violations > 0, "o plantado volta VERMELHO: a fórmula sem fator de zona viola a banda em %d pares" % violations)
	var accusation : String = _bandAccusation(_highZone, _topTier, _corruptBase * _topTier * _topTier, "PLANTADO")
	_check(accusation != "", "e a acusação nomeia o par do achado #107 (zona %d tier %d)" % [_highZone, _topTier])
	if accusation != "":
		print("  [planted] " + accusation)
	_check(accusation.contains("ABAIXO do piso"),
		"a acusação diz o motivo CERTO: o sumidouro encolheu em tempo de fazenda, não cresceu")
	print("  [planted] pior caso do estado antigo: %s — %.2f min" % [str(plantedWorst.get("pair", "?")), float(plantedWorst.get("minutes", 0.0))])
	# (b) O KNOB MORTO: elasticidade 0 pela função pura é o mesmo defeito por outro
	# caminho (o helper que esquece de multiplicar). Tem de doer igual.
	var dead : Callable = func(baseGold : int, tier : int, zoneID : int) -> int:
		return _fee(baseGold, tier, zoneID, 0)
	_checkEq(_sweepBand(dead, "PLANTADO elasticidade 0", {}), violations,
		"elasticidade 0 viola a banda exatamente nos mesmos %d pares da fórmula crua" % violations)
	_checkEq(_fee(_corruptBase, _topTier, _highZone, 0), _corruptBase * _topTier * _topTier,
		"e devolve o número antigo intocado (%d) — é o estado que o plantado reproduz" % (_corruptBase * _topTier * _topTier))
	# (c) ZONA ERRADA: se o fator fosse aplicado também na zona 1 (leitura torta da
	# âncora), a régua da perna B tem de acusar — o que exige que os dois números sejam
	# diferentes por medição, não por construção da régua.
	_check(_fee(_corruptBase, _topTier, _highZone, permille) != _corruptBase * _topTier * _topTier,
		"a régua da zona 1 tem dentes: taxa da zona topo != constante, então zona lida torta apareceria")
	# (d) O PLANTADO DE ARQUIVO: uma banda larga o bastante para deixar 0 entrar
	# deixaria a fórmula antiga voltar sem ninguém notar. A do repo recusa.
	var zeroErrors : PackedStringArray = _apply(_docWithElasticity(0, 1, _bandHiFromDoc()))
	_check(zeroErrors.size() > 0, "com a banda aberta em 1 o valor 0 ainda é recusado (zero fricção é faucet gratuito)")
	# Repara: o MESMO predicado, no estado consertado, volta verde. É a prova de que o
	# vermelho acima veio do plantado e não de um predicado sempre-falso.
	_reset()
	var repaired : Callable = func(baseGold : int, tier : int, zoneID : int) -> int:
		return _fee(baseGold, tier, zoneID, _elasticity())
	_checkEq(_sweepBand(repaired, "DEPOIS da reparação", {}), 0,
		"reparado, o MESMO predicado volta a dizer 0 violações — quem mordeu foi a emenda")
	_checkEq(_chargedFee(_charHigh, _corruptBase, _topTier), _fee(_corruptBase, _topTier, _highZone, permille),
		"e o produto cobra de novo a taxa escalada da zona do char")
