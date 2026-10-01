# Runbook de operação — saúde, boot, parada limpa e os números de recurso

Estado da árvore em 2026-09-27. Cada número abaixo ou é lido do código
(arquivo:linha) ou foi **medido nesta máquina** (comando de reprodução em §4.3).
O que não foi medido está dito como não medido.

## 1. Os três serviços que importam, e o que cada um realmente escuta

| serviço | porta | quem escuta | bind |
|---|---|---|---|
| `game` | 6108 | WebSocket do jogo (`EXPOSE` em `deploy/server/Dockerfile:45`; `static var WebSocketPort = 6108` em `sources/network/NetworkCommons.gd:@WebSocketPort`) | interface do container |
| `game` | 9400 | `/healthz` + `/metrics` na `DefaultPort` do painel (`sources/system/MetricsServer.gd:@DefaultPort`) | **só `127.0.0.1`**, o `BindAddress` do painel (`sources/system/MetricsServer.gd:@BindAddress`) |
| `companion` | 8901 | `/health`, `/metrics`, `/checkout/*`, `/webhooks/payments` (`Handler` em `companion/server.py:@Handler`) | `0.0.0.0` (`deploy/companion/Dockerfile:46`) |
| `web` | 80 | nginx estático + proxy para o companion (`deploy/web/nginx.conf:43`, `deploy/web/nginx.conf:174` e `:205`) | `listen 80` (IPv4) |

Fora do container, TLS termina no proxy do Coolify (ou no `cloudflared`). Nada
aqui deve ter porta publicada (`deploy/docker-compose.yml:15-22`).

## 2. Saúde: como ler, e o que cada leitura NÃO prova

```bash
# estado consolidado (o que o orquestrador vê)
for s in web game companion; do printf '%-10s %s\n' "$s" \
  "$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
     $(docker compose ps -q $s) 2>/dev/null)"; done

# game: 200 = serve; conexão recusada = processo morto; 503 = o processo está de pé
#   e se RECUSANDO a servir — ainda booting (migrations/mundo) ou esquema parado.
#   No segundo caso a porta de entrada também recusa handshake (`Admission` devolve
#   o reason `schema_blocked` antes do teto de conexões), então 503 não é lentidão:
#   é o server sabendo que o schema dele está incompleto. Sinal e procedimento estão
#   em `deploy/ROLLBACK.md` ("Migration aplicada pela metade: qual é o sinal").
docker compose exec game curl -fsS http://127.0.0.1:9400/healthz
docker compose exec game curl -fsS http://127.0.0.1:9400/metrics | grep shambleta_grant_queue
# companion: a rota abre a MESMA conexão SQLite do grant
docker compose exec companion wget -q -O- http://127.0.0.1:8901/health
# fronteira do dinheiro, vista de fora (pelo domínio do `web`, sem segunda origem)
curl -s -o /dev/null -w '%{http_code}\n' https://<dominio>/webhooks/payments
```

Leituras e honestidade:

- `grant_queue_pending > 0` crescendo é compra paga sem crédito — é o alerta que
  importa, não o `up`, que é `IsServing()` (`sources/system/MetricsServer.gd:@IsServing`).
- `/webhooks/payments` por GET devolve **404** do companion (companion vivo, proxy
  OK — medido: `{"error": "not_found"}`, `companion/server.py:1448`). **502/504** é
  outra coisa: o nginx não alcança o upstream (companion morto ou `resolver` sem
  resposta). Distinguir os dois é o inteiro propósito desta linha.
- O healthcheck do `web` (`deploy/docker-compose.yml`, bloco `web:`) confere que o
  shell do jogo é o shell do jogo (`index.js` no corpo de `/index.html`) — ele
  **não** prova nada sobre o companion nem sobre o `game`, de propósito: o `web`
  não pode ficar unhealthy por causa de outro serviço quando o próprio nginx está
  servindo (mesmo raciocínio do `companion:` com `condition: service_started`,
  `deploy/docker-compose.yml:95-96`).
