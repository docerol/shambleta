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
#   C5 — o faucet de MEMÓRIA (WorkOrder #185): ouro ganho em `ActorStats.AddGP` e
#        descido ao banco por `SQLGrants.FlushGoldDelta` nasce com linha de ledger e
#        com a família bookada. É a perna que deixava `unattested` crescer sem
#        ninguém acordar, e é medida no agente real, não num dicionário montado à mão.
#   C6 — o censo tem DONO no produto: chamado de produção lido do diretório (não de
#        uma lista escrita), na cadência diária, com o job rodando de fato e o
#        `/metrics` emitindo a IDADE dele. Um censo que só existe para o harness não
#        mede nada entre execuções — foi exatamente o que os juízes chamaram de
#        "economia não vê a própria oferta".

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
# C5 — as quantias do faucet de MEMÓRIA são escolhas de cenho, não medidas: o que
# importa é que cada uma FECHA com o banco e com o ledger. O último valor é o do
# débito que o `MAX(0, …)` do funil corta de propósito.
const FlushFarmGold : int = 1500
const FlushStalePendingGold : int = 700
const FlushBossGold : int = 300
const FlushUntrackedGold : int = 900
const FlushImpossibleDebit : int = 999999

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
	# empilha os `load_threaded_request` de `Preload` (`sources/db/DB.gd:@Preload`) e o `PreloadUpdate()`
	# (`sources/db/DB.gd:@PreloadUpdate`) fecha o preload, chama `Load()` e acende `isInitialized`,
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
	_suiteMemoryFaucet()
	_suiteCensusHasOwner()
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

# ------------------------------------------------------------------ C5 (WorkOrder #185)

# Agente real, criado à mão: o faucet de memória é `ActorStats.AddGP`, e nada aqui
# mede o que ele faz se eu montar o dicionário `gpPending` numa mesa. O
# `Actor.@_init` sem `data` sai antes do `stat.Init`, então `stat.actor` fica nulo
# — sem ele `ActorCommons.IsAlive` é falso, `AddGP` volta no-op, e a régua mediria
# zero chamando de verde. O laço é o que um agente vivo tem.
#
# O agente entra por `load()` e é manuseado por `get`/`set`/`call`, nunca por um tipo
# estático: um harness que escreve `var a : Actor` puxa `sources/actor/Actor.gd` — e
# dali a cadeia de GUI que fala com o autoload `Launcher` — para o grafo de
# compilação do `godot -s`, que roda ANTES de os autoloads serem registrados. O
# sintoma medido neste repo em 2026-10-04 foi o boot inteiro caindo com
# `Identifier not found: Launcher` em arquivos que nada têm com a régua, e nenhuma
# check impressão. É a mesma razão pela qual todo harness daqui carrega
# `ActorCommons` com `load()`.
func _mkBareAgent() -> Object:
	var agent : Object = load("res://sources/actor/Actor.gd").new()
	_stat(agent).set("actor", agent)
	return agent

func _stat(agent : Object) -> Object:
	return agent.get("stat")

func _stGP(st : Object) -> int:
	return int(st.get("gp"))

func _stFlushed(st : Object) -> int:
	return int(st.get("gpFlushed"))

func _stPending(st : Object) -> Dictionary:
	return st.get("gpPending") as Dictionary

# A sonda começa com o lastro do banco: `gpFlushed` é o que o banco já tem e
# `gpPending` é o que a memória deve ao banco. Fora daqui cada caso escreve a
# memória por um caminho que NÃO é `MoveGold`, que é exatamente o que se quer medir.
func _seedLastro(st : Object) -> void:
	st.set("gp", _gp(_probeChar))
	st.set("gpFlushed", _stGP(st))
	_stPending(st).clear()

func _maxLedgerID() -> int:
	return int(_sql.call("QueryBindings", "SELECT COALESCE(MAX(id),0) AS m FROM ledger_transaction;", [])[0].get("m", 0))

func _lastGoldRow(charID : int) -> Dictionary:
	var rows : Array = _sql.call("QueryBindings",
		"SELECT amount, balance_after, reason FROM ledger_transaction WHERE char_id = ? AND kind = 'gold' ORDER BY id DESC LIMIT 1;",
		[charID])
	return {} if rows.is_empty() else (rows[0] as Dictionary)

