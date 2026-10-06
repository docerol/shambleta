extends SceneTree

# SOM-IDLE: harness da recompensa DECLARADA de quest, paga pelo servidor via
# ledger. A auditoria mediu (AUDITORIA_INDEPENDENTE_2026-09-24) que quest era a
# única atividade não-kill sem pagamento: `QuestData.reward` (fontes
# sources/db/instance/QuestData.gd:@QuestData) era texto de vitrine que ninguém lê,
# NpcCommons.SetQuest fechava a quest sem mintar nada (o funil auditado em
# NpcCommons.gd:167-177, antes desta mudança só emitia notificação), e o que
# existia de recompensa estava à mão em diálogos que somavam `stat.gp` na
# memória — sem linha de ledger, sem regra no dado, sem prova de que o crédito
# existiu. Sete desses números hoje MORAM no dado (suíte 8); os que ficaram à mão
# são os de ramo/estado intermediário, contados um a um no censo da mesma suíte.
#
# O que este harness segura, na ordem das suítes, cada um contra a regressão
# específica:
#   1. o dado: QuestData tem campos numéricos próprios ANTES de qualquer parse de
#      prose, o texto de vitrine continua no schema e o default é 0/0 — a mudança é
#      aditiva: nada é mintado até o dado declarar. O que os .tres dizem hoje é
#      MEDIDO e impresso (preset é dado de outro dono), não asserção;
#   2. o guard puro: só a TRANSIÇÃO para 255 paga; reentregar 255 (o mesmo diálogo
#      revisitado) e regredir estado não pagam;
#   3. o mint: fechar quest com recompensa declarada credita exatamente o declarado
#      na carteira e escreve UMA linha de ledger com kind/reason do catálogo — e o
#      dupe clássico não paga de novo, nem depois de o estado da quest ser
#      reaberto/apagado no banco (Elanore.gd:152, WorldCommands.gd:1208), porque a
#      prova é o ledger append-only (data/conf/migrations/009_idle_economy.sql:32),
#      não o estado; e o guard é POR QUEST, não por personagem;
#   4. quest sem recompensa declarada: não paga, não erro, nenhuma linha, e a frase
#      do pagamento fica vazia;
#   5. a perna de XP exige o agente carregado: sem agente nada do XP é mintado —
#      inclusive a linha, que é o guard (linha sem crédito provaria o falso);
#   6. a frase do pagamento sai dos NÚMEROS, não do texto ("Unknown" não vira
#      crédito e crédito real não se esconde atrás de "Unknown");
#   7. o gancho: SetQuest chama o pagamento amarrado à transição, pelo funil que
#      todo diálogo e o comando de GM usam, e nada soma em `stat.gp` cru;
#   8. a migração: o número que estava no diálogo está declarado no preset, a
#      vitrine promete exatamente esse número, e o diálogo parou de pagar — com
#      censo dos que ainda pagam e ratchet por nome para nenhum deles voltar.
#
# Mesmo contrato dos outros harnesses descobertos por `scripts/test.sh`: o script
# `-s` compila ANTES dos autoloads existirem — nada de class_name ou de
# Launcher/DB/SQL em tempo de parse; as classes do projeto entram por load()
# depois do boot. Exit code = nº de falhas; a régua do gate é a última linha
# `== RESULT: N checks, 0 failures ==`.

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

# ------------------------------------------------------------------ boot

var _launcher : Node = null
var _sql : Node = null
var _economy : Node = null
var _dbScript : GDScript = null
var _npcCommons : GDScript = null
var _catalog : GDScript = null
var _progressCommons : GDScript = null
var _networkCommons : GDScript = null
var _actorCommons : GDScript = null
var _skillCommons : GDScript = null

# Presets REAIS: "An Old Friendship" promete 1000 GP na vitrine e declara
# exatamente 1000 em `rewardGP` (era o número que o diálogo de Frost pagava à mão,
# suíte 8); "Tutorial" não promete nada e não declara nada.
const OLD_FRIENDSHIP : String = "res://presets/quests/TulimsharOldFriendship.tres"
const TUTORIAL : String = "res://presets/quests/Tutorial.tres"
const NINA : String = "res://presets/quests/NinaHungry.tres"