- `cloudflared` não tem healthcheck: a imagem não traz shell nem wget, e um probe
  que falha por falta de ferramenta é ruído. O túnel se mede pela origem pública
  (`curl -sI https://<dominio>/index.html`; 530 = origem inalcançável). **[NÃO
  MEDIDO]** aqui, porque não há túnel nesta máquina.
- Nenhuma leitura de saúde diz **qual build está no ar** — as três rotas acima
  respondem "saudável", não "de que commit". O identificador é o tag da imagem, e
  ele se lê do container, não da memória de quem deployou (bloco abaixo). Um
  `local-unpinned` em qualquer linha significa que aquele serviço foi buildado sem
  `SHAMBLETA_TAG` e **não tem alvo de rollback**: é um deploy a re-pisar, não um
  incidente a reiniciar. O procedimento de voltar atrás está em `deploy/ROLLBACK.md`
  ("Artefato versionado", "Ver o que está no ar agora"); o carimbo do lado da CI é o
  passo `Stamp the image tag from the commit` em `.github/workflows/godot-ci.yml`.

```bash
for s in web game companion prometheus alertmanager; do
  printf '%-12s %s\n' "$s" "$(docker inspect --format '{{.Config.Image}}' \
    "$(docker compose -f deploy/docker-compose.yml ps -q "$s")" 2>/dev/null)"
done
```

## 3. Parar sem perder dinheiro

**O `docker stop` não fecha o SQLite.** Medido: `kill -TERM` no server headless
termina com **exit 143** (128+SIGTERM — disposição padrão, sem handler) e deixa
`testing.db-wal` de 1.8 MiB ao lado de um `testing.db` de 94 KiB, com zero
jogadores conectados. Não há `_notification`/handler de SIGTERM em `sources/`
(grep: nenhum `NOTIFICATION_WM_CLOSE_REQUEST`), nem no companion
(`main()` em `companion/server.py:@main` roda `serve_forever()` e só segura `KeyboardInterrupt`; medido: exit 143).

Não é corrupção — o SQLite recupera o WAL na próxima abertura — mas é estado em
memória perdido: até `BackupPlayersSec` = 600 s de ouro (`sources/sql/SQLCommons.gd:@BackupPlayersSec`).

O caminho que fecha direito é o canary:

```bash
docker compose exec game touch /data/.local/share/Shambleta/canary   # = user://canary
docker compose logs -f game      # "Server restarting in 30 seconds." → "15" → saída
```

O que acontece depois do toque (`sources/world/ShutdownCanary.gd:28-59`): recusa
novas conexões, avisa em 30 s e 15 s, derruba os peers que restam e chama
`Launcher.Quit()` → `Reset(false,false)` → `SQL.Destroy()` → `backups.Stop()`
(join de até `BackupCheckIntervalSec` = 2 s) + `db.close_db()`
(`SQL.Destroy()` em `sources/sql/SQL.gd:@Destroy`, `Stop()` em `sources/sql/SQLBackups.gd:@Stop`).

É por isso que `stop_grace_period: 75s` no serviço `game`: 30 + 15 s de aviso + 2 s
de join, com folga de fsync. O grace não *causa* o shutdown — ele **não mata** um
shutdown que já está em curso. Redeploy sem canary = drain não acontece.

## 4. Limites de recurso: valor, origem, e o que ainda falta medir

### 4.1 Formato usado

Os quatro campos são as chaves planas do Compose Spec (`mem_limit`,
`mem_reservation`, `cpus`, `stop_grace_period`), que mapeiam 1:1 para flags do
`docker run` e funcionam tanto em compose v1 quanto v2 — `deploy.resources.*` é
ignorado silenciosamente por v1, que é exatamente o modo como um limite "existe"
no arquivo e não existe no container.

### 4.2 Os números

