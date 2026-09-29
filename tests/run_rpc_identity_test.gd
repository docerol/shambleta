extends SceneTree

# gate-marker: == RPC IDENTITY:

# S1 — prova de transporte real (a única que ninguém pode fingir no loopback).
# Sobe o NetServer WebSocket do projeto, conecta dois NetClient reais e faz um
# client chamar o RPC mirando o peer do OUTRO. Identidade falsa no corpo do
# pacote tem que virar o sender do transporte; se o facade algum dia confiar no
# corpo, este runner falha.
#
# Uso: godot --headless --path . -s tests/run_rpc_identity_test.gd
# Exit code: número de checks falhos (0 = verde).
#
# Igual ao run_idle_tests: -s compila antes dos autoloads existirem, então nada
# de identificador de autoload/class_name aqui — tudo via load()/get()/call().

const PROBE_SOURCE := """
extends Node
var seen : Array = []

@rpc("any_peer", "call_remote", "reliable")
func probe(claimed : int):
	var net : Node = get_node_or_null(NodePath("/root/Network"))
	var entry : Dictionary = { "claimed": claimed, "sender": 0, "auth": claimed }
	if net:
		entry["sender"] = int(net.call("TransportSenderID"))
		entry["auth"] = int(net.call("AuthPeerID", claimed))
	seen.append(entry)
"""

const PROBE_NODE_NAME := "NetworkRpcProbe"

# Orçamento de relógio wall da espera de boot em `_tickBootWait`. Em frames seria
# a régua errada: é exatamente o pacing de frame que a contenção de CPU muda.
const DB_BOOT_BUDGET_MS : int = 20000

var checks : int = 0
var failures : int = 0
var frames : int = 0
var step : int = 0

var net : Node = null
var srv : Node = null
var cliA : Node = null
var cliB : Node = null
var probe : Node = null
var seen : Array = []
var idA : int = 0
var idB : int = 0

var dbScript : GDScript = null
var waitingForBoot : bool = false
var bootDeadlineMs : int = 0
var bootStartMs : int = 0

