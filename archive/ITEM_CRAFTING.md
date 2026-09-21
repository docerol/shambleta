# ITEM_CRAFTING — Criação de itens por jogadores (versão gold; RMT adiado)

Contrato de design para a feature de criação de itens pelo jogador. Decisão de escopo (2026-09):
**versão 1 usa apenas gold** (moeda fechada, já existente); a venda em BRL/cripto com split payment
foi levantada como intenção final, mas fica **fora de escopo aqui**, registrada como pendência de
dono em §10, sujeita a assessoria jurídica especializada (direito regulatório de jogos/apostas e
de ativos virtuais) antes de qualquer arquitetura.

Relacionados: [MONETIZATION.md §0](MONETIZATION.md) (guardrails anti-P2W, testados contra este
sistema) · [ECONOMY_STUDY.md](ECONOMY_STUDY.md) (trade fee, invariantes de ledger) ·
[XP_PROGRESSION.md](XP_PROGRESSION.md) (curva de tier/zona) · [ROADMAP.md](ROADMAP.md) (Fase 4 —
AH com listagem em gold, pré-requisito de §7).

---

## 1. Resumo da decisão

O jogador desenha um item (slot, nome, alocação de stats dentro de um orçamento por tier), paga
uma taxa em gold para submeter, um GM aprova o nome/conteúdo, e o item aprovado **entra no pool de
drop compartilhado da(s) zona(s) do tier correspondente** — qualquer jogador, pagante ou não, pode
dropá-lo depois disso. O criador recebe uma cópia garantida na aprovação e uma fee de revenda
(1%, em gold) toda vez que o item trocar de dono depois — mecanismo que só liga de fato quando o
AH (Fase 4) existir, ver §7.

Este desenho passou no teste do `MONETIZATION.md §0` porque **o efeito (o item em si) é alcançável
por qualquer F2P jogando** — pagar compra o direito de desenhar uma peça de conteúdo e uma fee de
criador, não uma vantagem exclusiva de stats.

## 2. Fluxo do jogador