| serviço | cpus | mem_reservation | mem_limit | por quê |
|---|---|---|---|---|
| `game` | 2 | 640 M | 1536 M | loop único (`ServerMaxFPS` em `sources/launcher/LauncherCommons.gd:@ServerMaxFPS` = 30 FPS), ~1 core; o 2º core é para o boot (migrations + mundo) caber no `start_period: 40s`. Teto a ~3× o piso medido, porque SIGKILL aqui custa o §7.1 de `archive/AUDITORIA_2026-09-27.md` (até 600 s de ouro só em memória) — o teto protege o **host**, não a performance. |
| `companion` | 0.5 | 64 M | 256 M | 31 MiB medido ocioso; stateless entre requests (cada request abre a própria conexão, `companion/server.py:1070-1074`); OOM não perde dinheiro — o provedor re-tenta o webhook e a idempotência do grant decide. |
| `web` | — | 64 M | — | **sem teto**: nginx servindo o primeiro load de ~35 MiB (`deploy/WEB_SLIM.md:69`) não foi medido nesta máquina; teto sem medida é causa de indisponibilidade. |
| `cloudflared` | — | 32 M | — | binário de terceiro, idem. |

### 4.2.1 Capacidade de tick (o outro número, medido)

O parágrafo acima responde "quanto de RAM/CPU o container pede". A pergunta
"quantos jogadores cabem no tick de 30 Hz" tem número próprio, método e régua em
**`deploy/SCALING.md`** — gerado por `tests/tick_capacity_test.gd` (gate:
`== RESULT: 32 checks, 0 failures ==`), com 1 / 20 / 100 / 200 players na mesma
zona. Resumo: custo marginal medido **0,206 ms/player/passo**, joelho
**extrapolado** (reta, não medição) em **~154 players por zona**, período real
dentro do orçamento de 33,33 ms em todos os níveis medidos até 200. O cap de 20
por instância (`sources/world/WorldInstance.gd:5`) não é a restrição do processo —
o total de players somando as instâncias é, e esse tem número medido e fence: **200 players conviventes em 10 instâncias cheias dentro de 33,33 ms/passo**, imposto por `CeilingFencePlayers` (`tests/multi_instance_tick_test.gd:@CeilingFencePlayers`) e cobrado por duas checks (`:1802` e `:1805`).

### 4.3 Reproduzir as medidas (sem docker, a partir da raiz do repo)

```bash
mkdir -p /tmp/deploymem && env HOME=/tmp/deploymem godot --headless --path . --server &
sleep 10; ps -o rss= -p $!          # 469940 kB ≈ 459 MiB (0 jogadores, 30 s)
python3 companion/server.py --db /tmp/deploymem/.local/share/Shambleta/testing.db \
  --port 8939 --provider shared --allow-dev --secret t &
sleep 2;  ps -o rss= -p $!          #  31312 kB ≈ 31 MiB (ocioso)

# Capacidade de tick (deploy/SCALING.md §2) — mesmo princípio: harness como gate,
# número impresso na saída, nada copiado de memória. O runner sancionado existe
# porque godot cru sobre o mesmo WAL é o processo estrangeiro que o `boot_guard` de
# `scripts/test.sh` recusa; um verde obtido por atalho não é o verde do portão.
bash scripts/test.sh one tick_capacity_test
# capacidade de instância (cap 20, busca limitada): bash scripts/test.sh one shard_capacity_test
```

**Docker não existe nesta máquina** (`which docker podman` vazio): nada do §4 ou do
`deploy/SCALING.md` foi medido dentro de container, e o stack de observação é
provado por parse de config + `bash scripts/check_compose.sh`, não por
`docker compose up`. A contagem medida do gate e os dois fumos que ele pula por
falta de binário estão declarados em `deploy/SCALING.md` §6 — este runbook não
repete o número para que ele não possa apodrecer aqui.

Valores desta rodada: Godot 4.7.2 (Arch), execução a partir do fonte — o binário
exportado do `deploy/server/Dockerfile` pode ser menor; **[NÃO MEDIDO]** no
container. O próximo passo é medir no host: `docker stats --no-stream` depois de
uma semana de beta e transformar as duas reservas em tetos com número próprio.

## 5. Ordem de boot (por que `service_healthy` e não `service_started`)

- `web → game: service_healthy`: o nginx não precisa do jogo para servir estático,
  mas o beta não deve abrir a porta antes do `/healthz` dizer `ok`
  (`_route()` em `sources/system/MetricsServer.gd:@_route` devolve 503 enquanto
  `IsServing()` é false).
