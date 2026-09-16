-- SOM-IDLE: rebirth engine (híbrido B+C escolhido pelo owner em 2026-07;
-- decisão quantificada em som-idle-docs/REBALANCE_XP_OPTIONS.md, contrato em
-- XP_PROGRESSION.md §4.2). Cap de nível passa a 60; XP acima do cap converte
-- em essência (1:100), gasta na loja de bônus permanentes (custo 1.7^n —
-- superlinear por desenho: evita o burnout geométrico demonstrado na sim).
ALTER TABLE character ADD COLUMN essence INTEGER NOT NULL DEFAULT 0;
ALTER TABLE character ADD COLUMN rebirths INTEGER NOT NULL DEFAULT 0;
ALTER TABLE character ADD COLUMN favor_xp INTEGER NOT NULL DEFAULT 0;
ALTER TABLE character ADD COLUMN favor_gold INTEGER NOT NULL DEFAULT 0;
ALTER TABLE character ADD COLUMN attune_offline INTEGER NOT NULL DEFAULT 0;
