# Monetização — Catálogo, Brasil e Modelo Ideal

**Versão:** 1.0 (2026-09-09) · Relacionados: [ARCHITECTURE.md](ARCHITECTURE.md) · [ROADMAP.md](ROADMAP.md) · [ECONOMY_STUDY.md](ECONOMY_STUDY.md)
**Contexto:** F2P idle auto battler web (browser-first), Brasil como mercado inicial, gems fechadas (não-cashable), VIP já desenhado (2 tiers), baús com odds públicas, seasons, guilds, AH com taxa em gems.

---

## 1. Catálogo completo de opções aplicáveis

| # | Opção | Como aplicaria no SoM Idle | Potencial de receita | Risco P2W | Fit BR |
|---|---|---|---|---|---|
| 1 | **Battle Pass / Passe de temporada** | Trilha grátis + premium por temporada (4–8 sem): cosméticos, gems de volta, boosts, emotes. Premium ~R$ 24,90 | ⭐⭐⭐⭐⭐ (âncora) | Baixo | 🔥🔥🔥 |
| 2 | **VIP / assinatura mensal** | Já desenhado (cap offline, +gold/xp, slots) — R$ 19,90 / R$ 39,90 | ⭐⭐⭐⭐ | Baixo | 🔥🔥 |
| 3 | **Starter/Founder pack (one-time)** | Pacote único barato D0–D3: VIP 7d + gems + cosmético exclusivo — R$ 9,90 | ⭐⭐⭐⭐ (conversor) | Baixo | 🔥🔥🔥 |
| 4 | **Cosméticos diretos** | Skins de herói/armadura, paletas, emotes, títulos, molduras, tags de guild, efeitos de drop | ⭐⭐⭐ | Zero | 🔥🔥 |
| 5 | **Baús pagos / gacha leve** | Já desenhado: chaves em gems, odds públicas, provably-fair, pity timer | ⭐⭐⭐⭐ | Médio (mitigável) | 🔥🔥🔥 |
| 6 | **Time-savers / QoL** | Claim instantâneo offline, auto-venda de lixo, mais slots de AH, expansão de formação/banco (one-time) | ⭐⭐⭐ | Baixo | 🔥🔥 |
| 7 | **Rewarded ads (vídeo opcional)** | Assistir → 2× no claim do AFK, baú bônus diário, reroll da loja diária | ⭐⭐⭐ (volume) | Zero | 🔥🔥🔥 |
| 8 | **Taxas do AH/trade** | Já desenhado: taxa em gems queimada (3–5%) + destaque de anúncio | ⭐⭐ (indireto) | Zero | 🔥🔥 |
| 9 | **Offers/flash sales rotativas** | Loja diária com 3–6 SKUs rotativos, pacotes temporários, "oferta de nível" ao subir de zona | ⭐⭐⭐ | Baixo | 🔥🔥🔥 |
| 10 | **Guild monetization** | Cosméticos de guild, níveis acelerados, banners/tags — guild leader paga expansões | ⭐⭐ | Zero | 🔥🔥 |
| 11 | **Torneios com inscrição** | Entrada em **gold**, prêmios em gems/cosméticos — *não* entrada paga em dinheiro (risco de loteria/azar no BR) | ⭐ | Baixo | 🔥 |
| 12 | **Doação/apoio (Pix direto)** | Botão "apoiar o dev" com contrapartida cosmética mínima | ⭐ | Zero | 🔥🔥 |
| 13 | **Portais de web games (rev share de ads)** | Distribuição via CrazyGames/Poki/GameDistribution: eles vendem os ads e repassam % | ⭐⭐ (canal, não SKU) | Zero | 🔥🔥 |
| 14 | **Founder pack de lançamento / crowdfunding** | Pacote único de apoio na abertura do beta (título "Fundador") | ⭐⭐ (one-shot) | Zero | 🔥🔥 |
| — | Energy/stamina paga | — | — | — | ❌ **NÃO usar** (mata o loop idle) |
| — | Venda direta de poder (stats) | — | — | Alto | ❌ **NÃO usar** (corrompe leaderboard/ah) |
| — | Zonas atrás de paywall | — | — | Alto | ❌ **NÃO usar** (divide a comunidade) |
| — | P2E/token | — | — | — | ❌ Decidido (ver ECONOMY_STUDY) |

