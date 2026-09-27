#!/usr/bin/env python3
"""SOM-IDLE i18n — extrator/gap report de strings do cliente.

Varre as fontes de texto do jogo e compara com data/i18n/ui.csv:
  1. tr("...") literais nos *.gd            -> precisam de linha no CSV
     (e TranslationServer.translate("..."), same domain: é o `tr()` de quem está
      num contexto estático, onde o método do Object não existe)
  2. text = "..." estaticos nos *.gd        -> traduzidos no runtime pelo Localizer
  3. text/title = "..." nos *.tscn          -> idem (Godot 4 NAO auto-traduz; Localizer.gd)
  4. Mes/Say(...) nos scripts de conteudo   -> dominio 'content' (fase 2)
Escreve data/i18n/coverage_report.md (contagem + chaves faltantes por dominio).

Uso:  python3 tools/extract_i18n.py [--write-gaps]   (--write-gaps adiciona as
chaves faltantes de UI com pt_BR vazio para o tradutor preencher)
"""
import csv, glob, re, sys, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
UI_CSV = os.path.join(ROOT, 'data', 'i18n', 'ui.csv')
REPORT = os.path.join(ROOT, 'data', 'i18n', 'coverage_report.md')

RE_TR = re.compile(r'tr\("((?:[^"\\]|\\.)+)"\)')
# `tr()` é método de Object; função estática não tem. A chamada equivalente é a do
# singleton, e omiti-la do domínio deixava invisível toda chave traduzida num helper
# estático de UI — foi o caso do rastro do cofre (`GuildVaultTrail.Render`).
RE_TS = re.compile(r'TranslationServer\.translate\("((?:[^"\\]|\\.)+)"\)')
RE_TEXT_GD = re.compile(r'^\s*(?:\w+\.)*text\s*=\s*"((?:[^"\\]|\\.)+)"\s*$')
RE_TEXT_TSCN = re.compile(r'\btext\s*=\s*"((?:[^"\\]|\\.)+)"')
RE_TITLE_TSCN = re.compile(r'\btitle\s*=\s*"((?:[^"\\]|\\.)+)"')
RE_MES = re.compile(r'\b(?:Mes|Msg|Say|Dialog|Option|Answer|Question)\s*\(\s*"((?:[^"\\]|\\.)+)"')
CONTENT_DIR = os.path.join(ROOT, 'sources', 'scripts')

# Chaves de identidade deliberada: simbolos, numeros e loanwords que a comunidade
# BR usa verbatim (Mana, PC, Slot, Gems:, Odds:, Drops:, VIP:, Artis proper noun).
# Credits (nomes de autores premiados no conteúdo) não se traduzem: ficam por
# identidade, como símbolos/números acima. Regra da casa: créditos são intocáveis.
IDENTITY = {"⏎", "\n", "+", "-", "<", ">", "?", "~", "0", "1", "2", "3", "4", "5",
	"6", "7", "8", "9", "0/0", "35%", "999+", "x1", "x2", "x3", "+%s XP", "+0 XP",
	"000000", "Artis", "Drops: %d", "Drops: 0", "Gems: —", "Mana", "Odds: —",
	"PC", "Slot", "Slots", "VIP: —", "Visual", "★ Local Server",
    "Johanne Laliberté, 2011", "Nard, 2011",
    # pontuação/interjeições/loanwords de mesa usados crus pela comunidade BR
    "...", "Blackjack!", "ARGH.", "OK",
    # acrescentadas em 2026-09-27 com a mesma justificativa de acima, cada uma
    # conferida no chamador: "Idle" é botão da barra de HUD cujo tooltip na mesma
    # tela já diz "HUD mínima de idle (F12)" — o jogo trata como palavra do
    # vocabulário BR; "Skin" é o rótulo da linha de skin em Formation.tscn (o BR
    # usa "skin"); "Arena" é homógrafo: a palavra existe igual nas duas línguas.
    # "—" e "−" são os placeholders vazios dos letreiros ("Tournament: —"), mesma
    # classe do "-" ASCII já listado. O "AH" que esteve aqui saiu junto do botão
    # duplicado da barra: sem chamador, a exceção seria só uma licença de eco.
    "Idle", "Skin", "Arena", "—", "−",
}

