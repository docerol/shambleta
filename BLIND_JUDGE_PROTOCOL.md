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
| Meta Game | 8,5 | — | 7,6 | 7,5 | 7,5 | R3A+R3B: `pass_tiers` é `{}` na S1 — a única temporada no ar corre por default de código (`SeasonConfig.gd:244` valida a faixa, `PassService.gd:84` leria o arquivo se existisse) — e as `races` power/spend não têm produtor rastreado; o ranking de temporada pontua estado acumulado, não o delta da janela (`SeasonService.gd:174-207`) |
| Game Design | 8,6 | — | 8,0 | 7,0 | 7,0 | R3A+R3B: nenhum sumiouro de gold escala com a torneira (z27 paga ~3,77 M gold/h contra guild L10 a 10 M e teto de vendor ~29 k/dia), a trilha gratuita soma 100 gemas por temporada contra 120 por baú (`EconomyCatalog.gd:447,529`) — o F2P nunca alcança um baú — e `Experience.gd:9-10` afirma "3 semanas"/"satura na zona 24" contra a curva de 27 zonas |
| Retenção | 7,8 | — |  |  | 7,8 |  |
| Economia | 9,4 | — |  |  | 9,4 |  |
| Monetização | 9,4 | — |  |  | 9,4 |  |
| Marketplace | 8,5 | — |  |  | 8,5 |  |
| Analytics | 8,0 | — | 8,5 | 7,5 | 8,0 | R3A+R3B: o D1 é honesto sobre a própria janela nas duas pontas (`TelemetryService.gd:83,281`, `companion/server.py:466-476` com `window_closed`, migration 045) e os 14 `FUNNEL_KINDS` têm emissor real — mas `telemetry_event` não tem poda temporal alguma (retenção de 90 dias é só do ledger, `SQLRetention.gd:30`; o único delete é LGPD em `SQL.gd:326`), e `FunnelDaily`/`/metrics` fazem `GROUP BY` numa tabela que cresce para sempre com feature flag como única proteção |
| Live Ops | 9,2 | — | 6,0 | 6,8 | **6,0** | R3A+R3B: `deploy/alertmanager.yml:60-64` materializa os dois receivers como `webhook_configs: []` — por default do repo o `severity: page` não acorda ninguém; nenhum dashboard versionado; rotação de temporada/campanha é PULL com TTL de 60 s (`LiveOpsCalendar.gd:108`) e não há cron versionado (`deploy/STAGING.md:136`), então a transição depende de trocar arquivo no host. *A favor, medido por R3B:* as dez séries de `alerts.rules.yml` resolvem em `MetricsServer.gd:190-244` e o orçamento do drain tem controle negativo que morde (`check_compose.sh`) |
| Arquitetura | 8,5 | — | 7,0 | 8,9 | **7,0** | R3A+R3B: `EconomyKernel.GrantItem` (`:44-55`) insere em `ledger_transaction` por `Launcher.SQL.db.query_with_bindings` sob `_eco._get_settle_mutex`, **fora** de `SQL.Transaction()` — ao contrário de `LedgerAppend` (`:33-41`), que declara o contrário no comentário — enquanto `:20-28` lê a mesma tabela pelo funil; e `deploy/SCALING.md:285-286` afirma que "a `queryMutex` de `SQL.gd:7` continua sendo o único funil de escrita" contra 30 escritores `.db.` crus em `sources/` (`GuildService.gd:164,207`, `AuctionHouseService.gd:263`, `CheckoutService.gd:490`), sem nenhum gate de censo. R3B: nada exercita o ledger com DOIS processos servindo a mesma conta — a escala provada é multi-instância intra-processo |
| Performance | 8,5 | — | 8,0 | 8,7 | **8,0** | R3A: mediu `one benchmarks` sob contenção de outro juiz e o p99 normalizado ficou a ~10% do teto (budget 2.076 µs, 1.881 µs) — a régua aperta, mas `max 549.622 µs` com 3 hitches >50 ms não tem causa confirmada; e **não existe detector do orçamento de passo em produção**: `grep -rn "TIME_PHYSICS_PROCESS|get_frames_per_second" sources` devolve só `ServerDisplay.gd:13` (painel de dev legível por humano) e o que sai por `/metrics` é espera de mutex (`MetricsServer.gd:173-178`), não ms/passo. R3B: a régua do tick é gated pela MEDIANA; a 200 players o p95/max deu 42,09 ms contra orçamento de 33,33 ms e nenhuma harness compara a cauda com o orçamento |
| Escalabilidade | 7,4 | — | 7,2 | 7,9 | **7,2** | R3A+R3B: o teto horizontal continua `[NÃO MEDIDO]` e o doc confessa (`SCALING.md:285-295`: "Dois servidores em duas máquinas não foi medido", contenção entre processos no mesmo WAL em `:225-227`) — o "~200 players conviventes" é teto **por processo único**, e ninguém rodou dois escritores com `SHAMBLETA_SERVER_ID` distintos sobre o mesmo arquivo; a âncora do degrau é unilateral (±100 sobre 200 deixa passar um erro de 2× e só pega queda, não inflação). `deploy/SCALING.md:125-127` afirma um erro por-passo em `AIAgent.gd:64` que o código já não tem; o recipe de `:136` usa `godot --headless -s` cru, classe que o próprio `boot_guard` do `test.sh` recusa |
| Código | 8,2 | — | 7,3 | 8,6 | **7,3** | R3A+R3B: `harness_marker()` (`scripts/test.sh:437`) só casa `"== [A-Z]+[A-Z ]*:`, então `one benchmarks` (marcador real `== Benchmarks:` em `benchmarks.gd:397`) e `one test_backup_restore` devolvem `GATE VERMELHO` com `godot exit=0` e produto verde — reproduzido pelo R3A em shell para os 7 harnesses explícitos; e `reason_toast_test` é julgado certo **por acidente de ordem textual** (a regex casa o `"== RESULT:` de `_finish` em `:57` antes do `== REASON:` de `_initialize` em `:61` — mover `_finish` para o fim troca o marcador do gate). A superfície também mente: `scripts/test.sh:15` anuncia `gate <log> <marker> <script>` como interface, mas `gate` é função interna — os cases são `all|quick|idle|backup|benchmarks|rpc|companion|fixation|preflight|structure|one|diag|clean`. *A favor, medido por R3A:* 1 TODO/real em 330 `.gd`, e `check_god_nodes.sh` limpo com folgas vivas (`Server.gd 1963/1965`) |
| Testes | 8,2 | — | 7,8 | 8,2 | **7,8** | R3A: ~419 de 4.290 linhas de `Check*` casam TEXTO do fonte; `check_ci.sh:190` aceita `needs` de build como portão. R3B: `tests/nginx_hardening_test.gd:570-574` DEGRADA para ler a doc quando não há nginx no host e `deploy/web/Dockerfile:30` só `COPY`a o `nginx.conf` sem `nginx -t` — um proxy que o nginx recusa passa em todos os gates e chega ao prod |
| UX/UI | 7,5 | — | 7,0 | 7,5 | **7,0** | R3A+R3B: a passada de telefone do `hud_decision_fit_test` (verde medido por R3B: `== RESULT: 68 checks, 0 failures ==` sobre 390x844 com piso de 48 px) só amarra os 7 painéis que vivem no boot — guilda/leilão/forja/vault, que nascem por ação, estão fora da régua; e 66 chaves de conteúdo NPC seguem sem `pt_BR` (`data/i18n/coverage_report.md`) |
| Social | 5,5 | 9,0 | 8,0 | 6,5 | **5,5** | R3A+R3B: `GuildService.gd:94-97` é read-then-write sem transação nem lock (`JoinReason` conta por `SELECT COUNT(*)` em `GuildRoster.gd:105-108` e o `INSERT` vem solto, ao contrário de `LeaveGuild` logo abaixo) — o próprio código nomeia o buraco em `GuildRoster.gd:82-85` e a PK de `guild_member` impede double-join mas não o teto estourado; falta transação/`CHECK` durável + N joins simultâneos asseridos |
| Segurança | 8,7 | 6,8 | 7,2 | 7,5 | 6,8 | R3A+R3B: a cota existe só ANTES da credencial (`Admission.gd:67`, `NetworkCommons.gd:63`) — varredura por `MsgPerSec|PerPeer|Throttle|RateLimit` não acha janela pós-auth — então `TriggerChat` (`Server.gd:1644-1671`) amplifica 1→N sem taxa por peer; cesta pré-auth nunca podada; APK de release com debug keystore (`release.yml:107-109`) |
| DevOps | 8,9 | 8,8 | 6,3 | 7,0 | **6,3** | R3A+R3B: `snap`/`release` com `needs: builds` publicam com teste vermelho; `deploy/ROLLBACK.md:26-33` declara que não há registry e `pull_policy: never` (`docker-compose.yml:50,102,211,319,374`), então o `SHAMBLETA_TAG` do job `container-images` morre no runner efêmero; smoke de compose roda 0 containers e nenhum `up` existe no caminho |
| Documentação | 8,6 | 7,5 | 8,5 | 6,5 | **6,5** | R3A: taxa de erro falsa medida por ele = 0/5 (`DOC DRIFT: 1391 checks, 0 failures`), mas nenhuma afirmação de COMPORTAMENTO é coberta — números de `SCALING.md`/`OPS_RUNBOOK.md`/`WEB_SLIM.md` e o "4.7.2" de `deploy/web/landing/index.html:118`, construído em 4.7.1; e `tests/panel_fit_test.gd:6-7` aponta `WindowPanel.gd:235-237` para código que está em :238-239 sem acusação. R3B: duas afirmações falsas conferidas por mim passam — `docs/development/testing.md:87` diz "as 61 patches reais do boot viram a versão 61" contra 62 `.sql` em `data/conf/migrations/` (001..062), e a régua de numeral (`check_doc_drift.sh:178`) só morde quando o substantivo é "migrations", nunca "patches"; `README.md:65` aponta `Action.gd:176-199` para a cadeia `ui_*` que vai até 200, com `ui_fullscreen` FORA do intervalo citado, sem acusação |

