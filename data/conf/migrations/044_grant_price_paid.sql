-- 044 — Preço pago na fila de grant (AUDITORIA_INDEPENDENTE_2026-09-24 §"Receita em
-- dinheiro": "grant_queue.amount guarda gems concedidas, não o preço pago ...
-- Correção mínima: price_paid + currency na fila de grant"). Sem isto as metas do
-- ROADMAP_COMERCIAL (ARPPU, VIP ≥ 60% da receita) não têm o que dividir: /metrics
-- agregava SUM(amount) por SKU e chamava aquilo de venda, que é unidade de jogo.
--
-- Unidade menor (centavos) em INTEGER: SQLite não tem ponto fixo e float em
-- caminho de dinheiro é como se perde dinheiro. O float só existe na borda do
-- provedor (transaction_amount), já convertido aqui. Moeda junto porque o
-- provedor não garante a mesma do catálogo.
--
-- Bundle (um SKU que concede N itens) gera N linhas com o mesmo sku e a mesma
-- chave de pagamento: o preço vai na primeira e 0 nas demais, senão
-- SUM(price_paid) contaria a mesma compra N vezes.
ALTER TABLE grant_queue ADD COLUMN price_paid INTEGER NOT NULL DEFAULT 0;
ALTER TABLE grant_queue ADD COLUMN currency TEXT NOT NULL DEFAULT '';
