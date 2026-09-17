# BETA DEPLOY — Relatório (Web export + Coolify)

**Data:** 2026-09-11 · **Base:** auditoria de beta (beta fechado, web, GUI mínima)
**Testes:** `== RESULT: 418 checks, 0 failures ==` após os patches desta sessão.

## 1. Primeiro export Web da história do pivô

| Etapa | Resultado |
|---|---|
| Templates 4.7 stable instalados (local, `.test-home/`) | ✓ |
| Export `Web` (preset 5: threads+PWA+Sentry) | ✓ após 1 fix |
| Integridade dos artefatos (refs do index.html) | ✓ todos presentes |

**Fix do bloqueio de export:** o plugin de export do Sentry copia `sentry-bundle.js`
no `export_begin` — se a pasta destino não existe ainda, o export **aborta**
(`Failed to open '../binary/Web/sentry-bundle.js'`). Correção: `mkdir -p` antes
(mitigado no Dockerfile do web e no job de CI).

## 2. Peso do primeiro load (meta < 25 MB gzip)

| Arquivo | gzip | raw |
|---|---|---|
| index.pck | 46.22 MB | 61.14 MB |
| index.side.wasm (engine threads) | 9.99 MB | 41.26 MB |
| libgdsqlite (wasm) | 0.68 MB | 2.40 MB |
| index.wasm + index.js | 0.93 MB | 4.35 MB |
| **Total primeiro load** | **57.8 MB** | **111 MB** |

Excludes aplicados ao preset Web (não-runtime): `data/press/readme|map|web/*`
(−3.7 MB raw). **Próximo alvo:** `data/music` = 26 MB ogg embutidos no pck —
sem ele o load cai para ~33 MB; meta final exige stream/cache PWA de música
(trabalho de AudioService, não aplicado nesta sessão). CI emite warning se
acima de 25 MB.

## 3. Deploy Coolify (`deploy/`)

| Artefato | Papel |
|---|---|
| `deploy/docker-compose.yml` | 3 serviços: `web` (nginx+client), `game` (headless :6108), `companion` (:8901); volume compartilhado `game-data` (SQLite WAL) |
| `deploy/web/Dockerfile` | multi-stage: export Godot → nginx com **COOP/COEP**; ARG `SHAMBLETA_SERVER_ADDRESS` embute o endpoint no pck |
| `deploy/web/nginx.conf` | COOP/COEP em todos os locations + gzip + cache imutável p/ wasm/pck |
| `deploy/server/Dockerfile` | export headless → debian-slim; `HOME=/data` (user:// no volume), `SHAMBLETA_PROXY_TLS=1` |
| `deploy/companion/Dockerfile` | python-slim apontando para o live.db do volume |
| `deploy/COOLIFY.md` | runbook: domínios, credenciais user://, smoke test, webhook assinado, operação |

## 4. Patches de rede para proxy-TLS (Coolify)

- `NetworkCommons`: `ServerAddress`/`WebSocketPort`/`ENetPort` viram `static var`
  configuráveis + flag `ProxyTLS` (env `SHAMBLETA_PROXY_TLS=1`).
- `Launcher._ready`: lê `[Network] Server-Address/Server-Port` do **settings.cfg**
  (via `Conf.Type.SETTINGS` — embarcado no pck do client; `CREDENTIAL` lê
  `user://` e NÃO vai no pck — descoberta de LoadConfig).
- `Client.gd`: em web não-local a URL é `wss://host` **sem porta** (proxy 443);
  desktop mantém `:6108`.
- `Server.gd`: `ProxyTLS` permite bind plain atrás do proxy (o A2 assert só
  dispara sem TLS e sem proxy); log explícito no boot.

## 5. CI

- Novo job `Export Web` (barichello/godot-ci:4.7.1): import + export release +
  medição de peso (warning >25 MB) + artifact `Web`.
- Job `idle-tests` mantido; suíte 418/0 após os patches.

## 6. Correções menores

- `tests/IdleTests.gd:1239`: `%` não escapado em `"buff +4% at..."` quebrava a
  formatação do log (erro de runtime no CI). → `+4%%`.
- Scan de literais `%` em strings de teste: limpo (restantes são SQL sem
  operador de formato).

## 7. Pendências de beta (fora desta sessão)

1. GUI mínima de economia (baús/gems/VIP/leaderboard) + loja de chaves — maior
   lacuna de UX.
2. Stream/cache de música para bater <25 MB.
3. Pacing: par 72/h vs 36/h medidos (recalibrar ou buffar).
4. Formation read-back (v0 write-only).
5. ToS/LGPD no login; zonas 29–40 escondidas; premiação de temporada.
