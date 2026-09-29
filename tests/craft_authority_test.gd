extends SceneTree

# SOM-GAMEPLAY (juiz cego 2026-09-27): a auditoria apontou que "craft tem catálogo e
# serviço, mas nenhuma fonte de material" — i.e. o loop ocioso não alimenta a forja.
# Este harness não finge o contrário: ele MED E DOCUMENTA o que a forja É hoje, na
# ponta que importa — AUTORIDADE.
#
# `balance_test.gd` e `economy_design_fix_test.gd` cobrem o budget/teto de modifiers,
# mas os dois chamam `EconomyService.SubmitCraft(charID, accountID, ...)` com a conta
# mastigada no argumento, e NENHUM dos dois chega a gravar uma submissão de verdade
# (sem `email_verified` a aceite morre em `email_not_verified` e a asserção continua
# verde). Aqui a forja é exercida de ponta a ponta:
#
#   C1  identidade: o RPC (`Server.SubmitCraft`) não tem parâmetro de char/conta —
#       char e conta vêm do PEER. Peer sem sessão não forja nada; a linha gravada é da
#       conta da sessão, não de quem escreveu o pacote;
#   C2  insumo: a forja cobra DOIS preços — ouro (`SubmitFee`) e a matéria-prima
#       declarada da faixa do tier (`CraftCatalog.MaterialPerCraft`). Sem material o
#       `pending` não nasce (motivo `no_stock`, e o ouro fica no char), o lote
#       consumido é o BOUND que o drop produz, e a grandeza é régua de tempo de
#       fazenda: recomputamos a taxa de material/h das três constantes de
#       `FarmZoneData` e exigimos que um craft de tier 1 custe entre 1 e 3 horas.
#       Até 2026-09-27 esta suíte asserava o contrário ("zero material e a forja
#       aceita"), que é como o repo registrou que o segundo eixo não existia;
#   C3  porta de e-mail e teto diário (`CraftCatalog.MAX_PER_DAY`) decididos no
#       servidor, com o ouro intacto na recusa;
#   C4  `pending` não é item: submeter não cria `craft_item_template` nem entrega
#       nada; o próprio criador sem permissão é barrado DENTRO do serviço;
#   C5  só depois do OK de um GM o template nasce, a cópia vinculada vai ao criador e
#       `decided_by` fica registrado — o único ponto em que a forja toca o mundo.
#
# Uso: godot --headless --path . -s tests/craft_authority_test.gd
# Régua: última linha `== RESULT: N checks, 0 failures ==`; exit code = falhas.
#
# Como todo harness `-s`: compila antes dos autoloads existirem -> tudo por load() +
# call()/get()/set(), sem identificadores tipados do projeto.

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _sql : Node = null
var _network : Node = null
var _world : Node = null
var _eco : Object = null
var _netServer : Object = null
var _dbScript : GDScript = null
var _craft : GDScript = null
var _farm : GDScript = null
var _actorCommons : GDScript = null
var _skillCommons : GDScript = null
var _networkCommons : GDScript = null
var _peers : GDScript = null
var _playerAgentScript : GDScript = null

var _accountID : int = 0
var _charID : int = 0
var _peerID : int = 840001
var _slot : int = 0
var _baseHash : int = 0
var _baseTier : int = 0
var _maxPerDay : int = 0

func _initialize():
	_run()

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

func _enumValue(script : GDScript, enumName : String, key : String) -> int:
	if script == null:
		return -1
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

# Constante lida pelo NOME do script (não copiada para cá): as taxas de oferta que
# a régua de tempo de fazenda recompra vêm da tabela viva em `FarmZoneData`, então
# mexer numa constante de drop move a régua em vez de deixá-la mentindo.
func _const(script : GDScript, constantName : String) -> float:
	var raw : Variant = script.get_script_constant_map().get(constantName, null)
	return float(raw) if (raw is int or raw is float) else -1.0

# ------------------------------------------------------------------ boot

