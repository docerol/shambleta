# Arquitetura — Shambleta: Idle Auto Battler (Web)

**Versão:** 1.0 (2026-09-09) · **Base de código:** `docerol/sourceofmana@48029cc` · **Docs relacionados:** [ROADMAP.md](ROADMAP.md) · [ECONOMY_STUDY.md](ECONOMY_STUDY.md) · [BENCHMARK_AFK_HEROES.md](BENCHMARK_AFK_HEROES.md)

---

## 1. Conceito do produto

> **Shambleta: Idle** — idle auto battler fantasy jogável no browser. O jogador monta sua **formação** (até 5 personagens), define **equips, skills e o mapa (zona) de farm**, e a equipe luta sozinha no servidor — online ou offline — acumulando XP, gold, drops e baús. Progressão por zonas com gate de poder, guilds com buffs, temporadas com leaderboards, loja de cosméticos/conveniência e VIP. F2P com moeda premium **fechada** (gems).

**O jogador não controla combate.** Toda decisão de build é pré-combate; o combate é resolvido pelo servidor.

### Loop principal
1. Montar/editar **formação** (personagens, equips, skill loadout, consumíveis).
2. Escolher **zona de farm** (40 mapas existentes, com gate de Power).
3. Servidor simula o combate; acumula XP/gold/drops em tempo real (online) ou via settle (offline).
4. Coletar recompensas (com relatório de sessão/offline), gerenciar inventário, abrir baús.
5. Investir: equipamentos, guild, níveis de guild, entradas de boss.
6. Avançar de zona → repetir, com seasons reposicionando o leaderboard periodicamente.

---

## 2. Princípios de arquitetura

1. **O servidor Godot existente permanece o simulador autoritativo.** Não reescrevemos o combate; colocamos uma **CombatPolicy** no lugar do input humano (mesmo padrão do `ownScript`/`NpcScript` já presente em `PlayerAgent.gd:279`).
2. **Cliente é "painel de gestão".** RPCs novos reduzidos a comandos de configuração e consulta — todos rate-limited pelo `Footprint` existente. Nenhum estado de combate vem do cliente.
3. **Toda moeda e todo item passam por ledger append-only.** Saldo nunca muda sem linha de transação (`wallet`, `transaction`), herança direta do requisito da moeda premium (RELATORIO §3.2) e da principal lição negativa do AFK Heroes (itens que "somem").
4. **Offline = fórmula, não simulação.** O servidor nunca simula 24/7 de todas as contas; progresso offline é calculado por taxa média da zona, com caps e relatório auditável (§8).
5. **Data-driven sempre.** Zonas, guild levels, VIP, baús, catálogo da loja: tudo em recursos `.tres`/JSON no padrão existente do projeto (`presets/cells/`, `data/db/*.json`), sem valores hardcoded.
6. **Pagamentos nunca no game server.** Serviço companion (REST) é a única fronteira de dinheiro real (§11).
7. **Fork disciplinado.** Manter `sources/` upstream intocado onde possível; extensões em módulos próprios (`sources/idle/`, `sources/economy/`) para facilitar sync futuro com o upstream (§13).

---

## 3. Visão de contexto (system landscape)

```
                         ┌──────────────────────────────┐
                         │        JOGADOR (browser)     │
                         │  PWA Godot Web (COOP/COEP)   │
                         └──────┬───────────────┬───────┘
                 WebSocket/WSS  │               │  HTTPS (REST, opcional p/ web)
                                ▼               ▼
        ┌───────────────────────────────┐   ┌─────────────────────────────┐
        │      GAME SERVER (Godot 4.7)  │   │   COMPANION SERVICE (REST)  │
        │  - CombatPolicy (auto-battle) │   │  - Conta/e-mail/2FA (fase 2)│
        │  - OfflineSettle              │◄──┤  - Pagamentos (Stripe/Pix)  │
        │  - EconomyService (ledger)    │IP │  - Webhooks → grants        │
        │  - GuildService/TradeService  │or │  - VIP grants               │
        │  - SeasonService              │ipc│  - Anti-fraude/velocity     │
        │  - SQLite (+WAL)              │   │  - PostgreSQL               │
        └──────┬────────────────────────┘   └───────┬─────────────────────┘
               │ shared DB access (fase 1: mesmo arquivo/banco)      │
               ▼                                      ▼
        ┌────────────────────────────┐   ┌───────────────────────────────┐
        │  Observabilidade           │   │  Gateways externos            │
        │  Sentry + métricas + logs  │   │  Stripe/Pix · e-mail (Brevo)  │
        └────────────────────────────┘   └───────────────────────────────┘
```

