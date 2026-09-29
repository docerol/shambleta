#!/usr/bin/env bash
set -euo pipefail

# Raiz do projeto derivada do lugar onde este script está (não do HOME de um
# desenvolvedor específico).
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

cd "$PROJECT"

# Mesma régua da CI: exit code sozinho não prova nada (um harness que termina em
# quit(0) sobre um segfault sai 0). Cada harness é gravado em log e passado por
# scripts/ci_gate_log.sh, que exige zero SCRIPT ERROR/Parse Error, linha de
# resultado presente, contagem de falhas lida DA LINHA e exit code conferido à
# parte. `gate <log> <marker> <script>` roda e avalia.
#
# Gate vermelho não aborta a passada: ele é anotado e o veredito sai no resumo do
# case. Um `all` que morre no primeiro gate conta uma falha por execução — e as
# três execuções perdidas desta rodada foram exatamente isso, descobrir o segundo
# problema depois de corrigir o primeiro.
FAILED_GATES=""
record_gate() {
	if [ "$1" != "0" ]; then
		FAILED_GATES="$FAILED_GATES $2"
		echo "GATE VERMELHO: $2"
	fi
}

# Um harness por vez. O log e o sandbox são nomeados por harness
# (`/tmp/shambleta-<script>.log`, `.test-home/<script>/`), então duas execuções do
# MESMO harness — um `all` meu e um harness rodando num agente, dois terminais, a
# CI e um pre-commit — escrevem no mesmo arquivo ao mesmo tempo. O veredito lido do
# log passa a ser a mistura das duas, e mistura pode ser verde falso: uma execução
# imprime `0 failures` e a outra nem terminou. O `flock` serializa por nome;
# harnesses diferentes continuam em paralelo. Onde `flock` não existe no host o
# gate roda igual (não se bloqueia o portão por falta de utilitário).
SHAMBLETA_GATE_WAIT="${SHAMBLETA_GATE_WAIT:-1800}"

_acquire() {
	# `_acquire <nome> [fd]` — o fd é argumento porque um gate pode segurar dois
	# locks ao mesmo tempo (o do harness e o do boot); com fd fixo o segundo
	# `exec` fechava o descritor do primeiro e o lock do harness ia embora junto.
	local fd="${2:-9}"
	command -v flock >/dev/null 2>&1 || return 0
	eval "exec $fd>\"/tmp/shambleta-$1.lock\""
	if ! flock -w "$SHAMBLETA_GATE_WAIT" "$fd"; then
		echo "GATE BLOQUEADO: $1 segura o lock há mais de ${SHAMBLETA_GATE_WAIT}s — outra execução do mesmo harness não foi esperada (veredito não pode ser lido de log misturado)"
		eval "exec $fd>&-"
		return 1
	fi
	return 0
}

_release() {
	local fd="${1:-9}"
	command -v flock >/dev/null 2>&1 || return 0
	eval "exec $fd>&-"
}

# DOIS locks, dois domínios. O lock por nome acima só fala do MESMO harness; o que
# derrubou a passada de 2026-09-28 não foi isso — foi um `godot -s
# tests/content_hygiene_test.gd` avulso (rodado por um agente, fora do
# scripts/test.sh, portanto sem lock nenhum) convivendo com o `all`: os dois boots
# disputam o `.godot/` compartilhado, o `testing.db` do projeto e a porta 9400 do
# probe, e o resultado não foi "verde falso" — foi SIGSEGV no teardown de três
# harnesses que não têm nada de errado (hud_decision_fit, login_hardening,
# season_campaign_alignment, todos verdes sozinhos e verdes de novo na passada
# limpa) e uma contagem de leak de 1747 onde o teto-default era 64. O `lock boot`
# serializa o boot entre duas execuções do script; o `foreign_godot_pids` pega o
# processo que não passou por aqui.
# Quem caminha na árvore de ancestrais é o outro lado deste guard: dois `all`
# simultâneos — dois terminais, um `all` e um juiz rodando um harness — não são
# "estrangeiro". Cada um já está preso nos dois locks, então um espera o outro na
# ordem certa; acusar aqui travaria o segundo portão num processo que é dele
# próprio. A isenção é por ANCESTRALIDADE declarada: algum processo da cadeia tem
# `scripts/test.sh` na linha de comando. Um `godot -s tests/<nome>.gd` cru de
# agente não tem, e continua sendo recusado. O anúncio não pode ser silencioso,
# mas também não pode ir pela saída: a SAÍDA desta função é o stream de pids, e
# foi exatamente isso que, em 2026-09-28, fez a isenção acusar — `boot_guard` lê
# `foreign_godot_pids`, vê a linha do `GATE SERIALIZADO` como se fosse pid e
# vermelha os dois portões que a isenção existia para deixar conviver. Anúncio vai
# para o stderr (onde o log do run o vê), pid vai para a stdout (onde o chamador o
# conta).
foreign_godot_pids() {
	command -v pgrep >/dev/null 2>&1 || return 0
	local mine pid pgid cwd exe anc cmd depth
	mine="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
	for pid in $(pgrep -f godot 2>/dev/null); do
		pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
		[ -n "$pgid" ] && [ "$pgid" = "$mine" ] && continue
		cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
		[ "$cwd" = "$PROJECT" ] || continue
		exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
		case "$exe" in *godot*) ;; *) continue ;; esac
		anc="$pid"
		depth=0
		while [ "$depth" -lt 16 ]; do
			cmd="$(tr '\0' ' ' < "/proc/$anc/cmdline" 2>/dev/null || true)"
			case "$cmd" in
				*scripts/test.sh*)
					echo "GATE SERIALIZADO: godot pid $pid pertence a outra instância deste script ($(printf '%s' "$cmd" | cut -c1-60)) — os locks de boot e de harness ordenam os dois, não é processo estrangeiro" >&2
					anc=""
					break ;;
			esac
			anc="$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')"
			[ -n "$anc" ] && [ "$anc" != "0" ] && [ "$anc" != "1" ] || break
			depth=$((depth + 1))
		done
		[ -n "$anc" ] || continue
		printf '%s\n' "$pid"
	done
	return 0
}