Cadeiras entregues: **8 de 10** — produto A+B, engenharia A+B, entrega A+B,
experiência A+B. Faltam as duas de dinheiro (`juiz-A-dinheiro2`, `juiz-B-dinheiro2`),
relançadas depois que os assentos originais estouraram o teto de turnos. Enquanto elas
voam, a árvore fica congelada: são exatamente os arquivos de dinheiro que elas leem, e
mudar `scripts/test.sh` sob um run em andamento fabrica um verde que ninguém mediu.

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
  As âncoras `DRIFT proc_*` estão vivas e conferem. *Contra:* `deploy/SCALING.md:125-127`
  afirma que o `ERROR: Attempted to erase a variable of type 'int' into a TypedArray` em
  `sources/actor/agent/variants/AIAgent.gd:64` acontece dentro do passo de física e está
  incluído nos custos medidos — hoje a linha 64 é COMENTÁRIO e a 68 usa `pop_front()`; o
  bug foi corrigido. *Lacuna:* mesma do Arquitetura — shard real multi-processo indemonstrado.
- **Código 8,6.** Varredura de dívida: os ~121 hits de TODO/FIXME/HACK são a palavra
  portuguesa "todo", zero marcadores reais; guard-clause e autoridade do par em
  `sources/network/server/Server.gd` derivando de `Peers.GetAccount/GetCharacter` do peer
  de transporte; idempotência do grant com as duas guardas. *Contra, defeito concreto:*
  `harness_marker()` em `scripts/test.sh:435-440` casa só `"== [A-Z]+[A-Z ]*:`, mas
  `tests/benchmarks.gd:397` imprime `== Benchmarks:` e `tests/test_backup_restore.gd:28`
  imprime `== Backup Restore Probe:` e nenhum dos dois imprime `== RESULT:`; o fallback
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
  `sources/idle/IdlePolicy.gd:191` e `:522-535` (`_tickDead` → `Revive()`, `State.SEEK`,
  `sessionDeaths`/`sessionDowntimeSecs`), com substep fixo `TickInterval = 0.25` e
  `MaxCatchUpSeconds = 2.0` (`:163-166`). Aggro com cap cobrado no runtime e dano agregado
  por atacante (`sources/actor/agent/variants/AIAgent.gd:37-68`); drop nasce no evento de
  morte (`MonsterAgent.gd:34-40`) e é coletado com raio finito (`IdlePolicy.gd:483-518`,
  `LootSearchRadius = 192`). *Hipótese:* `autoPotionItemHash = 215387671` (Apple) pode ser a
  razão do texto de `FarmZoneData.gd:45-47`; não confirmou se char novo tem Apple nem se o
  `CactusPotion` do vendor (`EconomyCatalog.gd:201`) entra no auto-use.
