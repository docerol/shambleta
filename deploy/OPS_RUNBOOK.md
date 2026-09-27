# Runbook de operação — saúde, boot, parada limpa e os números de recurso

Estado da árvore em 2026-09-27. Cada número abaixo ou é lido do código
(arquivo:linha) ou foi **medido nesta máquina** (comando de reprodução em §4.3).
O que não foi medido está dito como não medido.

## 1. Os três serviços que importam, e o que cada um realmente escuta

| serviço | porta | quem escuta | bind |
|---|---|---|---|
| `game` | 6108 | WebSocket do jogo (`EXPOSE` em `deploy/server/Dockerfile:40`; `static var WebSocketPort = 6108` em `sources/network/NetworkCommons.gd:12`) | interface do container |
| `game` | 9400 | `/healthz` + `/metrics` do `MetricsServer` (`sources/system/MetricsServer.gd:21`) | **só `127.0.0.1`** (`:22`) |
| `companion` | 8901 | `/health`, `/metrics`, `/checkout/*`, `/webhooks/payments` (`companion/server.py:1165-1209`) | `0.0.0.0` (`deploy/companion/Dockerfile:34`) |
| `web` | 80 | nginx estático + proxy para o companion (`deploy/web/nginx.conf:31`, `:155-157`) | `listen 80` (IPv4) |

Fora do container, TLS termina no proxy do Coolify (ou no `cloudflared`) — nada
aqui deve ter porta publicada (`deploy/docker-compose.yml:15-22`).

## 2. Saúde: como ler, e o que cada leitura NÃO prova

```bash
# estado consolidado (o que o orquestrador vê)
for s in web game companion; do printf '%-10s %s\n' "$s" \
  "$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
     $(docker compose ps -q $s) 2>/dev/null)"; done

# game: 503 = ainda booting (migrations/mundo); conexão recusada = processo morto
docker compose exec game curl -fsS http://127.0.0.1:9400/healthz
docker compose exec game curl -fsS http://127.0.0.1:9400/metrics | grep shambleta_grant_queue
# companion: a rota abre a MESMA conexão SQLite do grant
docker compose exec companion wget -q -O- http://127.0.0.1:8901/health
# fronteira do dinheiro, vista de fora (pelo domínio do `web`, sem segunda origem)
curl -s -o /dev/null -w '%{http_code}\n' https://<dominio>/webhooks/payments
```

Leituras e honestidade:

- `grant_queue_pending > 0` crescendo é compra paga sem crédito — é o alerta que
  importa, não o `up` (`sources/system/MetricsServer.gd:99-134`).
- `/webhooks/payments` por GET devolve **404** do companion (companion vivo, proxy
  OK — medido: `{"error": "not_found"}`, `companion/server.py:1222`). **502/504** é
  outra coisa: o nginx não alcança o upstream (companion morto ou `resolver` sem
  resposta). Distinguir os dois é o inteiro propósito desta linha.
- O healthcheck do `web` (`deploy/docker-compose.yml`, bloco `web:`) confere que o
  shell do jogo é o shell do jogo (`index.js` no corpo de `/index.html`) — ele
  **não** prova nada sobre o companion nem sobre o `game`, de propósito: o `web`
  não pode ficar unhealthy por causa de outro serviço quando o próprio nginx está
  servindo (mesmo raciocínio do `depends_on: companion: service_started`,
  `deploy/docker-compose.yml:56-66`).
- `cloudflared` não tem healthcheck: a imagem não traz shell nem wget, e um probe
  que falha por falta de ferramenta é ruído. O túnel se mede pela origem pública
  (`curl -sI https://<dominio>/index.html`; 530 = origem inalcançável). **[NÃO
  MEDIDO]** aqui, porque não há túnel nesta máquina.

## 3. Parar sem perder dinheiro

**O `docker stop` não fecha o SQLite.** Medido: `kill -TERM` no server headless
termina com **exit 143** (128+SIGTERM — disposição padrão, sem handler) e deixa
`testing.db-wal` de 1.8 MiB ao lado de um `testing.db` de 94 KiB, com zero
jogadores conectados. Não há `_notification`/handler de SIGTERM em `sources/`
(grep: nenhum `NOTIFICATION_WM_CLOSE_REQUEST`), nem no companion
(`companion/server.py:1838-1839` só trata `KeyboardInterrupt`; medido: exit 143).

Não é corrupção — o SQLite recupera o WAL na próxima abertura — mas é estado em
memória perdido: até `BackupPlayersSec` = 600 s de ouro (`sources/sql/SQLCommons.gd:11`).

O caminho que fecha direito é o canary:

```bash
docker compose exec game touch /data/.local/share/Shambleta/canary   # = user://canary
docker compose logs -f game      # "Server restarting in 30 seconds." → "15" → saída
```

O que acontece depois do toque (`sources/world/ShutdownCanary.gd:28-59`): recusa
novas conexões, avisa em 30 s e 15 s, derruba os peers que restam e chama
`Launcher.Quit()` → `Reset(false,false)` → `SQL.Destroy()` → `backups.Stop()`
(join de até `BackupCheckIntervalSec` = 2 s) + `db.close_db()`
(`sources/sql/SQL.gd:1562-1569`, `sources/sql/SQLBackups.gd:172-188`).

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
| `game` | 2 | 640 M | 1536 M | loop único a 30 FPS = ~1 core (`sources/launcher/LauncherCommons.gd:19`); o 2º core é para o boot (migrations + mundo) caber no `start_period: 40s`. Teto a ~3× o piso medido, porque SIGKILL aqui custa o §7.1 da AUDITORIA_2026-09-27.md (até 600 s de ouro só em memória) — o teto protege o **host**, não a performance. |
| `companion` | 0.5 | 64 M | 256 M | 31 MiB medido ocioso; stateless entre requests (cada request abre a própria conexão, `companion/server.py:838-841`); OOM não perde dinheiro — o provedor re-tenta o webhook e a idempotência do grant decide. |
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
o total de players somando as instâncias é, e esse ainda está **[NÃO MEDIDO]**.

