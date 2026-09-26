-- 047 — Performance Indexes III (os dois ORDER BY quentes do jogo)
-- Leaderboard (`SQL.GetLeaderboard`): ORDER BY power_score DESC, char_id ASC LIMIT n.
-- Sem índice dedicado o SQLite materializava temp B-tree sobre a tabela inteira
-- (5,07 ms medido hoje numa réplica sintética de 30k personagens, linear no
-- tamanho da tabela); com ele, 0,04 ms na mesma réplica. ASC na segunda coluna é
-- o que a query pede — um índice só crescente seria varrido ao contrário e daria
-- (DESC, DESC).
CREATE INDEX IF NOT EXISTS idx_character_leaderboard ON character(power_score DESC, char_id ASC);

-- Navegação do leilão (`AuctionHouseService.BrowseListings`): WHERE status = 'open'
-- ORDER BY highlight DESC, id DESC LIMIT n. O `idx_auction_open(status, id)` de 018
-- serve filtro por id, não esta ordenação (2,89 ms em temp B-tree → 0,01 ms).
CREATE INDEX IF NOT EXISTS idx_auction_browse ON auction_listing(status, highlight DESC, id DESC);
