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
# =============================================================================
# DECISÃO #90 (auditoria 2026-09-29): o contrato é FAIL-LOUD, com uma saída
# DECLARADA. Este header é o lugar onde a decisão mora — `deploy/OPS_RUNBOOK.md`
# é de outro dono e ainda não tem a linha (o runbook não tem um §2.1: quem cita
# "OPS_RUNBOOK.md §2.1" cita uma seção inexistente; a linha pedida ao dono está no
# relatório da rodada).
#
# O defeito que isto fecha: sem env, o render produzia config VÁLIDO com
# `webhook_configs: []` e saía 0. O `severity: page` avaliava, entrava em
# /api/v2/alerts e morria lá. "Config válido" era lido como "config certo" por
# qualquer revisão, e a ausência do incendiário era indistinguível da ausência do
# incêndio. Rotina sem destino não é "pager desligado": é pager que ninguém ligou.
#
# A tentação registrada (e recusada): o outro extremo — o `docker compose up`
# recusar o stack inteiro porque um humano não colou a URL — é pior, porque
# transforma um item de configuração faltante em indisponibilidade do jogo. O que
# se decide aqui é o meio: MORRE O CONTAINER DO ALERTMANAGER, NÃO O STACK.
#  · nada nesta stack tem `depends_on: alertmanager` (o serviço `alertmanager`
#    depende de `prometheus` em deploy/docker-compose.yml; nenhum serviço depende
#    dele — conferido pelo gate);
#  · entrypoint falhando ⇒ o container não sobe, o healthcheck não passa, e o
#    motivo é a primeira linha do log dele;
#  · `restart: unless-stopped` faz o aviso reaparecer em vez de se calar.
# Custo de falhar: um container parado com motivo escrito. Custo de não falhar:
# uma emergência silenciosa. A régua que confere os três resultados rodando este
# script de verdade está em scripts/check_compose.sh (bloco "TRÊS ESTADOS").
#
# OS TRÊS ESTADOS, e qual deles é vermelho:
#  1) DESTINO CONFIGURADO ......... env do page materializada => exit 0 e config
#                                   com `      - url:` no receiver roteado pelo page.
#  2) SEM PAGUER, DECLARADO ....... `SHAMBLETA_ALERT_NO_PAGER_ACK=1` => exit 0 com
#                                   uma linha alta em stderr EM CADA BOOT. É a saída
#                                   para staging / ambiente sem on-call humano, e é
#                                   opt-in: exige um gesto explícito de quem opera,
#                                   não um esquecimento.
#  3) SEM PAGUER, SILENCIOSO ...... nem env nem ack => exit != 0 antes do exec. É o
#                                   estado que esta mudança mata, e o ÚNICO vermelho.
# Distinguir 2 de 3 é todo o ponto: env vazia não é uma decisão, é a ausência dela.
# Só o valor exato `1` declara; `0`, vazio, `true`, `yes` continuam sendo silêncio.
#
# Fail-loud pré-existente, preservado e alargado: destino existe mas é malformed =>
# exit != 0 (um `page` apontando para um host que não existe é pior do que não
# apontar para nenhum). O mesmo vale para receiver do page SEM marcador, e para um
# roteamento `severity: page` que não se consegue ler — esses três NÃO têm saída
# declarada, porque "config quebrado" não é "pager desligado": ack não abençoa
# config quebrado.
# =============================================================================
#
# Portabilidade: só builtins de POSIX sh (`read`, `printf`, `case`, redireção).
# Sem `sed`, sem `awk`, sem `envsubst` — a base da imagem é
# `quay.io/prometheus/busybox` (linha 3 do Dockerfile upstream do
# prom/alertmanager, conferido em 2026-09-28), mas o conjunto exato de applets
# habilitados não foi conferido nesta máquina (não há docker aqui). Depender de
# `sed` seria prometer uma imagem que ninguém abriu. Por isso também a derivacão
# de roteamento abaixo é feita com `case` e fatiamento de string, não com parser.
#
# Nunca imprime o valor do webhook: log de container é legível por qualquer um com
# acesso ao host, e o URL é credencial. Os diagnósticos nomeiam ENV e RECEIVER,
# nunca conteúdo.