func Check(condition : bool, label : String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		print("  [FAIL] " + label)
	else:
		print("  [ok] " + label)
	return condition

func _iface(node : Node):
	return node.get("multiplayerAPI") if node != null else null

func _makeClient() -> Node:
	var script : GDScript = load("res://sources/network/client/Client.gd")
	return script.new(true, false, false, true)

func _process(_delta):
	frames += 1
	if waitingForBoot:
		return _tickBootWait()
	if net == null:
		net = root.get_node_or_null(NodePath("Network"))
	if net == null:
		if frames > 600:
			print("FATAL: autoload Network ausente")
			quit(1)
		return false

	match step:
		0:
			if frames < 30:
				return false
			var serverScript : GDScript = load("res://sources/network/server/Server.gd")
			srv = serverScript.new(true, false, false, true)
			net.set("WebSocketServer", srv)
			probe = Node.new()
			probe.name = PROBE_NODE_NAME
			root.add_child(probe)
			var probeScript : GDScript = GDScript.new()
			probeScript.source_code = PROBE_SOURCE
			probeScript.reload()
			probe.set_script(probeScript)
			seen = probe.get("seen")
			step = 1
		1:
			var api = _iface(srv)
			if api == null or not api.has_multiplayer_peer():
				if frames > 900:
					Check(false, "transporte: NetServer WebSocket não subiu")
					return _finish()
				return false
			Check(api.get_multiplayer_peer().get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING or api.get_multiplayer_peer().get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED, "transporte: servidor escutando na porta de teste")
			cliA = _makeClient()
			cliB = _makeClient()
			step = 2
		2:
			idA = int(cliA.get("interfaceID"))
			idB = int(cliB.get("interfaceID"))
			var srvApi = _iface(srv)
			var alive : Array = srvApi.get_peers()
			if idA <= 0 or idB <= 0 or idA == idB or not (idA in alive and idB in alive):
				if frames > 1200:
					Check(false, "transporte: dois clients reais conectados ao servidor (A=%d B=%d, vivos=%s)" % [idA, idB, str(alive)])
					return _finish()
				return false
			Check(idA != idB and idA > 1 and idB > 1, "transporte: sessões reais distintas (A=%d, B=%d)" % [idA, idB])
			Check(idA in alive and idB in alive, "transporte: ambos os peers vivos no servidor")
			Check(seen.is_empty(), "transporte: nada registrado antes do primeiro pacote")
			# A fala mirando a sessão de B.
			cliA.get("multiplayerAPI").rpc(1, probe, "probe", [idB])
			step = 3
		3:
			if seen.is_empty():
				if frames > 1500:
					Check(false, "transporte: RPC de A não chegou ao servidor")
					return _finish()
				return false
			var first : Dictionary = seen[0]
			Check(int(first.get("claimed")) == idB, "forja aceita no corpo: A declarou ser B (%d)" % idB)
			Check(int(first.get("sender")) == idA, "transporte reporta A como sender (%d)" % idA)
			Check(int(first.get("auth")) == idA, "AuthPeerID descarta o corpo e devolve A")
			Check(int(first.get("auth")) != idB, "B não é atendido no lugar de A")
			# Agora na direção contrária: B mirando A.
			cliB.get("multiplayerAPI").rpc(1, probe, "probe", [idA])
			step = 4
		4:
			if seen.size() < 2:
				if frames > 1800:
					Check(false, "transporte: RPC de B não chegou ao servidor")
					return _finish()
				return false
			var second : Dictionary = seen[1]
			Check(int(second.get("auth")) == idB, "mesma regra na direção inversa (B)")
			Check(int(second.get("auth")) != int(second.get("claimed")), "identidade nunca vem do pacote")
			return _finish()
	return false

func _finish():
	# DRENAR NÃO BASTAVA. A contagem de teardown deste runner não era propriedade
	# do harness: medido em 2026-09-28, vazava 30 dentro do `all` e 1747 rodado
	# sozinho (`one run_rpc_identity_test`), três vezes seguidas. O
	# `DrainPendingPreloads()` de `sources/db/DB.gd` só junta os caminhos que já
	# estão em `preloadPaths`, e `preloadPaths` é preenchido por `Preload()` —
	# quanto do boot tinha materializado quando o `quit()` chegava dependia da
	# carga da máquina (LOGIN_SCREEN a 4,494 s no `all` contra 1,865 s sozinho).
	# A frase que estava aqui, "com o dreno o caminho é sempre o do boot completo",
	# é falsa por essa medição: `load_threaded_get` bloqueia por um caminho pedido,
	# e caminho ainda não pedido não é juntado por ninguém.
	#
	# O que existe agora é espera de estado. Terminada a máquina de passos, o
	# runner entra em `waitingForBoot` e `_tickBootWait` continua girando em
	# `_process` até `DB.isInitialized` virar true — o mesmo sinal que
	# `multi_instance_tick_test` lê, posto por `PreloadUpdate`, que na mesma
	# emissão de `process_frame` chama o `Load()` síncrono. A linha de veredito só
	# é impressa quando a espera fecha, com o check do boot dentro da contagem. O
	# teto da espera é relógio wall (`Time.get_ticks_msec()`), não frames: o pacing
	# de frame é justamente o que a contenção muda. Estourado o orçamento sem o
	# sinal, `Check(false, ...)` vai vermelho e o `quit()` leva a falha — não é
	# silêncio. O invariante que a mudança cria é nenhum `quit()` deste harness
	# alcançar o teardown com o boot do DB por fechar.
	#
	# Medido depois da mudança, host com Steam em execução (load 8 a 18 em 12
	# núcleos): dez runs de `bash scripts/test.sh one run_rpc_identity_test 600`
	# deram 1747 sete vezes e 1748 três vezes — um regime só: 1066 ObjectDB + 641
	# recursos + 40 RIDs de `NavRegion2D`, e o +1 é uma instância ObjectDB a mais
	# (1067) ou um RID de `RendererDummy…DummyTexture`, nunca o outro regime. Um
	# dos dez rodou com 20 loops de CPU extras (`nice -n 19`) competindo e
	# LOGIN_SCREEN a 3,439 s, e vazou 1747 igual. A espera custou de 1 a 19 ms:
	# `DB.isInitialized` já era true quando o passo 4 pousou, então a espera é
	# piso, não custo. O teto gravado é 2247 e a régua de rebaixa de
	# `scripts/ci_gate_log.sh` não acusa: 2247 não é maior que 1747 + 1747/2 + 64.
	# O caminho do `all` não foi remedido aqui (20+ min, e o lock global de boot
	# serializa); dele se sabe o invariante do parágrafo anterior.
	dbScript = load("res://sources/db/DB.gd")
	waitingForBoot = true
	bootStartMs = int(Time.get_ticks_msec())
	bootDeadlineMs = bootStartMs + DB_BOOT_BUDGET_MS
	return false

func _tickBootWait():
	if dbScript != null and bool(dbScript.get("isInitialized")):
		Check(true, "boot do DB fechado antes do quit (DB.isInitialized em %d ms de espera)" % (int(Time.get_ticks_msec()) - bootStartMs))
	elif int(Time.get_ticks_msec()) >= bootDeadlineMs:
		Check(false, "DB.isInitialized seguiu false por %d ms: o boot parou no preload threadado e o veredito deste runner deixaria de ser lido no regime do boot completo" % DB_BOOT_BUDGET_MS)
	else:
		return false
	if dbScript != null:
		dbScript.call("DrainPendingPreloads")
	print("== RPC IDENTITY: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
	return true
