# Debugging

## Ferramentas

### Console do Godot

O jogo imprime logs estruturados via `Util.PrintLog/PrintInfo/PrintWarning`.

### Painel de performance

Não existe atalho in-game: nenhum binding de F3 (ou de qualquer tecla) abre um
painel de performance, e `sources/gui/ServerDisplay.gd` — o único script que lê o
singleton `Performance` — não chega à tela por outro motivo: a cena existe
(`presets/gui/Server.tscn:4` anexa o script, e `presets/Server.tscn:4` instancia
essa cena), mas **nenhum carregador chama `presets/Server.tscn`**. O `main_scene` do projeto
vem de `application.run/main_scene` e é `res://presets/Default.tscn` (`project.godot:@application.run/main_scene`)
e nenhuma linha de `sources/`, `presets/` ou `export_presets.cfg` carrega a cena do servidor — o que
não existe é o caminho que a abre, não a cena. Para medir frame time/FPS/memória use
o **Profiler** e os **Monitors** do editor do Godot, ou leia `Performance.get_monitor(...)`
num harness próprio (`./scripts/test.sh benchmarks`).

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

### `resources still in use at exit` / `ObjectDB instances were leaked`

Todo log de harness headless termina com estas duas linhas (e por vezes um
`RID allocations ... leaked at exit`). Elas **não** são o veredito e não deixam o
gate vermelho: `scripts/ci_gate_log.sh` confere quatro coisas — `SCRIPT ERROR` /
`Parse Error` no log, a linha `== RESULT:` presente, a contagem de falhas lida
dessa linha e o código de saída do `godot`. Uma linha de leak não é nenhuma delas.

O que elas significam: um harness é um `SceneTree` que chega em `quit()` sem
passar pelo fechamento do editor. O cache de `class_name`, tudo que foi
`preload`ado (`.gd`, `.tres`, `.tscn`) e os RIDs dos servers são liberados pelo SO
quando o processo morre, e o Godot imprime o que ainda estava vivo naquele
instante. Para ver a composição, rode o mesmo harness com `--verbose` e leia o
bloco depois da contagem — medido em `doc_facts_test`, a massa é `Resource` e
`GDScript` de preload, mais RIDs de região de navegação; nenhum byte de ledger.

Quando a linha deixa de ser ruído: se ela vier seguida de **segfault** — o
processo morre sem imprimir a linha de resultado, e o gate reclama da falta dela.
Isso já aconteceu de verdade, e a correção está no fonte: um preload em thread que
ninguém juntou é destruído no meio do parse, sob um cache de scripts que o
teardown já está libertando, e o sintoma era `script = ExtResource(...)` falhando
na saída seguida de crash. `DrainPendingPreloads` existe para isso
(`sources/db/DB.gd:@DrainPendingPreloads`) e é chamado no último hook de árvore ainda viva do
autoload — `_exit_tree` (`sources/launcher/Launcher.gd:@_exit_tree`) —, o que cobre produção e
qualquer harness que suba o `Launcher`, mesmo os que não o chamam por conta própria.
Os que chamam explicitamente (`grep -rn DrainPendingPreloads tests`) são os que
precisam do dreno **antes** de fechar o próprio `SQLite`, não só antes de morrer.
Então, ao investigar um run que morreu sem veredito: confirme que o dreno rodou —
é o primeiro suspeito, não o leak em si.

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
2. Confirme que nenhum `class_name` novo colide com os seis autoloads de
   `project.godot` (`Launcher`, `Network`, `FSM`, `Monitoring`, `WebPush`,
   `PwaUpdate` — `[autoload]` em `project.godot:@autoload`). <!-- DRIFT autoload_count 6 -->
   <!-- DRIFT autoload_names FSM,Launcher,Monitoring,Network,PwaUpdate,WebPush -->
3. Não procure guard `Engine.has_singleton` em `FSM.gd` `EnterState` nem em
   `Network.gd` `_init()`: eles **foram removidos**, e a razão está escrita no
   próprio fonte — `EnterState` (`sources/launcher/FSM.gd:@EnterState`) registra que o guard nunca foi
   verdadeiro (`Util` é `class_name`, não autoload), então o log de transição de
   estado — a primeira linha que você procura quando o cliente não chega em
   `IN_GAME` — não saía em build nenhum; `_init` (`sources/network/Network.gd:@_init`) é o hook
   sem guard (e o estado que faltava logar é `States.IN_GAME`, `sources/launcher/FSM.gd:@States`); e `sources/web/WebPush.gd:11-20` descreve o mesmo defeito
   nos guards de `Conf`/`LauncherCommons`, que também saíram. Chamada estática
   direta resolve também sob `godot -s` (é como os testes sobem), que era o
   pretexto do guard. **Consequência para debugging:** se um `class_name` novo
   colidir com um autoload, você não vê um log condicional — vê erro de resolução
   de nome em tempo de parse, e é aí que se procura.
