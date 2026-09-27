-- 056 — Fila de revisão antifraude acionável (Live Ops) + severidade composta.
-- Público BR: LAN house / cybercafé / NGM compartilhado é uso NORMAL. Por isso o
-- schema separa a FORÇA do sinal do registro de revisão: fraqueza de sinal (IP,
-- /24, dispositivo sem sobreposição) vive em peso, não em status — o detector
-- (FraudeReview.gd) só insere flag quando o score composto passa o limiar, e
-- nada aqui dá a qualquer job o poder de banir (a única coluna nova escrita por
-- automação é referral_hold, protetiva e reversível).

-- Trilha de revisão: "revisado" sem quem/quando/nota é folklore. score +
-- evidence congelam o cálculo que abriu a flag — o operador lê o sinal que
-- disparou (e o porquê) sem reconstruir o job de memória.
ALTER TABLE fraud_flag ADD COLUMN severity TEXT NOT NULL DEFAULT 'medium';
ALTER TABLE fraud_flag ADD COLUMN score INTEGER NOT NULL DEFAULT 0;
ALTER TABLE fraud_flag ADD COLUMN evidence TEXT NOT NULL DEFAULT '';
ALTER TABLE fraud_flag ADD COLUMN reviewed_by INTEGER NOT NULL DEFAULT 0;
ALTER TABLE fraud_flag ADD COLUMN reviewed_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE fraud_flag ADD COLUMN review_note TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS idx_fraud_severity ON fraud_flag(status, severity, created_at);
CREATE INDEX IF NOT EXISTS idx_fraud_reviewed ON fraud_flag(status, reviewed_at);

-- Fonte do sinal FRACO de rede: o IP observado no login. O producer é um hook
-- opcional (Peers.FinalizeLogin chama FraudeReview.NoteLoginIP quando ligado);
-- sem linhas aqui o detector não tem evidência de IP — ausência nunca vira
-- flag, e presença sozinha nunca passa do peso 1. `subnet` é o /24 derivado
-- ("203.0.113.*"): CGNAT de operadora brasileira junta contas alheias no mesmo
-- /24 o dia todo, por isso ele é ainda mais fraco que o IP cheio na leitura.
CREATE TABLE IF NOT EXISTS login_ip_event (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	account_id INTEGER NOT NULL,
	ip TEXT NOT NULL,
	subnet TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_login_ip_time ON login_ip_event(created_at);
CREATE INDEX IF NOT EXISTS idx_login_ip_subnet ON login_ip_event(subnet, created_at);

-- A ÚNICA ação automática do sistema, e é PROTETIVA: congela payout de referral
-- (dinheiro de marketing) quando a própria conta viola conservação de ledger
-- (wallet abaixo do saldo que o ledger dela atesta — impossível determinístico,
-- não heurística). Não remove saldo, não silencia, não bane. O operador desfaz
-- com /cs_flag <id> dismissed, que limpa o hold da conta (FraudeReview.
-- ReviewFlag) — sem SQL manual.
ALTER TABLE account ADD COLUMN referral_hold INTEGER NOT NULL DEFAULT 0;