**Fase 1:** companion e game server compartilham o mesmo SQLite (grants gravados pelo companion com `WAL`, leitura pelo server). **Fase 2:** migração do companion para PostgreSQL; game server permanece SQLite com sync dos grants via tabela de filas (`grant_queue`), isolando domínios.

---

## 4. Componentes novos no game server (Godot)

Todos em módulos novos, seguindo o padrão `ServiceBase` do projeto (`sources/system/ServiceBase.gd`, serviços registrados em `Launcher.gd`):

### 4.1 `IdlePolicy` (CombatPolicy) — `sources/idle/IdlePolicy.gd`
Substitui o input humano do `PlayerAgent`.
- Por personagem ativo na formação: engaja o mob mais próximo elegível da zona (reusa `WorldNavigation`, spawns existentes), seleciona skill por prioridade configurada (cooldown/type-aware, reusa `Skill.Cast`), usa consumível se HP < X% (reusa `Inventory.UseItem`), coleta drops (reusa `WorldDrop.PickupDrop`).
- Loop do mundo permanece o atual (`WorldInstance`, `AI` de monstros inalterada). Zona de farm = `WorldInstance` do mapa escolhido **reservado para farming** (ver §7: instâncias separadas das sociais, evita interferir visualmente).
- **Determinismo assistido:** ticks de combate gravados como agregados por janela (dano/kill/tempo), alimentando as taxas do settle offline (§8) — sem log de combate completo.
- Failsafe: se o agente ficar preso/travado > N s, respawn na entrada da zona; se a formação morrer, perda parcial de eficiência da sessão (ver ECONOMY §5.3 "death tax").

### 4.2 `OfflineSettle` — `sources/idle/OfflineSettle.gd`
> **Retificação 2026-09-25 (documento arquivado):** o teto não é mais fixo por VIP — `CapHoursForCharacter` = 1 h de base (F2P) + 1 h por anúncio `afkhoras` assistido desde a última coleta, ou 24 h com VIP ativo; o tier 2 ainda multiplica o loot por 2. O texto abaixo é o contrato original.

- No login de personagem: `last_settled_at` → agora, teto de acumulação (`OfflineCapHours`, default 12h; VIP estende — ECONOMY §3).
- Recompensa = `taxa_média_da_zona × horas × modificador_offline × bônus(VIP/guild/boosts)` com rolagem de drops por distribuição da zona (tabela `zone_drop_rate`), não simulação frame a frame.
- **Atomicidade:** settle inteiro dentro de `BEGIN/COMMIT` (SQLite) escrevendo no ledger — sem caminho de duplicação.
- Entrega o **AFK Report**: tela de retorno (deltas de XP/gold/itens/baús/tempo, "você foi derrotado 3×; eficiência 87%").

### 4.3 `EconomyService` — `sources/economy/EconomyService.gd`
- Único ponto de mutação de saldos/itens: `GrantGold`, `GrantGems`, `GrantItem`, `Spend`, `OpenChest`, `TradeEscrow`.
- Toda mutação = linha em `ledger_transaction` + `BEGIN/COMMIT`; saldo derivado é cache em `wallet.cache_gold/cache_gems`.
- Integração com o fluxo de item existente: drops de combate entram via `NpcCommons.AddItem` → redirecionado para `EconomyService.GrantItem` (ponto único).

### 4.4 `GuildService` — `sources/idle/GuildService.gd`
- CRUD de guild, membership (limite por nível), níveis 1–10 com custo progressivo em **gold + gems + Guild Points** (sink forte, espelha AFK Heroes), buffs % aplicados no settle/simulação, guild vault (depósito/retirada com permissões, tudo no ledger), leaderboard semanal.
- Nota: o "clã" MMORPG upstream **não existe** no código (verificado) — construímos guild nativa já no formato idle (formação compartilhada de buffs, não gameplay em tempo real).

