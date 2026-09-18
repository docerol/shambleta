#!/bin/bash
# Gera certificados self-signed para dev/test (não usar em produção com dinheiro real).
# Em produção, use SHAMBLETA_PROXY_TLS=1 (Coolify) ou Let's Encrypt.
DOMAIN=${1:-localhost}
mkdir -p deploy/web/certs
openssl req -x509 -newkey rsa:2048 -keyout deploy/web/certs/server.key -out deploy/web/certs/server.crt -days 365 -nodes -subj "/CN=$DOMAIN" 2>/dev/null
echo "Certificados gerados: deploy/web/certs/server.crt + server.key"
