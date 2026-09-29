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
# Um harness é código: `SHAMBLETA_NOISE_WAIT_MS` é lida por
# `tests/multi_instance_tick_test.gd` e documentada em `docs/development/testing.md`,
# e a régua chamava de inventada uma flag que existe, só porque procurava em quatro
# árvores sem `tests/`. O defeito que esta regra caça é a flag imaginada em runbook, e
# um leitor de ambiente no harness prova a mesma coisa que um no produto.
code_envs="$(grep -rhoE 'SHAMBLETA_[A-Z0-9_]+' sources/ companion/ deploy/ scripts/ tests/ .github/ 2>/dev/null | sort -u | tr '\n' ' ')"
for envname in $(grep -rhoE 'SHAMBLETA_[A-Z0-9_]+' $LIVE_DOCS 2>/dev/null | sort -u); do
	checks=$((checks + 1))
	case " $code_envs " in
		*" $envname "*) : ;;
		*) fail "doc cita $envname, que não aparece em sources/, companion/, deploy/, scripts/, tests/ nem .github/" ;;
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
				*) fail "$loc:$lineno cita sql-backups/$d — esperado um de:$bk_dirs, atual: $d (o nome vem de SQLCommons.BackupFrequency.keys(), sources/sql/SQLCommons.gd:43 + sources/sql/SQLBackups.gd:12; em container case-sensitive o \`ls\` minúsculo volta vazio)" ;;
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
#     `COOLIFY.md` (revisao anterior a esta regua) mandava reconhecer o smoke test por `missing auth_token`;
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
		# `IdleTests*` não é gate: é a fonte das suítes (o kernel `IdleTests.gd` e a
		# folha `IdleTestsFrontier.gd`, que o runner carrega) e entra no portão via
		# `run_idle_tests`, que faz `load()` dela. Nomeá-la na tabela seria contar
		# duas vezes a mesma execução.
		case "$n" in IdleTests*) continue ;; esac
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

# ---------------------------------------------------------------------------
# 22) Quantas suítes o gate `idle` executa, ancorada em `testing.md`.
# A frase do parágrafo da ferramenta de mão compara o ciclo de 45 s com o do portão
# inteiro e, para isso, precisa de um tamanho. Ela gravava "as 137 suítes": nenhum
# número no repo reproduzia 137, e o valor real medido em 2026-09-28 é 92 — a
# contagem havia apodrecido exatamente como o header deste arquivo proíbe. A
# diferença entre isto e a coluna `checks` da regra 21 é o que impede a apodrecida:
# o denominador aqui É recomputado a cada passada, a partir do único lugar que define
# o portão (`tests/run_idle_tests.gd`), então a doc pode dizer o número porque o
# gate confere o número. Chamar por `suites.Suite` é a única forma de invocação no
# runner (as outras ocorrências de "Suite" no arquivo são comentário), e `sort -u`
# porque suíte chamada duas vezes ainda é uma suíte.
# ---------------------------------------------------------------------------
IDLE_RUNNER="tests/run_idle_tests.gd"
if [ -f "$IDLE_RUNNER" ]; then
	idle_suites="$(grep -ohE 'suites\.Suite[A-Za-z0-9_]*' "$IDLE_RUNNER" | sort -u | wc -l)"
	idle_anchor="$(grep -rhoE 'DRIFT idle_suites [0-9]+' $LIVE_DOCS 2>/dev/null | awk '{ print $3 }' | head -n 1)"
	checks=$((checks + 1))
	if [ -z "$idle_anchor" ]; then
		fail "nenhuma âncora \`<!-- DRIFT idle_suites <N> -->\` nos docs vivos (atual: computed ${idle_suites}) — ou a frase que promete o tamanho do gate sumiu, ou voltou a gravar número solto em prosa"
	else
		expect "$TESTING_DOC: contagem de suítes do gate idle" "$idle_suites" "$idle_anchor"
	fi
else
	checks=$((checks + 1))
	fail "$IDLE_RUNNER não existe — a régua da contagem de suítes virou no-op"
fi

# ---------------------------------------------------------------------------
# 23) IDENTIDADE de ponteiro: `arquivo:NN` tem que nomear o que MORA na linha NN.
#
# As regras 5 e 6 conferem RESOLUÇÃO: o arquivo do ponteiro existe e o número cabe
# nele. Isso é necessário e não é suficiente — a mentira que os juízes de Documentação
# e DevOps penalizaram (2026-09-28, rodadas 1 e 2) tinha exatamente a forma de um
# ponteiro válido: um símbolo declarado numa linha de `sources/sql/SQL.gd` e ancorado
# no comentário três linhas acima, um `mem_limit` do compose ancorado no arquivo
# errado, uma faixa de métricas ancorada antes do `MetricsBody()` que a emite.
# Arquivo existe, linha existe, frase mente. Esta régua é a única que morde essa
# classe, e ela mordeu: as âncoras que ela acusou foram re-medidas no arquivo real,
# uma por uma, antes de este commit existir.
#
# Como funciona:
#  - clausa: o texto entre o fim do ponteiro anterior (ou o início da linha) e o
#    início deste, recortado na última célula de `|` (em tabela, a cláusula é a
#    célula, não a linha inteira). A convenção da casa é `simbolo` (`arquivo:NN`),
#    então o nome está SEMPRE ANTES do número e nunca é herdado do ponteiro vizinho.
#  - candidato: token entre backticks da cláusula com FORMA de identificador, em dois
#    cortes medidos um por um: `narrow` exige `_`, camelCase ou MAIÚSCULAS>=4;
#    `wide` aceita qualquer identificador. Só o narrow deixaria `gate()` e `Beta()`
#    de fora, e régua que só enxerga nome com cabeça é régua pela metade.
#  - três filtros contra falso positivo, cada um medido no self-test: palavra inteira
#    (senão `up` morde "group"), token com `/` ou `:` fora (senão `user://live.db`
#    vira dois "nomes"), e o candidato precisa EXISTIR EM ALGUM LUGAR do arquivo alvo
#    (senão rótulo de prosa como `game` acusa um ponteiro que não nomeia nada).
#  - veredito: as BORDAS do intervalo têm de ter texto (linha em branco não mostra
#    nada para quem abre o arquivo no número citado), e algum candidato aparece no
#    span citado => passa; nenhum => acusa com as linhas onde o nome realmente mora.
#
# A borda veio depois, e veio medida: a linha 53 de `ROADMAP_COMERCIAL.md` citava o
# intervalo 503-509 de `sources/economy/EconomyService.gd`, o topo era linha em branco,
# e o portão rápido dizia
# verde enquanto o `run_idle_tests` — 20 minutos, mesmo checks, dois runs — dizia
# vermelho três vezes. O nome não morava na borda, morava no meio do span, e a régua
# de identidade julga o intervalo como um texto só. Uma régua que só existe no run
# caro é a mesma coisa que não existir no commit; o checking barato é o que muda
# comportamento de quem edita.
#
# Mordida antes de confiança: o self-test roda doze controles em memória (nada escrito
# em disco) nos DOIS cortes, e a seção só pode reportar zero acusações se os 24 casos
# mordarem — mentira acusada, verdade aprovada, ponteiro sem nome não julgado, nome
# minúsculo julgado, rótulo que não existe no arquivo ignorado, caminho com `://`
# ignorado, span de faixa aceito, e as três bordas em branco (início, fim, ponteiro
# solto) acusadas mesmo quando o nome está no span. E um piso de ponteiros julgados:
# um `os.walk` quebrado também devolve "zero acusações", então zero sem volume é falha daqui.
#
# O que NÃO confere: linha exata dentro de uma faixa (aceita o nome em qualquer linha
# do range, desde que as duas bordas tenham texto), e nome dentro de uma cláusula que
# não nomeia símbolo nenhum (a régua de nome não tem o que julgar aí).
# A cláusula é a LINHA, não o parágrafo: medimos a variante de parágrafo (nome na
# linha de cima, número na de baixo) e ela foi rejeitada — em prosa de runbook o
# parágrafo carrega nomes de três ponteiros diferentes, e o corte produziu 16
# acusações das quais boa parte era atribuição errada da régua, não mentira do doc
# (`OPS_RUNBOOK.md:17` cobrando `cloudflared` na linha do resolver, por exemplo).
# Régua que precisa do autor do doc para decidir quem mente é ruído, e ruído em gate
# de doc é o que mata o gate. As três mentiras reais que o experimento achou
# (`SCALING.md` com faixa de mutex apontando para players, `STAGING.md` com
# `BindAddress`/`DefaultPort` dois linhas acima, `SQL.gd:1463` que é `UnmuteAccount`)
# foram corrigidas na mesma passada; o que ficou de fora é coberto pela convenção de
# nome ANTES do número, que é o formato em que toda a varredura abaixo acontece.
# ---------------------------------------------------------------------------
IDENT_MIN=120
# Piso da régua de literal: o censo medido no run de 2026-09-28 é 54 ponteiros
# pinados. É pouco porque a régua só julga o literal que mora UMA vez no arquivo-alvo
# — duas ocorrências não pinham nada e o caso devolve "não julgado" — e a maioria das
# citações deste repo nomeia um identificador (cobrado pela régua de identidade acima)
# em vez de prometer um trecho de código. O piso é queda-para-baixo, não meta: um walk
# que passa a enxergar menos é o walk quebrado, e foi um zero assim que esta régua foi
# escrita para pegar.
LIT_MIN=40
# Piso da régua de registro: 3 prosas afirmando a contagem (README, o job de CI e o
# runbook de operacao) no censo medido nesta passada. O piso e de queda-para-baixo: o
# que ele caça não é a prosa nova, é a prosa que suma ou o walk que parou de ler os
# arquivos — nos dois casos "zero acusacoes" seria a régua muda, não a árvore honesta.
REG_MIN=2
PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
	checks=$((checks + 1))
	fail "python3 indisponível (PYTHON=$PY) — a régua de identidade de ponteiro não rodou; ausência conta como falha, não como pulo"