### 4.5 `TradeService` — `sources/economy/TradeService.gd`
- Escrow de trade (§10 do ECONOMY): oferta com itens + gold; taxa do vendedor em **gems, queimada**; janela de confirmação de 60s; tudo transacional.
- Restrição inicial: trades liberados por **tier de conta** (e-mail verificado + nível mínimo), rate-limit e cooldown anti-RMT; itens **bound** (cosméticos comprados) são não-tradeáveis.

### 4.6 `SeasonService` — `sources/idle/SeasonService.gd`
- Temporadas de 4–8 semanas; snapshots (power, kills, spend, guild) a cada hora para leaderboards; premiação em cosméticos exclusivos + gems (corrida "Most Spenders" pontua gasto de gems, agregado do ledger — nunca premia com cash-out).
- **Regras congeladas no início da temporada** (lição do backlash do AFK Heroes); mudanças só com anúncio ≥7 dias.

### 4.7 `VipService` — `sources/economy/VipService.gd`
- Estado de VIP por conta (tier 1/2, duração 30d, renovação empilhável), perks consultáveis client-side via payload de login (ver ECONOMY §3 para o desenho completo).

---

## 5. RPCs novos (superfície de rede)

Padrão existente: `@rpc` em `sources/network/Network.gd` com validação em `Server.gd` + `Footprint` (rate-limit). Canais: CONNECT/ACTION/ENTITY existentes — novos métodos entram em `ACTION` (reliable).

| RPC | Direção | Payload | Rate-limit |
|---|---|---|---|
| `SetFormation(formation: Dictionary)` | C→S | 5 slots: charID + skill loadout + consumíveis | 5/min |
| `SetFarmZone(zoneID: int)` | C→S | valida gate de Power | 5/min |
| `ClaimOfflineSettle()` | C→S | dispara settle se pendente | 1/login |
| `GetAFKReport()` | C→S | relatório da última sessão/offline | 1/min |
| `OpenChest(chestInstanceID: int, keyItemID: int)` | C→S | server valida posse e revela odds | 10/min |
| `CreateGuild(name)/JoinGuild(id)/LeaveGuild()/GuildDeposit/GuildWithdraw` | C→S | — | 5/min |
| `CreateTradeOffer(items, gold)/AcceptTrade(offerID)/CancelTrade` | C→S | escrow no server | 1/10s |
| `PurchaseShopEntry(skuID)` | C→S | catálogo data-driven; gems via ledger | 10/min |
| `ShopCatalog()` / `GetLeaderboard(kind)` | C→S | leitura | 1/min |

**Removidos do caminho crítico do idle:** `SetClickPos/SetMovePos/TriggerEmote/...` continuam existindo (upstream intacto) mas são irrelevantes no modo idle.

---

## 6. Modelo de dados (migrations 009–016)

Convenção do projeto mantida: arquivos em `data/conf/migrations/`, template em `data/conf/templates/sqlite.template.db`, `SQL.gd` não é alterado em sua API (novos acessos via módulos).

