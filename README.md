# Shambleta

![screenshot](data/press/readme/header.png)

**Shambleta** is a server-authoritative idle RPG with offline progression, built with Godot 4. The project is open source and welcomes contributions.

## About the Project

**Engine:** Godot 4.7.1 (client and server)

**Design Tools:**
- Game editor: [Godot 4.7.1](https://godotengine.org/)
- Level editor: [Tiled 1.11.2](https://www.mapeditor.org/)

**Origins:** A fork of the Source of Mana (`docerol/sourceofmana`) community project. **Shambleta** (this project) has since pivoted to an idle-first design with commercial launch features.

**Goal:** A polished idle RPG with payment integration, cosmetics, seasons, and guild play.

**Platforms:** Desktop (Windows, macOS, Linux), Mobile (Android), and Web (HTML5/WebAssembly)

## Gameplay Highlights

- **Idle progression:** Your character farms gold and XP even when offline
- **Offline settle:** Come back to accumulated rewards based on session efficiency
- **Boss ladder:** Fight increasingly difficult bosses for chests and keys
- **Rebirth system:** Prestige mechanic with permanent bonuses (essence + favours)
- **Guild play:** Create or join guilds, deposit items, level up together
- **Economy:** Gems (premium), gold, items with lot-tracking, trade, and auction house
- **Season pass:** Daily/weekly missions with premium rewards
- **VIP status:** Idle faucet multiplier and extended offline caps
- **Combat:** Elemental weaknesses, auto-combat, skills, and equipment

## Screenshots

![exploration](data/press/readme/exploration.png)
![combat](data/press/readme/combat.png)
![dialogue](data/press/readme/dialogue.png)

## Quick Start

### Play (Web)

No installation needed — play directly in your browser at the project's web domain.

### Run Server (Docker)

```bash
docker compose up -d
```

See [deploy/COOLIFY.md](deploy/COOLIFY.md) for the full deployment guide.

### Run Locally (Desktop)

1. Open the project in Godot 4.7.1
2. Import assets (`Project → Tools → Import`)
3. Run the main scene (F5)

The server starts automatically in debug builds. Use `F1`–`F12` for UI shortcuts.

## Architecture

- **Server-authoritative:** The server owns all state; the client is a thin renderer.
- **SQLite WAL:** Single-file database with write-ahead logging for crash safety.
- **Migrations:** Versioned schema migrations (no raw ALTER in production).
- **Network:** ENet, WebSocket, and WebRTC transports with a unified RPC layer.
- **Idle engine:** `IdlePolicy` ticks at physics FPS; offline settle is idempotent via `last_settled_at`.

Current docs live in [`docs/`](docs/) (`development/architecture.md`, `setup.md`,
`testing.md`, `debugging.md`, plus the `adding-a-*.md` recipes), the commercial plan in
[`ROADMAP_COMERCIAL.md`](ROADMAP_COMERCIAL.md), and the historical design record —
architecture, economy study, monetization, battle pass, season activation notes — in
[`archive/`](archive/).

## Tests

```bash
./scripts/test.sh all     # os cinco harnesses headless, cada um pelo gate da CI
./scripts/test.sh idle    # suíte idle (XP curve, settle, ledger, guild, seasons, rebirth)
```

CI roda os cinco em todo push (`idle-tests`, `backup-restore`, `benchmarks` e os
jobs de `companion/`), sempre através de `scripts/ci_gate_log.sh` — exit code sozinho
não aprova nada. Ver [docs/development/testing.md](docs/development/testing.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

- **Code:** MIT License
- **Art & Design:** CC BY-SA 4.0

See [LICENSE.md](LICENSE.md) for full details and asset credits.