def unesc(s):
    return s.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')

def collect():
    tr_keys, textgd_keys, tscn_keys, content_keys = set(), set(), set(), set()
    for f in glob.glob(os.path.join(ROOT, 'sources', '**', '*.gd'), recursive=True):
        try:
            src = open(f, encoding='utf-8').read()
        except (UnicodeDecodeError, IsADirectoryError):
            continue
        in_content = f.startswith(CONTENT_DIR)
        for m in RE_TR.finditer(src):
            (content_keys if in_content else tr_keys).add(unesc(m.group(1)))
        for m in RE_TS.finditer(src):
            (content_keys if in_content else tr_keys).add(unesc(m.group(1)))
        for m in RE_MES.finditer(src):
            content_keys.add(unesc(m.group(1)))
        for line in src.splitlines():
            m = RE_TEXT_GD.match(line)
            if m and not line.lstrip().startswith('#'):
                k = unesc(m.group(1))
                (content_keys if in_content else textgd_keys).add(k)
    tscn_files = [f for f in glob.glob(os.path.join(ROOT, 'presets', '**', '*.tscn'), recursive=True)
                  if '/maps/' not in f and '/sprites/' not in f and '/particles/' not in f]
    for f in tscn_files:
        src = open(f, encoding='utf-8').read()
        for rx in (RE_TEXT_TSCN, RE_TITLE_TSCN):
            for m in rx.finditer(src):
                tscn_keys.add(unesc(m.group(1)))
    return tr_keys, textgd_keys, tscn_keys, content_keys

def load_csv():
    with open(UI_CSV, newline='', encoding='utf-8') as fh:
        rows = list(csv.DictReader(fh))
    # A chave comparável é a que o engine compila, não a que está escrita no
    # arquivo: `ui.csv.import` roda com `unescape_keys=true`, então a linha
    # "...\n\n..." do CSV vira uma chave com quebra de linha real, que é
    # exatamente o que `tr()` recebe do literal do .gd. Comparar a forma crua
    # denunciava como "faltando" uma chave que na verdade está traduzida e
    # funcionando — e escondia o dia em que o import parasse de escapar.
    return {unesc(r['keys']): r for r in rows}

def is_translated(row):
    k = row['keys']
    if k in IDENTITY:
        return True
    pt = (row.get('pt_BR') or '').strip()
    if pt and pt != k:
        return True
    return is_source_portuguese(row)

def is_source_portuguese(row):
    # Caso que a régua antiga não media: a linha foi ESCRITA em português
    # ("Eventos", "Leilão", "⚡ INTERRUPTAR"). Para o jogador BR ela já está
    # certa — `tr()` devolve a própria chave — e o defeito real é a coluna `en`,
    # que servia português para quem joga em inglês. Contamos como coberta em
    # pt_BR SOMENTE quando a linha declara o inglês dela (`en` preenchido e
    # diferente da chave): sem essa declaração a chave volta para a lista de
    # faltando. Não é afrouxamento decidido à mão: é a própria linha do CSV
    # afirmando "minha fonte é português", e uma fonte inglesa não consegue
    # fingir isso porque `en == keys` nela.
    k = row['keys']
    if k in IDENTITY:
        return False
    pt = (row.get('pt_BR') or '').strip()
    if pt and pt != k:
        return False
    en = (row.get('en') or '').strip()
    return bool(en) and en != k

