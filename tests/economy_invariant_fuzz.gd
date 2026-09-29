extends SceneTree

# economy_invariant_fuzz.gd — fuzzer de invariantes da fronteira do dinheiro.
#
# Uso:  godot --headless --path . -s tests/economy_invariant_fuzz.gd
# Saída: "== FUZZ: <n> checks, <m> failures =="  (exit code = <m>)
#
# Três fatias, mesmo princípio:
#   gemas pagas  — grant/chargeback/refund/delta sobre a carteira de wallet
#                  (I1..I7, as invariantes que caçaram o buraco do chargeback §8);
#   mercado      — I8..I13 sobre a mesa de leilão depois da migração 059: anúncio
#                  (escrow de ITEM + taxa em GEMA), ordem de compra (escrow de
#                  OURO), compra a ask, fill parcial de bid, cancelamento dos dois
#                  lados. É onde o ouro muda de dono sem passar pela loja.
#   faucet/sink  — FS1..FS12 sobre uma trajetória LONGA de 29 famílias de operação
#                  (settle, loja, forja, leilão, IAP, guilda, copa, troca, anúncio,
#                  quest, streak, GM): soma o que CRIA moeda contra o que DESTRÓI,
#                  POR MOEDA, com transferências e linhas de amount 0 nomeadas à
#                  parte, e confere o líquido contra o que EXISTE no banco (carteiras
#                  + custódia). Nenhuma régua acima vê um faucet que minte sem linha
#                  nem um sink que queima sem débito: por conta, os dois têm sinais
#                  opostos e se cancelam na soma.
#
# Por que existe: os harnesses deste repo são todos de CASO — cada um encena uma
# sequência que alguém pensou antes de escrever (grant → chargeback → refund). O
# buraco que a auditoria de 2026-09-27 achou no chargeback (§8) e o que ele abriu
# no art.49 (`charged_back` negando estorno do mesmo payment) são exatamente o tipo
# de coisa que nasce do INTERESSE, não da sequência: duas operações legalmente
# individuais que intercaladas violam uma invariante. Caso cobre o que já se
# imaginou; fuzz cobre o que falta imaginar.
#
# Semente FIXA de propósito: falha tem que ser reproduzível em um comando, e um
# gate que às vezes passa não é gate. Aleatoriedade é trajetória, não veredito.
#
# Como os outros harnesses chamados por `-s`: autoloads e `class_name` do projeto
# NÃO estão registrados quando o script compila, então nada de `EconomyCatalog`/
# `NetworkCommons` como identificador global — tudo via load(), get_node_or_null()
# e `.call`/`.get`.

const FixAccounts : int = 4
const FixOps : int = 1800
const FixPayments : int = 40
const FixSeed : int = 20260927
const FullSweepEvery : int = 25
# Fatia 059 do fuzz: o escrow de gold de uma ordem de compra é a primeira vez no
# leilão que um jogador tira ouro da carteira SEM comprar nada naquele instante.
# É exatamente a forma que cria dinheiro se o estorno e o débito não baterem
# unidade a unidade, então a trajetória abaixo é um mercado pequeno rodando
# muitas vezes, com as invariantes conferidas a cada operação.
const AHChars : int = 4
const AHOps : int = 700
const AHGoldEach : int = 40000
const AHItemsEach : int = 60

# ------------------------------------------------------------------ fatia faucet/sink
# Trajetória LONGA de propósito: a régua é uma SOMA, e soma só significa alguma
# coisa quando passa por muitos caminhos diferentes do mesmo ledger. As 29 famílias
# abaixo são as que mexem em ouro ou gema no produto (fatia 060 do ROADMAP_COMERCIAL).
const FSAccounts : int = 6
const FSOps : int = 2600
const FSWideEvery : int = 40
const FSGoldEach : int = 400000
const FSGemsEach : int = 150000
const FSMatUnits : int = 720
const FSEquipUnits : int = 90
const FSTradeUnits : int = 24
# Peso de cada família na trajetória (a tabela cumulativa é montada em runtime).
const FSOpNames : PackedStringArray = [
	"settle", "vendor", "salvage", "corrupt", "craft", "chest_buy", "daily_reroll",
	"daily_offer", "vip", "boss_key", "guild", "copa", "ah_list", "ah_order",
	"ah_cancel_order", "ah_cancel_listing", "ah_ask", "iap_grant", "gold_grant",
	"chargeback", "process", "refund", "gm_delta", "troca", "anuncio", "quest",
	"streak", "abrir_bau", "creator_round"]
const FSOpWeights : PackedInt32Array = [
	4, 3, 2, 2, 2, 3, 2, 2, 1, 2, 1, 1, 4, 4, 2, 1, 3, 4, 2, 3, 4, 2, 3, 1, 1, 1,
	1, 1, 2]
# Raízes de reason que NÃO criam nem destroem moeda: movem ouro entre contas
# (`ah_buy`/`ah_sell`/`ah_creator_fee`, que fecham o ciclo do anúncio em soma zero)
# ou entre carteira e custódia (`ah_bid_escrow`/`ah_bid_release`). A lista é a do
# leilão e SÓ ela: as taxas do mesmo leilão (`ah_list_fee`, `ah_slot`,
# `ah_highlight_fee`) são queima de gema, não transferência, e ficam no sink.
const FSTransferRoots : PackedStringArray = [
	"ah_buy", "ah_sell", "ah_creator_fee", "ah_bid_escrow", "ah_bid_release"]
# amount == 0 é linha legítima em dois lugares e NEUTRA em nenhum dos dois lados da
# régua: `clawback` de um payment cujo débito já foi consumido, e `ah_creator_fee`
# de um anúncio barato (fee = roundi(1% × preço) arredonda para 0 abaixo de 50).
# São contadas e nomeadas; nunca somadas em created nem destroyed.
const FSZeroRoots : PackedStringArray = ["clawback", "ah_creator_fee", "fs_nc_zero"]
# Moeda é {gold, gems}. Todo o resto é subproduto do ledger. Se um kind NOVO
# aparecer na população, FS7 falha e alguém tem que dizer em voz alta se ele é
# moeda — régua que ignora kind desconhecido é régua que deixa vazar.
const FSNonCurrencyKinds : PackedStringArray = [
	"item", "xp", "essence", "boss_key", "cosmetic", "vip", "pass", "pass_pt"]

var checks : int = 0
var failures : int = 0
var opsDone : int = 0
var _grantEnqueues : int = 0
var _clawbackEnqueues : int = 0
var _refundTries : int = 0
var _addRejects : int = 0

var _launcher : Node
var _sql : Node
var _eco : Node
var _rng : RandomNumberGenerator
var _gemsKind : String = "gems"
var _goldKind : String = "gold"

