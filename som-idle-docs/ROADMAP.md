# Roadmap — Shambleta: Idle Auto Battler

**Versão:** 1.1 (2026-09-09) · Relacionados: [ARCHITECTURE.md](ARCHITECTURE.md) · [ECONOMY_STUDY.md](ECONOMY_STUDY.md)
**Estimativa base:** 1–2 engenheiros (GDScript familiarizados + 1 backend), em semanas de trabalho efetivo. Estimativas ±30%.

> **🔄 Atualização de prioridade (decisão do dono do produto, 09/09/2026): monetização sai do caminho crítico.** A ordem agora é **jogo funcionando primeiro**: a F2 entrega o core idle jogável com a XP granular ([XP_PROGRESSION.md](XP_PROGRESSION.md)) e **nada é vendido** (loja/baús/VIP ficam implementados mas desligados até decisão posterior). A infraestrutura de economia (ledger, wallet, migrations da F1) permanece no plano — é barata e evita retrabalho — mas checkout/pagamento real só entra quando o produto estiver no ar.

---

## 0. Gaps consolidados → fase de resolução

Gaps herdados do [RELATORIO_AUDITORIA_sourceofmana.md](RELATORIO_AUDITORIA_sourceofmana.md) + novos do pivô idle. Ordem de resolução é a ordem das fases.

| Gap | Severidade | Resolvido em |
|---|---|---|
| Sem marca/decisão de uso da marca "Mana" (upstream Manasource) | 🔴 Bloqueante | **F0** |
| Sem modelo de negócio definido (F2P+VIP definido; falta desenho de tiers) | 🔴 | **F0** (docs prontos em ECONOMY_STUDY) |
| Sem gateway de pagamento / serviço companion | 🔴 | **F1/F2** |
| Sem ToS/Política de Privacidade/LGPD (e-mail, IP, Sentry) | 🔴 | **F0/F1** |
| Sem rota de exclusão de dados / e-mail não verificado/único | 🔴 | **F1** |
| Senhas SHA-256 + PRNG (sem KDF), sem lockout | 🔴 | **F1** |
| Sem item único (não há `item_uid` — inviabiliza trade/antiduplicação) | 🔴 | **F1** (migration 017) |
| Sem transações ACID nas operações econômicas | 🔴 | **F1** |
| Sem moeda premium/ledger | 🔴 | **F2** |
| Sem offline progress / CombatPolicy | 🔴 | **F2** |
| Sem guild | 🟡 | **F3** |
| Sem trade/AH | 🟡 | **F4** |
| Sem seasons/leaderboards | 🟡 | **F4** |
| TLS opcional / sem cert provisioning / sem TURN (STUN-only) | 🟡 | **F1** (WSS obrigatório; TURN só se P2P) |
| CI sem build Web (preset existe) / sem COOP-COEP no host | 🟡 | **F1** |
| SQLite contention (server+companion) | 🟡 | **F1** (grant_queue) → **F5** (Postgres) |
| Sem telemetria de produto / dashboards | 🟡 | **F2** (eventos) → **F4** (dashboards) |
| Sem testes automatizados | 🟡 | transversal — **cada fase entrega testes** |
| Sem i18n (PT-BR prioritário) | 🟢 | **F5** |
| Sem antifraude/velocity | 🟡 | **F2** (básico) → **F5** (completo) |
| Baús/odds sem exibição pública (risco regulatório loot box) | 🟡 | **F3** (odds públicas + client seed desde o dia 1) |
| Sem patcher/atualização incremental web | 🟢 | **F5** |
| Backups locais (sem offsite/restore testado) | 🟡 | **F1** |

---

## 1. Fases (ordem recomendada)

### Fase 0 — Decisões e Jurídico · **2–3 semanas** · paralelizável
**Objetivo:** poder começar a codar sem risco jurídico.
- [ ] Decisão de marca: acordo com Manasource **ou** rebranding (nome, logo, domínio próprios). *Recomendação: rebranding* (fork comercial de projeto de voluntários, sem risco de revés).
- [ ] Entidade legal + Pix/Stripe onboarding; política de reembolso; ToS; Política de Privacidade; termo de consentimento no cadastro (LGPD: e-mail, IP, Sentry).
- [ ] Congelar escopo do MVP idle (este roadmap) e o design doc do VIP (ECONOMY_STUDY §3).
- [ ] Decisão: **não usar cripto/token** (moeda fechada, não-cashable) — registrado como princípio de produto.
**Critério de saída:** docs assinados, domínio/gateway aprovados, identidade visual inicial.

