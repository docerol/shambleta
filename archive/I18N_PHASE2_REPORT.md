# I18N Fase 2 — conteúdo de NPCs/quests (pt-BR)

Data: 2026-07 · Depende de: `I18N_PHASE1_REPORT.md` (pipeline, `Localizer.gd`, extrator)

## Resultado

**Corpus completo em pt-BR: UI 176/176 (100%) + conteúdo 727/727 (100%), 0 gaps**
(`python3 tools/extract_i18n.py` → `data/i18n/coverage_report.md`).

730 chaves `Mes()/Say()` de `sources/scripts/` divididas em 3 lotes literários:

| Lote | Escopo | Linhas | Commit |
|---|---|---|---|
| 2A | generic, candor, splatyna, manayir, ship, desertpit | 136 | este |
| 2B | sandstorm (missão Uru + Minas da Tempestade + Vigia Nathan) | 160 | este |
| 2C | tulimshar (quest inicial, Rainha Vermelha, padaria, vidro, cartas, porto) | 432 | este |

Mais o seletor de idioma da Settings (fase 1.5, commit anterior `bec2ccc`).

## Regras editoriais aplicadas (recorde para futuros lotes/traduções)

1. **Mapas versionados**: cada lote é um arquivo `tools/i18n/maps/phase2X_*.py`
   (`(prefixo_da_chave, tradução)`) aplicado por `tools/i18n/apply_map.py`
   (match por prefixo mais longo, idempotente, relatório de sem-match). O csv
   final é gerado; os mapas ficam no repo como trilha de auditoria do tradutor.
2. **Lore nouns ficam verbatim**: Mana, Kaore, Uru, Kano, Kahwe, Hantu, Zielite,
   Soul Menhir, Tonori/Tulimshar/Manayir/Candor/Splatyna, Kaumatua, Credo Savean,
   Zuni, Nawah, La Johanne. É o vocabulário que a própria comunidade BR usa nas
   discussões do jogo — traduzir criaria wiki paralela.
3. **Nomes de item capitalizados ficam verbatim dentro da fala** (Sandstorm Bread,
   Healing Potion, Cactus Potion, Maggot Slime, Jeans Shorts, Snake Skins, Iron
   Ore, Water, Pitaya) — o nome exibido no inventário vem do banco e ainda não
   tem passe de tradução (ver Pendências).
4. **Créditos não se traduzem**: as 2 linhas de prêmio (`Johanne Laliberté, 2011`,
   `Nard, 2011`) entraram no conjunto IDENTITY do extrator, com comentário.
5. **Identidade traduzível-por-identidade**: `...`, `Blackjack!`, `ARGH.` — o
   heurístico do tool trata `pt == en` como "não traduzido"; essas entram no
   IDENTITY explicitamente, nunca para força-bruta no csv.
6. **Especificadores**: `%d/%s` preservados (auditoria automatizada: 0 divergências
   nas 875 linhas do csv). Chaves com espaços de cena (padding) são copiadas
   byte-a-byte do extrator.
7. **Consistência entre lotes**: Watchman → Vigia em todos os nomes (Nathan,
   Dausen, Ekinu, Kael); "Sandstorm Mines" → Minas da Tempestade idêntico a 2B.

## Suite

`SuiteI18n` ganhou 4 amostras de conteúdo (1 por lote + genérica): resolução
pt_BR de falas reais via `ui.pt_BR.translation` carregada. Ver commit: contagem
final da suíte.

## Pendências abertas (fora do escopo desta fase)

- **Nomes de itens/mobs do banco**: `data/db/*.json` alimenta tooltips e nomes
  via `DB.GetCellHash` — não passam por `tr()`. Precisam de decisão de arquitetura
  (traduzir no Localizer? chave extra no DB?) e depois um lote 2D. Item mais
  visível que falta: nome de item no inventory/tooltip.
- **OptionButton/TabContainer**: itens via API (não propriedade) — o seletor de
  idioma já trata os próprios itens manualmente; abas da Settings continuam em EN
  até estender o pass (pequeno).
- Revisão de tom: os lotes seguiram registro MMO direto ("você"); uma leitura
  final humana por cidade antes do soft-launch é barata e recomendada.
