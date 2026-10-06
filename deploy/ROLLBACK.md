# Rollback e Incidentes

Este runbook cobre rollback de deploy, a fronteira do schema, deploy morto no
meio caminho e resposta a incidentes.

Toda vez que um comando aqui diz `docker compose`, ele roda **na raiz do repositório
clonado no host**, com `-f deploy/docker-compose.yml`. Sem o arquivo não há serviço,
sem serviço não há comando — e o `SHAMBLETA_TAG` do §"Artefato versionado" é lido na
hora de cada invocação, então `build` e `up` precisam vê-lo igual.

## Artefato versionado (sem isto não há para onde voltar)

Os cinco serviços que o compose **builda** declaram imagem nomeada e tag vinda de um
knob único:

| serviço | imagem | chave no compose |
|---|---|---|
| `web` | `shambleta/web:${SHAMBLETA_TAG:-local-unpinned}` | `services.web.image` em `deploy/docker-compose.yml:@services.web.image` |
| `game` | `shambleta/game:${SHAMBLETA_TAG:-local-unpinned}` | `services.game.image` em `deploy/docker-compose.yml:@services.game.image` |
| `companion` | `shambleta/companion:${SHAMBLETA_TAG:-local-unpinned}` | `services.companion.image` em `deploy/docker-compose.yml:@services.companion.image` |
| `prometheus` | `shambleta/prometheus:${SHAMBLETA_TAG:-local-unpinned}` | `services.prometheus.image` em `deploy/docker-compose.yml:@services.prometheus.image` |
| `alertmanager` | `shambleta/alertmanager:${SHAMBLETA_TAG:-local-unpinned}` | `services.alertmanager.image` em `deploy/docker-compose.yml:@services.alertmanager.image` |

Os cinco trazem também `pull_policy: never`
(`deploy/docker-compose.yml:51,103,212,320,375`), cada um na linha seguinte ao seu
`image:`. Não é decoração: **não existe
registry** para onde este stack olhe. O artefato nasce e mora no host que o buildou.
Quem faz `docker compose pull game` num serviço buildado não está baixando versão
nenhuma — está ou procurando `shambleta/game` no Docker Hub (404) ou achando que
baixou. O `pull_policy: never` existe para transformar esse engano em recusa.
`cloudflared` fica de fora dos dois: é imagem de terceiro, puxada de registry, com
tag flutuante própria (`cloudflare/cloudflared:latest`).

### Como a tag é pisada no build

```bash
cd <repo>
export SHAMBLETA_TAG="$(git rev-parse --short=12 HEAD)"   # o knob, uma vez por deploy
docker compose -f deploy/docker-compose.yml build          # compose taga exatamente shambleta/<svc>:$SHAMBLETA_TAG
```

O compose usa o `image:` do serviço como alvo do `build:` — o mesmo comando que
produz a imagem é o que dá nome a ela, e é por isso que o tag pisa junto com o
build em vez de ser um passo separado que alguém esquece. A CI faz a mesma coisa no
job `container-images` de `.github/workflows/godot-ci.yml`, com `SHAMBLETA_TAG`
fixado no SHA do commit que gatilhou o job: lá o tag é consequência do checkout, não
digitado.

Duas coisas que isto **não** é, e é importante não confundir:

* Não é publicação. Nenhum desses builds sobe para registry; o tag só existe no host
  que rodou o `build`. Isso é o que torna o `--no-build` do §abaixo necessário, e é o
  que faz de um `docker image prune -a` a operação que apaga o caminho de volta.
* Não é o default. Sem `SHAMBLETA_TAG` no ambiente, os cinco serviços resolvem para
  `shambleta/<svc>:local-unpinned`. O nome é o aviso: um deploy com esta tag rodando
  **não tem alvo de rollback** — não existe "a versão anterior" para nomear. Antes de
  aceitar um deploy, confira o §"Ver o que está no ar agora"; se aparecer
  `local-unpinned`, o deploy seguinte precisa ser re-pisado com o knob, não o
  rollback.