else
	ident_out="$("$PY" - "$PWD" <<'PYEOF' 2>&1
# -*- coding: utf-8 -*-
"""Identidade de ponteiro de prosa: secao 23 de scripts/check_doc_drift.sh.

Todo `arquivo.ext:NN[-MM]` citado no repo vem com uma clausa que diz O QUE mora
naquela linha. A regula de resolucao ja confere que o arquivo existe e que a linha
cabe nele; ela nao confere que a linha e a coisa nomeada. Esta regula confere, e e
a unica mordida contra a classe de mentira que os juizes de Documentacao e DevOps
apontaram: ponteiro valido, arquivo existente, linha existente, frase falsa.

 - clausa: texto entre o fim do ponteiro anterior (ou o inicio da linha) e o inicio
   deste, recortado na ultima celula de tabela. A convencao da casa e
   `simbolo` (`arquivo:NN`), entao o nome esta sempre ANTES do numero e nunca e
   herdado do ponteiro da frase vizinha.
 - candidato: token entre backticks com FORMA de identificador, medido em dois
   cortes: `narrow` exige `_`, camelCase ou MAIUSCULAS>=4; `wide` aceita qualquer
   identificador. So o narrow deixaria `gate()` e `Beta()` de fora.
 - tres filtros contra falso positivo, cada um medido: palavra inteira (senao `up`
   morde "group"), token com `/` ou `:` fora (senao `user://live.db` vira dois
   nomes), e o candidato precisa existir EM ALGUM LUGAR do arquivo alvo (senao
   rotulo de prosa como `game` acusa um ponteiro que nao nomeia nada).
 - veredito: algum candidato aparece no span citado => passa; nenhum => acusa com as
   linhas onde o nome realmente mora.
 - nome de arquivo: um token entre backticks com forma de `arquivo.ext` SEM caminho
   entra na mesma cobra, com duas tolerancias a mais (linha vizinha e o quinhao
   delimitado por linha em branco), porque citar o bloco onde o arquivo aparece e
   prosa honesta. `IDENT` rejeia o ponto, e a regua de literal devolve "nao julgado"
   quando o nome mora mais de uma vez no alvo — era por essa fresta que um ponteiro
   podia apontar para texto cheio de outra coisa sem que nada acusasse.

Self-test em memoria (nada escrito em disco), nos dois cortes: regra que nao morde o
proprio controle e enfeite, entao a secao bash so aceita zero acusacoes se todos os
casos mordarem.
"""
import os
import re
import sys

MIN_CHECKS = 120
KEEP = {".git", ".godot", ".test-home", "__pycache__", "node_modules", ".venv", "graphify-out"}
EXTS = (".md", ".gd", ".py", ".sh", ".mjs", ".yml", ".yaml", ".conf", ".html")
# Registros datados: prose de quando o numero era outro. Cobrar deles a verdade de
# hoje seria reescrever historico.
SKIP_NAMES = {"CHANGELOG.md", "progress.md", "ROADMAP_COMERCIAL.md", "BLIND_JUDGE_PROTOCOL.md"}

# O alvo de um ponteiro: `caminho.ext:NN`, com `Dockerfile` (sem ponto) incluído — a
# posse de deploy cita `deploy/web/Dockerfile:50` e `Dockerfile:26` o tempo todo.
_TGT = (r"((?:[A-Za-z0-9_./-]+\.(?:gd|py|sh|yml|yaml|json|sql|cfg|conf|md|csv|mjs|"
        r"toml|godot|tscn|example|html))|(?:[A-Za-z0-9_./-]*Dockerfile))")
PTR = re.compile(r"`" + _TGT + r":(\d+)(?:-(\d+))?`")
BACKTICK = re.compile(r"`([^`]+)`")
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# A régua de embaixo exige o ponteiro ENTRE backticks; a prosa de deploy/ e do nginx
# cita sem backtick (`(deploy/web/nginx.conf:37)`), e foi exatamente assim que 21
# âncoras deslizaram para uma linha com texto mas com o texto errado sem que nada
# acusasse. ANYCITE vê as duas formas; o que pinha é o literal, não o nome.
ANYCITE = re.compile(r"(?<![\w./-])" + _TGT + r":(\d+)((?:[-,]\d+)*)")


# ---------------------------------------------------------------------------
# 26) NUMERAL DE REGISTRO: prosa que diz "N gates de estrutura" tem de dizer o
# número que o registro em `scripts/test.sh` tem HOJE.
#
# A classe nasceu nesta passada. `structure_gates()` ganhou dois gates (gate-log e
# boot-sandbox) e a contagem velha continuou escrita em quatro lugares: o README dizia
# "sete", o runner dizia "Três", a CI dizia "Os dois", e só o runbook dizia nove.
# Nenhuma régua acima via nada: sem `arquivo:linha` não há identidade nem literal a
# conferir, e a frase é honesta em português — só está errada. É exatamente o método
# que um juiz usa para plantar mentira ("escreva uma afirmação que nenhum portão lê");
# a régua tinha de existir antes dele.
#
# O escopo é estreito de propósito: só a expressão "<numeral> gates de estrutura", cujo
# registro é contável sem ambiguidade (as chamadas `gate_sh` do corpo de
# `structure_gates()`). Prosa que ENUMERA sem numeral não é julgada porque não afirma
# número nenhum, e numeral que não é numeral ("outros gates de estrutura") é isento,
# com controle próprio no self-test abaixo.
NUMWORD = {
    "um": 1, "uma": 1, "dois": 2, "duas": 2, "tres": 3, "três": 3, "quatro": 4,
    "cinco": 5, "seis": 6, "sete": 7, "oito": 8, "nove": 9, "dez": 10, "onze": 11,
    "doze": 12, "treze": 13, "quatorze": 14, "quinze": 15, "dezesseis": 16,
    "dezessete": 17, "dezoito": 18, "dezenove": 19, "vinte": 20, "zero": 0,
}
NUMREG = re.compile(r"\b([A-Za-zà-ú0-9]{1,10})\s+gates de estrutura", re.IGNORECASE)


def numeral_of(word):
    """O valor de um numeral em português ou em algarismo; None se não é numeral."""
    w = word.lower()
    if w in NUMWORD:
        return NUMWORD[w]
    if re.match(r"^\d{1,2}$", w):
        return int(w)
    return None


def registry(root):
    """A verdade do registro: as chamadas `gate_sh` do corpo de structure_gates().

    Devolve a lista de nomes — o tamanho que a prosa tem de bater — ou None se o fonte
    não foi lido. None NÃO é zero: régua que não lê o registro não pode aprovar a
    contagem escrita por ninguém.
    """
    path = os.path.join(root, "scripts", "test.sh")
    if not os.path.isfile(path):
        return None
    names, seen = [], False
    for line in open(path, encoding="utf-8", errors="replace").read().split("\n"):
        t = line.strip()
        if not seen:
            seen = t.startswith("structure_gates()")
            continue
        if t == "}":
            break
        if t.startswith("gate_sh"):
            m = re.search(r"scripts/([a-z0-9_]+\.sh)\s*$", t)
            if m:
                names.append(m.group(1))
    return names if seen else None


