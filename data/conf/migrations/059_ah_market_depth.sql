-- 059 — Mercado com memória e com demanda: histórico de preço REALIZADO e
-- ordens de compra (buy orders) na auction house (JUIZ MARKETPLACE 2026-09-27,
-- nota 8.5: "a AH é ask-only, sem paginação e sem estado").
--
-- (a) `ah_price_history` é a perna que faltava no "preço justo": até aqui o
-- único histórico de venda existia na memória do client
-- (`AuctionHouseWindow._history`, perdido ao fechar a janela) e não havia
-- nenhum preço realizado no servidor — quem anunciava não tinha como saber o
-- que o item VENDEU, só o que está PEDIDO (`auction_listing.price_gold` é ask,
-- e ask alto é autoindulgente). A linha é escrita na MESMA transação que
-- liquida a venda (em `AuctionHouseService`: ou o gold move e a história
-- existe, ou nada acontece) e tem `UNIQUE(listing_id)`: um anúncio liquida uma
-- vez, então o histórico não tem como ser duplicado por retry, e um segundo
-- INSERT na mesma linha é erro de programa capturado pela transação.
-- Sem `DEFAULT` e sem colunas de data nativas: `sold_at` é o INTEIRO de
-- `SQLCommons.Timestamp()` (mesma convenção de `auction_listing.created_at`,
-- migração 018), e toda coluna é escrita explicitamente pelo serviço.
--
-- (b) `ah_buy_order` é a demanda: até aqui só existia a oferta (ask), e um
-- mercado com só ordens de venda tem spread infinito e não fecha em preço
-- nenhum. Uma ordem de compra deposita gold ANTES de existir o item — é
-- espelho exato do escrow de item de `ListItemForSale`, que tira o lote do
-- personagem antes de existir o comprador. Por isso o gold entra pelo ÚNICO
-- caminho do kernel (`_MoveGoldLocked` + `ApplyGoldMoves`, ver o cabeçalho de
-- AuctionHouseService.gd): `escrow_gold` é o TOTAL ainda depositado nesta
-- ordem, e todo centavo dele tem uma linha de gold no `ledger_transaction`
-- (débito no depósito, crédito no estorno, e o pagamento ao vendedor no
-- preenchimento). Preenchimento parcial é a regra, não exceção: a ordem tem
-- `quantity` regressiva e o que sobra continua escrowed.
CREATE TABLE IF NOT EXISTS ah_price_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  listing_id INTEGER NOT NULL,
  item_id INTEGER NOT NULL,
  count INTEGER NOT NULL,
  unit_price INTEGER NOT NULL,
  price_gold INTEGER NOT NULL,
  buyer_account INTEGER NOT NULL,
  seller_account INTEGER NOT NULL,
  via TEXT NOT NULL,
  sold_at INTEGER NOT NULL
);
-- O índice do painel: "últimas vendas DESTE item, mais recentes primeiro".
CREATE INDEX IF NOT EXISTS idx_ah_price_history_item ON ah_price_history(item_id, sold_at);
-- Um anúncio, uma liquidação, uma linha de histórico.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ah_price_history_listing ON ah_price_history(listing_id);

CREATE TABLE IF NOT EXISTS ah_buy_order (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  buyer_char INTEGER NOT NULL,
  buyer_account INTEGER NOT NULL,
  item_id INTEGER NOT NULL,
  quantity INTEGER NOT NULL,
  unit_price INTEGER NOT NULL,
  escrow_gold INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
-- Casamento de ordem nova contra anúncio novo: procura por item e teto de
-- preço, do maior teto para o menor (`ORDER BY unit_price DESC, id ASC` no
-- serviço — o melhor pagador primeiro, e em empate o mais antigo).
CREATE INDEX IF NOT EXISTS idx_ah_buy_order_item ON ah_buy_order(item_id, status, unit_price);
-- Guard de cap por conta e o "minhas ordens" do painel.
CREATE INDEX IF NOT EXISTS idx_ah_buy_order_account ON ah_buy_order(buyer_account, status);
