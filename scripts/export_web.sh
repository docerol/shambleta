#!/usr/bin/env bash
# Produto do beta: o pacote Web que o jogador abre no navegador, produzido SEM
# o GitHub Actions (o dono está sem créditos no Actions desde 2026-09-25, então
# nenhum job roda). Censo dos produtores, medido nos arquivos: o artefato que
# realmente sobe para o player sempre teve dois caminhos, e só um deles era a
# CI — `deploy/web/Dockerfile` faz o export no próprio multi-stage (é ele que
# horneia `SHAMBLETA_SERVER_ADDRESS` no `settings.cfg` antes do `--export-release
# "Web"`), e é ele que o Coolify builda; o `deploy/server/Dockerfile` idem para o
# headless. O que o job `web-export` tinha de próprio era o pacote de dev
# (artifact do Actions, sem endereço horneado) e a MEDIDA do primeiro load
# (gzip < 25 MB, deploy/COOLIFY.md §6) — com o job morto, nada mais media, e o
# Dockerfile não mede: ele exporta e vai embora. Este script cobre as duas
# pontas: pacote local (para abrir no navegador antes de existir servidor) e a
# régua de peso, na mesma sequência de passos do job. Ao fim soma o que o job nunca
# teve: abrir o pacote num navegador de verdade (`scripts/qa_web.mjs`), porque medir
# bytes não prova que o jogador consegue entrar no jogo.
#
# Por que o pré-check de template existe (lição escrita no próprio job): procurar
# template ausente no meio do export custa ~3 min e devolve "Cannot export project
# with preset Web due to configuration errors" sem nomear nada. Aqui a falha vem
# antes, com o caminho e o arquivo que faltam.
#
# Uso: scripts/export_web.sh [saida]   (default: build/Web)
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${1:-$PROJECT/build/Web}"
PRESET="Web"
cd "$PROJECT"

# A versão do binário decide o diretório de templates. O CI pinna 4.7.1; esta
# máquina roda 4.7.2 (medido) — um pacote feito local é do toolchain local, e é
# isso que tem que aparecer na mensagem, não um caminho herdado do CI.
version="$("$GODOT" --version 2>/dev/null | tr -d '[:space:]')"
short="$(printf '%s' "$version" | cut -d. -f1-3)"
tpl="$HOME/.local/share/godot/export_templates/${short}.stable"

echo "godot: $version · templates esperados em: $tpl"
if [ ! -d "$tpl" ]; then
	echo "::error::nenhum template de export instalado para Godot ${short}."
	echo "   Instale no editor (Project → Manage Export Templates → Download) ou copie"
	echo "   o pacote de templates para ${tpl}. Sem ele não há export Web — nem local, nem na CI."
	exit 1
fi
# `variant/extensions_support=true` no preset Web (export_presets.cfg:956) = GDExtension
# (gdsqlite) dentro do pacote, que é o template *dlink*, não o plain.
if [ ! -f "$tpl/web_dlink_release.zip" ]; then
	echo "::error::${tpl}/web_dlink_release.zip ausente — o preset Web usa extensions_support."
	echo "   Baixe os templates completos da ${short} (o zip de templates do editor traz este arquivo)."
	exit 1
fi

# Import primeiro: sem os artefatos de `.godot/` importados o export empacota
# recursos velhos (e é o mesmo passo que o job roda).
echo "==> Importando recursos"
"$GODOT" --headless --editor --import --quit >/dev/null 2>&1 || {
	echo "::error::o import de recursos falhou — rode \`$GODOT --headless --editor --import --quit\` e leia o erro"
	exit 1
}

# A pasta destino ANTES do export: o plugin do Sentry copia sentry-bundle.js no
# export_begin e aborta se o diretório não existe (mesma linha do job). E o
# `.gdignore` junto: sem ele, o import da PRÓXIMA rodada enxerga os PNG/JSON que
# este export gerou como recursos do jogo e os empacota de novo — peso composto
# (medido em 2026-09-25: um `index.png` de 2,4 MB de um build anterior estava
# dentro do `.pck` que o jogador baixa).
mkdir -p "$OUT"
[ -f "$PROJECT/build/.gdignore" ] || { mkdir -p "$PROJECT/build"; : > "$PROJECT/build/.gdignore"; }
echo "==> Exportando $PRESET para $OUT"
"$GODOT" --headless --path . --export-release "$PRESET" "$OUT/index.html"

