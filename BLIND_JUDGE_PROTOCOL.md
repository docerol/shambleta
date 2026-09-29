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
| Core Gameplay | 8,3 | — |  |  | 8,3 |  |
| Core Loop | 8,7 | — |  |  | 8,7 |  |
| Meta Game | 8,5 | — |  |  | 8,5 |  |
| Game Design | 8,6 | — |  |  | 8,6 |  |
| Retenção | 7,8 | — |  |  | 7,8 |  |
| Economia | 9,4 | — |  |  | 9,4 |  |
| Monetização | 9,4 | — |  |  | 9,4 |  |
| Marketplace | 8,5 | — |  |  | 8,5 |  |
| Analytics | 8,0 | — |  |  | 8,0 |  |
| Live Ops | 9,2 | — |  |  | 9,2 |  |
| Arquitetura | 8,5 | — |  |  | 8,5 |  |
| Performance | 8,5 | — |  |  | 8,5 |  |
| Escalabilidade | 7,4 | — |  |  | 7,4 |  |
| Código | 8,2 | — |  |  | 8,2 |  |
| Testes | 8,2 | — |  |  | 8,2 |  |
| UX/UI | 7,5 | — |  |  | 7,5 |  |
| Social | 5,5 | 9,0 |  |  | 5,5 |  |
| Segurança | 8,7 | 6,8 |  |  | 6,8 |  |
| DevOps | 8,9 | 8,8 |  |  | 8,8 |  |
| Documentação | 8,6 | 7,5 |  |  | 7,5 |  |

R1 foi um juiz por categoria (a regra 6 só passou a valer na rodada 2), então a
coluna R1 é nota única. `Social` teve R2 re-medida à parte, com a governança de
guilda como lacuna: 9,0, e a mínima continua 5,5 até os dois juízes da rodada 3
concordarem. Preencher A/B com a nota, as três evidências e a lacuna; a coluna
"mínima vigente" é recalculada na hora, não lembrada.

