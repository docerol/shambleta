# Protocolo de avaliação cega — Shambleta

Este arquivo define o prompt dado a um agente julgador. Ele existe para que a
nota por categoria seja produzida **sem contaminação** pelo resultado anterior.

## Regras do juiz

1. O juiz NÃO lê nem recebe: `archive/AUDITORIA_2026-09-27.md`,
   `archive/AUDITORIA_INDEPENDENTE_2026-09-24.md`, `archive/AUDITORIA_SHAMBLETA.md` e qualquer `archive/*.md` de
   auditoria datada, `ROADMAP_COMERCIAL.md`, `CHANGELOG.md`, `progress.md`, notas antigas, resumos de
   sessões anteriores, este protocolo preenchido, e nada em `/tmp` cujo nome comece com `gate-`,
   `judge-` ou `blind-verdicts`.
   Nada sobre "o que foi corrigido" — o juiz avalia o estado do repo como se o visse pela primeira vez.
2. Avalia as 20 categorias (0–10, uma casa decimal): Core Gameplay, Core Loop, Meta Game,
   Game Design, Retenção, Economia, Monetização, Marketplace, Segurança, Arquitetura,
   Performance, Escalabilidade, UX/UI, Social, Live Ops, Analytics, Testes, DevOps,
   Documentação, Código.
3. **Nota > 9 exige prova executável**: para cada categoria acima de 9, o juiz deve citar
   arquivo:linha e, onde cabe, resultado de teste realmente rodado. Sem prova, a nota não passa de 9.
4. Regra anti-invenção: problema não confirmado no código é marcado `HIPÓTESE` e **não** derruba nota.
5. O juiz entrega, por categoria: nota, 3 evidências concretas e a **lacuna específica** que
   separa a nota de >9 (se for o caso).
6. Dois juízes independentes por rodada; a nota final da categoria é a **mínima** entre os dois.

## Rodada 1 — lançada em 2026-09-27

Juízes efetivamente lançados (não foi `blind-judge-a`/`blind-judge-b`: a linha que
anunciava dois juízes descrevia a intenção, não o run — a regra 6 ficou
**violada nesta rodada** e é por isso que a rodada 2 repete tudo): cinco agentes de
leitura, um por grupo — produto, dinheiro, engenharia, UX/UI+Social, e
segurança/DevOps/Documentação. Cada categoria tem pois **um** veredito, e a nota
abaixo é essa nota única, não uma mínima entre dois.

## ledger da rodada 1 (vereditos recebidos em 2026-09-27/28)

Existe por um motivo pragmático: os vereditos viviam só em `/tmp` e no transcript,
e uma compactação de contexto já os perdeu uma vez. Sem registro, a régua "nota
acima de 9" não tem de onde partir.

Este registro **não cita coordenada de arquivo**. Os vereditos originais citavam, e
as linhas citadas envelhecem a cada rodada de correção; regravá-las aqui seria
importar para o repo um ponteiro que a régua de ponteiros cobraria como se fosse
verdade atual. O que se guarda é a categoria, a nota e a **lacuna nomeada** — que é
o work order. A prova executável mora no run do juiz, não aqui.

| categoria | nota | a lacuna nomeada pelo juiz |
|---|---|---|
| Core Gameplay | 8,3 | escada curta de chefes; prioridade de skills só editável por chat |
| Core Loop | 8,7 | um eixo de atividade só (matar); sem crafting alcançável pela UI |
| Meta Game | 8,5 | uma temporada declarada; marcos amarrados à escada curta |
| Game Design | 8,6 | bandas de drop com fallback para conteúdo que não existe |
| Retenção | 7,8 | streak sem superfície visível; push ainda stub; calendário sem campanha futura |
| Economia | 9,4 | knobs ainda com custos fixos; nenhuma trajetória longa de faucet/sink |
| Monetização | 9,4 | canal de anúncio sem verificação de callback do provedor |
| Marketplace | 8,5 | sem buy-order, sem histórico de preço server-side, paginação sem offset |
| Analytics | 8,0 | funil medido e não consumido; D1 errada na origem |
| Live Ops | 9,2 | tipos de evento no calendário sem consumidor |
| Arquitetura | 8,5 | allowlist de nós-deus gravava o número medido em vez de teto |
| Performance | 8,5 | fences de sanidade que não eram régua de regressão |
| Escalabilidade | 7,4 | sem número de capacidade por processo; caps de spawn e de redirect ausentes |
| Código | 8,2 | arquivos fora de qualquer gate na raiz; contradição documentada sobre a mutex |
| Testes | 8,2 | harnesses fora do git (clone limpo não reproduz); detector de gate cego a teardown |
| UX/UI | 7,5 | widgets de decisão fora da tela em viewport de telefone |
| Social | 5,5 | painel social órfão, sinal de seleção não conectado, denúncia só por chat |
| Segurança | 8,7 | proxy sem rate limit, limite de corpo, CSP/frame-deny nem hardening de resposta |
| DevOps | 8,9 | contexto de build enorme; sem smoke do compose na CI |
| Documentação | 8,6 | páginas que descrevem gates que não existem ou mentem sobre o que apuram |

Estado da correção, conferido por leitura e por comando em 2026-09-28 — não é nota
nova, é mapa de qual lacuna ainda está de pé: **fechadas em código** Core Gameplay,
Game Design, Monetização, Marketplace, Analytics, Live Ops, Arquitetura,
Performance, Código; e mais três que a leitura do estado atual do repo fecha hoje,
não a memória da rodada 1: **Meta Game** (o arquivo de agenda tem duas temporadas, a
sucessora com janela futura e o SKU dela no catálogo que a loja cobra),
**Retenção** (o calendário de live ops tem campanhas com janela à frente desta
data, o streak tem superfície e o push tem signer real) e **Segurança** (o proxy de
borda agora tem rate limit por rota, limite de corpo, `server_tokens off`,
frame-deny e CSP). **Ainda abertas**: Core Loop (crafting sem botão na UI — agente
em curso), Economia (trajetória longa de faucet/sink — agente em curso), Testes
(harnesses só em stage, não no HEAD — é o commit pendente), Escalabilidade (o teto
de N instâncias no mesmo processo e o confronto com os limites do compose seguem
declarados como NÃO MEDIDO no próprio documento — agente em curso), DevOps (contexto
de build e smoke de compose na CI).

Social foi re-julgada à parte em 2026-09-28, com a governança de guilda como
lacuna, e voltou **9,0**. Documentação foi re-julgada na mesma passada e voltou
**7,5**, mais baixa que a nota da rodada 1: o juiz mediu a mordida da máquina
injetando mentiras num clone descartável e provou que a régua de ponteiros valida
resolução, nunca identidade — quatro falsos apontam para linhas que existem e estão
cheias. Esse é o work order em curso, e é por isso que a regra de re-julgar vale o
mínimo entre duas leituras e não a mais recente.

Nada nesta tabela é meta: a meta é **todas as 20 acima de 9, julgado por juiz que
não viu a tabela**. Enquanto houver linha aqui com nota ≤ 9 — ou sem nota por falta
de segundo juiz — a rodada continua.

## Rodada 2 — vereditos entrando (parcial, 2026-09-28)

Um juiz novo por categoria, sem a tabela acima, e a nota gravada é o mínimo entre
esta passada e a rodada 1. Só as categorias julgadas até agora:

| categoria | rodada 1 | rodada 2 | mínima |
|---|---|---|---|
| Social | 5,5 | 9,0 | 5,5 → re-medir com governança de guilda no ar |
| Documentação | 8,6 | 7,5 | 7,5 |
| DevOps | 8,9 | 8,8 | 8,8 |
| Segurança | 8,7 | 6,8 | 6,8 |

A mínima de Segurança caiu porque o juiz não achou fraqueza criptográfica: achou
**código que não existe para o git**. A porta pré-autenticação que limita conexão e
orçamento de handshake, o roster de guilda, o entrypoint do container e o renderizador
do config do alertmanager estão no disco e são invocados por arquivo versionado, mas
nenhum deles entrou no índice — num clone limpo o identificador não compila e o
`COPY` do Dockerfile morre. A defesa contra flood de handshake não tem histórico de
revisão, não roda em CI, não é deployável. Somado: o cabeçalho de um desses arquivos
cita um harness que não existe. O gate que detecta isso já está vermelho em HEAD, ou
seja, falta a entrega e não a régua.

A segunda nota de DevOps desceu, e a lacuna nomeada não é a da rodada 1. O juiz
rodou os gates de infraestrutura e achou verde; o que derruba a nota é o **caminho
de volta**: nenhum serviço que o compose compila tem imagem nomeada, então o
rollback documentado manda puxar imagem que não existe; falha no meio do deploy
(migration que estoura no boot) não é tratada nem mediada; e uma linha de runbook
negando uma métrica que o servidor emite e pela qual a alerta pagina. Mais o
`COPY` de arquivo de entrada fora do índice, que quebra o build de um clone limpo.
Isso é trabalho, não discussão: a tabela acima virou work order.

As outras 18 categorias ainda não têm segundo juiz. A rodada 2 só fecha quando cada
linha da tabela anterior tiver duas notas independentes.

## Rodada 2 — protocolo corrigido antes de lançar

A rodada 1 expôs três buracos no próprio protocolo, e fechá-los é condição do
segundo round valer como prova:

1. **Dois juízes por categoria, não um.** Regra 6 cumprida de fato: cada grupo é
   lançado duas vezes, e a nota gravada é a mínima.
2. **O veredito tem de sobreviver ao `/tmp`.** O juiz escreve o próprio texto no
   stdout da tarefa (já escreve); o orquestrador copia para este arquivo antes de
   qualquer outra coisa. A rodada 1 perdeu cinco categorias por não fazer isso.
3. **Juiz que não roda teste não passa de 9.** Na rodada 1 houve categoria nota 9+
   com prova de run parcial; a regra 3 passa a exigir o comando e a última linha do
   resultado, citados no veredito.

## Rodada 3 — lançada em 2026-09-28, depois do portão completo verde