def regverdict(word, reg):
    """(julgado, ok) de um numeral afirmado contra um registro de tamanho `reg`."""
    value = numeral_of(word)
    if value is None:
        return False, True
    if reg is None:
        return True, False
    return True, value == len(reg)


# Cada controle é a mentira desta passada, ou a forma honesta que a régua não pode
# tocar. Sem estes, "zero acusações" no REGISTRO seria a mesma cegueira verde que a
# casa caça: uma régua que nunca morde não se distingue de uma régua ausente.
REG_CONTROLES = [
    ("nove bate um registro de nove", "nove", ["g"] * 9, True, True),
    ("sete: a mentira do README", "sete", ["g"] * 9, True, False),
    ("dois: a mentira da CI", "dois", ["g"] * 9, True, False),
    ("Tres sem acento e maiuscula tambem e numeral", "Três", ["g"] * 9, True, False),
    ("algarismo arabe aprovado", "9", ["g"] * 9, True, True),
    ("algarismo arabe divergente acusado", "7", ["g"] * 9, True, False),
    ("outros nao afirma contagem: isento", "outros", ["g"] * 9, False, True),
    ("Os sozinho nao afirma contagem: isento", "Os", ["g"] * 9, False, True),
    ("zero gates: numeral de verdade, acusado de verdade", "zero", ["g"] * 9, True, False),
    ("registro ilegivel nao aprova ninguem", "nove", None, True, False),
    ("nove contra dez: compara-se o numero, nao a palavra", "nove", ["g"] * 10, True, False),
]


def regselftest():
    biting = 0
    for nome, word, reg, jul, ok in REG_CONTROLES:
        got = regverdict(word, reg)
        if got == (jul, ok):
            biting += 1
        else:
            print("[FAIL] registro: self-test cego no controle %s (%r vs registro %r -> %r, esperava %r)"
                  % (nome, word, reg, got, (jul, ok)))
    return biting, len(REG_CONTROLES)


def lit_spans(m):
    """Os intervalos de um ponteiro: `:334-339` é um; `:26,41` são dois.

    Os números vêm dos grupos de ANYCITE, que captura o caminho antes deles:
    grupo 1 é o alvo, grupo 2 a primeira linha, grupo 3 o resto da enumeração.
    """
    nums = [int(m.group(2))] + [int(x) for x in re.findall(r"[-,](\d+)", m.group(3))]
    ops = re.findall(r"([-,])\d+", m.group(3))
    spans, cur = [], nums[0]
    for op, nxt in zip(ops, nums[1:]):
        if op == "-" and cur is not None:
            spans.append((cur, nxt))
            cur = None
        else:
            if cur is not None:
                spans.append((cur, cur))
            cur = nxt
    if cur is not None:
        spans.append((cur, cur))
    return [(min(a, b), max(a, b)) for a, b in spans]


def lit_clause(prev, seg, first, bt):
    """A oração que este ponteiro promete, não a frase inteira antes dele.

    "o gate (`scripts/check_compose.sh`) confere os dois juntos, e o comando canônico
    está em deploy/STAGING.md:72" não promete o script na linha 72: a promessa do
    ponteiro é a sua própria oração, e o literal da oração coordenada de cima já foi
    julgado por ela. Corta no último ponto, `,` ou `;` FORA de backticks — dentro de
    um comando ou de "Dockerfile:26,41" a vírgula não é fronteira de oração, e um ponto
    que não fecha frase (`v2.0`) também não. O que se descarta
    antes do corte é a cauda colada ao ponteiro: "(`X + Y`, arq.gd:10)" tem vírgula de
    pontuação, e quem promete é o literal.

    `bt` diz se o próprio ponteiro está entre backticks: se sim, o que cola nele é a
    marca dele, não cláusula, e contar aquilo como backtick (1) faria uma citação
    ``(`arq.gd:10`)`` parecer portadora de literal, (2) mataria a quebra de linha
    abaixo. Só então a frase pode ir buscar na linha de cima o literal que morreu na
    quebra — e só o que sobra depois do último ponteiro daquela, porque o que veio
    antes já foi promessa daquele. O backtick que cola nesse resto é o de FECHAMENTO
    do ponteiro carregado; sem descascá-lo o par desbalanceia e a promessa some do
    censo.
    """
    if bt and seg.endswith("`"):
        seg = seg[:-1]
    if first and prev is not None and "`" not in seg and "`" in prev:
        pm = None
        for pm2 in ANYCITE.finditer(prev):
            pm = pm2
        tail = prev[pm.end():] if pm else prev
        if tail.startswith("`"):
            tail = tail[1:]
        seg = tail + " " + seg
    seg = seg.rstrip()
    while seg and seg[-1] in ",;.(":
        seg = seg[:-1].rstrip()
    in_bt, cut = False, -1
    for i, ch in enumerate(seg):
        if ch == "`":
            in_bt = not in_bt
        elif not in_bt and (ch in ",;" or (ch == "." and i + 1 < len(seg) and seg[i + 1] == " ")):
            cut = i
    return seg[cut + 1:].lstrip() if cut >= 0 else seg


def shaped(tok, wide):
    if not tok or "/" in tok or "*" in tok or " " in tok or ":" in tok:
        return False
    for piece in tok.replace("...", " ").replace("(", " ").replace(")", " ").split():
        if not piece or not IDENT.match(piece):
            continue
        if wide:
            return True
        if "_" in piece or re.search(r"[a-z][A-Z]", piece) or re.fullmatch(r"[A-Z0-9_]{4,}", piece):
            return True
    return False


def candidates(clause, wide):
    out = []
    for tok in BACKTICK.findall(clause):
        for piece in tok.replace("...", " ").replace("(", " ").replace(")", " ").split():
            if shaped(piece, wide) and piece not in out:
                out.append(piece)
    return out


# Um arquivo citado pelo nome sem caminho: `check_secrets.sh`, `paid_catalog.json`.
# `IDENT` rejeia o ponto, então essa forma era invisível à régua de nome, e a de
# literal só julga o que mora UMA vez no arquivo — `check_secrets.sh` mora duas no
# runner (o motivo escrito e a chamada). Foi por essa fresta que
# `tests/IdleTests.gd:6018` apontou a linha 431 de `scripts/test.sh` para dizer que
# `check_secrets.sh` entrou no runner, quando a entrada vive na 532: a linha citada
# existia, tinha texto, e não era o que a frase afirmava. Consertado à mão e agora
# cobrado.
DOTNAME = re.compile(r"^[A-Za-z0-9_-]+\.(?:sh|py|gd|yml|yaml|md|json|sql|mjs|conf|cfg|csv|toml)$")


def dotcands(clause):
    out = []
    for tok in BACKTICK.findall(clause):
        for piece in tok.replace("...", " ").replace("(", " ").replace(")", " ").replace(",", " ").split():
            if DOTNAME.match(piece) and piece not in out:
                out.append(piece)
    return out


def mentions(word, text):
    """Palavra inteira, no sentido de identificador: `up` nao morde `group`."""
    return re.search(r"(?<![A-Za-z0-9_])" + re.escape(word) + r"(?![A-Za-z0-9_])", text) is not None