func _run():
	print("== Craft authority harness (peer decide conta / matéria-prima cobra hora de fazenda / GM decide saída) ==")
	_launcher = root.get_node_or_null(^"Launcher")
	if _launcher == null:
		print("FATAL: Launcher autoload missing")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.SQL
		_world = _launcher.World
		if _sql != null and _sql.isInitialized and _world != null and _world.isInitialized:
			break
	_dbScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 40:
		if _dbScript != null and _dbScript.isInitialized:
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (cells loaded)"):
		_finish()
		return
	_network = root.get_node_or_null(^"Network")
	_eco = _launcher.get("Economy")
	_craft = load("res://sources/economy/CraftCatalog.gd")
	_farm = load("res://sources/idle/FarmZoneData.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	_skillCommons = load("res://sources/skill/SkillCommons.gd")
	_networkCommons = load("res://sources/network/NetworkCommons.gd")
	_peers = load("res://sources/network/server/Peers.gd")
	_playerAgentScript = load("res://sources/actor/agent/variants/PlayerAgent.gd")
	_netServer = _network.get("ENetServer") if _network != null else null
	_maxPerDay = int(_craft.MAX_PER_DAY)
	if not _check(_eco != null and _netServer != null and _craft != null, "Economy + ENetServer + CraftCatalog vivos no boot"):
		_finish()
		return
	if not _setupFixture():
		_finish()
		return
	_suiteIdentity()
	_suiteMaterialSink()
	_suiteEmailAndCap()
	_suiteApprovalNeedsGM()
	_finish()

func _finish():
	_dropFixture()
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ fixture

func _setupFixture() -> bool:
	_sql.db.delete_rows("character", "nickname = 'CafrCharA'")
	_sql.db.delete_rows("account", "username = 'cafr_a'")
	if not _sql.AddAccount("cafr_a", "testpass", "cafr_a@test.local",
			_networkCommons.AgreementTosVersion, _networkCommons.AgreementPrivacyVersion, "203.0.113.1"):
		_check(false, "conta fixture criada")
		return false
	_accountID = _sql.GetAccountID("cafr_a")
	if not _sql.AddCharacter(_accountID, "CafrCharA", _actorCommons.DefaultStats,
			_actorCommons.DefaultTraits, _actorCommons.DefaultAttributes):
		_check(false, "personagem fixture criado")
		return false
	_charID = _sql.GetCharacterID(_accountID, "CafrCharA")
	_sql.SetSkill(_charID, _skillCommons.SkillMeleeName.hash(), 1)
	_sql.db.update_rows("stat", "char_id = %d" % _charID, {"gp" = 200000})
	# D3 exige e-mail verificado; a porta em si é aferida em C3.
	_sql.db.update_rows("account", "account_id = %d" % _accountID, {"email_verified" = 1})
	# Sessão real no Peers: é DAQUI que o handler de rede tira conta/char (C1).
	_openSession(_accountID, _charID, _peerID)
	_slot = _enumValue(_actorCommons, "Slot", "WEAPON")
	var items : Dictionary = _dbScript.ItemsDB
	for tier : int in [1, 3, 4, 5]:
		for itemHash in items.keys():
			var item : Object = items[itemHash]
			if item != null and int(item.get("slot")) == _slot and int(item.get("tier")) == tier and int(itemHash) > 0:
				_baseHash = int(itemHash)
				_baseTier = tier
				break
		if _baseHash != 0:
			break
	if not _check(_baseHash != 0 and int(_craft.BudgetCap(_baseTier, _slot)) > 0,
			"base craftável (tier %d) com budget cap na faixa (%d)" % [_baseTier, int(_craft.BudgetCap(_baseTier, _slot))]):
		return false
	if not _check(_maxPerDay >= 1, "o catálogo declara um teto diário (%d)" % _maxPerDay):
		return false
	# Pilha para as suítes que PRECISAM forjar (C1, C3, C4): C2 mede o consumo com
	# conta exata e reabastece no fim, então o resto do harness não depende de
	# quanto insumo a suíte de insumo deixou.
	if _matHash() != int(_dbScript.UnknownHash):
		_grantMaterial(_matNeed() * (_maxPerDay + 4))
	return true

func _openSession(accountID : int, charID : int, peerID : int):
	if not bool(_peers.HasPeer(peerID)):
		_peers.AddPeer(peerID, 0)
	var peer : Object = _peers.GetPeer(peerID)
	if peer == null:
		return
	peer.set("accountID", accountID)
	peer.set("characterID", charID)
	(_peers.accounts as Dictionary)[accountID] = peerID

func _agentFor(peerID : int, nick : String) -> Object:
	var entities : Dictionary = _dbScript.EntitiesDB
	var data : Object = entities.get(int(_dbScript.PlayerHash), null)
	if data == null:
		return null
	var agent : Object = _playerAgentScript.new(_enumValue(_actorCommons, "Type", "PLAYER"), data, nick, true)
	agent.set("peerID", peerID)
	return agent

func _gp() -> int:
	var rows : Array = _sql.db.select_rows("stat", "char_id = %d" % _charID, ["gp"])
	return int(rows[0]["gp"]) if not rows.is_empty() and rows[0].get("gp", null) != null else 0

# Linhas do ITEM FORJADO no inventário, não "qualquer item": desde que o craft
# cobra matéria-prima, o char da sessão tem linha de insumo por definição, e contar
# tudo faria "nada foi entregue" mentir sem nada ter mudado no produto.
func _itemRows() -> int:
	var rows : Array[Dictionary] = _sql.QueryBindings(
			"SELECT COUNT(*) AS n FROM item WHERE char_id = ? AND item_id = ?;", [_charID, _baseHash])
	return int(rows[0]["n"]) if not rows.is_empty() else 0

func _subs() -> Array[Dictionary]:
	return _sql.QueryBindings("SELECT * FROM craft_submission WHERE account_id = ? ORDER BY id;", [_accountID])

func _subRow(subName : String) -> Dictionary:
	for row in _subs():
		if str(row.get("name", "")) == subName:
			return row
	return {}

func _templates() -> int:
	var rows : Array[Dictionary] = _sql.QueryBindings("SELECT COUNT(*) AS n FROM craft_item_template WHERE creator_account_id = ?;", [_accountID])
	return int(rows[0]["n"]) if not rows.is_empty() else 0

func _fee() -> int:
	var base : int = int(_craft.SubmitFee(_baseTier))
	if _eco.has_method("GetLiveEventCraftingFeeMod"):
		return maxi(1, roundi(float(base) * float(_eco.call("GetLiveEventCraftingFeeMod"))))
	return base

func _dropFixture():
	if _sql == null or not is_instance_valid(_sql) or not _sql.isInitialized or _accountID == 0:
		return
	_sql.db.delete_rows("craft_submission", "account_id = %d" % _accountID)
	_sql.db.delete_rows("craft_item_template", "creator_account_id = %d" % _accountID)
	_sql.db.delete_rows("item", "char_id = %d" % _charID)
	# Lotes também: desde que a fixture concede matéria-prima, sobrar `item_instance`
	# de um personagem apagado é órfão que o reconcile dos outros harnesses conta.
	_sql.DeleteRowsRaw("item_instance", "char_id = %d" % _charID)
	# Ledger fica: `ledger_transaction_no_delete` recusa o DELETE (056:103) e a
	# forja grava taxa atestada, então esta linha era o erro que o gate ainda não
	# via. A perna de carteira do reconcile dá JOIN em wallet/account — apagar o
	# account aposenta a série inteira.
	_sql.db.delete_rows("character", "nickname = 'CafrCharA'")
	_sql.db.delete_rows("account", "username = 'cafr_a'")
	_accountID = 0

# ------------------------------------------------------------------ insumo
# A matéria-prima é resolvida pelo NOME canônico da faixa (`BandMaterialNames`,
# via `GetBandMaterialHash`), nunca por hash regravado aqui: é a MESMA função que o
# roll de drop usa, então "a faixa entrega" e "o craft cobra" são a mesma
# identidade por construção, e conteúdo renomeado quebra as duas pontas juntas.

func _matHash() -> int:
	return int(_farm.call("GetBandMaterialHash", _baseTier))

func _matNeed() -> int:
	return int(_craft.call("MaterialPerCraft", _baseTier))

# Saldo em LOTES com bound incluso — a unidade que o consumidor do craft usa.
func _matBalance() -> int:
	return int(_sql.GetLotBalanceRaw(_charID, _matHash(), true))

# Concede pelo caminho de produção: `AddItemToCharacter` espelha agregado + lote e
# carimba bound = 1 porque a célula é matéria-prima (regra de
# `EconomyKernel._GrantStackRaw`). Conceder unbound testaria um estado que o jogo
# não fabrica — e é exatamente o estado que os caminhos de trade recusam.
func _grantMaterial(units : int) -> void:
	if units > 0:
		_sql.AddItemToCharacter(_charID, _matHash(), units, "craft_authority_fixture")

func _dropMaterial() -> void:
	_sql.db.delete_rows("item", "item_id = %d AND char_id = %d AND storage = 0;" % [_matHash(), _charID])
	_sql.DeleteRowsRaw("item_instance", "char_id = %d AND item_id = %d AND storage = 0" % [_charID, _matHash()])

# Linhas de ledger do insumo lidas como DELTA: a suíte C1 já forjou uma vez antes
# daqui, então contar absolutos chamaria o craft anterior de bug.
func _matLedgerAmounts() -> Array[Dictionary]:
	return _sql.QueryBindings(
			"SELECT amount FROM ledger_transaction WHERE account_id = ? AND reason = ?;",
			[_accountID, "craft_material:%d" % _matHash()])

# Unidades de matéria-prima por hora de fazenda na zona 1, recompradas das três
# constantes da oferta: kills/h × drops/kill × fatia do roll que é insumo.
func _materialPerHour() -> float:
	var killsPerHour : float = 3600.0 / float(_const(_farm, "ParBaseSeconds"))
	var dropsPerKill : float = float(_const(_farm, "DefaultDropRatePPM")) / 1000000.0
	var share : float = float(_const(_farm, "MaterialDropSharePPM")) / 1000000.0
	return killsPerHour * dropsPerKill * share

# ------------------------------------------------------------------ C1 identidade

func _suiteIdentity():
	print("[suite] C1: a forja é decidida pelo PEER, nunca pelo pacote")
	var subName : String = "Zorvane Bladesong"
	var mods : Dictionary = {"PoisonPower": 1}
	# Peer sem sessão (conta/char desconhecidos) não forja — e não derruba o servidor.
	_netServer.call("SubmitCraft", _slot, _baseHash, subName, mods, 899999)
	_checkEq(_subs().size(), 0, "peer sem sessão não deixou submissão nenhuma no banco")
	_checkEq(_itemRows(), 0, "e nada foi entregue a ninguém")
	# Peer com sessão: o pacote nomeia SLOT + BASE + NOME + MODS; ninguém escreve
	# "essa submissão é da conta X" — quem decide a conta é o servidor.
	var before : int = _gp()
	var matBefore : int = _matBalance()
	_netServer.call("SubmitCraft", _slot, _baseHash, subName, mods, _peerID)
	var row : Dictionary = _subRow(subName)
	_check(not row.is_empty(), "a submissão do peer logado foi gravada")
	_checkEq(int(row.get("account_id", -1)), _accountID, "account_id da linha vem da SESSÃO do peer")
	_checkEq(int(row.get("char_id", -1)), _charID, "char_id da linha vem da SESSÃO do peer")
	_checkEq(str(row.get("status", "")), "pending", "nasce pendente (nenhum item no mundo ainda)")
	_checkEq(before - _gp(), _fee(), "o pedágio em ouro saiu (500×tier²)")
	_checkEq(matBefore - _matBalance(), _matNeed(), "e a matéria-prima da faixa saiu junto (o RPC do peer paga os dois preços)")
	var serverSrc : String = _sourceText("res://sources/network/server/Server.gd")
	_check(serverSrc.contains("func SubmitCraft(slot : int, baseItemHash : int, name : String, modifiers : Dictionary, peerID : int)"),
			"Server.SubmitCraft só recebe slot/base/nome/mods + peerID (char e conta NÃO são parâmetros)")
	_check(serverSrc.contains("Peers.GetCharacter(peerID)") and serverSrc.contains("Peers.GetAccount(peerID)"),
			"o handler resolve char/conta por Peers (fonte da identidade)")

# ------------------------------------------------------------------ C2 material

func _suiteMaterialSink():
	print("[suite] C2: o craft cobra matéria-prima da faixa — e o preço é hora de fazenda")
	var mat : int = _matHash()
	if not _check(mat != int(_dbScript.UnknownHash), "a faixa do tier %d declara uma matéria-prima" % _baseTier):
		return
	var need : int = _matNeed()
	_check(need > 0, "o catálogo cobra %d unidades por craft no tier %d" % [need, _baseTier])

	# (a) sem insumo, com ouro de sobra: a recusa tem motivo PRÓPRIO, nada é gravado,
	# nada é cobrado. Ouro e insumo são dois motivos distintos na tela, e a única
	# forma de provar isso é deixar o char rico e quebrado de material.
	_dropMaterial()
	_checkEq(_matBalance(), 0, "o char da sessão está sem NENHUMA unidade de insumo")
	var gpBefore : int = _gp()
	var subsBefore : int = _subs().size()
	var ledgerBefore : int = _matLedgerAmounts().size()
	var refused : Dictionary = _eco.SubmitCraft(_charID, _accountID, _slot, _baseHash, "Kethrik Vowsunder", {"FireDamage": 1})
	_check(not bool(refused.get("ok", false)), "sem matéria-prima a submissão é recusada")
	_checkEq(str(refused.get("reason", "")), "no_stock", "com ouro sobrando o motivo é no_stock, nunca insufficient_gold")
	_checkEq(gpBefore, _gp(), "na recusa o ouro NÃO saiu")
	_checkEq(_subs().size(), subsBefore, "e a recusa não gravou linha nenhuma")
	_checkEq(_matLedgerAmounts().size(), ledgerBefore, "nem o ledger do insumo viu a recusa")

	# (b) preço exato, pago em lote BOUND — o estado que o drop produz. Saldo zero e
	# agregado drenado: metade do invariante que o `ReconcileDaily` confere.
	_grantMaterial(need)
	_checkEq(_matBalance(), need, "a pilha concedida é exatamente um preço de craft")
	ledgerBefore = _matLedgerAmounts().size()
	var accepted : Dictionary = _eco.SubmitCraft(_charID, _accountID, _slot, _baseHash, "Kethrik Vowsunder", {"FireDamage": 1})
	_check(bool(accepted.get("ok", false)), "com o insumo exato a mesma submissão passa (motivo: %s)" % str(accepted.get("reason", "")))
	_checkEq(_matBalance(), 0, "as %d unidades saíram — nem uma sobrou para esconder consumo parcial" % need)
	_checkEq(_sql.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [mat, _charID], ["count"]).size(),
			0, "o agregado do insumo desceu junto (nenhum item fantasma na tela)")
	var matLedger : Array[Dictionary] = _matLedgerAmounts()
	_checkEq(matLedger.size() - ledgerBefore, 1, "cada craft escreve UMA linha de ledger para o insumo, razoada com o hash do item")
	var wrongAmounts : int = 0
	for entry in matLedger:
		if int(entry["amount"]) != -need:
			wrongAmounts += 1
	_checkEq(wrongAmounts, 0, "todo lançamento de insumo é DÉBITO exato do preço (%d unidades; sink, nunca crédito)" % need)

	# (c) grandeza: o preço é TEMPO DE FAZENDA, recomprado das três constantes de
	# oferta (`ParBaseSeconds`, `DefaultDropRatePPM`, `MaterialDropSharePPM`). A
	# banda 1..3 h é a decisão: abaixo de 1 h o insumo é burocracia, acima de 3 h
	# "farmar para forjar" deixa de caber num dia de jogo.
	var perHour : float = _materialPerHour()
	_check(perHour > 0.0, "a taxa de insumo/h sai das constantes (%.2f/h)" % perHour)
	var hours : float = float(need) / perHour
	_check(hours >= 1.0 and hours <= 3.0, "um craft de tier %d custa %.1f h de fazenda — banda 1..3 h" % [_baseTier, hours])

	# (d) dar um segundo preço ao craft não o transformou em fonte de ouro.
	var ledgers : Array[Dictionary] = _sql.QueryBindings(
			"SELECT amount FROM ledger_transaction WHERE account_id = ? AND reason LIKE ?;",
			[_accountID, "craft_submit_fee:tier%"])
	_check(ledgers.size() >= 2, "cada forja deixa rastro de sink de ouro no ledger (%d linhas)" % ledgers.size())
	var positive : int = 0
	for entry in ledgers:
		if int(entry["amount"]) >= 0:
			positive += 1
	_checkEq(positive, 0, "todo lançamento de forja é DÉBITO de ouro (sink, nunca crédito)")
	var row : Dictionary = _subRow("Kethrik Vowsunder")
	_check(int(row.get("budget_used", -1)) >= 0, "o budget do design continua sendo do design, não do insumo (%s)" % str(row.get("budget_used", "?")))
	_grantMaterial(need * (_maxPerDay + 2))

