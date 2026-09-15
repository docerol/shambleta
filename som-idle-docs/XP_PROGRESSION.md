# XP_PROGRESSION — SOM-IDLE

Contrato da curva de progressão (XP, ouro, par de kills/hora) por zona de
farm. Reconstruído em 2026-09 a partir de `sources/idle/FarmZoneData.gd` e
do `som-idle-docs/D1_GATE_REPORT.md`, para fechar a lacuna de este arquivo
ser citado no código (§4.1.1, §4.1.2, §4.1.3) sem existir no repositório.

## §4.1.1 — Banda de pacing em tempo real

Piso honesto **30 kills/h**, teto de sanidade **200 kills/h** (gate de teste
automatizado, `tests/IdleTests.gd`). Medido saudável nesta máquina de
referência: ~80 kills/h standalone na zona 1 (mundo limpo), 36–48 kills/h em
suíte completa sob carga concorrente. Ver `som-idle-docs/D1_GATE_REPORT.md`
para o histórico completo da recalibração (o piso antigo de 60/h nunca
passou nem no commit que o definiu; causa raiz era um bug de dois relógios,
não uma mudança de pacing real — corrigido, ver `TECH_SPEC_CORE.md §3`).

Esta é a banda **medida no clock de jogo**, após a correção do bug de dois
relógios. Qualquer relato de taxa fora dessa banda deve ser tratado como
regressão de pacing e disparar o gate D1, não recalibrado sem investigar a
causa primeiro.

## §4.1.2 — Curva por zona

24 zonas de farm reais (`ZONE_COUNT = 24`), agrupadas em 8 tiers de 3 zonas
cada (`ZonesPerTier = 3`, `MAX_TIER = 8`). Fórmulas, para zona `z` (1-indexed):

| Grandeza | Fórmula | Zona 1 | Zona 24 |
|---|---|---|---|
| Tier | `ceil(z / 3)`, limitado a `[1, 8]` | 1 | 8 |
| XP por kill | `round(1200 × 1.25^(z-1))` | 1200 | ≈ 209 232 |
| Ouro por kill | `round(xpPerKill / 8)` | 150 | ≈ 26 154 |
| Par (kills/h) | `round(3600 / (24 + 0,9×(z-1)))` | 150/h | ≈ 96/h |
| Ouro/h (par) | `parKillsPorHora × ouroPorKill` | 22 500 | ≈ 2 511 000 |
| Poder mínimo | `24 + 8×(z-1)` | 24 | 208 |

Notas de calibração:
- A curva de XP é geométrica (crescimento de **25% por zona**), a de par é
  harmônica decrescente suave (zona funda ainda rende kills, só mais devagar
  — não existe zona "travada" por pacing, só por poder mínimo/gear).
- `MinPower` é uma escada suave amarrada ao poder nu do nível-intenção da
  zona (ajuste medido: poder nu ≈ `14 + 10,7 × nível`). Equipamento soma
  ataque/defesa ao poder, permitindo "socar acima" do nível nu da zona —
  esse é o loop de gear pretendido para zonas fundas.
- O catálogo de 24 zonas veio de uma recalibração contra o dump real de
  mapas/mobs (`tests/dump_calibration.gd`): dos mapas originais, só 28 têm
  mobs e seu nível satura em L20; as 4 salas de boss nomeado saíram do
  rodízio de farm normal e viraram conteúdo de boss-key
  (ver `ECONOMY_STUDY.md §6`). As 24 zonas restantes foram reordenadas por
  dificuldade monotônica (o catálogo antigo de 40 zonas tinha 12
  placeholders sem mapa real e ordem não-monotônica).

## §4.1.3 — Boost de novato

`NewbieBoostFactor = 5` (multiplicador de 5×) aplicado até
`NewbieBoostMaxLevel = 10`. Existe para comprimir o início da curva e levar
o jogador novo ao primeiro loop de gear/trade rapidamente, sem precisar
tocar a curva base das zonas fundas (que serve ao jogador retido).

## §5. Uso pelo `OfflineSettle`

`xpPerKill` e `parKillsPorHora` desta curva são os dois insumos diretos da
fórmula de liquidação offline (ver `ECONOMY_STUDY.md §5`): o par precisa
casar com a taxa online real para que o ganho offline (60% do par, por
`OfflineFactor`) seja percebido como proporcional pelo jogador, não como um
valor arbitrário.

## Pendência de design (não é gate, é meta de conteúdo)

150 kills/h de par na zona 1 é citado nos commits como **meta de conteúdo**
(densidade de spawn desejada), não como gate de teste — o gate real é a
banda 30–200/h do §4.1.1, medida no agregado das zonas testadas. Ver item 15
da auditoria comercial (`auditoria-shambleta-idle-comercial.md`): o loop de
progressão de médio prazo (jogador em zonas tier 5+, semana 2 em diante)
ainda depende do loop de gear ser validado com jogadores reais, não só a
curva matemática aqui descrita.
