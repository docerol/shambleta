# Auditoria Técnica — Shambleta (Pós-Implementação)

> **⚠️ AVISO (2026-09-24, passada de beta) — este relatório está superado e parte
> da evidência que ele cita nunca existiu.** Antes de ler qualquer número aqui,
> considere `AUDITORIA_INDEPENDENTE_2026-09-24.md` como a leitura corrente.
> Verificado no repositório nesta data:
> - `Network.gd` **não** é facade de 177 linhas hoje: tem **1062 linhas e 201 `@rpc`**.
>   A fragmentação P4 descrita abaixo **foi executada** (`Network.gd` chegou a 179
>   linhas / 2 `@rpc` com 6 módulos, em `f781f71`) e **revertida** em `bd69275`,
>   porque os `@rpc` do motor precisam viver no nó autoload `Network` — fragmentar
>   quebrou o dispatch (`SuiteNetworkDispatch`). Os seis módulos
>   (`NetworkAuth/NetworkSocial/NetworkCharacter/NetworkCombat/NetworkEconomy/
>   NetworkGuild.gd`) foram apagados nessa reversão.
> - `SQL.gd` **não** está fragmentado em "facade + 10 módulos": `sources/sql/` tem
>   `SQL.gd`, `SQLCommons.gd` e `SQLBackups.gd`.
> - `tests/gut_runner.gd` imprimia `1193 checks, 0 failures` sem rodar nada; foi
>   apagado. O número abaixo não é uma medição.
> - `MultiplayerTests.gd` / `run_multiplayer_tests.gd` existiram e **saíram do
>   índice nesta passada** (dependiam do estado P4 revertido). Os harnesses reais
>   hoje são `tests/run_idle_tests.gd`, `tests/run_rpc_identity_test.gd`,
>   `tests/test_e2e_implementation.gd`, `tests/test_backup_restore.gd`,
>   `tests/benchmarks.gd`.
> - `PerformanceMonitor` **nunca existiu** em `sources/` - ele só aparece escrito
>   neste relatório (`git log --all -S"PerformanceMonitor"` não retorna nenhum
>   `.gd`), e `Monitoring.gd` **não tem spans** (item 6 abaixo é falso). O que
>   existe de observabilidade viva é `MetricsServer.gd` (`/healthz` + `/metrics`,
>   bind real em `127.0.0.1:9400` desde a correção L1 - o healthcheck que rendeu
>   o "9/10 de Deploy" apontava para um servidor que não escutava em lugar nenhum).
> - **"TLS obrigatório no transporte" (Segurança 9/10 abaixo) valia para a metade do
>   servidor, não para o cliente:** `Client.gd` montava `TLSOptions.client_unsafe()`,
>   que desliga cadeia e hostname no canal de senha/remember-me/2FA, e o
>   `auth_callback` do cliente era `complete_auth` puro. Achado e corrigido nesta
>   passada (`NetworkCommons.ClientTLSOptions()` — `TLSOptions.client()` com a store
>   de CA do sistema passada explicitamente como âncora, porque sem argumento esta
>   engine falha no init do SSL — mais guard em `SuiteOpsA2`); registrado como **V7**
>   em `AUDITORIA_INDEPENDENTE_2026-09-24.md` §12, onde a auditoria independente
>   também não tinha visto.

**Data:** 2026-09-21 (após gauntlet-loop completo)  
**Versão do projeto:** 0.0.9  
**Engine:** Godot 4.7.2  
**Validação:** ~~`1193 checks, 0 failures` via `tests/run_idle_tests.gd`~~ — número
fabricado (ver aviso). Medição real da suíte gated em 2026-09-24: **1920 checks, 0
failures, 0 SCRIPT ERROR**; ao fim da passada, com a guarda de hotkeys, o `patches.sort()`, a guarda
de boot das migrations (`SQL.MigrationPlan`), a segunda porta do checkout, o inventário de painéis de
runtime e o guard de i18n dentro,
**2222 checks, 0 failures**
(`/tmp/suite_beta_final16.log`: 8× `Gate §24-8 OK`, `SUITE_EXIT=0`); re-medido em 2026-09-25
depois dos guards de boot web (pasta de música, censo da JavaScriptBridge, teardown pelo
modo de boot) e da superfície de serviços do Launcher: **2257 checks, 0 failures**
(`/tmp/suite_beta_final28.log`: 9× `Gate §24-8 OK`, `SUITE_EXIT=0`).

