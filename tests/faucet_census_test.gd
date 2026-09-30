extends SceneTree

# gate-marker: == RESULT:

# faucet_census_test.gd — censo de torneira e pia (gold sink), medido do ledger e
# do estado do banco.
#
# Uso:  bash scripts/test.sh one faucet_census_test 300
# Saída: "== RESULT: <n> checks, <m> failures =="  (exit code = <m>)
#
# Por que existe: `ReconcileWalletDaily` lê UMA direção — a carteira ABAIXO do que
# o ledger atesta. Um faucet que escreve `stat.gp` e a linha de ledger juntos sobe
# as duas pernas e passa limpo por construção; nada no repo somava a expansão
# líquida de oferta contra as pias enumeráveis (forja, vendor, guilda, chave de
# boss, taxa de torneio, taxa de anúncio). `EconomyKernel.CensusSupply` soma, por
# FAMÍLIA de `reason`, e confronta banco × ledger nas duas direções. Este harness é
# o que torna isso uma régua:
#   C1 — funil conservado: para a população limpa, `Σ amount == último
#        balance_after == carteira`, dono a dono, e `unattested == 0`.
#   C2 — censo não é vazio: as pias do catálogo aparecem com `destroyed > 0` e com
#        valor MEDIDO (nada aqui é número digitado na doc).
#   C3 — mundo fechado: o catálogo do kernel cobre os escritores do produto, e a
#        cobertura é conferida LENDO `sources/` (controle negativo do próprio
#        extrator: ele tem que achar famílias conhecidas).
#   C4 — controles negativos plantados: faucet cru sem ledger, faucet cru COM
#        ledger (o caso que a régua antiga não vê — e o harness mede
#        `ReconcileWalletDaily` dizendo 0 nele), pia crua sem ledger (sinal
#        trocado) e faucet cru de gemas. Todos mordem pelo mesmo predicado que C1
#        usa, e a sonda é reparada no fim para não deixar envenenamento no sandbox.

const ProbeGoldFaucetNoLedger : int = 7000
const ProbeGoldFaucetWithLedger : int = 4000
const ProbeGoldSinkNoLedger : int = 3000
const ProbeGemsFaucetNoLedger : int = 500
# Famílias de endowment do harness. Não são pias do produto e por isso entram como
# `declared` na chamada do censo: o censo continua somando e listando cada uma
# (isto é conferido por valor), apenas não toca o alarme de família desconhecida.
const FixtureFamilies : PackedStringArray = ["fc_mint", "fc_gems_mint"]
# As pias que a auditoria nomeou. `death_tax` NÃO está aqui de propósito: a taxa de
# 5% do settle offline entra diluída no crédito `offline_settle` e não tem linha
# própria — o censo não pode enumerar o que o funil não registra, e isso é achado
# aberto, não régua.
const NamedSinks : PackedStringArray = [
	"vendor", "boss_key_buy", "guild_create", "tournament_entry", "craft_submit_fee", "ah_list_fee"]

