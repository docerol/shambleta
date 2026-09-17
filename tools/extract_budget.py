#!/usr/bin/env python3
"""Extrai dos 65 .tres o teto de orçamento por (tier, slot) p/ ITEM_CRAFTING.

Teto = maior soma bruta de modifiers entre os itens reais da célula (pesos
1:1 — CRAFT_MOD_WEIGHTS; recalibrar pesos NÃO muda este script, só a const).
Somente leitura: imprime a tabela GDScript p/ colar em EconomyService +
checa células vazias (tiers 6-8 sem precedente real).
Uso: python3 tools/extract_budget.py
"""
import os
import re
import sys

SLOTS = {0: "CHEST", 1: "LEGS", 2: "FEET", 3: "HANDS", 4: "HEAD",
         5: "NECK", 6: "WEAPON", 7: "SHIELD"}
MODS = ["None", "Health", "Mana", "Stamina", "MaxMana", "RegenMana",
        "CritRate", "MAttack", "MDefense", "MaxStamina", "RegenStamina",
        "CooldownDelay", "MaxHealth", "RegenHealth", "Defense", "CastDelay",
        "DodgeRate", "AttackRange", "WalkSpeed", "WeightCapacity", "Attack",
        "Hide", "Invisible", "Count"]

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "..", "presets", "cells", "items")


def parse_tres(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    mslot = re.search(r"^slot\s*=\s*(\d+)", txt, re.M)
    mtier = re.search(r"^tier\s*=\s*(\d+)", txt, re.M)
    if not mslot or not mtier:
        return None
    slot, tier = int(mslot.group(1)), int(mtier.group(1))
    if slot not in SLOTS:
        return None  # consumível/quest/baú — fora do crafting de equipamento
    name = re.search(r'^name\s*=\s*"([^"]+)"', txt, re.M).group(1)
    mods = []
    for m in re.finditer(
            r"_effect\s*=\s*(\d+).*?_value\s*=\s*([0-9.eE+-]+)", txt, re.S):
        mods.append((int(m.group(1)), float(m.group(2))))
    return slot, tier, name, mods


def main():
    cells = {}
    count = 0
    skipped = 0
    for dirpath, _dirs, files in os.walk(ROOT):
        for fn in sorted(files):
            if not fn.endswith(".tres"):
                continue
            parsed = parse_tres(os.path.join(dirpath, fn))
            if parsed is None:
                skipped += 1
                continue
            slot, tier, name, mods = parsed
            count += 1
            # Soma só POSITIVOS: negativos (ex. WalkSpeed-10) são drawback
            # livre, não orçamento. Célula 0 = sem precedente real = crafting
            # bloqueado naquele (tier, slot) até existir item real melhor.
            total = round(sum(v for _e, v in mods if v > 0))
            key = (tier, SLOTS.get(slot, "SLOT%d" % slot))
            detail = "%s=%s" % (name, "+".join(
                "%s%s" % (MODS[e] if e < len(MODS) else "M%d" % e,
                          ("%g" % v)) for e, v in mods))
            if key not in cells or total > cells[key][0]:
                cells[key] = (total, detail)
    print("# %d itens de equipamento lidos (%d não-equipamento pulados)"
          % (count, skipped))
    print("# células (tier, slot) SEM precedente real:",
          sorted(set((t, s) for t in range(1, 9) for s in SLOTS.values())
                 - set(cells)))
    print("const CRAFT_BUDGET_CAP : Dictionary = {")
    for tier in range(1, 9):
        row = []
        for _i, slot in sorted(SLOTS.items()):
            total, _detail = cells.get((tier, slot), (0, "-"))
            row.append("%d" % total)
        print("\t%d: [%s]," % (tier, ", ".join(row)))
    print("}")
    print("# slots ordem: %s" % [SLOTS[i] for i in sorted(SLOTS)])
    print("# detalhe do máximo por célula:")
    for key in sorted(cells):
        print("#   %s: %d (%s)" % (key, cells[key][0], cells[key][1]))


if __name__ == "__main__":
    sys.exit(main())