func _run():
	print("== quest reward harness (dado declarativo + ledger + idempotência) ==")
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
		# `Economy.isInitialized` é o sinal de que `EconomyDomainBinding.Bind` rodou:
		# sem o kernel montado (EconomyService.gd:65 → :78) MoveGold não existe e o
		# pagamento não tem caminho — é o mesmo gate que a suítes de economia amarram
		# (economy_design_fix_test.gd:212 olha o serviço montado no boot).
		if _sql != null and _sql.isInitialized and _economy != null and _economy.isInitialized:
			break
	print("== boot wait done (waited %d ms) ==" % waited)
	# Falha alta e controlada antes de qualquer pagamento: sem kernel o caminho do
	# ledger não existe, e chamar MoveGold assim seria o SCRIPT ERROR que derruba o
	# gate inteiro em vez de uma linha [FAIL] legível.
	if not _check(_economy != null and _economy.kernel != null, "kernel do Economy montado no boot (o caminho único do gold)"):
		_finish()
		return
	_dbScript = load("res://sources/db/DB.gd")
	_npcCommons = load("res://sources/actor/agent/NpcCommons.gd")
	_catalog = load("res://sources/economy/EconomyCatalog.gd")
	_progressCommons = load("res://sources/actor/ProgressCommons.gd")
	_networkCommons = load("res://sources/network/NetworkCommons.gd")
	_actorCommons = load("res://sources/actor/ActorCommons.gd")
	_skillCommons = load("res://sources/skill/SkillCommons.gd")
	var dbReady : bool = false
	for i in 40:
		if bool(_dbScript.get("isInitialized")):
			dbReady = true
			break
		await create_timer(0.25).timeout
	if not _check(dbReady, "DB initialized (quests/items preloaded)"):
		_finish()
		return
	# O "salt" da corrida, em millis de relógio: id de quest novo a cada gate.
	# `Time` e não `OS`: `OS` não é classe estática no 4.x e o resolveamento em
	# GDScript estrito é erro de parse (medido), e ticks do processo reiniciam em
	# zero — o que não serve de salt entre corridas.
	_salt = int(Time.get_unix_time_from_system() * 1000.0) % 100000000

	var schemaOK : bool = _suiteDeclarativeData()
	if not schemaOK:
		_check(false, "sem os campos declarados em QuestData as suítes de pagamento não têm o que provar (o fix não está aplicado)")
		_finish()
		return
	_suiteTransitionGuard()
	_suitePaysOnce()
	_suiteNoDeclaredReward()
	_suiteXPPaidByLoadedAgentOnly()
	_suiteRewardLineFromNumbers()
	_suiteHookWiring()
	_suiteMigration()

	_finish()

func _finish():
	# O drain ANTES do quit: Preload() dispara loads em thread; sem juntá-las o
	# Launcher._exit_tree estoura SIGSEGV no fim do processo (mesma regra de
	# tests/balance_test.gd:129).
	if _dbScript != null:
		_dbScript.call("DrainPendingPreloads")
	print("== RESULT: %d checks, %d failures ==" % [checks, failures])
	quit(failures if failures > 0 else 0)

# ------------------------------------------------------------------ fixture

# Cópia própria e mínima do CreateFixture das suítes de economia: conta com aceite
# vigente + personagem level 1 + gold. Nada de estado compartilhado.
func _createFixture(accountName : String, nickname : String, gp : int = 5000) -> int:
	_sql.db.delete_rows("character", "nickname = '%s';" % nickname)
	_sql.db.delete_rows("account", "username = '%s';" % accountName)
	if not _sql.AddAccount(accountName, "testpass", accountName + "@test.local", _networkCommons.AgreementTosVersion, _networkCommons.AgreementPrivacyVersion, "203.0.113.1"):
		return 0
	var accountID : int = _sql.GetAccountID(accountName)
	if accountID < 0:
		return 0
	if not _sql.AddCharacter(accountID, nickname, _actorCommons.DefaultStats, _actorCommons.DefaultTraits, _actorCommons.DefaultAttributes):
		return 0
	var charID : int = _sql.GetCharacterID(accountID, nickname)
	if charID < 0:
		return 0
	_sql.SetSkill(charID, _skillCommons.SkillMeleeName.hash(), 1)
	_sql.db.update_rows("stat", "char_id = %d" % charID, {"gp": gp})
	return charID

func _dropFixture(accountName : String, nickname : String):
	_sql.db.delete_rows("character", "nickname = '%s'" % nickname)
	_sql.db.delete_rows("account", "username = '%s'" % accountName)

func _gpOf(charID : int) -> int:
	var rows : Array = _sql.db.select_rows("stat", "char_id = %d" % charID, ["gp"])
	return int(rows[0]["gp"]) if not rows.is_empty() and rows[0].get("gp", null) != null else 0

func _questRows(charID : int) -> int:
	var rows : Array = _sql.db.select_rows("quest", "char_id = %d" % charID, ["quest_id"])
	return rows.size()

