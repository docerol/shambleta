# Escalabilidade medida — o número, como foi medido, e o que ele NÃO prova

Data da rodada: 2026-09-27. Máquina: AMD Ryzen 5 5500 (12 threads visíveis),
Godot 4.7.2.stable.arch_linux, execução **a partir do fonte** (`godot --headless
--path .`), sem container. Quem muda de máquina/HW muda o número: por isso a
tabela abaixo é acompanhada do comando que a reproduz, e o harness que a imprime
é um gate (`tests/tick_capacity_test.gd`, formato `== RESULT: N checks, M
failures ==`), não um script solto. Número que ninguém remede é boato.

## 1. Orçamento de tick

O servidor roda a 30 Hz: `const ServerMaxFPS : int = 30` em
`sources/launcher/LauncherCommons.gd:19`, aplicado em `sources/launcher/Launcher.gd:205-206`
(`Engine.set_max_fps` + `Engine.set_physics_ticks_per_second`) **somente sob
`--server`**. Orçamento por passo = 1000/30 = **33,33 ms**. É a régua de tudo
abaixo. O harness confere a paridade antes de medir (assert "tick do harness =
tick de produção (30 Hz, budget 33.33 ms/passo)").

## 2. Tabela medida (mesma zona, players na mesma instância)

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

**Número com que se planeja (conservador): ~150 players na mesma zona por
processo.** Por quê conservador: o período de 33,6 ms a 200 players foi medido com
o mundo simulado **e sem** o que divide o mesmo thread em produção — pacotes de
rede, `settle`/save, rajadas de SQL e as instâncias de boss. Esses custos têm réguas
próprias (`tests/scale_test.gd`, `tests/read_pool_test.gd`), não estão incluídos na
reta acima.

Com o cap real de 20 players/instância, **uma** instância usa 4,11 ms dos 33,33.
Logo a restrição do processo não é o cap de instância e sim o **total de players
somando todas as instâncias do mesmo processo** — que é exatamente o que ainda não
foi medido (ver §6).

## 4. O que limita, no código

- **Um único thread de tick**: tudo acima é 30 Hz num processo (`sources/launcher/Launcher.gd:205-206`).
- **SQL serializada numa única mutex**: `var queryMutex : Mutex = Mutex.new()` em
  `sources/sql/SQL.gd:7`. `grep -rn "Thread.new()" sources/` devolve **exatamente
  uma** linha — `sources/sql/SQLBackups.gd:5` (worker de backup). Não existe pool
  de threads de jogo: escrita, transação e o round trip do read pool competem pela
  mesma `queryMutex`. Espera dela é medida, não suposta: `_LockQueryMutex()`
  (`sources/sql/SQL.gd:1424`) cronometra cada `lock()` com
  `Time.get_ticks_usec()` e acumula em `sources/sql/SQL.gd:1408-1416`
  (contadores + buckets >1/>10/>100 ms); leitura por
  `SQL.QueryMutexWaitSeconds()` (`sources/sql/SQL.gd:1444`, forma counter
  Prometheus) e `SQL.QueryMutexWaitStats()` (`sources/sql/SQL.gd:1447`).
  Na tabela do §2 a espera é 0,00 µs/passo porque o harness simula o mundo e não
  um fluxo de escrita por player; o caminho de escrita é o que
  `tests/scale_test.gd` mede em round trips por ação.
- **Cap de instância**: `MAX_PLAYERS_PER_INSTANCE = 20` em
  `sources/world/WorldInstance.gd:5`, resolvido por busca limitada em
  `WorldAgent.ResolvePlayerInstance()` (`sources/world/WorldAgent.gd:158`,
  janela `MAX_SHARDS_PER_FAMILY = 32` em `sources/world/WorldAgent.gd:16`,
  chamada no spawn em `sources/world/WorldAgent.gd:218` e no warp em
  `sources/world/World.gd:106`). Instâncias de zona dedicada (`>=
  IdlePolicyService.ZoneInstanceBase`) e de boss **não** são fragmentadas
  (`sources/world/WorldAgent.gd:150`). Prova: `tests/shard_capacity_test.gd`
  (41 e 61 players pelo caminho real → 20/20/1 e 20/20/20/1, nenhuma instância
  acima de 20).
- **Observabilidade**: o `/metrics` binda só `127.0.0.1:9400`
  (`sources/system/MetricsServer.gd:25-26`), então o scraper precisa compartilhar
  o namespace do jogo — `network_mode: service:game` em
  `deploy/docker-compose.yml:261`, porta do Prometheus `--web.listen-address=:9090`
  (`deploy/docker-compose.yml:274`), Alertmanager `:9093`
  (`deploy/docker-compose.yml:304`). As regras viajam dentro da imagem
  (`deploy/monitoring/prometheus.Dockerfile:19-20`,
  `deploy/monitoring/alertmanager.Dockerfile:11`).

## 5. Remedir

```bash
cd /mnt/dados/Projetos/shambleta
mkdir -p /tmp/scale-fix/.data /tmp/scale-fix/.cache
env XDG_DATA_HOME=/tmp/scale-fix/.data XDG_CACHE_HOME=/tmp/scale-fix/.cache \
  stdbuf -oL -eL timeout 300 godot --headless --path . -s tests/tick_capacity_test.gd 2>&1 | tail -20
```

A última linha útil é `== RESULT: 32 checks, 0 failures ==`, precedida de
`== TABELA (deploy/SCALING.md) ==` com as quatro linhas do §2 — copie-as para cá
se re-meçar. O harness se auto-valida: falha se o tick não for 30 Hz, se a queima
injetada não aparecer no trabalho medido, se o período não reagir à sobrecarga
injetada, se a série não for monotônica ou se o piso/instância-cheia não caberem
no orçamento. Capacidade de instância (o cap de 20):

```bash
env XDG_DATA_HOME=/tmp/scale-fix/.data XDG_CACHE_HOME=/tmp/scale-fix/.cache \
  stdbuf -oL -eL timeout 300 godot --headless --path . -s tests/shard_capacity_test.gd 2>&1 | tail -5
```

## 6. Pendentes, declarados

- **[NÃO MEDIDO] no container.** Docker **não está instalado** nesta máquina
  (`which docker podman` vazio). Nada aqui foi rodado com `docker compose up`: a
  prova do stack de observação é parse de config + o gate
  `bash scripts/check_compose.sh` (atualmente `== COMPOSE GATE: 87 checks, 0
  failures ==`), que confere referência às regras, alvos/portas de scrape contra o
  que os processos escutam, serviço de alerting declarado e routing por severidade.
  Binário exportado (`deploy/server/Dockerfile`) vs. fonte também não foi medido.
- **[NÃO MEDIDO] o teto do compose.** `cpus: 2` / `mem_limit: 1536M` do `game`
  (`deploy/docker-compose.yml:81` para o limite) nunca foi confrontado com a curva
  acima: a 200 players o RSS medido é 416 MB e o CPU de um tick saturado é ~1
  core. Falta medir N instâncias × 20 no mesmo processo — o número que o beta
  precisa.
- **[PEDIDO, arquivo de outro dono]** falta uma linha no `/metrics` para expor a
  espera da mutex que o §4 já conta. Linha exata, no padrão do corpo de
  `MetricsBody()` (`sources/system/MetricsServer.gd:148-177`), a ser inserida por
  quem é dono do arquivo:

  ```gd
  body += "# HELP shambleta_sql_query_mutex_wait_seconds segundos acumulados aguardando a queryMutex (sources/sql/SQL.gd:7).\n"
  body += "# TYPE shambleta_sql_query_mutex_wait_seconds counter\n"
  body += "shambleta_sql_query_mutex_wait_seconds %.6f\n" % (Launcher.SQL.QueryMutexWaitSeconds() if Launcher.SQL != null else 0.0)
  ```

  Com ela, a regra de alerta correspondente (também em arquivo de outro dono,
  `deploy/alerts.rules.yml`) passa a ter o que ler.

Cross-referências: `deploy/OPS_RUNBOOK.md` §4 (limites de recurso e como reproduzir),
`deploy/prometheus.yml`, `deploy/alerts.rules.yml`.
