-- 041 — Performance Indexes II (analytics and lookups)
CREATE INDEX IF NOT EXISTS idx_ledger_account_kind ON ledger_transaction(account_id, kind, created_at);
CREATE INDEX IF NOT EXISTS idx_telemetry_account_created ON telemetry_event(account_id, created_at);
CREATE INDEX IF NOT EXISTS idx_fraud_status ON fraud_flag(status, created_at);
CREATE INDEX IF NOT EXISTS idx_guild_member_account ON guild_member(account_id);
CREATE INDEX IF NOT EXISTS idx_arena_entry_account ON arena_entry(account_id);
CREATE INDEX IF NOT EXISTS idx_shop_daily_account_day ON shop_daily(account_id, day);
CREATE INDEX IF NOT EXISTS idx_season_account ON season_account_state(account_id, season_id);
