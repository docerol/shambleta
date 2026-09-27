extends RefCounted
class_name FraudeReview

# SOM-IDLE Live-Ops (ROADMAP_COMERCIAL D3/S5): detector de fraude com SEVERIDADE
# por tipo de sinal + fila de revisão acionável. Extraído de CommunityService.gd
# pelo gate anti-god-node; a fachada pública continua sendo CommunityService
# (EconomyService.communityService), nada aqui é chamado de job novo.
#
# Por que severidade e não flag binário: o público-alvo é Brasil, onde LAN house,
# cybercafé e NGM compartilhado são uso NORMAL da conta — duas contas legítimas
# no mesmo IP público (CGNAT de operadora) ou no mesmo teclado são o dia-a-dia.
# Um detector que trata IP como evidência dura produz fila 100 % falsa (foi
# exatamente o bug da heurística de login removida em 2026-09-24 — ver o
# comentário em Peers.FinalizeLogin) e operador que lê fila falsa passa a
# ignorar fila inteira. Então: sinal fraco entra no score mas NUNCA abre flag
# sozinho; sinal médio abre fila (não punição); só violação determinística gera
# ação automática, e a ação automática é protetiva (segurar payout de referral),
# reversível e nunca ban.
#
# ------------------------------------------------------------------ matriz de severidade
# kind                 | peso | por quê
# ---------------------|------|-------------------------------------------------
# ip_shared            |  1   | CGNAT residencial/móvel agrupa estranhos no mesmo
#                      |      | IP o dia todo; sozinho nunca passa de 1 (limiar 2)
# subnet_shared        |  1   | /24 então agrupa cidade inteira; mesmo teto do ip
# device_shared        |  1   | mesma instalação SEM produção sobreposta = família
#                      |      | dividindo PC / NGM — normal, não é fraude
# trade_burst          |  2   | rajada de trades/dia (heurística v1, preservada)
# flip_trade           |  2   | compra+vende o mesmo item <1h (laundering/RMT)
# level_velocity       |  2   | níveis ganhos rápido demais p/ o meta declarado
# reports_cluster      |  2   | ≥3 denunciantes DISTINTOS na mesma conta em 7d
# referral_ring        |  2   | inviter+invitee logando na MESMA instalação no
#                      |      | resgate do bônus — fecha o vetor trivial da escada
# device_overlap       |  3   | mesma instalação E produção de valor sobreposta
#                      |      | (settle/levelup/trade a <1h um do outro) — farming
#                      |      | de multi-conta de verdade, não sofá de família
# chargeback_shortfall |  3   | o provedor tomou o dinheiro e o clawback NÃO achou
#                      |      | gem paga suficiente: rombo de caixa determinado pelo
#                      |      | próprio ledger (pedido menos tomado), não heurística.
#                      |      | Alta porque é perda real e fechada; não é 4 porque
#                      |      | nada aqui foi escrito por fora do caminho único.
# ledger_divergent     |  4   | carteira abaixo do saldo que o próprio ledger
#                      |      | atesta: conservação violada é FATO, não heurística
#
# Score composto (ComposeScore): pesos 2+ somam; os fracos (1) somam entre si mas
# são CAPADOS em 1 no total — IP + /24 + dispositivo em família = 1, nunca 3.
# Limiar de abertura: FlagScoreThreshold = 2. Consequências mensuráveis:
#   ip_shared isolado ......................... 1 → sem flag   (prova FP-1)
#   device_shared isolado (família/NGM) ....... 1 → sem flag   (prova FP-2)
#   ip_shared + subnet_shared + device_shared . 1 → sem flag   (prova FP-3)
#   trade_burst isolado ....................... 2 → flag média (paridade com v1)
#   device_overlap isolado .................... 3 → flag alta  (prova TP-1)
#   ledger_divergent .......................... 4 → flag crítica + hold protetor
#
# Revisão (ReviewFlag): 'dismissed' registra falso-positivo — o detector não
# reabre a mesma (conta, kind) por ReopenCooldownSec, senão descartar hoje e
# reabrir amanhã é a máquina de fazer fila infinita — e limpa o hold protetor se
# ele nascia só desta flag. 'reviewed' = problema real confirmado: hold continua
# e QUALQUER punição (ban/mute) é decisão humana explícita em outro comando
# (/ban, /mute); nenhuma linha deste arquivo chama BanAccount/BanIPRange, e o
# harness tests/fraud_test.gd varre sources/ para garantir que ninguém liga
# automação punitiva por engano.

# ------------------------------------------------------------------ calibração
const FlagScoreThreshold : int = 2			# fraco (1) não abre; médio (2) abre fila
const WeakSignalCap : int = 1				# teto da soma dos sinais de peso 1
const FingerprintWindowSec : int = 7 * 86400	# janela dos eventos de login com fp
const ProductionOverlapSec : int = 3600		# produção "sobreposta" = <1h apart
const IPWindowSec : int = 7 * 86400
const SubnetMinAccounts : int = 4			# /24 só vira evidência com 4+ contas
const ReportClusterMin : int = 3			# denunciantes distintos p/ reports_cluster
const ReopenCooldownSec : int = 30 * 86400	# descarte proteje contra re-flag 30d
const ReferralQualifySec : int = 5 * 86400	# bônus espera a indicada ter 5 dias
const ReferralLifetimeCap : int = 25		# tetos por inviter, além do semanal
const ReferralRingWindowSec : int = 7 * 86400

