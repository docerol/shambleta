-- SOM-IDLE Fase B: VIP com cap diferenciado + loja diária/ofertas (MONETIZATION
-- §2.2/§2.6). vip_tier distingue o cap offline (0 = 12h F2P, 1 = 24h, 2 = 36h);
-- shop_daily guarda a rotação do dia por conta; shop_offer_claim marca ofertas
-- one-time (packs de boss, fim de temporada).
ALTER TABLE account ADD COLUMN vip_tier INTEGER NOT NULL DEFAULT 0;
CREATE TABLE IF NOT EXISTS shop_daily (
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  day INTEGER NOT NULL,
  salt INTEGER NOT NULL DEFAULT 0,
  offers_json TEXT NOT NULL DEFAULT '[]',
  claimed_json TEXT NOT NULL DEFAULT '[]',
  rerolls_used INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, day)
);
CREATE TABLE IF NOT EXISTS shop_offer_claim (
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  offer_id TEXT NOT NULL,
  claimed_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, offer_id)
);
