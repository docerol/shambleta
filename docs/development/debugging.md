# Debugging

## Ferramentas

### Console do Godot

O jogo imprime logs estruturados via `Util.PrintLog/PrintInfo/PrintWarning`.

### Painel de performance

Não existe atalho in-game: nenhum binding de F3 (ou de qualquer tecla) abre um
painel de performance, e `sources/gui/ServerDisplay.gd` — o único script que lê o
singleton `Performance` — é órfão: nenhuma cena `.tscn` o instancia e nenhum código
o referencia, então ele não aparece em tela. Para medir frame time/FPS/memória use
o **Profiler** e os **Monitors** do editor do Godot, ou leia `Performance.get_monitor(...)`
num harness próprio (`./scripts/test.sh bench`).

### Diagnóstico de Pacing

```bash
./scripts/test.sh diag
```

Mede o kill rate em tempo real (1 simulação) para detectar desbalanceamento.

### Inspeção do SQLite

`user://` do Godot 4 com `config/use_custom_user_dir=true` + `custom_user_dir_name="Shambleta"`
resolve para `$XDG_DATA_HOME/Shambleta` (fallback `$HOME/.local/share/Shambleta`) — não
para o layout `godot/app_userdata/<projeto>` do Godot 3. No fonte o banco é `testing.db`
(produção é o que o `Dockerfile` liga, via `live.db`):

```bash
sqlite3 ~/.local/share/Shambleta/testing.db
sqlite3> .tables
sqlite3> SELECT * FROM account LIMIT 10;
```

Em container, o mesmo arquivo está em `/data/.local/share/Shambleta/live.db`.

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

### Erros de compilação em `Network.gd` / `FSM.gd`

`Util`, `NetworkCommons` e `OnlineList` são `class_name` globais sobre
`RefCounted` — **não** são autoload, e não devem ser adicionados como um: o Godot 4
recusa `RefCounted` como autoload, e foi exatamente isso que derrubou a tentativa do
P4 de fragmentar `Network.gd` em seis módulos (revertida). Na ordem:

1. Rode a import uma vez neste ambiente — `godot --headless --path . --editor --import --quit`.
   O cache `.godot/` (`global_script_class_cache.cfg`) é o que faz um `class_name`
   resolver; sem ele nada resolve as classes globais e o erro parece "autoload
   faltando". Esta foi a causa raiz real da suíte bloqueada.
2. Confirme que nenhum `class_name` novo colide com os cinco autoloads de
   `project.godot` (`Launcher`, `Network`, `FSM`, `Monitoring`, `WebPush`).
3. `FSM.gd` `EnterState` e `Network.gd` `_init()` mantêm guard `Engine.has_singleton`
   para quando rodam antes dos serviços existirem (modo `-s`, é assim que os testes
   sobem).
