# Passe de Temporada 1 — Design Detalhado ("Era da Redescoberta")

**Versão:** 1.0 (2026-09-09) · Relacionados: [MONETIZATION.md](MONETIZATION.md) · [ARCHITECTURE.md §4.6](ARCHITECTURE.md) · [ECONOMY_STUDY.md](ECONOMY_STUDY.md)
**Status:** design para revisão — implementação na Fase 4 (SeasonService), com telemetria de tuning desde o beta fechado.

---

## 1. Visão geral

| Parâmetro | Valor | Racional |
|---|---|---|
| Duração S1 | **28 dias** | Padrão do gênero; 4 semanas de missões fecham a matemática da curva |
| Tema | **"Era da Redescoberta"** (lore oficial em `designs/Timeline`) | Cosméticos contam a história do jogo; diff de arte raso (paletas existentes) |
| Níveis | **30 na trilha principal + 10 bônus (31–40)** | 30 = compromisso de conteúdo; bônus = "faixa infinita" barata |
| XP por nível | L1–10: 100 · L11–20: 120 · L21–30: 140 · **Total 3.600 XP** | Curva quase-linear; ver §3 |
| Preço | **Premium R$ 24,90** (+ variante Deluxe R$ 44,90, opcional) | Faixa aceita no BR; devolve ~65–70% em gems |
| Regra de ouro | **Regras e tabela de recompensas congeladas no dia 0** | Lição AFK Heroes (mudança a 3 dias do fim = backlash) |

**Como se ganha XP:** missões diárias/semanais (gameplay real, validadas server-side) + marcos de progressão (primeira kill de boss por zona). **Nada de XP por tempo pago** — o passe mede engajamento, não carteira (o "Most Spenders" da corrida de leaderboards cuida do gasto).

> **Nomenclatura:** o acumulador do passe chama-se **Pontos de Temporada (PT)** — não "XP" — para não confundir com a XP do jogo, que na nova escala é exponencial e granular ([XP_PROGRESSION.md](XP_PROGRESSION.md)). Os números do passe (40/120 PT) ficam pequenos de propósito.

## 2. Fontes de XP (tabela oficial)

| Fonte | Frequência | XP | Total na temporada |
|---|---|---|---|
| Missão diária (3 de um pool de 8, reset 03:00 BRT) | 28 dias | 40 cada | 3.360 |
| Missão semanal (3 de um pool de 6) | 4 semanas | 120 cada | 1.440 |
| Marco: primeira kill de boss de zona (1×/zona, 8 zonas S1) | one-shot | 50 cada | 400 |
| **XP máximo possível** | | | **5.200** |
| Bônus VIP | passivo | **+10% de todo XP de passe** | até +520 |

**Perfis simulados (validação da curva):**
- **Hardcore** (100% dailies+weeklies+marcos): ~5.200 XP → **termina L30 no dia ~20–21**, bônus 31–34 no fim. Deixa folga para um erro.
- **Ativo** (~70% dailies, 70% weeklies, metade dos marcos): ~3.600 XP → **termina L30 no dia ~27–28** (final apertado = FOMO saudável de compra no fim).
- **Casual** (~50% dailies, 50% weeklies): ~2.400 XP → **chega a L20–22**. Perde o L30 (prêmio maior) → gatilho clássico de compra de nível skip.

**Skip de nível:** 50 gems/nível, **máx. 10/temporada** (cap explícito, exibido na UI). É sink + catch-up justo; acima disso o jogador espera a próxima temporada (protege o valor do passe).

## 3. Trilha GRÁTIS (todo jogador, sem pagar)

Níveis-chave (demais níveis: gold/itens pequenos):

| Nível | Recompensa |
|---|---|
| 3 | 10 gems |
| 5 | Chave de baú comum |
| 8 | 10 gems |
| 10 | Emote "Tocha do Explorador" |
| 13 | 15 gems |
| 16 | Chave de baú comum |
| 20 | 15 gems |
| 24 | Chave de baú rara |
| 27 | 20 gems |
| 30 | **30 gems + Título "Redescobridor"** |

Total grátis: **100 gems + 3 chaves + emote + título**. Função: mostrar o valor da trilha premium (espalhar recompensas "gostosas" nos níveis também premium-adjacentes).

## 4. Trilha PREMIUM (R$ 24,90)

