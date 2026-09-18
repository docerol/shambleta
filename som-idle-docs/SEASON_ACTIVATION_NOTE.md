# Season — nota técnica de ativação futura (débito técnico pós-beta)

**Status no beta fechado:** Seasons travadas server-side (`EconomyService.SeasonsBetaLock`;
`CreateSeason` → `-1`, `TickSeasonLifecycle` → no-op sem `SHAMBLETA_ENABLE_SEASONS=1`).
Nada no fluxo normal do beta depende de temporada (`GetSeasonBoardsState` → `{}`,
passe indisponível sem temporada, job diário vira no-op). Cobertura da trava:
`SuiteSeasonLock`. **Não remover o código.**

## Por que a trava existe (problemas conceituais encontrados na auditoria)

1. **Snapshot do estado atual, não do fim:** `SnapshotSeason*` lê `character`,
   `ledger` e `guild` *no momento da chamada* — não existe registro imutável do
   placar no instante do fechamento.
2. **Delimitação temporal fraca:** `SnapshotSeasonSpend` filtra
   `created_at >= starts_at` sem teto; `SnapshotSeasonPower/BossKills` ignoram
   janela temporal por completo (lêem o valor corrente, whenever).
3. **Fechamento em `ends_at` não é atômico:** `TickSeasonLifecycle` roda no job
   diário — entre `ends_at` e a execução do job, eventos posteriores (kills,
   gasto, pontos) ainda entram nas tabelas-fonte e contaminam a apuração.
4. **Sem estado intermediário:** o ciclo pula `active → closed → settled` sem
   `CLOSING` (janela de congelamento/auditoria antes de liquidar).

## Auditoria exigida antes da ativação (pós-beta)

Desenhar e testar um dos dois caminhos (proposta, não definitivo):

- **Opção A — estados + snapshot imutável:** `ACTIVE → CLOSING → CLOSED → SETTLED`,
  onde `CLOSING` congela a apuração (snapshot persistido em tabela própria,
  ex. `season_snapshot`, com hash encadeado p/ auditoria) e só `CLOSED` liquida
  a partir do snapshot — nunca das tabelas vivas.
- **Opção B — event sourcing:** toda pontuação de corrida vira evento imutável
  com `season_id` carimbado na origem; a apuração é `fold` dos eventos com
  `created_at <= ends_at`, reproduzível e auditável.

Critérios de aceite da ativação: teste de corrida (evento 1s após `ends_at`
não entra), teste de replay do job (idempotente), e changelog público de
regras por temporada (decisão do dono).

## Débito incluído: regra de acúmulo de guild points (beta, sem efeito)

`GuildSettlePoints` (via `OfflineSettle` e vitória de boss) credita
`maxi(1, floori(hours))` — settles de minutos viram 1 ponto. Verificado no
beta: **sem benefício econômico relevante**, porque pontos só são consumidos
por (a) board de exibição e (b) premiação `season_prize:*:guild_points:*`,
inalcançável com a trava (`TickSeasonLifecycle` no-op; sem caminho GM/cliente
p/ `SettleSeasonPrizes`). Não refatorado de propósito (métrica de display +
suíte `SuiteGuildPremium` pinada em `points >= 1`). Na ativação, definir a
regra junto do snapshot (floor puro vs. participação mínima) e ajustar teste.

## Checklist de ativação

1. Implementar A ou B + suítes (corrida, replay, idempotência).
2. Remover `SeasonsBetaLock` (ou trocar por flag de live-ops por temporada).
3. Congelar regras da S1 + publicar changelog.
4. Rodar `SuiteSeasonLock` atualizada (a trava deve continuar existindo como
   kill-switch de emergência, não como default).
