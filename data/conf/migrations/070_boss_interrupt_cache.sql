-- Q-1 (2026-10-07): o interrupt demonstrado na luta ao vivo passa a valer no BossRush.
-- A sim do rush resolvia sem o multiplicador da mecânica ativa — o jogador nunca era
-- pago por uma habilidade que exerceu. O cache guarda o MELHOR mult dentro da janela
-- (EconomyCatalog.BossInterruptCacheSec); quem nunca acertou a janela corre com 1.0,
-- exatamente como antes. Colunas novas com default: sem wipe, forma da 037.
ALTER TABLE character ADD COLUMN interrupt_mult REAL NOT NULL DEFAULT 0;
ALTER TABLE character ADD COLUMN interrupt_at INTEGER NOT NULL DEFAULT 0;
