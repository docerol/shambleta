extends SceneTree

# M-6 (2026-10-07): harness do Town Portal Scroll — a porta para a cidade.
# Prende nas FUNÇÕES REAIS (ShopService.BuyVendorOffer + o funil cru de lotes +
# a porta nominal `TownPortalScript.Verdict`) as três promessas do produto:
#
#  1. o ouro compra o lote: `vendor:portal` cobra e entrega exatamente um scroll
#     pelo hash NOMEADO da célula (a mesma chave que o inventário consome);
#  2. o estoque é o teto do vendor e o saldo é porta: pagar sem ouro não cria
#     lote, e o clique além da cota do dia é `sold_out` com ouro intacto;
#  3. a recusa nunca consome: `Verdict` devolve o token certo para quem já
#     está na cidade e para o mapa ausente — e o roteamento dessas recusas por
#     `_Rollback` é guardado no fonte (o consumo acontece antes do Execute,
#     então a devolução é a única forma de o scroll não virar golpe).
#
# Uso: XDG_DATA_HOME=/tmp/tp/data XDG_CACHE_HOME=/tmp/tp/cache \
#        timeout 300 godot --headless --path . -s tests/town_portal_test.gd
# Exit code: nº de checks falhos. Régua: `== RESULT: N checks, M failures ==`.
# Duck-typed como os irmãos: nada de identificador de projeto em tempo de parse.

const PortalHash : int = 3727406510

var checks : int = 0
var failures : int = 0

var _launcher : Node = null
var _sql = null
var _eco = null

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

func _portalLots(charID : int) -> int:
	var rows : Array = _sql.QueryBindings("SELECT COALESCE(SUM(count), 0) AS n FROM item_instance WHERE char_id = ? AND item_id = ?;", [charID, PortalHash])
	return int(rows[0]["n"]) if not rows.is_empty() else 0

func _gold(charID : int) -> int:
	var rows : Array = _sql.QueryBindings("SELECT gp FROM stat WHERE char_id = ?;", [charID])
	return int(rows[0]["gp"]) if not rows.is_empty() else -1