func _ledgerRows(charID : int, reason : String) -> Array[Dictionary]:
	# Só conta e confere; nunca apaga. `ledger_transaction` é append-only
	# (009_idle_economy.sql:32 e a trigger condicional da 056, que só libera linha
	# coberta por rollup) — DELETE aqui abortaria no banco e a fixture ficaria
	# presa. A limpeza é o `reason` com id de quest novo a cada corrida.
	var rows : Array[Dictionary] = _sql.QueryBindings("SELECT kind, amount, balance_after FROM ledger_transaction WHERE char_id = ? AND reason = ?;", [charID, reason])
	return rows

# O reason do grant é construído AQUI pelo mesmo formato que o servidor publica
# (NpcCommons.QuestRewardReason), com o kind lido do catálogo — se o servidor
# mudar o vocabulário, a régua muda junto em vez de procurar string morta.
func _rewardReason(quest : Resource, kind : String) -> String:
	return "quest:%d:%s" % [int(quest.get("id")), kind]

# Preset real + recompensa declarada na INSTÂNCIA COPIADA: os .tres de presets/
# são dado de outro dono (fora desta mudança) e a instância carregada é a mesma
# que vive no DB.QuestsDB — duplicate() declara o número como um preset declararia
# sem rasgar o arquivo nem mutar o registro compartilhado do processo.
# O `id` também é trocado: o guard durável é o par (char_id, reason) e o reason é
# `quest:<id>:kind`. A suíte apaga o PERSONAGEM no fim, mas a linha de ledger é
# append-only (009_idle_economy.sql:32, e a 056 só libera linha coberta por rollup)
# e o SQLite pode reusar o char_id de uma corrida para a outra — com id de quest
# real a segunda corrida do gate herdaria "já paguei esta quest" da primeira e a
# suíte 3 acusaria um dupe que não existe. Id novo por corrida = reason novo.
var _salt : int = 0

func _questID(tag : int) -> int:
	return _salt * 100 + tag

func _declaredPreset(path : String, gp : int, exp : int, questID : int) -> Resource:
	var original : Resource = load(path)
	if original == null:
		return null
	var quest : Resource = original.duplicate()
	quest.set("id", questID)
	quest.set("rewardGP", gp)
	quest.set("rewardEXP", exp)
	return quest

func _pay(quest : Resource) -> bool:
	# O terceiro argumento é o agente vivo da perna de XP; null explícito porque o
	# caminho testado aqui é o do servidor sem agente carregado (offline/stub).
	return bool(_npcCommons.call("PayQuestRewardForCharacter", _payCharID, quest, null))

var _payCharID : int = 0

# ------------------------------------------------------------------ suite 1: o dado

func _suiteDeclarativeData() -> bool:
	print("[suite] 1: QuestData declara número; prose continua sendo só vitrine")
	var preset : Resource = load(OLD_FRIENDSHIP)
	if not _check(preset != null, "preset real '%s' carrega" % OLD_FRIENDSHIP):
		return false
	var props : Array[Dictionary] = preset.get_script().get_script_property_list()
	var names : Array[String] = []
	for p in props:
		names.append(str(p["name"]))
	# Os dois campos novos: sem eles a recompensa teria de ser parseada de prose,
	# que é o que a auditoria marcou como causa (NinaHungry.tres: "Cactus Potion
	# x10, 100 GP" não tem como virar linha de ledger por kind sem adivinhar).
	var haveFields : bool = names.has("rewardGP") and names.has("rewardEXP")
	_check(haveFields, "QuestData declara rewardGP/rewardEXP como campos próprios (propriedades lidas: %d)" % names.size())
	_check(names.has("reward"), "e o `reward` de vitrine continua no schema (o jogador lê a frase, o servidor paga o número)")
	if not haveFields:
		return false
	# O campo nasce em 0: é isto que torna a mudança de schema ADITIVA e inerte —
	# sem dado declarado nada é mintado, e o `reward` de vitrine continua sem poder
	# virar dinheiro (não há parse de prose em lugar nenhum). Os presets são dado de
	# outro dono e podem declarar números a qualquer momento: por isso a régua é o
	# default da classe, e o que os arquivos dizem hoje é MEDIDO e impresso, não
	# asserção (senão o gate deste fix quebraria no commit de quem preenche o dado).
	var fresh : Resource = load("res://sources/db/instance/QuestData.gd").new()
	_check(int(fresh.get("rewardGP")) == 0 and int(fresh.get("rewardEXP")) == 0, "QuestData.new() nasce com 0/0 (nada é mintado por default)")
	_check(not bool(fresh.call("HasDeclaredReward")), "e HasDeclaredReward() é false no 0/0 (o gate de 'nada a pagar')")
	print("   vitrine medida: OldFriendship = '%s' | Nina = '%s'" % [str(preset.get("reward")), str(load(NINA).get("reward"))])
	# O registro inteiro: a mudança de schema é aditiva, os 17 presets têm de
	# continuar carregando (uma @export mal declarada derrubaria o QuestsDB).
	var registry : Dictionary = _dbScript.QuestsDB
	_check(registry.size() >= 17, "DB.QuestsDB montou os presets (medido %d)" % registry.size())
	var missing : int = 0
	var declared : int = 0
	for questID in registry.keys():
		var quest : Resource = registry[questID]
		if quest.get("rewardGP") == null or quest.get("rewardEXP") == null:
			missing += 1
		elif bool(quest.call("HasDeclaredReward")):
			declared += 1
	_checkEq(missing, 0, "todo preset do registro traz os campos novos (faltam: %d)" % missing)
	print("   presets já declarando número no registro: %d de %d" % [declared, registry.size()])
	return true

