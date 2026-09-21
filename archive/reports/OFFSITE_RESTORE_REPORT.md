# Backup offsite — estado, cobertura e procedimento de restore (SOM-IDLE A2)

## 0. Drill local executado (beta fechado, 2026-09-18)

`tests/test_backup_full_restore.gd` — `== FULL RESTORE: PASSED ==`:

| Item | Observado |
|---|---|
| Backup criado (via `backup_to`, mesmo mecanismo de produção) | `/tmp/shambleta_restore_test/backup.db`, **1.925.120 bytes** |
| Base de trabalho (snapshot do live de teste) | 70 contas, 40 chars, 11.138 linhas ledger |
| Perda simulada | original removido + lixo gravado no caminho (rejeitado: não abre íntegro) |
| Restauração | em base **separada** (`restored.db`), live de teste intocado |
| Integridade (`PRAGMA integrity_check`) | ok no original e na restaurada |
| Dados verificados | migration version, contas, personagens, ledger (linhas + soma gems/gold), wallet gems, level/gp do jogador — todos conferem |
| Abertura pela aplicação | `VerifyBackupRestorable` aceita a restaurada; abre em handle separado |
| Limitações | drill local (mesmo disco), não mede RPO/RTO contra objeto remoto; restore S3 real segue pendente (§2–3 deste relatório) |

**Data:** 2026-09-18 · **Base:** `SQLBackups.PushOffsite` + `VerifyBackupRestorable`
**Testes:** `== RESULT: 1015 checks, 0 failures ==` (inclui `SuiteOpsA2`, que cobre
o round-trip offsite contra diretório local) + `tests/test_backup_restore.gd`
(restore probe local em CI).

## 1. O que já está coberto (não re-testar)

| Caso | Cobertura | Onde |
|---|---|---|
| Backup diário local criado e legível | `CreateDailyBackup` + `VerifyBackupRestorable` (abre a cópia, lê `migration.version`) | `tests/test_backup_restore.gd` (job `backup-restore` em CI) |
| Push offsite + verificação de restore | `PushOffsite` copia p/ `SHAMBLETA_OFFSITE_BACKUPS` (ou dir de teste) e só retorna o caminho se `VerifyBackupRestorable` passar; rejeita origem vazia e dir inalcançável | `SuiteOpsA2` (`tests/IdleTests.gd`: "offsite push + verified", "empty source rejected") |
| Push nunca quebra o backup local | `PushOffsite` é best-effort após `CreateDailyBackup`; falha retorna `""` sem erro | `SQLBackups.gd:Run` |

## 2. O que continua pendente (cenário de desastre real)

`FEATURE_MATRIX.md §8`: o mecanismo é agnóstico a destino (NFS, segundo disco,
**S3 via s3fs/rclone-mount**), mas nenhum restore foi executado contra um
bucket S3 real — RPO/RTO observados contra objeto remoto são desconhecidos.
Isso exige credenciais/infra que não existem neste ambiente (dono).

## 3. Procedimento de aceite (para o dono/executor com acesso ao bucket)

```bash
# 1. Montar o bucket como filesystem (ex.: s3fs) e apontar o server:
SHAMBLETA_OFFSITE_BACKUPS=/mnt/shambleta-offsite  # segunda montagem, ver deploy/docker-compose.yml
# 2. Aguardar um ciclo diário (ou forçar via backup manual) e confirmar o push:
ls -la /mnt/shambleta-offsite/  # <timestamp>.db presente
# 3. Restore em container ISOLADO (nunca em produção):
docker run --rm -v shambleta-offsite:/offsite:ro -v restore-probe:/data \
  shambleta-server sqlite3 /offsite/<timestamp>.db ".recover" # ou ATTACH + backup
# 4. Verificação de integridade na cópia restaurada:
#    - `SELECT version FROM migration;` == versão do live
#    - `PRAGMA integrity_check;` == ok
#    - contagens: account / character / ledger_transaction / wallet batem com o live do mesmo dia
#    - boot do game server contra a cópia (read-only) sem erros de schema
```

Medir e anotar aqui: **RPO** (idade do backup mais recente no bucket no momento
do desastre simulado — alvo ≤ 24h) e **RTO** (tempo entre "decidir restaurar" e
"server jogável contra a cópia" — alvo a definir com o primeiro drill).

## 4. Decisão proposta (não definitiva — pendência de dono)

Manter o offsite como montagem S3-fuse (zero código novo, o mecanismo atual já
funciona) e rodar este drill **mensalmente** (runbook), não só no lançamento.
Alternativa (pós-lançamento): plugin S3 nativo com multipart upload — só se o
fuse virar gargalo. Preço/critério seguem padrão `XP_PROGRESSION.md`: proposta,
não definição.
