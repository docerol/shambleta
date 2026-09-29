# Alertmanager da stack Shambleta — para onde as regras de `deploy/alerts.rules.yml`
# vão depois de avaliadas (route por `severity`, com `page` separado de `ticket`).
# Build context: RAIZ do repositório (mesma convenção dos outros Dockerfiles).
#
# Correção de fato (2026-09-28): este arquivo afirmava que a imagem oficial "não
# traz shell". Não é verdade — o Dockerfile de release do prom/alertmanager
# (https://github.com/prometheus/alertmanager/blob/v0.34.1/Dockerfile) faz
# `FROM quay.io/prometheus/busybox-${OS}-${ARCH}` na linha 3, então `/bin/sh`
# EXISTE, e a linha 9 do mesmo arquivo copia `/bin/amtool`, que é justamente o
# `amtool check-config` que o gate agora roda. O que continua verdade: não existe
# variante `-busybox` do `prom/alertmanager` (a API de tags do Docker Hub devolve
# só `v0.34.1` e `v0.34.0` para o filtro `name=v0.34`), porque busybox JÁ É a
# base. O serviço `alertmanager` no compose agora TEM healthcheck (`wget` do
# mesmo busybox, porta 9093): a forma é a do probe do `prometheus`, e o applet
# exato não foi aberto nesta máquina (sem docker) — o que se confere no primeiro
# deploy está em deploy/OPS_RUNBOOK.md §2.2.
#
# Para que serve o segundo COPY: o Alertmanager não interpola ambiente no config,
# e o destino humano do `severity: page` é segredo de deploy (URL de webhook =
# credencial, e este repo é open source). Então o config versionado traz um
# marcador por receiver e este entrypoint materializa o destino a partir de
# `SHAMBLETA_ALERT_PAGE_WEBHOOK_URL` / `SHAMBLETA_ALERT_TICKET_WEBHOOK_URL` antes
# do exec. Sem as envs, o arquivo renderizado é o próprio template: config válido,
# rota intacta, ninguém acordado — e é o gate, não o `up`, que reclama
# (deploy/OPS_RUNBOOK.md §2.1).
FROM prom/alertmanager:v0.34.1

# `.tmpl` de propósito: o caminho final é o que o `--config.file` do compose já
# aponta, e é escrito pelo render no boot. Deixar o config versionado em
# /etc/alertmanager/alertmanager.yml significaria um container que pode subir com
# o arquivo cru (sem destino) sem que nada tivesse rodado o render.
COPY deploy/alertmanager.yml /etc/alertmanager/alertmanager.yml.tmpl
COPY deploy/monitoring/render-alertmanager-config.sh /etc/alertmanager/render-config.sh
# A imagem oficial traz o exemplo de HA dos docs exatamente no caminho que o
# `--config.file` do compose aponta (linha 11 do Dockerfile upstream). Apagar é o
# que faz "o render não rodou" ser um container que não sobe em vez de um cluster
# de alertas apontando para peers inventados.
RUN rm -f /etc/alertmanager/alertmanager.yml

# /bin/sh em vez do bit de execução: o mode bit de um arquivo do repo não é
# reprodutível entre builders. O diretório é gravável pelo usuário do container —
# a linha 14 do Dockerfile upstream faz `chown -R nobody:nobody /etc/alertmanager`
# e a 17 roda `USER nobody`; quem cria o arquivo renderizado é o dono do
# diretório, não o dono do arquivo.
ENTRYPOINT ["/bin/sh", "/etc/alertmanager/render-config.sh"]
CMD ["--config.file=/etc/alertmanager/alertmanager.yml", "--storage.path=/alertmanager"]
