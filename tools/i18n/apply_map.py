#!/usr/bin/env python3
"""Aplica um arquivo de mapa (prefixo -> pt_BR) às chaves Mes()/Say() do conteúdo.

Uso: python3 tools/i18n/apply_map.py tools/i18n/maps/<mapa>.py <cidade|todas> [<cidade>...]
Match: prefixo MAIS LONGO vence (chaves aninhadas tipo "A B." vs "A B. C.").
Chaves sem match ou ambíguas são reportadas e NÃO bloqueiam as demais.
Só escreve com --write. Idempotente (pula chaves já no csv).
"""
import re, glob, csv, sys, runpy, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
UI = os.path.join(ROOT, 'data', 'i18n', 'ui.csv')
RE_MES = re.compile(r'\b(?:Mes|Msg|Say|Dialog|Option|Answer|Question)\s*\(\s*"((?:[^"\\]|\\.)+)"')

def extract(cities):
    seen, out = set(), []
    for f in glob.glob(os.path.join(ROOT, 'sources', 'scripts', '**', '*.gd'), recursive=True):
        parts = f.split(os.sep)
        if 'todas' not in cities and not any(c in parts for c in cities):
            continue
        for m in RE_MES.finditer(open(f, encoding='utf-8').read()):
            k = m.group(1).replace('\\"', '"')
            if k not in seen:
                seen.add(k); out.append(k)
    return out

def main():
    args = sys.argv[1:]
    write = '--write' in args
    args = [a for a in args if a != '--write']
    mp = runpy.run_path(args[0])['MAP']
    mp = sorted(mp, key=lambda t: -len(t[0]))  # longest prefix first
    keys = extract(args[1:])
    have = {r['keys'] for r in csv.DictReader(open(UI, newline='', encoding='utf-8'))}
    pairs, misses = [], []
    for k in keys:
        if k in have:
            continue
        hit = next((pt for pref, pt in mp if k.startswith(pref)), None)
        if hit is None:
            misses.append(k)
        else:
            pairs.append((k, hit))
    print("chaves extraídas: %d | já cobertas: %d | novos pares: %d | sem tradução: %d" %
          (len(keys), len(keys) - len(pairs) - len(misses), len(pairs), len(misses)))
    for k in misses:
        print("  SEM-MAP:", k[:90])
    if write and pairs:
        with open(UI, 'a', newline='', encoding='utf-8') as fh:
            w = csv.writer(fh, quoting=csv.QUOTE_ALL, lineterminator='\n')
            for k, pt in pairs:
                w.writerow([k, k, pt])
        print("csv +%d" % len(pairs))

if __name__ == '__main__':
    main()
