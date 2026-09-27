extends Node
class_name WebPushDelivery
# SOM-W5: contrato de entrega de web push — a parte DO JOGO do caminho que o
# companion já anda (migration 052: push_subscription + push_outbox; CLI
# --push-register/--push-sweep/--push-drain; POST /push/test com sender
# plugável). Este arquivo é static-only e não é autoload: mora do lado do
# `WebPushService` para o harness headless (`tests/web_delivery_test.gd`)
# conseguir amarrar as duas pontas sem subir a árvore de nós.
#
# POR QUE ISTO EXISTE SE O GATE É WebPush.CanDeliver()?
# Porque o gate precisa de UMA fonte de verdade, não de duas. `WebPush.gd` lê
# `SenderImplemented()` (mudou de `return false` para a delegação em
# 2026-09-27, na passada que tirou este arquivo da lista de código órfão), e
# esta classe declara a verdade sobre a única peça que falta — o sender.
# Registrar o worker (`_register_service_worker`) já estava guardado por
# CanDeliver(), a linha de Settings já consulta CanDeliver(), e
# o arquivo `/sw.js` fino (deploy/web/sw.js, handlers de push sem `fetch`) já
# é copiado pelo Dockerfile e servido no-cache pelo nginx — registrar por
# cima do worker do engine sem sender pronto é exatamente o que o guard atual
# impede. Falta também o lado JS do registro (`ShambletaPush.register_sw` +
# `pushManager.subscribe` com applicationServerKey = chave pública VAPID),
# que vive no shell do export — pendência registrada no relatório.

# Verdade única enquanto o sender do companion for NotImplementedError (sem
# ECDSA P-256 na stdlib do Python e companion stdlib-only por contrato): o
# harness amarra este false ao false de WebPush.CanDeliver() e ao prefixo
# `vapid_sender_unimplemented` que a fila grava quando alguém drena.
static func SenderImplemented() -> bool:
	return false

# Campos mínimos de uma subscription — os mesmos quatro que a CLI
# `--push-register` exige e que a migration 052 declara NOT NULL.
static func SubscriptionFields() -> PackedStringArray:
	return PackedStringArray(["account_id", "endpoint", "p256dh", "auth"])

static func SubscriptionComplete(data : Dictionary) -> bool:
	for field in SubscriptionFields():
		if not data.has(field):
			return false
		if str(data.get(field, "")).strip_edges() == "":
			return false
	return true

# O que o jogador pode ganhar HOJE: nada. Mantido em uma função para o harness
# poder exigir a mesma resposta que Settings.gd vai ler de CanDeliver().
# (chamada sem qualificador: de estática para estática no mesmo script — o
# nome global `WebPushDelivery` só entra no cache de classes quando o editor
# re-scanear, e o harness carrega este arquivo por caminho.)
static func CanOfferToPlayer() -> bool:
	return SenderImplemented()
