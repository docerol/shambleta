-- 048 — Nonce de anúncio de uso único (AUDITORIA_INDEPENDENTE_2026-09-24 C2)
--
-- O credential do rewarded ad era um formato público: `stub:<placement>:<dia>`
-- era derivável por qualquer client (a string era montada no próprio client, em
-- `AdProvider.gd:_MintStub` — removida com este corte) e o servidor só
-- distinguia bom de forjado por `SHAMBLETA_AD_STUB`. Consequência medida: com a
-- env ligada, o mesmo token valia infinitas vezes (replay) e
-- `afkhoras`/`reroll` não estavam
-- no dicionário de caps — 12h/dia de hora offline era só um loop de chamadas,
-- e hora offline vira loot.
--
-- A tabela move a autoridade para o servidor: slot é LINHA, com dono
-- (`account_id`), placement e prazo. Consumir é um `DELETE` condicionado — a
-- linha some no primeiro uso, então replay não tem o que validar. Não é prova
-- de exibição: enquanto não houver SSV do portal, o servidor continua aceitando
-- "assisti" do client (é o que `SHAMBLETA_AD_STUB` liga, e o default é
-- desligado). O que muda é o teto do abuso: o inventário de slots de uma conta
-- por placement/dia, e não o vocabulário de strings.
CREATE TABLE IF NOT EXISTS ad_slot (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL,
  placement TEXT NOT NULL,
  nonce TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ad_slot_nonce ON ad_slot(nonce);
-- Contagem de pendentes por (conta, placement) e purge por vencimento: os dois
-- queries do gate de mint, ambos filtrando por `expires_at` para que um slot
-- abandonado (anúncio fechado antes do fim) não consuma a cota do dia.
CREATE INDEX IF NOT EXISTS idx_ad_slot_account ON ad_slot(account_id, placement, expires_at);