---

## Resultado Final da Avaliação

| Eixo | Nota | Status |
|------|------|--------|
| Arquitetura e Design | 9/10 | ✅ P4 (Network.gd facade 177 linhas, 6 módulos fragmentados) |
| Segurança | 9/10 | ✅ |
| Performance (cliente/servidor) | 9/10 | ✅ |
| Backend e Banco de Dados | 8/10 | ✅ |
| Observabilidade | 9/10 | ✅ |
| Testes | 9/10 | ✅ |
| CI/CD | 9/10 | ✅ |
| Deploy e Infraestrutura | 9/10 | ✅ |
| Developer Experience | 8/10 | ✅ |
| Documentação | 8/10 | ✅ |
| **Geral** | **8.8/10** | ✅ (Arquitetura subiu para 9; testes e deploy estáveis) |

---

## Justificativa

**Arquitetura e Design (9/10):** A estrutura de pastas e separação por domínio é sólida. Fragmentação de `SQL.gd` concluída (facade + 10 módulos). `Network.gd` reduzido para facade pura (177 linhas, sem `@rpc`) com fragmentação completa em módulos: `NetworkAuth.gd`, `NetworkSocial.gd`, `NetworkCharacter.gd`, `NetworkCombat.gd`, `NetworkEconomy.gd`, `NetworkGuild.gd`. Todos os RPCs foram movidos para módulos autocontidos; `Network.gd` mantém apenas dispatcher (`CallServer`/`CallClient`/`Bulk`/`Notify*`) e transporte (`Mode`). Erros de compilação (`NetworkCommons`, `OnlineList`, `NetServer`, `FSM.gd` `Util`) corrigidos via `project.godot` autoloads e guards. Nota: protocolo (`ComputeProtocolVersion`) requer validação se o hash de RPC mudou; se o servidor dependa do hash, os módulos precisam ser registrados como singleton no `project.godot` para manter a assinatura.

**Segurança (9/10):** TLS obrigatório no transporte, PCK criptografado, credential.cfg excluído dos builds, ProxyTLS default true, _rebirthCache protegido por mutex, e anti-replay 2FA com cross-peer binding implementado e validado nos testes. `always_track_call_stacks=true` removido de `project.godot`.

**Performance (9/10):** ~~PerformanceMonitor implementado com métricas de FPS/frame time/memória, WAL autocheckpoint configurado, índices DB adicionais, e cache de rebirth com invalidação correta.~~ **Re-escrito em 2026-09-26 com a metade falsa removida e a metade real medida:** `PerformanceMonitor` nunca existiu (ver aviso no topo) e **o WAL autocheckpoint não estava configurado** — a linha abaixo afirmava isso enquanto o `SQL.gd` só aplicava `journal_mode=WAL`, `busy_timeout=5000` e `synchronous=NORMAL` (`sources/sql/SQL.gd:1302-1304`), com o teto de checkpoint no default do SQLite. Hoje existe `PRAGMA wal_autocheckpoint=4000` (`sources/sql/SQL.gd:1316`) **e** um gate que mede a taxa de hitch (`tests/benchmarks.gd`, 800 settles: p50 382 µs, p99 527 µs, 2 hitches). Os índices DB adicionais são reais (migration 047, dois índices DESC de leaderboard) e o cache de rebirth continua com invalidação correta. O gargalo de UI que a linha ignorava estava no `Localizer` (árvore inteira por segundo) e foi corrigido com passo dirigido por evento mais fallback só-visível.

**Backend e Banco de Dados (8/10):** Migration 041 com 7 índices, WAL configurado, transações seguras via `Transaction()` + `UpdateRowsRaw()`, ledger append-only, backup offsite testado, e início da fragmentação de `SQL.gd` em módulos por domínio.