# ------------------------------------------------------------------ C3 e-mail + teto

func _suiteEmailAndCap():
	print("[suite] C3: porta de e-mail e teto diário são do servidor")
	_sql.db.update_rows("account", "account_id = %d" % _accountID, {"email_verified" = 0})
	var gpBefore : int = _gp()
	var blocked : Dictionary = _eco.SubmitCraft(_charID, _accountID, _slot, _baseHash, "Nymra Oathbrand", {"PoisonPower": 1})
	_check(not bool(blocked.get("ok", false)), "e-mail não verificado barra a forja")
	_checkEq(str(blocked.get("reason", "")), "email_not_verified", "motivo explícito: email_not_verified")
	_checkEq(gpBefore, _gp(), "na recusa o ouro NÃO saiu (nada de cobrar antes de decidir)")
	_checkEq(_subRow("Nymra Oathbrand"), {}, "a recusa nem chegou a gravar linha")
	_sql.db.update_rows("account", "account_id = %d" % _accountID, {"email_verified" = 1})
	var already : int = _subs().size()
	var accepted : int = 0
	for i in _maxPerDay + 1:
		var res : Dictionary = _eco.SubmitCraft(_charID, _accountID, _slot, _baseHash, "Quorlin Vastforge %d" % i, {"PoisonPower": 1})
		if bool(res.get("ok", false)):
			accepted += 1
	_checkEq(accepted, maxi(0, _maxPerDay - already), "aceita exatamente até o teto diário (%d) e nem um além dele" % _maxPerDay)
	_checkEq(_subs().size(), mini(_maxPerDay, already + accepted), "o banco tem exatamente MAX_PER_DAY submissões no dia")
	var overflow : Dictionary = _eco.SubmitCraft(_charID, _accountID, _slot, _baseHash, "Quorlin Vastforge overflow", {"PoisonPower": 1})
	_check(not bool(overflow.get("ok", false)), "a submissão além do teto diário é recusada")
	_checkEq(str(overflow.get("reason", "")), "daily_cap_reached", "motivo explícito: daily_cap_reached")

