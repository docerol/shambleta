-- SOM-IDLE Fase C: passe de temporada S1 (BATTLE_PASS_S1.md). PT (Pontos de
-- Temporada) por conta/temporada; missões com progresso/claim idempotente;
-- cosmetic_grant guarda cosméticos (uso pleno na Fase D: entitlements).
CREATE TABLE IF NOT EXISTS season_account_state (
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  season_id INTEGER NOT NULL REFERENCES season(season_id),
  pt INTEGER NOT NULL DEFAULT 0,
  premium INTEGER NOT NULL DEFAULT 0,
  claimed_free TEXT NOT NULL DEFAULT '[]',
  claimed_premium TEXT NOT NULL DEFAULT '[]',
  skips_used INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, season_id)
);
CREATE TABLE IF NOT EXISTS season_mission_state (
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  season_id INTEGER NOT NULL REFERENCES season(season_id),
  mission_id TEXT NOT NULL,
  period_id TEXT NOT NULL,
  progress INTEGER NOT NULL DEFAULT 0,
  goal INTEGER NOT NULL DEFAULT 1,
  claimed INTEGER NOT NULL DEFAULT 0,
  claimed_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, season_id, mission_id, period_id)
);
CREATE TABLE IF NOT EXISTS cosmetic_grant (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  cosmetic_id TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '',
  granted_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cosmetic_account ON cosmetic_grant(account_id);