# ------------------------------------------------------------------ suite 2: transição

# Tabela de decisão PURA do guard — é o que impede o dupe clássico: o diálogo do
# NPC reentrega o mesmo 255 a cada visita (Ryan.gd:101 e :114 são o mesmo
# REWARDS_WITHDREW em dois ramos) e o estado volta do banco no login.
func _suiteTransitionGuard():
	print("[suite] 2: só a TRANSIÇÃO para concluída paga (reentregar 255 não paga)")
	var done : int = int(_progressCommons.CompletedProgress)
	var unknown : int = int(_progressCommons.UnknownProgress)
	_check(bool(_npcCommons.call("ShouldPayQuestReward", unknown, done)), "0 → 255 paga (conclusão de verdade)")
	_check(bool(_npcCommons.call("ShouldPayQuestReward", 2, done)), "2 → 255 paga (veio de um estado intermediário)")
	_check(not bool(_npcCommons.call("ShouldPayQuestReward", done, done)), "255 → 255 NÃO paga (a reentrega do mesmo diálogo)")
	_check(not bool(_npcCommons.call("ShouldPayQuestReward", done, 2)), "255 → 2 não paga (regressão de estado)")
	_check(not bool(_npcCommons.call("ShouldPayQuestReward", 1, 1)), "estado do meio não paga nada (255 é o único marco)")

# ------------------------------------------------------------------ suite 3: mint + dupe

