#!/usr/bin/env bash
# OPS-6 (AUDITORIA_2026-09-27 §16 — Documentação 6/10): régua de drift de docs.
#
# O problema medido nesta repo não é falta de documentação: é doc que já foi
# verdade. A varredura de 2026-09-27 achou `docs/development/architecture.md`
# dizendo 5 autoloads (são 6), "os 201 `@rpc`" (número que ninguém reproduzia),
# `SQL.gd` com 1267 linhas (tinha 1502) e um `data/conf/l10n/ui.csv` que nunca
# existiu (o real é `data/i18n/ui.csv`). Doc errada é pior que doc ausente num
# incidente de madrugada: o operador segue o texto.
#
# Como isto funciona (e por que não é um lint genérico):
#  1. AFIRMAÇÕES ANCORADAS — cada fato verificável vive no markdown dentro de um
#     comentário HTML `<!-- DRIFT <título> <args> -->`, ao lado da frase que o
#     cita. O script recalcula o fato a partir do repo e compara. Comentário HTML
#     porque não aparece renderizado e não exige parser de markdown.
#  2. VERIFICAÇÕES UNIVERSAIS — caminhos citados em code span, números de
#     migration citados, subcomandos de `scripts/test.sh` citados, env gates
#     `SHAMBLETA_*` citados e jobs de CI citados têm que existir. Estas não
#     precisam de âncora: a asserção é "o que o texto menciona está no repo".
#  3. Nada aqui é cosmetico: cada falha imprime esperado vs. atual. A contagem
#     de falhas vai na linha de resultado, que é o que `scripts/ci_gate_log.sh`
#     lê (§24-8) — exit 0 sem linha de resultado não é verde.
#
# O que esta régua NÃO verifica (e ninguém deve fingir que verifica):
#  - contagem de linhas por arquivo. Saiu de propósito: três arquivos daqui mudam
#    a cada rodada e doc que grava número de linha apodrece em dias. O teto real
#    é o gate anti-god-node (`scripts/check_god_nodes.sh`), que mede no próprio
#    run e por isso nunca fica velho.
#  - prosa. "O que o módulo faz" não é verificável em bash; é revisado a olho.
#  - documentos de auditoria históricos (`AUDITORIA_*.md`, `ROADMAP_COMERCIAL.md`,
#    `CHANGELOG.md`): são registros datados, não especificação viva. Só
#    `README.md`, `docs/development/*.md` e os runbooks de `deploy/` são varridos
#    pelas regras universais.
#
# Uso: bash scripts/check_doc_drift.sh
# Saída: "== DOC DRIFT: N checks, M failures ==" e exit M (0 = sem drift).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

checks=0
failures=0

fail() {
	failures=$((failures + 1))
	echo "[FAIL] $1"
}

# $1 rótulo, $2 esperado, $3 atual — conta um check em qualquer caso.
expect() {
	checks=$((checks + 1))
	if [ "$2" = "$3" ]; then
		return 0
	fi
	fail "$1: esperado [$2], atual [$3]"
	return 1
}

# ---------------------------------------------------------------------------
# Documentos vivos: especificação, não registro histórico. A lista é derivada do
# repo (todo `docs/development/*.md`, todo `deploy/*.md`, README) e o que NÃO é
# especificação viva sai pela allowlist de história — assim, somar um runbook novo
# não o deixa sem varredura (era o caso de `LAUNCH_HANDOFF.md`, `BACKUP_RUNBOOK.md`
# e `OPS_RUNBOOK.md`: os três citam números e caminhos e nenhum gate os lia).
# ---------------------------------------------------------------------------
HIST_DOCS=""
if [ -f scripts/doc_drift_history.txt ]; then
	HIST_DOCS="$(grep -vE '^[[:space:]]*(#|$)' scripts/doc_drift_history.txt | tr '\n' ' ')"
fi
LIVE_DOCS=""
for f in README.md docs/development/*.md deploy/*.md; do
	[ -f "$f" ] || continue
	case " $HIST_DOCS " in
		*" $f "*) continue ;;
	esac
	LIVE_DOCS="$LIVE_DOCS $f"
done
if [ -z "$LIVE_DOCS" ]; then
	# Exit, não só fail: com a lista vazia todo `grep $LIVE_DOCS` abaixo vira
	# `grep` sem arquivo, que lê stdin e empaca o job de CI até o timeout.
	fail "nenhum documento vivo encontrado — o gate virou no-op"
	echo "== DOC DRIFT: $checks checks, $failures failures =="
	exit 1
fi

# ---------------------------------------------------------------------------
# 1) Autoloads: o que está em project.godot é a verdade do runtime.
# ---------------------------------------------------------------------------
actual_autoloads="$(awk '
	/^\[autoload\]/ { f = 1; next }
	/^\[/ { f = 0 }
	f && /=/ { name = $0; sub(/=.*/, "", name); gsub(/[[:space:]]/, "", name); if (name != "") print name }
' project.godot | sort | tr '\n' ',' | sed 's/,$//')"
autoload_count="$(printf '%s' "$actual_autoloads" | awk -F',' '{ print NF }')"

anchor_names="$(grep -rhoE 'DRIFT autoload_names [A-Za-z0-9_,]+' $LIVE_DOCS 2>/dev/null |
	awk '{ print $3 }' | sort -u | head -n 1)"
if [ -z "$anchor_names" ]; then
	fail "nenhuma âncora \`<!-- DRIFT autoload_names ... -->\` nos docs vivos"
else
	expect "conjunto de autoloads ancorado nas docs" "$actual_autoloads" "$anchor_names"
fi