var checks : int = 0
var failures : int = 0
var _launcher : Node
var _sql : Node
var _eco : Node
var _chars : Array = []
var _accounts : Array = []
var _gold : Dictionary = {}
var _gems : Dictionary = {}

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _initialize():
	print("== Censo faucet/pia (EconomyKernel.CensusSupply) ==")
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	if _launcher == null:
		print("FATAL: autoload Launcher ausente")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.get("SQL")
		_eco = _launcher.get("Economy")
		if _sql != null and _eco != null \
				and bool(_sql.get("isInitialized")) and bool(_eco.get("isInitialized")):
			break
	if _sql == null or _eco == null or not bool(_sql.get("isInitialized")):
		print("FATAL: SQL/Economy não inicializaram")
		quit(1)
		return
	# O catálogo de conteúdo NÃO sobe junto com `SQL.isInitialized`: `DB.Preload()`
	# empilha os `load_threaded_request` (`sources/db/DB.gd:224`) e o `PreloadUpdate()`
	# (`sources/db/DB.gd:233-235`) fecha o preload, chama `Load()` e acende `isInitialized`,
	# re-armado a cada `process_frame` — portanto precisa de FRAMES. Esperar só o SQL e medir com o
	# catálogo ainda vazio: aqui os frames caem antes do `quit()`, no runner da CI não,
	# e o MESMO run vale ~30 ou ~1700 objetos conforme a máquina. O check nomeado é o
	# ponto — boot leve é vermelho visível, não medição parcial silenciosa.
	# Padrão de tests/content_hygiene_test.gd.
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 80:
		if bool(dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (entities/maps/items carregados)"):
		print("== RESULT: %d checks, %d failures ==" % [checks, failures])
		var dbAbort : Node = _launcher.get("DB")
		if dbAbort != null:
			dbAbort.call("DrainPendingPreloads")
		quit(failures)
		return
	_populate()
	_runFunnelTrajectory()
	_readCensus()
	_suiteCleanFunnel()
	_suiteCensusNotEmpty()
	_suiteClosedWorld()
	_suitePlantedControls()
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	var db : Node = _launcher.get("DB")
	if db != null:
		db.call("DrainPendingPreloads")
	quit(failures)

# ------------------------------------------------------------------ fixtures e trajetória
func _mk(prefix : String) -> Dictionary:
	var tag : int = int(Time.get_unix_time_from_system())
	var name : String = "%s_%d_%d" % [prefix, tag, _chars.size() + _accounts.size()]
	var acctName : String = name + "_acct"
	var nc : GDScript = load("res://sources/network/NetworkCommons.gd")
	var consts : Dictionary = nc.get_script_constant_map()
	var ac : GDScript = load("res://sources/actor/ActorCommons.gd")
	if not bool(_sql.call("AddAccount", acctName, "senha-de-censo-123", acctName + "@censo.test.local",
			consts.get("AgreementTosVersion"), consts.get("AgreementPrivacyVersion"), "203.0.113.9")):
		_check(false, "conta de censo criada (%s)" % acctName)
		return {}
	var accountID : int = int(_sql.call("GetAccountID", acctName))
	if not bool(_sql.call("AddCharacter", accountID, name, ac.get("DefaultStats"),
			ac.get("DefaultTraits"), ac.get("DefaultAttributes"))):
		_check(false, "personagem de censo criado (%s)" % name)
		return {}
	var charID : int = int(_sql.call("GetCharacterID", accountID, name))
	return {"accountID" = accountID, "charID" = charID}

func _populate() -> void:
	for i in range(3):
		var f : Dictionary = _mk("fc")
		if f.is_empty():
			continue
		_chars.append(int(f["charID"]))
		_accounts.append(int(f["accountID"]))
		_check(bool(_eco.call("MoveGold", int(f["charID"]), 120000, "fc_mint")), "endowment de gold %d" % i)
		_check(bool(_eco.call("AddGems", int(f["accountID"]), 4000, "fc_gems_mint")), "endowment de gemas %d" % i)
	_check(_chars.size() == 3, "população limpa tem três personagens (%d)" % _chars.size())
	# Sonda: population À PARTE, para os controles negativos não sujarem a régua de
	# conservação da população limpa.
	var probe : Dictionary = _mk("fcprobe")
	if not probe.is_empty():
		_probeChar = int(probe["charID"])
		_probeAccount = int(probe["accountID"])
		_check(bool(_eco.call("MoveGold", _probeChar, 100000, "fc_mint")), "sonda endowment gold")
		_check(bool(_eco.call("AddGems", _probeAccount, 1000, "fc_gems_mint")), "sonda endowment gemas")
	_check(_probeChar > 0, "sonda de controle existe (%d)" % _probeChar)

var _probeChar : int = 0
var _probeAccount : int = 0
var _ahItem : int = 0

func _runFunnelTrajectory() -> void:
	# Cada linha abaixo é um escritor REAL do funil, chamada pelo facade do produto.
	# O censo só significa alguma coisa se as pias que ele nomeia aconteceram.
	var i : int = 0
	for charID in _chars:
		var accountID : int = int(_accounts[i])
		_check(bool(_eco.call("BuyVendorOffer", accountID, int(charID), "apple").get("ok", false)), "vendor apple comprada (%d)" % i)
		_check(bool(_eco.call("BuyBossKey", int(charID)).get("ok", false)), "chave de boss comprada (%d)" % i)
		var ent : Dictionary = _eco.call("EnterTournament", accountID, int(charID), 1)
		print("  [torneio] entrada char %d: ok=%s reason=%s" % [int(charID), str(ent.get("ok", false)), str(ent.get("reason", ""))])
		_check(int(_eco.call("CreateGuild", accountID, int(charID), "censo_guild_%d_%d" % [int(Time.get_unix_time_from_system()), i])) > 0, "guilda fundada (pia guild_create) (%d)" % i)
		i += 1
	# Taxa de anúncio em GEMA: a pia que o fuzzer dizia gastar "por fora do gate".
	_ahItem = absi(str("fcen_%d" % int(Time.get_unix_time_from_system())).hash())
	var seller : int = int(_chars[0])
	_check(bool(_sql.call("AddItemToCharacter", seller, _ahItem, 5, "fc_items")), "item do anúncio concedido")
	var listing : int = int(_eco.call("ListItemForSale", seller, _ahItem, 1, 900))
	_check(listing > 0, "anúncio nasceu cobrando a taxa de anúncio em gema (%d)" % listing)

func _census() -> Dictionary:
	return _kernel().call("CensusSupply", 86400, 0, _chars + [_probeChar], _accounts + [_probeAccount], FixtureFamilies)

func _kernel() -> Object:
	return _eco.get("kernel")

func _readCensus() -> void:
	var c : Dictionary = _census()
	_check(bool(c.get("ok", false)), "censo respondeu (%s)" % str(c.get("reason", "")))
	_gold = c.get("gold", {}) if c.get("gold", {}) is Dictionary else {}
	_gems = c.get("gems", {}) if c.get("gems", {}) is Dictionary else {}
	_check(not _gold.is_empty() and not _gems.is_empty(), "censo traz as duas moedas (gold=%d gems=%d chaves)" % [_gold.size(), _gems.size()])
	print("  [censo gold] dia: criado %d destruído %d líquido %d | banco %d ledger %d diferença %d" % [
		int((_gold.get("day", {}) as Dictionary).get("created", 0)), int((_gold.get("day", {}) as Dictionary).get("destroyed", 0)),
		int((_gold.get("day", {}) as Dictionary).get("net", 0)), int(_gold.get("observed", 0)), int(_gold.get("attested", 0)), int(_gold.get("unattested", 0))])
	print("  [censo gems] dia: criado %d destruído %d líquido %d | banco %d ledger %d diferença %d" % [
		int((_gems.get("day", {}) as Dictionary).get("created", 0)), int((_gems.get("day", {}) as Dictionary).get("destroyed", 0)),
		int((_gems.get("day", {}) as Dictionary).get("net", 0)), int(_gems.get("observed", 0)), int(_gems.get("attested", 0)), int(_gems.get("unattested", 0))])
	print("  [pias gold] %s" % str((_gold.get("all", {}) as Dictionary).get("sinks", {})))
	print("  [pias gems] %s" % str((_gems.get("all", {}) as Dictionary).get("sinks", {})))

# C1 — o funil conserva: dono a dono, Σ do ledger == último balance_after ==
# carteira, e o censo não deve diferença nenhuma entre banco e ledger.
func _suiteCleanFunnel() -> void:
	for charID in _chars:
		var sum : int = int(_sql.call("QueryBindings",
			"SELECT COALESCE(SUM(amount),0) AS s FROM ledger_transaction WHERE char_id = ? AND kind = 'gold';", [int(charID)])[0].get("s", 0))
		var last : int = int(_sql.call("QueryBindings",
			"SELECT balance_after AS b FROM ledger_transaction WHERE char_id = ? AND kind = 'gold' ORDER BY id DESC LIMIT 1;", [int(charID)])[0].get("b", -1))
		var gp : int = int(_sql.call("QueryBindings", "SELECT gp AS g FROM stat WHERE char_id = ?;", [int(charID)])[0].get("g", -1))
		_check(sum == last and last == gp, "C1 gold: ledger fecha com a carteira no char %d (soma %d, atestado %d, carteira %d)" % [int(charID), sum, last, gp])
	for accountID in _accounts:
		var gsum : int = int(_sql.call("QueryBindings",
			"SELECT COALESCE(SUM(amount),0) AS s FROM ledger_transaction WHERE account_id = ? AND kind = 'gems';", [int(accountID)])[0].get("s", 0))
		var gg : int = int(_sql.call("GetGems", int(accountID)))
		_check(gsum == gg, "C1 gems: ledger fecha com a carteira na conta %d (soma %d, carteira %d)" % [int(accountID), gsum, gg])
	_check(int(_gold.get("unattested", -1)) == 0, "C1 censo: banco == ledger em gold sobre a população (%d)" % int(_gold.get("unattested", -1)))
	_check(int(_gems.get("unattested", -1)) == 0, "C1 censo: banco == ledger em gems sobre a população (%d)" % int(_gems.get("unattested", -1)))

# C2 — o censo não é vazio: cada pia nomeada que a trajetória exerceu aparece com
# valor, e o total destruído é maior que zero nas duas moedas.
func _suiteCensusNotEmpty() -> void:
	var goldAll : Dictionary = _gold.get("all", {}) as Dictionary
	var gemsAll : Dictionary = _gems.get("all", {}) as Dictionary
	var goldSinks : Dictionary = goldAll.get("sinks", {}) as Dictionary
	var gemsSinks : Dictionary = gemsAll.get("sinks", {}) as Dictionary
	_check(int(goldAll.get("destroyed", 0)) > 0, "C2 gold: existe destruição medida (%d)" % int(goldAll.get("destroyed", 0)))
	_check(int(gemsAll.get("destroyed", 0)) > 0, "C2 gems: existe destruição medida (%d)" % int(gemsAll.get("destroyed", 0)))
	_check(int(goldAll.get("created", 0)) > 0, "C2 gold: existe criação medida (%d)" % int(goldAll.get("created", 0)))
	_check(goldSinks.has("vendor"), "C2 pia vendor no censo (%s)" % str(goldSinks.keys()))
	_check(goldSinks.has("boss_key_buy"), "C2 pia de chave de boss no censo (%s)" % str(goldSinks.keys()))
	_check(goldSinks.has("guild_create"), "C2 pia de guilda no censo (%s)" % str(goldSinks.keys()))
	_check(int(gemsSinks.get("ah_list_fee", 0)) > 0, "C2 pia ah_list_fee queima gema e aparece no censo (%s)" % str(gemsSinks.keys()))
	# Expansão líquida de oferta: é o número que a auditoria pediu para ser medido
	# (torneiras menos pias), não uma contagem de chaves.
	_check(int(goldAll.get("net", 0)) == int(goldAll.get("created", 0)) - int(goldAll.get("destroyed", 0))
			and int(goldAll.get("net", 0)) > 0,
		"C2 gold: oferta líquida medida e positiva (criado %d - destruído %d = %d)" % [
			int(goldAll.get("created", 0)), int(goldAll.get("destroyed", 0)), int(goldAll.get("net", 0))])
	_check(not (gemsAll.get("faucets", {}) as Dictionary).has("fc_gems_mint")
			and not (goldAll.get("faucets", {}) as Dictionary).has("fc_mint"),
		"C2 família declarada do harness não vira torneira do produto no censo (gold faucets %s)" % str((goldAll.get("faucets", {}) as Dictionary).keys()))
	# A perna DIÁRIA, que é o que "censo de pia diário" significa: as pias exercidas
	# neste run têm de aparecer na janela do dia, não só no total de sempre. (Com a
	# borda superior exclusiva da janela o dia ficava 0 e isto pegava.)
	var goldDay : Dictionary = _gold.get("day", {}) as Dictionary
	var gemsDay : Dictionary = _gems.get("day", {}) as Dictionary
	_check(int(goldDay.get("destroyed", 0)) > 0 and int(gemsDay.get("destroyed", 0)) > 0
			and int(goldDay.get("created", 0)) > 0,
		"C2 janela de dia mede a trajetória deste run (gold criado %d destruído %d, gems destruído %d)" % [
			int(goldDay.get("created", 0)), int(goldDay.get("destroyed", 0)), int(gemsDay.get("destroyed", 0))])

# C3 — mundo fechado: o catálogo do kernel cobre os escritores do produto. LER
# `sources/` é o que torna isto geral (não é a lista das minhas três operações).
# O extrator tem controle negativo próprio: se ele não achar as famílias que já
# existem, a régua virou no-op silencioso.
func _suiteClosedWorld() -> void:
	var kernel : GDScript = load("res://sources/economy/EconomyKernel.gd")
	var consts : Dictionary = kernel.get_script_constant_map()
	var catalog : Dictionary = {}
	for key in ["CensusFaucetFamilies", "CensusSinkFamilies", "CensusTransferFamilies"]:
		for fam in (consts.get(key, PackedStringArray()) as PackedStringArray):
			catalog[str(fam)] = true
	_check(catalog.has("ah_list_fee") and catalog.has("vendor") and catalog.has("boss_key_buy"),
		"C3 catálogo do kernel nomeia as pias da auditoria (%d famílias)" % catalog.size())
	for named in NamedSinks:
		_check(catalog.has(str(named)), "C3 pia nomeada pela auditoria está no catálogo: %s" % named)
	var found : Dictionary = _productReasonFamilies()
	var missing : String = ""
	for fam in found.keys():
		if not _catalogCovers(catalog, str(fam)):
			missing += " " + str(fam)
	print("  [catálogo] %d famílias escritas em sources/, %d fora do censo" % [found.size(), missing.strip_edges().split(" ", false).size()])
	_check(found.has("ah_list_fee") and found.has("vendor") and found.has("grant") and found.has("clawback"),
		"C3 o extrator LÊ os writers reais (achou %d: ah_list_fee=%s vendor=%s grant=%s)" % [found.size(),
			str(found.has("ah_list_fee")), str(found.has("vendor")), str(found.has("grant"))])
	_check(missing.strip_edges().is_empty(), "C3 nenhum writer de ledger fora do catálogo do censo (%s)" % missing)
	# E o alarme do censo sobre a população limpa: nada ficou sem família.
	_check(int((_gold.get("all", {}) as Dictionary).get("unattributed_rows", -1)) == 0,
		"C3 censo gold: zero linhas sem família (%s)" % str(((_gold.get("all", {}) as Dictionary).get("unattributed", {}) as Dictionary).keys()))
	_check(int((_gems.get("all", {}) as Dictionary).get("unattributed_rows", -1)) == 0,
		"C3 censo gems: zero linhas sem família (%s)" % str(((_gems.get("all", {}) as Dictionary).get("unattributed", {}) as Dictionary).keys()))

func _gdFilesUnder(path : String, out : Array = []) -> Array:
	var da : DirAccess = DirAccess.open(path)
	if da == null:
		return out
	for f in da.get_files():
		if str(f).ends_with(".gd"):
			out.append(path + "/" + str(f))
	for sub in da.get_directories():
		_gdFilesUnder(path + "/" + str(sub), out)
	return out

# Toda chamada de ledger do produto cujo `reason` é literal. A régua é a ASSINATURA
# do writer (posição do argumento de moeda e posição do `reason`), não uma lista de
# casos: quem adiciona um writer novo aparece aqui sem que o harness mude.
# [índice do argumento de moeda (-1 = moeda implícita no nome), índice do reason, token implícito]
const WriterSignatures : Dictionary = {
	"_LedgerAppendLocked": [2, 5, ""],
	"LedgerAppend": [2, 5, ""],
	"_MoveGoldLocked": [-1, 4, "gold"],
	"MoveGold": [-1, 2, "gold"],
	"AddGems": [-1, 2, "gems"],
}
const CurrencyKindTokens : PackedStringArray = ["gold", "gems"]

# Caractere de identificador: rejeita `AddGemsPaidRaw(` quando se procura `AddGems`,
# mas mantém `economy.LedgerAppend(` (ponto é chamada, não sufixo de nome).
const IdentChars : String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
func _identChar(ch : String) -> bool:
	return IdentChars.contains(ch)

# Argumentos de nível topo de uma chamada que abre em `openAt` (o parêntese).
# Strings são opacas; colchetes/chaves contam profundidade — otherwise `% [a, b]`
# de um format quebraria o argumento no meio.
func _callArgs(text : String, openAt : int) -> Array:
	var args : Array = []
	var depth : int = 0
	var cur : String = ""
	var inStr : bool = false
	var i : int = openAt
	while i < len(text):
		var ch : String = text[i]
		if inStr:
			cur += ch
			if ch == "\"":
				inStr = false
			i += 1
			continue
		if ch == "\"":
			inStr = true
			cur += ch
		elif ch == "(" or ch == "[" or ch == "{":
			depth += 1
			if depth > 1:
				cur += ch
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
			if depth < 1:
				args.append(cur.strip_edges())
				return args
			cur += ch
		elif ch == "," and depth == 1:
			args.append(cur.strip_edges())
			cur = ""
		else:
			cur += ch
		i += 1
	return args

func _isCurrencyKind(arg : String) -> bool:
	var low : String = arg.to_lower()
	for tok in CurrencyKindTokens:
		if low.contains(str(tok)):
			return true
	return false

# Família = o texto do literal até o primeiro `:` (a mesma regra do GROUP BY do
# censo), com placeholders de format virando curinga: `"vip%d_purchase"` escreve
# `vip2_purchase` no banco e é coberto pela família do catálogo via `matchn`.
func _reasonFamily(arg : String) -> String:
	if not arg.begins_with("\""):
		return ""
	var close : int = arg.find("\"", 1)
	if close <= 1:
		return ""
	var fam : String = str(arg.substr(1, close - 1).split(":")[0])
	for ph in ["%02d", "%03d", "%d", "%s", "%i"]:
		fam = fam.replace(ph, "*")
	return fam if fam != "*" else ""

func _productReasonFamilies() -> Dictionary:
	var found : Dictionary = {}
	for path in _gdFilesUnder("res://sources"):
		var text : String = FileAccess.get_file_as_string(path)
		if text.is_empty():
			continue
		for wname in WriterSignatures.keys():
			var sig : Array = WriterSignatures[wname]
			var from : int = 0
			while true:
				var at : int = text.find(str(wname), from)
				if at < 0:
					break
				from = at + len(str(wname))
				if at > 0 and _identChar(text[at - 1]):
					continue
				var openAt : int = from
				while openAt < len(text) and (text[openAt] == " " or text[openAt] == "\t"):
					openAt += 1
				if openAt >= len(text) or text[openAt] != "(":
					continue
				var args : Array = _callArgs(text, openAt)
				var reasonIdx : int = int(sig[1])
				if args.size() <= reasonIdx:
					continue
				var kindIdx : int = int(sig[0])
				if not _isCurrencyKind(str(args[kindIdx]) if kindIdx >= 0 else str(sig[2])):
					continue
				var fam : String = _reasonFamily(str(args[reasonIdx]))
				if not fam.is_empty():
					found[fam] = true
	return found

# O catálogo cobre a família? Uma família extraída com placeholder (`"vip%d_
# purchase"` → `vip*_purchase`) bate por glob contra cada entrada do catálogo; o
# resto é igualdade exata. O curinga está no PADRÃO, então é `candidate.matchn(fam)`.
func _catalogCovers(catalog : Dictionary, fam : String) -> bool:
	if catalog.has(fam):
		return true
	if not fam.contains("*"):
		return false
	for candidate in catalog.keys():
		if str(candidate).matchn(fam):
			return true
	return false

# C4 — controles negativos plantados. Cada um morde pelo MESMO predicado de C1
# (`unattested`/`unattributed`), e o par que a auditoria chamou de invisível por
# construção é conferido contra `ReconcileWalletDaily`, que tem que dizer 0 nele.
func _suitePlantedControls() -> void:
	if _probeChar <= 0:
		_check(false, "sonda ausente — os controles negativos não rodaram")
		return
	var attested : int = _lastBalance(_probeChar, "gold")
	var observed : int = _gp(_probeChar)
	_check(attested == observed, "C4 base: sonda começa conservada (%d == %d)" % [attested, observed])
	# (a) faucet cru: infla a carteira sem linha de ledger.
	_raw("UPDATE stat SET gp = gp + ? WHERE char_id = ?", [ProbeGoldFaucetNoLedger, _probeChar])
	_check(_deltaCensusGold() == ProbeGoldFaucetNoLedger,
		"C4a faucet cru de gold aparece no censo como oferta não atestada (esperado %d, medido %d)" % [ProbeGoldFaucetNoLedger, _deltaCensusGold()])
	# (b) O CASO DA AUDITORIA: carteira E ledger escritos juntos, por fora de
	# qualquer funil. `ReconcileWalletDaily` fica em zero — é a prova de que a
	# régua antiga é cega aqui e de que o que fecha o buraco é a família.
	var before : int = _gp(_probeChar)
	var legible : int = before + ProbeGoldFaucetWithLedger
	_check(bool(_eco.call("LedgerAppend", _probeChar, _probeAccount, "gold", ProbeGoldFaucetWithLedger, legible, "fc_rogue_faucet:1")),
		"C4b linha de ledger escrita junto com a carteira")
	_raw("UPDATE stat SET gp = ? WHERE char_id = ?", [legible, _probeChar])
	var c : Dictionary = _census()
	var gold : Dictionary = c.get("gold", {}) as Dictionary
	var all : Dictionary = gold.get("all", {}) as Dictionary
	# O faucet lavou a si mesmo: a linha criminosa fecha `balance_after` com a
	# carteira inflada, então a perna banco × ledger volta a ZERO e o resíduo de C4a
	# desaparece. Isso NÃO é "tudo bem" — é a prova medida de que essa perna é cega
	# ao caso da auditoria. O que pega é a família desconhecida, dois cheques abaixo.
	_check(int(gold.get("unattested", -999)) == 0,
		"C4b par carteira+ledger zera `unattested` (medido %d) — a perna banco × ledger é CEGA aqui, e é isso que o censo de família fecha" % int(gold.get("unattested", -999)))
	_check(_reconcileTotal() == 0,
		"C4b `ReconcileWalletDaily` continua dizendo zero com o faucet plantado (medido %d)" % _reconcileTotal())
	_check(int(all.get("unattributed_created", -1)) == ProbeGoldFaucetWithLedger,
		"C4b o censo vê o faucet pelo família desconhecida (esperado %d, medido %d: %s)" % [ProbeGoldFaucetWithLedger,
			int(all.get("unattributed_created", -1)), str((all.get("unattributed", {}) as Dictionary).keys())])
	_check((all.get("unattributed", {}) as Dictionary).has("fc_rogue_faucet"),
		"C4b a família crua está NOMEADA no censo, não diluída no total (%s)" % str((all.get("unattributed", {}) as Dictionary).keys()))
	# (c) pia crua: destruição sem linha — o sinal trocado do mesmo predicado.
	_raw("UPDATE stat SET gp = gp - ? WHERE char_id = ?", [ProbeGoldSinkNoLedger, _probeChar])
	_check(_deltaCensusGold() == -ProbeGoldSinkNoLedger,
		"C4c débito cru aparece como contração não atestada (esperado %d, medido %d)" % [-ProbeGoldSinkNoLedger, _deltaCensusGold()])
	# (d) gems: faucet cru na outra moeda.
	_raw("UPDATE wallet SET gems = gems + ? WHERE account_id = ?", [ProbeGemsFaucetNoLedger, _probeAccount])
	var gd : Dictionary = (_census().get("gems", {}) as Dictionary)
	_check(int(gd.get("unattested", 0)) == ProbeGemsFaucetNoLedger,
		"C4d faucet cru de gemas aparece no censo (esperado %d, medido %d)" % [ProbeGemsFaucetNoLedger, int(gd.get("unattested", 0))])
	# Repara a sonda: sandbox persistente não pode herdar envenenamento do run.
	_repairProbe()
	var after : Dictionary = _census()
	_check(int((after.get("gold", {}) as Dictionary).get("unattested", -1)) == 0
			and int((after.get("gems", {}) as Dictionary).get("unattested", -1)) == 0,
		"C4 sonda reparada: censo volta a fechar sem resíduo (gold %d, gems %d)" % [
			int((after.get("gold", {}) as Dictionary).get("unattested", -1)), int((after.get("gems", {}) as Dictionary).get("unattested", -1))])

func _repairProbe() -> void:
	_raw("UPDATE wallet SET gems = ? WHERE account_id = ?", [_lastBalance(_probeAccount, "gems"), _probeAccount])
	_raw("UPDATE stat SET gp = ? WHERE char_id = ?", [_lastBalance(_probeChar, "gold"), _probeChar])

func _reconcileTotal() -> int:
	return int(_eco.call("ReconcileWalletDaily", 0).get("total", -1))

func _deltaCensusGold() -> int:
	return int((_census().get("gold", {}) as Dictionary).get("unattested", 0))

func _raw(sqlText : String, args : Array) -> void:
	if not bool(_sql.call("ExecuteBindings", sqlText, args)):
		_check(false, "UPDATE cru do controle negativo falhou (%s)" % sqlText)

func _gp(charID : int) -> int:
	return int(_sql.call("QueryBindings", "SELECT gp AS g FROM stat WHERE char_id = ?;", [charID])[0].get("g", 0))

func _lastBalance(owner : int, kind : String) -> int:
	var col : String = "char_id" if kind == "gold" else "account_id"
	var rows : Array = _sql.call("QueryBindings",
		"SELECT balance_after AS b FROM ledger_transaction WHERE %s = ? AND kind = ? ORDER BY id DESC LIMIT 1;" % col,
		[owner, kind])
	return 0 if rows.is_empty() else int((rows[0] as Dictionary).get("b", 0))
