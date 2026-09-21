# Auditoria — Shambleta como Idle Comercial

**Repositório:** github.com/docerol/shambleta (branch master)
**Auditoria original:** 15/09/2026, commit `2364ada8`
**Esta revisão:** 15/09/2026, commit `7472e54c` — reverificação item a item após os commits `c77dd24e`, `6d50dffb` e `7472e54c`.

Esta revisão **não é uma auditoria nova do zero**: é a mesma lista de 15 itens, reconferida contra o estado atual do código e da documentação. Cada item recebeu um status. Dois itens da auditoria original estavam **superestimados** — a reverificação encontrou evidência de que já estavam mais resolvidos do que relatei da primeira vez; isso está registrado abaixo em vez de escondido.

**Legenda:** ✅ Resolvido · 🟡 Planejado/parcial (desenhado, não implementado) · 🔴 Ainda aberto · ⚠️ Correção de avaliação (eu estava errado no relatório original) · ❓ Não verificável a partir do clone local

---

## P0 — Bloqueadores

### 1. ToS proíbe o mecanismo central do jogo — ✅ Resolvido
Commit `6d50dffb` reescreveu a seção "Game Rules" do `agreement.json`: o auto-farm nativo agora é explicitamente descrito como a forma pretendida de jogar; o que permanece proibido é automação de terceiros (bots/macros externos) e multi-contas para multiplicar recompensa. A cláusula de jurisdição também foi corrigida (Brasil/CDC/LGPD, com placeholder aguardando revisão de advogado antes da publicação). O commit `c77dd24e`, na sequência, foi além do que eu tinha pedido: tornou o consentimento uma **comparação de versão real** (antes só checava se o campo era não-vazio) — isso fecha um bug que eu tinha sinalizado como achado extra e que, sem esse fix, teria deixado contas antigas sem re-aceite mesmo com a versão do texto bumped.
**Resta:** o placeholder de revisão jurídica continua aberto — isso é esperado, é trabalho de advogado, não de engenharia.

### 2. Documentos de design citados como contrato não existiam — ✅ Resolvido (e ampliado)
Commit `6d50dffb` trouxe `TECH_SPEC_CORE.md`, `ECONOMY_STUDY.md` e `XP_PROGRESSION.md`. O commit `7472e54c` foi além: também versionou `ARCHITECTURE.md` e `MONETIZATION.md` (citados em `WorldInstance.gd`/`SQL.gd`/`EconomyService.gd`/`OfflineSettle.gd` mas antes só existiam num workspace não versionado), criou um **índice canônico** (`som-idle-docs/README.md`) distinguindo contratos de sistema, docs de design e relatórios de fase, e arquivou as versões pré-pivô superadas fora do repo com um README apontando para onde ficaram. Boa prática que não pedi: o índice já documenta abertamente as referências pendentes (`§11`/`§5` desta própria auditoria, que ainda não existia como arquivo no repo) em vez de fingir que não existem.

### 3. Sem tela de compra de gems no cliente — 🔴 Ainda aberto (agora com contexto de decisão)
Não encontrei nenhuma tela nova de checkout no cliente. O que mudou é que isso agora é uma **decisão de produto explícita e documentada**, não um gap por omissão: `ROADMAP.md` registra que, em 09/09/2026, o dono do produto decidiu tirar a monetização do caminho crítico — "jogo funcionando primeiro"; loja/baús/VIP ficam **implementados mas desligados** até essa decisão ser revisitada (Fase 2 do roadmap). Ou seja, o gap técnico continua existindo, mas agora é rastreável e intencional, não um esquecimento.
**Continua valendo:** quando a Fase 2 for ativada, a tela de compra é o item que efetivamente liga a receita — vale manter como o gate real de "ligar" o pagamento, junto com o item 5 abaixo.

