# SOM-IDLE Fase E: abstração de rewarded ads (MONETIZATION §2.5). O stub
# devolve um token local imediato; o SDK real (portal CrazyGames/Poki ou
# AdSense for Games) pluga em ShowStub() sem mudar chamadores, RPCs ou
# servidor — o servidor valida o formato do token, não o SDK. Regra de ouro:
# anúncio é sempre opt-in (botão), nunca interrupção.
# Sem class_name de propósito: utilitário carregado por preload (não depende
# do cache global de classes).
extends RefCounted
static func DayNow() -> int:
	var now : int = int(Time.get_unix_time_from_system())
	return (now - 6 * 3600) / 86400

static func IsReady(_placement : String) -> bool:
	# Stub: sempre pronto. O SDK real consulta disponibilidade aqui.
	return true

static func ShowStub(placement : String) -> String:
	# Stub: "exibe" na hora e devolve o token que o servidor valida
	# (formato + dia). Produção troca por callback assinado do SDK.
	return "stub:%s:%d" % [placement, DayNow()]
