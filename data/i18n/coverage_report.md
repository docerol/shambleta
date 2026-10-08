# I18N Coverage Report — cliente Shambleta (pt_BR)

Gerado por `tools/extract_i18n.py`. Fontes: tr()/Mes() em `sources/`, atribuição literal de `placeholder_text`, `title`, `text` (props lidos de `Localizer.TrackedProps`) em .gd e em `presets/gui/**/*.tscn`. A tradução de cena acontece no runtime (`Localizer.gd`), não no engine.

| Domínio | Chaves | Cobertas pt_BR | Faltando |
|---|---|---|---|
| tr() código (UI) | 98 | 98 | 0 |
| text= .gd (UI, via Localizer; props placeholder_text/title/text) | 71 | 71 | 0 |
| cenas .tscn (via Localizer) | 167 | 167 | 0 |
| conteúdo NPCs/quests (fase 2) | 732 | 732 | 0 |

**UI total:** 321 chaves, 321 cobertas (100%), 0 faltando. **Conteúdo:** 0 chaves pendentes (fase 2 — diálogos NPC em `sources/scripts/`).

Das cobertas, **19** contam-se por a fonte já estar em português (o `tr()` devolve a chave; a coluna `en` dessas linhas é que carrega a tradução) — listadas ao final, uma a uma.

## Cobertas por fonte em português (UI)

Linhas onde o texto-fonte já é português: o jogador BR vê a chave, e o que existe para conferir é o `en` da linha.

- Atualizar → en: Refresh
- Busca por nome, filtro por tipo e teto de preço. Histórico: últimas 10 vendas da sessão. → en: Search by name, filter by type and price cap. History: the last 10 sales of this session.
- Cancelar → en: Cancel
- Comprar key → en: Buy key
- Confirmar → en: Confirm
- Corromper → en: Corrupt
- Cubo 3:1 → en: 3:1 Cube
- Desmanchar → en: Disassemble
- Eventos → en: Events
- Forja → en: Forge
- Guilda → en: Guild
- Histórico: nenhuma venda nesta sessão. → en: History: no sales this session.
- Iniciar rush (1 key) → en: Start rush (1 key)
- Leilão → en: Auction
- Leilão — Grand Exchange → en: Auction — Grand Exchange
- Nome do item → en: Item name
- Reler catálogo → en: Re-read the catalog
- Submeter à forja → en: Submit to the forge
- ⚡ INTERRUPTAR → en: ⚡ INTERRUPT

