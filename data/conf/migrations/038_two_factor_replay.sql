CREATE TABLE IF NOT EXISTS two_factor_used_token (
	account_id INTEGER NOT NULL,
	token_hash TEXT NOT NULL,
	expires_at INTEGER NOT NULL,
	PRIMARY KEY (account_id, token_hash)
);
CREATE INDEX IF NOT EXISTS idx_two_factor_used_token_expires_at
	ON two_factor_used_token(expires_at);
