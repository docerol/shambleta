# Community roadmap — o que a comunidade do gênero gosta (pós-beta)

**Status:** proposta (2026-09-18), não definição. Números são ponto de partida
p/ tuning com dados do beta — mesmo padrão de `XP_PROGRESSION.md`/`MONETIZATION.md`.
**Tudo aqui é pós-beta fechado** (ver `BETA_DEBT.md`); nada entra sem decisão do
dono marcada em cada item. Ordem sugerida: R1 → R2 → R3 → R4 (custo/benefício).

Convenção de implementação (não reinventar): mutação econômica em transação ACID
com espelho no `ledger_transaction`, schema novo só via migration sequencial em
`data/conf/migrations/`, suíte nova em `tests/IdleTests.gd` por feature, conta
derivada da sessão nos RPCs (padrão auditado na rodada beta).

---

## R1. Referral — código de convite com recompensa por marco (S, ~3–5 dias)

**Por que primeiro:** aquisição mais barata do gênero; ~70% reaproveita
sistemas existentes (ledger, grant, fraud_flag, e-mail verificado).

- **Mecânica proposta:** toda conta ganha um código (`username#XXXX`, gerado no
  cadastro, migration `account.referral_code UNIQUE` + `referred_by` + flag de
  resgate). Convidado informa o código no cadastro (ou em até 72h, página da
  conta). Recompensa **por marco, não por cadastro**: convidado atinge L10 +
  e-mail verificado → ambos recebem (proposta: 200 gems cada, dono confirma).
- **Anti-farma (o ponto que decide se presta):** marco L10+verificação já
  elimina conta fantasma barata; mesmo fingerprint/IP em massa cai no
  `fraud_flag multi_account` existente (revisão manual); teto proposto de 10
  indicações premiadas/semana por conta; auto-referral bloqueado
  (`referred_by != account_id`, mesmo e-mail/IP não ganha).
- **Implementação:** migration 031; `EconomyService.GrantReferralBonus` (transacional,
  idempotente por `(inviter, invitee)`); checagem no marco (hook no level-up ou
  job diário — reaproveitar `RunFraudScan`-style); RPCs `GetReferralState`/
  campo no cadastro; `SuiteReferral` (marco, duplicata, auto-referral, teto).
- **Aceite:** indicado ativa → ambos creditados 1×; farma de 20 contas no mesmo
  dispositivo gera flags, não gems.
- **Decisão do dono:** valores (200 gems?), teto semanal, janela de 72h.

## R2. Loja gold → consumíveis — vendor de poções (S, ~3–5 dias)

**Por que segundo:** fecha o circuito do gold (hoje gold só sai em guild/copa/AH/
crafting) e dá motivo diário de login sem tocar em monetização.

- **Mecânica proposta:** aba "Suprimentos" na `Shop` (ou diálogo de NPC vendor —
  mesma função, sem cena nova se preferir): poções de HP/mana por gold
  (proposta: 50/120/300 por tier, stack), pergaminho de retorno à cidade
  (proposta: 200), **não** vender chaves de boss (canibaliza gems/ads) nem nada
  com poder permanente. Estoque diário por item (proposta: 20/dia) + reset no
  boundary das missões; preço fixo, sem reroll.
- **Anti-P2W:** consumível = conveniência/tempo, mesma categoria já aprovada em
  `MONETIZATION.md §0.3`; nada de multiplicador, essência ou acesso a zona.
- **Implementação:** catálogo gold em const (`GOLD_CATALOG`, preço só server-side);
  `EconomyService.BuyGoldOffer` (débito gold + grant item + ledger, mesma forma
  de `BuyDailyOffer`); UI reaproveita `dailyBox`; `SuiteGoldVendor` (saldo
  insuficiente, estoque diário, preço server-side ignora cliente).
- **Aceite:** compra com gold funciona offline do companion; ledger `gold_offer:*`.
- **Decisão do dono:** lista inicial, preços/estoques, NPC vs. aba da Shop.

## R3. Eventos temporários rotativos — framework + 2 primeiros (M, ~1–2 semanas)

**Por que terceiro:** retenção (D7/D30) e conversa da comunidade; o framework
serve todos os eventos futuros.

- **Mecânica proposta:** tabela `live_event` (id, kind, starts_at, ends_at,
  params_json) + estado servido ao client (banner + modificadores ativos).
  Lançar com 2 kinds: **Fim de semana 2× drops** (multiplicador no settle/sim,
  mesmo eixo dos bônus VIP/ads) e **Semana do ferreiro** (taxa de crafting
  −50%). Calendário anunciado com ≥7 dias (mesma regra das seasons).
- **Anti-farma/P2W:** evento nunca vende acesso nem multiplica essência/favor;
  bônus de evento soma no mesmo `mods` do settle (auditável no relatório).
- **Implementação:** migration 032; hook no job diário (`RunReconcileJob`-style)
  ativa/encerra por timestamp; `GetActiveEvents` no estado da conta;
  `SuiteLiveEvents` (fora da janela = sem efeito; sobreposição resolve por
  prioridade determinística; replay do job idempotente).
- **Aceite:** evento ativo aplica o modificador; expirado some sozinho; dois
  eventos nunca somam de forma não-documentada.
- **Decisão do dono:** calendário dos 2 primeiros, valores, quem opera (manual
  via GM com tabela vs. agenda fixa em código — propor GM com tabela).

## R4. Arena assíncrona antes de qualquer PvP síncrono (M agora, síncrono depois)

**Posição técnica:** PvP síncrono real (lockstep, CCU de simulação, anti-cheat
de input) é o item mais caro desta lista (XL, redesenho de netcode) e o de
menor retorno garantido. O gênero resolve 90% do desejo com **arena assíncrona**,
que cabe na arquitetura atual (servidor simula os dois lados).

- **Mecânica proposta (assíncrona):** defesa = formação salva do jogador;
  ataque = ticket diário (proposta: 3/dia, +1 p/ VIP — tempo, não poder);
  resultado pela simulação existente, sem RNG do cliente; ranking por ELO
  simplificado com reset semanal e recompensa em cosméticos/títulos (nunca
  gems em volume nem poder). Derrota da defesa não tira nada do defensor
  (atacar é sempre seguro psicologicamente — lição do benchmark AFK).
- **Implementação:** migration (arena_entry, arena_ladder); `ArenaService`
  reaproveitando `IdlePolicy`/snapshot de luta do boss; RPCs `ArenaAttack/
  ArenaBoard`; `SuiteArena` (ticket, ELO soma-zero, defesa offline válida,
  replay idempotente).
- **Síncrono (pós-tudo):** só com CCU e time que justifiquem; exige spike de
  netcode antes de qualquer compromisso. Registrar como "não" por padrão.
- **Aceite:** atacar/defender funciona offline do oponente; ELO conserva pontos;
  nenhum item/gold muda de mãos fora do previsto.
- **Decisão do dono:** assíncrona entra no roadmap? Síncrono fica fora por
  escrito?

---

## O que NÃO fazer (limites desta lista)

- Nada de poder vendável, essência/favor por qualquer via paga, zona atrás de
  paywall (`MONETIZATION.md §0` continua valendo p/ os 4 itens).
- Nada de moeda nova, herói novo ou modo novo além do R4-assíncrono.
- Housing/customização 3D e co-op síncrono: backlog distante, fora deste plano.