anchor_count="$(grep -rhoE 'DRIFT autoload_count [0-9]+' $LIVE_DOCS 2>/dev/null |
	awk '{ print $3 }' | head -n 1)"
expect "contagem de autoloads ancorada" "$autoload_count" "${anchor_count:-sem-ancora}"

# ---------------------------------------------------------------------------
# 2) @rpc com TOLERÂNCIA declarada. A contagem vem do fonte; o ± vem da doc.
#    Um número exato apodrece a cada RPC novo; um ± explícito diz ao leitor o
#    grau de confiança que a frase merece, que é o que uma doc deveria fazer.
# ---------------------------------------------------------------------------
rpc_actual="$(grep -rhE '^[[:space:]]*@rpc\(' sources/ | wc -l | tr -d ' ')"
anchors="$(grep -rhoE 'DRIFT rpc_total [0-9]+ [0-9]+' $LIVE_DOCS 2>/dev/null | awk '{ print $3 " " $4 }' | sort -u)"
if [ -z "$anchors" ]; then
	fail "nenhuma âncora \`<!-- DRIFT rpc_total <valor> <tolerancia> -->\` nos docs vivos"
else
	while IFS=' ' read -r declared tol; do
		[ -z "$declared" ] && continue
		checks=$((checks + 1))
		delta=$((rpc_actual - declared))
		[ "$delta" -lt 0 ] && delta=$((-delta))
		if [ "$delta" -gt "$tol" ]; then
			fail "@rpc ancorado em $declared ±$tol, atual $rpc_actual (diff $delta fora da tolerância)"
		fi
	done <<< "$anchors"
fi

# ---------------------------------------------------------------------------
# 3) Migrations: 001..N contínuo. O runner usa índice do array como versão
#    (`SQL.gd:63 patches[currentVersion]`), então um buraco aplica o patch
#    errado em silêncio — é contrato de código, não de gosto.
# ---------------------------------------------------------------------------
mig_files="$(ls data/conf/migrations/*.sql 2>/dev/null | sed -E 's|.*/([0-9]{3})_.*\.sql|\1|' | sort -n)"
mig_count="$(printf '%s\n' "$mig_files" | grep -c '[0-9]')"
mig_max="$(printf '%s\n' "$mig_files" | tail -n 1)"
expected_seq=""
i=1
while [ "$i" -le "${mig_count:-0}" ]; do
	num="$(printf '%03d' "$i")"
	if [ -z "$expected_seq" ]; then
		expected_seq="$num"
	else
		expected_seq="$expected_seq
$num"
	fi
	i=$((i + 1))
done
expect "migrations 001..N contínuas" "$expected_seq" "$(printf '%s' "$mig_files")"

anchor_mig="$(grep -rhoE 'DRIFT migration_max [0-9]{3}' $LIVE_DOCS 2>/dev/null | awk '{ print $3 }' | head -n 1)"
# A última migration não é número que a doc deva reter: `data/conf/migrations/` é a
# fonte de verdade (o runner endereça patch por posição — §3) e um literal gravado
# na doc ("DRIFT migration_max 058") apodrece no commit seguinte, que é justamente a
# doença que este arquivo caça. O gate DERIVA o máximo do diretório; se a doc ainda
# insistir em nomear um número, ele tem que bater com o derivado. Ausência de
# literal é o estado correto — não há o que envelhecer.
if [ -z "$anchor_mig" ]; then
	checks=$((checks + 1))
	echo "[ok] última migration derivada de data/conf/migrations/ (${mig_max:-nenhuma}) sem número gravado na doc"
else
	expect "última migration citada na doc (se a doc nomear um número, tem que ser o do diretório)" "${mig_max:-nenhuma}" "$anchor_mig"
fi

for cited in $(grep -rhoE 'migration [0-9]{3}' $LIVE_DOCS 2>/dev/null | awk '{ print $2 }' | sort -u); do
	checks=$((checks + 1))
	if ! printf '%s\n' "$mig_files" | grep -qx "$cited"; then
		fail "doc cita migration $cited, que não existe em data/conf/migrations/"
	fi
done

# 3b) Prosa que AFIRMA quantas migrations existem. `deploy/STAGING.md` dizia "as 49
#     versioned migrations" com 55 no disco — o número exato estava no meio de uma
#     frase, quebra de linha no meio, e nenhuma âncora o protegia. Não adianta pedir
#     âncora aqui: a régua é "se o texto conta, o texto acerta". Junta as linhas antes
#     de casar justamente porque o número e a palavra caem em linhas diferentes.
for doc in $LIVE_DOCS; do
	for stated in $(tr '\n' ' ' < "$doc" |
			grep -oiE '[0-9]+([[:space:]]+(versioned|avaliadas|de)[[:space:]]+)?migrations' |
			grep -oE '^[0-9]+' | sort -u); do
		expect "$doc diz \"$stated migrations\"" "$stated" "$mig_count"
	done
done

# ---------------------------------------------------------------------------
# 4) Caminho citado em code span tem que existir. Exceções declaradas em
#    `scripts/doc_drift_allowlist.txt` (uma por linha) — para os arquivos que a
#    doc menciona justamente para dizer que NÃO existem, que é o caso de
#    `NetworkAuth.gd` e companhia.
# ---------------------------------------------------------------------------
allow=""
if [ -f scripts/doc_drift_allowlist.txt ]; then
	# Bash e espaço: a lista vira um único string pesquisado por `*" $path "*`.
	# A barra final é normalizada dos dois lados — a doc cita `sources/discord/`
	# e o caminho testado aqui já teve a barra tirada na linha abaixo.
	allow="$(grep -vE '^[[:space:]]*(#|$)' scripts/doc_drift_allowlist.txt |
		sed -E 's/[[:space:]]+$//; s|/+$||' | tr '\n' ' ')"
