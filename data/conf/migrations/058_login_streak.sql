-- 058 — Gatilho de retorno: streak diário de login (AUDITORIA_2026-09-27 §6 —
-- "sem streaks em lugar nenhum"). Estado puramente server-side: a linha guarda
-- o dia como inteiro derivado de `EconomyCatalog.ShopDay` (mesmo divisor UTC
-- dos resets de loja/passe/baú-de-settle) — data de cliente nunca entra aqui,
-- quem decide o dia é o relógio do servidor em `StreakService.RecordLogin`.
-- A escada de recompensa é código (LadderGold), nada de prêmio em SQL.
CREATE TABLE IF NOT EXISTS login_streak (
	char_id INTEGER PRIMARY KEY,
	current_streak INTEGER NOT NULL DEFAULT 0,
	best_streak INTEGER NOT NULL DEFAULT 0,
	last_day INTEGER NOT NULL DEFAULT -1,
	updated_at INTEGER NOT NULL DEFAULT 0
);
