# Shambleta companion v0 — fronteira de dinheiro real (webhooks de pagamento).
# Build context: RAIZ do repositório (dockerfile: deploy/companion/Dockerfile).
#
# Requer (env no Coolify):
#   SHAMBLETA_WEBHOOK_PROVIDER = mercadopago (produção, default do compose) |
#                               stripe (alternativa) | shared (sandbox, exige allow-dev)
#   mercadopago: SHAMBLETA_MP_WEBHOOK_SECRET (credencial do endpoint) obrigatório e
#                SHAMBLETA_MP_ACCESS_TOKEN para o re-fetch autoritativo do payment
#   stripe:      SHAMBLETA_STRIPE_WEBHOOK_SECRET (whsec_...) obrigatório
#   shared:      SHAMBLETA_WEBHOOK_SECRET + SHAMBLETA_ALLOW_DEV_WEBHOOK=1 (nunca p/ real)
#   SHAMBLETA_MP_BACK_URLS_BASE = origem pública do jogo (ex.: https://seudominio.com);
#                os back_urls da preferência apontam para <base>/checkout_return.html,
#                que é a página copiada na raiz do serviço `web`. Vazio = sem back_urls.
#   opcional: SHAMBLETA_CATALOG_FILE (JSON SKU->grant), SHAMBLETA_WEBHOOK_TOLERANCE
#   (o catálogo canônico do repositório — data/conf/paid_catalog.json — é copiado
#   para /app abaixo e vira o default; sem ele, restaria o embutido DEFAULT_CATALOG)

#
# Compartilha o volume /data com o serviço `game`: o companion grava em
# grant_queue no MESMO SQLite (WAL). Só vale em single-node; multi-node = Postgres.
FROM python:3.12-alpine
WORKDIR /app
COPY companion/server.py .
# Fonte única do catálogo pago: o mesmo arquivo que o jogo valida no boot.
COPY data/conf/paid_catalog.json .
EXPOSE 8901
# Bind na interface do container, não no loopback: `companion/server.py` lê
# SHAMBLETA_COMPANION_HOST com default 127.0.0.1 (main(), antes do
# ThreadingHTTPServer), que dentro de um container é inatingível de fora — o
# proxy do serviço `web` (deploy/web/nginx.conf) e qualquer outro destino
# morreriam em connection refused na frente do dinheiro.
# Continuar privado é o compose quem garante: nenhum `ports:` para companion, e
# o único caminho de entrada é o proxy same-origin.
ENV SHAMBLETA_COMPANION_HOST=0.0.0.0
# user:// do game server com HOME=/data: Godot 4 + config/use_custom_user_dir=true
# escreve em $HOME/.local/share/Shambleta/ (NÃO no godot/app_userdata/ do Godot 3).
# Apontar para o layout antigo faz o companion sair com "database not found" e o
# grant de cada compra cai numa fila que ninguém consome.
CMD ["python3", "server.py", \
     "--db", "/data/.local/share/Shambleta/live.db", \
     "--port", "8901"]
