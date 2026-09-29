-- 062 — Trilha de auditoria da GOVERNANÇA de guilda (AUDITORIA 2026-09-28
-- "administração de guilda na mão do jogador"). Cada promote/demote/kick ACEITO pelo
-- SERVIDOR fica reviewável depois da mesma forma que os movimentos do vault ficam em
-- `guild_vault_log` (migration 018): tabela append-only, uma linha por ação, nunca um
-- UPDATE/DELETE — é evidência, não estado. Quem decidiu (o account autenticado) e sobre
-- quem, além do verbo. O `guild_member` continua com UM dono (`GuildService`); esta
-- tabela só registra o que já foi aplicado, então nenhum caminho novo decide "quem
-- manda": a autorização aconteceu antes, no verbo, a partir do rank lido do banco.
-- O índice (`idx_governance_log_review`) atende a leitura por guild+ação+tempo, na mesma
-- forma de igualdade/igualdade/alcance do `idx_vault_log_window` (060), para a revisão
-- (e a régua do harness) não varrer um log que cresce para sempre.
CREATE TABLE IF NOT EXISTS guild_governance_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id INTEGER NOT NULL,
  actor_account INTEGER NOT NULL DEFAULT 0,
  target_account INTEGER NOT NULL DEFAULT 0,
  action TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_governance_log_review ON guild_governance_log(guild_id, action, created_at);
