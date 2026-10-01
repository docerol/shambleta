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
#
#     A régua original casava só o substantivo `migrations` e por isso era cega à
#     sinonímia: `docs/development/testing.md` escreveu "as 61 patches reais do boot"
#     com 62 `.sql` no disco, e o portão passou verde sobre a mentira porque a palavra
#     era outra. A classe não é "a palavra migrations" — é "o artefato do diretório de
#     boot contado em prosa", e o artefato tem sinônimos. A tabela abaixo declara a
#     classe com suas formas; o `case` de controle no fim desta seção prova que cada
#     sinônimo morde, porque régua de sinônimo sem controle plantado é régua que um
#     dia volta a ser uma palavra só.
#
#     O que fica de fora, declarado: um sinônimo novo (`N scripts de boot`, por
#     exemplo) só é julgado se entrar na tabela. A alternativa — acusar qualquer
#     substantivo plural contado — foi medida na régua de cláusula e virou ruído.
MIG_SYNONYMS='migrations|migration|migracoes|migrações|patches|patch|sql'
MIG_PROSE_PAT="[0-9]+[[:space:]]+(versioned[[:space:]]+|avaliadas[[:space:]]+|de[[:space:]]+|reais[[:space:]]+do[[:space:]]+boot[[:space:]]+)?(${MIG_SYNONYMS})\b"
mig_prose() {
	tr '\n' ' ' < "$1" |
		grep -oiE "$MIG_PROSE_PAT" |
		grep -oE '^[0-9]+' | sort -u
}
for doc in $LIVE_DOCS; do
	for stated in $(mig_prose "$doc"); do
		expect "$doc diz \"$stated\" patches/migrations" "$stated" "$mig_count"
	done
done

# 3c) Controle plantado da régua de sinônimo: cada forma da tabela tem de devolver o
#     numeral quando o texto o chama pelo segundo nome. Se um sinônimo sair da tabela
#     (ou o recorte quebrar), o controle fica vermelho na mesma passada em que a doc
#     voltaria a mentir — nada é escrito em disco, a mordida é julgada em memória.
for forma in 'migrations' 'patches' 'sql'; do
	checks=$((checks + 1))
	probe="$(printf 'as 61 %s reais do boot\n' "$forma" |
		tr '\n' ' ' |
		grep -oiE "$MIG_PROSE_PAT" |
		grep -oE '^[0-9]+')"
	if [ "$probe" != "61" ]; then
		fail "controle da régua de registro: o sinônimo \`$forma\` não é julgado (recorte devolveu '${probe:-vazio}', esperava 61)"
	fi
done
checks=$((checks + 1))
if printf 'as 61 calendars do boot' | tr '\n' ' ' |
	grep -qiE "$MIG_PROSE_PAT"; then
	fail "controle da régua de registro: substantivo fora da classe (\`calendars\`) foi julgado — a tabela virou peneira"
fi
# A borda `\b` existe por um motivo: `sql` é um nome da classe e "sqlite" começa com
# ele. Sem borda, "as 28 tabelas sqlite" seria lido como contagem de patch e a régua
# acusaria uma frase honesta. O controle abaixo morde se alguém perder a borda.
checks=$((checks + 1))
if printf 'as 28 tabelas sqlite do boot' | tr '\n' ' ' |
	grep -qiE "$MIG_PROSE_PAT"; then
	fail "controle da régua de registro: \`sqlite\` foi julgado como contagem de patch — falta a borda de palavra na classe"
fi

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
	# `arquivo.gd:NN` e `arquivo.gd:NN-NN` são ponteiros de evidência: a âncora
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
#     `ui_*`/`gp_*` e a faixa 176-200 de `sources/input/Action.gd` despachar essa
#     ação. Ler
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
# 19b) Receita em bloco de código de doc viva não pode mandar rodar pelo atalho um
#      harness que o portão corre (`godot … -s tests/<nome>.gd`). O motivo é o
#      veredito, não a estética: `one` existe (scripts/test.sh, ramo `one`) porque a
#      alternativa de quem depura ou de um juiz é justamente esse comando cru, e ele é
#      o processo estrangeiro que o `boot_guard` recusa — dois boots no mesmo WAL
#      foram o SIGSEGV de 2026-09-28. Doc que ensina o atalho fabrica verde que ninguém
#      reproduz do jeito que o gate roda.
#
#      A exceção é estrutural e derivada do registro, não de lista decorada: só pode
#      ser chamado cru o que o portão NÃO corre (sonda `_probe_*`, diagnóstico
#      `diag_pacing`). A régua pergunta ao registro de `scripts/test.sh` — se o nome
#      está lá, a receita é vermelha. Prosa que NOMEA o comando proibido entre backticks
#      fora de bloco de código não é receita, e por isso não é julgada.
# ---------------------------------------------------------------------------
fenced_recipe_names() {
	[ -f "$1" ] || return 0
	awk '/^```/{f = !f; next} f' "$1" |
		grep -oE -- '-s[[:space:]]+tests/[A-Za-z0-9_]+\.gd' |
		sed 's#-s[[:space:]]*##; s#tests/##; s#\.gd$##' | sort -u
}

recipe_offends() {
	for n in $1; do
		case " $gate_scripts " in *" $n "*) printf '%s\n' "$n" ;; esac
	done
}

for doc in $LIVE_DOCS; do
	off="$(recipe_offends "$(fenced_recipe_names "$doc")")"
	[ -z "$off" ] && continue
	checks=$((checks + 1))
	fail "$doc receita de atalho para harness que o portão corre:$(printf ' %s' $off) — o jeito de reproduzir é \`bash scripts/test.sh one <nome>\`; godot cru sobre o mesmo WAL é o processo estrangeiro que o boot_guard recusa"
done

checks=$((checks + 1))
ctrl_off="$(recipe_offends "tick_capacity_test")"
if [ "$ctrl_off" != "tick_capacity_test" ]; then
	fail "controle da régua de receita: harness de gate chamado cru (\`tick_capacity_test\`) não foi acusado — ou o registro mudou, ou a régua virou no-op (devolveu '${ctrl_off:-vazio}')"
fi
checks=$((checks + 1))
ctrl_ok="$(recipe_offends "_probe_readonly diag_pacing")"
if [ -n "$ctrl_ok" ]; then
	fail "controle da régua de receita: diagnóstico chamado à mão ($ctrl_ok) foi acusado — a exceção deixou de ser 'o que o portão não corre'"
fi
checks=$((checks + 1))
if printf '```bash\ngodot --headless --path . -s tests/tick_capacity_test.gd\n```\n' |
	awk '/^```/{f = !f; next} f' |
	grep -qE -- '-s[[:space:]]+tests/[A-Za-z0-9_]+\.gd'; then
	:
else
	fail "controle da régua de receita: o recorte de bloco de código não enxerga \`-s tests/…\` dentro de fence — a régua julgaria doc nenhuma"
fi

# ---------------------------------------------------------------------------
# 19c) A página pública afirma a engine do build que ela entrega. `index.html` é
#      embarcado no mesmo job que exporta o Web com o `GODOT_VERSION` do workflow,
#      então a frase "Engine: Godot X" do landing é uma afirmação sobre o pin de CI,
#      não sobre a máquina de quem edita. Medido em 2026-09-29: o landing dizia 4.7.2
#      enquanto os dois workflows pinam 4.7.1 — um juiz leu a página, leu o workflow e
#      chamou de mentira, com razão. O `README.md:9-13` já declara a regra: o pin é o
#      do CI; runbook que diz 4.7.2 está falando do run local.
#      A régua lê os dois lados e não tolera ausência de nenhum dos dois: lado que não
#      parseia é vermelho, porque uma régua que passa quando não encontra o padrão é a
#      que dorme no dia em que o HTML muda de classe CSS.
# ---------------------------------------------------------------------------
engine_claim_verdict() { # <pin-ci> <landing> -> vazio = confere; texto = a acusação
	local pin="$1" landing="$2"
	if [ -z "$pin" ]; then
		printf 'pin de engine não foi lido de .github/workflows/ (GODOT_VERSION) — a régua da landing não tem com que conferir'
		return 0
	fi
	if [ -z "$landing" ]; then
		printf 'a landing não declara mais a engine no formato `Engine:</strong> Godot X.Y.Z` — ou a frase mudou, ou sumiu; a régua acima dela precisa ser ajustada junto'
		return 0
	fi
	if [ "$landing" != "$pin" ]; then
		printf 'deploy/web/landing/index.html entrega ao público engine %s, e o CI builda com %s — quem joga no browser recebe o build do pin, não o da máquina de quem edita' "$landing" "$pin"
		return 0
	fi
	printf ''
}

ci_pin="$(grep -hoE '^ *GODOT_VERSION: *[0-9]+\.[0-9]+\.[0-9]+' .github/workflows/godot-ci.yml .github/workflows/release.yml 2>/dev/null |
	 grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ' | sed 's/ $//')"
landing_engine="$(grep -ohE 'Engine:</strong> Godot [0-9]+\.[0-9]+\.[0-9]+' deploy/web/landing/index.html 2>/dev/null |
	grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
checks=$((checks + 1))
engine_bad="$(engine_claim_verdict "$ci_pin" "$landing_engine")"
if [ -n "$engine_bad" ]; then
	fail "$engine_bad"
else
	echo "[ok] landing e CI na mesma engine: $ci_pin"
fi

# Controles plantados da régua acima: os três ramos passam pelo mesmo predicado que
# julga o repo, e cada um morre se a régua virar no-op.
for par in 'ok|4.7.1|4.7.1' 'mude|4.7.1|4.7.2' 'mude|4.7.2|4.7.1' 'sem-pin||4.7.1' 'sem-landing|4.7.1|'; do
	espera="${par%%|*}"; resto="${par#*|}"; p1="${resto%%|*}"; p2="${resto##*|}"
	checks=$((checks + 1))
	got="$(engine_claim_verdict "$p1" "$p2")"
	if [ "$espera" = "ok" ] && [ -n "$got" ]; then
		fail "controle da régua de engine: pin=$p1 landing=$p2 foi acusado ($got) — a régua não aceita o estado que o repo tem hoje"
	elif [ "$espera" = "mude" ] && [ -z "$got" ]; then
		fail "controle da régua de engine: pin=$p1 landing=$p2 passou verde — desigualdade não é julgada"
	elif [ "$espera" = "sem-pin" ] && [ -z "$got" ]; then
		fail "controle da régua de engine: pin ausente passou verde — a régua dorme quando não lê o workflow"
	elif [ "$espera" = "sem-landing" ] && [ -z "$got" ]; then
		fail "controle da régua de engine: landing ausente passou verde — a régua dorme quando o HTML muda de formato"
	fi
