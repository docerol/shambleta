-- AUDITORIA_2026-09-27 §12: "presença in-memory" é um dos degraus que segura o
-- teto de 5–10k CCU declarado — `Peers.peers` e `OnlineList.byNick` morrem no
-- restart do processo e são invisíveis para um segundo processo, então dois
-- servidores não enxergam os jogadores um do outro e o "quem está online" de
-- guild/social só vê metade da população. Este patch dá à presença um endereço
-- durável e consultável; o índice de memória continua lá para a latência, o banco
-- passa a ser a verdade compartilhada.
--
-- Chave por PERSONAGEM (não por conta): é a unidade que o painel de guild e a
-- lista de amigos consultam (`OnlineList.IsPlayerOnline(nick)`), e é o que o
-- auditante precisa para "dois processos veem os mesmos jogadores".
--
-- `last_seen_at` + TTL é o contrato de liveness: um processo que morre sem passar
-- por `DisconnectCharacter` não deixa um fantasma online para sempre — a linha
-- vence e `Presence.Prune` a remove. Escrita por personagem é uma UPSERT de uma
-- statement, então o custo marginal de presença é contado e limitado pelo
-- heartbeat (`Presence.HeartbeatSec`), medido em tests/presence_fuzz.gd.
CREATE TABLE IF NOT EXISTS presence_session (
	char_id INTEGER PRIMARY KEY,
	account_id INTEGER NOT NULL DEFAULT 0,
	nick TEXT NOT NULL DEFAULT '',
	server_id TEXT NOT NULL DEFAULT '',
	zone_id INTEGER NOT NULL DEFAULT 0,
	connected_at INTEGER NOT NULL DEFAULT 0,
	last_seen_at INTEGER NOT NULL DEFAULT 0
);
-- Cauda viva por servidor (o "quem está online" de um segundo processo), consulta
-- por nick (painel de guild) e varredura de vencidos (prune). Os três planos são
-- asseridos por EXPLAIN QUERY PLAN no harness.
CREATE INDEX IF NOT EXISTS idx_presence_seen ON presence_session (last_seen_at);
CREATE INDEX IF NOT EXISTS idx_presence_server ON presence_session (server_id, last_seen_at);
CREATE INDEX IF NOT EXISTS idx_presence_nick ON presence_session (nick);
