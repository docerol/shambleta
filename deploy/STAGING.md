# Shambleta Staging Environment

## Overview

Staging is a separate Coolify environment that mirrors production but uses:
- Separate volume (`game-data-staging`) — the server always opens `live.db` inside
  whatever it mounts, so isolation is the volume, not the file name
- Sandbox payment provider (`shared`)
- Its own pair of domains (`staging.` + `ws.staging.`), so the baked client endpoint
  is not the production one

Não existe build de staging: as duas imagens são as da produção, com `--export-release
"Web"` e a feature `production` (o override só muda volume, domínios e provider). Uma
linha anterior deste doc prometia "debug build enabled", que nenhum artifacto daqui
produz — o que staging habilita de diferente é o sandbox do companion:
`SHAMBLETA_ALLOW_DEV_WEBHOOK=1` com `provider=shared` liga `--allow-dev`, e
`server.py` deriva disso `allow_dev_checkout` — ou seja, `/checkout/simulate` e a
identidade por username funcionam aqui sem real dinheiro, e é exatamente para isso
que a rota proxied do serviço `web` serve.

## Coolify Setup

1. Create a new **Environment** in Coolify called `staging`
2. Add a new **Service** using the same Docker Compose template as production
3. Override the following environment variables:

```env
# Staging overrides
SHAMBLETA_ALLOW_DEV_WEBHOOK=1
SHAMBLETA_WEBHOOK_PROVIDER=shared
SHAMBLETA_WEBHOOK_SECRET=<staging-secret>
```

Os três acima são lidos em runtime pelo container `companion`. O endereço do jogo
**não** entra aqui por uma razão que já custou um bug de doc: `web` é nginx puro e o
client lê `Server-Address` do `settings.cfg` **gravado dentro do pck pelo build**
(`deploy/web/Dockerfile`, ARG + `sed`). Como variável de ambiente do serviço `web`,
`SHAMBLETA_SERVER_ADDRESS` não faz nada — e era assim que o override estava escrito,
ou seja: o endereço de staging dependia do `SHAMBLETA_SERVER_ADDRESS` que o operator
tivesse no `.env`/aba de ambiente do projeto (é dele que o `${...}` do compose base
interpolate), e não do override. Reaproveitar o env da produção — o que "mesmo
template de produção" convida a fazer — deixava o client de staging apontando para o
game server de produção. Hoje o override fixa `staging.seudominio.com` em
`web.build.args` como literal, e a suíte amarra os dois arquivos
(`SuiteDeployMode`).

4. Use o mesmo par de domínios da produção, com o prefixo de staging:
   `staging.seudominio.com` (serviço `web`) e `ws.staging.seudominio.com` (serviço
   `game`, porta 6108 do container, TLS terminada no proxy). Não é capricho: o
   client web ignora a porta e monta `wss://<Server-Address>` na 443, e o nginx do
   `web` não faz upgrade de WebSocket — um endereço só faria o client de staging
   receber o próprio `index.html` no lugar do handshake.
5. Use um volume de banco separado (`game-data-staging`)

Staging is not a code mode: the server only knows testing vs production
(`LauncherCommons.IsTesting` reads the `production` feature and
`SHAMBLETA_PRODUCTION`, and the base `docker-compose.yml` sets that one as a literal
precisely so an absent env cannot turn it off). Staging therefore inherits
`SHAMBLETA_PRODUCTION: "1"` — same `live.db`, same port 6108 — and is made staging by
its own volume, its own domain and the sandbox webhook provider. There is
deliberately no `SHAMBLETA_ENV`: nothing reads it, and a second switch for "which
database" is the same class of ambiguity that made the beta's release build open
`testing.db` while the companion wrote paid grants into `live.db` (D1).

## Docker Compose Override

`deploy/docker-compose.staging.yml` já está no repositório — ele é a fonte, e não há
cópia dele aqui de propósito: a versão anterior deste doc omitia os dois redirects de
volume, que são justamente o que mantém `game` e `companion` no mesmo SQLite.

```bash
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.staging.yml config
```

O override só faz três coisas: redireciona `game` **e** `companion` para
`game-data-staging`, aponta o endereço público para o domínio de staging e liga o
webhook sandbox. Nada nele muda o modo do servidor — `SHAMBLETA_PRODUCTION: "1"` é
literal no compose base e continua valendo em staging.

## CI Pipeline

`.github/workflows/staging.yml` já existe (push em `develop` → `POST` na API de
deploy do Coolify com `vars.COOLIFY_STAGING_URL` + `secrets.COOLIFY_STAGING_TOKEN`).
Configurar os dois no repositório é o passo pendente, não escrever o arquivo.

## Database

- Filename is `live.db` in every non-testing build, staging included — what makes
  staging a separate database is the separate volume (`game-data-staging`)
- A fresh volume self-bootstraps: `SQL` copies `data/conf/templates/sqlite.template.db`
  into the missing `live.db` and then runs `ApplyMigrations()` over the 45 versioned
  migrations in `data/conf/migrations/`. There is no seed SQL file to load and no
  import step to remember — the schema and its seeds are the migrations