### Fase 1 — Fundação · **4–6 semanas**
**Objetivo:** plataforma segura e testável, sem features novas.
1. Migrations 009–013 (ledger, wallet, formation, guild, trade — schema desde já; features vêm depois) + migration 017 `item_uid` (UUID por instância de item; antiduplicação).
2. `EconomyService` + ACID (`BEGIN/COMMIT`) em toda mutação de item/moeda + **triggers append-only**.
3. Hardening auth: KDF (PBKDF2-HMAC iterado ou hash externo), salt CSPRNG (`Crypto`), e-mail verificado+único, lockout exponencial, rota de deleção de dados (LGPD art. 18).
4. Companion v0: REST `/health`, `/webhooks/payments` (idempotente) → `grant_queue`; Postgres; deploy containerizado; TLS no game server (WSS obrigatório).
5. CI: job **Web export** com COOP/COEP, testes headless (migrations, ledger invariants, settle idempotência), backups offsite.
**Critério de saída:** webhook end-to-end em sandbox credita gems no client real; leak-test de senha (hash não reversível); restore de backup executado com sucesso.

### Fase 2 — Core Idle Loop (MVP jogável fechado) · **6–8 semanas**
**Objetivo:** loop de farm completo offline+online, monetização mínima.
1. `IdlePolicy` (online sim, instâncias de farm) + `session_efficiency`.
2. `OfflineSettle` + AFK Report (fórmula §8, caps, idempotência).
3. **Sistema de XP granular** ([XP_PROGRESSION.md](XP_PROGRESSION.md)): curva exponencial por fórmula, XP por zona com newbie boost ×5, formatter K/M/B/T, reset de progressão (migration 018). **Cap recalibrado para L60 com motor de renascimento** (decisão de dono em [REBALANCE_XP_OPTIONS.md](REBALANCE_XP_OPTIONS.md), contrato em `XP_PROGRESSION.md §4.2`, migração 021) — a parede pós-L60 virou essência + loja permanente em vez de treadmill.
4. Formação (1 personagem MVP → 5 slots), Zone Map com gates, Power Score.
5. Loja v1: **gems** (grant via companion), SKUs: chaves de baú, cosméticos, QoL. Baús com **odds públicas + provably-fair (server/client seed)**. *(Mecânica de baús/keys entra no jogo; a venda de gems por dinheiro real é ativada depois — prioridade atual: jogo funcionando.)*
6. VIP v1 (ECONOMY §3): grant via companion; benefícios aplicados no settle/simulação. *(Estado/efeitos implementados; venda por dinheiro real ativada depois.)*
7. Telemetria: eventos para Postgres; dashboard mínimo (retention, gems mint/burn).
**Critério de saída (soft gate de beta):** jogador completo loop conta→farm online→sair→voltar→coletar offline→comprar com gems→abrir baú→evoluir equip. 0 itens duplicados em testes de caos (crash kill -9 durante settle/trade em staging).

### Fase 3 — Guilds · **3–4 semanas**
1. Guild CRUD + níveis 1–10 (custo gold+gems+points = **sink principal**) + buffs % no settle/sim.
2. Guild vault com permissões (ledger próprio).
3. Guild leaderboard semanal (premiação em gems/cosméticos).
**Critério de saída:** guild criada, nível up pago, buffs visíveis no relatório, leaderboard correto.

### Fase 4 — Trades/AH + Seasons · **5–6 semanas**
1. Trade escrow P2P com **taxa em gems queimada**; AH com listagem (gold) + destaque (gems). RMT guards: tier de conta, cooldowns, caps por dia.
2. Seasons: jobs de snapshot, 4 corridas (Power, Boss Kills, Spend, Guild Points), premiação não-cashable, **regras congeladas + changelog público**.
3. Antifraude v1: heurísticas de anomalia (kill-rate, grafo de trades) com revisão manual.
**Critério de saída:** trade atômico sob carga (teste de corrida), taxa queimada visível no ledger, temporada completa simulada em staging.