fi
cited_paths="$(grep -rhoE '`(sources|data|docs|deploy|scripts|companion|tests|presets|addons|\.github)/[^`[:space:]]+`' $LIVE_DOCS 2>/dev/null |
	tr -d '`' | sort -u)"
for raw in $cited_paths; do
	path="${raw%/}"
	# `arquivo.gd:123` e `arquivo.gd:12-13` são ponteiros de evidência: a âncora
	# de linha é verificada por IdleTests.SuiteEvidencePointers, daqui só o caminho.
	path="${path%%:*}"
	case "$raw" in
		*\**|*"<"*|*"("*) continue ;;
	esac
	[ -z "$path" ] && continue
	case " $allow " in
		*" $path "*) continue ;;
	esac
	checks=$((checks + 1))
	if [ ! -e "$path" ] && [ ! -d "$path" ]; then
		# tolera citação sem extensão (`data/i18n/ui.` -> ui.csv) e diretório
		if [ -n "$(ls "$path"* 2>/dev/null | head -n 1)" ]; then
			continue
		fi
		fail "doc cita caminho inexistente: $raw"
	fi
done

# ---------------------------------------------------------------------------
# 5) Subcomando de scripts/test.sh citado tem que existir no `case`.
# ---------------------------------------------------------------------------
test_sh_cases="$(sed -nE 's/^[[:space:]]*([a-z][a-z0-9_]*)\)[[:space:]]*$/\1/p' scripts/test.sh | sort -u | tr '\n' ' ')"
for sub in $(grep -rhoE 'test\.sh [a-z]+' $LIVE_DOCS 2>/dev/null | awk '{ print $2 }' | sort -u); do
	checks=$((checks + 1))
	case " $test_sh_cases " in
		*" $sub "*) : ;;
		*) fail "doc cita \`scripts/test.sh $sub\`, que não é case de scripts/test.sh (cases: $test_sh_cases)" ;;
	esac
done

# ---------------------------------------------------------------------------
# 6) Env gate citada é lida no código. Flag inventada em runbook é o defeito que
#    faz a correção documentada não funcionar.
# ---------------------------------------------------------------------------
code_envs="$(grep -rhoE 'SHAMBLETA_[A-Z0-9_]+' sources/ companion/ deploy/ scripts/ .github/ 2>/dev/null | sort -u | tr '\n' ' ')"
for envname in $(grep -rhoE 'SHAMBLETA_[A-Z0-9_]+' $LIVE_DOCS 2>/dev/null | sort -u); do
	checks=$((checks + 1))
	case " $code_envs " in
		*" $envname "*) : ;;
		*) fail "doc cita $envname, que não aparece em sources/, companion/, deploy/, scripts/ nem .github/" ;;
	esac
done

# ---------------------------------------------------------------------------
# 7) Job de CI citado tem que existir num workflow.
# ---------------------------------------------------------------------------
ci_jobs="$(grep -rhoE '^  [a-z0-9_-]+:$' .github/workflows/*.yml 2>/dev/null | tr -d ' :' | sort -u | tr '\n' ' ')"
for job in $(grep -rhoE 'job `[a-z0-9_-]+`' $LIVE_DOCS 2>/dev/null | sed 's/^job //;s/`//g' | sort -u); do
	checks=$((checks + 1))
	case " $ci_jobs " in
		*" $job "*) : ;;
		*) fail "doc cita job \`$job\`, ausente de .github/workflows (jobs: $ci_jobs)" ;;
	esac
done

# ---------------------------------------------------------------------------
# 8) Diretório de backup citado tem que ser a chave do enum.
#    A varredura de 2026-09-27 achou cinco linhas de runbook mandando o operator
#    fazer `ls .../sql-backups/daily` num container case-sensitive: o nome real
#    vem de `SQLCommons.BackupFrequency.keys()` (MAIÚSCULO) e o `ls` vazio era
#    lido como "o backup nunca rodou". Expectativa = enum do código, atual = o que
#    a doc escreve.
# ---------------------------------------------------------------------------
bk_enum="$(sed -nE 's/^enum BackupFrequency[[:space:]]*\{(.*)\}[[:space:]]*$/\1/p' sources/sql/SQLCommons.gd </dev/null 2>/dev/null | tr -d ' ' | head -n 1)"
if [ -z "$bk_enum" ]; then
	checks=$((checks + 1))
	fail "enum BackupFrequency não encontrado em sources/sql/SQLCommons.gd — a régua de diretório de backup ficou sem fonte de verdade"
else
	bk_dirs=" $(printf '%s' "$bk_enum" | tr ',' ' ') "
	bk_n="$(printf '%s' "$bk_enum" | awk -F',' '{ print NF }')"
	expect "BackupFrequency tem uma chave por cadência documentada" "3" "$bk_n"
	bk_cited="$(grep -rnoE 'sql-backups/[A-Za-z{][A-Za-z{},]*' $LIVE_DOCS </dev/null 2>/dev/null || true)"
	if [ -z "$bk_cited" ]; then
		echo "[PENDÊNCIA] nenhuma doc viva cita sql-backups/<DIR> — a régua 8 não tem o que conferir neste estado"
	fi
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		loc="${line%%:*}"
		rest="${line#*:}"
		lineno="${rest%%:*}"
		cited="${rest#*:}"
		dirs="${cited#sql-backups/}"
		for d in $(printf '%s' "$dirs" | tr '{},' '   '); do
			[ -z "$d" ] && continue
			checks=$((checks + 1))
			case "$bk_dirs" in
				*" $d "*) : ;;
				*) fail "$loc:$lineno cita sql-backups/$d — esperado um de:$bk_dirs, atual: $d (o nome vem de SQLCommons.BackupFrequency.keys(), sources/sql/SQLCommons.gd:32 + sources/sql/SQLBackups.gd:12; em container case-sensitive o \`ls\` minúsculo volta vazio)" ;;
			esac
		done
	done <<< "$bk_cited"
