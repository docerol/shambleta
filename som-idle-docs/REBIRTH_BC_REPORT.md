# REBIRTH_BC_REPORT — híbrido B+C no cap de XP (renascimento + essência)

Data: 2026-07 · Decisão de dono em [`REBALANCE_XP_OPTIONS.md`](REBALANCE_XP_OPTIONS.md) ·
Contrato vigente: [`XP_PROGRESSION.md §4.2`](XP_PROGRESSION.md) ·
Moeda/ledger: [`ECONOMY_STUDY.md §1/§5`](ECONOMY_STUDY.md) ·
Invariantes: [`TECH_SPEC_CORE.md §5`](TECH_SPEC_CORE.md)

## O problema, no número

`XP(L→L+1) = 8000 × 1.22^L` com `MAX_LEVEL 150` e renda saturando na zona 24
(~20,1M XP/h) produzia parede: L70 em 4,1 meses, L80 em 3 anos, L100 inalcançável.
A decisão foi **C no topo + B como motor**: o cap passa a existir de verdade (L60,
≈17–21 dias de ciclo 1) e o excedente vira moeda de prestígio.

## O que entrou

| Camada | Entrega |
|---|---|
| Contrato numérico | `sources/idle/RebirthData.gd` (puro, sem I/O): divisor 100 XP : 1 essência, custos `base × 1.7^owned`, favores `1.05^owned`, `attune` +0,02/nível com cap 10 |
| Persistência | `data/conf/migrations/021_rebirth.sql` — `character.{essence, rebirths, favor_xp, favor_gold, attune_offline}` (todos `INTEGER NOT NULL DEFAULT 0`) |
| Faucet (mint) | Online: `Stats.AddExperience` (chunk inteiro do divisor, resto continua no bucket). Offline: `OfflineSettle._Apply`, na **mesma transação** do settle, com linha de ledger `kind=essence`, `reason=offline_settle` |
| Sinks | `EconomyService.BuyRebirthUpgrade` — tx única: débito de essência + incremento do nível do favor + ledger `rebirth_upgrade:<id>`; guardas `unknown_upgrade` / `no_character` / `maxed` / `insufficient_essence` / `transaction_failed` |
| Motor (reset) | `EconomyService.Rebirth` — exige agente vivo no cap (`not_online` / `below_cap`); `IncRebirthCounter` + `UpdateStatDirect(charID, 1, 0, gp)` em uma transação; espelha no agente (`level=1`, `experience=0`, `ResetAttributesIfOverBudget`, `vital_stats_updated`); não toca equipamento, chaves, ouro, essência nem favores; `rebirths` nunca reseta |
| Pontos de aplicação | `Formula.ApplyXp` (XP/ouro por kill), `EconomyService.SettleBossResult` (faucet de boss), `OfflineSettle._ApplyFormula` (renda + drops + chaves via fator attuned). Favor 0 / attune 0 = identidade → o golden de settle não se move |
| Cliente | RPCs `GetRebirthState`/`RebirthState`/`RebirthNow`/`RebirthResult`/`BuyRebirthUpgrade`; `NetClient.LastRebirthState`; seção de renascimento na janela do Personagem **construída em runtime** (política no-tscn), com confirmação `UICommons.MessageBox` e botões de compra com custo/saldo/desabilitado |
| i18n | +12 chaves `tr()` no CSV (`data/i18n/ui.csv`), binários re-importados; cobertura de UI **188/188 (100%)** |

## Estado em que a tarefa parou (e o que foi fechado agora)

A implementação anterior tinha parado no meio da suíte. Três defeitos reais:

1. **`SQL.IncRebirthUpgrade` gravava em coluna inexistente.** O UPDATE usava o
   literal lua-style `{upgradeID = next}` — nesse formato a chave é o **nome do
   identificador** (`"upgradeID"`), não o valor da variável (`"favor_xp"`).
   Resultado: `no such column: upgradeID` no meio da transação de compra, essência
   debitada e favor **não aplicado** (com o cache mostrando ×1.00). Corrigido para
   a forma `{chave: valor}`; os três helpers de escrita de renascimento
   (`AddCharacterEssence`/`IncRebirthCounter`/`IncRebirthUpgrade`) agora retornam
   `-1` quando o `UpdateRowsRaw` falha, então qualquer falha de gravação derruba a
   transação em vez de deixar moeda gasta sem produto.
2. **Golden de custo errado na suíte**, não no código: `2000 × 1.7^5 = 28 397`
   (a suíte esperava 54 110 = `1.7^6`). Corrigido na suíte.