- **Core Loop 6,5.** A porta de capacidade fecha no servidor (`FarmZoneData.gd:266` cobrado em
  `Server.gd:612`, `WorldCommands.gd:1125`, `IdlePolicyService.gd:66,259`) e o anel de
  prestígio é lido no faucet (`OfflineSettle.gd:290-296`; essência em `Stats.gd:241`).
  *Contra, o defeito:* dez escritores crus de `stat.gp` fora do kernel, com o contrato do
  kernel em `EconomyKernel.gd:85-96` dizendo que escrever `stat.gp` sem mexer no agente é
  escrever valor que sobrevive até o próximo snapshot — e o snapshot é absoluto
  (`SQL.gd:1156`, `SQL.gd:533-544`, `World.gd:206`, `SQLCommons.gd:11`). O detector
  (`EconomyKernel.gd:187`) só flagge `s.gp < balance_after`, então a perna do estouro é cega.
- **Meta Game 7,5.** Temporada é dado + estado: `data/conf/seasons.json` (`s1` rotativa, `s2`
  1799971200–1802563200, `premium_sku pass.s2`) com recusa explícita de vigência inválida
  (`SeasonService.gd:150-171`, `:158`, `:163`) e relê por relógio (`SQLBackups.gd:142`).
  Missão do passe resolvida por `COUNT(*)` de telemetria e ledger reais
  (`PassService.gd:130-178`) e entrega escrevendo wallet+ledger, baú, VIP e cosmético
  (`:315-352`). Governança autoritativa com rastro (`GuildService.gd:263,278,294,313`,
  migration 062) e buff de guilda consumido no settle (`OfflineSettle.gd:230-233`).
  *Hipótese/lacuna:* `SnapshotSeasonPower`/`SnapshotSeasonBossKills` pontuam estado
  acumulado, não o delta da janela (`SeasonService.gd:174-207`; só `spend` é janelado), e
  `pass_tiers` é `{}` nas duas entradas — a tabela vem dos defaults de código.
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
  `:33-35`; cadeado de capacidade por `Formula.GetPowerScore` (`Server.gd:612`) e essência
  nascendo no level (`OfflineSettle.gd:417`). *Lacuna:* nenhum harness emenda o ciclo
  inteiro — cada transição é verde isolada. *Hipótese declarada:* não rodou o
  `economy_invariant_fuzz`, não leu o kernel do reset.
