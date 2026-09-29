#!/usr/bin/env bash
# §24-8: exit code zero sozinho não prova nada num runner headless do Godot. Um
# SCRIPT ERROR no meio derruba um autoload e o runner ainda chega na última linha
# e imprime "0 failures"; um crash antes dela não imprime nada e sai com código
# que não é contagem de falha. O gate é quádruplo: log sem SCRIPT ERROR/Parse
# Error, linha de resultado presente, contagem de falhos LIDA DO LOG (é isso que
# vale — o terceiro argumento é o exit code do godot, conferido à parte, e quem
# passa 0 no lugar dele não consegue mais aprovar um run com check falho), e o
# código de saída do godot.
# Uso: ci_gate_log.sh <log> <marcador-do-resultado> <exit-code-do-godot> [harness]
set -u
log="${1:?uso: ci_gate_log.sh <log> <marcador> <exit-code>}"
marker="${2:?faltando o marcador de resultado}"
status="${3:-0}"

if [ ! -f "$log" ]; then
	echo "::error::não existe log do run ($log)"
	exit 1
fi

# O run pode ter dezenas de milhares de linhas; o resumo vai no arquivo do job.
tail -n 40 "$log"

errors="$(grep -nE 'SCRIPT ERROR|Parse Error' "$log" | head -n 20)"
if [ -n "$errors" ]; then
	echo "::error::o run teve SCRIPT ERROR / Parse Error (20 primeiros):"
	printf '%s\n' "$errors"
	exit 1
fi

if ! grep -qF "$marker" "$log"; then
	echo "::error::o run não terminou: faltou a linha \"$marker\" (crash ou timeout)"
	exit 1
fi

# A contagem de checks falhos está na própria linha de resultado
# ("== RESULT: 1825 checks, 1 failures =="). Ler do log é o que fecha o buraco de
# quem chama o gate passando 0 no exit code à mão: o run acima falhou 1 check e o
# gate aprovou. Uma linha de resultado que não cas com o formato também não passa —
# sem falha não verificável não há verde.
result_line="$(grep -F "$marker" "$log" | tail -n 1)"
fails="$(printf '%s\n' "$result_line" | sed -nE 's/.*[^0-9]([0-9]+) failures?.*/\1/p')"
if [ -z "$fails" ]; then
	echo "::error::linha de resultado presente mas não reconhecida: $result_line"
	exit 1
fi
if [ "$fails" -ne 0 ]; then
	echo "--- checks falhos ---"
	grep -nE '\[FAIL\]' "$log" | head -n 20
	echo "::error::$fails checks falhos em $(printf '%s' "$result_line" | sed -nE 's/.*: ([0-9]+) checks.*/\1/p') ($result_line)"
	exit 1
fi

if [ "$status" -ne 0 ]; then
	echo "::error::o runner saiu com $status mas a linha de resultado diz 0 falhas — log e exit code não batem"
	exit 1
fi

# §24-8 (teardown): o quádruplo acima lê o que o harness imprime e o código com
# que ele sai — nada disso enxerga o que acontece depois da última linha. Godot
# grava no teardown "N ObjectDB instances were leaked at exit" / "N resources
# still in use at exit" / "N RID allocations … leaked", e um run com veredito
# verde e 1066 instâncias presas passava igual. Isso não é cosmético: preso no
# teardown é referência que não voltou, e num `-s` que monta mundo a conta é
# grande e estável o bastante para esconder um vazamento novo dentro dela.
#
# Régua por harness, não um teto global: o boot do mundo custa ~1700 e um harness
# que não monta cena custa 30. Um teto único de 1700 deixaria o magro inchar 50×
# antes de reclamar; um teto de 30 acusaria o mundo por existir.
#
# A métrica é a soma dos números de todas as linhas de leak, e a entrada de
# `data/conf/teardown_baseline.txt` é medida, não escolhida. Rodar com
# TEARDOWN_RECORD=1 regrava a linha do harness com a medida de agora + folga,
# que é o único jeito de o número escrito ser conseqüência do observado.
# A CHAVE é o nome do harness, passado pelo chamador em $4 — nunca o nome do
# arquivo de log. O mesmo boot tem três nomes conforme o caminho: `all` o chama
# de rpc, a CI de rpc-identity e um juiz com `one` de run_rpc_identity_test.
# Derivar do log dava três tetos para um harness e dois deles inexistentes: a
# busca caía no teto padrão de 64, o boot do mundo vaza ~1700, e o único caminho
# que um juiz usa sem pedir licença virava acusação de regressão.
harness="${4:-$(basename "$log" .log)}"
harness="${harness#shambleta-}"
baseline="data/conf/teardown_baseline.txt"
leaked="$(grep -E 'leaked at exit|still in use at exit' "$log" 2>/dev/null \
	| sed -nE 's/^[A-Z]+: ([0-9]+) .*$/\1/p' | awk '{ s += $1 } END { print s + 0 }')"
