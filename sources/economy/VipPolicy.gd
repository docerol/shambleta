extends RefCounted
class_name VipPolicy

# C-7 (2026-10-06): regra de origem do tempo de VIP. O VIP é a linha QoL que a
# promessa comercial jura não ser P2W, e antes deste arquivo qualquer rota de
# grant — trilha FREE do passe, oferta paga em gem (moeda farmável: 880 gems
# valiam menos que uma semana de faucet) e a compra direta — empilhava
# `vip_until` sem teto: a assinatura era canibalizável e o ×2 no loot da
# liquidação se auto-financiava. A política agora tem DONO num arquivo só:
#   1. origem: `vip_days` NUNCA sai da trilha free do passe (recusado no grant,
#      no validador do catálogo e no do `seasons.json` — três pontas, a mesma
#      régua);
#   2. teto: ninguém estoca mais de `MaxStackDays` à frente, nem pagando — o
#      stack continua legítimo (comprar adiantado é escolha do jogador), o que
#      não cabe é virar balde permanente de dias.
# O clamp mora AQUI e os três escritores o chamam: um writer que "esquece" o
# teto é exatamente a classe de defeito que a auditoria achou.
const MaxStackDays : int = 90

# Devolve o novo `vip_until`: base = máximo entre agora e o saldo vigente (o
# tempo não consumido não se perde), soma entra por cima, e o teto é relativo
# ao INSTANTE DA COMPRA (não ao saldo anterior — estocar além de 90 dias
# adiantados é o que esta régua recusa, não gastar o que já se tem).
static func ClampGrant(curUntil : int, now : int, addSec : int) -> int:
	var base : int = maxi(now, curUntil)
	return mini(base + addSec, now + MaxStackDays * 86400)
