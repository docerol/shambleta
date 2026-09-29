#!/usr/bin/env bash
# Gate de segredo — o que impediria, de fato, um `git add -A` committar a chave
# do provedor de pagamento num repositório que se declara open source (README.md:5).
#
# Por que este script existe se o `.gitignore` já tem a regra dotenv agora: um
# `.gitignore` é uma convenção que uma linha apaga. O buraco medido em 2026-09-27
# era exatamente esse — o `.gitignore` não tinha NENHUMA regra de dotenv (só o
# comentário `# linux env`), o `.env.example:1-4` mandava copiar para `.env` e não
# versionar, e nos campos 27-28 daquele arquivo vivem
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

# --------------------------- (1b) config de runtime rastreada: o escopo que faltava
# Finding #87 (2026-09-29): as três listas acima passam por `is_dotenv_name`, e as
# regras B1/B2 pedem chave MAIÚSCULA sem hífen. O resultado é que o arquivo de
# configuração que o MODO SERVIDOR lê — `data/conf/credential.cfg`, chave
# `Email-ApiKey` — era invisível ao portão duas vezes: nem por nome (não é dotenv),
# nem por forma (a regex não sabe o que é `Email-ApiKey=`). Um `Email-ApiKey=sk…`
# committado ali atravessaria o gate com ele verde.
# Desde então: a classe de arquivo entra por nome, a chave de credencial é procurada
# SEM distinguir caixa e aceitando hífen/ponto, e a saída continua sendo
# `arquivo:linha` — o valor NUNCA é impresso (log de CI em repo aberto é superfície
# pública; ver o contrato no topo deste arquivo e a sonda (4d) abaixo).
is_runtime_config_name() {
	case "$1" in
	*.cfg | *.credentials) return 0 ;;
	*) return 1 ;;
	esac
}

# A varredura cobre o índice E o que está na árvore sem estar ignorado: um
# `credential.cfg` com valor vivo ainda não comitado é exatamente o que o próximo
# `git add -A` committa, e foi assim que o `.env` entrou neste repo uma vez.
RUNTIME_CFG="$( { git ls-files --cached; git ls-files --others --exclude-standard; } 2>/dev/null \
	| sort -u | while IFS= read -r f; do is_runtime_config_name "$f" && printf '%s\n' "$f"; done )"
RUNTIME_CFG_N="$(printf '%s\n' "$RUNTIME_CFG" | grep -c '[^[:space:]]' || true)"

# Chave de credencial em qualquer caixa, com hífen/ponto, e valor com >=8 caracteres
# que não são aspa nem espaço. `author=`, `authenticate_accounts=` e `use_credentials=false`
# ficam fora por construção: a classe exige a PALAVRA de credencial encostada na
# chave (com fronteira de `_`/`-`/`.` ou fim do nome) e um valor que não é flag.
RX_C1='^[[:space:]]*[A-Za-z0-9_.-]*(secret|token|passw|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential[s]?|keystore|vapid[_-]?key|dsn|auth[_-]?key)[A-Za-z0-9_.-]*[[:space:]]*[=:][[:space:]]*"?[^"[:space:]]{8,}'

# O valor é LIDO para classificar e nunca para ser impresso. Vazio, máscara, flag
# booleana, `<placeholder>` e interpolação `${…}` não são credencial viva — sem esta
# classe o gate gritaria nos seis `.cfg` que já existem e a primeira pessoa que o
# achateixasse perderia o sinal de verdade (mesmo motivo de `placeholder_hit`).
runtime_value_spared() {
	local val
	val="$(printf '%s' "${1:-}" | sed -nE 's/^[^=:]*[=:][[:space:]]*(.*)$/\1/p')"
	val="$(printf '%s' "$val" | sed -E 's/[[:space:]]*[;#].*$//')"
	val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
	[ -z "$val" ] && return 0
	printf '%s' "$val" | grep -qiE '^(true|false|none|null|on|off|0|1|1[05]|disabled?|enabled?|required|optional)$' && return 0
	printf '%s' "$val" | grep -qE '^[x.*_-]{6,}$' && return 0
	printf '%s' "$val" | grep -qiE '^(change_?me|replace_?me|your[_-]?|seu[_-]?|placeholder|exemplo|example|sample|dummy)' && return 0
	printf '%s' "$val" | grep -qE '^<.*>$' && return 0
	printf '%s' "$val" | grep -qE '^\$\{[^}]+\}$' && return 0
	return 1
}