const SignalWeights : Dictionary = {
	"ip_shared": 1,
	"subnet_shared": 1,
	"device_shared": 1,
	"trade_burst": 2,
	"flip_trade": 2,
	"level_velocity": 2,
	"reports_cluster": 2,
	"referral_ring": 2,
	"device_overlap": 3,
	"chargeback_shortfall": 3,
	"ledger_divergent": 4,
}

var _eco : EconomyService = null

# ------------------------------------------------------------------ matriz pura
static func WeightOf(signalKind : String) -> int:
	return int(SignalWeights.get(signalKind, 0))

static func SeverityOfWeight(weight : int) -> String:
	if weight >= 4:
		return "critical"
	if weight >= 3:
		return "high"
	if weight >= 2:
		return "medium"
	return "low"

static func SeverityOfKinds(kinds : Array) -> String:
	var top : int = 0
	for kind in kinds:
		top = maxi(top, WeightOf(str(kind)))
	return SeverityOfWeight(top)

# Dominante = maior peso, empate por ordem alfabética (estável: a flag precisa
# ter UM kind determinístico para o dedupe de reabertura funcionar).
static func DominantKind(kinds : Array) -> String:
	var best : String = ""
	var bestWeight : int = -1
	var sorted : Array = kinds.duplicate()
	sorted.sort()
	for kind in sorted:
		var w : int = WeightOf(str(kind))
		if w > bestWeight:
			bestWeight = w
			best = str(kind)
	return best

# Score composto com cap de fraqueza (ver tabela no cabeçalho).
static func ComposeScore(kinds : Array) -> int:
	var seen : Dictionary = {}
	var strong : int = 0
	var weak : int = 0
	for kind in kinds:
		var key : String = str(kind)
		if seen.has(key) or not SignalWeights.has(key):
			continue
		seen[key] = true
		var w : int = int(SignalWeights[key])
		if w >= 2:
			strong += w
		else:
			weak += w
	return strong + mini(weak, WeakSignalCap)

static func ShouldOpen(score : int) -> bool:
	return score >= FlagScoreThreshold

static func SubnetOf(ip : String) -> String:
	var parts : PackedStringArray = ip.strip_edges().split(".")
	if parts.size() != 4:
		return ""
	for octet in parts:
		if not octet.is_valid_int() or int(octet) < 0 or int(octet) > 255:
			return ""
	return "%s.%s.%s.*" % [parts[0], parts[1], parts[2]]

static func WhyOf(signalKind : String) -> String:
	match signalKind:
		"ip_shared": return "mesmo IP público de login em 2+ contas (7d) — FRACO: CGNAT residencial/móvel é normal"
		"subnet_shared": return "mesmo /24 em 4+ contas (7d) — FRACO: operadora agrupa cidade inteira"
		"device_shared": return "mesma instalação sem produção sobreposta — FRACO: família/NGM dividido"
		"trade_burst": return "rajada de trades em 24h acima da régua v1"
		"flip_trade": return "mesmo item devolvido em <1h (padrão laundering/RMT)"
		"level_velocity": return "saltos de nível rápidos demais para o meta declarado"
		"reports_cluster": return "3+ denunciantes distintos na mesma conta em 7d"
		"referral_ring": return "inviter e invitee logando na mesma instalação no resgate do bônus"
		"device_overlap": return "mesma instalação COM produção de valor sobreposta (<1h) — multi-conta de farming"
		"chargeback_shortfall": return "chargeback do provedor sem gem paga suficiente para reverter: débito parcial/zero, diferença é prejuízo contável"
		"ledger_divergent": return "carteira abaixo do saldo que o próprio ledger atesta — conservação violada (determinístico)"
	return "sinal desconhecido"

static func ActionDoc(status : String) -> String:
	match status:
		"reviewed":
			return "problema confirmado na revisão; hold de referral (se havia) CONTINUA e qualquer punição é decisão humana explícita em /ban ou /mute — revisão nunca pune sozinha"
		"dismissed":
			return "falso-positivo registrado; o detector não reabre a mesma (conta,kind) por 30 dias e o hold protetor de referral desta conta é limpo salvo outra flag crítica aberta"
	return ""

