-- 061 — Grafo social: amizade e bloqueio (AUDITORIA_2026-09-27 §14 SOCIAL, 4/10)
-- O §14 chamou "amizades, lista de ignorados, denúncias: inexistente ou decorativo"
-- de duas coisas: não havia onde morar a pergunta "o que eu tenho com ALVO?" (nem
-- tabela, nem código — `grep -riE "friend|ignore"` em sources/sql e nas migrations só
-- achava `INSERT OR IGNORE` de token 2FA), e o clique na lista de online era um sinal
-- que ninguém escutava. Esta é a base durável dos dois; a leitura é
-- `sources/social/SocialGraph.gd` e a cobrança no hot path está em `Network.ChatPlayer`.
--
-- (a) UMA tabela, não duas. A pergunta do hot path é sempre "esta ARESTA existe entre
-- estes DOIS accounts, de que tipo" — ela é respondida pela mesma chave primária para
-- `friend` e para `ignore`, e o `ignore` é lido em CADA entrega de mensagem de chat
-- (uma checagem por destinatário, ver o plano abaixo). Duas tabelas seriam duas
-- janelas de consistência no caminho mais quente da área: `friend` é escrita par
-- (simetria) e `ignore` é escrita ímpar (unilateral), e um `UNION` de duas tabelas
-- para responder "o que eu tenho com X" é exatamente o tipo de join que alguém escreve
-- errado sob pressão. O custo de juntar as duas num só lugar é um `kind TEXT` — e
-- `kind` entra na chave, então nenhum dos dois tipos perde seletividade.
--
-- (b) `friend` é bidirecional por convenção de ESCRITA, não por duas linhas de
-- leitura. Quem grava é `SocialGraph.Add(KindFriend, ...)`: as duas arestas
-- — (A→B) e (B→A) — entram na MESMA `Transaction()`, então "amigo" nunca é estado
-- assimétrico que a UI não consegue explicar (A vê B na lista dele e B não vê A). Se a
-- segunda INSERT falhar, a primeira volta atrás: ou os dois lados, nem um. `ignore` é
-- unilateral de propósito — bloquear não é conversa — e por isso os dois tipos cabem
-- na mesma chave: quem decide a semântica é a escrita, não o schema.
--
-- (c) Ordem das colunas e plano MEDIDO. A chave primária é igualdade-tripla na ordem
-- da consulta do hot path (`account_id` = dono da aresta, `target_account_id` = alvo,
-- `kind`), então `IsIgnored` não toca no índice de ninguém além do próprio índice da
-- PK. O índice nomehado serve as consultas de lista/contagem, que filtram por dono e
-- tipo e varrem os alvos: igualdade, igualdade — `created_at`/nick vêm depois, e o
-- `ORDER BY` da lista é do lado de `account` (temp B-tree), o que é aceitável porque a
-- lista é lida num clique, não por linha de chat. Planos abaixo, medidos com
-- `EXPLAIN QUERY PLAN` nesta árvore (os mesmos três asserts são executados por
-- `tests/social_graph_test.gd` contra o SQLite do próprio boot — plano prometido sem
-- régua executa é o defeito que a §14 descreveu em 057):
--   SELECT 1 FROM social_graph WHERE account_id=? AND target_account_id=? AND kind=?
--   -> SEARCH social_graph USING COVERING INDEX sqlite_autoindex_social_graph_1
--      (account_id=? AND target_account_id=? AND kind=?)
--   SELECT COUNT(*) FROM social_graph WHERE account_id=? AND kind=?
--   -> SEARCH social_graph USING COVERING INDEX idx_social_graph_owner (account_id=? AND kind=?)
--   SELECT ... FROM social_graph s JOIN account a ON a.account_id = s.target_account_id
--      WHERE s.account_id=? AND s.kind=? ORDER BY a.username
--   -> SEARCH s USING INDEX idx_social_graph_owner (account_id=? AND kind=?)
--      SEARCH a USING INTEGER PRIMARY KEY (rowid=?) / USE TEMP B-TREE FOR ORDER BY
-- O DELETE de purge por alvo (EraseAccount, LGPD art.18) é o único acesso que filtra
-- por `target_account_id` primeiro; sem o índice abaixo ele viraria varredura da
-- tabela inteira dentro de uma transação de anonimização.
CREATE TABLE IF NOT EXISTS social_graph (
	account_id INTEGER NOT NULL,
	target_account_id INTEGER NOT NULL,
	kind TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	PRIMARY KEY (account_id, target_account_id, kind)
);
CREATE INDEX IF NOT EXISTS idx_social_graph_owner ON social_graph(account_id, kind, target_account_id);
CREATE INDEX IF NOT EXISTS idx_social_graph_target ON social_graph(target_account_id, kind, account_id);