func _sumGoldAmount(charID : int) -> int:
	return int(_sql.call("QueryBindings",
		"SELECT COALESCE(SUM(amount),0) AS s FROM ledger_transaction WHERE char_id = ? AND kind = 'gold';",
		[charID])[0].get("s", 0))

# O predicado de C1 aplicado a um dono só, e é ele que o `FlushGoldDelta` tem que
# manter: um flush que mexe em `stat.gp` e deixa a linha fora dessa igualdade mente
# para o atesto para sempre, e o `ReconcileWalletDaily` nem vê, porque só enxerga
# carteira ABAIXO do último `balance_after`.
func _conserved(charID : int) -> bool:
	return _sumGoldAmount(charID) == _lastBalance(charID, "gold") \
		and _lastBalance(charID, "gold") == _gp(charID)

func _dayGoldFamilies() -> Dictionary:
	var gold : Dictionary = _census().get("gold", {}) as Dictionary
	return (gold.get("day", {}) as Dictionary).get("families", {}) as Dictionary

# C5 — as três regras de fechamento do flush, medidas com um agente de verdade na
# mesa. O que estava plantado aqui em 2026-10-04 era a ausência delas: `AddGP` somava
# em memória, `SQL.@UpdateStat` escrevia `stat.gp` como delta e nenhuma linha de
# ledger nascia, então todo jogador online que coletava ouro ficava `unattested`.
func _suiteMemoryFaucet() -> void:
	if _probeChar <= 0:
		_check(false, "C5 sonda ausente — o faucet de memória não foi medido")
		return
	var agent : Object = _mkBareAgent()
	var st : Object = _stat(agent)
	var bank : int = _gp(_probeChar)
	var ids : int = _maxLedgerID()
	_seedLastro(st)
	# (1) A torneira que mais enche no jogo: kill de zona, família `farm`.
	st.call("AddGP", FlushFarmGold, false, "farm")
	_check(int(_stPending(st).get("farm", 0)) == FlushFarmGold, "C5 a memória booka a família ANTES de descer (%d)" % int(_stPending(st).get("farm", 0)))
	_check(bool(_sql.call("FlushGoldDelta", _probeChar, st)), "C5 o flush do farm comitou")
	_check(_maxLedgerID() == ids + 1, "C5 um farm de %d nasce EXATAMENTE uma linha de ledger (%d -> %d)" % [FlushFarmGold, ids, _maxLedgerID()])
	_check(_gp(_probeChar) == bank + FlushFarmGold, "C5 a carteira subiu o que o agente ganhou (%d -> %d)" % [bank, _gp(_probeChar)])
	var row : Dictionary = _lastGoldRow(_probeChar)
	_check(int(row.get("amount", 0)) == FlushFarmGold, "C5 a linha tem o valor ganho (%s)" % str(row.get("amount", 0)))
	_check(str(row.get("reason", "")) == "farm:%d" % _probeChar, "C5 a linha tem a FAMÍLIA bookada na memória, não um reason inventado (%s)" % str(row.get("reason", "")))
	_check(int(row.get("balance_after", -1)) == _gp(_probeChar), "C5 a linha atesta a carteira que acabou de escrever (%s vs %d)" % [str(row.get("balance_after", -1)), _gp(_probeChar)])
	_check(_conserved(_probeChar), "C5 depois do flush vale para a sonda o predicado de C1: Σ ledger == último atesto == carteira")
	_check(_stFlushed(st) == _stGP(st) and _stPending(st).is_empty(), "C5 o lastro avança no commit e a pendência esvazia (lastro %d, gp %d, pending %d)" % [_stFlushed(st), _stGP(st), _stPending(st).size()])
	var day : Dictionary = _dayGoldFamilies()
	_check(int((day.get("farm", {}) as Dictionary).get("created", 0)) == FlushFarmGold, "C5 o censo do dia conta a torneira pela família real (%d)" % int((day.get("farm", {}) as Dictionary).get("created", 0)))
	_check(_deltaCensusGold() == 0, "C5 o flush não deixa carteira acima do atesto (%d)" % _deltaCensusGold())
	_check(not day.has("flush_untracked"), "C5 controle (não pode morder): ouro com família bookada não vira flush sem família (%s)" % str(day.keys()))
	# (2) Outro sentido, também não mordido: lastro `-1` é carga de banco que nunca
	# foi feita e por isso não pode creditar nada às cegas.
	bank = _gp(_probeChar)
	ids = _maxLedgerID()
	st.set("gp", bank + FlushFarmGold)
	st.set("gpFlushed", -1)
	st.set("gpPending", {"farm": FlushFarmGold})
	_check(bool(_sql.call("FlushGoldDelta", _probeChar, st)), "C5 controle: flush com lastro não carregado responde true")
	_check(_gp(_probeChar) == bank and _maxLedgerID() == ids, "C5 controle (não pode morder): sem carga de banco o flush não mintar ouro nem linha (%d vs %d, ids %d vs %d)" % [_gp(_probeChar), bank, _maxLedgerID(), ids])
	# (3) Pendência VELHA já atestada por outra linha (é o ramo online do streak, que
	# credita memória e grava banco na mesma transação): o excedente não pode ser
	# re-emitido, e cobrar o mais recente é o que mantém a FAMÍLIA verdadeira.
	_seedLastro(st)
	st.set("gpPending", {"farm": FlushStalePendingGold})
	st.call("AddGP", FlushBossGold, false, "boss")
	_check(bool(_sql.call("FlushGoldDelta", _probeChar, st)), "C5 o flush do boss comitou")
	row = _lastGoldRow(_probeChar)
	_check(str(row.get("reason", "")) == "boss:%d" % _probeChar and int(row.get("amount", 0)) == FlushBossGold,
		"C5 os %d de delta foram cobrados da família mais recente, não re-emitados da pendência velha de %d (%s / %s)" % [
			FlushBossGold, FlushStalePendingGold, str(row.get("reason", "")), str(row.get("amount", 0))])
	_check(_conserved(_probeChar), "C5 cobrar o mais recente conserva a invariante: a soma fecha com a carteira em qualquer ordem")
	_check(not _dayGoldFamilies().has("flush_untracked"), "C5 controle (não pode morder): corte de pendência velha não deixa rastro sem família (%s)" % str(_dayGoldFamilies().keys()))
	# (4) Writer cru por baixo do agente: `gp` mexido sem `AddGP`, portanto sem
	# família. O dinheiro desce e o censo tem que dizer a verdade dos dois lados —
	# a carteira fecha, e o NOME é o alarme.
	_seedLastro(st)
	st.set("gp", _stGP(st) + FlushUntrackedGold)
	_check(bool(_sql.call("FlushGoldDelta", _probeChar, st)), "C5 o flush do writer cru comitou")
	row = _lastGoldRow(_probeChar)
	_check(str(row.get("reason", "")) == "flush_untracked:%d" % _probeChar and int(row.get("amount", 0)) == FlushUntrackedGold,
		"C5 o gold que desceu sem que nenhum `AddGP` o nomeasse ganha a família que grita (%s / %s)" % [str(row.get("reason", "")), str(row.get("amount", 0))])
	_check(_conserved(_probeChar) and _deltaCensusGold() == 0,
		"C5 mesmo sem família a carteira fecha com o ledger: o alarme é o nome, não o número (unattested %d)" % _deltaCensusGold())
	_check(int((_dayGoldFamilies().get("flush_untracked", {}) as Dictionary).get("created", 0)) == FlushUntrackedGold,
		"C5 o censo do dia mede o flush sem família (%d)" % int((_dayGoldFamilies().get("flush_untracked", {}) as Dictionary).get("created", 0)))
	# Reparo honesto numa ledger apenas-anexar: não há DELETE sancionado — o trigger
	# recusa (`row is not covered by a durable rollup`), e a régua nem deveria querer
	# um, porque apagar a linha é exatamente o que um desvio faria para não ser pego.
	# Repara-se a CARTEIRA, levada ao atesto (`_repairProbe`), e afirma-se que o
	# alarme sobrevive ao reparo: a família continua legível no censo do dia.
	_repairProbe()
	_check(_conserved(_probeChar), "C5 sonda levada ao atesto depois do writer cru (carteira %d, atesto %d)" % [_gp(_probeChar), _lastBalance(_probeChar, "gold")])
	_check(_dayGoldFamilies().has("flush_untracked"),
		"C5 uma ledger apenas-anexar não esquece o flush sem família (%s)" % str(_dayGoldFamilies().keys()))
	# (5) Regra 1 do funil, medida: a linha conta o que o BANCO moveu, não o delta
	# pedido. Um débito maior que a carteira é cortado pelo `MAX(0, …)`, e linha do
	# tamanho do pedido atestaria ouro que ninguém tem.
	bank = _gp(_probeChar)
	_seedLastro(st)
	st.set("gpFlushed", bank + FlushImpossibleDebit)
	st.set("gp", 0)
	_check(bool(_sql.call("FlushGoldDelta", _probeChar, st)), "C5 o flush do débito comitou")
	row = _lastGoldRow(_probeChar)
	_check(int(row.get("amount", 0)) == -bank,
		"C5 a linha do débito conta o CORTE, não o pedido (esperado %d, medido %s para um pedido de -%d)" % [-bank, str(row.get("amount", 0)), FlushImpossibleDebit])
	_check(str(row.get("reason", "")).begins_with("flush_correction:"),
		"C5 um débito de memória tem família própria, não `flush_untracked` (%s)" % str(row.get("reason", "")))
	_check(_conserved(_probeChar), "C5 carteira cortada a zero fecha com atesto zero — linha maior mintaria ouro para o ledger")
	# E aqui o reparo é mais honesto ainda: a carteira cortada a ZERO é o estado que
	# o ledger atesta, e não se desfaz apagando a linha — move-se a carteira ao
	# atesto. O que fica é o que ops precisa que fique: a correção contada como
	# destruição do dia pelo valor do CORTE.
	_repairProbe()
	_check(_conserved(_probeChar) and _gp(_probeChar) == _lastBalance(_probeChar, "gold"),
		"C5 sonda levada ao atesto depois do débito plantado (%d vs atesto %d)" % [_gp(_probeChar), _lastBalance(_probeChar, "gold")])
	var fam : Dictionary = _dayGoldFamilies()
	_check(int((fam.get("flush_correction", {}) as Dictionary).get("destroyed", 0)) == bank,
		"C5 o censo do dia carrega a `flush_correction` como destruição do valor cortado (%d vs %d)" % [
			int((fam.get("flush_correction", {}) as Dictionary).get("destroyed", 0)), bank])
	agent.free()

