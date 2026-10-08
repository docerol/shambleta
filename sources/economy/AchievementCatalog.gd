extends RefCounted
class_name AchievementCatalog

# M-8 (2026-10-07): as conquistas saem do `EconomyCatalog` para o arquivo
# próprio no MESMO regime do `EconomyPassTrack` (M-1): o catálogo grande é a
# fonte única jurada pelas suites, e a política que nasce nova entra pela porta
# do dono — aqui, a lista de objetivos com prêmio. O `EconomyCatalog` mantém o
# alias `ACHIEVEMENTS` para nenhum leitor antigo ter de ser reensinado; a
# NARRATIVA (quem escolhe goal/gemas/prêmio) vive desta borda para dentro.
#
# Formas de prêmio, ambas medidas por suite própria:
#  - `gems`  → torneira com linha de ledger `achievement:<id>`;
#  - `cosmetic` → única porta cosmética do claim (M-8); o id precisa existir no
#    `COSMETIC_CATALOG` e o grant sai com `source = achievement:<id>` — quem foi
#    dado por coleção é rastreável à coleção.

const ACHIEVEMENTS : Array = [
	{"id": "slayer_100", "label": "Exterminador iniciante", "desc": "Derrote 100 monstros", "counter": "kills_total", "goal": 100, "gems": 25},
	{"id": "slayer_1000", "label": "Exterminador", "desc": "Derrote 1.000 monstros", "counter": "kills_total", "goal": 1000, "gems": 50, "cosmetic": "emote_tocha"},
	{"id": "slime_100", "label": "Caça-slimes", "desc": "Derrote 100 Slimes", "counter": "kills_mob", "mob": "Slime", "goal": 100, "gems": 30},
	{"id": "chest_10", "label": "Abre-baús", "desc": "Abra 10 baús", "counter": "chests", "goal": 10, "gems": 20},
	{"id": "chest_100", "label": "Mestre dos baús", "desc": "Abra 100 baús", "counter": "chests", "goal": 100, "gems": 60},
	{"id": "boss_1", "label": "Caçador de chefes", "desc": "Vença 1 chefe", "counter": "bosses", "goal": 1, "gems": 30},
	{"id": "boss_10", "label": "Lenda viva", "desc": "Vença 10 chefes", "counter": "bosses", "goal": 10, "gems": 100},
	{"id": "level_20", "label": "Veterano", "desc": "Alcance o nível 20", "counter": "level", "goal": 20, "gems": 25},
	{"id": "level_40", "label": "Elite", "desc": "Alcance o nível 40", "counter": "level", "goal": 40, "gems": 60},
	{"id": "rebirth_1", "label": "Renascer", "desc": "Renasça 1 vez", "counter": "rebirths", "goal": 1, "gems": 50},
	# M-8 (2026-10-07): coleções do bestiário — o prêmio é COSMÉTICO, não gems.
	# A métrica `mobs_distinct` conta MONSTROS DIFERENTES com pelo menos
	# `minPerMob` abates (a coleção é variedade comprovada, não um farm de um
	# mob só — `kills_mob`/`kills_total` já cobrem profundidade). Prêmios:
	# `skin_mascara` e `title_bestiarista`, nenhum à venda, nenhum no passe,
	# nenhuma doação — a mesma régua de exclusividade que o M-1 prendeu.
	{"id": "colecao_cacador", "label": "Colecionador da campina", "desc": "Abata 10+ de 6 monstros diferentes", "counter": "mobs_distinct", "minPerMob": 10, "goal": 6, "cosmetic": "skin_mascara"},
	{"id": "colecao_bestiarista", "label": "Bestiarista completo", "desc": "Abata 50+ de 12 monstros diferentes", "counter": "mobs_distinct", "minPerMob": 50, "goal": 12, "cosmetic": "title_bestiarista"},
]

static func AchievementByID(achievementID : String) -> Dictionary:
	for entry in ACHIEVEMENTS:
		if str(entry.get("id", "")) == achievementID:
			return entry
	return {}
