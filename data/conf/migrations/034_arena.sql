-- SOM-IDLE R3 (COMMUNITY_ROADMAP): arena assíncrona.
-- arena_entry armazena ticket diário + defesa salva por conta.
-- arena_ladder armazena ranking ELO simplificado.
CREATE TABLE IF NOT EXISTS arena_entry (
	account_id INTEGER PRIMARY KEY,
	tickets INTEGER NOT NULL DEFAULT 0,
	ticket_reset_at INTEGER NOT NULL DEFAULT 0,
	defense_char_id INTEGER NOT NULL DEFAULT 0,
	defense_snapshot TEXT NOT NULL DEFAULT '',
	updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS arena_ladder (
	account_id INTEGER PRIMARY KEY,
	elo INTEGER NOT NULL DEFAULT 1000,
	wins INTEGER NOT NULL DEFAULT 0,
	losses INTEGER NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL
);