if [ "$RUNTIME_CFG_N" -gt 0 ]; then
	pass "$RUNTIME_CFG_N arquivo(s) de configuração de runtime estão no escopo do gate (*.cfg, *.credentials)"
	printf '       varridos: %s\n' "$(printf '%s\n' "$RUNTIME_CFG" | tr '\n' ' ')"
else
	fail "nenhum arquivo de config de runtime foi encontrado pelo gate" "a lista (*.cfg, *.credentials) não vazia" "índice ilegível ou o repo não tem config — a sonda (4d) abaixo é o que prova se a regra está viva"
fi

CFG_LIVE=0
CFG_SPARED=0
while IFS= read -r f; do
	[ -n "$f" ] || continue
	hits="$(grep -n -i -E -e "$RX_C1" -- "$f" 2>/dev/null || true)"
	[ -n "$hits" ] || continue
	while IFS= read -r h; do
		[ -n "$h" ] || continue
		ln="${h%%:*}"
		body="${h#*:}"
		if runtime_value_spared "$body"; then
			CFG_SPARED=$((CFG_SPARED + 1))
			continue
		fi
		# Só arquivo:linha. O `$body` foi lido para classificar e morre aqui.
		fail "credencial viva em configuração de runtime — $f:$ln" \
			"chave de credencial com valor vazio, mascarado ou placeholder" \
			"arquivo:linha impressos, valor ocultado"
		CFG_LIVE=$((CFG_LIVE + 1))
	done <<< "$hits"
done <<< "$RUNTIME_CFG"
if [ "$CFG_LIVE" = "0" ]; then
	if [ "$CFG_SPARED" -gt 0 ]; then
		pass "nenhuma credencial viva em configuração de runtime ($CFG_SPARED match(es) classificado(s) como vazio, flag, máscara ou placeholder — valores não impressos)"
	else
		pass "nenhuma credencial viva em configuração de runtime (zero match na classe de arquivo; a prova de que a regra está viva é a sonda (4d))"
	fi
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
	# (3b) Nenhum NOME que o companion lê por os.environ pode ficar órfão do template.
	# A constante *_ENV é a única fonte dos nomes (companion/push_common.py), e um nome
	# novo que existe no código mas não no template é uma porta que ninguém documenta:
	# o operator do deploy nem saberia que ela existe. name_const_hit já exige o
	# template para ESCUSAR a constante de nome; isto exige o template para todo nome,
	# mesmo os que o scanner não teria motivo para marcar (PUSH_TIMEOUT).
	ORPHAN_ENV=""
	while IFS= read -r envname; do
		[ -n "$envname" ] || continue
		grep -qE "^${envname}=" .env.example || ORPHAN_ENV="$ORPHAN_ENV $envname"
	done <<EOF
$(git grep -hI -E '^[A-Z0-9_]+_ENV[[:space:]]*=[[:space:]]*"SHAMBLETA_[A-Z0-9_]*"' -- 'companion/*.py' \
	| sed -E 's/.*"(SHAMBLETA_[A-Z0-9_]+)".*/\1/' | sort -u)
EOF
	if [ -z "$ORPHAN_ENV" ]; then
		pass "todo nome *_ENV do companion está declarado no .env.example"
	else
		fail "*_ENV órfãos do template:$ORPHAN_ENV" "cada nome lido por os.environ declarado no .env.example" "faltam na lista acima"
	fi
else
	fail ".env.example ausente" "o template das variáveis de ambiente" "arquivo não legível"
fi

# --------------------------- (4) arquivo rastreado com cara de credencial viva
# Allowlist por arquivo com o motivo ao lado. Entrada morta é falha: uma allowlist
# que ninguém confere vira o buraco com documentação.
ALLOW_B2="companion/test_security.py"
ALLOW_B2_REASON="test_security.py:53-54 são fixture do HMAC em teste (companion/test_commons.py) e não são usados contra o provedor real. As constantes de NOME de ambiente (server.py, push_common.py) saíram da allowlist em 2026-09-27: agora são classificadas por name_const_hit, que exige o literal declarado em .env.example."

