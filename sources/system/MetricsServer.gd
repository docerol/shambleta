extends ServiceBase
class_name MetricsServer

# SOM-IDLE L1: health e métricas do server de jogo (HTTP/1.0, loopback).
#
# O contrato de deploy já existia antes deste arquivo: `deploy/docker-compose.yml`
# faz `curl -f http://localhost:9400/healthz` e o serviço `web` só sobe com
# `depends_on: game: condition: service_healthy`. Nada escutava na 9400 (só o
# `.uid` de um MetricsServer nunca commitado tinha ficado no repositório), então
# o healthcheck falhava sempre e a stack do beta nunca ficava healthy.
#
# Escopo deliberado: nada de painel, nada de escrita, nada de métrica nova que
# exija instrumentação — só o que os serviços já sabem. O `/metrics` do companion
# (porta 8901) continua sendo o dashboard financeiro; este aqui é o probe de
# processo vivo + fila de grants presa. Desde a P1-ANALYTICS/OPS-4 também é o
# LEITOR dos dois agregados que existiam sem consumo: o funil diário de receita
# (`TelemetryService.FunnelDaily` → `FunnelGaugeLines`) e a agenda declarativa de
# live ops (`LiveOpsCalendar.GaugeLines`) — nenhuma instrumentação nova, só o
# que já era calculado e não saia do processo.
#
# Segurança: bind exclusivo em 127.0.0.1, sem TLS e sem auth — igual ao
# /metrics do companion. Não pode ser exposto publicamente; leitura é por dentro
# do container (docker compose exec game curl localhost:9400/healthz).

const DefaultPort : int					= 9400
const BindAddress : String				= "127.0.0.1"
const RequestMaxBytes : int				= 4096
const ConnectionTimeoutSec : float		= 5.0
const FlushGraceSec : float				= 0.25
const MetricsCacheSec : int				= 5
# OPS-4 (Analytics): janela do funil diário que vai no scrape. Sete dias é a
# granularidade com que a doc de produto compara janelas de onboarding, e o
# `FunnelDaily` faz duas queries GROUP BY por chamada — com o cache de 5 s abaixo,
# o custo máximo é ~24 leituras por minuto, em reads `query_only` do pool.
const FunnelWindowDays : int			= 7

var listenPort : int					= DefaultPort
var listener : TCPServer				= TCPServer.new()
var listening : bool					= false
var openedAt : int						= 0

var metricsCache : String				= ""
var metricsCacheAt : int				= -1000

# Contrato da seção de telemetria: quantas vezes o funil foi calculado de
# verdade. Se a linha nunca anda, o anexo virou superstição (a métrica existe no
# código e ninguém a lê) — `tests/ops_fix_test.gd` amarra o contador, e um
# `null` aqui nunca acontece: sem serviço de telemetria a função devolve "".
var funnelSectionCalls : int			= 0
# Seam de teste (mesma ideia dos seams de `OfflineSettle`): o probe é um nó
# autoloado, então um harness `-s` injeta aqui a instância que ele mesmo sobe.
var telemetryService : TelemetryService	= null


# {peer: StreamPeerTCP, buf: String, deadline: float}
var reading : Array[Dictionary]			= []
# Respostas já escritas; aguardam a janela de flush antes do close.
var closing : Array[Dictionary]			= []

# Bind do probe. Falhar aqui NUNCA derruba o server: observabilidade é periférica,
# o jogo continua sem /healthz (e o operator vê o bind recusado no log).
func Launch(newPort : int = DefaultPort) -> bool:
	if listening:
		return true
	listenPort = newPort
	if listener.listen(newPort, BindAddress) != OK:
		push_warning("MetricsServer: bind %s:%d recusado — /healthz indisponível" % [BindAddress, newPort])
		return false
	listening = true
	isInitialized = true
	openedAt = int(Time.get_unix_time_from_system())
	return true

func Destroy() -> void:
	for entry in reading:
		(entry["peer"] as StreamPeerTCP).disconnect_from_host()
	for entry in closing:
		(entry["peer"] as StreamPeerTCP).disconnect_from_host()
	reading.clear()
	closing.clear()
	if listening:
		listener.stop()
	listening = false
	isInitialized = false

# O que o healthcheck responde: o server está de pé E servindo. Boot em andamento
# (SQL abrindo, mundo não carregado) é 503 — é exatamente o que start_period
# do compose existe para tolerar.
func IsServing() -> bool:
	if Launcher.SQL == null or not Launcher.SQL.isInitialized:
		return false
	if Network.WebSocketServer == null and Network.ENetServer == null:
		return false
	return true

func UptimeSeconds() -> int:
	if openedAt == 0:
		return 0
	return int(Time.get_unix_time_from_system()) - openedAt