def verdict(clause, ptr, target_lines, wide):
    """(ok, candidatos, onde_mora, motivo). `clause` e o texto da frase ANTES deste ponteiro."""
    a, b = int(ptr.group(2)), ptr.group(3)
    last = int(b) if b else a
    # A borda do intervalo e o que quem abre o arquivo le. A regua de nome julga o
    # span como um texto so, e um texto com borda em branco ainda contem o simbolo —
    # foi assim que a linha 53 de `ROADMAP_COMERCIAL.md`, citando o intervalo 503-509
    # de `sources/economy/EconomyService.gd` com o topo em branco, passou no portao
    # rapido (~1 min de python) e caiu no `run_idle_tests` (20 min)
    # tres vezes na mesma passada. Linha vazia nao mostra nada para ninguem, e o
    # motivo pelo qual ela mora aqui, no portao barato, e so o preco do run.
    for edge in (a, last):
        if 1 <= edge <= len(target_lines) and not target_lines[edge - 1].strip():
            return False, [], [edge], "branco"
    span = "\n".join(target_lines[max(0, a - 1):min(len(target_lines), int(b) if b else a)])
    joined = "\n".join(target_lines)
    # Nome de arquivo citado pelo nome: perdoa a linha exata se o nome mora no mesmo
    # quinhão delimitado por linha em branco (citar o bloco é prosa honesta) ou a uma
    # linha de vizinhança; fora disso, a âncora deslizou para um texto cheio de outra
    # coisa — a classe que a régua de literal não vê porque o nome multiplicado não
    # pinha uma linha só.
    dots = [c for c in dotcands(clause) if mentions(c, joined)]
    if dots and not any(mentions(c, span) for c in dots):
        lo, hi = lit_chunk(target_lines, a, last)
        neighborhood = "\n".join(target_lines[max(0, a - 2):min(len(target_lines), last + 1)])
        chunk = "\n".join(target_lines[max(0, lo - 1):min(len(target_lines), hi)])
        if not any(mentions(c, neighborhood) or mentions(c, chunk) for c in dots):
            first = dots[0]
            where = [i + 1 for i, t in enumerate(target_lines) if mentions(first, t)][:4]
            return False, dots, where, "arquivo"
    cands = [c for c in candidates(clause, wide) if mentions(c, joined)]
    if not cands:
        return True, [], [], "nome"
    if any(mentions(c, span) for c in cands):
        return True, cands, [], "nome"
    first = cands[0]
    where = [i + 1 for i, t in enumerate(target_lines) if mentions(first, t)][:4]
    return False, cands, where, "nome"


def lit_chunk(target_lines, a, b):
    """O quinhão delimitado por linha em branco que contém [a..b].

    Citar o corpo de uma função apontando para a linha da função (ou vice-versa) é
    prosa honesta, e régua que acusa isso vira ruído que se desliga. A fronteira que
    separa um bloco de outro, nestes nove arquivos de linguagem diferentes (gd, py,
    sh, conf, yml, json, md, html, mjs), é a linha em branco — não a indentação, que
    um `.conf` de nginx e um `.gd` de Godot não escrevem igual.
    """
    n = len(target_lines)
    if not (1 <= a <= n):
        return (a, b)
    lo = a
    while lo - 1 >= 1 and target_lines[lo - 2].strip():
        lo -= 1
    hi = b
    while hi + 1 <= n and target_lines[hi].strip():
        hi += 1
    return (lo, hi)


def litverdict(clause, spans, target_lines, stem=None):
    """(julgado, ok, literal, linha_onde_mora) pela régua do LITERAL pinado.

    A régua de nome acima só morde quando a frase nomeia um identificador. Há
    afirmações que prometem outra coisa: "o probe é honesto porque `EXPOSE 8901`
    (deploy/companion/Dockerfile:38)". O que se cobra é o literal entre backticks:

     - ele tem de existir no arquivo-alvo EXATAMENTE UMA vez — é isso que o torna
       régua; duas ocorrências não pinham nada, e a régua devolve "não julgado" em
       vez de chutar;
     - a linha pinada tem de ser a citada (com uma linha de vizinhança), OU morar no
       mesmo quinhão que a linha citada, OU a linha citada tem de conter todas as
       palavras do literal. Fora dessas três, a âncora deslizou: aponta para uma
       linha que tem texto, mas não é o texto.

    É exatamente o buraco que esta passada abriu: as 23 âncoras corrigidas satisfaziam
    "linha com texto" enquanto apontavam para outro código, e nada no portão podia ver
    isso.

    `stem` é o nome do arquivo-alvo sem extensão. Nomear o próprio arquivo (`NpcScript`
    em `NpcScript.gd`) é dizer como a coisa se chama, não onde ela mora: num arquivo que
    é a definição de uma classe, o nome dela ocorre uma vez só — no `class_name` — e
    cobrar isso de cada ponteiro para um método da classe seria acusar prosa honesta.
    """
    joined = "\n".join(target_lines)
    for tok in BACKTICK.findall(clause):
        lit = tok.strip()
        if lit == stem:
            continue
        if len(lit) < 8 or "*" in lit or "?" in lit or ANYCITE.search(lit):
            continue
        if joined.count(lit) != 1:
            continue
        pin = joined[:joined.index(lit)].count("\n") + 1
        for a, b in spans:
            if a - 1 <= pin <= b + 1:
                return True, True, lit, pin
            lo, hi = lit_chunk(target_lines, a, b)
            if lo <= pin <= hi:
                return True, True, lit, pin
            span = "\n".join(target_lines[max(0, a - 1):min(len(target_lines), b)])
            pieces = [w for w in re.findall(r"[A-Za-z_][A-Za-z0-9_]{2,}", lit)]
            if pieces and all(mentions(w, span) for w in pieces):
                return True, True, lit, pin
        return True, False, lit, pin
    return False, True, "", 0


# `Betamax` existe na linha 2 e `Beta` so como palavra inteira na 3: e o par que mede
# a palavra-inteira. Cada controle declara o veredito ESPERADO nos dois cortes, e a
# diferenga entre eles e a medida do que o corte estreito nao enxerga.
ALVO = ["# cabecalho", "const Betamax : int = 1", "func Beta() -> void:", "\tgate.run()",
        "\tgate.run()"]
# ponteiro aqui é SEM backtick de propósito — é a forma que a identidade não vê.
# As linhas 2 e 6 são em branco de propósito: é a borda que a régua do branco cobra.
ALVO2 = ["# EXPOSE 8901 e o que o compose nomeia", "", "func Beta() -> void:",
         "\tgate.run()", "\tgate.run()", "", "\tgate.run()", "chamada EXPOSE com porta",
         "const Storefront : int = 1"]
# ALVO3 é o terreno da régua de NOME DE ARQUIVO: `check_alpha.sh` mora em dois blocos
# separados por linha em branco (2 e 4), `check_beta.sh` só no segundo (5). Linha 8 em
# branco é o que fecha o quinhão de cima — sem ela o bloco 4..9 seria um só e o
# controle que cobra a âncora deslizada deixaria de discriminar nada.
ALVO3 = ["# cabecalho", "\tgate_sh a.log scripts/check_alpha.sh", "",
         "\t# o mesmo check_alpha.sh e citado adentro",
         "\tgate_sh b.log scripts/check_beta.sh", "\tgate_sh c.log nada", "}", "",
         "echo pronto"]