### 4.3 Reproduzir as medidas (sem docker, a partir da raiz do repo)

```bash
mkdir -p /tmp/deploymem && env HOME=/tmp/deploymem godot --headless --path . --server &
sleep 10; ps -o rss= -p $!          # 469940 kB ≈ 459 MiB (0 jogadores, 30 s)
python3 companion/server.py --db /tmp/deploymem/.local/share/Shambleta/testing.db \
  --port 8939 --provider shared --allow-dev --secret t &
sleep 2;  ps -o rss= -p $!          #  31312 kB ≈ 31 MiB (ocioso)

# Capacidade de tick (deploy/SCALING.md §2) — mesmo princípio: harness como gate,
# número impresso na saída, nada copiado de memória.
mkdir -p /tmp/scale-fix/.data /tmp/scale-fix/.cache
env XDG_DATA_HOME=/tmp/scale-fix/.data XDG_CACHE_HOME=/tmp/scale-fix/.cache \
  stdbuf -oL -eL timeout 300 godot --headless --path . -s tests/tick_capacity_test.gd 2>&1 | tail -20
# capacidade de instância (cap 20, busca limitada): -s tests/shard_capacity_test.gd
```

**Docker não existe nesta máquina** (`which docker podman` vazio): nada do §4 ou do
`deploy/SCALING.md` foi medido dentro de container, e o stack de observação é
provado por parse de config + `bash scripts/check_compose.sh` (87 checks), não por
`docker compose up`.

Valores desta rodada: Godot 4.7.2 (Arch), execução a partir do fonte — o binário
exportado do `deploy/server/Dockerfile` pode ser menor; **[NÃO MEDIDO]** no
container. O próximo passo é medir no host: `docker stats --no-stream` depois de
uma semana de beta e transformar as duas reservas em tetos com número próprio.

## 5. Ordem de boot (por que `service_healthy` e não `service_started`)

- `web → game: service_healthy`: o nginx não precisa do jogo para servir estático,
  mas o beta não deve abrir a porta antes do `/healthz` dizer `ok`
  (`sources/system/MetricsServer.gd:195-198` devolve 503 enquanto
  `Launcher.SQL.isInitialized` é false).
- `companion → game: service_healthy`: sem `live.db` o companion sai com **exit 2**
  (`companion/server.py:2032-2034`; reproduzido: `--db /tmp/nao-existe.db` →
  `database not found`, exit 2). Num volume novo, isso aconteceria antes de o game
  criar o banco — crash-loop exatamente na fronteira do dinheiro.
- `web → companion: service_started` (não healthy): o nginx resolve o upstream por
  `resolver`/variável a cada request (`deploy/web/nginx.conf:155-156`), então um
  companion esquentando responde 502 em vez de derrubar o site.
- `cloudflared → game`: curto, sem condição — o túnel só precisa do container.

O gate lê os quatro `depends_on` + as portas dos probes contra o código:
`bash scripts/check_compose.sh`.

## 6. Pendências em arquivo de outro dono (nada disso foi editado aqui)

| arquivo:linha | o que muda | por quê |
|---|---|---|
| `deploy/web/Dockerfile:50` | remover o `HEALTHCHECK ... wget -qO- http://127.0.0.1/` | o compose agora define o probe honesto; a linha na imagem é um check que não consegue falhar (`try_files ... /index.html`, `deploy/web/nginx.conf:194`) e só sobrevive para confundir quem lê a imagem. |
| `companion/server.py:1838` | instalar handler de `SIGTERM` → `server.shutdown()` + join das threads antes do `sys.exit` | hoje `docker stop` mata no meio de um webhook (medido: exit 143). O provedor re-tenta, mas a janela entre verificar a assinatura e gravar o grant é exatamente onde o dinheiro vive. |
| `sources/sql/SQLBackups.gd:92` | `lastDailyBackupTimestamp = 0` (como `:102` faz para o job meta) | redeploy diário zera o relógio do backup diário; ver `deploy/BACKUP_RUNBOOK.md` §2. |
| `sources/system/MetricsServer.gd:177` | somar ao corpo de `MetricsBody()` as três linhas de `shambleta_sql_query_mutex_wait_seconds` (HELP/TYPE/valor, formato em `deploy/SCALING.md` §6) | a espera na `queryMutex` (`sources/sql/SQL.gd:7`) já é contada pelo código (`sources/sql/SQL.gd:1424`, getter em `:1444`), mas sem a linha no `/metrics` o Prometheus não tem o que raspar e a regra de serialização de SQL não tem métrica para ler. |

**Não é mais pendência (e a linha que dizia que era estava errada):** o job de CI
que invoca `scripts/check_compose.sh` já existe e já bloqueia. `code-health`
(`.github/workflows/godot-ci.yml:128-140`) roda `bash scripts/test.sh structure`, e
`structure_gates()` (`scripts/test.sh:194-198`) chama os três gates de estrutura —
`check_god_nodes.sh`, `check_doc_drift.sh` e `check_compose.sh` — pelo mesmo
`gate_sh`/`scripts/ci_gate_log.sh` do `all` local. Conferido aqui porque esta
tabela é lida como fila de trabalho: pendência falsa faz alguém re-inventar um job
que já roda.

## 7. Backups

Fora do escopo deste arquivo: `deploy/BACKUP_RUNBOOK.md` (o que roda, como
verificar, como restaurar, como podar o que sai do host).