# Prefixo de payment DISTINTO POR EXECUÇÃO. A semente é fixa (ver o cabeçalho), e
# isto roda no sandbox persistente `.test-home/`: com chaves literais, a segunda
# execução reenfileirava `fuzzpay_1` sobre a linha da PRIMEIRA execução — UNIQUE
# global em `idempotency_key` — e nada chegava à conta nova. A régua ficava vermelha
# por inércia de fixture, não por comportamento do servidor. Um sufixo de relógio
# não enfraquece nada: a trajetória (ordem, montantes, colisões de chave dentro do
# run) continua a mesma, e a idempotência pressionada é a do próprio run.
var _payPrefix : String = "fuzzpay_"

# ------------------------------------------------------------------ fatia AH (059)
# Contas/personagens do mercado falso, o item EXCLUSIVO deles e o total de ouro
# que nós mesmos criamos neles. `_ahMinted` é a âncora da invariante de
# conservação: se uma liberação de escrow errar o centavo, é aí que aparece.
var _ahChars : Array = []
var _ahAccounts : Array = []
var _ahMinted : int = 0
var _ahGranted : int = 0
var _ahItem : int = 0
var _listFeeGems : int = 5
var _ahLists : int = 0
var _ahBids : int = 0
var _ahBuys : int = 0
var _ahBidCancels : int = 0
var _ahRejected : int = 0
var _ahFuzzChecked : int = 0
# Interleave (059 + §8): as contas do mercado TAMBÉM recebem a trajetória de gemas
# IAP (grant → chargeback → refund). É o único jeito de pressionar, na MESMA
# carteira, o par "gasta-gema-na-taxa-de-anúncio" (ah_list_fee) e "devolve-gema-
# paga" (estorno): o buraco do chargeback (I2, `not_paid`) e o buraco de escrow de
# ouro (I8) têm que valer ao mesmo tempo, no mesmo account_id, sob a mesma fila de
# grants. Prefixo de payment À PARTE (`_ahPayPrefix`) para que o portão `not_paid`
# não colida com os payments da trajetória de dinheiro e as réguas I1..I4 passem a
# valer sobre um ledger que agora mistura grant de IAP, taxa de leilão e estorno.
var _ahPayPrefix : String = "fuzzahp_"
var _ahGemGrants : int = 0
var _ahGemClawbacks : int = 0
var _ahGemRefunds : int = 0
# Censo de débito de gema paga (IG2c): motivo -> linhas, e motivo -> gemas. O
# contador existe porque a régua antiga pedia um "estado legal" sem nome; agora
# cada débito fora do gate de origem tem que aparecer aqui com o seu motivo.
var _paidDrainRoots : Dictionary = {}
var _paidDrainGems : Dictionary = {}

# Trajetória: quais chaves já foram enfileiradas, por qual conta, e quantas vezes
# a fila as processou. É o que permite afirmar "este grant virou UMA linha" em vez
# de contar o mundo.
var _grantKeys : Dictionary = {}
var _clawbackKeys : Dictionary = {}
var _accounts : Array = []