# ------------------------------------------------------------------ evidência bruta
# Producer do sinal FRACO de IP. Hook em Peers.FinalizeLogin é PENDÊNCIA de dona
# de arquivo (Peers.gd é proibido nesta rodada); sem ele esta tabela fica vazia
# e o detector segue sem evidência de IP — ausência nunca vira flag.
func NoteLoginIP(accountID : int, ip : String, now : int = 0) -> bool:
	if accountID <= 0 or ip.strip_edges().is_empty():
		return false
	var ts : int = now if now > 0 else SQLCommons.Timestamp()
	return Launcher.SQL.ExecuteBindings("INSERT INTO login_ip_event (account_id, ip, subnet, created_at) VALUES (?, ?, ?, ?);", [accountID, ip.strip_edges(), SubnetOf(ip), ts])

# ------------------------------------------------------------------ scan composto
# Roda no job diário (CommunityService.RunFraudScan → TournamentArenaService.
# RunReconcileJob). Lê evidências, compõe score POR CONTA e abre no máximo uma
# flag por conta por passada. `now` injetável para o harness calibrar relógio.
func Scan(now : int = 0) -> Dictionary:
	var ts : int = now if now > 0 else SQLCommons.Timestamp()
	var signals : Dictionary = {}	# account_id -> Array[String de kinds]
	var details : Dictionary = {}	# account_id -> Array[notas por kind]
	_CollectFingerprintSignals(ts, signals, details)
	_CollectIPSignals(ts, signals)
	_CollectMediumHeuristics(ts, signals, details)
	_CollectReportCluster(ts, signals)
	_CollectLedgerDivergence(ts, signals)
	var opened : int = 0
	var openedByKind : Dictionary = {}
	var accounts : Array = signals.keys()
	accounts.sort()
	for accountKey in accounts:
		var accountID : int = int(accountKey)
		if _IsGhostAccount(accountID):
			continue
		var kinds : Array = signals[accountID]
		var score : int = ComposeScore(kinds)
		if not ShouldOpen(score):
			continue
		var kind : String = DominantKind(kinds)
		var detail : String = "score=%d/%d %s" % [score, FlagScoreThreshold, "+".join(PackedStringArray(kinds))]
		if details.has(accountID):
			detail += " | " + "; ".join(PackedStringArray(details[accountID]))
		var evidence : String = JSON.stringify({"signals": kinds, "score": score, "threshold": FlagScoreThreshold, "why": _WhyMap(kinds)})
		if OpenFlag(accountID, kind, SeverityOfKinds(kinds), score, detail, evidence, ts):
			opened += 1
			openedByKind[kind] = int(openedByKind.get(kind, 0)) + 1
		# Única automação punitiva-de-dinheiro possível aqui: determinística.
		if kinds.has("ledger_divergent"):
			Launcher.SQL.ExecuteBindings("UPDATE account SET referral_hold = 1 WHERE account_id = ? AND referral_hold = 0;", [accountID])
	return {"accounts_evaluated": signals.size(), "flags_opened": opened, "opened_by_kind": openedByKind}

func _WhyMap(kinds : Array) -> Dictionary:
	var why : Dictionary = {}
	for kind in kinds:
		why[str(kind)] = WhyOf(str(kind))
	return why

# Conta anonimizada (DeleteAccountData → username 'deleted_%', SQL.gd:335) não
# é sujeito revisável nem evidência viva: ghosts nunca abrem flag, nunca dão
# hold e não contam como par de instalação/IP/denúncia. Sem isto, o LGPD
# hard-delete de um colega de casa geraria falso-positivo no sobrevivente.
func _IsGhostAccount(accountID : int) -> bool:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT username FROM account WHERE account_id = ?;", [accountID])
	return not rows.is_empty() and str(rows[0].get("username", "")).begins_with("deleted")

static func GhostClause(column : String) -> String:
	return " AND " + column + " NOT IN (SELECT account_id FROM account WHERE username LIKE 'deleted%')"

# Multi-conta verdadeiro: mesma instalação (fingerprint de cliente, migration
# 030) E produção de valor sobreposta. Mesma instalação sem sobreposição é o
# sofá de família / o teclado do NGM → peso 1, nunca abre flag.
func _CollectFingerprintSignals(now : int, signals : Dictionary, details : Dictionary) -> void:
	var byFP : Dictionary = {}
	for row in Launcher.SQL.QueryBindings("SELECT fingerprint, account_id FROM telemetry_event WHERE kind = 'login' AND fingerprint != '' AND account_id > 0 AND created_at >= ?" + GhostClause("account_id") + " GROUP BY fingerprint, account_id;", [now - FingerprintWindowSec]):
		var fp : String = str(row["fingerprint"])
		if not byFP.has(fp):
			byFP[fp] = []
		byFP[fp].append(int(row["account_id"]))
	for fp in byFP:
		var accounts : Array = byFP[fp]
		if accounts.size() < 2:
			continue
		var overlap : Dictionary = _ProductionOverlap(accounts, now)
		for accountID in accounts:
			var acct : int = int(accountID)
			if overlap.has(acct):
				_PushSignal(signals, acct, "device_overlap")
				var other : int = int(overlap[acct])
				_PushDetail(details, acct, "fp=%s overlap_acct=%d (<%ds)" % [str(fp).left(12), other, ProductionOverlapSec])
			else:
				_PushSignal(signals, acct, "device_shared")