# ------------------------------------------------------------------ C4/C5 aprovação

func _suiteApprovalNeedsGM():
	print("[suite] C4/C5: só um GM põe o item no mundo; sem GM nada nasce")
	var pending : Dictionary = {}
	for row in _subs():
		if str(row.get("status", "")) == "pending":
			pending = row
			break
	if not _check(not pending.is_empty(), "há submissão pendente para a suíte de aprovação"):
		return
	var submissionID : int = int(pending["id"])
	var subName : String = str(pending["name"])
	_checkEq(_templates(), 0, "submeter sozinho NÃO cria template nem entrega item")
	_checkEq(_itemRows(), 0, "e o criador está com o inventário vazio até aqui")
	_check(not bool(_eco.ApproveCraftSubmission(null, submissionID)), "approver nulo é recusado")
	var nobody : Object = _agentFor(899998, "CafrNobody")
	if nobody != null:
		_check(not bool(_eco.ApproveCraftSubmission(nobody, submissionID)), "peer sem conta na sessão não aprova forja")
	var owner : Object = _agentFor(_peerID, "CafrCharA")
	if not _check(owner != null, "agente da própria sessão instanciável"):
		return
	_check(not bool(_eco.ApproveCraftSubmission(owner, submissionID)),
			"o próprio criador, sem permissão GM, NÃO aprova a própria submissão")
	_checkEq(_templates(), 0, "nenhuma tentativa sem permissão criou template")
	_checkEq(str(_subRow(subName).get("status", "")), "pending", "o status segue pending depois de recusa sem permissão")
	# Mesma sessão, MESMO agente: só a PERMISSÃO muda — é ela que decide, não o chamador.
	var peer : Object = _peers.GetPeer(_peerID)
	if peer == null:
		_check(false, "sessão do par para virar GM")
		return
	peer.set("permission", _enumValue(_actorCommons, "Permission", "GM"))
	_check(bool(_eco.ApproveCraftSubmission(owner, submissionID)), "com permissão GM a mesma sessão aprova")
	_checkEq(_templates(), 1, "o template entra no catálogo de drop só depois do OK do GM")
	var decided : Dictionary = _subRow(subName)
	_checkEq(str(decided.get("status", "")), "approved", "status vira approved")
	_checkEq(int(decided.get("decided_by", 0)), _accountID, "decided_by grava a conta que decidiu (lida do peer, não do pacote)")
	_checkEq(_itemRows(), 1, "a cópia vinculada do criador aparece no inventário")
	_check(int(_craft.CREATOR_FEE_PCT) >= 0 and int(_craft.CREATOR_FEE_PCT) <= 100,
			"a taxa do criador (%d%%) é número de catálogo, aplicada pelo leilão ao vender" % int(_craft.CREATOR_FEE_PCT))
