# Setup do Ambiente de Desenvolvimento

Este guia cobre o setup completo para desenvolver o Shambleta localmente.

## Pré-requisitos

- **Godot 4.7.1** — [download](https://godotengine.org/download)
- **Git**
- **Python 3.12** (opcional, para scripts i18n e companion)
- **Docker + Docker Compose** (opcional, para rodar servidor local)

## Clone e abertura

```bash
git clone https://github.com/shambleta/shambleta.git
cd shambleta
```

Abra o projeto no Godot Editor (`Project -> Import`).

## Import de assets

Na primeira abertura, os assets precisam ser importados:

```
Project -> Tools -> Import
```

Ou via CLI:

```bash
godot --headless --path . --editor --import --quit || true
```

## Rodar cliente (desktop)

No Godot Editor, clique em **Play**. O cliente inicia em modo offline por padrão.

Para conectar a um servidor local:

1. Inicie o servidor headless em outro terminal:
   ```bash
   godot --headless --path . --server
   ```
2. No cliente, o endereço padrão é `som.manasource.org:6108`.
3. Para local, edite `data/conf/settings.cfg`:
   ```ini
   [Network]
   Server-Address=127.0.0.1
   Server-Port=6108
   ```

## Rodar servidor (Docker)

```bash
docker compose up -d game
```

O banco de dados (`live.db`) fica em `game-data:/data`.

## Rodar testes

```bash
./scripts/test.sh all          # todos os testes
./scripts/test.sh quick        # sem sims real-time
./scripts/test.sh idle         # idle tests
./scripts/test.sh backup       # backup restore probe
./scripts/test.sh benchmarks   # performance benchmarks
./scripts/test.sh diag         # pacing diagnosis
./scripts/test.sh clean        # limpa testing.db
```

## Convenções

- **GDScript**: static typing, snake_case, 4 espaços
- **Commits**: Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`)
- **Branches**: `main` (produção), `develop` (staging), `feature/*`

## Notas de Arquitetura (P4 — Fragmentação Network)

`Network.gd` foi fragmentado em módulos (`NetworkAuth`, `NetworkSocial`, `NetworkCharacter`, `NetworkCombat`, `NetworkEconomy`, `NetworkGuild`). A facade (`Network.gd`, 177 linhas) mantém apenas dispatcher, transporte e `Notify*`. Os módulos são registrados como `autoload` no `project.godot`. Veja `docs/development/architecture.md` para detalhes.
