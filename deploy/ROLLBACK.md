# Rollback e Incidentes

Este runbook cobre procedimentos de rollback e resposta a incidentes.

## Rollback de Deploy

### Via Coolify

1. Acesse o Coolify
2. Vá para o serviço `game` ou `web`
3. Clique em **Rollback**
4. Confirme a versão anterior

### Via Docker Compose

```bash
# Verificar versão atual
docker compose ps

# Rollback do serviço game
docker compose pull game
docker compose up -d game

# Rollback do serviço web
docker compose pull web
docker compose up -d web
```

### Restore de Backup

Se o banco de dados foi corrompido:

```bash
# Parar o servidor
docker compose stop game

# Listar backups disponíveis. Os caminhos são os de dentro do container: `user://`
# do Godot 4 com `config/use_custom_user_dir=true` é `$HOME/.local/share/Shambleta`,
# e o compose monta o volume `game-data` em `/data` (`HOME=/data`). Rodar isso no
# shell do host (`~/...`) nunca encontrou nada.
docker compose run --rm --entrypoint sh game -c 'ls -la /data/.local/share/Shambleta/sql-backups/'

# Restaurar backup específico. O nome real é DAILY/AAAA-MM-DD_HH-MM-SS.db
# (SQLBackups.gd:12-13); havia "daily_2026-09-20.db" aqui e esse arquivo nunca
# existiu. O rm do -wal/-shm não é cosmético: o banco está em WAL, e deixar o
# journal da base antiga em cima do arquivo restaurado faz o SQLite reler aquele
# WAL sobre o restore.
docker compose run --rm --entrypoint sh game -c \
  'cp /data/.local/share/Shambleta/sql-backups/DAILY/2026-09-24_15-56-24.db /data/.local/share/Shambleta/live.db && rm -f /data/.local/share/Shambleta/live.db-wal /data/.local/share/Shambleta/live.db-shm'

# Reiniciar
docker compose up -d game
```

## Incidentes Comuns

### Servidor não inicia

1. Verificar logs: `docker compose logs game`
2. Verificar se `credential.cfg` está montado corretamente
3. Verificar se o volume `/data` está íntegro

### Webhooks falhando

1. Verificar `SHAMBLETA_WEBHOOK_SECRET`
2. Verificar logs do companion: `docker compose logs companion`
3. Verificar `grant_queue` no banco: `SELECT * FROM grant_queue WHERE granted_at IS NULL LIMIT 10;`

### Alta latência

1. Verificar CPU/memória dos containers: `docker stats`
2. Verificar `queryMutex` contention via `/metrics`
3. Considerar reduzir `MaxPlayerCount`

### Erros de TLS

1. Verificar se `SHAMBLETA_PROXY_TLS=1` está setado
2. Verificar certificados do proxy (Coolify/Cloudflare)
3. Verificar logs do nginx: `docker compose logs web`
4. **Se o sintoma for "servidor no ar, mas nenhum cliente loga"** (só desktop/ENet;
   o build Web continuando ok): desde a passada de beta o cliente **rejeita** cadeia
   inválida ou hostname que não bate com o certificado (`NetworkCommons.ClientTLSOptions()`
   em `sources/network/client/Client.gd` — âncora = store de CA do sistema passada
   explicitamente; se `OS.get_system_ca_certificates()` vier vazio no ambiente do
   cliente, a verificação não tem com o que ancorar e a conexão cai por isso, não por
   certificado ruim). Confirme que a entrada que atende
   `wss://<ServerAddress>:6108` serve certificado **emitido por CA pública e válido
   para exatamente esse hostname** — não um `--self-signed` de `provision_tls.sh`.
   O erro aparece no log do cliente como falha de conexão/TLS, nunca como ban.
   A correção é no certificado da borda; afrouxar o cliente de volta reabre o
   buraco de credencial (ver `deploy/TLS.md`, "Client-side verification").

## Contatos

- **On-call:** consulte `LAUNCH_HANDOFF.md`
- **Sentry:** dashboard do projeto
- **Coolify:** painel de deploy