func _suitePaysOnce():
	print("[suite] 3: fechar a quest minta o declarado e escreve UMA linha de ledger")
	var charID : int = _createFixture("qrw_paid_account", "QrwPaidChar", 5000)
	if not _check(charID != 0, "fixture criada"):
		return
	_payCharID = charID
	var goldKind : String = str(_catalog.LedgerKindGold)
	# O número declarado aqui é o mesmo que o preset promete na vitrine e guarda em
	# `rewardGP` (1000 GP, o valor que o diálogo de Frost pagava à mão antes da
	# suíte 8), lido do arquivo em vez de chutado — a régua é a carteira subir o
	# que o DADO declara, e o que o preset diz hoje é impresso para o log contar a
	# história sem mais um número solto no harness.
	var preset : Resource = load(OLD_FRIENDSHIP)
	print("   vitrine de OldFriendship: '%s' / rewardGP = %d → o harness paga o declarado" % [str(preset.get("reward")), int(preset.get("rewardGP"))])
	var quest : Resource = _declaredPreset(OLD_FRIENDSHIP, 1000, 0, _questID(1))
	var reason : String = _rewardReason(quest, goldKind)
	var gpBefore : int = _gpOf(charID)
	var first : bool = _pay(quest)
	_check(first, "primeira conclusão paga (retorna true)")
	_checkEq(_gpOf(charID) - gpBefore, 1000, "carteira subiu exatamente o declarado (+1000 GP)")
	var rows : Array[Dictionary] = _ledgerRows(charID, reason)
	_checkEq(rows.size(), 1, "UMA linha de ledger no reason da quest (%s)" % reason)
	if not rows.is_empty():
		_check(str(rows[0]["kind"]) == goldKind, "a linha é do kind do catálogo ('%s'), não um reason livre" % goldKind)
		_checkEq(int(rows[0]["amount"]), 1000, "amount do ledger == o declarado")
		_checkEq(int(rows[0]["balance_after"]), _gpOf(charID), "balance_after fecha com a carteira (invariante 1 do kernel)")
	# Reentrega: mesma conclusão, segunda e terceira chamada (o bug clássico).
	var second : bool = _pay(quest)
	_check(not second, "reentrega da mesma conclusão não paga (retorna false)")
	_checkEq(_gpOf(charID) - gpBefore, 1000, "e a carteira não subiu de novo (era exatamente o dupe)")
	_checkEq(_ledgerRows(charID, reason).size(), 1, "reentrega não duplica a linha de ledger")
	# Prova DURÁVEL: primeiro a conclusão é PERSISTIDA pelo caminho real do
	# servidor (Progress.SetQuest → SQL.SetQuest, sources/actor/Progress.gd:@SetQuest e
	# sources/sql/SQL.gd:1171), e
	# aí o estado é apagado do banco — o caso de Elanore.gd:152, que devolve a quest
	# a INACTIVE, e do `/quest <name> <state>` na mão de um GM (WorldCommands.gd:1208).
	# Quem guardasse "já paguei" só no estado da quest pagaria de novo exatamente
	# aqui; é esta asserção que o ledger tem de atravessar.
	var done : int = int(_progressCommons.CompletedProgress)
	var questID : int = int(quest.get("id"))
	_check(bool(_sql.SetQuest(charID, questID, done)), "conclusão persistida pelo caminho real (SQL.SetQuest)")
	_checkEq(_questRows(charID), 1, "o banco tem a linha de quest concluída")
	_sql.db.delete_rows("quest", "char_id = %d" % charID)
	_checkEq(_questRows(charID), 0, "estado apagado do banco (reabertura/reset de GM simulado)")
	var third : bool = _pay(quest)
	_check(not third, "mesmo sem estado no banco, a recompensa não sai duas vezes (o ledger é a prova)")
	_checkEq(_gpOf(charID) - gpBefore, 1000, "carteira intacta depois do reset de estado")
	_checkEq(_ledgerRows(charID, reason).size(), 1, "ledger intacta depois do reset de estado")
	# Uma quest DIFERENTE da mesma personagem paga: o guard é por quest, não por
	# conta — senão a segunda quest da vida nunca seria paga.
	var other : Resource = _declaredPreset(NINA, 100, 0, _questID(2))
	var otherReason : String = _rewardReason(other, goldKind)
	var beforeOther : int = _gpOf(charID)
	_check(_pay(other), "outra quest da mesma personagem paga (guard é por quest, não por char)")
	_checkEq(_gpOf(charID) - beforeOther, 100, "e credita o valor dela (+100 GP)")
	_checkEq(_ledgerRows(charID, otherReason).size(), 1, "com linha de ledger própria")
	_checkEq(_ledgerRows(charID, reason).size(), 1, "sem tocar a linha da primeira quest")
	_sql.db.delete_rows("quest", "char_id = %d" % charID)
	_dropFixture("qrw_paid_account", "QrwPaidChar")
	_payCharID = 0

# ------------------------------------------------------------------ suite 4: nada declarado

func _suiteNoDeclaredReward() -> void:
	print("[suite] 4: quest sem recompensa declarada não paga, não erro, não linha")
	var charID : int = _createFixture("qrw_none_account", "QrwNoneChar", 5000)
	if not _check(charID != 0, "fixture criada"):
		return
	_payCharID = charID
	# O caso real do preset "Tutorial" (vitrine "Unknown"), forçado a 0/0 numa cópia:
	# "nenhuma recompensa declarada" é a hipótese da suíte, então ela tem de valer
	# mesmo se o dono do dado preencher números naquele arquivo depois.
	var quest : Resource = _declaredPreset(TUTORIAL, 0, 0, _questID(7))
	print("   vitrine de Tutorial: '%s' (texto sem número, e sem número declarado)" % str(quest.get("reward")))
	_check(not bool(quest.call("HasDeclaredReward")), "nada declarado no preset (o gate de 'nada a pagar')")
	var gpBefore : int = _gpOf(charID)
	var paid : bool = _pay(quest)
	_check(not paid, "nada declarado → nada pago (retorna false)")
	_checkEq(_gpOf(charID), gpBefore, "carteira intocada")
	_checkEq(_ledgerRows(charID, _rewardReason(quest, str(_catalog.LedgerKindGold))).size(), 0, "nenhuma linha de ledger (zero linhas ≠ linha de valor 0)")
	_checkEq(_ledgerRows(charID, _rewardReason(quest, str(_catalog.LedgerKindXP))).size(), 0, "nenhuma linha de ledger de XP também")
	_check(str(_npcCommons.call("QuestRewardLine", quest)) == "", "e a frase do pagamento fica vazia: sem número declarado nada é prometido na tela")
	_dropFixture("qrw_none_account", "QrwNoneChar")
	_payCharID = 0

