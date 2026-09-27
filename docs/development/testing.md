# Testes

## Estrutura

Dois grupos de harness, e a diferença entre eles é mecânica, não de nome:

- **Fixos** — `EXPLICIT_HARNESSES` em `scripts/test.sh`: `run_idle_tests.gd` (o
  runner, que só sobe os serviços e chama `IdleTests.gd`, onde as suítes vivem),
  `IdleTests.gd`, `run_rpc_identity_test.gd`, `test_e2e_implementation.gd`,
  `test_backup_restore.gd` e `benchmarks.gd`. Somam-se a eles `diag_pacing.gd` e
  `dump_calibration.gd`, que são diagnóstico invocado à mão, não gate.
- **Auto-inscritos** — `harnesses_extra()` varre `tests/*_test.gd` e
  `tests/*_fuzz.gd` e transforma CADA arquivo num gate próprio (`gates_extra`, e
  o mesmo no passo `fixation` do job `idle-tests` da CI). Não existe lista para
  manter: um arquivo novo que case com o padrão já está inscrito no portão. O
  motivo é o destino que arquivos fora de lista tiveram neste repo — um runner de
  `gut` que nunca foi chamado, o próprio `check_doc_drift.sh`, `check_compose.sh`
  e o harness de restore completo, que viveu em `tests/` com nome fora do padrão
  desde que foi escrito: 184 linhas de régua que ninguém chamava (virou
  `backup_full_restore_test.gd` em 2026-09-27, e o primeiro run isolado dele já
  morreu num `player[0]` fora de índice — ver a linha da tabela acima).

Medido em 2026-09-27 com `bash ./scripts/test.sh preflight` — 40 harnesses no
preflight, sendo os 39 das linhas abaixo (a tabela omite `IdleTests.gd`, que não é
gate próprio: `run_idle_tests` o carrega). A tabela não grava quantos checks cada
harness roda, de propósito: essa contagem vive na linha de resultado do próprio
harness, e reescrevê-la aqui é exatamente o número que mente no commit seguinte. O
que a tabela guarda é o estável — o QUE cada harness apura. `scripts/check_doc_drift.sh`
confere os nomes e a contagem de harnesses do preflight, e reprova linha de harness
que voltar a trazer contagem de checks:

