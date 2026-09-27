-- 052 — Web push: subscription + outbox (SOM-W5 C1/C3)
--
-- O gate `WebPush.CanDeliver()` exige três peças (auditoria W5): chave VAPID,
-- TABELA de subscription e sender no companion. Esta migration entrega as
-- duas primeiras partes de banco do caminho e a fila de saída; o sender VAPID
-- é o que ainda falta (ECDSA P-256 em Python sem `cryptography`/`ecdsa` não
-- existe na stdlib e o companion é stdlib-only — ver companion/server.py,
-- `vapid_webpush_send`). Nada aqui promete entrega: só dá à linha de chegada
-- (registration CLI + sweep + POST /push/test) onde escrever e de onde ler.
--
-- push_subscription: UMA linha por conta (PRIMARY KEY em account_id é o
-- upsert — trocar de navegador re-escreve o mesmo registro; subscription
-- velha de navegador desinstalado apodrece aqui e o sender trata 404/410 como
-- limpeza quando existir). p256dh/auth são opacos do browser (ECDH local /
-- chave de payload) — o servidor nunca os usa para autorizar nada, só para
-- cifrar; endpoint é URL escolhida PELO PROVEDOR de push, não pelo jogador.
--
-- push_outbox: fila de entrega. O sweep do companion ENFILEIRA (nunca envia
-- inline no request de jogo nem no loop do servidor); quem drena é operador
-- via CLI --push-drain ou o endpoint interno POST /push/test (fora do proxy
-- do nginx — nada de push pela fronteira pública). Status:
-- pending -> sent | failed (com last_error), nunca re-tentativa automática:
-- sem sender real, uma fila com retry seria spam futuro com backlog do
-- passado. created_at é também a janela de dedupe do sweep (não notificar a
-- mesma conta duas vezes em `--push-quiet-hours`).
CREATE TABLE IF NOT EXISTS push_subscription (
  account_id INTEGER PRIMARY KEY,
  endpoint TEXT NOT NULL,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS push_outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  sent_at INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);

-- Drenagem: pega pendentes por id (FIFO estável, idempotente por linha).
CREATE INDEX IF NOT EXISTS idx_push_outbox_pending ON push_outbox(status, id);
-- Dedupe do sweep: "esta conta já foi notificada na janela?" por conta+data.
CREATE INDEX IF NOT EXISTS idx_push_outbox_account ON push_outbox(account_id, created_at);