fi

# ---------------------------------------------------------------------------
# 9) Coluna citada em SQL de runbook tem que existir na tabela.
#    `ROLLBACK.md` mandava rodar `SELECT * FROM grant_queue WHERE granted_at IS
#    NULL` — `granted_at` é de `cosmetic_grant` (migration 023), não de
#    `grant_queue`. Numa madrugada, `no such column` é lido como "o webhook nunca
#    chegou", que é o contrário do diagnóstico. A expectativa é montada das
#    migrations (CREATE TABLE + ALTER TABLE ADD COLUMN), não de doc.
# ---------------------------------------------------------------------------
table_columns() { # $1 = tabela; imprime uma coluna por linha
	awk -v t="$1" '
		match($0, /^CREATE TABLE( IF NOT EXISTS)? [a-z_][a-z0-9_]*/) {
			n = substr($0, RSTART, RLENGTH); sub(/^CREATE TABLE( IF NOT EXISTS)? /, "", n)
			inside = (n == t); next
		}
		inside && /^[[:space:]]*\)?;?[[:space:]]*$/ { inside = 0; next }
		inside {
			l = $0; sub(/^[[:space:]]+/, "", l)
			w = l; sub(/[[:space:](,].*$/, "", w)
			if (w ~ /^(PRIMARY|UNIQUE|CHECK|FOREIGN|CONSTRAINT)$/) next
			if (w ~ /^[a-z][a-z0-9_]*$/) print w
		}
	' data/conf/migrations/*.sql </dev/null 2>/dev/null
	grep -rhoE "ALTER TABLE $1 ADD COLUMN (IF NOT EXISTS )?[a-z_][a-z0-9_]*" data/conf/migrations/*.sql </dev/null 2>/dev/null |
		sed -E 's/.*ADD COLUMN (IF NOT EXISTS )?([a-z_][a-z0-9_]*).*/\2/'
}
sql_cited="$(grep -rnoE 'FROM [a-z_]+ WHERE [a-z_]+' $LIVE_DOCS </dev/null 2>/dev/null | sort -u || true)"
while IFS= read -r line; do
	[ -z "$line" ] && continue
	loc="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; stmt="${rest#*:}"
	tbl="$(printf '%s' "$stmt" | awk '{ print $2 }')"
	col="$(printf '%s' "$stmt" | awk '{ print $4 }')"
	cols="$(table_columns "$tbl" | sort -u | tr '\n' ' ')"
	checks=$((checks + 1))
	if [ -z "$cols" ]; then
		fail "$loc:$lineno cita \`FROM $tbl\`, que nenhuma migration cria — tabela inexistente"
		continue
	fi
	case " $cols " in
		*" $col "*) : ;;
		*) fail "$loc:$lineno filtra $tbl por \`$col\` — esperado uma coluna de:$cols, atual: $col" ;;
	esac
done <<< "$sql_cited"

# ---------------------------------------------------------------------------
# 10) Quantos serviços o compose tem, e quais a doc nomeia.
#     `COOLIFY.md` dizia "3 serviços" enquanto `deploy/docker-compose.yml` declara
#     quatro (cloudflared): um operator que conta três ignora o túnel na hora de
#     debugar WSS. A contagem vem do bloco `services:` do arquivo, não da doc.
# ---------------------------------------------------------------------------
compose_list="$(awk '/^services:/{ f = 1; next } /^[^[:space:]#]/ { f = 0 } f && /^  [a-z0-9_-]+:/ { gsub(/[ :]/, ""); print }' deploy/docker-compose.yml </dev/null 2>/dev/null | sort -u)"
compose_names=" $(printf '%s' "$compose_list" | tr '\n' ' ') "
compose_n="$(printf '%s\n' "$compose_list" | grep -c '[a-z]')"
state_n="$(grep -rniE '[0-9]+ (servi[cç]os)' $LIVE_DOCS </dev/null 2>/dev/null | sort -u || true)"
while IFS= read -r line; do
	[ -z "$line" ] && continue
	loc="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; body="${rest#*:}"
	stated="$(printf '%s' "$body" | grep -oE '[0-9]+ (servi[cç]os)' | grep -oE '^[0-9]+')"
	[ -z "$stated" ] && continue
	expect "$loc:$lineno diz \"$stated serviços em deploy/docker-compose.yml\"" "$compose_n" "$stated"
	# Os nomes entre crases na MESMA linha têm que ser serviços daquele arquivo.
	for nm in $(printf '%s' "$body" | tr '`' '\n' | grep -E '^[a-z][a-z0-9_-]*$'); do
		case " $compose_names " in
			*" $nm "*) continue ;;
			sql-backups|data|services) continue ;;
		esac
		checks=$((checks + 1))
		fail "$loc:$lineno nomeia \`$nm\` como serviço do compose — esperado um de:$compose_names, atual: $nm"
	done
done <<< "$state_n"