- `companion → game: service_healthy`: sem `live.db` o companion sai com **exit 2**
  (`main()` em `companion/server.py:@main` recusa o banco ausente; reproduzido:
  `--db /tmp/nao-existe.db` → `database not found`, exit 2). Num volume novo, isso
  aconteceria antes de o game criar o banco — crash-loop exatamente na fronteira
  do dinheiro.
- `web → companion: service_started` (não healthy): o nginx resolve o upstream por
  `resolver`/variável a cada request (`deploy/web/nginx.conf:190-192`), então um
  companion esquentando responde 502 em vez de derrubar o site.
- `cloudflared → game`: curto, sem condição — o túnel só precisa do container.

O gate lê os quatro `depends_on` + as portas dos probes contra o código:
`bash scripts/check_compose.sh`.

## 6. Pendências em arquivo de outro dono (nada disso foi editado aqui)

| arquivo:linha | o que muda | por quê |
|---|---|---|
| `deploy/web/Dockerfile:50` | remover o `HEALTHCHECK ... wget -qO- http://127.0.0.1/` | o compose agora define o probe honesto; a linha na imagem é um check que não consegue falhar (`try_files ... /index.html`, `deploy/web/nginx.conf:306`) e só sobrevive para confundir quem lê a imagem. |
| `main()` — `companion/server.py:@main` | instalar handler de `SIGTERM` antes do `serve_forever()`, com join das threads | hoje `docker stop` mata no meio de um webhook (medido: exit 143). O provedor re-tenta, mas a janela entre verificar a assinatura e gravar o grant é exatamente onde o dinheiro vive. |
| `sources/sql/SQLBackups.gd:92` | `lastDailyBackupTimestamp = 0` (como `lastMetaJobTimestamp = 0` já faz em `sources/sql/SQLBackups.gd:102`, na mesma `Run()`) | redeploy diário zera o relógio do backup diário; ver `deploy/BACKUP_RUNBOOK.md` §2. |


**Não é mais pendência (2026-09-28, conferido no arquivo, não na memória):** a
espera da `queryMutex` JÁ sai no `/metrics` — `shambleta_sql_query_mutex_waits`,
`..._wait_seconds`, `..._wait_max_seconds` e os degrades `..._over_1ms`/`..._over_10ms`/
`..._over_100ms` são emitidos no corpo do `/metrics` (`sources/system/MetricsServer.gd:220-239`,
dentro de `MetricsBody()` declarada em `sources/system/MetricsServer.gd:@MetricsBody`,
lidos de `QueryMutexWaitStats()` em `sources/sql/SQL.gd:@QueryMutexWaitStats`) — e a regra de alerta que
precisava do sinal também já existe: `deploy/alerts.rules.yml:102`. A linha desta tabela
que dizia o contrário sobreviveu ao trabalho feito, que é exatamente o defeito que faz um
operador re-inventar uma métrica que já está sendo raspada.

**Não é mais pendência (e a linha que dizia que era estava errada):** o job de CI
que invoca `scripts/check_compose.sh` já existe e já bloqueia. `code-health`
(`.github/workflows/godot-ci.yml:128-140`) roda `bash scripts/test.sh structure`, e
`structure_gates()` (`scripts/test.sh:@structure_gates`) chama os 11 gates de estrutura —
`check_god_nodes.sh`, `check_doc_drift.sh`, `check_compose.sh`, `check_secrets.sh`,
`check_ci.sh`, `check_dead_code.sh`, `check_untracked.sh`, `check_gate_log.sh` e
`check_boot_sandbox.sh`, `check_gate_markers.sh` e
`check_write_funnel.sh` — pelo mesmo
`gate_sh`/`scripts/ci_gate_log.sh` do `all` local. Conferido aqui porque esta
tabela é lida como fila de trabalho: pendência falsa faz alguém re-inventar um job
que já roda.

## 7. Backups

Fora do escopo deste arquivo: `deploy/BACKUP_RUNBOOK.md` (o que roda, como
verificar, como restaurar, como podar o que sai do host).
