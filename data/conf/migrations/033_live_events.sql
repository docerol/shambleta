-- SOM-IDLE R3 (COMMUNITY_ROADMAP): eventos temporários rotativos.
-- live_event armazena o kind + janela temporal + params_json.
-- O job diário (TickLiveEvents) ativa/desativa por timestamp; params_json
-- carrega os modificadores do evento (ex.: {"drops_mod": 2.0}).
CREATE TABLE IF NOT EXISTS live_event (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	kind TEXT NOT NULL,
	starts_at INTEGER NOT NULL,
	ends_at INTEGER NOT NULL,
	params_json TEXT NOT NULL DEFAULT '{}',
	created_at INTEGER NOT NULL
);

-- SOM-IDLE R3: tick de ativação (idempotência por event_id + ticked_at).
CREATE TABLE IF NOT EXISTS live_event_tick (
	event_id INTEGER NOT NULL,
	ticked_at INTEGER NOT NULL,
	PRIMARY KEY (event_id, ticked_at)
);