A régua disto não é esta tabela: `scripts/check_compose.sh` (seção `rollback:`) exige
imagem nomeada, knob único, default não-mutável e `pull_policy: never` em todo serviço
com `build:` que o compose declarar — inclusive nos que ainda vão nascer.

## Rollback de Deploy

### Via Docker Compose

#### 1. Ver o que está no ar agora

`docker compose ps` mostra *qual imagem* cada container em execução foi criado — é a
única resposta que não depende do que você *achava* que tinha deployado:

```bash
export SHAMBLETA_TAG="$(docker inspect --format '{{.Config.Image}}' \
  "$(docker compose -f deploy/docker-compose.yml ps -q game)" | cut -d: -f2)"
echo "game no ar: $SHAMBLETA_TAG"          # 'local-unpinned' aqui = não há para onde voltar
docker images | grep '^shambleta/'          # que tags este host ainda tem
```

O `cut -d: -f2` pega a tag da referência `shambleta/game:<tag>`. Se o host não tem
`game`, `ps -q` devolve vazio e o `docker inspect` reclama — que é a resposta honesta
para "o que está no ar". E confira o resto do stack no mesmo formato, um por serviço
(`web`, `companion`): deploy pela metade tem tag diferente em serviço diferente (§
"Deploy que morre no meio").

#### 2. Escolher para qual tag voltar — e onde está o chão

A tag anterior precisa **existir neste host** (`docker images | grep '^shambleta/'`).
Se ela não está ali, não há rollback de compose: sobra o rollback do Coolify (§abaixo,
que usa o histórico do próprio painel) ou o restore de backup.

O chão real, porém, não é a imagem: é o schema. Veja o §"A fronteira do schema" antes
de subir binário mais velho que a base.

#### 3. Voltar sem tocar no schema

```bash
export SHAMBLETA_TAG=<sha-da-lista-acima>          # tag ANTerior, que você confirmou no passo 1
docker compose -f deploy/docker-compose.yml up -d --no-build game web companion
docker compose -f deploy/docker-compose.yml ps     # IMAGE deve bater com a tag exportada
```

`--no-build` + `pull_policy: never` é o par que faz este passo ser um rollback e não um
redeploy: o compose não pode buildar (não há fonte novo no container) nem puxar (não
há registry), então ele **usa exatamente a imagem daquele tag ou falha**. Um `up -d`
sem `--no-build`, com o tag ausente do host, é o erro clássico: ele reconstroi o fonte
corrente e você sobe o mesmo build que acabou de rejeitar, agora com a etiqueta da
versão antiga. Se o comando reclamar de imagem ausente, a resposta é o passo 2, não
tirar o `--no-build`.

Uma linha sobre os três serviços juntos: `web` embute o endereço do game server no
pacote em **build** (`SHAMBLETA_SERVER_ADDRESS` é ARG do Dockerfile, `deploy/COOLIFY.md`
§2), então voltar o `web` não muda o endereço. Voltar só o `game` é o caso comum — um
server que ficou lento ou quebrado; voltar `companion` junto só se o defeito é na
frente do dinheiro, e lembre que os dois dependem do `game` saudável — o
`services.web.depends_on.game` (`deploy/docker-compose.yml:@services.web.depends_on.game`) e o
`services.companion.depends_on.game` (`deploy/docker-compose.yml:@services.companion.depends_on.game`).

### Via Coolify

1. Acesse o Coolify, abra o recurso (Docker Compose) do stack.
2. No serviço (`game`, `web`), abra o histórico de deployments do recurso.
3. Escolha o deployment anterior ao que quebrou e acione o rollback/redeploy dele — o
   Coolify re-aponta para a imagem daquele deployment, não para o fonte de hoje.
4. Confirme no terminal, com o passo 1 do caminho acima, que a imagem em execução é a
   que você nomeou. A UI diz o que ela *pediu*; o `docker inspect` diz o que *está*.