CONTROLES = [
    ("positivo: simbolo na linha citada e aprovado", "abre a sessao em `Beta` (`x.gd:3`)", True, True),
    ("negativo: um linha acima, e substring pura, e acusado", "abre a sessao em `Beta` (`x.gd:2`)", True, False),
    ("alcance: ponteiro sem nome na clausa nao e julgado", "ver `x.gd:2` para o numero", True, True),
    ("minusculo: `gate` citado fora da linha dele e acusado no wide", "bate em `gate` (`x.gd:2`)", True, False),
    ("minusculo: `gate` na linha onde ele existe e aprovado", "bate em `gate` (`x.gd:4`)", True, True),
    ("rotulo: nome que nao existe no arquivo e so prosa", "o `jogo_todo_inteiro` roda em `x.gd:2`", True, True),
    ("caminho: `user://live.db` nao e identificador", "a base `user://live.db` esta em `x.gd:2`", True, True),
    ("faixa: o span aceita o nome em qualquer linha do range", "roda em `Beta`-`gate` (`x.gd:3-4`)", True, True),
    # Os quatro abaixo usam ALVO2, que tem linha em branco — a borda e o que a
    # pessoa le ao abrir o numero citado, e o corte nao muda isso.
    ("branco: fim de faixa em linha vazia e acusado mesmo com o nome no span",
     "roda em `Beta` (`x.gd:3-6`)", False, False, ALVO2),
    ("branco: inicio de faixa em linha vazia e acusado",
     "roda em `Beta` (`x.gd:2-3`)", False, False, ALVO2),
    ("branco: faixa sem borda vazia continua aprovada",
     "roda em `Beta`-`gate` (`x.gd:3-5`)", True, True, ALVO2),
    ("branco: ponteiro que nao nomeia nada cai na mesma regua da linha vazia",
     "ver `x.gd:2` para o numero", False, False, ALVO2),
    # Nome de arquivo sem caminho: a forma que o `IDENT` nao ve e que a régua de
    # literal nao pinha porque o nome multiplicado mora mais de uma vez no alvo.
    ("arquivo: nome citado na linha onde ele mora e aprovado",
     "o `check_alpha.sh` entrou (`x.gd:2`)", True, True, ALVO3),
    ("arquivo: nome multiplicado apontando para bloco de outro e acusado",
     "o `check_beta.sh` entrou (`x.gd:2`)", False, False, ALVO3),
    ("arquivo: quinhao perdoa a linha exata quando o nome mora no mesmo bloco",
     "o `check_alpha.sh` e comentado (`x.gd:6`)", True, True, ALVO3),
    ("arquivo: nome que nao existe no alvo e so prosa",
     "o `check_gamma.sh` entrou (`x.gd:6`)", True, True, ALVO3),
    ("arquivo: caminho com barra nao entra na regua nova",
     "o `scripts/check_alpha.sh` entrou (`x.gd:9`)", True, True, ALVO3),
]
LIT_CONTROLES = [
    ("positivo: literal único exatamente na linha citada", "o `func Beta() -> void:` mora em x.gd:3", True, True),
    ("vizinho: uma linha de folga ainda é a mesma afirmação", "o `func Beta() -> void:` mora em x.gd:4", True, True),
    ("bloco: citar o corpo do bloco que contém o literal é verdade", "o `func Beta() -> void:` mora em x.gd:5", True, True),
    ("negativo: o mesmo literal, cite outro bloco, e a régua morde", "o `func Beta() -> void:` mora em x.gd:8", True, False),
    ("negativo: literal pinado longe, com o bloco citado no meio do arquivo", "o `EXPOSE 8901` mora em x.gd:3", True, False),
    ("peca: todas as palavras do literal na linha citada aprovam", "o `EXPOSE 8901` mora em x.gd:8", True, True),
    ("nao pinado: literal que ocorre três vezes não é régua", "repete `gate.run()` em x.gd:1", False, None),
    ("glob: `tests/*_test.gd` nomeia um conjunto, não uma linha", "repete `tests/*_test.gd` em x.gd:1", False, None),
    ("ausente: literal que não existe no alvo não é julgado", "fala `betaquemnaoexiste` em x.gd:1", False, None),
    ("curto: `Beta()` é miúdo demais para pinar linha", "chama `Beta()` em x.gd:1", False, None),
    ("prosa: frase sem literal fica fora do censo", "veja o número em x.gd:1", False, None),
    ("cláusula: literal da oração coordenada não é promessa deste ponteiro",
     "o `func Beta() -> void:` existe, mas não mora em x.gd:8", False, None),
    ("pontuação: a vírgula colada ao ponteiro não corta a cláusula",
     "(`func Beta() -> void:`, x.gd:3)", True, True),
    ("quebra: a promessa na linha de cima vale para este ponteiro",
     "a imagem expõe `EXPOSE 8901`\nem x.gd:1", True, True),
    ("quebra: só o resto depois do último ponteiro da linha de cima é cláusula",
     "mora em x.gd:3, o corpo `func Beta() -> void:`\nfica em x.gd:8", True, False),
    ("quebra: o backtick de fechamento do ponteiro carregado não vira abertura",
     "vive em `x.gd:1`, o `func Beta() -> void:`\nfica em x.gd:8", True, False),
    ("quebra: o backtick de abertura do próprio ponteiro não é cláusula",
     "porta do `EXPOSE 8901`\n(`x.gd:1`)", True, True),
    ("homonímia: nomear o próprio arquivo não é prometer uma linha dele",
     "o `Storefront` é cosmético em Storefront.gd:5", False, None),
    ("sentença: o ponto que fecha a frase anterior não carrega a promessa dela",
     "`EXPOSE 8901` é o que a imagem expõe. A rota de saúde fica em outra linha, "
     "e o número está em x.gd:3", False, None),
]


def litselftest():
    biting = 0
    total = 0
    for label, text, esp_j, esp_ok in LIT_CONTROLES:
        total += 1
        head, brk, cur = text.rpartition("\n")
        ptr_text = cur if brk else text
        m = ANYCITE.search(ptr_text)
        seg = ptr_text[:m.start()]
        clause = lit_clause(head + "\n" if brk else None, seg, True,
                            seg.endswith("`") and ptr_text[m.end():m.end() + 1] == "`")
        stem = os.path.splitext(os.path.basename(m.group(1)))[0]
        judged, ok, lit, pin = litverdict(clause, lit_spans(m), ALVO2, stem)
        wrong = None
        if judged != esp_j:
            wrong = "julgou=%s deveria ser %s" % (judged, esp_j)
        elif esp_ok is not None and ok != esp_ok:
            wrong = "ok=%s deveria ser %s" % (ok, esp_ok)
        if wrong is None:
            biting += 1
        else:
            print("[FAIL] literal: self-test cego no controle %s (%s)" % (label, wrong))
    return biting, total


def selftest():
    biting = 0
    total = 0
    for wide in (False, True):
        nome = "wide" if wide else "narrow"
        for label, text, esperado_n, esperado_w, *fixture in CONTROLES:
            total += 1
            alvo = fixture[0] if fixture else ALVO
            esperado = esperado_w if wide else esperado_n
            ok, cands, where, motivo = verdict(text[:text.index("`x.gd")], PTR.search(text), alvo, wide)
            if ok == esperado:
                biting += 1
            else:
                print("[FAIL] identidade: self-test %s cego no controle %s (%s)"
                      % (nome, label, "aprovou o que devia acusar" if ok else "acusou o que devia aprovar"))
    return biting, total