## 2. As 6 que faremos — detalhe

### 2.1 Passe de Temporada (âncora de receita)
- Alinha 1:1 com o sistema de seasons já arquitetado (SeasonService). Trilha grátis (míssil de gems pequenas) + premium (R$ 24,90–34,90/temporada, 30–40 níveis).
- **Devolve ~60–70% do preço em gems ao longo da trilha** — o padrão que faz o passe ser percebido como "investimento, não gasto" e gera renovação.
- Conteúdo do premium: cosméticos da temporada (exclusivos mas **retornam** após 2+ temporadas), boosts de rendimento, chaves de baú, título sazonal, slot extra no leaderboard de guild.
- Por que é a âncora: valor percebido alto × preço acessível × recorrência natural (a temporada renova a compra sem churn de assinatura).

### 2.2 VIP (camada de hábito)
Desenho completo em ECONOMY_STUDY §3. O gatilho de venda é o **cap de coleta offline**: é o único limite que o jogador F2P sente de verdade num idle. VIP1 (24h cap) e VIP2 (36h + claim reset) vendem "respeito ao seu tempo", não poder.

### 2.3 Starter Pack (conversor de porta)
- Aparece após o tutorial (D0) e expira em 72h: VIP 7d + 220 gems + cosmético exclusivo "Recruta" por **R$ 9,90**.
- Função real: quebrar a barreira da primeira compra (a 2ª compra é estatisticamente muito mais provável que a 1ª). One-time — nunca repetir, para não punir o convertido.

### 2.4 Cosméticos com identidade social
- Priorizar o que é **visível aos outros**: skins de formação (as formações são exibidas nas zonas e no perfil/guild), tags de guild, efeitos de drop raríssimo (o "rainbow effect" que os jogadores do AFK Heroes elogiaram espontaneamente nos reviews).
- Sazonais: alguns **nunca retornam** (status de veterano), a maioria retorna com cooldown — escassez com dignidade, calendário anunciado.

### 2.5 Rewarded ads (monetiza os 95% que não pagam)
- Momentos: claim do AFK ("assistir e dobrar"), baú bônus 1×/dia, reroll da loja diária. **Nunca interstitial/banner dentro do jogo** (quebra a estética pixel e a confiança).
- No BR o eCPM de rewarded é modesto, mas a adoção é altíssima; e cada visualização de "2× claim" é um ensaio do valor do VIP — converte watcher em payer.
- Implementação: SDK do portal (se distribuir via CrazyGames/Poki) ou ad network própria no site. VIP2 pode dobrar o bônus de anúncio (não remover — anúncios continuam sendo faucet do F2P).

### 2.6 Ofertas rotativas (a loja viva)
- Loja diária com rotação (reroll por gems), pacote "nível" quando o jogador bate gate de zona nova (oferece build-up relevante), ofertas de fim de temporada.
- É o multiplicador de ARPPU barato: mesmo catálogo, apresentação dinâmica.

## 3. O que funciona no Brasil — e por quê

| Fator | Realidade BR | Implicação de design |
|---|---|---|
| **Pix** | 1º método de pagamento do país, gratuito p/ consumidor, irreversível, sem chargeback | Checkout **Pix-first** (1 toque, QR/copia-cola); reduz fraude a ~zero p/ nós |
| **Sensibilidade a preço** | ARPPU baixo, volume alto; dólar encarece SKUs globais | **Preço local obrigatório**: R$ 4,99–34,90 como faixa principal; nunca exibir só US$ |
| **Cultura do passe** | Passe é o SKU dominante nos top grossing BR (mobile e PC) | Passe como âncora (§2.1) — padrão mental já treinado |
| **Parcelamento** | Cultura "parcelado sem juros" no cartão | Oferecer 2–3× em pacotes altos (≥ R$ 50) via processador com anti-chargeback (3DS) |
| **Chargeback/fraude de cartão** | Elevado no BR | Pix-first resolve; cartão sempre com 3DS |
| **Gacha/loot** | Mercado forte, mas sensível a odds injustas | Odds públicas + pity timer (já desenhado) é *vantagem competitiva* de confiança |
| **Assinatura** | Mais difícil que passe; funciona com hábito diário | VIP vendido no momento do cap offline atingido (dor real), não no cadastro |
| **eCPM de ads** | Abaixo de US/EU, adoção alta | Rewarded ads p/ volume, não p/ receita principal |
| **Idioma/auditória** | Jogo em PT-BR primeiro | i18n PT-BR é pré-requisito de conversão (ROADMAP F5) |