# Placeholder de documentação NÃO é segredo: a convenção `<preencha-aqui>` (usada
# em deploy/STAGING.md, por exemplo) e palavras tipo CHANGE_ME/YOUR_/exemplo são
# instrução para o operator, não credencial. A classificação lê a linha mas imprime
# só o veredito — nunca o valor. Sem esta função o gate gritaria em todo doc e a
# primeira pessoa que o achateixasse perderia o sinal de verdade.
PLACEHOLDER_WORDS='(CHANGE_?ME|REPLACE_?ME|YOUR_?[A-Z_]*|SEU_?[A-Z_]*|placeholder|exemplo|example|sample|dummy|fake|troque|coloque)[A-Za-z0-9_-]*'
# Constante de NOME de variável de ambiente: a linha tem o forma FOO_ENV = "SHAMBLETA_FOO".
# A regra B2 foi escrita para pegar valor de credencial, e a convenção `_ENV` do
# companion guarda exatamente o oposto — o nome sob o qual o valor chega. Distinguir
# os dois por allowlist de arquivo é o buraco com documentação (cresce a cada nome
# novo, e ninguém confere se ainda casa). Então a classe é conferida, não listada:
# o alvo tem de terminar em `_ENV`, o literal tem de ter forma de nome de variável,
# e o nome tem de estar DECLARADO em `.env.example` — esconder valor real atrás de
# um `_ENV` que ninguém declara continua sendo falha, e declarar a variável no
# template passa a ser requisito de gate (a seção 3 exige o valor vazio).
name_const_hit() {
	local file="$1" line="$2" body name value
	body="$(sed -n "${line}p" "$file" 2>/dev/null)" || return 1
	name="$(printf '%s' "$body" | sed -nE 's/^[[:space:]]*([A-Z0-9_]+_ENV)[[:space:]]*[:=].*/\1/p')" || true
	[ -n "$name" ] || return 1
	value="$(printf '%s' "$body" | sed -nE 's/.*[[:space:]][:=][[:space:]]*"([A-Z][A-Z0-9_]*)".*/\1/p')" || true
	[ -n "$value" ] || return 1
	grep -qE "^${value}=" .env.example 2>/dev/null
}
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

# Payload serializada do Godot não é credencial — é base64 de dados de mapa. Esta
# classe nasceu no dia em que `presets/maps/**` saiu do `.gitignore`: 28 linhas de
# `presets/maps/layers/**.tscn` casaram B4, todas da forma
# `tile_map_data = PackedByteArray("…")`, e o que o alphabet base64 faz com um
# alphabet de 20 caracteres é aritmética, não dedo no teclado. A classificação é
# ESTRUTURAL, não de caminho (caminho seria allowlist, e allowlist é o buraco com
# documentação que a seção 2 já recusa):
#   (a) a linha tem de ser a atribuição de uma propriedade a `PackedByteArray("` —
#       construtor de blob antes do match, na mesma linha;
#   (b) o NOME da propriedade não pode ter cara de credencial (SECRET/TOKEN/KEY/…),
#       porque `aws_access_key = PackedByteArray("AKIA…")` é um segredo fantasiado,
#       não tile data;
#   (c) só B4 pede essa saída, e é só a B4 que ela vale. As outras regras não
#       precisam: `-----BEGIN`, `eyJ….eyJ….` e `scheme://user:pass@` contêm
#       caracteres que não existem dentro de um literal desses, então poupar o blob
#       nelas seria cegar o gate sem ganhar nada. O canary abaixo prova (b) e (c).
blob_hit() {
	local file="$1" line="$2" body
	body="$(sed -n "${line}p" "$file" 2>/dev/null)" || return 1
	blob_body_spared "$body"
}

# A forma crua, separada de `blob_hit` para o canary poder exercitá-la sem que
# alguém precise committar um falso positivo para provar a regra.
blob_body_spared() {
	local prop
	prop="$(printf '%s' "$1" | sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*PackedByteArray\(".*/\1/p')"
	[ -n "$prop" ] || return 1
	printf '%s' "$prop" | grep -qiE 'SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL' && return 1
	return 0
}