def scan(root, wide, reg):
    cache = {}
    lit_judged = 0
    lit_accused = 0
    reg_judged = 0
    reg_accused = 0

    def lines_of(path):
        if path not in cache:
            full = os.path.join(root, path)
            cache[path] = open(full, encoding="utf-8", errors="replace").read().split("\n") \
                if os.path.isfile(full) else None
        return cache[path]

    accused = 0
    judged = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in KEEP and (not d.startswith(".") or d == ".github")]
        for fn in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
            if rel.startswith("archive/") or os.path.basename(rel) in SKIP_NAMES:
                continue
            if not fn.endswith(EXTS):
                continue
            src = lines_of(rel)
            if src is None:
                continue
            is_doc = fn.endswith(".md")
            for n, line in enumerate(src, 1):
                # Em codigo, so comentario: o corpo de uma funcao nao e prosa nomeando
                # a linha de outra pessoa.
                if not is_doc and not line.lstrip().startswith(("#", "//")):
                    continue
                prev_end = 0
                for m in PTR.finditer(line):
                    target = m.group(1)
                    if target.startswith("res://"):
                        target = target[6:]
                    clip = line[prev_end:m.start()]
                    prev_end = m.end()
                    if "|" in clip:
                        clip = clip.rsplit("|", 1)[-1]
                    tl = lines_of(target)
                    if tl is None:
                        continue
                    judged += 1
                    ok, cands, where, motivo = verdict(clip, m, tl, wide)
                    if ok:
                        continue
                    accused += 1
                    if motivo == "branco":
                        print("[FAIL] branco: %s:%d aponta %s e a linha %s está em branco — quem abre no número citado não vê nada"
                              % (rel, n, m.group(0), where[0]))
                    elif motivo == "arquivo":
                        print("[FAIL] arquivo: %s:%d nomeia %s e aponta %s:%s; o nome mora em %s — a linha citada é texto cheio de outra coisa"
                              % (rel, n, cands[:3], target, m.group(2), where or "lugar nenhum"))
                    else:
                        print("[FAIL] identidade: %s:%d nomeia %s e aponta %s:%s; o nome mora em %s"
                              % (rel, n, cands[:3], target, m.group(2), where or "lugar nenhum"))
                # Régua de literal: os mesmos ponteiros da linha, com ou sem backtick,
                # julgados pelo que a frase PROMETE em código. É ortogonal ao censo de
                # nome acima, e é o que vê a âncora que deslizou para outra linha.
                lit_prev_end = 0
                lit_k = 0
                for m2 in ANYCITE.finditer(line):
                    lit_k += 1
                    seg = line[lit_prev_end:m2.start()]
                    lit_prev_end = m2.end()
                    if "|" in seg:
                        seg = seg.rsplit("|", 1)[-1]
                    tl2 = lines_of(m2.group(1))
                    if tl2 is None:
                        continue
                    stem2 = os.path.splitext(os.path.basename(m2.group(1)))[0]
                    pin_judged, pin_ok, lit2, pin2 = litverdict(
                        lit_clause(src[n - 2] if n > 1 else None, seg, lit_k == 1,
                                   seg.endswith("`") and m2.end() < len(line)
                                   and line[m2.end()] == "`"),
                        lit_spans(m2), tl2, stem2)
                    if not pin_judged:
                        continue
                    lit_judged += 1
                    if pin_ok:
                        continue
                    lit_accused += 1
                    print("[FAIL] literal: %s:%d promete %r e aponta %s; o literal mora na linha %s"
                          % (rel, n, lit2, m2.group(0), pin2))
                # Regua de registro: o numeral que a frase afirma, contra o tamanho
                # lido do proprio fonte. Nao depende do corte (compara numero, nao forma
                # de identificador), entao os dois passes tem de ver o mesmo — a
                # igualdade é invariant e é cobrada em main().
                for m3 in NUMREG.finditer(line):
                    reg_ok, reg_good = regverdict(m3.group(1), reg)
                    if not reg_ok:
                        continue
                    reg_judged += 1
                    if reg_good:
                        continue
                    reg_accused += 1
                    print("[FAIL] registro: %s:%d afirma \"%s gates de estrutura\" e o registro em scripts/test.sh tem %s"
                          % (rel, n, m3.group(1),
                             "nenhuma chamada de gate_sh lida (scripts/test.sh nao encontrado)"
                             if reg is None else "%d chamada(s) de gate_sh em structure_gates()" % len(reg)))
    return judged, accused, lit_judged, lit_accused, reg_judged, reg_accused


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    biting, cases = selftest()
    lbiting, lcases = litselftest()
    rbiting, rcases = regselftest()
    reg = registry(root)
    narrow_judged, narrow_bad, lit_judged, lit_bad, reg_judged, reg_bad = scan(root, False, reg)
    wide_judged, wide_bad, lit_judged_w, lit_bad_w, reg_judged_w, reg_bad_w = scan(root, True, reg)
    accused = narrow_bad + wide_bad
    # A régua de literal não depende do corte: ela compara texto, não forma de
    # identificador. Os dois passes têm de ver o mesmo; divergir é o walk tendo
    # mudado de forma entre os cortes, e aí nenhum dos dois números vale.
    cut_drift = (lit_judged, lit_bad) != (lit_judged_w, lit_bad_w)
    reg_cut_drift = (reg_judged, reg_bad) != (reg_judged_w, reg_bad_w)
    print("identidade de ponteiro: %d nomeados no corte narrow (%d acusacoes), %d no corte wide (%d acusacoes), self-test %d/%d controles mordendo"
          % (narrow_judged, narrow_bad, wide_judged, wide_bad, biting, cases))
    print("literal pinado: %d ponteiros com literal único no alvo (%d acusacoes), self-test %d/%d controles mordendo"
          % (lit_judged, lit_bad, lbiting, lcases))
    print("registro de gates de estrutura: %d prosas afirmando a contagem (%d acusações), %s, self-test %d/%d controles mordendo"
          % (reg_judged, reg_bad, "registro NÃO lido" if reg is None else "registro com %d gates" % len(reg), rbiting, rcases))
    if reg_cut_drift:
        print("[FAIL] registro: narrow viu %r e wide viu %r — contagem de numeral não depende do corte"
              % ((reg_judged, reg_bad), (reg_judged_w, reg_bad_w)))
    if cut_drift:
        print("[FAIL] literal: narrow viu %r e wide viu %r — a régua não depende do corte, a igualdade é invariant"
              % ((lit_judged, lit_bad), (lit_judged_w, lit_bad_w)))
    # Maquina: as tres linhas abaixo sao o que a secao bash soma em `checks` e `failures`.
    print("IDENTIDADE %d %d %d %d %d" % (narrow_judged, wide_judged, accused, cases, biting))
    print("LITERAL %d %d %d %d" % (lit_judged, lit_bad, lcases, lbiting))
    print("REGISTRO %d %d %d %d" % (reg_judged, reg_bad, rcases, rbiting))
    if (biting != cases or accused or narrow_judged < MIN_CHECKS or wide_judged < narrow_judged
            or cut_drift or reg_cut_drift or lbiting != lcases or rbiting != rcases
            or reg_bad or reg is None):
        return 1
    return 0


sys.exit(main())
PYEOF
)"
	ident_code=$?
	printf '%s\n' "$ident_out" | grep -vE '^(IDENTIDADE|LITERAL|REGISTRO) '
	ident_stats="$(printf '%s\n' "$ident_out" | grep '^IDENTIDADE ' | tail -n 1)"
	lit_stats="$(printf '%s\n' "$ident_out" | grep '^LITERAL ' | tail -n 1)"
	checks=$((checks + 1))
	if [ -z "$ident_stats" ]; then
		fail "a régua de identidade não devolveu a linha \`IDENTIDADE\` (código $ident_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		ident_narrow=0
		ident_wide=0
		ident_accused=0
		ident_cases=0
		ident_biting=0
		read -r _lab ident_narrow ident_wide ident_accused ident_cases ident_biting <<< "$ident_stats"
		checks=$((checks + ident_narrow + ident_wide))
		failures=$((failures + ident_accused))
		if [ "$ident_biting" -ne "$ident_cases" ]; then
			fail "self-test da identidade mordeu $ident_biting de $ident_cases controles — com a régua cega, o zero de acusações não vale nada"
		fi
		if [ "$ident_narrow" -lt "$IDENT_MIN" ] || [ "$ident_wide" -lt "$ident_narrow" ]; then
			fail "identidade julgou pouco (narrow=$ident_narrow com piso $IDENT_MIN, wide=$ident_wide) — um walk quebrado também devolve zero acusações"
		fi
		if [ "$ident_accused" -eq 0 ] && [ "$ident_biting" -eq "$ident_cases" ] && [ "$ident_narrow" -ge "$IDENT_MIN" ] && [ "$ident_wide" -ge "$ident_narrow" ]; then
			echo "[ok] $((${ident_narrow} + ${ident_wide})) ponteiros nomeados conferidos linha a linha nos dois cortes (borda em branco acusada), com os ${ident_cases} controles do self-test mordendo"
		fi
	fi
	# ---------------------------------------------------------------------------
	# 25) LITERAL pinado: o que a FRASE promete entre backticks tem que morar na
	# linha citada.
	#
	# A seção 23 só morde quando a cláusula nomeia um identificador. Há afirmações que
	# prometem outra coisa: um probe que diz ser honesto porque a imagem expõe a porta
	# que a frase escreve. Isso não nomeia nada — nomeia um trecho — e a identidade não
	# tem como ver. Foi exatamente assim que as 23 âncoras da passada de 2026-09-28
	# ficaram verdes: satisfaziam "linha com texto" enquanto apontavam para outro
	# código, e nenhum portão podia ver a diferença.
	#
	# O motor vive em `litverdict`, `lit_clause` e `lit_chunk` no heredoc acima. Julga
	# o literal que mora UMA vez no arquivo-alvo (duas ocorrências não pinham nada, e
	# chutar seria a régua mentindo) e aprova por três caminhos: a linha pinada é a
	# citada ou vizinha (±1), o literal mora no mesmo quinhão delimitado por linha em
	# branco, ou a linha citada contém todas as palavras dele. Isenções medidas, cada
	# uma com controle próprio no self-test: glob, token curto, autocolitação, homônimo
	# do arquivo-alvo, e a cláusula recortada por cima de quebra de linha — que é onde
	# a régua quase acusou prosa honesta.
	checks=$((checks + 1))
	if [ -z "$lit_stats" ]; then
		fail "a régua de literal não devolveu a linha \`LITERAL\` (código $ident_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		lit_n=0
		lit_accused=0
		lit_cases=0
		lit_biting=0
		read -r _lab lit_n lit_accused lit_cases lit_biting <<< "$lit_stats"
		checks=$((checks + lit_n))
		failures=$((failures + lit_accused))
		if [ "$lit_biting" -ne "$lit_cases" ]; then
			fail "self-test do literal mordeu $lit_biting de $lit_cases controles — com a régua cega, o zero de acusações não vale nada"
		fi
		if [ "$lit_n" -lt "$LIT_MIN" ]; then
			fail "literal julgou pouco (n=$lit_n com piso $LIT_MIN) — um walk quebrado também devolve zero acusações"
		fi
		if [ "$lit_accused" -eq 0 ] && [ "$lit_biting" -eq "$lit_cases" ] && [ "$lit_n" -ge "$LIT_MIN" ]; then
			echo "[ok] $lit_n ponteiros conferidos pelo literal que a frase promete, com os $lit_cases controles do self-test mordendo"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# 24) CAMINHO de doc: um `.md` citado entre backticks tem que existir na árvore.