**Regulação/compliance BR (rápido):** CDC art. 49 (arrependimento 7 dias — política de reembolso de gems não gastas), divulgação de odds de baús pagos, CLASSIND para distribuição comercial, NF/recolhimento (ME no Simples), LGPD já coberto na F1. Detalhes jurídicos = F0 com advogado (análise de arquitetura, não parecer).

## 4. O modelo ideal — por que jogadores VÃO QUERER gastar

A regra de ouro do gênero: **o jogador gasta quando gastar respeita o tempo dele, expressa identidade e tem hora certa** — nunca quando o jogo fecha a porta.

### 4.1 Os 4 pilares do modelo

1. **Nunca vender poder; vender tempo e identidade.**
   - Tempo: VIP (cap offline, claim instantâneo) e time-savers. O jogador paga para o jogo se adaptar à *vida dele*, não para vencer.
   - Identidade: cosméticos sociais + status de temporada. No idle, a "vitrine" é a formação no perfil/guild/leaderboard.
2. **Sempre vender no momento de dopamina, nunca no de frustração.**
   - Momentos de venda permitidos: claim do AFK (pico de recompensa), kill de boss de zona, level up de guild, reset de temporada. Proibidos: ao morrer, ao faltar recurso no meio do combate, pop-up agressivo na 1ª sessão.
3. **Recorrência por design, não por assinatura forçada.**
   - Temporada (passe) > assinatura: renovação vem do conteúdo novo, não de auto-charge. VIP complementa para o hábito diário.
4. **Economia transparente.**
   - Odds públicas, gems com preço fixo e funcionalidade clara, sink visível (a taxa de trade que "some" é apresentada como "custo de segurança do mercado"). Confiança é o que sustenta LTV no BR (a crítica #1 do AFK Heroes foi itens que somem; a #1 elogiada foi transparência do dev).

### 4.2 A escada de conversão (jornada do pagante)

```
F2P ──(rewarded ad 2× claim)──► usuário engajado
  ──(starter pack R$ 9,90, D0–D3)──► 1ª compra
  ──(passe R$ 24,90 na 1ª temporada)──► pagante recorrente
  ──(VIP R$ 19,90 quando bate o cap offline)──► assinante
  ──(gems p/ chaves/guild/trades)──► baleia saudável (tudo em sink)
```
Cada degrau tem preço < R$ 35 e valor percebido > preço. A escada inteira é opcional: o F2P nunca fica travado.

### 4.3 Mix de receita alvo (maturidade, ~6 meses pós-launch)

| Fonte | % da receita |
|---|---|
| Passe de temporada | 35–40% |
| VIP | 20–25% |
| Gems (chaves, guild, QoL, cosméticos) | 25–30% |
| Starter/flash packs | 8–10% |
| Rewarded ads | 5–15% (depende de portal) |

**KPIs de monetização:** conversão paga ≥ 2% (mau: <1%, bom: ≥4%) · ARPPU ≥ R$ 25/mês · attach do passe ≥ 8% do MAU · VIP ≥ 2% do MAU · churn do passe < 40% entre temporadas · % da receita via Pix ≥ 50%.

### 4.4 Ordem de ativação (alinhada ao ROADMAP)
- **F2:** gems + starter pack + loja v1 (chaves/cosméticos) — receita mínima desde o beta.
- **F3:** VIP on (grant pelo companion) + primeira temporada de passe piloto (sem premium? não — passe entra com a 1ª temporada oficial).
- **F4:** rewarded ads (após estabilizar economia) + ofertas rotativas completas.
- **F5+:** passes sazonais recorrentes, torneios gold-entry, canal de portais.

---

*Doc vivo: revisar preços e mix com dados reais do beta fechado (F2) antes do launch.*