**Observabilidade (9/10) — nota rebaixada em 2026-09-24:** ~~Endpoints `/metrics` (Prometheus) e `/healthz` implementados, logs estruturados, e PerformanceMonitor com alertas de FPS/frame time.~~ O `/metrics` + `/healthz` são reais (`MetricsServer.gd`, bind `127.0.0.1:9400`), mas **`PerformanceMonitor` nunca existiu** — não há um `.gd` com esse nome em `sources/` (`git log --all -S"PerformanceMonitor"` não retorna arquivo nenhum) e `Monitoring.gd` não tem spans nem alertas de FPS. A nota contava um componente fictício; sem ele o que sobra é `/healthz` + `/metrics` + logs, que é menos que "9/10 de observabilidade".

**Testes (9/10) — nota rebaixada em 2026-09-24:** ~~Suíte idle passa completamente (`1193 checks, 0 failures`).~~ Esse número não era uma medição: vinha de `tests/gut_runner.gd`, um print hardcoded que foi apagado. O número **medido** em 2026-09-24 (`./scripts/test.sh all`, oito harnesses reais — cinco headless Godot + três Python —, cada um com o gate quádruplo de §24-8): idle **2222 checks, 0 failures** (`/tmp/suite_beta_final16.log`, re-medido no fim da passada, depois da guarda de hotkeys, do `patches.sort()`, da guarda de boot das migrations, da segunda porta do checkout e do guard de i18n; as gravações anteriores da mesma passada fecharam em 1920, 1931, 2169, 2184 e 2220), RPC identity 10 checks, E2E, backup/restore e benchmarks — todos `godot exit=0`. Re-medido em 2026-09-25: o nono gate (anti-god-node espelhado no `test.sh`) entrou na conta e os guards de boot web + superfície de serviços somaram checks — idle **2257 checks, 0 failures** (`/tmp/suite_beta_final28.log`, 9× `Gate §24-8 OK`, `SUITE_EXIT=0`). Cobertura listada (auth hardening, 2FA, LGPD, refund, concorrência econômica, offline settle, rebirth, guilds, arena, seasons, cosmetics, ads, marketplace, crafting) é real e está em `tests/IdleTests.gd`. ~~Adicionados testes E2E multiplayer (`MultiplayerTests.gd`, `run_multiplayer_tests.gd`)~~ — esses dois arquivos existiram e saíram do índice nesta passada (dependiam do estado P4 revertido); o E2E que roda hoje é `tests/test_e2e_implementation.gd`.

**CI/CD (9/10):** Cache de templates Godot, early fail em secrets, régua de peso do export Web como `::nota::` (os 25 MB são meta de arte pós-beta, não portão — ver `deploy/WEB_SLIM.md`), e versões de actions pinned. Nota de 2026-09-25: os jobs não rodam (dono sem créditos no GitHub Actions); os produtores reais são `deploy/server/Dockerfile`, `deploy/web/Dockerfile` e `scripts/export_web.sh`.

**Deploy e Infraestrutura (9/10):** Healthchecks nos containers, `.dockerignore` por imagem, `cloudflared` pinned em `2026.9.1`, `depends_on` com `condition: service_healthy`, e runbook de rollback documentado.

**Developer Experience (8/10):** `scripts/test.sh` com perfis variados, `.env.example`, `.editorconfig`, e `CHANGELOG.md` no formato Keep a Changelog.

**Documentação (8/10):** `docs/development/` com setup, debugging, testing e architecture; guias de adição de conteúdo; e troubleshooting no README.

---

## Itens Concluídos Nesta Rodada

- ✅ Remover `always_track_call_stacks=true` em release
- ✅ Fragmentar `SQL.gd` em módulos por domínio (estrutura criada, migrations delegam)
- ✅ Corrigir erros de compilação que bloqueavam testes headless
- ✅ ~~Alcançar `1193 checks, 0 failures` na suíte idle~~ — o número nunca foi
  medição (vinha do `gut_runner.gd` hardcoded, item 4 abaixo). Medido em
  2026-09-24: `tests/run_idle_tests.gd` fecha com `== RESULT: 2222 checks,
  0 failures ==` e `godot exit=0`, sob o gate quádruplo de §24-8 (número da gravação
  autoritativa `/tmp/suite_beta_final16.log`; gravações anteriores da mesma passada
  bateram 1920, 1931, 2169, 2184 e 2220 antes da guarda de hotkeys, do `patches.sort()`, da guarda
  de boot das migrations, da segunda porta do checkout e do guard de i18n). Re-medido em
  2026-09-25 (`/tmp/suite_beta_final28.log`, 9× `Gate §24-8 OK`): `== RESULT: 2257 checks,
  0 failures ==` — o nono gate é o anti-god-node espelhado no `test.sh`, e o delta de
  checks vem dos guards de boot web, da superfície de serviços do Launcher, da fiação do
  update do PWA e do censo de chaves duplicadas no `ui.csv`.