# ---------------------------------------------------------------------------
# 11) Linha de log citada em doc tem que ser uma linha que o código emite, com o
#     grupo certo. `COOLIFY.md` e `TLS.md` mandavam `grep '[TLS]'` no log do
#     container: o grupo real é `Server` (`Util.PrintLog("Server", ...)`, e o
#     prefixo `[msec][Grupo]` é de `sources/util/Util.gd:5-6`). grep que volta
#     vazio em doc de incidente vira "o modo proxy não ligou".
# ---------------------------------------------------------------------------
log_groups=" $(grep -rhoE 'Print(Log|Info|Warning|Error)\("[A-Za-z]+"' sources/ </dev/null 2>/dev/null | sed -E 's/.*"([A-Za-z]+)"$/\1/' | sort -u | tr '\n' ' ')"
quoted_logs="$(grep -rnE '^\[[A-Za-z]+\] .{8,}' $LIVE_DOCS </dev/null 2>/dev/null | sort || true)"
while IFS= read -r line; do
	[ -z "$line" ] && continue
	loc="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; body="${rest#*:}"
	tag="$(printf '%s' "$body" | sed -nE 's/^\[([A-Za-z]+)\].*/\1/p')"
	msg="$(printf '%s' "$body" | sed -E 's/^\[[A-Za-z]+\][[:space:]]*//')"
	probe="$(printf '%s' "$msg" | cut -c1-40)"
	checks=$((checks + 1))
	if [ -z "$tag" ]; then
		fail "$loc:$lineno cita uma linha \`[Grupo] ...\` ilegível para esta régua — atual: $body"
		continue
	fi
	case "$log_groups" in
		*" $tag "*) : ;;
		*) fail "$loc:$lineno atribui o log ao grupo [$tag] — esperado um grupo emitido por Util.Print*(sources/):$log_groups, atual: $tag" ;;
	esac
	checks=$((checks + 1))
	if ! grep -rqF "$probe" sources/ </dev/null 2>/dev/null; then
		fail "$loc:$lineno cita uma mensagem que nenhum fonte emite: \"$probe…\" — esperado: texto presente em sources/, atual: ausente"
	fi
done <<< "$quoted_logs"

# ---------------------------------------------------------------------------
# 12) Corpo de erro JSON citado em doc tem que ser corpo que o companion/devolve.
#     `COOLIFY.md:173` mandava reconhecer o smoke test por `missing auth_token`;
#     o que `companion/server.py` devolve é `{"error": "missing_token"}`. Uma string
#     inventada num passo de smoke test = "a rota não existe" dito errado.
# ---------------------------------------------------------------------------
for tok in $(grep -rhoE '\{\\?"error\\?": ?\\?"[a-z_]+\\?"' $LIVE_DOCS </dev/null 2>/dev/null | grep -oE '[a-z_]{4,}' | grep -vx error | sort -u); do
	checks=$((checks + 1))
	if grep -rqF "\"$tok\"" companion/ sources/ </dev/null 2>/dev/null; then
		continue
	fi
	fail "doc cita \`{\"error\": \"$tok\"}\`, que não aparece em companion/ nem sources/ — esperado: literal emitido pelo código, atual: \"$tok\" inventado ou Renomeado"
done

# ---------------------------------------------------------------------------
# 13) Cadência do reconcile: o timer é próprio (MetaJobIntervalSec) e o
#     acoplamento com o backup foi removido de propósito (#28). Doc que diz
#     "pós-backup" faz o operator esperar um job que não veio porque o disco está
#     cheio — e procurar a causa no lugar errado.
# ---------------------------------------------------------------------------
recon_line="$(grep -n 'RunReconcileJob()' sources/sql/SQLBackups.gd </dev/null 2>/dev/null | head -n 1 | cut -d: -f1)"
recon_timer=""
if [ -n "$recon_line" ]; then
	recon_timer="$(awk -v stop="$recon_line" 'NR <= stop && NR >= stop - 14 { if (match($0, /SQLCommons\.[A-Za-z0-9_]*IntervalSec/)) print substr($0, RSTART + 11, RLENGTH - 11) }' sources/sql/SQLBackups.gd </dev/null 2>/dev/null | tail -n 1)"
fi
if [ -z "$recon_timer" ]; then
	checks=$((checks + 1))
	fail "não foi possível derivar o timer do reconcile em sources/sql/SQLBackups.gd — a régua 13 ficou sem fonte de verdade"
else
	coupled="$(grep -rniE '(reconcil[a-z]*|RunReconcileJob).{0,80}(p[óo]s-backup|depois do backup)|(p[óo]s-backup|depois do backup).{0,80}reconcil' $LIVE_DOCS </dev/null 2>/dev/null | sort || true)"
	if [ -n "$coupled" ]; then
		checks=$((checks + 1))
		fail "doc acopla reconcile ao backup — esperado: cadência própria por $recon_timer (disparo em sources/sql/SQLBackups.gd, desacoplamento deliberado #28), atual: $(printf '%s' "$coupled" | tr '\n' '|')"
	fi
	for named in $(grep -rhoE 'DRIFT reconcile_timer [A-Za-z0-9_]+' $LIVE_DOCS </dev/null 2>/dev/null | awk '{ print $3 }' | sort -u); do
		expect "âncora DRIFT reconcile_timer" "$recon_timer" "$named"
	done
fi