def main():
    write_gaps = '--write-gaps' in sys.argv
    tr_keys, textgd_keys, tscn_keys, content_keys = collect()
    rows_by_key = load_csv()
    ui_all = tr_keys | textgd_keys | tscn_keys
    missing = sorted(k for k in ui_all
                     if k not in IDENTITY and (k not in rows_by_key or not is_translated(rows_by_key[k])))
    content_missing = sorted(k for k in content_keys
                             if k not in IDENTITY and (k not in rows_by_key or not is_translated(rows_by_key[k])))
    covered = len(ui_all) - len(missing)
    # Quantas das "cobertas" o são só porque a fonte já é português. Publicamos o
    # número separado para que a linha de cima não possa insuflar a taxa em
    # silêncio: cada uma delas está listada abaixo e precisa de `en` preenchido.
    srcpt = sorted(k for k in ui_all
                   if k in rows_by_key and is_source_portuguese(rows_by_key[k]))

    with open(REPORT, 'w', encoding='utf-8') as fh:
        fh.write('# I18N Coverage Report — cliente Shambleta (pt_BR)\n\n')
        fh.write('Gerado por `tools/extract_i18n.py`. Fontes: tr()/Mes() em `sources/`, '
                 '`text =` em .gd, `text/title =` em `presets/gui/**/*.tscn`. '
                 'A tradução de cena acontece no runtime (`Localizer.gd`), não no engine.\n\n')
        fh.write('| Domínio | Chaves | Cobertas pt_BR | Faltando |\n|---|---|---|---|\n')
        domains = [("tr() código (UI)", tr_keys), ("text= .gd (UI, via Localizer)", textgd_keys),
                   ("cenas .tscn (via Localizer)", tscn_keys), ("conteúdo NPCs/quests (fase 2)", content_keys)]
        for name, s in domains:
            if name.startswith("conteúdo"):
                miss = [k for k in content_missing if k in s]
            else:
                miss = [k for k in missing if k in s]
            fh.write('| %s | %d | %d | %d |\n' % (name, len(s), len(s) - len(miss), len(miss)))
        fh.write('\n**UI total:** %d chaves, %d cobertas (%.0f%%), %d faltando. '
                 '**Conteúdo:** %d chaves pendentes (fase 2 — diálogos NPC em `sources/scripts/`).\n'
                 % (len(ui_all), covered, 100.0 * covered / max(1, len(ui_all)), len(missing), len(content_missing)))
        fh.write('\nDas cobertas, **%d** contam-se por a fonte já estar em português (o `tr()` '
                 'devolve a chave; a coluna `en` dessas linhas é que carrega a tradução) — '
                 'listadas ao final, uma a uma.\n' % len(srcpt))
        if missing:
            fh.write('\n## Faltando (UI)\n\n')
            for k in missing:
                fh.write('- %s\n' % k.replace('\n', '⏎'))
        if srcpt:
            fh.write('\n## Cobertas por fonte em português (UI)\n\n')
            fh.write('Linhas onde o texto-fonte já é português: o jogador BR vê a chave, '
                     'e o que existe para conferir é o `en` da linha.\n\n')
            for k in srcpt:
                fh.write('- %s → en: %s\n'
                         % (k.replace('\n', '⏎'), (rows_by_key[k].get('en') or '').replace('\n', '⏎')))
        fh.write('\n')
    print("UI: %d/%d cobertas; conteúdo: %d faltando" % (covered, len(ui_all), len(content_missing)))

    if write_gaps:
        with open(UI_CSV, 'a', newline='', encoding='utf-8') as fh:
            w = csv.writer(fh, quoting=csv.QUOTE_ALL, lineterminator='\n')
            for k in missing:
                if k not in rows_by_key:
                    # mesma convenção das 6 linhas multilinha que já existem na
                    # tabela: `\n` de dois caracteres, que o import desescapa.
                    w.writerow([k.replace('\n', '\\n'), k.replace('\n', '\\n'), ''])
            print("append %d pendentes" % len(missing))

if __name__ == '__main__':
    main()