set -u

TMPL="${ALERTMANAGER_TEMPLATE:-/etc/alertmanager/alertmanager.yml.tmpl}"
OUT="${ALERTMANAGER_CONFIG:-/etc/alertmanager/alertmanager.yml}"
MARKER='@@ALERTWEBHOOK:'
NL='
'
# Um backslash literal, para o teste de URL abaixo.
BS='\'
# Estado 2: "este ambiente não tem on-call humano, e eu decidi isso".
NO_PAGER_ACK="${SHAMBLETA_ALERT_NO_PAGER_ACK:-0}"

die() {
	printf 'alertmanager-config: %s\n' "$1" >&2
	exit 1
}

has_token() { # $1 = lista separada por espaço, $2 = token
	case " $1 " in
	*" $2 "*) return 0 ;;
	esac
	return 1
}

# Espaço das pontas fora (inclui CR de arquivo editado no Windows).
strip() {
	local_trim="$1"
	local_trim="${local_trim#"${local_trim%%[![:space:]]*}"}"
	printf '%s' "${local_trim%"${local_trim##*[![:space:]]}"}"
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

# ------------------------------------------------------------------ roteamento
# "Quem acorda quando `severity: page` dispara" nao e suposicao nossa: e o que o
# proprio arquivo diz, lido em uma passada:
#   page_receivers   receivers alcancados por uma rota com severidade `page`
#   all_routed       todo receiver nomeado por qualquer `receiver:` (rota ou default)
#   marked_receivers receivers com marcador de destino na linha do webhook_configs
#                    (ou seja, que PODERIAM ter destino)
#   destined         receivers cujo marcador foi materializado neste boot
# Contar marcadores no arquivo inteiro nao servia: um receiver que nenhuma rota
# alcanca nao e um pager quebrado, e um pager quebrado nao e um config sem env.
in_receivers=0
pending_page=0
current_receiver=""
page_receivers=""
all_routed=""
marked_receivers=""
destined=""
rendered=0

while IFS= read -r line || [ -n "$line" ]; do
	# Linha de comentario puro NUNCA e destino: e documentacao. Sem esta excecao,
	# o cabecalho do proprio template (que explica o formato do marcador) seria
	# lido como um receiver e o render morreria no texto que existe para ensinar
	# o formato. A regra espelhada esta em scripts/check_compose.sh.
	trim="$(strip "$line")"
	case "$trim" in
	'#'*)
		printf '%s\n' "$line"
		continue
		;;
	esac

	# --- deriva o roteamento antes de tratar o marcador -------------------------
	case "$trim" in
	receivers:)
		in_receivers=1
		;;
	"- name:"*)
		if [ "$in_receivers" -eq 1 ]; then
			current_receiver="$(strip "${trim#- name:}")"
		fi
		;;
	"receiver:"*)
		rname="$(strip "${trim#receiver:}")"
		rname="${rname#\"}"
		rname="${rname%\"}"
		rname="${rname#\'}"
		rname="${rname%\'}"
		all_routed="$all_routed $rname"
		# A rota do page e `- match:` com `severity: page` e o `receiver:` logo
		# abaixo; marcar na descida e o que separa o page do default do route.
		if [ "$pending_page" -eq 1 ]; then
			has_token "$page_receivers" "$rname" || page_receivers="$page_receivers $rname"
			pending_page=0
		fi
		;;
	severity:*)
		sval="$(strip "${trim#severity:}")"
		sval="${sval#\"}"
		sval="${sval%\"}"
		case "$sval" in
		page) pending_page=1 ;;
		*) pending_page=0 ;;
		esac
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
		[ -n "$current_receiver" ] || die "marcador na linha '$trim' nao esta dentro de nenhum bloco de receiver (o render nao sabe a quem pertence o destino)"
		marked_receivers="$marked_receivers $current_receiver"
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
			# com webhook_configs vazio. O veredito por esse vazio sai no fim da
			# passada, porque aqui ainda nao se sabe se o receiver e o do page.
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
		destined="$destined $current_receiver"
		rendered=$((rendered + 1))
		;;
	*)
		printf '%s\n' "$line"
		;;
	esac