boot_guard() {
	[ "${SHAMBLETA_ALLOW_FOREIGN:-0}" = "1" ] && return 0
	local foreign tok
	foreign=""
	# A stdout de `foreign_godot_pids` é o stream de pids, e aqui só dígito conta.
	# Não é defesa contra o impossível: em 2026-09-28 a frase de isenção saiu por
	# essa mesma stdout, `boot_guard` a contou como pid e vermelhou os sete harnesses
	# que a isenção existia para deixar conviver. O anúncio mudou para o stderr; o
	# filtro é o que impede a próxima frase de fazer o mesmo estrago.
	while read -r tok; do
		case "$tok" in
			'' | *[!0-9]*) continue ;;
		esac
		foreign="$foreign $tok"
	done < <(foreign_godot_pids)
	foreign="${foreign# }"
	[ -n "${foreign// /}" ] || return 0
	echo "GATE PULADO: godot estrangeiro (pid ${foreign}) com cwd em $PROJECT. Boot dividido com quem não passou por este script corrói o veredito: o .godot/, o testing.db e a porta 9400 do probe são compartilhados, e o que se viu em 2026-09-28 foi SIGSEGV no teardown de harness sadio. Ou espera o outro processo terminar, ou roda com SHAMBLETA_ALLOW_FOREIGN=1 assumindo o risco."
	return 1
}

# Cache global de `class_name`. Um `class_name X` só resolve como identificador
# global depois que o Godot varre o projeto e regrava
# `.godot/global_script_class_cache.cfg`. Quem cria o arquivo por fora do editor
# (agente, `cp`, `git checkout`, `git pull`) deixa o cache velho, e o sintoma é o
# pior possível: `SCRIPT ERROR: Parse Error: Identifier "StreakService" not
# declared in the current scope` no BOOT de todo harness — não do arquivo novo, de
# todos. O §24-8 lê isso como gate vermelho e nada do que estava certo roda.
# A CI já se protege sozinha (`godot --headless --editor --import --quit` antes de
# cada job); localmente não havia o mesmo passo, e a diferença entre os dois
# caminhos é exatamente o tipo de surpresas que este script existe para acabar.
#
# O disparo é por mtime, não por contagem: um arquivo `.gd` mais novo que o cache
# é a condição exata do defeito, e na máquina quieta o teste sai sem gastar nada.
# Um `.gd` mais novo que o cache, ou cache ausente com `.gd` presente. `head -1`
# fecha o pipe do find de propósito, então o status da pipeline não é confiável:
# quem chama trata vazio como "nada a fazer" e ignora o código.
_stale_class_probe() {
	local cache="$PROJECT/.godot/global_script_class_cache.cfg"
	if [ ! -f "$cache" ]; then
		find sources addons tests -name '*.gd' 2>/dev/null | head -1
		return 0
	fi
	find sources addons tests -name '*.gd' -newer "$cache" 2>/dev/null | head -1
}

