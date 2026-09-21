CREATE TABLE IF NOT EXISTS consent_log (
	account_id INTEGER NOT NULL,
	terms_version TEXT NOT NULL,
	privacy_version TEXT NOT NULL,
	accepted_at INTEGER NOT NULL,
	ip_hash TEXT,
	PRIMARY KEY (account_id, terms_version, privacy_version)
);
CREATE INDEX IF NOT EXISTS idx_consent_log_account_id ON consent_log(account_id);
