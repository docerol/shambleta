# ECONOMY_STUDY — SOM-IDLE

Contrato dos parâmetros de economia (sources/faucets/sinks) do pivô idle.
Reconstruído em 2026-09 a partir de `sources/economy/EconomyService.gd`,
`sources/idle/OfflineSettle.gd` e `sources/idle/BossService.gd`, para fechar
a lacuna de este arquivo ser citado no código (§6, §7) sem existir no
repositório. Atualizar aqui sempre que uma constante de economia mudar.

## §1. Moedas e ledger

| Moeda | Fonte primária | Natureza |
|---|---|---|
| Ouro (`gold`) | Kill de mob (por zona, ver `XP_PROGRESSION.md`) | Gasto em NPCs/itens, não cashable |
| XP (`xp`) | Kill de mob | Progressão de nível, não é moeda transacionável |
| Gems | Compra real (Mercado Pago) via `grant_queue`, ou recompensas pontuais (boss, temporada) | **Moeda premium** — ligada a dinheiro real, sujeita a reembolso CDC |
| Chave de boss (`boss_key`) | Drop em farm (`KeyDropPPM = 2000` partes por milhão) | Consumível, abre desafio de boss |
| Essência (`essence`) | XP que excede o cap de renascimento: 100 XP : 1 essência, online e offline (`XP_PROGRESSION.md §4.2`) | Moeda de prestígio de longo prazo: financia a loja permanente de favores. **Não** é comprável nem transferível, e nunca volta a ser XP |

Todo movimento de qualquer uma dessas moedas passa por `LedgerAppend` —
não há alteração de saldo sem linha de ledger correspondente (auditável por
conta e por personagem). O `kind` da essência é `essence`, com reasons
`xp_overflow` (mint online), `offline_settle` (mint no mesmo transaction do
settle) e `rebirth_upgrade:<id>` (burn na compra). O contador de renascimentos
(`character.rebirths`) **não** é moeda e por isso não tem linha de ledger: é
estatística de ciclo, incrementada dentro da transação do renascimento.

## §2. Sinks — trade fee (sink primário)

- `TradeFeeGems = 10` gems, cobradas do personagem que **inicia** o trade,
  queimadas (não vão para a outra parte nem para nenhuma conta — saem de
  circulação).
- Cobrança é *all-or-nothing*: se o saldo de gems for menor que o fee, o
  trade inteiro é abortado antes de qualquer movimentação de item.
- Gems gastas em fee **não são cashable** — não há caminho de conversão de
  volta para dinheiro real a partir do fee (distinção importante para o
  cálculo de RMT/exploit e para a contabilidade de reembolso CDC, que só
  cobre gems *não gastas*, ver `deploy/LAUNCH_HANDOFF.md` item 1d).

## §3. Baús — pity e provably-fair

- `ChestPityEvery = 10`: a cada 10 aberturas de baú de um personagem, a
  11ª é garantida como item raro (tier 3+) do pool da zona.
- Roll determinístico: `hash(server_seed + client_seed + nonce)`, onde
  `nonce` é a contagem de baús já abertos por aquele personagem (também o
  input do timer de pity).
- **Transparência de odds (compliance de loot box)**: distribuição de tier do
  pool da zona é pública via `/chests` **antes** de abrir, e um snapshot
  (`odds_snapshot`) com pool/tiers/nonce/pity é persistido no momento da
  abertura, junto com `server_seed`, para replay em caso de disputa.
- Pool de itens da zona segue a banda de tier `[tier, min(tier+1, 8)]`
  (ver `TECH_SPEC_CORE.md §2`); pool vazio cai para o item padrão.

## §4. VIP

- `VIPModFactor = 1.2` — multiplicador aplicado ao ganho de `OfflineSettle`
  quando `GetVIPUntil(accountID) > agora` (conta com VIP ativo).
- VIP também multiplica a recompensa de boss (ver §6).
- **Tiers e cap offline (Fase B, MONETIZATION §2.2):** `account.vip_tier`
  (migration 022) — 1 = VIP1 (**24h** de cap), 2 = VIP2 (**36h** de cap); F2P
  fica em 12h (`OfflineSettle.CapHoursForAccount`). Upgrade nunca rebaixa tier
  ativo; expirado volta a 12h. Grants `vip_days` carregam tier pelo SKU
  (`vip.3mo` → 2, demais → 1); trial (starter, deal diária) entra como tier 1.
