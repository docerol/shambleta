-- P1-1: CHECK constraints em tabelas economicas (requer recreacao em SQLite).
-- Verificado no codigo: apenas 1 CHECK existente (storage IN (0,1) na migration 001).
-- Este patch recria as tabelas com CHECK e copia os dados; falha aborta sem corromper.
-- DDL explicito por coluna: o schema vivo difere do template de origem — wallet
-- ganhou gems_paid (049), auction_listing ganhou highlight (025), creator_account_id
-- (028) e expires_at (063), item_instance ganhou creator_account_id (027). Um
-- `INSERT ... SELECT *` cego racha a aplicacao no boot (fail-closed, MigrationBlocked).
-- DROP TABLE leva indices e triggers grudados na tabela: os seis indices historicos
-- do leilao e o trg_auction_listing_delete (067) sao recriados abaixo, senao o
-- censo de orfaos de escrow morre em silencio. E o trg_character_delete (066) nao
-- esta grudado em nada que recriamos — ele VIVE na character e aponta para
-- item_instance e auction_listing no corpo: enquanto as duas nao existem com esse
-- nome (entre o DROP e o RENAME), o recompile da schema racha o boot no patch 67.
-- Ele sai no alto e volta inteiro no fim, copia fiel da 066.

BEGIN TRANSACTION;

-- Dependent trigger first: it must not be alive while its target tables are gone.
DROP TRIGGER IF EXISTS trg_character_delete;

-- Wallet: gems nao pode ser negativo (sink anti-duplicacao/infla).
CREATE TABLE wallet_new (
  account_id INTEGER NOT NULL,
  gems BIGINT NOT NULL DEFAULT 0 CHECK (gems >= 0),
  updated_at INTEGER NOT NULL DEFAULT 0,
  gems_paid INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id)
);
INSERT INTO wallet_new (account_id, gems, updated_at, gems_paid)
  SELECT account_id, gems, updated_at, gems_paid FROM wallet;
DROP TABLE wallet;
ALTER TABLE wallet_new RENAME TO wallet;

-- Auction listing: count e price devem ser positivos (previne ordem corrompida).
CREATE TABLE auction_listing_new (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  seller_char INTEGER NOT NULL REFERENCES character(char_id),
  seller_account INTEGER NOT NULL REFERENCES account(account_id),
  item_id INTEGER NOT NULL,
  count INTEGER NOT NULL CHECK (count > 0),
  price_gold INTEGER NOT NULL CHECK (price_gold > 0),
  escrow_uids TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',
  created_at INTEGER NOT NULL,
  highlight INTEGER NOT NULL DEFAULT 0,
  creator_account_id INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER NOT NULL DEFAULT 0
);
INSERT INTO auction_listing_new (id, seller_char, seller_account, item_id, count,
  price_gold, escrow_uids, status, created_at, highlight, creator_account_id, expires_at)
  SELECT id, seller_char, seller_account, item_id, count,
  price_gold, escrow_uids, status, created_at, highlight, creator_account_id, expires_at
  FROM auction_listing;
DROP TABLE auction_listing;
ALTER TABLE auction_listing_new RENAME TO auction_listing;
CREATE INDEX idx_auction_open ON auction_listing(status, id);
CREATE INDEX idx_auction_creator ON auction_listing(creator_account_id);
CREATE INDEX idx_auction_browse ON auction_listing(status, highlight DESC, id DESC);
CREATE INDEX idx_auction_listing_seller_account ON auction_listing(seller_account);
CREATE INDEX idx_auction_listing_seller_char ON auction_listing(seller_char);
CREATE INDEX idx_auction_expiring ON auction_listing(status, expires_at);
CREATE TRIGGER trg_auction_listing_delete
AFTER DELETE ON auction_listing
FOR EACH ROW
BEGIN
    DELETE FROM ah_escrow_lot WHERE listing_id = OLD.id;
END;

-- Item instance: count nao pode ser negativo (invariante FIFO/sink).
CREATE TABLE item_instance_new (
  uid INTEGER PRIMARY KEY AUTOINCREMENT,
  char_id INTEGER NOT NULL REFERENCES character(char_id),
  item_id INTEGER NOT NULL,
  count INTEGER NOT NULL CHECK (count >= 0),
  storage INTEGER NOT NULL DEFAULT 0 CHECK (storage IN (0, 1)),
  bound INTEGER NOT NULL DEFAULT 0,
  customfield TEXT NOT NULL DEFAULT '',
  reason TEXT NOT NULL DEFAULT '',
  parent_uid INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  creator_account_id INTEGER NOT NULL DEFAULT 0
);
INSERT INTO item_instance_new (uid, char_id, item_id, count, storage, bound, customfield,
  reason, parent_uid, created_at, creator_account_id)
  SELECT uid, char_id, item_id, count, storage, bound, customfield,
  reason, parent_uid, created_at, creator_account_id FROM item_instance;
DROP TABLE item_instance;
ALTER TABLE item_instance_new RENAME TO item_instance;
CREATE INDEX idx_item_instance_char ON item_instance(char_id, item_id);
CREATE INDEX idx_item_instance_parent ON item_instance(parent_uid);

-- A cascata da 066 de volta, verbatim, com as duas tabelas-alvo existindo.
CREATE TRIGGER trg_character_delete
AFTER DELETE ON character
FOR EACH ROW
BEGIN
    DELETE FROM trait WHERE char_id = OLD.char_id;
    DELETE FROM attribute WHERE char_id = OLD.char_id;
    DELETE FROM stat WHERE char_id = OLD.char_id;
    DELETE FROM equipment WHERE char_id = OLD.char_id;
    DELETE FROM item WHERE char_id = OLD.char_id;
    DELETE FROM item_instance WHERE char_id = OLD.char_id;
    DELETE FROM skill WHERE char_id = OLD.char_id;
    DELETE FROM quest WHERE char_id = OLD.char_id;
    DELETE FROM bestiary WHERE char_id = OLD.char_id;
    DELETE FROM chest_instance WHERE char_id = OLD.char_id;
    DELETE FROM auction_listing WHERE seller_char = OLD.char_id;
END;

COMMIT;