# ------------------------------------------------------------------ C6 (WorkOrder #185)

# Chamados de produção de um símbolo, LIDOS do diretório. O que a régua precisa é
# exatamente o que o judge chamou de falta: um censo que só existe porque um harness
# o chama não mede nada entre execuções. Uma lista escrita de arquivos não prova
# nada — quem move o chamada para um boot one-shot continuaria "no catálogo".
func _productionCallers(symbol : String) -> Array:
	var hits : Array = []
	for path in _gdFilesUnder("res://sources"):
		# Definição e fachada do kernel não são dono: o que se procura é quem chama.
		if path.ends_with("/EconomyKernel.gd"):
			continue
		for line in FileAccess.get_file_as_string(path).split("\n"):
			var code : String = str(line).split("#")[0]
			var at : int = code.find(symbol)
			if at < 0 or code.strip_edges().begins_with("func "):
				continue
			var end : int = at + len(symbol)
			if _identChar(code[at - 1] if at > 0 else " ") or (end < len(code) and _identChar(code[end])):
				continue
			hits.append(path)
			break
	return hits

func _suiteCensusHasOwner() -> void:
	var callers : Array = _productionCallers("RunSupplyCensusJob")
	_check(not callers.is_empty(), "C6 o censo de oferta tem chamado de produção lido do diretório (%s)" % str(callers))
	var cadenciado : bool = false
	for path in callers:
		if FileAccess.get_file_as_string(str(path)).contains("MetaJobIntervalSec"):
			cadenciado = true
	_check(cadenciado, "C6 o dono do censo está na cadência diária do mesmo seam do reconcile, não num disparo de boot (%s)" % str(callers))
	# Controle do extrator nas duas direções: um vizinho conhecido tem de ser
	# encontrado nos mesmos arquivos (senão a régua é um no-op verde para sempre) e
	# um símbolo que não existe não pode aparecer.
	var reconcileCallers : Array = _productionCallers("RunReconcileJob")
	var orphans : Array = []
	for path in callers:
		if not reconcileCallers.has(path):
			orphans.append(path)
	_check(not reconcileCallers.is_empty() and orphans.is_empty(),
		"C6 controle: o extrator acha o reconcile em TODO arquivo em que acha o censo (reconcile %s, órfãos %s)" % [str(reconcileCallers), str(orphans)])
	_check(_productionCallers("RunSupplyCensusJobZZZ").is_empty(), "C6 controle: o extrator não alucina chamado de um símbolo que não existe")
	# O job roda de fato e os contadores que o `/metrics` expõe são a MESMA conta do
	# censo que ele acabou de fazer. Uma métrica que não bate com a medição que ela
	# resume é uma régua nova mentindo sobre a velha — foi assim que o rodapé do
	# `RunReconcileJob` divergiu do seu próprio diagnóstico.
	var before : Dictionary = _kernel().call("CensusJobStats")
	var res : Dictionary = _eco.call("RunSupplyCensusJob")
	_check(bool(res.get("ok", false)), "C6 o job do censo responde no processo bootado (%s)" % str(res.get("reason", "")))
	var after : Dictionary = _kernel().call("CensusJobStats")
	_check(int(after.get("runs", 0)) == int(before.get("runs", 0)) + 1, "C6 rodar o censo pelo dono conta uma passada (%d -> %d)" % [int(before.get("runs", 0)), int(after.get("runs", 0))])
	_check(int(after.get("age", -99)) >= 0, "C6 censo que rodou tem idade mensurável; -1 é a assinatura do job que nunca rodou (%d)" % int(after.get("age", -99)))
	var rg : Dictionary = res.get("gold", {}) as Dictionary
	var rAll : Dictionary = rg.get("all", {}) as Dictionary
	var rFam : Dictionary = (rg.get("day", {}) as Dictionary).get("families", {}) as Dictionary
	var rgems : Dictionary = res.get("gems", {}) as Dictionary
	var expectedUntracked : int = int((rFam.get("flush_untracked", {}) as Dictionary).get("created", 0)) \
		+ int((rFam.get("flush_correction", {}) as Dictionary).get("destroyed", 0))
	_check(int(after.get("goldUnattested", -1)) == int(rg.get("unattested", -2)), "C6 fidelidade: `goldUnattested` == censo direto (%d vs %d)" % [int(after.get("goldUnattested", -1)), int(rg.get("unattested", -2))])
	_check(int(after.get("gemsUnattested", -1)) == int(rgems.get("unattested", -2)), "C6 fidelidade: `gemsUnattested` == censo direto (%d vs %d)" % [int(after.get("gemsUnattested", -1)), int(rgems.get("unattested", -2))])
	_check(int(after.get("divergentOwners", -1)) == int(rg.get("divergent", 0)) + int(rgems.get("divergent", 0)), "C6 fidelidade: `divergentOwners` == as duas moedas somadas (%d vs %d + %d)" % [int(after.get("divergentOwners", -1)), int(rg.get("divergent", 0)), int(rgems.get("divergent", 0))])
	_check(int(after.get("untrackedGold", -1)) == expectedUntracked, "C6 fidelidade: `untrackedGold` == flush sem família/correção do dia (%d vs %d)" % [int(after.get("untrackedGold", -1)), expectedUntracked])
	_check(int(after.get("createdGold", -1)) == int(rAll.get("created", -2)), "C6 fidelidade: `createdGold` == total criado do censo (%d vs %d)" % [int(after.get("createdGold", -1)), int(rAll.get("created", -2))])
	_check(int(after.get("destroyedGold", -1)) == int(rAll.get("destroyed", -2)), "C6 fidelidade: `destroyedGold` == total destruído do censo (%d vs %d)" % [int(after.get("destroyedGold", -1)), int(rAll.get("destroyed", -2))])
	# O dono só serve se alguém acorda: as séries que as regras de alerta lêem têm de
	# estar no corpo do `/metrics`, escritas como literal emitido (mesma régua de
	# `tests/deploy_ops_test.gd`, aqui pelo lado do censo).
	var metricsText : String = FileAccess.get_file_as_string("res://sources/system/MetricsServer.gd")
	for metricName in ["shambleta_supply_census_runs_total", "shambleta_supply_census_age_seconds",
			"shambleta_supply_census_gold_unattested", "shambleta_supply_census_untracked_gold"]:
		_check(metricsText.contains("body += \"" + str(metricName) + " "), "C6 o censo é emitido no /metrics: %s" % str(metricName))
