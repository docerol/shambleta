extends SceneTree

# SOM-IDLE: harness autônomo dos fixes de economy-design (AUDITORIA_2026-09-27).
# Cobre, nas FUNÇÕES REAIS (sem mock):
#   P1-3  gold offline do newbie obedece a regra do gold online (sem o ×5 que
#         só existe no XP) — OfflineSettle.BuildReport;
#   P1-4  CraftCatalog.MOD_WEIGHTS completa contra o enum Modifier + validação
#         fail-closed do boot (CraftCatalog.ValidateModWeights) + rolo
#         extremo {"FireDamage": 99999} rejeitado pelo clamp de budget
#         (EconomyService.SubmitCraft);
#   P1-9  `beaten` não regrediu no rush (SettleBossResult com maxi);
#   P1-10 PurchaseVIP e reroll pago fechados em transação única (sem estado
#         meio-aplicado quando o pagamento é rejeitado);
#   cap   banda de teto do offline (F2P < VIP, com o número lido da constante
#         declarada — o valor do F2P é regra do dono, não do harness); e
#   passe auto-claim de encerramento idempotente (estado persiste o pago).
#
# Mesmo contrato do run_idle_tests.gd: o script `-s` compila ANTES dos autoloads
# existirem — nada de class_name ou de Launcher/DB/SQL em tempo de parse; as
# classes do projeto entram por load() depois do boot. Exit code = nº de falhas;
# a régua do gate é a última linha: `== RESULT: N checks, 0 failures ==`.

var checks : int = 0
var failures : int = 0

func _initialize():
	_run()

func _autoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

# ------------------------------------------------------------------ contagem

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

func _checkNear(value : float, expected : float, tolerance : float, label : String) -> bool:
	checks += 1
	if absf(value - expected) > tolerance:
		failures += 1
		print("  [FAIL] %s: %f vs %f (±%f)" % [label, value, expected, tolerance])
		return false
	return true

# ------------------------------------------------------------------ boot

var _launcher : Node = null
var _sql : Node = null
var _economy : Node = null
var _offline : GDScript = null
var _catalog : GDScript = null
var _cellCommons : GDScript = null
var _farmZone : GDScript = null
var _rebirth : GDScript = null
var _dbScript : GDScript = null
var _craft : GDScript = null
var _sqlCommons : GDScript = null
var _actorCommons : GDScript = null
var _skillCommons : GDScript = null
var _networkCommons : GDScript = null
var _idlePolicyService : GDScript = null
var _worldAgent : GDScript = null

