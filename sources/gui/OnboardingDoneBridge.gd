# SOM-IDLE P1-7: ponte do funil `onboarding_done`.
#
# O tour de boas-vindas (`Onboarding.gd`) já chamava
# `Launcher.Telemetry.RecordFunnel("onboarding_done")` no `Stop()`, mas
# `Telemetry` é alocada apenas em `Launcher.Server()` — no build web o processo é
# só cliente, o serviço é `null`, e a ÚLTIMA etapa do funil comercial nunca era
# gravada. Este arquivo não edita o `Onboarding` (posse de outra frente): ele
# OBSERVA o fim do tour e manda o sinal para o servidor pelo rpc próprio
# (`Network.OnboardingDone` → `Server.OnboardingDone` → `Telemetry.RecordFunnel`
# com a conta/personagem da SESSÃO).
#
# Como o fim é detectado sem tocar no outro arquivo: as duas saídas do fluxo são
# os botões `_nextButton` (no passo "Finish") e `_skipButton`, e `Stop()` é o que
# baixam `_isActive` para false. Nos botões, o handler do próprio `Onboarding` foi
# conectado em `_ready()` — o nosso é conectado depois, na mesma emissão de
# `pressed`, então roda após `Stop()` e lê o estado já atualizado.
extends RefCounted
class_name OnboardingDoneBridge

static var _sent : bool = false

# true quando a ponte conseguiu observar o fluxo (botões encontrados).
static func Attach(onboarding : Node) -> bool:
	_sent = false
	if onboarding == null:
		return false
	var wired : int = 0
	for buttonName : String in ["_nextButton", "_skipButton"]:
		var button : Button = onboarding.get(buttonName) as Button
		if button == null:
			continue
		var handler : Callable = _Observe.bind(button)
		if not button.pressed.is_connected(handler):
			button.pressed.connect(handler)
		wired += 1
	return wired > 0

static func _Observe(button : Button) -> void:
	if _sent or button == null:
		return
	# Os botões são filhos diretos do `Onboarding` (add_child em `_ready`), então o
	# pai é o fluxo a ser lido — sem guardar referência a um Node que pode se ir.
	var flow : Node = button.get_parent()
	if flow == null:
		return
	var active : Variant = flow.get("_isActive")
	# `get` devolve null se o fluxo mudou de forma: melhor não afirmar um evento.
	if active == null or bool(active):
		return
	_sent = true
	Network.OnboardingDone()

# O funil é por sessão de tour; exposto para os testes resetarem entre casos.
static func ResetSent() -> void:
	_sent = false

static func HasSent() -> bool:
	return _sent