| harness | o que apura |
|---|---|
| `run_idle_tests` | as suítes de `IdleTests.gd` — jogo, economia, rede, docs, ponteiros de evidência |
| `economy_invariant_fuzz` | fuzzer de invariantes da fronteira do dinheiro (marker `== FUZZ:`): pares de operações legalmente individuais que intercaladas somam errado |
| `spend_confirm_test` | os gastos irreversíveis só falam com a rede depois do `ConfirmPending()` |
| `season_liveops_test` | temporada, passe, calendário de live ops |
| `reason_toast_test` | nenhum reason token cru do servidor chega à tela: enumera o que `sources/` emite e confere catálogo/degradação nos dois sentidos |
| `accounts_fix_test` | conta, sessão, 2FA, reset de senha |
| `balance_test` | varredura de nível com invariante — jogar nunca paga menos por hora que esperar, para XP e gold — mais peso de `Modifier` e streak diário server-side |
| `fraud_test` | fila anti-fraude, referral guard |
| `read_pool_test` | pool de leitura: certificação e concordância dos dois caminhos |
| `login_hardening_test` | tentativas de reset, lockout, hash |
| `scale_test` | retenção de ledger medida no DB que o boot migrou: contrato do predicado, poda com retomada, dinheiro conservado, leitura de cauda e VACUUM |
| `economy_design_fix_test` | cap offline, forge, moeda, passe |
| `gameplay_fix_test` | prioridade de skill, elemental, escada de boss |
| `doc_facts_test` | fatos de doc cuja única fonte é o runtime: enum de diretório de backup, colunas depois de todas as migrations, autoload registrado |
| `hud_wiring_test` | cadeia botão HUD → handler `Gui` → painel e o portão de gasto |
| `social_fix_test` | guilda, chat, lista de online |
| `test_e2e_implementation` | tabela chamador→método entre arquivos |
| `backup_full_restore_test` | restore completo: fixture semeada pela API de produção, corrompe, restaura em base separada, confere ledger/wallet/stat da fixture |
| `web_delivery_test` | push honesto (gate + contrato + e2e python), ads bridge |
| `perf_fix_test` | regressões de performance medidas |
| `deploy_ops_test` | flags de operação, runbooks |
| `i18n_catalog_test` | a tabela `ui.csv` e o catálogo COMPILADO que o `TranslationServer` lê dizem a mesma coisa, chave por chave |
| `run_rpc_identity_test` | WebSocket real + clients forjando peerID |
| `test_backup_restore` | probe de backup/restore |
| `gm_gate_fix_test` | portão de GM |
| `auction_house_wiring_test` | alcançabilidade do leilão: cada alvo da tabela do painel tem braço literal no `NetworkSend`, RPC no `Network` e handler no `Server`, e clique real (painel montado na árvore) manda o nome e os args certos para a rua — inclusive os da migração de market depth (GetAuctionPage/AuctionBid/AuctionBidCancel) — enquanto o "armar sem confirmar" não emite nada |
| `marketplace_depth_test` | economia das três pernas de mercado: preço realizado persistido na MESMA transação que liquida a venda, `BrowseListingsPage` com OFFSET/filtro/total no servidor, escrow/cancel/cruzamento, sem auto-negócio, e exatamente uma linha de histórico por liquidação (inclusive `via='bid'`) |
| `content_hygiene_test` | higiene de conteúdo: todo grupo de mob de toda zona resolve para entidade com nome, nível > 0 e contagem > 0 no EntitiesDB; a pool de drop de cada zona É exatamente o conjunto de itens da própria faixa (fallback vazio deletado); a perna nova de boss é conteúdo real, não string |
| `craft_authority_test` | autoridade da forja ponta a ponta: char e conta vêm do PEER (não do pacote), o único insumo do craft é ouro (char a zero itens ainda forja, cobra só o pedágio), porta de e-mail e teto diário decididos no servidor, `pending` não cria item, e só depois do OK de um GM o template nasce |
| `formation_priority_ui_test` | ordem de prioridade de skill alcançável pela UI: o painel declara a ordem e emite a string do comando via RPC do chat, a cena `presets/gui/Formation.tscn` está ligada, o servidor decide o que persiste (payload adulterado barrado) e a relog re-monta a `IdlePolicy` a partir do banco |
| `guild_chat_fanout_test` | fan-out do chat de guilda com EXECUÇÃO, não texto: um guildmate em segunda sessão recebe a linha (no canal e nick certos), quem não é da guilda não recebe nada, o fan-out é exatamente a lista resolvida (falante incluído), e as guardas de tamanho/mute continuam dentro do ramo |
| `nginx_hardening_test` | cerca do proxy da fronteira do dinheiro: faz parse de `deploy/web/nginx.conf` e confere diretiva por diretiva rate-limit, teto de corpo, CSP, X-Frame-Options e `server_tokens off` nas rotas /checkout/ e /webhooks/payments, respeitando a precedência real de `location`; roda `nginx -t` se o binário existir no host |
| `ops_fix_test` | lacuna de analytics/ops medida (não só prometida em comentário): telemetria com predicado d1_return, funil diário servido, `MetricsServer` e calendário de live ops fazendo o que o fonte afirma |
| `panel_fit_test` | cerca da CLASSE de bug "botão fora da tela": instancia todo painel `WindowPanel` no container de janelas flutuantes real do `Gui`, roda layout de verdade e mede retângulos contra o viewport de projeto, para nenhum controle nascer abaixo da borda |
| `password_timing_path_test` | comparação de senha em tempo constante: os dois ramos de versão de hash de `Hasher.VerifyPassword` convergem para um comparador sem saída antecipada, e "senha errada" e "conta inexistente" percorrem o MESMO caminho de custo |
| `repo_layout_test` | forma do repo: sonda rastreada na raiz que não compila/não emite marcador `== ...:`/`quit()` é falsa, e gate de estrutura escrito sem chamador no portão é pego |
| `shard_capacity_test` | lotação de shard pelo caminho real: `WorldAgent.CreateAgent` distribui cheio-na-ordem e nenhuma instância da família passa de `MAX_PLAYERS_PER_INSTANCE`, e a espera na `queryMutex` deixa de ser invisível |
| `tick_capacity_test` | capacidade de tick medida, não estimada: quantos players por zona o processo aguenta, cada nível numa zona isolada (instância dedicada por zona), e a tabela que vai transcrita no runbook de escalabilidade |
| `benchmarks` | orçamentos de performance (linha de resultado própria) |
| companion (python) | a fronteira do dinheiro em python: `test_webhook.py`, `test_security.py`, `test_refund_cli.py` |
| structure | os gates que medem o repo sem rodar jogo: `check_compose.sh`, `check_doc_drift.sh`, `check_god_nodes.sh`, `check_secrets.sh` — cada um imprime a própria contagem na sua linha de resultado, então o total é o do run, não uma promessa |

