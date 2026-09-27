# Alertmanager da stack Shambleta — para onde as regras de `deploy/alerts.rules.yml`
# vão depois de avaliadas (route por `severity`, com `page` separado de `ticket`).
# Build context: RAIZ do repositório (mesma convenção dos outros Dockerfiles).
#
# Imagem oficial sem shell: por isso o serviço `alertmanager` no compose NÃO tem
# healthcheck — um probe que não tem com o que rodar é ruído, não sinal (mesmo
# critério do `cloudflared`). Verificar vida daqui é por fora, e o comando está em
# deploy/OPS_RUNBOOK.md §2.
FROM prom/alertmanager:v0.34.1

COPY deploy/alertmanager.yml /etc/alertmanager/alertmanager.yml