func PlayersOnline() -> int:
	return OnlineList.GetPlayerNames().size()

func LoggedAccounts() -> int:
	var count : int = 0
	for value in Peers.accounts.values():
		if int(value) != NetworkCommons.PeerUnknownID:
			count += 1
	return count

# Grant queue é o sinal operacional que importa: linha presa = compra paga e não
# entregue. Contagem com TTL (scrape de healthcheck a cada 30s não justifica um
# COUNT por resposta, e a tabela cresce).
func MetricsBody() -> String:
	var now : int = int(Time.get_ticks_msec() / 1000)
	if now - metricsCacheAt < MetricsCacheSec and not metricsCache.is_empty():
		return metricsCache
	var pending : int = 0
	var failed : int = 0
	var refunded : int = 0
	var recDivergences : int = 0
	var recAge : int = -1
	var flagsOpen : int = 0
	var mutexWaits : int = 0
	var mutexWaitMicros : int = 0
	var mutexWaitMaxMicros : int = 0
	var mutexOver1ms : int = 0
	var mutexOver10ms : int = 0
	var mutexOver100ms : int = 0
	if Launcher.SQL != null and Launcher.SQL.isInitialized:
		var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT status, COUNT(*) AS n FROM grant_queue WHERE status IN ('pending','processing','failed','refunded') GROUP BY status;", [])
		for row in rows:
			var n : int = int(row["n"])
			match str(row["status"]):
				"pending", "processing":
					pending += n
				"failed":
					failed += n
				"refunded":
					refunded += n
		# O reconcile de carteira/arena já contava divergência e o número morava
		# só em `reconcile_run`, tabela que ninguém scrapeia. Sem sair daqui ele não
		# é alerta, é arquivo morto: quem tem que decidir se acorda às 3h não vê.
		# A IDADE vai junto de propósito — "0 divergências" vindo de um run de seis
		# semanas atrás lê como verde e não é; o sinal que importa é o job parado.
		var rec : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT created_at, divergences FROM reconcile_run ORDER BY id DESC LIMIT 1;", [])
		if not rec.is_empty():
			recDivergences = int(rec[0].get("divergences", 0))
			recAge = int(Time.get_unix_time_from_system()) - int(rec[0].get("created_at", 0))
		var ff : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM fraud_flag WHERE status = 'open';", [])
		if not ff.is_empty():
			flagsOpen = int(ff[0].get("n", 0))
		# ESCALABILIDADE: `queryMutex` é o serializador de todo round trip do processo
		# (sources/sql/SQL.gd:7) e até aqui não tinha sinal — `deploy/SCALING.md` mede o
		# teto do tick, mas o que encosta no teto primeiro é a espera, e espera sem
		# número é a hipótese que ninguém consegue refute num incidente. A média sozinha
		# não serve: um passe de backup de 400 ms numa média de 3 µs é apagado pela média
		# e sentido pelo jogador, por isso as caudas vão expostas em degrades.
		var waits : Dictionary = Launcher.SQL.QueryMutexWaitStats()
		mutexWaits = int(waits.get("waits", 0))
		mutexWaitMicros = int(waits.get("microseconds", 0))
		mutexWaitMaxMicros = int(waits.get("maxMicroseconds", 0))
		mutexOver1ms = int(waits.get("over1ms", 0))
		mutexOver10ms = int(waits.get("over10ms", 0))
		mutexOver100ms = int(waits.get("over100ms", 0))
	var body : String = ""
	body += "# HELP shambleta_up 1 quando o processo do server está servindo.\n"
	body += "# TYPE shambleta_up gauge\n"
	body += "shambleta_up %d\n" % (1 if IsServing() else 0)
	body += "# HELP shambleta_uptime_seconds desde o bind do próprio MetricsServer.\n"
	body += "# TYPE shambleta_uptime_seconds counter\n"
	body += "shambleta_uptime_seconds %d\n" % UptimeSeconds()
	body += "# HELP shambleta_players_online personagens no mundo.\n"
	body += "# TYPE shambleta_players_online gauge\n"
	body += "shambleta_players_online %d\n" % PlayersOnline()
	body += "# HELP shambleta_accounts_logged_in contas com sessão.\n"
	body += "# TYPE shambleta_accounts_logged_in gauge\n"
	body += "shambleta_accounts_logged_in %d\n" % LoggedAccounts()
	body += "# HELP shambleta_grant_queue_pending compras pagas aguardando crédito.\n"
	body += "# TYPE shambleta_grant_queue_pending gauge\n"
	body += "shambleta_grant_queue_pending %d\n" % pending
	body += "# HELP shambleta_grant_queue_failed grants que falharam (revisão manual).\n"
	body += "# TYPE shambleta_grant_queue_failed gauge\n"
	body += "shambleta_grant_queue_failed %d\n" % failed
	body += "# HELP shambleta_grant_queue_refunded grants estornados.\n"
	body += "# TYPE shambleta_grant_queue_refunded gauge\n"
	body += "shambleta_grant_queue_refunded %d\n" % refunded
	body += "# HELP shambleta_reconcile_divergences divergências do último reconcile (carteira+arena).\n"
	body += "# TYPE shambleta_reconcile_divergences gauge\n"
	body += "shambleta_reconcile_divergences %d\n" % recDivergences
	body += "# HELP shambleta_reconcile_age_seconds segundos desde o último reconcile; -1 = nunca rodou.\n"
	body += "# TYPE shambleta_reconcile_age_seconds gauge\n"
	body += "shambleta_reconcile_age_seconds %d\n" % recAge
	body += "# HELP shambleta_fraud_flags_open flags anti-fraude aguardando revisão humana.\n"
	body += "# TYPE shambleta_fraud_flags_open gauge\n"
	body += "shambleta_fraud_flags_open %d\n" % flagsOpen
	body += "# HELP shambleta_sql_query_mutex_waits round trips que passaram pela queryMutex.\n"
	body += "# TYPE shambleta_sql_query_mutex_waits counter\n"
	body += "shambleta_sql_query_mutex_waits %d\n" % mutexWaits
	body += "# HELP shambleta_sql_query_mutex_wait_seconds segundos acumulados esperando a queryMutex.\n"
	body += "# TYPE shambleta_sql_query_mutex_wait_seconds counter\n"
	body += "shambleta_sql_query_mutex_wait_seconds %.6f\n" % (float(mutexWaitMicros) / 1000000.0)
	body += "# HELP shambleta_sql_query_mutex_wait_max_seconds espera individual mais longa desde o boot.\n"
	body += "# TYPE shambleta_sql_query_mutex_wait_max_seconds gauge\n"
	body += "shambleta_sql_query_mutex_wait_max_seconds %.6f\n" % (float(mutexWaitMaxMicros) / 1000000.0)
	# As três caudas separadas porque a régua que um humano aplica é "um passe segurou
	# a mutex por mais de X": numa média isso não aparece, num degrade acumulado aparece.
	body += "# HELP shambleta_sql_query_mutex_wait_over_1ms esperas individuais acima de 1 ms.\n"
	body += "# TYPE shambleta_sql_query_mutex_wait_over_1ms counter\n"
	body += "shambleta_sql_query_mutex_wait_over_1ms %d\n" % mutexOver1ms
	body += "# HELP shambleta_sql_query_mutex_wait_over_10ms esperas individuais acima de 10 ms.\n"
	body += "# TYPE shambleta_sql_query_mutex_wait_over_10ms counter\n"
	body += "shambleta_sql_query_mutex_wait_over_10ms %d\n" % mutexOver10ms
	body += "# HELP shambleta_sql_query_mutex_wait_over_100ms esperas individuais acima de 100 ms — um jogador travado.\n"
	body += "# TYPE shambleta_sql_query_mutex_wait_over_100ms counter\n"
	body += "shambleta_sql_query_mutex_wait_over_100ms %d\n" % mutexOver100ms
	# OPS-4: o funil diário e a agenda de live ops entram AQUI porque este é o
	# único leitor dos dois dentro do processo de jogo. Uma métrica que nada serve
	# é uma métrica que ninguém pagina — `FunnelDaily`/`FunnelGaugeLines` e
	# `LiveOpsCalendar` já calculavam tudo e não havia saída. O bloco é anexado no
	# fim, depois dos nomes que `deploy/alerts.rules.yml` cita, então a regex de
	# nomes do `tests/deploy_ops_test.gd` (que lê este corpo) não se move.
	body += _funnelSection()
	body += _liveOpsSection()
	metricsCache = body
	metricsCacheAt = now
	return body