Todos passam pelo mesmo
`scripts/ci_gate_log.sh`, que não aceita exit code sozinho: o log não pode ter
`SCRIPT ERROR`/`Parse Error`, a linha de resultado tem que existir, a contagem de
falhas é lida DA LINHA DE RESULTADO (alimentar `0` à mão não aprova mais nada) e
o exit code do runner é conferido à parte. A linha tem que dizer
`N checks, M failures` — um `PASSED` sem contagem é rejeitado, porque "terminou"
não prova que a suíte iterou alguma coisa. Antes de rodar qualquer harness,
`scripts/test.sh all|idle|quick` (e o job `idle-tests` da CI, no mesmo passo) faz
o **preflight de parse** de todos os harnesses: `godot --check-only --script` em
cada arquivo (medido: ~1 s no total). O motivo é um defeito que custou três execuções do
portão: `run_idle_tests.gd:76` faz `load("res://tests/IdleTests.gd")` e chama
`.new()` — se o arquivo não compila (um `CheckEq` recebendo `String` onde a
assinatura é `(int, int, String)`), nenhuma suíte roda, `== RESULT:` nunca
aparece e o gate descobre isso só no timeout de 1200 s. A régua é ancorada em
`SCRIPT ERROR: Parse Error`: em `--check-only` um script que referencia autoload
também emite `ERROR: ….tscn - Parse Error: [ext_resource] referenced
non-existent resource`, que é falso positivo do modo, não do código.
Antes de 2026-09-24 o companion era o
único pedaço do portão com CI e local provando coisas diferentes: a CI chamava
`python3` direto e o `test.sh all` local não o rodava nenhum — hoje os dois chamam
`./scripts/test.sh companion`. `test_e2e_implementation.gd` estava
no repositório sem job nenhum até 2026-09-24 — é a tabela chamador→método entre
arquivos que teria pego `Gui.gd:286` chamando `Settings.get_sessionfirstlogin`,
um método que nunca existiu em nenhuma revisão (a chamada abortava o primeiro
login e o tour de onboarding não abria para ninguém). `test_backup_restore.gd`
saiu do mesmo jeito: ele terminava em `quit(0)` sem contagem, então o job
`backup-restore` ficava verde sobre um segfault.

A tabela acima não é mantida à mão. `scripts/check_doc_drift.sh` deriva a lista de
harnesses do próprio `scripts/test.sh` — `EXPLICIT_HARNESSES` mais o que
`harnesses_extra()` varre — e reclama nos dois sentidos: harness de gate sem linha,
e linha de tabela nomeando algo que o portão não executa. Uma régua com a própria
lista copiada passaria verde para si mesma e cega para o portão real, que é o defeito
que deixou `backup_full_restore_test` 184 linhas sem ninguém chamar. A coluna de
contagem de checks saiu desta tabela de vez: quantos checks um harness roda vive na
linha de resultado DELE, e regrava-la na doc é a doença que este arquivo existe para
caçar. Além de conferir os nomes e a contagem de harnesses do preflight, a régua agora
REPROVA linha de harness que voltar a trazer contagem de checks.

