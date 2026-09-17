-- Follow-ups Fase F: estorno do dinheiro (companion lê refund_notified) + tags
-- de guild (2–5 chars A-Z0-9, definidas pelo líder).
ALTER TABLE grant_queue ADD COLUMN refund_notified INTEGER NOT NULL DEFAULT 0;
ALTER TABLE guild ADD COLUMN tag TEXT NOT NULL DEFAULT '';