# Cada regra: nome + regex. Os regexes exigem literal longo (>=12) e não batem em
# `KEY=` vazio nem em chamada de função (`password = _read(...)` fica fora).
# O 4º argumento liga a saída de blob; ele é opt-in POR REGRA de propósito — se
# fosse geral, um `secret = PackedByteArray("…")` em `.tscn` atravessava B1, B2 e B7.
scan_rule() {
	local name="$1" regex="$2" allow="${3:-}" blob="${4:-0}" hits
	hits="$(git grep -I -n -E -e "$regex" 2>/dev/null | cut -d: -f1,2 || true)"
	if [ -z "$hits" ]; then
		pass "$name"
		return 0
	fi
	local n=0 ph=0 nc=0 bl=0 f ln h
	while IFS= read -r h; do
		[ -n "$h" ] || continue
		f="${h%%:*}"
		ln="${h##*:}"
		if name_const_hit "$f" "$ln"; then
			nc=$((nc + 1))
			continue
		fi
		if placeholder_hit "$f" "$ln"; then
			ph=$((ph + 1))
			continue
		fi
		if [ "$blob" = "1" ] && blob_hit "$f" "$ln"; then
			bl=$((bl + 1))
			continue
		fi
		case " $allow " in
		*" $f "*) continue ;;
		esac
		fail "$name — $f:$ln" "nenhum match" "arquivo:linha impressos, valor ocultado"
		n=$((n + 1))
	done <<< "$hits"
	[ "$nc" -gt 0 ] && printf '       (%d match(es) classificado(s) como constante de NOME de ambiente: alvo `*_ENV` cujo literal está declarado em .env.example)\n' "$nc"
	[ "$ph" -gt 0 ] && printf '       (%d match(es) classificado(s) como placeholder de documentação: valor entre colchetes angulares, interpolação ${...} ou CHANGE_ME — não impressos)\n' "$ph"
	[ "$bl" -gt 0 ] && printf '       (%d match(es) classificado(s) como payload serializada: `propriedade = PackedByteArray("…")`, base64 de tile data cujo alphabet casa a forma do ID de nuvem — o nome da propriedade foi conferido e não é de credencial)\n' "$bl"
	if [ "$n" -eq 0 ]; then
		# O sufixo nomeia SÓ as classes que de fato pouparam algo nesta regra. Dizer
		# "allowlist motivada" quando o que poupou foi payload serializada é o gate
		# mentindo sobre a própria saída — e é a frase que um auditor lê para decidir
		# se confia no verde.
		local why=""
		[ "$nc" -gt 0 ] && why="${why}constante de nome de ambiente, "
		[ "$ph" -gt 0 ] && why="${why}placeholder de doc, "
		[ "$bl" -gt 0 ] && why="${why}payload serializada do Godot, "
		[ -n "$allow" ] && why="${why}allowlist motivada, "
		if [ -z "$why" ]; then
			pass "$name"
		else
			pass "$name (todos os matches poupados por classificação: ${why%, })"
		fi
	fi
	return 0
}

# regra B1: estilo dotenv (`NOME_SECRETO=valor`) mesmo dentro de Dockerfile /
# shell / compose com `export`.
RX_B1='^(export[[:space:]]+)?[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*=[^[:space:]$&"'\'']'
scan_rule "nenhum dotenv-style de credencial em arquivo rastreado (B1)" "$RX_B1"
# regra B2: atribuição com literal entre aspas e chave MAÚSCULA de segredo.
RX_B2='[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{12,}["'\'']'
scan_rule "nenhuma atribuição de credencial com literal longo em arquivo rastreado (B2)" \
	"$RX_B2" "$ALLOW_B2"
RX_B3='-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan_rule "nenhuma chave privada PEM em arquivo rastreado (B3)" "$RX_B3"
RX_B4='(AKIA|ASIA)[0-9A-Z]{16}'
scan_rule "nenhum Access Key ID de nuvem (AKIA/ASIA) em arquivo rastreado (B4)" "$RX_B4" "" 1
RX_B5='(APP_USR|APP_TEST)-[0-9]{4,}'
scan_rule "nenhum access token do Mercado Pago em arquivo rastreado (B5)" "$RX_B5"
RX_B6='eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'
scan_rule "nenhum JWT assinado em arquivo rastreado (B6)" "$RX_B6"
RX_B7='(postgres(ql)?|mysql|redis|amqp|https?)://[A-Za-z0-9_.%+-]{2,}:[^@/[:space:]"]{8,}@'
scan_rule "nenhuma URL de banco com usuário:senha embutidos (B7)" "$RX_B7"