A rodada 2 deixou 18 categorias com um juiz só e quatro com a mínima abaixo de 9 por
causa **fechada em código mas não re-medida** (Social, Segurança, Documentação, DevOps).
Julgar de novo é o único jeito de a nota valer: o que está na tabela das rodadas
anteriores é a memória do que o repo era, não do que ele é.

Layout, para não repetir o erro da rodada 1 (cinco vereditos perdidos porque viviam só
em `/tmp`):

- **Cinco grupos de quatro categorias**, cada grupo lançado por **dois juízes
  independentes**, dez tarefas no total: (1) Core Gameplay, Core Loop, Meta Game, Game
  Design; (2) Retenção, Monetização, Marketplace, Economia; (3) Arquitetura,
  Performance, Escalabilidade, Código; (4) Testes, Segurança, DevOps, Live Ops;
  (5) UX/UI, Social, Analytics, Documentação.
- O juiz **não escreve no repo** e **não chama `godot` na mão**: harness é
  `bash scripts/test.sh one <harness> <timeout>`, que é o caminho que aplica o `flock`,
  o sandbox `.test-home/` e o `scripts/ci_gate_log.sh`. Um verde obtido por atalho não é
  o verde do portão.
- A rodada 3 só é lançada com o `all` verde e o trabalho commitado: julgar árvore
  suja é dar ao juiz um repo que não existe para ninguém mais, e a lacuna da categoria
  Testes nas duas rodadas anteriores foi exatamente "está no disco, não no índice".
- Nota da categoria = **mínima** entre os dois juízes da rodada 3 e a mínima já
  registrada, até que o judge cego confirme o estado atual. Re-medir uma categoria cujo
  gap fechou substitui a antiga mínima — e é por isso que a tabela abaixo guarda também
  o veredito anterior.

Vereditos recebidos (copiados para cá assim que chegam, na ordem de chegada):

