-- 042 — Funnel indexes (ROADMAP_COMERCIAL S1/S3: dashboard + d1_return query).
-- Cobre (account_id, kind, created_at): funil por conta e D1 distinto.
CREATE INDEX IF NOT EXISTS idx_telemetry_account_kind_time ON telemetry_event(account_id, kind, created_at);
