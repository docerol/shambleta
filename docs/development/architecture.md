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

Cinco, e só estes: `Launcher`, `Network`, `FSM`, `Monitoring`, `WebPush`. Todo o
restante é classe global por `class_name` (`Util`, `NetworkCommons`, `OnlineList`,
`SQLCommons`, `EconomyCatalog`, …) ou serviço composto dentro do `Launcher`
(`Launcher.SQL`, `Launcher.Economy`, `Launcher.World`). Registrar um `RefCounted`
como autoload não funciona no Godot 4 — foi exatamente isso que derrubou a
tentativa de fragmentação do `Network` (ver abaixo).

### Network

| Arquivo | Papel | Linhas |
|---|---|---|
| `sources/network/Network.gd` | Nó autoload: dispatcher (`CallServer`/`CallClient`/`Bulk`/`Notify*`), transporte (`ENet`, `WebSocket`, `WebRTC`), sinais **e os 201 `@rpc`** | 1062 |
| `sources/network/server/Server.gd` | Autoridade: sessão, mundo, economia, chat, guild, torneios | 1468 |
| `sources/network/client/Client.gd` | Lado do cliente | 876 |
| `sources/network/NetworkCommons.gd` | Constantes de protocolo + `ComputeProtocolVersion(network)` — hash dos `@rpc` do nó, usado no handshake | — |
| `sources/network/server/` | `Peers.gd`, `OnlineList.gd`, `ChatModeration.gd` (mute/denúncia), `EmailService.gd` | — |
| `sources/network/Interface.gd` | `class_name NetInterface` | — |

**Não existe** `NetworkAuth.gd`/`NetworkSocial.gd`/`NetworkCharacter.gd`/
`NetworkCombat.gd`/`NetworkEconomy.gd`/`NetworkGuild.gd`. O P4 (2026-09) fragmentou
`Network.gd` nesses seis módulos registrados como autoload; a tentativa foi
revertida: `RefCounted` não vira autoload no Godot 4 e os `class_name` colidiam com
os nomes globais, travando a compilação de tudo que tocava rede. As docs antigas
descreviam a fragmentação como concluída — ver `ROADMAP_COMERCIAL.md` §S3 e
`AUDITORIA_INDEPENDENTE_2026-09-24.md` §20.

**Transportes**: `ENet` (UDP), `WebSocket`, `WebRTC` (web). Canais: `CONNECT`, `ACTION`, `MAP`, `MAP_UNRELIABLE`, `NAVIGATION`, `NAVIGATION_UNRELIABLE`, `ENTITY`, `ENTITY_UNRELIABLE`, `BULK`.

### Idle Engine

- `IdlePolicy` — tick por jogador (0.25s interval, max 2s catch-up)
- `ZonePolicy` — batching O(1) por zona
- `OfflineSettle` — idempotente via `last_settled_at`

### SQL

`SQL.gd` (1267 linhas) é o serviço de dados e está na allowlist do gate
anti-god-node como legado consciente, junto com `Server.gd`, `Client.gd`,
`Network.gd`, `WorldCommands.gd` e `companion/server.py`. Ao lado dele só
`SQLCommons.gd` (constantes/caminho de DB) e `SQLBackups.gd` (worker de backup +
rotação do meta game). Os dez módulos de domínio que esta página listava
(`SQLMigration`, `SQLAccount`, `SQLCharacter`, `SQLStats`, `SQLInventory`,
`SQLEquipment`, `SQLProgress`, `SQLEconomy`, `SQLBan`, `SQLUtils`) foram
**removidos em 2026-09-24**: zero referências em `sources/` e `tests/`, e eram
cópias parciais/stub do que o próprio `SQL.gd` já implementa — mexer neles não
mudava nada e era exatamente o tipo de armadilha que uma hotfix de beta encontra.

### Economy

16 arquivos, ~5.7k linhas em `sources/economy/`. `EconomyService.gd` (778) é a
fachada: dono dos mutexes (`settleMutex` global + 8 shards por
`hash(accountID) % EconomyCatalog.SHARD_COUNT`) e dos wrappers que os callers
(RPC do servidor, GUI, testes) sempre enxergaram. Domínios extraídos por composição
com back-reference `_eco` — mesmo locking, mesma assinatura pública:

`EconomyKernel` (carteira, ledger, ops de item) · `CheckoutService` (grant queue,
VIP, refund) · `SeasonService` · `PassService` · `GuildService` ·
`AuctionHouseService` · `ShopService` · `ItemForgeService` (crafting/sinks) ·
`BossProgressionService` (rebirth/escada/tormento) · `AdsCosmeticsService` ·
`TournamentArenaService` · `CommunityService` (live events, conquistas, referral,
anti-fraude) · `TradeChestService` · `TelemetryService` ·
`EconomyCatalog` (constantes/helpers puros).

A fronteira de dinheiro não tem módulo GDScript: assinatura de webhook é validada
no companion (`companion/server.py`, HMAC + re-fetch autoritativo, fail-closed) e o
servidor do jogo apenas consome a `grant_queue` que esse código escreveu.

Ledger append-only (trigger no banco), baús provably-fair com pity, e o catálogo
pago canônico em `data/conf/paid_catalog.json` — a mesma fonte que o companion
cobra e que o servidor valida no boot (`EconomyCatalog.ValidatePaidCatalogFile`).

### Observabilidade

`Monitoring.gd` integra Sentry (opt-in). `MetricsServer.gd` é instanciado pelo
`Launcher` (`Launcher.Metrics`), faz bind de `127.0.0.1:9400` e responde `/healthz` e
`/metrics` — é para essa porta que o healthcheck do Docker aponta; antes de
existir servidor nenhum, o check era permanentemente falso. Leitura por dentro do
container (`docker compose exec game curl localhost:9400/healthz`); não é exposta
publicamente.

## Diagrama de Sequência — Login

```
Client                        Server
  |                              |
  |-- LoginWithPassword -------->|
  |                              |-- ValidateAuthPassword
  |                              |-- CheckRateLimit
  |<-- AuthError / Token ---------|
  |                              |
  |-- LoginWithToken ------------>|
  |                              |-- ValidateSession
  |<-- CharacterList ------------|
  |                              |
  |-- SelectCharacter ----------->|
  |<-- WorldInstance -------------|
```