## Execução

```bash
./scripts/test.sh all           # cada harness do portão, pelo quádruplo
./scripts/test.sh idle          # só a suíte idle
./scripts/test.sh rpc           # só identidade de RPC
./scripts/test.sh companion     # só a fronteira do dinheiro (python)
./scripts/test.sh clean         # descarta bases de teste
```

`test.sh` não chama `godot` direto: cada harness é gravado em `/tmp/shambleta-*.log`
e avaliado por `scripts/ci_gate_log.sh`, exatamente como na CI. Rodar local e a CI
com réguas diferentes é como o job de backup ficou verde sobre um segfault. Os
sandboxs de `user://`/cache ficam em `.test-home/<harness>/`, então um harness não
herda o `testing.db` do outro e o seu `~/.local/share/Shambleta` (o `user://` real
deste projeto, que usa `use_custom_user_dir`) não é tocado.

Log e sandbox são nomeados **por harness**, o que tem uma consequência medida: duas
execuções do mesmo harness — o `all` de uma janela e um gate disparado por outra, um
agente e o operador — escrevem no mesmo arquivo ao mesmo tempo, e o veredito lido de
um log misturado pode ser um verde falso (uma execução imprime `0 failures` enquanto
a outra ainda nem terminou). Por isso `gate`/`gate_py`/`gate_sh` seguram um
`flock /tmp/shambleta-<harness>.lock`: o segundo processo **espera**
(`SHAMBLETA_GATE_WAIT`, padrão 1800 s) e, se o espera estourar, o gate é registrado
vermelho com `GATE BLOQUEADO` em vez de ler log alheio. Harnesses diferentes seguem
em paralelo, e onde o host não tem `flock` o portão roda normalmente — a ausência do
utilitário não pode travar um lançamento. Verificado nesta máquina: com o lock do
`check_doc_drift.sh` tomado por outro processo e `SHAMBLETA_GATE_WAIT=1`, a passada
fechou `== GATES VERMELHOS: check_doc_drift.sh ==`.

## Nota histórica: o harness multiplayer (P4)

Este parágrafo afirmava que `MultiplayerTests.gd` "dependia de `Parse Error`
pré-existente em `Network.gd`/`FSM.gd`" e que a causa raiz era o cache `.godot/`
nunca importado. As duas coisas eram falsas, medidas em 2026-09-24: `Network.gd`
e `FSM.gd` compilam, e `run_idle_tests.gd` roda verde há várias passadas. Os
erros eram de `MultiplayerTests.gd` contra a API real de `Network` —
`BulkCall(peerA, "Ping", [])` inverte a assinatura (`methodName, bulkedArgs,
peerID`) e devolve `void`; `NotifyNeighbours/NotifyInstance/NotifyArea` recebem
`BaseAgent`/`WorldInstance`/`WorldMap`, não inteiros. O arquivo não compilava
desde que essas assinaturas mudaram, e 4 dos 5 checks dele eram
`Check(true, "não crashou")`. Ele foi apagado: o único assert verdadeiro
(registro/identidade/desregistro de peer em `Peers`) foi portado para
`SuiteAuthHardening` em `IdleTests.gd`, e a cobertura real de rede é
`run_rpc_identity_test.gd` (transporte WebSocket de verdade) mais as suítes de
simulação que exercitam os callers de produção de `Notify*` (`BaseAgent`,
`PlayerAgent`, `NpcCommons`, `Inventory`). A fragmentação de `Network.gd` em
seis módulos autoload (P4) continua revertida; ver
`docs/development/architecture.md`.

## Escrevendo novos testes

- Use `Check(condition, label)`, `CheckEq(value, expected, label)`, `CheckNear(value, expected, tolerance, label)`
- Crie fixtures com cleanup explícito (DELETE no final)
- Use `Transaction()` para testes que modificam o banco