# ------------------------------------------------------------------ suite 5: XP

# XP mora na memória do agente carregado (Stats.AddExperience resolve level-up e
# transbordo de essência, Stats.gd:225-244). Reescrever a curva de Experience
# aqui seria a segunda regra para um número só; então a perna de XP só sai com
# agente, e sem agente NADA da perna de XP é mintado — inclusive a linha, que é
# o guard: linha sem crédito diria ao ledger que pagou o que não existe.
func _suiteXPPaidByLoadedAgentOnly() -> void:
	print("[suite] 5: perna de XP exige o agente carregado; sem ela nada é meia-pago")
	var charID : int = _createFixture("qrw_xp_account", "QrwXPChar", 5000)
	if not _check(charID != 0, "fixture criada"):
		return
	_payCharID = charID
	var xpOnly : Resource = _declaredPreset(OLD_FRIENDSHIP, 0, 250, _questID(3))
	var paid : bool = _pay(xpOnly)
	_check(not paid, "XP declarado sem agente vivo não paga (retorna false)")
	_checkEq(_ledgerRows(charID, _rewardReason(xpOnly, str(_catalog.LedgerKindXP))).size(), 0, "e não escreve ledger de XP (prova só o que foi creditado)")
	_checkEq(_gpOf(charID), 5000, "carteira intocada")
	var goldKind : String = str(_catalog.LedgerKindGold)
	var both : Resource = _declaredPreset(OLD_FRIENDSHIP, 700, 250, _questID(4))
	var gpBefore : int = _gpOf(charID)
	_check(_pay(both), "com ouro declarado a perna monetária paga mesmo sem agente")
	_checkEq(_gpOf(charID) - gpBefore, 700, "e credita só o ouro (+700 GP)")
	_checkEq(_ledgerRows(charID, _rewardReason(both, goldKind)).size(), 1, "uma linha de gold")
	_checkEq(_ledgerRows(charID, _rewardReason(both, str(_catalog.LedgerKindXP))).size(), 0, "nenhuma linha de XP falsa")
	_dropFixture("qrw_xp_account", "QrwXPChar")
	_payCharID = 0

# ------------------------------------------------------------------ suite 6: frase

func _suiteRewardLineFromNumbers() -> void:
	print("[suite] 6: a frase do pagamento sai dos números, não da prose")
	var quest : Resource = _declaredPreset(TUTORIAL, 250, 40, _questID(5))
	print("   vitrine do preset usado: '%s'" % str(quest.get("reward")))
	var line : String = str(_npcCommons.call("QuestRewardLine", quest))
	_check(line.contains("+250 GP") and line.contains("+40 EXP"), "a linha cita os declarados (%s)" % line)
	_check(not line.contains("Unknown"), "e não repete a vitrine (%s)" % line)
	var goldOnly : Resource = _declaredPreset(OLD_FRIENDSHIP, 1000, 0, _questID(6))
	_check(str(_npcCommons.call("QuestRewardLine", goldOnly)) == "Quest Reward: +1000 GP", "sem EXP declarado a linha não inventa degrau")

# ------------------------------------------------------------------ suite 7: gancho

# O pagamento mora no funil por onde TODA quest passa: NpcCommons.SetQuest é
# chamado pelos diálogos (NpcScript.gd:158) e pelo comando de GM
# (WorldCommands.gd:1208). Verificar a costura na fonte é o que separa "existe
# uma função que paga" de "fechar quest paga".
func _suiteHookWiring() -> void:
	print("[suite] 7: SetQuest paga pela transição, no funil que todo diálogo usa")
	var src : String = FileAccess.get_file_as_string("res://sources/actor/agent/NpcCommons.gd")
	var inSetQuest : bool = false
	# A existência é acumulada, não o estado do cursor: SetQuest não é a última
	# função do arquivo, então ler `inSetQuest` depois do laço daria false mesmo com
	# o funil inteiro no lugar (a régua se auto-derrubava por isso).
	var sawSetQuest : bool = false
	var body : bool = false
	for line : String in src.split("\n"):
		if line.begins_with("static func SetQuest("):
			inSetQuest = true
			sawSetQuest = true
		elif inSetQuest and line.begins_with("static func "):
			inSetQuest = false
		elif inSetQuest and line.contains("PayQuestReward(caller, questData)"):
			body = true
	_check(sawSetQuest, "SetQuest existe no funil (NpcCommons.gd)")
	_check(body, "SetQuest chama PayQuestReward(caller, questData) — sem esta linha fechar quest não paga nada")
	_check(src.contains("if ShouldPayQuestReward(previousState, state):"), "o pagamento está amarrado à TRANSIÇÃO (não à chamada)")
	_check(src.contains("var previousState : int = caller.progress.GetQuest(questID)"), "e o estado anterior é lido ANTES da escrita (ler depois veria 255 sempre)")
	_check(src.contains("Launcher.Economy.MoveGold(charID, questData.rewardGP, goldReason)"), "o ouro sai pelo caminho único do kernel, não por stat.gp cru")
	_check(not src.contains("caller.stat.AddGP(questData.rewardGP"), "nada soma em stat.gp fora do ledger (a rota dos diálogos à mão)")