### Fase 5 — Beta aberto & Live-ops · **4 semanas + contínuo**
1. Beta aberto (jogadores reais), i18n PT-BR/EN, patcher/notas de versão.
2. Balance de zonas (telemetria → ajustes de `gold_per_hour`/drops), painel de CS (procurar transação/item, restaurar por ledger).
3. Performance web (primeiro load <25 MB gzip, TTI <8s em 4G), suporte mobile-web.
4. Antifraude v2, Postgres no companion se CCU exigir.
**Critério de saída (LAUNCH):** ToS/LGPD auditados, D7 ≥ 20% no beta, faucet/sink de gems estável (±15% semana), 0 incidentes P1 de duplicação, custo infra < meta.

### Pós-lançamento (backlog priorizado)
Expansões de heróis/classes · Co-op: boss de guild semanal · Prestige/rebirth · Mini-games (feedback AFK Heroes) · Eventos temáticos · Torneios PvP assíncronos (defesa de formação) · App mobile nativo (IAP) · Integração Discord Activity.

### Follow-ups de monetização — bloqueados fora da esteira (não executáveis aqui)
Itens que a implementação (Fases A–F + follow-ups G1–G3) deixou preparados mas
que exigem decisão do dono, terceiros ou arte. Cada um lista o pré-requisito
e o que já está pronto no código.

| Item | Bloqueado por | Pronto no código |
|---|---|---|
| Sprites/partículas dos cosméticos (skins, molduras, Faísca de Mana, partícula do renascimento) | Artista pixel-art (fora do escopo de engenharia) | Catálogo, posse, equip, vitrine, títulos/skin visíveis em texto (`EconomyService.COSMETIC_CATALOG`, janela Coleção) |
| SDK real de rewarded ads (CrazyGames/Poki ou AdSense for Games) | Conta no portal/rede + decisão de canal | `AdProvider` (troca de 1 função), 4 placements, caps, validação fail-closed (`sources/ads/AdProvider.gd`) |
| Portais web (distribuição + rev-share) | Decisão de negócio + contas nos portais | Nada pendente de código além do SDK acima |
| `Claim reset` do VIP2 (MONETIZATION §2.2 cita, sem definir) | Decisão de design do dono (o que "reseta"?) | Cap 36h + resto do VIP implementados |
| Conta MP PJ + `SHAMBLETA_MP_REFUNDS=1` p/ estornos | Onboarding de gateway (handoff §2) | `refund-sweep --dry-run` + chamada de refund fail-closed (`companion/server.py`) |
| Preço Deluxe R$ 44,90 | Confirmação do dono (sugerido em BATTLE_PASS_S1 §4) | Mecânica completa atrás do SKU `pass.s1.deluxe` |

---

## 2. Linha do tempo visual

```
Mês 1      Mês 2      Mês 3      Mês 4      Mês 5      Mês 6      Mês 7
|--F0--|
|-----F1: Fundação------|
           |-------F2: Core Idle (MVP fechado)-------|
                                |--F3: Guild--|
                                       |----F4: Trade+Season----|
                                                    |--F5: Beta--LAUNCH
```
**MVP jogável fechado: fim do mês 3. · Lançamento comercial: mês 6–7.**

## 3. Riscos do roadmap

| Risco | Mitigação |
|---|---|
| F2 estourar (CombatPolicy é o maior risco técnico) | Protótipo de spike na semana 1 da F2: 1 zona, 1 char, sim+settle end-to-end antes de expandir |
| Dependência de backend não-alocado | Companion é Go/Node simples; escopo mínimo (webhook+grants) pode ser entregue por 1 dev em 2 semanas |
| Balance viciado descoberto tardiamente | Harness de simulação headless na F2 (milhares de settles sintéticos/dia) + beta fechado na F2 (não F5) |
| Jurídico (marca) atrasar tudo | F0 paralela a F1; rebranding é caminho curto e controlável |
| Scope creep do gênero (mini-games, PvP, co-op) | Tudo em backlog pós-launch; congelado por critério de saída por fase |

## 4. Métricas de sucesso (30/90 pós-launch)

- **Jogo:** D1 ≥ 35%, D7 ≥ 20%, D30 ≥ 8%; sessões/dia ≥ 2; tempo até primeira coleta offline < 30 min.
- **Economia:** razão sink/faucet de gems 0.8–1.2 semanal; ≥ 60% das gems gastas em chaves de baú/guild (não cosmético puro).
- **Receita:** conversão paga ≥ 2% (idle típico 1–5%); ARPPU ≥ US$ 8/mês; VIP ≥ 60% da receita.
- **Operação:** uptime ≥ 99.5%; ledger vs. saldos divergência = 0 (job diário de reconciliação).
