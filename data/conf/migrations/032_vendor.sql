-- SOM-IDLE R2 (COMMUNITY_ROADMAP): estoque diário da loja gold (vendor).
-- Uma linha por (conta, dia, oferta) com a quantidade já comprada.
CREATE TABLE IF NOT EXISTS vendor_claim (
	account_id INTEGER NOT NULL,
	day INTEGER NOT NULL,
	offer_id TEXT NOT NULL,
	count INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (account_id, day, offer_id)
);
