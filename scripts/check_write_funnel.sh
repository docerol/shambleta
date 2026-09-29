#!/usr/bin/env bash
# WorkOrder #91 — census gate do funil de escrita.
#
# `deploy/SCALING.md` §7 afirma que a `queryMutex` de `sources/sql/SQL.gd:7` é o
# funil de escrita do processo. Isso só é verdade para quem passa pelas portas de
# `SQLService` (`Query`, `QueryBindings`, `ExecuteBindings`, `Transaction`). Um
# `db.update_rows(...)` / `db.insert_row(...)` / `db.delete_rows(...)` cru, pegado
# em `Launcher.SQL.db`, escapa da mutex E do contador de round trips — e o addon
# SQLite ainda faz BEGIN/END próprio dentro de uma `Transaction()` já aberta, que é
# exatamente o defeito que o grito de auditoria A de `SQL.Transaction` nomeia.
#
# A régua, no estilo da de `presence_session` (§7: um símbolo só pode aparecer onde
# foi sancionado): nenhuma escrita `.db.` crua em `sources/` fora da allowlist
# abaixo, e cada arquivo da allowlist tem que PROVAR que escreve dentro de
# transação — a prova é textual (o mesmo arquivo abre `Transaction(`) e é conferida
# no arquivo real, não no comentário deste script.
#
# Controles plantados (doutrina da casa: régua que não morde é régua sem efeito):
# três fixtures passam pelo MESMO predicado do produto, num diretório temporário —
# writer transacional (0 acusações), writer cru novo fora da allowlist (1), entry
# da allowlist que parou de abrir transação (1). Sem isso, "0 acusações" pode ser
# um predicado que não acha nada.
set -uo pipefail

CHECKS=0
FAILURES=0
ROOT="sources"

ok()  { CHECKS=$((CHECKS + 1)); printf '[ok]   %s\n' "$1"; }
bad() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '[FAIL] %s\n' "$1"; printf '       esperado: %s\n       visto:    %s\n' "$2" "$3"; }

# Caminhos RELATIVOS a `sources/`. Motivo de cada entrada:
#   sql/SQL.gd                — é o FUNIL: dono da `queryMutex` e de `Transaction()`.
#                               As 83 escritas cruas dele são as portas (UpdateRowsRaw,
#                               DeleteRowsRaw, AddAccount, ...) e a mutex é pega antes.
#   economy/*.gd, idle/*.gd   — domínios que só chamam `db.*` dentro do lambda de um
#                               `Launcher.SQL.Transaction()` próprio (mesmo mutex, mesmo
#                               contador, mesmo commit do estado que o ledger espelha).
WRITE_ALLOWLIST="
sql/SQL.gd
economy/AuctionHouseService.gd
economy/CheckoutService.gd
economy/EconomyKernel.gd
economy/GuildService.gd
economy/ItemForgeService.gd
economy/SeasonService.gd
economy/ShopService.gd
economy/TelemetryService.gd
idle/StreakService.gd
"

# Escrita crua = insert/update/delete/execute/query com o handle `db` (ou seu
# apelido local `dbNode`). `select_rows` é leitura e fica fora: o que fura a mutex
# e o contador é ESCRITA.
WRITE_RE='\b[A-Za-z_][A-Za-z0-9_]*\.db\.(insert_row|update_rows|delete_rows|execute|query_with_bindings|query)\(|\bdbNode\.(insert_row|update_rows|delete_rows|execute|query_with_bindings|query)\(|(^|[^.[:alnum:]_])db\.(insert_row|update_rows|delete_rows|execute|query_with_bindings|query)\('

# Forma pesquisável da allowlist: a lista acima é multi-linha, e `*" $rel "*`
# num string com quebras de linha NÃO casa nada — o gate viraria verde por
# inanição do próprio grep. Colapsar em espaços é o que faz o `case` abaixo ter
# significado.
ALLOW_FLAT=" $(printf '%s ' $WRITE_ALLOWLIST)"

