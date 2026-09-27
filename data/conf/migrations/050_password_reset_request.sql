-- 050 — Ledger de solicitações de reset de senha (AUDITORIA_2026-09-27 §10 e
-- §22-P0-2: "Takeover de conta via brute-force do código de reset").
--
-- O caminho de recuperação era o pior do produto: código de 6 dígitos decimais
-- (`Hasher.gd:49`, `int(b) % 10` = espaço 10⁶), 15 min de validade, e
-- `EmailService.ValidateReset` apenas comparando hash — tentativa errada não
-- consumia o pending nem havia contador. Com ~1.100 conexões o espaço era coberto
-- dentro da janela, e o sucesso é troca de senha + revoke de tokens = conta
-- inteira. O throttle que existia era 1/s/PEER (`Peers`), e atrás do proxy o IP é
-- compartilhado: multiplicável por conexão, não por conta.
--
-- O código em si agora é base32 não ambíguo (32 símbolos × 6 posições = 30 bits,
-- ~1,07 × 10⁹), cada tentativa errada consome uma de 5, e a 5ª apaga o pending —
-- esses dois vivem em memória, junto do hash, porque o pending também vive: um
-- restart derruba o código, então não há o que adivinhar depois do restart, e o
-- contador só precisa sobreviver enquanto o pending existir.
--
-- O que NÃO pode morrer no restart é o orçamento de SOLICITAÇÕES: sem esta tabela,
-- reiniciar o processo (deploy, crash, restart periódico) devolveria a qualquer
-- conta o direito a mais N e-mails de reset, e o budget por janela voltaria a ser
-- multiplicável — agora por deploys. Esta tabela é o registro de "quem pediu reset,
-- quando, e até quando aquele código valia", contado por CONTA em janela rolante
-- (`NetworkCommons.ResetRequestWindowMinutes` / `ResetRequestWindowMax`).
--
-- Não guarda segredo nenhum: `code_hash` fica em memória de propósito — um hash de
-- código de 30 bits sem salt é material suficiente para validar um pending ao vivo,
-- e não há ganho em durabilizá-lo (ver acima). Os 24h de retenção são auditáveis
-- para o suporte responder "quantas vezes esta conta pediu reset antes de ser
-- tomada?" e são podados pela própria escrita (`DELETE ... WHERE requested_at <`),
-- então a tabela não cresce sem teto. O índice de `requested_at` é essa poda;
-- o de `(account_id, requested_at)` é o COUNT da janela.
CREATE TABLE IF NOT EXISTS password_reset_request (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	account_id INTEGER NOT NULL,
	requested_at INTEGER NOT NULL,
	code_expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_password_reset_request_account ON password_reset_request(account_id, requested_at);
CREATE INDEX IF NOT EXISTS idx_password_reset_request_requested_at ON password_reset_request(requested_at);