### 4. Monetização sem ads/entrada gratuita — 🟡 Planejado, não implementado
`MONETIZATION.md` (novo, trazido em `7472e54c`) já desenha rewarded ads em detalhe: 2× no claim do AFK, baú bônus diário, reroll de loja, com racional de eCPM no Brasil e posicionamento como "F4: após estabilizar a economia". Ou seja, deixou de ser uma lacuna de design (não pensada) para ser um item sequenciado no roadmap. Ainda não há SDK integrado nem código — o que é esperado, dado que a Fase 2 de monetização real ainda nem começou por decisão do item 3.

### 5. Mercado Pago em build mobile pode violar política de loja — 🔴 Ainda aberto, não endereçado
Não encontrei nenhuma menção a Google Play Billing, Apple IAP, ou a uma decisão de escopo por canal (web vs. loja oficial) em `MONETIZATION.md` ou `ARCHITECTURE.md`. Esse item não foi tocado pelos commits recentes.
**Recomendo tratar isso junto com o item 3**, já que ambos são pré-requisito do mesmo botão ("ligar pagamento") — decidir agora evita redesenhar o checkout depois de já implementado só para web.

---

## P1 — Alto risco / impacto em retenção e receita

### 6. Sem push notification / lembrete de retorno — 🔴 Ainda aberto
Não encontrei infraestrutura de push (web push, e-mail de retorno, etc.) em nenhum dos novos documentos ou código. `BATTLE_PASS_S1.md` menciona um "aviso: restam 7 dias" e lembrete de claim, mas é um conceito de UI dentro do jogo, não um mecanismo de notificação que traga o jogador de volta enquanto ele está fora. Segue sem dono nem fase no roadmap.

### 7. Telemetria rasa para medir as KPIs prometidas — 🟡 Planejado, não implementado
`sources/economy/TelemetryService.gd` continua com os mesmos 3 tipos de evento (login/settle/levelup), sem alteração. Por outro lado, `ARCHITECTURE.md` agora especifica métricas mais amplas a serem coletadas no companion (CCU, sessões, settle/hora, mint/burn de gems, taxa de trade, falhas de webhook, lag de tick) — mas isso está desenhado, não implementado, e é infraestrutura do companion, não do funil de produto (loja/checkout/abandono) que era o foco original deste item. Ou seja: o desenho de telemetria de operação avançou; o funil de conversão comercial continua sem instrumentação.

### 8. Testes fracos nos fluxos financeiros — ⚠️ Correção de avaliação
Ao reverificar com mais cuidado, encontrei em `tests/IdleTests.gd` cobertura que já existia (independente dos commits recentes) para: `ExecuteTrade` (fee insuficiente, stacks faltando, self-trade, cadeia de trades), `OpenChest` (double-open, snapshot de odds, replay de disputa) e guardas de RMT (cooldown de trade, cap diário — "trade cooldown rejects repeat", "daily cap rejects 21st"). O companion também tem sua própria suíte dedicada (`companion/test_webhook.py`, 166 linhas: resolução de catálogo, validação de assinatura). **Eu superestimei essa lacuna no relatório original** — a cobertura dos fluxos de maior risco financeiro é mais sólida do que eu relatei. O que genuinamente falta, se quiser fechar 100%: teste de replay de webhook duplicado ponta-a-ponta (mesmo `payment_id` processado duas vezes) e teste de fluxo de reembolso CDC completo — não confirmei a presença desses dois especificamente.

### 9. CI idle-tests pode não estar rodando — ❓ Não verificável neste momento
Tentei checar via API do GitHub (`actions/workflows/godot-ci.yml/runs`) e recebi rate limit da rede sandbox, sem autenticação. O workflow continua definido no repo. **Recomendo você mesmo checar em Settings → Actions** no GitHub se as execuções aparecem após os últimos pushes — eu não tenho como confirmar isso de fora sem autenticação.

