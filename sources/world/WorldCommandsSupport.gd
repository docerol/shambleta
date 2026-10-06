extends RefCounted
class_name WorldCommandsSupport

# C-4 (2026-10-06): o bloco CS/operação saiu do `WorldCommands.gd` verbatim —
# o arquivo era o ratchet apertado (1904 linhas contra teto 1925) e cada PR
# futuro ali morria no god-node gate por trivialidade. Os métodos são os
# MESMOS, com as MESMAS assinaturas: o CommandManager grava o callable com o
# objeto bound (`Command.Call` varre `get_method_list()` de
# `_callable.get_object()`), e é por isso que a REGISTRAÇÃO continua em
# `WorldCommands.RegisterCommands` — agora apontando para `_support`. Quem
# muda o verbete de ajuda aqui muda o despacho real; nenhum dos dois é
# espelho do outro por sorte: `tests/craft_wiring_test.gd` lê este fonte.

# SOM-IDLE: D3 — CS panel (thin wrappers over SQL reads; permission GM).
func CommandCsTrans(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty():
		Network.CommandFeedback("Usage: /cs_trans <account> [limit]", caller.peerID)
		return false
	var accountID : int = Launcher.SQL.GetAccountID(parts[0])
	if accountID == NetworkCommons.PeerUnknownID:
		Network.CommandFeedback("Account '%s' not found" % parts[0], caller.peerID)
		return false
	var limit : int = parts[1].to_int() if parts.size() > 1 else 10
	var rows : Array = Launcher.SQL.SearchLedger(accountID, limit)
	if rows.is_empty():
		Network.CommandFeedback("No transactions for %s" % parts[0], caller.peerID)
		return true
	var lines : PackedStringArray = PackedStringArray()
	for row in rows:
		lines.append("#%d %s %+d (bal %d) %s" % [int(row["id"]), str(row["kind"]), int(row["amount"]), int(row["balance_after"]), str(row["reason"])])
	Network.CommandFeedback("\n".join(lines), caller.peerID)
	return true

func CommandCsItem(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var uid : int = arg.strip_edges().to_int()
	if uid <= 0:
		Network.CommandFeedback("Usage: /cs_item <uid>", caller.peerID)
		return false
	var chain : Array = Launcher.SQL.LotHistory(uid)
	if chain.is_empty():
		Network.CommandFeedback("Lot %d not found" % uid, caller.peerID)
		return false
	var lines : PackedStringArray = PackedStringArray()
	for lot in chain:
		lines.append("uid %d: char %d item %d x%d (%s, parent %d)" % [int(lot["uid"]), int(lot["char_id"]), int(lot["item_id"]), int(lot["count"]), str(lot["reason"]), int(lot["parent_uid"])])
	Network.CommandFeedback("\n".join(lines), caller.peerID)
	return true

func CommandCsFlags(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var cs : CommunityService = Launcher.Economy.communityService if Launcher.Economy != null else null
	if cs == null:
		Network.CommandFeedback("Economy não montada", caller.peerID)
		return false
	var page : int = maxi(1, arg.strip_edges().to_int())
	var queue : Dictionary = cs.ListFlagsPaged("open", page, 10)
	var rows : Array = queue.get("rows", [])
	var total : int = int(queue.get("total", 0))
	if rows.is_empty():
		Network.CommandFeedback("No open fraud flags", caller.peerID)
		return true
	var lines : PackedStringArray = PackedStringArray()
	for row in rows:
		lines.append("#%d [%s %d/%d] %s acct %d char %d: %s" % [int(row["id"]), str(row["severity"]), int(row["score"]), int(queue.get("threshold", 2)), str(row["kind"]), int(row["account_id"]), int(row["char_id"]), str(row["detail"])])
	lines.append("page %d/%d (%d flags) — /cs_flag_info <id> · /cs_flag <id> <reviewed|dismissed> [nota] · /cs_fraud_stats" % [int(queue.get("page", 1)), int(queue.get("pages", 1)), total])
	Network.CommandFeedback("\n".join(lines), caller.peerID)
	return true

# Revisão com trilha: quem revisou (a conta do chamador), quando e a nota.
# Nenhuma das duas ações bane — reviewed mantém o hold e espera punição humana
# explícita (/ban, /mute); dismissed registra falso-positivo e o detector para
# de reabrir a mesma flag por 30 dias (FraudeReview.ReopenCooldownSec).
func CommandCsFlag(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var cs : CommunityService = Launcher.Economy.communityService if Launcher.Economy != null else null
	if cs == null:
		Network.CommandFeedback("Economy não montada", caller.peerID)
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.size() < 2:
		Network.CommandFeedback("Usage: /cs_flag <id> <reviewed|dismissed> [nota]", caller.peerID)
		return false
	var reviewerID : int = Peers.GetAccount(caller.peerID)
	if reviewerID <= 0:
		Network.CommandFeedback("Not logged in", caller.peerID)
		return false
	var note : String = " ".join(PackedStringArray(parts.slice(2)))
	var result : Dictionary = cs.ReviewFlag(parts[0].to_int(), parts[1], reviewerID, note)
	if not bool(result.get("ok", false)):
		match str(result.get("reason", "")):
			"bad_status":
				Network.CommandFeedback("Status must be reviewed or dismissed", caller.peerID)
			"not_found":
				Network.CommandFeedback("Flag not found", caller.peerID)
			"already_closed":
				Network.CommandFeedback("Flag already closed (revisões não são reescritas — abra outra se discorda)", caller.peerID)
			_:
				Network.CommandFeedback("Review failed: %s" % str(result.get("reason", "?")), caller.peerID)
		return false
	Network.CommandFeedback("Flag #%d -> %s por acct %d. %s" % [int(result.get("flag", 0)), str(result.get("status", "")), reviewerID, str(result.get("what_happened", ""))], caller.peerID)
	return true

# Contexto do acusado sem SQL manual: identidade resumida (LGPD: nunca o e-mail
# cru), sinais que dispararam a flag com o porquê congelado no evidence, saldo e
# últimas movimentaões, e o que cada ação faz de fato com a conta.
func CommandCsFlagInfo(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var cs : CommunityService = Launcher.Economy.communityService if Launcher.Economy != null else null
	if cs == null:
		Network.CommandFeedback("Economy não montada", caller.peerID)
		return false
	var flagID : int = arg.strip_edges().to_int()
	if flagID <= 0:
		Network.CommandFeedback("Usage: /cs_flag_info <id>", caller.peerID)
		return false
	var ctx : Dictionary = cs.FlagContext(flagID)
	if not bool(ctx.get("ok", false)):
		Network.CommandFeedback("Flag not found", caller.peerID)
		return false
	var flag : Dictionary = ctx.get("flag", {})
	var accused : Dictionary = ctx.get("accused", {})
	var lines : PackedStringArray = PackedStringArray()
	lines.append("#%d %s [%s score %d, limiar %d] status %s" % [flagID, str(flag.get("kind", "?")), str(flag.get("severity", "?")), int(flag.get("score", 0)), int(ctx.get("threshold", 2)), str(flag.get("status", "?"))])
	lines.append("detail: %s" % str(flag.get("detail", "")))
	if accused.is_empty():
		lines.append("accused: <sem linha de account>")
	else:
		lines.append("accused: %s (acct %d, %d dias, e-mail %s, hold referral %d, aberto em %d outras flags)" % [
			str(accused.get("username", "?")), int(flag.get("account_id", 0)), int(accused.get("age_days", 0)),
			"verificado" if int(accused.get("email_verified", 0)) == 1 else "não verificado",
			int(accused.get("referral_hold", 0)), (ctx.get("other_open_flags", []) as Array).size()])
	if accused.has("wallet"):
		lines.append("wallet: %d gems (%d pagos)" % [int((ctx.get("wallet", {}) as Dictionary).get("gems", 0)), int((ctx.get("wallet", {}) as Dictionary).get("gems_paid", 0))])
	var evidence : Dictionary = ctx.get("signals", {})
	if evidence is Dictionary and evidence.has("why"):
		for signalKind in (evidence.get("why", {}) as Dictionary).keys():
			lines.append("sinal %s (peso %d): %s" % [str(signalKind), int(FraudeReview.WeightOf(str(signalKind))), str((evidence.get("why", {}) as Dictionary)[signalKind])])
	lines.append("ações: reviewed -> %s" % str((ctx.get("action_semantics", {}) as Dictionary).get("reviewed", "")))
	lines.append("ações: dismissed -> %s" % str((ctx.get("action_semantics", {}) as Dictionary).get("dismissed", "")))
	Network.CommandFeedback("\n".join(lines), caller.peerID)
	return true

# Métrica de revisão (o beta só sabe se o detector está calibrado com números):
# flags por severidade, falsos positivos descartados/dia, tempo médio de revisão.
# Os mesmos contadores saem em telemetry_event kind 'fraud_metrics' (via do
# /metrics do companion) a cada passada do scan diário.
func CommandCsFraudStats(caller : PlayerAgent) -> bool:
	if not caller:
		return false
	var cs : CommunityService = Launcher.Economy.communityService if Launcher.Economy != null else null
	if cs == null:
		Network.CommandFeedback("Economy não montada", caller.peerID)
		return false
	var metrics : Dictionary = cs.FraudMetrics()
	var lines : PackedStringArray = PackedStringArray()
	for key in metrics.keys():
		if key == "open_by_severity":
			for sev in (metrics[key] as Dictionary).keys():
				lines.append("open_%s=%d" % [str(sev), int((metrics[key] as Dictionary)[sev])])
		else:
			lines.append("%s=%s" % [str(key), str(metrics[key])])
	Network.CommandFeedback("\n".join(lines), caller.peerID)
	return true

# SOM-IDLE Fase H: GM review of craft submissions (ITEM_CRAFTING.md §5).
# /cs_craft list                         — lists pending submissions
# /cs_craft approve <id>                  — approves (enters ItemsDB + drops creator item)
# /cs_craft reject <id> [reason]          — rejects (no fee refund per §5.3 policy)
func CommandCsCraft(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	if parts.is_empty() or parts[0] == "list" or parts.size() == 1:
		var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
			"SELECT id, account_id, char_id, slot, name, template_hash, tier, budget_used, rarity, submits_used, created_at FROM craft_submission WHERE status = 'pending' ORDER BY id;", [])
		if rows.is_empty():
			Network.CommandFeedback("No pending craft submissions", caller.peerID)
			return true
		var lines : PackedStringArray = PackedStringArray()
		lines.append("Pending craft submissions (%d):" % rows.size())
		for row in rows:
			lines.append("#%d acct %d char %d slot %d '%s' T%d %s budget %d resubmit %d" % [
				int(row["id"]), int(row["account_id"]), int(row["char_id"]),
				int(row["slot"]), str(row["name"]), int(row["tier"]),
				str(row["rarity"]), int(row["budget_used"]), int(row["submits_used"])])
		Network.CommandFeedback("\n".join(lines), caller.peerID)
		return true
	if parts.size() < 2:
		Network.CommandFeedback("Usage: /cs_craft <list|approve <id>|reject <id> [reason]>", caller.peerID)
		return false
	var subID : int = parts[1].to_int()
	if subID <= 0:
		Network.CommandFeedback("Invalid submission ID", caller.peerID)
		return false
	match parts[0]:
		"approve":
			if Launcher.Economy.ApproveCraftSubmission(caller, subID):
				Network.CommandFeedback("Submission #%d approved — entered drop pool" % subID, caller.peerID)
				return true
			Network.CommandFeedback("Approval failed (invalid ID or DB error)", caller.peerID)
			return false
		"reject":
			var reason : String = "rejected by GM"
			if parts.size() >= 3:
				reason = " ".join(parts.slice(2))
			if Launcher.Economy.RejectCraftSubmission(caller, subID, reason):
				Network.CommandFeedback("Submission #%d rejected: %s" % [subID, reason], caller.peerID)
				return true
			Network.CommandFeedback("Rejection failed (invalid ID or already reviewed)", caller.peerID)
			return false
		_:
			Network.CommandFeedback("Usage: /cs_craft <list|approve <id>|reject <id> [reason]>", caller.peerID)
			return false