# O serviço de telemetria, com seam para harness (o autoload só é alcançável
# depois do boot, e um probe que não responde não pode derrubar o loop).
func _telemetry() -> TelemetryService:
	if telemetryService != null:
		return telemetryService
	if Launcher == null:
		return null
	return Launcher.Telemetry

# As linhas do funil de receita na janela corrente. "" sem SQL pronto ou sem
# serviço — ausência aqui é visível no scrape (o bloco simplesmente não aparece),
# e o `funnelSectionCalls` abaixo denuncia o anexo morto.
func FunnelGaugeLines() -> String:
	return _funnelSection()

func _funnelSection() -> String:
	if Launcher.SQL == null or not Launcher.SQL.isInitialized:
		return ""
	var tele : TelemetryService = _telemetry()
	if tele == null:
		return ""
	funnelSectionCalls += 1
	return tele.FunnelGaugeLines(FunnelWindowDays)

# O estado da agenda declarativa de live ops (sources/ops/LiveOpsCalendar.gd).
# Leitura pura de arquivo com cache de 60 s, sem banco: sempre responde, e o
# fail-closed do módulo já devolve "nada no ar" quando o JSON está quebrado.
func LiveOpsGaugeLines() -> String:
	return _liveOpsSection()

func _liveOpsSection() -> String:
	return LiveOpsCalendar.GaugeLines(int(Time.get_unix_time_from_system()))