ensure_class_cache() {
	local stale
	stale="$(_stale_class_probe)" || true
	[ -z "$stale" ] && return 0
	if ! _acquire class_cache; then
		record_gate 1 class_cache
		return 0
	fi
	# O `--import` regrava `.godot/` inteiro: é a operação mais destrutiva para
	# rodar em paralelo com qualquer boot, inclusive o de um harness de nome
	# diferente. O lock do boot é o mesmo do `gate()`.
	if ! _acquire boot 8; then
		_release
		record_gate 1 class_cache
		return 0
	fi
	# Re-confere sob o lock: quem estava na fila pode ter acabado de importar.
	stale="$(_stale_class_probe)" || true
	if [ -n "$stale" ]; then
		echo "==> cache de class_name velho (ex.: $stale) — rodando --import"
		set +e
		timeout 900 "$GODOT" --headless --editor --import --quit > /tmp/shambleta-import.log 2>&1
		local code=$?
		set -e
		# Import falho NÃO é gate: o portão de verdade é o harness, que vai ler o
		# cache que existe. Anunciar o código é o que impede o silêncio de virar
		# "importou e ficou bom" quando não importou.
		if [ "$code" -ne 0 ]; then
			echo "    (--import saiu com $code; ver /tmp/shambleta-import.log)"
		fi
	fi
	_release 8
	_release
}

# Instabilidade contada, não escondida. O que se mediu nesta máquina em 2026-09-28:
# 60 boots da passada completa e DOIS harnesses saindo 134 (`SIGSEGV` numa thread
# worker, assinatura idêntica nos dois — mesmos offsets de engine) depois de
# imprimir `0 failures`; os mesmos dois harnesses, rodados três vezes cada um pelo
# `one` abaixo, voltaram 6/6 verdes. Então o veredito do harness está certo e o
# processo que o imprimiu não. Repetir o boot é a única leitura que distingue os
# dois estados, e ela tem teto: uma retratada por harness, nunca duas, senão o portão
# vira roleta. A recusa é por ASSINATURA, e são duas: exit ≠ 0 com o marcador dizendo
# zero falhas, ou morte por sinal (exit ≥ 128) sem marcador nenhum — o segundo caso é
# o crash que derruba o run ANTES de ele dar veredito. Harness que falha de verdade
# continua vermelho na primeira, porque aí não há contradição a resolver. Toda retratada
# acontece sob o mesmo lock de boot.
FLAKES=""

# Quantas réguas de tempo este run DECLAROU NÃO MEDIR por ruído externo. O gancho é
# `== NOISE-DECLARED: N ==`, impresso SEMPRE (inclusive N=0) por todo harness que tem
# a régua — ver `tests/multi_instance_tick_test.gd`. É ASCII porque a linha humana ao
# lado tem acento, e um portão não pode depender de normalização de Unicode. Vazio =
# o harness não tem régua de ruído; isso NÃO é zero.
#
# Porque isto existe: num host tomado (medido 2026-09-28, load 15 em 12 núcleos com um
# jogo do usuário rodando) as fences de wall-clock do degrau saíram 60,66 ms contra
# 11,11 ms medidos dois minutos antes. Vermelho ali é acusação de regressão de produto
# causada por vizinho. O harness então re-mede até achar janela limpa e, se o ruído
# vencer, marca a régua como `[RUIDO]` em vez de dar veredito. Um verde assim é verde
# com lacuna, e lacuna anunciada é diferente de lacuna escondida: o portão continua
# VERMELHO se houver falha, mas diz quantas réguas não foram lidas.
_noise_declared() {
	local log="$1"
	[ -f "$log" ] || return 0
	sed -nE 's/^== NOISE-DECLARED: ([0-9]+) ==$/\1/p' "$log" | tail -n 1
}
NOISY=""

# Durabilidade de sandbox. Medido 2026-09-28: uma passada foi morta no meio de
# `run_idle_tests`, e o processo caiu deixando no sandbox do próprio harness um
# `testing.db` de 3,4 MB com `testing.db-wal` de 16 MB e `testing.db-shm` a meio
# escrever. A passada seguinte abriu por cima e o harness morreu por sinal duas vezes —
# 134 na primeira tentativa e 134 na retratada, com os mesmos offsets de engine nas duas,
# e a retratada caiu ANTES de imprimir a linha da primeira suíte, ou seja, mais cedo que a
# tentativa que a originou. Um veredito que depende do que o run anterior deixou no disco
# não é verde nem vermelho: é roleta com histórico, e um juiz lendo aquilo anotaria crash
# no produto.
#
# O gatilho é o sentinela `.booting`, escrito antes do boot e despido só depois de um
# veredito verde: presença dele significa "o último processo deste sandbox não terminou",
# e só aí se apaga `data/` e `cache/`. Apagar sempre custaria a migração completa em cada
# um dos ~190 boots da passada; deixar passar o estado sujo custa o veredito. Despir o
# sentinela só sob veredito é o que faz a RETRATADA abrir limpo — sem isso, a segunda
# tentativa reabre exatamente o estado que derrubou a primeira, que foi o caso medido.
_reap_interrupted_sandbox() {
	local script="$1"
	local home="$PROJECT/.test-home/$script"
	[ -f "$home/.booting" ] || return 0
	if [ -e "$home/data" ] || [ -e "$home/cache" ]; then
		rm -rf "$home/data" "$home/cache"
		echo "    sandbox $script: último boot não terminou — data/ e cache/ reapados antes deste run"
	fi
	return 0
}

