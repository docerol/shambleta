#!/usr/bin/env bash
# Gate de segredo — o que impediria, de fato, um `git add -A` committar a chave
# do provedor de pagamento num repositório que se declara open source (README.md:5).
#
# Por que este script existe se o `.gitignore` já tem a regra dotenv agora: um
# `.gitignore` é uma convenção que uma linha apaga. O buraco medido em 2026-09-27
# era exatamente esse — o `.gitignore` não tinha NENHUMA regra de dotenv (só o
# comentário `# linux env`), o `.env.example:1-4` mandava copiar para `.env` e não
# versionar, e nos campos 19-20 daquele arquivo vivem
# `SHAMBLETA_MP_WEBHOOK_SECRET` / `SHAMBLETA_MP_ACCESS_TOKEN`. `git check-ignore -v
# .env` saía 1 e nada entre o editor e o `git push` discordava. Régua que só vive
# num arquivo de configuração é decoração: o portão é aqui, e ele é chamado por
# `structure_gates()` em scripts/test.sh, então `all` (local) e o job `code-health`
# da CI passam pela mesma porta.
#
# Uso:   bash scripts/check_secrets.sh
# Saída: uma linha por regra ([PASS]/[FAIL]) e, no fim,
#        `== SECRETS GATE: N checks, M failures ==` — o formato é o que
#        scripts/ci_gate_log.sh:42 lê. Exit code = nº de falhas.
#
# Ocultação: este script NUNCA imprime o valor casado, só `arquivo:linha`. Um gate
# de segredo que ecoa o match vira ele o vazador (log de CI é superfície pública
# em repo aberto). Os regexes de valor vivo exigem literal longo, então um valor
# vazio (`KEY=`) ou um nome de variável não disparam.
#
# Escopo honesto: varremos o ÍNDICE/árvore de trabalho, não o histórico do git.
# Segredo que já foi committado em outro commit não é consertado por `git rm
# --cached` — exige rotação no painel do provedor e reescrita de histórico. Nada
# aqui substitui isso; o que este gate garante é que ele NÃO VOLTE a acontecer por
# descuido, e que o `check-ignore` continua valendo.
set -uo pipefail

ROOT="${SHAMBLETA_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 1

CHECKS=0
FAILURES=0

pass() { CHECKS=$((CHECKS + 1)); printf '[PASS] %s\n' "$1"; }
fail() {
	CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1))
	printf '[FAIL] %s\n' "$1"
	[ $# -gt 1 ] && printf '       ESPERADO: %s\n       ENCONTRADO: %s\n' "$2" "$3"
	return 0
}

# Arquivo com nome de dotenv: `.env`, `.env.local`, `.env.prod`, `deploy/.env`,
# `companion/production.env` — as três formas que o compose/Coolify aceita. O
# template `.env.example` fica FORA de propósito: ele é o documento das chaves.
is_dotenv_name() {
	local b
	b="$(basename "$1")"
	case "$b" in
	.env.example) return 1 ;;
	.env | .env.* | *.env) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------- git presente
if git rev-parse --git-dir >/dev/null 2>&1; then
	pass "índice do git legível (sem ele nada abaixo seria verificável)"
else
	fail "índice do git ilegível em $ROOT" "um repositório git" "rev-parse falhou"
	echo "== SECRETS GATE: $CHECKS checks, $FAILURES failures =="
	exit 1
fi

# ------------------------------------------------- (1) dotenv fora do índice
TRACKED_DOTENV="$(git ls-files | while IFS= read -r f; do is_dotenv_name "$f" && printf '%s\n' "$f"; done)"
if [ -z "$TRACKED_DOTENV" ]; then
	pass "nenhum arquivo dotenv rastreado pelo git"
else
	n=0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		fail "dotenv rastreado no índice: $f" "0 arquivos dotenv rastreados" "$f (valor não impresso de propósito)"
		n=$((n + 1))
	done <<< "$TRACKED_DOTENV"
	[ "$n" -gt 0 ] && printf '       correção: git rm --cached <arquivo> E ROTACIONES a chave — o histórico do commit já o tem, e `git rm` não apaga de lá.\n'
fi

# O estado intermediário que o teste acima não vê: `git add` de um dotenv (índice,
# ainda não commitado) e deleção não preparada de um dotenv que ainda está no
# índice. É o mesmo canto que o check_god_nodes.sh:39 aprendeu a cobrir.
STAGE_DOTENV="$(git ls-files --stage --others --exclude-standard 2>/dev/null | awk '{print $NF}' | while IFS= read -r f; do is_dotenv_name "$f" && printf '%s\n' "$f"; done)"
if [ -z "$STAGE_DOTENV" ]; then
	pass "nenhum dotenv em índice de staging ou não ignorado na árvore"
else
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		fail "dotenv adicionável/staged (seria committado pelo próximo commit): $f" "0" "$f"
	done <<< "$STAGE_DOTENV"
fi

