-- C-6 (2026-10-06): o portão de ciclo de lavagem pergunta EXISTÊNCIA do par
-- (item, vendedor, comprador) dentro da janela a cada settle. Sem índice no par,
-- o SELECT varre o histórico inteiro do item — e como cada settle também grava
-- em ah_price_history, o custo do portão crescia com o próprio mercado (o
-- benchmark pegou: p99 do settle estourou a régua de regressão).
-- `idx_ah_price_history_item` (059) só cobre (item_id, sold_at).
CREATE INDEX IF NOT EXISTS idx_ah_price_history_pair ON ah_price_history(item_id, seller_account, buyer_account, sold_at);
