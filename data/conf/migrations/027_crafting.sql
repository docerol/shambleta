-- SOM-IDLE Fase H: criação de itens por jogadores (ITEM_CRAFTING.md, v1 gold).
-- craft_submission = fila de aprovação (pending/approved/rejected); template
-- aprovado entra no pool via craft_item_template (dicionário paralelo ao
-- ItemsDB de boot); creator_account_id carimba cada instância p/ a fee de 1%.
CREATE TABLE IF NOT EXISTS craft_submission (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  char_id INTEGER NOT NULL,
  slot INTEGER NOT NULL,
  name TEXT NOT NULL,
  template_hash INTEGER NOT NULL,
  tier INTEGER NOT NULL,
  modifiers_json TEXT NOT NULL DEFAULT '[]',
  budget_used INTEGER NOT NULL DEFAULT 0,
  rarity TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending',
  submits_used INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  decided_at INTEGER NOT NULL DEFAULT 0,
  decided_by INTEGER NOT NULL DEFAULT 0,
  decide_reason TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_craft_status ON craft_submission(status, id);
CREATE TABLE IF NOT EXISTS craft_item_template (
  item_hash INTEGER PRIMARY KEY,
  slot INTEGER NOT NULL,
  name TEXT NOT NULL,
  tier INTEGER NOT NULL,
  modifiers_json TEXT NOT NULL DEFAULT '[]',
  template_hash INTEGER NOT NULL,
  rarity TEXT NOT NULL DEFAULT '',
  creator_account_id INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS craft_name_blocklist (
  term TEXT PRIMARY KEY
);
ALTER TABLE item_instance ADD COLUMN creator_account_id INTEGER NOT NULL DEFAULT 0;
