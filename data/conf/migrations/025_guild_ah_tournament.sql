-- SOM-IDLE Fase F: guild/AH premium + torneios (MONETIZATION §1 itens 8/10/11).
-- auction_listing.highlight = destaque pago; guild.vault_slots_purchased =
-- expansões do vault; ah_slots = slots extras de anúncio; tournament (+entry)
-- = copas com inscrição em gold (nunca dinheiro — risco loteria/azar no BR).
ALTER TABLE auction_listing ADD COLUMN highlight INTEGER NOT NULL DEFAULT 0;
ALTER TABLE guild ADD COLUMN vault_slots_purchased INTEGER NOT NULL DEFAULT 0;
CREATE TABLE IF NOT EXISTS ah_slots (
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  extra INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id)
);
CREATE TABLE IF NOT EXISTS tournament (
  tournament_id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  entry_gold INTEGER NOT NULL,
  starts_at INTEGER NOT NULL,
  ends_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  prizes_json TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS tournament_entry (
  tournament_id INTEGER NOT NULL REFERENCES tournament(tournament_id),
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  char_id INTEGER NOT NULL,
  power_start INTEGER NOT NULL DEFAULT 0,
  power_end INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (tournament_id, account_id)
);
