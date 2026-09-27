-- 054 — Janelas de tentativa PERSISTIDAS para as rotas de login/2FA
-- (AUDITORIA_2026-09-27, trilha "login hardening", frente 1 e frente 3).
--
-- O que já existia e NÃO se duplica aqui: o backoff POR CONTA vive desde a
-- migration 011 (`account.failed_attempts` / `locked_until`, gravados por
-- `SQL.RecordFailedLogin` dentro de `ValidateAuthPassword`) — contador durável,
-- teto em `NetworkCommons.MaxLockoutSec`, zera no login certo. O que faltava era
-- o segundo eixo (teto por IP, para o spray não chegar na conta) e o orçamento
-- por CONTA da etapa TOTP (o segredo survive restart, então a tentativa tem que
-- survival também — regra completa e o rationale conta-vs-IP em
-- `sources/sql/SQLSecurity.gd`).
--
-- Formato: uma linha por (eixo, sujeito). `attempt_kind` separa os usos
-- ('login_ip' → `attempt_subject` é o IP; 'totp_account' → é o account_id em
-- texto) sem tabela por feature. `INSERT OR REPLACE` pela chave primária é a
-- escrita única (`SQLSecurity.NoteFailure`), e a poda anda junto da escrita
-- (retenção `SQLSecurity.WindowRetentionSec`), então a tabela tem teto
-- natural: só sobrevivem janelas do último dia.
--
-- NÃO guarda segredo: contadores e timestamps. Nenhum índice extra além da PK
-- (o `blocked_until` é lido junto da linha pela PK; varredura por bloqueado é
-- função de suporte, não caminho quente).
--
-- Só statements idempotentes de propósito: `ApplyMigrations` endereça patch por
-- POSIÇÃO no diretório ordenado, e o nome NNN tem que bater com índice+1 (gate
-- `== DOC DRIFT:` mede a densidade 001..N) — reaplicar não pode doer.
CREATE TABLE IF NOT EXISTS security_attempt_window (
	attempt_kind TEXT NOT NULL,
	attempt_subject TEXT NOT NULL,
	window_start INTEGER NOT NULL,
	failures INTEGER NOT NULL DEFAULT 0,
	blocked_until INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (attempt_kind, attempt_subject)
);
CREATE INDEX IF NOT EXISTS idx_security_attempt_window_window_start ON security_attempt_window(window_start);
