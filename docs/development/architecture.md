# Arquitetura

## Visão Geral

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CAMADA DE APLICAÇÃO                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │   CLIENTE    │  │   SERVIDOR   │  │      COMPANION           │  │
│  │   Godot 4.7  │  │  Godot 4.7   │  │   Python 3.12            │  │
│  │   (Desktop,  │  │  (Headless)  │  │   (Webhook Boundary)     │  │
│  │  Mobile, Web)│  │              │  │                          │  │
│  └──────┬───────┘  └──────┬───────┘  └───────────┬──────────────┘  │
│         │                  │                       │                  │
│    ENet/WebSocket/        │                 HTTP (8901)             │
│    WebRTC (RPC)           │                  Webhooks                 │
│         │                  │                       │                  │
└─────────┼──────────────────┼───────────────────────┼──────────────────┘
          │                  │                       │
          └──────────────────┼───────────────────────┘
                             │
                    ┌────────▼────────┐
                    │   SQLite WAL    │
                    │   (live.db)     │
                    └─────────────────┘
```

## Componentes Principais

### Launcher / FSM

`Launcher.gd` gerencia lifecycle dos serviços. `FSM.gd` implementa máquina de estados do launcher (LOGIN_SCREEN → IN_GAME).

### Autoloads (o que realmente existe em `project.godot`)

Seis, e só estes: `FSM`, `Launcher`, `Monitoring`, `Network`, `PwaUpdate`,
`WebPush`.
<!-- DRIFT autoload_names FSM,Launcher,Monitoring,Network,PwaUpdate,WebPush -->
<!-- DRIFT autoload_count 6 -->
Os dois últimos existem por um motivo concreto: `WebPush` fala com o serviço de
push do navegador e `PwaUpdate` pulsa `postMessage("update")` no worker do engine,
sem o qual um deploy novo só assumiria quando o jogador fechasse a aba. Os dois
ficam sem `class_name` de propósito — o nome do autoload já é o global, e declarar
`class_name` homônimo esconde o autoload e quebra o parse estrito. Todo o
restante é classe global por `class_name` (`Util`, `NetworkCommons`, `OnlineList`,
`SQLCommons`, `EconomyCatalog`, …) ou serviço composto dentro do `Launcher`
(`Launcher.SQL`, `Launcher.Economy`, `Launcher.World`). Registrar um `RefCounted`
como autoload não funciona no Godot 4 — foi exatamente isso que derrubou a
tentativa de fragmentação do `Network` (ver abaixo).

### Network

| Arquivo | Papel |
|---|---|
| `sources/network/Network.gd` | Nó autoload: dispatcher (`CallServer`/`CallClient`/`Bulk`/`Notify*`), transporte (`ENet`, `WebSocket`, `WebRTC`), sinais **e os `@rpc`** <!-- DRIFT rpc_total 224 20 --> |
| `sources/network/server/Server.gd` | Autoridade: sessão, mundo, economia, chat, guild, torneios |
| `sources/network/client/Client.gd` | Lado do cliente |
| `sources/network/NetworkCommons.gd` | Constantes de protocolo + `ComputeProtocolVersion(network)` — hash dos `@rpc` do nó, usado no handshake |
| `sources/network/server/` | `Peers.gd`, `OnlineList.gd` (metade quente da presença), `Presence.gd` (metade durável: `presence_session`, migration 057, heartbeat/poda/TTL), `ChatModeration.gd` (mute/denúncia), `EmailService.gd` |
| `sources/network/Interface.gd` | `class_name NetInterface` |

A coluna de linhas saiu daqui de propósito, pela mesma razão declarada na §SQL:
contagem de linha apodrece em dias e o teto real é medido no run por
`scripts/check_god_nodes.sh`.

**Não existe** `NetworkAuth.gd`/`NetworkSocial.gd`/`NetworkCharacter.gd`/
`NetworkCombat.gd`/`NetworkEconomy.gd`/`NetworkGuild.gd`. O P4 (2026-09) fragmentou
`Network.gd` nesses seis módulos registrados como autoload; a tentativa foi
revertida: `RefCounted` não vira autoload no Godot 4 e os `class_name` colidiam com
os nomes globais, travando a compilação de tudo que tocava rede. As docs antigas
descreviam a fragmentação como concluída — ver `ROADMAP_COMERCIAL.md` §S3 e
`archive/AUDITORIA_INDEPENDENTE_2026-09-24.md` §20.

**Transportes**: `ENet` (UDP), `WebSocket`, `WebRTC` (web). Canais: `CONNECT`, `ACTION`, `MAP`, `MAP_UNRELIABLE`, `NAVIGATION`, `NAVIGATION_UNRELIABLE`, `ENTITY`, `ENTITY_UNRELIABLE`, `BULK`.

### Idle Engine

- `IdlePolicy` — cérebro de farm por jogador: um `Tick` por passo de física,
  decisões em subpassos de 0,25 s de jogo (máximo 2 s de catch-up).
- **O agrupamento por zona é a lista da instância, e só.** `WorldInstance` mantém
  `idlePolicies` — a lista das políticas daquela zona — e o `_physics_process` dá
  um `Tick` por entrada ali. Uma política por jogador, anexada à instância da zona
  dele. Não há objeto intermédio: a `ZonePolicy`, anunciada aqui como "batching
  O(1) por zona", foi **removida em 2026-09-27** porque o batching que ela
  anuncia não existia — nenhum código em `sources/` ou `tests/` chamava o seu
  `AttachPolicy`, o array que deveria agrupar as políticas estava sempre vazio, e
  o `Tick` dela só repassava ao `super.Tick` depois de varrer esse vazio. O custo
  medido (mesmo instrumento de `tests/perf_baseline.gd`, máquina ociosa):
  10,09 µs e 2 objetos por attach, contra 3,36 µs e 1 objeto na forma direta —
  porque o attach alocava a segunda política por cima da que já tinha criado — e
  +0,1244 µs por tick de dispatch morto, ~1,5 ms/s de CPU com 200 farmers a 60 Hz.
  O que é O(1) por zona é a *chegada* à lista (o ponteiro da instância); o trabalho
  de decidir alvo continua linear no número de farmers, e é isso que farma
  independente um do outro significa.
- `OfflineSettle` — idempotente via `last_settled_at`

### SQL

`SQL.gd` é o serviço de dados e está na allowlist do gate anti-god-node como
legado consciente, junto com `Server.gd`, `Client.gd`, `Network.gd`,
`WorldCommands.gd` e `companion/server.py`. Números de linha não vão nesta página:
eles apodrecem em dias e o teto real é medido no próprio run por
`scripts/check_god_nodes.sh`. Ao lado dele, em `sources/sql/`: `SQLCommons.gd`
(constantes/caminho de DB), `SQLBackups.gd` (worker de backup + rotação do meta
game), `SQLReadPool.gd` + `SQLReadRules.gd` (conexões só-leitura do WAL fora do
`queryMutex`, e o decisor puro que decide o que pode ser lito por elas) e
`SQLSecurity.gd` (contador persistido de tentativas de auth — o que o `SQL.gd`,
congelado, não podia hospedar). Os dez módulos de domínio que esta página listava
(`SQLMigration`, `SQLAccount`, `SQLCharacter`, `SQLStats`, `SQLInventory`,
`SQLEquipment`, `SQLProgress`, `SQLEconomy`, `SQLBan`, `SQLUtils`) foram
**removidos em 2026-09-24**: zero referências em `sources/` e `tests/`, e eram
cópias parciais/stub do que o próprio `SQL.gd` já implementa — mexer neles não
mudava nada e era exatamente o tipo de armadilha que uma hotfix de beta encontra.

**Migrations** (`data/conf/migrations/NNN_*.sql`): `SQL.ApplyMigrations()` endereça
patch por **posição no diretório ordenado** — `migration.version` guarda quantos
patches foram aplicados (`patches[currentVersion]`), não qual arquivo. Consequência
 dura: o número no nome tem que ser denso (001..N, sem buraco) e nunca pode haver
reinserção no meio da sequência, porque ambas as operações mudam qual arquivo cai
em qual índice. Um buraco é fechado renomeando os maiores para baixo (mantém
contagem e ordem, logo nenhum banco re-aplica nada), nunca criando um arquivo novo
no vão. A densidade da sequência e o valor da última migration são medidos pelo
gate `== DOC DRIFT:` contra `data/conf/migrations/` — o número não fica gravado
aqui de propósito: sairia velho no commit seguinte. É por isso que esta linha é um
ponteiro, não uma asserção de valor.
<!-- DRIFT migration_max derivado de data/conf/migrations/ — o gate resolve o máximo; a doc não grava número -->

### Economy

`EconomyService.gd` é a fachada: dono dos mutexes (`settleMutex` global + 8 shards
por `hash(accountID) % EconomyCatalog.SHARD_COUNT`) e dos wrappers que os callers
(RPC do servidor, GUI, testes) sempre enxergaram. Não conto arquivos nem linhas
aqui — número solto em doc é a primeira coisa que mente; o que mede é o gate
`Gate anti-god-node:`. Domínios extraídos por composição com back-reference `_eco`
— mesmo locking, mesma assinatura pública:

`EconomyKernel` (carteira, ledger, ops de item) · `CheckoutService` (grant queue,
VIP, refund) · `SeasonService` · `PassService` · `GuildService` ·
`AuctionHouseService` · `ShopService` · `ItemForgeService` (crafting/sinks) ·
`BossProgressionService` (rebirth/escada/tormento) · `AdsCosmeticsService` ·
`TournamentArenaService` · `CommunityService` (live events, conquistas, referral,
anti-fraude) · `TradeChestService` · `TelemetryService`.

Catálogo puro são dois, cortados por dono de decisão e não por tamanho:
`EconomyCatalog` (o que é contrato entre domínios — shard count, shop day,
catálogo pago, limiares anti-fraude) e `CraftCatalog` (a regra do forjeiro: budget
por (tier, slot), pesos de modifier com a validação fail-closed contra o enum
`Modifier`, bandas de raridade, taxa de submissão, comparação de nome). O segundo
existe porque o primeiro passou do teto de 800 linhas — o teto é o sintoma, a
doença era um ajuste de peso de DoT brigar por contexto com janela de reembolso.
`Storefront` é o espelho do catálogo cobrável que a UI anuncia.

A fronteira de dinheiro não tem módulo GDScript para o webhook: assinatura é
validada no companion (`companion/server.py`, HMAC + re-fetch autoritativo,
fail-closed). A `grant_queue` tem os dois lados: o companion escreve o que o
pagador confirmou, e o servidor do jogo escreve o que ele próprio concedeu —
`EnqueueGrant()` (`CheckoutService.gd:@EnqueueGrant`) insere com `price_paid`/`currency` da migration 044, que
é a coluna que separa dinheiro real de sandbox. Consumir a fila é o que o servidor
faz com o resto.

Ledger append-only (trigger no banco), baús provably-fair com pity, e o catálogo
pago canônico em `data/conf/paid_catalog.json` — a mesma fonte que o companion
cobra e que o servidor valida no boot (`EconomyCatalog.ValidatePaidCatalogFile`).

### Observabilidade

`Monitoring.gd` integra Sentry (opt-in). `MetricsServer.gd` é instanciado pelo
`Launcher` (`Launcher.Metrics`), faz bind de `127.0.0.1:9400` e responde `/healthz` e
`/metrics` — é para essa porta que o healthcheck do Docker aponta; antes de
existir servidor nenhum, o check era permanentemente falso. Leitura por dentro do
container (`docker compose exec game curl 127.0.0.1:9400/healthz`); não é exposta
publicamente.

## Diagrama de Sequência — Login

```
Client                        Server
  |                              |
  |-- LoginWithPassword -------->|  Network.gd:61
  |                              |-- SQL.ValidateAuthPassword      Server.gd:35
  |                              |-- SQLSecurity (backoff/lockout) Server.gd:103
  |<-- AuthError / Token ---------|
  |                              |
  |-- LoginWithToken ------------>|  Network.gd:77
  |                              |-- SQL.ValidateAuthToken         Server.gd:260
  |                              |-- SQL.RefreshAuthToken          Server.gd:267
  |<-- CharacterListing ----------|  Network.gd:160
  |                              |
  |-- ConnectCharacter ----------->|  Network.gd:148 / Server.gd:502
  |<-- WorldInstance -------------|
```