1. Abre a janela de criação (nova UI, sem precedente no client — mais perto de "Formation
   Builder" que de uma janela de loja existente).
2. Escolhe **slot** (arma, peito, pernas, mãos, cabeça, pés, escudo, pescoço — os mesmos 8 slots de
   equipamento já existentes em `ActorCommons.Slot`).
3. Escolhe um **sprite-base** entre os itens já existentes daquele slot (reaproveita textura/ícone/
   shader de paleta — ver §4). Puramente visual, não herda os stats do item-base escolhido.
4. Digita um **nome** (fica em estado "pendente" até aprovação de GM — ver §5).
5. Aloca stats dentro do **orçamento do tier** (ver §3) — ex.: Attack, Defense, CritRate, um
   "poison"/"bleed" como efeito de dano ao longo do tempo se esse modifier existir (ver nota em
   §3.3 sobre modifiers ainda não suportados pelo motor).
6. Confirma e paga a **taxa de submissão em gold** (sink — ver §8).
7. Item entra em fila de aprovação. Enquanto pendente, existe só como cópia do criador, **não
   equipável, não tradeável, não entra no drop pool**.
8. GM aprova → item vira membro permanente do `ItemsDB` (ver §6), a cópia do criador destrava,
   `creator_account_id` fica gravado no registro do item para sempre (ver §7).
9. GM rejeita → taxa de submissão **não é reembolsada automaticamente** (ver §5.3 sobre por quê) e
   o jogador pode reenviar com nome/stats ajustados.

## 3. Orçamento de poder e raridade

### 3.1 O que os dados reais mostram (e não mostram)

Extraí os modifiers dos 65 itens `.tres` existentes por slot e tier. Achado central, que muda o
desenho: **a cobertura de tiers é muito esparsa fora do tier 1**. Armas vão só até tier 5 (Attack
20 no T1 → 100 no T5); todos os outros slots de equipamento (peito, pernas, mãos, cabeça, pés,
escudo) têm dado real **só no tier 1** (Defense 1–20 dependendo do slot) mais um único ponto de
peito em T2 (Defense 30). **Não existe nenhum item real de tier 6, 7 ou 8 no catálogo atual**,
mesmo a progressão idle (`XP_PROGRESSION.md`) já cobrindo os 8 tiers.

Isso significa que não dá para "olhar o item real do tier X e copiar o teto" para a maior parte da
tabela — a maioria das células não tem precedente. A tabela abaixo é *derivada por fórmula*, não
observada, e precisa de aprovação do dono antes de virar número de produção (ver §10).

### 3.2 Fórmula proposta (ancorada na curva que já existe)

Para manter o item criado no mesmo ritmo de poder que o resto do jogo já usa, ancorei o
crescimento por tier no mesmo formato de `MinPower` de `XP_PROGRESSION.md` (`24 + 8×(tier-1)` por
*zona*, aqui adaptado por *tier* de item) em vez de inventar uma curva nova:

```
OrçamentoPrincipal(tier)   = round(AttackBaseT1 × (1 + 0,20 × (tier − 1)))   # arma, stat primário
OrçamentoSecundário(tier)  = round(DefenseBaseT1 × (1 + 0,20 × (tier − 1)))  # armadura, stat primário
```

Com `AttackBaseT1 = 20` (igual ao Piou Slayer/Short Sword reais) e `DefenseBaseT1` variando por
slot conforme a tabela §3.1 (ex.: peito 20, mãos 15, cabeça 5, pés 5, escudo 20 — usando o maior
valor real observado em cada slot no T1 como piso, não a média, para não *rebaixar* o que já
existe). Resultado, arma (Attack), como exemplo de leitura da fórmula:

| Tier | Orçamento total (arma) |
|---|---|
| 1 | 20 |
| 2 | 24 |
| 3 | 28 (bate com o Gladius real: Attack 50 + AttackRange 16 → confirma que a fórmula de *stat único*
    subestima itens reais com múltiplos rolls; ver §3.3) |
| 4 | 32 |
| 5 | 36 |
| 6 | 40 |
| 7 | 44 |
| 8 | 48 |

**Isso não bate com os itens reais de T3–T5**, que já somam 50–100 de Attack sozinho. Ou seja, a
fórmula linear simples §3.2 fica **abaixo** do que já é jogável — usá-la como está criaria itens
piores que os já existentes, o oposto do risco de P2W, mas ainda um problema (ninguém ia querer
pagar por um item pior). **Isto precisa de recalibração por quem decide o número final** — deixei
a fórmula e o gap documentados aqui em vez de inventar uma curva que pareça arbitrária.

### 3.3 Múltiplos stats e o teto por item (não só por stat)

Itens reais frequentemente têm 2 stats (Attack + AttackRange, Attack + CastDelay). Proponho
orçamento como **pontos totais**, com uma tabela de câmbio entre modifiers (1 ponto de Attack ≠
1 ponto de CritRate) — os pesos relativos precisam ser calibrados por quem já testou o combate
(fora do escopo deste documento, é um dado de gameplay, não de economia). Regra de teto: **a soma
ponderada dos stats escolhidos nunca excede o orçamento do tier**, e o teto é fixado no **maior
item real já existente daquele tier/slot**, nunca na média — para que um item criado nunca seja
provavelmente melhor que o melhor item já dropável daquele tier (evita power creep silencioso à
medida que mais itens forem criados e entrarem no pool compartilhado).

**Nota sobre "poison (1–5)" e "bleed (1–5%)" do seu exemplo:** o motor atual (`CellCommons.Modifier`)
não tem efeito de dano ao longo do tempo — a lista de 23 modifiers cobre stats diretos (Attack,
Defense, CritRate, DodgeRate, regen, etc.), não status de veneno/sangramento. Dá pra simular via
`RegenHealth` negativo persistente equipado (dano contínuo), mas isso é indistinguível de "perder
vida regenerando ao contrário" no sistema atual — **efeitos de status tipo Diablo (poison/bleed
como debuff aplicado ao alvo, com duração própria) não existem hoje e são uma peça de combate nova,
não só de economia**. Se isso for essencial pro pitch do sistema, é um pré-requisito técnico
separado, maior que o sistema de criação em si.

### 3.4 Raridade como saída, não escolha

Consistente com o que você descreveu: raridade nunca é um campo que o jogador seta, é calculada a
partir de **quanto do orçamento do tier o item usa** — ex. `<40%` Comum, `40–65%` Incomum,
`65–85%` Raro, `85–97%` Épico, `>97%` Lendário (faixas de exemplo, ajustáveis). Isso mantém a
promessa "quanto melhor o item, maior a raridade" sem o jogador poder simplesmente clicar
"Lendário".

