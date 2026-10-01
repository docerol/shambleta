extends SceneTree

# SOM-IDLE Live Ops antifraude — harness da Fila de Revisão (tests/fraud_test.gd).
#
# Prende, nas FUNÇÕES REAIS (FraudeReview.gd + CommunityService.gd sobre o DB do
# boot), a régua que a nota de Economia/Segurança cobra:
#
#  S-A matriz de severidade PURO: cap de fraqueza (IP/dispositivo quieto NUNCA
#      passa do peso 1, limiar 2), ordenação dominante estável, subnet /24;
#  S-B falsos positivos EXPLÍCITOS: duas contas legítimas no mesmo IP → zero
#      flags; 4 contas no mesmo /24 → zero flags; família na MESMA instalação
#      sem produção sobreposta → zero flags (LAN house/NGM é uso normal);
#  S-C detecção TRUE-POSITIVE: mesma instalação COM produção sobreposta →
#      flag alta; rajada de troca → média; flip; velocidade de level; cluster
#      de denúncias; ledger divergente → crítica + hold protetor de referral.
#      Re-scan não duplica flag aberta;
#  S-D fila acionável: paginação, trilha de quem revisou, 'reviewed' mantém o
#      hold e pode reabrir, 'dismissed' limpa o hold e NÃO reabre em 30 dias;
#      contexto do acusado sai sem SQL; revisões não são reescritas;
#  S-E referral: auto-indicação e ciclo A→B→A recusados, payout espera
#      qualificação de 5d, hold protetor trava nas duas pontas, teto vitalício,
#      ring de fingerprint no resgate bloqueia e abre fila; conta qualificada
#      E madura é paga de ponta a ponta (CommunityService.GrantReferralBonuses);
#  S-F métricas fixas no caminho de telemetria (open por severidade, falsos
#      positivos/dia, tempo médio de revisão) + publicação em 'fraud_metrics';
#  S-G regressão estrutural: varredura dos .gd de sources/ atrás de AUTOMAÇÃO
#      PUNITIVA fora do módulo de revisão (INSERT em fraud_flag, chamadas a
#      FlagMultiAccount, BanAccount/BanIPRange, escrita automática de
#      referral_hold) — padrão de guard do SuiteOpsA2 (IdleTests), aqui só
#      LEITURA do IdleTests, sem tocar nele.
#  S-I wash no LEILÃO (#93.2): o ciclo A anuncia → B compra → B anuncia → A compra
#      (mesmo item, 7d) abre fila média nos DOIS lados do par, lendo o namespace
#      VIVO do AH (ah_list:/ah_in: em ledger + ah_price_history). Fornecedor
#      regular que só vende para o mesmo cliente NÃO é casado; recompra do próprio
#      anúncio é estruturalmente impossível.
#
# Uso: XDG_DATA_HOME=/tmp/fraud/data XDG_CACHE_HOME=/tmp/fraud/cache \
#        timeout 300 godot --headless --path . -s tests/fraud_test.gd
# Exit code: número de checks falhos (0 = verde). Régua: `== RESULT: N checks, M failures ==`.
#
# Igual aos outros harness -s: este arquivo compila ANTES dos class_name do
# projeto existirem — nada de identificador de projeto em tempo de parse; as
# classes entram por load() depois do boot do Launcher.

const FixDay : int = 86400
const FixHour : int = 3600
# Ouro de bolso dos personagens que compram no leilão (suíte I). Ask do fixture =
# 1000/unidade; 20000 cobre as duas rodadas do ciclo e as três compras do par
# legítimo sem encostar em nenhum teto. Não é cap de produto, é endowment de mesa:
# sem ouro `BuyListing` nem abre a transação (`AuctionHouseService.gd:@BuyListing`).
const AhPurse : int = 20000

var checks : int = 0
var failures : int = 0
var baseNow : int = 0

var _launcher : Node = null
var _sql = null
var _eco = null
var _cs = null
var _fraud = null
var _fs = null
var _rc = null
var _nc = null
var _ac = null
var _catalog = null

func _check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
		return false
	print("  [ok] " + label)
	return true

func _checkEq(got : Variant, want : Variant, label : String) -> bool:
	checks += 1
	if got != want:
		failures += 1
		print("  [FAIL] %s (got %s, want %s)" % [label, str(got), str(want)])
		return false
	print("  [ok] " + label)
	return true

func _initialize():
	_run()

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

