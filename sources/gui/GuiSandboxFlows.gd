extends RefCounted
class_name GuiSandboxFlows

# Fatia do HUD (gate anti-god-node — teto de 800 linhas do `Gui`, mesmos
# precedentes de `ManualHudBar`/`HudWindows`/`GuildPanelRows`): os três fluxos de
# fase que só conversam com o jogador pelo `notificationLabel` — checkout sandbox
# (comercial), gate de benchmark (performance) e teste de conectividade (rede).
#
# O `Gui` mantém os métodos chamados por nome (`SimulateCheckout`,
# `RunPerformanceBenchmark`, `CheckNetworkStability`): o `tests/test_e2e_implementation.gd`
# cobra os três na superfície do `Gui`, e é de lá que a ponte de comandos os chama.
# Aqui mora o corpo, com a mesma decisão de sempre e nenhuma a mais: o checkout
# pergunta ao `Launcher.Economy` e NUNCA grava nada — aprovar o pagamento sandbox
# é do servidor.

# Só o rótulo do `intent` é formatado aqui; o preço é o que o serviço devolve.
static func SimulateCheckout(gui : Node, sku : String) -> void:
	if Launcher.Economy == null:
		Notice(gui, "Checkout: EconomyService not available", 2.0)
		return
	var accountID : int = 0
	var peer : Variant = Launcher.get("Peer") if Launcher else null
	if peer and int(peer.get("accountID", 0)) > 0:
		accountID = int(peer.get("accountID", 0))
	if accountID <= 0:
		Notice(gui, "Checkout: no account ID found", 2.0)
		return
	var intent : Dictionary = Launcher.Economy.GetCheckoutIntent(accountID, sku)
	if not bool(intent.get("ok", false)):
		Notice(gui, "Checkout rejected: %s" % str(intent.get("reason", "unknown")), 2.0)
		return
	# Simula aprovação do pagamento (sandbox) e concede o grant.
	Notice(gui, "Checkout approved: %s (%.2f BRL)" % [str(intent.get("label", sku)), float(intent.get("price", 0.0))], 3.0)

static func RunPerformanceBenchmark(gui : Node) -> void:
	Notice(gui, "Performance benchmark started...", 1.0)
	# O benchmark real roda via `godot --headless -s tests/benchmarks.gd`;
	# esta função apenas notifica o início/fim para o usuário.
	Notice(gui, "Benchmark gate: budget 500ms settle, 1000ms XP, 200ms catalog", 2.0)

static func CheckNetworkStability(gui : Node) -> void:
	if Network.Client == null and not LauncherCommons.isWeb:
		Notice(gui, "Network: Client disconnected", 2.0)
	else:
		Notice(gui, "Network: Stable", 1.0)

# O HUD ainda pode não ter nó de notificação (antes do `@onready` resolver, ou em
# cena sem overlay): engolir em silêncio é o comportamento que já estava nos três
# fluxos, um `if notificationLabel` por chamada.
static func Notice(gui : Node, text : String, duration : float) -> void:
	if gui.notificationLabel:
		gui.notificationLabel.AddNotification(text, duration)