gate() {
	local log="$1" marker="$2" script="$3" timeout="${4:-900}"
	local attempt code verdict noise
	for attempt in 1 2; do
		if ! _acquire "$script"; then
			record_gate 1 "$script"
			return 0
		fi
		# Segundo lock, domínio diferente: o boot do projeto é compartilhado mesmo
		# quando os harnesses têm nomes diferentes (`.godot/`, `testing.db`, porta
		# 9400). Segura o boot inteiro e só o boot; a leitura do veredito acontece
		# depois de soltar.
		if ! _acquire boot 8; then
			_release
			record_gate 1 "$script"
			return 0
		fi
		# Ordem que importa: reapa ANTES de marcar presença (a ordem invertida apaga o
		# sandbox a cada boot, porque o reaper sempre vê a marca deste run), e marque
		# presença antes do godot (depois, nenhuma interrupção seria registrada).
		_reap_interrupted_sandbox "$script"
		mkdir -p "$PROJECT/.test-home/$script"
		: > "$PROJECT/.test-home/$script/.booting"
		set +e
		env XDG_DATA_HOME="$PROJECT/.test-home/$script/data" \
			XDG_CACHE_HOME="$PROJECT/.test-home/$script/cache" \
			timeout "$timeout" "$GODOT" --headless --path . -s "tests/$script.gd" > "$log" 2>&1
		code=$?
		set -e
		_release 8
		echo "godot exit=$code" >> "$log"
		verdict=0
		bash scripts/ci_gate_log.sh "$log" "$marker" "$code" "$script" || verdict=$?
		# Verde = o sandbox terminou como acabou. Vermelho com crash deixa a marca de
		# propósito: a retratada tem de abrir um sandbox limpo, não o mesmo estado sujo
		# que derrubou esta tentativa.
		if [ "$verdict" = "0" ]; then
			rm -f "$PROJECT/.test-home/$script/.booting"
		fi
		_release
		if [ "$verdict" = "0" ] || [ "$attempt" = "2" ]; then
			break
		fi
		# Duas assinaturas reexecutam, e nenhuma delas é veredito de check:
		#   (a) crash-contra-verde — o marcador disse `0 failures` e o processo caiu;
		#   (b) morte por sinal (exit ≥ 128) SEM marcador nenhum — o run não chegou a
		#       dar veredito.
		# (b) é o SIGSEGV de teardown medido nesta máquina em 2026-09-28: ele derrubou
		# `test_backup_restore` no meio de uma passada otherwise verde, e como a régua
		# antiga só conhecia (a), harness que crasha ANTES de imprimir nunca era
		# retratado — o portão contava como defeito de produto o que era defeito de
		# engine, e um juiz lendo aquilo anotaria crash no produto. Timeout fica fora
		# de propósito (exit 124 < 128): retratar lentidão custaria o dobro de relógio
		# sem provar nada.
		if [ "$code" -lt 128 ] && { [ "$code" -eq 0 ] || ! grep -qE "$marker[[:space:]]+[0-9]+ checks, 0 failures" "$log"; }; then
			break
		fi
		if [ "$code" -ge 128 ]; then
			echo "GATE INSTÁVEL: $script morreu por sinal (exit=$code) sem imprimir o próprio marcador (crash de engine, não de check) — reexecutando uma vez, resultado registrado como instabilidade"
		else
			echo "GATE INSTÁVEL: $script caiu com exit=$code depois de imprimir \`0 failures\` (crash de engine, não de check) — reexecutando uma vez, resultado registrado como instabilidade"
		fi
		# A evidência do crash não pode ser sobrescrita pela retratada: sem o log da
		# primeira tentativa, "instabilidade registrada" seria uma frase sem prova.
		mv -f "$log" "$log.crash" 2>/dev/null || true
		FLAKES="$FLAKES $script"
	done
	# Só a última tentativa é contada: somar a primeira daria duas culpas pelo mesmo
	# vizinho, e a retratada pode justamente ter caído numa janela limpa.
	noise="$(_noise_declared "$log")"
	if [ -n "$noise" ] && [ "$noise" -gt 0 ]; then
		NOISY="$NOISY $script:$noise"
	fi
	record_gate "$verdict" "$script"
}

