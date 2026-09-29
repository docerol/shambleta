#!/bin/sh
# Renderiza o config do Alertmanager no boot do container.
#
# Por que existe: o Alertmanager NÃO interpola variável de ambiente no arquivo de
# config (não existe `${...}` no schema dele — o que ele lê é YAML literal), e o
# destino humano do `severity: page` é um segredo de deploy (a URL de webhook de
# Slack/PagerDuty/on-call É uma credencial: quem a tem publica no canal de
# emergência). Num repositório open source o arquivo versionado não pode conter o
# valor, e um valor inventado faria o `page` falar sozinho. Este script é a ponte:
# o arquivo versionado traz o marcador, o valor vem do ambiente, e o caminho que o
# `--config.file` do compose aponta não muda.
#
# O arquivo de saída tem sempre o mesmo caminho, com ou sem segredo: sem env, o
# resultado é byte-a-byte o template (`webhook_configs: []` — config válido, rota
# intacta, destino ausente). Essa é a escolha (b) registrada em
# deploy/OPS_RUNBOOK.md §2.1: o stack sobe sem pager e a régua acusa; não é o
# `up` que recusa subir.
#
# Fail-loud deliberado: se o destino existe mas é malformed, este script sai != 0
# ANTES do exec — o container não sobe com um `page` apontando para um host que
# não existe, que é pior do que não apontar para nenhum.
#
# Portabilidade: só builtins de POSIX sh (`read`, `printf`, `case`, redireção).
# Sem `sed`, sem `awk`, sem `envsubst` — a base da imagem é
# `quay.io/prometheus/busybox` (linha 3 do Dockerfile upstream do
# prom/alertmanager, conferido em 2026-09-28), mas o conjunto exato de applets
# habilitados não foi conferido nesta máquina (não há docker aqui; comando em
# deploy/OPS_RUNBOOK.md §2.2). Depender de `sed` seria prometer uma imagem que
# ninguém abriu.
#
# Nunca imprime o valor do webhook: log de container é legível por qualquer um com
# acesso ao host, e o URL é credencial.

set -u

TMPL="${ALERTMANAGER_TEMPLATE:-/etc/alertmanager/alertmanager.yml.tmpl}"
OUT="${ALERTMANAGER_CONFIG:-/etc/alertmanager/alertmanager.yml}"
MARKER='@@ALERTWEBHOOK:'
NL='
'
# Um backslash literal, para o teste de URL abaixo.
BS='\'

die() {
	printf 'alertmanager-config: %s\n' "$1" >&2
	exit 1
}

[ -r "$TMPL" ] || die "template ilegivel em $TMPL (o Dockerfile copia deploy/alertmanager.yml para la)"

# O alvo tem de ser gravavel; morremos aqui, e nao no meio do exec. O `( ... )`
# nao e decoracao: quando a redirecao falha, e o PROPRIO shell que reclama, e a
# reclamacao sai antes de qualquer `2>/dev/null` da linha simples — sem o subshell
# o diagnostico do die abaixo viria acompanhado de um erro bruto de shell.
if ! ( : > "$OUT" ) 2>/dev/null; then
	die "nao consegui escrever $OUT"
fi

# Aceita so http(s) e recusa as tres formas que quebrariam o YAML gerado: aspas
# duplas, barra invertida e newline (este ultimo viraria uma linha nova dentro do
# config). Espaco tambem fora.
url_is_valid() {
	case "$1" in
	http://* | https://*) : ;;
	*) return 1 ;;
	esac
	case "$1" in
	*'"'*) return 1 ;;
	*"$BS"*) return 1 ;;
	*"$NL"*) return 1 ;;
	*" "*) return 1 ;;
	*"$MARKER"*) return 1 ;;
	esac
	return 0
}

rendered=0
while IFS= read -r line || [ -n "$line" ]; do
	# Linha de comentario puro NUNCA e destino: e documentacao. Sem esta excecao,
	# o cabecalho do proprio template (que explica o formato do marcador) seria
	# lido como um receiver e o render morreria no texto que existe para ensinar
	# o formato. A regra espelhada esta em scripts/check_compose.sh.
	trim="${line#"${line%%[![:space:]]*}"}"
	case "$trim" in
	'#'*)
		printf '%s\n' "$line"
		continue
		;;
	esac
	case "$line" in
	*"$MARKER"*)
		# Um marcador so pode morar na linha que ele substitui. Se ele migrou para
		# outro lugar do arquivo, "sem destino" e o resultado silencioso — e
		# resultado silencioso e exatamente o que este script recusa produzir.
		case "$trim" in
		webhook_configs:*) : ;;
		*) die "marcador fora da linha de webhook_configs (linha: $trim)" ;;
		esac
		var="${line#*"$MARKER"}"
		var="${var%%@@*}"
		# O NOME e lido do arquivo antes de virar chave de `eval`, entao a forma
		# dele e conferida primeiro: sem isso, um marcador corrompido no template
		# seria codigo de shell. `eval` so roda depois dos dois testes.
		case "$var" in
		SHAMBLETA_ALERT_*_WEBHOOK_URL) : ;;
		*) die "marcador aponta para um nome fora de SHAMBLETA_ALERT_*_WEBHOOK_URL" ;;
		esac
		case "$var" in
		*[!A-Za-z0-9_]*) die "marcador com nome malformed (so A-Z0-9_): $var" ;;
		esac
		eval "val=\${$var:-}"
		if [ -z "$val" ]; then
			# Sem destino: a linha do template sai como entrou, que e YAML valido
			# com webhook_configs vazio.
			printf '%s\n' "$line"
			continue
		fi
		url_is_valid "$val" || die "$var nao e uma URL http(s) valide (valor ocultado)"
		# Substitui a linha inteira pelo bloco de destino. A indentacao e fixa de
		# proposito: receivers a dois espacos, webhook_configs a quatro, item a
		# seis -- e o gate confere essa paridade contra o template.
		printf '    webhook_configs:\n'
		printf '      - url: "%s"\n' "$val"
		printf '        send_resolved: true\n'
		rendered=$((rendered + 1))
		;;
	*)
		printf '%s\n' "$line"
		;;
	esac
done < "$TMPL" > "$OUT"

if [ "$rendered" -eq 0 ]; then
	printf 'alertmanager-config: nenhum receiver com destino humano (nem SHAMBLETA_ALERT_PAGE_WEBHOOK_URL nem SHAMBLETA_ALERT_TICKET_WEBHOOK_URL). O routing por severidade esta de pe e o `severity: page` nao acorda ninguem: configuracao incompleta, nao segura.\n' >&2
fi
exit 0
