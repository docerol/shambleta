-- Q-6 (2026-10-07): budget diário do BossRush por personagem. O rush gasta 1 chave e
-- colhe a escada inteira em baús/chaves por vitória; com ouro infinito a compra de
-- chaves (sem teto) transformava o rush em faucet de ~434 chaves/dia/char — o mesmo
-- bucket UTC da loja (EconomyCatalog.ShopDay), durável como o cap de anúncio do AH
-- (063): um cap que vive em memória é um cap que reseta com o boot.
CREATE TABLE IF NOT EXISTS boss_rush_activity (
	char_id INTEGER NOT NULL,
	day INTEGER NOT NULL,
	runs INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (char_id, day)
);