# ------------------------------------------------------------------ predicado
# $1 = diretório raiz da varredura (a estrutura de `sources/` dele).
# Imprime "FORA-DA-ALLOWLIST <rel>:<linha>" ou "SEM-TRANSACAO <rel>:<linha>".
scan_writes() {
	local root="$1"
	[ -d "$root" ] || return 0
	grep -rnE "$WRITE_RE" "$root" --include='*.gd' 2>/dev/null | while IFS= read -r hit; do
		local file="${hit%%:*}"
		local rest="${hit#"$file":}"
		local line="${rest%%:*}"
		local rel="${file#"$root/"}"
		case "$ALLOW_FLAT" in
			*" $rel "*) ;;
			*) printf 'FORA-DA-ALLOWLIST %s:%s\n' "$rel" "$line"; continue ;;
		esac
		if ! grep -q 'Transaction(' "$file"; then
			printf 'SEM-TRANSACAO %s:%s\n' "$rel" "$line"
		fi
	done
}

HITS="$(scan_writes "$ROOT")"
OUTSIDE="$(printf '%s' "$HITS" | grep -c '^FORA-DA-ALLOWLIST' || true)"
NOTX="$(printf '%s' "$HITS" | grep -c '^SEM-TRANSACAO' || true)"
# Escritas sancionadas = TODAS as Matches de escrita crua em sources/ (não só as
# acusações): é o número que o §7 do SCALING cita como tamanho do funil.
SANCTIONED="$(grep -rE "$WRITE_RE" "$ROOT" --include='*.gd' 2>/dev/null | grep -c . || true)"
if [ "$OUTSIDE" -eq 0 ] && [ "$NOTX" -eq 0 ]; then
	ok "nenhuma escrita .db. crua fora dos writers transacionais da allowlist ($SANCTIONED escritas conferidas em $ROOT/)"
else
	bad "escrita crua vazando do funil" "0 acusacoes" "$(printf '%s\n' "$HITS" | head -12)"
fi

# A allowlist também tem que ser VERDADE: entrada sem escrita crua no arquivo
# listado é autorização sobrando (e arquivo que sumiu é régua lendo o vazio).
ENTRY_STALE=""
for entry in $WRITE_ALLOWLIST; do
	if [ ! -f "$ROOT/$entry" ]; then
		ENTRY_STALE="$ENTRY_STALE arquivo-ausente:$entry"
		continue
	fi
	if [ -z "$(grep -nE "$WRITE_RE" "$ROOT/$entry" 2>/dev/null)" ]; then
		ENTRY_STALE="$ENTRY_STALE sem-escrita:$entry"
	fi
done
if [ -z "$ENTRY_STALE" ]; then
	ok "toda entrada da allowlist tem escrita crua de verdade no arquivo listado"
else
	bad "allowlist com entrada morta" "cada entrada com >= 1 escrita .db." "$ENTRY_STALE"
fi

# O funil nomeado na doc existe: verde aqui não pode conviver com a `queryMutex`
# renomeada e o §7 do SCALING voltando a ser prosa inventada.
if grep -q 'queryMutex : Mutex' sources/sql/SQL.gd; then
	ok "a queryMutex citada pelo SCALING (sources/sql/SQL.gd:7) existe no fonte"
else
	bad "queryMutex nomeada na doc nao esta no fonte" "var queryMutex : Mutex" "ausente"
fi

# WorkOrder #91, segunda perna: toda linha de `ledger_transaction` nasce dentro de
# uma transação. O `GrantItem` do kernel escrevia no handle cru segurando só o
# mutex de shard, então o lançamento cometia separado do estado que ele espelha.
LEDGER_RE='INSERT INTO ledger_transaction'
LEDGER_FILES="$(grep -rlE "$LEDGER_RE" $ROOT --include='*.gd' 2>/dev/null | sed "s|^$ROOT/||" | sort | tr '\n' ' ')"
LEDGER_BAD=""
for f in $LEDGER_FILES; do
	grep -qE 'Transaction\(|ExecNoLock' "$ROOT/$f" || LEDGER_BAD="$LEDGER_BAD $f"
done
if [ -z "$LEDGER_BAD" ]; then
	ok "todo arquivo que insere em ledger_transaction abre transacao (ou usa ExecNoLock dentro dela): $LEDGER_FILES"
else
	bad "linha de ledger nascida fora de transacao" "nenhum arquivo sem Transaction()" "$LEDGER_BAD"