- **Gap conhecido**: não há, no código revisado, detalhe do preço/duração do
  pacote de VIP à venda — só o efeito do status. Preço e duração do SKU de
  VIP devem ser especificados no catálogo (`SHAMBLETA_CATALOG_FILE`, ver
  `deploy/LAUNCH_HANDOFF.md` item 2) e referenciados aqui quando definidos.

## §5. Liquidação offline (`OfflineSettle`)

Parâmetros que convertem tempo desconectado em recompensa ao reconectar:

| Constante | Valor | Efeito |
|---|---|---|
| `OfflineFactor` | 0.6 | Ganho offline é 60% do ganho equivalente online (par da zona) |
| `BaseCapHours` | 12.0 | Teto F2P de horas offline liquidáveis por sessão (VIP1 = 24h, VIP2 = 36h — `CapHoursForAccount`) |
| `DeathTaxPct` | 5% | Penalidade aplicada por morte durante a janela liquidada |
| `MaxChests` | 3 | Máximo de baús gerados por liquidação |
| `ChestHoursPerChest` | 4 | 1 baú a cada 4h offline liquidadas (até o teto de 3) |
| `EfficiencyDecayPerDeath` | 0.05 | Queda de eficiência por morte acumulada na janela |
| `MinEfficiency` | 0.5 | Piso de eficiência (nunca liquida abaixo de 50% do par) |
| `VIPModFactor` | 1.2 | Multiplicador para contas com VIP ativo (ver §4) |
| `GuildHookFactor` | 1.0 (neutro) | Gancho reservado para bônus de guilda — sem efeito hoje |
| `RebirthData.XpStep`/`GoldStep` | 0.05^n | Favores comprados com essência compõem o faucet offline (`XP_PROGRESSION.md §4.2`) |
| `RebirthData.OfflineStep` | +0.02/nível, cap 10 | `attune_offline` eleva o `OfflineFactor` de 0.60 até **0.80** — único bônus com cap |

Fórmula base: `ganho = xpPerKill(zona) × parKillsPerHora(zona) × horas ×
OfflineFactor(attach attune) × eficiência × [VIPModFactor se aplicável] ×
[favor do renascimento]`, com `horas` limitado por `BaseCapHours` e
`eficiência` decaindo por morte até `MinEfficiency`. Favor 0 / attune 0 é
identidade — o golden de settle (§`TECH_SPEC_CORE.md §7`/suíte) não muda.

**Nota anti-abuso**: o teto de `BaseCapHours` e o piso de `MinEfficiency`
existem, mas não há, no código revisado, um sanity check contra manipulação
do relógio do cliente/reconexões artificiais para inflar o tempo offline
liquidado — ver item 13 da auditoria comercial (`anti-cheat não revisitado
para o modelo idle`).

## §6. Boss economy (`BossService`)

- 4 bosses nomeados (`Dorian`, `Gabriel`, `Marvin`, `Splatyna`), piso de nível
  `[5, 5, 5, 10]`.
- Chave de farm (`boss_key`) dropa em zonas de farm a `2000 ppm` (~0,2% por
  kill).
- HP/ataque/defesa do boss escalam com o nível do personagem desafiante
  (`BossHpBase=120 + 46/nível`, multiplicador ×6; `BossAtkBase=12 +3/nível`;
  `BossDefBase=10 +2/nível`).
- **Vitória**: `BossXpKills = 60` (XP equivalente a 60 kills de farm da zona),
  `BossGoldBonus = 1.5×`, `BossChestReward = 1` baú.
- **Derrota**: `ConsolationXpKills = 8` (XP de esforço), e a chave é
  consumida mesmo perdendo (`ConsolationKeepsKey = false`) — sink real,
  não é "tentativa grátis".

## §7. Ver também

Invariantes de ledger/grant e o relógio de pacing que alimenta a fórmula de
`OfflineSettle` estão em `TECH_SPEC_CORE.md §4` e `§5`. A curva de XP/ouro/par
por zona que este documento consome (`xpPerKill`, `parKillsPerHora`) está em
`XP_PROGRESSION.md`.
