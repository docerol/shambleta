# SOM-IDLE Fase E: rewarded ads (MONETIZATION §2.5). Regra de ouro:
# anúncio é sempre opt-in (botão), nunca interrupção.
#
# Dois caminhos, selecionados por SHAMBLETA_AD_PROVIDER (env, default "stub"):
# - "stub": dev/teste — o anúncio é simulado (2 s, sempre concluído). Útil em
#   desktop/staging sem SDK. O que ele pula é a exibição, não a autorização: o
#   slot continua vindo do servidor, como no caminho real.
# - "portal": produção web — o SDK do portal de distribuição é chamado via
#   JavaScriptBridge e o token só é devolvido quando o SDK confirma "assistido
#   até o fim". O contrato JS vive em deploy/web/ads_bridge.js (objeto
#   window.ShambletaAds com show_rewarded(placement, done_callback) +
#   ad_ready(placement)).
#
# O que os dois caminhos têm em comum desde C2 (auditoria 2026-09-24): o token
# nunca foi construído aqui. O preço de mostrar um anúncio é uma autorização do
# servidor (`Network.RequestAdSlot` → `Network.AdSlot`), e ela vale uma vez.
# Trocar de portal/rede = trocar ads_bridge.js + SHAMBLETA_AD_PROVIDER; os
# 4 placements, os RPCs e o servidor não mudam.
# Ainda sem prova de exibição: o servidor aceita a declaração deste client
# enquanto `SHAMBLETA_AD_STUB=1` estiver ligado **no servidor** (default:
# desligado, e o compose de produção não o seta — `SuiteDeployMode` assenta
# isso). O que o nonce mudou foi o teto do abuso, não a natureza da
# confiança — com SSV real, `ShowRewarded` passa a entregar a assinatura do
# portal no lugar do slot, e o servidor troca `_ConsumeAdSlot` pela verificação.
# Sem class_name de propósito: utilitário carregado por preload (não depende
# do cache global de classes).
extends RefCounted

const PROVIDER_STUB : String = "stub"
const PROVIDER_PORTAL : String = "portal"

# placement -> Callable do botão que pediu o slot. Indexado por placement porque
# a resposta do servidor chega por `Client.AdSlot`, sem nenhuma relação com quem
# perguntou — é o único jeito de achar o callback. Um pedido por vez por
# placement: o botão se desabilita ao clicar, então o clique seguinte só acontece
# depois de uma resposta (ou depois de um refresh de janela, quando o anterior se
# perdeu no caminho); nesse caso o callback novo é o do mesmo botão, e
# substituir é o que o devolve ao estado clicável.
static var _waiters : Dictionary = {}

static func Provider() -> String:
	var p : String = OS.get_environment("SHAMBLETA_AD_PROVIDER").strip_edges().to_lower()
	if p == PROVIDER_PORTAL:
		return PROVIDER_PORTAL
	return PROVIDER_STUB

static func IsReady(_placement : String) -> bool:
	# Kill-switch de runtime (OPS-2, flag `ads_rewarded`): com a flag desligada o
	# botão de anúncio sai da UI antes de qualquer pedido ao servidor. Escopo
	# honesto: este arquivo é o LADO CLIENT do rewarded (o mesmo `AdProvider.gd`
	# roda no browser e no desktop), e aqui a flag controla superfície, não
	# dinheiro — quem credita gems por anúncio é o servidor (`MintAdSlot`/
	# `WatchAd`, em `sources/economy/`, fora da minha posse nesta passada), e o
	# desligador de receita que já existe lá é `SHAMBLETA_AD_STUB`. O gate de
	# verdade server-side desta rodada é `tournament_enter`, em WorldCommands.
	if not FeatureFlags.Enabled(FeatureFlags.ADS_REWARDED):
		return false
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
	# Nota de honestidade: "pronto" é sobre o inventário de anúncios, não sobre a
	# cota da conta — quantos ainda cabem no dia só o servidor sabe, e a recusa
	# chega como `AdFeedback("placement_cap")` depois do clique.
	return true

# Caminho de produção: exibe o rewarded e chama on_token(token) na conclusão.
# token vazio = sem slot, anúncio pulado ou fechado antes do fim (nada a
# creditar). Primeiro pedido = assíncrono por construção (a autorização vem do
# servidor); com o placement já autorizado, mostra na hora.
static func ShowRewarded(placement : String, on_token : Callable) -> void:
	# Mesmo portão de `IsReady`, e por um motivo operacional: `IsReady` é onde a UI
	# esconde o botão, mas quem chega aqui por um caminho que não perguntou (botão
	# já desenhado antes do `/flags reload`, atalho de teste) tem que receber a
	# resposta na mesma. `on_token.call("")` é o contrato de "nada a creditar" que
	# a UI já trata — ela reativa o botão. Registrar em `_waiters` sem ir ao
	# servidor é que deixaria o botão preso para sempre.
	if not FeatureFlags.Enabled(FeatureFlags.ADS_REWARDED):
		on_token.call("")
		return
	_waiters[placement] = on_token
	Network.RequestAdSlot(placement)

# Chamado por Client.AdSlot com a resposta do servidor. Sempre libera o botão:
# token vazio devolve "" e o callback da UI reativa o botão em vez de deixá-lo
# preso esperando uma resposta que não vem.
static func OnAdSlot(placement : String, token : String, _reason : String) -> void:
	if not _waiters.has(placement):
		return
	var onToken : Callable = _waiters[placement]
	_waiters.erase(placement)
	_Show(placement, token, onToken)

static func _Show(placement : String, slot : String, on_token : Callable) -> void:
	if Provider() == PROVIDER_PORTAL:
		if LauncherCommons.isWeb:
			var js = _PortalBridge()
			if js:
				js.show_rewarded(placement, func(completed : bool) -> void:
					on_token.call(slot if bool(completed) else ""))
				return
		on_token.call("")
		return
	# Stub explícito (beta/dev): o slot é o token; sem slot, nada a entregar.
	on_token.call(slot)

static func _PortalBridge():
	if not LauncherCommons.isWeb:
		return null
	return JavaScriptBridge.get_interface("ShambletaAds")