fi
# Control plantado: arquivo de ledger SEM transacao tem que ser acusado.
D="$(mktemp -d)"; mkdir -p "$D/economy"
printf 'extends RefCounted\nfunc BadRow(a : int) -> bool:\n\treturn db.query_with_bindings("INSERT INTO ledger_transaction (account_id) VALUES (?);", [a])\n' > "$D/economy/Ledgerless.gd"
lf="$(grep -rlE "$LEDGER_RE" "$D" --include='*.gd' 2>/dev/null | sed "s|^$D/||" | sort | tr '\n' ' ')"
badled=""
for f in $lf; do
	grep -qE 'Transaction\(|ExecNoLock' "$D/$f" || badled="$badled $f"
done
if [ "$badled" = " economy/Ledgerless.gd" ]; then
	ok "control: insercao de ledger plantada sem Transaction() e acusada"
else
	bad "control: regua de ledger nao mordeu" "economy/Ledgerless.gd acusada" "${badled:-nenhuma}"
fi
rm -rf "$D"

# ------------------------------------------------------------------ fixtures
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkfix() {
	local d="$FIX/$1"; mkdir -p "$d/sql" "$d/economy"
	cat > "$d/sql/SQL.gd" <<'GD'
extends RefCounted
func Transaction(callable : Callable) -> bool:
	return callable.call()
func AddRow(t : String, d : Dictionary) -> bool:
	return db.insert_row(t, d)
GD
	printf '%s' "$d"
}

# (1) Writer transacional: sancionado, NAO pode ser acusado.
D="$(mkfix clean)"
cat > "$D/economy/ShopService.gd" <<'GD'
extends RefCounted
func DoThing(id : int) -> bool:
	return sql.Transaction(func() -> bool:
		return sql.db.update_rows("thing", "id = %d" % id, {"n" = 1})
	)
GD
n1="$(scan_writes "$D" | grep -c . || true)"
if [ "$n1" -eq 0 ]; then ok "control: writer dentro de Transaction() nao e acusado"; else bad "control: writer transacional plantado foi acusado" "0 acusacoes" "$n1"; fi

# (2) Writer cru novo, fora da allowlist: TEM que ser acusado (a negativa que
#     morde quando alguém abre um serviço novo escrevendo no handle direto).
D="$(mkfix raw)"
cat > "$D/economy/NewService.gd" <<'GD'
extends RefCounted
func DoBadThing(id : int) -> bool:
	return Launcher.SQL.db.update_rows("thing", "id = %d" % id, {"n" = 1})
GD
n2="$(scan_writes "$D" | grep -c '^FORA-DA-ALLOWLIST' || true)"
if [ "$n2" -eq 1 ]; then ok "control: escrita crua nova fora da allowlist e acusada"; else bad "control: negativa plantada nao mordeu" "1 acusacao" "$n2"; fi

# (3) Entry DA allowlist que parou de abrir transação: o arquivo sancionado
#     continua na lista, mas sem `Transaction(` ele vira escritor sem funil.
D="$(mkfix orphan)"
cat > "$D/economy/ShopService.gd" <<'GD'
extends RefCounted
func DoStillBad(id : int) -> bool:
	return sql.db.delete_rows("thing", "id = %d" % id)
GD
n3="$(scan_writes "$D" | grep -c '^SEM-TRANSACAO' || true)"
if [ "$n3" -eq 1 ]; then ok "control: entry da allowlist sem Transaction() e acusada"; else bad "control: prova de transcricao nao mordeu" "1 acusacao" "$n3"; fi

# (4) Autorização sobrando: arquivo da allowlist sem nenhuma escrita crua.
D="$(mkfix stale)"
printf 'extends Refcounted\nfunc Read(id : int) -> Array:\n\treturn sql.db.select_rows("thing", "id = %%d" %% id, ["n"])\n' > "$D/economy/ShopService.gd"
if [ -n "$(grep -nE "$WRITE_RE" "$D/economy/ShopService.gd" 2>/dev/null)" ]; then
	bad "control: allowlist aceita entrada sem escrita crua" "0 escritas .db. no fixture" "acha 1"
else
	ok "control: entrada de allowlist sem escrita crua e detectada"
fi

printf 'escopo: %s/*.gd; allowlist de %d writers sancionados; escrita = insert_row/update_rows/delete_rows/execute/query_with_bindings/query no handle db cru\n' "$ROOT" "$(printf '%s\n' $WRITE_ALLOWLIST | grep -c .)"
echo "== WRITE FUNNEL GATE: $CHECKS checks, $FAILURES failures =="
exit "$FAILURES"
