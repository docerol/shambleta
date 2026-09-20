-- Conquistas one-time (sem wipe): progresso derivado dos contadores
-- existentes (bestiary, chest_instance, bosses_beaten, level, rebirths);
-- aqui só vive o resgate (idempotente por PK).
CREATE TABLE IF NOT EXISTS achievement_state (
  account_id INTEGER NOT NULL,
  achievement_id TEXT NOT NULL,
  claimed INTEGER NOT NULL DEFAULT 0,
  claimed_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, achievement_id)
);