3. **Cauda da `SuiteRebirth` inexistente** — parava em "dirigir o char ao cap pelo
   caminho público" sem uma asserção. Escrita agora, e a suíte virou async
   (`await` no runner) porque a metade B exige `PlayerAgent` vivo:
   settle de 12h na zona 1 com `favor_xp=1` rende exatamente `×1.05` do golden e
   converte o bucket em essência (com resto `< divisor` acumulado, 1 linha de
   ledger, ouro creditado, nível congelado); os 10 níveis de `attune` compram e o
   11º volta `maxed`, com efeito medido na renda (razão `0.80/0.60`); mint online
   `1:100` via `Stats.AddExperience`; renascimento completo (nível→1 no DB **e** no
   agente, ouro/essência/favores preservados, `rebirths=1`, cache de multiplicador
   intacto, segunda tentativa `below_cap`); e o faucet de boss escalando com o
   favor comprado no meio (diferencial ×1.05 medido, sem fórmula-tautologia).

## Gates re-rodados (suíte headless completa, DB limpo)

Comando: `rm -rf .test-home && mkdir -p .test-home/{data,cache} && XDG_DATA_HOME=... XDG_CACHE_HOME=... godot --headless --path . -s tests/run_idle_tests.gd`

- **`== RESULT: 651 checks, 0 failures ==`**, exit 0. Referência: 589/0 era o verde
  em `11ff5a4` (pré-rebirth, última suíte inteira verde); a execução interrompida do
  WIP marcava 614/3. Ou seja: **+62 checks, todos verdes**.
- **Migração 021 aplicada no caminho de instalação limpa** (DB zerado no run).
- **Gate de pacing D1 (binding, `SuiteIdlePolicyRealTime`): 36 kills/h** na zona 1
  sob carga de suíte completa — banda 30–200 ✓ e **idêntico ao valor medido antes do
  cap mudar**: a troca de 150→60 não tocou o relógio de jogo, como previa a decisão
  ("os gates medem o clock de jogo, não a economia").
- Sim comprimida 20×: 93..396 kills/h na 1ª corrida, média 65/h na 2ª (sanity band
  ≤300% e "runs produtivos" ✓ nas duas; a comprimida é informativa, não-binding —
  a variância dela entre corridas já era documentada no relatório D1).
- **Confirmado em duas corridas completas seguidas com DB limpo: 651/0 e 651/0**,
  mesma árvore do commit (a 2ª foi depois do commit, para checar que nada ficou de
  fora dele).
- Faucet harness: 12 settles em 0.0–0.1s (120 settles/s) ✓.
- Erros **nominais** conhecidos continuaram nos logs (chaos de transação envenenada,
  triggers append-only, `UNIQUE constraint failed: guild.name`, `near "%"` no
  `SuiteSeasonPayout`) — nenhum conta como falha.

## O que a suíte agora tranca (invariantes)

- Custo 1.7^n vs bônus 1.05^n: a curva que evita o burnout geométrico simulado da
  Opção B é golden, não conversa.
- `attune_offline` é o **único** bônus com cap (10 níveis, 0.60→0.80) — 0,80 é
  piso honesto de AFK, não teto de poder.
- Essência nunca se perde no cap (online e offline com a mesma taxa), e o resto
  abaixo do divisor continua no bucket.
- Renascimento preserva tudo que não é nível; `rebirths` é cumulativo.
- Favor 0 é identidade: qualquer mudança no golden de settle sem compra de favor
  quebra a suíte.

## Pendências

1. **Decisão de dono (bloqueia o sentido do ciclo):** o ato de renascer não paga
   nada hoje. Está documentado em `XP_PROGRESSION.md §4.2` como PENDÊNCIA, com as
   duas pernas possíveis (pagamento proporcional ao ciclo ou trilha fechada a
   `rebirths ≥ n`). Não foi inventado aqui porque é mudança de economia, e o dono
   fixou o contrato em `REBALANCE_XP_OPTIONS.md`.
2. **Custo de escrita no cap:** cada kill no cap credita essência → 1 transação +
   1 linha de ledger (~96–150/h/char). Aceito por auditabilidade; se doer, batching
   do mint é a alavanca (documentado no §4.2).
3. **Compensação visível:** contador/seção na UI do Personagem existem; título,
   moldura e número de ciclo "de vitrine" (o anti-churn citado na decisão) ainda
   não — domínio da fase de cosméticos/passe.
4. **Lado "season" da Opção C:** ladder sazonal é Fase 4 do ROADMAP; o cap L60 sem
   renascimento paga essência, e sem season a escada de favores é a única
   progressão de fim de jogo.
5. **Operacional (pré-existente, não criado aqui):** o job `idle-tests` do CI roda
   `timeout 300`, mas a sonda de pacing binding custa `SOM_REALTIME_SECS` = 300s de
   wall clock sozinha — a suíte completa nesta máquina fecha em ~7 min. Como
   `D1_GATE_REPORT.md` já registra que o job nunca rodou de verdade (Actions com 0
   runs no repo), isso não estava medido; antes de habilitar Actions, separar o gate
   D1 em job próprio (como o relatório D1 sugere) em vez de esticar o timeout.