## 4. Reuso de sprite/template

Tecnicamente barato: cada `ItemCell` já carrega `textures`/`icon` e, opcionalmente, `shader`
(recolor de paleta — o motor já tem isso pronto, ex. `weapon-green-iron.tres`, `weapon-bone.tres`
recolorindo a mesma sprite base). O criador escolhe um item-base existente do slot escolhido só
para herdar essa parte visual (textura + paleta disponível para aquele slot); nome e modifiers do
item criado **não herdam** do template, só a aparência. Não precisa de arte nova para o v1.

## 5. Aprovação de GM

### 5.1 Infraestrutura nova necessária
Hoje só existe comando de GM síncrono, ao vivo, no mundo (`WorldCommands.gd`, ex. `/item`) — não
existe fila assíncrona nem painel. Este sistema precisa de: uma lista de itens pendentes (nova
permissão `GM` já existe, ver `ActorCommons.Permission`), visível fora do momento em que o GM está
logado como personagem no mundo — senão a aprovação trava toda vez que nenhum GM está online.

### 5.2 O que o GM revisa
Nome (ofensivo, marca registrada, se parece com item oficial de forma enganosa) e os stats
propostos (o orçamento em si é calculado automaticamente e travado pelo client/servidor, mas o GM
ainda deveria conseguir rejeitar um nome mesmo com stats válidos).

### 5.3 Política de reembolso (decisão de produto, não só técnica)
Cobrar a taxa **antes** da aprovação, sem devolver automaticamente em caso de rejeição, é o
desenho mais simples, mas cria fricção: jogador paga, espera, é rejeitado só pelo nome, precisa
pagar de novo para resubmeter com nome trocado. Alternativas: (a) a taxa cobre N resubmissões
dentro de X dias sem cobrar de novo (protege o jogador de erro de nome, não de tentativa de burlar
review), ou (b) validação automática de nome (lista de bloqueio + checagem de duplicata com nome
de item oficial) **antes** de cobrar, reduzindo rejeição de GM a casos realmente ambíguos. Recomendo
(b) como pré-filtro e (a) como rede de segurança — mas é decisão de produto, registrada como
pendência em §10, não resolvida aqui.

## 6. Integração no drop pool compartilhado

`FarmZoneData.GetDropPool(zoneID)` hoje monta o pool de uma zona filtrando `DB.ItemsDB` por banda
de tier `[tier, tier+1]` e sorteia **com peso uniforme** entre todos os itens do pool
(`pool[roll % pool.size()]` — cada item tem a mesma chance, não importa raridade). Dois pontos que
este sistema precisa resolver, ambos mudança de comportamento, não só "adicionar ao dicionário":

1. **`DB.ItemsDB` hoje só é populado uma vez, no boot, a partir de arquivos `.tres` estáticos.**
   Um item aprovado em runtime precisa de um caminho para entrar nesse dicionário (ou um dicionário
   paralelo que `GetDropPool` também consulte) sem reiniciar o servidor, e a cache de pool
   (`_dropPoolCache`) precisa ser invalidada na aprovação — o hook para isso já existe
   (`InvalidateDropPools()`), só falta o evento de aprovação chamá-lo.
2. **O sorteio é uniforme, não ponderado por raridade.** Sem mudar isso, um item Lendário criado
   teria a mesma chance de drop que um item Comum do mesmo tier — o que provavelmente não é a
   intenção (itens melhores deveriam ser mais raros de dropar, não só "mais caros de orçamento").
   Ponderar o sorteio por raridade é mudança na mecânica de drop que afeta **todos** os itens do
   jogo, não só os criados por jogador — vale medir impacto na curva de drop atual antes de mudar.

## 7. Creator fee de 1% (gold) — depende do AH

Não existe hoje mecanismo de **venda com preço**. O trade atual (`ExecuteTrade`) é escrow
item-por-item (troca, sem campo de preço); o AH com listagem em gold é Fase 4 do roadmap, ainda
não implementado. Proposta para não travar este sistema nessa dependência:

- **Desde a v1:** todo item criado grava `creator_account_id` permanentemente no registro do item
  (dado que precisa existir desde o dia 1, senão não dá para pagar o criador depois).
- **A fee de 1% só liga quando o AH existir**: no evento de venda do AH (preço em gold), 1% do
  valor da venda vai para `creator_account_id` (se o vendedor não for o próprio criador), o
  restante segue a regra de fee do servidor já desenhada para o AH. Zero trabalho duplicado —
  o gancho já fica pronto, só falta o AH para acionar.
