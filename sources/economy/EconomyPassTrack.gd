extends RefCounted
class_name EconomyPassTrack

# M-1 (2026-10-07) + fatia do gate anti-god-node: as DUAS tabelas da trilha de
# passe saíram de `EconomyCatalog.gd` (que estourou o teto de 800 ao ser
# preenchida) para cá, no mesmo regime da FATIA 13 (`EconomyBaseCatalog.gd`).
# Zero mudança de comportamento para os consumidores: `EconomyCatalog` mantém os
# aliases `PASS_FREE`/`PASS_PREMIUM`, o validador `ValidatePassTables` recebe as
# tabelas como parâmetro e a dependência corre num sentido só — este arquivo não
# lê `EconomyCatalog`. Os knobs escalares da trilha (`PASS_MAX_LEVEL`,
# `PASS_BONUS_START`, `PASS_BONUS_GEMS`, `PASS_DOUBLEXP_LAST_DAYS`) ficaram no
# catálogo: quem mudou de casa foi o corpo (as tabelas de recompensa), não a
# régua.

# (de EconomyService.gd, antes da divisao)
# M-1 (2026-10-07): os 30 slots vazios da trilha free foram preenchidos com o
# acervo que já existe — gems pequenos, baús e DOIS cosméticos de marco que são
# da própria trilha (emote-guilda 25, fx-faísca 35). Os cosméticos DAS OUTRAS
# origens ficaram fora de propósito: `title_recruta`/`title_apoiador` são backfill
# de compra, `title_campeao` é prêmio da copa, `emote_coroa` é exclusividade
# vitalícia do Deluxe — pô-los na vitrine grátis é prometer de novo o que já foi
# vendido caro. A régua de quem pode morar aqui é o censo em
# `SuiteStorefrontHonesty`: nível 1..40 sem entrada NÃO-VAZIA é vermelhot — slot
# vazio era o que a vitrine prometia e o jogador não recebia.
#vip_days continua fora daqui por construção (C-7, ponta do validador em
# `EconomyCatalog.ValidatePassTables`).
const PASS_FREE : Dictionary = {
	1: {"gems": 5}, 2: {"chests": 1}, 3: {"gems": 10}, 4: {"gems": 5},
	5: {"chests": 1}, 6: {"gems": 5}, 7: {"chests": 1}, 8: {"gems": 10},
	9: {"gems": 5}, 10: {"cosmetics": ["emote_tocha"]}, 11: {"gems": 10},
	12: {"chests": 1}, 13: {"gems": 15}, 14: {"gems": 10},
	15: {"gems": 25}, 16: {"chests": 1}, 17: {"gems": 10},
	18: {"chests": 1}, 19: {"gems": 10}, 20: {"gems": 15}, 21: {"gems": 10},
	22: {"chests": 1}, 23: {"gems": 10}, 24: {"chests": 2}, 25: {"cosmetics": ["emote_guilda"]},
	26: {"gems": 10}, 27: {"gems": 20}, 28: {"chests": 1}, 29: {"gems": 15},
	30: {"gems": 30, "cosmetics": ["title_redescobridor"]},
	31: {"gems": 10}, 32: {"chests": 1}, 33: {"gems": 10}, 34: {"gems": 10},
	35: {"cosmetics": ["fx_faisca"]}, 36: {"chests": 1}, 37: {"gems": 15},
	38: {"chests": 1}, 39: {"gems": 15}, 40: {"gems": 40},
}

# (de EconomyService.gd, antes da divisao)
# M-1: os 12 slots livres ANTES da escada de bônus (31..40) foram preenchidos —
# gems, baús e VIP pago em três marcos (a trilha premium É a linha QoL).
# `emote_coroa` (exclusivo vitalício do Deluxe) e `title_apoiador` (backfill de
# doação) ficaram de fora pela mesma régua da trilha grátis. De 31 em diante o
# `PASS_BONUS_GEMS` por nível já é a recompensa declarada (linha 320 de
# `PassService.gd`): a régua aceita nível premium OU com entrada na tabela OU
# dentro da escada de bônus — o que não pode é buraco silencioso.
const PASS_PREMIUM : Dictionary = {
	1: {"cosmetics": ["skin_manto"]}, 2: {"gems": 25}, 3: {"gems": 25},
	4: {"chests": 2}, 5: {"vip_days": 3}, 6: {"gems": 25}, 7: {"gems": 25},
	8: {"gems": 25}, 9: {"gems": 25}, 10: {"vip_days": 3},
	11: {"chests": 2}, 12: {"gems": 25}, 13: {"chests": 2},
	14: {"chests": 2}, 15: {"gems": 50}, 16: {"gems": 25},
	17: {"cosmetics": ["skin_mascara"]}, 18: {"gems": 25}, 19: {"vip_days": 3},
	20: {"chests": 2}, 21: {"chests": 3}, 22: {"gems": 25}, 23: {"gems": 25},
	24: {"gems": 25}, 25: {"vip_days": 5},
	26: {"gems": 25}, 27: {"chests": 2}, 28: {"gems": 50}, 29: {"gems": 50},
	30: {"gems": 100, "cosmetics": ["title_veterano"]},
}