func _process(_delta : float) -> void:
	if not listening:
		return
	var now : float = Time.get_ticks_msec() / 1000.0
	while listener.is_connection_available():
		var peer : StreamPeerTCP = listener.take_connection()
		if peer != null and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			reading.append({"peer": peer, "buf": "", "deadline": now + ConnectionTimeoutSec})
	_handle_reading(now)
	_handle_closing(now)

func _handle_reading(now : float) -> void:
	var alive : Array[Dictionary] = []
	for entry in reading:
		var peer : StreamPeerTCP = entry["peer"]
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or now > float(entry["deadline"]):
			peer.disconnect_from_host()
			continue
		peer.poll()
		var available : int = peer.get_available_bytes()
		var buf : String = String(entry["buf"])
		if available > 0:
			var chunk : Variant = peer.get_data(available)
			if int(chunk[0]) != OK:
				peer.disconnect_from_host()
				continue
			buf += (chunk[1] as PackedByteArray).get_string_from_utf8()
			if buf.length() > RequestMaxBytes:
				_respond(peer, 431, "text/plain", "request header fields too large\n")
				continue
		if buf.contains("\r\n\r\n") or buf.contains("\n\n"):
			_respond_route(peer, _route(buf.get_slice("\n", 0).strip_edges()))
			continue
		alive.append({"peer": peer, "buf": buf, "deadline": float(entry["deadline"])})
	reading = alive

func _handle_closing(now : float) -> void:
	var alive : Array[Dictionary] = []
	for entry in closing:
		if now >= float(entry["deadline"]):
			var peer : StreamPeerTCP = entry["peer"]
			peer.disconnect_from_host()
			continue
		alive.append(entry)
	closing = alive

# Só três caminhos, todos GET: /healthz (probe de liveness), /metrics (Prometheus)
# e / (página curta para leitura humana). Qualquer outra coisa é 404 de propósito.
func _route(requestLine : String) -> Dictionary:
	var parts : PackedStringArray = requestLine.split(" ")
	if parts.size() < 2:
		return {"status": 400, "type": "text/plain", "body": "bad request\n"}
	if parts[0] != "GET":
		return {"status": 405, "type": "text/plain", "body": "method not allowed\n"}
	var path : String = parts[1].split("?")[0]
	match path:
		"/healthz", "/health":
			if IsServing():
				return {"status": 200, "type": "text/plain", "body": "ok\n"}
			return {"status": 503, "type": "text/plain", "body": "starting\n"}
		"/metrics":
			return {"status": 200, "type": "text/plain; version=0.0.4", "body": MetricsBody()}
		"/":
			return {"status": 200, "type": "text/plain", "body": "shambleta metrics: /healthz /metrics\n"}
	return {"status": 404, "type": "text/plain", "body": "not found\n"}

func _respond_route(peer : StreamPeerTCP, route : Dictionary) -> void:
	_respond(peer, int(route["status"]), String(route["type"]), String(route["body"]))

func _respond(peer : StreamPeerTCP, status : int, contentType : String, body : String) -> void:
	var head : String = "HTTP/1.0 %d %s\r\n" % [status, _StatusText(status)]
	head += "Content-Type: %s\r\n" % contentType
	head += "Content-Length: %d\r\n" % body.to_utf8_buffer().size()
	head += "Cache-Control: no-store\r\n"
	head += "Connection: close\r\n\r\n"
	if peer.put_data(head.to_utf8_buffer()) != OK:
		peer.disconnect_from_host()
		return
	if peer.put_data(body.to_utf8_buffer()) != OK:
		peer.disconnect_from_host()
		return
	# HTTP/1.0 com Connection: close: o curl espera EOF por dentro do socket, não
	# Content-Length. Fechar na hora descarta o que ainda está no buffer, então a
	# resposta espera uma janela antes do disconnect.
	closing.append({"peer": peer, "deadline": Time.get_ticks_msec() / 1000.0 + FlushGraceSec})

func _StatusText(status : int) -> String:
	match status:
		200:
			return "OK"
		400:
			return "Bad Request"
		404:
			return "Not Found"
		405:
			return "Method Not Allowed"
		431:
			return "Request Header Fields Too Large"
		503:
			return "Service Unavailable"
	return "Internal Server Error"
