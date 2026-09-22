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

### Network (Fragmentado — P4 / 2026-09)

`Network.gd` agora atua como **facade pura** (177 linhas, 0 `@rpc`): dispatcher (`CallServer`/`CallClient`/`Bulk`/`Notify*`), transporte (`ENet`, `WebSocket`, `WebRTC`) e sinais. Todos os RPCs foram fragmentados em módulos autocontidos (registrados como `autoload` em `project.godot`):

| Módulo | RPCs principais | Linhas |
|---|---|---|
| `Network.gd` (facade) | `CallServer`, `CallClient`, `Bulk`, `Notify*`, `Mode` | 177 |
| `NetworkAuth.gd` | Auth (`CreateAccount`, `LoginWithPassword`, `2FA`, `Refund`) | 44 |
| `NetworkSocial.gd` | Guild / Social (`GuildState`, `GuildFeedback`) | 22 |
| `NetworkCharacter.gd` | Personagem (`CreateCharacter`, `CharacterInfo`, `ConnectCharacter`) | 33 |
| `NetworkCombat.gd` | Combate / Chat / Contexto (`TriggerSkill`, `TriggerChat`, `Express`) | 36 |
| `NetworkEconomy.gd` | Economia (`OpenChest`, `BuyPass`, `PurchaseVIP`, `GetAchievements`) | 48 |
| `NetworkGuild.gd` | Guild / Torneios (`LevelUpGuildFast`, `EnterTournament`) | 22 |

**Protocolo (`ComputeProtocolVersion`)**: atualizado em `NetworkCommons.gd` (§ Passo 2) para agregar `@rpc` de todos os módulos, não apenas da facade. Isso garante que o handshake (`Server.gd:1355` / `Client.gd:793`) valide corretamente clientes com a versão dos módulos.

**Transportes**: `ENet` (UDP), `WebSocket`, `WebRTC` (web). Canais: `CONNECT`, `ACTION`, `MAP`, `MAP_UNRELIABLE`, `NAVIGATION`, `NAVIGATION_UNRELIABLE`, `ENTITY`, `ENTITY_UNRELIABLE`, `BULK`.

### Idle Engine

- `IdlePolicy` — tick por jogador (0.25s interval, max 2s catch-up)
- `ZonePolicy` — batching O(1) por zona
- `OfflineSettle` — idempotente via `last_settled_at`

### SQL (Fragmentado — P4)

`SQL.gd` atua como facade; módulos por domínio (`SQLMigration`, `SQLAccount`, `SQLCharacter`, `SQLStats`, `SQLInventory`, `SQLEquipment`, `SQLProgress`, `SQLEconomy`, `SQLBan`, `SQLUtils`).

### Economy

`EconomyService` com sharding de mutex (8 shards), ledger append-only, settlement, rebirth.

### Monitoring

`Monitoring.gd` integra Sentry (opt-in). `MetricsServer` expõe `/metrics` e `/healthz` em `127.0.0.1:9400`.

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
