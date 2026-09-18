# Shambleta — Cloudflared Tunnel (Cloudflare Zero Trust)

O jogo pode ser exposto via Cloudflare Tunnel sem abrir portas no firewall da VPS Ampere A1.
Isso substitui (ou complementa) o proxy TLS do Coolify.

## Configuração

1. Obtenha o token do Cloudflare Zero Trust (Dashboard → Access → Tunnels).
2. Defina a variável de ambiente no deploy (Coolify ou docker-compose):
   ```env
   CLOUDFLARED_TOKEN=<token-do-tunnel>
   ```
3. O serviço `cloudflared` (adicionado ao docker-compose.yml) conecta ao tunnel.
4. O `game` continua bindando WebSocket plain (`ws://` na 6108) — o cloudflared faz o WSS.

## Vantagens sobre Coolify proxy (opcional)
- Não precisa do proxy Traefik do Coolify para TLS.
- Funciona com qualquer domínio (não precisa apontar A record para o Coolify).
- A landing (`/landing/`) e o jogo (`/index.html`) são servidos pelo nginx como antes.

## Observação de segurança
- O `game` ainda deve rodar com `SHAMBLETA_PROXY_TLS=1` (TLS terminado no proxy — seja Coolify ou Cloudflare).
- Certificados locais (`user://server.crt`) ainda são necessários apenas se o server for exposto diretamente (sem proxy).

## VPS Ampere A1 (2 vCPU / 12 GB)
O container `cloudflared` adiciona ~50 MB de RAM e pouca CPU. A folga (~10 GB) não é afetada.

## Arquivos modificados
- `deploy/docker-compose.yml`: serviço `cloudflared` adicionado
- `deploy/web/Dockerfile`: comentário sobre cloudflared adicionado
- `deploy/web/nginx.conf`: nota sobre proxy do Cloudflare adicionada
- `deploy/cloudflared.md`: documentação completa (novo arquivo)