func _run():
	print("== economy-design fix harness (P1-3/P1-4/P1-9/P1-10 + cap) ==")
	_launcher = _autoload("Launcher")
	if _launcher == null:
		print("FATAL: Launcher autoload missing")
		_finish()
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		_sql = _launcher.SQL
		_economy = _launcher.Economy
		if _sql != null and _sql.isInitialized and _launcher.World != null and _launcher.World.isInitialized:
			break
	print("== boot wait done (waited %d ms) ==" % waited)
	_offline = load("res://sources/idle/OfflineSettle.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	_cellCommons = load("res://sources/cell/CellCommons.gd")
	_farmZone = load("res://sources/idle/FarmZoneData.gd")
	_rebirth = load("res://sources/idle/RebirthData.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	_skillCommons = load("res://sources/skill/SkillCommons.gd")
	_networkCommons = load("res://sources/network/NetworkCommons.gd")
	_idlePolicyService = load("res://sources/idle/IdlePolicyService.gd")
	_worldAgent = load("res://sources/world/WorldAgent.gd")
	_dbScript = load("res://sources/db/DB.gd")
	# `CraftCatalog` tem `CellCommons` na dependência e `CellCommons.IsEquipped` fala com o
	# autoload `Launcher`: citar o global por nome aqui é referência em tempo de parse
	# (a regra deste arquivo é load() depois do boot), e o harness nem compilava.
	_craft = load("res://sources/economy/CraftCatalog.gd")
	_sqlCommons = load("res://sources/sql/SQLCommons.gd")
	var dbReady : bool = false
	for i in 40:
		if _dbScript.isInitialized:
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (items/maps loaded)"):
		_finish()
		return

	_suiteCapBand()
	_suitePassAutoClaim()
	_suiteNewbieGold()
	_suiteCraftWeights()
	await _suiteCraftBudget()
	await _suiteBeatenNoRegression()
	_suiteVIPSingleTx()
	_suiteRerollSingleTx()

	_finish()

func _finish():
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ fixture

# Cópia mínima do CreateFixture do IdleTests (leitura permitida, cópia própria):
# conta com aceite vigente + personagem level 1 + skills + gold. Nomes próprios,
# limpos no fim — nada de estado compartilhado com as outras suítes.
func _createFixture(accountName : String, nickname : String, gp : int = 50000) -> int:
	_sql.db.delete_rows("character", "nickname = '%s';" % nickname)
	_sql.db.delete_rows("account", "username = '%s';" % accountName)
	if not _sql.AddAccount(accountName, "testpass", accountName + "@test.local", _networkCommons.AgreementTosVersion, _networkCommons.AgreementPrivacyVersion, "203.0.113.1"):
		return 0
	var accountID : int = _sql.GetAccountID(accountName)
	if accountID < 0:
		return 0
	_sql.db.delete_rows("ad_slot", "account_id = %d;" % accountID)
	if not _sql.AddCharacter(accountID, nickname, _actorCommons.DefaultStats, _actorCommons.DefaultTraits, _actorCommons.DefaultAttributes):
		return 0
	var charID : int = _sql.GetCharacterID(accountID, nickname)
	if charID < 0:
		return 0
	_sql.SetSkill(charID, _skillCommons.SkillMeleeName.hash(), 1)
	_sql.SetSkill(charID, _skillCommons.SkillRunName.hash(), 1)
	_sql.db.update_rows("stat", "char_id = %d" % charID, {"gp" = gp})
	return charID

func _dropFixture(accountName : String, nickname : String):
	_sql.db.delete_rows("character", "nickname = '%s'" % nickname)
	_sql.db.delete_rows("account", "username = '%s'" % accountName)

func _ledgerCount(accountID : int, reason : String) -> int:
	var rows : Array = _sql.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason = ?;", [accountID, reason])
	return 0 if rows.is_empty() else int(rows[0]["n"])

# ------------------------------------------------------------------ suite: cap banda (retenção)

func _suiteCapBand():
	print("[suite] offline cap band: banda F2P < VIP, com o teto lido da constante declarada")
	# A régua é a RELação, não o número. `BaseCapHours` é decisão do dono (1h,
	# registrado em OfflineSettle.gd:14-17: o dia de acúmulo é o que se vende como
	# VIP e o F2P compra hora com anúncio); a auditoria pediu 8h e o dono manteve
	# 1h. Um harness que hardcodeia 800 legisla contra o dono — e já legislou.
	var baseCs : int = int(_offline.BaseCapHours * 100.0)
	_check(baseCs > 0, "há teto base declarado (%d cs)" % baseCs)
	_check(_offline.CapHoursVIP1 > _offline.BaseCapHours, "VIP1 sobe o teto acima do base (%.2fh > %.2fh)" % [_offline.CapHoursVIP1, _offline.BaseCapHours])
	_check(_offline.CapHoursVIP2 > _offline.BaseCapHours, "VIP2 sobe o teto acima do base (%.2fh > %.2fh)" % [_offline.CapHoursVIP2, _offline.BaseCapHours])
	_checkEq(int(_offline.CapHoursForAccount(0) * 100.0), baseCs, "sem conta → teto base")
	# OfflineFactor é o número do TECH_SPEC_CORE §3, não escolha de banda: se ele
	# mudar junto com um teto, o dano é de economia inteira e o gate tem que gritar.
	_checkEq(int(_offline.OfflineFactor * 100.0), 60, "OfflineFactor 0.6 intocado (só o teto mudou)")
	var charID : int = _createFixture("edfx_cap_account", "EdfxCapChar")
	if not _check(charID != 0, "cap fixture created"):
		return
	var accountID : int = _sql.GetAccountIDForCharacter(charID)
	var now : int = _sqlCommons.Timestamp()
	_checkEq(int(_offline.CapHoursForAccount(accountID, now) * 100.0), baseCs, "F2P → teto base")
	# sem view de anúncio, o teto do personagem é o da conta
	_checkEq(int(_offline.CapHoursForCharacter(charID, accountID, now - 30 * 3600, now) * 100.0), baseCs, "F2P sem anúncio → teto base liquidável")
	_sql.SetVIPUntil(accountID, now + 30 * 86400)
	_sql.SetVIPTier(accountID, 1)
	_checkEq(int(_offline.CapHoursForAccount(accountID, now) * 100.0), int(_offline.CapHoursVIP1 * 100.0), "VIP1 → o teto declarado da faixa 1")
	_sql.SetVIPTier(accountID, 2)
	_checkEq(int(_offline.CapHoursForAccount(accountID, now) * 100.0), int(_offline.CapHoursVIP2 * 100.0), "VIP2 → o teto declarado da faixa 2")
	_sql.SetVIPUntil(accountID, now - 10)
	_checkEq(int(_offline.CapHoursForAccount(accountID, now) * 100.0), baseCs, "VIP expirado → volta ao teto base")
	_dropFixture("edfx_cap_account", "EdfxCapChar")

# ------------------------------------------------------------------ suite: auto-claim do passe

# O auto-claim de encerramento é o único caminho do passe que escreve
# `claimed_free` sem o jogador pedir nada. Medido em 2026-09-27: ele DAVA o reward
# e não persistia o claim — a flag `changedF` era um local escrito dentro do lambda
# de `Transaction(func() …)`, e GDScript copia local por valor; o `UPDATE` era
# sempre pulado e a passada seguinte revendia a trilha inteira. A régua é a relação
# que fecha o dupe: depois de liquidar, o ESTADO diz o que foi pago, e liquidar de
# novo não paga nada.
func _suitePassAutoClaim():
	print("[suite] auto-claim do passe: paga uma vez e o estado prova o que pagou")
	var charID : int = _createFixture("edfx_pass_account", "EdfxPassChar")
	if not _check(charID != 0, "pass fixture created"):
		return
	if not _check(_economy.get("passService") != null, "PassService montado no boot (`_post_launch` rodou)"):
		_dropFixture("edfx_pass_account", "EdfxPassChar")
		return
	var accountID : int = _sql.GetAccountIDForCharacter(charID)
	var now : int = _sqlCommons.Timestamp()
	var starts : int = now - 30 * 86400
	var ends : int = now - 20 * 86400
	_sql.ExecuteBindings("INSERT INTO season (starts_at, ends_at, rules_frozen, status) VALUES (?, ?, '{}', 'closed');", [starts, ends])
	var seasonRows : Array = _sql.QueryBindings("SELECT season_id FROM season WHERE starts_at = ? AND ends_at = ? AND status = 'closed';", [starts, ends])
	if not _check(not seasonRows.is_empty(), "temporada liquidada fixture criada"):
		_dropFixture("edfx_pass_account", "EdfxPassChar")
		return
	var seasonID : int = int(seasonRows[0]["season_id"])
	# O nível provado vem da trilha do catálogo, e o valor também: nada de "10 gems"
	# escrito aqui — se o catálogo mudar de reward, a suíte muda junto.
	var freeTrack : Dictionary = _catalog.get("PASS_FREE")
	var thresholds : Array = _catalog.PassThresholds()
	var paidLevel : int = 0
	var paidGems : int = 0
	for lvl in range(1, mini(3, thresholds.size()) + 1):
		if freeTrack.has(lvl) and int((freeTrack[lvl] as Dictionary).get("gems", 0)) > 0:
			paidLevel = lvl
			paidGems = int((freeTrack[lvl] as Dictionary).get("gems", 0))
			break
	if not _check(paidLevel > 0, "a trilha grátis paga gems em nível alcançável (senão a suíte não tem o que provar)"):
		_dropFixture("edfx_pass_account", "EdfxPassChar")
		return
	_sql.ExecuteBindings("INSERT INTO season_account_state (account_id, season_id, pt, premium, claimed_free, claimed_premium) VALUES (?, ?, ?, 0, '[]', '[]');", [accountID, seasonID, int(thresholds[paidLevel - 1])])
	var reason : String = "pass_reward:free:%d" % paidLevel
	var gemsBefore : int = int(_sql.GetGemsRaw(accountID))
	var first : Dictionary = _economy._AutoClaimPass(seasonID)
	_checkEq(int(first.get("claimed", -1)), 1, "primeira passada liquida a trilha da conta")
	_checkEq(int(_sql.GetGemsRaw(accountID)) - gemsBefore, paidGems, "creditado = o valor do catálogo para o nível %d (+%d gems)" % [paidLevel, paidGems])
	_checkEq(_ledgerCount(accountID, reason), 1, "ledger registra o reward uma vez")
	var stateRows : Array = _sql.QueryBindings("SELECT claimed_free, claimed_premium FROM season_account_state WHERE account_id = ? AND season_id = ?;", [accountID, seasonID])
	var claimedFree : String = str(stateRows[0].get("claimed_free", "")) if not stateRows.is_empty() else "<sem linha>"
	_check(claimedFree.contains(str(paidLevel)), "o ESTADO persiste o que foi pago (claimed_free = %s) — sem isto a passada seguinte revende a trilha" % claimedFree)
	_check(str(stateRows[0].get("claimed_premium", "")) == "[]", "trilha premium intocada para quem não comprou")
	var gemsMid : int = int(_sql.GetGemsRaw(accountID))
	var second : Dictionary = _economy._AutoClaimPass(seasonID)
	_checkEq(int(second.get("claimed", -1)), 0, "segunda passada não liquida nada")
	_checkEq(int(_sql.GetGemsRaw(accountID)), gemsMid, "segunda passada não credita gem (era exatamente o dupe)")
	_checkEq(_ledgerCount(accountID, reason), 1, "segunda passada não duplica ledger")
	_sql.db.delete_rows("season_account_state", "season_id = %d;" % seasonID)
	_sql.db.delete_rows("season", "season_id = %d;" % seasonID)
	# Nada de apagar ledger: a linha do `pass_reward` é o que a régua de cima
	# acabou de contar, e `ledger_transaction_no_delete` (056:103) recusa o DELETE.
	# Quem aposenta a série é o `_dropFixture` abaixo, porque as pernas do reconcile
	# dão JOIN em account/wallet.
	_sql.db.delete_rows("cosmetic_grant", "account_id = %d;" % accountID)
	_dropFixture("edfx_pass_account", "EdfxPassChar")

# ------------------------------------------------------------------ suite: P1-3 newbie gold

# O jogador novo (level < 10) ganha ×5 no XP, online e offline; no gold, nem
# online nem offline. BuildReport é a função real do settle.
func _suiteNewbieGold():
	print("[suite] P1-3: offline newbie gold == fórmula sem o x5 (simetria com o online)")
	var charID : int = _createFixture("edfx_newbie_account", "EdfxNewbieChar")
	if not _check(charID != 0, "newbie fixture created"):
		return
	var accountID : int = _sql.GetAccountIDForCharacter(charID)
	var level : int = int(_sql.GetCharacter(charID).get("level", 1))
	_check(level < _farmZone.NewbieBoostMaxLevel, "fixture é newbie (level %d < %d)" % [level, _farmZone.NewbieBoostMaxLevel])
	_sql.SetCharacterFarmZone(charID, 1)
	var now : int = _sqlCommons.Timestamp()
	_sql.UpdateSettleAnchor(charID, now - 30 * 3600, 1.0)
	_offline.nowOverride = now
	var report = _offline.BuildReport(charID, now)
	_offline.nowOverride = 0
	if not _check(report != null, "BuildReport produced a report"):
		return
	# a janela bate no teto novo de 8h (Fix 5 provado dentro do caminho do fix 1)
	_checkEq(int(report.hours * 100.0), int(_offline.BaseCapHours * 100.0), "hours = o teto F2P declarado (a janela de 30h bate no cap)")
	var zone = _farmZone.GetZone(1)
	var rebInfo : Dictionary = _sql.GetRebirthInfo(charID)
	var rebXp : float = _rebirth.XpMult(int(rebInfo.get("favor_xp", 0)))
	var rebGold : float = _rebirth.GoldMult(int(rebInfo.get("favor_gold", 0)))
	var offFactor : float = _rebirth.OfflineFactorWithBonus(_offline.OfflineFactor, int(rebInfo.get("attune_offline", 0)))
	var mods : float = _offline.GetModsForAccount(accountID, now)
	mods *= float(load("res://sources/actor/stat/Formula.gd").TormentRewardMult(_sql.GetTormentLevel(charID)))
	var adMult : int = _offline._LootMult(accountID, now)
	var h : float = report.hours
	var eff : float = report.efficiency
	# gold: MESMA fórmula do settle sem o newbieMult — é a regra do online
	# (Formula.ApplyXp dá ×5 só em zoneXp; zoneGold nunca recebeu o boost).
	var expectedGold : int = roundi(float(zone.goldPerKill) * float(zone.parKillsPerHour) * h * eff * offFactor * mods * rebGold * float(adMult))
	_checkEq(report.goldEarned, expectedGold, "gold offline do newbie == fórmula sem o x5")
	var expectedGoldWithBoost : int = roundi(float(expectedGold) * float(_farmZone.NewbieBoostFactor))
	_check(report.goldEarned != expectedGoldWithBoost, "gold NÃO carrega o x5 (a inversão P1-3 acabou)")
	var expectedXp : int = roundi(float(zone.xpPerKill) * float(zone.parKillsPerHour) * h * eff * offFactor * mods * rebXp * float(adMult) * float(_farmZone.NewbieBoostFactor))
	_checkEq(report.xpEarned, expectedXp, "XP offline do newbie mantém o tuning x5")
	_dropFixture("edfx_newbie_account", "EdfxNewbieChar")

# ------------------------------------------------------------------ suite: P1-4 pesos

func _suiteCraftWeights():
	print("[suite] P1-4: CraftCatalog.MOD_WEIGHTS cobre o enum Modifier inteiro, pesos > 0")
	var modifierEnum : Dictionary = _cellCommons.Modifier
	var count : int = int(modifierEnum["Count"])
	var table : Array = _craft.MOD_WEIGHTS
	_checkEq(table.size(), count, "tabela tem exatamente Count entradas")
	var zeroIndexes : Array[int] = []
	for i in range(1, count):
		if i >= table.size() or float(table[i]) <= 0.0:
			zeroIndexes.append(i)
	_checkEq(zeroIndexes.size(), 0, "todo Modifier 1..Count-1 tem peso > 0 (faltam: %s)" % [str(zeroIndexes)])
	# varredura nominal: cada nome do enum (fora None/Count) resolve a um peso > 0
	var missingNames : Array[String] = []
	for key in modifierEnum.keys():
		var name : String = str(key)
		if name == "None" or name == "Count":
			continue
		var idx : int = int(modifierEnum[key])
		if idx >= table.size() or float(table[idx]) <= 0.0:
			missingNames.append(name)
	_checkEq(missingNames.size(), 0, "nomes elementais/DoT/pen/trailing com peso (faltam: %s)" % [str(missingNames)])
	# a validação fail-closed do boot passa no catálogo corrente…
	_checkEq(_craft.ValidateModWeights().size(), 0, "ValidateModWeights() limpa no boot")
	# …e pega a regressão quando a tabela encolhe (mesmo código do boot, tabela truncada)
	var truncated : Array[float] = [0.0, 1.0]
	_check(_craft.ValidateModWeights(truncated).size() > 0, "validação reprova tabela truncada (fail-closed)")
	var zeroed : Array[float] = table.duplicate()
	if zeroed.size() > 24:
		zeroed[24] = 0.0
		_check(_craft.ValidateModWeights(zeroed).size() > 0, "validação reprova peso zero no meio da tabela")

# ------------------------------------------------------------------ suite: P1-4 budget clamp

func _findCraftBase(slot : int) -> Array:
	# base item real: slot + tier com budget cap > 0 (tier 1 antes de tier 5)
	for tier in [1, 3, 4, 5]:
		for itemHash in _dbScript.ItemsDB:
			var item = _dbScript.ItemsDB[itemHash]
			if item != null and item.slot == slot and item.tier == tier and int(itemHash) > 0:
				return [int(itemHash), tier]
	return []

func _suiteCraftBudget():
	print("[suite] P1-4: rolo extremo rejeitado pelo clamp de budget (função real)")
	var charID : int = _createFixture("edfx_craft_account", "EdfxCraftChar")
	if not _check(charID != 0, "craft fixture created"):
		return
	var accountID : int = _sql.GetAccountIDForCharacter(charID)
	var slot : int = int(_actorCommons.Slot.WEAPON)
	var base : Array = _findCraftBase(slot)
	if not _check(not base.is_empty(), "base weapon craftável encontrada no ItemsDB"):
		return
	var baseHash : int = int(base[0])
	var res = _economy.SubmitCraft(charID, accountID, slot, baseHash, "EcoFix FireGreat", {"FireDamage": 99999})
	_check(not bool(res.get("ok", false)), "FireDamage 99999 rejeitado")
	_check(str(res.get("reason", "")) == "budget_exceeded", "motivo budget_exceeded (clamp de forged mods em FireDamage 99999)")
	var res2 = _economy.SubmitCraft(charID, accountID, slot, baseHash, "EcoFix MightGreat", {"Attack": 99999})
	_check(not bool(res2.get("ok", false)) and str(res2.get("reason", "")) == "budget_exceeded", "Attack 99999 continua rejeitado (guarda antiga intacta)")
	var res3 = _economy.SubmitCraft(charID, accountID, slot, baseHash, "EcoFix Bogus", {"NotAModifier": 5})
	_check(not bool(res3.get("ok", false)) and str(res3.get("reason", "")) == "invalid_modifier", "modificador inexistente rejeitado")
	# peso > 0 de verdade: DeadlyChance 40 × 1.0 estoura qualquer cap (era peso 0 → livre)
	var res4 = _economy.SubmitCraft(charID, accountID, slot, baseHash, "EcoFix DeathFang", {"DeadlyChance": 40})
	_check(not bool(res4.get("ok", false)) and str(res4.get("reason", "")) == "budget_exceeded", "DeadlyChance 40 agora conta no budget")
	# dentro do cap o budget deixa passar (cai no gate de email, não no de budget)
	var res5 = _economy.SubmitCraft(charID, accountID, slot, baseHash, "EcoFix VenomBlade", {"PoisonPower": 40})
	_check(str(res5.get("reason", "")) != "budget_exceeded" and str(res5.get("reason", "")) != "invalid_modifier", "rolo no cap passa do budget (power 0.5 × 40 = 20)")
	_dropFixture("edfx_craft_account", "EdfxCraftChar")

# ------------------------------------------------------------------ suite: P1-9 beaten

# Agente vivo do mesmo jeito do _SpawnSimAgent do IdleTests (cópia própria e
# mínima): SettleBossResult exige PlayerAgent válido.
func _spawnLiveAgent(charID : int, runTag : int):
	var zone = _farmZone.GetZone(1)
	if zone == null or zone.mapID == _dbScript.UnknownHash:
		_check(false, "sim %d: zone 1 tem mapa" % runTag)
		return null
	var map = _launcher.World.GetMap(zone.mapID)
	if map == null:
		_check(false, "sim %d: mapa da zona 1 instanciado" % runTag)
		return null
	var instID : int = _idlePolicyService.GetFarmInstanceID(1)
	var stale = map.instances.get(instID, null)
	if stale:
		stale.Destroy()
		map.instances.erase(instID)
	map.CreateInstance(instID)
	var warm : bool = false
	for i in 200:
		var candidate = _idlePolicyService.GetFarmInstance(1)
		if candidate != null and candidate.is_node_ready() and NavigationServer2D.map_get_iteration_id(map.mapRID) > 0:
			warm = true
			break
		await process_frame
	if not _check(warm, "sim %d: farm instance warm" % runTag):
		return null
	var spawnPoint = load("res://addons/tiled_importer/SpawnObject.gd").new()
	spawnPoint.map = map
	spawnPoint.type = _actorCommons.Type.PLAYER
	spawnPoint.id = _dbScript.PlayerHash
	spawnPoint.is_global = false
	var anchor = null
	for spawn in map.spawns:
		if spawn and spawn.type == _actorCommons.Type.MONSTER:
			anchor = spawn
			break
	spawnPoint.spawn_position = anchor.spawn_position if anchor != null else Vector2i.ZERO
	var agent = _worldAgent.CreateAgent(spawnPoint, instID, "EdfxBossTester")
	if not _check(agent != null, "sim %d: PlayerAgent spawnado" % runTag):
		return null
	agent.SetCharacterInfo(_sql.GetCharacterInfo(charID), charID)
	return agent

func _suiteBeatenNoRegression():
	print("[suite] P1-9: beaten nunca regride (maxi no lugar de escrita absoluta)")
	var charID : int = _createFixture("edfx_beaten_account", "EdfxBeatenChar")
	if not _check(charID != 0, "beaten fixture created"):
		return
	var agent = await _spawnLiveAgent(charID, 1)
	if agent == null:
		_dropFixture("edfx_beaten_account", "EdfxBeatenChar")
		return
	var bossCount : int = load("res://sources/idle/BossService.gd").GetBossCount()
	_sql.SetCharacterFarmZone(charID, 1)
	# estado de quem já zerou a escada: beaten = 4
	_check(_sql.SetCharacterBossesBeaten(charID, bossCount), "beaten=4 semeado (escada zerada)")
	# vitória de rush em índice baixo: ANTES disso escrevia index+1 e regresava
	var res = _economy.SettleBossResult(charID, agent, 1, true)
	_check(bool(res.get("ok", false)), "settle boss result (vitória no índice 1) aceito")
	_checkEq(_sql.GetCharacterBossesBeaten(charID), bossCount, "beaten=4 NÃO regride para 2 (P1-9)")
	# derrota também não mexe
	var res2 = _economy.SettleBossResult(charID, agent, 0, false)
	_check(bool(res2.get("ok", false)), "settle derrota aceito")
	_checkEq(_sql.GetCharacterBossesBeaten(charID), bossCount, "derrota não mexe no beaten")
	# caminho direto (ChallengeBoss usa index == beaten): progresso continua subindo
	_check(_sql.SetCharacterBossesBeaten(charID, 1), "beaten=1 semeado")
	var res3 = _economy.SettleBossResult(charID, agent, 1, true)
	_check(bool(res3.get("ok", false)), "settle vitória no índice 1 aceito (state 1)")
	_checkEq(_sql.GetCharacterBossesBeaten(charID), 2, "beaten avança 1 → 2 (maxi não trava o progresso)")
	# torment guard continua: zerar a escada libera T1
	_check(_sql.SetCharacterBossesBeaten(charID, bossCount - 1), "beaten=%d semeado (último)" % (bossCount - 1))
	var res4 = _economy.SettleBossResult(charID, agent, bossCount - 1, true)
	_check(bool(res4.get("ok", false)), "settle do último boss aceito")
	_checkEq(_sql.GetCharacterBossesBeaten(charID), bossCount, "beaten fecha a escada")
	_check(_sql.GetTormentMax(charID) >= 1, "guarda de tormento: zerar a escada libera T1")
	_worldAgent.RemoveAgent(agent)
	_dropFixture("edfx_beaten_account", "EdfxBeatenChar")

# ------------------------------------------------------------------ suite: P1-10 VIP txn única

func _suiteVIPSingleTx():
	print("[suite] P1-10: PurchaseVIP — débito + ledger + janela + tier num só commit")
	var charID : int = _createFixture("edfx_vip_account", "EdfxVipChar")
	if not _check(charID != 0, "vip fixture created"):
		return
	var accountID : int = _sql.GetAccountIDForCharacter(charID)
	_check(_economy.AddGems(accountID, 5000, "edfx_seed"), "gems semeadas (5000)")
	var cost : int = int(_catalog.VIP1CostGems)
	var now : int = _sqlCommons.Timestamp()
	_check(_economy.PurchaseVIP(accountID, 1), "VIP1 comprado com gems")
	_checkEq(_sql.GetGems(accountID), 5000 - cost, "débito único (sem double-charge de re-run)")
	_checkEq(_ledgerCount(accountID, "vip1_purchase"), 1, "ledger gems do VIP escrito uma vez")
	var until : int = _sql.GetVIPUntil(accountID)
	_check(until >= now + int(_catalog.VIPDays) * 86400 - 3 and until <= now + int(_catalog.VIPDays) * 86400 + 3, "janela = 30d a partir da compra")
	_checkEq(_sql.GetVIPTier(accountID), 1, "tier 1 registrado")
	# stack: segunda compra estende a partir da janela ativa (nunca rebaixa)
	_check(_economy.AddGems(accountID, cost, "edfx_seed2"), "gems p/ segunda compra")
	_check(_economy.PurchaseVIP(accountID, 2), "VIP2 comprado (upgrade)")
	_checkEq(_sql.GetVIPTier(accountID), 2, "tier 2 registrado no upgrade")
	_check(_sql.GetVIPUntil(accountID) > until, "janela estendida pelo upgrade")
	# saldo insuficiente: NADA é escrito — o estado meio-aplicado do bug P1-10
	_checkEq(_sql.GetVIPTier(accountID), 2, "tier 2 ainda registrado antes do teste de recusa")
	_sql.SetGems(accountID, 5)
	var untilBefore : int = _sql.GetVIPUntil(accountID)
	_check(not _economy.PurchaseVIP(accountID, 1), "compra com 5 gems recusada")
	_checkEq(_sql.GetGems(accountID), 5, "gems intactas na recusa")
	_checkEq(_sql.GetVIPUntil(accountID), untilBefore, "vip_until intacto na recusa (nenhuma metade aplicada)")
	_checkEq(_ledgerCount(accountID, "vip1_purchase"), 1, "nenhum ledger novo na recusa")
	# tier inválido: no-op
	_check(not _economy.PurchaseVIP(accountID, 3), "tier inválido rejeitado")
	_checkEq(_sql.GetGems(accountID), 5, "tier inválido não cobra nada")
	_dropFixture("edfx_vip_account", "EdfxVipChar")

# ------------------------------------------------------------------ suite: P1-10 reroll txn única

func _suiteRerollSingleTx():
	print("[suite] P1-10: reroll pago — débito + rotação num só commit")
	var charID : int = _createFixture("edfx_reroll_account", "EdfxRerollChar")
	if not _check(charID != 0, "reroll fixture created"):
		return
	var accountID : int = _sql.GetAccountIDForCharacter(charID)
	var cost : int = int(_catalog.DAILY_REROLL_COST)
	var day : int = _catalog.ShopDay(_sqlCommons.Timestamp())
	_sql.SetGems(accountID, maxi(1, cost - 10))
	var res0 = _economy.RerollDailyShop(accountID)
	_check(not bool(res0.get("ok", false)) and str(res0.get("reason", "")) == "insufficient_gems", "reroll sem gems é recusado")
	_checkEq(_sql.GetGems(accountID), cost - 10, "gems intactas na recusa")
	var row0 : Array = _sql.QueryBindings("SELECT salt, rerolls_used FROM shop_daily WHERE account_id = ? AND day = ?;", [accountID, day])
	_check(row0.is_empty() or (int(row0[0]["salt"]) == 0 and int(row0[0]["rerolls_used"]) == 0), "rotação intacta na recusa (sem estado meio-aplicado)")
	_check(_economy.AddGems(accountID, 200, "edfx_seed"), "gems semeadas p/ reroll")
	var saltBefore : int = 0
	var rerollsBefore : int = 0
	var rowB : Array = _sql.QueryBindings("SELECT salt, rerolls_used FROM shop_daily WHERE account_id = ? AND day = ?;", [accountID, day])
	if not rowB.is_empty():
		saltBefore = int(rowB[0]["salt"])
		rerollsBefore = int(rowB[0]["rerolls_used"])
	var res1 = _economy.RerollDailyShop(accountID)
	_check(bool(res1.get("ok", false)), "reroll pago aceito")
	_checkEq(_sql.GetGems(accountID), cost - 10 + 200 - cost, "débito único do custo")
	var row1 : Array = _sql.QueryBindings("SELECT salt, rerolls_used FROM shop_daily WHERE account_id = ? AND day = ?;", [accountID, day])
	_check(not row1.is_empty(), "linha do dia atualizada")
	if not row1.is_empty():
		_checkEq(int(row1[0]["salt"]), saltBefore + 1, "salt avançou junto com o débito (mesmo commit)")
		_checkEq(int(row1[0]["rerolls_used"]), rerollsBefore + 1, "contador de rerolls avançou")
	_checkEq(_ledgerCount(accountID, "daily_reroll"), 1, "ledger do reroll escrito uma vez")
	# cap diário: contador no máximo → recusado sem cobrar
	_sql.ExecuteBindings("UPDATE shop_daily SET rerolls_used = ? WHERE account_id = ? AND day = ?;", [int(_catalog.DAILY_REROLLS_MAX), accountID, day])
	var gemsBefore : int = _sql.GetGems(accountID)
	var res2 = _economy.RerollDailyShop(accountID)
	_check(not bool(res2.get("ok", false)) and str(res2.get("reason", "")) == "reroll_cap", "cap diário aplicado")
	_checkEq(_sql.GetGems(accountID), gemsBefore, "cap não cobra gems")
	_checkEq(_ledgerCount(accountID, "daily_reroll"), 1, "cap não escreve ledger")
	_dropFixture("edfx_reroll_account", "EdfxRerollChar")
