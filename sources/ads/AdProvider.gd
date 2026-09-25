# SOM-IDLE Fase E: rewarded ads (MONETIZATION §2.5). Regra de ouro:
# anúncio é sempre opt-in (botão), nunca interrupção.
#
# Dois caminhos, selecionados por SHAMBLETA_AD_PROVIDER (env, default "stub"):
# - "stub": dev/teste — ShowRewarded() minta o token na hora (comportamento
#   antigo do ShowStub). Útil em desktop/staging sem SDK.
# - "portal": produção web — ShowRewarded() chama o SDK do portal de
#   distribuição (CrazyGames/Poki ou equivalente) via JavaScriptBridge e SÓ
#   minta o token quando o SDK confirma "assistido até o fim". O contrato JS
#   vive em deploy/web/ads_bridge.js (objeto window.ShamletaAds com
#   show_rewarded(placement, done_callback) + ad_ready(placement)).
#   Sem SDK presente (ou fora do web), cai para o stub — o servidor valida
#   formato + dia e aplica os caps, mas NÃO tem como provar que o anúncio foi
#   assistido (ver ShowRewarded): por isso o token mintável aqui só credita com
#   SHAMBLETA_AD_STUB=1 no servidor, que é o ligador explícito do beta.
#
# Trocar de portal/rede = trocar ads_bridge.js + SHAMBLETA_AD_PROVIDER; os
# 4 placements, RPCs e o servidor não mudam.
# Sem class_name de propósito: utilitário carregado por preload (não depende
# do cache global de classes).
extends RefCounted

const PROVIDER_STUB : String = "stub"
const PROVIDER_PORTAL : String = "portal"

static func DayNow() -> int:
	var now : int = int(Time.get_unix_time_from_system())
	return (now - 6 * 3600) / 86400

static func Provider() -> String:
	var p : String = OS.get_environment("SHAMBLETA_AD_PROVIDER").strip_edges().to_lower()
	if p == PROVIDER_PORTAL:
		return PROVIDER_PORTAL
	return PROVIDER_STUB

static func _MintStub(placement : String) -> String:
	# Token que o servidor valida (formato + dia). Produção minta SÓ após o
	# callback de conclusão do SDK — ver ShowRewarded().
	return "stub:%s:%d" % [placement, DayNow()]

static func IsReady(_placement : String) -> bool:
	if Provider() == PROVIDER_PORTAL and LauncherCommons.isWeb:
		# `js.has_method(...)` não consulta a ponte: Godot encaminha o nome para o
		# lado JS, `ShambletaAds.has_method` não existe e cada chamada despejava um
		# TypeError no console do navegador (medido com o mesmo padrão em
		# WebPush.gd, 2026-09-25). A ponte é nossa (deploy/web/ads_bridge.js): ou o
		# global existe no `get_interface`, ou a página não tem SDK.
		var js = _PortalBridge()
		if js:
			return bool(js.ad_ready(_placement))
		return false
	# Stub: sempre pronto. O SDK real consulta disponibilidade aqui.
	return true

static func ShowStub(placement : String) -> String:
	# Caminho síncrono legado (dev/testes/suíte). UI de produção usa
	# ShowRewarded() para exigir a conclusão real do anúncio.
	return _MintStub(placement)

# Caminho de produção: exibe o rewarded e chama on_token(token) na conclusão.
# token vazio = anúncio pulado/fechado antes do fim (nada a creditar).
# SOM-IDLE M2: atenção ao que isto NÃO é. O token entregue nos dois caminhos é o
# mesmo formato "stub:", que o servidor só aceita com SHAMBLETA_AD_STUB=1 — ou
# seja, portal sem SSV continua sem prova de exibição verificável no servidor
# (o player pode mintar sem assistir). O modo portal existe para trocar o corpo
# do ads_bridge.js pelo SDK real; até lá, a defesa contra forja é o flag do
# servidor desligado (produção) e os caps (6/dia, 1 baú, 2 chaves).
static func ShowRewarded(placement : String, on_token : Callable) -> void:
	if Provider() == PROVIDER_PORTAL:
		if LauncherCommons.isWeb:
			var js = _PortalBridge()
			if js:
				# Mesma regra de `IsReady`: sem `has_method` na ponte, a presença do
				# global é a presença do SDK.
				js.show_rewarded(placement, func(completed : bool) -> void:
					if bool(completed):
						on_token.call(_MintStub(placement))
					else:
						on_token.call(""))
				return
		on_token.call("")
		return
	# Stub explícito (beta/dev): minta na hora, com caps server-side.
	on_token.call(_MintStub(placement))

static func _PortalBridge():
	if not LauncherCommons.isWeb:
		return null
	return JavaScriptBridge.get_interface("ShambletaAds")
