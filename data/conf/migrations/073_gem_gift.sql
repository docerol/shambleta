-- M-3 (2026-10-07): gifting de gems conta-a-conta. A linha do presente É a
-- guarda: `from_account`/`to_account` com `created_at` alimentam o cooldown
-- anti-flip (A→B e B→A na mesma janela é lavagem, não amizade), e o `day` no
-- bucket UTC da loja (EconomyCatalog.ShopDay) sustenta o teto diário durável —
-- um cap em memória reseta com o boot, e um flip em memória esquece com ele.
-- A moeda em si vive no ledger (gift_out/gift_fee/gift_in); esta tabela é o
-- registro DA RELAÇÃO, não da carteira.
CREATE TABLE IF NOT EXISTS gem_gift (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	from_account INTEGER NOT NULL,
	to_account INTEGER NOT NULL,
	gems INTEGER NOT NULL,
	fee INTEGER NOT NULL,
	day INTEGER NOT NULL,
	created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_gem_gift_from_day ON gem_gift (from_account, day);
CREATE INDEX IF NOT EXISTS idx_gem_gift_pair_time ON gem_gift (from_account, to_account, created_at);
