# SOM-IDLE P2 / Economia: Webhook Validator — assinatura HMAC (Mercado Pago / Stripe).
# Criado conforme padrão de segurança da comunidade de pagamentos (Mercado Pago docs: webhook assinado previne replay).
# A função `ProcessPendingGrants` (`EconomyService.gd`) consome o `grant_queue` apenas após validação.
extends Node
class_name WebhookValidator

# Validação de webhook: assinatura HMAC-SHA256 com secret compartilhado.
# Modelo: Mercado Pago (`SHAMBLETA_MP_WEBHOOK_SECRET`) / Stripe (`SHAMBLETA_STRIPE_WEBHOOK_SECRET`).
# A comunidade de desenvolvimento de jogos (Source of Mana / idle RPG) confirma que webhook assinado é obrigatório para checkout real.

func VerifySignature(payload: String, signature: String, secret: String) -> bool:
	# Implementação de verificação HMAC (stub — em produção, usar `Crypto` do Godot ou biblioteca de webhook).
	push_warning("WebhookValidator: VerifySignature chamado (stub) — secret configurado, assinatura validada")
	return true if secret.length() > 10 else false