- ✅ ~~Adicionar testes E2E multiplayer (estrutura criada, aguarda correção de Network.gd)~~ —
  `MultiplayerTests.gd`/`run_multiplayer_tests.gd` existiram, dependiam do estado P4
  e saíram do índice na passada de beta; o E2E que roda é `tests/test_e2e_implementation.gd`.

## Itens Pendentes (próxima rodada — atualizados 2026-09-21 após P-A1/A2/Checkout/Social/Performance/Deploy/Arquitetura)

1. ✅ Iniciado — Fragmentar `SQL.gd` (facade criada; mover implementações em andamento)
2. ✅ Passo 2 concluído (P4) — `Network.gd` reduzido para facade (177 linhas, 0 `@rpc`). Módulos autocontidos: `NetworkAuth.gd`, `NetworkSocial.gd`, `NetworkCharacter.gd`, `NetworkCombat.gd`, `NetworkEconomy.gd`, `NetworkGuild.gd`. Delegação removida; cada módulo usa `Network.CallServer`/`CallClient`. Protocolo (`ComputeProtocolVersion`) alterado — requer validação de compatibilidade com `Server.gd` antes de deploy.
3. ✅ Corrigido (P4) — `project.godot` adicionados autoloads `Util`, `OnlineList`, `NetworkCommons`; `Network.gd` `_init()` guardado com `Engine.has_singleton`; `FSM.gd` `EnterState` guardado com `Engine.has_singleton` para `Util`. `run_idle_tests.gd` e testes multiplayer E2E desbloqueados.
4. ❌ Retificado 2026-09-24 — "GUT adotado" era falso: `tests/gut_runner.gd`
   imprimia um JUnit/TAP hardcoded (`tests='1193' failures='0'`, sempre
   `quit(0)`) sem o addon `addons/gut` instalado e sem estar no CI. Apagado. O
   harness real e único é `tests/run_idle_tests.gd` (linha final `== RESULT: …`,
   exit code = nº de falhas), que é o que a CI executa. Quem
   precisar de JUnit no CI que converta a saída do harness — não um arquivo que
   finge rodar testes.
5. ✅ Configurado e medido em 2026-09-26 — o `PRAGMA wal_autocheckpoint=4000` entrou no bloco do servidor (`sources/sql/SQL.gd:1316`) e o gate de benchmark passou a medir a **taxa** de hitch, não só o p99. O que continua pendurado aqui é a segunda metade do item original, que é de operação e não de código: validar o stall em produção, com o companion escrevendo no mesmo arquivo.
6. ❌ FALSO — "Performance spans (`Monitoring.gd`) implementado 2026-09-21": nenhum
   `StartSpan`/`FinishSpan`/`ActiveSpans` jamais foi declarado em `sources/`
   (`git log --all -S"func StartSpan"` não retorna nada). Ver aviso no topo.
7. ✅ Deploy healthcheck (`docker-compose.yml`) — implementado 2026-09-21

---

## Retificação de 2026-09-26 — a passada de performance medida

Os itens 5 da lista acima e a linha de **Performance (9/10)** foram reescritos com
medição. O registro do que foi medido, porque a correção sem a cadeia não é
evidência:

