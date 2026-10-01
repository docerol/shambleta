# Escalabilidade medida — o número, como foi medido, e o que ele NÃO prova

Data da rodada: 2026-09-27. Máquina: AMD Ryzen 5 5500 (12 threads visíveis),
Godot 4.7.2.stable.arch_linux, execução **a partir do fonte** (`godot --headless
--path .`), sem container. Quem muda de máquina/HW muda o número: por isso a
tabela abaixo é acompanhada do comando que a reproduz, e o harness que a imprime
é um gate (`tests/tick_capacity_test.gd`, formato `== RESULT: N checks, M
failures ==`), não um script solto. Número que ninguém remede é boato.

## 1. Orçamento de tick

O servidor roda a 30 Hz: `const ServerMaxFPS : int = 30` em
`sources/launcher/LauncherCommons.gd:@ServerMaxFPS`, aplicado em `sources/launcher/Launcher.gd:205-206`
(`Engine.set_max_fps` + `Engine.set_physics_ticks_per_second`) **somente sob
`--server`**. Orçamento por passo = 1000/30 = **33,33 ms**. É a régua de tudo
abaixo. O harness confere a paridade antes de medir (assert "tick do harness =
tick de produção (30 Hz, budget 33.33 ms/passo)").

### 1.1 O orçamento virou grandeza exportada (instrumento dentro do processo)

Até aqui, "33,33 ms por passo" era régua de harness: nada no processo do server
media o custo do próprio passo, e `/metrics` só exportava espera de mutex de SQL.
O orçamento existe agora como instrumento do produto, cronometrado com
`Time.get_ticks_usec()` em `_physics_process` de `sources/launcher/Launcher.gd`
(um por processo, sempre ligado) e servido por `sources/system/MetricsServer.gd`:

| série | o que é | janela/coverage confessa |
|---|---|---|
| `shambleta_step_period_seconds` (histograma) | parede entre duas fronteiras de física consecutivas, baldes em 16,67/33,33/50/100 ms + `_sum`/`_count`/`_max` | vale mesmo com instância parada; quando o engine recupera atraso rodando dois passos seguidos, a fronteira entre eles lê curta — o déficit acumulado é `shambleta_step_lost_total` |
| `shambleta_step_work_seconds` (histograma) | só a bomba de políticas de ocioso que `sources/world/WorldInstance.gd` faz por passo | **não** é o passo inteiro: é o trabalho que esta base de código cronometra por dentro, declarado no HELP |
| `shambleta_step_over_budget_total` (counter) | passos com período acima de orçamento + folga | a folga (`shambleta_step_budget_tolerance_seconds`) é o piso do throttle de 30 Hz, não uma margem de boa vontade |
| `shambleta_step_lost_total` (counter) | pior déficit entre passos esperados e entregues | `increase()` lê "passos que deixaram de ser entregues", não "tempo perdido" |
| `shambleta_steps_measured_total` (counter) | denominador de tudo acima | sem passo amostrado o bloco inteiro **não aparece** — ausência não é zero, e quem scrapeia vê ausência |

O predícado de estouro estritamente `> orçamento + folga` tem controle negativo no
harness da própria perna (`bash scripts/test.sh one step_budget_metric_test 300`), e
os nomes citados por `deploy/alerts.rules.yml` (`PassoForaDoOrcamento`,
`PassoPerdido`, `PassoSemMedida`) são cruzados com o que o servidor emite no mesmo
predícado — regra apontando para série que ninguém serve vermelha ali, não no
dashboard. A cauda por passo (p95 e máximos, não mediana) virou régua em
`bash scripts/test.sh one multi_instance_tick_test 900` com `CheckCeiling`, pelo
motivo escrito no próprio harness.

## 2. Tabela medida (mesma zona, players na mesma instância)

Os números abaixo são UMA corrida de `tests/tick_capacity_test.gd` nesta máquina, não uma
constante da física: a medida de 2026-09-28 às 22:27 saiu `1,38 / 4,75 / 8,12 / 31,82 ms`
nos mesmos quatro degraus, e o que se publica aqui é o degrau, não o dígito. A régua que
segura o plano é a fence do harness (`>= 200 players conviventes dentro de 33,33 ms/passo`)
e as âncoras `<!-- DRIFT proc_* -->` da seção 8, conferidas pelo próprio medir; esta tabela
é prosa de contexto e é por isso que declara a corrida de que veio.

| players/instância | trabalho nos callbacks (mediana, ms/passo) | física + idle | p95 | **período atingido** (wall clock) | nós | recursos | memória estática |
|---|---|---|---|---|---|---|---|
| 1 | 1,63 | 0,72 + 0,92 | 1,72 | 33,61 ms | 8.940 | 2.868 | 382 MB |
| 20 (cap de instância) | 4,11 | 2,94 + 1,17 | 8,09 | 33,61 ms | 9.855 | 2.868 | 390 MB |
| 100 | 8,84 | 5,49 + 1,58 | 9,49 | 33,59 ms | 10.532 | 2.868 | 396 MB |
| 200 | 42,59 | 34,98 + 7,61 | 52,43 | 33,58 ms | 12.767 | 2.868 | 416 MB |

Custo marginal medido entre 1 e 200 players: **0,206 ms por player por passo**
(120 passos amostrados por nível, 30 descartados de transitório, 90 usados).
Extrapolação **declarada** (reta pelos dois pontos medidos, 1 e 200; não é
medição): o trabalho do passo encosta nos 33,33 ms em **~154 players na mesma
zona**.

## 3. Onde o tick para de cumprir o orçamento — as duas respostas honestas

O harness decide "estourou" por dois detectores independentes e publica os dois:

- **Período real entre passos** (wall clock sobre 120 `physics_frame` aguardados):
  33,58–33,61 ms em todos os níveis, inclusive a 200 players. **Nenhum nível
  medido perdeu o relógio** — o atraso é ~0,3 ms, granularidade do throttle, não
  saturação.
- **Trabalho auto-relatado pela engine** (`Performance.TIME_PHYSICS_PROCESS` +
  `Performance.TIME_PROCESS`, soma por passo): cruza os 33,33 ms entre 100 e 200
  players (42,59 ms a 200) e marca o joelho extrapolado em ~154.

Os dois discordam a partir de ~100 players, e isso está na tabela de propósito: o
self-report da engine é um contador de tempo de callback com janela móvel de 1 s,
não uma medição de wall clock. O que se provou no harness é que **os dois
detectores respondem** — com 4 ms/passo de queima injetada o trabalho vai de 1,63 →
5,57 ms e com 40 ms/passo o **período** vai a 46,89 ms (> 33,33), então nenhum dos
dois está lendo ruído.

**Número com que se planeja: 200 players SOMANDO todas as instâncias do mesmo
processo** — 10 instâncias dedicadas de zona, 20 players cada, medidos dentro dos
33,33 ms/passo. Substitui o `~150` que estava aqui: aquilo era a interseção de uma
reta traçada por dois pontos (§2) com o orçamento, e era uma ZONA só; a escada abaixo
é o processo real do beta, com N instâncias convivendo no mesmo thread de tick.
Com o cap de 20 players/instância (`sources/world/WorldInstance.gd:5`), a restrição do
processo nunca foi o cap de uma instância — é o total convivente, agora medido.

### 3.1 Escada medida: N instâncias × cap no MESMO processo

Rodada 2026-09-28 na mesma máquina do §1 (Ryzen 5 5500, 12 threads, 15,6 GB, Godot
4.7.2.stable.arch_linux, a partir do fonte, sem container). Cada nível **acrescenta**
uma instância dedicada de farm com 20 players reais e sessão idle real; cada nível é
medido 3 vezes e o que entra na régua é a mediana das 3, com o spread entre passadas
publicado — número que não se reproduz não é número. A régua de reprodução são três
perguntas, não uma: a **maioria** das passadas cabe em ±25% da mediana do degrau, **até
a pior passada** cabe no orçamento de 33,33 ms, e o spread total fica abaixo de **um
período de frame**. Cobrar `max − mín` pequeno sobre três medianas seria pedir conta de
uma estatística de três observações — `medianMs` amostra monitores da engine que já são
média móvel de 1 s, e num host quieto medido em 2026-09-28 isso vermelhou um degrau
são ([5,13 7,66 5,52] ms com o período de parede fixo em 33,60 ms).

| players no processo | instâncias | trabalho mediano (ms/passo) | período | tick entregue | RSS | CPU (ms/passo, core) | spread entre passadas |
|---|---|---|---|---|---|---|---|
| 0 (piso do boot) | 0 | 0,64 | 33,61 | 30,00 Hz | 579 MB | 0,42 / 0,01 | 0,03 ms |
| 1 | 1 | 1,56 | 33,61 | 30,00 Hz | 591 MB | — | 0,04 ms |
| 20 (cap de instância) | 1 | 3,20 | 33,61 | 30,00 Hz | 591 MB | 1,00 / 0,03 | 0,52 ms |
| 40 | 2 | 4,66 | 33,61 | 30,00 Hz | 591 MB | 1,83 / 0,05 | 0,01–1,22 ms |
| 100 | 5 | 8,70 | 33,59 | 30,02 Hz | 604 MB | 3,67 / 0,11 | 0,78–1,45 ms |
| **200** | **10** | **26,87** | 33,57 | 30,04 Hz | 690 MB | 10,50 / 0,31 | 6,68–7,98 ms |
| 300 | 15 | 29,00 | 33,81 | 29,82 Hz | 736 MB | 17,58 / 0,52 | 0,91 ms |
| 400 | 20 | 88,93 | 49,13 | 20,52 Hz | 846 MB | 49,00 / 1,00 | 15,79 ms |

Custo por player convivente, medido: <!-- DRIFT proc_marginal_us_per_player 221 90 -->
**221 µs de passo por player** na escada toda (reta do piso ao degrau de 400 players),
**95 µs/player** no trecho afirmado até 300 players. A fence que o harness impose é
340 µs — folga de +54% sobre o medido, escolhida acima do maior spread entre passadas
e entre execuções que esta máquina mostrou. Passar dela é o gate vermelho.

O teto, em degraus medidos: <!-- DRIFT proc_inside_rung_players 200 1 --> o último
degrau **dentro do orçamento** foi 200 players (10 instâncias) num run com a máquina
sob concorrência de outros agentes e 300 players (15) num run mais quieto; 400 players
não coube em nenhum (**88,93 ms/passo, 20,52 Hz entregues** — aqui os três detectores
concordam: trabalho, período e passos-por-segundo de parede). O harness afirma
`RÉGUA: >= 200 players conviventes dentro de 33,33 ms/passo` como fence e
<!-- DRIFT proc_tick_ceiling_players 200 100 --> amarra o número da doc à medição com
tolerância de ±100 players; regredir para 40/20 players fecha o gate.

A âncora do degrau é **bilateral em degraus**, não em players: o segundo número do
`DRIFT proc_inside_rung_players` é quantos degraus da escada o run pode ficar longe do
que a doc afirma, nos **dois** sentidos. Um degrau é o spread que este parágrafo
confessa (200 concorrido × 300 quieto). Dois degraus — 400, o dobro do prometido, ou
40, uma quinta parte — são a doc errando o tamanho do servidor, e isso já passou verde
quando a régua era só `medido >= afirmado`. A escada comparada é a que o próprio run
andou, impressa na linha do gate; afrouxar a banda é editar este arquivo, e só.

Extrapolação **declarada** (não é medição): a reta entre os dois degraus que cruzam o
orçamento (10 e 15 instâncias, assumindo linearidade nesse trecho) cruza os 33,33 ms
em ~12 instâncias ≈ **240 players**. Assume linearidade justo onde a curva é convexa
(cada instância nova traz mapa, mobs e navegação próprios), por isso o plano de
lançamento usa os 200 medidos e não os 240 extrapolados.

O que **bounda** N no processo, medido neste processo (não é constante de manual):
descritores abertos **15 no chão e 15 no topo da escada** (0,00 por instância), threads
vivas **16 → 16** (0,00 por instância — `WorldInstance` é objeto no thread do tick, não
thread), contra `RLIMIT_NOFILE` soft/hard = **1048576/1048576** e `RLIMIT_NPROC` soft =
**63024** lidos de `/proc/self/limits` nesta máquina. Nem fd nem thread são o funil: o
funil é o orçamento de tick. Memória: RSS 579 → 846 MB na escada, inclinação medida de
**0,671 MB por player**, o que daria ~1.428 players antes dos `mem_limit: 1536M` do
compose — 5× acima do teto de tick, então quem vincula primeiro é o tick.

Dois custos que a própria medição confessa: (i) o self-report da engine captura 68–85%
da queima injetada de 4 ms/passo (por isso a fence de calibração é 60%, não 90%);
(ii) **histórico** — até 2026-09-28, `RemoveOldestAttacker` fazia `attackers.erase(0)`
num `Array[Dictionary]`, e o `erase()` recebe VALOR, não índice: além de não remover
nada, despejava um `ERROR: Attempted to erase a variable of type 'int' into a TypedArray`
por ataque processado, **dentro** do passo de física. A tabela acima foi medida com essa
queima dentro, e ela continua aqui de propósito: hoje o código é
`attackers.pop_front()` depois da ordenação (`sources/actor/agent/variants/AIAgent.gd:62-68`,
linhas 64-66 são o comentário que conta esta história), então o número publicado é
**conservador** — remover a queima só barateou o passo, e o gate continua valendo porque
é remedido a cada passada, não porque a correção foi credibilidade antecipada.

Reproduz com o runner sancionado:

```bash
cd "$(git rev-parse --show-toplevel)"
bash scripts/test.sh one multi_instance_tick_test
```

Rodar o godot cru (`godot --headless --path . -s tests/multi_instance_tick_test.gd`) é
exatamente o que o `boot_guard` de `scripts/test.sh` recusa: dois processos escrevendo
no mesmo WAL é o SIGSEGV de 2026-09-28, e um verde obtido por atalho não é o verde do
portão. A última linha do gate é o `== RESULT: <N> checks, <M> failures ==` do próprio
harness; o `<N>` não é transcrito aqui de propósito — essa contagem vive na linha de
resultado do harness e regravá-la neste arquivo é o número que mente no commit seguinte.


## 4. O que limita, no código

- **Um único thread de tick**: tudo acima é 30 Hz num processo (`sources/launcher/Launcher.gd:205-206`).
- **SQL serializada numa única mutex**: `var queryMutex : Mutex = Mutex.new()` em
  `sources/sql/SQL.gd:@queryMutex`. `grep -rn "Thread.new()" sources/` devolve **exatamente
  uma** linha — `sources/sql/SQLBackups.gd:5` (worker de backup). Não existe pool
  de threads de jogo: escrita, transação e o round trip do read pool competem pela
  mesma `queryMutex`. Espera dela é medida, não suposta: o ponto único de lock é
  `_LockQueryMutex()` (`sources/sql/SQL.gd:@_LockQueryMutex`), que cronometra cada seção com
  `Time.get_ticks_usec()`. Os contadores e a cauda >1/>10/>100 ms são declarados
  por `mutexWaits` (`sources/sql/SQL.gd:@mutexWaits`) e acumulados dentro da
  seção crítica por `mutexWaitMicroseconds`
  (`sources/sql/SQL.gd:1565-1574`); a leitura é `SQL.QueryMutexWaitSeconds()`
  (`sources/sql/SQL.gd:@QueryMutexWaitSeconds`, forma counter Prometheus) e
  `SQL.QueryMutexWaitStats()` (`sources/sql/SQL.gd:@QueryMutexWaitStats`).
  Na tabela do §2 a espera é 0,00 µs/passo porque o harness simula o mundo e não
  um fluxo de escrita por player; o caminho de escrita é o que
  `tests/scale_test.gd` mede em round trips por ação.
- **Cap de instância**: `MAX_PLAYERS_PER_INSTANCE = 20` em
  `sources/world/WorldInstance.gd:@MAX_PLAYERS_PER_INSTANCE`, resolvido por busca limitada em
  `WorldAgent.ResolvePlayerInstance()` (`sources/world/WorldAgent.gd:@ResolvePlayerInstance`,
  janela `MAX_SHARDS_PER_FAMILY = 32` em `sources/world/WorldAgent.gd:@MAX_SHARDS_PER_FAMILY`,
  chamada no spawn em `sources/world/WorldAgent.gd:218` e no warp em
  `sources/world/World.gd:111-112`). Instâncias de zona dedicada (`>=
  IdlePolicyService.ZoneInstanceBase`) e de boss **não** são fragmentadas
  (`sources/world/WorldAgent.gd:150`). Prova: `tests/shard_capacity_test.gd`
  (41 e 61 players pelo caminho real → 20/20/1 e 20/20/20/1, nenhuma instância
  acima de 20).
- **Observabilidade**: o `/metrics` binda só `127.0.0.1:9400`
  (`sources/system/MetricsServer.gd:25-26`), então o scraper precisa compartilhar
  o namespace do jogo — `network_mode: service:game` em
  `deploy/docker-compose.yml:330`, porta do Prometheus `--web.listen-address=:9090`
  (`deploy/docker-compose.yml:352`) e Alertmanager na porta 9093
  (`deploy/docker-compose.yml:402`). As regras viajam dentro da imagem
  (`deploy/monitoring/prometheus.Dockerfile:19-20`,
  `deploy/monitoring/alertmanager.Dockerfile:32`).

## 5. Remedir

```bash
cd "$(git rev-parse --show-toplevel)"
bash scripts/test.sh one tick_capacity_test
```

O runner sancionado existe porque godot cru sobre o mesmo WAL é justamente o processo
estrangeiro que o `boot_guard` de `scripts/test.sh` recusa — e um verde obtido por
atalho não é o verde do portão. A última linha é o `== RESULT: <N> checks, <M>
failures ==` do harness (o `<N>` mora na linha de resultado dele, não neste arquivo),
precedida de `== TABELA (deploy/SCALING.md) ==` com as quatro linhas do §2 — re-meçar é
reescrever a tabela a partir do que aquele bloco imprime, nunca de memória. O harness se auto-valida: falha se o tick não for 30 Hz, se a queima
injetada não aparecer no trabalho medido, se o período não reagir à sobrecarga
injetada, se a série não for monotônica ou se o piso/instância-cheia não caberem
no orçamento. Capacidade de instância (o cap de 20):

```bash
bash scripts/test.sh one shard_capacity_test
```

## 6. Pendentes, declarados

- **[NÃO MEDIDO] no container.** Docker **não está instalado** nesta máquina
  (`which docker podman` vazio). Nada aqui foi rodado com `docker compose up`: a
  prova do stack de observação é parse de config + o gate
  `bash scripts/check_compose.sh`, medido nesta máquina em 2026-09-28 como
  `152 checks, 0 failures` com `fumaça: 0 rodaram, 0 falharam, 2 pulados` — os
  dois pulos são exatamente `docker compose config` e `amtool`, que não existem
  aqui, e o gate imprime o MOTIVO de cada pulo em vez de calar. O que o gate
  confere é referência às regras, alvos/portas de scrape contra o que os
  processos escutam, serviço de alerting declarado e routing por severidade.
  Binário exportado (`deploy/server/Dockerfile`) vs. fonte também não foi medido.
- **O teto do compose — MEDIDO no que dava para medir, declarado no que não dá.**
  A frase que estava aqui ("falta medir N instâncias × 20 no mesmo processo — o número
  que o beta precisa") foi substituída pela escada do §3.1: **200 players conviventes
  dentro de 33,33 ms/passo** (10 instâncias cheias), 221 µs por player, com fence
  imposta por `tests/multi_instance_tick_test.gd`. O confronto com os limites do
  serviço `game` (`deploy/docker-compose.yml:98`) contra os limites declarados dele
  (`mem_limit` em `deploy/docker-compose.yml:123` e `cpus` em
  `deploy/docker-compose.yml:129`) agora tem número dos dois lados: a
  inclinação medida de RSS (0,671 MB/player) diria ~1.428 players antes dos
  `mem_limit: 1536M`, e a CPU medida no pior degrau é 1,00 core dos `cpus: 2` — os
  dois folgam por 5× e 2× respectivamente, então **quem vincula o beta é o tick, não o
  cgroup**. O que continua **[NÃO MEDIDO]**, e não é por preguiça: (i) `cpus: 2` e
  `mem_limit` **impostos por cgroup** nunca rodaram aqui — Docker/podman não estão
  instalados nesta máquina (`which docker podman` vazio), então a conta acima é a
  medição do processo contra o valor declarado no YAML, não o comportamento sob
  throttling; (ii) **contenção entre processos no mesmo arquivo SQLite** também não:
  o harness roda um processo, e abrir dois writers no mesmo WAL exigiria orquestrar
  dois `SQLService` em processos separados com o `SHAMBLETA_SERVER_ID` correto — o
  `tests/presence_fuzz.gd` faz isso dentro de um processo só, que é a claim dele, não
  esta; (iii) pacotes de rede, `settle`/save e rajadas de SQL por player **dividem o
  mesmo thread** do tick medido em §3.1 e não entraram na escada — eles têm réguas
  próprias (`tests/scale_test.gd`, `tests/read_pool_test.gd`) e por isso o número do
  beta é afirmado como **200 com folga declarada**, não como 240 extrapolados; (iv) a
  escada usa instâncias de zona dedicadas e não inclui instâncias de boss
  (`sources/world/WorldAgent.gd:150`), que são mais caras por instância.
- **Não é mais pendência (e a linha que dizia que era estava errada):** o `/metrics`
  já expõe a espera da mutex, e com cauda — `shambleta_sql_query_mutex_waits`,
  `shambleta_sql_query_mutex_wait_seconds`, `..._wait_max_seconds` e os degrades
  `..._over_1ms` / `..._over_10ms` / `..._over_100ms` saem do corpo de `MetricsBody()`
  em `sources/system/MetricsServer.gd:@MetricsBody`, lidos de `QueryMutexWaitStats()`
  (`sources/sql/SQL.gd:@QueryMutexWaitStats`). A regra de alerta que esperava esse sinal também já
  existe: `deploy/alerts.rules.yml:102` alarma em
  `increase(shambleta_sql_query_mutex_wait_over_100ms[10m]) > 0`. O snippet que estava
  aqui chamava `QueryMutexWaitSeconds()`, função que ninguém definiu — era pedido
  escrito depois de o trabalho ter sido feito, do mesmo tipo de ficção que faz um
  operador re-inventar uma linha que já roda.

## 7. Presença durável — o que a migration 057 passou a custar

`presence_session` existe desde a migration 057 com um cabeçalho prometendo
`Presence.Prune`, `Presence.HeartbeatSec` e um harness que mede os três planos de
índice. Até esta rodada **nada disso existia** — o único leitor da tabela no repo era
uma asserção de existência em `tests/scale_test.gd`, o que deixava o "quem está
online" de guild/social respondendo por um processo só. Hoje a promessa é verdade:
`sources/network/server/Presence.gd` é o único caminho que escreve e lê a tabela,
alimentado por `Server.ConnectCharacter` / `DisconnectCharacter` / `SetFarmZone`, por
`Presence.ReclaimServer` no boot (`sources/sql/SQL.gd`) e por `Presence.Tick` no
acumulador de 1 s de `World._process`. A régua é `tests/presence_fuzz.gd`
(`== PRESENCE: N checks, M failures ==`), que também exige a verdade do texto: os
símbolos nomeados no cabeçalho da migration têm que existir no fonte.

Medido nesta máquina (a mesma do §1), 1.000 personagens no `server_id` do processo,
WAL + `synchronous=NORMAL`, seis execuções do run completo:

| grandeza | valor medido |
|---|---|
| tick de heartbeat (`UPDATE ... WHERE server_id = ?`) | **1.463–1.664 µs, 1 statement** |
| mesmo tick no modo por-personagem (contra-prova: código quebrado de propósito) | 27.732 µs, 1.001 statements |
| tick quinquenal (heartbeat + poda) | 2 statements |
| `Report` de conexão, `Forget` de desconexão, `SetFarmZone` | 1 statement cada |
| orçamento do gate | 8.000 µs (≈5× o pior medido) |

A conta que importa para o teto de players por processo do §3 (conservador: ~150 na
mesma zona): **uma statement por
`SHAMBLETA_PRESENCE_HEARTBEAT_SEC` por processo**, não por jogador — o heartbeat não
entra na curva de 0,206 ms/player/passo do §2. Para conferir com as próprias mãos:

```bash
cd "$(git rev-parse --show-toplevel)"
bash scripts/test.sh one presence_fuzz
```

O que **NÃO** mudou, declarado porque é exatamente o que este número não prova:

- **Um escritor só — com duas origens de valor.** A `queryMutex` de
  `sources/sql/SQL.gd:@queryMutex` continua sendo o único funil de *statement*: nada no repo
  escreve sem passar por ela (`Query`, `QueryBindings`, `ExecuteBindings` e
  `Transaction` são os quatro caminhos que a pegam; as escritas cruas de `db.*`
  vivem atrás de `Transaction()`, e `scripts/check_write_funnel.sh` é a régua que
  census isso com controles plantados). Mas `stat.gp` tem DUAS origens de valor, e
  o texto anterior escondia isso atrás de "único funil": o agente carregado, cujo
  ouro de farm só desce ao banco no passe de 600 s, e o kernel
  (`EconomyKernel._MoveGoldLocked`), que grava direto para loja, forja, guilda,
  copa, boss, streak, checkout e leilão. Enquanto o snapshot daquele passe foi
  ABSOLUTO (`"gp" = stats.gp` em `SQL.UpdateStat`), a segunda origem era apagada
  pela primeira: débito do vendor que volta a existir com o item no bolso, crédito
  de grant que desaparece. Desde a WorkOrder #88 o `gp` saiu do dicionário absoluto
  de `SQL.UpdateStat` e é gravado como DELTA por `SQL.FlushGoldDelta` — as duas
  origens compõem. O §12 da auditoria falava de presença *compartilhada*, não de
  shard com dois escritores. A régua de presença está no harness:
  `presence_session` só pode aparecer em frases SQL de
  `sources/network/server/Presence.gd`, e os ganchos são contados nos fontes
  (`Server.gd` reporta 2× e esquece 1×, `World.gd` faz o tick, `SQL.gd` reclama o
  `server_id`).
- **Dois servidores em duas máquinas não foi medido.** O harness mede dois
  `SQLService` sobre o **mesmo arquivo**, no mesmo processo: o segundo lê o que o
  primeiro escreveu (`B ve A` / `A ve B` nas checks), que é a claim literal da
  migration. SQLite sobre filesystem de rede é outro teste, e ele não existe aqui.
- **`SHAMBLETA_SERVER_ID` é contrato, não decoração**: `Presence.ReclaimServer` apaga
  no boot a cauda do próprio id, então dois processos escrevendo com o mesmo id apagam
  a presença um do outro. Um id por processo escritor.
- **Presença não é autorização.** `OnlineList.byNick` continua sendo o índice dos
  painéis (latência); a tabela durável responde "quem está online no outro processo",
  não "quem pode entrar".

Cross-referências: `deploy/OPS_RUNBOOK.md` §4 (limites de recurso e como reproduzir),
`deploy/prometheus.yml`, `deploy/alerts.rules.yml`.