- **Meta Game 7,6.** `SeasonConfig.gd:244` valida `pass_tiers.max_level` contra o produto e
  `PassService.gd:84` lê a trilha do arquivo; `SeasonService.gd:169` abre a temporada do JSON
  e congela as regras, com preempt da S2 agendada em `:249`; o meta entra na torneira real
  (`OfflineSettle.gd:233,269`). *Contra:* em `data/conf/liveops_calendar.json` nenhuma janela
  está no ar hoje (uma encerrada 20–21/09, o resto em nov/2026 e jan/2027), `pass_tiers` é `{}`
  na S1 — que é a temporada que corre — e das quatro `races` só tracei `guild_points` e
  `boss_kills`.
- **Game Design 8,0.** Curva calculada por ele: `z1 xp/h=180000`, `z24 xp/h=16466328`,
  `z27 xp/h=30175572`, `hours at z27 = 183.1 (7.6 days); at z24 = 335.5`, e a última linha
  `offline z1: 8h*0.6*eff1 xp= 864000  xp needed L1->2= 9760`. `economy_base_catalog.json`
  com `chest_cost_gems: 120` dentro da banda 60..240, lido via `ShopService.gd:30` (faixa,
  não igualdade — rebalance sem rebuild). *Contra:* trilha gratuita soma 100 gemas por
  temporada contra 120 por baú (`EconomyCatalog.gd:447,529`), com `REFERRAL_BONUS_GEMS = 200`
  como única torneira social; guild L10 a 10 M de gold é ~2,6 h de farm na zona 27.



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
  como portão, e `.github/workflows/godot-ci.yml:415` dá `needs: builds` ao job que publica;
  `structure` verde com `== CI GATE: 97 checks, 0 failures ==` passa por cima do próprio
  buraco. *Hipótese:* ~93 suítes do kernel ficaram não conferidas nesta passada.
- **Segurança 7,2.** `sources/network/server/Admission.gd:72` declara `windows` e escreve em
  `:141`; nenhum `erase`/`clear` no repo — cesta pré-auth cresce sem teto por endereço.
  Caminho de ataque que o código não barra: o limitador por RPC vive em
  `sources/network/Network.gd:1146`, dentro de `CallServer`, que roda no processo do
  CHAMADOR; no servidor `Peers.Footprint` só aparece em `Server.gd:629` e `:1085`, e
  `TriggerChat` (`Server.gd:1644`) corta tamanho, cobra mute, faz
  `Network.NotifyGlobal("ChatPlayer", ...)` sem cobrar taxa — quem pular `CallServer` e
  emitir o `@rpc` direto inunda o fan-out. `.github/workflows/release.yml:107-109` assina o
  APK de release com `/root/debug.keystore`, `androiddebugkey`/`android`. *Hipótese:*
  superfície SQL sem injeção encontrada (concatenações em `SQL.gd:825,836` e
  `FraudeReview.gd:248` montam cláusulas internas e passam valores por bindings).