func _note(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	return condition

func _initialize():
	print("== Economy invariant fuzz (seed %d, %d contas, %d ops) ==" % [FixSeed, FixAccounts, FixOps])
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
	var ecoCat : GDScript = load("res://sources/economy/EconomyCatalog.gd")
	var catConsts : Dictionary = ecoCat.get_script_constant_map()
	_gemsKind = str(catConsts.get("LedgerKindGems", "gems"))
	_goldKind = str(catConsts.get("LedgerKindGold", "gold"))
	_listFeeGems = int(catConsts.get("AHListFeeGems", 5))
	_rng = RandomNumberGenerator.new()
	_rng.seed = FixSeed

	_makeAccounts()
	_runOps()
	_sweep("fim da trajetória")
	_reportTrajectory()
	_collisionSuite()
	_ahFuzz()
	_finish()

func _finish():
	print("== FUZZ: %d checks, %d failures ==" % [checks, failures])
	var db : Node = _launcher.get("DB")
	if db != null:
		db.call("DrainPendingPreloads")
	quit(failures)

# ------------------------------------------------------------------ fixtures
func _makeAccounts() -> void:
	var tag : int = int(Time.get_unix_time_from_system())
	_payPrefix = "fuzzpay%d_" % tag
	var nc : GDScript = load("res://sources/network/NetworkCommons.gd")
	var consts : Dictionary = nc.get_script_constant_map()
	for i in range(FixAccounts):
		var name : String = "fuz_%d_%d" % [tag, i]
		var ok : bool = bool(_sql.call("AddAccount", name, "senha-de-fuzz-123",
			name + "@fuzz.test.local", consts.get("AgreementTosVersion"),
			consts.get("AgreementPrivacyVersion"), "203.0.113.9"))
		_note(ok, "fixture de fuzz criada (%s)" % name)
		if not ok:
			continue
		var accountID : int = int(_sql.call("GetAccountID", name))
		_accounts.append(accountID)
		# Partir de zero é o que torna a soma do ledger comparável ao saldo: sem
		# isso a invariante 1 não pode ser asserida, só conferida como delta.
		_note(_gems(accountID) == 0 and _ledgerSum(accountID) == 0,
			"fixture começa com saldo e ledger em zero (conta %d)" % accountID)

# ------------------------------------------------------------------ trajetória
func _runOps() -> void:
	for step in range(FixOps):
		var accountID : int = int(_accounts[_rng.randi_range(0, _accounts.size() - 1)])
		var op : int = _rng.randi_range(0, 5)
		if op == 0:
			_opGrant(accountID)
		elif op == 1:
			_opChargeback(accountID)
		elif op == 2:
			_opRefund(accountID)
		elif op == 3:
			_opProcess()
		elif op == 4:
			_opAdd(accountID, _rng.randi_range(1, 400))
		else:
			_opAdd(accountID, -_rng.randi_range(1, 400))
		opsDone += 1
		if opsDone % FullSweepEvery == 0:
			_sweep("op %d" % opsDone)

func _opGrant(accountID : int) -> void:
	var key : String = _payPrefix + str(_rng.randi_range(1, FixPayments))
	var amount : int = [1, 50, 550, 1000, 999999][_rng.randi_range(0, 4)]
	var price : int = [0, 4990, 9990][_rng.randi_range(0, 2)]
	_grantKeys[key] = int(_grantKeys.get(key, 0)) + 1
	_grantEnqueues += 1
	_eco.call("EnqueueGrant", accountID, "gems", amount, key, '{"sku":"fuzz"}', price, "BRL")

func _opChargeback(accountID : int) -> void:
	var pay : String = _payPrefix + str(_rng.randi_range(1, FixPayments))
	# Duas formas de re-enfileirar o mesmo payment: a chave canônica e uma chave
	# nova. A UNIQUE pega a primeira; só a pré-checagem por payment_id pega a
	# segunda, e é ela que o fuzz interessa pressionar.
	var key : String = pay + (":chargeback" if _rng.randf() < 0.6 else (":cb_%d" % _rng.randi_range(1, 5)))
	_clawbackKeys[pay] = int(_clawbackKeys.get(pay, 0)) + 1
	_clawbackEnqueues += 1
	_eco.call("EnqueueGrant", accountID, "chargeback", [550, 1000, 5000][_rng.randi_range(0, 2)],
		key, '{"payment_id":"%s","sku":"fuzz"}' % pay, 4990, "BRL")

func _opRefund(accountID : int) -> void:
	_refundTries += 1
	_eco.call("RequestGemRefund", accountID, _payPrefix + str(_rng.randi_range(1, FixPayments)))

func _opProcess() -> void:
	_eco.call("ProcessPendingGrants", _rng.randi_range(1, 20))

func _opAdd(accountID : int, amount : int) -> void:
	if not bool(_eco.call("AddGems", accountID, amount, "fuzz:delta")):
		_addRejects += 1

# ------------------------------------------------------------------ invariantes
func _gems(accountID : int) -> int:
	return int(_sql.call("GetGems", accountID))

func _paid(accountID : int) -> int:
	return int(_sql.call("GetGemsPaid", accountID))

func _ledgerSum(accountID : int) -> int:
	var rows : Array = _sql.call("QueryBindings",
		"SELECT COALESCE(SUM(amount),0) AS s FROM ledger_transaction WHERE account_id = ? AND kind = ?;",
		[accountID, _gemsKind])
	return 0 if rows.is_empty() else int((rows[0] as Dictionary).get("s", 0))

func _lastBalance(accountID : int) -> int:
	var rows : Array = _sql.call("QueryBindings",
		"SELECT balance_after AS b FROM ledger_transaction WHERE account_id = ? AND kind = ? ORDER BY id DESC LIMIT 1;",
		[accountID, _gemsKind])
	return -1 if rows.is_empty() else int((rows[0] as Dictionary).get("b", -1))

func _countReason(accountID : int, reason : String) -> int:
	var rows : Array = _sql.call("QueryBindings",
		"SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason = ?;",
		[accountID, reason])
	return 0 if rows.is_empty() else int((rows[0] as Dictionary).get("n", 0))

func _sweep(at : String) -> void:
	for accountID in _accounts:
		var gems : int = _gems(accountID)
		var paid : int = _paid(accountID)
		var sum : int = _ledgerSum(accountID)
		# I1 — saldo nunca negativo. Um saldo assim vira gem infinita para o lado
		# de lá e é o que o portão de origem do estorno não consegue reconstituir.
		_note(gems >= 0, "I1 saldo não-negativo (%s conta %d gems=%d)" % [at, accountID, gems])
		# I2 — `gems_paid <= gems` é o que faz o gate `not_paid` do art.49 ser prova
		# de ORIGEM e não contagem de saldo; violado, o chargeback toma gem grátis.
		_note(paid >= 0 and paid <= gems, "I2 paid dentro de [0, gems] (%s conta %d gems=%d paid=%d)" % [at, accountID, gems, paid])
		# I3 — o ledger espelha a carteira (invariante 1 de EconomyKernel.AddGems).
		# É a única coisa que torna o saldo auditável depois do fato.
		_note(sum == gems, "I3 ledger bate com a carteira (%s conta %d gems=%d soma=%d)" % [at, accountID, gems, sum])
		# I4 — `balance_after` da última linha é o saldo. Uma mutação que mexe na
		# carteira sem lançar linha aparece aqui e não em I3 (delta 0 disfarça).
		# Sem linha nenhuma, porém, "-1" não é divergência: é a conta intocada, e
		# a asserção honesta aí é o lado oposto — intocada NÃO pode ter saldo.
		var last : int = _lastBalance(accountID)
		if last >= 0:
			_note(last == gems, "I4 último balance_after é o saldo (%s conta %d gems=%d last=%d)" % [at, accountID, gems, last])
		else:
			_note(gems == 0, "I4 conta sem linha de ledger está zerada (%s conta %d gems=%d)" % [at, accountID, gems])
	# I5/I6 olham a trajetória inteira (uma chave pode ter sido re-enfileirada 9
	# vezes); conferir isso a cada 25 ops multiplicaria o custo sem achar nada que
	# a leitura final não ache.
	if at == "fim da trajetória":
		_sweepUniqueReasons()

func _sweepUniqueReasons() -> void:
	# I5 — idempotência por chave: a mesma entrega nunca vira duas linhas. É o
	# buraco que a janela 'pending → creditado → marcado' abria (SOM-IDLE E3).
	for key in _grantKeys:
		for accountID in _accounts:
			_note(_countReason(accountID, "grant:" + str(key)) <= 1,
				"I5 grant aplicado no máximo uma vez (chave %s conta %d)" % [key, accountID])
	# I6 — clawback por payment, não por tentativa: cobrar duas vezes o mesmo
	# payment debitaria duas vezes a mesma compra.
	for pay in _clawbackKeys:
		for accountID in _accounts:
			_note(_countReason(accountID, "clawback:" + str(pay)) <= 1,
				"I6 clawback único por payment (payment %s conta %d)" % [pay, accountID])

func _reasonRows(pattern : String) -> int:
	var rows : Array = _sql.call("QueryBindings",
		"SELECT COUNT(*) AS n FROM ledger_transaction WHERE kind = ? AND reason LIKE ? AND account_id IN (%s);" % _idsSql(),
		[_gemsKind, pattern])
	return 0 if rows.is_empty() else int((rows[0] as Dictionary).get("n", 0))

func _idsSql() -> String:
	var parts : Array = []
	for accountID in _accounts:
		parts.append(str(accountID))
	return ",".join(parts)

# Cobertura: um fuzz que não mexeu em nada é verde por inércia, e isso não é
# evidência de nada. Os números abaixo são lidos do banco no fim da trajetória —
# são a diferença entre "passei 30 s rodando" e "300 grants entraram na fila,
# 40 payments foram contestados, o saldo chegou a X e bate com o ledger".
func _reportTrajectory() -> void:
	var grantRows : int = _reasonRows("grant:" + _payPrefix + "%")
	var clawRows : int = _reasonRows("clawback:" + _payPrefix + "%")
	var refundRows : int = _reasonRows("refund:" + _payPrefix + "%")
	print("  [info] %d ops em %d contas | %d grants enfileirados (%d chaves distintas) | %d contestações (%d payments) | %d estornos tentados | %d linhas: %d grant / %d clawback / %d refund | %d AddGems recusados" % [
		opsDone, _accounts.size(), _grantEnqueues, _grantKeys.size(), _clawbackEnqueues,
		_clawbackKeys.size(), _refundTries, grantRows + clawRows + refundRows, grantRows, clawRows, refundRows, _addRejects])
	_note(opsDone == FixOps, "a trajetória inteira foi executada (%d/%d ops)" % [opsDone, FixOps])
	_note(_grantEnqueues > _grantKeys.size(), "chaves foram re-enfileirada: a idempotência foi pressionada, não evitada (%d enfileiramentos p/ %d chaves)" % [_grantEnqueues, _grantKeys.size()])
	_note(grantRows >= 1 and grantRows <= _grantEnqueues, "pelo menos um grant chegou à carteira sem mais linhas do que enfileiramentos (%d linhas p/ %d enfileiramentos)" % [grantRows, _grantEnqueues])
	_note(clawRows >= 1 and clawRows <= _clawbackEnqueues, "pelo menos um clawback chegou ao ledger sem mais linhas do que contestações (%d linhas p/ %d enfileiramentos)" % [clawRows, _clawbackEnqueues])
	_note(_refundTries >= 1, "o caminho de estorno foi exercitado (%d tentativas)" % _refundTries)
	_note(_addRejects >= 1, "débitos acima do saldo foram recusados em vez de aplicar (%d recusas)" % _addRejects)

# ------------------------------------------------- I7: a idempotência é por conta
# Nasceu de um buraco que o próprio fuzz expôs ao rodar duas vezes no mesmo
# sandbox: `idempotency_key` tem UNIQUE GLOBAL (migration 015), e o pré-check de
# `EnqueueGrant` conferia só a chave. Reapresentar uma chave que já é de outra
# conta devolvia `true` — "está na fila" — sem inserir nada: dinheiro que some com
# resposta de sucesso. É o inverso do que a idempotência promete (proteger a
# reentrega do MESMO payment) e é o tipo de caso que nenhuma trajetória aleatória
# encontra sozinho: precisa de duas contas e uma chave compartilhada de propósito.
func _collisionSuite() -> void:
	if _accounts.size() < 2:
		_note(false, "a colisão de chave precisa de duas contas de fixture (%d)" % _accounts.size())
		return
	var a : int = int(_accounts[0])
	var b : int = int(_accounts[1])
	var key : String = _payPrefix + "clash"
	var gemsBefore : int = _gems(b)
	_note(bool(_eco.call("EnqueueGrant", a, "gems", 550, key, '{"sku":"fuzz"}', 4990, "BRL")),
		"I7 grant da conta A enfileirado")
	_note(bool(_eco.call("EnqueueGrant", a, "gems", 550, key, '{"sku":"fuzz"}', 4990, "BRL")),
		"I7 reentrega na MESMA conta é idempotente (true, sem segunda linha)")
	_note(_queueRows(key) == 1, "I7 reentrega não duplicou a linha da fila (%d)" % _queueRows(key))
	_note(not bool(_eco.call("EnqueueGrant", b, "gems", 550, key, '{"sku":"fuzz"}', 4990, "BRL")),
		"I7 mesma chave em OUTRA conta é recusada, não 'já na fila' silencioso")
	_note(_queueRows(key) == 1, "I7 a recusa não abriu linha na fila (%d)" % _queueRows(key))
	_note(_gems(b) == gemsBefore, "I7 a conta preterida não recebeu nada")
	# E o que foi aceito chega: sem isso a "recusa" verde poderia ser só uma fila
	# que não processa nada.
	_eco.call("ProcessPendingGrants", 50)
	_note(_reasonRowsFor(a, "grant:" + key) == 1, "I7 o grant aceito virou exatamente uma linha de ledger")
	_sweep("depois da colisão")

func _queueRows(key : String) -> int:
	var rows : Array = _sql.call("QueryBindings",
		"SELECT COUNT(*) AS n FROM grant_queue WHERE idempotency_key = ?;", [key])
	return 0 if rows.is_empty() else int((rows[0] as Dictionary).get("n", 0))

func _reasonRowsFor(accountID : int, reason : String) -> int:
	var rows : Array = _sql.call("QueryBindings",
		"SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason = ?;",
		[accountID, reason])
	return 0 if rows.is_empty() else int((rows[0] as Dictionary).get("n", 0))

# ------------------------------------------------- I8..I13: escrow de gold no leilão
#
# Por que esta fatia entrou no fuzzer e não num harness de caso: a ordem de compra
# de 059(c) é a primeira operação do leilão que TIRA ouro da carteira sem que nada
# seja vendido naquele instante. Ela só volta a ser ouro de alguém em três
# situações (estorno de cancelamento, pagamento ao vendedor, sobra depois do fill),
# e cada uma tem um caminho diferente no mesmo `kernel._MoveGoldLocked`. Isso é o
# formato exato do defeito que este arquivo caça: duas operações legalmente
# individuais, intercaladas, e o centavo some ou aparece. Um harness de caso cobre
# a sequência que alguém imaginou; aqui a sequência é sorteada e as invariantes são
# conferidas DEPÓSITO A DEPÓSITO.
#
# Âncora: `_ahMinted` é o ouro que NÓS criamos nestas contas. Como o leilão não
# queima gold (a taxa de anúncio é em GEMAS), a soma "carteira de todos + escrow
# aberto de todos" tem que ser esse número em qualquer instante da trajetória.
func _ahFuzz() -> void:
	print("[ah] fatia de mercado (059c): %d personagens, %d ops sorteadas" % [AHChars, AHOps])
	var tag : int = int(Time.get_unix_time_from_system())
	_ahPayPrefix = "fuzzahp%d_" % tag
	var nc : GDScript = load("res://sources/network/NetworkCommons.gd")
	var consts : Dictionary = nc.get_script_constant_map()
	var ac : GDScript = load("res://sources/actor/ActorCommons.gd")
	_ahItem = absi(str("fuzzah_%d_%d" % [tag, FixSeed]).hash())
	for i in range(AHChars):
		var name : String = "fuzah_%d_%d" % [tag, i]
		if not bool(_sql.call("AddAccount", name, "senha-de-fuzz-123", name + "@fuzz.test.local",
				consts.get("AgreementTosVersion"), consts.get("AgreementPrivacyVersion"), "203.0.113.9")):
			_note(false, "fixture de mercado criada (%s)" % name)
			continue
		var accountID : int = int(_sql.call("GetAccountID", name))
		var nick : String = name + "_char"
		if not bool(_sql.call("AddCharacter", accountID, nick, ac.get("DefaultStats"),
				ac.get("DefaultTraits"), ac.get("DefaultAttributes"))):
			_note(false, "personagem de mercado criado (%s)" % nick)
			continue
		var charID : int = int(_sql.call("GetCharacterID", accountID, nick))
		_ahAccounts.append(accountID)
		_ahChars.append(charID)
		_note(bool(_eco.call("MoveGold", charID, AHGoldEach, "fuzzah_mint")), "gold de mercado mintado (%d)" % charID)
		_ahMinted += AHGoldEach
		_note(bool(_eco.call("AddGems", accountID, 100000, "fuzzah_gems")), "gemas de taxa mintadas (%d)" % accountID)
		_note(bool(_sql.call("AddItemToCharacter", charID, _ahItem, AHItemsEach, "fuzzah_items")), "itens de mercado dados (%d)" % charID)
		_ahGranted += AHItemsEach
	if _ahChars.size() < 2:
		_note(false, "a fatia de mercado precisa de pelo menos dois personagens (%d)" % _ahChars.size())
		return
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = FixSeed * 7 + 13
	for step in range(AHOps):
		_ahOp(rng, step)
		_ahSweep("op %d" % step)
	_ahReport()
	# Limpeza: as ordens abertas ficam com ouro escrowed, e é o estado que a
	# próxima execução reencontraria como divergência falsa.
	for o in _sql.call("QueryBindings", "SELECT id, buyer_char FROM ah_buy_order WHERE item_id = ? AND status = 'open';", [_ahItem]):
		_eco.call("CancelBuyOrder", int((o as Dictionary).get("buyer_char", 0)), int((o as Dictionary).get("id", 0)))
	for l in _sql.call("QueryBindings", "SELECT id, seller_char FROM auction_listing WHERE item_id = ? AND status = 'open';", [_ahItem]):
		_eco.call("CancelListing", int((l as Dictionary).get("seller_char", 0)), int((l as Dictionary).get("id", 0)))
	_ahSweep("depois da limpeza")

func _ahOp(rng : RandomNumberGenerator, step : int) -> void:
	# A contagem é da TRAJETÓRIA, não do resultado: um passo que descobre a vitrine
	# vazia e desiste também percorreu o caminho e também varreu os invariantes. Se
	# contássemos só os passos que mexeram em algo, "697/700" viraria uma falha do
	# harness por construção, não uma queda de cobertura do mercado.
	_ahFuzzChecked += 1
	var actor : int = int(_ahChars[rng.randi_range(0, _ahChars.size() - 1)])
	# Interleave: a carteira que faz a operação de mercado é a mesma que recebe o
	# golpe de IAP (grant/chargeback/refund/process) no MESMO passo. É isto, e não
	# uma fatia de gemas separada, que força o ledger a manter I1..I4 (gemas) e
	# I8..I13 (ouro/escrow) verdadeiros ao mesmo tempo, no mesmo account_id.
	var actorAccount : int = int(_sql.call("GetAccountIDForCharacter", actor))
	if rng.randf() < 0.45 and actorAccount != 0:
		_ahGemOp(rng, actorAccount)
	var roll : int = rng.randi_range(0, 9)
	if roll <= 3:
		# Anunciar: tranca ITEM e cobra GEMA. É o par da ordem, que tranca OURO.
		var count : int = rng.randi_range(1, 3)
		var price : int = [1, 200, 700, 1500, 90000][rng.randi_range(0, 4)]
		var id : int = int(_eco.call("ListItemForSale", actor, _ahItem, count, price))
		if id > 0:
			_ahLists += 1
		else:
			_ahRejected += 1
	elif roll <= 6:
		var qty : int = rng.randi_range(1, 4)
		var cap : int = [1, 250, 900, 2000, 100000][rng.randi_range(0, 4)]
		var order : int = int(_eco.call("PlaceBuyOrder", actor, _ahItem, qty, cap))
		if order > 0:
			_ahBids += 1
		else:
			_ahRejected += 1
	elif roll == 7:
		var open : Array = _sql.call("QueryBindings", "SELECT id FROM auction_listing WHERE item_id = ? AND status = 'open';", [_ahItem])
		if open.is_empty():
			return
		var pick : int = int((open[rng.randi_range(0, open.size() - 1)] as Dictionary).get("id", 0))
		if bool(_eco.call("BuyListing", actor, pick)):
			_ahBuys += 1
		else:
			_ahRejected += 1
	elif roll == 8:
		var held : Array = _sql.call("QueryBindings", "SELECT id, seller_char FROM auction_listing WHERE item_id = ? AND status = 'open';", [_ahItem])
		if held.is_empty():
			return
		var row : Dictionary = held[rng.randi_range(0, held.size() - 1)]
		if bool(_eco.call("CancelListing", int(row.get("seller_char", 0)), int(row.get("id", 0)))):
			_ahLists -= 1
		else:
			_ahRejected += 1
	else:
		var orders : Array = _sql.call("QueryBindings", "SELECT id, buyer_char FROM ah_buy_order WHERE item_id = ? AND status = 'open';", [_ahItem])
		if orders.is_empty():
			return
		var row2 : Dictionary = orders[rng.randi_range(0, orders.size() - 1)]
		if bool(_eco.call("CancelBuyOrder", int(row2.get("buyer_char", 0)), int(row2.get("id", 0)))):
			_ahBidCancels += 1
		else:
			_ahRejected += 1

# Mesma gramática de IAP da trajetória de dinheiro (grant/chargeback/refund/
# process/add), mas sobre a conta que está fazendo mercado e com payment prefix
# próprio. Não é um "segundo fuzzer de gemas": é o mesmo `EnqueueGrant`/
# `ProcessPendingGrants`/`RequestGemRefund` caindo numa carteira que acabou de
# QUEIMAR gema em taxa de anúncio — o único cenário em que o portão `not_paid` do
# estorno e o ledger de `ah_list_fee` têm que bater ao mesmo tempo.
func _ahGemOp(rng : RandomNumberGenerator, accountID : int) -> void:
	var roll : int = rng.randi_range(0, 5)
	if roll == 0:
		var key : String = _ahPayPrefix + str(rng.randi_range(1, 40))
		_eco.call("EnqueueGrant", accountID, "gems", [1, 50, 550, 1000, 999999][rng.randi_range(0, 4)],
			key, '{"sku":"fuzzah"}', [0, 4990, 9990][rng.randi_range(0, 2)], "BRL")
		_ahGemGrants += 1
	elif roll == 1:
		var pay : String = _ahPayPrefix + str(rng.randi_range(1, 40))
		var ckey : String = pay + (":chargeback" if rng.randf() < 0.6 else (":cb_%d" % rng.randi_range(1, 5)))
		_eco.call("EnqueueGrant", accountID, "chargeback", [550, 1000, 5000][rng.randi_range(0, 2)],
			ckey, '{"payment_id":"%s","sku":"fuzzah"}' % pay, 4990, "BRL")
		_ahGemClawbacks += 1
	elif roll == 2:
		_eco.call("RequestGemRefund", accountID, _ahPayPrefix + str(rng.randi_range(1, 40)))
		_ahGemRefunds += 1
	elif roll == 3:
		_eco.call("ProcessPendingGrants", rng.randi_range(1, 20))
	elif roll == 4:
		_eco.call("AddGems", accountID, rng.randi_range(1, 400), "fuzzah:delta")
	else:
		_eco.call("AddGems", accountID, -rng.randi_range(1, 400), "fuzzah:delta")

func _ahGoldSum() -> int:
	var total : int = 0
	for charID in _ahChars:
		total += int(_eco.call("_CharGoldRaw", int(charID)))
	return total

func _ahEscrowSum() -> int:
	var rows : Array = _sql.call("QueryBindings",
		"SELECT COALESCE(SUM(escrow_gold),0) AS s FROM ah_buy_order WHERE item_id = ? AND status = 'open';", [_ahItem])
	return 0 if rows.is_empty() else int((rows[0] as Dictionary).get("s", 0))

func _ahSweep(at : String) -> void:
	var wallets : int = _ahGoldSum()
	var escrow : int = _ahEscrowSum()
	# I8 — conservação. O leilão não cria nem destrói ouro: tudo que sai de uma
	# carteira ou está na outra ou está no escrow de uma ordem em pé.
	_note(wallets + escrow == _ahMinted,
		"I8 ouro conservado (%s): carteiras %d + escrow %d != minted %d" % [at, wallets, escrow, _ahMinted])
	# I9 — nenhuma carteira negativa. Ouro negativo é faucet infinito para o par.
	for charID in _ahChars:
		var gold : int = int(_eco.call("_CharGoldRaw", int(charID)))
		_note(gold >= 0, "I9 carteira de gold não-negativa (%s char %d = %d)" % [at, charID, gold])
	# I10 — o escrow é a demanda, unidade a unidade: se `quantity × unit_price` e
	# `escrow_gold` divergem, ou há ouro preso ou há demanda comprando com ouro que
	# ninguém depositou.
	var broken : int = 0
	for row in _sql.call("QueryBindings",
			"SELECT id, quantity, unit_price, escrow_gold FROM ah_buy_order WHERE item_id = ? AND status = 'open';", [_ahItem]):
		var o : Dictionary = row
		if int(o.get("escrow_gold", 0)) != int(o.get("quantity", 0)) * int(o.get("unit_price", 0)):
			broken += 1
	_note(broken == 0, "I10 escrow == quantity × unit_price em toda ordem aberta (%s, %d ruins)" % [at, broken])
	var stuck : int = int(_sql.call("QueryBindings",
		"SELECT COUNT(*) AS n FROM ah_buy_order WHERE item_id = ? AND status <> 'open' AND escrow_gold > 0;", [_ahItem])[0].get("n", 0))
	_note(stuck == 0, "I10 nenhuma ordem fechada reteve ouro (%s, %d presas)" % [at, stuck])
	# I11 — o ledger de gold é o espelho da carteira em cada conta. É a invariante
	# do kernel, e a que um débito/estorno mal emparelhado quebra primeiro.
	for accountID in _ahAccounts:
		var ledger : int = int(_eco.call("GetGoldLedgerSum", int(accountID)))
		var wallet : int = 0
		for charID in _ahChars:
			if int(_sql.call("GetAccountIDForCharacter", int(charID))) == int(accountID):
				wallet += int(_eco.call("_CharGoldRaw", int(charID)))
		_note(ledger == wallet, "I11 ledger de gold bate com a carteira (%s conta %d ledger=%d carteira=%d)" % [at, accountID, ledger, wallet])
	# I12 — uma linha de preço realizado por anúncio liquidado, sem exceção.
	var soldRows : int = int(_sql.call("QueryBindings",
		"SELECT COUNT(*) AS n FROM auction_listing WHERE item_id = ? AND status = 'sold';", [_ahItem])[0].get("n", 0))
	var histRows : int = int(_sql.call("QueryBindings",
		"SELECT COUNT(*) AS n FROM ah_price_history WHERE item_id = ?;", [_ahItem])[0].get("n", 0))
	_note(soldRows == histRows, "I12 uma linha de histórico por venda (%s: %d vendas / %d linhas)" % [at, soldRows, histRows])
	# I13 — o item também se conserva: o escrow de gold não pode inventar lote, e o
	# fill parcial não pode entregar duas vezes a mesma unidade.
	var stock : int = int(_sql.call("QueryBindings",
		"SELECT COALESCE(SUM(count),0) AS s FROM item WHERE item_id = ? AND storage = 0;", [_ahItem])[0].get("s", 0))
	var listed : int = int(_sql.call("QueryBindings",
		"SELECT COALESCE(SUM(count),0) AS s FROM auction_listing WHERE item_id = ? AND status = 'open';", [_ahItem])[0].get("s", 0))
	_note(stock + listed == _ahGranted,
		"I13 unidades conservadas (%s: %d em carteira + %d em escrow != %d concedidas)" % [at, stock, listed, _ahGranted])
	# Interleave (IG): as MESMAS contas que seguram escrow de ouro também mexeram
	# em gemas IAP e gastaram gema de taxa de anúncio. As réguas I1..I4 valem aqui
	# sobre um ledger que agora mistura grant, clawback, refund e `ah_list_fee`. Se
	# o estorno tomar gema que a taxa já queimou (paid > wallet) ou uma linha não
	# espelhada aparecer, cai aqui — e é exatamente a contaminação cruzada que a
	# separação anterior das duas trajetórias não conseguia ver.
	for accountID in _ahAccounts:
		var gems : int = _gems(accountID)
		var gsum : int = _ledgerSum(accountID)
		var glast : int = _lastBalance(accountID)
		# IG1 — saldo de gemas não-negativo. É o que o estorno NÃO pode furar mesmo
		# com a taxa de leilão (`SetGemsRaw`) tendo queimado carteira paga: o
		# chargeback tira de `paid` mas respeita o piso do saldo. Um saldo negativo
		# aqui é faucet para o par — e é o motivo de este interleave existir.
		_note(gems >= 0, "IG1 saldo de gemas não-negativo no mercado (%s conta %d=%d)" % [at, accountID, gems])
		# IG3/IG4 — o ledger de gemas espelha a carteira mesmo com grant de IAP,
		# clawback, refund E a linha `ah_list_fee` (SetGemsRaw + _LedgerAppendLocked)
		# todas no mesmo kind. Uma que escreve carteira sem linha (ou linha sem
		# carteira) aparece aqui.
		# IG2 — `gems_paid <= gems`, ASSERTO. A versão anterior desta régua declarava
		# o estado "inalcançável" porque "a taxa de anúncio gasta gemas pagas por fora
		# do gate de origem"; ela não gasta por fora: `ah_list_fee` queima saldo pelo
		# ÚNICO writer de `wallet.gems` (`SQL.SetGemsRaw`), e esse writer clampa
		# `gems_paid` a `[0, gems]` na mesma escrita (sources/sql/SQL.gd:1146 —
		# `newPaid = clampi(paid - spent, 0, max(0, gems))`). Uma taxa pode levar
		# `paid` junto com `gems`, nunca deixá-lo ACIMA da carteira. `paid > gems` não
		# é estado legal do leilão: é writer fora do funil, e é exatamente isso que
		# o clawback (`CheckoutService.gd:379`, teto `clampi(paid, 0, saldo)`) e o
		# `not_paid` do art.49 (`:722`) leem como se fosse verdade de origem. Régua que
		# o próprio detector declara inalcançável é buraco de auditoria, não escolha:
		# a sensibilidade do predicado é conferida por sonda em `_ig2Probe()`.
		var paid : int = _paid(accountID)
		_note(paid >= 0 and paid <= gems, "IG2 paid dentro de [0, gems] no mercado (%s conta %d gems=%d paid=%d)" % [at, accountID, gems, paid])
		# IG3/IG4 — o ledger de gemas espelha a carteira mesmo com grant de IAP,
		# clawback, refund E a linha `ah_list_fee` (SetGemsRaw + _LedgerAppendLocked)
		# todas no mesmo kind. Uma que escreve carteira sem linha (ou linha sem
		# carteira) aparece aqui. IG2 (`paid <= gems`) é deliberadamente NÃO-asserto
		# nestas contas: a taxa de anúncio gasta gemas pagas por fora do gate de
		# origem, então `paid > wallet` é estado legal do leilão, não buraco.
		_note(gsum == gems, "IG3 ledger de gemas bate com a carteira (%s conta %d gems=%d soma=%d)" % [at, accountID, gems, gsum])
		if glast >= 0:
			_note(glast == gems, "IG4 última balance_after de gemas é o saldo (%s conta %d gems=%d last=%d)" % [at, accountID, gems, glast])

# Cobertura da fatia: um fuzz que não mexeu em nada é verde por inércia. Estes
# números saem do banco no fim, não de contador otimista.
func _ahReport() -> void:
	var sold : int = 0
	var hist : int = 0
	var filled : int = 0
	var openBids : int = 0
	sold = int(_sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM auction_listing WHERE item_id = ? AND status = 'sold';", [_ahItem])[0].get("n", 0))
	hist = int(_sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM ah_price_history WHERE item_id = ?;", [_ahItem])[0].get("n", 0))
	filled = int(_sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM ah_buy_order WHERE item_id = ? AND status = 'filled';", [_ahItem])[0].get("n", 0))
	openBids = int(_sql.call("QueryBindings", "SELECT COUNT(*) AS n FROM ah_buy_order WHERE item_id = ? AND status = 'open';", [_ahItem])[0].get("n", 0))
	print("  [ah] %d ops | %d anúncios vivos / %d vendas / %d linhas de histórico | %d ordens preenchidas / %d abertas / %d canceladas | %d recusas | ouro final: carteiras %d + escrow %d = %d" % [
		_ahFuzzChecked, _ahLists, sold, hist, filled, openBids, _ahBidCancels, _ahRejected,
		_ahGoldSum(), _ahEscrowSum(), _ahGoldSum() + _ahEscrowSum()])
	_note(_ahFuzzChecked == AHOps, "a trajetória de mercado inteira foi executada (%d/%d)" % [_ahFuzzChecked, AHOps])
	_note(_ahLists >= 1, "pelo menos um anúncio nasceu (%d)" % _ahLists)
	_note(_ahBids >= 1, "pelo menos uma ordem de compra depositou ouro (%d colocadas)" % _ahBids)
	_note(sold >= 1, "o mercado fechou vendas (%d)" % sold)
	_note(hist >= 1, "e o preço realizado existe no servidor (%d)" % hist)
	_note(_ahBidCancels >= 1 or filled >= 1, "o escrow foi DEVOLVIDO ou GASTO, nunca ambos ao mesmo tempo (cancelamentos %d / preenchidas %d)" % [_ahBidCancels, filled])
	_note(_ahRejected >= 1, "recusas de saldo/cap/teto aconteceram no caminho (%d)" % _ahRejected)
	# O interleave tem que ter ACONTECIDO, senão IG1..IG4 são verde por inércia
	# (nenhuma gema IAP tocou as contas de mercado). Semente fixa ⇒ determinístico.
	_note(_ahGemGrants >= 1, "grant de IAP caiu sobre conta de mercado (%d)" % _ahGemGrants)
	_note(_ahGemClawbacks >= 1, "chargeback de IAP foi tentado em conta de mercado (%d)" % _ahGemClawbacks)
	_note(_ahGemRefunds >= 1, "refund de IAP foi tentado em conta de mercado (%d)" % _ahGemRefunds)
	_ahPaidAudit()
	_ig2Probe()

# IG2b/IG2c — o que a confissão antiga chamava de "estado legal" agora é MEDIDO:
# cada débito de gema paga destas contas tem exatamente um motivo, o motivo tem que
# ser reconhecível no catálogo de pias do produto (`EconomyKernel.CensusSinkFamilies`,
# lido do código, não redigitado aqui) e o total queimado por taxa vira contador.
# IG2b é o aperto de dois lados que só ledger + fila de grant sabem: `paid` nunca
# acima do que as linhas `grant:` creditaram COM preço (`grant_queue.price_paid > 0`)
# e nunca abaixo desse crédito menos o total dos débitos enumerados. O lado de baixo
# precisa da fila porque a carteira não conta origem: `SetGemsRaw` só sobe pago na
# perna paga do checkout, então um grant com `price_paid = 0` aparece na carteira
# sem aparecer em `paid` — e é isso que a confissão antiga confundia com "pago
# gasto por fora do gate".
func _ahPaidAudit() -> void:
	var kernelConsts : Dictionary = load("res://sources/economy/EconomyKernel.gd").get_script_constant_map()
	var sinkRoots : PackedStringArray = kernelConsts.get("CensusSinkFamilies", PackedStringArray())
	var known : Dictionary = {}
	for root in sinkRoots:
		known[str(root)] = true
	# Raiz do próprio fuzz: `AddGems(..., "fuzzah:delta")` endowment/reversal de
	# fixture. Não é writer do produto e é por isso que ela é NOMEADA aqui em vez de
	# entrar no catálogo do kernel.
	var harnessRoots : PackedStringArray = PackedStringArray(["fuzzah"])
	var feeBurned : int = 0
	var unattributed : int = 0
	var debits : int = 0
	for accountID in _ahAccounts:
		var rows : Array = _sql.call("QueryBindings",
			"SELECT substr(reason, 1, CASE WHEN instr(reason, ':') > 0 THEN instr(reason, ':') - 1 ELSE length(reason) END) AS family,"
			+ " COALESCE(SUM(-amount),0) AS burned, COUNT(*) AS n FROM ledger_transaction"
			+ " WHERE account_id = ? AND kind = ? AND amount < 0 GROUP BY family;", [accountID, _gemsKind])
		for r in rows:
			var rec : Dictionary = r as Dictionary
			var fam : String = str(rec.get("family", ""))
			var burned : int = int(rec.get("burned", 0))
			var n : int = int(rec.get("n", 0))
			debits += n
			if known.has(fam):
				_paidDrainRoots[fam] = int(_paidDrainRoots.get(fam, 0)) + n
				_paidDrainGems[fam] = int(_paidDrainGems.get(fam, 0)) + burned
				if fam == "ah_list_fee":
					feeBurned += burned
			elif harnessRoots.has(fam):
				_paidDrainRoots[fam] = int(_paidDrainRoots.get(fam, 0)) + n
			else:
				unattributed += n
				_paidDrainRoots["UNATTRIBUTED:" + fam] = int(_paidDrainRoots.get("UNATTRIBUTED:" + fam, 0)) + n
		var gems : int = _gems(accountID)
		var paid : int = _paid(accountID)
		# O aperto de `paid` não pode sair da carteira: `SetGemsRaw` só sobe a coluna
		# na perna de grant que o checkout REGISTRA como dinheiro (`grant_queue.
		# price_paid > 0`, migration 044). Uma linha `grant:` com price_paid 0 é
		# unidade de jogo disfarçada de pago, e linha sem perna na fila é tratada como
		# paga — o censo não acusa o que não pode provar.
		var grantCredit : int = int(_sql.call("QueryBindings",
			"SELECT COALESCE(SUM(amount),0) AS s FROM ledger_transaction WHERE account_id = ? AND kind = ? AND amount > 0 AND reason LIKE 'grant:%';",
			[accountID, _gemsKind])[0].get("s", 0))
		var freeGrantCredit : int = int(_sql.call("QueryBindings",
			"SELECT COALESCE(SUM(l.amount),0) AS s FROM ledger_transaction l JOIN grant_queue g"
			+ " ON g.idempotency_key = substr(l.reason, 7) AND g.account_id = l.account_id"
			+ " WHERE l.account_id = ? AND l.kind = ? AND l.amount > 0 AND l.reason LIKE 'grant:%' AND g.price_paid = 0;",
			[accountID, _gemsKind])[0].get("s", 0))
		var gemDebit : int = int(_sql.call("QueryBindings",
			"SELECT COALESCE(SUM(-amount),0) AS s FROM ledger_transaction WHERE account_id = ? AND kind = ? AND amount < 0;",
			[accountID, _gemsKind])[0].get("s", 0))
		var paidCredit : int = grantCredit - freeGrantCredit
		_note(paid >= 0 and paid <= paidCredit, "IG2b pago nunca acima do que o checkout registrou como dinheiro (conta %d paid=%d creditadoPagado=%d grantGratis=%d gems=%d)" % [accountID, paid, paidCredit, freeGrantCredit, gems])
		_note(paid >= maxi(0, paidCredit - gemDebit), "IG2b pago nunca abaixo do creditado pago menos os débitos enumerados (conta %d paid=%d creditadoPagado=%d debit=%d)" % [accountID, paid, paidCredit, gemDebit])
	print("  [paid] %d débitos de gema | por motivo: %s | taxa de anúncio queimada: %d gemas" % [debits, _paidDrainRoots.keys(), feeBurned])
	_note(unattributed == 0, "IG2c todo débito de gema fora do gate tem motivo enumerável (%d órfãos: %s)" % [unattributed, _paidDrainRoots.keys()])
	_note(int(_paidDrainRoots.get("ah_list_fee", 0)) >= 1 and feeBurned >= _listFeeGems,
		"IG2c a taxa de anúncio queimou gema paga e foi CONTADA (linhas %d, gemas %d)" % [int(_paidDrainRoots.get("ah_list_fee", 0)), feeBurned])

# Controle negativo do PREDICADO da IG2, plantado e medido: uma conta de sonda que
# ninguém varre recebe `gems_paid` ACIMA da carteira por UPDATE cru — o estado que a
# confissão antiga dizia ser "legal". Se a sonda não vermelhar o mesmo predicado que
# IG2 usa, a régua é ruído: ela não sabe falhar. A sonda é a última coisa do run e
# não entra em `_ahAccounts`, então nenhum dinheiro real é tocado.
func _ig2Probe() -> void:
	var tag : int = int(Time.get_unix_time_from_system())
	var name : String = "fuzig2_%d" % tag
	var nc : GDScript = load("res://sources/network/NetworkCommons.gd")
	var consts : Dictionary = nc.get_script_constant_map()
	if not bool(_sql.call("AddAccount", name, "senha-de-fuzz-123", name + "@fuzz.test.local",
			consts.get("AgreementTosVersion"), consts.get("AgreementPrivacyVersion"), "203.0.113.9")):
		_note(false, "sonda de IG2 criada (%s)" % name)
		return
	var probe : int = int(_sql.call("GetAccountID", name))
	_note(_gems(probe) == 0 and _paid(probe) == 0, "sonda nasce zerada (conta %d)" % probe)
	var balanceOK : bool = bool(_sql.call("SetGems", probe, 10))
	_note(balanceOK, "sonda recebe 10 gemas pelo funil (SetGems) — paid drena junto")
	_note(_paid(probe) <= _gems(probe), "IG2 vale na sonda antes do plantio (paid=%d gems=%d)" % [_paid(probe), _gems(probe)])
	var planted : int = _gems(probe) + 1
	var bitten : bool = not bool(_sql.call("ExecuteBindings", "UPDATE wallet SET gems_paid = ? WHERE account_id = ?;", [planted, probe])) \
		or _paid(probe) > _gems(probe)
	_note(bitten, "IG2 VERMELHA com gems_paid escrito por fora do funil (paid=%d gems=%d)" % [_paid(probe), _gems(probe)])
	_note(bool(_sql.call("SetGems", probe, _gems(probe))), "sonda re-normalizada pelo funil (paid volta ao teto do saldo: paid=%d gems=%d)" % [_paid(probe), _gems(probe)])