# Pares de contas cujos eventos de produção (settle/levelup/trade) acontecem a
# menos de ProductionOverlapSec um do outro. Volta account_id -> outro da mesma
# instalação; só o primeiro par de cada instalação basta para a severidade.
func _ProductionOverlap(accounts : Array, now : int) -> Dictionary:
	var times : Dictionary = {}
	var idList : PackedStringArray = PackedStringArray()
	for accountID in accounts:
		idList.append(str(int(accountID)))
	for row in Launcher.SQL.QueryBindings("SELECT account_id, created_at FROM telemetry_event WHERE account_id IN (%s) AND kind IN ('settle','levelup','trade') AND created_at >= ?" % ", ".join(idList) + GhostClause("account_id") + " ORDER BY created_at;", [now - FingerprintWindowSec]):
		var acct : int = int(row["account_id"])
		if not times.has(acct):
			times[acct] = []
		times[acct].append(int(row["created_at"]))
	var overlap : Dictionary = {}
	var ids : Array = times.keys()
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			if overlap.has(ids[i]) and overlap.has(ids[j]):
				continue
			if _TimesWithin(times[ids[i]], times[ids[j]], ProductionOverlapSec):
				if not overlap.has(ids[i]):
					overlap[ids[i]] = ids[j]
				if not overlap.has(ids[j]):
					overlap[ids[j]] = ids[i]
	return overlap

static func _TimesWithin(timesA : Array, timesB : Array, windowSec : int) -> bool:
	for a in timesA:
		for b in timesB:
			if absi(int(a) - int(b)) <= windowSec:
				return true
	return false

# Sinal FRACO só existe se houver produção de IP por login (hook pendente).
# Mesmo IP com 2+ contas → ip_shared; /24 com 4+ → subnet_shared. Ambos peso 1
# e capificados — duas contas legítimas no mesmo IP NUNCA geram flag daqui.
func _CollectIPSignals(now : int, signals : Dictionary) -> void:
	var byIP : Dictionary = {}
	for row in Launcher.SQL.QueryBindings("SELECT ip, account_id FROM login_ip_event WHERE created_at >= ?" + GhostClause("account_id") + " GROUP BY ip, account_id;", [now - IPWindowSec]):
		var ip : String = str(row["ip"])
		if not byIP.has(ip):
			byIP[ip] = []
		byIP[ip].append(int(row["account_id"]))
	for ip in byIP:
		if (byIP[ip] as Array).size() >= 2:
			for accountID in byIP[ip]:
				_PushSignal(signals, int(accountID), "ip_shared")
	var bySubnet : Dictionary = {}
	for row in Launcher.SQL.QueryBindings("SELECT subnet, account_id FROM login_ip_event WHERE subnet != '' AND created_at >= ?" + GhostClause("account_id") + " GROUP BY subnet, account_id;", [now - IPWindowSec]):
		var subnet : String = str(row["subnet"])
		if not bySubnet.has(subnet):
			bySubnet[subnet] = []
		bySubnet[subnet].append(int(row["account_id"]))
	for subnet in bySubnet:
		if (bySubnet[subnet] as Array).size() >= SubnetMinAccounts:
			for accountID in bySubnet[subnet]:
				_PushSignal(signals, int(accountID), "subnet_shared")

# Heurísticas v1 (preservadas de CommunityService.gd, agora como peso 2 — antes
# abriam flag binária; hoje abrem fila de revisão com severidade média).
func _CollectMediumHeuristics(now : int, signals : Dictionary, details : Dictionary) -> void:
	for row in Launcher.SQL.QueryBindings("SELECT account_id, COUNT(*) AS n FROM ledger_transaction WHERE reason LIKE 'trade_out:%' AND created_at >= ? GROUP BY account_id HAVING n > ?;", [now - 86400, EconomyCatalog.FraudTradeBurstPerDay]):
		var acct : int = int(row["account_id"])
		_PushSignal(signals, acct, "trade_burst")
		_PushDetail(details, acct, "trades_24h=%d" % int(row["n"]))
	for row in Launcher.SQL.QueryBindings("SELECT account_id, char_id, value, meta FROM telemetry_event WHERE kind = 'levelup' AND created_at >= ? AND value >= ?;", [now - 86400, EconomyCatalog.FraudLevelJump]):
		var meta : Variant = JSON.parse_string(str(row.get("meta", "")))
		if meta is Dictionary and float((meta as Dictionary).get("hours", 99.0)) < EconomyCatalog.FraudLevelJumpHours:
			var acct : int = int(row["account_id"])
			_PushSignal(signals, acct, "level_velocity")
			_PushDetail(details, acct, "jump=%d levels in %sh" % [int(row["value"]), str((meta as Dictionary).get("hours", "?"))])
	# Flip = char enviou o item X e RECEBEU o mesmo X em <1h (padrão
	# laundering/RMT). Trade bilateral normal (X por Y) não casa: itens diferem.
	for row in Launcher.SQL.QueryBindings("SELECT account_id, char_id, reason, created_at FROM ledger_transaction WHERE reason LIKE 'trade_out:%' AND created_at >= ?;", [now - 86400]):
		var parts : PackedStringArray = str(row["reason"]).split(":")
		if parts.size() < 2:
			continue
		var item : String = parts[1]
		var back : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM ledger_transaction WHERE char_id = ? AND reason LIKE ? AND ABS(created_at - ?) < 3600 LIMIT 1;", [int(row["char_id"]), "trade_in:" + item + ":%", int(row["created_at"])])
		if not back.is_empty():
			var acct : int = int(row["account_id"])
			_PushSignal(signals, acct, "flip_trade")
			_PushDetail(details, acct, "item=%s" % item)