- **DevOps 6,3.** `structure` → `== COMPOSE GATE: 152 checks, 0 failures ==` com
  "fumaça: 0 rodaram, 0 falharam, 2 pulados", porque `docker` não existe na máquina; nginx
  idem. `gh run list --commit 855b0a7…` não devolve run: a árvore atual nunca passou pelo
  portão remoto (o último é de `9e38f16`, três commits atrás) e aquele run publicou o snap
  de fato. `snap` com `needs: builds` publica `release: edge` em push a master com
  `idle-tests` vermelho; `release.yml:119,147` repete; `deploy/server/entrypoint.sh:108-137`
  (SIGTERM → canary → drain) é conferido só por texto em `scripts/check_compose.sh:1160`.
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
transação), a afirmação de `SCALING.md:285-286`, os 30 sites `.db.` crus, a ausência de
métrica de passo em produção, a ordem textual de `reason_toast_test` e o `gate` que
`scripts/test.sh:15` anuncia e não existe como case.

- **Arquitetura 7,0.** A favor: identidade nunca vem do pacote — `Server.gd:600`
  (`Peers.GetCharacter(peerID)`, repetido em `:625/:639/:654/:730`) com a régua que morde
  em `tests/run_rpc_identity_test.gd:147`, dois WebSockets reais em que A declara ser B e
  o servidor devolve o `AuthPeerID` de A. Leitura fail-closed em `SQLReadRules.gd:14-19`
  (`txnDepth > 0` nunca roteia) e `SQLReadPool.gd:11-13` declarando o pool
  não-fonte-de-verdade, com a opção `read_only=true` refutada por medição no próprio repo.
  **Contra (a nota):** `EconomyKernel.GrantItem` (`:44-55`) insere em `ledger_transaction`
  por `Launcher.SQL.db.query_with_bindings` sob `_eco._get_settle_mutex(accountID)` — não
  sob `queryMutex` e não dentro de `SQL.Transaction()`, ao contrário do que o comentário de
  `LedgerAppend` (`:33-41`) exige — enquanto `:20-28` lê a mesma tabela pelo funil.
  `SCALING.md:286` afirma que a `queryMutex` "continua sendo o único funil de escrita"; a
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
  abaixo do pior p99 normalizado já medido sob carga hostil (`benchmarks.gd:373-375`,
  `WorstP99NormalizadoSobCargaUs = 1601`) e fecha os dois lados (folga `>4×` deixa passar
  regresso de 5×; `<2×` flakeia contra o ruído de 1,24× do run ocioso), com a cauda julgada
  duas vezes — p99 normalizado E taxa de hitch (`benchmarks.gd:388`, porque "com 800
  amostras, 1% de hitch cai exatamente no furo do p99"). Calibre de 4 ms/passo injetado de
  propósito em `tick_capacity_test.gd:81-82,443-445`, com o monitor da engine obrigado a
  ver ≥70% da queima. **Contra:** nenhum detector do orçamento de passo em produção —
  `grep -rn "TIME_PHYSICS_PROCESS" sources` devolve só `ServerDisplay.gd:13` (painel de dev
  legível por humano) e `/metrics` expõe espera de mutex (`MetricsServer.gd:173-178`), não
  ms/passo; o `max 549.622 µs` (3 hitches >50 ms em 800) ficou sem causa confirmada —
  provavelmente o auto-checkpoint do WAL, como `benchmarks.gd:56-60` declara. *Não remediu*
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
  produto. Causa determinística, apurada em estático: `scripts/test.sh:437` casa só
  `"== [A-Z]+[A-Z ]*:` e cai no default `== RESULT:`, que `tests/benchmarks.gd:397`
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
  `all|quick|idle|backup|benchmarks|rpc|companion|fixation|preflight|structure|one|diag|clean`,
  então rodou os `check_*.sh` à mão. Não abriu os valores de `data/conf/credential.cfg:1-6`
  (só nomes de chave e contagem de linhas); `check_secrets.sh` →
  `== SECRETS GATE: 37 checks, 0 failures ==`, o que "sugere placeholder/allowlist, não
  credencial viva".
- **Ponto cego declarado por ele:** os falsos-vermelhos do `one` são fail-closed (nunca
  geram verde falso), mas queimam um boot de vários minutos justamente do juiz que depura;
  e a veracidade do marcador dos outros 56 harnesses ficou como deriva em shell, não como
  run.