done < "$TMPL" > "$OUT"

# ------------------------------------------------------------------ veredito
# Ordem dos testes: primeiro o que NAO tem saida (config quebrado), depois o que
# tem (destino faltando), e so ai o ack entra em jogo.
if [ -z "$page_receivers" ]; then
	die "nenhum receiver alcancado por 'severity: page' foi lido do template (receivers nomeados por rota: ${all_routed:-nenhum}). 'O page acorda quem' deixou de ser uma proposicao verificavel: isto e config quebrado, nao config sem pager, e SHAMBLETA_ALERT_NO_PAGER_ACK nao cobre config quebrado."
fi
orphan_markers=""
for r in $marked_receivers; do
	has_token "$all_routed" "$r" || orphan_markers="$orphan_markers $r"
done

missing_page=""
for r in $page_receivers; do
	if ! has_token "$marked_receivers" "$r"; then
		die "receiver '$r' e alcancado por 'severity: page' mas nao tem marcador de destino na linha webhook_configs: nao ha o que materializar, logo nao ha pager. Config quebrado — SHAMBLETA_ALERT_NO_PAGER_ACK nao cobre config quebrado."
	fi
	if ! has_token "$destined" "$r"; then
		missing_page="$missing_page $r"
	fi
done
missing_other=""
for r in $all_routed; do
	if has_token "$page_receivers" "$r"; then
		continue
	fi
	if has_token "$marked_receivers" "$r" && ! has_token "$destined" "$r"; then
		missing_other="$missing_other $r"
	fi
done

if [ -n "$missing_other" ]; then
	# Ticket sem destino e degradacao visivel, nao emergencia muda: o alerta fica
	# no /api/v2/alerts e alguem le no painel. Grita em todo boot, nao morre.
	printf 'alertmanager-config: AVISO - receivers roteados sem destino humano:%s. O alerta avalia e fica em /api/v2/alerts.\n' "$missing_other" >&2
fi
if [ -n "$orphan_markers" ]; then
	printf 'alertmanager-config: AVISO - marcador de destino em receiver que nenhuma rota alcansa:%s (destino que ninguem usa).\n' "$orphan_markers" >&2
fi

if [ -n "$missing_page" ]; then
	if [ "$NO_PAGER_ACK" = "1" ]; then
		# Estado 2: sem paguer, DECLARADO. Sobe, e grita a cada boot.
		printf 'alertmanager-config: SEM PAGUER, DECLARADO (SHAMBLETA_ALERT_NO_PAGER_ACK=1): receivers do severity:page sem destino:%s. O stack sobe; um page disparado nao acorda ninguem e fica em /api/v2/alerts ate alguem abrir o painel. Esta linha vai aparecer em todo boot enquanto o ack estiver posto - e assim que o estado "sem pager" fica visivel em vez de silencioso.\n' "$missing_page" >&2
		exit 0
	fi
	die "SEM DESTINO PARA O 'severity: page': receivers$missing_page, e nenhuma env de destino deles esta posta. Isto e configuracao INCOMPLETA, nao segura: o page avaliaria, entraria em /api/v2/alerts e morreria la sem acordar ninguem. Conserte uma das duas: (a) declare a URL de webhook do on-call na env do receiver do page (o nome esta no marcador deste config; o valor NAO se escreve no repo - e credencial), ou (b) declare explicitamente que este ambiente nao tem paguer: SHAMBLETA_ALERT_NO_PAGER_ACK=1, que sobe o container e imprime o aviso em todo boot."
fi

printf 'alertmanager-config: %d receiver(s) com destino humano materializado; receivers do page:%s; sem destino: %s. Nunca se imprime o valor do URL.\n' \
	"$rendered" "${page_receivers# }" "${missing_page# }" >&2
exit 0