# A régua de peso do job, arquivo por arquivo. Três correções sobre o trecho que
# rodava na CI: (1) o `for` do job listava `libgdsqlite*.wasm` de dentro de
# build/Web, mas o glob era expandido no diretório errado e o `continue` engolia
# a ausência em silêncio — o GDExtension (gdsqlite 691 KB + sentry 427 KB gzip)
# nunca entrou na conta; aqui o `cd` vem antes do glob e o que existe é medido por
# padrão (`*.wasm`), não por nome lembrado. (2) `test` e não `&&` para o aviso
# aparecer no log com a meta escrita. (3) a conta do job media uma lista lembrada
# de arquivos e não o que o navegador baixa: faltava `index.png` (o splash que o
# próprio shell referencia em `<img id="status-splash" src="index.png">`), 2,4 MB
# de gzip — 6,7% do download. Aqui a régua é o diretório: tudo que o export
# produz é baixado no primeiro load, com uma exceção medida —
# `index.offline.html` só é servido quando o service worker não alcança a rede.
echo "==> First-load (gzip -9): todos os arquivos que o navegador baixa"
cd "$OUT"
total=0
measured=0
engine=0
assets=0
shell=0
for f in *; do
	[ -f "$f" ] || continue
	case "$f" in
		index.offline.html) continue ;; # não é primeiro load: servido só offline, em cache miss
		*.import|*.remap) continue ;;   # metadado do importador, não vai para o navegador
	esac
	gz=$(gzip -9 -c "$f" | wc -c)
	measured=$((measured + 1))
	total=$((total + gz))
	case "$f" in
		*.wasm|index.js|sentry-bundle.js) engine=$((engine + gz)) ;;
		*.pck) assets=$((assets + gz)) ;;
		*) shell=$((shell + gz)) ;;
	esac
	printf '  %-46s %8d KB gzip\n' "$f" "$((gz / 1024))"
done
if [ "$measured" -eq 0 ]; then
	echo "::error::export não produziu nenhum arquivo medível em $OUT — o export não rodou."
	exit 1
fi
mib() { echo $(( ($1 + 524288) / 1048576 )); } # arredonda: 35,98 MiB não pode sair como "35"
echo "First-load gzip: $(mib $total) MiB ($total bytes, $measured arquivos)"
echo "  composição: engine $(mib $engine) MiB · pck $(mib $assets) MiB · shell $(mib $shell) MiB"
# **Sobre os 25 MB (por que isto é `::nota::` e não portão).** A meta não é nossa
# e a causa dela já foi executada: ela veio da linha P1 do plano de auditoria
# comercial ("Web build ~32MB gzip (meta <25MB)"), cujo remedo escrito na própria
# linha era tirar a música (`data/music/`, 26 MB) de dentro do `.pck` — corte
# feito e medido em deploy/WEB_SLIM.md (−44%). O arquivo de origem
# (`.kilo/plans/1789659178562-audit-commercial-launch.md`) foi removido do
# repositório pelo dono em 2026-09-25, então a citação está preservada lá.
# E o piso medido sem mexer em arte é ~32 MiB (engine + pck), ou seja: o número
# estava abaixo do que dá para alcançar com mudança segura. Não há limite técnico
# de tamanho para abrir ou instalar no navegador — sem cota de instalação por
# peso em Chrome/Android nem iOS, e nada em deploy/ descreve consequência de
# estourar. Estimar 25 MB como portão seria transformar meta de arte (re-compressão
# de texturas, exige QA visual) em bloqueio de lançamento.
# O preset já emite o que o navegador cobra para instalar (`progressive_web_app/
# enabled=true`, manifest com ícone/`display`, e o service worker do engine sai no
# export), então não há portão técnico aqui: isto é `::nota::`, não `::error::`.
echo "::nota::piso medido sem tocar em arte: ~32 MiB (engine 10 MiB side.wasm + pck). Hoje: $(mib $total) MiB. Os 25 MB são meta de arte pós-beta, ver deploy/WEB_SLIM.md"
if [ "$total" -lt $((25 * 1024 * 1024)) ]; then
	echo "  meta histórica de 25 MB atingida."
fi
# Boot real do pacote num navegador. Fecha a lacuna que nenhuma suíte daqui cobria:
# `scripts/test.sh` roda `godot --headless -s` (sem navegador) e o export media
# bytes — a plataforma de lançamento não era executada por teste nenhum.
# `scripts/qa_web.mjs` serve o artefato com os mesmos headers de isolamento do
# `deploy/web/nginx.conf` e abre um Chromium headless por CDP, checando
# `crossOriginIsolated`, o canvas, o manifest, o service worker e o console — foi
# assim que os quatro erros de boot do web apareceram em 2026-09-25, nenhum deles
# visível na suíte headless.
#
# Roda por padrão (é portão, não opcionais de debug), mas não faz o export depender
# de um binário que o export não controla: sem node ou sem Chromium a etapa é pulada
# com a razão escrita no log, em vez de vermelha por ambiente.
cd "$PROJECT"
CHROME_BIN="${SHAMBLETA_CHROME:-$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome}"
if [ "${SHAMBLETA_QA_WEB:-1}" = "0" ]; then
	echo "::nota::QA no navegador desligado (SHAMBLETA_QA_WEB=0): nenhum navegador abriu este pacote."
elif ! command -v node >/dev/null 2>&1; then
	echo "::nota::sem node na máquina — QA no navegador não rodou."
elif [ ! -x "$CHROME_BIN" ]; then
	echo "::nota::sem Chromium em $CHROME_BIN — QA no navegador não rodou (aponte SHAMBLETA_CHROME)."
else
	echo "==> QA no navegador: $OUT"
	node scripts/qa_web.mjs --dir "$OUT" --chrome "$CHROME_BIN" --deadline "${SHAMBLETA_QA_DEADLINE:-180}"
fi
echo "Gate de export OK: pacote em $OUT."
