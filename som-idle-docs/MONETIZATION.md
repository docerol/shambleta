# Monetização — Catálogo, Brasil e Modelo Ideal

**Versão:** 1.1 (2026-09-16) · Relacionados: [ARCHITECTURE.md](ARCHITECTURE.md) · [ROADMAP.md](ROADMAP.md) · [ECONOMY_STUDY.md](ECONOMY_STUDY.md) · [XP_PROGRESSION.md §4.2](XP_PROGRESSION.md) · [REBIRTH_BC_REPORT.md](REBIRTH_BC_REPORT.md)
**Contexto:** F2P idle auto battler web (browser-first), Brasil como mercado inicial, gems fechadas (não-cashable), VIP já desenhado (2 tiers), baús com odds públicas, seasons, guilds, AH com taxa em gems.

**Changelog v1.1:** revisão pós-rebirth/essência e pós-i18n completo (100% UI + conteúdo pt-BR).
Adiciona §0 (guardrails anti-P2W, com a essência/rebirth como caso concreto testado contra o
catálogo), expande §2.5 (rewarded ads — implementação, não só conceito) e §2.7 (nova: vitrine
de renascimento como monetização cosmética do sistema de prestígio). i18n sai da lista de
pré-requisitos pendentes (§3) — já está em 100%.

---

## 0. Guardrails anti-P2W — o que nunca vendemos

Regra de decisão, para qualquer SKU novo daqui pra frente, inclusive os que ainda não existem
neste documento: **se o efeito pode ser obtido apenas jogando, dá pra vender o atalho (tempo);
se o efeito não é alcançável sem pagar, não vendemos (poder).** Todo item do catálogo em §1 foi
testado contra essa regra antes de entrar na lista dos "6 que faremos" em §2.

### 0.1 Teste aplicado ao sistema de renascimento (o caso mais arriscado do jogo hoje)

O sistema de renascimento (`RebirthData.gd`, `XP_PROGRESSION.md §4.2`) é o ponto do jogo com
maior risco estrutural de virar P2W, porque os favores (`favor_xp`, `favor_gold`) são
multiplicadores reais de XP/ouro (`×1.05^n`, compostos) — ou seja, **é poder de verdade**, não
cosmético. O que impede isso de ser pay-to-win hoje, por construção:

- **Essência só nasce de excedente de XP** (farm no cap, online ou offline) — não existe, em
  nenhum ponto do código revisado, um caminho de `gems → essência`. É tempo convertido em
  progressão, não dinheiro convertido em progressão.
- **`attune_offline` tem teto (10 níveis, 0,60→0,80)** — mesmo o jogador que farma essência sem
  parar não ultrapassa 80% de eficiência offline. Isso é deliberadamente um **piso honesto de
  AFK**, não um teto de poder competitivo — não é algo que separa pagante de não-pagante, porque
  ninguém compra isso com dinheiro.
- **Todo player, dado tempo suficiente, chega ao mesmo lugar.** Isso é exatamente a definição de
  "não é P2W": diferença de investimento de **tempo**, não de **dinheiro**.

**Regra travada a partir desta versão do documento:** essência, favores de renascimento e
qualquer parâmetro futuro do sistema de prestígio **nunca** entram em SKU de gems, VIP, passe ou
qualquer oferta paga — nem como bônus percentual, nem como "acelerador". Se um dia alguém propuser
"VIP dá +X% de essência" ou "compre um booster de essência", isso é uma regressão desta regra e
deve ser barrado aqui, não silenciosamente aprovado numa reunião de roadmap.

### 0.2 A pendência de dono do rebirth não é uma porta para monetização

`REBIRTH_BC_REPORT.md` registra que o **ato** de renascer ainda não paga nada — decisão em aberto
entre (a) custo de essência proporcional ao ciclo, ou (b) travar upgrades a `rebirths ≥ n`. Do
ponto de vista deste documento, isso é irrelevante para monetização **desde que o custo continue
sendo pago em essência** (tempo), nunca em gems. Recomendação, sem substituir a decisão do dono:
opção (a), porque mantém o ciclo simétrico entre F2P e pagante — o único jeito de essa decisão
virar risco de P2W seria alguém propor pagar esse custo em gems "pra pular a fila", o que a regra
de §0.1 já proíbe.

### 0.3 Padrão geral (aplicar a qualquer sistema futuro)

| Categoria | Pode vender? | Exemplo já no jogo |
|---|---|---|
| Tempo (atalho para algo que o F2P alcança jogando) | ✅ Sim | VIP (cap offline), claim instantâneo |
| Identidade/status visível | ✅ Sim | Cosméticos, títulos, molduras, tags |
| Conveniência que não afeta ranking/economia | ✅ Sim | Slots de AH, auto-venda de lixo |
| Multiplicador de progressão permanente (XP/ouro/drop) | ❌ Nunca | — (é exatamente o que `favor_xp`/`favor_gold` são, por isso ficam fora de qualquer SKU) |
| Acesso a conteúdo/zona | ❌ Nunca | Todas as 24 zonas já são F2P |
| Vantagem em PvP/leaderboard competitivo | ❌ Nunca | Seasons/leaderboard premiam com cosméticos, não com poder de entrada |

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
| — | Essência / favores de renascimento por gems | — | — | Alto | ❌ **NÃO usar** (ver §0.1 — é o único multiplicador de progressão real do jogo; vender isso é P2W por definição) |

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

### 2.5 Rewarded ads — o motor de receita do F2P (detalhado)

