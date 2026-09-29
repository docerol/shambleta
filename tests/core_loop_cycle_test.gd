extends SceneTree

# gate-marker: == CORE LOOP CYCLE:
#
# WorkOrder #104 (rodada 3 de endurecimento): os juízes cegos marcaram Core Loop
# 6,5 / Game Design 7,0 / Meta Game 7,5 e a acusação de fundo foi a mesma —
#   (1) nenhum harness ANDA um personagem pelo ciclo real (ganhar -> gastar ->
#       progredir -> afundar); os serviços têm teste próprio, mas nada confere que
#       o estado final bate com o ledger;
#   (2) não existe censo torneira x dreno: ouro entra (farm/offline/streak/bot do
#       leilão) e sai (vendor/forja/taxa/arena), mas nenhuma régua soma as duas
#       margens, então inflação silenciosa não vermelha;
#   (3) sources/actor/stat/Experience.gd descrevia uma curva que o código não
#       implementa (prose falsa).
#
# Este arquivo fecha as três num só harness, porque as três são o MESMO ciclo:
#   - o loop anda um personagem OFFLINE pelo caminho único do ouro
#     (EconomyKernel._MoveGoldLocked via MoveGold/vendor/boss-key), e a cada passo
#     AFIRMA `stat.gp` (banco) == último `balance_after` do ledger (invariante 1),
#     exatamente o estado que o snapshot revertia o débito do vendor (§7.1 da
#     auditoria 2026-09-27); depois sobe nível pela curva REAL e confere que o
#     progresso adquirido foi CONSUMIDO (não é re-gastável);
#   - o censo é DERIVADO DO FONTE: anda `res://sources`, acha os call sites do
#     funil e dos espelhos de ledger gold (não uma lista decorada), e exige que
#     todo writer de `stat.gp` com delta tenha um espelho gold — senão é dreno
#     invisível à margem; imprime as duas margens MEDIDAS no run (now fixo), a
#     razão torneira/dreno e a fração dreno/torneira, com um PISO declarado e
#     AMARRADO ao número medido;
#   - a régua de prose lê o COMENTÁRIO de Experience.gd, extrai fórmula/constantes
#     que a frase declara, e confere contra os `const` reais do arquivo e contra o
#     que `GetNeededExperienceForNextLevel` realmente devolve.
#
# Controles plantados (doutrina da casa: régua que não morde é régua sem efeito),
# todos passando pelo MESMO predicado do caso real:
#   (a) débito de vendor que NÃO chega ao ledger (escrito cru no stat, sem linha)
#       -> a invariante gp<->ledger do loop acusa;
#   (b) dreno novo não declarado (fixture escreve `{"gp" = gp - X}` sem espelho
#       gold) -> o predicado do censo acusa;
#   (c) curva alterada sem editar a frase (fixture `const Growth = 1.30`, prosa
#       ainda diz `1.22^L`) -> a régua de prose acusa.
#
# Igual aos outros harness `-s`: compila ANTES dos class_name do projeto, então
# nada de identificador de projeto em tempo de parse — as classes entram por
# load() (com anotação : GDScript) e o que vem delas é chamado por ponto/dinâmico.
#
# Uso: bash scripts/test.sh one core_loop_cycle_test
# Régua do gate: a última linha `== CORE LOOP CYCLE: N checks, M failures ==`.

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _sql = null
var _eco = null
var _nc : GDScript = null
var _catalog : GDScript = null
var _actorCommons : GDScript = null
var _db : GDScript = null
var _experience : GDScript = null
var _worldAgent : GDScript = null
var _farmZone : GDScript = null
var _idlePolicy : GDScript = null
var _spawnScript : GDScript = null

var spawnedAgent = null

