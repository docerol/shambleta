#!/bin/sh
# Entrypoint do game server: transforma SIGTERM em DRENAGEM DE VERDADE.
#
# O problema que este arquivo resolve: o compose promete 75 s de
# `stop_grace_period` porque o drain do servidor existe — mas o drain é o canary
# (`sources/world/ShutdownCanary.gd:28-42`), que só dispara quando alguém TOCA no
# arquivo `user://canary`, à mão. O processo do jogo não trata SIGTERM (grep em
# `sources/`: nenhum handler no caminho do server; `NOTIFICATION_WM_CLOSE_REQUEST`
# só aparece em `sources/gui/Gui.gd:409`, que é client). Consequência medida antes
# desta mudança: `docker compose stop` mandava SIGTERM, o binário saía com 143 sem
# teardown, e até `BackupPlayersSec` = 600 s de ouro que só existia em memória iam
# junto (`sources/sql/SQLCommons.gd:11`), com `-wal` órfão.
#
# O que fazer ao receber TERM/INT não é reinventar shutdown: é tocar o MESMO canary
# que o runbook manda tocar à mão (deploy/OPS_RUNBOOK.md §3), para que `docker
# compose stop`, o redeploy do Coolify e o `stop` manual caiam no mesmo caminho —
# recusa conexões novas, avisa em 30 s e 15 s, derruba os peers, chama
# `Launcher.Quit()` (sources/launcher/Launcher.gd:166-172) e fecha o SQLite.
#
# Prova de que o watcher está armado, e não só de que o diretório existe:
# `ShutdownCanary.Start()` APAGA o canary no boot (sources/world/ShutdownCanary.gd:21).
# Então, se depois de escrever o arquivo ele some sozinho, o `CheckCanary` está
# rodando e a drenagem começou. Se ele continua lá, o processo ainda está em boot
# (migrations + mundo) ou travado — e o canary nunca seria lido. Nesse caso este
# script avisa em voz alta e deixa o watchdog abaixo encaminhar SIGTERM ao filho
# (o comportamento antigo, exit 143). Sem isso, "drena" seria uma promessa que vale
# só quando o servidor já terminou de subir — que é exatamente quando ninguém quer
# parar.
#
# Por que o timeout é um watchdog em background e não um laço `kill -0`: um
# processo que já morreu mas ainda não foi colhido pelo `wait` do shell é um zumbi,
# e `kill -0` responde "vivo" para zumbi em qualquer shell POSIX. Um laço de
#polling acusaria "falha do drain" em todo drain BEM-SUCEDIDO que terminasse antes
# do `wait` colher — o oposto do que um runbook precisa. O watchdog só fala se o
# `wait` ainda estiver bloqueado quando ele dispara.
#
# Orçamento (conferido por `scripts/check_compose.sh` contra o compose, e os três
# números são lidos DAS LINHAS ABAIXO, não de memória):
#   10 s de detecção (2 batidas de `checkInternalSec`, sources/world/ShutdownCanary.gd:5)
#   + 30 + 15 s dos avisos (ShutdownCanary.gd:10-13) + 2 s de join do worker de backup
#   (sources/sql/SQLCommons.gd:10) = 57 s de drain, que têm de caber nos 62 s de
#   DRAIN_TIMEOUT_SEC — o teto é contado DO SINAL, não do fim da detecção.
#   62 + 6 de graça antes do KILL = 68 s < `stop_grace_period: 75s` do compose, então
#   o SIGKILL que pode fechar o container é do docker, e só acontece se ESTE script
#   já estiver preso (o que é um bug para abrir, não um plano).
#
# `exec "$@"` no caminho feliz não cabe aqui: o shell precisa continuar vivo como
# supervisor do filho — se ele sair antes, o docker encerra o container e o drain
# é cortado no meio.

set -u

