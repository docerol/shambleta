# Debugging

## Ferramentas

### Console do Godot

O jogo imprime logs estruturados via `Util.PrintLog/PrintInfo/PrintWarning`.

### Performance Monitor

Pressione **F3** no cliente para alternar o painel de debug de performance (FPS, frame time, memória, node count).

### Diagnóstico de Pacing

```bash
./scripts/test.sh diag
```

Mede o kill rate em tempo real (1 simulação) para detectar desbalanceamento.

### Inspeção do SQLite

```bash
sqlite3 ~/.local/share/godot/app_userdata/Shambleta/live.db
sqlite3> .tables
sqlite3> SELECT * FROM account LIMIT 10;
```

### Sentry

Erros e warnings são enviados ao Sentry se `Privacy-BugReports` estiver ativado nas configurações.

## Problemas Comuns

### "testing.db locked"

Mate processos Godot zumbis:

```bash
pkill -f godot
```

### "Assets not importing"

Rode o import manualmente:

```bash
godot --headless --path . --editor --import --quit || true
```

### "CI fails on idle tests"

Aumente o timeout do teste real-time:

```bash
export SOM_REALTIME_SECS=600
./scripts/test.sh idle
```

### Servidor não conecta

Verifique se o proxy TLS está configurado e se a porta 6108 não está bloqueada.

### Erros de compilação em `Network.gd` / `FSM.gd` (P4)

Se aparecer `Parse Error` relacionado a `NetworkCommons`, `OnlineList`, `NetServer` ou `Util`:

1. Confirme que `project.godot` contém:
   - `Util="*res://sources/util/Util.gd"`
   - `OnlineList="*res://sources/network/server/OnlineList.gd"`
   - `NetworkCommons="*res://sources/network/NetworkCommons.gd"`
   - `NetworkAuth`, `NetworkSocial`, `NetworkCharacter`, `NetworkCombat`, `NetworkEconomy`, `NetworkGuild` (autoloads para protocolo)
2. Verifique que `Network.gd` `_init()` e `FSM.gd` `EnterState` têm `Engine.has_singleton` guard.