# As três suítes do companion são a fronteira do dinheiro real (HMAC do webhook,
# idempotência do grant, CLI de reembolso). A CI já roda cada uma, mas o
# `test.sh all` local não — um "beta gate verde" na máquina deixava 138 checks de
# fora. Mesmo quádruplo de §24-8: marcador próprio por suíte, contagem lida do log,
# exit code conferido à parte.
gate_py() {
	local log="$1" marker="$2" script="$3"
	if ! _acquire "$script"; then
		record_gate 1 "$script"
		return 0
	fi
	set +e
	timeout 300 python3 "companion/$script.py" > "$log" 2>&1
	local code=$?
	set -e
	echo "python exit=$code" >> "$log"
	local verdict=0
	bash scripts/ci_gate_log.sh "$log" "$marker" "$code" || verdict=$?
	_release
	record_gate "$verdict" "$script"
}

companion_gates() {
	# Cobertura ANTES de executar: a lista de suítes era de memória, e assim ela
	# envelheceu — as quatro suítes do sender de push (232 checks, ECDSA e AES-GCM
	# escritos à mão em stdlib, a face mais crítica de correção do pacote) viveram
	# verdes no diretório e ausentes do portão. Agora um `companion/test_*.py` sem
	# `gate_py` aqui é gate vermelho, não suíte invisível.
	local suite missing=""
	for suite in $(ls companion/test_*.py 2>/dev/null | sed 's|.*/test_||; s|\.py$||'); do
		grep -q "gate_py .*$suite\b" scripts/test.sh || missing="$missing $suite"
	done
	if [ -n "$missing" ]; then
		record_gate 1 "companion_gates (sem gate_py:$missing)"
	fi
	gate_py /tmp/shambleta-companion.log "== COMPANION:" test_webhook
	gate_py /tmp/shambleta-security.log "== SECURITY:" test_security
	gate_py /tmp/shambleta-refund.log "== REFUND CLI:" test_refund_cli
	gate_py /tmp/shambleta-ad-ssv.log "== AD SSV:" test_ad_ssv
	gate_py /tmp/shambleta-push-common.log "== PUSH COMMON:" test_push_common
	gate_py /tmp/shambleta-push-p256.log "== PUSH P-256:" test_push_p256
	gate_py /tmp/shambleta-push-aesgcm.log "== PUSH AES128GCM:" test_push_aesgcm
	gate_py /tmp/shambleta-push-vapid.log "== PUSH VAPID:" test_push_vapid
	gate_py /tmp/shambleta-retention.log "== RETENTION:" test_retention
	gate_py /tmp/shambleta-season-offer.log "== SEASON OFFER:" test_season_offer
}

# Gate de estrutura em shell, pelo mesmo quádruplo de §24-8. Existe porque a CI roda
# `scripts/check_god_nodes.sh` num job próprio e o `test.sh all` não: o beta gate
# verde na máquina conviveu com a CI vermelha (Gui.gd 815 linhas contra o teto de
# 800). Um gate que só a CI roda não é gate de lançamento — é surpresa de diff.
gate_sh() {
	local log="$1" marker="$2" script="$3"
	if ! _acquire "$(basename "$script")"; then
		record_gate 1 "$(basename "$script")"
		return 0
	fi
	set +e
	bash "$script" > "$log" 2>&1
	local code=$?
	set -e
	echo "bash exit=$code" >> "$log"
	local verdict=0
	bash scripts/ci_gate_log.sh "$log" "$marker" "$code" || verdict=$?
	_release
	record_gate "$verdict" "$(basename "$script")"
}

# Pré-checagem de parse. Um harness que não compila é morte lenta: `run_idle_tests.gd:76`
# faz `load()` de `IdleTests.gd` e chama `.new()` — se o arquivo não parseia, o
# load devolve um GDScript inválido, `.new()` falha, nenhuma suíte roda, a linha
# de marcador nunca aparece e o gate só descobre isso no timeout de 1200 s. Três
# execuções do portão foram perdidas exatamente assim (um `CheckEq` recebeu String
# onde a assinatura é `(int, int, String)`). A régua é ancorada em
# `SCRIPT ERROR: Parse Error`: `--check-only` também emite
# `ERROR: …tscn - Parse Error: [ext_resource]` para scripts que referenciam
# autoload (falso positivo do modo, não do código).
#
# A régua vale para os históricos nomeados acima e para todo harness descoberto: falhar em
# 1 s é melhor que falhar em 1200 s.
#
# Descoberta: os nomes de `EXPLICIT_HARNESSES` acima entram no portão pelo nome
# (cada um com timeout próprio e marcador já conhecido; os `IdleTests*` são a fonte
# das suítes, checados no preflight e carregados pelo runner). Todo o resto é
# harness de fixação e entra por padrão de nome — criar o arquivo compra a execução,
# sem editar este script nem o workflow. O marcador vem do próprio arquivo (a linha
# que ele imprime), porque um gate que regrava o veredito de outro não é gate:
# `web_delivery_test` apura `== WEB DELIVERY:`, `perf_fix_test` apura `== RESULT:`.
EXPLICIT_HARNESSES=" run_idle_tests IdleTests IdleTestsFrontier run_rpc_identity_test test_e2e_implementation test_backup_restore benchmarks "

