-- AUDITORIA_2026-09-27 §12 (Escalabilidade 3/10): o ledger é a única coisa cujo
-- crescimento o auditante traduziu em arquivo ("1M CCU → 20M linhas/dia → 51 GB"),
-- e o motivo de ele não poder ser podado é a trigger append-only da migration 009.
-- §7.3 diz que essa disciplina é a parte boa do repo — então a poda não pode
-- comprá-la. Este patch troca "uma linha por transação de alto volume" por "uma
-- linha por dia de transações de alto volume" sem tirar nada de ninguém:
--
--  1. O agregado entra como LINHA NA PRÓPRIA `ledger_transaction`, herdando o `id`
--     da última linha crua que ele engoliu. Por isso nenhum leitor muda de endereço
--     nem de plano: `SUM(amount)` por conta+kind continua batendo, o
--     `ORDER BY id DESC LIMIT 1` que atesta saldo devolve o saldo certo (a linha
--     agregada carrega `balance_after` = saldo depois da última linha que ela
--     representa) e a ordem por id segue cronológica, porque o id herdado é o id da
--     linha mais antiga do lote. Sem view, sem reescrita de caminho quente.
--  2. A trigger de DELETE passa a ser condicional por COBERTURA: uma linha crua só
--     morre se houver linha em `ledger_compaction_cover` ligando-a ao agregado que a
--     contém. O cover é gravado numa transação que COMITA ANTES de qualquer DELETE,
--     então "agregado durável antes de dropar o cru" é garantia do banco, não
--     disciplina de código: se o T1 não comitou, o T2 morre na trigger; se o T2
--     falha, o rollback devolve as linhas cruas e o agregado fica esperando o
--     re-run (`SQLRetention.FinishPendingRuns`).
--     UPDATE continua 100% negado — a trigger da migration 009 não é tocada, e a
--     linha agregada é imutável exatamente como a linha crua.
--  3. Compactável é lista FECHADA de reasons de corpo (`SQLRetention.BulkExact` +
--     `BulkPrefixes`, amarrada por teste contra o predicado SQL): settle offline e as
--     linhas de kill que §7.1 manda escrever, que ninguém lê linha a linha.
--     Proveniência de dinheiro — `refund:`/`clawback:`/`grant:`/`trade_*`/`ah_*`/
--     `chest:`/`referral_bonus:`/`vault_*`/`pass_*`/`season_prize:`/
--     `tournament_prize:` — não entra e não sai nunca. A linha agregada tem root
--     `rollup`, também fora da lista: nada se compacta duas vezes.
--
-- Idempotência: tudo `IF NOT EXISTS` e o trigger é DROP+CREATE, então re-aplicar o
-- patch num banco que já o tem não duplica nada.

-- Um lote por (rodada, dia, conta, personagem, kind, root). É o registro analítico
-- E o payload do agregado: com estas colunas dá para reconstruir a linha-agregado do
-- item 1 sem reler nada que já foi embora — é por isso que a recovery existe.
CREATE TABLE IF NOT EXISTS ledger_daily_rollup (
	bucket_id INTEGER PRIMARY KEY AUTOINCREMENT,
	run_id INTEGER NOT NULL,
	day INTEGER NOT NULL,
	account_id INTEGER NOT NULL,
	char_id INTEGER NOT NULL DEFAULT 0,
	kind TEXT NOT NULL,
	reason_root TEXT NOT NULL,
	aggregate_id INTEGER NOT NULL DEFAULT 0,
	tx_count INTEGER NOT NULL DEFAULT 0,
	inflow BIGINT NOT NULL DEFAULT 0,
	outflow BIGINT NOT NULL DEFAULT 0,
	net BIGINT NOT NULL DEFAULT 0,
	opening_balance BIGINT NOT NULL DEFAULT 0,
	closing_balance BIGINT NOT NULL DEFAULT 0,
	first_id INTEGER NOT NULL DEFAULT 0,
	last_id INTEGER NOT NULL DEFAULT 0,
	first_at INTEGER NOT NULL DEFAULT 0,
	last_at INTEGER NOT NULL DEFAULT 0,
	compacted_at INTEGER NOT NULL DEFAULT 0
);
-- Consulta do painel (dia, conta) e cauda por personagem (o saldo que o agregado
-- atesta). O UNIQUE não está aqui de propósito: um dia pode ganhar mais de um lote
-- quando a janela de retenção avança sobre ele em duas rodadas.
CREATE INDEX IF NOT EXISTS idx_rollup_day_account ON ledger_daily_rollup (day, account_id);
CREATE INDEX IF NOT EXISTS idx_rollup_char ON ledger_daily_rollup (char_id, last_id);
CREATE INDEX IF NOT EXISTS idx_rollup_run ON ledger_daily_rollup (run_id);

-- Autorização de drop + proveniência bruta→agregado: uma linha por linha crua que
-- saiu. Estreita (quatro inteiros) contra a linha que ela substitui, e é o que
-- responde no incidente "de qual linha crua veio este agregado".
CREATE TABLE IF NOT EXISTS ledger_compaction_cover (
	ledger_id INTEGER PRIMARY KEY,
	run_id INTEGER NOT NULL,
	aggregate_id INTEGER NOT NULL,
	bucket_id INTEGER NOT NULL,
	compacted_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cover_run ON ledger_compaction_cover (run_id);
CREATE INDEX IF NOT EXISTS idx_cover_bucket ON ledger_compaction_cover (bucket_id);

-- Diário da poda, e máquina de estado da recovery: uma rodada que comitou o
-- agregado (status 'aggregated') e morreu antes do drop é retoma por ali mesmo.
CREATE TABLE IF NOT EXISTS ledger_compaction_run (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	started_at INTEGER NOT NULL,
	aggregated_at INTEGER NOT NULL DEFAULT 0,
	finished_at INTEGER NOT NULL DEFAULT 0,
	cutoff_at INTEGER NOT NULL DEFAULT 0,
	rows_read INTEGER NOT NULL DEFAULT 0,
	aggregates_written INTEGER NOT NULL DEFAULT 0,
	rows_dropped INTEGER NOT NULL DEFAULT 0,
	status TEXT NOT NULL DEFAULT 'open'
);

-- Nenhum índice novo no corpo, de propósito: a varredura de elegibilidade anda pela
-- PK a partir da fronteira de ids já cobertos (`SQLRetention.LowerBoundID`), então o
-- trabalho por rodada é proporcional ao corpo NOVO e um índice por `created_at` só
-- existiria para ser escrito em toda linha do ledger — custo certo em troca de nada.
-- O que é asserido por EXPLAIN QUERY PLAN em tests/scale_test.gd é justamente o
-- `SEARCH ledger_transaction USING INTEGER PRIMARY KEY (rowid>?)` desta varredura.

-- A trigger antiga morre e renasce condicional. O nome continua
-- `ledger_transaction_no_delete` porque é ele que o teste e a doc citam.
DROP TRIGGER IF EXISTS ledger_transaction_no_delete;
CREATE TRIGGER ledger_transaction_no_delete BEFORE DELETE ON ledger_transaction
FOR EACH ROW
WHEN NOT EXISTS (SELECT 1 FROM ledger_compaction_cover c WHERE c.ledger_id = OLD.id)
BEGIN
	SELECT RAISE(ABORT, 'ledger_transaction is append-only (DELETE denied: row is not covered by a durable rollup)');
END;