# ------------------------------- (4b) zero hits não prova regra viva
# Um regex quebrado também acha zero. Sem um positivo plantado, o `[PASS]` de B3..B7
# é indistinguível de "a regra morreu": a árvore estaria "limpa" pelo resto da vida
# por um `(` a menos. Cada regra é obrigada a (a) casar um canary que é a forma exata
# do segredo que ela caça e (b) NÃO casar o negativo equivalente — o mesmo literal
# curto/sem valor que a casa escreve em `.env.example` e nos runbooks.
#
# O canary é MONTADO em runtime a partir de pedaços, nunca escrito inteiro: este
# arquivo é rastreado e é varrido pelas próprias regras. A prova disso é medida: a
# primeira versão desta seção deixou o literal da chave de nuvem (prefixo `AK` + `IA`
# mais dezesseis alfanuméricos) dentro de um COMENTÁRIO aqui, e o próprio gate devolveu
# `B4 — scripts/check_secrets.sh` apontando para a linha do comentário. Um gate de
# segredo que precisa de allowlist para si mesmo é o bug, não a exceção.
canary_rule() {
	local name="$1" regex="$2" good="$3" bad="$4" flags="${5:-}"
	if ! printf '%s\n' "$good" | grep $flags -E -q -e "$regex"; then
		fail "$name: regex NÃO casa o canary — regra morta" "a regra caça o segredo plantado" \
			"zero hits na árvore hoje significa zero poder de detecção, não árvore limpa"
		return 0
	fi
	if printf '%s\n' "$bad" | grep $flags -E -q -e "$regex"; then
		fail "$name: regex casa TAMBÉM o negativo — regra frouxa" "o placeholder de doc poupano" \
			"o primeiro README honesto vai derrubar o portão por motivo errado"
		return 0
	fi
	pass "$name: caça o canary e poupa o negativo"
}

_K1="MP_WEBHOOK""_SECRET"
_K2="MP_ACCESS""_TOKEN"
_PEM_A="-----BEGIN "; _PEM_EC="EC PR"; _PEM_B="IVATE KEY-----"
_AK="AK""IA0123456789ABCDEF"
_MP="APP_""USR-1234567890"
_J1="eyJhbGciOiJIUzI1NiJ9"; _J2="eyJzdWIiOiIxIn0"
_DB="postgres""://app:sup3rs3cr3t@db:5432/sh"
canary_rule "B1" "$RX_B1" "${_K1}=abcdefghij1234567890" "${_K1}=\"\""
canary_rule "B2" "$RX_B2" "${_K2}: \"abcdefghij1234567890\"" "${_K2}: \"changeme\""
canary_rule "B3" "$RX_B3" "${_PEM_A}${_PEM_EC}${_PEM_B}" "${_PEM_A}PUBLIC KEY-----"
canary_rule "B4" "$RX_B4" "$_AK" "AKIA0123"
canary_rule "B5" "$RX_B5" "$_MP" "APP_USR-sem-numero"
canary_rule "B6" "$RX_B6" "${_J1}.${_J2}.c2ln${_J1}" "${_J1}"
canary_rule "B7" "$RX_B7" "$_DB" "postgres://app@db:5432/sh"
# A C1 é a regra da classe que o #87 deixou de fora, e ela é a única lida com `-i`
# (a chave do servidor é `Email-ApiKey`, mista e com hífen; B1/B2 pedem chave MAIÚSCULA
# sem hífen e por isso nunca viram o arquivo). O positivo e o negativo são montados em
# runtime: este arquivo é varrido pelas próprias regras e um literal aqui seria o
# gate precisando de allowlist para si mesmo.
_C1A="sk-liv"; _C1B="e9f8e7d6c5b4a3f2"
canary_rule "C1" "$RX_C1" "Email-ApiKey=${_C1A}${_C1B}" 'Email-ApiKey=""' -i
canary_rule "C1 (chave minúscula com hífen)" "$RX_C1" "send_grid-api-key=${_C1A}${_C1B}" 'send_grid-api-key="x"' -i
# A regex não sabe o que é placeholder — quem sabe é a classe. Os probes abaixo são
# o contrato de `runtime_value_spared`, exercitados em processo: o mesmo corpo que o
# fixture (4d) escreve num arquivo, aqui é passado como string, e a saída é RÓTULO,
# nunca valor. O valor VAZIO (`""`) não chega à classe: é a própria regex que o
# recusa (o negativo do canário C1 acima) — linha que a regex não alcança é linha
# invisível, e um probe que contabiliza invisível como "poupado" estaria medindo o
# contrário do que diz. `author=` (chave sem palavra de credencial) e flag curta são
# os dois negativos de REGRA, e os demais são negativos de CLASSE.
cfg_spare_probe() {
	local label="$1" body="$2" want="$3" got=0
	if runtime_value_spared "$body"; then got=1; fi
	# `want` é o resultado do CLASSIFICADOR, e só vale se a REGRA casar a linha:
	# uma chave que a regex não alcança não é "poupada", é invisível — que é a
	# diferença exata entre um placeholder certo e uma regra cega.
	if ! printf '%s\n' "$body" | grep -i -E -q -e "$RX_C1"; then
		fail "C1 classe: $label — a regex nem casou a linha" "a regex casar a linha e o classificador decidir o destino" \
			"linhas que a regex não alcança não podem ser contadas como poupadas (é invisibilidade, não licença)"
		return 0
	fi
	if [ "$got" = "$want" ]; then
		pass "C1 classe: $label"
	else
		fail "C1 classe: $label (esperava spared=$want, veio $got)" "classificador coerente com o contrato" "linha reclassificada"
	fi
}
cfg_spare_probe 'valor vivo é CASADO e não poupado' "Email-ApiKey=${_C1A}${_C1B}" 0
cfg_spare_probe 'CHANGE_ME é poupado' 'Email-ApiKey="CHANGE_ME"' 1
cfg_spare_probe '<preencha> é poupado' 'Email-ApiKey=<preencha-a-chave>' 1
cfg_spare_probe '${INTERPOLACAO} do compose é poupada' 'Email-ApiKey=${SHAMBLETA_EMAIL_KEY}' 1
cfg_spare_probe 'máscara xxxx é poupada' 'Email-ApiKey="xxxxxxxxxxxx"' 1
cfg_spare_probe 'flag longa (required) é poupada' 'use_credentials=required' 1
# Negativos de REGRA, não de classe: `author=` (chave sem palavra de credencial) e
# valor curto (`false`) não chegam nem perto do match — é a fronteira que impede o
# gate de gritar nos seis .cfg que já existem no repo.
canary_rule "C1 (chave que não é credencial)" "$RX_C1" "Email-ApiKey=${_C1A}${_C1B}" 'author="SoM Team"' -i
canary_rule "C1 (flag booleana curta)" "$RX_C1" "Email-ApiKey=${_C1A}${_C1B}" 'use_credentials=false' -i