done

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
#    nada para quem abre o arquivo no número citado), a faixa tem de SELAR o
#    construto que nomeia (se a linha seguinte à última citada começa com `elif`,
#    `else`, `}`, `,`..., a cadeia continua fora do span), e algum candidato aparece
#    no span citado => passa; nenhum => acusa com as linhas onde o nome realmente mora.
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
# O selo veio pela mesma porta e com o mesmo formato de mentira: `README.md:65` dizia
# que a faixa 176-199 de `sources/input/Action.gd` despacha os `ui_*` do projeto e
# enumerava F11
# na frase — F11 é `ui_fullscreen`, linha 200. Span com as duas bordas cheias, nome
# dentro, e a cadeia cortada um `elif` antes do fim. Medido antes de escrever: das 64
# faixas citadas nos docs vivos, essa era a única truncada; a variante por família de
# prefixo, também medida, acusava 6 spans honestos de `deploy/ROLLBACK.md` e não achava
# nada falso a mais. Por isso o critério é o token de continuação, não a semântica.
#
# Mordida antes de confiança: o self-test roda seus controles em memória (nada escrito
# em disco) nos DOIS cortes, e a seção só pode reportar zero acusações se TODOS os casos
# mordarem — a contagem é lida do próprio array, porque "doze" gravado aqui apodreceria
# no controle que alguém acrescentasse. Mentira acusada, verdade aprovada, ponteiro sem
# nome não julgado, nome
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
# (OPS_RUNBOOK.md:17 cobrando cloudflared na linha do resolver, por exemplo).
# Régua que precisa do autor do doc para decidir quem mente é ruído, e ruído em gate
# de doc é o que mata o gate. As três mentiras reais que o experimento achou
# (`SCALING.md` com faixa de mutex apontando para players, `STAGING.md` com
# `BindAddress`/`DefaultPort` dois linhas acima, `SQL.gd:1463` que é `UnmuteAccount`)
# foram corrigidas na mesma passada; o que ficou de fora é coberto pela convenção de
# nome ANTES do número, que é o formato em que toda a varredura abaixo acontece.
# ---------------------------------------------------------------------------
IDENT_MIN=120
# Piso da RESOLUÇÃO de nome, e ela existe porque a resolução É uma régua nova: aberto
# o índice por base de nome, o bash passou a ler os 87 ponteiros que citam o arquivo
# sem caminho, e eles devolveram 37 acusações que nenhum portão barato imprimia. Antes
# disso só o GDScript do harness resolvia — dois leitores da mesma árvore, um cego e um
# mudo, e a árvore se mostrava verde (#116). Sem piso, um walk que para de resolver
# devolve "0 acusações" julgando 180 nomes, e 180 passa no IDENT_MIN acima: o zero não
# prova nada, o 87 é que prova que a classe foi lida.
RESOL_MIN=87
# Régua de CONTINUAÇÃO (#124, fatia órfão). O braço nasceu nesta passada e foi
# rodado contra a árvore ANTES do conserto (be573ce): 33 `:NN` lidos — 22 ÓRFÃOS (numero
# sem arquivo na linha) e 11 herdando — e 24 acusações, porque além dos 22 órfãos dois
# herdando mentiam: em COOLIFY a faixa 111-120 de SQLBackups caia numa linha em branco,
# e em OPS_RUNBOOK o número 102 nomeava `lastDailyBackupTimestamp`, que mora em 92, 164
# e 166. O piso NÃO é 33, e a razão é a mesma que faz o braço existir: cobrar 33
# continuações seria cobrar que os 22 órfãos continuassem na árvore, porque a única
# forma de manter esse piso verde é não consertar os órfãos — piso que só fica verde com
# a doença presente é prêmio à doença. O censo daquela passada era 8 lidos, 8 julgados
# pelo arquivo herdado, 0 órfãos, 0 acusações, e foi esse o nível escrito: afrouxamento
# de população medida, não de métrica, com o mesmo predicado nos mesmos dois cortes. O
# que impede a volta do órfão não é o nível, é a acusação: `herdado is None` entra em
# `cont_accused`, que é somado às falhas do portão — órfão novo é vermelho na hora, e foi
# assim que os 22 saíram, não por edição a olho. O nível guardava só o walk mudo (0
# lidos com 8 na árvore é braço parado), e o que prova que o braço lê nunca foi ele: é o
# self-test mordendo os controles (dois deles exatamente o órfão e o off-by-one de
# grupo). Ver o bloco da 25b abaixo, que trocou o nível por cobertura.
#
# O 9 virou 8 na passada do gémeo (`tests/IdleTestsFrontier.gd`, braço (9)), e o que
# desceu é doença, não régua: um daqueles nove não era ponteiro nenhum, era a PORTA do
# Alertmanager escrita em forma de continuação — dois-pontos colado no número, dentro de
# backticks, logo depois de um ponteiro de linha do compose. O braço novo do harness
# herdou a porta para o arquivo do vizinho e a acusou de cair além da última linha; ESTA
# régua leu o mesmo token e não podia acusá-lo, porque o `verdict` daqui não tinha
# predicado de fim de arquivo: a fatia de faixa era cortada pelo comprimento do arquivo
# (`min(len(target_lines), ...)`) e o check de branco era condicionado a a borda estar
# dentro dele (`1 <= edge <= len(...)`), então número além da última linha fatiava vazio e
# devolvia "nada a acusar". A porta voltou a ser porta na prosa e o censo desceu um.
#
# O buraco foi fechado na passada seguinte, que é este `verdict` com o predicado `alem`.
# A auditoria que fecharia a dívida saiu junto: com o predicado ligado, ZERO dos 264
# ponteiros nomeados da árvore caía além do fim do alvo, e os oito de continuação
# também não — ou seja, o dano conhecido era o token da porta, e o que restou é o risco,
# que é o que um predicado cobra. Os quatro controles novos (três na régua de identidade
# e um no adaptador da continuação) nomeiam zero coisas do alvo de propósito, porque só
# assim eles provam o predicado em vez de passarem pela porta da régua de nome.
#
# O piso de NÍVEL que havia aqui (`CONT_MIN=8`) não existe mais, e a razão é a classe
# que ele acusava: ele não distinguia "o braço parou" de "um ponteiro foi consertado".
# Descrito na 25b, com o substituto (censo de COBERTURA, diferença e não nível) e com
# a anti-vacuidade do `cont_cases > 0`, que era o único buraco real que o nível tapava.
# Piso da régua de literal: o censo medido no run de 2026-10-01 é 59 ponteiros
# pinados (54 no run de 2026-09-28; não decomponho os cinco que se somaram — nenhuma
# régua desta fatia mediu a classe de literal, e número que sobe sem medição não entra
# aqui como entendimento). É pouco porque a régua só julga o literal que mora UMA vez no
# arquivo-alvo — duas ocorrências não pinham nada e o caso devolve "não julgado" — e a maioria das
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
# Ratchet da ÂNCORA (#124). Dois números, um só sentido de afrouxamento:
#  - ANCHOR_MIN é PISO de `arquivo:@simbolo`: só pode subir. Cair âncora significa
#    ou que a âncora voltou a ser linha (o custo que se quer matar), ou que o walk
#    parou de ler o arquivo — nos dois casos "zero acusações" é a régua muda. Os 19
#    da fatia 2 eram os 17 medidos mais dois que o registro daquela rodada ganhou ao
#    citar o braço pelo nome em vez de por linha; os 128 de agora são os 19 mais os
#    103 do automático e mais 6 que a marreta cobrou na própria rodada — escrever a
#    costura da âncora em `tests/IdleTestsFrontier.gd` (+62 linhas) empurrou de si nove
#    ponteiros que a doc fazia àquele arquivo. Seis viraram âncora; três foram para
#    prosa, porque a afirmação que eles carregavam ("== instância da zona 1") não é o
#    que uma âncora diz, e um deles já mentia no HEAD: a linha 2205 de
#    `IdleTestsFrontier.gd` é o comentário de `InventorySize`, não a instância.
#    Nenhum régua disse nada: o arquivo era citado pelo nome nu, a linha era cheia e a
#    cláusula não nomeava símbolo — é a classe que a fatia 4 tem de resolver, não esta.
#    Pagar em âncora exigiu reescrever a oração, porque a cláusula desta régua é a
#    ORAÇÃO (corta no último `,`/`;`/ponto-fora-de-backtick antes do ponteiro) e não a
#    janela de ±2 linhas da régua de identidade: `SuiteIdleLootPipeline` estava do lado
#    de lá da vírgula de `0,70`, e âncora sem nome na oração é decorativa. A vírgula
#    decimal é lida aqui como fronteira de oração, o que corta cláusula no meio de toda
#    prosa de número em português — achado registrado, não consertado de passagem.
#    Os 148 de agora são os 137 daquela costura mais 11, e os 11 não saíram de marreta:
#    saíram de matar a classe que nenhuma régua lia. O braço 29, rodado contra a árvore
#    do HEAD, acusou 22 números sem arquivo na linha, e onde havia símbolo declarável a
#    resposta foi âncora: cinco em `deploy/BACKUP_RUNBOOK.md`, um em `deploy/COOLIFY.md`
#    (a porta que estava escrita como `:NN` e portanto lida como linha), um em
#    `tests/d1_return_metric_test.gd`, um em `tests/economy_invariant_fuzz.gd` e dois em
#    `tests/marketplace_depth_test.gd` que cabem numa âncora só porque a frase passou a
#    nomear a função que declara o `out`. Isso fecha dez; o décimo primeiro veio de um
#    ponteiro que JÁ tinha arquivo em COOLIFY e valia menos que o nome da função que o
#    dispara. Dos doze órfãos que sobram, nenhum tem símbolo para ancorar: seis eram esta
#    régua citando a própria régua, dois eram exemplo de sintaxe no harness, e quatro são
#    o `pull_policy` do compose, onde âncora não cabe porque `DECLS` só conhece gd, py e
#    sh — a forma barata ali é nomear o arquivo UMA vez e deixar o `ANYCITE` ler as cinco
#    linhas, que é o que a enumeração de `deploy/ROLLBACK.md` faz.
#  - LINE_MAX é TETO de `arquivo:linha`: só pode descer. Subir é a marreta sendo
#    paga de novo, e foi exatamente assim que o custo apareceu: +132 linhas numa
#    rodada quebraram 21 ponteiros. A queda de 608 para 496 é a fatia 3 cobrando a
#    própria aposta: 103 ponteiros migrados para âncora numa passada só, cada um
#    escolhido porque o `anchorverdict` já devolvia verdadeiro para ele — a faixa
#    citada mora dentro de UM símbolo declarado, a cláusula nomeia esse símbolo, e
#    todo literal pinado já mora no bloco. Nenhum dos três é decisão de `sed`, e a
#    prova de que a frase não foi reescrita está no diff: nos 103 automáticos só o
#    token muda; os seis que a marreta cobrou nesta rodada pediram a oração
#    reescrita, porque o nome do símbolo caiu do outro lado da vírgula. Dois ponteiros
#    ficaram de fora do automático porque sobrava um dígito na prosa
#    (`SCALING.md §7`, `= 5 s`), e trocar o ponteiro deixando a frase soletar o
#    número velho é comprar a mentira nova; os dois eram falso positivo do guarda e
#    foram à mão. O que sobra não cabe em script: 163 faixas que moram dentro de um
#    símbolo que a cláusula não nomeia (`prosa`) e duas pinando literal fora do
#    bloco — 165 sentenças a reescrever, julgamento, não marreta.
# O censo desta passada foi escrito com uma disciplina a mais, e ela é medida, não
# prometida: `sources/idle/FarmZoneData.gd` foi re-fluxido para ficar com o MESMO
# número de linhas do HEAD (13 entradas, 13 saídas), porque cinco citações dele pelo
# nome, sem caminho, em quatro arquivos, apontavam para dentro; cada linha que eu
# acrescentasse lá era
# uma mentira entrando pela porta dos fundos — nenhuma régua a acusaria, porque o
# arquivo é citado sem caminho e a linha citada continua cheia. É o custo da marreta em
# cifra exata: uma frase sobre âncora custa dois minutos de re-fluxo enquanto o ponteiro
# for de linha.
# O censo de 2026-09-30 é a passada da resolução, e ela baixou o teto sem marreta:
# oito ponteiros viraram âncora (README dois, `architecture.md`, `debugging.md`,
# `testing.md`, `FarmZoneData.gd`, `drop_band_content_test.gd`, `fraud_test.gd`), e a
# prosa honesta cobrou quatro linhas de volta — a sonda do `AfkReport` precisou de uma
# para o declarante e uma para o leitor, porque os dois moram em arquivos diferentes e
# a frase antiga acusava o `AfkReport` de mentir sobre `OfflineSettle`; o id do addon
# ganhou a sua (`tiled_importer` mora na 30, não na 162); `set_default_obj_params`
# ganhou a sua pela mesma razão. O nono ponteiro convertido não tirou linha nenhuma: no
# `marketplace_depth_test.gd` a âncora nomeia a função e o ponteiro de faixa fica,
# porque apagar linha é afirmação sobre um ramo de `if`, e âncora não declara ramo. Os
# outros vinte e oito casos das 37 eram número errado pago no próprio ponteiro — a chave do
# i18n tinha escorregado uma linha, o bloco citado do compose era o de outro serviço, o
# `return` do painel era a linha de baixo, e a faixa do apagador parava antes do `elif`
# — ou a régua julgando a frase errada: o
# braço de identidade comia o prefixo bruto da linha enquanto o de literal cortava a
# oração, e dois juízes da MESMA promessa liam duas promessas. Agora os dois chamam
# `lit_clause` e os dois perdoam o nome do próprio arquivo; cada isenção entrou no
# self-test com o espelho que prova que não é manto, e os controles mordem 56/56.
# A passada do órfão baixou o teto em UM, e o número pequeno é a descoberta, não o
# barulho: o censo de linha nunca foi onde o custo morava. Dos 22 números sem arquivo,
# nenhum foi devolvido à linha certa — dez viraram âncora, quatro viraram um só
# ponteiro de enumeração, seis eram esta régua citando a si mesma e dois eram exemplo de
# sintaxe no harness. O que cai de vinte e dois para zero não é marreta paga, é classe
# que enfim tem juiz; régua nova se prova em acusação, não em ratchet de linha.
#
# Os quatro abaixo dos 490 saíram com o fim do `sources/sql/SQL.gd`: as duas seções de
# WorkOrder foram para `sources/sql/SQLGrants.gd` (o teto anti-god-node de lá estourou)
# e o ensaio que as prendia no fim do arquivo ia junto dizendo quais linhas a doc nomeia
# — quatro ponteiros que existiam para avisar quem edita, não para apontar evidência. O
# aviso verdadeiro sobrevive no texto novo, sem número. É a primeira vez que esta régua
# desce por causa de fatiamento de código, e é o que #124 promete: quando o ponteiro
# deixa de ser o que impede a mudança, ele some sozinho na mudança.
# Sobe outra vez em 2026-10-01 com as 12 trocas de linha por âncora que a régua já aceitava
# de graça (medido: dos 260 ponteiros de linha cobrados, só 12 tinham o símbolo declarado no
# alvo e nomeado na cláusula — o resto é prosa que precisa ser reescrita, não atalho). O que
# estas doze custaram de verdade não foi o número, foi a cláusula: seis foram recusadas por
# `prosa` até a frase levar o nome para o MESMO segmento de vírgula do ponteiro, que é a
# régua dizendo que âncora citada longe do que ela nomeia não é evidência de nada.
# A segunda colheita foi medida com a CLÁUSULA DA RÉGUA, não com o clipe bruto da linha, e
# a diferença é o achado: o clipe bruto apontava dezenove "nomes fora do segmento" que,
# julgados por `lit_clause` (com o puxamento da linha de cima, quando a oração morreu na
# quebra), não eram nada disso — o nome não estava na oração. Dos que sobraram, seis já
# nomeavam o bloco e esperavam. Custaram zero prosa: `:NN` virou `:@simbolo`, e o que a
# frase dizia continua sendo o que o bloco contém.
# A fatia do YAML cobra o preço que a de cima não cobrou, e é honesto escrevê-lo: dos 25
# ponteiros `.yml` sob a régua, dezesseis viraram âncora, e nenhum deles de graça. Uma
# chave de compose não tem nome próprio — `mem_limit: 1536M` mora em três serviços e a
# linha sozinha não diz qual — então o caminho `services.game.mem_limit` É a afirmação,
# e a cláusula tem de dizê-lo. Cada conversão custou uma oração reescrita, não uma
# marreta: a régua de `prosa` é que exigiu a frase, e é ela que impede a âncora de virar
# número disfarçado. Os nove que sobraram são posição de verdade (linha de comentário,
# item de lista `- alert:` repetido dez vezes, `--flag` de argv) e ficam de linha.
#
# A mordida da fatia, nos dois sentidos: um `#Shift` inserido na segunda linha do compose, que
# é exatamente o evento que a âncora existe para absorver. No HEAD a mutação acusou dez linhas
# citando o compose, de seis ponteiros distintos: dois `branco` (ROLLBACK e SCALING, ambos na
# linha 98 do arquivo), três de identidade (linhas 87, 123 e 129) e o `service_started` que
# `deploy/OPS_RUNBOOK.md` cita na linha 54. Nesta árvore a mesma mutação acusa duas linhas: o
# mesmo ponteiro do runbook, uma por corte. Os cinco que calaram são as conversões; o que
# continuou acusando ficou de linha de propósito — item de lista é valor sem chave, e o caminho
# da chave não o alcança. Isenção de cobrança não é silêncio da régua, e é isso que os dois
# números provam juntos.
#
# A frase acima foi reescrita três vezes porque a régua leu o próprio comentário: no rascunho,
# citar os números na forma de ponteiro custou quatro órfãos de continuação, uma identidade
# mentindo por `service_started` e o teto de ponteiros estourado em dois. É a tese desta
# fatia mordendo quem a documenta, e ela ficou registrada sem número colado ao arquivo — o
# que é, exatamente, o que #124 diz que um aviso deve fazer quando o número deixa de ser a
# evidência.
# Terceira colheita, 2026-10-01: `deploy/SCALING.md` saiu do ponteiro de linha. Dos catorze
# cobrados ali, treze viraram âncora e um ficou de linha por motivo MEDIDO: a regra de alerta
# do Prometheus é discriminada por VALOR (`- alert: QueryMutexTravando`), e o índice YAML julga
# CAMINHO de chave — `groups.rules.expr` mora catorze vezes no arquivo, então a régua responde
# `duplo`, que é a acusação certa: caminho repetido não escolhe nada. Pelo mesmo motivo os dois
# `Dockerfile` de monitoramento ficam na classe `sem modelo`: sem declaração legível, âncora não
# tem bloco, e fingir um bloco seria aprovar ponteiro que não prova nada.
# O achado dentro do achado: a doc apontava o throttle de 30 Hz para duas linhas de
# `sources/launcher/Launcher.gd` que caíram em cima de um comentário de `Reset()`, enquanto o
# `Engine.set_max_fps` de verdade mora em `_ready()`. Linha cheia, texto presente, julgamento
# nenhum — é exatamente a classe que a âncora fecha, e ela só apareceu porque converter obriga
# a abrir o alvo.
# Quarta colheita, na mesma tarde, e é a que responde pelo rate do #124: a frase duplicada é o
# ponteiro mais barato que existe. Dez harnesses carregam a MESMA sentença sobre o boot do
# catálogo, apontando a mesma linha do mesmo arquivo, e os dez viraram âncora com uma
# substituição só — custo de prosa zero por casa, porque a prosa foi escrita uma vez e copiada
# nove. O custo de marreta que o #124 caçava nunca foi o da régua por ponteiro: é o do censo
# repetir em dez arquivos uma frase que ninguém relia havia meses.
# Essa colheita cobrou conserto na GRAMÁTICA, não na frase. O puxamento de cláusula cortava a
# linha de cima pelo último ponteiro de LINHA dela; linha terminando em ÂNCORA não tinha corte
# nenhum, a cauda vinha inteira, e o literal que a âncora de cima já tinha julgado descia como
# se fosse promessa da âncora de baixo. Foram dez acusações de bloco por causa de sintaxe, num
# texto cujo sentido não mudou uma palavra — e é o tipo de mordida que faria alguém desistir de
# converter. Corrigido no puxamento, com dois controles novos: o do corte, e o espelho, que
# continua descendo e acusando quando a linha de cima não prometeu nada. Sem o espelho, o
# conserto seria indistinguível de manto.
# Quinta colheita, 2026-10-01, e é a que mostra o rate do lado do DOCUMENTO: sete itens da
# mesma lista de famílias do `/metrics`, em `deploy/ROLLBACK.md`, apontavam sete faixas dentro
# de `MetricsBody()` — corpo que a mudança do orçamento de passo acabou de editar, e cada `# HELP`
# escrito acima da 190 move as sete faixas de uma vez. Viraram a MESMA âncora repetida oito
# vezes. A régua também cobrou o preço de converter com pressa: `deploy/STAGING.md` deu
# acusação de `bloco` porque a frase pin-ava `MetricsServer`, nome que mora na classe e fora do
# bloco da constante, e o conserto foi um ponto no lugar do travessão — prova de que a mordida
# julga a promessa, não o caminho percorrido.
ANCHOR_MIN=234
LINE_MAX=407
# O piso do RECORTE, medido nesta árvore em 2026-10-01: quinze âncoras moram dentro dos
# registros datados. É prova de posição, não de censo: com o atalho de `SKIP_NAMES` subido
# para cima do laço de âncora, o total cai de 215 para 200 e o `ANCHOR_MIN` acima acusa —
# mas acusa "faltam âncoras", sem dizer qual recorte parou de ser lido. Contada no local da
# cobrança, a mesma mutação zera ESTE número, e aí a frase passa a nomear a classe.
ANCHOR_FORA_MIN=15
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
EXTS = (".md", ".gd", ".py", ".sh", ".mjs", ".yml", ".yaml", ".conf", ".html", ".json")
# Registros datados: prose de quando o numero era outro. Cobrar deles a verdade de
# hoje seria reescrever historico.
SKIP_NAMES = {"CHANGELOG.md", "progress.md", "ROADMAP_COMERCIAL.md", "BLIND_JUDGE_PROTOCOL.md"}

# O alvo de um ponteiro: `caminho.ext:NN`. A segunda alternativa existe porque
# `Dockerfile` não tem ponto: o primeiro ramo exige extensão, e sem ela nem
# `deploy/server/Dockerfile` seguido de número seria lido. Medido no HEAD varrido, as
# citações reais vêm todas com caminho (`deploy/server/`, `deploy/web/`,
# `deploy/companion/`); a forma nua só aparece em `archive/`, que o walk não lê.
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

# A ÂNCORA (#124): `arquivo.ext:@símbolo` no lugar de `arquivo.ext:NN`. O que faz a
# régua morder nunca foi o número — é ler o CONTEÚDO daquele endereço — e o número é
# o que cobra marreta: +132 linhas numa rodada quebraram 21 ponteiros e o conf do
# nginx exigiu 9 reparos. Uma âncora sobrevive a inserção em qualquer ponto do
# arquivo sem perder julgamento, porque o que se julga é o BLOCO do símbolo: (1) o
# símbolo é declarado naquele arquivo, uma declaração só — duas são acusação, não
# escolha; (2) o que a prosa pin-a aparece dentro do bloco. O literal viaja junto,
# senão a âncora vira "o nome existe", e isso não prova nada.
# Em mapa YAML o símbolo é o CAMINHO pontilhado (`services.web.mem_limit`), e só
# a forma pontilhada resolve: o segmento final sozinho mora em dois serviços do
# mesmo compose. Os pontos entram no capturado, não no `_TGT` — o delimitador de
# alvo continua sendo o `:`, e um `@a.b` sem ponto capturado seria `@a` seguido de
# lixo, que é como uma âncora YAML viraria âncora `.gd` por acidente.
ANCHOR = re.compile(r"(?<![\w./-])" + _TGT + r":@([A-Za-z_]\w*(?:\.[A-Za-z0-9_-]+)*)")

# A CONTINUACAO de ponteiro: `:NN` ou `:NN-MM` sem arquivo, herdando o alvo do
# ponteiro anterior. Nem `PTR` nem `ANYCITE` nem `ANCHOR` a veem, porque as tres
# exigem o `arquivo.ext` antes do dois-pontos — entao a classe inteira era ilegivel
# para o portao barato. Censo medido por este braço na arvore do HEAD (be573ce): 33
# continuacoes fora dos registros datados, 22 delas sem antecedente nenhum na linha e
# 11 herdando o alvo, e 24 acusacoes — os 22 orfaos mais dois herdando que mentiam.
# O nome e CONTPTR
# porque `CONT` ja e o regex de token-de-continuacao da régua de faixa, e os dois
# significam coisas opostas.
CONTPTR = re.compile(r"`:(\d+)(?:-(\d+))?`")

# O ponteiro com VIRGULA: `` `arquivo:12,34` ``, ou com intervalos misturados
# (`` `arquivo:12-15,34` ``). Ele nao e um ponteiro para `PTR`, que exige o backtick
# colado no ultimo digito — e por isso mesma frase que promete quatro sitios saia do
# walk sem que nenhuma linha dela fosse conferida. Medido no corpus vivo (fora dos
# registros datados e fora de `archive/`): nove citacoes assim, todas em arquivo que
# existe, e nenhum dos numeros julgado. E a forma mais barata de ponteiro que existe
# — quem escreve uma lista nao pode ser obrigado a abrir cinco backticks para ser
# lido —, entao fecha-se a porta em vez de proibir a forma.
#
# O que se cobra de cada numero e o que a frase afirma e independe da prosa: o sitio
# existe e tem linha. A clausula nao entra: uma frase fazendo quatro afirmacoes sobre
# quatro linhas nao e decomponivel pelo parser de oracao, e inventar um recorte para
# ela seria pior que nao medir nada — daria veredito de uma linha para a promessa de
# outra. Quem quer que a frase seja conferida escreve ponteiros separados, e ai o
# `verdict` de identidade ja os ve.
LISTPTR = re.compile(r"`" + _TGT + r":((?:\d+(?:-\d+)?)(?:,\d+(?:-\d+)?)+)`")
LISTITEM = re.compile(r"^(\d+)(?:-(\d+))?$")


def listitems(raw):
    """Os numeros de uma lista `12,13-15` como pares (de, ate).

    Separado do laço porque as duas metades da régua — o veredito e o censo que cerca
    o veredito — têm de ler a mesma string do mesmo jeito, e uma `split` escrita duas
    vezes é onde as duas começam a discordar em silêncio. A recusa do que não é numero
    esta aqui de proposito: `LISTPTR` ja garante a forma, entao o ramo so e alcancavel
    pela mesa de controles, e e ela que prova que a promessa da regex e a promessa da
    parser.
    """
    out = []
    for part in raw.split(","):
        m = LISTITEM.match(part)
        if m is None:
            continue
        de = int(m.group(1))
        ate = int(m.group(2)) if m.group(2) else de
        out.append((de, ate))
    return out