### 10. Localização pt-BR incompleta — 🔴 Ainda aberto
`data/i18n/ui.csv` continua com 18 linhas, sem mudança. Nenhum dos novos documentos trata tradução de conteúdo (quests/diálogos/lore) como item de trabalho — só aparece no roadmap como "Fase 5" (i18n PT-BR/EN, junto do beta aberto), então tecnicamente já está sequenciado, só que ainda não iniciado.

---

## P2 — Melhorias importantes

### 11. SQLite single-node é teto de escala conhecido — ✅ Resolvido (em documentação/planejamento)
`ARCHITECTURE.md` agora define gatilhos explícitos e numéricos por CCU: **<500 CCU** = 1 game server + SQLite WAL + companion container; **500–3k CCU** = sharding manual por zona, Postgres no companion, Redis para leaderboards; **>3k CCU** = settle em workers dedicados. Isso é exatamente o que eu recomendei (definir o gatilho antes de decidir sob pressão) — o item passa de "gap" para "decisão documentada, aguardando o número acontecer".

### 12. UI não adaptada a touch — ⚠️ Correção de avaliação
Reverificando o código-base (herdado do engine original, não um commit novo), encontrei suporte a touch já implementado e não superficial: `TouchScreenButton` para movimento e ações, joystick virtual (`Sticks/LeftAnchor`, `Sticks/RightAnchor`), um toggle em Settings ("Shows touch buttons on screen for movement and actions") e uma aba dedicada de rebind de controles touch em `InputBindings.gd`. **Eu estava errado ao listar isso como ausente** — a camada técnica de touch já existe. O que não posso confirmar sem testar num dispositivo real é se a UX faz sentido especificamente para o loop idle simplificado (o HUD parece desenhado para o MMO completo, não para uma tela mínima de farm/loja/baús) — isso é uma pergunta de validação de UX, não mais um gap de implementação.

### 13. Anti-cheat não revisitado para o modelo idle — 🔴 Ainda aberto
Revisei `OfflineSettle.gd` de novo: os únicos clamps são de eficiência (`MinEfficiency`), não há nenhuma verificação contra manipulação de relógio do cliente ou reconexões artificiais para inflar tempo offline liquidado. `ARCHITECTURE.md` não menciona detecção de multi-conta. Este item segue exatamente como estava.

### 14. Comentários de código desatualizados — ✅ Resolvido
Corrigido na sessão anterior (cabeçalho de `EconomyService.gd`), mantido no estado atual do repo.

### 15. Roadmap de conteúdo pós-semana-1 indefinido — ✅ Resolvido
`ROADMAP.md` (versão 1.1) cobre exatamente essa lacuna: fases F0–F5 com critério de saída por fase, métricas de sucesso D1/D7/D30, e dois documentos de design de conteúdo de médio prazo que não existiam antes — `BATTLE_PASS_S1.md` (temporada) e `BENCHMARK_AFK_HEROES.md` (benchmark de gênero, usado para justificar decisões como "offline earnings são o coração do gênero"). O roadmap também é honesto sobre o próprio risco maior ("CombatPolicy é o maior risco técnico da F2") em vez de esconder incerteza.

---

## Resumo atualizado

| # | Item | Status |
|---|------|--------|
| 1 | ToS proíbe o mecanismo central do jogo | ✅ Resolvido |
| 2 | Docs de balanceamento citados mas ausentes | ✅ Resolvido (ampliado) |
| 3 | Sem tela de compra de gems no cliente | 🔴 Aberto (decisão de produto explícita: adiado) |
| 4 | Monetização sem ads/entrada gratuita | 🟡 Desenhado, não implementado |
| 5 | Mercado Pago em build mobile vs. política de loja | 🔴 Aberto, não endereçado |
| 6 | Sem push/lembrete de retorno | 🔴 Aberto |
| 7 | Telemetria rasa para medir KPIs | 🟡 Desenho de operação avançou; funil comercial ainda não |
| 8 | Testes fracos nos fluxos financeiros | ⚠️ Eu superestimei — cobertura já era sólida |
| 9 | CI idle-tests pode não estar rodando | ❓ Verificar direto no GitHub (Settings → Actions) |
| 10 | Localização pt-BR incompleta | 🔴 Aberto (sequenciado para Fase 5) |
| 11 | SQLite single-node é teto de escala | ✅ Resolvido (gatilhos por CCU documentados) |
| 12 | UI não adaptada a touch | ⚠️ Eu estava errado — já existe |
| 13 | Anti-cheat não revisitado para o modelo idle | 🔴 Aberto |
| 14 | Comentários de código desatualizados | ✅ Resolvido |
| 15 | Roadmap de conteúdo pós-semana-1 indefinido | ✅ Resolvido |