O procedimento de clique por clique e o nome exato de cada botão não são medidos
nesta máquina — não há Coolify aqui **[NÃO MEDIDO]**. O que se exige é o resultado:
`docker inspect --format '{{.Config.Image}}'` apontando para um tag que não é o do
último push. `deploy/COOLIFY.md` §7 cobre o mesmo caminho pelo lado do painel,
incluindo o que fazer quando o deploy é automático no push.

### A fronteira do schema (o que não volta junto com a imagem)

**As migrations são forward-only.** Cada patch é um `data/conf/migrations/NNN_*.sql`
aplicado em ordem no boot do `game`, e o número gravado em `migration.version` só
sobe. Um binário que traz **menos** patches do que a versão da base não rebaixa nada:
`SQL.ApplyMigrations()` decide o plano, vê `patchCount < currentVersion`, recusa, e o
processo segue rodando sem aplicar — a linha que você vai ver no log é

```
SQL: <N> patches visíveis contra a base na versão <M> — binário mais velho que o schema. Nada aplicado.
```

(estado `stale` do plano; `docker compose logs game | grep "binário mais velho"`).

Logo: **o rollback de binário tem como teto o último build compatível com o schema que
já está na base**, e "compatível" aqui tem um sentido operacional e mensurável — o
build cujo número de patches é **>=** a versão da base. Não é uma promessa de que o
código velho sabe ler a coluna nova: uma `ALTER TABLE ADD COLUMN` costuma ser
inofensiva para um binário que não a lê, mas não existe matriz de compatibilidade
por migration neste repo **[NÃO MEDIDO]**, e uma coluna `NOT NULL` sem default ou um
`CREATE INDEX` sobre expressão já teria quebrado o apply, não o rollback.

```bash
# versão da base — read-only, pela imagem do companion (python3 traz sqlite3;
# a imagem do game não: deploy/server/Dockerfile:22 instala debian:bookworm-slim e
# :27 acrescenta só ca-certificates e curl)
docker compose -f deploy/docker-compose.yml run --rm --no-deps \
  --entrypoint python3 companion -c \
  'import sqlite3;c=sqlite3.connect("file:/data/.local/share/Shambleta/live.db?mode=ro",uri=True);print("live.db version =",c.execute("SELECT version FROM migration").fetchone()[0])'

# quantos patches o commit que você quer voltar trazia
git -C <repo> ls-tree -r --name-only <sha-anterior> -- data/conf/migrations | grep -c '\.sql$'
```

Se o segundo número for **menor** que o primeiro, aquele tag não é um rollback: é um
binário que vai reclamar no boot e operar sobre um schema que ele não conhece. As
três saídas honestas, nesta ordem de preferência:

1. **Corrigir para a frente** (build novo por cima do mesmo schema) — é quase sempre
   mais rápido que qualquer volta, e não tem fronteira de compatibilidade.
2. **Rollback do schema junto com o do banco**: restaurar um backup feito **antes** do
   deploy que migrou (§"Restore de Backup"). O custo é explicitamente perda: todo
   jogador que logou, guilda que mexeu e pagamento creditado entre o backup e o
   incidente volta junto. O `grant_queue` de um pagamento aceito pelo provedor nesse
   intervalo é a coisa que você não pode perder calado — confira
   `shambleta_grant_queue_pending` antes de restaurar.
3. **Reparar o schema para cima** com um patch novo, se o problema é o patch, não o
   binário.

Nunca conte que "o binário velho ignora a coluna nova" seja suficiente: isto não é
testado migration-por-migration.

### Restore de Backup

Se o banco de dados foi corrompido (ou você escolheu a saída 2 acima):

```bash
# Parar o servidor
docker compose -f deploy/docker-compose.yml stop game

# Listar backups disponíveis. Os caminhos são os de dentro do container: `user://`
# do Godot 4 com `config/use_custom_user_dir=true` é `$HOME/.local/share/Shambleta`,
# e o compose monta o volume `game-data` em `/data` (`HOME=/data`). Rodar isso no
# shell do host (`~/...`) nunca encontrou nada.
docker compose -f deploy/docker-compose.yml run --rm --entrypoint sh game -c 'ls -la /data/.local/share/Shambleta/sql-backups/'