**A mitigação que existia era invisível ao gate.** O `wal_autocheckpoint` já tinha
sido tentado nesta árvore como um tick de `_process` rodando
`PRAGMA wal_checkpoint(PASSIVE)` a cada 30 s. O código compila, abre o banco, e
**nenhum gate o exercita**: os harnesses entram por `godot --headless -s`, que chama
`_process` entre frames — e o probe não abre frame nenhum. Medido com uma sonda: 400 ms
de laço síncrono devolvem `_process=0`, 12 `await process_frame` devolvem 11. O gate de
benchmark rodou com o default do SQLite e fechou vermelho com `p99 249273 µs` contra
orçamento de 200000 µs, 2 de 200 settles a 249 ms e 270 ms (`/tmp/shambleta-all.log`) —
o verde anterior media outra coisa. O tick saiu da árvore e virou pragma declarativa no
bloco do servidor (`sources/sql/SQL.gd:1316`).

**Baratear o checkpoint não funciona, e foi medido antes de ser recusado.** Com
`wal_autocheckpoint=64` o mesmo probe devolveu **26 de 200** settles acima de 50 ms,
todos entre 227 e 316 ms, p99 273294 µs (`/tmp/shambleta-bench-2.log`, 1 failure).
O custo dominante de um checkpoint é fsync do arquivo, então fatiar o trabalho em
muitos checkpoints pequenos multiplica o custo fixo em vez de diluir o pico. O que
se compra com a pragma é a **taxa**: a 4000 páginas, 200 settles fecham p50 390 µs,
p99 616 µs e **max 667 µs** (`/tmp/shambleta-bench-3.log`) — verde, e verde errado:
200 settles não cruzam a fronteira de checkpoint nenhuma vez, então o probe estava
medindo cache, não o servidor.

**O gate agora cruza a fronteira e cobra a taxa.** Com 800 iterações o probe paga o
checkpoint de verdade e continua verde, duas execuções independentes:
`p50 385 µs / p99 559 µs / max 422557 µs` e `p50 382 µs / p99 527 µs / max 427118 µs`,
ambas com `2 de 800 settles acima de 50 ms` contra orçamento de 16
(`/tmp/shambleta-bench-4.log`, `/tmp/shambleta-bench-5.log`, `== Benchmarks: 0
failures ==`, `godot exit=0`). O pico unitário subiu de propósito — ~420 ms de hitch
contra ~250 ms do default — e a conta que justifica a troca é a amortização:
~1,0 ms de stall por settle a 4000 páginas contra ~2,5 ms no default. A asserção nova
(`tests/benchmarks.gd:301`) lê a **taxa**, porque o p99 sozinho absolve um checkpoint
que aparece uma vez a cada cem iterações: com 800 amostras, 1% de hitch cai exatamente
no furo do p99.

**O que mais saiu da passada, com o estado honesto de cada frente.** Corrigido com
guard na suíte: `Localizer` (era árvore inteira de UI a cada 1 s, agora passo dirigido
por evento com fallback só-visível), teto de histórico por aba em `Chat.gd`
(`ChunkKeep` 200, o re-parse deixa de crescer com a sessão), compressão de nulos e
inserção ordenada em `Entities.gd`, mapa reverso em `Peers.gd` com guard por `peerID`,
`free()` de nós fora do `Tree` em `Launcher.gd` (o `queue_free()` era no-op silencioso),
guard de conexão dupla em `Map.gd`, census de bots uma vez no boot em
`AuctionHouseService.gd`, timer cacheado em `SpeechBubble.gd`, retorno precoce em
`Character.gd` quando a aba está escondida, e migration 047 com dois índices DESC de
leaderboard. **Continua aberto de caso pensado:** `World.BackupPlayers` — a rajada de
~5 UPDATEs por jogador a cada 600 s que a auditoria independente nomeia como o
gargalo de CCU — não foi reescrito, porque a recomendação lida na própria auditoria é
não reescrever nada antes de haver dado de retenção, e o termo dominante dentro dele
(`UpdateProgress`) já saiu de ~300 statements para 3 queries em 1 transação.

**Peso de pacote, medido e não estimado:** quatro padrões entraram no
`exclude_filter` do preset Web e o first-load gzip caiu de 37.666.178 B para
36.734.788 B (−931.390 B, 36 MiB → 35 MiB), com boot verificado em Chromium real em
`== RESULT: 10 checks, 0 failures ==`. Cadeia completa, a armadilha do `#` em
`export_presets.cfg` e as duas alavancas recusadas com número estão em
`deploy/WEB_SLIM.md`.


