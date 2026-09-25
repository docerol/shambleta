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
./scripts/test.sh all          # todos os testes (5 harnesses Godot + 3 suítes do companion)
./scripts/test.sh quick        # sem sims real-time
./scripts/test.sh idle         # idle tests
./scripts/test.sh backup       # backup restore probe
./scripts/test.sh benchmarks   # performance benchmarks
./scripts/test.sh companion    # fronteira do dinheiro (webhook/segurança/reembolso)
./scripts/test.sh diag         # pacing diagnosis
./scripts/test.sh clean        # limpa testing.db
```

## Convenções

- **GDScript**: static typing, snake_case, **tab** para indentar (292 dos 301
  arquivos; `treat_warnings_as_errors=true`, então um warning no `.gd` quebra o
  build tanto quanto um erro)
- **Commits**: Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`)
- **Branches**: `main` (produção), `develop` (staging), `feature/*`

## Arquitetura de rede

`Network.gd` é um nó autoload único (1062 linhas, 201 `@rpc`) com dispatcher,
transporte e RPCs; do lado do servidor o domínio fica em
`sources/network/server/` (`Server.gd`, `Peers.gd`, `ChatModeration.gd`,
`OnlineList.gd`, `EmailService.gd`) e no cliente em `sources/network/client/Client.gd`.
A versão do protocolo é derivada dos `@rpc` por `NetworkCommons.ComputeProtocolVersion`.
Os autoloads registrados são cinco: `Launcher`, `Network`, `FSM`, `Monitoring`,
`WebPush` — o resto é `class_name` global ou serviço composto no `Launcher`.
Detalhes (e o motivo da fragmentação do P4 ter sido revertida) em
`docs/development/architecture.md`.
