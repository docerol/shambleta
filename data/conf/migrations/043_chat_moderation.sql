-- 043 — Moderação de chat (AUDITORIA_INDEPENDENTE §16 SOCIAL: "sem qualquer
-- ferramenta de denúncia ou mute para o jogador"). A moderação antes só existia como
-- ação do operador sobre a CONTA inteira (/ban, /kick): não havia para onde
-- denunciar assédio/golpe no canal, e não havia como calar alguém sem tirar o
-- acesso ao jogo. Os dois juntos são o loop mínimo: denúncia entra, o
-- moderador vê a trilha e aplica um mute com prazo — que o servidor cobra na
-- hora de enviar, não no cliente que recebe.
--
-- account_id, nunca nick: nick é apresentação (e o C1/V1 mostrou que apresentação
-- falsificável não pode ser chave de decisão de segurança).
CREATE TABLE IF NOT EXISTS chat_mute (
	account_id INTEGER NOT NULL,
	muted_by INTEGER NOT NULL DEFAULT 0,
	reason TEXT NOT NULL DEFAULT '',
	until_ts INTEGER NOT NULL,
	created_ts INTEGER NOT NULL,
	PRIMARY KEY (account_id)
);
CREATE INDEX IF NOT EXISTS idx_chat_mute_until ON chat_mute(until_ts);

-- A denúncia carrega o trecho que o SERVIDOR viu aquele account falar (buffer
-- circular de ChatModeration), não o texto que o denunciante digitou:
-- `verified=1` quer dizer "a linha bate com o que passou pelo canal", `0` quer
-- dizer "não havia registro" — e o moderador sabe que está ouvindo um lado só.
CREATE TABLE IF NOT EXISTS chat_report (
	report_id INTEGER PRIMARY KEY AUTOINCREMENT,
	reporter_account INTEGER NOT NULL,
	reported_account INTEGER NOT NULL,
	channel TEXT NOT NULL DEFAULT '',
	reason TEXT NOT NULL DEFAULT '',
	excerpt TEXT NOT NULL DEFAULT '',
	verified INTEGER NOT NULL DEFAULT 0,
	status TEXT NOT NULL DEFAULT 'open',
	created_ts INTEGER NOT NULL,
	resolved_ts INTEGER NOT NULL DEFAULT 0,
	resolved_by INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_chat_report_status ON chat_report(status, created_ts);
CREATE INDEX IF NOT EXISTS idx_chat_report_reported ON chat_report(reported_account, created_ts);
