-- 066 — WorkOrder #167: apagar um personagem leva o que pendura nele.
--
-- O `trg_character_delete` nasceu no template de bootstrap com quatro DELETEs —
-- stat, trait, attribute, equipment — que são exatamente as quatro linhas que o
-- `trg_character_new` mintava junto. Todo objeto de schema criado depois pendurou
-- linhas num `char_id` e ninguém mexeu na cascata: `item_instance` (012),
-- `chest_instance` (009), os anúncios por `seller_char` (018). Ou seja, apagar o
-- personagem levava a ficha e deixava o inventário.
--
-- Medido em 2026-10-02, neste mesmo arquivo fora do diretório de migrations e com
-- banco limpo: UMA corrida de `tests/benchmarks.gd` deixou 34.409 linhas órfãs —
-- 33.922 `item_instance`, 200 `auction_listing`, 129 `item`, 80 `bestiary`, 40
-- `skill`, 30 `quest`, 8 `chest_instance` — com zero personagens vivos. Não é
-- extravagância de harness — `SQL.RemoveCharacter` é rota de jogador
-- (`Server.DeleteCharacter`), e o `trg_account_delete` apaga personagens aos montes
-- na erasure.
--
-- A rota LGPD (`SQL.EraseAccount`) sempre soube a lista completa: eram os dez
-- DELETEs por personagem que ela executava antes de derrubar as linhas de
-- `character`. As duas rotas divergiam porque a lista morava num método e a
-- cascata no outro. Esta migration põe a cascata na lista — e aí
-- `RemoveCharacter`, `EraseAccount` e a cascata de conta passam a limpar do mesmo
-- jeito, por construção, sem depender de quem escreveu o DELETE.
--
-- 2026-10-02 (WorkOrder #169): a cópia do método foi apagada, então agora a lista
-- mora SÓ aqui. O que segura a mudança não é a prosa desta migration, é o censo
-- plantado no `SuiteLGPD`: uma linha em cada uma das onze tabelas antes da
-- erasure, zero depois, mais o retrato de escrow do anúncio. Contrafactual medido
-- no mesmo dia, com este arquivo fora do diretório e sandbox recriado do template:
-- exatamente SEIS pernas vão ao vermelho (item, item_instance, skill, quest,
-- bestiary, chest_instance) — as quatro que o template já levam ficam verdes, e o
-- anúncio com seu lote também, porque o DELETE por conta da própria rota os
-- alcança. Sétima falha do mesmo run, colateral e esperada: a régua de numeração
-- do boot acusa que o índice 65 não é o 066. É a mordida que diz que a
-- responsabilidade está no schema, e não no DELETE.
--
-- Custo: um DELETE por tabela por personagem apagado, cada um servido por chave
-- líder em `char_id` — PK de stat/trait/attribute/equipment/skill/quest/bestiary,
-- `idx_item_char_item` (040), `idx_item_instance_char` (012), `idx_chest_char` (009).
-- `auction_listing` não tinha índice por `seller_char` (só por `seller_account`),
-- então o cascade varreria a tabela de anúncios inteira a cada personagem; o
-- índice abaixo é o que fecha isso. O trabalho é proporcional às linhas do
-- personagem, não ao tamanho da tabela.
--
-- Ficam de fora, deliberadamente: `ledger_transaction` (append-only por
-- `ledger_transaction_no_delete`, criado em 009 e reafirmado em 056 — a retenção
-- fiscal sobrevive ao personagem, que é o que `tests/IdleTests.gd` assina como
-- "LEDGER preserved") e `telemetry_event` (série por CONTA, podada por tempo desde
-- a 065; o DELETE que a alcança é o da rota LGPD). Um órfão dessas duas tabelas é
-- registro, não lixo.
--
-- Varredura de limpeza: a cascata nova só vale para o DELETE que vier depois, e em
-- banco vivo o lixo já está dentro — cada `RemoveCharacter` desde o dia 1 deixou
-- herança. Os onze DELETEs do fim do arquivo varrem o acervo uma única vez, dentro
-- do `BEGIN TRANSACTION`/`COMMIT` que `SQL.ApplyMigration` envelopa em torno deste
-- patch: ou a cascata e a varredura entram juntas, ou nenhuma entra. `char_id` é
-- AUTOINCREMENT, então um órfão nunca volta
-- a ter dono: o que não tem personagem é inalcançável por construção, não está
-- "esperando". O censo de `tests/benchmarks.gd` cobra o DELTA justamente para não
-- acusar este run do que veio de antes — a régua não fica verde porque a varredura
-- existiu, nem vermelha porque ela não existiu no passado.
--
-- Régua: o mesmo censo dos dois lados da corrida, mais um controle plantado que
-- planta uma linha num personagem vivo (não pode ser contada) e uma num char_id que
-- nunca existiu (tem que ser contada), e ainda confere que apagar o personagem vivo
-- levou a filha — que é a cascata desta migration sendo exercida dentro do gate. E
-- confere no plano que o DELETE de anúncio usa `idx_auction_listing_seller_char` em
-- vez de varrer.
--
-- Contrafactual medido no mesmo dia, com este arquivo fora do diretório de
-- migrations e banco limpo: 6 falha(s) em vez de 2, e as linhas impressas são
-- `Censo de órfãos do char_id: 0 na largada, 34409 na chegada`, `Plano do purge de
-- anúncio por seller_char: SCAN auction_listing` e as duas pernas do controle —
-- `sobraram item=130, auction_listing=201 depois do DELETE, antes era 129/200` e
-- `o órfão arrancado não saiu da contagem (item 129→130, auction_listing 200→201)`.
DROP TRIGGER IF EXISTS trg_character_delete;
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
CREATE INDEX IF NOT EXISTS idx_auction_listing_seller_char ON auction_listing(seller_char);
DELETE FROM trait WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = trait.char_id);
DELETE FROM attribute WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = attribute.char_id);
DELETE FROM stat WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = stat.char_id);
DELETE FROM equipment WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = equipment.char_id);
DELETE FROM item WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = item.char_id);
DELETE FROM item_instance WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = item_instance.char_id);
DELETE FROM skill WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = skill.char_id);
DELETE FROM quest WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = quest.char_id);
DELETE FROM bestiary WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = bestiary.char_id);
DELETE FROM chest_instance WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = chest_instance.char_id);
DELETE FROM auction_listing WHERE NOT EXISTS (SELECT 1 FROM character c WHERE c.char_id = auction_listing.seller_char);