# user:// do Godot 4 com HOME=/data (ENV HOME em deploy/server/Dockerfile) e
# config/custom_user_dir_name="Shambleta" (project.godot) ->
# $HOME/.local/share/Shambleta. Os dois são conferidos contra o fonte por
# `scripts/check_compose.sh`, que também confere o nome do arquivo contra
# Path.CanaryFile (sources/system/Path.gd:56).
USER_DIR="${HOME:-/data}/.local/share/Shambleta"
CANARY_FILE="$USER_DIR/canary"

# 2 batidas do CheckCanary (5 s cada, sources/world/ShutdownCanary.gd:5).
CANARY_DETECT_SEC="${SHAMBLETA_CANARY_DETECT_SEC:-10}"
# Teto absoluto contando DO SINAL, esperando o Quit() do jogo. Menor que o
# stop_grace_period do compose de propósito: quem mata por fora tem de ser o
# docker, não um número solto neste script.
DRAIN_TIMEOUT_SEC="${SHAMBLETA_DRAIN_TIMEOUT_SEC:-62}"
# Graça entre o TERM encaminhado (drain falhou; não há mais o que esperar limpo)
# e o KILL. Somado acima é o que faz o pior caso caber no grace do compose.
KILL_GRACE_SEC=6

log() {
	printf 'entrypoint: %s\n' "$*"
}

signal=""
on_signal() {
	signal="$1"
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

"$@" &
child=$!
log "server como pid $child; SIGTERM -> canary $CANARY_FILE"

# Caminho normal: fica em `wait`, a única forma de o trap rodar sem atraso (um
# `sleep` em primeiro plano seguraria o sinal até ele voltar).
wait "$child"
rc=$?

if [ -z "$signal" ]; then
	# O processo saiu por conta própria (crash, ou Quit() pedido de dentro):
	# propaga o código para o `restart: unless-stopped` decidir com o número certo.
	exit "$rc"
fi

if ! kill -0 "$child" 2>/dev/null; then
	# O filho morreu junto com o sinal. `wait` de um pid já colhido devolve 127
	# ("não há esse filho") em alguns shells POSIX, e 127 não é o código do jogo:
	# nesse caso fica o >128 do próprio sinal, que é o que um supervisor precisa
	# ver ("saiu porque pediram", não "crashou").
	wait "$child" 2>/dev/null
	rc2=$?
	[ "$rc2" = 127 ] && rc2=$rc
	exit "$rc2"
fi

log "recebi SIG$signal; pedindo drain pelo canary"

# Watchdog primeiro, ANTES de escrever o canary: o teto é contado do sinal, senão o
# pior caso (detecção + teto + graça do KILL) estouraria o `stop_grace_period` do
# compose e quem mataria o processo seria o docker no meio do Quit(). Roda em
# subshell porque `wait "$child"` é a única coisa que sabe quando ele morreu.
(
	sleep "$DRAIN_TIMEOUT_SEC"
	log "TETO DE DRAIN (${DRAIN_TIMEOUT_SEC}s) ATINGIDO sem o servidor sair; encaminhando TERM"
	kill -TERM "$child" 2>/dev/null
	sleep "$KILL_GRACE_SEC"
	log "sem resposta ao TERM; KILL"
	kill -KILL "$child" 2>/dev/null
) &
watchdog=$!

drained=0
if [ -d "$USER_DIR" ]; then
	: > "$CANARY_FILE" 2>/dev/null || log "AVISO: nao consegui escrever $CANARY_FILE"
	i=0
	while [ "$i" -lt "$CANARY_DETECT_SEC" ]; do
		sleep 1
		i=$((i + 1))
		[ -e "$CANARY_FILE" ] || { drained=1; break; }
	done
else
	log "AVISO: $USER_DIR ainda nao existe (boot nao terminou); o canary seria ignorado"
fi

[ "$drained" = 1 ] || log "FALHA DO DRAIN: canary nao foi lido (janela de ${CANARY_DETECT_SEC}s; boot em curso, servidor travado, ou o processo ja saiu); drenagem abortada"

wait "$child"
rc=$?
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null

exit "$rc"
