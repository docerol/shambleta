#!/usr/bin/env bash
# §24-8: exit code zero sozinho não prova nada num runner headless do Godot. Um
# SCRIPT ERROR no meio derruba um autoload e o runner ainda chega na última linha
# e imprime "0 failures"; um crash antes dela não imprime nada e sai com código
# que não é contagem de falha. O gate é quádruplo: log sem SCRIPT ERROR/Parse
# Error, linha de resultado presente, contagem de falhos LIDA DO LOG (é isso que
# vale — o terceiro argumento é o exit code do godot, conferido à parte, e quem
# passa 0 no lugar dele não consegue mais aprovar um run com check falho), e o
# código de saída do godot.
# Uso: ci_gate_log.sh <log> <marcador-do-resultado> <exit-code-do-godot>
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

echo "Gate §24-8 OK: run completo, zero SCRIPT ERROR, zero checks falhos."