def listitem_verdict(de, ate, linhas):
    """O veredito de um numero `de-ate` de uma lista, ou None se a linha abre.

    Puro de proposito, pelo mesmo motivo do `deadjudge`: as duas bordas vem do mesmo
    cano que cobra o `arquivo:NN-NN` simples, o meio do intervalo nao e cobrado porque o
    ponteiro simples tambem nao cobra, e uma mesa de controles nao pode nascer de um
    laço que percorre a arvore. Devolver string-motivo em vez de print deixa o `scan`
    escolher a frase da acusacao sem escolher a regra.
    """
    if de < 1 or ate < de or ate > len(linhas):
        return "borda"
    if linhas[de - 1].strip() == "":
        return "branco"
    return None


class Herdado:
    """Um `:NN` julgado como ponteiro: a interface de `PTR`, com o arquivo emprestado.

    `PTR` e `CONT` tem grupos em posicoes diferentes (o arquivo desloca os numeros em
    uma casa), entao o adaptador e o que deixa o `verdict` julgar os dois sem saber
    qual dele veio de onde.
    """

    def __init__(self, m, arquivo):
        self._m = m
        self._arquivo = arquivo

    def group(self, i):
        if i == 1:
            return self._arquivo
        if i == 2:
            return self._m.group(1)
        if i == 3:
            return self._m.group(2)
        return self._m.group(0)

    def start(self):
        return self._m.start()

    def end(self):
        return self._m.end()