# O canal de denúncia (chat_report, migration 043) já é humano; 3+ denunciantes
# DISTINTOS na mesma conta viram peso 2 aqui — 1-2 denúncias ficam só na fila do
# /reports do moderador, sem tocar o detector (viração de denúncia é o vetor de
# assédio reverso, e o detector não pode ser arma de quem denuncia).
func _CollectReportCluster(now : int, signals : Dictionary) -> void:
	for row in Launcher.SQL.QueryBindings("SELECT reported_account AS account_id, COUNT(DISTINCT reporter_account) AS n FROM chat_report WHERE status = 'open' AND created_ts >= ?" + GhostClause("reported_account") + GhostClause("reporter_account") + " GROUP BY reported_account HAVING n >= ?;", [now - 7 * 86400, ReportClusterMin]):
		_PushSignal(signals, int(row["account_id"]), "reports_cluster")

# Determinístico: carteira ABAIXO do saldo que o próprio ledger atesta (a mesma
# régua do ReconcileWalletDaily do kernel, por conta). Acima não é divergência —
# é faucet F2P ainda não ledgerado? Não: o reconcile oficial compara só neste
# sentido, e é ele que o job diário já roda; aqui a diferença é apontar A CONTA,
# não o total, para virar fila + hold protetor.
func _CollectLedgerDivergence(now : int, signals : Dictionary) -> void:
	# Última linha da série, e `created_at >= account.created_timestamp`: as duas
	# condições que o ReconcileWalletDaily do kernel já usam. O MAX flagava quem
	# qualquer já gastou (medido na base do harness: 4 contas contra 1 real), e
	# sem o guard do timestamp a carteira nova de um id reciclado por purge LGPD
	# entrava na fila de revisão como suspeita.
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT w.account_id FROM wallet w INNER JOIN account a ON a.account_id = w.account_id WHERE w.gems < COALESCE((SELECT l.balance_after FROM ledger_transaction l WHERE l.account_id = w.account_id AND l.kind = ? AND l.created_at >= a.created_timestamp ORDER BY l.id DESC LIMIT 1), 0) AND w.gems >= 0;", [EconomyCatalog.LedgerKindGems])
	for row in rows:
		_PushSignal(signals, int(row["account_id"]), "ledger_divergent")

func _PushSignal(signals : Dictionary, accountID : int, kind : String) -> void:
	if not signals.has(accountID):
		signals[accountID] = []
	if not (signals[accountID] as Array).has(kind):
		signals[accountID].append(kind)

func _PushDetail(details : Dictionary, accountID : int, note : String) -> void:
	if not details.has(accountID):
		details[accountID] = []
	details[accountID].append(note)

# ------------------------------------------------------------------ escrita da fila
func OpenFlag(accountID : int, kind : String, severity : String, score : int, detail : String, evidence : String, now : int = 0) -> bool:
	if accountID <= 0 or kind.is_empty():
		return false
	var ts : int = now if now > 0 else SQLCommons.Timestamp()
	return _InsertFlag(accountID, 0, kind, severity, score, detail, evidence, ts)

# Dedupe com MEMÓRIA DE DESCARTE: 'open' não reabre; 'dismissed' só reabre depois
# do cooldown (senão descartar é inútil — a mesma heurística recria a flag na
# manhã seguinte e a fila volta a ser folklore); 'reviewed' (problema real) pode
# reabrir: a conduta continuou.
func _InsertFlag(accountID : int, charID : int, kind : String, severity : String, score : int, detail : String, evidence : String, ts : int) -> bool:
	var dup : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM fraud_flag WHERE account_id = ? AND kind = ? AND (status = 'open' OR (status = 'dismissed' AND created_at >= ?)) LIMIT 1;", [accountID, kind, ts - ReopenCooldownSec])
	if not dup.is_empty():
		return false
	return Launcher.SQL.ExecuteBindings("INSERT INTO fraud_flag (created_at, account_id, char_id, kind, detail, status, severity, score, evidence) VALUES (?, ?, ?, ?, ?, 'open', ?, ?, ?);", [ts, accountID, charID, kind, detail, severity, score, evidence])

