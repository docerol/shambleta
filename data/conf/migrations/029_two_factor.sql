-- SOM-IDLE S4: TOTP two-factor authentication for admin/GM accounts.
-- Columns: two_factor_secret (base32), two_factor_enabled (0/1).
ALTER TABLE account ADD COLUMN two_factor_secret TEXT DEFAULT '';
ALTER TABLE account ADD COLUMN two_factor_enabled INTEGER NOT NULL DEFAULT 0;