# Restaurar backup específico. O nome real é DAILY/AAAA-MM-DD_HH-MM-SS.db
# (SQLBackups.gd:12-13); havia "daily_2026-09-20.db" aqui e esse arquivo nunca
# existiu. O rm do -wal/-shm não é cosmético: o banco está em WAL, e deixar o
# journal da base antiga em cima do arquivo restaurado faz o SQLite reler aquele
# WAL sobre o restore.
docker compose -f deploy/docker-compose.yml run --rm --entrypoint sh game -c \
  'cp /data/.local/share/Shambleta/sql-backups/DAILY/2026-09-24_15-56-24.db /data/.local/share/Shambleta/live.db && rm -f /data/.local/share/Shambleta/live.db-wal /data/.local/share/Shambleta/live.db-shm'

# Reiniciar COM o tag que combina com aquele schema — não com o do incidente.
export SHAMBLETA_TAG=<sha-do-build-da-época>
docker compose -f deploy/docker-compose.yml up -d --no-build game
```

Depois de restaurar, a base está na versão do backup: subir o build *mais novo* sobre
ela re-aplica os patches daquele intervalo, o que é correto se os patches são os
mesmos — e é por isso que o restore com o `game` do build novo tem de ser seguido da
leitura da versão (§"A fronteira do schema"), não de um `ps` verde.

## Deploy que morre no meio (build falhou, ou subiu e está quebrado)

Nada aqui é reconstruído por intuição: as três situações têm sinais diferentes e o
trato seguro é diferente.

### Como detectar

```bash
docker compose -f deploy/docker-compose.yml ps                    # STATE/STATUS por serviço
for s in web game companion prometheus alertmanager; do
  printf '%s -> %s\n' "$s" "$(docker inspect --format '{{.Config.Image}}' \
    "$(docker compose -f deploy/docker-compose.yml ps -q $s)" 2>/dev/null || echo ausente)"