# ---------------------------------------------------------------------------
# 14) Sonda de saúde no bind real: o MetricsServer binda SOMENTE o endereço que
#     `BindAddress` declara. `localhost` com `::1` no /etc/hosts do container leva
#     connection refused num servidor saudável — foi o defeito que o comentário em
#     `deploy/docker-compose.yml` registra e que `STAGING.md` ensinava a repetir.
#     Pendência de outro dono fica listada como PENDÊNCIA (visível no log), não
#     como aprovação silenciosa.
# ---------------------------------------------------------------------------
ms_addr="$(sed -nE 's/^[[:space:]]*const BindAddress[[:space:]]*:[[:space:]]*String[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' sources/system/MetricsServer.gd </dev/null 2>/dev/null | head -n 1)"
ms_port="$(sed -nE 's/^[[:space:]]*const DefaultPort[[:space:]]*:[[:space:]]*int[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' sources/system/MetricsServer.gd </dev/null 2>/dev/null | head -n 1)"
HEALTHZ_PENDING="docs/development/architecture.md"
if [ -z "$ms_addr" ] || [ -z "$ms_port" ]; then
	checks=$((checks + 1))
	fail "não foi possível derivar BindAddress/DefaultPort de sources/system/MetricsServer.gd — régua 14 sem fonte de verdade"
else
	wrong_host="$(grep -rnoE "localhost:$ms_port" $LIVE_DOCS </dev/null 2>/dev/null | sort || true)"
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		loc="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"
		checks=$((checks + 1))
		case " $HEALTHZ_PENDING " in
			*" $loc "*) echo "[PENDÊNCIA OUTRO DONO] $loc:$lineno usa localhost:$ms_port — esperado: $ms_addr:$ms_port (BindAddress em sources/system/MetricsServer.gd)" ;;
			*) fail "$loc:$lineno usa localhost:$ms_port — esperado: $ms_addr:$ms_port (bind IPv4-only em sources/system/MetricsServer.gd), atual: localhost:$ms_port" ;;
		esac
	done <<< "$wrong_host"
fi

# ---------------------------------------------------------------------------
# 15) Contagem de autoloads em prosa. `project.godot` é o que o motor registra;
#     `setup.md` e `debugging.md` diziam "cinco" com seis no arquivo, e a régua de
#     âncora (§1) só conferia quem escreve âncora — prosa solta passava.
# ---------------------------------------------------------------------------
autoload_wordnum="$(grep -rniE '(um|dois|duas|tr[êe]s|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|[0-9]+)[[:space:]]+\*{0,2}[a-z]*\*{0,2}[[:space:]]*autoloads?|autoloads[[:space:]]+registrados[[:space:]]+s[ãa]o' $LIVE_DOCS </dev/null 2>/dev/null | sort -u || true)"
while IFS= read -r line; do
	[ -z "$line" ] && continue
	loc="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; body="${rest#*:}"
	# `*` de ênfase atravessa a frase ("são **seis**"), então sai antes de casar.
	plain="$(printf '%s' "$body" | tr -d '*_')"
	word="$(printf '%s' "$plain" | grep -ioE '(um|dois|duas|tr[êe]s|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|[0-9]+)[[:space:]]+autoloads' | head -n 1 | tr 'A-Z' 'a-z' | awk '{ print $1 }')"
	[ -z "$word" ] && word="$(printf '%s' "$plain" | grep -ioE 'autoloads registrados s[ãa]o (um|dois|duas|tr[êe]s|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|[0-9]+)' | grep -ioE '(um|dois|duas|tr[êe]s|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|[0-9]+)$' | tr 'A-Z' 'a-z')"
	[ -z "$word" ] && continue
	case "$word" in
		um) n=1 ;; dois|duas) n=2 ;; tr[êe]s) n=3 ;; quatro) n=4 ;; cinco) n=5 ;; seis) n=6 ;;
		sete) n=7 ;; oito) n=8 ;; nove) n=9 ;; dez) n=10 ;; onze) n=11 ;; doze) n=12 ;; *) n="$word" ;;
	esac
	expect "$loc:$lineno afirma \"$word autoload\"" "$autoload_count" "$n"
done <<< "$autoload_wordnum"

# ---------------------------------------------------------------------------
# 16) Tecla de atalho afirmada em doc tem que ser tecla tratada no código.
#     `README.md` prometia "F1–F12 para atalhos de UI" quando nenhuma delas era
#     tratada. A régua nasceu assim e continuou certa por um motivo que ela não
#     media: neste projeto tecla não se trata só com `KEY_F<n>` cru — o caminho
#     dominante é o `InputMap` (`project.godot [input]`) ligar a tecla a uma ação
#     `ui_*`/`gp_*` e `sources/input/Action.gd:176-199` despachar essa ação. Ler
#     apenas `KEY_F` no código contava uma tecla (F12) e chamava de verdade, o que
#     deixava VERDE a mentira oposta: "não existe binding de F1–F11", quando F1
#     abre o menu e F2 abre o hub de personagem. Então a tecla é tratada quando
#     (a) algum `KEY_F<n>` cru aparece em `sources/`, OU (b) o `InputMap` mapeia
#     F<n> para uma ação que o código lê. Linha com negação ("não existe",
#     "there is no") é pulada de propósito: é assim que uma doc honesta registra a
#     tecla que falta, e a régua continua pegando a afirmação.
# ---------------------------------------------------------------------------
raw_fkeys=" $(grep -rhoE 'KEY_F[0-9]+' sources/ </dev/null 2>/dev/null | sed 's/KEY_//' | sort -u | tr '\n' ' ')"
# Ações de input que o código efetivamente lê (não basta estarem no InputMap).
read_actions=" $( { grep -rhoE 'Try[A-Za-z]*\([^,]+,[[:space:]]*"[a-z_0-9]+"' sources/; grep -rhoE 'Input\.is_action_[a-z_]*\("[a-z_0-9]+"' sources/; } </dev/null 2>/dev/null | grep -oE '"[a-z_0-9]+"' | tr -d '"' | sort -u | tr '\n' ' ')"
# F<n> -> ação, lido do InputMap. O código de F1 é 4194332 e sobe até F12=4194343.
fkey_actions="$(awk '
	/^\[input\]/ { inp = 1; next }
	/^\[/ { inp = 0 }
	inp {
		if ($0 ~ /^[a-z_][a-z0-9_]*=\{/) { act = $0; sub(/=.*/, "", act); next }
		if ($0 ~ /physical_keycode":4194[0-9][0-9][0-9]/) {
			n = split($0, parts, "physical_keycode\":")
			for (i = 2; i <= n; i++) {
				code = substr(parts[i], 1, 7) + 0
				if (code >= 4194332 && code <= 4194343) print "F" code - 4194331 " " act
			}
		}
	}' project.godot </dev/null 2>/dev/null)"
handled_fkeys="$raw_fkeys"
for pair in $fkey_actions; do
	case "$pair" in
		F*) : ;;
		*)	if printf '%s' "$read_actions" | grep -q " $pair "; then
				handled_fkeys="$handled_fkeys $(printf '%s\n' "$fkey_actions" | grep -w "$pair" | cut -d' ' -f1)"
			fi ;;
	esac
