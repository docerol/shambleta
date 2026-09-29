-- 064 — marco zero das corridas de temporada que não têm histórico.
--
-- O placar congelado por `CloseSeason` (migration 018) é o veredito de quem recebe
-- prêmio, e três das quatro corridas eram lidas de UM NÚMERO CORRENTE sem
-- histórico: `character.power_score`, `character.bosses_beaten` e `guild.points`.
-- Congelar o valor corrente congela também tudo o que o jogador fez ANTES da
-- temporada abrir — que é exatamente o que a janela promete não contar. A única
-- corrida certa era `spend`, porque ela nasce do `ledger_transaction` e já tinha
-- `created_at` entre `starts_at` e `ends_at` (o teto em `ends_at` é a régua G1).
--
-- O conserto é um marco zero, não um histórico: no instante em que a temporada
-- abre, o estado corrente das três tabelas é gravado aqui uma vez e subtraído no
-- fechamento. Custo O(estado) na abertura e no fechamento, nenhuma coluna nova em
-- `character`/`guild`, nenhum write por evento de jogo — o que paga o prêmio passa
-- a ser o que aconteceu DENTRO da janela, medido contra a própria linha de origem.
--
-- `season.baselines_at` torna a ausência observável em vez de presumida: 0 é a
-- default da coluna e significa "esta linha não tem marco zero porque nasceu antes
-- da 064", e para ela o placar continua sendo o valor corrente — o mesmo número
-- que já estava congelado, não um delta inventado a posteriori. Uma temporada
-- aberta depois daqui tem `baselines_at > 0` gravado na mesma transação do INSERT,
-- e é aí que o placar passa a ser diferença. Quem lê o banco distingue os dois
-- regimes sem adivinhar; é por isso que a coluna existe e não um heurística de
-- "existe alguma linha em season_score_baseline".
CREATE TABLE IF NOT EXISTS season_score_baseline (
  season_id INTEGER NOT NULL REFERENCES season(season_id),
  kind TEXT NOT NULL,
  subject_id INTEGER NOT NULL,
  value INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (season_id, kind, subject_id)
);
ALTER TABLE season ADD COLUMN baselines_at INTEGER NOT NULL DEFAULT 0;