- Sem AH, o creator fee simplesmente não paga nada no P2P atual (trocar item por item não tem
  preço para tirar 1% de) — isso é aceitável para uma v1, mas vale deixar claro para o jogador que
  a fee de revenda é sobre o **futuro AH**, não sobre trade direto, para não vender a feature com
  uma promessa que não paga ainda.

## 8. Anti-abuso e sinks

- **Taxa de submissão em gold**: sink, escala com o tier do item (item de tier alto = taxa maior —
  espelha o próprio ouro/hora que aquele tier já rende, para a taxa nunca ser trivial nem proibitiva).
- **Cap de criações por conta/dia ou por semana**: evita flood do pool compartilhado com itens
  quase-idênticos maximizando o orçamento (ver risco de power creep em §3.3).
- **Bloqueio de nome**: lista de termos proibidos + checagem de similaridade com nomes de itens
  oficiais (evita golpe de nome enganoso, tipo item fake se passando por um item raro real).
- Este sistema deveria entrar nos mesmos "RMT guards" já citados no roadmap (tier de conta,
  cooldown) — um item criado e aprovado entra na economia compartilhada, então merece a mesma
  cautela que trade já tem.

## 9. Escopo técnico (alto nível, sem código)

Sistemas tocados, para dimensionar o tamanho do trabalho antes de estimar:
- **Novo dado**: itens deixam de ser só estáticos — precisa de registro persistente por item
  criado (slot, nome, modifiers, tier, criador, status de aprovação), e um caminho para isso virar
  um `ItemCell` utilizável em runtime pelos mesmos sistemas que já leem `DB.ItemsDB` hoje
  (inventário, equip, trade, tooltip, drop pool).
- **Novo fluxo de UI**: janela de criação (nova), fila de aprovação de GM (nova — hoje GM só age
  ao vivo no mundo).
- **Mudança de comportamento em sistema existente**: `GetDropPool`/`GetDropForRoll` passam de
  uniforme para ponderado por raridade (afeta todo o jogo, não só itens criados).
- **Gancho pronto, sem uso ainda**: `creator_account_id` no item, sem lógica de pagamento até o AH
  existir.
- Nenhuma mudança em `ExecuteTrade` é necessária para a v1 (a fee de criador não usa esse caminho).

## 10. Pendências de dono (preciso da sua decisão antes de detalhar mais)

1. **Tabela de orçamento por tier/slot (§3.2)**: a fórmula proposta fica abaixo dos itens T3–T5
   reais — precisa de recalibração deliberada, não é algo que eu deveria fixar sozinho (é um número
   de balanceamento de combate, igual `XP_PROGRESSION.md` foi). Fica pendente até você decidir o
   método de recalibração.
2. **Pesos de câmbio entre modifiers** (§3.3): quanto vale 1 ponto de CritRate vs. 1 de Attack —
   dado de gameplay, não de economia.
3. **Efeitos de status (poison/bleed)** (§3.3): não existem no motor hoje. Confirmar se o v1 sai
   sem eles (só stats diretos) ou se isso vira pré-requisito de combate antes do crafting em si.
4. **Política de reembolso de taxa em rejeição** (§5.3): pré-filtro automático, janela de
   resubmissão grátis, ou cobrar de novo sempre — decisão de produto.
5. **Peso por raridade no sorteio de drop** (§6, item 2): confirmar que quer mudar o sorteio
   uniforme atual — é mudança que afeta todos os itens do jogo, vale ter certeza antes.

## 11. RMT (BRL/cripto) — status

Fora de escopo deste documento por decisão do dono (2026-09-16). Fica registrado aqui como
lembrete: qualquer trabalho nessa direção precisa passar por assessoria jurídica especializada em
direito regulatório de jogos/apostas e de ativos virtuais antes de qualquer arquitetura — ver a
análise completa na conversa que gerou este documento, resumida em três riscos: split payment em
BRL (factível via parceiro de pagamento, mas exige CNPJ formal), custódia/repasse de cripto (regime
de VASP, Lei 14.478/2022), e o risco mais sério — prêmio de RNG (baús/drops) tornando-se sacável em
dinheiro real aproxima o produto de enquadramento como jogo de azar (art. 50 da LCP).
