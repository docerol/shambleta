# REBALANCE_XP_OPTIONS — decisão de owner: a parede pós-L70

Data: 2026-07 · Depende de: `XP_PROGRESSION.md` (curva vigente) · Gera decisão para `ROADMAP.md` Fase 2

## O problema (quantificado, jogo como está)

Custo: `XP(L→L+1) = 8000 × 1.22^L`, cap `MAX_LEVEL 150`.
Renda: satura na zona 24 (`1200 × 1.25^23 ≈ 209k/kill`, ~96 kills/h ≈ **20,1M XP/h**).
Expoente da renda (0, na zona 24 — é fixa) vs 1,22 do custo ⇒ parede.

| Dias de farm ótimo (24/7) | L atual | | Nível | tempo real p/ passar |
|---|---|---|---|---|
| 1 | 45 | | L60 | 17 d |
| 7 | 55 | | L70 | 4,1 meses |
| 30 | 62 | | L80 | 3 anos |
| 90 | 68 | | L100 | 134 anos (inalcançável) |

Assunções: boost novato ×5 (L<10), gate de zona por poder nu `14+10,7L`, sem mortes,
sem gear. Jogador humano (offline 60%/cap 12h) ≈ ×1,25 nos tempos.

## Opção A — renda escala com o nível (treadmill)

Para manter saúde de pacing o multiplicador de XP-por-kill precisa:

| Nível | ritmo-alvo | M exigido | composto |
|---|---|---|---|
| L60 | 24 h/nível | ×3 | +1,9%/L |
| L80 | 72 h/nível | ×55 | +5,1%/L |
| L100 | 6 d/nível | ×1 468 | +7,6%/L |
| L150 | 30 d/nível | ×6,1 mi | +11,0%/L |

Multiplicador "meio" (`1.055^L`) só **empurra** a parede: L100 em 10 meses ✔, L120 em 15 anos ✘.
Regra honesta: para tempo/nível chato, M tem de crescer ≈ `1.22^L` (casar o expoente do custo),
ou o cap de nível precisa existir de verdade.

- Custo de implementação: baixo (um multiplicador no `FarmZoneData.xpPerKill` por profundidade
  de "eternidade/loop" das mesmas 24 zonas).
- Riscos: acopla inflação ao ouro (`gold=xp/8` → precisa desacoplar); números incham (trilhões
  na UI: precisa notação 1.2e6, fonte/formato já tratados no idle? conferir); sem reset, o
  jogador nunca "conclui" nada — a parede vira a UI.
- Quem usa: **NGU Idle** (paredes infinitas com multiplicadores nomeados), **Diablo III/IV**
  Greater Rifts (monstros e recompensa escalam ∝ push — a literalidade de A), **Path of Exile**
  (XP do mob escala com tier do map/devouring).

## Opção B — prestige / renascimento (cap L60)

Cap = onde a renda ainda sustenta (L60: 17–21 d o primeiro ciclo). Reset de nível em troca de
bônus permanente. Simulado com +25% de renda composto:

| ciclo | duração | acumulado | | variante RO (bônus em stat, não em XP): |
|---|---|---|---|---|
| 1 | 20,9 d | 21 d | | ciclo constante ~17 d |
| 5 | 8,6 d | 2,3 m | | 12 ciclos ≈ 7 meses |
| 12 | 1,8 d | 3,2 m | | ciclo 20 ≈ 1 ano |

**Achado**: com bônus composto na própria renda XP, a série **converge** (Σ → ~3,5 meses) — o
motor de prestige queima combustível sozinho. Jogos que duram decades em prestige usam uma de
duas defesas: bônus não-composto no XP (RO/TOS: cada renascer ~mesmo tempo, poder vem de stats
novos) ou curva de custo do bônus superlinear (Cookie Clicker/NGU: o multiplicador existe mas
custa cada vez mais "moeda de prestige").

- Custo de implementação: médio (reset de stats/sessões, moeda de prestige, UI de confirmação,
  ledger no economy — todo o machinery LGPD/settle já existe).
- Riscos: reset sem compensação VISÍVEL (título/moldura/estatística "ciclo 7") = churn. Precisa
  de 1ª classe no ledger (`LedgerKindPrestige`).
- Quem usa: **Ragnarok Online** (rebirth: 1ª→2ª classe, o modelo histórico), **Tree of Savior**
  (renascimentos por faixa de nível), **Cookie Clicker** (Ascension), **Idle Heroes/AFK Arena**
  (camadas de ascensão), **Melvor Idle** (não-composto por design).

## Opção C — soft-cap + endgame fora da curva (L60–70)

Nível congela em ~L60 (alcançável em ~3 semanas ativas — dado real da tabela baseline);
excedente de XP converte em moeda do endgame. No cap, a renda é estável: 20,1M XP/h ≈
**482M XP/dia** → taxa de conversão define a economia do endgame (ex.: 1% = 4,8M essence/dia
para financiar escadas de boss/guild/pass).

O jogo já tem as pontas prontas: **bosses escalam com o nível do char** (dado do código:
"boss escala com o nível do char"), 4 boss-keys, `GuildMaxLevel 10`, seasons no ROADMAP Fase 4.
Level vira *statística de porte* — como Lost Ark, onde depois do cap quem joga é o item score.

- Custo de implementação: médio-baixo (conversor de overflow + loja/escada de essence +
  ladder sazonal com reset de *ranking*, não de progresso).
- Riscos: sem progressão visível no endgame (boss tiers finitos) a temporada morre no mês 2 —
  precisa do rodízio de seasons para existir de verdade antes do beta.
- Quem usa: **Clash Royale** (cap de nível de carta → stars/swap), **Brawl Stars** (overflow →
  coins), **AFK Arena** (Paragon: excedente vira nível paragon contínuo), **Lost Ark** (cap de
  nível + item score), **Diablo III/IV seasons + Path of Exile leagues** (ladders sazonais — o
  lado "season" da opção), **WoW** (squish + cap + Mythic+ = C com 20 anos de histórico).

## Híbrido padrão-de-mercado (o que os idle bem-sucedidos entregam)

Na prática A, B e C não são excludentes — o cânone do gênero (AFK Arena, Idle Heroes, Raid):
**C no topo** (cap visível + endgame boss/season) + **B embaixo** (ascension/prestige que dá
multiplicador PERMANENTE, o que torna A supérflua: a cada ciclo o jogador re-farma as mesmas
zonas com M maior, e M vem de prestige, não de treadmill forçado). Tempo-alvo do ciclo 1
intenção de design a escolher (sugestão de contrato: 3 semanas → cap L60, ciclo decresce a
~40% do anterior, plateau em ~2 d/ciclo como motor de longo prazo com custo superlinear).

## Recomendação para decisão

1. Escolher cap do ciclo-1 (L60 ⇒ ~3 sem; L70 ⇒ ~4 meses — L70 cedo demais p/ prestige).
2. Adotar B como motor de renda crescente (bônus atrelado a moeda de prestige com custo
   superlinear, não composto direto no XP — tabela do achado acima).
3. Adotar C como teto de engajamento (overflow → essence; bosses como escada; seasons no
   ledger desde o dia 1).
4. A só se quisermos números infinitos explícitos (postura NGU) — incompatível com o tom
   "MMO idle arrumadinho" do branding; desaconselhada como eixo único.

Alterar `Experience.gd`/`FarmZoneData.gd` depois desta decisão = commit próprio com
recalibração dos gates da suíte D1 (piso 30/teto 200 kills/h não muda; a banda mede o clock
de jogo, não a economia).
