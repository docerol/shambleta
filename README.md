# Shambleta

![screenshot](data/press/readme/header.png)

**Shambleta** is a server-authoritative idle RPG with offline progression, built with Godot 4. The project is open source and welcomes contributions.

## About the Project

**Engine:** Godot 4.7.1 (client and server) — the pin is
`.github/workflows/godot-ci.yml:8` + `GODOT_VERSION`, the `barichello/godot-ci:4.7.1`
images in `.github/workflows/`, `deploy/server/Dockerfile` and `deploy/web/Dockerfile`.
Where a runbook says "medido em Godot 4.7.2" (`deploy/OPS_RUNBOOK.md`,
`deploy/TLS.md`), that is the local binary the measurement ran on, not the pinned
engine — the divergence is tracked, not denied.

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
cd deploy && docker compose up -d
```

See [deploy/COOLIFY.md](deploy/COOLIFY.md) for the full deployment guide.

### Run Locally (Desktop)

1. Open the project in Godot 4.7.1
2. Import assets (`Project → Tools → Import`)
3. Run the main scene (F5)

The server starts automatically in debug builds. Keyboard bindings exist and are
live: `_input()` in `Action.gd:@_input` dispatches the project's `ui_*` actions (declared in
`project.godot`), so `F1` opens the menu, `F2`/`F4`/`F5` open the character hub,
`F3` inventory, `F6` minimap, `F7` chat, `F8` emote, `F9` social, `F10` settings
and `F11` fullscreen — the four game-state-only ones are gated on the same line
they are read. `F12` is the exception: it is a raw key, not an action, because the
`ui_f10` action it used to call never existed (`_input()` in `sources/gui/Gui.gd:@_input` explains
why it moved off `F10`). None of these keys exist on web or mobile, so every window
is also reachable by tap: the on-screen `Menu` indicator (`_on_button_pressed()` in `MenuIndicator.gd:63`)
opens the 17 `WindowButton` icons declared in `presets/gui/Game.tscn` (Stat,
Inventory, Skill, Minimap, Chat, Emote, Social, Settings, ZoneMap, Formation, AFK,
Chests, Shop, Leaderboard, SeasonPass, Cosmetics, Boss), and the idle HUD that `F12`
toggles got its own button because it had no other caller (`Build()` in `ManualHudBar.gd:@Build`).

## Architecture

- **Server-authoritative:** The server owns all state; the client is a thin renderer.
- **SQLite WAL:** Single-file database with write-ahead logging for crash safety.
- **Migrations:** Versioned schema migrations (no raw ALTER in production).
- **Network:** ENet, WebSocket, and WebRTC transports with a unified RPC layer.
- **Idle engine:** `IdlePolicy` ticks at physics FPS; offline settle is idempotent via `last_settled_at`.

Current docs live in [`docs/`](docs/) (`docs/development/architecture.md`,
`docs/development/setup.md`, `docs/development/testing.md`,
`docs/development/debugging.md`, plus the `docs/adding-a-*.md` recipes — item,
quest, skill, zone), the commercial plan in
[`ROADMAP_COMERCIAL.md`](ROADMAP_COMERCIAL.md), and the historical design record —
architecture, economy study, monetization, battle pass, season activation notes — in
[`archive/`](archive/).

## Tests

```bash
./scripts/test.sh all     # todos os harnesses headless, cada um pelo gate da CI
./scripts/test.sh idle    # suíte idle (XP curve, settle, ledger, guild, seasons, rebirth)
```

Quantos harnesses existem não vai escrito aqui: `scripts/test.sh` **deriva** a
lista — os nomes em `EXPLICIT_HARNESSES` mais todo `tests/*_test.gd` /
`tests/*_fuzz.gd`, auto-inscrito por nome (`harnesses_extra()`), e o `preflight`
imprime o total a cada run. Um harness novo entra no portão sozinho, sem edição de
doc. CI roda o mesmo script em todo push — `idle-tests`, `backup-restore`,
`benchmarks`, `companion-tests` e `code-health` (os 11 gates de estrutura: god-node, doc drift, compose, secrets, CI, dead code,
untracked, gate-log, boot-sandbox, gate-marker e write-funnel) — sempre através de `scripts/ci_gate_log.sh`: exit
code sozinho não aprova nada. A contagem não é decorativa: toda prosa que afirma
quantos gates de estrutura existem é conferida contra `structure_gates()` pela
régua de registro de `scripts/check_doc_drift.sh`. Ver
[docs/development/testing.md](docs/development/testing.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

- **Code:** MIT License
- **Art & Design:** CC BY-SA 4.0

See [LICENSE.md](LICENSE.md) for full details and asset credits.