DELETED_DOTENV="$(git ls-files --cached --deleted | while IFS= read -r f; do is_dotenv_name "$f" && printf '%s\n' "$f"; done)"
if [ -z "$DELETED_DOTENV" ]; then
	pass "nenhum dotenv apagado na árvore mas ainda no índice"
else
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		fail "deleção de dotenv não preparada (ainda rastreado): $f" "0" "$f"
	done <<< "$DELETED_DOTENV"
fi

# ------------------------------------------- (2) a regra do .gitignore funciona
# Comportamental, não texto: `git check-ignore` é o git respondendo a pergunta.
# Um gate que só lesse o `.gitignore` aprovaria `.env` com a regra errada de
# precedência (exceção `!` no lugar errado, diretório excluído antes do arquivo).
for probe in ".env" "deploy/.env" "companion/.env" ".env.production" "sub/acme.env"; do
	if git check-ignore -q "$probe" 2>/dev/null; then
		pass "o git descarta $probe (.gitignore eficaz)"
	else
		fail "$probe NÃO está ignorado" "git check-ignore exit 0" "exit $? — o próximo \`git add -A\` committa este arquivo"
	fi
done

# E o template tem de continuar rastreado: a mesma regra que fecha a porta não
# pode engolir o arquivo que documenta as chaves.
if git check-ignore -q ".env.example" 2>/dev/null; then
	fail ".env.example está sendo ignorado pela regra dotenv" "exceção !.env.example eficaz" "o template sumiria do clone"
else
	pass ".env.example permanece fora da regra dotenv (exceção !.env.example em vigor)"
fi

# ------------------------------------------------ (3) o template não traz valor
if [ -r .env.example ]; then
	pass ".env.example existe e é legível (é o documento das chaves)"
	# Um segredo preenchido no template é segredo distribuído no clone.
	NONEMPTY_TPL="$(grep -nE '^[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*=[^[:space:]]' .env.example || true)"
	if [ -z "$NONEMPTY_TPL" ]; then
		pass "nenhum campo de credencial preenchido no .env.example"
	else
		while IFS=: read -r ln _; do
			fail ".env.example:$ln traz valor de credencial no template" "KEY= vazio" "linha $ln (valor ocultado)"
		done <<< "$NONEMPTY_TPL"
	fi
	# As duas chaves do dinheiro, nominalmente: foram elas que o juíz apontou.
	for key in SHAMBLETA_MP_WEBHOOK_SECRET SHAMBLETA_MP_ACCESS_TOKEN; do
		if grep -qE "^${key}=" .env.example; then
			pass "$key declarada no template (com valor vazio por regra acima)"
		else
			fail "$key sumiu do template" "a chave declarada em .env.example" "não encontrada"
		fi
	done
else
	fail ".env.example ausente" "o template das variáveis de ambiente" "arquivo não legível"
fi

# --------------------------- (4) arquivo rastreado com cara de credencial viva
# Allowlist por arquivo com o motivo ao lado. Entrada morta é falha: uma allowlist
# que ninguém confere vira o buraco com documentação.
ALLOW_B2="companion/server.py companion/test_security.py"
ALLOW_B2_REASON="server.py:707 guarda o NOME da variável de ambiente do sender de push, não um valor; test_security.py:53-54 são fixture do HMAC em teste (companion/test_commons.py) e não são usados contra o provedor real."

# Placeholder de documentação NÃO é segredo: a convenção `<preencha-aqui>` (usada
# em deploy/STAGING.md, por exemplo) e palavras tipo CHANGE_ME/YOUR_/exemplo são
# instrução para o operator, não credencial. A classificação lê a linha mas imprime
# só o veredito — nunca o valor. Sem esta função o gate gritaria em todo doc e a
# primeira pessoa que o achateixasse perderia o sinal de verdade.
PLACEHOLDER_WORDS='(CHANGE_?ME|REPLACE_?ME|YOUR_?[A-Z_]*|SEU_?[A-Z_]*|placeholder|exemplo|example|sample|dummy|fake|troque|coloque)[A-Za-z0-9_-]*'
placeholder_hit() {
	local file="$1" line="$2" body
	body="$(sed -n "${line}p" "$file" 2>/dev/null)" || return 1
	# valor entre <...> (com aspas opcionais) ou ${...} (interpolação do compose)
	printf '%s' "$body" | grep -qE '[:=][[:space:]]*["'"'"']?<[^<>]*>' && return 0
	printf '%s' "$body" | grep -qE '[:=][[:space:]]*["'"'"']?\$\{[^}]+\}["'"'"']?$' && return 0
	printf '%s' "$body" | grep -qiE "[:=][[:space:]]*[\"']?${PLACEHOLDER_WORDS}[\"']?[[:space:]]*$" && return 0
	printf '%s' "$body" | grep -qE '[:=][[:space:]]*["'\'']?[x.*_-]{6,}["'\'']?[[:space:]]*$' && return 0
	return 1
}