def herancas(line):
    """[(match do `:NN`, arquivo herdado ou None)] para cada continuacao da linha.

    Heranca e do ultimo `arquivo:NN` ou `arquivo:@simbolo` ANTERIOR NA MESMA LINHA, e
    so ai. Nada de linha anterior: a promessa de um `:NN` e lida por quem esta com o
    olho na frase, e uma regla que herda de cima passaria a depender de onde a frase
    quebrou no arquivo — o mesmo defeito de juiz que le a linha errada que o #116
    registrou. Sem antecedente, `None`: o opto e acusar, nao adivinhar.
    """
    saida = []
    ultimo = None
    eventos = []
    for rx, tipo in ((PTR, "p"), (ANCHOR, "a"), (CONTPTR, "c")):
        for m in rx.finditer(line):
            eventos.append((m.start(), tipo, m))
    for _pos, tipo, m in sorted(eventos, key=lambda t: t[0]):
        if tipo == "c":
            saida.append((m, ultimo))
        else:
            ultimo = m.group(1)
    return saida


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

    O "último ponteiro" é das DUAS formas. Medido na primeira árvore onde uma linha
    passou a terminar em âncora (`tests/ops_fix_test.gd` e os outros nove harnesses
    que citam `DB.gd`): cortando só por `ANYCITE`, a linha sem `:NN` não tinha corte,
    a cauda era o linha inteira e o literal que a ÂNCORA de cima já tinha julgado
    descia como promessa da âncora de baixo — dez acusações `bloco` honestas por
    sintaxe, de um texto que não mudou de sentido em nada. Âncora é citação, e o que
    ela prometeu já foi cobrado por ela.
    """
    if bt and seg.endswith("`"):
        seg = seg[:-1]
    if first and prev is not None and "`" not in seg and "`" in prev:
        pm = None
        for rx in (ANYCITE, ANCHOR):
            for pm2 in rx.finditer(prev):
                if pm is None or pm2.start() > pm.start():
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


# Token de continuação: linha que começa assim é linha que PERTENCE ao construto
# aberto antes dela — `elif`, `else`, `}`, `,`, `||`... Não é lista de palavras de
# doc, é lista de palavras da GRAMÁTICA dos nove arquivos que o portão lê (gd, py,
# sh, conf, yml, json, md, html, mjs). Por isso julga faixa sem julgar prosa.
CONT = re.compile(r"^(elif\b|else\b|,|\||&&|\|\||::|default:|- *default:)")


def sealed(target_lines, a, b):
    """(selada, linha_acusada): a faixa `a-b` termina onde o construto termina?

    Foi a classe que sobrou depois da régua de nome e da de borda em branco: um
    intervalo válido, com as duas bordas cheias e o nome dentro, que corta a cadeia
    no meio. Medido em 2026-09-29 antes de escrever — das 64 faixas citadas nos docs
    vivos, uma única mentia assim, e era o `README.md:65` dizendo que a faixa
    176-199 de `Action.gd` despacha os `ui_*` quando a linha 200 é
    `elif ... "ui_fullscreen"`, o F11 que a própria frase enumera. A variante de
    família de prefixo foi medida e rejeitada: acusava 6 spans honestos de
    `deploy/ROLLBACK.md` (cada métrica cita o próprio bloco HELP/TYPE/valor dentro de
    uma sequência de irmãos) e deixava de fora nada de falso — régua que precisa do
    autor para decidir quem mente é a ruído que esta casa já enterrou uma vez.

    O lado de início não entrou: medido, zero acusações nos docs vivos, e régua sem
    caso medido é régua que ninguém sabe se morde.
    """
    nxt = ""
    for k in range(b, min(b + 3, len(target_lines))):
        if target_lines[k].strip():
            nxt = target_lines[k].strip()
            break
    if CONT.match(nxt):
        return False, b + 1
    return True, None


def verdict(clause, ptr, target_lines, wide, stem=None):
    """(ok, candidatos, onde_mora, motivo). `clause` e o texto da oração ANTES deste ponteiro.

    `stem` é o nome do arquivo-alvo sem extensão, e um candidato igual a ele é
    descartado antes de qualquer julgamento — pela mesma razão declarada na régua de
    literal ("homonímia"): nomear o próprio arquivo é dizer como a coisa se chama, não
    onde ela mora. As duas réguas da mesma frase liam doutro modo, e `SkillTrainer.gd`
    citando `NpcScript.gd:353` para falar da classe `NpcScript` era acusado pela de
    nome enquanto a de literal o perdoava: dois juízes, uma promessa (#116).
    """
    a, b = int(ptr.group(2)), ptr.group(3)
    last = int(b) if b else a
    # Fim de arquivo: um número além da última linha não é borda de nada, é a citação de
    # um texto que não existe. Este predicado NÃO existia aqui desde que a régua existe,
    # e é por isso que o mesmo token passava verde deste lado e vermelho do outro: a
    # fatia é cortada por `min(len(target_lines), ...)`, então além-do-fim fatia vazio, e
    # o check de branco é condicionado a `1 <= edge <= len(...)`, então nem olha. O
    # vazio não promete nome nenhum, e sem nome a oração sai pela porta do "é só prosa".
    # O gémeo GDScript (`_ContStruct`, braço (9) de `SuiteEvidencePointers`) tem o
    # predicado desde a origem e foi ele que achou o primeiro caso.
    for edge in (a, last):
        if edge > len(target_lines):
            return False, [], [edge], "alem"
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
    # A faixa tem de selar o construto que nomeia (ver `sealed` acima). Só julga
    # faixa: `arquivo:NN` solto não promete fim de nada.
    if b:
        tight, cut = sealed(target_lines, a, int(b))
        if not tight:
            return False, [], [cut], "faixa"
    span = "\n".join(target_lines[max(0, a - 1):min(len(target_lines), int(b) if b else a)])
    joined = "\n".join(target_lines)
    # Nome de arquivo citado pelo nome: perdoa a linha exata se o nome mora no mesmo
    # quinhão delimitado por linha em branco (citar o bloco é prosa honesta) ou a uma
    # linha de vizinhança; fora disso, a âncora deslizou para um texto cheio de outra
    # coisa — a classe que a régua de literal não vê porque o nome multiplicado não
    # pinha uma linha só.
    dots = [c for c in dotcands(clause) if mentions(c, joined)
            and (stem is None or os.path.splitext(c)[0] != stem)]
    if dots and not any(mentions(c, span) for c in dots):
        lo, hi = lit_chunk(target_lines, a, last)
        neighborhood = "\n".join(target_lines[max(0, a - 2):min(len(target_lines), last + 1)])
        chunk = "\n".join(target_lines[max(0, lo - 1):min(len(target_lines), hi)])
        if not any(mentions(c, neighborhood) or mentions(c, chunk) for c in dots):
            first = dots[0]
            where = [i + 1 for i, t in enumerate(target_lines) if mentions(first, t)][:4]
            return False, dots, where, "arquivo"
    cands = [c for c in candidates(clause, wide) if mentions(c, joined)
             and (stem is None or c != stem)]
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


# ---------------------------------------------------------------------------
# ÂNCORA (#124): o modelo de declaração abaixo é o MESMO da régua de span do
# harness (`_SymbolSpans` em `tests/IdleTestsFrontier.gd`): coluna zero, e o bloco
# vai da declaração até a linha antes da próxima declaração de coluna zero. Duas
# réguas lendo duas geografias diferentes do mesmo arquivo é o jeito de um ponteiro
# ser aprovado por uma e acusado pela outra, e é por isso que o formato é copiado da
# que já estava certa, não inventado aqui.
DECL_GD = re.compile(r"^(?:static func |func |static var |const |class_name |enum |var )([A-Za-z_]\w*)")
DECL_PY = re.compile(r"^(?:async def |def |class )([A-Za-z_]\w*)")
DECL_SH = re.compile(r"^([A-Za-z_]\w*)\s*\(\)")
DECL_UP = re.compile(r"^([A-Z][A-Z0-9_]*)\s*=")
DECLS = {"gd": (DECL_GD,), "py": (DECL_PY, DECL_UP), "sh": (DECL_SH, DECL_UP)}

# YAML (#124, fatia 6): num mapa, declarar é escrever CHAVE, e o bloco é a SUBÁRVORE.
# O índice é o caminho pontilhado, e a forma pontilhada é a única julgável: `mem_limit`
# sozinho mora em dois serviços do mesmo compose, então âncora que não diz de quem é a
# chave não é escolha — é o `duplo` com a crase caída. O nível é a COLUNA DA CHAVE, não
# a do traço: em `- name: game` seguido de `  image: x`, os dois têm a chave na mesma
# coluna e são irmãos; contar o espaço antes do traço faria `image` filho de `name`,
# que é exatamente a geografia diferente que o #116 proíbe entre os dois juízes. Raiz
# de um segmento (`services`, `jobs`, `on`) não entra no índice: é seção, não
# declaração, e aprová-la daria à doc uma âncora que julga o arquivo inteiro com uma
# palavra — o `@services` que aprovaria qualquer linha do compose. E bloco escalar
# (`run: |`) é opaco: o que mora dentro é script, não par do mapa, e indexar o
# `foo: bar` de um `|` seria dar âncora a um texto que o próprio YAML não lê como chave.
KEY_YAML = re.compile(r"^( *)(?:- +)?([A-Za-z_][A-Za-z0-9_-]*):(?=\s|$)(.*)$")
ESCALA = re.compile(r"^\s*[|>]")
YAML_EXT = ("yml", "yaml")


def yaml_spans(lines):
    pilha, decls = [], []
    for i, raw in enumerate(lines, 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = KEY_YAML.match(raw)
        if not m:
            continue
        col, key = m.start(2), m.group(2)
        while pilha and pilha[-1][0] >= col:
            pilha.pop()
        if pilha and pilha[-1][2]:
            # O pai é bloco escalar (`run: |`, `command: >`): o que vem dentro é
            # SCRIPT, não par do mapa. Indexar o `foo: bar` de dentro de um `|` daria
            # à doc uma âncora para um texto que o próprio YAML não lê como chave.
            continue
        decls.append((".".join([s[1] for s in pilha] + [key]), i, col))
        pilha.append((col, key, ESCALA.match(m.group(3) or "") is not None))
    out = {}
    for k, (path, start, col) in enumerate(decls):
        if "." not in path:
            continue
        fim = len(lines)
        for j in range(k + 1, len(decls)):
            if decls[j][2] <= col:
                fim = decls[j][1] - 1
                break
        out.setdefault(path, []).append([start, max(start, fim)])
    return out


def anchor_ext(path):
    return os.path.splitext(path)[1].lstrip(".").lower()


# A acusação em português, com o `%s` do detalhe. Separado do veredito para o
# self-test julgar o MOTIVO, não a frase: uma régua que acusa certo mas por um
# motivo que ninguém plantou é a mesma que um dia absolve por engano.
ANCHOR_MOTIVOS = {
    "arquivo": "o alvo é `.%s`, onde nenhuma declaração é legível — âncora só existe onde a casa sabe onde começa e termina o bloco",
    "inexistente": "`%s` não é declarado neste arquivo — âncora para nome que ninguém declara é linha disfarçada",
    "duplo": "declarações em %s — duas é acusação, não escolha",
    "prosa": "nada na cláusula nomeia `%s` — a âncora só prova que o nome existe, e isso não é evidência",
    "bloco": "%s mora no arquivo, mas fora do bloco do símbolo — a prosa pin-a outra coisa",
}


def anchor_spans(lines, ext):
    """nome -> lista de [comeco, fim]. LISTA, não par: duplicidade é a acusação.

    Devolve {} para extensão sem modelo de declaração (`.md`, `.json`, `.conf`,
    `.tscn`). Ali a âncora não tem o que julgar, e fingir que tem é o caminho para
   aprovar ponteiro que não prova nada — por isso o veredito acusa em vez de calar.
    """
    if ext in YAML_EXT:
        return yaml_spans(lines)
    pats = DECLS.get(ext)
    if not pats:
        return {}
    decls = []
    for i, t in enumerate(lines, 1):
        for p in pats:
            m = p.match(t)
            if m:
                decls.append((m.group(1), i))
                break
    out = {}
    for k, (nm, start) in enumerate(decls):
        finish = decls[k + 1][1] - 1 if k + 1 < len(decls) else len(lines)
        out.setdefault(nm, []).append([start, max(start, finish)])
    return out


def anchorverdict(sym, clause, target_lines, ext):
    """(ok, motivo, detalhe) de `arquivo:@símbolo`.

    Quatro acusações, cada uma com controle plantado: arquivo onde nenhuma
    declaração é legível, símbolo que ninguém declara, símbolo declarado duas vezes,
    âncora cujo par não aparece na prosa (o "o nome existe" que não prova nada), e o
    literal da cláusula morando FORA do bloco. Aprovar exige os dois juntos: o nome
    dito na frase E o que a frase pin-a dentro do bloco.
    """
    if ext not in DECLS and ext not in YAML_EXT:
        # O ponto é da frase: devolver ponto mais extensão imprimia dois pontos,
        # e o self-test julga justamente o motivo impresso.
        return False, "arquivo", ext
    spans = anchor_spans(target_lines, ext)
    if sym not in spans:
        return False, "inexistente", sym
    if len(spans[sym]) > 1:
        return False, "duplo", [str(s[0]) for s in spans[sym]]
    if not mentions(sym, clause):
        return False, "prosa", sym
    joined = "\n".join(target_lines)
    a, b = spans[sym][0]
    block = "\n".join(target_lines[a - 1:b])
    fora = [c for c in candidates(clause, False) if mentions(c, joined) and not mentions(c, block)]
    if fora:
        return False, "bloco", ", ".join(fora)
    return True, "", ""


# ---------------------------------------------------------------------------
# WORKLIST (#124, o custo de marreta). `DRIFT_WORKLIST=1` faz o MESMO walk que
# cobra os ponteiros devolver, para cada `arquivo:NN` cobrado, o `@simbolo` cujo
# bloco contém a linha citada e a classe do trabalho que falta para converter.
# Não é régua: não muda veredito, censo nem saída do portão — é ferramenta de
# mão, lida por humano. O que ela tira da conversão é a procura (abrir o alvo,
# caçar a declaração, conferir se a frase já nomeia o nome) e deixa só a frase,
# que é o custo real registrado no #124: das `prosa` nenhuma sai de graça, mas
# todas saem de uma linha lida em vez de dois arquivos abertos.
#
# A classe é decidida pelos mesmos `anchor_spans`, `mentions` e `lit_clause` da
# régua, e é por isso que o worklist mora neste arquivo e não num script próprio:
# um conversor com modelo segundo seria o segundo leitor lendo outra geografia do
# mesmo alvo (#116), prometendo âncora que o portão acusa.
#
# O self-test da ferramenta é o invariante, cobrado em `main()`: a soma das
# classes é o censo de ponteiros julgados do corte narrow mais os alvos mortos.
# Laço que para de registrar um ponteiro é lista menor que a árvore, e lista
# menor que a árvore é exatamente o modo de mentir desta ferramenta — ela não
# acusa nada, só deixa de dizer.
# ---------------------------------------------------------------------------
WL_ON = os.environ.get("DRIFT_WORKLIST") == "1"
WL_ROWS = []
WL_TOT = {}
WL_SPANS = {}
WL_CLASSES = ("gratis", "prosa", "fora", "sem modelo", "morto")


def wl_inner(spans, lnum):
    """O bloco MAIS INTERNO cobrindo a linha citada.

    `func` morando dentro de `class` são dois vãoes sobre a mesma linha, e o que
    a frase pin-a é o método: o menor vão é a única âncora que a régua aprova
    sem reescrever a promessa. Empate de tamanho é desempate por nome, para a
    lista ser determinística entre duas passadas.
    """
    donos = sorted((b - a, nm) for nm, v in spans.items() for (a, b) in v
                   if a <= lnum <= b)
    return donos[0][1] if donos else ""


def wl_add(classe, site, alvo, cand, clause):
    WL_TOT[classe] = WL_TOT.get(classe, 0) + 1
    WL_ROWS.append((classe, site, alvo, cand, (clause or "")[:88].strip()))


def wl_judge(site, target, lnum, tl, clause):
    """Um ponteiro de linha, a classe e o candidato — sem julgar nada."""
    if tl is None:
        wl_add("morto", site, target + ":" + lnum, "", clause)
        return
    ext = anchor_ext(target)
    if ext not in DECLS and ext not in YAML_EXT:
        wl_add("sem modelo", site, target + ":" + lnum, "", clause)
        return
    if target not in WL_SPANS:
        WL_SPANS[target] = anchor_spans(tl, ext)
    try:
        primeiro = int(lnum.split("-")[0])
    except ValueError:
        primeiro = 0
    cand = wl_inner(WL_SPANS[target], primeiro)
    if not cand:
        wl_add("fora", site, target + ":" + lnum, "", clause)
    elif mentions(cand, clause):
        wl_add("gratis", site, target + ":" + lnum, cand, clause)
    else:
        wl_add("prosa", site, target + ":" + lnum, cand, clause)


# ALVO5 é o terreno da ÂNCORA: `GATE_RUN` declarado na 2, `Beta` uma vez só na 4 (e a
# linha 6, indentada, não é declaração de coluna zero — é corpo do `Beta`), `WAL_SALT`
# dentro do bloco, `Delta_Load` no bloco seguinte, e `Gamma` que não existe no arquivo.
# ALVO6 é o arquivo onde o mesmo nome é declarado duas vezes: ali a âncora é acusação,
# não escolha.
ALVO5 = ["# cabecalho", "const GATE_RUN : int = 1", "", "func Beta() -> void:",
         "\tvar WAL_SALT = 1", "\tconst Beta = 1", "func Delta_Load() -> void:",
         "\tBeta.run()"]
ALVO6 = ["func Beta() -> void:", "\tpass", "func Beta() -> int:", "\treturn 1"]
# ALVO7/8/9 são o terreno do YAML: `services.web.image` declarado uma vez, o MESMO
# caminho `ports.target` nascendo de dois itens de lista (duplo), raiz de um segmento
# fora do índice, item de lista IRMÃO e não filho, bloco escalar opaco, e o literal
# `health_check` morando num caminho diferente do nomeado.
ALVO7 = ["services:", "  web:", "    image: nginx", "    ports:",
         "      - target: 80", "      - target: 443",
         "  db:", "    run: |", "      checks: pass"]
ALVO8 = ["jobs:", "  build:", "    steps:", "      - name: sobe", "        run: make"]
ALVO9 = ["services:", "  web:", "    health_check:", "      retention: 7d", "    mem_limit: 512M"]
ANCHOR_CONTROLES = [
    ("âncora honesta: símbolo declarado e nomeado na cláusula",
     "abre a sessão em `Beta` (`x.gd:@Beta`)", True, ""),
    ("âncora pinando literal que mora dentro do bloco é aprovada",
     "a sonda `WAL_SALT` mora em `Beta` (`x.gd:@Beta`)", True, ""),
    ("inexistente: símbolo que nenhuma linha declara é acusado",
     "bate em `Gamma` (`x.gd:@Gamma`)", False, "inexistente"),
    ("duplo: o mesmo nome declarado duas vezes não é escolha de âncora",
     "bate em `Beta` (`x.gd:@Beta`)", False, "duplo", ALVO6),
    ("prosa: âncora sem o símbolo na frase só prova que o nome existe",
     "o número está aqui (`x.gd:@Beta`)", False, "prosa"),
    ("bloco: literal pinado que mora em outro símbolo é acusado",
     "a constante `GATE_RUN` mora em `Beta` (`x.gd:@Beta`)", False, "bloco"),
    ("bloco: o irmão declarado depois não entra no bloco do nomeado",
     "usa `Delta_Load` junto de `Beta` (`x.gd:@Beta`)", False, "bloco"),
    ("arquivo: extensão sem declaração legível não ganha âncora",
     "bate em `Beta` (`x.md:@Beta`)", False, "arquivo"),
    # Os sete de baixo são o YAML: o índice é o caminho, e cada um planta um modo de
    # o caminho mentir. Sem estes, "182 âncoras, 0 acusações" poderia significar que a
    # régua aceitou `@services` como âncora do arquivo inteiro.
    ("yaml: caminho de folha declarado uma vez é âncora legível",
     "a imagem do `web` é `services.web.image` (`x.yml:@services.web.image`)", True, "", ALVO7),
    ("yaml: raiz de um segmento é seção, não declaração",
     "o mapa inteiro vive em `services` (`x.yml:@services`)", False, "inexistente", ALVO7),
    ("yaml: o mesmo caminho nascendo de dois itens de lista é duplo",
     "a porta publicada é `services.web.ports.target` (`x.yml:@services.web.ports.target`)",
     False, "duplo", ALVO7),
    ("yaml: item de lista é IRMÃO do nome do item, não filho",
     "o script do step é `jobs.build.steps.run` (`x.yml:@jobs.build.steps.run`)", True, "", ALVO8),
    ("yaml: a nesting que o traço mal contado inventaria não está no arquivo",
     "corre em `jobs.build.steps.name.run` (`x.yml:@jobs.build.steps.name.run`)",
     False, "inexistente", ALVO8),
    ("yaml: bloco escalar é opaco — o que mora num `run: |` não é chave",
     "o script faz `checks: pass` em `services.db.run.checks` (`x.yml:@services.db.run.checks`)",
     False, "inexistente", ALVO7),
    ("yaml: literal nomeado que mora em outro caminho é acusado",
     "a `health_check` é de `services.web.mem_limit` (`x.yml:@services.web.mem_limit`)",
     False, "bloco", ALVO9),
    # Os dois de baixo são o puxamento de cláusula na presença de ÂNCORA, classe que
    # só nasceu quando uma linha passou a terminar em `:@símbolo`. O primeiro é a
    # correção; o segundo é o espelho, e sem ele o corte novo seria manto: puxar
    # continua trazendo o literal de cima quando a linha de cima não prometeu nada.
    ("continuação: âncora no fim da linha de cima é citação, e o literal dela não desce",
     "\t# (`x.gd:@Delta_Load`) fecha o preload", True, "", ALVO5,
     "\t# empilha os `GATE_RUN` de `Beta` (`x.gd:@Beta`) e o `Delta_Load()`"),
    ("continuação sem citação na linha de cima desce mesmo: literal fora do bloco é acusado",
     "\t# (`x.gd:@Delta_Load`) fecha o preload", False, "bloco", ALVO5,
     "\t# usa `Delta_Load()` e a constante `GATE_RUN`"),
]


def anchorselftest():
    biting = 0
    for label, text, esp_ok, esp_mot, *fix in ANCHOR_CONTROLES:
        alvo = fix[0] if fix else ALVO5
        prev = fix[1] if len(fix) > 1 else None
        m = ANCHOR.search(text)
        clause = lit_clause(prev, text[:m.start()], True,
                            text[m.end():m.end() + 1] == "`")
        ok, motivo, _det = anchorverdict(m.group(2), clause, alvo,
                                         anchor_ext(m.group(1)))
        if ok == esp_ok and motivo == esp_mot:
            biting += 1
        else:
            print("[FAIL] âncora: self-test cego no controle %s (ok=%s motivo=%r, esperava ok=%s motivo=%r)"
                  % (label, ok, motivo, esp_ok, esp_mot))
    return biting, len(ANCHOR_CONTROLES)



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
# ALVO4 é o terreno da régua de SELO de faixa, no formato do caso real
# (`sources/input/Action.gd:176-200`, um `elif` por linha): a cadeia vai da 2 à 5 e a
# 6 em branco existe para que o controle selado olhe a 7 (`pass`, não continuação) em
# vez de parar na borda vazia. Cortar em 3 ou 4 deixa o `elif` seguinte do lado de
# fora — é a mentira que a régua de nome aprova porque o símbolo está no span.
ALVO4 = ["# cabecalho", "func Beta() -> void:",
         "\tif TryJustPressed(\"ui_close\"):\tClose()",
         "\telif TryJustPressed(\"ui_menu\"):\tMenu()",
         "\telif TryJustPressed(\"ui_full\"):\tFull()", "", "pass"]
# ALVO3 é o terreno da régua de NOME DE ARQUIVO: `check_alpha.sh` mora em dois blocos
# separados por linha em branco (2 e 4), `check_beta.sh` só no segundo (5). Linha 8 em
# branco é o que fecha o quinhão de cima — sem ela o bloco 4..9 seria um só e o
# controle que cobra a âncora deslizada deixaria de discriminar nada.
ALVO3 = ["# cabecalho", "\tgate_sh a.log scripts/check_alpha.sh", "",
         "\t# o mesmo check_alpha.sh e citado adentro",
         "\tgate_sh b.log scripts/check_beta.sh", "\tgate_sh c.log nada", "}", "",
         "echo pronto"]
# ALVO7 é o terreno da HOMONÍMIA na régua de nome: a classe tem o nome do arquivo
# (`npc_script`, na 2) e o ponteiro aponta para a 4, a função. Isentado o nome-próprio,
# o outro nome da oração (`WAL_SALT`, na 5) tem de continuar sendo cobrado — é o espelho
# que prova que a isenção não virou manto.
ALVO7 = ["# cabecalho", "class_name npc_script", "", "func Load() -> void:",
         "\tWAL_SALT.run()"]
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
    # Além do fim do arquivo: os três abaixo nomeiam ZERO coisas do alvo de propósito.
    # Nomeando algo, a régua de identidade já acusaria pela porta do "o nome mora em
    # outra linha" e o controle passaria sem provar o predicado novo — é o mesmo
    # raciocínio do controle de branco acima, que também abre mão de nome.
    ("alem: a última linha do alvo é uma linha de verdade",
     "ver `x.gd:9` para o numero", True, True, ALVO2),
    ("alem: além da última linha não há o que abrir, e isso é acusação",
     "ver `x.gd:10` para o numero", False, False, ALVO2),
    ("alem: é a segunda borda da faixa que cai fora",
     "ver `x.gd:8-10` para o numero", False, False, ALVO2),
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
    # Selo de faixa: o caso que a régua de nome aprova e a leitura desmente. Os três
    # primeiros têm `Beta` no span — se caíem, é o selo que morde, não o nome.
    ("faixa: cadeia selada — a última linha citada é a última do construto",
     "roda em `Beta` (`x.gd:2-5`)", True, True, ALVO4),
    ("faixa: corta a cadeia antes do `elif` final e é acusado",
     "roda em `Beta` (`x.gd:2-4`)", False, False, ALVO4),
    ("faixa: corta a cadeia no segundo membro, idem",
     "roda em `Beta` (`x.gd:2-3`)", False, False, ALVO4),
    ("faixa: ponteiro solto não promete fim de nada e passa",
     "roda em `Beta` (`x.gd:2`)", True, True, ALVO4),
    # Os quatro abaixo são o MODELO DE ORAÇÃO e a HOMONÍMIA na régua de nome — as
    # duas coisas que a régua de literal já fazia e a de nome não: o `return` de
    # `sources/map/Map.gd` (linha 165) acusado por uma frase que não promete
    # `return` em parte nenhuma, e o `NpcScript` de `SkillTrainer.gd` acusado por
    # dizer o nome da classe. Cada isenção entra com o espelho que prova que ela não
    # é manto: o outro nome da mesma oração continua sendo cobrado.
    ("oração: o nome da oração coordenada anterior não é promessa deste ponteiro",
     "bate em `gate`, e roda em (`x.gd:2`)", True, True),
    ("oração: sem a vírgula, o mesmo nome é da oração e é acusado no wide",
     "bate em `gate` e roda em (`x.gd:2`)", True, False),
    ("homonímia: nomear o próprio arquivo não é prometer uma linha dele",
     "o `npc_script` abre na função (`npc_script.gd:4`)", True, True, ALVO7),
    ("homonímia não é manto: o outro nome da oração continua acusado",
     "o `npc_script` usa `WAL_SALT` (`npc_script.gd:4`)", False, False, ALVO7),
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
            # O ponteiro é procurado de verdade, a cláusula é cortada pela MESMA
            # função que `scan()` usa e o `stem` vem do alvo: as três coisas que
            # faltavam para um controle poder provar o modelo da oração e o da
            # homonímia. Cortar na substring fixa "`x.gd" deixaria o segundo sem como
            # existir — é justamente um ponteiro cujo nome é o do próprio arquivo.
            mp = PTR.search(text)
            seg = text[:mp.start()]
            clause = lit_clause(None, seg, True,
                                text[mp.end():mp.end() + 1] == "`")
            ok, cands, where, motivo = verdict(clause, mp, alvo, wide,
                                               os.path.splitext(
                                                   os.path.basename(mp.group(1)))[0])
            if ok == esperado:
                biting += 1
            else:
                print("[FAIL] identidade: self-test %s cego no controle %s (%s)"
                      % (nome, label, "aprovou o que devia acusar" if ok else "acusou o que devia aprovar"))
    return biting, total


# Os dois controles da classe `:NN`. O primeiro é a FORMA da herança (de qual arquivo
# cada continução fala), o segundo é o ADAPTADOR: `PTR` e `CONTPTR` têm os grupos em
# casas diferentes — no ponteiro nomeado o arquivo é o grupo 1 e a linha o grupo 2, no
# nu a linha é o grupo 1 — então um off-by-one aqui julgaria o arquivo como se fosse a
# linha, ou a linha 4 como se fosse a 3, e o verde sairia de uma régua que não leu nada.
HERD_HERDAS = [
    ("herança: o `:NN` puxa o arquivo do ponteiro anterior na mesma linha",
     "abre `Beta` em `x.gd:3` e fecha em `:4`", ["x.gd"]),
    ("herança: âncora também é antecedente, porque o arquivo é o mesmo",
     "declara `Beta` (`x.gd:@Beta`), e o corpo está em `:4`", ["x.gd"]),
    ("órfão: `:NN` antes de qualquer ponteiro da linha não herda de nada",
     "`:4` abre a frase, e `x.gd:3` vem depois", [None]),
    ("troca: cada continuação herda do SEU antecedente, na ordem da linha",
     "`a.gd:1` nomeia `Beta` e `:3` também; depois `x.gd:3` e `:4`", ["a.gd", "x.gd"]),
    ("faixa: `:4-6` é uma continuação, não duas",
     "mora em `x.gd:3` e a cadeia está em `:4-6`", ["x.gd"]),
    ("sem continuação na linha, nenhuma herança é inventada",
     "só `x.gd:3` e `x.gd:4`", []),
]

HERD_ADAPTADOR = [
    ("adaptador: o número herdado é o cobrado, e ele mora no alvo",
     "(`x.gd:4`), o `GATE_RUN` mora na `:2`", True),
    ("adaptador: o mesmo número apontando para outra linha é acusado",
     "(`x.gd:4`), o `GATE_RUN` mora na `:5`", False),
    # O caminho da continuação tem de chegar ao predicado de fim de arquivo pelo MESMO
    # `verdict` do ponteiro nomeado, senão a classe nova fica com uma régua própria que
    # só vale para a metade da árvore. `porta` não existe em ALVO5, que tem oito linhas:
    # sem o predicado, a oração sai pela porta de "não nomeia nada" e passa verde.
    ("adaptador: número herdado além da última linha do alvo é acusado",
     "(`x.gd:4`), a porta está na `:9`", False),
]

# ---------------------------------------------------------------------------
# 25b) COBERTURA da continuação: quantos tokens da forma `:NN` EXISTEM no escopo
# lido, contado por um laço que não passa por `herancas()` nem pelo `scan()`.
#
# Isto substitui o piso de NÍVEL (`CONT_MIN=8`), e o motivo é a classe que o piso
# acusava ser defeito: converter um `:NN` em âncora — que é exatamente o #124 —
# tira um do saldo, e o piso gritava "um walk que para de herdar devolve zero
# acusações" sobre um walk que lia tudo. Medido nesta fatia: três continuações
# viraram âncora (o ramo de Ryan, o `CopyBackup` do runbook de backup e o
# `BindAddress` do runbook de operação), o censo foi de 8 a 5, e o portão ficou
# verde; com o nível de 8 o PRIMEIRO deles já era vermelho. O outro lado do mesmo
# defeito: com população acima do piso, um walk que perdesse metade continuava
# verde — o nível só acusava depois de cair abaixo de um número escrito à mão.
#
# O que o piso guardava, guardado por escrito e sem falso positivo:
#   (i)  o braço lê os CONTROLES -- é `herdselftest`, e agora com o censo de
#        controles cobrado em `cont_cases > 0`, porque `biting == cases` é verde
#        vazio se alguém apagar a tabela (0 == 0).
#   (ii) o braço lê a ÁRVORE -- é o laço abaixo. Cobra-se a DIFERENÇA, não o
#        nível: todo token da forma `:NN` no escopo lido tem de estar no saldo do
#        walk. Converter um ponteiro derruba os dois números juntos, então a
#        diferença não se mexe; um `continue` tendo subido por cima da herança
#        mexe, e é acusado no tamanho exato do que sumiu — medido com o predicado
#        de escopo do `scan()` trocado por `startswith`, que lê 7 contra os 8 do
#        censo e imprime "sumiram 1".
#
# A independência é o ponto do desenho: `herd_cov_count` reimplementa a regra de
# escopo (doc, JSON, comentário em código) SEM chamar `herancas()`, e `scan()`
# mantém a condição inline dela. Os dois laços concordando é a afirmação; divergir
# é um dos dois tendo mudado. O regex é reescrito à mão abaixo de propósito -- se
# ele fosse o `CONTPTR` compartilhado, afivelar o `CONTPTR` afivelaria a testemunha.
#
# O que esta régua NÃO julga, julgado por censo impresso: o `poupados` é o que o
# recorte de registro datado deixa de ler. Alargar `SKIP_NAMES` move tokens de
# cobráveis para poupados sem tocar na diferença -- mudança de ESCOPO, declarada no
# número que sai no log, não métrica afrouxada. Para o recorte há réguas próprias
# (o teto de linha e o piso de âncora cobrada dentro do registro).
# ---------------------------------------------------------------------------
HERD_COV = [
    ("cobertura: comentário de código é escopo lido", ".gd", "# abre em `:4`", 1),
    ("cobertura: corpo de função não é prosa e não entra no censo", ".gd", "\tvar a = `:4`", 0),
    ("cobertura: doc conta, inclusive linha de tabela", ".md", "| `x.gd:1` | `:4` |", 1),
    ("cobertura: JSON não tem marcador de comentário, e ainda assim é lido", ".json", '"_note": "`:4`"', 1),
    ("cobertura: YAML fora de comentário não é escopo lido", ".yml", "  port: `:4`", 0),
    ("cobertura: YAML em comentário é escopo lido", ".yml", "# porta em `:4`", 1),
    ("cobertura: faixa `:4-6` é UM token, não dois", ".gd", "# mora em `x.gd:3` e a cadeia em `:4-6`", 1),
    ("cobertura: dois `:NN` na mesma linha são dois tokens", ".gd", "# `:4` e `:5`", 2),
    ("cobertura: ponteiro nomeado não é continuação", ".gd", "# `x.gd:4` nomeado", 0),
    ("cobertura: porta escrita como `:NN` sem backtick não é token", ".yml", "# target 127.0.0.1:9400", 0),
]


def herd_cov_count(ext, line):
    """Tokens de continuação nesta linha, se a linha estiver no escopo lido."""
    if not (ext == ".md" or ext == ".json"
            or line.lstrip().startswith(("#", "//"))):
        return 0
    return len(re.findall(r"`:[0-9]+(?:-[0-9]+)?`", line))


def herdcoverage(root):
    """(cobráveis, poupados) no escopo de `scan()`, contado sem `herancas()`."""
    cobravamos = 0
    poupados = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in KEEP and (not d.startswith(".") or d == ".github")]
        for fn in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
            if rel.startswith("archive/"):
                continue
            ext = os.path.splitext(fn)[1]
            if ext not in EXTS:
                continue
            try:
                src = open(os.path.join(dirpath, fn), encoding="utf-8",
                           errors="replace").read().split("\n")
            except OSError:
                continue
            soma = sum(herd_cov_count(ext, line) for line in src)
            if fn in SKIP_NAMES:
                poupados += soma
            else:
                cobravamos += soma
    return cobravamos, poupados


def herdselftest():
    biting = 0
    total = 0
    for label, line, esperadas in HERD_HERDAS:
        total += 1
        vistas = [arq for _m, arq in herancas(line)]
        if vistas == esperadas:
            biting += 1
        else:
            print("[FAIL] continuação: self-test cego no controle %s (herda %s, esperado %s)"
                  % (label, vistas, esperadas))
    for wide in (False, True):
        nome = "wide" if wide else "narrow"
        for label, line, esperado in HERD_ADAPTADOR:
            total += 1
            hs = herancas(line)
            err = None
            if not hs:
                err = "nenhuma continuação reconhecida na linha do controle"
            else:
                mc, arq = hs[0]
                if arq is None:
                    err = "órfão onde o controle promete um antecedente"
                else:
                    # O MESMO caminho de `scan()`: o `:NN` vira `Herdado` e o veredito
                    # decide pela oração cortada na posição dele, não na do ponteiro.
                    ok, cands, _where, _motivo = verdict(
                        lit_clause(None, line[:mc.start()], False, False),
                        Herdado(mc, arq), ALVO5, wide, "x")
                    if ok != esperado:
                        err = "deveria %s e %s (candidatos %s)" % (
                            "aprovar" if esperado else "acusar",
                            "aprovou" if ok else "acusou", cands[:3])
            if err is None:
                biting += 1
            else:
                print("[FAIL] continuação: self-test %s cego no controle %s (%s)"
                      % (nome, label, err))
    for label, ext, line, esperado in HERD_COV:
        total += 1
        visto = herd_cov_count(ext, line)
        if visto == esperado:
            biting += 1
        else:
            print("[FAIL] continuação: cobertura cega no controle %s (leu %d tokens, esperado %d)"
                  % (label, visto, esperado))
    return biting, total


# O REGISTRO de caminhos mortos: `scripts/dead_paths.txt`, uma linha por caminho com
# `| <motivo>` obrigatório. Ele era a única exceção da seção 24 (caminho de `.md` citado)
# e passa a ser a única exceção do ponteiro de linha morto. Os dois leitores do MESMO
# arquivo — o `read_registry` de lá e o `deadset` daqui — têm de aceitar exatamente as
# mesmas linhas, senão um poupa o que o outro acusa; o tamanho do registro sai nas duas
# máquinas (`MORTOS` e `CAMINHOS`) e a igualdade é cerca na bash, não prosa.
DEAD_PATH = re.compile(r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\.md$")
DEAD_MOTIVO_MIN = 12


def deadset(text):
    """O conjunto de caminhos que o registro declara mortos.

    As MESMAS quatro regras do `read_registry` da seção 24: comentário e linha em branco
    fora, `|` obrigatório, caminho com barra e de `.md`, motivo com doze caracteres ou
    mais. Copiar a regra é o que permite poupar; o que impede a cópia de virar duas
    verdades é a cerca do tamanho, e não a boa vontade de quem escreve.
    """
    out = set()
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "|" not in line:
            continue
        path, reason = line.split("|", 1)
        path = path.strip()
        reason = reason.strip()
        if not DEAD_PATH.match(path):
            continue
        if len(reason) < DEAD_MOTIVO_MIN:
            continue
        out.add(path)
    return out


def deadjudge(target, dead):
    """(acusar, poupado_por_registro) de um `arquivo:NN` cujo alvo não resolveu.

    Puro de propósito: o veredito não depende do corte, nem do arquivo que cita, nem do
    tamanho da linha — só do caminho como ele foi escrito e do registro. É por isso que
    ele tem controle plantado, e é por isso que um registro malformado NÃO poupa: a
    licença de um fantasma tem de ser lida pelos dois juízes como o que ela é — nada.
    """
    if target in dead:
        return False, True
    return True, False


# Cada controle é um modo de esta exceção mentir. Sem a perna negativa a função pode
# virar "poupa tudo" e o zero de acusações volta a ser a cegueira que a casa caça; sem
# a positiva, vira máquina de acusar citação registrada. O nono é o buraco que o piso
# de nível tapava em toda régua pequena: tabela vazia dá `biting == cases` em 0 de 0.
DEAD_CONTROLES = [
    ("morto sem registro e acusado", "", "a/b.md", True, False),
    ("morto registrado e poupado", "a/b.md | motivo comprido o bastante", "a/b.md", False, True),
    ("entrada sem motivo nao poupa", "a/b.md", "a/b.md", True, False),
    ("motivo curto nao poupa", "a/b.md | curto", "a/b.md", True, False),
    ("nome sem barra nao entra no registro", "b.md | motivo comprido o bastante", "b.md", True, False),
    ("so .md e registrado", "a/b.gd | motivo comprido o bastante", "a/b.gd", True, False),
    ("comentario do registro nao poupa", "# a/b.md | motivo comprido o bastante", "a/b.md", True, False),
    ("espaco em volta nao impede a poupanca", "  a/b.md   |   motivo comprido o bastante  ",
     "a/b.md", False, True),
    ("prefixo nao poupa caminho vizinho", "a/b.md | motivo comprido o bastante", "x/a/b.md", True, False),
    ("pipe dentro do motivo nao desloca o caminho", "a/b.md | motivo com | pipe dentro",
     "a/b.md", False, True),
    ("dois registros: o segundo poupa o segundo alvo",
     "a/b.md | motivo comprido o bastante\nc/d.md | outro motivo comprido aqui",
     "c/d.md", False, True),
    ("alvo que nao e o do registro continua acusado",
     "a/b.md | motivo comprido o bastante", "e/f.md", True, False),
]


def deadselftest():
    biting = 0
    for nome, texto, alvo, acusar, poupar in DEAD_CONTROLES:
        got = deadjudge(alvo, deadset(texto))
        if got == (acusar, poupar):
            biting += 1
        else:
            print("[FAIL] ponteiro morto: self-test cego no controle %s (registro %r, alvo %r -> %r, esperava (%r, %r))"
                  % (nome, texto, alvo, got, acusar, poupar))
    return biting, len(DEAD_CONTROLES)


# Cada controle é um modo de esta forma mentir, e os três grupos são as três pernas dela.
# Os três primeiros são o PARSER: o ramo que recusa não-número é inalcançável pelo corpus
# (`LISTPTR` já garantiu a forma), e ramo inalcançável sem controle é ramo que mudou de
# comportamento em silêncio — é a prova de que a promessa da regex é a promessa do parser.
# Os três seguintes são o SHAPE: se `PTR` passasse a casar `12,13` os dois braços julgam o
# mesmo número e a soma da cobertura deixa de ser um censo; se `LISTPTR` casasse o
# ponteiro simples, o braço novo comeria o velho. Os últimos são o VEREDITO, com as duas
# bordas cobradas e o meio não — a decisão de ESCOPO escrita em número, que sem controle
# é só comentário.
_LFILL = ["a", "b", "", "d", "e"]
LISTA_CONTROLES = [
    ("parse de `12,13-15` devolve os dois pares",
     lambda: listitems("12,13-15") == [(12, 12), (13, 15)]),
    ("parse recusa o nao-numero e mantem o vizinho",
     lambda: listitems("12,x") == [(12, 12)]),
    ("numero sem traco vale a si mesmo como fim",
     lambda: listitems("12,13") == [(12, 12), (13, 13)]),
    ("LISTPTR nao casa o ponteiro simples",
     lambda: len(LISTPTR.findall("`a.gd:12`")) == 0),
    ("PTR nao casa a lista",
     lambda: len(PTR.findall("`a.gd:12,13`")) == 0),
    ("LISTPTR da o arquivo no grupo 1 e a lista no grupo 2",
     lambda: [(m.group(1), m.group(2)) for m in LISTPTR.finditer("`a.gd:12,13-15`")]
             == [("a.gd", "12,13-15")]),
    ("numero que cabe e nao esta em branco nao e acusado",
     lambda: listitem_verdict(2, 2, _LFILL) is None),
    ("fim exatamente na ultima linha nao e borda",
     lambda: listitem_verdict(1, 5, _LFILL) is None),
    ("fim uma linha alem do arquivo e borda",
     lambda: listitem_verdict(1, 6, _LFILL) == "borda"),
    ("comeco zero e borda",
     lambda: listitem_verdict(0, 2, _LFILL) == "borda"),
    ("intervalo invertido e borda",
     lambda: listitem_verdict(4, 2, _LFILL) == "borda"),
    ("comeco em branco e acusado",
     lambda: listitem_verdict(3, 3, _LFILL) == "branco"),
    ("meio do intervalo em branco nao e cobrado",
     lambda: listitem_verdict(2, 4, _LFILL) is None),
]


def listaselftest():
    biting = 0
    for nome, teste in LISTA_CONTROLES:
        if teste():
            biting += 1
        else:
            print("[FAIL] ponteiro com vírgula: self-test cego no controle %s" % nome)
    return biting, len(LISTA_CONTROLES)


def build_index(root):
    # indice basename -> ate tres caminhos, para resolver ponteiro citado por NOME NU.
    # A medicao desta passada: 95 ponteiros fora dos registros datados tem alvo que nao
    # existe como foi escrito, e 89 deles resolvem um unico arquivo. Nenhum braco abaixo
    # os lia: `lines_of` exigia o caminho literal, entao o ponteiro de nome nu saia pela
    # porta dos invisiveis e a linha citada nunca era conferida -- exatamente a classe
    # que o #79 registrou como escapando da identidade e do literal. O cap de 3 e a
    # exigencia de unicidade sao os mesmos de `_PtrResolve` (`tests/IdleTestsFrontier.gd`):
    # nome ambiguo nao tem como decidir, nome ausente e historico legitimo (a prosa que
    # fala do `gut_runner.gd` apagado tem que poder existir). `build`/`dist` ficam fora
    # porque copia gerada nao e alvo de evidencia -- entrar no indice seria trocar uma
    # citacao verdadeira por "ambigua" so porque alguem rodou o export antes.
    idx = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in KEEP and d not in ("build", "dist")
                       and (not d.startswith(".") or d == ".github")]
        for fn in filenames:
            bucket = idx.setdefault(fn, [])
            if len(bucket) < 3:
                bucket.append(os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/"))
    return idx


def resolve_path(path, root, index, cache, count=None):
    # caminho citado -> linhas do alvo, ou None. É a decisão que estava dentro de
    # `scan`, suspensa para fora porque o censo independente do ponteiro morto precisa
    # dela sem precisar do veredito: o que se duplica é o WALK, nunca a resolução.
    # Ordem de resolucao -- a mesma do `_PtrResolve` do harness: caminho literal;
    # caminho que e sufixo unico da arvore (o nome bate e o diretorio esta errado);
    # nome nu unico na arvore. Os dois ultimos eram justamente o que a classe nao
    # tinha: o walk so abria arquivo pelo caminho como ele foi escrito, e um ponteiro
    # por nome nu saia pela porta dos invisiveis sem a linha citada ser conferida.
    if path not in cache:
        full = os.path.join(root, path)
        target = path if os.path.isfile(full) else None
        if target is None:
            arr = index.get(os.path.basename(path)) or []
            suffix = [p for p in arr if p.endswith("/" + path)]
            if len(suffix) == 1:
                target = suffix[0]
            elif "/" not in path and len(arr) == 1:
                target = arr[0]
        if target is None:
            cache[path] = None
        else:
            if target != path and count is not None:
                count[0] += 1
            cache[path] = open(os.path.join(root, target), encoding="utf-8",
                               errors="replace").read().split("\n")
    return cache[path]


def deadcensus(root, index):
    """Quantos `arquivo:NN` tem alvo que não resolve, contado por um walk próprio.

    Existe por um motivo só: o veredito do ponteiro morto nasce dentro do laço que
    julga a cláusula, e número nascido junto do veredito não sobrevive à sua remoção.
    Este laço não chama `deadjudge`, não conhece o registro e não julga frase nenhuma —
    resolve alvo e conta. A igualdade com o censo do veredito é cerca na bash, e é o
    que impede que "0 acusações" volte a significar "o braço parou de olhar".
    """
    cache = {}
    seen = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in KEEP and (not d.startswith(".") or d == ".github")]
        for fn in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
            if rel.startswith("archive/") or fn in SKIP_NAMES:
                continue
            if not fn.endswith(EXTS):
                continue
            lines = resolve_path(rel, root, index, cache)
            if lines is None:
                continue
            is_doc = fn.endswith(".md") or fn.endswith(".json")
            for line in lines:
                if not is_doc and not line.lstrip().startswith(("#", "//")):
                    continue
                for m in PTR.finditer(line):
                    tgt = m.group(1)
                    if tgt.startswith("res://"):
                        tgt = tgt[6:]
                    if resolve_path(tgt, root, index, cache) is None:
                        seen += 1
    return seen


def listacensus(root, index):
    """Quantos ponteiros com virgula o corpus tem, contado por um walk proprio.

    Mesmo motivo do `deadcensus`: o numero que cerca um braço nao pode nascer dentro
    do braço. Este laço nao abre intervalo, nao confere linha em branco, nao conhece o
    registro de caminhos mortos — conta token e numero, e é com ele que a igualdade de
    cobertura da secao 31 e cerca. O recorte de registro datado e refeito aqui porque
    o veredito roda depois dele: censos de escopos diferentes nao sao comparaveis, e a
    parcela poupada sai como terceiro numero, nao somada aos outros dois.
    """
    cache = {}
    tokens = 0
    itens = 0
    poupados = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in KEEP and (not d.startswith(".") or d == ".github")]
        for fn in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
            if rel.startswith("archive/") or not fn.endswith(EXTS):
                continue
            lines = resolve_path(rel, root, index, cache)
            if lines is None:
                continue
            # O mesmo corte do veredito, decidido por NOME e nao por caminho: sem ele os
            # dois lados estariam contando escopos diferentes, e a igualdade diria
            # qualquer coisa menos "o braço olhou tudo que o censo viu".
            e_fora = fn in SKIP_NAMES
            is_doc = fn.endswith(".md")
            is_json = fn.endswith(".json")
            for line in lines:
                if not is_doc and not is_json and not line.lstrip().startswith(("#", "//")):
                    continue
                for m in LISTPTR.finditer(line):
                    n_itens = len(listitems(m.group(2)))
                    if e_fora:
                        poupados += n_itens
                        continue
                    tokens += 1
                    itens += n_itens
    return tokens, itens, poupados


def scan(root, wide, reg, index, dead):
    cache = {}
    lit_judged = 0
    lit_accused = 0
    reg_judged = 0
    reg_accused = 0
    anchor_total = 0
    anchor_accused = 0
    cont_total = 0
    cont_judged = 0
    cont_accused = 0
    cont_orfas = 0
    line_total = 0
    # O censo do ponteiro morto: quantos `arquivo:NN` tem alvo que não resolve, quantos
    # acusam e quantos o registro poupa. Os três saem impressos porque a exceção tem de
    # ser contada: sem o número dos poupados, "0 acusações" passaria a significar também
    # "a exceção cresceu", que é exatamente o que o `registry_rot` de lá caça.
    dead_bad = 0
    dead_spared = 0
    # Os `:NN` de continuação cujo alvo herdado não resolve: o censo independente só vê
    # ponteiro nomeado, então é esta a parcela que a igualdade com ele tem de tirar.
    dead_cont = 0
    resolvidos = [0]
    # Censo do RECORTE de registro datado: `fora` conta linhas lidas por arquivo, e os dois
    # numeros seguintes separam o que a isencao poupa (linha) do que ela nao poupa (ancora).
    fora = {}
    lin_fora = 0
    anc_fora = 0
    # O censo do ponteiro com virgula: listas vistas, numeros dentro delas, quantas
    # linhas o registro datado poupou de cobrança e quantas o alvo não resolveu. Os
    # quatros saem impressos pela mesma razão dos do ponteiro morto — exceção sem
    # número não é exceção, é buraco, e "0 acusações" tem de continuar sendo frase
    # diferente de "ninguém olhou".
    lista_total = 0
    lista_itens = 0
    lista_fora = 0
    lista_morto = 0
    lista_spared = 0
    lista_accused = 0

    def lines_of(path):
        return resolve_path(path, root, index, cache, resolvidos)

    accused = 0
    judged = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in KEEP and (not d.startswith(".") or d == ".github")]
        for fn in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
            if rel.startswith("archive/"):
                continue
            if not fn.endswith(EXTS):
                continue
            src = lines_of(rel)
            if src is None:
                continue
            is_doc = fn.endswith(".md")
            # JSON nao tem marcador de comentario: a prosa embarcada no dado
            # (`_note`, `_campos`, `_estado_atual`) e linha como qualquer outra, e ela
            # vinha apodrecendo exatamente porque nenhum corpo deste script a lia. O
            # censo medido em 2026-09-29: 3 ponteiros em data/conf/*.json no HEAD, e os
            # tres eram falsos; reescrita a prosa, o corpo hoje julga 10.
            is_json = fn.endswith(".json")
            # O recorte de registro datado decidido UMA vez por arquivo, antes de qualquer
            # laço: o censo de âncora cobrada precisa nascer no mesmo lugar que a cobrança,
            # senão ele conta o shape e não o veredito (ver o bloco do SKIP_NAMES).
            e_fora = fn in SKIP_NAMES
            for n, line in enumerate(src, 1):
                # Em codigo, so comentario: o corpo de uma funcao nao e prosa nomeando
                # a linha de outra pessoa.
                if not is_doc and not is_json and not line.lstrip().startswith(("#", "//")):
                    continue
                # Régua de ÂNCORA (#124): `arquivo:@símbolo`, julgada pelo bloco da
                # declaração. Não depende do corte (o símbolo vem do próprio ponteiro,
                # não da forma de um identificador da cláusula), então os dois passes
                # têm de ver o mesmo número — a igualdade é invariant e é cobrada em
                # main(), como a de literal. Ela roda ANTES do atalho de registro
                # datado abaixo de propósito: `arquivo:NN` em CHANGELOG é história e
                # não se cobra; âncora não envelhece com inserção, e deixar a forma
                # nova fora do censo é exatamente o buraco da classe #114 — ponteiro
                # que nenhuma régua lê.
                anc_prev_end = 0
                anc_k = 0
                for m4 in ANCHOR.finditer(line):
                    anchor_total += 1
                    if e_fora:
                        anc_fora += 1
                    anc_k += 1
                    tgt = m4.group(1)
                    if tgt.startswith("res://"):
                        tgt = tgt[6:]
                    seg4 = line[anc_prev_end:m4.start()]
                    anc_prev_end = m4.end()
                    if "|" in seg4:
                        seg4 = seg4.rsplit("|", 1)[-1]
                    tl4 = lines_of(tgt)
                    if tl4 is None:
                        anchor_accused += 1
                        print("[FAIL] âncora: %s:%d cita %s e o arquivo não existe — linha quebra, arquivo quebra também, e sem alvo não há bloco"
                              % (rel, n, m4.group(0)))
                        continue
                    ok4, mot4, det4 = anchorverdict(
                        m4.group(2),
                        lit_clause(src[n - 2] if n > 1 else None, seg4, anc_k == 1,
                                   m4.end() < len(line) and line[m4.end()] == "`"),
                        tl4, anchor_ext(tgt))
                    if ok4:
                        continue
                    anchor_accused += 1
                    print("[FAIL] âncora: %s:%d aponta %s e %s"
                          % (rel, n, m4.group(0), ANCHOR_MOTIVOS[mot4] % det4))
                if e_fora:
                    # O recorte dito em numero, nao so em comentario: quantos ponteiros de
                    # linha esta isencao poupa. O censo de ANCORA cobrada nao nasce aqui de
                    # proposito: ele nasce no laco que cobra. Medir o shape no atalho deixa
                    # o piso ANCHOR_FORA_MIN cego para o unico erro que ele existe para
                    # ver -- i.e. o atalho subir para cima do laco de ancora continua
                    # dizendo "15 cobradas" enquanto o laço não julga mais nenhuma.
                    fora[rel] = fora.get(rel, 0) + 1
                    lin_fora += sum(1 for _ in PTR.finditer(line))
                    lista_fora += sum(len(listitems(m6.group(2))) for m6 in LISTPTR.finditer(line))
                    continue
                # O ponteiro com virgula, julgado depois do atalho acima de proposito: a
                # forma afirma LINHAS, então envelhece com a doc como o `arquivo:NN` e herda
                # a mesma isenção dos registros datados. O que muda é o oposto do que
                # mudou no `:NN` de continuação: aquele já era lido por um braço e ganhou
                # licença; este não era lido por braço nenhum.
                for m6 in LISTPTR.finditer(line):
                    lista_total += 1
                    itens = listitems(m6.group(2))
                    alvo = m6.group(1)
                    if alvo.startswith("res://"):
                        alvo = alvo[6:]
                    tl6 = lines_of(alvo)
                    if tl6 is None:
                        lista_morto += len(itens)
                        acusar6, poupada6 = deadjudge(alvo, dead)
                        if poupada6:
                            lista_spared += len(itens)
                        elif acusar6:
                            lista_accused += len(itens)
                            print("[FAIL] ponteiro com vírgula: %s:%d cita %s e nenhum dos %d números pode ser aberto — o alvo não resolve nem por caminho, nem por sufixo, nem por nome; registre o caminho em scripts/dead_paths.txt com motivo, senão a frase afirma evidência que ninguém pode abrir"
                                  % (rel, n, m6.group(0), len(itens)))
                        continue
                    for (d6, a6) in itens:
                        lista_itens += 1
                        # As duas bordas pelo mesmo cano do `arquivo:NN-NN`: o fim fora do
                        # arquivo é acusação, e o começo em branco também. O meio do
                        # intervalo não é cobrado porque o ponteiro simples não o cobra —
                        # uma régua mais dura para a forma barata seria o incentivo exato
                        # para voltar a escrever cinco backticks.
                        mot6 = listitem_verdict(d6, a6, tl6)
                        if mot6 is None:
                            continue
                        lista_accused += 1
                        if mot6 == "borda":
                            print("[FAIL] ponteiro com vírgula: %s:%d cita %s e o número %d não cabe em %s, que tem %d linhas — quem abre a doc cola num sítio que não existe"
                                  % (rel, n, m6.group(0), a6 if a6 > len(tl6) else d6, alvo, len(tl6)))
                        else:
                            print("[FAIL] ponteiro com vírgula: %s:%d cita %s e a linha %d cai em branco em %s — branco não mostra nada para quem abre no número citado"
                                  % (rel, n, m6.group(0), d6, alvo))
                prev_end = 0
                ptr_k = 0
                # A CONTINUACAO entra no mesmo laco do ponteiro nomeado, nao num laco
                # separado de proposito: o que faz a clausula de um `:NN` e a posicao
                # dele na linha. Jogando os dois num fluxo ordenado, o ponteiro que vem
                # depois do `:NN` corta no `:NN` — e `ptr_k == 1` passa a significar "o
                # primeiro ponteiro da linha", que e o que a funcao da oracao quer saber.
                pontos = [(m.start(), m, False) for m in PTR.finditer(line)]
                for mc, herdado in herancas(line):
                    cont_total += 1
                    if herdado is None:
                        cont_accused += 1
                        cont_orfas += 1
                        print("[FAIL] continuação: %s:%d cita %s sem nenhum `arquivo:NN` ou `arquivo:@sim` antes, na mesma linha — sem antecedente não há de que arquivo falar, e a régua que adivinha pela linha de cima passa a depender de onde a frase quebrou"
                              % (rel, n, mc.group(0)))
                        continue
                    pontos.append((mc.start(), Herdado(mc, herdado), True))
                for _pos, m, eh_cont in sorted(pontos, key=lambda t: t[0]):
                    target = m.group(1)
                    if target.startswith("res://"):
                        target = target[6:]
                    ponto = m.group(0) if not eh_cont else "`%s:%s%s`" % (
                        target, m.group(2),
                        ("-%s" % m.group(3)) if m.group(3) else "")
                    herd = " (linha herdada do ponteiro anterior na mesma linha)" if eh_cont else ""
                    clip = line[prev_end:m.start()]
                    prev_end = m.end()
                    ptr_k += 1
                    if "|" in clip:
                        clip = clip.rsplit("|", 1)[-1]
                    clause = lit_clause(src[n - 2] if n > 1 else None, clip, ptr_k == 1,
                                        m.end() < len(line) and line[m.end()] == "`")
                    tl = lines_of(target)
                    if tl is None:
                        # A porta dos invisíveis, fechada: até aqui um `arquivo:NN` cujo alvo
                        # não resolvia saía do walk sem julgamento nenhum, enquanto a ÂNCORA do
                        # mesmo arquivo morto era acusada (`cita %s e o arquivo não existe`). A
                        # assimetria custou a passada do worklist: sete ponteiros sem alvo na
                        # árvore, seis deles prosa que se deixou ler como evidência e um
                        # registrado como morto. Quem abre a doc cola um número em arquivo que
                        # não existe, e o veredito da régua era o silêncio.
                        acusar, poupada = deadjudge(target, dead)
                        if poupada:
                            dead_spared += 1
                        elif acusar:
                            dead_bad += 1
                            print("[FAIL] ponteiro morto: %s:%d cita %s e o alvo não resolve — nem caminho literal, nem sufixo único, nem nome único na árvore; se o arquivo saiu do repositório, registre o caminho em scripts/dead_paths.txt com motivo, senão a frase afirma evidência que ninguém pode abrir%s"
                                  % (rel, n, ponto, herd))
                        if eh_cont:
                            dead_cont += 1
                        if WL_ON and not wide and not eh_cont:
                            wl_judge("%s:%d" % (rel, n), target, m.group(2), None, clause)
                        continue
                    if WL_ON and not wide and not eh_cont:
                        wl_judge("%s:%d" % (rel, n), target, m.group(2), tl, clause)
                    if eh_cont:
                        cont_judged += 1
                    else:
                        judged += 1
                    # A MESMA oração que a régua de literal julga (#116). Antes desta
                    # linha o braço de identidade comia o prefixo bruto da linha desde o
                    # ponteiro anterior, e os dois juízes da mesma frase liam duas
                    # promessas diferentes: a linha 165 de `Map.gd` foi acusada de
                    # mentir porque a ORAÇÃO ANTERIOR, na mesma linha, citava o
                    # `return` — e a frase sobre o chamador não promete `return` em
                    # lugar nenhum. Régua que julga a frase errada acusa a frase certa.
                    ok, cands, where, motivo = verdict(
                        clause, m, tl, wide,
                        os.path.splitext(os.path.basename(target))[0])
                    if ok:
                        continue
                    if eh_cont:
                        cont_accused += 1
                    else:
                        accused += 1
                    if motivo == "alem":
                        print("[FAIL] fim de arquivo: %s:%d aponta %s e o alvo tem %s linhas — quem abre no número citado não chega lá%s"
                              % (rel, n, ponto, len(tl), herd))
                    elif motivo == "branco":
                        print("[FAIL] branco: %s:%d aponta %s e a linha %s está em branco — quem abre no número citado não vê nada%s"
                              % (rel, n, ponto, where[0], herd))
                    elif motivo == "faixa":
                        print("[FAIL] faixa: %s:%d cita %s e o construto continua na linha %s (%s) — a faixa termina no meio da cadeia que a frase nomeia%s"
                              % (rel, n, ponto, where[0],
                                 (tl[where[0] - 1].strip()[:70] if where[0] <= len(tl) else ""), herd))
                    elif motivo == "arquivo":
                        print("[FAIL] arquivo: %s:%d nomeia %s e aponta %s:%s; o nome mora em %s — a linha citada é texto cheio de outra coisa%s"
                              % (rel, n, cands[:3], target, m.group(2), where or "lugar nenhum", herd))
                    else:
                        print("[FAIL] identidade: %s:%d nomeia %s e aponta %s:%s; o nome mora em %s%s"
                              % (rel, n, cands[:3], target, m.group(2), where or "lugar nenhum", herd))
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
                line_total += lit_k
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
    return judged, accused, lit_judged, lit_accused, reg_judged, reg_accused, anchor_total, anchor_accused, line_total, resolvidos[0], cont_total, cont_judged, cont_accused, cont_orfas, len(fora), lin_fora, anc_fora, dead_bad, dead_spared, dead_cont, lista_total, lista_itens, lista_fora, lista_morto, lista_spared, lista_accused


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    biting, cases = selftest()
    lbiting, lcases = litselftest()
    rbiting, rcases = regselftest()
    abiting, acases = anchorselftest()
    hbiting, hcases = herdselftest()
    dbiting, dcases = deadselftest()
    vbiting, vcases = listaselftest()
    cov_n, cov_spared = herdcoverage(root)
    reg = registry(root)
    index = build_index(root)
    reg_path = os.path.join(root, "scripts/dead_paths.txt")
    dead_text = (open(reg_path, encoding="utf-8", errors="replace").read()
                 if os.path.isfile(reg_path) else "")
    dead = deadset(dead_text)
    (narrow_judged, narrow_bad, lit_judged, lit_bad, reg_judged, reg_bad,
     anchors, anchor_bad, lines, resolvidos, cont_n, cont_jn, cont_an, cont_on,
     fora_n, fora_lin, fora_anc, dead_n, dead_sp, dead_c,
     lista_n, lista_it, lista_f, lista_mt, lista_sp, lista_bad) = \
        scan(root, False, reg, index, dead)
    (wide_judged, wide_bad, lit_judged_w, lit_bad_w, reg_judged_w, reg_bad_w,
     anchors_w, anchor_bad_w, lines_w, resolvidos_w, cont_w, cont_jw, cont_aw,
     cont_ow, fora_n_w, fora_lin_w, fora_anc_w, dead_w, dead_spw, dead_cw,
     lista_nw, lista_itw, lista_fw, lista_mtw, listaspw, lista_badw) = \
        scan(root, True, reg, index, dead)
    dead_seen = deadcensus(root, index)
    lista_tok_c, lista_it_c, lista_fora_c = listacensus(root, index)
    accused = narrow_bad + wide_bad
    cont_jugados = cont_jn + cont_jw
    cont_acusados = cont_an + cont_aw
    # A régua de literal não depende do corte: ela compara texto, não forma de
    # identificador. Os dois passes têm de ver o mesmo; divergir é o walk tendo
    # mudado de forma entre os cortes, e aí nenhum dos dois números vale.
    cut_drift = (lit_judged, lit_bad) != (lit_judged_w, lit_bad_w)
    reg_cut_drift = (reg_judged, reg_bad) != (reg_judged_w, reg_bad_w)
    anchor_cut_drift = (anchors, anchor_bad, lines) != (anchors_w, anchor_bad_w, lines_w)
    # Resolver por nome nao depende do corte: a arvore e a mesma, e os dois passes tem de
    # abrir os mesmos alvos. Divergir e o indice tendo mudado entre os dois `scan`, e ai
    # nenhum dos censos acima vale.
    resol_cut_drift = resolvidos != resolvidos_w
    # Quantos `:NN` existem na arvore nao depende do corte: o corte muda a FORMA do
    # candidato, nao a regex do ponteiro. Divergir e o walk tendo perdido linha.
    cont_cut_drift = cont_n != cont_w
    # Um alvo que não resolve não resolve nos dois cortes: o corte muda a FORMA do
    # candidato da cláusula, não a árvore. Divergir aqui é `resolve_path` ou o índice
    # tendo mudado entre os dois `scan` — ou o registro lendo texto diferente — e aí o
    # censo de mortos não diz mais nada sobre a árvore.
    dead_cut_drift = (dead_n, dead_sp, dead_c) != (dead_w, dead_spw, dead_cw)
    # A cobertura, e não o piso: `deadcensus` refaz o walk sem chamar `deadjudge`, então
    # os tokens que o veredito viu (menos as continuações, que ele conta à parte porque o
    # censo só conhece `arquivo:NN`) têm de bater com o que o censo acha. É esta a cerca
    # que sobrevive à remoção do braço: sem ela, apagar o `if tl is None` devolve
    # "0 acusados" e o censo do veredito cai a zero junto — nada dentro do veredito pode
    # denunciar o próprio veredito.
    dead_cov_drift = (dead_n + dead_sp - dead_c) != dead_seen
    print("identidade de ponteiro: %d nomeados no corte narrow (%d acusacoes), %d no corte wide (%d acusacoes), %d alvos abertos por resolucao de nome, self-test %d/%d controles mordendo"
          % (narrow_judged, narrow_bad, wide_judged, wide_bad, resolvidos, biting, cases))
    print("literal pinado: %d ponteiros com literal único no alvo (%d acusacoes), self-test %d/%d controles mordendo"
          % (lit_judged, lit_bad, lbiting, lcases))
    print("continuação de ponteiro: %d `:NN` no corte narrow (%d acusações), %d no corte wide (%d acusações), %d sem antecedente na linha, self-test %d/%d controles mordendo"
          % (cont_n, cont_an, cont_w, cont_aw, cont_on, hbiting, hcases))
    print("cobertura da continuação: o censo independente acha %d tokens no escopo lido, o walk leu %d, e %d ficaram poupados pelo recorte de registro datado"
          % (cov_n, cont_n, cov_spared))
    print("registro de gates de estrutura: %d prosas afirmando a contagem (%d acusações), %s, self-test %d/%d controles mordendo"
          % (reg_judged, reg_bad, "registro NÃO lido" if reg is None else "registro com %d gates" % len(reg), rbiting, rcases))
    print("âncora de ponteiro: %d `arquivo:@simbolo` no lugar de %d `arquivo:linha` (%d acusações), self-test %d/%d controles mordendo"
          % (anchors, lines, anchor_bad, abiting, acases))
    # O censo do ponteiro morto sai com os dois números juntos — o que o veredito viu e o
    # que um walk separado, que não chama `deadjudge`, acha — porque número nascido junto
    # do veredito não sobrevive à remoção do veredito. A poupados é a exceção, e exceção
    # sem número impresso é a licença que a seção 24 existe para caçar (`registry_rot`).
    print("ponteiro morto: %d vistos pelo veredito (%d acusados, %d poupados pelo registro de %d caminho(s), %d deles continuação) e %d vistos pelo censo independente, self-test %d/%d controles mordendo"
          % (dead_n + dead_sp, dead_n, dead_sp, len(dead), dead_c, dead_seen, dbiting, dcases))
    if reg_cut_drift:
        print("[FAIL] registro: narrow viu %r e wide viu %r — contagem de numeral não depende do corte"
              % ((reg_judged, reg_bad), (reg_judged_w, reg_bad_w)))
    if anchor_cut_drift:
        print("[FAIL] âncora: narrow viu %r e wide viu %r — o símbolo vem do ponteiro, não do corte"
              % ((anchors, anchor_bad, lines), (anchors_w, anchor_bad_w, lines_w)))
    if resol_cut_drift:
        print("[FAIL] resolução: narrow abriu %d alvos por nome e wide abriu %d — a árvore é a "
              "mesma entre os dois passes, e divergir aqui é o índice tendo mudado no meio"
              % (resolvidos, resolvidos_w))
    if cont_cut_drift:
        print("[FAIL] continuação: narrow viu %d `:NN` e wide viu %d — a regex do ponteiro não depende do corte"
              % (cont_n, cont_w))
    if dead_cut_drift:
        print("[FAIL] ponteiro morto: narrow acusou %d e poupou %d, wide acusou %d e poupou %d — um alvo que não resolve não resolve nos dois cortes, e divergir aqui é o walk (ou o registro) tendo parado de olhar entre os dois passes"
              % (dead_n, dead_sp, dead_w, dead_spw))
    if dead_cov_drift:
        print("[FAIL] cobertura do ponteiro morto: o veredito viu %d tokens sem alvo (%d acusados + %d poupados − %d continuações, que o censo não conhece) e o censo independente, que não chama `deadjudge`, acha %d no mesmo escopo — diferença de %d é o braço tendo parado de olhar (positivo é o censo vendo morto que ninguém julga, negativo é o veredito contando o que não está na árvore)"
              % (dead_n + dead_sp - dead_c, dead_n, dead_sp, dead_c, dead_seen,
                 dead_seen - (dead_n + dead_sp - dead_c)))
    # O censo do RECORTE também não depende do corte: a isenção é de classe, não de forma.
    # Divergir aqui é o `continue` de registro datado tendo subido ou descido no laço entre
    # os dois passes — ou seja, exatamente o momento em que a âncora deixaria de ser cobrada
    # dentro do CHANGELOG sem que nenhum dos dois censos de âncora o dissesse.
    fora_cut_drift = (fora_n, fora_lin, fora_anc) != (fora_n_w, fora_lin_w, fora_anc_w)
    if fora_cut_drift:
        print("[FAIL] recorte: narrow viu %d registros / %d linhas poupadas / %d âncoras cobradas, e wide viu %d / %d / %d — o atalho de registro datado não pode depender do corte"
              % (fora_n, fora_lin, fora_anc, fora_n_w, fora_lin_w, fora_anc_w))
    print("recorte de registro datado: %d arquivos lidos, %d ponteiros de linha poupados, %d âncoras cobradas MESMO DENTRO do registro"
          % (fora_n, fora_lin, fora_anc))
    if cut_drift:
        print("[FAIL] literal: narrow viu %r e wide viu %r — a régua não depende do corte, a igualdade é invariant"
              % ((lit_judged, lit_bad), (lit_judged_w, lit_bad_w)))
    # Maquina: as linhas abaixo sao o que a secao bash soma em `checks` e `failures`.
    print("IDENTIDADE %d %d %d %d %d %d" % (narrow_judged, wide_judged, accused, cases, biting, resolvidos))
    print("LITERAL %d %d %d %d" % (lit_judged, lit_bad, lcases, lbiting))
    print("REGISTRO %d %d %d %d" % (reg_judged, reg_bad, rcases, rbiting))
    print("ANCORA %d %d %d %d %d %d %d %d" % (anchors, anchor_bad, lines, acases, abiting, fora_n, fora_lin, fora_anc))
    print("CONT %d %d %d %d %d %d %d %d" % (cont_jugados, cont_acusados, hcases, hbiting, cont_n, cont_on, cov_n, cov_spared))
    print("MORTOS %d %d %d %d %d %d %d %d %d" % (dead_n, dead_sp, len(dead), dcases, dbiting,
                                                 1 if dead_cut_drift else 0,
                                                 dead_c, dead_seen,
                                                 1 if dead_cov_drift else 0))
    # O ponteiro com virgula, cercado pelas mesmas duas igualdades do ponteiro morto. O
    # corte nao muda nada aqui: `LISTPTR` e regex de forma, e os dois passes leem a
    # mesma arvore — divergir e o braco tendo parado no meio de um dos dois.
    lista_cut_drift = ((lista_n, lista_it, lista_f, lista_mt, lista_sp, lista_bad)
                       != (lista_nw, lista_itw, lista_fw, lista_mtw, listaspw, lista_badw))
    # Cobertura, nunca piso: quantos token e quantos numero o veredito abriu, contra o
    # walk que nao abre intervalo nenhum e nao conhece o registro. Um piso de "tem de
    # haver lista na arvore" acusaria progresso pela razao do #137 — quem converte a
    # ultima lista em ponteiros separados derruba o saldo sem derrubar o walk.
    lista_cov_drift = (lista_n != lista_tok_c) or (lista_it + lista_mt != lista_it_c)
    # Os poupados do recorte sao contados duas vezes de proposito — uma dentro do
    # veredito, outra dentro do censo — e as duas contam por nomes de arquivo, nao por
    # caminho. Divergir e o `SKIP_NAMES` tendo sido lido de um lado e do outro, que e o
    # exato modo de a isencao crescer sem que ninguem a escreva.
    lista_reg_drift = lista_f != lista_fora_c
    if lista_reg_drift:
        print("[FAIL] recorte da vírgula: o veredito poupou %d números dentro dos registros datados e o censo, que não julga nada, conta %d no mesmo recorte — as duas leituras do `SKIP_NAMES` deixaram de ser a mesma isenção"
              % (lista_f, lista_fora_c))
    if lista_cut_drift:
        print("[FAIL] ponteiro com vírgula: narrow viu %d listas / %d números julgados / %d em alvo morto / %d poupados pelo registro, e wide viu %d / %d / %d / %d — a forma não depende do corte, a igualdade é invariant"
              % (lista_n, lista_it, lista_mt, lista_f, lista_nw, lista_itw, lista_mtw, lista_fw))
    if lista_cov_drift:
        print("[FAIL] cobertura do ponteiro com vírgula: o veredito abriu %d listas e %d números (%d vivos + %d em alvo que não resolve) e o censo independente, que não confere linha nenhuma, acha %d listas e %d números no mesmo escopo — diferença é braço tendo parado de olhar, e sem esta cerca o braço pode ser apagado que os dois números caem a zero juntos dentro dele"
              % (lista_n, lista_it + lista_mt, lista_it, lista_mt, lista_tok_c, lista_it_c))
    print("ponteiro com vírgula: %d listas com %d números julgados (%d acusados, %d dentro de alvo que não resolve, %d desses poupados pelo registro) e %d números poupados dentro dos registros datados, contra %d listas e %d números no censo independente"
          % (lista_n, lista_it + lista_mt, lista_bad, lista_mt, lista_sp, lista_f,
             lista_tok_c, lista_it_c))
    print("LISTA %d %d %d %d %d %d %d %d %d %d %d %d %d" % (
        lista_n, lista_it, lista_mt, lista_sp,
        lista_f, lista_bad,
        1 if lista_cut_drift else 0,
        1 if lista_cov_drift else 0,
        lista_tok_c, lista_it_c, lista_fora_c,
        len(LISTA_CONTROLES), vbiting))
    wl_fail = False
    if WL_ON:
        # A lista sai ordenada por classe porque é por classe que ela é lida: primeiro a
        # que é sintaxe (`gratis`), depois a que é frase (`prosa`), depois as que não têm
        # âncora a oferecer. Os `:NN` de continuação ficam fora por construção: a classe
        # deles depende do ponteiro nomeado da mesma linha, e o worklist julgaria o alvo
        # herdado como se a frase o tivesse nomeado.
        for row in sorted(WL_ROWS, key=lambda r: (WL_CLASSES.index(r[0]), r[1])):
            print("WORKLIST %s %s %s %s | %s" % row)
        soma = sum(WL_TOT.get(c, 0) for c in WL_CLASSES)
        mortos = WL_TOT.get("morto", 0)
        print("WORKLIST resumo %s total %d, cobrados %d, mortos %d" % (
            " ".join("%s=%d" % (c, WL_TOT.get(c, 0)) for c in WL_CLASSES),
            soma, narrow_judged, mortos))
        if soma != narrow_judged + mortos:
            print("[FAIL] worklist: as classes somam %d ponteiros contra os %d julgados mais %d mortos do corte narrow (%d) — a lista parou de registrar algum, e lista mais curta que a árvore é o único modo de esta ferramenta mentir, porque ela não acusa nada, só deixa de dizer"
                  % (soma, narrow_judged, mortos, narrow_judged + mortos))
            wl_fail = True
    if (biting != cases or accused or narrow_judged < MIN_CHECKS or wide_judged < narrow_judged
            or cut_drift or reg_cut_drift or anchor_cut_drift or resol_cut_drift or lbiting != lcases
            or rbiting != rcases or abiting != acases or anchor_bad
            or hbiting != hcases or cont_acusados or cont_cut_drift or fora_cut_drift
            or cont_n != cov_n
            or dbiting != dcases or dead_n or dead_cut_drift or dead_cov_drift
            or vbiting != vcases or lista_bad or lista_cut_drift or lista_cov_drift
            or lista_reg_drift
            or wl_fail
            or reg_bad or reg is None):
        return 1
    return 0


sys.exit(main())
PYEOF
)"
	ident_code=$?
	printf '%s\n' "$ident_out" | grep -vE '^(IDENTIDADE|LITERAL|REGISTRO|ANCORA|CONT|MORTOS|LISTA) '
	ident_stats="$(printf '%s\n' "$ident_out" | grep '^IDENTIDADE ' | tail -n 1)"
	lit_stats="$(printf '%s\n' "$ident_out" | grep '^LITERAL ' | tail -n 1)"
	anc_stats="$(printf '%s\n' "$ident_out" | grep '^ANCORA ' | tail -n 1)"
	cont_stats="$(printf '%s\n' "$ident_out" | grep '^CONT ' | tail -n 1)"
	mortos_stats="$(printf '%s\n' "$ident_out" | grep '^MORTOS ' | tail -n 1)"
	lista_stats="$(printf '%s\n' "$ident_out" | grep '^LISTA ' | tail -n 1)"
	checks=$((checks + 1))
	if [ -z "$ident_stats" ]; then
		fail "a régua de identidade não devolveu a linha \`IDENTIDADE\` (código $ident_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		ident_narrow=0
		ident_wide=0
		ident_accused=0
		ident_cases=0
		ident_biting=0
		ident_resol=0
		read -r _lab ident_narrow ident_wide ident_accused ident_cases ident_biting ident_resol <<< "$ident_stats"
		checks=$((checks + ident_narrow + ident_wide))
		failures=$((failures + ident_accused))
		if [ "$ident_biting" -ne "$ident_cases" ]; then
			fail "self-test da identidade mordeu $ident_biting de $ident_cases controles — com a régua cega, o zero de acusações não vale nada"
		fi
		if [ "$ident_narrow" -lt "$IDENT_MIN" ] || [ "$ident_wide" -lt "$ident_narrow" ]; then
			fail "identidade julgou pouco (narrow=$ident_narrow com piso $IDENT_MIN, wide=$ident_wide) — um walk quebrado também devolve zero acusações"
		fi
		if [ "$ident_resol" -lt "$RESOL_MIN" ]; then
			fail "resolução de nome abriu $ident_resol alvos contra o piso $RESOL_MIN — o walk que para de resolver devolve zero acusações sem ler a classe que o #116 escondeu"
		fi
		if [ "$ident_accused" -eq 0 ] && [ "$ident_biting" -eq "$ident_cases" ] && [ "$ident_narrow" -ge "$IDENT_MIN" ] && [ "$ident_wide" -ge "$ident_narrow" ] && [ "$ident_resol" -ge "$RESOL_MIN" ]; then
			echo "[ok] $((${ident_narrow} + ${ident_wide})) ponteiros nomeados conferidos linha a linha nos dois cortes (borda em branco acusada), $ident_resol alvos abertos por nome, com os ${ident_cases} controles do self-test mordendo"
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
    print("CAMINHOS %d %d %d %d %d" % (judged, accused, cases, biting, len(dead)))
    if biting != cases or accused or judged < MIN_PATHS:
        return 1
    return 0


sys.exit(main())
PYEOF
)"
	path_code=$?
	printf '%s\n' "$path_out" | grep -v '^CAMINHOS '
	path_stats="$(printf '%s\n' "$path_out" | grep '^CAMINHOS ' | tail -n 1)"
	# O tamanho do registro aceito pela seção 24 sai para fora do `if`: a seção 30 compara
	# este número com o que a seção 23 acha lendo o MESMO arquivo por regras próprias, e
	# `set -u` não perdoa ler variável que o ramo de python ausente nunca atribuiu.
	path_reg=0
	checks=$((checks + 1))
	if [ -z "$path_stats" ]; then
		fail "a régua de caminho não devolveu a linha \`CAMINHOS\` (código $path_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		path_judged=0
		path_accused=0
		path_cases=0
		path_biting=0
		path_reg=0
		read -r _lab path_judged path_accused path_cases path_biting path_reg <<< "$path_stats"
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
# 27) CAMINHO DE COMANDO: o que se cola num terminal tem que existir na árvore.
#
# A seção 24 lê a PROSA e só julga `.md`, porque estender aquele corpo a `.py` e
# `.sh` gerou ruído (caminho absoluto de container, basename que a própria prosa
# declara morto). Um comando dentro de bloco ``` é outra coisa: não é citação, é
# instrução, e quem cola a linha no terminal recebe "No such file or directory".
# Foi exatamente o que a passada achou em `docs/adding-an-item.md`, um doc que
# nenhuma régua de caminho lia porque não está no corpo das specs vivas: a receita
# manda gerar os `.translation` com `python3 tools/i18n/extract_i18n.py`, e a
# ferramenta está em `tools/extract_i18n.py`.
#
# O que é julgado: token com barra e extensão de arquivo, DENTRO de bloco de
# código, nos docs que alguém executa (README, `docs/*.md`, `docs/development/*.md`,
# `deploy/*.md`). Três filtros, cada um com controle no self-test: caminho
# absoluto (`/app/server.py` — o token existe, mas não é relativo à raiz), `res://`
# (caminho de engine, não de disco) e o que está fora de bloco de código (prosa é
# trabalho da seção 24, e sobrepor as duas é duplicar veredito).
#
# Piso de volume: 40 com 76 medidos nesta passada (19 docs de receita). O corpo é
# pequeno de propósito, então o piso existe só para uma coisa: um walk que parou de
# ler os docs devolve zero acusações tão bem quanto uma régua que acha tudo.
# ---------------------------------------------------------------------------
CODE_DOCS=""
for f in README.md docs/*.md docs/development/*.md deploy/*.md; do
	[ -f "$f" ] && CODE_DOCS="$CODE_DOCS $f"
done
CODE_MIN=40
if [ -z "$CODE_DOCS" ]; then
	checks=$((checks + 1))
	fail "nenhum doc de receita foi lido pela régua de caminho de comando — ela virou no-op"
elif ! command -v "$PY" >/dev/null 2>&1; then
	checks=$((checks + 1))
	fail "python3 indisponível (PYTHON=$PY) — a régua de caminho de comando não rodou; ausência conta como falha, não como pulo"
else
	code_out="$(CODE_MIN="$CODE_MIN" "$PY" - "$PWD" $CODE_DOCS <<'PYEOF' 2>&1

# -*- coding: utf-8 -*-
"""Caminho dentro de bloco de codigo: o que se cola no terminal tem que existir.

Secao 27 de scripts/check_doc_drift.sh.
"""
import os
import re
import sys

# O piso é um só, e mora no shell (`CODE_MIN`): duas metades da mesma régua com o
# mesmo número escrito à mão é a fresta pela qual uma delas apodrece.
MIN_JUDGED = int(os.environ.get("CODE_MIN", "0"))

EXT = r"(?:py|sh|mjs|js|ts|gd|json|sql|ya?ml|csv|toml|ini|conf|txt|env|html|css)"
# Um ou mais segmentos seguidos do nome com extensao. O `(?:.../)+` e obrigatorio:
# com so um segmento o `tools/i18n/extract_i18n.py` da receita escapa inteiro da
# regula, que e justamente o caminho morto que a secao veio caçar. O lookbehind
# deixa de fora caminho absoluto (`/app/server.py`) e `res://` — nem um nem outro
# sao relativos à raiz.
TOKEN = re.compile(r"(?<![\w/.-])((?:\./)?(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+\." + EXT + r")\b")
FENCE = re.compile(r"^\s*(```|~~~)")


def extract(line):
    """Os caminhos de arquivo que a linha de comando cita."""
    out = []
    for match in TOKEN.finditer(line):
        tok = match.group(1)
        if "://" in tok or "*" in tok or "<" in tok or ">" in tok:
            continue
        out.append(tok)
    return out


def accuse(tok, exists):
    """Verdadeiro quando o caminho citado nao esta na arvore."""
    if exists(tok):
        return False
    if tok.startswith("./"):
        return not exists(tok[2:])
    return True


def scan(root, files):
    def exists(path):
        return os.path.isfile(os.path.join(root, path[2:] if path.startswith("./") else path))

    judged = 0
    accused = 0
    for fn in files:
        inside = False
        with open(fn, encoding="utf-8", errors="replace") as handle:
            for n, line in enumerate(handle.read().split("\n"), 1):
                if FENCE.match(line):
                    inside = not inside
                    continue
                if not inside:
                    continue
                for tok in extract(line):
                    judged += 1
                    if accuse(tok, exists):
                        accused += 1
                        print("[FAIL] caminho de comando: %s:%d cita `%s` - nao existe na arvore"
                              % (fn, n, tok))
    return judged, accused


def selftest():
    """Cada filtro e o veredito tem que poder falhar; senao o zero nao e noticia."""
    have = {"scripts/test.sh", "tools/extract_i18n.py", "tests/run_idle_tests.gd"}

    def exists(path):
        return path in have

    # (rotulo, linha, caminhos que a extracao tem que enxergar, algum deles e morto?)
    cases = [
        ("caminho morto dentro de bloco e acusado",
         "python3 tools/i18n/extract_i18n.py", ["tools/i18n/extract_i18n.py"], True),
        ("caminho vivo passa", "bash scripts/test.sh all", ["scripts/test.sh"], False),
        ("./ e so ruido de shell, nao muda o veredito",
         "./scripts/test.sh idle", ["./scripts/test.sh"], False),
        ("caminho absoluto de container nao e da raiz",
         "COPY /app/server.py /srv/", [], False),
        ("res:// e caminho de engine, nao de disco",
         'load("res://sources/x.gd")', [], False),
        ("glob de receita nao e caminho", "cat docs/adding-a-*.md", [], False),
        ("placeholder <nome>.py nao e caminho", "python3 tools/<nome>.py", [], False),
        ("comando com argumentos nao inventa caminho",
         "godot --headless -s tests/run_idle_tests.gd",
         ["tests/run_idle_tests.gd"], False),
    ]
    biting = 0
    for label, line, want, expect_dead in cases:
        got = extract(line)
        good = got == want
        if good and want:
            good = any(accuse(tok, exists) for tok in want) == expect_dead
        if not good:
            print("[FAIL] self-test do comando: %s (extraiu %r, veredito esperado %s)"
                  % (label, got, "morto" if expect_dead else "vivo"))
        else:
            biting += 1
    return biting, len(cases)


def main():
    root = sys.argv[1]
    files = sys.argv[2:]
    biting, cases = selftest()
    present = [f for f in files if os.path.isfile(f)]
    judged, accused = scan(root, present)
    print("caminhos de comando: %d em %d docs de receita, %d acusacoes, self-test %d/%d mordendo"
          % (judged, len(present), accused, biting, cases))
    print("CODEPATHS %d %d %d %d" % (judged, accused, cases, biting))
    if biting != cases or accused or judged < MIN_JUDGED:
        return 1
    return 0


sys.exit(main())
PYEOF
)"
	code_code=$?
	printf '%s\n' "$code_out" | grep -v '^CODEPATHS '
	code_stats="$(printf '%s\n' "$code_out" | grep '^CODEPATHS ' | tail -n 1)"
	checks=$((checks + 1))
	if [ -z "$code_stats" ]; then
		fail "a régua de caminho de comando não devolveu a linha \`CODEPATHS\` (código $code_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		code_judged=0
		code_accused=0
		code_cases=0
		code_biting=0
		read -r _lab code_judged code_accused code_cases code_biting <<< "$code_stats"
		checks=$((checks + code_judged))
		failures=$((failures + code_accused))
		if [ "$code_biting" -ne "$code_cases" ]; then
			fail "self-test do caminho de comando mordeu $code_biting de $code_cases controles — com a régua cega, o zero de acusações não vale nada"
		fi
		if [ "$code_judged" -lt "$CODE_MIN" ]; then
			fail "caminho de comando julgou pouco ($code_judged com piso $CODE_MIN) — um walk que parou de ler os docs também devolve zero acusações"
		fi
		if [ "$code_accused" -eq 0 ] && [ "$code_biting" -eq "$code_cases" ] && [ "$code_judged" -ge "$CODE_MIN" ]; then
			echo "[ok] ${code_judged} caminhos de comando conferidos contra a árvore, com os ${code_cases} controles do self-test mordendo"
		fi
	fi
fi


# ---------------------------------------------------------------------------
# 26) NUMERAL DE REGISTRO: a contagem que a prosa afirma é lida do fonte.
#
# As três réguas acima conferem ponteiros: o que mora na linha, o nome citado, o
# caminho existindo. Nenhuma delas vê a frase que não cita arquivo nenhum e mesmo
# assim afirma um fato de código — "os 11 gates de estrutura". Esta classe nasceu
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

# ---------------------------------------------------------------------------
# 28) ÂNCORA de ponteiro (#124): `arquivo:@simbolo`, julgado pelo BLOCO da declaração.
#
# O custo recorrente deste repo não era a medição, era a marreta: `arquivo:NN` é
# verdadeiro até a linha de cima ganhar um comentário. Medido na rodada que originou
# esta seção — `tests/benchmarks.gd` cresceu de 400 para 690 linhas e isso, sozinho,
# sujou seis ponteiros que nenhuma régua acusava (a cláusula vazia não nomeia símbolo
# nenhum, então "linha existe e tem texto" bastava). Cada reparo foi uma caçada; a
# âncora é uma escrita.
#
# O veredito mora em `anchorverdict` no heredoc da seção 23 e não afrouxa nada do que
# a linha cobrava — cobra a mais: o símbolo tem de ser declarado NO ARQUIVO (zero ou
# dois é acusação, não escolha), tem de ser NOMEADO NA CLÁUSULA (senão a âncora só
# prova que o nome existe, que é a mentira que a régua de identidade já caçava) e todo
# literal pinado pela frase tem de morar DENTRO do bloco. Arquivo sem modelo de
# declaração (.md, .json, .conf) é acusado em vez de ficar mudo: âncora onde ninguém
# sabe onde começa o bloco é linha disfarçada.
#
# Diferente do `arquivo:NN`, a âncora também é julgada nos registros datados
# (CHANGELOG, progress, ROADMAP_COMERCIAL, BLIND_JUDGE_PROTOCOL): o que é história
# ali é o número, e um número gravado em 20 de setembro não deve ser reescrito; mas
# uma âncora que hoje aponta para outro lugar mente do mesmo jeito, e o walk da seção
# 23 agora entra nesses arquivos só por causa disso.
#
# O ratchet é de um sentido só: ANCHOR_MIN sobe, LINE_MAX desce. Nenhum dos dois é
# meta — é o preço de reescrever a marreta em vez de pagá-la.
# ---------------------------------------------------------------------------
if ! command -v "$PY" >/dev/null 2>&1; then
	checks=$((checks + 1))
	fail "python3 indisponível (PYTHON=$PY) — a régua de âncora não rodou; ausência conta como falha, não como pulo"
else
	checks=$((checks + 1))
	if [ -z "$anc_stats" ]; then
		fail "a régua de âncora não devolveu a linha \`ANCORA\` (código $ident_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		anc_n=0
		anc_accused=0
		anc_lines=0
		anc_cases=0
		anc_biting=0
		anc_fora_n=0
		anc_fora_lin=0
		anc_fora_anc=0
		read -r _lab anc_n anc_accused anc_lines anc_cases anc_biting anc_fora_n anc_fora_lin anc_fora_anc <<< "$anc_stats"
		checks=$((checks + anc_n + anc_lines))
		failures=$((failures + anc_accused))
		if [ "$anc_biting" -ne "$anc_cases" ]; then
			fail "self-test da âncora mordeu $anc_biting de $anc_cases controles — com a régua cega, nenhuma âncora verde vale nada"
		fi
		if [ "$anc_n" -lt "$ANCHOR_MIN" ]; then
			fail "âncora em $anc_n com piso $ANCHOR_MIN — âncora que voltou a ser linha, ou walk que parou de ler os registros datados"
		fi
		if [ "$anc_lines" -gt "$LINE_MAX" ]; then
			fail "$anc_lines ponteiros \`arquivo:linha\` contra o teto $LINE_MAX — o ratchet só desce; cada linha escrita é marreta comprada de novo"
		fi
		# O recorte tem de ser DITO e mordido, não só comentado: `arquivo:NN` dentro de registro
		# datado é isento, `arquivo:@simbolo` dentro dele é cobrado. Provado em mutação hoje:
		# subir o atalho para cima do laço de âncora acusa no total (148 → 133), mas o total diz
		# "faltam âncoras" — este piso é o que diz QUAL recorte, e por isso o número nasce no
		# laço que cobra, não no shape da linha.
		if [ "$anc_fora_n" -lt 2 ]; then
			fail "só $anc_fora_n registro(s) datado(s) na varredura — a lista de SKIP_NAMES parou de casar com a árvore, e ninguém isenta (nem cobra) história"
		fi
		if [ "$anc_fora_anc" -lt "$ANCHOR_FORA_MIN" ]; then
			fail "$anc_fora_anc âncoras cobradas dentro dos registros datados, piso $ANCHOR_FORA_MIN — ou o atalho de registro subiu para cima do laço de âncora (história voltou a não ser lida por ninguém), ou a história foi reescrita sem âncora"
		fi
		if [ "$anc_accused" -eq 0 ] && [ "$anc_biting" -eq "$anc_cases" ] && [ "$anc_n" -ge "$ANCHOR_MIN" ] && [ "$anc_lines" -le "$LINE_MAX" ] && [ "$anc_fora_n" -ge 2 ] && [ "$anc_fora_anc" -ge "$ANCHOR_FORA_MIN" ]; then
			echo "[ok] $anc_n âncoras \`arquivo:@simbolo\` julgadas pelo bloco da declaração, sobre $anc_lines ponteiros de linha (teto $LINE_MAX), com os $anc_cases controles do self-test mordendo"
			echo "[ok] recorte: $anc_fora_n registros datados lidos, $anc_fora_lin ponteiros de linha poupados de cobrança (aqui eles não são nem lidos) e $anc_fora_anc âncoras cobradas neles — é este o número que o gémeo GDScript tem de ler, classe por classe, e os dois censos não são comparáveis porque o corpo dela varre mais tipos de arquivo"
		fi
	fi
	# ---------------------------------------------------------------------------
	# 29) CONTINUAÇÃO de ponteiro: o `:NN` que herda o arquivo do ponteiro anterior.
	#
	# A classe nasceu da passada que ensinou o bash a resolver nome nu: consertando os
	# ponteiros, três deles tinham sido escritos como `` `nome.ext:NN` … e `:NN` `` —
	# segunda citação do mesmo arquivo, sem arquivo. `PTR`, `ANYCITE` e
	# `ANCHOR` exigem o `nome.ext` antes dos dois-pontos, então o número era lido por
	# ninguém: nem a régua de linha, nem a de literal, nem a de caminho. O censo é
	# medido pelo próprio braço abaixo e impresso no human line; o que se decidiu aqui,
	# com número, é que só a forma ENTRE backticks é lida: `:NN` solto no texto tem
	# 3291 ocorrências na árvore e quase todas são razão (`3:1`), porta 9400 ou
	# hora (`22:27`) — cobrar a forma sem backtick seria acusar prosa inocente, que é
	# a doença que o #116 denuncia.
	#
	# A herança é do último `arquivo:NN` ou `arquivo:@simbolo` ANTERIOR NA MESMA LINHA.
	# Não herda da linha de cima: uma régua que atravessa a quebra de linha passa a
	# acusar prosa honesta conforme o formatador resolveu quebrar a frase, e é o
	# #116 de novo. Sem antecedente, o `:NN` é órfão e é ACUSADO — a alternativa é
	# adivinhar o arquivo, e adivinhação em gate é manto.
	#
	# Cobertura (o censo abaixo) e self-test próprio, porque a régua nova tem três
	# modos de mentir verde: não reconhecer a continuação nenhuma (walk mudo),
	# reconhecer trocando os grupos do regex — `CONTPTR` numera a linha no grupo 1 e
	# `PTR` no grupo 2, e um off-by-one julgaria o arquivo como se fosse o número — e
	# apagar a tabela de controles, que deixa `biting == cases` verde com 0 de 0. O
	# nível (`CONT_MIN`) foi trocado por diferença contra o censo independente da 25b:
	# os dois modos de sumir continuam acusados, e o reparo do #124 — converter um
	# ponteiro em âncora — deixa de ser contado como um deles.
	# ---------------------------------------------------------------------------
	checks=$((checks + 1))
	if [ -z "$cont_stats" ]; then
		fail "a régua de continuação não devolveu a linha \`CONT\` (código $ident_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		cont_j=0
		cont_a=0
		cont_cases=0
		cont_biting=0
		cont_seen=0
		cont_orfas=0
		cont_cov=0
		cont_spared=0
		read -r _lab cont_j cont_a cont_cases cont_biting cont_seen cont_orfas cont_cov cont_spared <<< "$cont_stats"
		checks=$((checks + cont_j))
		failures=$((failures + cont_a))
		if [ "$cont_biting" -ne "$cont_cases" ]; then
			fail "self-test da continuação mordeu $cont_biting de $cont_cases controles — com a herança quebrada, o \`:NN\` vira número sem arquivo e o zero de acusações não vale nada"
		fi
		if [ "$cont_cases" -eq 0 ]; then
			fail "a tabela de controles da continuação está vazia (0 de 0) — \`biting == cases\` é verde vazio sem controle, e era o piso de nível que tapava este buraco"
		fi
		if [ "$cont_seen" -ne "$cont_cov" ]; then
			fail "cobertura da continuação: o censo independente acha $cont_cov tokens no escopo lido e o walk leu $cont_seen — sumiram $((cont_cov - cont_seen)), e é exatamente o que o piso de nível deixava passar enquanto o saldo ficasse acima de 8"
		fi
		if [ "$cont_a" -eq 0 ] && [ "$cont_biting" -eq "$cont_cases" ] && [ "$cont_cases" -gt 0 ] && [ "$cont_seen" -eq "$cont_cov" ]; then
			echo "[ok] $cont_seen ponteiros de continuação \`:NN\` lidos de $cont_cov no censo independente (0 sem testemunha), $cont_j julgados pelo arquivo herdado nos dois cortes (órfão é acusação), $cont_spared poupados pelo recorte de registro datado, com os $cont_cases controles do self-test mordendo"
		fi
	fi
	# ---------------------------------------------------------------------------
	# 30) PONTEIRO MORTO: o `arquivo:NN` cujo alvo não resolve em lugar nenhum.
	#
	# A porta dos invisíveis tinha três batentes e só dois fechados. A âncora já acusava
	# o arquivo que não existe (`cita %s e o arquivo não existe`), o caminho de doc já
	# acusava o `.md` citado que sumiu (seção 24), e o `arquivo:NN` — a forma mais
	# copiada em incidente de madrugada — saía do walk por `if tl is None: continue` sem
	# julgamento nenhum. Medido na passada que abriu este buraco: sete tokens sem alvo na
	# árvore, seis deles prosa que se deixava ler como evidência. Quem cola `abra
	# docs/x.md:NN` num arquivo que foi removido não recebe erro; recebe a tela vazia, e a
	# régua dizia verde.
	#
	# A exceção é o registro `scripts/dead_paths.txt`, lido por DUAS réguas: esta, que
	# poupa o acusado, e a seção 24, que valida o motivo e caça a entrada que voltou a
	# existir. É por isso que o tamanho do registro sai nas duas linhas de máquina e a
	# igualdade é cerca na bash: `deadset` daqui reimplementa as quatro regras de
	# `read_registry` de lá, e cópia que apodrece em silêncio é exatamente a doença que
	# este gate existe para ver. Divergir entre os dois é ou a regra de parse tendo
	# mudado de um lado, ou o registro ganhando entrada duplicada.
	#
	# Sem piso de nível nos mortos (a lição do #137: piso acusa progresso). O anti-vazio
	# é a igualdade com `deadcensus`, um walk que não chama `deadjudge`: apagar o braço
	# inteiro leva os dois números a zero *dentro* do veredito, e é o censo separado que
	# fica dizendo 7.
	# ---------------------------------------------------------------------------
	checks=$((checks + 1))
	if [ -z "$mortos_stats" ]; then
		fail "a régua do ponteiro morto não devolveu a linha \`MORTOS\` (código $ident_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		dead_a=0
		dead_sp=0
		dead_reg=0
		dead_cases=0
		dead_biting=0
		dead_drift=0
		dead_cont=0
		dead_seen=0
		dead_cov=0
		read -r _lab dead_a dead_sp dead_reg dead_cases dead_biting dead_drift dead_cont dead_seen dead_cov <<< "$mortos_stats"
		checks=$((checks + dead_a + dead_sp))
		failures=$((failures + dead_a))
		if [ "$dead_biting" -ne "$dead_cases" ]; then
			fail "self-test do ponteiro morto mordeu $dead_biting de $dead_cases controles — com o julgamento cego, poupado e acusado são o mesmo número e o zero de acusações não vale nada"
		fi
		if [ "$dead_cases" -eq 0 ]; then
			fail "a tabela de controles do ponteiro morto está vazia (0 de 0) — \`biting == cases\` é verde vazio sem controle, e o registro sem controle próprio é licença para poupar tudo"
		fi
		if [ "$dead_drift" -ne 0 ]; then
			fail "ponteiro morto divergiu entre os dois cortes — o índice ou o registro mudou no meio do run e nenhum dos dois censos vale"
		fi
		if [ "$dead_cov" -ne 0 ]; then
			fail "cobertura do ponteiro morto: o veredito viu $((dead_a + dead_sp - dead_cont)) tokens sem alvo e o censo independente acha $dead_seen no mesmo escopo — o braço parou de olhar, e é a única forma deste gate ficar verde com ponteiros mortos na árvore"
		fi
		if [ "$dead_reg" -ne "$path_reg" ]; then
			fail "as duas réguas que leem \`scripts/dead_paths.txt\` aceitam números diferentes: a seção 23 conta $dead_reg caminho(s), a seção 24 conta $path_reg — ou as quatro regras de parse divergiram, ou o registro ganhou entrada duplicada, e nos dois casos a exceção passou a valer uma coisa em cada régua"
		fi
		if [ "$dead_a" -eq 0 ] && [ "$dead_biting" -eq "$dead_cases" ] && [ "$dead_cases" -gt 0 ] && [ "$dead_drift" -eq 0 ] && [ "$dead_cov" -eq 0 ] && [ "$dead_reg" -eq "$path_reg" ]; then
			echo "[ok] $((dead_a + dead_sp)) ponteiros de linha sem alvo na árvore, todos julgados ($dead_a acusados, $dead_sp poupados pelo registro de $dead_reg caminho(s), $dead_cont deles continuação) contra $dead_seen no censo independente, com os $dead_cases controles do self-test mordendo"
		fi
	fi
	# ---------------------------------------------------------------------------
	# 31) PONTEIRO COM VÍRGULA: `arquivo:12,13-15` afirma N linhas de um golpe.
	#
	# É a forma que a marreta de #124 empurra a prosa a escrever quando uma frase precisa
	# de quatro sítios: um backtick em vez de quatro. E porque era nova, nenhum braço a
	# lia — `PTR` exige o backtick logo depois do número, então `12,13` não casava nem pela
	# identidade nem pela continuação, e o walk saia pela mesma porta dos invisíveis que a
	# seção 30 fechou por outro batente. Medido antes de escrever a régua: nove citações
	# assim no corpus vivo, todas em arquivo que existe, e nenhum dos números julgado.
	#
	# O que se cobra é o que a frase promete, número a número: o alvo resolve (ou está no
	# registro de caminhos mortos, a mesma licença da seção 30, lida pela mesma função), a
	# borda cabe no arquivo e a linha citada não é branca. O meio do intervalo não é
	# cobrado porque o `arquivo:NN-NN` simples também não cobra — régua mais dura para a
	# forma barata seria exatamente o incentivo para voltar a escrever cinco backticks, e
	# o objetivo aqui era matar o custo de ponteiro, não recriá-lo. A cláusula não entra:
	# uma frase fazendo quatro afirmações não é decomponível pelo parser de oração, e
	# inventar um recorte para ela daria veredito de uma linha para a promessa de outra.
	#
	# Três cercas, todas de escopo, nunca de nível (a lição do #137): igualdade entre os
	# dois cortes, igualdade com `listacensus` — um walk que não abre intervalo e não
	# conhece registro — e igualdade do recorte de `SKIP_NAMES` entre veredito e censo,
	# que é onde a isenção cresce sozinha. Mais uma mesa de treze controles, três deles
	# provando que `PTR` e `LISTPTR` não comem o mesmo token: sem esses, a cobertura passaria
	# a somar o mesmo número duas vezes e ainda dar igualdade.
	# ---------------------------------------------------------------------------
	checks=$((checks + 1))
	if [ -z "$lista_stats" ]; then
		fail "a régua do ponteiro com vírgula não devolveu a linha \`LISTA\` (código $ident_code, python=$PY) — sem contagem, o que ela viu não pode entrar no total"
	else
		lista_ln=0
		lista_num=0
		lista_morto=0
		lista_poup=0
		lista_rec=0
		lista_acus=0
		lista_corte=0
		lista_cob=0
		lista_censo=0
		lista_censo_n=0
		lista_censo_r=0
		lista_cases=0
		lista_biting=0
		read -r _lab lista_ln lista_num lista_morto lista_poup lista_rec lista_acus \
			lista_corte lista_cob lista_censo lista_censo_n lista_censo_r \
			lista_cases lista_biting <<< "$lista_stats"
		checks=$((checks + lista_num + lista_morto))
		failures=$((failures + lista_acus))
		if [ "$lista_biting" -ne "$lista_cases" ]; then
			fail "self-test do ponteiro com vírgula mordeu $lista_biting de $lista_cases controles — sem a mesa, parser e veredito podem devolver o que quiserem e o zero de acusações não vale nada"
		fi
		if [ "$lista_cases" -eq 0 ]; then
			fail "a tabela de controles do ponteiro com vírgula está vazia (0 de 0) — \`biting == cases\` é verde vazio sem controle"
		fi
		if [ "$lista_corte" -ne 0 ]; then
			fail "ponteiro com vírgula divergiu entre os dois cortes — a forma não depende do recorte de cláusula, e divergir é o braço tendo parado no meio de um dos dois passes"
		fi
		if [ "$lista_cob" -ne 0 ]; then
			fail "cobertura do ponteiro com vírgula: o veredito abriu $lista_ln listas e $((lista_num + lista_morto)) números e o censo independente, que não confere linha nenhuma, acha $lista_censo listas e $lista_censo_n números no mesmo escopo — o braço parou de olhar, e apagar o braço inteiro leva os dois números a zero dentro dele"
		fi
		if [ "$lista_rec" -ne "$lista_censo_r" ]; then
			fail "recorte da vírgula: o veredito poupou $lista_rec números dentro dos registros datados e o censo, que não julga nada, conta $lista_censo_r no mesmo recorte — as duas leituras de \`SKIP_NAMES\` deixaram de ser a mesma isenção, que é o modo de a licença crescer sem que ninguém a escreva"
		fi
		if [ "$lista_acus" -eq 0 ] && [ "$lista_biting" -eq "$lista_cases" ] && [ "$lista_cases" -gt 0 ] && [ "$lista_corte" -eq 0 ] && [ "$lista_cob" -eq 0 ] && [ "$lista_rec" -eq "$lista_censo_r" ]; then
			echo "[ok] $lista_ln ponteiros com vírgula julgados número a número ($((lista_num + lista_morto)) números, $lista_acus acusados, $lista_morto dentro de alvo que não resolve dos quais $lista_poup poupados pelo registro), $lista_rec números poupados dentro dos registros datados, contra $lista_censo listas e $lista_censo_n números no censo independente, com os $lista_cases controles do self-test mordendo"
		fi
	fi
fi
echo "== DOC DRIFT: $checks checks, $failures failures =="
exit "$failures"