Esta é a peça que faz o jogador que **nunca vai pagar** (a maioria — ver §4.3, 5–15% da receita
mas cobrindo perto de 100% da base) ainda gerar receita e ainda sentir que o jogo é generoso com
quem não paga. Regra de ouro: **anúncio é sempre um botão que o jogador aperta, nunca uma
interrupção que o jogo empurra.**

**Placements (pontos exatos, todos opt-in, todos com prévia clara do que ganha antes de assistir):**

| Placement | Gatilho | Recompensa | Cooldown/cap |
|---|---|---|---|
| 2× no claim do AFK Report | Botão ao lado do claim normal, ao voltar de offline | Dobra XP/ouro/drops daquela liquidação específica | 1×/liquidação (não acumula com claims seguidos) |
| Baú bônus diário | Botão na tela de baús, 1×/dia | +1 baú do tier da zona atual, sem custo de gems | 1×/dia (reseta 00h local) |
| Reroll da loja diária | Botão na loja, quando o jogador não gostou do rotativo do dia | Novo sorteio dos SKUs do dia | 3×/dia (evita farm de reroll infinito) |
| Chave de boss extra | Ao ficar sem chave e querer tentar de novo | +1 tentativa de duelo de boss | 2×/dia |

**O que nunca entra como placement:** interstitial ao trocar de tela, banner fixo na UI do jogo,
anúncio obrigatório para continuar jogando, anúncio em loop forçado. Um jogo com estética pixel
art perde a confiança do jogador rapidíssimo com esse tipo de intrusão — e confiança é o ativo
que este documento mais protege (§4.1, pilar 4).

**Rede/SDK:** duas rotas, não mutuamente exclusivas —
1. **Distribuição via portal** (CrazyGames/Poki/GameDistribution): o portal já entrega o SDK de
   rewarded e faz o rev-share; menor esforço de integração, mas menor controle de preço.
2. **Ad network própria no site** (AdSense for Games, ou um mediador tipo AppLovin/Unity Ads
   version web): mais trabalho de integração, mas 100% da receita de ads fica com o produto —
   vale a pena assim que o volume justificar a engenharia (não é bloqueante para o F2 do roadmap).

**Frequência global (anti-fadiga):** cap agregado de ads/dia por jogador (sugestão: 6–8, somando
todos os placements) — o objetivo é volume sustentável de longo prazo, não maximizar impressões
de curto prazo às custas de churn.

**Interação com VIP:** VIP **dobra o bônus do anúncio quando assistido** (ex.: 2× vira 4× no
claim), mas **nunca remove a opção de assistir** — o anúncio continua sendo a via de faucet do
F2P mesmo para quem tem VIP. Isso também funciona como funil: cada "assistir e dobrar" é uma
prova de valor do que o VIP faria de graça, sem esperar — o mesmo padrão de conversão de watcher
para payer já descrito na versão anterior deste documento.

**Por que isso não é P2W:** nenhum placement acima libera essência, favor de renascimento, ou
qualquer efeito coberto pela regra de §0.1 — só bônus pontual de XP/ouro/drop **na sessão**, o
mesmo tipo de bônus que qualquer jogador engajado já tira jogando mais. Rewarded ads são tempo
assistindo em troca de tempo de farm economizado — o mesmo eixo tempo-por-tempo do resto do
catálogo, não um atalho de dinheiro.

### 2.6 Ofertas rotativas (a loja viva)
- Loja diária com rotação (reroll por gems), pacote "nível" quando o jogador bate gate de zona nova (oferece build-up relevante), ofertas de fim de temporada.
- É o multiplicador de ARPPU barato: mesmo catálogo, apresentação dinâmica.

### 2.7 Vitrine de renascimento (novo — monetização cosmética do sistema de prestígio)

O sistema de rebirth (§0.1) criou, de graça, o melhor gancho de identidade social que o jogo tem:
o contador de `rebirths` é público na conta e não existe hoje nenhuma forma de exibi-lo com
orgulho. `REBIRTH_BC_REPORT.md` já lista isso como pendência #3 ("compensação visível... domínio
da fase de cosméticos/passe") — esta seção é essa fase.

- **O que vendemos:** título de ciclo ("Renascido III"), moldura de avatar por marco de
  `rebirths` (1º, 5º, 10º renascimento), efeito visual de partícula ao renascer (cosmético,
  visível a outros jogadores na zona por alguns segundos). Nada disso altera `favor_xp`,
  `favor_gold` ou `attune_offline` — é decoração do número que o jogador já ganhou jogando.
- **O que continua de graça:** o contador em si e um título/moldura básica no 1º renascimento
  (celebra o marco sem custo — a versão paga é sobre *estilo*, não sobre *existir*).
- **Por que funciona:** quem chega ao rebirth já é, por definição, o jogador mais engajado do
  jogo (17–21 dias de farm ativo por ciclo, `XP_PROGRESSION.md §4.2`) — é exatamente o perfil de
  alto LTV que mais valoriza status visível sobre poder. Vender aqui não compete com o F2P: quem
  ainda não chegou ao cap nem vê essa vitrine.
- **Encaixe no catálogo:** entra como conteúdo do Passe de Temporada (§2.1, cosméticos sazonais)
  quando o marco cai dentro de uma temporada, ou como SKU avulso de gems para quem quer a moldura
  fora do ciclo do passe — de qualquer forma, sempre gems/passe, nunca essência (essência continua
  fora do alcance de qualquer compra, por §0.1).

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
| **Idioma/auditória** | Jogo em PT-BR primeiro | ✅ Resolvido — i18n 100% (UI + 727 linhas de conteúdo NPC/quest, `I18N_PHASE1_REPORT.md`/`I18N_PHASE2_REPORT.md`); pré-requisito de conversão já não bloqueia mais o beta |

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
