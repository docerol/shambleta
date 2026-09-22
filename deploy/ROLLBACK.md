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

# Listar backups disponíveis
ls -la ~/.local/share/godot/app_userdata/Shambleta/backups/

# Restaurar backup específico
cp ~/.local/share/godot/app_userdata/Shambleta/backups/daily_2026-09-20.db /data/.local/share/godot/app_userdata/Shambleta/live.db

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

## Contatos

- **On-call:** consulte `LAUNCH_HANDOFF.md`
- **Sentry:** dashboard do projeto
- **Coolify:** painel de deploy