#
# A seção 23 confere o que MORA na linha de um ponteiro; ela é cega ao ponteiro para um
# ARQUIVO que não está mais lá. A classe apareceu nesta passada com nome e sobrenome: os
# relatórios de auditoria moravam na raiz, foram para `archive/`, e a prosa de `sources/`,
# `deploy/` e dos documentos de plano continuou citando o caminho velho. Quem abre o doc,
# cola o caminho e tenta ler não abre nada.
#
# O que é julgado:
#  - token entre backticks que termina em `.md`, com ou sem o sufixo `:NN[-MM]` de
#    ponteiro (o sufixo é desmontado antes de julgar);
#  - com barra -> o caminho tem que existir EXATAMENTE onde foi escrito, relativo à raiz;
#  - sem barra -> o nome tem que existir em algum lugar da árvore, `archive/` incluído.
# Só `.md` porque foi o que sobrou da medição: estender para `.py`, `.sh`, `.json` e `.gd`
# produziu 66 acusações cuja maioria era caminho absoluto de container e basename que a
# própria prosa declara morto. Régua que só existe com exceção é ruído, e ruído em gate
# de doc mata o gate. Quatro filtros, cada um controle do self-test: caminho `res://`,
# caminho absoluto, comando que embute caminho e glob do tipo `adding-a-*.md`.
#  - exceção registrada em `scripts/dead_paths.txt`: uma linha por caminho, com motivo
#    obrigatório depois do `|`. Caminho registrado que VOLTOU a existir é acusado; o
#    registro apodrece junto, senão vira licença para citar fantasma.
#  - registros datados (este arquivo grava datas) não são fonte: o caminho que um diário
#    gravou era verdadeiro no momento do registro, e cobrar a verdade de hoje dele é
#    reescrever histórico.
#
# Piso de volume (100 caminhos; medido em 121 nesta passada) e self-test de 18 controles
# cobrindo veredito, extração e registro. Sem os dois mordendo, zero acusações não é
# notícia: é a régua quebrada, e é por isso que o piso existe.
# ---------------------------------------------------------------------------
PATH_MIN=100
if ! command -v "$PY" >/dev/null 2>&1; then
	checks=$((checks + 1))
	fail "python3 indisponível (PYTHON=$PY) — a régua de caminho de doc não rodou; ausência conta como falha, não como pulo"
else
	path_out="$("$PY" - "$PWD" <<'PYEOF' 2>&1

# -*- coding: utf-8 -*-
"""Caminho de doc citado: se a prosa nomeia `alguma/coisa.md`, o arquivo tem que estar la.

Secao 24 de scripts/check_doc_drift.sh.

A regula de identidade (secao 23) confere o que mora NA linha de um ponteiro; ela nao
enxerga o ponteiro para um ARQUIVO que nao esta mais la. Esta e a mordida contra a
classe que apareceu em 2026-09-28: os relatorios de auditoria moravam na raiz, foram
para `archive/`, e a prosa de `sources/`, `deploy/` e dos documentos de plano continuou
citando o caminho velho. Quem abre o doc e cola o caminho abre um arquivo que nao existe.

 - token: o que esta entre backticks, partido em palavras, com o sufixo `:NN`/`:NN-MM`
   removido antes de julgar. So `.md` entra, e isso foi medido: estender para `.py`,
   `.sh`, `.json` e `.gd` produziu 66 acusacoes cuja maioria era caminho absoluto de
   container e basename que a propria prosa declara morto. Custo alto, valor baixo.
 - com barra: o caminho tem que existir EXATAMENTE onde foi escrito, relativo a raiz.
 - sem barra: o nome tem que existir em algum lugar da arvore (prosa cita relatorio pelo
   nome; o que se pune aqui e nome que nao resolve a nada).
 - quatro filtros contra falso positivo, cada um controle do self-test: `res://`,
   caminho absoluto (`/app/x.md`), comando que embute caminho (`git show 1^:x.md`) e
   glob (`docs/adding-a-*.md`).
 - excecao: `scripts/dead_paths.txt`, onde cada linha precisa de `| <motivo>`. Um
   caminho registrado que VOLTOU a existir e acusado: o registro apodrece junto.
"""
import os
import re
import sys

MIN_PATHS = 100
KEEP = {".git", ".godot", ".test-home", "__pycache__", "node_modules", ".venv", "graphify-out", "build"}
EXTS = (".md", ".gd", ".py", ".sh", ".mjs", ".yml", ".yaml")
# Registros datados: o caminho que la esta foi verdadeiro no momento do registro, e
# reescrever historico para satisfazer uma regula de hoje e o erro contrario.
SKIP_NAMES = {"CHANGELOG.md", "progress.md", "ROADMAP_COMERCIAL.md", "BLIND_JUDGE_PROTOCOL.md"}

SLASHED = re.compile(r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\.md$")
BARE = re.compile(r"^[A-Za-z0-9_.-]+\.md$")
SUFFIX = re.compile(r":\d+(?:-\d+)?$")
BACKTICK = re.compile(r"`([^`]+)`")


def paths_in(line):
    """Os caminhos `.md` que a linha cita, ja sem o sufixo de numero."""
    out = []
    for tok in BACKTICK.findall(line):
        for piece in tok.replace("...", " ").replace("(", " ").replace(")", " ").split():
            p = SUFFIX.sub("", piece)
            if (SLASHED.match(p) or BARE.match(p)) and p not in out:
                out.append(p)
    return out


def decide(path, exists, names, dead):
    """(julgado, ok, porque). Pura: so nome, um `exists`, o inventario e o registro."""
    if SLASHED.match(path):
        if exists(path):
            return True, True, ""
        if path in dead:
            return True, True, ""
        return True, False, "caminho com barra citado nao existe na arvore"
    if BARE.match(path):
        if path in names:
            return True, True, ""
        return True, False, "nome citado nao existe em nenhum lugar da arvore"
    return False, True, ""


def read_registry(text):
    """(caminhos, erros). Cada linha: `caminho | motivo`."""
    paths = []
    errors = []
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "|" not in line:
            errors.append("entrada sem motivo: %s" % line)
            continue
        path, reason = line.split("|", 1)
        path = path.strip()
        reason = reason.strip()
        if not SLASHED.match(path):
            errors.append("registro so vale para caminho de .md com barra: %s" % path)
            continue
        if len(reason) < 12:
            errors.append("motivo curto demais em %s (%d caracteres)" % (path, len(reason)))
            continue
        paths.append(path)
    return paths, errors


def registry_rot(dead, exists):
    """Entrada que voltou a existir: o registro virou licenca para um caminho fantasma."""
    return [p for p in dead if exists(p)]


EXISTE = {"docs/development/testing.md", "deploy/ROLLBACK.md", "README.md", ".kilo/plans/vivo.md"}
NOMES = {"testing.md", "ROLLBACK.md", "README.md", "AUDITORIA_SHAMBLETA.md"}
MORTOS = [".kilo/plans/x.md", ".kilo/plans/vivo.md"]


def selftest():
    biting = 0
    total = 0

    def check(label, got, want):
        nonlocal biting, total
        total += 1
        if got == want:
            biting += 1
        else:
            print("[FAIL] caminho: self-test cego em %s (esperava %r, veio %r)" % (label, want, got))

    ex = lambda p: p in EXISTE  # noqa: E731
    for label, path, want in [
        ("caminho com barra que existe e aprovado", "docs/development/testing.md", (True, True)),
        ("caminho com barra no diretorio errado e acusado", "development/testing.md", (True, False)),
        ("nome solto que existe em algum lugar e aprovado", "AUDITORIA_SHAMBLETA.md", (True, True)),
        ("nome solto que nao resolve a nada e acusado", "RELATORIO_QUE_NAO_EXISTE.md", (True, False)),
        ("caminho registrado como morto e aprovado", ".kilo/plans/x.md", (True, True)),
        ("coisa que nao e caminho nao e julgada", "gate()", (False, True)),
    ]:
        judged, ok, _ = decide(path, ex, NOMES, MORTOS)
        check(label, (judged, ok), want)

    for label, line, want in [
        ("sufixo de linha e desmontado antes de julgar", "ver `docs/development/testing.md:12-13`", ["docs/development/testing.md"]),
        ("`res://` nao e caminho de repo", "abra `res://docs/testing.md`", []),
        ("absoluto de container nao e", "dentro de `/app/companion/x.md`", []),
        ("comando que embute caminho nao e", "leia `git show 6277671^:.kilo/x.md`", []),
        ("glob nao e", "as receitas `docs/development/adding-a-*.md`", []),
        ("dois caminhos na mesma linha", "de `deploy/ROLLBACK.md` para `README.md`", ["deploy/ROLLBACK.md", "README.md"]),
    ]:
        check(label, paths_in(line), want)

    paths_ok, errs_ok = read_registry("a/b.md | motivo longo o bastante para valer\n")
    check("registro: entrada valida nao acusa", (paths_ok, errs_ok), (["a/b.md"], []))
    check("registro: entrada sem motivo e acusada", read_registry("sem-motivo.md\n")[1],
          ["entrada sem motivo: sem-motivo.md"])
    check("registro: caminho sem barra e recusado", read_registry("soNome.md | motivo longo o bastante\n")[1],
          ["registro so vale para caminho de .md com barra: soNome.md"])
    check("registro: motivo curto e acusado", read_registry("a/b.md | tao curto\n")[1],
          ["motivo curto demais em a/b.md (9 caracteres)"])
    check("rot: entrada que voltou a existir e acusada", registry_rot(MORTOS, ex), [".kilo/plans/vivo.md"])
    check("rot: entrada ainda morta nao acusa", registry_rot([".kilo/plans/x.md"], ex), [])
    return biting, total


def inventory(root):
    """Basenames de `.md` que existem na arvore inteira, archive/ incluido."""
    names = set()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in KEEP and (not d.startswith(".") or d == ".github")]
        for fn in filenames:
            if fn.endswith(".md"):
                names.add(fn)
    return names