# ------------------------------------------------------------------ suite 8: migração

# Os sete presets abaixo são os sete diálogos que pagavam GP/EXP à mão NA
# TRANSIÇÃO para 255. A migração é REFACTOR, não rebalance: o número declarado no
# dado é o mesmo que o ramo do script somava antes, e o ramo agora não soma nada.
# As duas metades valem juntas — preencher o preset sem esvaziar o diálogo paga o
# dobro; esvaziar o diálogo sem preencher tira do jogador. Só esta suíte confere o
# meio-termo que nenhuma das duas metades isoladas enxerga.
const MIGRATED : Array[Dictionary] = [
	{"preset": "res://presets/quests/NinaHungry.tres", "dialog": "Nina.gd", "gp": 100, "xp": 0},
	{"preset": "res://presets/quests/TulimsharOldFriendship.tres", "dialog": "Frost.gd", "gp": 1000, "xp": 0},
	{"preset": "res://presets/quests/SnakePitBitingThrist.tres", "dialog": "Mauro.gd", "gp": 1000, "xp": 50},
	{"preset": "res://presets/quests/SnakePitThief.tres", "dialog": "ThiefsChest.gd", "gp": 200, "xp": 50},
	{"preset": "res://presets/quests/SandstormNathanWater.tres", "dialog": "Nathan.gd", "gp": 100, "xp": 50},
	{"preset": "res://presets/quests/TulimsharGlassmaking.tres", "dialog": "Eridu.gd", "gp": 0, "xp": 100},
	{"preset": "res://presets/quests/GrainInTheDesert.tres", "dialog": "Riskim.gd", "gp": 0, "xp": 30},
]

# O censo dos que ainda pagam à mão, medido nesta árvore, com o motivo de cada um
# ficar de fora da migração. É o que separa "a régua olhou tudo" de "a régua olhou
# o que conveniava": PeterGlobal dá três prêmios por estado intermediário da
# temporada, Ekinu e Kael pagam em EKINU_DONE/KAEL_DONE (passo de tutorial, não
# conclusão), e Ryan paga 1000 OU 2000 conforme o ramo do relatório — o modelo
# declara um número por quest, e escolher um dos dois disfarçado de migração seria
# rebalance. Ninguém aqui inventa economia: a régua é um ratchet, e fechar um dos
# cinco só baixando este número.
const HAND_PAID_EXPECTED : int = 5

# Detector do par (SetQuest, pagamento à mão) no MESMO bloco de função, com linha
# de comentário descartada: sem o descarte, a própria prosa que explica a
# migração ("os 100 GP saíram daqui") seria contada como pagamento — é o defeito
# que a régua de links externos deste repo já aprendeu a evitar.
func _handPaidBlocks(src : String, fileLabel : String) -> Array[String]:
	var out : Array[String] = []
	var fnName : String = ""
	var hasSet : bool = false
	var hasPay : bool = false
	for rawLine in src.split("\n"):
		var line : String = String(rawLine)
		var trimmed : String = line.strip_edges()
		if trimmed.begins_with("func ") or trimmed.begins_with("static func "):
			if hasSet and hasPay:
				out.append("%s:%s" % [fileLabel, fnName])
			hasSet = false
			hasPay = false
			fnName = trimmed.trim_prefix("static ").trim_prefix("func ").get_slice("(", 0)
			continue
		if trimmed.begins_with("#"):
			continue
		if line.contains("SetQuest("):
			hasSet = true
		if line.contains("AddGP(") or line.contains("AddExp("):
			hasPay = true
	if hasSet and hasPay:
		out.append("%s:%s" % [fileLabel, fnName])
	return out

func _scriptFilesUnder(dirPath : String, found : Array[String]) -> void:
	var dir : DirAccess = DirAccess.open(dirPath)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname : String = dir.get_next()
	while fname != "":
		var full : String = dirPath.path_join(fname)
		if dir.current_is_dir():
			if not fname.begins_with("."):
				_scriptFilesUnder(full, found)
		elif fname.ends_with(".gd"):
			found.append(full)
		fname = dir.get_next()
	dir.list_dir_end()

