# Prometheus da stack Shambleta — imagem de config, não de código.
# Build context: RAIZ do repositório (mesma convenção de deploy/web/Dockerfile e
# deploy/server/Dockerfile, e o mesmo `context: .` do deploy/docker-compose.yml).
#
# Por que COPY em vez de bind-mount: as regras que pagam têm de viajar com o
# release. Um `./alerts.rules.yml:/etc/prometheus/...` sobrevive ao `git pull` mas
# não a um host trocado de propósito — e regra de alerta que só existe no host é a
# classe de coisa que some num rebuild e continua "ligada" no painel. O gate
# (`scripts/check_compose.sh`) confere que ESTE arquivo embarca o `deploy/alerts.rules.yml`
# que o `deploy/prometheus.yml` referencia.
#
# Variante `-busybox` de propósito: é a única que traz `/bin/sh` + `wget`, e sem
# elas o healthcheck do compose seria um probe que falha por falta de ferramenta
# (mesmo critério que deixou `cloudflared` sem probe em deploy/docker-compose.yml).
FROM prom/prometheus:v3.15.0-busybox

# /etc/prometheus/prometheus.yml é o default do binário; o path do --config.file no
# command do compose aponta para cá explicitamente, para não depender de default.
COPY deploy/prometheus.yml /etc/prometheus/prometheus.yml
COPY deploy/alerts.rules.yml /etc/prometheus/alerts.rules.yml

# Sem ENTRYPOINT próprio: o command do compose decide escuta, config e retenção.