done
docker compose -f deploy/docker-compose.yml logs --since 30m game | grep -E "SQL:|SCRIPT ERROR|ERROR:"
docker compose -f deploy/docker-compose.yml logs --since 30m web  | tail -20
```

Três estados, três assinaturas:

* **Build que não terminou** — o comando `docker compose build` sai com erro e
  nenhuma imagem nova aparece no `docker images` com o tag que você pisou. Nada foi
  tocado no host: nenhum container mudou, o volume não foi aberto, nenhuma migration
  rodou (patch só aplica no boot do processo, não no build). Os dois healthchecks que
  importam — o `services.game.healthcheck.test` (`deploy/docker-compose.yml:@services.game.healthcheck.test`) e o
  `services.web.healthcheck.test` (`deploy/docker-compose.yml:@services.web.healthcheck.test`) continuam
  apontando para a imagem velha, que continua servindo.
* **Subiu e não fica saudável** — `ps` mostra `unhealthy` ou o container em
  restart-loop, e é aqui que o `--no-build` do rollback precisa de você: compare as
  cinco linhas do laço acima. Tag diferente por serviço é o retrato do deploy
  interrompido (o `web` novo com o `game` velho é o caso provável, porque o `web`
  builda primeiro e o `game` é o que o `depends_on` espera —
  `deploy/docker-compose.yml:102-104`). O que o jogador vê: página no ar e login
  caindo, ou site inteiro fora se o `game` não chegou a `service_healthy`.
* **Subiu, ficou verde, e o schema já migrou** — `ps` saudável, mas o log do boot traz uma linha `SQL:` (os estados que o runner anuncia) ou um `ERROR:`/`SCRIPT ERROR` de runtime,
  ou `migration.version` subiu e o erro apareceu depois. Este é o único dos três em
  que o chão se moveu: o rollback agora tem fronteira (§"A fronteira do schema").

### O que é seguro repetir

| situação | ação segura | por quê |
|---|---|---|
| `build` falhou | corrigir e repetir **o mesmo comando, com o mesmo `SHAMBLETA_TAG`** | build é idempotente e não toca estado: o volume `game-data` nem foi aberto |
| `up` falhou / serviço `unhealthy`, sem migration nova | `up -d --no-build` com a tag anterior | a imagem velha continua no host e o schema nunca mudou |
| `up` falhou **com** patches novos no build | voltar o binário só se o passo do §fronteira confirmar `patches(tag) >= live version`; senão, fix forward | o carimbo anda patch a patch: o que virou schema já está gravado e não re-apply |
| boot parou **num** patch (log com `SQL: migration ... FALHOU`) | subir o **mesmo** `SHAMBLETA_TAG` de novo (`up -d --no-build game`) — não trocar de tag | fail-closed: o patch que falhou fica atrás do carimbo e roda de novo com a causa consertada; os anteriores não reaplicam |
| serviço em restart-loop | `docker compose logs <svc>` antes de qualquer `stop` — e nunca `down -v` | o log é a única evidência; `-v` apaga o banco |

O build que morreu no meio **não** deixa migração pela metade por si só: migration roda
no boot do processo, e um build que não produziu imagem não produziu boot.

### O que NÃO fazer num deploy interrompido

* `docker compose down -v` — os dois volumes nomeados são o `live.db` e o histórico de
  backup no mesmo golpe (`game-data` + `game-backups`; por isso o §log do cabeçalho de
  `deploy/docker-compose.yml` existe).
* `docker image prune -a` / `docker system prune -af` — são literalmente a remoção do
  caminho de volta: as tags antigas não estão em registry nenhum, estão só aqui.
* `docker compose pull <serviço buildado>` — com `pull_policy: never` o compose recusa;
  sem ele, você ia ao Docker Hub atrás de `shambleta/game`.
* `docker compose build` sem `SHAMBLETA_TAG` exportado — produz
  `shambleta/<svc>:local-unpinned`, um build que você não consegue nomear depois.

### Migration aplicada pela metade: qual é o sinal

O apply é **fail-closed e carimba patch a patch**: `SQL.ApplyMigrations()` só avança
`migration.version` depois que aquele patch virou schema, e para o boot no primeiro
falho com a linha

```
SQL: migration <arquivo> (patch <N> de <M>) FALHOU: <motivo> — a base para na versão <V> e nada além dela é estampado.
```

Isso dá ao operador três coisas que a frase "o número está certo" nunca deu:

1. **A diferença entre o carimbo e o que o binário traz** é a grandeza, não o log.
   `shambleta_schema_version` contra `shambleta_migration_patches_visible`: patches
   visíveis > versão gravada é exatamente o caso "tem patch que não virou schema" — e
   o `shambleta_migration_stalled` já resolve a comparação no server. Os dois alertas
   que paginam sobre isso estão em `deploy/alerts.rules.yml` (`MigrationFalhou`,
   `SchemaAtrasadoVsBinario`, e `SchemaSemMedida` para a base sem carimbo nenhum).
   Ler direto da fonte, dentro do host:
   `docker compose exec game curl -fsS http://127.0.0.1:9400/metrics | grep -E "shambleta_schema_version|shambleta_migration_"`
2. **A repetição é segura**: o que passou ficou marcado e não reaplica; o que falhou
   fica para trás e roda de novo na próxima subida do **mesmo** build. Reiniciar o
   `game` com o mesmo `SHAMBLETA_TAG` é o retry correto — não um `up -d` com outro
   tag, e nunca com `--no-build` apontando para um binário mais velho (§fronteira).
