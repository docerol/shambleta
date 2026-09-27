-- 053 — Feature flags de runtime (auditoria 2026-09-27, Live Ops 5/10).
--
-- O repo já tinha dois canais de configuração e nenhum deles é um kill-switch:
--  - `res://data/conf/*.json` entra no .pck pelo `include_filter` dos presets
--    (`export_presets.cfg:17,94,328,380,646,936,1031`) e num template exportado
--    `res://` é só leitura. Mexer aqui = rebuild de imagem + redeploy.
--  - `SHAMBLETA_*` no compose/painel também é redeploy (ou restart do container),
--    e vive no painel, não no banco que o jogo já audita.
-- Live Ops pedia a terceira coisa: desligar UMA funcionalidade de risco em
-- minutos, sem rebuild, com registro de quem/quando. É esta tabela.
--
-- Semântica de chave (fonte: `sources/ops/FeatureFlags.gd`):
--  - `value` é TEXT e opaco para o schema — o interpretador é o código que lê.
--    `IsTrue` só aceita "1", "true", "on", "yes" (minúsculas): tudo o mais é FALSO.
--    Flag desconhecida ou valor inválido nunca liga uma feature (fail-closed).
--  - Ausência de linha NÃO é "desligado": é "usa env, senão usa o default do
--    código". O operador que quiser desligar escreve "0" explicitamente — assim o
--    `Snapshot()` mostra `source=db` e ninguém confunde "sem registro" com "desligado".
--  - `updated_at` é UNIX em SEGUNDOS (`SQLCommons.Timestamp()`), não milissegundos.
--    Serve para uma só coisa: dizer se a linha é velha. Cache de processo só se
--    atualiza com `/flags reload` ou restando o processo (ver FeatureFlags.gd).
--
-- `key` é PRIMARY KEY → o `INSERT OR REPLACE` do `Set()` é um upsert de linha
-- única, e é a razão de não existir coluna `id`: duas linhas para a mesma chave
-- significariam duas respostas para a mesma pergunta.
CREATE TABLE IF NOT EXISTS feature_flag (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