def scan(root, names, dead, exists):
    accused = 0
    judged = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in KEEP and (not d.startswith(".") or d == ".github")]
        for fn in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
            if rel.startswith("archive/") or os.path.basename(rel) in SKIP_NAMES:
                continue
            if not fn.endswith(EXTS):
                continue
            is_doc = fn.endswith(".md")
            with open(os.path.join(dirpath, fn), encoding="utf-8", errors="replace") as handle:
                for n, line in enumerate(handle.read().split("\n"), 1):
                    if not is_doc and not line.lstrip().startswith(("#", "//")):
                        continue
                    for path in paths_in(line):
                        judged += 1
                        ok, good, why = decide(path, exists, names, dead)
                        if ok and good:
                            continue
                        if not ok:
                            continue
                        accused += 1
                        print("[FAIL] caminho: %s:%d cita `%s` - %s" % (rel, n, path, why))
    return judged, accused


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    biting, cases = selftest()
    names = inventory(root)
    reg = os.path.join(root, "scripts/dead_paths.txt")
    texto = open(reg, encoding="utf-8").read() if os.path.isfile(reg) else ""
    dead, reg_errors = read_registry(texto)
    if not os.path.isfile(reg):
        reg_errors = reg_errors + ["scripts/dead_paths.txt nao existe: a excecao da regula nao pode ser implicita"]

    def exists(path):
        return os.path.isfile(os.path.join(root, path))

    judged, accused = scan(root, names, set(dead), exists)
    rot = registry_rot(dead, exists)
    accused += len(reg_errors) + len(rot)
    for msg in reg_errors:
        print("[FAIL] caminho: registro scripts/dead_paths.txt - %s" % msg)
    for path in rot:
        print("[FAIL] caminho: registro scripts/dead_paths.txt lista %s, mas o arquivo voltou a existir" % path)
    print("caminhos de doc: %d citados e julgados, %d acusacoes, registro com %d excecoes, self-test %d/%d mordendo"
          % (judged, accused, len(dead), biting, cases))
    print("CAMINHOS %d %d %d %d" % (judged, accused, cases, biting))
    if biting != cases or accused or judged < MIN_PATHS:
        return 1
    return 0


sys.exit(main())
PYEOF
)"
	path_code=$?
	printf '%s\n' "$path_out" | grep -v '^CAMINHOS '
	path_stats="$(printf '%s\n' "$path_out" | grep '^CAMINHOS ' | tail -n 1)"
	checks=$((checks + 1))
	if [ -z "$path_stats" ]; then
		fail "a régua de caminho não devolveu a linha \`CAMINHOS\` (código $path_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		path_judged=0
		path_accused=0
		path_cases=0
		path_biting=0
		read -r _lab path_judged path_accused path_cases path_biting <<< "$path_stats"
		checks=$((checks + path_judged))
		failures=$((failures + path_accused))
		if [ "$path_biting" -ne "$path_cases" ]; then
			fail "self-test do caminho mordeu $path_biting de $path_cases controles — com a régua cega, o zero de acusações não vale nada"
		fi
		if [ "$path_judged" -lt "$PATH_MIN" ]; then
			fail "caminho julgou pouco ($path_judged com piso $PATH_MIN) — um walk quebrado também devolve zero acusações, e foi exatamente isso que o piso veio caçar"
		fi
		if [ "$path_accused" -eq 0 ] && [ "$path_biting" -eq "$path_cases" ] && [ "$path_judged" -ge "$PATH_MIN" ]; then
			echo "[ok] ${path_judged} caminhos de doc conferidos contra a árvore, com os ${path_cases} controles do self-test mordendo"
		fi
	fi
fi


# ---------------------------------------------------------------------------
# 26) NUMERAL DE REGISTRO: a contagem que a prosa afirma é lida do fonte.
#
# As três réguas acima conferem ponteiros: o que mora na linha, o nome citado, o
# caminho existindo. Nenhuma delas vê a frase que não cita arquivo nenhum e mesmo
# assim afirma um fato de código — "os nove gates de estrutura". Esta classe nasceu
# da própria passada: `structure_gates()` ganhou gate-log e boot-sandbox e quatro
# lugares continuaram dizendo sete, três e dois. Um juiz que escrevesse "uma
# afirmação que nenhum portão lê" acharia que este repo não lê contagem nenhuma.
#
# O veredito mora em `registry` e `regverdict` no heredoc da seção 23: o registro é o
# corpo de `structure_gates()` em `scripts/test.sh`, medido como as chamadas `gate_sh`
# que ele faz. Numeral que não é numeral ("outros", "os") é isento com controle
# próprio, registro ilegível nunca aprova, e os 11 controles têm de morder todos.
# ---------------------------------------------------------------------------
if ! command -v "$PY" >/dev/null 2>&1; then
	checks=$((checks + 1))
	fail "python3 indisponível (PYTHON=$PY) — a régua de numeral de registro não rodou; ausência conta como falha, não como pulo"
else
	reg_stats="$(printf '%s\n' "$ident_out" | grep '^REGISTRO ' | tail -n 1)"
	checks=$((checks + 1))
	if [ -z "$reg_stats" ]; then
		fail "a régua de registro não devolveu a linha \`REGISTRO\` (código $ident_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		reg_n=0
		reg_accused=0
		reg_cases=0
		reg_biting=0
		read -r _lab reg_n reg_accused reg_cases reg_biting <<< "$reg_stats"
		checks=$((checks + reg_n))
		failures=$((failures + reg_accused))
		if [ "$reg_biting" -ne "$reg_cases" ]; then
			fail "self-test do registro mordeu $reg_biting de $reg_cases controles — com a régua cega, o zero de acusações não vale nada"
		fi
		if [ "$reg_n" -lt "$REG_MIN" ]; then
			fail "registro julgou pouco ($reg_n com piso $REG_MIN) — prosa afirmando contagem sumiu ou o walk parou de ler os arquivos; nos dois casos o zero de acusações é a régua muda"
		fi
		if [ "$reg_accused" -eq 0 ] && [ "$reg_biting" -eq "$reg_cases" ] && [ "$reg_n" -ge "$REG_MIN" ]; then
			echo "[ok] $reg_n prosas afirmando quantos gates de estrutura existem conferidas contra o corpo de \`structure_gates()\`, com os $reg_cases controles do self-test mordendo"
		fi
	fi
fi
echo "== DOC DRIFT: $checks checks, $failures failures =="
exit "$failures"
