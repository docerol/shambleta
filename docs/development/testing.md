# Testes

## Estrutura

```
tests/
├── run_idle_tests.gd           # Runner principal (2257 checks, 0 falhas em 2026-09-25, `/tmp/suite_beta_final28.log`; exit = nº de falhas)
├── IdleTests.gd                # As suítes (o runner só sobe os serviços e chama)
├── run_rpc_identity_test.gd    # Servidor WebSocket real + 2 clients forjando peerID
├── test_backup_restore.gd      # Probe backup/restore
├── test_backup_full_restore.gd # Restore completo
├── benchmarks.gd               # Performance budgets
├── diag_pacing.gd              # Diagnóstico pacing
├── dump_calibration.gd         # Dump calibração
└── test_e2e_implementation.gd  # Smoke test E2E
```

A CI roda os cinco harnesses Godot headless — `run_idle_tests.gd`,
`run_rpc_identity_test.gd`, `test_e2e_implementation.gd`,
`test_backup_restore.gd` e `benchmarks.gd` — mais o gate de estrutura
`scripts/check_god_nodes.sh` (espelhado no `test.sh` pelo `gate_sh`) e as três suítes python do
companion (`companion/test_webhook.py` = 100 checks, `test_security.py` = 47,
`test_refund_cli.py` = 12), e todos passam pelo mesmo
`scripts/ci_gate_log.sh`, que não aceita exit code sozinho: o log não pode ter
`SCRIPT ERROR`/`Parse Error`, a linha de resultado tem que existir, a contagem de
falhas é lida DA LINHA DE RESULTADO (alimentar `0` à mão não aprova mais nada) e
o exit code do runner é conferido à parte. Antes de rodar qualquer harness,
`scripts/test.sh all|idle|quick` (e o job `idle-tests` da CI, no mesmo passo) faz
o **preflight de parse** dos seis arquivos: `godot --check-only --script` sobre
`run_idle_tests.gd`, `IdleTests.gd`, `run_rpc_identity_test.gd`,
`test_e2e_implementation.gd`, `test_backup_restore.gd` e `benchmarks.gd`
(meudado: ~1 s no total). O motivo é um defeito que custou três execuções do
portão: `run_idle_tests.gd:76` faz `load("res://tests/IdleTests.gd")` e chama
`.new()` — se o arquivo não compila (um `CheckEq` recebendo `String` onde a
assinatura é `(int, int, String)`), nenhuma suíte roda, `== RESULT:` nunca
aparece e o gate descobre isso só no timeout de 1200 s. A régua é ancorada em
`SCRIPT ERROR: Parse Error`: em `--check-only` um script que referencia autoload
também emite `ERROR: ….tscn - Parse Error: [ext_resource] referenced
non-existent resource`, que é falso positivo do modo, não do código.
Antes de 2026-09-24 o companion era o
único pedaço do portão com CI e local provando coisas diferentes: a CI chamava
`python3` direto e o `test.sh all` local não o rodava nenhum — hoje os dois chamam
`./scripts/test.sh companion`. `test_e2e_implementation.gd` estava
no repositório sem job nenhum até 2026-09-24 — é a tabela chamador→método entre
arquivos que teria pego `Gui.gd:286` chamando `Settings.get_sessionfirstlogin`,
um método que nunca existiu em nenhuma revisão (a chamada abortava o primeiro
login e o tour de onboarding não abria para ninguém). `test_backup_restore.gd`
saiu do mesmo jeito: ele terminava em `quit(0)` sem contagem, então o job
`backup-restore` ficava verde sobre um segfault.

## Execução

```bash
./scripts/test.sh all         # os nove gates, cada um pelo quádruplo
./scripts/test.sh idle        # só a suíte idle
./scripts/test.sh rpc         # só identidade de RPC
./scripts/test.sh companion   # só a fronteira do dinheiro (python)
./scripts/test.sh clean       # descarta bases de teste
```

`test.sh` não chama `godot` direto: cada harness é gravado em `/tmp/shambleta-*.log`
e avaliado por `scripts/ci_gate_log.sh`, exatamente como na CI. Rodar local e a CI
com réguas diferentes é como o job de backup ficou verde sobre um segfault. Os
sandboxs de `user://`/cache ficam em `.test-home/<harness>/`, então um harness não
herda o `testing.db` do outro e o seu `~/.local/share/Shambleta` (o `user://` real
deste projeto, que usa `use_custom_user_dir`) não é tocado.

## Nota histórica: o harness multiplayer (P4)

Este parágrafo afirmava que `MultiplayerTests.gd` "dependia de `Parse Error`
pré-existente em `Network.gd`/`FSM.gd`" e que a causa raiz era o cache `.godot/`
nunca importado. As duas coisas eram falsas, medidas em 2026-09-24: `Network.gd`
e `FSM.gd` compilam, e `run_idle_tests.gd` roda verde há várias passadas. Os
erros eram de `MultiplayerTests.gd` contra a API real de `Network` —
`BulkCall(peerA, "Ping", [])` inverte a assinatura (`methodName, bulkedArgs,
peerID`) e devolve `void`; `NotifyNeighbours/NotifyInstance/NotifyArea` recebem
`BaseAgent`/`WorldInstance`/`WorldMap`, não inteiros. O arquivo não compilava
desde que essas assinaturas mudaram, e 4 dos 5 checks dele eram
`Check(true, "não crashou")`. Ele foi apagado: o único assert verdadeiro
(registro/identidade/desregistro de peer em `Peers`) foi portado para
`SuiteAuthHardening` em `IdleTests.gd`, e a cobertura real de rede é
`run_rpc_identity_test.gd` (transporte WebSocket de verdade) mais as suítes de
simulação que exercitam os callers de produção de `Notify*` (`BaseAgent`,
`PlayerAgent`, `NpcCommons`, `Inventory`). A fragmentação de `Network.gd` em
seis módulos autoload (P4) continua revertida; ver
`docs/development/architecture.md`.

## Escrevendo novos testes

- Use `Check(condition, label)`, `CheckEq(value, expected, label)`, `CheckNear(value, expected, tolerance, label)`
- Crie fixtures com cleanup explícito (DELETE no final)
- Use `Transaction()` para testes que modificam o banco