# API do laço antigo (EconomyService.FlagMultiAccount → CommunityService): manual
# (companion/operador aponta a instalação compartilhada) e entra já na severidade
# forte, porque quem chama isto traz a sobreposição como premissa no `detail`.
func FlagMultiAccount(accountID : int, detail : String) -> bool:
	if accountID <= 0 or detail.is_empty():
		return false
	return OpenFlag(accountID, "multi_account", "high", WeightOf("device_overlap"), detail, JSON.stringify({"signals": ["device_overlap"], "score": WeightOf("device_overlap"), "threshold": FlagScoreThreshold, "why": {"multi_account": "sinal externo apontando instalação compartilhada com produção sobreposta"}}))

# P1-6b (chargeback): o provedor já levou o dinheiro e o clawback do jogo só pode
# tomar o que ainda é gem paga — o resto virou consumo legítimo do jogador. A
# diferença não é heurística e não é opinião: é `pedido - tomado`, e é ela que tem
# de aparecer para alguém com caneta. Daí esta função ser a ÚNICA porta do rombo:
# o checkout (CheckoutService) traz o número e o detector decide kind/severidade/
# score pelo mesmo mapa de todo sinal, em vez de cada domínio escrever
# `INSERT INTO fraud_flag` pela própria conta (guard: tests/fraud_test.gd S-G).
#
# Dedupe é o do OpenFlag (uma flag 'open' por conta+kind): cinco shortfalls da
# MESMA conta não viram cinco linhas na fila, e é por isso que o rombo por payment
# também mora em `grant_queue.error` + no ledger - nada se perde ao colapsar.
func ChargebackShortfall(accountID : int, paymentID : String, requested : int, debited : int, sku : String, grantID : int = 0) -> bool:
	if accountID <= 0 or paymentID.is_empty() or debited >= requested:
		return false
	var kind : String = ReasonCodes.ChargebackShortfall
	var missing : int = requested - debited
	var detail : String = "%s: payment=%s pedido=%d tomado=%d faltando=%d" % [kind, paymentID, requested, debited, missing]
	var evidence : String = JSON.stringify({
		"signals": [kind], "score": ComposeScore([kind]), "threshold": FlagScoreThreshold,
		"why": {kind: WhyOf(kind)}, "payment_id": paymentID, "sku": sku,
		"requested": requested, "debited": debited, "missing": missing, "grant_id": grantID})
	return OpenFlag(accountID, kind, SeverityOfWeight(WeightOf(kind)), ComposeScore([kind]), detail, evidence)

# ------------------------------------------------------------------ fila de revisão
func ListFlagsPaged(status : String, page : int = 1, perPage : int = 10) -> Dictionary:
	var cap : int = clampi(perPage, 1, 50)
	var pg : int = maxi(1, page)
	var totals : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM fraud_flag WHERE status = ?;", [status])
	var total : int = int(totals[0].get("n", 0)) if not totals.is_empty() else 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, created_at, account_id, char_id, kind, detail, status, severity, score, evidence, reviewed_by, reviewed_at, review_note FROM fraud_flag WHERE status = ? ORDER BY score DESC, id DESC LIMIT ? OFFSET ?;", [status, cap, (pg - 1) * cap])
	return {"ok": true, "status": status, "page": pg, "per_page": cap, "total": total, "pages": int(ceil(float(total) / float(cap))), "threshold": FlagScoreThreshold, "rows": rows}