- That first-boot path was measured on 2026-09-24 rather than assumed, because
  `ApplyMigrations()` treats the *array index* as the schema version: `DirAccess`
  returns the patch names sorted (001..046 on a filesystem whose raw readdir order is
  not sorted), applying 002→046 over the shipped template is clean, and it lands the
  same schema as a long-lived development database (53 tables, 1 view, 362
  `table.column` pairs, `version = 46`). `Query()` returns a result set, not a status,
  so a failing migration is reported by the SQLite addon's own log line
  (`verbosity_level = NORMAL` at boot) and not by the version counter — a half-built
  schema would show up in the container log, which is what makes
  `docker compose logs game` the first place to look on a fresh staging boot. The
  contiguity/ordering contract is guarded in `SuiteOpsA2`.
- Content that appears on a new server is seeded by code, not by data: the live-event
  calendar (`LiveEventSeed`), zone mob variants, and the S1 season once
  `SHAMBLETA_ENABLE_SEASONS` is set (it ships set in the base compose). Auction bots
  stay off (`SHAMBLETA_AH_BOTS` unset) for the beta
- Resetting staging is a manual, explicit act: stop the service, delete `live.db`
  (and `sql-backups/`) from the volume, start it. Nothing resets it on a schedule —
  there is no cron in this repository, and a database that wipes itself nightly is
  not something to discover during a beta

## Testing

Staging is used for:
- QA of new features before production
- Payment flow testing (sandbox)
- Performance testing under realistic load
- Regression testing

## Access

- Web (client + landing): https://staging.seudominio.com
- Game: wss://ws.staging.seudominio.com (443, TLS no proxy; o client web nem chega a
  usar a porta — `Client.gd` monta o URL sem sufixo no browser)
- Companion: **sem URL próprio**, e sem porta publicada. A entrada dele é a mesma
  origem do web: `https://staging.seudominio.com/checkout/{intents,preference,
  simulate}` (o client) e `/webhooks/payments` (o provedor), proxied para
  `companion:8901` na rede interna por `deploy/web/nginx.conf`. A linha anterior
  deste doc prometia `https://staging.seudominio.com:8901`, que nenhum artefato
  deste repositório expõe.

## Notes

- Nunca use credenciais de pagamento de produção em staging
- Backups rodam na cadência do próprio processo (diário + semanal + mensal, retenção
  7/4/12) e o offsite é best-effort quando `SHAMBLETA_OFFSITE_BACKUPS` aponta para uma
  montagem persistente; cada backup é verificado com restore probe.
  Ver `sources/sql/SQLBackups.gd` e `tests/test_backup_restore.gd`
- TLS termina no proxy do Coolify (ou no túnel do cloudflared): o `game` binda
  `ws://` plain na 6108 com `SHAMBLETA_PROXY_TLS=1`. O `healthcheck` do compose é um
  GET real em `http://localhost:9400/healthz` (loopback, plain) servido pelo próprio
  processo do jogo — ver `deploy/COOLIFY.md`
- **O cliente verifica o certificado do servidor** (`sources/network/client/Client.gd`,
  via `NetworkCommons.ClientTLSOptions()`). Antes era `TLSOptions.client_unsafe()`,
  que desligava cadeia e hostname no mesmo canal por onde passam senha, token de
  "lembrar" e o código 2FA. `ClientTLSOptions()` passa explicitamente o bundle do
  `OS.get_system_ca_certificates()` como âncora, porque nesta engine (Godot 4.7.2 /
  mbedtls) o caminho sem argumento — `TLSOptions.client()` puro — morre antes do
  handshake com `SSL module failed to initialize!` (`-0x6C00`); a âncora explícita é
  o que faz a verificação funcionar de verdade. Números e método da medição em
  `deploy/TLS.md`. Consequência prática para este deploy: nenhuma — o proxy Coolify /
  o túnel cloudflared apresenta certificado emitido por CA pública, e a cadeia é
  validada contra a store de CA do sistema do cliente (ou contra a pilha TLS do
  browser no export Web). O hostname conferido é o do URL (`wss://<host>`), não um
  parâmetro.
  Onde isto **quebra**: apontar um cliente direto para `create_server(..., tlsOptions)`
  com `user://server.crt`/`server.key` autoassinados (`NetworkCommons.ServerCertPath`,
  o ramo não-`ProxyTLS` de `sources/network/server/Server.gd`). A conexão passa a
  falhar com erro de cadeia (`-0x2700`/`-0x7180` na medição) — que é o comportamento
  correto; para testar esse bind é preciso emitir por uma CA confiável (ou instalar a
  CA própria no sistema que roda o cliente), não afrouxar o cliente de volta. Bind
  local de dev não é afetado: o URL é `ws://` plain e o Godot ignora as opções TLS.
- Deploy confirmado estável quando: `service_healthy` (não apenas `service_started`) para `web` → `game`
