# ELEMENTAL_COMBAT — Poison, Bleed, Burn e resistências elementais

Contrato do sistema de dano elemental e efeitos de status implementado em 2026-09.
Mecanismo (código) está pronto e ligado ao pipeline de dano real; **números de
conteúdo/balanceamento são proposta inicial, não veredito** — mesma postura de
`XP_PROGRESSION.md`/`ITEM_CRAFTING.md`: fórmula documentada, pendências marcadas
para você decidir com playtesting real.

Relacionados: [ITEM_CRAFTING.md §3.3](ITEM_CRAFTING.md) (o pedido de poison/bleed
que motivou este sistema) · `sources/combat/ElementCommons.gd` (implementação) ·
`sources/skill/SkillCommons.gd`/`Skill.gd` (pontos de integração).

---

## 1. O que existe agora

**Dano elemental instantâneo** (Fire/Ice/Lightning): bônus plano somado ao dano
base do golpe (`Skill.GetDamage`), mitigado pela resistência correspondente do
alvo. Funciona exatamente como Attack/Defense já funcionavam — vem do
equipamento, sem fórmula de atributo própria.

**Efeitos de status (Poison/Bleed/Burn)**: dano ao longo do tempo, só existem em
arma (chance + poder são stats de equipamento, nunca inatos ao personagem).
Um acerto rola cada um dos três independentemente — uma única arma pode ter
mais de um efeito. Burn é mitigado pela resistência de Fire (é o DoT do fogo,
não tem resistência própria).

**Resistências**: 5 stats novos (Fire/Ice/Lightning/Poison/Bleed), tetados em
75% (`Formula.ResistCap`) — nenhum elemento pode ser totalmente anulado, para
que resistência nunca vire imunidade total e apague um tipo de dano do jogo.
Reduzem tanto o dano instantâneo/de tick quanto a chance de proc (proporcional
à resistência).

## 2. Política de reaplicação (stack)

Uma nova aplicação do mesmo status **sempre substitui** a anterior (duração e
poder frescos), nunca acumula. Mais simples de balancear e de explicar ao
jogador do que "fica com a mais forte" — a alternativa existia e foi descartada
por esse motivo, registrada aqui para não ser redescoberta como pergunta em
aberto depois.

## 3. Por que os multiplicadores/valores não vêm de fórmula de atributo

Attack/Defense escalam com `strength`/`vitality` e nível (`Formula.gd`) porque
são a progressão central do personagem. Dano elemental e chance/poder de status
**não** escalam assim de propósito: eles são 100% dependentes do equipamento
que o jogador escolhe vestir. Isso é o que torna "montar um build de veneno"
uma decisão de gear, não um efeito colateral automático de subir de nível — e é
consistente com `ITEM_CRAFTING.md §0`: poder vem de tempo investido em craftar/
dropar o equipamento certo, não de um multiplicador que todo mundo ganha igual.

## 4. Proposta de calibração (pendente de playtesting)

Sem dados de combate real para calibrar contra, ancorei a proposta na mesma
curva de Attack já usada em `ITEM_CRAFTING.md §3.2` (`20 × (1 + 0,20×(tier−1))`)
— ou seja, um item elemental de tier X deveria valer, em dano equivalente, o
mesmo que um item físico puro do mesmo tier, para não criar um "build
elementar objetivamente melhor" só por escolher o tipo de dano.

| | Proposta |
|---|---|
| Dano elemental instantâneo (Fire/Ice/Lightning) | Mesma escala do Attack por tier — um item 100% elemental deveria ter dano elemental ≈ ao Attack que um item físico do mesmo tier teria |
| Poder total de DoT (Poison/Bleed/Burn) | ≈ 1,5× o dano-de-um-golpe equivalente, espalhado em 4 ticks (`TickCount`) de 1s — DoT vale mais que um hit porque exige o alvo ficar vivo tempo suficiente para render tudo, e contra farm idle (que já mata rápido) isso é uma penalidade natural, não um bônus escondido |
| Chance de proc | 15–30% por golpe, calibrável por item — o exemplo criado (`Venom Dagger`, tier 2) usa 25% de chance e poder 18 (≈ o Attack de um item tier 2) |
| Resistência inicial de personagem | 0% em tudo — resistência só vem de gear, igual dano |
| Resistência de monstro | **Não incluída nesta versão.** Todos os mobs existentes ficam em 0% de resistência (comportamento idêntico a antes do sistema existir) até haver uma decisão deliberada de quais monstros deveriam ser resistentes a quê — dar resistência default a mobs por fórmula de tier, sem tema (ex. "monstro de fogo resiste a fogo"), seria número investido em uma direção sem sentido de conteúdo por trás |

## 5. Decisões que ficam com você

1. **Confirmar a curva de calibração da tabela acima** — é uma proposta
   ancorada na curva de item já existente, não testada em combate real.
2. **Quais monstros ganham resistência, e a quê** — hoje é 0% em todos; dar
   tema (mobs de fogo resistem a fogo, mobs "podres"/mortos-vivos resistem a
   poison, etc.) é decisão de conteúdo, não de engine.
3. **Se `TickCount`/`TickInterval` (4 ticks de 1s = 4s de duração) fazem
   sentido para o ritmo do farm idle** — um DoT mais longo que isso compete
   mal com o piso de dano do farm (`FarmDamageFloor`, já mata mob rápido);
   mais curto que isso pode não valer a pena rolar.
4. **Se dano elemental deveria também contar para `Formula.GetPowerScore`**
   (usado no farm/pacing) — hoje não conta, só Attack/Defense entram nesse
   score; itens elementais ficariam "invisíveis" para qualquer sistema que
   meça poder por esse score até isso ser decidido.

## 6. O que foi implementado (mapa de arquivos)

| Arquivo | Mudança |
|---|---|
| `sources/cell/CellCommons.gd` | 14 novos `Modifier` (dano/resist/chance/power elementais) |
| `sources/actor/stat/BaseStats.gd` | 8 campos novos (dano/resist — chance/power ficam só em equipamento) |
| `sources/actor/stat/Formula.gd` | Getters dos 8 campos + `ResistCap` |
| `sources/actor/Stats.gd` | Wiring em `RefreshEntityStats()` |
| `sources/actor/ActorCommons.gd` | `Alteration.POISON/BLEED/BURN` (display do tick no client) |
| `sources/actor/agent/BaseAgent.gd` | `activeStatusEffects`, limpeza em `Killed()` |
| `sources/combat/ElementCommons.gd` | **Novo** — todo o mecanismo (dano instantâneo, proc, tick, resist) |
| `sources/skill/SkillCommons.gd` | `GetDamage()` soma dano elemental antes do crit/dodge |
| `sources/skill/Skill.gd` | `Damaged()` rola procs de status após um golpe confirmado |
| `presets/cells/items/weapon/VenomDagger.tres` | **Novo** — item de exemplo (25% chance, poder 18 de poison), reaproveita sprite/paleta do Gladius |

Não executei isto em um editor Godot (sem o binário disponível no ambiente em
que escrevi) — antes de mergear, rodar `tests/run_idle_tests.gd` (ver suíte
`SuiteElementalCombat` em `tests/IdleTests.gd`) e abrir o projeto no editor ao
menos uma vez para confirmar que o `.tres` novo importa sem erro.