3. **O `/healthz` recusa junto — e mesmo assim a métrica é o sinal.** A decisão está em
   `ServingFor()` (`sources/system/MetricsServer.gd:@ServingFor`): com o flag parado ela devolve
   falso, o `/healthz` responde 503 e o healthcheck do
   `services.game` (`deploy/docker-compose.yml:@services.game`) marca o container como não
   saudável. Antes
   desta alavanca o probe media só o processo de pé, e um boot parado num patch ficava
   verde: o cliente autenticava e morria na primeira RPC que tocasse a tabela ausente.
   Hoje a mesma flag fecha a porta de entrada antes do teto de conexões — o motivo é
   `schema_blocked` (`ReasonSchema` em `sources/network/server/Admission.gd:@ReasonSchema`), entregue à porta por
   `_ValidateAuth()` (`sources/network/server/Server.gd:@_ValidateAuth`), que lê
   `MigrationBlocked()` (`sources/sql/SQL.gd:@MigrationBlocked`). Os dois lados do flag, a precedência
   sobre o teto e essa fiação viva são medidos em S5 (`tests/admission_gate_test.gd:691-796`),
   sobre WebSocket de verdade. O que o probe continua sem dizer é QUAL patch falhou e
   contra qual carimbo o binário está: isso só o log e a métrica acima dizem, e é por
   isso que o alerta é `shambleta_migration_stalled` e não o healthcheck.

Se você precisa da resposta sem o server no ar (deploy morto antes do boot, ou o
`/metrics` inalcançável), o par externo é o mesmo: a versão da base contra os patches
do commit que você pisou.

```bash
# versão da base, read-only pela imagem do companion (a do game não tem sqlite3:
# deploy/server/Dockerfile:27 acrescenta só ca-certificates e curl ao
# debian:bookworm-slim)
docker compose -f deploy/docker-compose.yml run --rm --no-deps \
  --entrypoint python3 companion -c \
  'import sqlite3;c=sqlite3.connect("file:/data/.local/share/Shambleta/live.db?mode=ro",uri=True);print("version",c.execute("SELECT version FROM migration").fetchone()[0])'

# quantos patches aquele commit trazia
git -C <repo> ls-tree -r --name-only <sha-deployado> -- data/conf/migrations | grep -c '\.sql$'
```

Os dois números iguais = apply completo. Base **abaixo** dos patches do build = ou o
boot parou num patch (procure a linha `SQL: migration` no log) ou o processo nem
chegou a rodar. Base **acima** = binário mais velho que o schema, que é o estado do
§fronteira e não um estado de retry.

## Incidentes Comuns

### Servidor não inicia

1. Verificar logs: `docker compose logs game`
2. Verificar se `credential.cfg` está montado corretamente
3. Verificar se o volume `/data` está íntegro
4. Verificar **qual tag está no ar** (§"Ver o que está no ar agora"): um container
   criado com `local-unpinned` num host que tem a tag boa é um deploy que esqueceu o
   knob, e o sintoma pode ser o fonte que você achou que tinha descartado

### Webhooks falhando

1. Verificar `SHAMBLETA_WEBHOOK_SECRET`
2. Verificar logs do companion: `docker compose logs companion`
3. Verificar `grant_queue` no banco: `SELECT id, account_id, kind, amount, created_at FROM grant_queue WHERE status = 'pending' ORDER BY id LIMIT 10;`
   — a coluna de estado é `status` (`pending` → `processing` → `processed|failed|refunded`,
   `data/conf/migrations/015_grant_queue.sql:4-14`), e o timestamp de entrada é
   `created_at`. **Não existe `granted_at` em `grant_queue`**: essa coluna é de
   `cosmetic_grant` (`data/conf/migrations/023_season_pass.sql:25-32`), e a query
   que estava aqui devolvia `no such column: granted_at` — que é exatamente o
   erro que te faz procurar webhook onde o webhook nunca chegou.

### Alta latência

