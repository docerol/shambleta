# Testes

## Estrutura

```
tests/
├── run_idle_tests.gd           # Runner principal (1015+ checks)
├── test_backup_restore.gd      # Probe backup/restore
├── test_backup_full_restore.gd # Restore completo
├── benchmarks.gd               # Performance budgets
├── diag_pacing.gd              # Diagnóstico pacing
├── dump_calibration.gd         # Dump calibração
└── test_e2e_implementation.gd  # Smoke test E2E
```

## Execução

```bash
./scripts/test.sh all
```

## Notas sobre testes multiplayer (P4)

`MultiplayerTests.gd` e `test_e2e_implementation.gd` dependem da correção de `Parse Error` pré-existente (`NetworkCommons`, `OnlineList`, `NetServer`, `FSM.gd` `Util`). Esses erros foram corrigidos (autoloads adicionados no `project.godot` e guards em `_init()` / `EnterState`). A fragmentação de `Network.gd` (facade pura + 6 módulos) também foi concluída; o protocolo (`ComputeProtocolVersion`) foi atualizado para agregar todos os módulos.

## Escrevendo novos testes

- Use `Check(condition, label)`, `CheckEq(value, expected, label)`, `CheckNear(value, expected, tolerance, label)`
- Crie fixtures com cleanup explícito (DELETE no final)
- Use `Transaction()` para testes que modificam o banco
