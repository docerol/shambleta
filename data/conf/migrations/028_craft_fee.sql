-- SOM-IDLE Fase H §7: creator fee de 1% no AH (BuyListing).
-- Captura creator_account_id no momento do list (os lotes são deletados ao
-- consumir no escrow), permitindo a fee no momento da compra sem re-ler lotes
-- já apagados.
ALTER TABLE auction_listing ADD COLUMN creator_account_id INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_auction_creator ON auction_listing(creator_account_id);
