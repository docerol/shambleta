-- 045 — K1: coorte de retenção D1/D7/D30 (AUDITORIA_INDEPENDENTE §23 Bloco 1 item 9).
-- O funil de receita responde "comprou"; isto responde "voltou", que é o número
-- que o ROADMAP_COMERCIAL promete e hoje não existe de onde sair.
--
-- Definição fixada aqui e não mudada depois: D1 = a conta ter um login no DIA
-- CALENDÁRIO UTC exato +1 a partir do dia da criação. Não é "logou em algum
-- momento depois do primeiro dia" — essa segunda leitura existe em alguns
-- dashboards e dá número maior; trocá-la mais adiante rompe a série histórica,
-- então se um dia precisar das duas, o nome novo é outra view.
--
-- Uma linha por conta (não por evento): o dashboard soma as bandeiras e divide
-- pelo total. Contas sem nenhum login ficam de fora por construção do JOIN —
-- "D1 de quem nunca abriu o jogo" não existe e não deve entrar no denominador.
--
-- created_timestamp == 0 acontece em conta anterior à coluna; o fallback é o
-- login mais antigo, que é o melhor palpite honesto e não infla D1 (empurra o
-- dia-zero para frente, e o que passa a contar é o que veio depois).
CREATE VIEW IF NOT EXISTS cohort_retention AS
SELECT account_id,
       cohort_day,
       MAX(CASE WHEN day_index - cohort_day = 1 THEN 1 ELSE 0 END) AS d1,
       MAX(CASE WHEN day_index - cohort_day = 7 THEN 1 ELSE 0 END) AS d7,
       MAX(CASE WHEN day_index - cohort_day = 30 THEN 1 ELSE 0 END) AS d30
FROM (
	SELECT a.account_id AS account_id,
	       (CASE WHEN a.created_timestamp > 0 THEN a.created_timestamp
	             ELSE COALESCE((SELECT MIN(t0.created_at) FROM telemetry_event t0
	                           WHERE t0.account_id = a.account_id AND t0.kind = 'login'), 0)
	        END) / 86400 AS cohort_day,
	       t.created_at / 86400 AS day_index
	FROM account a
	JOIN telemetry_event t ON t.account_id = a.account_id AND t.kind = 'login'
)
GROUP BY account_id, cohort_day;