| Nível | Recompensa | Categoria |
|---|---|---|
| 1 | **Skin de formação "Manto do Descobridor"** (visual do conjunto) | Cosmético ⭐ |
| 3 | 25 gems | Moeda |
| 5 | VIP 3 dias (trial) | QoL |
| 6 | 25 gems | Moeda |
| 8 | **Efeito de drop "Faísca de Mana"** (o "rainbow" visível aos outros) | Cosmético ⭐⭐ |
| 9 | 25 gems | Moeda |
| 11 | Chave de baú rara | Consumível |
| 12 | 25 gems | Moeda |
| 14 | Moldura de perfil sazonal | Cosmético |
| 15 | **50 gems** | Moeda |
| 17 | **Skin de formação "Máscara Ritual de Tulimshar"** | Cosmético ⭐⭐ |
| 18 | 25 gems | Moeda |
| 21 | Chave de baú épica | Consumível |
| 22 | 25 gems | Moeda |
| 24 | Emote exclusivo "Sinal da Guilda" | Cosmético |
| 26 | 25 gems | Moeda |
| 28 | 50 gems | Moeda |
| 30 | **100 gems + Título "Veterano da Redescoberta" + Estandarte de guild sazonal** | ⭐⭐⭐ |
| 31–40 (bônus) | 20 gems por nível (repetível de temporada em temporada) | Moeda |

**Total premium: 400 gems** (≈ R$ 16–18 em valor de catálogo → **retorno ~65–70% do preço**) + 3 chaves + 5 cosméticos + trial de VIP. O "custo líquido percebido" fica em ~R$ 7 — é isso que faz o passe ser o SKU de maior attach do gênero.

**Deluxe (opcional, +R$ 20):** Premium + 10 níveis instantâneos + emote exclusivo "Coroa do Sol" + 150 gems. Meta: ~30% dos compradores escolhem Deluxe; **nunca** vende níveis além do cap de skip individual (o Deluxe é um atalho de conveniência, não um passe diferente).

### Regras de UX (não negociáveis)
- Comprar premium **no meio da temporada** libera retroativamente todas as recompensas premium dos níveis já alcançados (nunca punir a compra tardia).
- Recompensas não-claimadas no fim da temporada são **creditadas automaticamente** no ledger + notificação no AFK Report (nunca expirar silenciosamente — lição dos "itens que somem").
- Cosméticos sazonais **retornam** após ≥2 temporadas na "Loja do Legado" (exceto o emote Deluxe, exclusivo vitalício) — escassez com calendário público.

## 5. Catálogo de missões (pools)

### Diárias (3 sorteadas de 8, reset 03:00 BRT — mesma sorteio para todos no dia, server-side)
1. Colete a recompensa do AFK **2×** (settle/claim)
2. Abra **1 baú** (qualquer origem)
3. Equipe **3 itens novos** na formação (equip/un-equip conta 1× por item)
4. Derrote **25 mobs** na zona de farm atual
5. Deposite **1 item** no vault da guild (ou "entre na guild se não tem" — versão pré-F3: "visite o painel de guild")
6. Complete **1 trade** no AH (pré-F4: substituir por "use a re-forja 1×")
7. Re-forje **1 equipamento**
8. Assista a **1 rewarded ad** (se ads ativos; senão substituir por "abra a loja")

### Semanais (3 sorteadas de 6)
1. Derrote o **boss de 1 zona** (qualquer)
2. Alcance **eficiência de sessão ≥ 90%** em 3 sessões de farm
3. Gaste **100 gems** (qualquer sink — incentiva conhecer a loja; devolve no passe)
4. Complete **15 missões diárias** na semana
5. Suba a guild **1 nível** (ou contribua 1.000 gold no vault)
6. Farme **≥ 8 horas acumuladas** (online + offline settle somados)

**Anti-abuse:** progresso 100% server-side a partir de eventos do ledger (settle, chest_open, trade_log, guild_vault_log, re-forja) — nada de contador client-side; missões diárias não acumulam para o dia seguinte; eventos gerados antes de comprar o passe contam normalmente (XP é da conta, não da trilha).

## 6. Impacto na economia (faucet/sink)

