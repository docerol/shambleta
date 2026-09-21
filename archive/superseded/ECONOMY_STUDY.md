# Estudo Econômico — VIP, Moeda Premium, Trades e Sinks

**Versão:** 1.0 (2026-09-09) · Relacionados: [ARCHITECTURE.md](ARCHITECTURE.md) · [ROADMAP.md](ROADMAP.md) · [BENCHMARK_AFK_HEROES.md](BENCHMARK_AFK_HEROES.md)

---

## 1. Resumo executivo do estudo

| Pergunta | Veredito |
|---|---|
| F2P + VIP é viável neste jogo? | **Sim** — modelo clássico de idle; VIP é QoL/boost, nunca stats diretos de combate |
| Trades P2P viáveis? | **Sim, com guardrails** — escrow server-side + identidade de item (`item_uid`) + taxas |
| Sink de moeda paga nos trades? | **Sim — e é o design correto**, com uma regra de ouro: **gems nunca transitam entre jogadores** (são queimadas como taxa). Gold é o meio de troca; gems são o sink |
| Riscos principais | RMT (dinheiro real fora do jogo), inflação de gold, percepção de pay-to-win, loot box regulatório |

---

## 2. Princípios econômicos (não negociáveis)

1. **Gems = sink currency, não meio de troca.** Gems são compradas, **nunca** transferíveis P2P, nunca cashable. Toda taxa em gems é **queimada** (removida de circulação). Isso: (a) evita que gems virem dinheiro eletrônico/RMT, (b) garante que cada gasto é receita líquida e deflação ativa.
2. **Gold = faucet de gameplay.** Gold é gerado por combate (faucet) e gasto em progressão (sinks de gameplay: guild levels, upgrades).
3. **Nada que afeta diretamente o DPS do combate é vendido por gems.** Loja vende: conveniência, cosméticos, chaves de baú, entradas extras. Gear forte vem de **jogar** e do trade — não da loja. (Proteção contra percepção pay-to-win e contra implosão do AH.)
4. **Todo flow entra no ledger.** Reconciliação diária: soma do ledger == saldos == inventários. Zero tolerância para divergência (lição dos "itens que somem" do AFK Heroes).
5. **Odds de baú públicas e verificáveis** antes de abrir (provably-fair server/client seed) — confiança + compliance de loot box pago.

---

## 3. Design do VIP

**Posicionamento:** assinatura mensal (30d) em **2 tiers**, benefícios de **conveniência e aceleração**, nunca power direto. Compra com dinheiro real via companion (web: Stripe/Pix; mobile futura: IAP).

| Benefício | F2P | VIP 1 (~US$ 4,99/mês) | VIP 2 (~US$ 9,99/mês) |
|---|---|---|---|
| Cap de coleta offline | 12 h | 24 h | 36 h |
| Bônus de gold/xp do settle | — | +10% | +25% |
| Slots de formação | 3 | 4 | 5 |
| Auto-venda de lixo (junk filter) | — | ✔ | ✔ + filtro custom |
| Baú diário grátis | — | ✔ (comum) | ✔ (raro) |
| Slots de listagem no AH | 5 | 15 | 40 |
| Taxa de trade reduzida | 5% em gems | 4% | 3% |
| Entrada prioritária em zona cheia | — | ✔ | ✔ |
| Tag VIP no perfil + emote exclusivo | — | ✔ | ✔ (distinto) |
| Reset de coleta offline (1×/dia) | — | — | ✔ |

**Decisões de design:**
- **Não vender power** (atk/def/hp). Boosts de *rendimento* (+% gold/xp) são o padrão aceito do gênero e não corrompem a métrica de skill (build) nem o AH.
- VIP renovação empilhável (comprar 3× VIP1 = 90 dias), cancelável, sem auto-charge sem aviso (consumer law BR/UE).
- VIP **não** dá acesso a zonas exclusivas (evita dividir a comunidade); dá aceleração dentro do mesmo conteúdo.
- Reference points do gênero: AFK Arena (V0–V13 por gasto), AFK Heroes (gasto pontua corrida "Most Spenders"). Nossa "Most Spenders" pontua gasto de gems — VIP indiretamente pontua, cosmético também.

## 4. Catálogo de gems (preços e âncoras)

Pacotes (web, Stripe/Pix — mobile exigirá IAP nativo, ARCHITECTURE §11):
- 100 gems — R$ 4,99 · 550 (+10%) — R$ 24,90 · 1.200 (+25%) — R$ 49,90 · 3.000 (+40%) — R$ 99,90
- **First purchase 2×** (âncora de conversão clássica) e assinatura VIP separada.

**Pagamento em cripto (viável, sem interferir no design):** aceitar cripto como *meio de pagamento* não altera o modelo de gems fechadas — gems continuam não-cashable/não-transferíveis, e nada é "ganhado" em cripto (não-P2E). Regras: (1) usar processador licenciado que converte para fiat — as Resoluções BCB 519/520/521 (nov/2025) criaram o regime de autorização das PSAVs, e o licenciamento fica com o processador, não com o jogo; (2) precificar gems em BRL, invoice cripto com taxa travada e expiração curta; (3) proibido em builds de lojas de apps (IAP obrigatório para bens digitais no iOS/Android); (4) nunca oferecer o caminho inverso (gems→cripto) — é isso que recriaria o problema P2E.