```sql
-- 009_economy_core.sql
CREATE TABLE wallet (
  account_id INTEGER PRIMARY KEY REFERENCES account(account_id),
  cache_gold INTEGER NOT NULL DEFAULT 0,     -- cache do saldo derivado
  cache_gems INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE TABLE ledger_transaction (
  id INTEGER PRIMARY KEY AUTOINCREMENT,      -- append-only: sem UPDATE/DELETE (trigger bloqueia)
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  kind TEXT NOT NULL,        -- grant|spend|trade_fee|chest_open|settle|vip|refund|adjust|guild_level
  currency TEXT NOT NULL,    -- gold|gems|item
  ref_id TEXT,               -- item_hash / sku / offer_id
  amount INTEGER NOT NULL,   -- itens: signed; moedas: delta
  balance_after INTEGER,     -- p/ auditoria de moedas (itens: NULL)
  reason TEXT, created_at INTEGER NOT NULL
);
CREATE TRIGGER trg_ledger_no_update BEFORE UPDATE ON ledger_transaction BEGIN SELECT RAISE(ABORT,'ledger is append-only'); END;
CREATE TRIGGER trg_ledger_no_delete BEFORE DELETE ON ledger_transaction BEGIN SELECT RAISE(ABORT,'ledger is append-only'); END;

-- 010_idle_progression.sql
ALTER TABLE character ADD COLUMN power_score INTEGER DEFAULT 0;
CREATE TABLE farm_zone (  -- data-driven, populada de .tres/json (cache SQL p/ relatórios)
  zone_id INTEGER PRIMARY KEY, map_id INTEGER NOT NULL, name TEXT, min_power INTEGER,
  tier INTEGER, gold_per_hour INTEGER, xp_per_hour INTEGER, death_tax_pct INTEGER DEFAULT 5 );
CREATE TABLE zone_drop_rate (
  zone_id INTEGER REFERENCES farm_zone(zone_id), item_hash INTEGER NOT NULL,
  rate_ppm INTEGER NOT NULL, PRIMARY KEY (zone_id, item_hash) );  -- ppm = parts per million
CREATE TABLE character_settle (
  char_id INTEGER PRIMARY KEY REFERENCES character(char_id),
  zone_id INTEGER, last_settled_at INTEGER NOT NULL, session_efficiency REAL DEFAULT 1.0 );

-- 011_formation.sql
CREATE TABLE formation (
  account_id INTEGER, slot INTEGER CHECK(slot BETWEEN 0 AND 4), char_id INTEGER UNIQUE,
  skill_loadout TEXT, auto_potion_pct INTEGER DEFAULT 35,
  PRIMARY KEY (account_id, slot) );

-- 012_guild.sql
CREATE TABLE guild (
  guild_id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL,
  level INTEGER DEFAULT 1, points INTEGER DEFAULT 0, created_at INTEGER,
  creation_fee_gold INTEGER NOT NULL );     -- auditável
CREATE TABLE guild_member ( guild_id INTEGER REFERENCES guild(guild_id),
  account_id INTEGER PRIMARY KEY REFERENCES account(account_id), rank TEXT DEFAULT 'member',
  joined_at INTEGER );
CREATE TABLE guild_vault_log ( id INTEGER PRIMARY KEY AUTOINCREMENT, guild_id INTEGER,
  account_id INTEGER, item_hash INTEGER, amount INTEGER, created_at INTEGER );  -- append-only

-- 013_trade.sql
CREATE TABLE trade_offer (
  offer_id INTEGER PRIMARY KEY AUTOINCREMENT,
  seller_account INTEGER, buyer_account INTEGER,        -- buyer NULL = listagem AH
  payload TEXT NOT NULL,       -- JSON: [{item_hash,count}] + gold
  fee_gems INTEGER NOT NULL,   -- taxa do vendedor, queimada no accept
  status TEXT DEFAULT 'open',  -- open|accepted|cancelled|expired
  created_at INTEGER, expires_at INTEGER );
CREATE TABLE trade_log ( id INTEGER PRIMARY KEY AUTOINCREMENT, offer_id INTEGER,
  seller_account INTEGER, buyer_account INTEGER, fee_gems INTEGER, created_at INTEGER ); -- append-only

-- 014_shop_chest_vip.sql
CREATE TABLE chest_instance ( chest_id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER,
  origin TEXT, item_state TEXT NOT NULL, obtained_at INTEGER, opened_at INTEGER );
CREATE TABLE chest_open ( id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER,
  chest_id INTEGER, key_item_hash INTEGER, rewards TEXT NOT NULL, -- JSON
  odds_snapshot TEXT NOT NULL, server_seed TEXT, client_seed TEXT, nonce INTEGER, -- provably-fair
  created_at INTEGER );                       -- append-only
CREATE TABLE vip_state ( account_id INTEGER PRIMARY KEY REFERENCES account(account_id),
  tier INTEGER DEFAULT 0, expires_at INTEGER );

-- 015_season.sql
CREATE TABLE season ( season_id INTEGER PRIMARY KEY AUTOINCREMENT, starts_at INTEGER,
  ends_at INTEGER, rules_frozen_json TEXT NOT NULL );
CREATE TABLE season_score (
  season_id INTEGER, kind TEXT,               -- power|boss_kills|spend|guild_points
  subject_id INTEGER, value INTEGER, PRIMARY KEY (season_id, kind, subject_id) );

-- 016_shop_catalog.sql
CREATE TABLE shop_sku ( sku_id TEXT PRIMARY KEY, kind TEXT, payload TEXT, price_gems INTEGER,
  live_from INTEGER, live_to INTEGER );       -- espelho SQL do catálogo .tres p/ analytics
```

