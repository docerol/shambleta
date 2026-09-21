CREATE INDEX IF NOT EXISTS idx_character_account ON character(account_id);
CREATE INDEX IF NOT EXISTS idx_item_char_item ON item(char_id, item_id, storage);
