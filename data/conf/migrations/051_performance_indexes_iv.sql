-- 051 — Performance Indexes IV (presença do vendedor no leilão)
-- P1-11: as consultas quentes por vendedor filtram `auction_listing` por
-- `seller_account` — cancelamento em lote (`AuctionHouseService`: WHERE
-- seller_account = %d AND status = 'open'), dedupe de listagem de bot
-- (WHERE seller_account = ? AND item_id = ?) e a purga de conta/LGPD
-- (`SQL`: DELETE FROM auction_listing WHERE seller_account = ?). Sem índice o
-- SQLite varria a tabela inteira em cada uma; `idx_auction_open(status, id)` de
-- 018 não serve filtro por vendedor. Mesmo formato dos índices de 041/047.
CREATE INDEX IF NOT EXISTS idx_auction_listing_seller_account ON auction_listing(seller_account);