func _run() -> void:
	print("== SOM-IDLE town portal harness (M-6) ==")
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

	# Fixtures com sufixo de RUN (2026-10-07, lição do login_hardening): rerun
	# com nome fixo herda `vendor_claim` de ontem-e-hoje e a régua de estoque
	# vira acusação de mesa, não do produto.
	var runTag : String = str(int(Time.get_unix_time_from_system()))
	var acctName : String = "tp_" + runTag
	var email : String = acctName + "@tpl.test.local"
	var nc : GDScript = load("res://sources/network/NetworkCommons.gd")
	var ac : GDScript = load("res://sources/actor/ActorCommons.gd")
	if not _check(bool(_sql.AddAccount(acctName, "senha-de-teste-1", email, nc.get("AgreementTosVersion"), nc.get("AgreementPrivacyVersion"), "203.0.113.10")), "conta do portal criada"):
		_finish()
		return
	var accountID : int = int(_sql.GetAccountID(acctName))
	var nick : String = "tpc_" + runTag
	if not _check(bool(_sql.AddCharacter(accountID, nick, ac.get("DefaultStats"), ac.get("DefaultTraits"), ac.get("DefaultAttributes"))), "personagem do portal criado"):
		_finish()
		return
	var charID : int = int(_sql.GetCharacterID(accountID, nick))

	# Ouro de mesa pelo kernel (o mesmo caminho do `frd_ah_mint` do fraud).
	# 10000 cobre o teto inteiro do dia (20 × 180) sem o `insufficient_gold`
	# atrapalhar a régua de estoque — a recusa de saldo é provada em outra mesa.
	_eco.call("MoveGold", charID, 10000, "tp_mint")
	_checkEq(_gold(charID), 10000, "mesa com 10000 gp antes das compras")

	# 1. compra entrega o lote pelo hash nomeado e cobra o vendor:portal.
	var buy : Dictionary = _eco.BuyVendorOffer(accountID, charID, "portal")
	_check(bool(buy.get("ok", false)), "vendor vende o scroll (reason %s)" % str(buy.get("reason", "?")))
	_checkEq(_portalLots(charID), 1, "um lote pelo hash da célula (3727406510)")
	_checkEq(_gold(charID), 9820, "cobrança de 180 gp no vendor:portal")
	var ledger : Array = _sql.QueryBindings("SELECT reason, amount FROM ledger_transaction WHERE account_id = ? AND reason = 'vendor:portal';", [accountID])
	_checkEq(ledger.size(), 1, "uma linha de ledger nomeando a compra")
	_checkEq(int(ledger[0]["amount"]), -180, "o ledger debita o preço, não o troco")

	# 2. o consumo que o UseItem faz antes do Execute é exatamente um lote.
	var consumed : Array = _sql.ConsumeItemLotsRaw(charID, PortalHash, 1, true, "")
	_check(not consumed.is_empty(), "ConsumeItemLotsRaw come o scroll")
	_checkEq(_portalLots(charID), 0, "lote zerado após o consumo")
	_check(_sql.ConsumeItemLotsRaw(charID, PortalHash, 1, true, "").is_empty(), "sem lote não há segundo consumo")

	# 3. estoque: o teto do dia é VENDOR_STOCK_PER_DAY — cada oferta tem sua
	# própria contagem por linha, e a recusa não cria lote nem cobra ouro.
	var boughtMore : int = 1
	var stock : int = int(load("res://sources/economy/EconomyCatalog.gd").VENDOR_STOCK_PER_DAY)
	while boughtMore < stock:
		var again : Dictionary = _eco.BuyVendorOffer(accountID, charID, "portal")
		if not bool(again.get("ok", false)):
			break
		boughtMore += 1
	_checkEq(boughtMore, stock, "a oferta roda até o teto de estoque do dia")
	var out : Dictionary = _eco.BuyVendorOffer(accountID, charID, "portal")
	_checkEq(str(out.get("reason", "?")), "sold_out", "clique além do teto é sold_out")
	_checkEq(_portalLots(charID), boughtMore - 1, "recusa de estoque não criou lote")
	var goldNow : int = _gold(charID)
	var out2 : Dictionary = _eco.BuyVendorOffer(accountID, charID, "does_not_exist")
	_checkEq(str(out2.get("reason", "?")), "unknown_offer", "oferta inexistente recusada por nome")
	_checkEq(_gold(charID), goldNow, "nenhuma recusa moveu ouro")

	# 4. A porta nominal do script — os vereditos, sem agente na mesa. O scroll
	# leva À cidade (a volta é o idle-first de graça); recusa não consome.
	var tps : GDScript = load("res://sources/cell/scripts/TownPortalScript.gd")
	if not _check(tps != null, "TownPortalScript compila"):
		_finish()
		return
	_checkEq(str(tps.call("Verdict", true, true)), "already_in_town", "quem já está na cidade não compra o portão")
	_checkEq(str(tps.call("Verdict", false, false)), "town_unreachable", "mapa da cidade ausente: town_unreachable (o scroll não some num buraco)")
	_checkEq(str(tps.call("Verdict", false, true)), "", "fora da cidade, mundo com mapa: deixa passar")

	# 5. Wiring guard (declarado, §gameplay_fix_test): o consumo acontece ANTES
	# do Execute, então cada caminho de recusa do fonte tem que passar por
	# _Rollback — texto-fonte, o mínimo verificável sem cliente. E o aceite tem
	# que ser o warp para o mapa default com a política haltada ANTES de vender
	# o feedback.
	var f : FileAccess = FileAccess.open("res://sources/cell/scripts/TownPortalScript.gd", FileAccess.READ)
	var src : String = "" if f == null else f.get_as_text()
	if f != null:
		f.close()
	_check(src.contains("_Rollback(player)"), "script: a recusa devolve o scroll (_Rollback chamado)")
	_check(src.contains("func _Rollback") and src.contains("AddItem(scroll, 1)"), "script: a devolução volta pelo AddItem da casa")
	_check(src.contains("IdlePolicyService.StopIdleSession(player)"), "script: o aceite para a política viva (o warp é para a cidade)")
	_check(src.contains("Warp(player, townMap, LauncherCommons.DefaultStartPos"), "script: o warp é para o spawn default da cidade, não para a zona")
	_check(src.contains("ScrollCellHash : int = %d" % PortalHash), "script: o hash devolvido é o hash NOMEADO da célula")

	_finish()

func _bootReady() -> bool:
	if _launcher == null:
		return false
	var sql : Variant = _launcher.get("SQL")
	var world : Variant = _launcher.get("World")
	var eco : Variant = _launcher.get("Economy")
	return sql != null and bool(sql.isInitialized) and world != null and eco != null and bool(eco.isInitialized)