done
handled_fkeys="$(printf '%s' "$handled_fkeys" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
range_lines="$(grep -rnE 'F[0-9]+[^A-Za-z0-9]{1,3}F[0-9]+' $LIVE_DOCS </dev/null 2>/dev/null | sort -u || true)"
while IFS= read -r line; do
	[ -z "$line" ] && continue
	loc="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; body="${rest#*:}"
	if printf '%s' "$body" | grep -qiE 'n[ãa]o|never|there is no|does not|sem atalho|no binding|nenhuma'; then
		continue
	fi
	for k in $(printf '%s' "$body" | grep -oE 'F[0-9]+' | sort -u); do
		checks=$((checks + 1))
		case "$handled_fkeys" in
			*" $k "*) : ;;
			*) fail "$loc:$lineno afirma atalho $k — esperado: tecla tratada em sources/ (cru via KEY_F<n>, ou InputMap+ação lida pelo código; tratadas hoje:${handled_fkeys}), atual: $k sem handler em lugar nenhum" ;;
		esac
	done
done <<< "$range_lines"

# ---------------------------------------------------------------------------
# 18) Toda harness de gate tem linha na tabela de `docs/development/testing.md`.
# A tabela é o único lugar onde um operador descobre O QUE o portão apura; um
# harness sem linha é um gate que roda e ninguém sabe que existe. Foi assim que
# `backup_full_restore_test` viveu 184 linhas fora de lista. O motivo de derivar
# a lista DO MESMO `scripts/test.sh` (e não colar um array aqui) é o defeito
# clássico de régua duplicada: se este script tivesse a própria lista, ele
# passaria verde para si mesmo e cego para o portão real.
# As CONTAGENS por harness (checks) não são verificadas aqui de propósito: número
# que muda a cada suíte, e o cabeçalho deste arquivo proíbe doc-grava
# número-apodrece. O que não apodrece é a lista de nomes.
# ---------------------------------------------------------------------------
TESTING_DOC="docs/development/testing.md"
[ -f "$TESTING_DOC" ] && LIVE_HARNESS_LIST=1 || LIVE_HARNESS_LIST=0
if [ "$LIVE_HARNESS_LIST" != "1" ]; then
	checks=$((checks + 1))
	fail "$TESTING_DOC não existe — a régua da tabela de harnesses virou no-op"
else
	docs_harness="$(grep -hoE '^EXPLICIT_HARNESSES="[^"]*"' scripts/test.sh | sed 's/^EXPLICIT_HARNESSES="//; s/"$//; s/^/ /; s/$/ /')"
	extra=""
	for n in $(ls tests/*_test.gd tests/*_fuzz.gd 2>/dev/null | sed 's#.*/##; s#\.gd$##' | sort -u); do
		case "$docs_harness" in *" $n "*) : ;; *) extra="$extra $n" ;; esac
	done
	# A conta é exatamente `EXPLICIT_HARNESSES + harnesses_extra()` de
	# `scripts/test.sh` — i.e. o número que `preflight_parse()` imprime,
	# recomposto a partir do portão em vez de copiado para cá.
	preflight_total=$(( $(printf '%s\n' $docs_harness | wc -l) + $(printf '%s\n' $extra | wc -l) ))
	gate_scripts="$extra"
	for n in $docs_harness; do
		# `IdleTests` não é gate: é a fonte das suítes e entra no portão via
		# `run_idle_tests`, que faz `load()` dela. Nomeá-lo na tabela seria contar
		# duas vezes a mesma execução.
		[ "$n" = "IdleTests" ] && continue
		gate_scripts="$gate_scripts $n"
	done
	missing=""
	for n in $(printf '%s\n' $gate_scripts | sort -u); do
		grep -q "\`$n\`" "$TESTING_DOC" || missing="$missing $n"
	done
	checks=$((checks + 1))
	if [ -n "$missing" ]; then
		fail "harness de gate sem linha em $TESTING_DOC:${missing} — criar tests/<nome>_test.gd compra a execução no portão, e o documento tem que dizer o que ela apura"
	else
		echo "[ok] $(printf '%s\n' $gate_scripts | sort -u | wc -l) harnesses de gate nomeados em $TESTING_DOC"
	fi
	# `tr '\n' ' '` porque o markdown quebra a frase em duas linhas e um grep
	# linha-a-linha não vê a afirmação: régua que só enxerga a frase quando ela
	# está num só lugar é régua que falha por motivo errado.
	claimed_preflight="$(tr '\n' ' ' < "$TESTING_DOC" | grep -ohE '[0-9]+ harnesses no preflight' | grep -oE '[0-9]+' | head -n 1)"
	checks=$((checks + 1))
	if [ -z "$claimed_preflight" ]; then
		fail "$TESTING_DOC não declara mais a contagem do preflight no formato '<N> harnesses no preflight' — atualize a frase e esta régua juntos (atual: computed ${preflight_total})"
	else
		expect "$TESTING_DOC: contagem do preflight" "$preflight_total" "$claimed_preflight"
	fi
