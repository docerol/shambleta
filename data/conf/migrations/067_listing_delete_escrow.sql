-- 067 — WorkOrder #168: apagar um anúncio leva o retrato do escrow.
--
-- A migration 066 ensinou o `trg_character_delete` a levar o anúncio junto. O
-- anúncio morre, e a linha que descreve o que estava preso nele sobrevive:
-- `ah_escrow_lot` (063) é o snapshot do escrow — uma linha por (anúncio, uid) —
-- e quem apaga anúncio é o serviço, na liquidação e no reaper
-- (`_ClearEscrowSnapshotLocked`), nunca o schema. Apagar o personagem ou a conta
-- derruba a linha de `auction_listing` por fora do serviço, e o retrato fica.
--
-- Medido em 2026-10-02 na `testing.db` do próprio sandbox
-- `.test-home/run_idle_tests/`: 8 linhas em `ah_escrow_lot`, ZERO linhas em
-- `auction_listing`, e 0 de 8 `uid` ainda presentes em `item_instance` — retrato
-- de um mercado que não existe mais, apontando para itens que também não existem.
-- Na mesma varredura, `.test-home/faucet_census_test/` tinha 6 lotes e 6 anúncios
-- vivos: o órfão não é custo de harness, é o rastro de quem apagou dono.
--
-- Isso é lixo por leitura, não por gosto: todo consumidor desta tabela pede o lote
-- POR ANÚNCIO — `_RestoreEscrowLocked` lê, `_ClearEscrowSnapshotLocked` apaga e
-- `_WriteEscrowSnapshotLocked` escreve, os três por `listing_id`. Sem a linha do
-- anúncio ninguém jamais pergunta por
-- aquele lote de novo — nem para devolver, nem para auditar. O `listing_id` é
-- rowid de `auction_listing` e não é reutilizado, então a linha também não pode
-- casar com um anúncio futuro.
--
-- Fica de fora, deliberadamente: `ah_price_history`. Na mesma cópia do sandbox do
-- idle eram 5 linhas cujos anúncios morreram, e ela NÃO entra na cascata porque
-- nenhum dos seus leitores pede por anúncio — `AuctionHouseService.RecentSoldPrices`
-- ordena por `item_id`/`sold_at`, `AuctionHousePricing.AHPriceAnchor` pede a banda
-- por `item_id`, `FraudeReview._CollectAHWashPairs` varre a janela de lavagem por
-- `sold_at`, e o `via` do painel conta venda realizada, que aconteceu. É registro
-- de preço pago, mesma classe do `ledger_transaction` da 066: sobrevive ao dono.
--
-- Custo e por que a cascata de conta também é servida: um DELETE por anúncio
-- apagado, pela chave líder de `idx_ah_escrow_lot_listing` (063, UNIQUE em
-- `listing_id, uid`), que é exatamente o índice do caminho de devolução. Medido
-- numa cópia da `testing.db` do idle, com `recursive_triggers` OFF (o valor que o
-- produto nunca muda) no motor 3.53.4: `DELETE FROM account` levou a linha de
-- `character` e, de dentro do `trg_account_delete`, o `trg_character_delete`
-- rodou junto — stat/trait/attribute/equipment sumiram, `item_instance` sobrou
-- porque aquele banco era anterior à 066. Trigger que dispara dentro do corpo de
-- outro trigger vale para TABELA DIFERENTE; o único ajuste que governa isso é
-- `recursive_triggers`, e ele só governa o trigger disparando a SI MESMO. Então
-- este trigger pega as três rotas sem que nenhuma
-- delas precise conhecer a tabela: a devolução do serviço, a cascata do
-- personagem (066) e a erasure da conta.
--
-- Varredura: os retratos que já estão em banco vivo não vão sair sozinhos, e a
-- última vez que alguém os escreveu foi para um anúncio que não existe mais. O
-- DELETE do fim do arquivo roda dentro do `BEGIN TRANSACTION`/`COMMIT` que
-- `SQL.ApplyMigration` envelopa em torno deste patch, junto com o trigger: ou os
-- dois entram, ou nenhum. Medido: o DELETE aplicado como está no arquivo a uma
-- cópia da `testing.db` do sandbox `.test-home/run_idle_tests/` — 8 retratos, zero
-- anúncios, os 8 apontando para um mercado morto — devolve `orphans=0` e `lots=0`
-- sem tocar linha viva, porque linha viva nenhuma existe.
--
-- Régua: o censo de órfãos do portão ganha o eixo `listing_id`, cobrado pelo
-- DELTA como o de `char_id`, e `ah_price_history` entra na lista de registro que é
-- impresso e não cobrado. O controle planta os dois lados: lote de escrow sob
-- anúncio VIVO (não pode ser contado), anúncio apagado com o personagem (o lote
-- tem que sair — é a cadeia desta migration sendo exercida dentro do gate) e lote
-- sob um `listing_id` que nunca existiu (tem que ser contado). O plano do purge é
-- conferido no `EXPLAIN` contra `idx_ah_escrow_lot_listing`, que é da 063: esta
-- perna não morde no contrafactual de abaixo, ela guarda o índice que esta cascade
-- usa de alguém que o derrube.
--
-- Contrafactual medido no mesmo dia, com este arquivo fora do diretório de
-- migrations, banco do sandbox recriado e o portão rodando inteiro: 4 falha(s) em
-- vez de 2, e as duas a mais são as pernas do controle que exercitam a nesting —
-- `sobraram item=0, auction_listing=0, ah_escrow_lot=1 depois do DELETE, antes era
-- 0/0/0` e `o órfão arrancado não saiu da contagem (item 0→0, auction_listing 0→0,
-- ah_escrow_lot 0→2)`. As outras duas são a régua do settle, que este arquivo não
-- toca. O veredito do eixo ficou `0 na largada, 0 na chegada` nos dois lados do
-- experimento, e isso é informação, não atenuação: o caminho de leilão que este
-- portão percorre é o do serviço, que limpa o retrato na mesma transação — o órfão
-- nasce nas rotas que apagam o dono por fora do serviço, e é por isso que a régua
-- dele é o controle plantado, não a contagem do run.

DROP TRIGGER IF EXISTS trg_auction_listing_delete;
CREATE TRIGGER trg_auction_listing_delete
AFTER DELETE ON auction_listing
FOR EACH ROW
BEGIN
    DELETE FROM ah_escrow_lot WHERE listing_id = OLD.id;
END;
DELETE FROM ah_escrow_lot WHERE NOT EXISTS (SELECT 1 FROM auction_listing l WHERE l.id = ah_escrow_lot.listing_id);