func _suiteMigration() -> void:
	print("[suite] 8: o número migrou do diálogo para o dado, e o diálogo parou de pagar")
	# Controle positivo do detector, antes de confiar no censo: um bloco plantado
	# com SetQuest + AddGP TEM que ser apontado. Sem isto, "censo = 5" pode estar
	# sendo um detector mudo.
	var planted : String = "func OnX():\n\tSetQuest(1, 255)\n\tAddGP(100)\n\nfunc OnY():\n\tAddGP(5)\n"
	var plantedHit : Array[String] = _handPaidBlocks(planted, "planteia")
	_checkEq(plantedHit.size(), 1, "detector acha exatamente o bloco plantado que paga e transiciona")
	# E o comentário não conta: a mesma planteia, com o pagamento escrito em prosa.
	var prosaOnly : String = "func OnX():\n\tSetQuest(1, 255)\n\t# AddGP(100) saiu daqui\n"
	_checkEq(_handPaidBlocks(prosaOnly, "prosa").size(), 0, "linha de comentário não é pagamento")
	# 1) o dado declara o número histórico de cada migração.
	var declared : int = 0
	for entry in MIGRATED:
		var path : String = String(entry["preset"])
		var quest : Resource = load(path)
		if not _check(quest != null, "preset migado '%s' carrega" % path):
			continue
		var gp : int = int(quest.get("rewardGP"))
		var xp : int = int(quest.get("rewardEXP"))
		_checkEq(gp, int(entry["gp"]), "%s: rewardGP é o número que o diálogo pagava" % path.get_file())
		_checkEq(xp, int(entry["xp"]), "%s: rewardEXP é o número que o diálogo pagava" % path.get_file())
		_check(bool(quest.call("HasDeclaredReward")), "%s: HasDeclaredReward() true (fechar esta quest minta)" % path.get_file())
		declared += 1
		# 2) a vitrine não promete outro número: o texto que o jogador lê tem de
		# conter o valor pago, e não conter "GP"/"EXP" onde nada daquela perna é
		# pago. É a metade visível do bug auditado (promessa na tela sem grant).
		var prose : String = String(quest.get("reward"))
		if gp > 0:
			_check(prose.contains("%d GP" % gp), "%s: vitrine declara os %d GP pagos ('%s')" % [path.get_file(), gp, prose])
		else:
			_check(not prose.contains("GP"), "%s: vitrine não promete GP que a quest não paga ('%s')" % [path.get_file(), prose])
		if xp > 0:
			_check(prose.contains("%d EXP" % xp), "%s: vitrine declara os %d EXP pagos ('%s')" % [path.get_file(), xp, prose])
		else:
			_check(not prose.contains("EXP"), "%s: vitrine não promete EXP que a quest não paga ('%s')" % [path.get_file(), prose])
	_checkEq(declared, MIGRATED.size(), "as %d migrações estão declaradas no registro" % MIGRATED.size())
	# 3) o censo: quantos blocos ainda pagam à mão, e quais.
	var files : Array[String] = []
	_scriptFilesUnder("res://sources/scripts", files)
	_check(files.size() >= 20, "a varredura de diálogos acha os scripts de quest (medido %d arquivos)" % files.size())
	var ainda : Array[String] = []
	for filePath in files:
		var src : String = FileAccess.get_file_as_string(filePath)
		for block in _handPaidBlocks(src, filePath.get_file()):
			ainda.append(String(block))
	_checkEq(ainda.size(), HAND_PAID_EXPECTED, "diálogos que ainda pagam GP/EXP à mão na transição: esperado %d, medido %d (%s)" % [HAND_PAID_EXPECTED, ainda.size(), ", ".join(ainda)])
	# 4) nenhum dos sete migados volta para a lista (o ratchet por nome, não só
	# por contagem — recontar igual com um nome trocado é regressão disfarçada).
	for entry in MIGRATED:
		# A chave é o arquivo de diálogo, não o nome do preset: os dois divergem em
		# cinco dos sete casos (`SandstormNathanWater.tres` ↔ `Nathan.gd`), e
		# casando pelo preset o ratchet não olharia nunca para o arquivo real.
		var dialogFile : String = String(entry["dialog"])
		var hit : bool = false
		for block in ainda:
			if String(block).get_slice(":", 0).to_lower() == dialogFile.to_lower():
				hit = true
		_check(not hit, "%s: o diálogo correspondente não voltou a pagar à mão" % dialogFile)
	print("   [info] migração: %d quests pagando pelo ledger; %d blocos ainda à mão por motivo declarado" % [declared, ainda.size()])