1. Verificar CPU/memória dos containers: `docker stats`
2. Ler o `/metrics` do `game` pelo lado de dentro: `docker compose exec game curl -fsS http://127.0.0.1:9400/metrics`. A lista do que existe é o próprio corpo (as linhas `# HELP`). O que cada família mede, com o bloco que a emite — as sete famílias abaixo saem todas de `MetricsBody` (`sources/system/MetricsServer.gd:@MetricsBody`), e é o bloco que a citação aponta, não a linha, porque a função cresce e as sete faixas apodreceriam juntas:

   - processo: `shambleta_up`, `shambleta_uptime_seconds` — no bloco `MetricsBody` (`sources/system/MetricsServer.gd:@MetricsBody`)
   - mundo: `shambleta_players_online`, `shambleta_accounts_logged_in` — no bloco `MetricsBody` (`sources/system/MetricsServer.gd:@MetricsBody`)
   - fila de dinheiro: `shambleta_grant_queue_pending`, `shambleta_grant_queue_failed`, `shambleta_grant_queue_refunded` — no bloco `MetricsBody` (`sources/system/MetricsServer.gd:@MetricsBody`)
   - reconcile e fraude: `shambleta_reconcile_divergences`, `shambleta_reconcile_age_seconds`, `shambleta_fraud_flags_open` — no bloco `MetricsBody` (`sources/system/MetricsServer.gd:@MetricsBody`)
   - espera da `queryMutex`: `shambleta_sql_query_mutex_waits`, `shambleta_sql_query_mutex_wait_seconds`, `shambleta_sql_query_mutex_wait_max_seconds` — no bloco `MetricsBody` (`sources/system/MetricsServer.gd:@MetricsBody`)
   - caudas da mutex: `shambleta_sql_query_mutex_wait_over_1ms`, `shambleta_sql_query_mutex_wait_over_10ms`, `shambleta_sql_query_mutex_wait_over_100ms` — no bloco `MetricsBody` (`sources/system/MetricsServer.gd:@MetricsBody`)
   - migrations: `shambleta_schema_version`, `shambleta_migration_patches_visible`, `shambleta_migration_stalled` — no bloco `MetricsBody` (`sources/system/MetricsServer.gd:@MetricsBody`)

   As séries de espera da `queryMutex` acima são o que a frase original desta linha negava existir; a negação era **falsa** e foi retirada (o gate de CI quebra qualquer doc que volte a negá-la): quem a leu no meio de um incêndio procurou uma grandeza que o server publica e concluiu que a observação não existia. O alerta que pagina sobre a cauda de 100 ms é `QueryMutexTravando` (`deploy/alerts.rules.yml:134`), e a régua de leitura está em `deploy/OPS_RUNBOOK.md`. Se a fila de grants é que está presa, o sinal continua sendo `shambleta_grant_queue_pending` crescendo — as duas coisas são filas diferentes e agora as duas têm métrica.
3. Considerar reduzir `MaxPlayerCount`

### Erros de TLS

1. Verificar se `SHAMBLETA_PROXY_TLS=1` está setado
2. Verificar certificados do proxy (Coolify/Cloudflare)
3. Verificar logs do nginx: `docker compose logs web`
4. **Se o sintoma for "servidor no ar, mas nenhum cliente loga"** (só desktop/ENet;
   o build Web continuando ok): desde a passada de beta o cliente **rejeita** cadeia
   inválida ou hostname que não bate com o certificado (`NetworkCommons.ClientTLSOptions()`
   em `sources/network/client/Client.gd` — âncora = store de CA do sistema passada
   explicitamente; se `OS.get_system_ca_certificates()` vier vazio no ambiente do
   cliente, a verificação não tem com o que ancorar e a conexão cai por isso, não por
   certificado ruim). Confirme que a entrada que atende
   `wss://<ServerAddress>:6108` serve certificado **emitido por CA pública e válido
   para exatamente esse hostname** — não um `--self-signed` de `provision_tls.sh`.
   O erro aparece no log do cliente como falha de conexão/TLS, nunca como ban.
   A correção é no certificado da borda; afrouxar o cliente de volta reabre o
   buraco de credencial (ver `deploy/TLS.md`, "Client-side verification").

## Contatos

- **On-call:** consulte `LAUNCH_HANDOFF.md`
- **Sentry:** dashboard do projeto
- **Coolify:** painel de deploy