**Convenções:** todos os saldos derivam do ledger; `cache_*` são recomputáveis; triggers de append-only espelham o padrão de triggers do template (`trg_account_delete` etc.); FKs ativas (o template já as usa).

---

## 7. Zonas de farm e instâncias

- Os 40 TMX existentes são catalogados em `farm_zone` (tier 1–8 por dificuldade média dos mobs do mapa + boss de zona no tier mínimo).
- **Separação de instâncias:** o server mantém instâncias "sociais" (visuais, como hoje) e **instâncias de farm por zona** (cap alto de agents, visibilidade reduzida, sem chat local obrigatório). Um jogador idle não ocupa spawn de exploração — `WorldInstance` já suporta múltiplas instâncias por mapa (`WorldMap.areas/instances`).
- Gate de entrada: `power_score ≥ min_power`. Power Score = função determinística de equips (modifiers), level, skills — calculada server-side ao mudar equip/loadout (reusa `Formula.gd`/`BaseStats`).
- Boss de zona: spawna com cooldown por guild/tick; primeira kill da semana dá drop garantido (tap de engajamento).

## 8. Matemática do progresso offline (contrato)

> `CapHours(vip)` de 2026-09-25 em diante é `CapHoursForCharacter(char)` = cap comprado pela conta (1 h / 24 h VIP) + horas `afkhoras` assistidas desde a última coleta. O `×2` do tier 2 não entra em `mods`: multiplica XP/ouro/drops da liquidação.

```
hours           = min(now - last_settled_at, CapHours(vip))          // cap 12h base, 24h VIP1, 36h VIP2
eff             = session_efficiency (0.5..1.0, média da última simulação online da zona; 1.0 se nunca farmou)
offline_factor  = 0.6   (online full = 1.0)
mods            = (1 + guild_buffs) * (1 + vip_bonuses) * event_boosts
gold            = floor(zone.gold_per_hour * hours * eff * offline_factor * mods)
xp              = floor(zone.xp_per_hour   * hours * eff * offline_factor * mods)
drops           = Poisson/rolagem por item: rate_ppm * hours * 3600 * eff * offline_factor * mods
chests          = 1 chance por X horas de farm (janelas de 4h, teto por sessão)
death_tax       = se eff < 1.0, gold reduzido adicionalmente (death_tax_pct da zona)
```
- `session_efficiency` atualizada no fim de cada sessão online (kill/dano/tempo vs. par da zona) — jogador que "configura mal" colhe menos: o skill do jogo é a build.
- Settle é **idempotente** por `last_settled_at` (segundo login no mesmo segundo não duplica).
- Toda saída vai ao ledger com `kind=settle` — o AFK Report do cliente lê do ledger (auditoria gratuita).

## 9. Cliente (Godot Web) — mudanças de UI

- Novas janelas no padrão `WindowPanel`/`Window.tscn`: **Formation Builder** (grid de slots, drag equips do `Inventory` existente), **Zone Map** (lista de zonas com gate/rew ards estimados), **AFK Report**, **Guild**, **Trade/AH**, **Shop**, **Leaderboard/Season**.
- HUD reduzido: minimap/chat ficam secundários; a cena `Game.tscn` ganha modo "management" (câmera observando a zona do farm, combates visíveis — keep-sake visual dos assets CC BY-SA).
- Login/char selection existentes reaproveitados 100% (RPCs de auth inalterados na fase 1).

## 10. Deploy web

- **Build:** preset Web existente (`preset.5`) — PWA on, threads on; CI ganha job `Web` (hoje ausente, RELATORIO §D5) publicando em bucket/CDN com **COOP: same-origin** e **COEP: require-corp** (obrigatório p/ `thread_support=true`).
- **Servidor público:** WebSocket **WSS** (TLS obrigatório — RELATORIO §C7) atrás de proxy; ENet mantido p/ dev.
- **Domínios:** jogo (CDN + WSS), companion (api.*), site (marketing).
- **Throttling de aba:** client usa `Timer` em wall-clock e reconexão idempotente (handshake de protocol version + token 30d já suportam).
- **Peso:** strip agressivo (audio >X mbps, mapas não-zona, addons editor-only) via `exclude_filter` — meta <25 MB gzip no primeiro load.