func GetFlag(flagID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, created_at, account_id, char_id, kind, detail, status, severity, score, evidence, reviewed_by, reviewed_at, review_note FROM fraud_flag WHERE id = ?;", [flagID])
	return {} if rows.is_empty() else rows[0]

# Revisão de verdade: só flag aberta fecha, o revisador fica registrado, e o
# efeito colateral documentado acontece (dismissed limpa hold; reviewed mantém).
func ReviewFlag(flagID : int, status : String, reviewerAccountID : int, note : String = "") -> Dictionary:
	if flagID <= 0 or reviewerAccountID <= 0:
		return {"ok": false, "reason": "bad_args"}
	if status != "reviewed" and status != "dismissed":
		return {"ok": false, "reason": "bad_status"}
	var flag : Dictionary = GetFlag(flagID)
	if flag.is_empty():
		return {"ok": false, "reason": "not_found"}
	if str(flag.get("status", "")) != "open":
		return {"ok": false, "reason": "already_closed"}
	var ts : int = SQLCommons.Timestamp()
	var cleanNote : String = note.strip_edges().left(240)
	if not Launcher.SQL.ExecuteBindings("UPDATE fraud_flag SET status = ?, reviewed_by = ?, reviewed_at = ?, review_note = ? WHERE id = ? AND status = 'open';", [status, reviewerAccountID, ts, cleanNote, flagID]):
		return {"ok": false, "reason": "db_error"}
	if status == "dismissed":
		_ClearProtectiveHold(int(flag["account_id"]), flagID)
	return {"ok": true, "reason": "ok", "flag": flagID, "status": status, "reviewed_by": reviewerAccountID, "what_happened": ActionDoc(status)}

func _ClearProtectiveHold(accountID : int, dismissedFlagID : int) -> void:
	if accountID <= 0:
		return
	var still : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM fraud_flag WHERE account_id = ? AND kind = 'ledger_divergent' AND status = 'open' AND id != ? LIMIT 1;", [accountID, dismissedFlagID])
	if not still.is_empty():
		return
	Launcher.SQL.ExecuteBindings("UPDATE account SET referral_hold = 0 WHERE account_id = ?;", [accountID])

# Contexto do acusado para o operador decidir sem SQL: quem é, o que tem aberto,
# o sinal que disparou (e o porquê congelado no evidence) e o saldo do ledger.
func FlagContext(flagID : int) -> Dictionary:
	var flag : Dictionary = GetFlag(flagID)
	if flag.is_empty():
		return {"ok": false, "reason": "not_found"}
	var accountID : int = int(flag["account_id"])
	var now : int = SQLCommons.Timestamp()
	var out : Dictionary = {"ok": true, "flag": flag}
	var parsed : Variant = JSON.parse_string(str(flag.get("evidence", "")))
	out["signals"] = parsed if parsed is Dictionary else {}
	var accounts : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT username, email, email_verified, created_timestamp, referral_hold, referred_by, referral_bonus_claimed, permission, status FROM account WHERE account_id = ?;", [accountID])
	if not accounts.is_empty():
		var acct : Dictionary = accounts[0]
		acct["age_days"] = int((now - int(acct.get("created_timestamp", now))) / 86400)
		acct["email"] = "***"			# LGPD: o operador vê VERIFICADO, não o e-mail
		out["accused"] = acct
	var openFlags : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, kind, severity, score FROM fraud_flag WHERE account_id = ? AND status = 'open' AND id != ? ORDER BY score DESC, id;", [accountID, flagID])
	out["other_open_flags"] = openFlags
	var wallets : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT gems, gems_paid FROM wallet WHERE account_id = ?;", [accountID])
	if not wallets.is_empty():
		out["wallet"] = wallets[0]
	out["recent_ledger"] = Launcher.SQL.SearchLedger(accountID, 5)
	out["action_semantics"] = {"reviewed": ActionDoc("reviewed"), "dismissed": ActionDoc("dismissed")}
	out["threshold"] = FlagScoreThreshold
	return out

# ------------------------------------------------------------------ métricas de revisão
# Contadores FIXOS do detector (o beta não sabe se está calibrado sem isto):
# abertura por severidade, descarte/dia (falsos positivos), tempo médio de
# revisão e taxa de falso-positivo da janela. Tudo derivado da fila — nada é
# escrito aqui; o publish vai para telemetry_event (kind 'fraud_metrics'), a
# mesma fonte que o /metrics do companion já lê.
func Metrics(now : int = 0) -> Dictionary:
	var ts : int = now if now > 0 else SQLCommons.Timestamp()
	var dayStart : int = ts - (ts % 86400)
	var weekAgo : int = ts - 7 * 86400
	var monthAgo : int = ts - 30 * 86400
	var bySeverity : Dictionary = {"low": 0, "medium": 0, "high": 0, "critical": 0}
	for row in Launcher.SQL.QueryBindings("SELECT severity, COUNT(*) AS n FROM fraud_flag WHERE status = 'open' GROUP BY severity;", []):
		bySeverity[str(row["severity"])] = int(row["n"])
	var openedToday : int = _Scalar("SELECT COUNT(*) AS n FROM fraud_flag WHERE created_at >= ?;", [dayStart])
	var dismissedToday : int = _Scalar("SELECT COUNT(*) AS n FROM fraud_flag WHERE status = 'dismissed' AND reviewed_at >= ?;", [dayStart])
	var dismissed7d : int = _Scalar("SELECT COUNT(*) AS n FROM fraud_flag WHERE status = 'dismissed' AND reviewed_at >= ?;", [weekAgo])
	var reviewed7d : int = _Scalar("SELECT COUNT(*) AS n FROM fraud_flag WHERE status = 'reviewed' AND reviewed_at >= ?;", [weekAgo])
	var openNow : int = _Scalar("SELECT COUNT(*) AS n FROM fraud_flag WHERE status = 'open';", [])
	var avgRow : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT AVG(reviewed_at - created_at) AS a FROM fraud_flag WHERE status IN ('reviewed','dismissed') AND reviewed_at >= ? AND reviewed_at > created_at;", [monthAgo])
	var avgReviewSec : float = float(avgRow[0].get("a", 0.0)) if not avgRow.is_empty() and avgRow[0].get("a", null) != null else 0.0
	var closes7d : int = dismissed7d + reviewed7d
	var fpRate : float = float(dismissed7d) / float(closes7d) if closes7d > 0 else 0.0
	return {
		"open_flags": openNow,
		"open_by_severity": bySeverity,
		"opened_today": openedToday,
		"false_positives_today": dismissedToday,
		"dismissed_7d": dismissed7d,
		"reviewed_7d": reviewed7d,
		"false_positive_rate_7d": fpRate,
		"avg_review_sec_30d": int(avgReviewSec),
		"threshold": FlagScoreThreshold,
		"reopen_cooldown_days": ReopenCooldownSec / 86400,
	}

func _Scalar(sql : String, params : Array) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(sql, params)
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

func RecordMetricsTelemetry(now : int = 0) -> bool:
	var ts : int = now if now > 0 else SQLCommons.Timestamp()
	var metrics : Dictionary = Metrics(ts)
	if Launcher.Telemetry != null and Launcher.Telemetry.has_method("Record"):
		Launcher.Telemetry.Record("fraud_metrics", 0, 0, int(metrics.get("open_flags", 0)), JSON.stringify(metrics))
		# O dashboard não pode esperar o flush de 60 s do ciclo normal: métrica de
		# revisão é escrita no mesmo job que acabou de calcular a fila.
		if Launcher.Telemetry.has_method("Flush"):
			Launcher.Telemetry.Flush()
		return true
	return Launcher.SQL.ExecuteBindings("INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta, fingerprint) VALUES (?, 0, 0, 'fraud_metrics', ?, ?, '');", [ts, int(metrics.get("open_flags", 0)), JSON.stringify(metrics)])

# ------------------------------------------------------------------ guarda de referral
# O payout antigo (CommunityService.GrantReferralBonuses) premiava a PAR indistinta
# — auto-indicação direta já era barrada, mas a escada (A→B→A), conta recém-nascida
# farmando o marco e o mesmo fingerprint resgatando bônus em série passavam. Estes
# tetos moram aqui; a execução do pagamento continua no CommunityService.

# Ciclo de indicação (A→B→A ou escada longa): caminha referred_by a partir de
# `inviterID` e recusa se a corrente voltar para `accountID`.
func IsSelfLadder(accountID : int, inviterID : int) -> bool:
	if accountID <= 0 or inviterID <= 0:
		return false
	var cursor : int = inviterID
	for hop in 5:
		if cursor == accountID:
			return true
		var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT referred_by FROM account WHERE account_id = ?;", [cursor])
		if rows.is_empty():
			return false
		cursor = int(rows[0].get("referred_by", 0))
		if cursor <= 0:
			return false
	return cursor == accountID

# Porta do payout no job diário. Tudo que bloqueia aqui é PROTETIVO: o bônus não
# é perdido, fica para uma passada futura (maturidade chega, janela de fingerprint
# passa, review limpa o hold). `reason` é estável — os testes amarram a porta,
# não a frase.
func ReferralGuard(inviterID : int, inviteeID : int, now : int = 0) -> Dictionary:
	var ts : int = now if now > 0 else SQLCommons.Timestamp()
	var invitee : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT created_timestamp, referral_hold FROM account WHERE account_id = ?;", [inviteeID])
	if invitee.is_empty():
		return {"allow": false, "reason": "unknown_invitee"}
	if ts - int(invitee[0].get("created_timestamp", ts)) < ReferralQualifySec:
		return {"allow": false, "reason": "immature"}
	if int(invitee[0].get("referral_hold", 0)) != 0:
		return {"allow": false, "reason": "hold"}
	var inviter : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT referral_hold FROM account WHERE account_id = ?;", [inviterID])
	if inviter.is_empty() or int(inviter[0].get("referral_hold", 0)) != 0:
		return {"allow": false, "reason": "hold"}
	var lifetime : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE ?;", [inviterID, "referral_bonus:" + str(inviterID) + ":%"])
	if not lifetime.is_empty() and int(lifetime[0].get("n", 0)) >= ReferralLifetimeCap:
		return {"allow": false, "reason": "lifetime_cap"}
	# Ring: as duas pontas logando na MESMA instalação dentro da janela. No sofá
	# de família isso acontece — por isso bloqueia o payout desta passada e abre
	# FILA (peso 2, revisável), nunca punição: na passada seguinte, com a janela
	# de login fora do arco, o bônus legítimo sai sozinho.
	var ring : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM telemetry_event a JOIN telemetry_event b ON a.fingerprint = b.fingerprint WHERE a.account_id = ? AND b.account_id = ? AND a.kind = 'login' AND b.kind = 'login' AND a.fingerprint != '' AND a.created_at >= ? AND b.created_at >= ?;", [inviterID, inviteeID, ts - ReferralRingWindowSec, ts - ReferralRingWindowSec])
	if not ring.is_empty() and int(ring[0].get("n", 0)) > 0:
		OpenFlag(inviterID, "referral_ring", SeverityOfWeight(WeightOf("referral_ring")), ComposeScore(["referral_ring"]), "inviter=%d invitee=%d mesmo fingerprint no resgate" % [inviterID, inviteeID], JSON.stringify({"signals": ["referral_ring"], "score": ComposeScore(["referral_ring"]), "threshold": FlagScoreThreshold, "why": {"referral_ring": WhyOf("referral_ring")}}), ts)
		return {"allow": false, "reason": "ring"}
	return {"allow": true, "reason": "ok"}