fi

# ---------------------------------------------------------------------------
# 19) Linha na tabela de `testing.md` para algo que não é gate do portão.
# A regra de cima só sabe reclamar de falta; sem esta, a tabela incharia para
# sempre com portão morto — que é exatamente a "doc que já foi verdade" que este
# script existe para caçar. `IdleTests` é aceito à mão porque a tabela pode
# nomear a fonte das suítes sem estar documentando uma execução própria, e
# `companion`/`structure` são grupos, não harnesses Godot. Aceitar "o arquivo
# existe em tests/" foi o erro desta régua no primeiro dia: `diag_pacing` e
# `dump_calibration` são diagnóstico chamado à mão, passam nesse teste de
# existência, e uma linha de tabela dizendo que o portão roda um arquivo que ele
# nunca carregou é mentira com formato de verdade.
# ---------------------------------------------------------------------------
if [ "$LIVE_HARNESS_LIST" = "1" ]; then
	stale=""
	for n in $(grep -oE '^\|[[:space:]]*`[a-z0-9_]+`' "$TESTING_DOC" | sed 's/[|`]//g; s/^ *//'); do
		case " $gate_scripts " in
			*" $n "*) : ;;
			*)	[ "$n" = "IdleTests" ] || [ "$n" = "structure" ] || [ "$n" = "companion" ] || stale="$stale $n" ;;
		esac
	done
	checks=$((checks + 1))
	if [ -n "$stale" ]; then
		fail "linha na tabela de $TESTING_DOC apontando para um harness que o portão não executa:${stale} — ou o arquivo saiu, ou virou diagnóstico chamado à mão; a tabela descreve o portão de hoje, não o de ontem"
	fi
fi

# ---------------------------------------------------------------------------
# 20) Corpo do aceite afirmativo: quantas categorias o jogador lê e aceita.
# `LAUNCH_HANDOFF.md` afirma o tamanho do texto porque o texto está em inglês num
# jogo cujo fonte de língua é PT-BR — e o que a frase precisa é da grandeza, não do
# caractere exato. O número exato foi o erro anterior deste parágrafo: cinco mil
# trezentos e quinze apodreceu na cláusula de 18+, e nenhum gate sabia. A contagem de
# categorias é verificável em bash puro (uma chave `"category"` por categoria no
# JSON), então ela vira âncora; a grandeza em caracteres fica como "mais de cinco
# mil", que é o que a decisão do dono realmente precisa.
# ---------------------------------------------------------------------------
AGREEMENT="data/db/agreement.json"
agree_actual="$(grep -c '"category"' "$AGREEMENT" 2>/dev/null || echo 0)"
agree_anchor="$(grep -rhoE 'DRIFT agreement_categories [0-9]+' $LIVE_DOCS 2>/dev/null |
	awk '{ print $3 }' | head -n 1)"
expect "categorias do aceite ancoradas na doc" "$agree_actual" "${agree_anchor:-sem-ancora}"

# ---------------------------------------------------------------------------
# 21) Linha de harness não regrava contagem de checks. A coluna `checks` saiu da
# tabela de `testing.md` de propósito: "quantos checks este harness roda" é medido
# no run e impresso na linha de resultado do PRÓPRIO harness — um número copiado na
# doc mente no commit seguinte (a doc chegou a dizer que o `balance_test` rodava 124
# quando a régua já media muito mais). O que a doc guarda é o QUE o harness apura,
# prosa estável. Esta régua morde de novo se alguém re-inserir a coluna numérica OU
# escrever "N checks" numa linha de harness. Prosa FORA da tabela fica de fora: a
# frase "N checks, M failures" que descreve o FORMATO da linha de resultado é
# legítima e não é uma contagem regravada.
# ---------------------------------------------------------------------------
if [ "$LIVE_HARNESS_LIST" = "1" ]; then
	count_rows=""
	while IFS= read -r row; do
		case "$row" in
			'| `'*) : ;;
			*) continue ;;
		esac
		# (a) contagem literal "N checks" ; (b) a antiga coluna: 2º campo `|`-delimitado
		# composto só por dígitos (ex.: `| \`x\` | 669 | ...`).
		if printf '%s' "$row" | grep -qiE '[0-9]+[[:space:]]+checks'; then
			count_rows="$count_rows$(printf '\n%s' "$row")"
		elif [ -n "$(printf '%s' "$row" | awk -F'|' '{ gsub(/[[:space:]]/,"",$3); if ($3 ~ /^[0-9]+$/) print "x" }')" ]; then
			count_rows="$count_rows$(printf '\n%s' "$row")"
		fi
	done < "$TESTING_DOC"
	checks=$((checks + 1))
	if [ -n "$count_rows" ]; then
		fail "linha de harness em $TESTING_DOC re-declarou contagem de checks:$count_rows — a contagem vive na SAÍDA do próprio harness ('== RESULT: N checks, M failures =='), não na doc; doc que grava número mente no commit seguinte"
	else
		echo "[ok] nenhuma linha de harness em $TESTING_DOC grava contagem de checks"
	fi
fi

echo "== DOC DRIFT: $checks checks, $failures failures =="
exit "$failures"
