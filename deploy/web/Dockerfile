# Shambleta web client — build multi-stage para Coolify.
# Build context: RAIZ do repositório (dockerfile: deploy/web/Dockerfile).
#
# ARGs de build (setar na UI do Coolify, "Build Arguments"):
#   SHAMBLETA_SERVER_ADDRESS — domínio do jogo apontando para o serviço `game`
#       no Coolify (ex.: ws.seudominio.com). Vai embutido no pck; o client web
#       conecta wss://<address> (TLS na 443 é do proxy do Coolify).
#   SHAMBLETA_SERVER_PORT    — opcional (default 0 = URL sem porta, usa 443).
#
# O [Network] gravado aqui vai no settings.cfg embutido no pck — sem segredos.
# Credenciais reais (Email) são exclusivas do container `server`.
FROM barichello/godot-ci:4.7.1 AS build
ARG SHAMBLETA_SERVER_ADDRESS=""
ARG SHAMBLETA_SERVER_PORT="0"

WORKDIR /project
COPY . .

# Endpoint público embutido (Launcher._ready lê [Network] do settings.cfg).
RUN sed -i "s|^Server-Address=.*|Server-Address=\"${SHAMBLETA_SERVER_ADDRESS}\"|; s|^Server-Port=.*|Server-Port=${SHAMBLETA_SERVER_PORT}|" data/conf/settings.cfg

# Import de assets + export web (pasta destino precisa existir ANTES: o plugin
# do Sentry copia sentry-bundle.js no export_begin e aborta se o dir não existe).
RUN godot --headless --editor --import --quit || true
RUN mkdir -p /out/Web \
  && godot --headless --path . --export-release "Web" /out/Web/index.html

FROM nginx:1.27-alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY deploy/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /out/Web/ /usr/share/nginx/html/
COPY deploy/web/landing/ /usr/share/nginx/html/landing/
# SOM-IDLE checkout: página de retorno do Mercado Pago (back_urls do
# companion apontam p/ <base>/checkout_return.html — o grant chega pelo
# webhook, esta página é só UX para não prender o jogador).
COPY deploy/web/checkout_return.html /usr/share/nginx/html/checkout_return.html
# SOM-W5/A: ponte de rewarded ads servida de verdade (nginx: no-cache). Carregada
# pelo index só com o SDK do portal; sem ela o client cai no stub local. O
# simulador dela é off por default — ligável só com ?adstest=1 na URL.
COPY deploy/web/ads_bridge.js /usr/share/nginx/html/ads_bridge.js
# SOM-W5/B: worker fino de push. ESTAR servido não é ser registrado: o registro
# em "/" continua atrás de WebPush.CanDeliver() (false até o sender VAPID
# existir), porque registrar por cima deslocaria o worker do engine
# (index.service.worker.js — COOP/COEP + cache de assets).
COPY deploy/web/sw.js /usr/share/nginx/html/sw.js
# SOM-IDLE P1: música servida separadamente para não pesar no primeiro load.
# Os arquivos .ogg ficam em /usr/share/nginx/music/ e são servidos por /music/.
COPY data/music/ /usr/share/nginx/music/
# Finding #89 (2026-09-29): até aqui este build só COPIAVA o nginx.conf — um arquivo
# que o nginx recusa (diretiva fora de contexto, `location` duplicada, chave sem
# fechar, `proxy_pass` com variável sem `resolver`) atravessava o build verde e só
# falhava no boot do container, no meio de um deploy. `nginx -t` aqui é o validador
# do próprio software que vai servir: mesmo binário, mesma versão 1.27 do produção,
# mesma config de nível `http` que o nginx.conf da imagem monta em torno de
# conf.d/default.conf. Uma imagem que existe foi validada — não é uma asserção de
# README nem um smoke que "pula quando não tem nginx": o build inteiro é o smoke.
RUN nginx -t
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1/ >/dev/null 2>&1 || exit 1
# NOTA: para expor via Cloudflare Tunnel (WSS sem abrir portas), configure
# CLOUDFLARED_TOKEN no ambiente do serviço cloudflared (docker-compose.yml).
# O proxy do Cloudflare termina TLS (como Coolify), então o server binda ws:// plain.