| Fluxo | Efeito | Verificação |
|---|---|---|
| Gems para o jogador (faucet) | 100 grátis + 400 premium + 200 bônus = **até 700 gems/temporada/passe** | Faucet controlado e **pré-pago** (o passe é receita antes do faucet existir — inversão saudável vs. mint free-to-play) |
| Skip de nível (sink) | 50 gems × até 10 | Estimativa: 15–25% dos compradores usam ≥1 skip |
| Missão "gaste 100 gems" (sink) | 100 gems/semana direcionadas a sinks existentes | Telemetria: distribuição entre chaves/guild/reforja |
| Chaves ganhas (fauce→sink) | 3 grátis + 3 premium abrem baús → loot no ledger | Chance de puxar o jogador para o loop de chaves (gateway do gacha) |

**Orçamento de diluição:** o passe "imprime" no máximo 700 gems/100% de jogador hardcore — diluição conhecida e coberta pela receita do passe (é faucet **financiado**). Diverge do AFK Heroes, cujo faucet de token era dívida do reward pool.

## 7. Implementação (onde encaixa na arquitetura)

- **Dados (migration 015 estendida):** `season_pass_level(level, track, payload)` (data-driven, `presets/seasons/s1.json` espelhado em SQL p/ analytics) · `season_account_state(account_id, season_id, xp, premium, claimed_free TEXT, claimed_premium TEXT, skips_used)` · `season_mission_state(account_id, mission_id, period_id, progress, claimed)`.
- **RPCs (padrão Network.gd + Footprint):** `GetSeasonPass()` · `ClaimPassReward(level, track)` · `BuyPass(tier)` · `SkipLevel(n)` · `ClaimMission(id)`. Compra passa pelo companion (mesma `grant_queue`).
- **Eventos que alimentam missões:** todos já existem no ledger pós-F1/F2 (`settle`, `chest_open`, `trade_log`, `guild_vault_log`) + telemetria de kill/eficiência da IdlePolicy. Zero novo caminho de confiança.
- **UI:** janela `WindowPanel` "Temporada" com as duas trilhas lado a lado (coluna grátis | premium bloqueada com preço), barra de XP, abas Missões/Regras — regras da temporada visíveis **link permanente** (transparência como feature).
- **Tempo:** tudo em epoch; reset de missão em UTC-3 (03:00 BRT) para o "dia" coincidir com o hábito BR.

## 8. Calendário live-ops da S1 (conteúdo ≠ regras; nada muda as regras publicadas)

| Semana | Evento |
|---|---|
| D0 | Lançamento S1 + changelog público das regras congeladas + Starter Pack |
| D7 | Destaque da corrida de guilds (midpoint) — comunicação, sem mudança de regra |
| D14 | Missões semanais do "tema" (pool já definido no D0) |
| D21 | Aviso: "restam 7 dias" + lembrete de claim retroativo p/ quem ainda não comprou |
| D26–28 | **2× XP em TODAS as fontes de passe** (anunciado no D0; é conteúdo, não mudança de regra) |
| D28 | Encerramento: premiações de leaderboard + auto-claim de pendentes + anúncio da S2 |

## 9. KPIs do passe (metas S1)

| KPI | Meta |
|---|---|
| Attach (compradores/MAU) | ≥ 8% |
| Taxa de conclusão L30 entre compradores | ≥ 35% |
| Renovação S1→S2 entre compradores | ≥ 60% |
| Gem return ratio gasto pelo jogador | 65–70% do preço |
| Skips por comprador | 0,8–1,5 (se <0,5: curve leve demais; se >2,5: missões pesadas) |
| % de reclamações "não dá tempo" | < 3% (canal dedicado) |

**Tuning:** curva XP e pools de missão são data-driven — ajustes **entre temporadas** (nunca durante), com telemetria do beta fechado calibrando a S1 real.

## 10. Pendências/decisões para o dono do produto

1. Preço final (R$ 24,90 sugerido) e se lança a variante **Deluxe** já na S1.
2. Tema dos cosméticos S1 confirmar com arte (custo de sprites: ~5 assets novos; licença própria, fora do escopo CC BY-SA se arte 100% nova — ver nota de licença em ROADMAP F0).
3. Missões dependentes de features: `trade` (F4) e `re-forja` (F2) — se o scheduling da F4 apertar, S1 lança com o pool de substituição já previsto na §5.
4. Se rewarded ads entram antes da temporada (F4 ambas): a missão de anúncio (§5.8) entra ou sai do pool na S1.