Custos de referência (tuning pós-beta; escalas relativas):
- Chave de baú comum: 20 gems · rara: 60 · épica: 150
- Slot de formação permanente (1× por conta): 500
- Renome de guild: 300 · Upgrade de vault: 100–500 por nível
- Cosméticos: 50–300 · Entrada extra de boss de guild: 100

## 5. Sinks e faucets — mapa completo

| Fonte (faucet) | Valor | Sink | Valor |
|---|---|---|---|
| Combate online (gold) | taxa por zona/tier | Guild levels | gold+gems+points (grande, progressivo) |
| Settle offline (gold/xp) | fórmula capada | Chaves de baú | gems |
| Baús com recompensa (gold) | pequeno, raro | Taxa de trade/AH | **gems queimadas** |
| Venda no AH (gold) | player-to-player | Re-forja/re-roll de equipamento | gold alto + gems opcional |
| Missões diárias (gold/gems pequenos) | tabelado | Cosméticos / renomes / slots | gems |
| Eventos sazonais | variável | Entrada de boss / instâncias especiais | gold |
| — | — | Death tax em zonas altas | gold (% do gold/hr) |

**Regra de saúde (KPI):** razão sink/faucet de gems entre **0,8 e 1,2** semanal (sobrevivência da moeda); gold levemente inflacionário por design (drive de demanda por sinks de guild/upgrades).

## 6. Estudo de viabilidade — Trades P2P com sink de moeda paga

### 6.1 Modelo proposto
- **Trade direto:** escrow no server (`TradeService`): ambas as partes confirmam em janela de 60 s; troca atômica em `BEGIN/COMMIT`.
- **Auction House:** listagem por gold baixo (acessível ao F2P), **taxa de venda em gems (3–5%, queimada)**, destaque de anúncio pago em gems.
- **Por que a taxa em gems funciona:** cada trade útil queima receita proporcional à atividade econômica — sinks que crescem com a economia (self-balancing), padrão usado por MMORPGs maduros (AH cut) e idêntico em espírito ao marketplace do AFK Heroes (volume $48K/45d prova apetite por trade no gênero).

### 6.2 Por que viável no nosso stack (e o que precisamos construir)
| Requisito | Status hoje | Trabalho |
|---|---|---|
| Itens com identidade única (antiduplicação, histórico) | ❌ `item` é linha agregada (item_hash+count) | Migration 017: `item_uid` + tabela de instância; todo grant/passagem de item passa pelo ledger |
| Transação atômica multi-entidade | ❌ queries sob mutex | `BEGIN/COMMIT` no `EconomyService` (F1) |
| Escrow com rollback | ❌ | `TradeService` (F4) |
| Antifraude básico | ❌ | tier de conta p/ trade (e-mail verificado), cooldowns, caps diários |
| Log/CS | ❌ | `trade_log` append-only + painel de suporte (F5) |

### 6.3 Riscos e mitigação (matriz RMT)
| Risco | Prob. | Mitigação |
|---|---|---|
| RMT: venda de gold/itens por dinheiro real fora do jogo | Alta em todo jogo F2P com trade | Taxas em gems elevam custo de abuso; trade history por item (item_uid) rastreia cadeia; anomalias (grafo de trades) → revisão manual; caps por conta; ban por conta/IP já existe |
| Multi-conta farmando para vender | Alta | 1 conta por e-mail verificado + velocity; farms de gold têm death tax; sem cash-out interno não há alvo direto, mas gold vendido por RMT externo persiste → monitorar AH outliers |
| Chargeback como arma de RMT | Baixa | Gems compradas que viraram trade fee não são reembolsáveis (ToS); suspensão por chargeback |
| Loot box pago regulatório (BR/EU/lojas) | Média | Odds públicas + provably-fair + histórico pessoal de aberturas; sem cash-out (não é jogo de azar) |
| Inflação de gold quebra o AH | Média | Sinks de gold fortes (guild levels, re-forja); monitorar preço mediano por tier |

### 6.4 Veredito
**Viável e recomendado, com a Fase 4 (após guild e loja provarem o ledger).** Sequência de mitigação: primeiro AH somente-itens-bound→não, AH de consumíveis/equips não-bound com fees; trade direto por último (maior superfície de abuso). Se os KPIs de RMT ficarem vermelhos no beta, restringir trade a tier VIP2+ (curva de segurança, não de power).

## 7. Baús (chest) — desenho rápido

- Dropam no combate (online e settle), abertos com chaves compradas em **gems** (o principal sink F2P→pago).
- Provably-fair: `server_seed_hash` publicado antes, `client_seed` do jogador, nonce incremental — resultado verificável pós-abertura (padrão do AFK Heroes, eleva confiança).
- Pity timer (garantia de raro a cada N aberturas) — expectativa do gênero.
- Tabela de odds versionada por temporada; UI mostra % por raridade **antes** de abrir.

## 8. Métricas de economia (painel mínimo)
- Gems: mint (compras), burn (fees/chaves), estoque circulante, por dia.
- Gold: faucet (settle/combate) vs. sink (guild/upgrades) — alvo sink/faucet 0,7–0,9 semanal.
- Trade: nº de trades, gems queimadas em fees, mediana de preço por tier, % de contas que negociam.
- VIP: MRR, churn, conversão F2P→VIP1→VIP2.
- Retenção segmentada por VIP/não-VIP e por trade/no-trade.