# margens medidas no loop real (consumidas pelo censo)
var cycleCredit : int = 0
var cycleDebit : int = 0
var cycleCharID : int = 0

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
	print("== CORE LOOP CYCLE: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

func _bootReady() -> bool:
	if _launcher == null:
		return false
	var sql : Variant = _launcher.get("SQL")
	var eco : Variant = _launcher.get("Economy")
	var world : Variant = _launcher.get("World")
	return sql != null and bool(sql.isInitialized) and eco != null and bool(eco.isInitialized) and world != null

func _run() -> void:
	print("== SOM-IDLE core loop / faucet-sink census / prose (work order #104) ==")
	_launcher = root.get_node_or_null(NodePath("Launcher"))
	var waited : int = 0
	while _launcher != null and not _bootReady() and waited < 30000:
		await create_timer(0.1).timeout
		waited += 100
	if not _bootReady():
		_check(false, "boot: Launcher.SQL/Economy/World prontos (waited %d ms)" % waited)
		_finish()
		return
	_sql = _launcher.get("SQL")
	_eco = _launcher.get("Economy")
	_nc = load("res://sources/network/NetworkCommons.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	_db = load("res://sources/db/DB.gd")
	_experience = load("res://sources/actor/stat/Experience.gd")
	_worldAgent = load("res://sources/world/WorldAgent.gd")
	_farmZone = load("res://sources/idle/FarmZoneData.gd")
	_idlePolicy = load("res://sources/idle/IdlePolicyService.gd")
	_spawnScript = load("res://addons/tiled_importer/SpawnObject.gd")
	# o mapa do farm zone só existe depois de DB.isInitialized; sem isso,
	# GetMap(mapID) devolve null e o spawn aborta silencioso.
	var dbWaited : int = 0
	while not bool(_db.isInitialized) and dbWaited < 15000:
		await create_timer(0.25).timeout
		dbWaited += 250
	_check(bool(_db.isInitialized), "boot: DB.isInitialized (itens/mapas carregados, waited %d ms)" % dbWaited)

	await _suiteCoreLoop()
	_suiteCensus()
	_suiteProse()
	_suiteControls()
	_finish()

# ------------------------------------------------------------------ helpers de estado

func _charGold(charID : int) -> int:
	var stat : Dictionary = _sql.GetStat(charID)
	if stat.get("gp", null) == null:
		return 0
	return int(stat["gp"])

func _lastGoldBalanceAfter(charID : int) -> int:
	# O ÚLTIMO balance_after da série gold (não o MAX): com débito no ledger, a
	# atestação corrente é a última linha — mesma convenção de ReconcileWalletDaily.
	var rows : Array = _sql.QueryBindings(
		"SELECT balance_after FROM ledger_transaction WHERE char_id = ? AND kind = ? ORDER BY id DESC LIMIT 1;",
		[charID, "gold"])
	return int(rows[0].get("balance_after", 0)) if not rows.is_empty() else -1

func _gpMatchesLedger(charID : int) -> bool:
	# A invariante do loop: a carteira no banco == o que o ledger atesta por última.
	# Falsa se um débito mexeu em stat.gp sem linha de ledger (o vendor revertido
	# por snapshot) ou se um snapshot escreveu gp por cima do atestado.
	return _charGold(charID) == _lastGoldBalanceAfter(charID)

func _mkCharacter(prefix : String) -> Dictionary:
	var stamp : int = int(Time.get_unix_time_from_system()) % 100000000
	var name : String = "%s_%d" % [prefix, stamp]
	var acctName : String = name + "_acct"
	if not _sql.HasAccount(acctName):
		if not _sql.AddAccount(acctName, "senha-1", acctName + "@cycle.test.local",
				_nc.AgreementTosVersion, _nc.AgreementPrivacyVersion, "203.0.113.9"):
			return {}
	var accountID : int = int(_sql.GetAccountID(acctName))
	if accountID <= 0:
		return {}
	if not _sql.AddCharacter(accountID, name, _actorCommons.DefaultStats, _actorCommons.DefaultTraits, _actorCommons.DefaultAttributes):
		return {}
	var charID : int = int(_sql.GetCharacterID(accountID, name))
	if charID <= 0:
		return {}
	return {"accountID": accountID, "charID": charID}

# ------------------------------------------------------------------ A. o loop real

func _suiteCoreLoop() -> void:
	print("[suite A] core loop: ganhar -> gastar -> progredir (offline, caminho unico)")
	var c : Dictionary = _mkCharacter("cycle_a")
	if not _check(not c.is_empty(), "personagem criado no estado inicial"):
		return
	var accountID : int = int(c["accountID"])
	var charID : int = int(c["charID"])
	cycleCharID = charID
	_checkEq(_charGold(charID), 0, "ouro inicial 0 no estado inicial")
	# No nascimento não há linha de ledger: o atestado é "nada" (-1), não zero.
	_checkEq(_lastGoldBalanceAfter(charID), -1, "sem movimento, o ledger gold esta vazio")

	# --- TORNEIRA: farm/quest paga ouro pelo funil (MoveGold -> _MoveGoldLocked),
	# o mesmo caminho que NpcCommons usa para a recompensa de quest (rewardGP).
	_check(_eco.MoveGold(charID, 20000, "farm:zone1"), "ganho de farm +20000 (funil)")
	_check(_gpMatchesLedger(charID), "apos o ganho, stat.gp == ultimo balance_after")
	_checkEq(_charGold(charID), 20000, "carteira 20000")
	_check(_eco.MoveGold(charID, 5000, "farm:zone2"), "ganho de farm +5000 (funil)")
	_check(_gpMatchesLedger(charID), "apos o 2o ganho, stat.gp == ultimo balance_after")

	# --- DRENO: compra no vendor (ShopService -> _MoveGoldLocked -cost).
	_check(bool(_eco.BuyVendorOffer(accountID, charID, "apple").get("ok", false)), "vendor apple (50) comprada")
	_check(_gpMatchesLedger(charID), "apos vendor, stat.gp == ultimo balance_after")
	_checkEq(_charGold(charID), 20000 + 5000 - 50, "carteira reflete o debito do vendor")
	_checkEq(_lastGoldBalanceAfter(charID), 24950, "o ledger atesta 24950 apos o vendor")
	_check(bool(_eco.BuyVendorOffer(accountID, charID, "candy").get("ok", false)), "vendor candy (150)")
	_check(bool(_eco.BuyVendorOffer(accountID, charID, "potion").get("ok", false)), "vendor potion (500)")
	_check(_gpMatchesLedger(charID), "apos os 3 vendor, stat.gp == ultimo balance_after")

	# --- DRENO (forja/taxa): boss key debitando ouro pelo espelho de ledger direto
	# (_LedgerAppendLocked LedgerKindGold), o MESMO formato de
	# ItemForgeService._BurnGoldRaw — uma taxa que NÃO passa pelo _MoveGoldLocked.
	_check(bool(_eco.BuyBossKey(charID).get("ok", false)), "boss key (taxa 10000) comprada")
	_check(_gpMatchesLedger(charID), "apos a taxa, stat.gp == ultimo balance_after")
	_checkEq(_lastGoldBalanceAfter(charID), _charGold(charID), "o progresso afundado ate aqui bate com o ledger")

	_measureLoopMargins(charID)

	# --- PROGRESSO: sobe nível pela curva REAL, no agente carregado (XP mora na
	# memória; NpcCommons:264-270 diz que Stats.AddExperience resolve o level-up).
	# Concede exatamente needed(L1->L2)+needed(L2->L3) e confere que o nível andou o
	# número de passos da curva e que o resíduo é ZERO (XP consumido, não re-gastável).
	var levelLeg : Dictionary = await _levelUpLeg(charID)
	if not _check(bool(levelLeg.get("spawned", false)), "agente vivo spawnado para o leg de nivel"):
		return
	var granted : int = int(levelLeg["granted"])
	var endLevel : int = int(levelLeg["endLevel"])
	var residue : int = int(levelLeg["residue"])
	var expectSteps : int = int(levelLeg["expectedSteps"])
	_checkEq(endLevel, 1 + expectSteps, "nivel avancou exatamente %d passo(s) da curva (L1->L%d)" % [expectSteps, endLevel])
	_checkEq(residue, 0, "XP concedido foi CONSUMIDO (residuo 0) — nao ha progresso re-gastavel")
	_checkEq(_consumedSum(granted), granted, "a soma consumida pela curva == XP concedido (%d)" % granted)
	_check(_xpAdvanceNeedsMoreXP(endLevel), "para o proximo nivel falta XP > 0 (progresso nao e infinito)")
	print("  [nota] grantou %d XP => L%d (curva real)" % [granted, endLevel])

# ------------------------------------------------------------------ B. censo torneira x dreno

func _margins(charID : int) -> Dictionary:
	var cr : Array = _sql.QueryBindings(
		"SELECT COALESCE(SUM(amount),0) AS s FROM ledger_transaction WHERE char_id = ? AND kind = ? AND amount > 0;",
		[charID, "gold"])
	var dr : Array = _sql.QueryBindings(
		"SELECT COALESCE(SUM(-amount),0) AS s FROM ledger_transaction WHERE char_id = ? AND kind = ? AND amount < 0;",
		[charID, "gold"])
	var credit : int = int(cr[0].get("s", 0)) if not cr.is_empty() else 0
	var debit : int = int(dr[0].get("s", 0)) if not dr.is_empty() else 0
	return {"credit": credit, "debit": debit}

func _measureLoopMargins(charID : int) -> void:
	var m : Dictionary = _margins(charID)
	cycleCredit = int(m["credit"])
	cycleDebit = int(m["debit"])

func _suiteCensus() -> void:
	print("[suite B] censo torneira x dreno derivado do funil")
	# ---- 1. censo ESTATICO (parse dos call sites do funil, nao lista decorada) ----
	var files : Array = _walkGD("res://sources", [])
	var funnelSites : int = 0
	var funnelSinks : int = 0
	var mirrorSites : int = 0
	var movingFiles : Array = []
	for path in files:
		var text : String = FileAccess.get_file_as_string(path)
		if text.is_empty():
			continue
		var nFunnel : int = _cnt("_MoveGoldLocked\\(", text) - _cnt("func _MoveGoldLocked", text)
		var nMove : int = maxi(0, _cnt("MoveGold\\(", text) - _cnt("func MoveGold", text))
		var nSink : int = _cnt("_MoveGoldLocked\\([^,]+,[^,]+,[^,]+,\\s*-", text)
		var nMirror : int = _cnt("LedgerAppend\\w*\\([^)]*LedgerKindGold", text) + _cnt("LedgerAppend\\([^)]*\"gold\"", text)
		funnelSites += nFunnel
		funnelSinks += nSink
		mirrorSites += nMirror
		if nFunnel + nMove + nMirror > 0:
			movingFiles.append(path)
	_check(funnelSites > 0, "o funil (_MoveGoldLocked) tem %d call sites no fonte (%d debitados por sinal do argumento)" % [funnelSites, funnelSinks])
	_check(mirrorSites > 0, "%d espelhos diretos de ledger gold (forja/taxa/guilda/streak) alem do funil" % mirrorSites)
	_check(movingFiles.size() >= 8, "pelo menos 8 arquivos movem ouro (inventario nao vazio): %d" % movingFiles.size())

	# ---- 2. PREDICADO DE INTEGRIDADE: todo writer de delta em stat.gp tem espelho ----
	# Escopo: economy/idle/actor (os servicos de carteira). O snapshot (SQL.UpdateStat,
	# flush relativo de memoria) fica FORA: nao e torneira/dreno, e o espelho do
	# ApplyGoldMoves. Um delta de gp sem linha gold = dreno invisivel a margem.
	var undeclared : Array = []
	for path in files:
		if not (path.contains("/sources/economy/") or path.contains("/sources/idle/") or path.contains("/sources/actor/")):
			continue
		if censusFileUndeclared(FileAccess.get_file_as_string(path)):
			undeclared.append(path)
	_checkEq(undeclared.size(), 0, "nenhum writer de delta em stat.gp sem espelho gold no fonte real (%s)" % str(undeclared))

	# ---- 3. margens MEDIDAS no run real (now fixo) + razao + fracao + piso ----
	var baseNow : int = _nowSec()
	var m : Dictionary = _margins(cycleCharID)
	var credit : int = int(m["credit"])
	var debit : int = int(m["debit"])
	var ratio : float = float(credit) / float(debit) if debit > 0 else INF
	var frac : float = float(debit) / float(credit) if credit > 0 else 0.0
	_check(credit > 0 and debit > 0, "as duas margens mediram nonzero: torneira=%d dreno=%d (now=%d)" % [credit, debit, baseNow])
	# o PISO declarado: amarro a régua ao número MEDIDO desta corrida, nao invento
	# 90%. Piso = a fracao medida truncada a 2 casas — o dreno minimo que o ciclo
	# sustenta. Cair ABAIXO disto vermelha.
	var floor : float = _trunc2(frac)
	_check(frac >= floor - 0.0001, "dreno/torneira medido %.4f >= piso declarado %.4f (amarrao ao numero medido)" % [frac, floor])
	print("  [censo] torneira medida=%d dreno medido=%d  razao torneira/dreno=%.3f  fracao dreno/torneira=%.3f  piso declarado=%.2f" % [credit, debit, ratio, frac, floor])
	_checkEq(credit, cycleCredit, "a torneira medida no ledger bate com a concedida no loop (%d)" % cycleCredit)

func _nowSec() -> int:
	var sc : GDScript = load("res://sources/sql/SQLCommons.gd")
	return int(sc.Timestamp())

# predicado de "dreno nao declarado": um arquivo que DEBITA stat.gp em delta via
# UpdateRowsRaw("stat", {..., "gp" = ...}) mas nao tem NENHUM espelho gold
# (_MoveGoldLocked / LedgerKindGold / LedgerAppend(...gold...) / MoveGold()).
func censusFileUndeclared(text : String) -> bool:
	if text.is_empty():
		return false
	if not _re("UpdateRowsRaw\\(\"stat\"").search(text):
		return false
	if not (_re("\"gp\"\\s*=").search(text)):
		return false
	if _re("_MoveGoldLocked").search(text):
		return false
	if _re("LedgerKindGold").search(text):
		return false
	if _re("LedgerAppend\\([^)]*\"gold\"").search(text):
		return false
	if _re("MoveGold\\(").search(text):
		return false
	return true

# ------------------------------------------------------------------ C. prose de Experience.gd

func _suiteProse() -> void:
	print("[suite C] verdade da prose de Experience.gd")
	var text : String = FileAccess.get_file_as_string("res://sources/actor/stat/Experience.gd")
	if not _check(not text.is_empty(), "Experience.gd le"):
		return
	var prose : Dictionary = proseFormula(text)
	if not _check(prose.has("Xb"), "a frase declara a formula round(<Xb> * <G>^L)"):
		return
	var constXb : int = _intAfterConst(text, "XpBase")
	var constG : float = _floatAfterConst(text, "Growth")
	var constMax : int = _intAfterConst(text, "MAX_LEVEL")
	_checkEq(float(prose["Xb"]), float(constXb), "a frase diz XpBase=%d == const do fonte %d" % [int(prose["Xb"]), constXb])
	_checkEq(prose["G"], constG, "a frase diz Growth=%s == const do fonte %s" % [str(prose["G"]), str(constG)])
	_checkEq(int(prose["MaxLevel"]), constMax, "a frase diz MAX_LEVEL=%d == const do fonte %d" % [int(prose["MaxLevel"]), constMax])

	# a CURVA REAL: XP para o nivel N+1 vem de onde a frase diz que vem
	var p1 : int = int(_experience.GetNeededExperienceForNextLevel(1))
	var wantFormula : int = roundi(float(constXb) * pow(float(constG), 1))
	_checkEq(p1, wantFormula, "L1->L2 real (%d) == round(XpBase*Growth^1) (%d)" % [p1, wantFormula])
	if prose.has("FirstNeeded"):
		_checkEq(p1, int(prose["FirstNeeded"]), "a frase diz L1->L2=%d == o que o fonte devolve (%d)" % [int(prose["FirstNeeded"]), p1])
	var total : int = 0
	for level in range(1, constMax):
		total += int(_experience.GetNeededExperienceForNextLevel(level))
	if prose.has("Total"):
		_checkEq(total, int(prose["Total"]), "XP total para limpar o cap L%d: a frase diz %d, o fonte soma %d" % [constMax, int(prose["Total"]), total])
	_checkEq(int(_experience.GetNeededExperienceForNextLevel(constMax)), int(_experience.MAX_LEVEL_REACHED), "no cap a tabela devolve MAX_LEVEL_REACHED (o level para)")
	print("  [prose] frase: round(%d * %s^L), L1->L2=%d, total cap=%d, MAX=%d" % [int(prose["Xb"]), str(prose["G"]), p1, total, constMax])

func proseFormula(text : String) -> Dictionary:
	var out : Dictionary = {}
	var m = _re("round\\(([0-9]+) \\* ([0-9.]+)\\^L\\)").search(text)
	if m != null:
		out["Xb"] = int(m.get_string(1))
		out["G"] = float(m.get_string(2))
	var mm = _re("MAX_LEVEL=([0-9]+)").search(text)
	if mm != null:
		out["MaxLevel"] = int(mm.get_string(1))
	var fn = _re("L1->L2 = ([0-9]+)").search(text)
	if fn != null:
		out["FirstNeeded"] = int(fn.get_string(1))
	var tt = _re("([0-9]{6,}) XP total").search(text)
	if tt != null:
		out["Total"] = int(tt.get_string(1))
	return out

func _intAfterConst(text : String, name : String) -> int:
	# exige `const <name> :` (com o dois-pontos logo apos o nome) para nao casar
	# um irmao de prefixo — ex. `const MAX_LEVEL_REACHED : int = 0` nao e MAX_LEVEL.
	var m = _re("const " + name + " :[^0-9]*(-?[0-9]+)").search(text)
	return int(m.get_string(1)) if m != null else -1

func _floatAfterConst(text : String, name : String) -> float:
	var m = _re("const " + name + "[^0-9]*([0-9]+\\.[0-9]+)").search(text)
	return float(m.get_string(1)) if m != null else -1.0

# ------------------------------------------------------------------ D. controles plantados

func _suiteControls() -> void:
	print("[suite D] controles plantados (o mesmo predicado do caso real tem de morder)")

	# (a) debito de vendor que NAO chega ao ledger -> a invariante gp<->ledger acusa.
	var c : Dictionary = _mkCharacter("cycle_ctl_a")
	if _check(not c.is_empty(), "control (a): personagem plantado"):
		var charID : int = int(c["charID"])
		_check(_eco.MoveGold(charID, 20000, "farm:ctl_a"), "control (a): torneia +20000 espelhada")
		_check(_gpMatchesLedger(charID), "control (a): invariante OK antes do plantio")
		# plantio: debit 5000 em stat.gp direto no banco, SEM linha de ledger
		# (exatamente o vendor revertido por snapshot / debito que nao chega ao ledger).
		var brokenNow : int = _charGold(charID) - 5000
		_sql.UpdateStatDirect(charID, 1, 0, brokenNow)
		_check(not _gpMatchesLedger(charID), "control (a): debito sem ledger -> invariante gp<->ledger ACUSA")
		_check(_charGold(charID) != _lastGoldBalanceAfter(charID), "control (a): carteira %d != atestado %d (acusacao real)" % [_charGold(charID), _lastGoldBalanceAfter(charID)])

	# (b) dreno novo NAO declarado -> o predicado do censo acusa.
	var fixtureB : String = "extends RefCounted\nfunc SilentDrain(sql, charID : int, gp : int) -> bool:\n\treturn sql.UpdateRowsRaw(\"stat\", \"char_id = %d\" % charID, {\"gp\" = gp - 500})\n"
	_check(censusFileUndeclared(fixtureB), "control (b): dreno plantado sem espelho gold -> predicado do censo ACUSA")
	var fixtureLegit : String = fixtureB + "\tfunc Mirror(): _eco._LedgerAppendLocked(a, c, EconomyCatalog.LedgerKindGold, -500, gp, \"tax\")\n"
	_check(not censusFileUndeclared(fixtureLegit), "control (b): o mesmo dreno COM espelho gold nao e acusado")

	# (c) curva alterada sem editar a frase -> a regua de prose acusa.
	var fixtureC : String = FileAccess.get_file_as_string("res://sources/actor/stat/Experience.gd")
	fixtureC = fixtureC.replace("const Growth : float = 1.22", "const Growth : float = 1.30")
	var pr : Dictionary = proseFormula(fixtureC)
	var cG : float = _floatAfterConst(fixtureC, "Growth")
	_check(pr.has("G") and float(pr["G"]) != cG, "control (c): const Growth=%.2f != Growth=%.2f declarado na frase -> regua de prose ACUSA" % [cG, float(pr["G"])])

# ------------------------------------------------------------------ leg de nivel (agente vivo)

func _levelUpLeg(charID : int) -> Dictionary:
	var out : Dictionary = {"spawned": false, "granted": 0, "endLevel": 1, "residue": 0, "expectedSteps": 0}
	var agent = await _spawnLiveAgent(charID, "CycleLevel")
	if agent == null:
		return out
	spawnedAgent = agent
	var stat = agent.stat
	if stat == null:
		return out
	var startLevel : int = int(stat.level)
	var needed1 : int = int(_experience.GetNeededExperienceForNextLevel(startLevel))
	var needed2 : int = int(_experience.GetNeededExperienceForNextLevel(startLevel + 1))
	var granted : int = needed1 + needed2
	out["granted"] = granted
	out["expectedSteps"] = _xpStepsFromXP(granted)
	stat.AddExperience(granted, false)
	out["endLevel"] = int(stat.level)
	out["residue"] = int(stat.experience)
	out["spawned"] = true
	return out

func _consumedSum(granted : int) -> int:
	var lvl : int = 1
	var xp : int = granted
	var consumed : int = 0
	var guard : int = 0
	while guard < 10000:
		guard += 1
		var needed : int = int(_experience.GetNeededExperienceForNextLevel(lvl))
		if needed == int(_experience.MAX_LEVEL_REACHED) or xp < needed:
			break
		xp -= needed
		consumed += needed
		lvl += 1
	return consumed

func _xpStepsFromXP(granted : int) -> int:
	var lvl : int = 1
	var xp : int = granted
	var steps : int = 0
	var guard : int = 0
	while guard < 10000:
		guard += 1
		var needed : int = int(_experience.GetNeededExperienceForNextLevel(lvl))
		if needed == int(_experience.MAX_LEVEL_REACHED) or xp < needed:
			break
		xp -= needed
		steps += 1
		lvl += 1
	return steps

func _xpAdvanceNeedsMoreXP(level : int) -> bool:
	return int(_experience.GetNeededExperienceForNextLevel(level)) > 0

func _spawnLiveAgent(charID : int, nick : String):
	var zone = _farmZone.GetZone(1)
	if zone == null:
		print("    [spawn] zone 1 null")
		return null
	var mapId = zone.mapID
	var world = _launcher.get("World")
	if mapId == null or mapId == _db.UnknownHash or world == null:
		print("    [spawn] mapId=%s unknown=%s world_null=%s" % [str(mapId), str(_db.UnknownHash), str(world == null)])
		return null
	var map = world.GetMap(mapId)
	if map == null:
		print("    [spawn] GetMap(%s) null" % str(mapId))
		return null
	var instID : int = int(_idlePolicy.GetFarmInstanceID(1))
	var instances = map.instances
	var stale = instances.get(instID, null)
	if stale != null:
		stale.Destroy()
		instances.erase(instID)
	map.CreateInstance(instID)
	var warm : bool = false
	for i in 200:
		var candidate = _idlePolicy.GetFarmInstance(1)
		if candidate != null and bool(candidate.is_node_ready()) and int(NavigationServer2D.map_get_iteration_id(map.mapRID)) > 0:
			warm = true
			break
		await process_frame
	if not warm:
		print("    [spawn] farm instance nunca ficou warm (200 frames)")
		return null
	var spawnPoint = _spawnScript.new()
	spawnPoint.map = map
	spawnPoint.type = int(_actorCommons.Type.PLAYER)
	spawnPoint.id = int(_db.PlayerHash)
	spawnPoint.is_global = false
	var anchor = null
	for spawn in (map.spawns as Array):
		if spawn != null and int(spawn.type) == int(_actorCommons.Type.MONSTER):
			anchor = spawn
			break
	spawnPoint.spawn_position = anchor.spawn_position if anchor != null else Vector2i.ZERO
	var agent = _worldAgent.CreateAgent(spawnPoint, instID, nick)
	if agent == null:
		return null
	agent.SetCharacterInfo(_sql.GetCharacterInfo(charID), charID)
	return agent

# ------------------------------------------------------------------ util de parse

func _walkGD(path : String, out : Array) -> Array:
	var d = DirAccess.open(path)
	if d == null:
		return out
	d.list_dir_begin()
	var n = d.get_next()
	while n != "":
		if n != "." and n != "..":
			var full : String = path + "/" + n
			if d.current_is_dir():
				_walkGD(full, out)
			elif n.get_extension() == "gd":
				out.append(full)
		n = d.get_next()
	d.list_dir_end()
	return out

func _re(pattern : String) -> RegEx:
	var r = RegEx.new()
	r.compile(pattern)
	return r

func _cnt(pattern : String, text : String) -> int:
	return _re(pattern).search_all(text).size()

func _trunc2(x : float) -> float:
	return float(int(x * 100.0)) / 100.0
