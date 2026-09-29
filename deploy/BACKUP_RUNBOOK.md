# Runbook de backup — o que roda, onde cai, como se verifica, como se restaura

Escrito contra o estado da árvore em 2026-09-27. Toda afirmação tem arquivo:linha;
toda medida tem o comando de reprodução. Nada aqui é heredado de doc antigo: o que
não foi conferido no código está marcado como **[NÃO MEDIDO]**.

## 1. Onde vive o estado (e por que isso é o ponto todo)

| dado | caminho lógico | caminho no container | origem |
|---|---|---|---|
| banco | `user://live.db` | `/data/.local/share/Shambleta/live.db` | `sources/sql/SQLCommons.gd:7` (`DBName`) + `sources/system/Path.gd:55` (`Local = "user://"`) + `ENV HOME=/data` (`deploy/server/Dockerfile:37`) |
| histórico de backup | `user://sql-backups/{DAILY,WEEKLY,MONTHLY}/AAAA-MM-DD_HH-MM-SS.db` | dentro do **mesmo** `/data` | `sources/sql/SQLCommons.gd:8` (`BackupPath`), `sources/sql/SQLBackups.gd:10-19` |
| cópia offsite | `$SHAMBLETA_OFFSITE_BACKUPS/<mesmo nome>` | `/data-backups` (volume `game-backups`) | `sources/sql/SQLCommons.gd:107-108`, `sources/sql/SQLBackups.gd:35-51`, `deploy/docker-compose.yml` (`SHAMBLETA_OFFSITE_BACKUPS`, `- game-backups:/data-backups`) |

Os diretórios são **MAIÚSCULOS** e isto não é cosmetismo: o nome vem das chaves do
enum `BackupFrequency` (`sources/sql/SQLCommons.gd:43`, `{DAILY, WEEKLY, MONTHLY}`,
usado em `sources/sql/SQLBackups.gd:12` e `:22`), e o
container é case-sensitive. Um `ls` na variante minúscula desse caminho devolve vazio
num banco que tem backups — a aparência de "o backup nunca rodou" vem do `ls`, não
do worker. O `ls` do §3.1 de `ROLLBACK.md` já usa o caminho certo.

O layout `/.local/share/Shambleta/` é o do Godot 4 com `use_custom_user_dir` — não
o `godot/app_userdata/` do Godot 3. Isso é **executado**, não afirmado:
`godot --headless --path . -s tests/deploy_ops_test.gd` (14 checks) e a régua
equivalente em `scripts/check_compose.sh`.

Consequência que motivou o volume extra: o backup nasce **dentro** do volume do
banco. Um `docker compose down -v`, um `rm -rf` no `/data` ou uma corrupção de
volume levavam as duas coisas juntas. `game-backups` é o segundo volume, e o
gate recusa compose que o apague ou que o aponte para o mesmo volume do banco.

## 2. Cadência real do worker

- diário a cada `DailyBackupIntervalSec` = 24 h, semanal 7 d, mensal 28 d
  (`sources/sql/SQLCommons.gd:13-15`, disparo em `sources/sql/SQLBackups.gd:149-162`).
- A cópia é feita pela API de backup online do SQLite (`Launcher.SQL.db.backup_to`,
  `sources/sql/SQLBackups.gd:14`) — arquivo único e consistente **sem** o `-wal`.
- Retensão local: 7 diários / 4 semanais / 12 mensais (`sources/sql/SQLCommons.gd:34-38`),
  podada por `PruneBackups()` (`sources/sql/SQLBackups.gd:66-88`).
- O push offsite acontece **depois** do diário (`sources/sql/SQLBackups.gd:54-64`),
  cria o diretório se faltar (`:39-42`) e só é anunciado como sucesso depois de
  `VerifyBackupRestorable()` abrir a cópia e ler `SELECT version FROM migration`
  (`:47-49`, `:54-64`).
- **O offsite nunca é podado**: `PruneBackups()` só caminha por `GetBackupPath()`
  (`:69`). A rotação de longa duração é do operator (§5).
- **[PENDÊNCIA, arquivo de outro dono]** `sources/sql/SQLBackups.gd:92` inicializa
  `lastDailyBackupTimestamp = SQLCommons.Timestamp()`, então o primeiro diário só
  existe 24 h depois do boot — um redeploy zera o relógio. É o defeito que o
  `#28` corrigiu para o job meta (`:97-102`, `lastMetaJobTimestamp = 0`) e que
  ficou para trás no backup. Mudança pedida: nascer em `0` (ou persistir o último
  carimbo no banco). Sintoma: `ls /data/.local/share/Shambleta/sql-backups/DAILY`
  vazio num beta que re-deploya todo dia.

## 3. Verificação (roda, não se acredita em texto)