harnesses_extra() {
	local f n
	for f in tests/*_test.gd tests/*_fuzz.gd; do
		[ -e "$f" ] || continue
		n="$(basename "$f" .gd)"
		case "$EXPLICIT_HARNESSES" in
			*" $n "*) continue ;;
		esac
		echo "$n"
	done
}

harness_marker() {
	local m
	m="$(grep -ohE '"== [A-Z]+[A-Z ]*:' "tests/$1.gd" 2>/dev/null | head -1 | tr -d '"')"
	[ -n "$m" ] || m="== RESULT:"
	echo "$m"
}

# Pré-voo: `--check-only` é o único ponto do gate que lê um harness antes de
# qualquer boot, então ele existe para não se depender dos 20 min do gate para
# descobrir que o script não levanta o processo. Até 2026-09-28 o grep era só
# `Parse Error`, e o defeito que achou isso não é parse: amarrar o nome global de
# um recurso (`is EntityData`) a um harness `-s SceneTree` coloca a árvore de
# dependências dele no COMPILE do main loop, que roda antes dos autoloads — o boot
# cai com `SCRIPT ERROR: Compile Error: Identifier not found: Launcher` em
# `Peers.gd`, `DB.gd`, `World.gd`, e o gate morre no timeout sem imprimir nada.
# Medido no mesmo arquivo nos dois estados: 40 linhas mutado, 0 consertado.
# `Compile Error` é a mesma classe de "esta script não sobe", então entra na régua.
#
# Tolerância por harness, medida e gravada em `data/conf/preflight_baseline.txt`;
# sem linha o teto é 0. O único caso legítimo acima de zero é o kernel do harness
# que referencia um autoload (`IdleTests = 1`), porque `--check-only` nunca registra
# autoload. Os dois lados acusam: acima do gravado é erro novo; abaixo é a linha
# que deixou de descrever o run (erro consertado e não rebaixado), que é o teto que
# virou permissão. `PREFLIGHT_RECORD=1` regrava com a medida de agora.
preflight_parse() {
	local bad="" stale="" count=0 script
	local baseline="data/conf/preflight_baseline.txt"
	local errs errsN allowed
	for script in $EXPLICIT_HARNESSES $(harnesses_extra); do
		errs="$("$GODOT" --headless --path . --check-only --script "tests/$script.gd" 2>&1 |
			grep -E '^SCRIPT ERROR: (Parse|Compile) Error' || true)"
		errsN="$(printf '%s\n' "$errs" | grep -cE '^SCRIPT ERROR' || true)"
		count=$((count + 1))
		if [ "${PREFLIGHT_RECORD:-0}" = "1" ]; then
			if [ ! -f "$baseline" ]; then
				printf '%s\n' \
					"# tolerancia de SCRIPT ERROR: Parse/Compile Error por harness no --check-only do preflight." \
					"# métrica: contagem de linhas; harness sem linha aqui tem teto 0." \
					"# PREFLIGHT_RECORD=1 regrava com a medida de agora — sem folga, o número É a medida." > "$baseline"
			fi
			if grep -qE "^${script}[[:space:]]*=" "$baseline"; then
				sed -i -E "s|^${script}[[:space:]]*=.*|${script} = ${errsN}|" "$baseline"
			else
				printf '%s = %s\n' "$script" "$errsN" >> "$baseline"
			fi
		fi
		allowed=""
		if [ -f "$baseline" ]; then
			allowed="$(grep -E "^${script}[[:space:]]*=" "$baseline" | tail -n 1 | sed -nE 's/.*=[[:space:]]*([0-9]+).*/\1/p' || true)"
		fi
		[ -n "$allowed" ] || allowed=0
		if [ "$errsN" -gt "$allowed" ]; then
			bad="$bad$script ($errsN acima do teto medido $allowed)
$errs
"
		elif [ "$errsN" -lt "$allowed" ]; then
			stale="$stale$script: medido $errsN, teto gravado $allowed
"
		fi
	done
	if [ -n "$bad" ]; then
		echo "PREFLIGHT FALHOU: harness não compila (parse ou compile), o gate morreria no timeout."
		printf '%s' "$bad"
		exit 1
	fi
	if [ -n "$stale" ]; then
		echo "PREFLIGHT FALHOU: a baseline não descreve mais o run (erro que sumiu e teto que não desceu)."
		printf '%s' "$stale"
		echo "rode PREFLIGHT_RECORD=1 scripts/test.sh preflight"
		exit 1
	fi
	echo "Preflight OK: $count harnesses, cada um no teto medido de SCRIPT ERROR (parse+compile)."
}

gates_extra() {
	local script
	for script in $(harnesses_extra); do
		gate "/tmp/shambleta-${script}.log" "$(harness_marker "$script")" "$script" 300
	done
}