: "${leaked:=0}"
ceiling=64
if [ -f "$baseline" ]; then
	recorded="$(grep -E "^${harness}[[:space:]]*=" "$baseline" | tail -n 1 | sed -nE 's/.*=[[:space:]]*([0-9]+).*/\1/p')"
	[ -n "$recorded" ] && ceiling="$recorded"
fi
echo "teardown: $harness vazou $leaked no exit (teto $ceiling)"
if [ "${TEARDOWN_RECORD:-0}" = "1" ]; then
	want=$((leaked + leaked / 4 + 64))
	if [ ! -f "$baseline" ]; then
		echo "# teto de vazamento de teardown por harness, medido + 25% de folga + 64." >> "$baseline"
		echo "# métrica: soma dos números das linhas \"… leaked at exit\" / \"… still in use at exit\"." >> "$baseline"
		echo "# harness sem linha aqui tem teto 64 (o custo do boot magro). TEARDOWN_RECORD=1 regrava." >> "$baseline"
	fi
	if grep -qE "^${harness}[[:space:]]*=" "$baseline"; then
		sed -i -E "s|^${harness}[[:space:]]*=.*|${harness} = ${want}|" "$baseline"
	else
		printf '%s = %s\n' "$harness" "$want" >> "$baseline"
	fi
	LC_ALL=C sort -o "$baseline" "$baseline" 2>/dev/null || true
	echo "teardown: baseline gravada $harness = $want (medido $leaked)"
fi
if [ "$leaked" -gt "$ceiling" ]; then
	echo "::error::$harness vazou $leaked no teardown, acima do teto medido de $ceiling — referência que não voltou é regressão, e ela cresce em silêncio"
	grep -E 'leaked at exit|still in use at exit' "$log"
	exit 1
fi
# Teto velho sem baixa: a folga é tolerância de medição, não permissão. A faixa
# tem de ser conseqüência da fórmula de gravação ali em cima, senão as duas regras
# se anulam: gravar escreve `leaked + leaked/4 + 64`, e uma banda em `ceiling/2`
# só fecha para runs acima de 85 objetos. Todo harness magro ficaria vermelho
# para sempre — inclusive na linha recém-gravada pelo próprio TEARDOWN_RECORD.
# O teto acima do que o gravador produziria para ESTE run é o que significa
# "a baseline deixou de descrever o run".
if [ "$leaked" -gt 0 ] && [ "$ceiling" -gt $((leaked + leaked / 2 + 64)) ] \
	&& [ "${TEARDOWN_RECORD:-0}" != "1" ]; then
	echo "::error::$harness vazou $leaked mas o teto registrado é $ceiling — o boot mudou e a baseline não foi rebaixada (rode TEARDOWN_RECORD=1)"
	exit 1
fi

# Terceira conta do §24-8, e a única que fala de um run que PASSOU. As réguas de
# wall-clock de um harness podem ser declaradas não-medidas quando a máquina está
# tomada por trabalho de outro processo (`tests/multi_instance_tick_test.gd`: janela
# suja → re-meete até o teto → `[RUIDO]` em vez de veredito). O gancho é ASCII e vem
# sempre impresso, inclusive em zero; ausência da linha é "harness sem régua", e isto
# não pode ler ausência como zero. Sem este bloco o CI aprovava um verde que não leu
# nenhuma fence de tempo — o log do job não dizia nada.
noise="$(sed -nE 's/^== NOISE-DECLARED: ([0-9]+) ==$/\1/p' "$log" | tail -n 1)"
if [ -n "$noise" ]; then
	if [ "$noise" -gt 0 ]; then
		grep -E '^== RUÍDO EXTERNO:' "$log" | tail -n 1
		echo "::notice::$harness declarou $noise janela(s) de medição sem CPU livre: as réguas de tempo desse run NÃO foram lidas. Verde com lacuna — remedir num host quieto antes de citar qualquer degrau."
	else
		echo "ruído: $harness mediu todas as janelas com CPU livre (réguas de tempo lidas)."
	fi
fi

echo "Gate §24-8 OK: run completo, zero SCRIPT ERROR, zero checks falhos, teardown dentro do teto medido ($leaked/$ceiling)."