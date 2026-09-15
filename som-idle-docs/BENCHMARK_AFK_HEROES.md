# Benchmark: AFK Heroes (afkheroes.xyz) → aplicação ao Source of Mana Idle

**Fontes:** [solgames.buzz/game/afk-heroes](https://solgames.buzz/game/afk-heroes), [cryptogames.gg](https://cryptogames.gg/afk-heroes-sets-friday-launch-for-season-2-opens-early-access-waitlist/), [cryptogames3d.com (guilds)](https://cryptogames3d.com/afk-heroes-launched-guilds-members-could-earn-up-to-25-extra-afkhero/), X/@AFKHeroesXYZ. Dados de ago/2026.

## 1. O que o AFK Heroes é

Idle RPG voxel jogável no browser (Solana, lançado jun/2026, P2E com token $AFKHERO). Loop:

- **Auto Battle 24/7**: jogador monta a equipe e os heróis lutam sozinhos, **mesmo offline** (recompensas continuam acumulando).
- **Zone Progression**: biomas com gate de nível (Frozen Spire Lv40 → Singularity Vault Lv90+), cada zona com boss próprio.
- **Loot & Builds**: gear e relics dropam do combate; otimização de build = o jogo em si.
- **Ancient Appraisal (chests)**: baús dropam durante o combate; abertura paga em token com **odds provably-fair exibidos antes de abrir**; baús/chaves/fragmentos são **tradeáveis**.
- **Guilds**: criar custa 250k tokens (sink); 5 níveis desbloqueados com Gold + token + Guild Points; **vault compartilhado**; tags cosméticas; bônus de até **+25% ganhos, +100% XP, +100% Gold**; leaderboard de guildas paga 5M tokens/temporada.
- **Seasons/Leaderboards**: temporada encerra com distribuição de token em 4 corridas — Top 50 geral, **Most Spenders** (top 20), Most Boss Kills, Power Level. "Power level decide o split do reward pool".
- **Marketplace**: 45 dias = $48K de volume, 43k vendas, 15.6k wallets; câmbio Gold→token.

## 2. Lições (o que copiar e o que evitar)

| Lição | Evidência AFK Heroes | Aplicação no SoM Idle |
|---|---|---|
| **Offline earnings são o coração do gênero** | "heroes auto-fight 24/7, earn even while offline" | Offline settle por fórmula + relatório de retorno (ver ARCHITECTURE §4) |
| **Sinks fortes geram economia viva** | criar guild = 250k tokens; guild levels custam gold+token+points; chests pagas | Guild creation em gold alto; níveis de guild consomem gold+gems; chaves de baú em gems |
| **Odds visíveis geram confiança** | "provably-fair odds shown pre-open" + screenshots de jackpots diários | Mostrar % de drop dos baús na UI antes de abrir (também exigência legal crescente para loot boxes pagos) |
| **Seasons com 4 corridas** | Top geral, Most Spenders, Boss Kills, Power Level | Replicar 3–4 corridas; **congelar regras no início da temporada** (eles mudaram regra a 3 dias do fim e levaram backlash) |
| **Guild como multiplicador de retenção** | +25% earnings/+100% XP por guild; leaderboard de guilds | Guild buffs % e leaderboard semanal |
| **Power level como métrica central** | decide split de recompensas | Power Score calculado das builds = ranking principal |
| **Ledger de tudo** | review 1★: "itens comprados somem e o dev sugere comprar de novo" | Ledger append-only de grants/compras/trades + ferramenta de CS (evita o pior feedback deles) |
| **P2E/crypto trouxe volatilidade e exposição regulatória** | market cap ~-74% do ATH em ~3 meses ($473.6K → ~$122K, DexScreener set/2026); recap de 45d: $53K gastos por jogadores vs $14.3K recebidos; câmbio gold→token 8× pior desde S1; prêmio do 1º lugar da S2 ≈ $190; review 1★: itens comprados somem | **Não usar token/cripto**; moeda premium fechada (gems), não-cashable, sem transferência P2P |
| **Dev muito presente = comunidade fiel** | dezenas de reviews elogiando cadência de updates | Live-ops com changelog público semanal desde o beta |

## 3. Mapeamento de features → arquitetura SoM

| AFK Heroes | SoM Idle equivalente | Onde |
|---|---|---|
| Heroes/team | Formação de até 5 personagens próprios (10 slots existentes) | `formation` + `formation_slot` |
| Zones com gate de nível | Os 40 mapas existentes viram zonas de farm com nível/Power gate | `farm_zone` (data-driven dos TMX) |
| Loot chests pagas | Baús dropam no combate; chaves vendidas por gems; odds públicas | `chest`, `chest_open` (ledger) |
| Guild levels + vault | Guild com níveis (gold+gems+Guild Points), vault, buffs % | `guild`, `guild_member`, `guild_vault_log` |
| Marketplace (token) | AH/trade P2P em **gold**, com **taxas em gems (sink queimado)** | `trade_offer`, `trade_log` |
| Seasons/leaderboards | Temporadas de 4–8 semanas, snapshots, 4 corridas | `season`, `season_score` |
| Most Spenders | VIP + gasto de gems pontuável | `premium_transaction` agregada |
| Token/câmbio | **Não replicar** — gems fechadas, sem cash-out | — |