```bash
# 3.1 Sonda de restore no CI/na máquina: cria um diário, relê, confere a versão do
#     schema contra o banco vivo. Marcador lido pelo gate §24-8.
bash scripts/test.sh backup            # -> "== Backup Restore Probe: 8 checks, 0 failures =="
#     (tests/test_backup_restore.gd:67-94)

# 3.2 Os volumes de estado existem e estão montados onde o código espera:
bash scripts/check_compose.sh          # -> "== COMPOSE GATE: N checks, 0 failures =="

# 3.3 No host: o que existe de fato dentro do volume do jogo
docker compose ps -q game | xargs -I{} docker inspect --format '{{.Name}}' {}
docker compose exec game sh -c 'ls -la /data/.local/share/Shambleta/ \
  /data/.local/share/Shambleta/sql-backups/DAILY /data-backups | tail -30'

# 3.4 O push offsite rodou de verdade (o log do worker é a única prova local):
docker compose logs --since 48h game | grep -E "Offsite backup (pushed|failed)|Backup created|PruneBackups"
```

Um `Offsite backup dir unreachable` no log 3 quer dizer montagem errada (path que
não é volume), não disco cheio — confira o §3.2 antes de culpar o `df`.

## 4. Restauração (janela de manutenção)

Migrations são **forward-only** (`ApplyMigrations()`, `sources/sql/SQL.gd:113-168`) e
a auditoria de 2026-09-27 registra que as primeiras (`005_reset_positions_and_inventory.sql`,
`006_reset_progress_veteran_legacy.sql`) são data-reset — restaurar um backup mais
velho que a última migration aplicada **não** devolve o estado esperado se houver
dessas no meio. Antes de restaurar, leia a versão da cópia:

```bash
# versão da cópia vs versão viva (a mesma consulta que VerifyBackupRestorable faz)
docker compose exec game sh -c 'ls -t /data/.local/share/Shambleta/sql-backups/DAILY | head -3'
```

Procedimento:

```bash
# 1. derrube o mundo, não o processo (ver OPS_RUNBOOK §3 — sem isto você perde
#    até BackupPlayersSec = 600 s de ouro que só existe em memória)
docker compose exec game touch /data/.local/share/Shambleta/canary
docker compose wait game 2>/dev/null || docker compose ps   # o processo sai sozinho no fim do drain

# 2. quarentena do banco atual + cópia do backup por cima, no MESMO volume
docker compose run --rm --no-deps game sh -c '
  cd /data/.local/share/Shambleta &&
  mkdir -p quarentena && mv live.db live.db-wal live.db-shm quarentena/ 2>/dev/null;
  cp sql-backups/DAILY/<ARQUIVO>.db live.db'

# 3. sobe só o game e lê o /healthz antes de abrir o tráfego
docker compose up -d game
docker compose exec game curl -fsS http://127.0.0.1:9400/healthz   # "ok"
```

Passos 2 e 3 usam `docker compose run`, que monta os mesmos volumes do serviço —
por isso não há `docker cp` nem volume à mão no meio. Se o passo 3 voltar 503, o
banco não abriu (migrations ou arquivo trocado): `docker compose logs game | tail -50`
e pare ali, não insista.

## 5. Rotação do que sai do host

O worker não poda o offsite (§2), então a política é externa. Deixar 35 diários
fora do host cobre os 7 diários + 4 semanais + 12 mensais do espelho local com
folga de um mês:

```bash
# cron diário no host do Coolify (find/sh existem na imagem debian do serviço game)
docker compose run --rm --no-deps game \
  find /data-backups -name '*.db' -mtime +35 -delete
```

Isso ainda é **mesmo host**. Para virar backup de verdade, aponte
`SHAMBLETA_OFFSITE_BACKUPS` (painel do Coolify, não o repositório) para uma
montagem NFS/S3-fuse e adicione o mount correspondente ao serviço `game` — o
código só copia para o caminho que a env disser, sem inventar nada
(`sources/sql/SQLCommons.gd:108`).

## 6. O que nada aqui cobre

- O snapshot de jogadores (`BackupPlayers`, cadência `BackupPlayersSec` = 600 s,
  `sources/sql/SQLCommons.gd:11` + `sources/sql/SQLBackups.gd:167-170`) não é
  backup: é o que se perde quando o processo morre sem drain. A causa raiz
  (memória por cima do banco) está em `archive/AUDITORIA_2026-09-27.md` §7.1, não é
  resolvida por backup e não é deste runbook.
- Nenhum teste deste repo restaura um backup **num servidor de jogo de verdade**
  (o probe abre a cópia e lê a versão). **[NÃO MEDIDO]** o tempo de restore num
  volume do tamanho do beta.