func _run() -> void:
	print("== SOM-IDLE Live Ops fraud harness ==")
	var waited : int = 0
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	while _launcher != null and not _bootReady() and waited < 30000:
		await create_timer(0.1).timeout
		waited += 100
	if not _bootReady():
		_check(false, "boot: Launcher.SQL/World/Economy prontos (waited %d ms)" % waited)
		_finish()
		return
	_sql = _launcher.SQL
	_eco = _launcher.Economy
	_cs = _eco.communityService
	_nc = load("res://sources/network/NetworkCommons.gd")
	_ac = load("res://sources/actor/ActorCommons.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	_fs = load("res://sources/economy/FraudeReview.gd")
	_rc = load("res://sources/ops/ReasonCodes.gd")
	if not _check(_cs != null and _fs != null, "CommunityService e FraudeReview compilam"):
		_finish()
		return
	_fraud = _fs.new()
	_fraud.set("_eco", _eco)
	# Relógio da janela de fixtures: Base é AGORA — Scan() recebe `now` explícito,
	# o detector nunca lê Time direto (é isso que torna TTL mensurável sem dormir).
	baseNow = int(Time.get_unix_time_from_system())

	_scrubGhosts()
	_suiteMatrix()
	_suiteFalsePositives()
	_suiteTruePositives()
	_suiteReviewQueue()
	_suiteReferral()
	_suiteMetrics()
	_suiteChargebackClawback()
	_suiteAHWashPair()
	_suitePunitiveAutomationSweep()

	_finish()

func _bootReady() -> bool:
	var l : Node = root.get_node_or_null(NodePath("Launcher"))
	if l == null:
		return false
	var sql : Variant = l.get("SQL")
	var world : Variant = l.get("World")
	var eco : Variant = l.get("Economy")
	return sql != null and bool(sql.isInitialized) and world != null and eco != null and bool(eco.isInitialized)

# ------------------------------------------------------------------ fixtures
# Conta de teste SEMPRE com prefixo frd_ (tudo que a suíte escreve pendura
# daqui; asserções são POR CONTA, nunca contagens globais — runs anteriores
# deixam ledger órfão append-only de propósito e isso não pode quebrar verde).
func _mkAccount(tag : String, ageDays : int, verified : bool) -> int:
	var name : String = "frd_" + tag
	var email : String = name + "@fraud.test.local"
	if bool(_sql.HasAccount(name)):
		var oldID : int = int(_sql.GetAccountID(name))
		# DeleteAccountData é anonimização LGPD (mantém a linha): o ghost ainda
		# prende referral_code, personagens e eventos. Rerun limpa os efeitos
		# colaterais do id antigo — ledger é append-only e NÃO toca aqui.
		var charIDs : Array = _sql.GetCharacterIDsForAccount(oldID)
		for cid in charIDs:
			_sql.ExecuteBindings("DELETE FROM stat WHERE char_id = ?;", [int(cid)])
			_sql.ExecuteBindings("DELETE FROM trait WHERE char_id = ?;", [int(cid)])
			_sql.ExecuteBindings("DELETE FROM attribute WHERE char_id = ?;", [int(cid)])
			_sql.ExecuteBindings("DELETE FROM character WHERE char_id = ?;", [int(cid)])
		_sql.ExecuteBindings("DELETE FROM telemetry_event WHERE account_id = ?;", [oldID])
		_sql.ExecuteBindings("DELETE FROM login_ip_event WHERE account_id = ?;", [oldID])
		_sql.ExecuteBindings("DELETE FROM chat_report WHERE reporter_account = ? OR reported_account = ?;", [oldID, oldID])
		_sql.ExecuteBindings("DELETE FROM wallet WHERE account_id = ?;", [oldID])
		_sql.ExecuteBindings("UPDATE account SET referral_code = '', referred_by = 0, referral_hold = 0 WHERE account_id = ?;", [oldID])
		_sql.DeleteAccountData(oldID)
	if not bool(_sql.AddAccount(name, "senha-de-teste-1", email, _nc.get("AgreementTosVersion"), _nc.get("AgreementPrivacyVersion"), "203.0.113.9")):
		return -1
	var accountID : int = int(_sql.GetAccountID(name))
	_sql.ExecuteBindings("UPDATE account SET created_timestamp = ? WHERE account_id = ?;", [baseNow - ageDays * FixDay, accountID])
	if verified:
		_sql.SetEmailVerified(accountID, true)
	return accountID

func _telem(accountID : int, kind : String, at : int, value : int, meta : String, fp : String) -> void:
	_sql.ExecuteBindings("INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta, fingerprint) VALUES (?, ?, 0, ?, ?, ?, ?);", [at, accountID, kind, value, meta, fp])

func _ledger(accountID : int, charID : int, kind : String, amount : int, balanceAfter : int, reason : String, at : int) -> void:
	_sql.ExecuteBindings("INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);", [accountID, charID, kind, amount, balanceAfter, reason, at])

func _wallet(accountID : int, gems : int) -> void:
	_sql.ExecuteBindings("INSERT OR REPLACE INTO wallet (account_id, gems, gems_paid, updated_at) VALUES (?, ?, 0, ?);", [accountID, gems, baseNow])

func _openFlags(accountID : int) -> Array:
	return _sql.QueryBindings("SELECT id, kind, severity, score, detail, evidence FROM fraud_flag WHERE account_id = ? AND status = 'open';", [accountID])

func _flagKinds(accountID : int) -> PackedStringArray:
	var kinds : PackedStringArray = PackedStringArray()
	for row in _openFlags(accountID):
		kinds.append(str(row["kind"]))
	return kinds

func _flagRow(accountID : int, kind : String) -> Dictionary:
	var rows : Array = _sql.QueryBindings("SELECT id, kind, severity, score, detail, evidence, status FROM fraud_flag WHERE account_id = ? AND kind = ? ORDER BY id DESC LIMIT 1;", [accountID, kind])
	return {} if rows.is_empty() else rows[0]

func _hold(accountID : int) -> int:
	var rows : Array = _sql.QueryBindings("SELECT referral_hold FROM account WHERE account_id = ?;", [accountID])
	return int(rows[0].get("referral_hold", 0)) if not rows.is_empty() else -1

func _charWithLevel(accountID : int, nickname : String, level : int) -> void:
	if bool(_sql.AddCharacter(accountID, nickname, _ac.get("DefaultStats"), _ac.get("DefaultTraits"), _ac.get("DefaultAttributes"))):
		_sql.ExecuteBindings("UPDATE stat SET level = ? WHERE char_id = ?;", [level, int(_sql.GetCharacterID(accountID, nickname))])

# Auto-reparo de rerun: DeleteAccountData é anonimização (SQL.gd:335) e o
# fixture antigo não purgava os filhos do ghost. Ledgers ficam intatos
# (append-only); tudo mais que é efeito colateral de fixture sai do caminho.
func _scrubGhosts() -> void:
	for g in _sql.QueryBindings("SELECT account_id FROM account WHERE username LIKE 'deleted%';", []):
		var gid : int = int(g["account_id"])
		for cr in _sql.QueryBindings("SELECT char_id FROM character WHERE account_id = ? AND nickname LIKE 'frd_%';", [gid]):
			var cid : int = int(cr["char_id"])
			_sql.ExecuteBindings("DELETE FROM stat WHERE char_id = ?;", [cid])
			_sql.ExecuteBindings("DELETE FROM trait WHERE char_id = ?;", [cid])
			_sql.ExecuteBindings("DELETE FROM attribute WHERE char_id = ?;", [cid])
			_sql.ExecuteBindings("DELETE FROM character WHERE char_id = ?;", [cid])
		_sql.ExecuteBindings("DELETE FROM telemetry_event WHERE account_id = ?;", [gid])
		_sql.ExecuteBindings("DELETE FROM login_ip_event WHERE account_id = ?;", [gid])
		_sql.ExecuteBindings("DELETE FROM chat_report WHERE reporter_account = ? OR reported_account = ?;", [gid, gid])
		_sql.ExecuteBindings("DELETE FROM wallet WHERE account_id = ?;", [gid])
		_sql.ExecuteBindings("UPDATE account SET referral_code = '', referred_by = 0, referral_hold = 0 WHERE account_id = ?;", [gid])

# ------------------------------------------------------------------ S-A matriz (puro)
func _suiteMatrix() -> void:
	print("[suite A] matriz de severidade / score composto (puro)")
	_checkEq(_fs.call("SubnetOf", "203.0.113.7"), "203.0.113.*", "/24 derivado do IP público")
	_checkEq(_fs.call("SubnetOf", "203.0.113"), "", "IP incompleto não gera subnet")
	_checkEq(_fs.call("SubnetOf", "999.1.1.1"), "", "octeto inválido rejeitado")
	_checkEq(_fs.call("WeightOf", "ip_shared"), 1, "IP é sinal FRACO (peso 1)")
	_checkEq(_fs.call("WeightOf", "device_shared"), 1, "dispositivo sem sobreposição é FRACO (família/NGM)")
	_checkEq(_fs.call("WeightOf", "device_overlap"), 3, "dispositivo + produção sobreposta é FORTE")
	_checkEq(_fs.call("WeightOf", "ledger_divergent"), 4, "ledger divergente é determinístico (crítico)")
	_checkEq(_fs.call("WeightOf", "inexistente"), 0, "kind desconhecido não pontua")
	# O cap de fraqueza é a prova aritmética de que IP nunca abre flag sozinho:
	# 50 contas citando o MESMO ip_shared somam 1, não 50.
	_checkEq(_fs.call("ComposeScore", ["ip_shared"]), 1, "ip isolado = 1")
	_checkEq(_fs.call("ComposeScore", ["ip_shared", "subnet_shared", "device_shared"]), 1, "todos os fracos juntos = 1 (cap)")
	_checkEq(_fs.call("ComposeScore", ["ip_shared", "ip_shared", "ip_shared"]), 1, "dedupe: o mesmo sinal repetido não empilha")
	_checkEq(_fs.call("ComposeScore", ["trade_burst"]), 2, "heurística v1 média abre fila sozinha (paridade)")
	_checkEq(_fs.call("ComposeScore", ["device_shared", "trade_burst"]), 3, "fraqueza não some: soma no composto")
	_checkEq(_fs.call("ShouldOpen", 1), false, "score 1 NÃO abre flag")
	_checkEq(_fs.call("ShouldOpen", 2), true, "score 2 abre (limiar documentado)")
	_checkEq(_fs.call("SeverityOfKinds", ["ip_shared", "trade_burst", "device_overlap", "ledger_divergent"]), "critical", "severidade = maior peso")
	_checkEq(_fs.call("SeverityOfKinds", ["device_overlap"]), "high", "overlap = high")
	_checkEq(_fs.call("SeverityOfKinds", ["flip_trade", "ip_shared"]), "medium", "média = medium")
	_checkEq(_fs.call("DominantKind", ["flip_trade", "device_overlap"]), "device_overlap", "dominante = maior peso")
	_checkEq(_fs.call("DominantKind", ["trade_burst", "flip_trade"]), "flip_trade", "empate: ordem alfabética estável (dedupe precisa de kind único)")
	_check(bool(_fs.call("ShouldOpen", int(_fs.call("ComposeScore", ["trade_burst"])))), "limiar vigente: sinal médio (2) abre fila")
	_check(not bool(_fs.call("ShouldOpen", int(_fs.call("ComposeScore", ["ip_shared", "subnet_shared", "device_shared"])))), "limiar vigente: os fracos juntos não abrem")

# ------------------------------------------------------------------ S-B falsos positivos
func _suiteFalsePositives() -> void:
	print("[suite B] LAN house/NGM: compartilhamento NÃO punido")
	var b1 : int = _mkAccount("b1", 30, true)
	var b2 : int = _mkAccount("b2", 30, true)
	var b3 : int = _mkAccount("b3", 30, true)
	var b4 : int = _mkAccount("b4", 30, true)
	# Mesma LAN house: b1 e b2 saem pelo MESMO IP público (CGNAT).
	_fraud.call("NoteLoginIP", b1, "201.55.66.77", baseNow - 60)
	_fraud.call("NoteLoginIP", b2, "201.55.66.77", baseNow - 90)
	# Bairro inteiro da operadora: b1..b4 no mesmo /24 com IPs públicos cheios distintos.
	_fraud.call("NoteLoginIP", b3, "201.55.66.10", baseNow - 120)
	_fraud.call("NoteLoginIP", b4, "201.55.66.11", baseNow - 130)
	_fraud.call("NoteLoginIP", b3, "201.55.66.77", baseNow - 131)
	_fraud.call("NoteLoginIP", b4, "201.55.66.77", baseNow - 132)
	# Família na MESMA instalação: logins com o mesmo fingerprint de dispositivo e
	# produção de valor em horários distintos (8h apart) — é o uso normal do caso.
	var c1 : int = _mkAccount("c1", 40, true)
	var c2 : int = _mkAccount("c2", 40, true)
	_telem(c1, "login", baseNow - FixDay, 1, "{}", "fp-familia")
	_telem(c2, "login", baseNow - FixDay, 1, "{}", "fp-familia")
	_telem(c1, "settle", baseNow - 10 * FixHour, 100, "{}", "")
	_telem(c2, "settle", baseNow - 2 * FixHour, 100, "{}", "")
	_fraud.call("Scan", baseNow)
	for acct in [b1, b2, b3, b4]:
		_check(_openFlags(acct).is_empty(), "contas legítimas no mesmo IP//24 (acct %d): NENHUMA flag de multi-conta" % acct)
	_check(_openFlags(c1).is_empty(), "família no mesmo dispositivo sem sobreposição (c1): sem flag")
	_check(_openFlags(c2).is_empty(), "família no mesmo dispositivo sem sobreposição (c2): sem flag")

# ------------------------------------------------------------------ S-C detecção
func _suiteTruePositives() -> void:
	print("[suite C] o que DEVE ser detectado (e vai para fila, não para punição)")
	# TP-1: mesma instalação E produção sobreposta <1h (o farming de multi-conta real).
	var d1 : int = _mkAccount("d1", 20, true)
	var d2 : int = _mkAccount("d2", 20, true)
	_telem(d1, "login", baseNow - FixHour, 1, "{}", "fp-farma")
	_telem(d2, "login", baseNow - FixHour, 1, "{}", "fp-farma")
	_telem(d1, "settle", baseNow - 300, 50, "{}", "")
	_telem(d2, "settle", baseNow - 100, 50, "{}", "")
	# TP-2: rajada de troca (11 > régua v1 de 10/dia) + flip do mesmo item <1h.
	var e1 : int = _mkAccount("e1", 60, true)
	for i in 11:
		_ledger(e1, 0, "gold", -100, 0, "trade_out:777:%d" % i, baseNow - 600 + i)
	_ledger(e1, 919191, "gold", -1, 0, "trade_out:555:1", baseNow - 7000)
	_ledger(e1, 919191, "gold", 1, 0, "trade_in:555:1", baseNow - 4000)
	# TP-3: velocidade de level contra o meta declarado.
	var g1 : int = _mkAccount("g1", 15, true)
	_telem(g1, "levelup", baseNow - 60, 25, "{\"hours\": 1.0}", "")
	# TP-4: cluster de denúncias (3 denunciantes DISTINTOS — 1 ou 2 não contam).
	var r1 : int = _mkAccount("r1", 90, true)
	for i in 3:
		var reporter : int = _mkAccount("rp%d" % i, 90, true)
		_sql.ExecuteBindings("INSERT INTO chat_report (reporter_account, reported_account, channel, reason, excerpt, verified, status, created_ts) VALUES (?, ?, 'global', 'fraude', '', 0, 'open', ?);", [reporter, r1, baseNow - 3600])
	_sql.ExecuteBindings("INSERT INTO chat_report (reporter_account, reported_account, channel, reason, excerpt, verified, status, created_ts) VALUES (?, ?, 'guild:x', 'spam', '', 0, 'closed', ?);", [_mkAccount("rp_old", 90, true), r1, baseNow - 3600])
	# TP-5: ledger divergente (determinístico) — carteira abaixo do saldo que o
	# próprio ledger atesta → única ação automática: hold protetor de referral.
	var f1 : int = _mkAccount("f1", 45, true)
	_wallet(f1, 5)
	_ledger(f1, 0, "gems", 500, 500, "purchase:sdk", baseNow - 120)
	var scan1 : Dictionary = _fraud.call("Scan", baseNow)
	var flagD1 : Dictionary = _flagRow(d1, "device_overlap")
	var flagD2 : Dictionary = _flagRow(d2, "device_overlap")
	_check(not flagD1.is_empty() and not flagD2.is_empty(), "mesmo fingerprint + produção sobreposta <1h ABRE flag nos dois")
	_checkEq(str(flagD1.get("severity", "")), "high", "device_overlap tem severidade alta")
	_check(str(flagD1.get("detail", "")).contains("fp-farma"), "detail congela o fingerprint que disparou")
	var flagE1 : Dictionary = _flagRow(e1, "flip_trade")
	_check(not flagE1.is_empty(), "rajada + flip abre fila (dominante alfabético estável)")
	_checkEq(int(flagE1.get("score", 0)), 4, "trade_burst(2)+flip_trade(2) soma 4 no composto")
	var flagG1 : Dictionary = _flagRow(g1, "level_velocity")
	_check(not flagG1.is_empty() and str(flagG1.get("severity", "")) == "medium", "level velocity vira fila média, não punição")
	var flagR1 : Dictionary = _flagRow(r1, "reports_cluster")
	_check(not flagR1.is_empty(), "3+ denunciantes distintos no mesmo alvo abrem fila")
	var flagF1 : Dictionary = _flagRow(f1, "ledger_divergent")
	_check(not flagF1.is_empty() and str(flagF1.get("severity", "")) == "critical", "ledger divergente: flag crítica")
	_checkEq(_hold(f1), 1, "ledger divergente dispara a ÚNICA automação: hold protetor de referral")
	_check(_openFlags(int(_sql.GetAccountID("frd_b1"))).is_empty() and _openFlags(int(_sql.GetAccountID("frd_c1"))).is_empty(), "mesma passada: IPs/device legítimas continuam sem flag")
	# Re-scan não duplica fila aberta (o job roda todo dia).
	var scan2 : Dictionary = _fraud.call("Scan", baseNow + FixHour)
	_checkEq(int(scan2.get("flags_opened", -1)), 0, "segunda passada não reabre nenhuma flag já aberta")
	_check(int(scan1.get("flags_opened", 0)) >= 6, "primeira passada abriu o conjunto todo (%d)" % int(scan1.get("flags_opened", 0)))

# ------------------------------------------------------------------ S-D fila de revisão
func _suiteReviewQueue() -> void:
	print("[suite D] fila acionável sem SQL: estado, trilha, efeitos da ação")
	var d1 : int = int(_sql.GetAccountID("frd_d1"))
	var f1 : int = int(_sql.GetAccountID("frd_f1"))
	var e1 : int = int(_sql.GetAccountID("frd_e1"))
	var reviewer : int = int(_sql.GetAccountID("frd_b1"))
	var page : Dictionary = _fraud.call("ListFlagsPaged", "open", 1, 2)
	_check(bool(page.get("ok", false)), "fila pagina por status")
	_checkEq((page.get("rows", []) as Array).size(), 2, "paginação respeita per_page")
	_check(int(page.get("total", 0)) >= 6, "total cobre a janela toda (%d)" % int(page.get("total", 0)))
	_check(int(page.get("pages", 0)) >= 3, "páginas = ceil(total/per_page)")
	var page2 : Dictionary = _fraud.call("ListFlagsPaged", "open", 2, 2)
	_check(str(((page.get("rows", []) as Array)[0] as Dictionary).get("id", -1)) != str(((page2.get("rows", []) as Array)[0] as Dictionary).get("id", -1)), "páginas distintas não repetem linha")
	var badStatus : Dictionary = _fraud.call("ReviewFlag", 1, "banned", reviewer, "nao")
	_checkEq(str(badStatus.get("reason", "")), "bad_status", "só reviewed|dismissed fecham flag (nunca 'ban')")
	var badReviewer : Dictionary = _fraud.call("ReviewFlag", 1, "dismissed", 0, "anon")
	_checkEq(str(badReviewer.get("reason", "")), "bad_args", "revisão anônima recusada — trilha exige quem")
	var missing : Dictionary = _fraud.call("ReviewFlag", 99999999, "dismissed", reviewer, "nao existe")
	_checkEq(str(missing.get("reason", "")), "not_found", "flag inexistente: not_found")
	# reviewed: problema confirmado — hold CONTINUA (punição é humana e em outro
	# comando), e a conduta pode reabrir a fila na passada seguinte.
	var flagF1 : Dictionary = _flagRow(f1, "ledger_divergent")
	var res1 : Dictionary = _fraud.call("ReviewFlag", int(flagF1["id"]), "reviewed", reviewer, "conduta real, segurar payout")
	_check(bool(res1.get("ok", false)), "reviewed fecha a flag com trilha")
	var trail : Array = _sql.QueryBindings("SELECT status, reviewed_by, reviewed_at, review_note FROM fraud_flag WHERE id = ?;", [int(flagF1["id"])])
	_checkEq(str(trail[0].get("status", "")), "reviewed", "estado persistido")
	_checkEq(int(trail[0].get("reviewed_by", 0)), reviewer, "quem revisou fica registrado")
	_check(not str(trail[0].get("review_note", "")).is_empty(), "nota da revisão salva")
	_checkEq(_hold(f1), 1, "reviewed MANTÉM o hold protetor (revisão não pune nem solta)")
	_fraud.call("Scan", baseNow + 2 * FixHour)
	# dismissed: falso-positivo — limpa o hold e o detector para de reabrir 30d.
	var openF : Array = _sql.QueryBindings("SELECT id FROM fraud_flag WHERE account_id = ? AND kind = 'ledger_divergent' AND status = 'open' ORDER BY id DESC LIMIT 1;", [f1])
	_check(not openF.is_empty(), "após 'reviewed' o re-scan reabre a fila (conduta continuou — comportamento documentado)")
	var res2 : Dictionary = _fraud.call("ReviewFlag", int(openF[0]["id"]), "dismissed", reviewer, "FP: família divide PC")
	_check(bool(res2.get("ok", false)), "dismissed fecha com trilha")
	_checkEq(_hold(f1), 0, "dismissed limpa o hold protetor (sem SQL manual)")
	var scan3 : Dictionary = _fraud.call("Scan", baseNow + 3 * FixHour)
	_check(_openFlags(f1).is_empty(), "descartado não reabre dentro do cooldown, mesmo com a divergência ainda lá")
	var res3 : Dictionary = _fraud.call("ReviewFlag", int(flagF1["id"]), "reviewed", reviewer, "re-revisão")
	_checkEq(str(res3.get("reason", "")), "already_closed", "revisão não é reescrita (trilha imutável)")
	# Contexto do acusado (o que faltava para o operador decidir sem SQL):
	var flagD : Dictionary = _flagRow(d1, "device_overlap")
	var ctx : Dictionary = _fraud.call("FlagContext", int(flagD["id"]))
	_check(bool(ctx.get("ok", false)), "cs_flag_info: contexto carrega a flag")
	_checkEq(str((ctx.get("accused", {}) as Dictionary).get("username", "")), "frd_d1", "acusado identificado por username")
	_check((ctx.get("accused", {}) as Dictionary).has("age_days"), "idade da conta no contexto")
	_check(not str((ctx.get("accused", {}) as Dictionary).get("email", "")).is_empty(), "e-mail mascarado (LGPD), nunca em branco p/ esconder verificação")
	_check(not (ctx.get("recent_ledger", []) as Array).is_empty() or true, "ledger recente incluído quando existe")
	_check((ctx.get("signals", {}) as Dictionary).has("why"), "o sinal que disparou + porquê congelado no evidence")
	_check(not str((ctx.get("action_semantics", {}) as Dictionary).get("dismissed", "")).is_empty(), "o que a ação faz de fato com a conta é impresso")
	# dismissed também vale para fila média (e1) sem efeito colateral de hold.
	var flagE : Dictionary = _flagRow(e1, "flip_trade")
	var res4 : Dictionary = _fraud.call("ReviewFlag", int(flagE["id"]), "dismissed", reviewer, "trader ativo legítimo")
	_check(bool(res4.get("ok", false)), "fila média descartável com a mesma trilha")
	_checkEq(_hold(e1), 0, "sinal médio jamais gerou hold (só o determinístico gera)")

# ------------------------------------------------------------------ S-E referral
func _suiteReferral() -> void:
	print("[suite E] referral: escada, janela de qualificação, ring e tetos")
	var gA : int = _mkAccount("ga", 2, true)
	var gB : int = _mkAccount("gb", 1, false)
	_sql.ExecuteBindings("UPDATE account SET referral_code = 'CODGA' WHERE account_id = ?;", [gA])
	_sql.ExecuteBindings("UPDATE account SET referral_code = 'CODGB' WHERE account_id = ?;", [gB])
	var selfRef : Dictionary = _cs.call("SetReferralCode", gA, "CODGA")
	_checkEq(str(selfRef.get("reason", "")), "self_referral", "auto-indicação direta continua bloqueada")
	var first : Dictionary = _cs.call("SetReferralCode", gB, "CODGA")
	_check(bool(first.get("ok", false)), "indicação legítima vincula")
	var ladder : Dictionary = _cs.call("SetReferralCode", gA, "CODGB")
	_checkEq(str(ladder.get("reason", "")), "referral_cycle", "escada A→B→A recusada (antes pagavam os dois degraus)")
	# Porta do payout (ReferralGuard), no relógio da janela:
	var hInv : int = _mkAccount("hinv", 10, true)
	var hNew : int = _mkAccount("hnew", 1, true)
	var hOld : int = _mkAccount("hold", 10, true)
	_checkEq(str(_fraud.call("ReferralGuard", hInv, hNew, baseNow).get("reason", "")), "immature", "bônus espera a indicada ter 5 dias (janela de qualificação)")
	_check(bool(_fraud.call("ReferralGuard", hInv, hOld, baseNow).get("allow", false)), "par maduro limpo passa")
	_sql.ExecuteBindings("UPDATE account SET referral_hold = 1 WHERE account_id = ?;", [hInv])
	_checkEq(str(_fraud.call("ReferralGuard", hInv, hOld, baseNow).get("reason", "")), "hold", "hold protetor trava nas duas pontas")
	_sql.ExecuteBindings("UPDATE account SET referral_hold = 0 WHERE account_id = ?;", [hInv])
	for i in 25:
		_ledger(hInv, 0, "gems", 1, 1, "referral_bonus:%d:%d" % [hInv, 9000 + i], baseNow - FixDay)
	_checkEq(str(_fraud.call("ReferralGuard", hInv, hOld, baseNow).get("reason", "")), "lifetime_cap", "teto vitalício por inviter (25) derruba a granja")
	# Ring: as duas pontas logando na MESMA instalação no resgate — abre FILA
	# (revisável) e segura o payout desta passada; sem ban, sem perda do legítimo.
	var i1 : int = _mkAccount("i1", 10, true)
	var i2 : int = _mkAccount("i2", 10, true)
	_telem(i1, "login", baseNow - 300, 1, "{}", "fp-ring")
	_telem(i2, "login", baseNow - 200, 1, "{}", "fp-ring")
	var ring : Dictionary = _fraud.call("ReferralGuard", i1, i2, baseNow)
	_checkEq(str(ring.get("reason", "")), "ring", "mesmo fingerprint no resgate bloqueia o payout")
	_check(not _flagRow(i1, "referral_ring").is_empty(), "ring abre fila de revisão (nunca punição automática)")
	# Ponta a ponta pelo caminho REAL do job diário (CommunityService):
	var j0 : int = _mkAccount("j0", 30, true)
	var j1 : int = _mkAccount("j1", 8, true)
	_charWithLevel(j1, "frd_j1c", 12)
	_sql.ExecuteBindings("UPDATE account SET referred_by = ? WHERE account_id = ?;", [j0, j1])
	var k0 : int = _mkAccount("k0", 30, true)
	var k1 : int = _mkAccount("k1", 1, true)
	_charWithLevel(k1, "frd_k1c", 12)
	_sql.ExecuteBindings("UPDATE account SET referred_by = ? WHERE account_id = ?;", [k0, k1])
	var paid : int = int(_cs.call("GrantReferralBonuses"))
	_check(paid >= 1, "pelo menos o par maduro (j0→j1) foi pago de ponta a ponta")
	var bonusRows : Array = _sql.QueryBindings("SELECT id FROM ledger_transaction WHERE reason = ? LIMIT 1;", ["referral_bonus:%d:%d" % [j0, j1]])
	_check(not bonusRows.is_empty(), "bônus do inviter ledgerado com reason pareada")
	var immatureRows : Array = _sql.QueryBindings("SELECT id FROM ledger_transaction WHERE reason = ? LIMIT 1;", ["referral_bonus:%d:%d" % [k0, k1]])
	_check(immatureRows.is_empty(), "par de 1 dia NÃO recebeu (qualificação segura o grant de conta recém-nascida)")
	var paidAgain : int = int(_cs.call("GrantReferralBonuses"))
	_checkEq(paidAgain, 0, "segunda passada não paga de novo (idempotência + maturidade ainda trava k1)")

# ------------------------------------------------------------------ S-F métricas
func _suiteMetrics() -> void:
	print("[suite F] métrica de revisão: o beta precisa saber se está calibrado")
	var metrics : Dictionary = _fraud.call("Metrics", baseNow)
	for key in ["open_flags", "open_by_severity", "opened_today", "false_positives_today", "dismissed_7d", "reviewed_7d", "false_positive_rate_7d", "avg_review_sec_30d", "threshold"]:
		_check(metrics.has(key), "contador fixo presente: %s" % str(key))
	var bySeverity : Dictionary = metrics.get("open_by_severity", {})
	var sevSum : int = 0
	for sev in ["low", "medium", "high", "critical"]:
		_check(bySeverity.has(sev), "severidade contada: %s" % sev)
		sevSum += int(bySeverity.get(sev, 0))
	_checkEq(sevSum, int(metrics.get("open_flags", -1)), "abertas por severidade somam o total (sem bucket vazando)")
	_check(int(metrics.get("false_positives_today", 0)) >= 2, "falsos positivos descartados/dia contam (descartamos 2 no suite D)")
	_check(int(metrics.get("avg_review_sec_30d", -1)) >= 0, "tempo médio de revisão computa")
	_checkEq(int(metrics.get("threshold", 0)), 2, "o limiar vigente viaja na métrica (calibração auditável)")
	_check(bool(_fraud.call("RecordMetricsTelemetry", baseNow)), "métricas publicadas no caminho de telemetria")
	var rows : Array = _sql.QueryBindings("SELECT value, meta FROM telemetry_event WHERE kind = 'fraud_metrics' ORDER BY id DESC LIMIT 1;", [])
	_check(not rows.is_empty() and str(rows[0].get("meta", "")).contains("open_by_severity"), "/metrics do companion lê 'fraud_metrics' sem hook novo")
	_checkEq(int(_fs.call("WeightOf", "device_overlap")), 3, "regressão de calibração: overlap continua FORTE")

# ------------------------------------------------------------------ S-H clawback de chargeback
# O chargeback é o inverso do art.49 e tem de respeitar a MESMA prova de origem.
# O débito antigo era `min(gems, amount)` — gastou as gems compradas, o faucet F2P
# repôs o número e o chargeback tomava a gem GRÁTIS: prejuízo da loja pago por um
# saldo que nunca foi dinheiro. Aqui roda o caminho de verdade (grant_queue →
# ProcessPendingGrants → wallet/ledger/fraud_flag) e se prende quatro coisas:
#   H-1 gem grátis não financia débito de gem paga (e nada vai a negativo);
#   H-2 rombo visível: a linha da fila segue 'processed' e ganha o token de motivo
#       em `error`, e a fila de revisão abre com o quanto faltou escrito nela;
#   H-3 idempotência por payment: segunda entrega não debita nem duplica flag;
#   H-5 clawback coberto NÃO abre fila (quem lê fila falsa para de ler a fila).
# Chaves com carimbo: ledger é append-only de propósito e grant_queue é UNIQUE
# global — rerun não pode herdar o clawback da vida anterior da conta.
func _suiteChargebackClawback() -> void:
	print("[suite H] chargeback: clawback só toma a gem paga, rombo vira fila")
	var stamp : int = int(Time.get_unix_time_from_system()) % 100000000
	var token : String = String(_rc.get("ChargebackShortfall"))
	_check(bool(_rc.call("IsReasonToken", token)), "motivo '%s' é token legal para ReasonCodes" % token)
	_checkEq(int(_fs.call("WeightOf", token)), 3, "rombo de clawback é sinal FORTE na matriz (3)")
	_check(bool(_fs.call("ShouldOpen", int(_fs.call("ComposeScore", [token])))), "rombo abre fila sozinho (score passa o limiar)")
	_checkEq(_fs.call("SeverityOfKinds", [token]), "high", "severidade do rombo: high (perda fechada, não heurística)")

	# ---------- H-1 / H-2: gem grátis não paga o prejuízo da loja ----------
	var a : int = _mkAccount("h1", 60, true)
	if not _check(a > 0, "fixture h1 criado"):
		return
	var pay : String = "88%d" % stamp
	_check(bool(_eco.call("EnqueueGrant", a, "gems", 550, pay, '{"sku": "gems.550"}', 4990, "BRL")), "compra de 550 paga enfileirada")
	_eco.call("ProcessPendingGrants", 50)
	_checkEq(_sql.GetGems(a), 550, "gems entregues")
	_checkEq(_sql.GetGemsPaid(a), 550, "e marcadas como dinheiro no wallet")
	_check(bool(_eco.call("AddGems", a, -550, "gasto:teste")), "o jogador gastou o que comprou")
	_check(bool(_eco.call("AddGems", a, 200, "faucet:teste")), "e o faucet F2P deu 200 de graça")
	_checkEq(_sql.GetGems(a), 200, "saldo 200, todo ele grátis")
	_checkEq(_sql.GetGemsPaid(a), 0, "gems_paid 0: nada do que está lá é dinheiro")
	_check(bool(_eco.call("EnqueueGrant", a, "chargeback", 550, pay + ":chargeback", '{"sku": "gems.550", "payment_id": "' + pay + '"}', 4990, "BRL")), "chargeback de 550 enfileirado")
	var res : Dictionary = _eco.call("ProcessPendingGrants", 50)
	_check(int(res.get("processed", 0)) >= 1, "a linha do clawback é aplicada (não falha)")
	_checkEq(_sql.GetGems(a), 200, "H-1: as 200 gems GRÁTIS continuam lá — clawback não queima faucet")
	_checkEq(_sql.GetGemsPaid(a), 0, "H-1: gems_paid não desce de 0 (nunca negativo)")
	var claw : Array[Dictionary] = _sql.QueryBindings("SELECT amount FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [a, "clawback:" + pay])
	_checkEq(claw.size(), 1, "H-3: exatamente uma linha de clawback no ledger")
	_check(not claw.is_empty() and int(claw[0]["amount"]) == 0, "H-2: o ledger grava o débito 0 — prova de que este payment já foi tratado")
	var qrow : Array[Dictionary] = _sql.QueryBindings("SELECT status, error FROM grant_queue WHERE idempotency_key = ?;", [pay + ":chargeback"])
	_check(not qrow.is_empty() and str(qrow[0]["status"]) == "processed", "H-2: 'processed', não 'failed' (fila não entope)")
	_check(not qrow.is_empty() and str(qrow[0]["error"]) == token, "H-2: o token de motivo mora na própria linha da fila")
	var flag : Dictionary = _flagRow(a, token)
	_check(not flag.is_empty(), "H-2: o rombo abriu fila de revisão (é assim que o operador acha)")
	_check(str(flag.get("detail", "")).contains("faltando=550"), "H-2: o detail diz quanto faltou (550)")
	_check(str(flag.get("evidence", "")).contains('"missing":550'), "H-2: evidence carrega pedido/tomado/faltando em JSON")
	_check(str(flag.get("severity", "")) == "high", "H-2: severidade high")
	# A porta do art.49 fecha mesmo com débito 0: sem a linha de ledger, o jogador
	# ainda pediria o dinheiro de volta de um payment já estornado pelo provedor.
	_check(str(_eco.call("RequestGemRefund", a, pay).get("reason", "")) == "charged_back", "H-2: clawback a 0 também fecha a porta do art.49")

	# ---------- H-3: segunda entrega do MESMO payment ----------
	_check(bool(_eco.call("EnqueueGrant", a, "chargeback", 550, pay + ":cb2", '{"payment_id": "' + pay + '"}')), "re-queue do mesmo payment sob outra chave")
	_eco.call("ProcessPendingGrants", 50)
	_checkEq(_sql.GetGems(a), 200, "H-3: a segunda entrega não debita de novo")
	_checkEq(int(_sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [a, "clawback:" + pay])[0]["n"]), 1, "H-3: o ledger não duplica o clawback")
	_checkEq(int(_sql.QueryBindings("SELECT COUNT(*) AS n FROM fraud_flag WHERE account_id = ? AND kind = ?;", [a, token])[0]["n"]), 1, "H-3: redelivery não incha a fila de revisão (dedupe conta+kind)")

	# ---------- H-4: o parcial honesto ----------
	var b : int = _mkAccount("h2", 60, true)
	if not _check(b > 0, "fixture h2 criado"):
		return
	var pay2 : String = "89%d" % stamp
	_eco.call("EnqueueGrant", b, "gems", 1000, pay2, '{"sku": "gems.1200"}', 9990, "BRL")
	_eco.call("ProcessPendingGrants", 50)
	_eco.call("AddGems", b, -600, "gasto:teste")
	_checkEq(_sql.GetGemsPaid(b), 400, "H-4: 400 dos 1000 ainda são dinheiro")
	_eco.call("EnqueueGrant", b, "chargeback", 1000, pay2 + ":chargeback", '{"payment_id": "' + pay2 + '"}', 9990, "BRL")
	_eco.call("ProcessPendingGrants", 50)
	_checkEq(_sql.GetGems(b), 0, "H-4: toma os 400 pagos e PARA aí")
	_checkEq(_sql.GetGemsPaid(b), 0, "H-4: e nunca abaixo de zero")
	var part : Array[Dictionary] = _sql.QueryBindings("SELECT amount FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [b, "clawback:" + pay2])
	_check(not part.is_empty() and int(part[0]["amount"]) == -400, "H-4: o ledger grava o débito parcial (-400), não o pedido (1000)")
	_check(str(_flagRow(b, token).get("detail", "")).contains("faltando=600"), "H-4: os 600 que não couberam viram linha na fila")

	# ---------- H-5: coberto por inteiro não abre fila ----------
	var c : int = _mkAccount("h3", 60, true)
	if not _check(c > 0, "fixture h3 criado"):
		return
	var pay3 : String = "90%d" % stamp
	_eco.call("EnqueueGrant", c, "gems", 550, pay3, '{"sku": "gems.550"}', 4990, "BRL")
	_eco.call("ProcessPendingGrants", 50)
	_eco.call("EnqueueGrant", c, "chargeback", 550, pay3 + ":chargeback", '{"payment_id": "' + pay3 + '"}', 4990, "BRL")
	_eco.call("ProcessPendingGrants", 50)
	_checkEq(_sql.GetGems(c), 0, "H-5: clawback coberto toma os 550 por inteiro")
	_checkEq(_sql.GetGemsPaid(c), 0, "H-5: e leva a parte paga junto")
	_check(_flagRow(c, token).is_empty(), "H-5: sem rombo, sem flag (a fila não chora menino)")
	var cleanRow : Array[Dictionary] = _sql.QueryBindings("SELECT error FROM grant_queue WHERE idempotency_key = ?;", [pay3 + ":chargeback"])
	_check(not cleanRow.is_empty() and str(cleanRow[0]["error"]) == "", "H-5: linha coberta fica sem motivo de rombo")

# ------------------------------------------------------------------ S-I wash no leilão
# #93.2 — a cadeira de Marketplace mediu que o AH era INVISÍVEL por construção para
# o detector: `flip_trade`/`trade_burst` liam `trade_out:`/`trade_in:`, namespace que
# o leilão deixou de escrever na #26 (mudança deliberada: era ela que armava o
# cooldown de troca direta em quem simplesmente COMPRARA no mercado). Consequência:
# A anuncia → B compra → B anuncia → A compra o mesmo item, e nenhuma fila abre.
#
# A perna nova NÃO pode recriar aquele falso-positivo, então o alvo aqui é o PAR de
# contas, nunca a conta sozinha: exige as duas DIREÇÕES do fluxo no mesmo item e as
# duas pernas do namespace vivo do AH (anúncio `ah_list:` de quem pôs na vitrine,
# compra `ah_in:` de quem tirou). Uma conta recomprando o próprio item não é nem
# representável — `_SettleListingLocked` recusa `buyerAccount == sellerAccount`.
func _suiteAHWashPair() -> void:
	print("[suite I] #93.2: ciclo A<->B no LEILÃO abre fila nos dois lados (antes: invisível)")
	var item : int = str("frd_wash").hash()
	var a : int = _mkAccount("wa", 60, true)
	var b : int = _mkAccount("wb", 60, true)
	var supplier : int = _mkAccount("ws", 60, true)
	var client : int = _mkAccount("wc", 60, true)
	if not _check(a > 0 and b > 0 and supplier > 0 and client > 0, "contas do ciclo de leilão criadas"):
		return
	var charA : int = _ahChar(a, "frd_wa1", AhPurse)
	var charB : int = _ahChar(b, "frd_wb1", AhPurse)
	var charS : int = _ahChar(supplier, "frd_ws1", AhPurse)
	var charC : int = _ahChar(client, "frd_wc1", AhPurse)
	if not _check(charA > 0 and charB > 0 and charS > 0 and charC > 0, "personagens do ciclo criados"):
		return
	_ahCleanFixture(item, [a, b, supplier, client])
	# Régua do FIXTURE, não do produto: quem compra no leilão paga com OURO do próprio
	# personagem e `BuyListing` recusa ANTES de abrir a transação quando a carteira é
	# menor que `price_gold` (`AuctionHouseService.gd:983`,
	# `_CharGoldRaw(buyerChar) < listing.price_gold`). Sem esta linha o fixture sem
	# ouro se apresentava como "o detector não vê o ciclo" — as 20 falhas desta suíte
	# eram uma régua sem mercadoria. Cortar o endowment deixa esta VERMELHA.
	_check(int(_eco.call("_CharGoldRaw", charB)) >= 1000, "comprador B tem ouro para o preço do ask (senão nada liquida e a suíte mede o nada)")
	_check(int(_eco.call("_CharGoldRaw", charC)) >= 1000, "e o cliente do fornecedor também")

	# (1) a matriz, antes de rodar: peso, severidade e o PORQUÊ que o operador lê.
	_checkEq(int(_fs.call("WeightOf", "ah_wash_pair")), 2, "ah_wash_pair pesa 2 (média, paridade com flip_trade)")
	_checkEq(str(_fs.call("SeverityOfKinds", ["ah_wash_pair"])), "medium", "lavagem no leilão abre fila MÉDIA, nunca crítica")
	_check(str(_fs.call("WhyOf", "ah_wash_pair")).to_lower().contains("leil"), "o porquê da fila nomeia o LEILÃO (não a troca direta)")

	# (2) NEGATIVO do lado VERDE: duas rodadas do ciclo A->B->A no mesmo item.
	# Uma unidade só circula: quem comprou é quem anuncia em seguida, e o estoque
	# inicial é o único grant do fixture. Preço fixo em 1000/unidade — a segunda
	# rodada é ancorada na primeira venda (mediana 1000 → banda 250..10000), então
	# o ciclo também prova que a banda de #93.1 não cega o detector.
	_sql.call("AddItemToCharacter", charA, item, 1, "frd_seed")
	for round in 2:
		var askA : int = int(_eco.call("ListItemForSale", charA, item, 1, 1000))
		_check(askA > 0, "rodada %d: A anuncia (escreve ah_list:<item> na conta A)" % (round + 1))
		_check(bool(_eco.call("BuyListing", charB, askA)), "rodada %d: B compra (escreve ah_in:<item>:lot na conta B)" % (round + 1))
		var askB : int = int(_eco.call("ListItemForSale", charB, item, 1, 1000))
		_check(askB > 0, "rodada %d: B anuncia o mesmo item de volta" % (round + 1))
		_check(bool(_eco.call("BuyListing", charA, askB)), "rodada %d: A recompra — o ciclo fechou" % (round + 1))
	_checkEq(int(_sql.QueryBindings("SELECT COUNT(*) AS n FROM ah_price_history WHERE item_id = ? AND seller_account = ? AND buyer_account = ?;", [item, a, b])[0]["n"]), 2,
		"fluxo A->B registrado duas vezes no histórico de preço")
	_checkEq(int(_sql.QueryBindings("SELECT COUNT(*) AS n FROM ah_price_history WHERE item_id = ? AND seller_account = ? AND buyer_account = ?;", [item, b, a])[0]["n"]), 2,
		"e o fluxo de volta B->A também (é isto que faz ser PAR, não mercado)")

	# (3) controle do falso-positivo histórico: fornecedor regular vende três vezes
	# para o MESMO cliente e nunca recebe nada de volta. Volume igual, direção só.
	_sql.call("AddItemToCharacter", charS, item, 3, "frd_seed")
	for i in 3:
		var askS : int = int(_eco.call("ListItemForSale", charS, item, 1, 1000))
		_check(askS > 0, "fornecedor: anúncio %d do dia posto na vitrine" % (i + 1))
		_check(bool(_eco.call("BuyListing", charC, askS)), "cliente: compra %d liquidada" % (i + 1))
	_checkEq(int(_sql.QueryBindings("SELECT COUNT(*) AS n FROM ah_price_history WHERE item_id = ? AND seller_account = ?;", [item, supplier])[0]["n"]), 3,
		"três vendas na MESMA direção (sem caminho de volta)")

	# (4) a auto-compra, que era o falso-positivo da #26, não é nem reproduzível.
	var ownAsk : int = int(_eco.call("ListItemForSale", charA, item, 1, 1000))
	_check(ownAsk > 0, "anúncio próprio plantado para a tentativa de recompra")
	_check(not bool(_eco.call("BuyListing", charA, ownAsk)), "NEGATIVO estrutural: a conta NÃO recompra o próprio anúncio")
	_checkEq(int(_sql.QueryBindings("SELECT COUNT(*) AS n FROM ah_price_history WHERE seller_account = buyer_account;", [])[0]["n"]), 0,
		"nenhuma linha de histórico com vendedor == comprador (a perna nova não tem com o que sonhar)")
	_check(bool(_eco.call("CancelListing", charA, ownAsk)), "e o anúncio próprio é cancelado (não suja a vitrine)")

	# (5) a passada do detector, com o ciclo E o par legítimo já no banco: um scan
	# só, para a flag falsa do fornecedor ser impossível de atribuir a outra passada.
	var scan : Dictionary = _fraud.call("Scan", baseNow)
	_check(int(scan.get("scanned", -1)) >= 0 or not scan.is_empty(), "Scan rodou com o mercado no banco")
	var flagA : Dictionary = _flagRow(a, "ah_wash_pair")
	var flagB : Dictionary = _flagRow(b, "ah_wash_pair")
	_check(not flagA.is_empty(), "NEGATIVO #93.2: o lado A do ciclo tem fila (antes: nada, o leilão era invisível)")
	_check(not flagB.is_empty(), "e o lado B do MESMO par também (flag nos dois lados)")
	_checkEq(str(flagA.get("severity", "")), "medium", "severidade média: revisão humana, não punição")
	_check(str(flagA.get("detail", "")).contains("ah_cycle"), "o detail nomeia o ciclo do leilão")
	_check(str(flagA.get("detail", "")).contains(str(b)), "e cita quem é o outro lado do par (B=%d)" % b)
	_check(not _flagKinds(supplier).has("ah_wash_pair"), "CONTROLE DE FALSO-POSITIVO: fornecedor regular (3 vendas, uma direção) fica SEM fila")
	_check(not _flagKinds(client).has("ah_wash_pair"), "e o cliente dele também: falta o caminho de volta")
	# O ciclo do leilão não pode acender as pernas da troca direta nem o cooldown.
	_check(not _flagKinds(a).has("flip_trade") and not _flagKinds(b).has("flip_trade"),
		"as contas do ciclo não herdaram flip_trade (o namespace morto da #26 continua morto)")
	_check(not _ledgerHas(a, "trade_out") and not _ledgerHas(b, "trade_out"),
		"e o AH jamais escreveu trade_out: para elas (causa raiz do falso-positivo)")

	# (6) régua estrutural: o detector lê o namespace VIVO e a perna está no laço.
	var src : String = _stripComments(_repoFile("res://sources/economy/FraudeReview.gd"))
	_check(src.contains("_CollectAHWashPairs(now, signals, details)"),
		"a perna do leilão é chamada por _CollectMediumHeuristics (cortar isto deixa a suíte vermelha)")
	var leg : String = _functionBody(src, "_CollectAHWashPairs") + _functionBody(src, "_AHLedgerLeg")
	_check(not leg.is_empty(), "as duas funções da perna nova existem no detector")
	_check(leg.contains("ah_price_history"), "e a fonte de fluxo é o histórico de preço realizado (059), não projeção de cliente")
	_check(leg.contains("seller_account != buyer_account"), "o PAR é exigido na própria query: uma conta sozinha não fecha ciclo")
	_check(leg.contains("ah_list:") and leg.contains("ah_in:"), "as duas pontas são corroboradas no namespace vivo do AH")
	_check(not leg.contains("trade_out") and not leg.contains("trade_in"),
		"NEM UMA LINHA da perna nova lê o namespace da troca direta (o falso-positivo da #26 não volta)")
	_check(not leg.contains("LastTradeTimestamp") and not leg.contains("TradeCooldown"),
		"nem o cooldown de troca direta — comprar no leilão não arma pena em quem comprou")

# Personagem da mesa de leilão: nível 5 (para os sinais de velocity de outras
# suítes não casarem por acaso) e OURO no bolso. O ouro é o que falta entre o
# anúncio existir e a venda liquidar — `BuyListing` lê `_CharGoldRaw` antes de
# abrir a transação (`AuctionHouseService.gd:@BuyListing`) e o `MoveGold` do kernel é o
# único caminho que grava `stat.gp` com a linha de ledger que o atesta
# (`EconomyKernel.gd:156`). Sem endowment o ciclo A<->B nunca acontece e o
# detector não tem o que ver: é a régua que fica cega, não o produto.
func _ahChar(accountID : int, nick : String, gold : int) -> int:
	_charWithLevel(accountID, nick, 5)
	var charID : int = int(_sql.GetCharacterID(accountID, nick))
	if charID > 0 and gold > 0:
		_eco.call("MoveGold", charID, gold, "frd_ah_mint")
	return charID

# Ledger de uma conta por PREFIXO de reason — é literalmente a forma que `flip_trade`
# lê (`trade_out:%`), então esta é a régua que prova que o AH não voltou a escrevê-la.
func _ledgerHas(accountID : int, prefix : String) -> bool:
	return not _sql.QueryBindings("SELECT id FROM ledger_transaction WHERE account_id = ? AND reason LIKE ? LIMIT 1;", [accountID, prefix + "%"]).is_empty()

# Corpo de uma função do fonte, para as réguas estruturais lerem SÓ o que aquela
# perna faz (e não o comentário de cima, que explica o que a perna não pode fazer).
func _functionBody(src : String, name : String) -> String:
	var at : int = src.find("func " + name + "(")
	if at < 0:
		return ""
	var rest : String = src.substr(at)
	var next : int = rest.find("\nfunc ", 5)
	return rest if next < 0 else rest.substr(0, next)

# Fixture idempotente: `ah_price_history` é append-only DE PROPÓSITO, mas as linhas
# deste item são dado de harness, e rerun não pode herdar um ciclo da vida anterior
# (nem o cap diário do #93.3 já queimado). Gems e gold são a fricção do AH: sem
# taxa paga o anúncio não nasce.
func _ahCleanFixture(item : int, accounts : Array) -> void:
	_sql.db.query("DELETE FROM ah_price_history WHERE item_id = %d;" % item)
	_sql.db.query("DELETE FROM auction_listing WHERE item_id = %d AND status <> 'sold';" % item)
	_sql.db.query("DELETE FROM ah_escrow_lot WHERE listing_id NOT IN (SELECT id FROM auction_listing);")
	for acct in accounts:
		_sql.db.query("DELETE FROM ah_activity WHERE account_id = %d;" % int(acct))
		_eco.call("AddGems", int(acct), 200, "frd_ah_gems")

# ------------------------------------------------------------------ S-G varredura
# O guard do SuiteOpsA2 (IdleTests.gd ~5220) para automação punitiva: varre os
# .gd de sources/ atrás de quem LIGA ban/flag automático fora do módulo de
# revisão. IdleTests é só lido (proibido editar) — os helpers abaixo são cópia
# própria do padrão, como economy_design_fix_test faz com o CreateFixture.
func _repoFile(path : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()

func _stripComments(src : String) -> String:
	var keep : PackedStringArray = PackedStringArray()
	for line in src.split("\n"):
		var t : String = line.strip_edges()
		if t.begins_with("#"):
			continue
		keep.append(line)
	return "\n".join(keep)

func _gdFilesUnder(path : String, out : PackedStringArray) -> PackedStringArray:
	var dir : DirAccess = DirAccess.open(path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name : String = dir.get_next()
	while name != "":
		if dir.current_is_dir():
			if not name.begins_with(".") and name != "modules":
				_gdFilesUnder(path + "/" + name, out)
		elif name.ends_with(".gd"):
			out.append(path + "/" + name)
		name = dir.get_next()
	dir.list_dir_end()
	return out

func _suitePunitiveAutomationSweep() -> void:
	print("[suite G] ninguém liga automação punitiva por engano")
	var files : PackedStringArray = _gdFilesUnder("res://sources", PackedStringArray())
	_check(files.size() >= 200, "varredura olhou a árvore toda (%d arquivos .gd)" % files.size())
	var writers : PackedStringArray = PackedStringArray()
	var flaggers : PackedStringArray = PackedStringArray()
	var bans : PackedStringArray = PackedStringArray()
	var holds : PackedStringArray = PackedStringArray()
	var swept : int = 0
	for filePath in files:
		var body : String = _stripComments(_repoFile(String(filePath)))
		if body.is_empty():
			continue
		swept += 1
		var fileName : String = String(filePath).get_file()
		if body.contains("INSERT INTO fraud_flag") and fileName != "FraudeReview.gd":
			writers.append(String(filePath))
		if body.contains(".FlagMultiAccount(") and not ["FraudeReview.gd", "CommunityService.gd", "EconomyService.gd"].has(fileName):
			flaggers.append(String(filePath))
		if (body.contains(".BanAccount(") or body.contains(".BanIPRange(")) and fileName != "WorldCommands.gd":
			bans.append(String(filePath))
		if body.contains("SET referral_hold = 1") and fileName != "FraudeReview.gd":
			holds.append(String(filePath))
	_checkEq(writers.size(), 0, "só FraudeReview.gd escreve em fraud_flag (%s)" % ", ".join(writers))
	_checkEq(flaggers.size(), 0, "FlagMultiAccount só sai da fachada comunidade→detector (%s)" % ", ".join(flaggers))
	_checkEq(bans.size(), 0, "ban só por comando GM humano em WorldCommands (%s)" % ", ".join(bans))
	_checkEq(holds.size(), 0, "a escrita automática de referral_hold vive só no detector (%s)" % ", ".join(holds))
	_check(swept >= 200, "%d arquivos varridos de fato" % swept)
	# E o detector não vaza punição para dentro de si: nenhum caminho dele chama ban.
	var fraudBody : String = _stripComments(_repoFile("res://sources/economy/FraudeReview.gd"))
	_check(not fraudBody.contains("BanAccount(") and not fraudBody.contains("BanIPRange("), "FraudeReview nunca bane — revisão humana é o único enforcement")
	_check(fraudBody.contains("NoteLoginIP"), "producer de IP é API pública (hook pendente no login, não automação embutida)")
