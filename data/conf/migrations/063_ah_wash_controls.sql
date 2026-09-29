-- 063 — Leilão com fricção e com memória de escrow (AUDITORIA rodada 3, cadeira
-- Marketplace 7,0/7,6: achados #93, #94 e #100).
--
-- (a) `expires_at` no anúncio. Até aqui o ask era ETERNO: `auction_listing`
-- (migração 018) tinha `status`, `created_at` e `escrow_uids`, mas nenhum prazo,
-- e não existia reaper nenhum em `sources/`. Consequência medida: a lavagem
-- A anuncia → B compra → B anuncia → A compra não precisava de mercado nenhum,
-- só de uma segunda conta disposta a esperar o anúncio para sempre com o item
-- trancado fora do inventário do dono. Anúncio que vence devolve o lote ao dono
-- (por linhagem, ver (b)); preço que ninguém aceita sai da vitrine sozinho.
-- `0` = linha sem prazo conhecido (anterior a esta migração, ou escrita por um
-- caminho que não é o do leilão): `ReapExpiredListings` ADOTA essas linhas na
-- primeira passada, em lote limitado (`expires_at = created_at + TTL`), em vez de
-- um UPDATE de dados dentro do patch — a migração fica DDL puro, como 001..062.
ALTER TABLE auction_listing ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0;
-- O reaper varre por "aberto cujo prazo venceu", limitado (nunca a tabela toda), e
-- é por aqui também que a adoção das linhas `expires_at = 0` entra.
CREATE INDEX IF NOT EXISTS idx_auction_expiring ON auction_listing(status, expires_at);
--
-- (b) `ah_escrow_lot` é o snapshot do escrow do anúncio. O
-- `ListItemForSale` consome lotes com `ConsumeItemLotsRaw`, que APAGA a linha de
-- `item_instance` (ou decresce o `count`), e guarda só a lista de uids em
-- `auction_listing.escrow_uids`. Isso basta para dar um `parentUID` ao lote do
-- comprador e não basta para DEVOLVER o item: `CancelListing` tinha de re-mintar
-- um lote novo (`_GrantStackRaw`), e list → cancel → re-list quebrava a cadeia de
-- `parent_uid` do item (achado #94 — o uid original já não existe, então o
-- `LotHistory` do lote novo morre no primeiro salto). Esta tabela é o snapshot
-- EXATO do que saiu do inventário — uid, unidades, bound, customfield,
-- parent_uid, creator_account_id e reason do lote consumido — escrita na MESMA
-- transação do anúncio. Com ela, cancelamento e reaper devolvem as UNIDADES AOS
-- MESMOS uids (row viva → soma `count`; row apagada → reinserção com o uid
-- original), e a liquidação dá a cada lote do comprador o seu PRÓPRIO pai, em vez
-- de `split(",")[0]` para o primeiro uid e nada para o resto da pilha.
-- Linha sem snapshot = anúncio pré-063 (ou fixture): os caminhos de devolução
-- declaram isso no código e caem no comportamento antigo, re-mint.
--
-- (c) `ah_activity` é o volume diário POR CONTA no leilão. A troca direta tinha
-- três fricções (e-mail verificado, cooldown de 60 s, teto diário —
-- `TradeChestService.gd:38-49`); o leilão não herdou nenhuma: só 5 gems de
-- anúncio e o cap de slots abertos. Contador durável (não é memória de sessão,
-- não é projeção do ledger — o ledger é podado pela retenção da migração 056),
-- com o dia UTC no mesmo bucket de `EconomyCatalog.ShopDay`. É escrito DENTRO da
-- transação que cria o anúncio e que liquida a compra: se o rollback desfaz o
-- movimento, desfaz o contador também.
CREATE TABLE IF NOT EXISTS ah_escrow_lot (
  listing_id INTEGER NOT NULL,
  uid INTEGER NOT NULL,
  item_id INTEGER NOT NULL,
  count INTEGER NOT NULL,
  bound INTEGER NOT NULL,
  customfield TEXT NOT NULL,
  parent_uid INTEGER NOT NULL,
  creator_account_id INTEGER NOT NULL,
  reason TEXT NOT NULL,
  lot_created_at INTEGER NOT NULL
);
-- Devolução por anúncio (cancelamento e reaper) e pais do lote do comprador:
-- sempre a chave `listing_id`, sempre o `uid` original junto.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ah_escrow_lot_listing ON ah_escrow_lot(listing_id, uid);

CREATE TABLE IF NOT EXISTS ah_activity (
  account_id INTEGER NOT NULL,
  day INTEGER NOT NULL,
  lists INTEGER NOT NULL,
  buys INTEGER NOT NULL,
  PRIMARY KEY (account_id, day)
);