# Gates de estrutura: medem o repo sem rodar jogo. Um arquivo que escreveu a
# própria régua e não foi chamado por ninguém é régua sem efeito — foi o destino
# de `gut_runner.gd`, do `check_doc_drift.sh` e do `check_compose.sh` (verdes e
# sem um chamador, antes de entrarem aqui). Todos vivem aqui, e `all` e o case
# `structure` chamam ESTA função, para que local e CI não divirjam.
#
# `check_secrets.sh` entrou nesta lista por um motivo que não é de bom tom: o
# `.gitignore` deste repo não tinha nenhuma regra de dotenv e o job `code-health`
# da CI só chamava esta função com três gates — ou seja, um `git add -A` com um
# `.env` contendo a chave do provedor de pagamento (`.env.example:27-28`) atravessava
# o CI de um repositório que se declara open source. Gate de segredo que não está
# aqui é comentário de README.
structure_gates() {
	gate_sh /tmp/shambleta-godnodes.log "Gate anti-god-node:" scripts/check_god_nodes.sh
	gate_sh /tmp/shambleta-docdrift.log "== DOC DRIFT:" scripts/check_doc_drift.sh
	gate_sh /tmp/shambleta-compose.log "== COMPOSE GATE:" scripts/check_compose.sh
	gate_sh /tmp/shambleta-secrets.log "== SECRETS GATE:" scripts/check_secrets.sh
	gate_sh /tmp/shambleta-ci.log "== CI GATE:" scripts/check_ci.sh
	gate_sh /tmp/shambleta-deadcode.log "== DEAD CODE GATE:" scripts/check_dead_code.sh
	gate_sh /tmp/shambleta-untracked.log "== UNTRACKED GATE:" scripts/check_untracked.sh
	# Auto-teste do próprio leitor de veredito. Ele entrou nesta lista pelo motivo
	# geral da casa: o bloco novo de ruído externo imprimi NOTA, não falha — um run
	# verde com réguas não lidas continua verde — e nada no portão, fora deste
	# fixture, garantia que a linha continuaria aparecendo. Dois leitores do mesmo
	# gancho — `scripts/ci_gate_log.sh` para a nota do job e `_noise_declared()` aqui,
	# para a conta da passada — sem fixture é a receita da divergência.
	gate_sh /tmp/shambleta-gatelog.log "== GATE-LOG:" scripts/check_gate_log.sh
	# Durabilidade do portão contra interrupção: um harness morto no meio deixa banco e
	# WAL sujos no próprio sandbox, e a passada que abre por cima crasha antes de dar
	# veredito. Ver `_reap_interrupted_sandbox()` acima.
	gate_sh /tmp/shambleta-bootsandbox.log "== BOOT-SANDBOX:" scripts/check_boot_sandbox.sh
}

# Qualquer coisa que abra o projeto precisa do cache de `class_name` em dia — o
# `preflight` inclusive, cujo régua é justamente `SCRIPT ERROR: Parse Error` e um
# cache velho produz exatamente essa linha em todo arquivo que referencia uma classe
# nova. `clean` não abre nada, então não paga o import.
if [ "${1:-all}" != "clean" ]; then
	if ! boot_guard; then
		echo "== GATES VERMELHOS: boot_guard =="
		exit 1
	fi
	ensure_class_cache
fi

