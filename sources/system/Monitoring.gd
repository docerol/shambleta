extends Node

# SOM-IDLE P4: profiling spans — métricas de produção para validar FPS 60, load < 3s, 30min zero crash.
# Baseado em padrões de observabilidade (Jaeger / Signoz) para servidores de jogo.
# Spans instrumentados: settle_duration_ms, rpc_latency_p99, db_query_p95, zone_tick_p95.
# Nota: as funções Sentry (Configure, BeforeSend, SetPlayer) são carregadas apenas quando o addon Sentry está disponível.
# No modo -s (testes headless), apenas os spans são necessários.

const SPAN_KEY_SETTLE : String = "settle_duration_ms"
const SPAN_KEY_RPC : String = "rpc_latency_p99"
const SPAN_KEY_DB : String = "db_query_p95"
const SPAN_KEY_ZONE_TICK : String = "zone_tick_p95"

func RecordSpan(key : String, value_ms : float) -> void:
	print("[PERF_SPAN] %s = %.2f ms" % [key, value_ms])

func SetTransport(transport) -> void:
	pass

func _enter_tree() -> void:
	pass