# Cada regra: nome + regex. Os regexes exigem literal longo (>=12) e não batem em
# `KEY=` vazio nem em chamada de função (`password = _read(...)` fica fora).
scan_rule() {
	local name="$1" regex="$2" allow="${3:-}" hits
	hits="$(git grep -I -n -E -e "$regex" 2>/dev/null | cut -d: -f1,2 || true)"
	if [ -z "$hits" ]; then
		pass "$name"
		return 0
	fi
	local n=0 ph=0 f ln h
	while IFS= read -r h; do
		[ -n "$h" ] || continue
		f="${h%%:*}"
		ln="${h##*:}"
		if placeholder_hit "$f" "$ln"; then
			ph=$((ph + 1))
			continue
		fi
		case " $allow " in
		*" $f "*) continue ;;
		esac
		fail "$name — $f:$ln" "nenhum match" "arquivo:linha impressos, valor ocultado"
		n=$((n + 1))
	done <<< "$hits"
	[ "$ph" -gt 0 ] && printf '       (%d match(es) classificado(s) como placeholder de documentação: valor entre colchetes angulares, interpolação ${...} ou CHANGE_ME — não impressos)\n' "$ph"
	if [ "$n" -eq 0 ]; then
		pass "$name (matches restantes são allowlist motivada ou placeholder de doc)"
	fi
	return 0
}

# regra B1: estilo dotenv (`NOME_SECRETO=valor`) mesmo dentro de Dockerfile /
# shell / compose com `export`.
scan_rule "nenhum dotenv-style de credencial em arquivo rastreado (B1)" \
	'^(export[[:space:]]+)?[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*=[^[:space:]$&"'\'']'
# regra B2: atribuição com literal entre aspas e chave MAÚSCULA de segredo.
scan_rule "nenhuma atribuição de credencial com literal longo em arquivo rastreado (B2)" \
	'[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{12,}["'\'']' \
	"$ALLOW_B2"
scan_rule "nenhuma chave privada PEM em arquivo rastreado (B3)" \
	'-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan_rule "nenhum Access Key ID de nuvem (AKIA/ASIA) em arquivo rastreado (B4)" \
	'(AKIA|ASIA)[0-9A-Z]{16}'
scan_rule "nenhum access token do Mercado Pago em arquivo rastreado (B5)" \
	'(APP_USR|APP_TEST)-[0-9]{4,}'
scan_rule "nenhum JWT assinado em arquivo rastreado (B6)" \
	'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'
scan_rule "nenhuma URL de banco com usuário:senha embutidos (B7)" \
	'(postgres(ql)?|mysql|redis|amqp|https?)://[A-Za-z0-9_.%+-]{2,}:[^@/[:space:]"]{8,}@'

# Confere as entradas da allowlist: cada uma tem de estar casando ALGO hoje.
for f in $ALLOW_B2; do
	if git grep -I -q -E -e '[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{12,}["'\'']' -- "$f" 2>/dev/null; then
		pass "allowlist B2: $f ainda casa (motivo registrado no topo desta seção)"
	else
		fail "allowlist B2: $f não casa mais — entrada morta" "remover a linha e o motivo" "$f está limpo ou o regex mudou"
	fi
done
printf '       motivo registrado para a allowlist B2: %s\n' "$ALLOW_B2_REASON"

# ------------------------------------ (5) o próprio gate tem de ser alcançável
# Foi assim que check_compose.sh chegou a 42 checks verdes e zero chamadores. Se
# este script não for chamado pelo `structure_gates()` — a função que `all` e a CI
# compartilham — ele é decoração, e a linha abaixo é o que denuncia.
if grep -q "check_secrets.sh" scripts/test.sh && grep -q "SECRETS GATE" scripts/test.sh; then
	pass "scripts/test.sh chama este gate com o marcador dele em structure_gates()"
else
	fail "scripts/check_secrets.sh não está ligado em scripts/test.sh" "gate_sh ... \"== SECRETS GATE:\" scripts/check_secrets.sh dentro de structure_gates()" "ausente"
fi

# E todo script de checagem do repo tem de ter chamador (nenhum portão órfão).
ORPHANS=""
for s in scripts/check_*.sh; do
	[ -e "$s" ] || continue
	b="$(basename "$s")"
	if ! grep -rqF "$b" scripts/test.sh .github/workflows/ 2>/dev/null; then
		ORPHANS="$ORPHANS $b"
	fi
done
if [ -z "$ORPHANS" ]; then
	pass "todo scripts/check_*.sh tem chamador em test.sh ou na CI"
else
	for b in $ORPHANS; do
		fail "gate órfão: scripts/$b não é chamado por scripts/test.sh nem por workflow" "chamador em structure_gates()" "zero chamadores"
	done
fi

printf 'escopo: índice + árvore de trabalho; histórico do git NÃO é varrido (segredo já committado => rotacionar + reescrever)\n'
echo "== SECRETS GATE: $CHECKS checks, $FAILURES failures =="
exit "$FAILURES"