case "${1:-all}" in
  all)
    echo "==> Running all tests..."
    preflight_parse
    structure_gates
    gate /tmp/shambleta-idle.log "== RESULT:" run_idle_tests 1200
    gate /tmp/shambleta-rpc.log "== RPC IDENTITY:" run_rpc_identity_test 180
    gate /tmp/shambleta-e2e.log "== RESULT:" test_e2e_implementation 120
    gate /tmp/shambleta-backup.log "== Backup Restore Probe:" test_backup_restore 120
    gate /tmp/shambleta-bench.log "== Benchmarks:" benchmarks 120
    gates_extra
    companion_gates
    ;;
  companion)
    echo "==> Running companion (money frontier)..."
    companion_gates
    ;;
  fixation)
    # Mesma descoberta do `all`, para a CI poder chamar sem duplicar a régua:
    # workflow e script local divergindo é exatamente como um gate vira enfeite.
    echo "==> Running discovered fixation gates..."
    gates_extra
    ;;
  preflight)
    # O `all` começa daqui; esta porta existe para a CI chamar a MESMA função em
    # vez de manter uma cópia do laço de parse — foi assim que o preflight da CI
    # ficou olhando para seis arquivos enquanto o gate descobria por nome.
    preflight_parse
    ;;
  quick)
    echo "==> Running quick tests (no real-time sims)..."
    preflight_parse
    gate /tmp/shambleta-idle.log "== RESULT:" run_idle_tests 1200
    ;;
  idle)
    echo "==> Running idle tests..."
    preflight_parse
    gate /tmp/shambleta-idle.log "== RESULT:" run_idle_tests 1200
    ;;
  backup)
    echo "==> Running backup restore probe..."
    gate /tmp/shambleta-backup.log "== Backup Restore Probe:" test_backup_restore 120
    ;;
  benchmarks)
    echo "==> Running benchmarks..."
    gate /tmp/shambleta-bench.log "== Benchmarks:" benchmarks 120
    ;;
  rpc)
    echo "==> Running RPC identity transport test..."
    gate /tmp/shambleta-rpc.log "== RPC IDENTITY:" run_rpc_identity_test 180
    ;;
  structure)
    # Os gates de estrutura todos por esta porta: a lista é o corpo de
    # structure_gates() acima, e é ele que a régua de registro confere. Não
    # enumerar aqui — lista copiada é a mentira que espera o próximo gate entrar.
    echo "==> Running structure gates..."
    structure_gates
    ;;
  one)
    # Um harness pelo machinery inteiro: locks, sandbox por nome, marcador lido do
    # próprio arquivo e quádruplo de §24-8. Existe porque a alternativa de quem
    # depura (ou de um juiz) é `godot --headless -s tests/<nome>.gd` cru, que
    # é exatamente o processo estrangeiro que o `boot_guard` acima recusa — e
    # que corrói o veredito de quem está rodando. O timeout é opcional.
    harness="${2:-}"
    if [ -z "$harness" ]; then
      echo "Usage: $0 one <harness> [timeout]"
      exit 1
    fi
    if [ ! -f "tests/$harness.gd" ]; then
      echo "GATE VERMELHO: $harness — tests/$harness.gd não existe"
      exit 1
    fi
    gate "/tmp/shambleta-$harness.log" "$(harness_marker "$harness")" "$harness" "${3:-900}"
    ;;
  diag)
    echo "==> Running diagnostics..."
    # Mesmo domínio de exclusão dos gates: `diag_pacing.gd` abre o projeto, e um
    # boot dividido com um gate produz o SIGSEGV que esta casa já mediu. Sem o
    # lock, o `diag` era o único caminho de código versionado que furava o guard.
    if _acquire boot 8; then
      set +e
      "$GODOT" --headless --path . -s tests/diag_pacing.gd
      diagCode=$?
      set -e
      _release 8
      [ "$diagCode" -eq 0 ] || record_gate "$diagCode" diag_pacing
    else
      record_gate 1 diag_pacing
    fi
    ;;
  clean)
    echo "==> Cleaning test artifacts..."
    # Os caminhos reais: `user://` do Godot 4 com config/use_custom_user_dir=true é
    # $HOME/.local/share/Shambleta (o layout godot/app_userdata/ do Godot 3 nunca
    # existiu aqui, então este rm era no-op). O harness de cada case roda com
    # XDG_DATA_HOME apontando para .test-home/<script>/data, limpo no final.
    rm -f testing.db data/db/testing.db*
    rm -rf "$HOME/.local/share/Shambleta/"testing*
    rm -rf .test-home
    ;;
  *)
    echo "Usage: $0 {all|quick|idle|backup|benchmarks|rpc|companion|fixation|preflight|structure|one|diag|clean}"
    exit 1
    ;;
esac

# Veredito da passada inteira, não do primeiro gate que caiu. O marcador é
# legível de propósito: `GATES VERMELHOS: none` é a linha que um beta gate deve
# imprimir, e a ausência dela não é passagem (§24-8).
if [ -n "$FAILED_GATES" ]; then
	echo "== GATES VERMELHOS:$FAILED_GATES =="
else
	echo "== GATES VERMELHOS: none =="
fi
# Contabilidade da instabilidade, sempre impressa — inclusive em zero. Um portão
# que só fala de flake quando ele aparece não permite distinguir "estável" de
# "ninguém olhou", que é o defeito que esta casa combate desde o §24-8.
if [ -n "$FLAKES" ]; then
	echo "== FLAKES:$FLAKES =="
else
	echo "== FLAKES: none =="
fi
# Terceira conta, e ela não é sinônimo de verde. Um gate listado aqui terminou sem
# falha, mas com N janelas de medição descartadas por trabalho de OUTRO processo — ou
# seja, as réguas de wall-clock daquele harness não foram lidas. O número é o de
# janelas, por harness. Isto é impresso em zero também: "ninguém falou de ruído" e
# "ruído nenhum" são frases diferentes, e a segunda é a que autoriza um lançamento.
if [ -n "$NOISY" ]; then
	echo "== GATES COM RUÍDO:$NOISY =="
else
	echo "== GATES COM RUÍDO: none =="
fi
if [ -n "$FAILED_GATES" ]; then
	exit 1
fi
exit 0