# ----------------------- (4d) sonda comportamental: VERMELHO quando vaza, e sem imprimir
# (1b) prova forma; isto prova efeito, no único caminho que importa: um arquivo de
# config de runtime com chave de credencial viva TEM de derrubar o portão, e o portão
# tem de dizer `arquivo:linha` sem nunca dizer o valor. O fixture vive num `mktemp -d`
# com `git init` próprio — nada aqui escreve, indexa ou staging no repositório desta
# máquina; o gate é chamado com `SHAMBLETA_REPO_ROOT` apontando para o fixture e com
# `SHAMBLETA_SECRETS_NO_PROBE=1` cortando a recursão.
probe_runtime_config() {
	local label="$1" value="$2" expect="$3" tmp out rc needle bare
	tmp="$(mktemp -d "${TMPDIR:-/tmp}/shambleta-secrets-probe-XXXXXX")" || {
		fail "$label: mktemp falhou" "um diretório temporário" "impossível plantar o controle"
		return 0
	}
	mkdir -p "$tmp/data/conf"
	printf '; config do modo servidor (fixture do gate)\n[Email]\nEmail-ApiKey=%s\nEmail-SenderName=""\n' "$value" > "$tmp/data/conf/credential.cfg"
	git init -q "$tmp" 2>/dev/null
	out="$(SHAMBLETA_REPO_ROOT="$tmp" SHAMBLETA_SECRETS_NO_PROBE=1 \
		bash "$ROOT/scripts/check_secrets.sh" 2>&1)"
	rc=$?
	rm -rf "$tmp"
	needle="$(printf '%s\n' "$out" | grep -oE 'data/conf/credential\.cfg:[0-9]+' | head -1)"
	bare="${value%\"}"; bare="${bare#\"}"; bare="${bare%\'}"; bare="${bare#\'}"
	if [ "$expect" = "red" ]; then
		if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'credencial viva em configuração de runtime'; then
			pass "$label: o valor vivo derrubou o portão (exit $rc, apontando ${needle:-nada})"
		else
			fail "$label: o portão NÃO ficou vermelho com credencial viva em config de runtime" \
				"exit != 0 e a linha da regra C1 na saída" "exit=$rc — a classe continua invisível"
		fi
		# A metade que importa para um repo open source: o valor não pode aparecer.
		# Procuramos o token cru, não a linha inteira — se o gate imprimisse o match,
		# a string do segredo estaria no log.
		case "$out" in
		*"$bare"*)
			fail "$label: a saída do gate CONTÉM o valor plantado" "somente arquivo:linha" \
				"o log de CI de um repo público vazaria exatamente o que o gate caça"
			;;
		*) pass "$label: a saída não contém o valor plantado (ocultação comportamental)" ;;
		esac
	else
		if printf '%s' "$out" | grep -qF 'nenhuma credencial viva em configuração de runtime'; then
			pass "$label: o placeholder vazio é poupado pela mesma regra (sem gritar em todo .cfg)"
		else
			fail "$label: o portão gritou num valor vazio" "placeholder escapado" \
				"um gate que grita é um gate achateixado na primeira semana"
		fi
	fi
}