## 11. Companion service (dinheiro real)

- **Stack sugerida:** Go ou Node + PostgreSQL; deploy containerizado; sem estado de sessão do jogo.
- **Responsabilidades:** conta (fase 2: e-mail verificado/único, 2FA TOTP), checkout (Stripe card/Pix + adapter cripto via processador licenciado — Coinbase Commerce/BTCPay; idempotência por tx hash; o *processador* é a PSAV regulada, Resoluções BCB 519–521/2025 — ver ECONOMY_STUDY §4), **webhook idempotente** → grava `grant_queue` (gold/gems/vip/sku) → game server consome e escreve no ledger (`kind=grant/vip`) → confirmação grava `processed=true` (at-least-once + idempotency key do gateway).
- **Anti-fraude:** velocity check por conta/cartão/IP, blocklist de chargeback → suspensão de conta (`ban` já existe) e reversão por estorno (ledger `kind=refund` com `reason`).
- **Reembolsos:** política pública 14 dias para gems **não gastas** (padrão consumer); gasto em itens consumíveis não é reembolsável (ToS).

## 12. Observabilidade e operação

- Sentry (já integrado) + métricas novas no companion e no server: CCU, sessões, settle/hora, gems mint/burn, taxa de trade, falhas de webhook, lag de tick das zonas de farm.
- Backups: SQLBackups existente + **offsite diário** + restore testado mensalmente (runbook).
- Alertas: fila `grant_queue` com itens não processados >5 min; queda de CCU; taxa de erro de settle.

## 13. Política de fork (deviations do upstream)

| Área | Estratégia |
|---|---|
| `sources/` core (network, world, actor) | Tocar o mínimo; patches pequenos e marcados `// SOM-IDLE:` para diff fácil |
| Módulos novos | `sources/idle/`, `sources/economy/` (self-contained, sem tocar classes upstream além de registration) |
| Migrations | Nunca editar 001–008; apenas adicionar |
| Assets upstream | Usar como está (CC BY-SA mantém-se); assets novos com licença própria (ver ROADMAP F0) |
| Sync upstream | Rebase trimestral revisado; `ComputeProtocolVersion` invalida clientes antigos automaticamente (bom: força update) |

## 14. Riscos arquiteturais e mitigações

| Risco | Prob. | Impacto | Mitigação |
|---|---|---|---|
| Tick das zonas de farm não escala com N jogadores simultâneos | Média | Alto | Instâncias por zona com cap; batch de agents; se necessário, shard por região/zone-group (§15) |
| SQLite contention entre server e companion | Média | Alto | WAL + busy_timeout já configurados em debug; fase 2 separa Postgres; grant_queue desacopla |
| Duplicação de itens em crash durante trade/chest | Baixa | Crítico | Tudo em `BEGIN/COMMIT` + ledger; testes de crash no CI |
| RMT/bots farmando 24/7 | Alta | Médio | Escrow + fees, caps, velocity, ban por conta/IP, bound items, client-seed em chests |
| Regressão no jogo original (se mantido) | Média | Médio | Política de fork §13; flags de modo (`LauncherCommons`) por build |
| Peso do build web expulsa novo usuário | Média | Médio | Strip §10; PWA cache; loading progressivo |

## 15. Caminho de escala

1. **<500 CCU:** 1 game server + SQLite WAL + companion container. Custo ~1 VPS médio.
2. **500–3k CCU:** server multi-processo por zone-group (world sharding manual: zonas A–D no processo 1, etc.), login/proxy simples, Postgres no companion, Redis p/ leaderboards.
3. **>3k CCU:** extração do settle para workers dedicados; leaderboards em serviço próprio; CDN de assets regional.
   *(Auto battler idle tem CCU/sessão alto mas bandwidth baixa — o gargalo é CPU de simulação, mitigado por instâncias/zona e por settle offline não-simulado.)*
