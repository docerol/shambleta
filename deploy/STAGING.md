# Shambleta Staging Environment

## Overview

Staging is a separate Coolify environment that mirrors production but uses:
- Separate database (`staging.db`)
- Separate volumes
- Sandbox payment provider (`shared`)
- Debug build enabled

## Coolify Setup

1. Create a new **Environment** in Coolify called `staging`
2. Add a new **Service** using the same Docker Compose template as production
3. Override the following environment variables:

```env
# Staging overrides
SHAMBLETA_ENV=staging
SHAMBLETA_ALLOW_DEV_WEBHOOK=1
SHAMBLETA_WEBHOOK_PROVIDER=shared
SHAMBLETA_WEBHOOK_SECRET=<staging-secret>
SHAMBLETA_SERVER_ADDRESS=staging.seudominio.com
SHAMBLETA_SERVER_PORT=0
```

4. Use a separate domain/subdomain (e.g., `staging.seudominio.com`)
5. Use a separate database volume (`game-data-staging`)

## Docker Compose Override

Create `deploy/docker-compose.staging.yml`:

```yaml
services:
  web:
    environment:
      - SHAMBLETA_SERVER_ADDRESS=staging.seudominio.com
      - SHAMBLETA_SERVER_PORT=0
  game:
    environment:
      - SHAMBLETA_ENV=staging
  companion:
    environment:
      - SHAMBLETA_WEBHOOK_PROVIDER=shared
      - SHAMBLETA_ALLOW_DEV_WEBHOOK=1
      - SHAMBLETA_WEBHOOK_SECRET=<staging-secret>
volumes:
  game-data-staging:
```

## CI Pipeline

Add a staging deployment workflow to `.github/workflows/staging.yml`:

```yaml
name: Deploy to Staging
on:
  push:
    branches:
      - develop
jobs:
  deploy-staging:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to Coolify Staging
        run: |
          curl -X POST "https://staging.seudominio.com/api/v1/deploy" \
            -H "Authorization: Bearer ${{ secrets.COOLIFY_STAGING_TOKEN }}"
```

## Database

- Staging uses a separate SQLite database (`staging.db`)
- Database is reset weekly via cron job
- Seed data is loaded from `data/conf/staging-seed.sql`

## Testing

Staging is used for:
- QA of new features before production
- Payment flow testing (sandbox)
- Performance testing under realistic load
- Regression testing

## Access

- Web: https://staging.seudominio.com
- Game: wss://staging.seudominio.com:6108
- Companion: https://staging.seudominio.com:8901 (internal only)

## Notes

- Never use production payment credentials in staging
- Staging data is not backed up
- Staging environment is reset weekly