if [ "${SHAMBLETA_SECRETS_NO_PROBE:-0}" != "1" ]; then
	probe_runtime_config "sonda plantada (valor vivo)" "\"${_C1A}${_C1B}\"" red
	probe_runtime_config "sonda negativa (placeholder vazio)" '""' green
else
	printf '[NOTE] sondas (4d) suprimidas neste run (chamada aninhada do próprio gate)\n'
fi

# ------------------------- (4c) a saída de blob não pode virar porta de contrabando
# Toda classificação que poupa um match é um buraco em potencial, então ela é
# obrigada a provar o próprio limite na mesma passada em que é usada. As quatro
# sondas abaixo são o contrato de `blob_body_spared`: o tile data real passa, o
# mesmo ID escondido atrás de um nome de credencial NÃO passa, e a forma nua não
# passa. Os corpos são MONTADOS a partir de `$_AK` em runtime pela mesma razão do
# canary acima — se este arquivo escrevesse o literal dentro de um
# `PackedByteArray("…")` para se auto-provar, ele estaria usando a própria saída de
# blob para passar na própria regra, que é exatamente o "gate que precisa de
# allowlist para si mesmo" que a seção (4b) recusa. A falha imprime o RÓTULO, nunca
# o corpo.
blob_probe() {
	local label="$1" body="$2" want="$3" got=0
	if blob_body_spared "$body"; then got=1; fi
	if [ "$got" = "$want" ]; then
		pass "$label"
	else
		fail "$label" "want-spared=$want" "got-spared=$got"
	fi
}
blob_probe "blob: tile data real (nome sem cara de credencial) é poupado" \
	"tile_map_data = PackedByteArray(\"${_AK}\")" 1
blob_probe "blob: o mesmo ID atrás de nome de credencial NÃO é poupado" \
	"aws_access_key_id = PackedByteArray(\"${_AK}\")" 0
blob_probe 'blob: push_secret = PackedByteArray(…) não é poupado' \
	"push_secret = PackedByteArray(\"${_AK}\")" 0
blob_probe 'blob: a forma nua, sem construtor de blob, não é poupada' \
	"${_AK}" 0

# A saída é opt-in por regra. Ligar `blob=1` em todas as regras — ou numa regra de
# URL/PEM/JWT por "já que existe" — abriria uma forma de esconder credencial em
# `.tscn`. A régua é no próprio texto deste script: exatamente uma chamada `scan_rule`
# passa o 4º argumento, e ela é a da B4.
blob_calls="$(grep -c '^[[:space:]]*scan_rule .*"\$RX_B[0-9]" "" 1$' scripts/check_secrets.sh 2>/dev/null || true)"
blob_on_b4="$(grep -E '^[[:space:]]*scan_rule .*"\$RX_B4" "" 1$' scripts/check_secrets.sh 2>/dev/null | grep -c 'B4' || true)"
if [ "$blob_calls" = "1" ] && [ "$blob_on_b4" = "1" ]; then
	pass 'a saída de blob está ligada em uma única regra, e é a B4 (as outras não precisam: o alphabet dos seus segredos tem caracteres que não cabem num literal base64)'
else
	fail "saída de blob fora do contrato (chamadas com 4º argumento: ${blob_calls}, ligada na B4: ${blob_on_b4})" "uma chamada, a da RX_B4" "ou o flag vazou para outra regra, ou a B4 ficou cega para o tile data e o gate volta a gritar em presets/maps"
fi

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