**Saldo:** 6 resolvidos, 2 desenhados/planejados, 5 ainda abertos, 1 não verificável remotamente, 2 autocorreções. Os cinco itens genuinamente abertos que restam (3, 5, 6, 10, 13) são, não por acaso, os que dependem de trabalho de produto/infra externo ao GDScript em si — decisão de billing por canal, SDK de push, tradução de conteúdo e heurísticas de anti-abuso —, não de lacunas de documentação ou de teste, que foi o que mais avançou nesta rodada.

---

## Adendo de verificação (15/09/2026, sessão de engenharia, sobre o mesmo commit `7472e54c`)

Esta auditoria foi conferida item a item contra o código pela sessão de engenharia na mesma data. O documento fica versionado aqui porque os contratos (`TECH_SPEC_CORE.md §11`, `ECONOMY_STUDY.md §5`, `XP_PROGRESSION.md` §"Pendência") citam exatamente estes itens 11/13/15. Duas correções additional, na direção oposta dos achados originais:

1. **Item 8 fecha 100%, não 90%.** Os "dois testes que faltam" também já existiam: `SuiteEconomyGrants` cobre replay ponta-a-ponta no lado do jogo (`duplicate key idempotent`, `single row for duplicate key`, `one grant processed` + `no reprocess` + `no double credit` + espelho de ledger `grant:<key>`), e `Suite` de refund cobre o fluxo CDC completo (`RequestGemRefund`: aprovado, `already_refunded` em double-refund, `not_found`, `gems_consumed` e `window_expired` com ledger back-datado de 8 dias). Combinado com o dedupe do companion (`replayed key deduped`/`only one pending grant`), o caminho do dinheiro tem teste nos dois lados da fronteira. **Status corrigido: ✅ Resolvido.**
2. **Item 13 está sobrestimado no vetor "relógio do cliente".** O settle é calculado exclusivamente com relógio do servidor: âncora `last_settled_at` (coluna do DB), guarda de idempotência `now <= lastSettled → {}`, re-leitura da âncora *dentro* da transação antes de gravar, e carimbo da âncora na primeira login sem zona (`_UpdateAnchor` em `OfflineSettle.gd:114`) — o que elimina tanto a manipulação de relógio do cliente (o cliente não fornece tempo nenhum) quanto inflação por reconexões artificiais e o "12h grátis" de personagem novo. O que **realmente** resta do item é um único vetor: **multi-conta** — proibido pelo ToS desde `6d50dffb` mas sem heurística de detecção (contas distintas liquidando settle do mesmo IP num janela, p.ex.). Isso é telemetria/companion, não o bug de settle que o texto alega. **Status sugerido: 🟡 parcial** (settle blindado; detecção de multi-conta aberta).
3. **Item 10 encogou:** as 8 chaves novas do fluxo de consentimento/re-aceite LGPD ("Agreements Update", "Accept", os textos do diálogo e do aviso) + 4 do fluxo de recuperação de senha entraram em `data/i18n/ui.csv` com tradução pt-BR, e um teste na `SuiteLGPD` passa a falhar a suíte se alguma string legal ficar sem tradução no `ui.pt_BR.translation` (consentimento ininteligível não pode voltar). O grosso da auditoria de i18n (quests/diálogos/lore) continua Fase 5.