| categoria | R1 | R2 | juiz A (R3) | juiz B (R3) | mínima vigente | lacuna nomeada em R3 |
|---|---|---|---|---|---|---|
| Core Gameplay | 8,3 | — | 8,4 | 8,5 | 8,3 | R3A+R3B: nenhum harness afirma a curva morte→eficiência→revive nem "sessão de 300 s na zona 1 com ≤2 mortes"; o L1 nu não tem a maçã do `autoPotionItemHash` (`IdlePolicy.gd:81`) e a política convive com ~8 mortes declaradas em comentário (`FarmZoneData.gd:45-47`) |
| Core Loop | 8,7 | — | 8,5 | 6,5 | **6,5** | R3B (conferido pelo orquestrador): nove escritores crus de `stat.gp` + snapshot absoluto (`SQL.gd:1156`) revertem o débito do vendor em ≤600 s para personagem conectado, e o detector do kernel só enxerga a perna de baixo (`EconomyKernel.gd:187`). R3A: nenhuma régua emenda o ciclo (logar→farmar→liquidar→gastar→subir zona→renascer na mesma sessão) |
| Meta Game | 8,5 | — | 7,6 | 7,5 | 7,5 | R3A+R3B: `pass_tiers` é `{}` na S1 — a única temporada no ar corre por default de código (`SeasonConfig.gd:244` valida a faixa, `PassService.gd:84` leria o arquivo se existisse — fechado em 2026-09-29: a S1 declara a trilha no arquivo, e o espelho nível a nível do catálogo é amarrado por `tests/season_liveops_test.gd`) — e as `races` power/spend não têm produtor rastreado; o ranking de temporada pontua estado acumulado, não o delta da janela (`SeasonService.gd:223-261` — lacuna verdadeira como escrita em 2026-09-28 e fechada pela migration 064 em 2026-09-29; o número citado é o de hoje, que já subtrai o marco zero) |
| Game Design | 8,6 | — | 8,0 | 7,0 | 7,0 | R3A+R3B: nenhum sumiouro de gold escala com a torneira (z27 paga ~3,77 M gold/h contra guild L10 a 10 M e teto de vendor ~29 k/dia) — **fechado em 2026-09-29**: a taxa de forja lê a zona do personagem (`ForgeFeeForZone` em `sources/economy/ItemForgeService.gd:496`), o tier 9 da zona 27 passou de 40 500 para 3 786 686 gold = 60,23 min de fazenda par, e a banda `[886, 1099]` ‰ é justa nas duas arestas (885 fura o piso em 59,93 min, 1100 estoura o teto em 180,24, cada um em exatamente um par — o mesmo par), medido por `tests/gold_sink_scale_test.gd` com 159 checks e 0 falhas em 2026-09-29; o "teto de vendor ~29 k/dia" continua não re-medido, porque `tests/faucet_census_test.gd` enumera o vendor como pia mas nenhum número diário em gold. A segunda afirmação do juiz era meia-verdade e corrige-se aqui: os 100 gemas da trilha gratuita contra 120 por baú batem (`PASS_FREE` em `sources/economy/EconomyCatalog.gd:447`, preço do baú na linha 170 do mesmo arquivo), mas "o F2P nunca alcança um baú" não — a própria trilha grátis distribui 4 baús nas linhas 448 a 450 (L5 = 1, L16 = 1, L24 = 2). Terceira: `Experience.gd:9-10` afirmava "3 semanas"/"satura na zona 24" contra a curva de 27 zonas — o cabeçalho foi reescrito na #104 e hoje calcula da curva sem prometer pacing |
| Retenção | 7,8 | — | 7,2 | 8,3 | **7,2** | R3A (medido por ele: `one balance_test` → `== RESULT: 875 checks, 0 failures ==` e `test_retention.py` → 21): o gancho não paga o suficiente para ser razão de volta — o ciclo de 7 dias soma 3.250 de ouro contra ~108.000 de UMA liquidação F2P de 8 h (~3%), e o `same_day` de `StreakService.gd:158` devolve `reward = 0` dentro da mesma transação que paga a escada (`:179-191`); o que puxa o retorno é o cap de offline (`OfflineSettle.gd:132`), não a escada. **E não há nada vivo agora**: `data/conf/liveops_calendar.json` tem 1 campanha encerrada, 2 em novembro/2026 e 3 na abertura da S2, nenhuma cobrindo hoje, e `data/conf/seasons.json` declara `s1` com `start_unix: 0, end_unix: 0`. R3B: `LossOnBreak` devolve 0 exatamente no dia 7 (`:76-80`) |
| Economia | 9,4 | — | 7,6 | 8,4 | **7,6** | R3A (conferido pelo orquestrador): o fuzzer **confessa o próprio buraco** — `economy_invariant_fuzz.gd:641` registra "`IG2 (`paid <= gems`) é deliberadamente NÃO-asserto nestas contas: a taxa de anúncio gasta gemas pagas por fora do gate de origem, então `paid > wallet` é estado legal do leilão" — e é exatamente essa coluna que o clawback limita (`CheckoutService.gd:368`) e que o `not_paid` do art.49 cobra (`:552`). E não existe censo de pia: `ReconcileWalletDaily` (`EconomyKernel.gd:160-169,187`) só enxerga a carteira **abaixo** do que o ledger atesta, então um faucet que escreva `stat.gp` e ledger juntos é invisível por construção, e nada soma a expansão líquida diária de oferta contra as pias enumeráveis (forja, vendor, guilda, chave de boss, taxa de torneio, death tax 5%, `ah_list_fee`). R3B: distribuição offline de variância zero (`OfflineSettle.gd:335`). *A favor, medido por R3A:* `one balance_test` → `== RESULT: 875 checks, 0 failures ==` com `:231` asserindo gold/XP online ≥ offline por nível 1..40 contra o `BuildReport` real; `_MoveGoldLocked` recusando `next < 0` (`:103`) e espelhando DELTA pós-commit (`:116-124`)  Ainda de R3B, a favor: `equivKills` gera os dois faucet numa régua só e o drop foi recalibrado de ppm-de-segundos para ppm-de-kills contra a taxa online medida (`OfflineSettle.gd:319-331`), os knobs do `economy_base_catalog.json` são cobertos por FAIXA (`economy_knob_range_test.gd`) e o fuzzer trata verde por inércia como falha (`:369-373`). |
| Monetização | 9,4 | — | 7,9 | 8,5 | **7,9** | R3A (conferido pelo orquestrador, e é o P0 novo da rodada): a reversão de dinheiro só conhece **gemas**. `Server.gd:58 RequestRefund` → `EconomyService.gd:377 RequestGemRefund` → `CheckoutService.gd:523-526` consulta `ledger_transaction WHERE kind = LedgerKindGems AND reason = 'grant:<key>'` e devolve `not_found` para qualquer outro kind. Dos 11 SKUs de `data/conf/paid_catalog.json`, **8 não são gems** (`vip.1mo`, `vip.3mo`, `pass.s1`, `pass.s1.deluxe`, `pass.s2`, `donate.support`, `starter.pack`, `founder.pack`); e não existe caminho de revogação — `grep premium = 0` não devolve nada no repo, `vip_until` só é escrito para frente (`CheckoutService.gd:403`, `SQL.gd:1055`) e `season_account_state.premium = 1` (`:438`) nunca volta a 0. Um chargeback ou um art.49 de passe/VIP devolve as gemas e **deixa o passe ativo**. *A favor, medido por ele:* `SetGemsRaw` drena `gems_paid` primeiro e clampa em `[0, gems]` (`SQL.gd:1144`), fila reivindicada e relida no mesmo commit (`CheckoutService.gd:268-270`), idempotência por conta (`:168-174`), e rodou `test_security` (63), `test_refund_cli` (12), `test_ad_ssv` (68), `test_season_offer` (125). R3B: o grant `kind == "gold"` escreve `stat.gp` cru (`:392→:396`), mas nenhum SKU pago é `gold` hoje |
| Marketplace | 8,5 | — | 7,0 | 7,6 | **7,0** | R3A+R3B (conferido pelo orquestrador): **a oferta não tem teto e o detector não enxerga o leilão.** `ListItemForSale:269` e o RPC `Server.gd:1365 AuctionList` só rejeitam `priceGold <= 0`, enquanto a demanda é limitada por `AHMaxBidUnitPrice = 100000000` / `AHMaxBuyOrderGold = 1000000000` (`EconomyCatalog.gd:144,146`) — assimetria de um lado só; `FraudeReview.gd:328,340,345` casa `trade_out:`/`trade_in:` e o AH escreve `ah_list:`/`ah_in:` (`:96,:323,:400`); `auction_listing` não tem `expires_at` (DDL `migrations/018`) e não há reaper. Somam-se os dois: A-anuncia → B-compra → B-anuncia → A-compra entre alts move ouro arbitrário, a preço livre, para sempre, sem filação. R3A acrescenta o **cruzamento sem rede**: `_TryMatchListing` tem UM chamador (`:332`, depois do commit e com o lock solto de propósito) e não existe varredura de re-cruzamento no boot — um restart entre o anúncio e a matching deixa ordens em pé sem parceiro até o próximo evento. *A favor:* auto-negócio barrado no funil (`:354`) **e** repetido nas duas direções em SQL (`:630 seller_account !=`, `:681 buyer_account !=`); `marketplace_depth_test.gd:533,535,537,596` varre o banco inteiro assinando escrow == quantity×price e riqueza = carteira + escrow. Nenhum harness GD rodou para nenhum dos dois juízes (`GATE SERIALIZADO`)  Somam-se a isso o cancelamento que re-minta lote novo (`:460`) embora `escrow_uids` esteja gravado (`:94,:318`) e lido só em `:375` — pelo primeiro uid, mesmo em anúncio com `count > 1` (#94) — e a ausência das três fricções da troca direta (`TradeChestService.gd:38-49`: e-mail verificado, cooldown, cap diário), restando `AHListFeeGems = 5` e `AHMaxOpenPerAccount = 5` (`EconomyCatalog.gd:488,491`) como única atrito. |
| Analytics | 8,0 | — | 8,5 | 7,5 | 8,0 | R3A+R3B: o D1 é honesto sobre a própria janela nas duas pontas (`TelemetryService.gd:83,281`, `companion/server.py:466-476` com `window_closed`, migration 045) e os 14 `FUNNEL_KINDS` têm emissor real — mas `telemetry_event` não tem poda temporal alguma (retenção de 90 dias é só do ledger, `SQLRetention.gd:30`; o único delete é LGPD em `SQL.gd:326`), e `FunnelDaily`/`/metrics` fazem `GROUP BY` numa tabela que cresce para sempre com feature flag como única proteção |
| Live Ops | 9,2 | — | 6,0 | 6,8 | **6,0** | R3A+R3B: `deploy/alertmanager.yml:60-64` materializa os dois receivers como `webhook_configs: []` — por default do repo o `severity: page` não acorda ninguém; nenhum dashboard versionado; rotação de temporada/campanha é PULL com TTL de 60 s (`LiveOpsCalendar.gd:108`) e não há cron versionado (`deploy/STAGING.md:136`), então a transição depende de trocar arquivo no host. *A favor, medido por R3B:* as dez séries de `alerts.rules.yml` resolvem em `MetricsServer.gd:190-244` e o orçamento do drain tem controle negativo que morde (`check_compose.sh`) |
| Arquitetura | 8,5 | — | 7,0 | 8,9 | **7,0** | R3A+R3B: `EconomyKernel.GrantItem` (`:44-55`) insere em `ledger_transaction` por `Launcher.SQL.db.query_with_bindings` sob `_eco._get_settle_mutex`, **fora** de `SQL.Transaction()` — ao contrário de `LedgerAppend` (`:33-41`), que declara o contrário no comentário — enquanto `:20-28` lê a mesma tabela pelo funil; e `deploy/SCALING.md:327-328` afirma que "a `queryMutex` de `SQL.gd:7` continua sendo o único funil de escrita" contra 30 escritores `.db.` crus em `sources/` (`GuildService.gd:164,207`, `AuctionHouseService.gd:263`, `CheckoutService.gd:490`), sem nenhum gate de censo. R3B: nada exercita o ledger com DOIS processos servindo a mesma conta — a escala provada é multi-instância intra-processo |
| Performance | 8,5 | — | 8,0 | 8,7 | **8,0** | R3A: mediu `one benchmarks` sob contenção de outro juiz e o p99 normalizado ficou a ~10% do teto (budget 2.076 µs, 1.881 µs) — a régua aperta, mas `max 549.622 µs` com 3 hitches >50 ms não tem causa confirmada; e **não existe detector do orçamento de passo em produção**: `grep -rn -e TIME_PHYSICS_PROCESS -e get_frames_per_second sources` devolve só `ServerDisplay.gd:13` (painel de dev legível por humano) e o que sai por `/metrics` é espera de mutex (`MetricsServer.gd:173-178`), não ms/passo. R3B: a régua do tick é gated pela MEDIANA; a 200 players o p95/max deu 42,09 ms contra orçamento de 33,33 ms e nenhuma harness compara a cauda com o orçamento |
| Escalabilidade | 7,4 | — | 7,2 | 7,9 | **7,2** | R3A+R3B: o teto horizontal continua `[NÃO MEDIDO]` e o doc confessa (`SCALING.md:347`: "Dois servidores em duas máquinas não foi medido", contenção entre processos no mesmo WAL em `:225-227`) — o "~200 players conviventes" é teto **por processo único**, e ninguém rodou dois escritores com `SHAMBLETA_SERVER_ID` distintos sobre o mesmo arquivo; a âncora do degrau é unilateral (±100 sobre 200 deixa passar um erro de 2× e só pega queda, não inflação). `deploy/SCALING.md:159-162` afirma um erro por-passo em `AIAgent.gd:64` que o código já não tem; o recipe de `:175` usa `godot --headless -s` cru, classe que o próprio `boot_guard` do `test.sh` recusa |
| Código | 8,2 | — | 7,3 | 8,6 | **7,3** | R3A+R3B: `harness_marker` (`scripts/test.sh:@harness_marker`) só casa `"== [A-Z]+[A-Z ]*:`, então `one benchmarks` (marcador real `== Benchmarks:` de `_run_benchmarks`, `tests/benchmarks.gd:@_run_benchmarks`) e `one test_backup_restore` devolvem `GATE VERMELHO` com `godot exit=0` e produto verde — reproduzido pelo R3A em shell para os 7 harnesses explícitos; e `reason_toast_test` é julgado certo **por acidente de ordem textual** (a regex casa o `"== RESULT:` de `_finish` em `:57` antes do `== REASON:` de `_initialize` em `:61` — mover `_finish` para o fim troca o marcador do gate). A superfície também mente: `scripts/test.sh:22` anuncia `gate <log> <marker> <script>` como interface, mas `gate` é função interna — os cases são `all`, `quick`, `idle`, `backup`, `benchmarks`, `rpc`, `companion`, `fixation`, `preflight`, `structure`, `one`, `diag`, `clean`. *A favor, medido por R3A:* 1 TODO/real em 330 `.gd`, e `check_god_nodes.sh` limpo com folgas vivas (`Server.gd 1963/1965`) |
| Testes | 8,2 | — | 7,8 | 8,2 | **7,8** | R3A: ~419 de 4.290 linhas de `Check*` casam TEXTO do fonte; `check_ci.sh:190` aceita `needs` de build como portão. R3B: `tests/nginx_hardening_test.gd:570-574` DEGRADA para ler a doc quando não há nginx no host e `deploy/web/Dockerfile:30` só `COPY`a o `nginx.conf` sem `nginx -t` — um proxy que o nginx recusa passa em todos os gates e chega ao prod |
| UX/UI | 7,5 | — | 7,0 | 7,5 | **7,0** | R3A+R3B: a passada de telefone do `hud_decision_fit_test` (verde medido por R3B: `== RESULT: 68 checks, 0 failures ==` sobre 390x844 com piso de 48 px) só amarra os 7 painéis que vivem no boot — guilda/leilão/forja/vault, que nascem por ação, estão fora da régua; e 66 chaves de conteúdo NPC seguem sem `pt_BR` (`data/i18n/coverage_report.md`) |
| Social | 5,5 | 9,0 | 8,0 | 6,5 | **5,5** | R3A+R3B: `GuildService.gd:94-97` é read-then-write sem transação nem lock (`JoinReason` conta por `SELECT COUNT(*)` em `GuildRoster.gd:105-107` e o `INSERT` vem solto, ao contrário de `LeaveGuild` logo abaixo) — o próprio código nomeia o buraco em `GuildRoster.gd:82-85` e a PK de `guild_member` impede double-join mas não o teto estourado; falta transação/`CHECK` durável + N joins simultâneos asseridos |
| Segurança | 8,7 | 6,8 | 7,2 | 7,5 | 6,8 | R3A+R3B: a cota existe só ANTES da credencial (`Admission.gd:67`, `NetworkCommons.gd:63`) — varredura por `MsgPerSec`, `PerPeer`, `Throttle`, `RateLimit` não acha janela pós-auth — então `TriggerChat` (`Server.gd:1649-1687`) amplifica 1→N sem taxa por peer; cesta pré-auth nunca podada; APK de release com debug keystore (`release.yml:72-74`) |
| DevOps | 8,9 | 8,8 | 6,3 | 7,0 | **6,3** | R3A+R3B: `snap`/`release` com `needs: builds` publicam com teste vermelho; `deploy/ROLLBACK.md:24-26` declara que não há registry e `pull_policy: never` (`deploy/docker-compose.yml:50,102,211,319,374`). O `SHAMBLETA_TAG` do job `container-images` morre no runner efêmero; smoke de compose roda 0 containers e nenhum `up` existe no caminho |
| Documentação | 8,6 | 7,5 | 8,5 | 6,5 | **6,5** | R3A: taxa de erro falsa medida por ele = 0/5 (`DOC DRIFT: 1391 checks, 0 failures`), mas nenhuma afirmação de COMPORTAMENTO é coberta — números de `SCALING.md`/`OPS_RUNBOOK.md`/`WEB_SLIM.md` e o "4.7.2" de `deploy/web/landing/index.html:118`, construído em 4.7.1; e `tests/panel_fit_test.gd:6-7` aponta `WindowPanel.gd:238-240` para código que está em :238-239 sem acusação. R3B: duas afirmações falsas conferidas por mim passam — `docs/development/testing.md:87` diz "as 61 patches reais do boot viram a versão 61" contra 62 `.sql` em `data/conf/migrations/` (001..062), e a régua de numeral (`check_doc_drift.sh:178`) só morde quando o substantivo é "migrations", nunca "patches"; `README.md:65` aponta `Action.gd:176-199` para a cadeia `ui_*` que vai até 200, com `ui_fullscreen` FORA do intervalo citado, sem acusação — as três conferidas em 2026-09-29: o README hoje cita `Action.gd:176-200` e `ui_fullscreen` está na linha 200; a linha da tabela que falava em "61 patches" não afirma número algum desde a #25 ("a versão final é o número de patches, conferido no próprio harness"); e a régua de numeral conheceu a sinonímia patch/migration, que é justamente o que a linha 178 de `scripts/check_doc_drift.sh` registra hoje. O método estava aberto e fechou em 2026-09-29: `SuiteEvidencePointers` ganhou um quarto braço que julga o **alvo linha** de um ponteiro que aponta para dentro de `.md` — nome escrito fora do intervalo citado acusa pelo símbolo e pelo número, nome que o documento não soletra silencia — e na primeira passada acusou quatro frases, as quatro verdadeiras, inclusive uma deste próprio registro. O que continua aberto, agora com nome: um ponteiro para arquivo de código cuja cláusula não nomeia símbolo declarado (um local, um arquivo, ou nada) segue sem span a conferir — foi por essa fresta que nove locadores de `IdleTestsFrontier.gd` apodreceram ~1300 linhas sem reclamação |

Cadeiras entregues: **10 de 10** — produto A+B, engenharia A+B, entrega A+B,
experiência A+B, dinheiro A+B. A rodada 3 fechou em 2026-09-29: cada uma das 20
categorias tem dois vereditos independentes, e a árvore volta a poder ser editada.
O `juiz-A-engenharia` original também bateu no teto de 150 turnos, já depois que o
substituto entregou — a cadeira conta uma vez, pelo veredito que chegou.

R1 foi um juiz por categoria (a regra 6 só passou a valer na rodada 2), então a
coluna R1 é nota única. `Social` teve R2 re-medida à parte, com a governança de
guilda como lacuna: 9,0, e a mínima continua 5,5 até os dois juízes da rodada 3
concordarem. Preencher A/B com a nota, as três evidências e a lacuna; a coluna
"mínima vigente" é recalculada na hora, não lembrada.

### Veredito bruto — juiz B, grupo engenharia (Arquitetura, Performance, Escalabilidade, Código)

Chegou 2026-09-28, depois de 90 chamadas de ferramenta e seis execuções verdes próprias
(`companion` 744 checks, `structure` 9 gates com doc-drift 1391, `scale_test` 95,
`tick_capacity_test` 32, `multi_instance_tick_test` 198, `benchmarks`). Reproduziu por
grep puro o defeito de marcador e confirmou código-vs-doc uma afirmação falsa no
`deploy/SCALING.md`.

- **Arquitetura 8,9.** Roteador de leitura fail-closed em `sources/sql/SQLReadRules.gd:326,329`
  (`ShouldRoute` devolve falso com `txnDepth > 0`) e leitores `PRAGMA query_only=1` fora da
  mutex em `sources/sql/SQLReadPool.gd:7,73,96`; `one multi_instance_tick_test` →
  `== RESULT: 198 checks, 0 failures ==` com `SQL 0.0 rt/tick` e `mutex 0.00 us/tick` em
  todos os degraus. Caminho monetário único em `sources/economy/EconomyKernel.gd:33` com
  triggers ABORT em `data/conf/migrations/009_idle_economy.sql:26-35` e roldura durável em
  `data/conf/migrations/056_ledger_retention.sql:103-107`. Identidade nunca vem do payload
  (`sources/network/Network.gd:1133,1141`); idempotência dupla do grant
  (`sources/economy/CheckoutService.gd:164,168,174`). *Lacuna:* nada prova consistência
  monetária entre PROCESSOS — todos os degraus medidos são multi-instância num só processo.
- **Performance 8,7.** `one tick_capacity_test` → `== RESULT: 32 checks, 0 failures ==`,
  medianas 1,58 → 4,57 → 10,68 → 27,86 ms (orçamento 33,33 ms), custo marginal ~0,132
  ms/player, extrapolação própria de ~240 players/zona; o injetor de estouro respondeu
  (40 ms queimados → período 46,22 ms). `one benchmarks` verde com `== Benchmarks: 0
  failures ==`. *Lacuna:* a cauda não cabe no orçamento — a 200 players o p95/max deu
  42,09 ms acima dos 33,33 ms, e o veredito é gated pela mediana; nenhuma harness compara
  p95 com o orçamento. *Hipótese não descontada:* período de 33,60 ms até com 1 player é
  granularidade do timer headless, não custo do produto.
- **Escalabilidade 7,9.** `one multi_instance_tick_test` (198 checks) chega a 300 players
  (15×20) com 25,80 ms dentro do orçamento e estoura a 400 (20×20): 90,12 ms de trabalho,
  período 53,37 ms, CPU ~1,00 core — consistente com a linha do doc (88,93 ms / 20,52 Hz).
  As âncoras `DRIFT proc_*` estão vivas e conferem. *Contra:* `deploy/SCALING.md:159-162`
  afirma que o `ERROR: Attempted to erase a variable of type 'int' into a TypedArray` em
  `sources/actor/agent/variants/AIAgent.gd:64` acontece dentro do passo de física e está
  incluído nos custos medidos — hoje a linha 64 é COMENTÁRIO e a 68 usa `pop_front()`; o
  bug foi corrigido. *Lacuna:* mesma do Arquitetura — shard real multi-processo indemonstrado.
- **Código 8,6.** Varredura de dívida: os ~121 hits de TODO/FIXME/HACK são a palavra
  portuguesa "todo", zero marcadores reais; guard-clause e autoridade do par em
  `sources/network/server/Server.gd` derivando de `Peers.GetAccount/GetCharacter` do peer
  de transporte; idempotência do grant com as duas guardas. *Contra, defeito concreto:*
  `harness_marker` (`scripts/test.sh:@harness_marker`) casa só `"== [A-Z]+[A-Z ]*:`, mas
  `_run_benchmarks` (`tests/benchmarks.gd:@_run_benchmarks`) imprime `== Benchmarks:` e
  `_Finish` (`tests/test_backup_restore.gd:@_Finish`) imprime `== Backup Restore Probe:` e nenhum
  dos dois imprime `== RESULT:`; o fallback
  faz `one benchmarks` e `one test_backup_restore` voltar VERMELHO pelo
  `scripts/ci_gate_log.sh` com `godot exit=0` e zero falhas. O `all` disfarça porque fixa
  o marcador (`test.sh:569-570,602,606`), então o buraco é exclusivo do caminho `one` — o
  caminho que este protocolo manda o juiz usar. *Lacuna:* nenhuma régua cobre o caso
  mixed-case (falta um assert de que `harness_marker benchmarks == "== Benchmarks:"`).

### Veredito bruto — juiz B, grupo produto (Core Gameplay, Core Loop, Meta Game, Game Design)

Chegou 2026-09-28 no assento relançado com teto de chamadas (60 chamadas, 3 tentativas de
harness). **Nenhuma linha verde é dele**: as três tentativas foram bloqueadas pelo boot guard
de outro juiz — `bash scripts/test.sh one balance_test 420` devolveu `RC=1` com
`GATE PULADO: godot estrangeiro (pid 269904) com cwd em /mnt/dados/Projetos/shambleta` e
`== GATES VERMELHOS: boot_guard ==`. Ele mesmo declarou que nada do grupo foi provado por
execução nesta passada; as evidências abaixo são de fonte lido e de uma curva calculada por
ele. Isso é tratado como HIPÓTESE de nota, não como veredito medido — mas a lacuna do Core
Loop foi conferida pelo orquestrador no fonte e é real (ver §"P0 do dual-write" abaixo).

- **Core Gameplay 8,5.** O produtor e o consumidor de `State.DEAD` existem:
  `sources/idle/IdlePolicy.gd:210` e `:522-535` (`_tickDead` → `Revive()`, `State.SEEK`,
  `sessionDeaths`/`sessionDowntimeSecs`), com substep fixo `TickInterval = 0.25` e
  `MaxCatchUpSeconds = 2.0` (`:163-166`). Aggro com cap cobrado no runtime e dano agregado
  por atacante (`sources/actor/agent/variants/AIAgent.gd:37-68`); drop nasce no evento de
  morte (`MonsterAgent.gd:34-40`) e é coletado com raio finito (`IdlePolicy.gd:483-518`,
  `LootSearchRadius = 192`). *Hipótese:* `autoPotionItemHash = 215387671` (Apple) pode ser a
  razão do texto de `FarmZoneData.gd:45-47`; não confirmou se char novo tem Apple nem se o
  `CactusPotion` do vendor (`EconomyCatalog.gd:201`) entra no auto-use.
- **Core Loop 6,5.** A porta de capacidade fecha no servidor (`FarmZoneData.gd:266` cobrado em
  `Server.gd:614`, `WorldCommands.gd:1125`, `IdlePolicyService.gd:66,259`) e o anel de
  prestígio é lido no faucet (`OfflineSettle.gd:290-296`; essência em `Stats.gd:241`).
  *Contra, o defeito:* dez escritores crus de `stat.gp` fora do kernel, com o contrato do
  kernel em `EconomyKernel.gd:85-96` dizendo que escrever `stat.gp` sem mexer no agente é
  escrever valor que sobrevive até o próximo snapshot — e o snapshot é absoluto
  (`SQL.gd:1156`, `SQL.gd:533-543`, `World.gd:206`, `SQLCommons.gd:11`). O detector
  (`EconomyKernel.gd:187`) só flagge `s.gp < balance_after`, então a perna do estouro é cega.
- **Meta Game 7,5.** Temporada é dado + estado: `data/conf/seasons.json` (`s1` rotativa, `s2`
  1799971200–1802563200, `premium_sku pass.s2`) com recusa explícita de vigência inválida
  (`SeasonService.gd:191-212`, `:199`, `:204`) e relê por relógio (`SQLBackups.gd:142`).
  Missão do passe resolvida por `COUNT(*)` de telemetria e ledger reais
  (`PassService.gd:130-178`) e entrega escrevendo wallet+ledger, baú, VIP e cosmético
  (`:315-352`). Governança autoritativa com rastro (`GuildService.gd:263,278,294,313`,
  migration 062) e buff de guilda consumido no settle (`OfflineSettle.gd:230-233`).
  *Hipótese/lacuna:* `SnapshotSeasonPower`/`SnapshotSeasonBossKills` pontuam estado
  acumulado, não o delta da janela (`SeasonService.gd:223-261`; só `spend` era janelado quando
  a nota foi dada — a 064 de 2026-09-29 janela as outras três), e
  `pass_tiers` é `{}` nas duas entradas era verdade só para a S1, que fechou em 2026-09-29: ela declara no arquivo o espelho nível a nível do catálogo (`tests/season_liveops_test.gd`), e a S2 já tinha trilha própria.
- **Game Design 7,0.** Curva calculada por ele sobre `Experience.gd:14-16` e
  `FarmZoneData.gd:263-270`: zona 27 dá `xp/kill 397.047`, `par/h 76`, `offline xp/h
  18.105.343`, `h to L60 250.1h = 10.4d`; zona 24 dá `458.3h = 19.1d`; total
  `4.527.868.739` XP; última linha do cálculo: `essence at cap: xp/h z27 online ->
  50,694,961`. Com cap F2P de 8 h (`OfflineSettle.gd:22`), a nota de
  `Experience.gd:9-10` ("~3 semanas", "income saturates at zone 24") não é verdadeira — e
  `ZONE_COUNT = 27`. `data/conf/economy_base_catalog.json` tem 5 knobs; o resto da afinação é
  const de GDScript. Torneira × gasto: ~2,26M gold/h na zona 27 contra ~29.000 gold/dia de
  teto do vendor, 10.000 a chave de boss, 5.000 a guilda, `500 × tier²` = 40.500 na forja
  tier 9 (`CraftCatalog.gd:111-112`).


### Veredito bruto — juiz A, grupo produto (Core Gameplay, Core Loop, Meta Game, Game Design)

Chegou 2026-09-28 (44 chamadas, assento relançado com teto). Também **não mediu nada**: as
três tentativas de harness caíram em `GATE PULADO: godot estrangeiro (pid 269904)` — um godot
órfão reparentado a systemd segurava o boot havia mais de 30 minutos, fora do alcance da
isenção por ancestralidade do boot guard. (O orquestrador conferiu depois: o pid não existia
mais e a锁 voltou a girar; o achado operacional é o próprio órfão segurar o portão.)

- **Core Gameplay 8,4.** `IdlePolicy.gd:191` produz `State.DEAD`, `:529-535` revive in-place
  com downtime e `sessionDeaths` na eficiência; kill nosso leva a `State.LOOT` e `_tickLoot`
  colhe com raio travado (`:373`, `:494`, `:28`); cap de aggro com `pop_front()`
  (`AIAgent.gd:68`). *Lacuna:* L1 nu não tem a maçã do `autoPotionItemHash` (`:81`) e nenhuma
  régua afirma a sessão de 300 s com ≤2 mortes.
- **Core Loop 8,5.** A perna earn existe em código (`OfflineSettle.gd:302,308`, kills
  alimentando drop e chave em `:319,:326,:362`); spend real com débito + ledger
  `vendor:<offer>` na mesma transação (`ShopService.gd:297-299`) e gemas queimando em
  `:33-35`; cadeado de capacidade por `Formula.GetPowerScore` (`Server.gd:614`) e essência
  nascendo no level (`OfflineSettle.gd:417`). *Lacuna:* nenhum harness emenda o ciclo
  inteiro — cada transição é verde isolada. *Hipótese declarada:* não rodou o
  `economy_invariant_fuzz`, não leu o kernel do reset.
- **Meta Game 7,6.** `SeasonConfig.gd:244` valida `pass_tiers.max_level` contra o produto e
  `PassService.gd:84` lê a trilha do arquivo; `SeasonService.gd:210` abre a temporada do JSON
  e congela as regras, com preempt da S2 agendada em `:303`; o meta entra na torneira real
  (`OfflineSettle.gd:233,269`). *Contra:* em `data/conf/liveops_calendar.json` nenhuma janela
  está no ar hoje (uma encerrada 20–21/09, o resto em nov/2026 e jan/2027) e das quatro `races` só
  tracei `guild_points` e `boss_kills`. O `pass_tiers` é `{}` na S1 era verdade como escrito em 2026-09-28
  e fechou em 2026-09-29: a S1 declara no arquivo o espelho nível a nível do catálogo, amarrado por `tests/season_liveops_test.gd`.
- **Game Design 8,0.** Curva calculada por ele: `z1 xp/h=180000`, `z24 xp/h=16466328`,
  `z27 xp/h=30175572`, `hours at z27 = 183.1 (7.6 days); at z24 = 335.5`, e a última linha
  `offline z1: 8h*0.6*eff1 xp= 864000  xp needed L1->2= 9760`. `economy_base_catalog.json`
  com `chest_cost_gems: 120` dentro da banda 60..240, lido via `ShopService.gd:30` (faixa,
  não igualdade — rebalance sem rebuild). *Contra:* trilha gratuita soma 100 gemas por
  temporada contra 120 por baú (`EconomyCatalog.gd:447,529`), com `REFERRAL_BONUS_GEMS = 200`
  como única torneira social; guild L10 a 10 M de gold é ~2,6 h de farm na zona 27.
  *Conferido pelo orquestrador em 2026-09-29:* a aritmética dos 100 contra os 120 é verdadeira
  (`PASS_FREE` soma 10+10+15+15+20+30), mas a conclusão que ele escreveu na planilha — "o F2P
  nunca alcança um baú" — não é: a própria trilha gratuita distribui 4 baús, um no nível 5, um
  no 16 e dois no 24, nas linhas 448 a 450 do mesmo arquivo. O par de linhas citado também
  estava torto: `:529` é o `REFERRAL_BONUS_GEMS` que ele nomeia na cláusula seguinte, e o preço
  do baú mora na linha 170 (`deal_chest1`, `cost: 120`). A pia que ele media aqui — forja sem
  fator de zona — fechou no mesmo dia: `tests/gold_sink_scale_test.gd`, 159 checks, 0 falhas.



### Veredito bruto — juiz A, grupo entrega (Testes, Segurança, DevOps, Live Ops)

Chegou 2026-09-28 (assento relançado com teto de chamadas depois que o juiz original
estourou 150 turnos esperando um processo em background). 80 chamadas, medido sob contenção
pesada — o `admission_gate_test` dele esperou ~980 s pelo `flock` de boot. Declarou não ter
encontrado credencial viva em arquivo rastreado.

- **Testes 7,8.** `one admission_gate_test` → `godot exit=0` com
  `== ADMISSION: 96 checks, 0 failures ==`; `tests/perf_fix_test.gd:141` asserta
  `Check(src.contains("Peers.Footprint(peerID, \"claim_settle\", ...)` — lê PROSA do fonte;
  contou 419 linhas de `Check(...contains(...)` em 4.290 linhas de `Check*` em `tests/*.gd`
  (~10% da suíte é casamento de texto). `scripts/check_ci.sh:190` aceita qualquer `needs`
  como portão, e `.github/workflows/godot-ci.yml:521-524` amarra o job que publica a `builds`
  (registro da passada: `test-gate` entrou nessa mesma lista depois, fechando #83; o ponteiro
  antigo apontava para 415, linha que o `+68` do passo de `nginx -t` deslocou);
  `structure` verde com `== CI GATE: 97 checks, 0 failures ==` passa por cima do próprio
  buraco. *Hipótese:* ~93 suítes do kernel ficaram não conferidas nesta passada.
- **Segurança 7,2.** `sources/network/server/Admission.gd:103` declara `windows` e escreve em
  `:141`; nenhum `erase`/`clear` no repo — cesta pré-auth cresce sem teto por endereço.
  Caminho de ataque que o código não barra: o limitador por RPC vive em
  `sources/network/Network.gd:1146`, dentro de `CallServer`, que roda no processo do
  CHAMADOR; no servidor `Peers.Footprint` só aparece em `Server.gd:629` e `:1085`, e
  `TriggerChat` (`Server.gd:1649`) corta tamanho, cobra mute, faz
  `Network.NotifyGlobal("ChatPlayer", ...)` sem cobrar taxa — quem pular `CallServer` e
  emitir o `@rpc` direto inunda o fan-out. `.github/workflows/release.yml:72-74` assina o
  APK de release com `/root/debug.keystore`, `androiddebugkey`/`android`. *Hipótese:*
  superfície SQL sem injeção encontrada (concatenações em `SQL.gd:825,836` e
  `FraudeReview.gd:248` montam cláusulas internas e passam valores por bindings).
- **DevOps 6,3.** `structure` → `== COMPOSE GATE: 152 checks, 0 failures ==` com
  "fumaça: 0 rodaram, 0 falharam, 2 pulados", porque `docker` não existe na máquina; nginx
  idem. `gh run list --commit 855b0a7…` não devolve run: a árvore atual nunca passou pelo
  portão remoto (o último é de `9e38f16`, três commits atrás) e aquele run publicou o snap
  de fato. `snap` com `needs: builds` publica `release: edge` em push a master com
  `idle-tests` vermelho; `release.yml:119,147` repete; `deploy/server/entrypoint.sh:108-137`
  (SIGTERM → canary → drain) é conferido só por texto em `scripts/check_compose.sh:1213`.
  *Nota do orquestrador:* parte disso é ausência de ferramenta no host, não defeito do
  repo — mas o publish-sem-teste é do repo, e está aberto como work order.
- **Live Ops 6,0.** O declarativo é real: `data/conf/liveops_calendar.json:6,8` com três
  kinds e `ImplementedKinds` recusando o arquivo inteiro por kind sem consumidor;
  `data/conf/seasons.json:2` com relê por TTL de 60 s e `_fail_closed`; `/flags reload`
  dentro do processo vivo (`sources/ops/OpsCommands.gd:79-80`); `deploy/alerts.rules.yml:102`
  bate com a série emitida em `sources/system/MetricsServer.gd:239` e o evaluator de
  alerta agora existe no compose (`:315,370`). *Lacuna:* nenhum dashboard versionado,
  nenhuma prova de ENTREGA de alerta, nenhum exercício cronometrado do drain;
  `deploy/docker-compose.yml:410-411` deixa `SHAMBLETA_ALERT_PAGE_WEBHOOK_URL` vazio, então
  uma stack recém-subida pagina para ninguém; e a transição S1→S2 nunca foi exercida em
  lugar nenhum (S2 agendada para 2027-01-15).

### Veredito bruto — juiz A, grupo engenharia (Arquitetura, Performance, Escalabilidade, Código)

Chegou 2026-09-29 (39 chamadas, assento relançado com teto). Rodou `one benchmarks` ele
mesmo, sob contenção de outro juiz, e refez em shell a deriva do marcador para os 7
harnesses explícitos. Conferi por mim, antes de gravar: os dois funis de
`ledger_transaction` em `EconomyKernel.gd` (`:20-28` lê, `:44-55` escreve fora de
transação), a afirmação de `SCALING.md:327-328`, os 30 sites `.db.` crus, a ausência de
métrica de passo em produção, a ordem textual de `reason_toast_test` e o `gate` que
`scripts/test.sh:22` anuncia e não existe como case.

- **Arquitetura 7,0.** A favor: identidade nunca vem do pacote — `Server.gd:602`
  (`Peers.GetCharacter(peerID)`, repetido em `:625/:639/:654/:730`) com a régua que morde
  em `tests/run_rpc_identity_test.gd:147`, dois WebSockets reais em que A declara ser B e
  o servidor devolve o `AuthPeerID` de A. Leitura fail-closed em `SQLReadRules.gd:14-19`
  (`txnDepth > 0` nunca roteia) e `SQLReadPool.gd:11-13` declarando o pool
  não-fonte-de-verdade, com a opção `read_only=true` refutada por medição no próprio repo.
  **Contra (a nota):** `EconomyKernel.GrantItem` (`:44-55`) insere em `ledger_transaction`
  por `Launcher.SQL.db.query_with_bindings` sob `_eco._get_settle_mutex(accountID)` — não
  sob `queryMutex` e não dentro de `SQL.Transaction()`, ao contrário do que o comentário de
  `LedgerAppend` (`:33-41`) exige — enquanto `:20-28` lê a mesma tabela pelo funil.
  `SCALING.md:327-328` afirma que a `queryMutex` "continua sendo o único funil de escrita"; a
  varredura do juiz devolve 30 sites `.db.` crus em `sources/`, inclusive caminhos de
  dinheiro (`GuildService.gd:164,207`, `AuctionHouseService.gd:263`,
  `CheckoutService.gd:490`). Nenhum gate faz censo desses sites, embora o repo já tenha a
  técnica para `presence_session`. *Hipótese declarada por ele:* benigno em termos de
  corrida, não de observabilidade — `Thread.new()` só aparece em `SQLBackups.gd:5`; li o
  sítio da definição, não cada chamador.
- **Performance 8,0.** `bash scripts/test.sh one benchmarks 600` → última linha
  `== GATES COM RUÍDO: none ==`, com `Load probe: 800 settles — p50 618 µs, p99 1938 µs,
  max 549622 µs (budget p99: 2076 µs), erros: 0` e normalização no mesmo processo (máquina
  a 1,03×; p99 normalizado 1881 µs = 3,62× o baseline). A auto-auditoria recusa folga
  abaixo do pior p99 normalizado já medido sob carga hostil (`WorstP99NormalizadoSobCargaUs` = 1601, `tests/benchmarks.gd:@WorstP99NormalizadoSobCargaUs`) e fecha os dois lados (folga `>4×` deixa passar
  regresso de 5×; `<2×` flakeia contra o ruído de 1,24× do run ocioso), com a cauda julgada
  duas vezes — p99 normalizado E taxa de hitch (`BudgetSlowIterPct`, `tests/benchmarks.gd:@BudgetSlowIterPct`, porque "com 800
  amostras, 1% de hitch cai exatamente no furo do p99"). Calibre de 4 ms/passo injetado de
  propósito em `tick_capacity_test.gd:81-82,443-445`, com o monitor da engine obrigado a
  ver ≥70% da queima. **Contra:** nenhum detector do orçamento de passo em produção —
  `grep -rn -e TIME_PHYSICS_PROCESS sources` devolve só `ServerDisplay.gd:13` (painel de dev
  legível por humano) e `/metrics` expõe espera de mutex (`MetricsServer.gd:173-178`), não
  ms/passo; o `max 549.622 µs` (3 hitches >50 ms em 800) ficou sem causa confirmada —
  provavelmente o auto-checkpoint do WAL, como `BudgetSlowIterPct` (`tests/benchmarks.gd:@BudgetSlowIterPct`) declara. *Não remediu*
  `tick_capacity_test` nem `multi_instance_tick_test` (outro juiz segurava o lock, visível
  no `GATE SERIALIZADO`), então as escadas de tick ficaram evidência estática, não veredito
  medido.
- **Escalabilidade 7,2.** A favor, e ele faz questão de registrar: o teto é degrau medido
  com âncora amarrada à medição (`SCALING.md:99-105`,
  `DRIFT proc_inside_rung_players 200`) e cobrada por `multi_instance_tick_test.gd:1675` com
  mensagem que nomeia a regressão ("capacidade real caiu abaixo do que a doc promete"); os
  recursos que NÃO limitam foram medidos (`fd 15→15`, threads 16→16, `RLIMIT_NOFILE` e
  `NPROC` lidos de `/proc/self/limits`, inclinação de RSS 0,671 MB/player, então quem
  vincula é o tick); a extrapolação 10→15 instâncias é rotulada "**declarada** (não é
  medição)". **Contra:** o horizontal é confesso em texto — `:285-295` "Dois servidores em
  duas máquinas não foi medido", contenção entre processos no mesmo WAL em `:225-228` —
  então o "~200 players conviventes" é teto **por processo único** e o número de lançamento
  não tem medida multi-processo. A tolerância da âncora (±100 sobre 200) aceita doc entre
  100 e 300: um erro de 2× passa, e a régua é unilateral (pega queda, não inflação). A §2
  admite que outra corrida (2026-09-28 22:27) leu 1,38/4,75/8,12/31,82 nos mesmos degraus —
  prosa defasada, rotulada como prosa. O recipe de `:136` manda rodar `godot --headless -s`
  cru, com caminho absoluto pessoal, classe de processo que o próprio `boot_guard` do
  `test.sh` recusa por causar SIGSEGV.
- **Código 7,3.** O defeito que ele mais gosta: `one benchmarks` devolve
  `::error::o run não terminou: faltou a linha "== RESULT:" (crash ou timeout)` e
  `GATE VERMELHO: benchmarks` com `godot exit=0` e `== Benchmarks: 0 failures ==` no
  produto. Causa determinística, apurada em estático: `harness_marker` (`scripts/test.sh:@harness_marker`) casa só
  `"== [A-Z]+[A-Z ]*:` e cai no default `== RESULT:`, que `_run_benchmarks` (`tests/benchmarks.gd:@_run_benchmarks`)
  (`== Benchmarks:`) não emite — só o case hardcoded `:604` conhece o marcador real. Mesmo
  defeito em `test_backup_restore` (emite `== Backup Restore Probe:`). E `reason_toast_test`
  é julgado certo **por acidente de ordem textual**: a regex acha o `"== RESULT:` de
  `_finish` (`:57`) antes do `== REASON:` de `_initialize` (`:61`); mover `_finish` para o
  fim do arquivo troca o marcador que o gate cobra — o contrato de `testing.md` ("o
  marcador vem do próprio arquivo") está cumprido por 59 auto-inscritos e violado por 2 dos
  7 explícitos no caminho `one`. A dívida é honesta e medida: 1 TODO/FIXME real em 330
  `.gd` (os demais hits são "TODOS" em português), `check_god_nodes.sh` limpo com folgas
  vivas (`Server.gd 1963/teto 1965`, `SQL.gd 1808/1814`) e a regra "encolheu tem que baixar
  o teto" no cabeçalho (`:16-24`). *Nota dele:* o `gate <log> <marker> <script>` que o
  cabeçalho de `test.sh:15` anuncia como interface não é case — os cases são
  `all`, `quick`, `idle`, `backup`, `benchmarks`, `rpc`, `companion`, `fixation`, `preflight`, `structure`, `one`, `diag`, `clean`,
  então rodou os `check_*.sh` à mão. Não abriu os valores de `data/conf/credential.cfg:1-6`
  (só nomes de chave e contagem de linhas); `check_secrets.sh` →
  `== SECRETS GATE: 37 checks, 0 failures ==`, o que "sugere placeholder/allowlist, não
  credencial viva".
- **Ponto cego declarado por ele:** os falsos-vermelhos do `one` são fail-closed (nunca
  geram verde falso), mas queimam um boot de vários minutos justamente do juiz que depura;
  e a veracidade do marcador dos outros 56 harnesses ficou como deriva em shell, não como
  run.

### Veredito bruto — juiz B, grupo dinheiro (Retenção, Monetização, Marketplace, Economia)

Chegou 2026-09-29 (33 chamadas, assento relançado com teto). **Não conseguiu rodar nenhum
harness GD**: `bash scripts/test.sh one economy_invariant_fuzz` devolveu
`GATE SERIALIZADO: godot pid 330713 pertence a outra instância deste script` em 3 tentativas
ao longo de ~975 s, e ele registra isso como contenção, não como falha do projeto. Rodou os
portões Python, que ficaram verdes: `test_retention.py` (`== RETENTION: 21 checks, 0 failures ==`),
`test_refund_cli.py` (`12 checks`), `test_season_offer.py` (`125 checks`). Conferi por mim,
antes de gravar, as quatro afirmações que baixam a nota: o `LossOnBreak` de topo de ciclo, o
`stat.gp` cru do grant, o par de padrões do detector de lavagem contra os motivos do AH, e o
`escrow_uids` gravado e nunca lido no cancelamento.

- **Retenção 8,3.** O ciclo existe e é honesto: escada `[100,200,300,400,500,750,1000]`
  (`StreakService.gd:21`), reentrada no mesmo `ShopDay` sem nada (`:158`), ouro saindo pelo
  ledger (`:188`), relógio do servidor (`:144`) — nunca data de cliente. Progresso offline
  cap-8 h F2P / 24 h VIP / horas por anúncio (`OfflineSettle.gd:131-132`) e a XP que sobra no
  cap vira essência (`:409-411`). O `balance_test` assere o carimbo do funil de login
  (`:187`) e a proporção do faucet, não uma constante (`:358`: ciclo semanal ≤ 10% de uma
  liquidação F2P no cap). **Contra:** `LossOnBreak` (`:76-80`) devolve 0 exatamente no dia 7 —
  o comentário confessa "no topo do ciclo o número é 0 de propósito" — então o único número
  de aversão à perda some no dia que mais paga, e nenhuma segunda razão de retorno é asserida
  do dia 8 em diante. *Hipótese dele:* não há notificação de "cap offline cheio" como gatilho
  de retorno, e o D1 é régua de medição, não mecanismo de retenção.
- **Monetização 8,5.** A perna de dinheiro está fechada onde ele pôde medir: fila reivindicada
  dentro do MESMO commit (`CheckoutService.gd:268-275`, `AND status='pending'` + releitura de
  verificação antes de creditar), idempotência conferida por CONTA (`:174` — colisão de chave
  de outra conta recusa em vez de devolver `true`), clawback limitado à parte paga (`:368`
  `mini(owed, clampi(GetGemsPaidRaw, 0, clawBal))`), rombo denunciado na coluna `error` e na
  fila de revisão (`:219`), art.49 exigindo prova de origem (`:552`) e barrando pagamento
  duplo pós-clawback (`:541`). Em produção o slot de anúncio nasce PENDENTE (`expires_at = 0`)
  e só o HMAC do portal ativa (`AdsCosmeticsService.gd:91-96`), com nonce de
  `Crypto.generate_random_bytes(16)` e não `randi()` (`:114`). Preço único em
  `data/conf/paid_catalog.json` com consentimento antes de qualquer preço (`:93`) e SKU do
  passe lido da linha ativa do banco (`:133`). **Contra:** o grant `kind == "gold"` escreve
  `stat.gp` cru (`:392` leitura, `:396` `{"gp" = gp + amount}`) fora do caminho único que
  `AuctionHouseService.gd:10-14` e `EconomyKernel.gd:86-96` documentam — para personagem com
  agente carregado o snapshot de 600 s reverte o crédito, e o detector de `:187` só flaga.
  Nenhum SKU pago é `gold` hoje, então o alcance é GM/sandbox.
- **Marketplace 7,6 — a nota mais baixa e o achado mais dele.** A mecânica é sólida:
  autordealização barrada nas duas chaves (`:354`, mesmo caminho de liquidação para ask e bid),
  escrow de demanda conferido antes de pagar (`:627` `held < need * unitCap → false`),
  depósito por `_MoveGoldLocked` (`:558`), sobra devolvida (`:649,:656`), cap por conta
  (`:549`), preço realizado na MESMA transação (`:389`) com `UNIQUE(listing_id)` (059), e a
  suíte asserindo invariante — `marketplace_depth_test.gd:412` confere que a RIQUEZA
  (carteira + escrow aberto, `:168-172`) não mudou. **Contra:** não há faixa de preço
  (`:269` só `priceGold <= 0`) e o detector ficou cego por decisão documentada: `:391-399`
  explica que a perna de compra foi movida de `trade_in:` para `ah_in:` porque `LastTradeTimestampRaw`
  armava o cooldown de 60 s de troca direta em quem comprava no leilão e `_FlagFlipTrades`
  abria flag de lavagem em quem recomprou o próprio item — mas `_FlagFlipTrades`/`trade_burst`
  (`FraudeReview.gd:328,340,345`) só enxergam `trade_out:%`/`trade_in:%`, então o round-trip
  entre duas alts do mesmo humano transfere ouro arbitrário em preço auto-fixado sem sinal
  nenhum. O AH não herdou nenhuma fricção da troca direta (`TradeChestService.gd:38-49`:
  e-mail verificado, cooldown, cap diário) — tem 5 gems de taxa e 5 slots. E
  `CancelListing` (`:460`) re-minta lote novo apesar de `escrow_uids` estar gravado (`:94,:318`)
  e lido só em `:375`, pelo primeiro uid, para o `parentUID` do comprador. *Conferido por mim
  além dele:* `auction_listing` não tem `expires_at` (DDL em `data/conf/migrations/018`, com
  `status`/`created_at` e índices por `status`) e nenhuma referência a expiry/reaper em
  `sources/` — o ask espera a alt o tempo que for, com o item travado fora do inventário.
- **Economia 8,4.** Escritor único de ouro com carteira nunca negativa (`EconomyKernel.gd:121`),
  `ApplyGoldMoves` aplicando DELTA e não valor absoluto para não apagar receita ganha durante a
  transação (`:116-124`); fuzzer assere I1..I6 (`economy_invariant_fuzz.gd:309-324,336,342`) e
  trata verde por inércia como falha (`:369-373`); uma única régua `equivKills` gera os dois
  faucet (`OfflineSettle.gd:319-331`) com o drop recalibrado de ppm-de-segundos para
  ppm-de-kills contra a taxa online medida ("0,54 drop/h contra ~105/h do farm ao vivo",
  `:324-326`); paridade online/offline asserida como invariante em `balance_test.gd:230-237`;
  knobs por FAIXA (`economy_knob_range_test.gd`). **Contra:** offline sorteia UM item por
  liquidação (`GetDropForRoll(zoneID, charID + zoneID)`, `:335`, gravado como
  `drops[itemHash] = dropCount`) — a taxa bate, a distribuição não: o AFK tem variância zero e
  nunca diversifica o pool da faixa. E `ReconcileWalletDaily`/`DivergingWallets` (`:170,:207`)
  usa o último `balance_after` como atestado, o que pega reversão de snapshot mas só denuncia.
- **Declaração de limitação, dele:** "medi sob contenção, nada aqui é veredito vermelho do
  projeto"; o `spend_confirm_test`, o `fraud_test` e o fuzz de invariantes — a prova executável
  de dupla entrega e estorno pós-gasto — nunca rodaram para ele, então a robustez do fuzzer é
  lida de código.

### Veredito bruto — juiz A, grupo dinheiro (Retenção, Monetização, Marketplace, Economia)

Chegou 2026-09-29 (40 chamadas, último assento da rodada, relançado com teto). É o único
assento de dinheiro que **medi em GD**: `bash scripts/test.sh one balance_test 520` →
`== RESULT: 875 checks, 0 failures ==`, última linha `== GATES COM RUÍDO: none ==`, mais os
portões Python `test_security` (63), `test_refund_cli` (12), `test_ad_ssv` (68),
`test_season_offer` (125) e `test_retention` (21). Não conseguiu rodar `marketplace_depth_test`
nem `economy_invariant_fuzz`: duas recusas `GATE SERIALIZADO` com o lock de boot tomado pelo
`run_idle_tests` de 1800 s/1200 s e pelo `multi_instance_tick_test` de outros agentes — ele lê
isso como contenção do harness compartilhado, não como defeito do projeto. Conferi por mim as
três afirmações que baixam a nota: o `kind = LedgerKindGems` do reembolso, a ausência total de
revogação de `premium`/`vip_until`, e a linha do fuzzer que confessa IG2 não-asserta.

- **Retenção 7,2.** O streak é durável e medido — `same_day` sem recompensa (`StreakService.gd:158`)
  dentro da mesma transação que paga a escada (`:179-191`), dia por `EconomyCatalog.ShopDay` do
  relógio do servidor (`:144`), sem campo de data vindo do cliente. **Contra:** o gancho não paga a
  quebra. Um ciclo de 7 dias soma 3.250 de ouro contra ~108.000 de UMA liquidação F2P de 8 h —
  ~3%, e o `balance_test` que ele rodou assere exatamente essa proporção (`:358`). O que puxa o
  retorno é o cap de offline (`OfflineSettle.gd:132`), não a escada. E a agenda está **vazia hoje**:
  `data/conf/liveops_calendar.json` traz 6 eventos, o primeiro encerrado em ~2026-08-21, os dois
  seguintes só em ~2026-11-04 e os três últimos na abertura da S2 (~2027-01-15); `data/conf/seasons.json`
  declara `s1` com `start_unix: 0, end_unix: 0`. Conferi os dois arquivos: não há nada vivo no
  instante do run, e a janela entre a última campanha e a próxima é de ~45 dias.
- **Monetização 7,9 — e o achado é o P0 que nenhuma rodada anterior nomeou.** O caminho de gemas
  está fechado e ele mediu: `SetGemsRaw` drena `gems_paid` primeiro e clampa em `[0, gems]`
  (`SQL.gd:1144`), a fila é reivindicada para `processing` e **relida** antes do crédito no mesmo
  commit (`CheckoutService.gd:170`), `EnqueueGrant` só devolve `true` na reentrega se o dono da
  chave é a mesma conta (`:168-174`), clawback limitado a `gems_paid` com rombo virando fila de
  revisão (`:368-375`). **Contra:** a reversão só conhece gemas. `Server.gd:58 RequestRefund` chama
  `EconomyService.gd:377 RequestGemRefund`, que cai em `CheckoutService.gd:523-526` consultando
  `ledger_transaction WHERE account_id = ? AND kind = ? AND reason = ?` com
  `EconomyCatalog.LedgerKindGems` — e devolve `not_found` para qualquer outro kind. Dos 11 SKUs do
  `paid_catalog.json`, **8 não são gems** (`vip.1mo`, `vip.3mo`, `pass.s1`, `pass.s1.deluxe`,
  `pass.s2`, `donate.support`, `starter.pack`, `founder.pack`); e não há caminho de revogação em
  lugar nenhum: `grep -rn 'premium = 0' sources tests data` **não devolve nada**, `vip_until` só é
  escrito para frente (`CheckoutService.gd:403`, `SQL.gd:1055`) e `season_account_state.premium = 1`
  (`:438`) nunca volta a 0. Estorno de passe ou VIP devolve o dinheiro e deixa o passe ativo.
  *Limitação dele:* nada foi verificado contra o Mercado Pago real (exige token), só o CLI com
  dry-run; e ele aceita sem prova que `nginx_hardening_test` mantém o rate-limit de `/checkout/` e
  `/webhooks/`.
- **Marketplace 7,0.** A favor: auto-negócio barrado no único funil (`:354`) **e** repetido como filtro
  SQL nas duas direções (`:630 seller_account != %d`, `:681 buyer_account != ?`); a suíte varre o banco
  do harness — `marketplace_depth_test.gd:533` exige zero ordens com `escrow_gold <> quantity * unit_price`,
  `:535` nenhuma fechada com escrow > 0, `:537` nada negativo, `:596` carteira + escrow == soma do
  ledger de gold. **Contra:** a assimetria de teto — `ListItemForSale:269` e o RPC
  `Server.gd:1365 AuctionList` só rejeitam `priceGold <= 0`, enquanto a demanda tem
  `AHMaxBidUnitPrice = 100000000` e `AHMaxBuyOrderGold = 1000000000` (`EconomyCatalog.gd:144,146`) —
  mais o detector cego ao namespace do leilão (`FraudeReview.gd:328,340,345` só casam
  `trade_out:`/`trade_in:`) e a ausência de `expires_at` (`migrations/018`) formam o round-trip
  barato entre alts. Achado só dele, que eu confirmei por ausência: `_TryMatchListing` tem **um
  chamador** (`:332`, depois do commit e com o lock solto de propósito, para taxa não paga duas
  vezes) e nenhuma varredura de re-cruzamento no boot existe — um restart entre o anúncio e a
  matching deixa ordens em pé sem parceiro até o próximo evento.
- **Economia 7,6.** A favor, medido: `balance_test.gd:231` assere `gold online/hora >= offline/hora`
  por nível 1..40 contra o `BuildReport` real da liquidação (desigualdade relacional, não
  constante), e `_MoveGoldLocked` (`EconomyKernel.gd:103`) recusa `next < 0` antes de escrever
  `stat.gp`, espelhando DELTA pós-commit (`:116-124`). **Contra:** o fuzzer confessa o buraco —
  `economy_invariant_fuzz.gd:641` escreve que "IG2 (`paid <= gems`) é deliberadamente NÃO-asserto
  nestas contas: a taxa de anúncio gasta gemas pagas por fora do gate de origem, então
  `paid > wallet` é estado legal do leilão, não buraco", e é essa coluna que limita o clawback e
  fundamenta o `not_paid` do art.49. E não há censo de pia: `ReconcileWalletDaily`
  (`EconomyKernel.gd:184`) só enxerga a carteira **abaixo** do atestado do ledger, então um
  faucet que escreva `stat.gp` e ledger juntos é invisível por construção; as pias são
  enumeráveis (forja, vendor, guilda, chave de boss, taxa de torneio, death tax 5%, `ah_list_fee`)
  e as fontes também, mas nada soma a expansão líquida diária de oferta de moeda.
- **Correção de registro:** ele disse "os outros 7 SKUs"; são **8** de 11 (ele não contou
  `starter.pack` e `founder.pack`, nem tirou os dois `pass.*` separados). O argumento não muda.


## Rodada 3 — fechada em 2026-09-29: vinte categorias, dois juízes cada

A régua foi recalculada do próprio arquivo, com a tabela acima como única fonte (script
lendo as 20 linhas, não memória): média **7,12**; **nenhuma** categoria acima de 9.

| # | categoria | mínima | # | categoria | mínima |
|---|---|---|---|---|---|
| 1 | Social | 5,5 | 11 | Retenção | 7,2 |
| 2 | Live Ops | 6,0 | 12 | Escalabilidade | 7,2 |
| 3 | DevOps | 6,3 | 13 | Código | 7,3 |
| 4 | Core Loop | 6,5 | 14 | Meta Game | 7,5 |
| 5 | Documentação | 6,5 | 15 | Economia | 7,6 |
| 6 | Segurança | 6,8 | 16 | Testes | 7,8 |
| 7 | Game Design | 7,0 | 17 | Monetização | 7,9 |
| 8 | Marketplace | 7,0 | 18 | Analytics | 8,0 |
| 9 | Arquitetura | 7,0 | 19 | Performance | 8,0 |
| 10 | UX/UI | 7,0 | 20 | Core Gameplay | 8,3 |

O que a rodada ensinou, e nenhuma rodada anterior sabia:

1. **A nota cai onde o portão não olha, não onde o código é frágil.** Dos vinte gaps
   nomeados, a maioria não é "falta feature" — é régua que afirma o contrário do fonte:
   o snapshot absoluto revertendo débito do vendor (#88), o `stat.gp` do grant pago, o
   `harness_marker` que faz `one benchmarks` mentir vermelho com `godot exit=0` (#81), a
   `queryMutex` nomeada "único funil" contra 30 escritores `.db.` crus (#91), o
   `alertmanager.yml` que pagina para ninguém (#90), o `snap`/`release` com `needs: builds`
   (#83). Fechar régua vale mais ponto do que fechar funcionalidade.
2. **Nenhum juiz dos dez rodou `marketplace_depth_test` ou `economy_invariant_fuzz` até o
   fim** — o lock de boot de 10 assentos em paralelo virou a limitação mais citada, e ela
   aparece escrita como contenção, não como defeito do projeto. Registro isso porque é
   custo do meu protocolo: com dez assentos em paralelo, a prova executável de dinheiro
   ficou lida de código em três das quatro categorias do dinheiro.
3. **Dois achados que as rodadas 1 e 2 não nomearam** e que eu conferi antes de gravar:
   o reembolso conhece só gemas — 8 dos 11 SKUs ficam `not_found` e não existe caminho de
   revogação de `premium`/`vip_until` no repo (estorno deixa o passe ativo); e o
   wash-trade do leilão é invisível por construção, porque o AH saiu do namespace
   `trade_out:`/`trade_in:` que o detector casa (#93).

Vinte ordens de trabalho abertas (#81–#100, contadas do `TaskList`, não da memória) viram
quatro ondas, na ordem em que a mínima pesa: **dinheiro** (#97 estorno sem revogação, #88
o snapshot que reverte o vendor, #91 o segundo funil do ledger, #93 wash-trade, #94
linhagem, #99 IG2 e censo de faucet, #100 re-cruzamento no boot, #95 distribuição do drop,
#96 aversão à perda, #98 agenda morta), **entrega** (#83 publish-sem-teste, #84 keystore de
debug, #85 cesta pré-auth, #86 rate limit no cliente, #87 gate de segredo, #89 nginx sem
`-t`, #90 página para ninguém, #81 marcador do gate, #82 âncoras de SCALING),
**experiência** (#92 orçamento de passo como métrica, mais as réguas de fit/social/analytics
já nomeadas) e **produto** (o ciclo, o meta e o sumiouro que R3A/R3B descreveram por último). Depois de cada onda, os
gates cobertos; no fim, `all` verde, commit, e uma rodada 4 com assentos novos — juiz que
não sabe o resultado anterior, porque é a única régua que ainda não foi comprada.

## Rodada 4 — assentos novos, depois do portão completo verde

A rodada 3 fechou com média 7,12 e nenhuma categoria acima de 9. Vinte ordens (#81–#104)
foram abertas a partir dos gaps nomeados e aterrissaram em quatro ondas: **dinheiro**
(#97, #88, #91, #93, #94, #100, #95, #96, #98), **entrega** (#83, #84, #85, #86, #87, #89,
#90, #81, #82), **experiência** (#101, #102, #103) e **produto** (#104, #99). Julgar de
novo é a única forma de a nota valer o estado atual: o que está na tabela das rodadas
anteriores é memória do que o repo era.

O que muda em relação à rodada 3 é mudança de protocolo, não do projeto:

- **Levas de até seis assentos, não dez em paralelo.** O lock de boot serializa harness
  GD; com dez assentos simultâneos nenhum dos dez rodou `marketplace_depth_test` nem
  `economy_invariant_fuzz` até o fim, e as categorias do dinheiro foram julgadas lidas de
  código.
- **Teto de 40 chamadas de ferramenta por assento**, com obrigação explícita: quem julga
  dinheiro, marketplace, economia ou código tem que **rodar** ao menos um harness GD da
  categoria e citar a última linha (`== RESULT: N checks, M failures ==`). Ler código sem
  rodar continua valendo, mas não sustenta nota acima de 9 sozinho.
- **Nada de `monitor`, `run_in_background` nem deixar processo vivo**: o assento que
  deixa um boot pendurado envenena o run do próximo — é a mesma razão do `flock` do runner.
- Assento não escreve no repo e não lê `BLIND_JUDGE_PROTOCOL.md`, as auditorias
  anteriores, `CHANGELOG.md`, `progress.md`, nenhum `archive/*.md` datado e nenhum `/tmp`
  começado por `gate-`, `judge-`, `blind-verdicts`, `shambleta-`, `red-`, `rerun-`,
  `drift-`, `qoder-`, `gateverdict`, `cleanall`.
- Harness é `bash scripts/test.sh one <harness> <timeout>`, nunca `godot --headless -s`
  cru: o atalho não aplica `flock`, o sandbox `.test-home/` nem `ci_gate_log.sh`, então o
  verde obtido por atalho não é o verde do portão.

Nota da categoria = mínima entre os dois juízes da rodada 4 e a mínima já registrada,
**a menos** que o juiz afirme que o gap que gerou aquela mínima fechou e cite a prova —
aí a mínima antiga é substituída pelo estado atual. Gap que fecha sem régua cuja falha
depende de a correção existir não conta como fechado.
