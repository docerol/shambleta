# SHAMBLETA — AUDITORIA INDEPENDENTE COMPLETA (2026-10-06)

**Estado auditado:** working tree de 2026-10-06 (commit base `eb9514e` + 38 arquivos
sujos, incluindo `data/conf/migrations/068_check_constraints.sql` **não rastreado**).
Auditoria anterior de 2026-10-04 tratada como fonte de hipóteses, não como verdade —
cada alegoria foi re-testada contra o código, por teste real, ou refutada.

**Método:** 6 frentes paralelas (economia, produto, arquitetura, testes/DevOps/analytics,
monetização, segurança) + pesquisa de comunidade com 18 fontes + verificação direta dos
P0 pelo auditor-chefe (engine, harnesses e gates executados nesta árvore).
Regra fundamental cumprida: nenhuma possibilidade virou bug confirmado. Classificações
usadas em todo o documento: `CONFIRMADO NO CÓDIGO`, `CONFIRMADO POR TESTE`,
`CONFIRMADO POR DADOS`, `EVIDÊNCIA DA COMUNIDADE`, `INFERÊNCIA`, `HIPÓTESE` (nota não
reduzida por hipótese).

---

## 1. Sumário executivo

O Shambleta é um idle RPG server-authoritative com engenharia de fronteira de dinheiro
acima da média (webhook HMAC + re-fetch + fila idempotente, ledger append-only por
trigger, IDOR varrido e limpo, SQL parametrizado por allowlist) e um sistema de gates
de qualidade real (74 harnesses Godot, suítes Python, 11 gates de estrutura com
controles plantados). **Mas a árvore atual não liga.** Dois defeitos mecânicos, ambos
no working tree não commitado, bloqueiam boot e CI hoje:

1. **`LoginWithTwoFactor` (`Server.gd:@LoginWithTwoFactor`) — parse error** (`CONFIRMADO POR TESTE`: o próprio engine
   acusa "Unindent doesn't match the previous indentation level" e recusa carregar o
   script; a cascata "Could not parse global class NetServer" derrubou todo harness
   dependente na run real). O fix de segurança C-01 (binding 2FA→conta) foi escrito
   com 3 linhas em ESPAÇO dentro de corpo em TAB, e anulou a si mesmo: com o arquivo
   quebrado, não há servidor, não há login, não há beta.
2. **Migration 068 quebra o boot do banco** (`CONFIRMADO POR TESTE`:
   `migration_atomicity_test` G3b/G4 vermelhos na árvore — `MigrationBlocked() = true`,
   versão carimbada 67 ≠ contagem de patches visíveis; causa estática `CONFIRMADO NO CÓDIGO`:
   três `INSERT ... SELECT *` com contagem de colunas errada contra o schema vivo —
   wallet 3×4, auction_listing 9×12, item_instance 10×11, por causa dos ALTERs das
   migrations 049/025/028/063/027). E o arquivo está **fora do índice git**
   (`CONFIRMADO POR TESTE`: `check_untracked.sh` → 2 FAIL → cadeia `code-health`/CI
   vermelha).

Abaixo da mecânica, o risco é **comercial** e se confirmou em três frentes:

- **A economia queima quase zero gold.** O AH — "sink primário" alegado no roadmap —
  destrói ~0% do volume (a queima de 1% só dispara quando o item foi criado por
  terceiros e revendido com aprovação de GM, ≈0% das listagens reais). Pior: o
  torneio converte 1.000 gold em 2.000–4.000 gems (ponte gold→premium que fura o
  preço da gem), e no pior caso medido o faucet de gold supera o sink em ~1.800:1.
  Padrão Diablo III documentado pela comunidade: AH sem comissão → goldflation.
- **A linha P2W que o produto promete não cruzar está à venda.** `guild_level_fast`
  cobra 2× gems por nível: 92.340 gems ≈ R$ 2.459 por um multiplicador permanente
  ×1.18 em três faucets, contradizendo `ROADMAP_COMERCIAL.md (princípio da seção 1)` ("sem P2W"). E o
  passe premium vende 4 cosméticos de 7 que **não são renderizáveis** — o jogador
  paga e não vê.
- **O produto é uma semana de conteúdo.** Cap L60 em ~7,7 dias, escada de 27 zonas
  em ~2h de atenção, 10 bosses, e a ÚNICA mecânica ativa do jogo (janela de
  interrupt) vale literalmente 0% no endgame (BossRush é simulação pura sem janela —
  `CONFIRMADO NO CÓDIGO` com o fluxo inteiro traçado). A cadência de live-ops que a
  comunidade do gênero exige (updates 4–6 semanas) não tem força de produção
  demonstrada.

**Veredito numérico** (§23): média técnica **6,5**, média produto **5,0**, potencial
comercial **4,5**, **prontidão beta 4,0** — e hoje, operacionalmente, **0**: a árvore
não compila e o banco não sobe. Não é refinamento: são dois comandos de conserto
(§24, P0-A e P0-B) que devolvem a árvore ao estado verde que o repositório
comprometeu no último commit.

---

## 2. Metodologia e regras de classificação

- Toda afirmação que reduz nota carrega sua classificação e evidência (arquivo:linha
  ou comando executado). Hipóteses listadas na §21 **não** reduziram nenhuma nota.
- Testes executados nesta auditoria sobre a árvore real: `godot --headless
  --check-only` (Server.gd), `scripts/test.sh one migration_atomicity_test`,
  `scripts/check_untracked.sh`, `--check-only` em harnesses dependentes.
- Os agentes de pesquisa de código operaram somente-leitura (sem gravar, sem rodar
  suítes pesadas para não colidir com o flock do `test.sh`); cada achado citado foi
  conferido por amostragem direta pelo auditor-chefe antes de entrar como CONFIRMADO.
- A auditoria anterior (10-04) foi re-testada, não copiada: suas duas maiores alegrias
  de P0 (clawback zerado, streak double-grant) permanecem **REFUTADAS**; a alegação
  "remember-me é SHA-256 sem sal" está **REFUTADA na árvore de trabalho** (virou
  HMAC-SHA256 com chave de env, fail-closed) mas **CONFIRMADA em HEAD** (o conserto
  é o diff não commitado); a "drift resolvida 1h vs 8h" está **REABERTA** (§22/P1).

---

## 3. Inventário do repositório (CONFIRMADO POR DADOS)

- **Stack:** Godot 4.7.1 pin / 4.7.2 local; servidor headless; SQLite WAL (`live.db`)
  single-writer + read-pool de 2 slots; companion Python 3.12 (webhook Mercado Pago/
  Pix, `/store`, push Web, métricas); nginx; Docker Compose; Prometheus + Alertmanager.
- **Volume:** ~440 arquivos `.gd` (~61k linhas), 90 arquivos GUI (14,085 linhas),
  72 patches de migração (001–072, todos rastreados; o lote C criou a 069, o lote Q criou 070–071 e o lote M criou 072), `companion/server.py` ~1.5k
  linhas + módulos de push próprios.
- **Qualidade de borda:** 74 harnesses Godot auto-inscritos + 11 suítes Python +
  11 gates de estrutura + ~52 checks de segredos; i18n pt_BR 100% (1.337 linhas CSV);
  alertas: 17 regras Prometheus.
- **Estado do tree:** 38 arquivos sujos incluindo endurecimentos reais (HMAC de
  token, throttle de criação por IP, re-hash PBKDF2) — e os dois P0 da §1.

## 4. Mapa do sistema (Graphify)

`graphify-out/` (1.913 nós / 2.395 arestas / 257 comunidades, commit `eb9514e`):
os hubs são documentais (auditorias, roadmap, specs), não código — 1.868 arquivos
(.tres/.uid/.gd) fora do grafo. **Consequência metodológica registrada:** o mapa
confirmou o fluxo de produto/social, mas a verificação de código foi feita por leitura
direta; o grafo está obsoleto para a árvore atual (não inclui o par de 38 arquivos).
Sem ciclos de import detectados — arquitetura de dependências limpa.

## 5. Arquitetura

Pontos fortes CONFIRMADOS: fronteira de dinheiro fora do processo do jogo (companion
assina, re-fetch autoritativo, fila idempotente); identidade sempre lida do transporte
(`TransportSenderID` (`Network.gd:@TransportSenderID`) sobrescreve peerID do pacote); migrations fail-closed com
carimbo por patch; domínios de economia extraídos por composição com fachada estável.

Débitos CONFIRMADOS NO CÓDIGO:
- **Duas disciplinas de lock convivem:** 47 sites no `settleMutex` global × 8 no
  sharded — e os shards são **100% inertes** (o gargalo real é o `queryMutex` único
  do SQL; sharding de mutex sem sharding de banco não paraleliza nada).
- **Companion é um segundo escritor** no `live.db` com threads ilimitadas
  (`ThreadingHTTPServer`) — contenção cruzada de processos **HIPÓTESE** com precedente
  histórico (SIGSEGV 2026-09-28), não medida; não contou nota.
- `PRAGMA foreign_keys` nunca é ligado (0 hits no repo); integridade depende de
  triggers `AFTER DELETE` (066/067) + censo de órfãos. Funciona, mas
  `architecture.md` sugere FK declarativa que não existe — §20.
- God-nodes no teto: `Server.gd`, `SQL.gd`, `Network.gd`, `TelemetryService.gd`
  (799/800) — orçamento de refator zero, o gate mede por run.

## 6. Game Design

Números reconstruídos e conferidos: XP(L→L+1)=`round(8000×1.22^L)`, cap 60; gate de
zona linear (24+8×z) × XP de zona exponencial (1.25^z) → escada de 27 zonas em ~2h de
atenção; 10 bosses; 96 células de item com tiers 4–9 somando 25 itens = o jogo fundo
inteiro; 13 skills sem levelamento (`Teach` (`SkillTrainer.gd:@Teach`)) — não há build optimization.
Pacing honesto, curva testada; o problema não é design de números, é **volume**.

## 7. Core loop e meta

- Loop claro e forçado (login→farm instance→claim), offline 5,07×/atenção vs 1,58×/
  relógio. **Variedade: 1.** E a única mecânica ativa (janela de interrupt, 1,2s/3,0s)
  **não paga no endgame**: fluxo traçado — a escada ao vivo aplica o bônus via
  `_consumeBossInterrupt` (`IdlePolicy.gd:@_consumeBossInterrupt`) (`InterruptBonus`→`Skill.Damaged`), a preview respeita
  (`WillWin` (`BossLadder.gd:@WillWin`), 3-arg), mas o **BossRush** pós-escada chama
  `BossService.Resolve(snapshot, level)` 2-args (`RunBossRush` (`BossProgressionService.gd:@RunBossRush`)),
  `interruptMult` default 1.0 (`Resolve` (`BossService.gd:@Resolve`)) — e não há janela para tocar na
  rush (uma RPC, N simulações). `CONFIRMADO NO CÓDIGO`.
- Meta = 1 eixo (zona) + 1 escalar (tormento 0–10) + rebirth multiplicando os mesmos
  faucets (positivo-feedback, não profundidade). Sem dungeon, sem world boss, sem
  coleção, sem evento procedural.

## 8. Retenção

Ganchos existem mas são estruturalmente diluídos: streak por *caractere* ×10 contas
(~1,2–2,0× a banda declarada por ciclo); passe com **30 de 40 níveis da trilha grátis
e 22 de 40 da premium vazios** (`PASS_FREE` (`EconomyCatalog.gd:@PASS_FREE`)); push re-engagement
construído (1.174 linhas) e **nunca disparado por evento de jogo** (sweep só via CLI);
login warp direto para a farm privada — guildas estruturalmente fora do caminho;
sem FOMO de loja limitada. Benchmarks da §22 dizem que D7 do gênero se segura por
ganchos de sessão — que é justamente a camada mais fraca aqui.

## 9. Economia (análise profunda)

Faucet→sink por moeda, reconstruído do código e medido pelos agentes:

| Moeda | Diagnóstico | Classificação |
|---|---|---|
| Gold | pior caso faucet:sink ≈ **1.800:1** (piso ~1,5:1); AH queima ~0%; torneio faz ponte 1k gold→2–4k gems; `favor_gold` 1.05^n sem cap; double_xp multiplica também o gold | CONFIRMADO NO CÓDIGO (condições) / CONFIRMADO POR DADOS (tax do burn ≈0% do volume) |
| Gems | faucet ~8,7e2/dia vs sink ~5,1e2/dia — próximo do equilíbrio; mas 1.150 de 1.300 preços de cosmético são **incompráveis** (sem SKU) | CONFIRMADO NO CÓDIGO |
| Essence/itens | OK — salvage/corrupt/cube destroem como documentado | CONFIRMADO POR TESTE (harnesses verdes de pia) |

**AH-sink morto — o mecanismo exato** (re-verificado no diff não commitado):
`_SettleListingLocked` queima o creatorFee de 1% só quando
`creatorAccount != 0 && creatorAccount != sellerAccount` — ou seja, só em revenda de
item crafted por terceiros com aprovação de GM. Praticamente nenhuma listagem viva
satisfaz isso. A roadmap vende o gold-sink do AH; o código não tem.
**Exploit de settle online (CONFIRMADO NO CÓDIGO):** âncora do settle não é
atualizada durante jogo online → farmer AFK-online acumula janelas (offline 8h
"grátis" repetidas em sessão). **Baús "provably fair" previsíveis:** seed =
`id + created_at + sal fixo` com um único sha256 — quem conhece a fórmula deduz o
roll antes do clique (CONFIRMADO NO CÓDIGO; exploração ativa = INFERÊNCIA).
**Verificado e saudável:** idempotência do `OfflineSettle`, escrow com lineage
restore, invariant de `held_gold` em buy-orders, ledger append-only.

## 10. Marketplace / AH

Estrutura forte (1.155 linhas, escrow, caps 50 listings/dia e 10 slots, TTL 3d,
buy-orders). Defeitos CONFIRMADOS: matcher **total ask × preço unitário do bid** em
dois sites — `_FillFromBuyOrder` (`AuctionHouseService.gd:@_FillFromBuyOrder`) e `_TryMatchListing` (`AuctionHouseService.gd:@_TryMatchListing`) — aceita bids fora do preço
médio; bots de seed one-shot morrem no TTL de 72h (liquidez evapora sem reseed);
anti-lavagem `ah_wash_pair` é detect-and-review, **não bloqueia**; AH não exige
e-mail verificado (trade exige). A migration 068 (P0-B) tentava consertar CHECKs
justamente aqui — e está quebrada.

## 11. Monetização

Catálogo coerente e preço calibrado ao Brasil (R$19,90–79,90, Pix — padrão do
mercado, §22). Três defeitos de linha-dura CONFIRMADOS: (a) **P2W à venda**
(a perna `LevelUpGuildFast`, que a rodada P1-C deste mesmo dia removeu de
`GuildService.gd`: skip da escada de gold a 2× ouro por nível; 92.340 gems ≈
R$ 2.459 por ×1.18 permanente), contra `ROADMAP_COMERCIAL.md (princípio da seção 1)`; (b) **passe premium
entrega cosmético que não renderiza** (4 de 7; `_GrantPassRewardRaw` (`PassService.gd:@_GrantPassRewardRaw`) concede sem
gate `IsRenderedCosmetic`) — dinheiro real por item invisível; (c) **VIP farmável**
(880 gems < 1 semana de faucet F2P — canibaliza a assinatura). Gifting ausente;
testes A/B ausentes; conversão-alvo 2% e D7 7% não são absurdos para o gênero (§22)
mas dependem das camadas 8 e 11 acima.

## 12. Segurança

A **fronteira** é boa: HMAC `compare_digest` com janela anti-replay (`companion/
`_const_time` em `server.py:@_const_time``), idempotência UNIQUE na fila (`015:6` + `INSERT OR IGNORE`),
clawback clampado a `gems_paid` no jogo (`_ApplyGrantRaw` (`CheckoutService.gd:@_ApplyGrantRaw`), shortfall →
flag), IDOR varrido em 126 RPCs — zero handler confia em id do pacote, e o único
campo de cliente validado (`SetFormation`) checa posse. Sem injeção SQL por
allowlist parametrizada. KDF a 210k PBKDF2-HMAC-SHA256 com re-hash transparente no
login (`ValidateAuthPassword` (`SQL.gd:@ValidateAuthPassword`)) e equalizador de timing (`BurnKdfTime` (`SQLSecurity.gd:@BurnKdfTime`)).

Furos CONFIRMADOS, em ordem de perigo:
1. **Repouso é a cadeia inteira:** DB em claro; `PRAGMA key` existe no código
   (`_post_launch` (`SQL.gd:@_post_launch`)) mas o addon **godot-sqlite não tem codec SQLCipher** (zero
   fonte no repo, env ausente do compose e do `.env.example`) → mesmo ligado, seria
   ignorado em silêncio. Somando: remember-me agora HMAC (bom) **mas o companion
   consulta o token SEM o filtro `ip_address` que o servidor exige**
   (`verify_session_token` (`server.py:@verify_session_token`) vs `ValidateAuthToken` (`SQL.gd:@ValidateAuthToken`)), a perna legada `sha256(token)` continua
   ativa, e o código de reset é **SHA-256 sem sal sobre 32⁶ ≈ 1,07e9**
   (`RequestPasswordReset` (`Server.gd:@RequestPasswordReset`) + `DefaultResetCodeLength` e `ResetCodeAlphabet` (`DefaultResetCodeLength` (`Hasher.gd:@DefaultResetCodeLength`))). Um dump de `live.db` → takeover de conta +
   porta de checkout, em 30 dias de janela. (CONFIRMADO NO CÓDIGO; o dump em si é
   pré-condição, não alegado.)
2. **Armadilhas do KDF novo:** a primeira geração devolvia 31 bytes e a
   verificação recalculava o custo pela constante do código, não pelo registro —
   subir `PBKDF2Iterations` invalidaria toda conta ver-2 de uma vez. (CONFIRMADO
   NO CÓDIGO na data da auditoria; a truncagem era consistente entre escrita e
   leitura, hoje não quebrava login.) **RESOLVIDO pelo lote P1-H (2026-10-06):**
   `VerifyPassword` (`Hasher.gd:@VerifyPassword`) agora lê iterações, sal e
   comprimento do registro `pbkdf2_sha256$<iters>$<salt_hex>$<hash_hex>`, e a
   linha cujo custo difere do regime atual é flagada por `NeedsRehash`
   (`Hasher.gd:@NeedsRehash`) e re-deriva no próximo login bem-sucedido. O
   comportamento é medido em `tests/password_timing_path_test.gd`.
3. **Criptografia hand-rolled** para Web Push (`push_aesgcm.py` AES/GCM do zero,
   `push_p256.py` P-256/ECDH/ECDSA do zero) — escopo confirmado é só payload de
   notificação, dinheiro usa stdlib. Débito de manutenção, não de cofre. (CONFIRMADO.)
4. **Reset code sem sal** — item 1 já inclui; com dump, pré-computável em GPU em
   segundos. Guarda online existe (`sec_reset_request_limit`). (CONFIRMADO NO CÓDIGO.)
5. E-mail logado em claro (`SendPasswordResetEmail` (`EmailService.gd:@SendPasswordResetEmail`)), accountName (`AcceptConsent` (`Server.gd:@AcceptConsent`)) —
   LGPD de baixo impacto, sem senha/token em log (grep 0 hits). (CONFIRMADO.)

## 13–14. Performance e escalabilidade

Medido (`CONFIRMADO POR DADOS`): tick idle 26,87 ms com 200 farmers / 88,93 ms com
400 (orçamento de 250 ms a 4 Hz → folga em 200, aperta em 400); `MaxPlayerCount=128`
é o teto duro atual; P99 settle dentro do gate. Caminhos quentes CONFIRMADOS: varredura
de boot (1.000 tx + 1.000 matches) na main thread; fanout de guild ~(2N+2) SELECTs;
AH buy-order sem índice `(status, item_id, price)`; shards de mutex inertes (§5).
Escalabilidade horizontal = plano em docs, zero implementação: SQLite single-node +
segundo escritor Python. Nota 3/10.

## 15–16. UX/UI e social

Toque completo, i18n 100%, HUD idle com botão próprio, streak visível no relatório
AFK (corrigindo falso-positivo de auditoria anterior). Mas: onboarding ainda ensina
F1/F2 em plataforma sem teclado em parte do fluxo; sem acessibilidade de leitor de
tela; login warp faz guilda/quests/cidade inalcançáveis no caminho feliz. Social é
real e testado (chat com moderação, fanout verificado, arena ELO, torneios) porém
sem gift e com pontos de guilda economicamente vazios.

## 17. Live Ops

Remote config JSON validada fail-closed (calendário, seasons, catálogo, knobs) —
mecanismo bom, conteúdo pobre: **11 das 15 janelas do calendário são torneios**
(premio-pool, irrelevante para F2P), nenhum `double_xp` vivo, S1 ancorada ao boot do
servidor (`start_unix: 0`). Sem A/B, sem segmentação.

## 18. Analytics

O companion agora expõe `/metrics/prometheus` em texto (fix 10-04, CONFIRMADO) e
publica D1 como gauge — **mas 0 das 17 regras de alerta referencia métrica do
companion**, `retention_d1` pode reportar **falso-zero** quando a coorte está vazia
(método `metrics_prometheus` do `server.py` contradiz o próprio comentário), o funil `starter` casa via
`LIKE '%"sku": "starter.pack"%'` (frágil a spacing), ARPPU/conversão existem só no
JSON de inside, não como série Prometheus. Decisões de dinheiro às cegas de alerta.

## 19–20. Testes, DevOps, código e docs

Superfície de teste é genuinamente forte (74+11+11, com controles plantados que os
próprios gates provam). Hoje está **vermelha por causa dos P0** (§1) — que é
justamente o sistema funcionando e sendo ignorado no tree de trabalho. Débitos
CONFIRMADOS: fuzz com seed fixa (reproduzível, pouco exploratório), `gm_gate_test` é
grep de fonte não comportamento, `check_write_funnel` cega a `ExecNoLock/
UpdateRowsRaw`, CI sem `timeout-minutes`, todos os 6 containers como root sem regra
no `check_compose.sh`, backup offsite no mesmo host (A-01 histórico), RTO nunca
medido (HIPÓTESE sobre falha de restore: não contou). Docs: arquitetura honesta e
com gates de drift, **mas** `ROADMAP_COMERCIAL.md (princípio da seção 1)` ainda promete "F2P liquida 1 h"
contra `BaseCapHours = 8.0` (`OfflineSettle.gd:@BaseCapHours`) — drift reaberta (CONFIRMADO NO
CÓDIGO), `architecture.md` insinua FKs não enforceadas, comentário do token diz
"128-bit" com 256 reais (`DefaultTokenSize` (`Hasher.gd:@DefaultTokenSize`)).

## 21. Hipóteses NÃO confirmadas (nota não reduzida)

- Contenção de escrita cross-process companion×servidor sob carga (precedente de
  SIGSEGV histórico; sem medição atual).
- Restore offsite na prática (RPO/RTO nunca cronometrados).
- Rollback de migration com falha injetada no meio de transação de produção.
- D30 ≥ 4% atingível com o produto atual (ambicioso vs mediana móvel ~0,7–0,8%, mas
  dentro do range relatado para idle; §22).
- "Exploração ativa" do RNG de baús por jogadores (fórmula fraca CONFIRMADA; uso =
  inferência).

## 22. Comunidade e concorrentes (EVIDÊNCIA DA COMUNIDADE, 18 fontes)

- **Benchmarks:** GameAnalytics 2025/2026 — mediana móvel D1 ~22%, D7 <4%, D30
  ~0,7–0,8%; idle/RPG no top quartil chegam a D1 31–33%. Proxy multi-gênero D1
  25–30/D7 10–15/D30 3–6. **O gate do Shambleta (27/7/4) é realista em D1, ambicioso
  em D30, e o elo frágil é D7** — que se ganha com ganchos de sessão, não com cap.
- **Caps de offline:** r/incremental_games rejeita parede dura e penalizar offline
  vs online (preferência por decaimento); Melvor 18–24h é aceito sem churn. **8h F2P
  é curto vs a norma e lê-se como castigo que vende VIP** (EVIDÊNCIA + INFERÊNCIA).
- **Backlash P2W:** Diablo III fechou o RMAH — Jay Wilson: "realmente machucou o
  jogo"; Idle Champions com threads "nós viramos P2W" + boicote; Evony = whales
  dominam guild wars, threads de abandono; Raid/IdleOn tolerados porque F2P ainda se
  diverte / não-competitivo. **Vender multiplicador de faucet permanente num jogo com
  guildas+AH é o padrão que a comunidade pune.**
- **Brasil:** Pix padrão, ~60% da receita mobile da LatAm, mercado US$ 2,47B/ano;
  packs R$19,90–79,90 alinhados; ticket de R$2.459 (guild fast) é isolado de baleia
  num mercado de ARPU abaixo do global.
- **Cadência:** updates 4–6 semanas elevam D90 em 25–35% (Adjust); AFK Arena lançou
  com ~48 heróis e US$10–20M no ano 1; Melvor em EA desde 2020. 27 zonas/10 bosses
  esgotam em ~1 semana **sem cadência comprovada de conteúdo = gargalo #1**.
- **AH precedentes:** OSRS GE cobra 1% (2% proposto) como sink estrutural; D3 sem
  sink → goldflation de bilhões, €25–40/bilhão. AH do Shambleta hoje é o D3, não a GE.

## 23. Scorecard

| # | Categoria | Nota | Base da nota (sem hipótese) |
|---|---|---|---|
| 1 | Core Gameplay | 4,5 | loop autoritativo excelente; 1 mecânica ativa, vale 0 no endgame |
| 2 | Core Loop | 5,5 | claro/forçado/medido; variedade 1, sustain falha |
| 3 | Meta Game | 4,0 | 1 eixo + escalares que multiplicam o mesmo faucet |
| 4 | Retenção | 3,5 | ganchos diluídos; push não disparado; D7 é o elo frágil |
| 5 | Game Design | 4,5 | números honestos; volume ~15–20% do gênero |
| 6 | Economia | 4,0 | gold 1.800:1, AH sem burn, ponte torneio, RNG fraco |
| 7 | Monetização | 4,5 | catálogo bom; P2W contra ToS, cosmético invisível, VIP farmável |
| 8 | Marketplace | 6,5 | infra forte; burn morto, matcher, anti-lavagem review-only |
| 9 | Segurança | 6,5 | fronteira/IDOR/injeção fortes; repouso+takes over chain, armadilhas KDF |
| 10 | Arquitetura | 7,0 | limites claros e testados; duas disciplinas de lock, teto god-node |
| 11 | Performance | 6,5 | medida e folga em 200; boot sweep, fanout, índices |
| 12 | Escalabilidade | 3,0 | teto 128, segundo escritor, horizontal só em doc |
| 13 | UX/UI | 6,5 | toque/i18n completos; onboarding F-key, sem leitor de tela |
| 14 | Social | 6,5 | real e testado; sem gift, guild points vazios, inalcançável no warp |
| 15 | Live Ops | 5,5 | config remota fail-closed; calendário 11/15 torneio, sem A/B |
| 16 | Analytics | 5,0 | expositor novo sem alerta; falso-zero D1; ARPPU fora do Prometheus |
| 17 | Testes | 6,5 | 96 harnesses+gates com controles; árvore vermelha = portão certo, tree errado |
| 18 | DevOps | 5,0 | compose/CI reais; root containers, offsite mesmo host, sem timeouts |
| 19 | Código | 7,0 | estilo/gates/disciplina; P0 de indentação num arquivo de auth prova o processo falho no commit, não na regra |
| 20 | Documentação | 7,0 | drift-gated e honesta; 1h-vs-8h reaberta, FK não documentada |

**Média técnica: 6,5 · Média produto: 5,0 · Potencial comercial: 4,5 · Prontidão beta: 4,0** (e 0 hoje: a árvore não liga — §1).

---

## 24. Problemas priorizados

Eixos: **S**everidade, **F**requência, **R**enda, **C**hurn, **E**sforço de conserto,
**C**onfiança (0–10). **OS** = Impacto(S+R+C) × Confiança ÷ Esforço.

### P0-A — A árvore não compila: `LoginWithTwoFactor` (`Server.gd:@LoginWithTwoFactor`) misturou espaço com tab
- **Evidência:** `CONFIRMADO POR TESTE` — `godot --check-only` na árvore:
  "Parse Error: Unindent doesn't match the previous indentation level" @147;
  load falha; cascata `NetServer` vista na run real do harness. Linhas 147-149 com
  2 espaços em corpo TAB (confirmado `cat -A`), introduzidas pelo fix C-01.
- **Impacto:** servidor não liga; todo o hardening de auth escrito junto vira código
  morto; CI vermelha por colateral. **Correção:** converter as 3 linhas para TAB.
- **Implementação:** edição de 3 linhas em `sources/network/server/Server.gd`.
- **Risco do fix:** nulo. **Teste de validação:** `--check-only` no arquivo +
  `test.sh one login_hardening_test` + `rpc_receive_budget_test` + suíte completa.
- **OS = (10+10+8) × 10 ÷ 1 = 280. Fazer agora.**

### P0-B — Migration 068 quebra o boot do banco e está fora do git
- **Evidência:** `CONFIRMADO POR TESTE` — `migration_atomicity_test`: G3b
  `MigrationBlocked() = true` no boot real da fileira de patches, G4 carimbada 67 ≠ 68;
  `check_untracked.sh` 2 FAILs apontando o arquivo. `CONFIRMADO NO CÓDIGO` — causa:
  `INSERT INTO ... SELECT *` em wallet (3 colunas novas vs 4 reais — `gems_paid` da
  049), auction_listing (9 vs 12 — `highlight`/`creator_account_id`/`expires_at` das
  025/028/063), item_instance (10 vs 11 — `creator_account_id` da 027).
- **Impacto:** qualquer deploy com esse diretório liga com boot bloqueado
  (fail-closed funcionando: o servidor se recusa a subir). **Correção:** DDL explícito
  por coluna nas três tabelas (não `SELECT *`), reaplicar em cópia do template, e
  `git add` do arquivo. Os CHECKs de `stat.gp`, `item.count`, `ah_buy_order.escrow_gold`
  que faltam: entrada separada na 068 (mesmo patch, sem buraco de densidade).
- **Risco do fix:** baixo (patch é idempotente por design de posição; testar no
  harness). **Validação:** `test.sh one migration_atomicity_test` verde +
  `check_untracked.sh` verde + boot real.
- **OS = (10+8+8) × 10 ÷ 2 = 130. Fazer agora.**

### P1-A — Companion valida token de sessão sem bind de IP (dump → takeover)
- **Evidência:** `CONFIRMADO NO CÓDIGO` — `verify_session_token` (`companion/server.py:@verify_session_token`) (consulta sem
  `ip_address`) vs `ValidateAuthToken` (`sources/sql/SQL.gd:@ValidateAuthToken`) (servidor exige); perna legada
  `sha256(token)` ativa (`verify_session_token` (`server.py:@verify_session_token`)); TTL 30d (`TokenExpirySec` (`NetworkCommons.gd:@TokenExpirySec`)).
- **Impacto:** linha de `auth_token` roubada vale checkout/pagamentos de qualquer
  máquina; o endurecimento HMAC do servidor é furado pelo lado do dinheiro.
- **Correção:** mesma cláusula de IP + depreciação da perna legada com janela de
  rotação. **Implementação:** `companion/server.py` (query + teste). **Risco:** médio
  (usuários móveis trocam de IP — mesma UX que o servidor já tem hoje). **Validação:**
  `companion/test_security.py` + `password_timing_path_test`. **OS = (9+8+7)×9÷3 = 72.**

### P1-B — Passe premium vende cosmético que não renderiza (4 de 7)
- **Evidência:** `CONFIRMADO NO CÓDIGO` — `_GrantPassRewardRaw` (`PassService.gd:@_GrantPassRewardRaw`) concede sem
  `IsRenderedCosmetic`; `CONFIRMADO POR DADOS` (tabela de cosméticos vs catálogo de
  render). **Impacto:** dinheiro real por item invisível → reembolso/chargeback +
  reputação (Folha já investiga "padrões enganosos" no BR). **Correção:** gate de
  render no grant OU remover do SKU. **Validação:** teste de grant com cosmético
  não-renderizável → recusa/flag. **OS = (9+9+8)×9÷3 = 78.**

### P1-C — P2W de guildas à venda contra o princípio do produto
- **Evidência:** `CONFIRMADO NO CÓDIGO` (à época do achado) — a perna `LevelUpGuildFast` vivia em `GuildService.gd` (2× gold em gems); **RESOLVIDO no lote P1-C (2026-10-06): função, RPC, fachada, botões e comando removidos**;
  EVIDÊNCIA DA COMUNIDADE — padrão Evony/Idle Champions/D3-RMAH pune exatamente
  isso. **Impacto:** R$ 2.459, permanentes, em multiplicador ×1.18 de faucet — em
  PvP/guilda, o churn composto é documentado. **Correção:** remover o skip ou
  trocá-lo por cosmético de status; se mantido, atualizar ToS/roadmap e precificar
  como temporada (não permanente). **Validação:** teste de invariant de poder por
  real pago + revisão de ToS. **OS = (8+9+9)×8÷4 = 50.**

### P1-D — AH não queima gold (sink alegado ≈ 0%) + matcher aceita spread errado
- **Evidência:** `CONFIRMADO NO CÓDIGO` — condição do burn
  (`creatorAccount != sellerAccount` com craft de terceiros) em
  `_SettleListingLocked` (`AuctionHouseService.gd:@_SettleListingLocked`); matcher `total_ask × preço unitário` em
  `@_FillFromBuyOrder/@_TryMatchListing`. `CONFIRMADO POR DADOS` — ~0% do volume satisfaz a condição.
- **Impacto:** goldflation estilo D3; lavagem de gold/RMT sem custo de transferência.
- **Correção:** taxa de listagem em **gold** (1–2% do preço, estilo OSRS GE) como
  burn imediato no escrow; matcher por preço médio. **Validação:** invariante de
  supply em `economy_invariant_fuzz` com cena de 10k listings; `marketplace_depth_test`.
  **OS = (8+8+9)×8÷4 = 50.**

### P1-E — Ponte gold→gems no torneio (1k gold → 2–4k gems)
- **Evidência:** `CONFIRMADO NO CÓDIGO` — premiação de torneio indexada a pool pago
  em gold, resgatável em gems. **Impacto:** contorna o preço da premium currency;
  faucets de gold (sem cap) imprimem premium. **Correção:** prêmios em gold/itens,
  gems só com destruição proporcional de gold no entry. **Validação:** censo
  gold→gems por conta/semana. **OS = (7+9+8)×8÷3 = 64.**

### P1-F — RNG de baú previsível (seed = id+created_at+salto fixo, sha256 único)
- **Correção:** HMAC do segredo de servidor sobre (uid, created_at) com rotação.
- **OS = (7+7+9)×9÷3 = 69.** *(Classificação: fraqueza CONFIRMADA NO CÓDIGO;
  exploração ativa = HIPÓTESE.)*

### P1-G — Settle online acumula janelas (anchor não atualizado durante sessão)
- **OS = (8+7+8)×8÷4 = 46.** `CONFIRMADO NO CÓDIGO` (`OfflineSettle`/`IdlePolicyService`
  — caminho de refresh).

### P1-H — KDF: chave de 31 bytes e iterações registradas ignoradas
- **Evidência:** `CONFIRMADO NO CÓDIGO` — `_Pbkdf2HmacSha256` (`Hasher.gd:@_Pbkdf2HmacSha256`) (`slice(0, outLen-1)`),
  e `VerifyPassword` (`Hasher.gd:@VerifyPassword`) (ver 2 ignora `parsed.iterations`). **Impacto:** mudar
  `PBKDF2Iterations` tranca todas as contas ver-2; formato ≠ "padrão" alegado.
- **Correção:** verificação deve usar as iterações parseadas (com re-hash transparente
  no custo novo); corrigir o slice em janela controlada com migração v3.
- **Validação:** `password_timing_path_test` + fixture v2 com iterações divergentes.
  **OS = (6+6+6)×9÷4 = 40.**

### P1-I — Oferta e código divergem no offline cap (1h vs 8h)
- **Evidência:** `CONFIRMADO NO CÓDIGO` — `ROADMAP_COMERCIAL.md (princípio da seção 1)` ("F2P liquida 1 h")
  contra o `BaseCapHours = 8.0` de `OfflineSettle.gd:@BaseCapHours`. A auditoria de 10-04 marcou isto
  como resolvido: **não está nesta árvore.** EVIDÊNCIA DA COMUNIDADE: 8h ainda é curto
  vs norma 18–24h, e cap duro penaliza offline (preferido: decaimento).
- **Correção:** decisão de produto única — recomendo 8h como *oferta* (corrigir a
  doc/marketing) e avaliar decaimento 8→24h como teste de retenção pós-beta; o cap
  é knob remote-config, então A/B é barato. **OS = (6+7+8)×9÷2 = 94.**

### P1-J — Volume de conteúdo × cadência de produção
- **Evidência:** `CONFIRMADO NO CÓDIGO` (volumes: 27/10/96/13/3) + EVIDÊNCIA DA
  COMUNIDADE (gênero exige 4–6 semanas; cap L60 ~7,7 dias). **Impacto:** D30≥4%
  inalcançável com o conteúdo atual. **Correção não é código:** pipeline de
  conteúdo (zonas/skills-level/coleção) com cadência declarada; interrupt pagando no
  BossRush como quick-win de profundidade (o 3º arg já existe na API).
- **OS = (9+7+9)×7÷8 = 22. Maior risco comercial; custo estrutural.**

**P2 (resumo, tabela completa no apêndice mental do commit):** slots vazios de passe;
streak ×10; AH bots one-shot; wash review-only; AH sem e-mail-gate; chest budget cego
às ~434 chaves/dia/char do rush; `favor_gold` sem cap; fanout guild N+1; índice AH
faltando; boot sweep main-thread; shards de mutex inertes; containers root; offsite
mesmo host; CI sem timeout; fuzz seed fixa; gm_gate source-grep; write-funnel cega;
`retention_d1` falso-zero; 17 alertas × 0 companion; funil LIKE; ARPPU sem série; 1/20
cosmético comprável; VIP farmável; sem gift; S1 anchor no boot; FKs não documentadas
na arquitetura. **P3:** comentário 128 vs 256 bits; preços órfãos de cosmético;
grafias de doc.

---

## 25. Roadmap e a pergunta do dinheiro

**Antes do beta (bloqueadores, nesta ordem):**
1. P0-A + P0-B (uma hora; sem isto não existe build).
2. P1-B (cosmético invisível) + commit do que está pendurado (o hardening de auth
   só existe se entrar).
3. P1-A + P1-F + P1-H (a cadeia de repouso/tokens/KDF, na mesma fatia de PR).
4. P1-I (alinhar oferta) e P1-D/E no mínimo como decisão documentada (tax do AH).
5. Green-check pós-fix: suíte completa + `ci_gate_log` + `check_untracked` verdes.

**No beta:** P1-C (tirar ou reprecificar o skip P2W), P1-G, P1-J iniciar o pipeline
de conteúdo com cadência medida; interrupt no rush; alertas sobre métricas do
companion; e2e de funil com presença→compra testada.

**Pós-beta:** read/write split real do companion (fim do 2º escritor), horizontal
sharding do banco, A/B infra, gifting, coleção/sets, decaimento de cap.

**Se eu fosse responsável pelo dinheiro investido:** os três maiores riscos são
(1) **a árvore não liga hoje** — dois P0 mecânicos em trabalho não commitado, com
todos os gates apontando para eles e ninguém fechando o loop, o que é falha de
processo, não de engenharia; (2) **a promessa comercial contradiz o código** — "sem
P2W" com ×1.18 permanente à venda a R$2.459, "sink primário é o AH" queimando 0%,
"offline 1h" rodando 8h, e cosmético pago que não aparece: cada uma dessas linhas é
processável, chargeável e postável no Reddit; (3) **uma semana de conteúdo com
retenção de sessão descalibrada** — o produto morre no D7 por exaustão, não por
bug. As oportunidades são simétricas: a base técnica (fronteira de dinheiro, gates,
idempotência) já é melhor que a média do mercado indie-LATAM; transformar os
ganchos existentes em política real (pass pago que entrega, streak com banda correta,
push ligado a evento, tax de 1–2% no AH) é esforço pequeno com impacto direto em
D7/ARPPU. **Fazer primeiro:** os dois commits de P0 (hoje), depois o gate de cosmético
do passe, depois a decisão de produto sobre P2W e cap — antes de gastar um real em
aquisição de usuários.

*Nada foi implementado por esta auditoria (Regra 30). Todos os comandos citados como
evidência foram executados na árvore auditada e são reproduzíveis.*

---

## 26. Adendo — o lote de implementação (mesma data, por ordem do dono)

A Regra 30 valeu até o relatório fechar; depois dele o dono ordenou "resolva tudo
sequencialmente". O que virou código, e o que NÃO virou (dito sem maquiagem):

**P0 (lote 1, commitado e no remote):** indentação mista que impedia o boot
(`Server.gd`) e a migration 068 reescrita — o `DROP TABLE` dela mata trigger
dependente que mora em outra tabela (`trg_character_delete`), então a dance agora
dropa, recria e preserva os seis índices do leilão; régua: harness `backup` verde.

**P1 (lote 2, este adendo):**
- **P1-B** — grant de passe premium agora passa por `IsRenderedCosmetic`; a
  validação de boot (`ValidatePassTables`) recusa cosmético não-renderizável na
  trilha paga, e `seasons.json` S1/S2 foram corrigidos para o espelho legal.
- **P1-A** — a perna legada `sha256(token)` do companion ganhou data de morte
  (`LEGACY_SHA256_LEG_RETIRE_UNIX`, 2026-11-04 — uma `TokenExpirySec` depois da
  onda HMAC). O bind de IP documentado no achado É estruturalmente impossível no
  companion (ele vê o proxy, o game vê o transporte) — em vez de bind falso,
  janela curta e medida.
- **P1-H** — `VerifyPassword` lê iterações/sal/comprimento DO REGISTRO, o slice
  de 31 bytes virou 32, e `NeedsRehash` + re-hash transparente no login sobem o
  custo sem prender ninguém. Medido em `tests/password_timing_path_test.gd`.
- **P1-F** — seed de baú de troca agora é HMAC do servidor (`ChestSeal`, chave de
  signing da sessão); sem chave, `OpenChest` fecha — cliente não escolhe sorte.
- **P1-D** — tax de 1% do preço em ouro, mínimo 1, QUEIMADA no list (`ah_burn`,
  census-family que o fraud já conhecia); o matcher de buy-order comparava teto
  por unidade com preço total — corrigido nas duas pontas (`price_gold <=
  unit * count`, `unitAsk = ceil(preço/count)`).
- **P1-E** — prêmio de torneio saiu da ponte gold→gems: paga em OURO, capped
  pelo pool (`entradas × fee`), `prizes_json` aceita as duas chaves para o que
  já está congelado em banco.
- **P1-C** — o skip P2W de guilda saiu do produto: RPC, handler, loja, painel e
  atalho de GM removidos (contagem de RPC 224→223; régua de comportamento no
  `IdleTests`, não só grep).
- **P1-I** — `ROADMAP_COMERCIAL.md` voltou a dizer as 8 h do F2P, ancorado na
  constante viva (`BaseCapHours`).
- **Observabilidade** — coorte D1 ausente deixou de ser zero: sem dados, o
  exposition não emite amostra, e `absent()` nos três alertas novos
  (`alerts_companion.rules.yml`) vira o sinal. `deploy_ops_test` cruza o nome de
  cada regra com a série emitida — regra que aponta para métrica inexistente
  morre no gate.
- **DevOps** — `no-new-privileges` nos seis serviços, `cap_drop: ALL` geral,
  `cap_add` só no web (7 caps nomeadas). Rootless (`run_as_user`) declarado
  dívida pós-beta no próprio compose: exige re-chown dos volumes, que é
  operação, não PR. Backup off-host e RTO documentados em `SCALING.md` —
  prover o bucket é decisão de infra/dinheiro do dono.

**Qualidade de gates:** fuzz tem seed (`SHAMBLETA_FUZZ_SEED`, impressa no
resultado, item hash do seed — reproduction sem sorteio); write-funnel varre o
API CRU (`.UpdateRowsRaw/.DeleteRowsRaw/.ExecNoLock` fora de `Transaction()` não
passa mais — 66 chamadas, 15 writers allowlistados com nome de arquivo); e a
porta GM deixou de ser só grep de fonte: o bloco 14 do `social_graph_test` mede
no despacho real — comum chamando ADMIN não executa, ADMIN executa,
`SHAMBLETA_GM_MODE=1` abre para comum e desligado recusa na hora (não é
pegajoso).

**O que este lote NÃO fecha, e não finge fechar:** P1-G/P1-J (cadência de
conteúdo de 4–6 semanas de produção — não existe commit que faça conteúdo),
sharding horizontal do SQLite (mudança de arquitetura pós-beta), split read/write
do companion (2º escritor continua de pé, por contrato documentado), e prover
offsite real (infra a contratar). A régua de oferta (P1-I) foi alinhada ao
código; a régua de produto sobre o cap (1 h vs 8 h era escolha) foi exercida na
decisão do dono de manter 8 h.

## 27. Adendo — o lote de qualidade de código (C-1..C-10, por ordem do dono: "implemente todos")

- **C-1 (KDF fora do frame)** — o duto `_AwaitOnWorker` (`Server.gd:@_AwaitOnWorker`) roda a tarefa no
  `WorkerThreadPool` e vota `process_frame`; `LoginWithPassword` e `AcceptConsent`
  validam senha off-thread, e o equalizador (`_BurnKdfTimeOffThread`) viaja junto —
  parado no frame ele reabria o oráculo de latência. A raça que o offload abriu
  (duas tentativas no MESMO nome perdiam a atualização de `failed_attempts`, lida
  antes da escrita vizinha) foi fechada na mesma fatia: `_authValidationInFlight`
  serializa por nome, e nomes diferentes continuam concorrentes — é ali que o
  alívio de CPU mora. `LoginWithTwoFactor` e o caminho de token ficam síncronos
  (HMAC é caro de outro jeito e não há ledger por tentativa em risco).
  **Residual confesso — fechado no Pacote P do mesmo dia (P-1 abaixo).**
- **C-2 (reset com sal por conta)** — `Hasher.HashResetCode(code, accountID)` usa o
  salt `reset:<id>`; o hash pendente deixa de ser um PBKDF global da tabela e passa
  a exigir trabalho POR CONTA num dump.
- **C-3 (boot do AH em lotes)** — o sweep de boot drena um lote de colheita e um de
  cruzamento por `AHBootBatchSec` com cursor keyset (`_ahSweepAfterID`); a régua
  (#100 do `marketplace_depth_test`) agora anda o relógio em vez de exigir uma
  passada única.
- **C-4 (ratchets sem folga)** — extraídos `WorldCommandsSupport.gd` (as 7 ops
  `CommandCs*`), `CheckoutReversal.gd` (o bloco de reversão, roda dentro do
  `Transaction(func(` da chamadora) e `VipPolicy.gd`; tetos baixados 1925→1899 e
  923→862 com o motivo escrito no comentário do próprio gate. `EconomyService`
  `EconomyService`
  (796/800) ficou como tripwire neste lote; o Pacote P o retirou (P-3
  abaixo) pelo caminho que o próprio motivo registrado na cerca prescrevia.
- **C-5 (ordem dos locks regada)** — ordem canônica `settleMutex → queryMutex`
  declarada no header do `EconomyKernel`; o write-funnel ganhou `scan_locks`, que
  proíbe por parêntese balanceado `settleMutex.lock()` e `ApplyGoldMoves(` dentro
  do lambda do `Transaction(`, com dois controles plantados (o padrão da casa —
  lock fora, espelho depois do commit — é poupado).
- **C-6 (lavagem no funil)** — a perna que fecha ciclo de lavagem é RECUSADA na
  transação: se o par já existe nos dois sentidos dentro de `AHWashWindowSec`
  (7 d), a segunda volta não liquida; um round trip completo continua comércio
  legítimo. O evento `sec_ah_wash_hold` é escrito depois do rollback (fila
  `_ahWashHolds`), senão o recuado deixaria rastro como se tivesse cometido.
  O custo do próprio portão foi pego pelo benchmark: a pergunta por par varria o
  histórico do item a cada settle — O(n²) contra o próprio mercado, e o p99 do
  settle estourou a régua de regressão na primeira passada. A conta paga foi
  índice, não afrouxamento: `idx_ah_price_history_pair` (migration 069).
- **C-7 (VIP não-farmável)** — `VipPolicy.ClampGrant` (teto 90 d a partir do
  instante da compra) nos QUATRO escritores de `vip_until` (checkout, oferta da
  loja, passe, applier do grant pendente); trilho free não concede VIP (catálogo e
  validador de temporada recusam `vip_days` no free; seasons.json S2 migrou para
  chest).
- **C-8 (KPI ratios)** — ARPU/ARPPU/conversão por moeda viraram gauges no
  exposition Prometheus com os MESMOS denominadores do JSON.
- **C-9 (push disparado)** — `Store.push_season_close` + scheduler opt-in
  (`SHAMBLETA_PUSH_SCHED=1`, `SHAMBLETA_PUSH_SCHED_SEC`, mínimo 60 s); dedupe pelo
  corpo `season:<id>` no outbox — sobrevive a restart.
- **C-10 (dupla taxa declarada)** — crafted paga 1% no list + 1% do criador no
  settle: os 2% são política declarada no `EconomyCatalog`, não bug de caminho.

Veredites do lote: varredura completa `test.sh all` na árvore final —
**zero gates vermelhos, zero flakes, zero ruído**. `login_hardening` 101/0,
`password_timing_path` 101/0 (a régua das duas rotas do equalizador foi
reancorada na forma off-thread), `accounts_fix`, `marketplace_depth`, `fraud`,
`season_liveops`, `refund_revocation`, `pass_season_alignment`, `repo_layout`,
`telemetry_census`, `migration_atomicity`, `benchmarks` e `multi_instance_tick`
verdes; gates de estrutura (god-node 0, doc-drift 2571/0, write-funnel com a
allowlist em 16 writers e o `scan_locks` novo, secrets, compose, untracked)
verdes. O ciclo de feedback que a casa gosta de contar: o `benchmarks` pegou o
custo O(n²) do portão C-6 na primeira passada, o `telemetry_census` pegou o
evento sem leitor, o `repo_layout` exigiu motivo para as duas cercas novas, e o
`doc_drift` mordeu dezesseis ponteiros `arquivo:NN` que as extrações
deslocaram — em todos os casos a régua estava certa e a correção foi código ou
registro, nunca o afrouxamento da régua.

## 28. Adendo — Pacote P (2026-10-06): as três pendências fecháveis em código

- **P-1 (cadastro off-thread)** — fecha o residual do C-1: `AddAccount` (deriva a
  senha nova, 210k) e a primeira `ValidateAuthPassword` (re-deriva, mais 210k)
  viajam como UMA tarefa no mesmo contêiner `_AwaitOnWorker`, serializando pelo
  MESMO espaço de nomes do login — criação e tentativa contra o mesmo nome nunca
  correm soltas. O guarda de colisão (`HasAccount`/`HasEmail`) e o gate de IP
  continuam síncronos, então o spray bloqueado não ocupa worker; o
  `accounts_list_update` e o `FinalizeLogin` continuam na borda do frame, com o
  peer revalidado depois do await. Mapeamento de erro: verificação que falha logo
  após a criação agora responde `ERR_NAME_AVAILABLE` em vez de silencioso `ERR_OK`
  sem sessão — falha melhor que o estado antigo.
- **P-2 (push ligado na operação)** — `SHAMBLETA_PUSH_SCHED=1` e
  `SHAMBLETA_PUSH_SCHED_SEC=900` entram no serviço companion do compose com
  escape por env do painel; o dedupe pelo outbox torna o thread reinício-seguro.
  A pendência "push não disparado" morre aqui, não no papel.
- **P-3 (EconomyService sai da cerca)** — as pernas do reconcílio (`ReconcileDaily`,
  `ReconcileDetail`, `RunReconcileJob`) saíram para `sources/economy/EconomyReconcile.gd`
  com `_eco` injetado; a fachada reteém o seam contratual (`SQLBackups` lê
  `Launcher.Economy`) com delegadores de duas linhas. 796 → 778 linhas: fora da
  banda ≥98%, a entrada do `NEAR_FENCE` foi APAGADA — entrada que apodrece é
  allowlist podre, e foi a régua do `repo_layout` quem cobrou as duas coisas.

Notas após o pacote: a média técnica fica ~7,3 — P-1/P-2/P-3 não compram nota
nova, fecham o que foi prometido no caminho registrado. O que continua aberto
continua sendo o que não é commit: conteúdo (P1-J), endgame/sustentação (P1-G na
leitura de produto), sharding horizontal, rootless de verdade e offsite real.

## 29. Adendo — Lote Q (2026-10-07): oito peças pequenas, cada uma com régua nova

- **Q-1 (interrupt pago no rush)** — o acerto de janela demonstrado na luta ao vivo
  passa a valer no boss rush: `SQL.CacheBossInterrupt` grava o MELHOR mult da
  janela em `character.interrupt_mult` (migração 070, expira em 7 dias — crédito
  declara uso, não direito eterno), `IdlePolicy._consumeBossInterrupt` escreve pelo
  dono da identidade (peer→char), e `RunBossRush` resolve com o mult vigente.
  A navalha medida: mesmo snapshot perde sem crédito e vence com o perfect em
  cache; sem demonstração o rush comporta-se exatamente como antes (a suíte antiga
  não se moveu). `ChallengeBoss` no fallback de sim continua sem crédito — é a
  luta que demonstra, não o menu.
- **Q-2 (vazamento S8 no `TriggerSelect`)** — a rota de stats públicos agora só
  responde sobre o conjunto autoritativo `visibleAgents` do próprio servidor: um
  RID adivinhado pelo cliente não extrai mais stats do mundo inteiro. Régua de
  fonte amarra ordem (gate antes do broadcast) e unicidade de saída.
- **Q-3 (LGPD no log de e-mail)** — `EmailService.MaskEmail`/`RedactEmails`: o log
  de envio grava `a***@do***`, e o corpo de erro do fornecedor é redigido antes
  do `printLog`. E-mail completo não volta a morar em log de produção.
- **Q-4 (`timeout-minutes` em todo job do CI)** — os 15 jobs dos três workflows
  ganham teto inteiro > 0, e o `check_ci.sh` passa a exigir a chave de todo job
  novo — a regra virou permanente, não cleanup de rodada.
- **Q-5 (streak por CONTA, não por char)** — a janela de pagamento do `login_streak`
  passa a ser reivindicada pelo primeiro char da conta no `ShopDay`: irmãos da
  mesma conta avançam a continuidade com `reason=account_day_taken` e ouro zero.
  Fecha a alavanca medida de 10 chars × faucet por char com régua no `balance_test`.
- **Q-6 (tetos declarados: favor + budget de rush)** — `RebirthData.FavorMaxLevels
  = 50` vira política (clamp na curva, guarda `maxed` na compra, `favor_max` no
  painel): teto que só existia como consequência de 1,7^n agora tem porta. O boss
  rush ganha budget diário durável (`boss_rush_activity`, migração 071, bucket
  `ShopDay`, cap 2) contabilizado na MESMA transação do gasto da chave — cap em
  memória reseta com o boot, e a recusa sai com nome (`rush_day_cap`) sem cobrar
  chave.
- **Q-7 (onboarding toca o toque; calendário vive dias comuns)** — os passos 2–5 do
  onboarding ensinam o `TouchButton` do menu (Web/celular não têm F1/F2; F1 fica
  como atalho secundário honesto), com as quatro linhas do catálogo pt_BR
  reescritas junto. No live ops, a proteção do golden mudou de dono: os harnesses
  que AFEREM economia pinam os eixos de bônus (`LiveOpsCalendar.PinNeutral`) e o
  contrato do pino é medido pelo `season_liveops_test` (E7 re-sondada no deserto
  novo). Com isso a agenda pôde enfim acender campanha em dia comum: sprint ×2 de de
  10–11/10 e semana do baú ×1,5 de 15–20/10, e a nota do arquivo deixa de proibir
  o calendário de existir.
- **Q-8 (funil por parse; guilda memoizada)** — o `starter_claimed` do painel
  decide por `json.loads` do payload, não pela forma do LIKE: a claim mintada pelo
  runtime Godot (`"sku":"starter.pack"`, sem espaço) era invisível ao funil antes
  de hoje, e o fixture agora exige as duas serializações e o controle negativo.
  `GetGuildForAccount` ganha memo TTL de 30 s com invalidação em todo verbo de
  roster (`Create/Join/Leave/RemoveMember`) e porta explícita para fixtures que
  escrevem por fora (`InvalidateMembershipAll`, já chamada pelas três limpezas
  cruas das suítes). A régua do censo em `benchmarks` não é cronômetro: 25
  leituras memoizadas sem escrita intercalada custam UMA ida ao banco, e a
  invalidação reabre exatamente a segunda.

Veredites após o lote: nada aqui compra nota nova por si — Q-1/Q-2/Q-5/Q-6
fecham buracos de política que a própria auditoria nomeou; Q-7 remove a
proibição que transformava live ops em calendário de datas distantes (Achado
#98 tem agora primeira perna de código); Q-8 fecha o funil que mentia para o
painel e o SELECT por mensagem de chat. O suite mordeu cinco vezes e as cinco
eram código meu, não régua: (i) o censo de fonte do `guild_roster_race_test`
leu a LITERAL `DELETE FROM guild_member` dentro do meu comentário e contabilizou
o memo como sexta mutadora — comentário é texto de fonte e o gate não distingue
(bom: é assim que ele pega escrita disfarçada); (ii) `reason_toast_test` cobrou e
achou os dois códigos novos (`account_day_taken`, `rush_day_cap`) sem linha própria
no catálogo bilíngue — token sem linha é o jogador lendo chave crua; (iii) o
`login_hardening` me pegou usando `call` com array no lugar de `callv` — SCRIPT
ERROR na hora, verde ao defeito nunca; (iv) o mesmo harness depois pegou
`m.start` em `RegExMatch` (o método é `get_start()`) — a redação de e-mail
falhava para texto vazio em produção e o check solto não viu; (v) o censo de
chaves repetidas do i18n achou a linha `reason/same_day` que eu plantei duas
vezes ao inserir as novas. Nada foi afrouxado; em todos os casos a régua estava
certa e o registro foi corrigido. E a navalha do Q-1, que passou em duas
execuções com HP de fixture em 100000, provou no sweep que o limiar dependia do
HP escolhido: agora o HP é DERIVADO do boss do instante (limiar de dano cravado
em K=500) e a banda existe por construção em qualquer nível, com diagnóstico
impresso se um dia faltar. O que continua aberto é o que não coube em lote:
sharding, teto dos 128, segundo writer, rootless real, conteúdo P1-J e
endgame P1-G.

## 30. Adendo — Lote M1 (2026-10-07): quatro peças de produto, cada uma com régua nova

- **M-1 (52 slots vazios do passe)** — as duas trilhas foram preenchidas com o
  acervo que já existia: free 1..40 com gems/báus e DOIS cosméticos de marco da
  própria prateleira (emote-guilda 25, fx-faísca 35); premium ganhou 12 entradas
  novas antes da escada (gems,baus e VIP QoL em 10/19/25), e 31..40 continuam
  pagando `PASS_BONUS_GEMS` pela escada declarada. Cosméticos de OUTRA origem
  ficaram fora de propósito — `emote_coroa` é exclusividade vitalícia do Deluxe,
  `title_recruta`/`title_apoiador` são backfill de compra/doação, `title_campeao`
  é prêmio de copa. O espelho `pass_tiers` da S1 em `seasons.json` foi reescrito
  nível a nível a partir do catálogo (a régua `suite A` do `season_liveops_test`
  amarra os dois lados), e o censo novo em `SuiteStorefrontHonesty` decreta:
  nível sem entrada NÃO-VAZIA (free) ou sem tabela/escada (premium) é vermelho.
  A casa nova é `EconomyPassTrack.gd` (gate anti-god-node; o catálogo voltou para
  787 dentro da banda com razão registrada). Morsas do caminho: (1)
  `formation_skin` é TYPE, não id — o validador fail-closed do `seasons.json`
  derrubou o arquivo inteiro e cinco checks de temporada caíram em cascata até a
  sonda imprimir `ValidateSeasonsFile` e dizer a linha; (2) o pointer "linha 319 de
  PassService" que eu escrevi era 320 — a régua de âncora não perdoa, e não
  deveria.
- **M-4 (push de abertura de campanha)** — terceiro gancho do scheduler: cada
  janela `double_xp`/`chest_bonus` do calendário LiveOps que abrir dentro da
  antecedência notifica os assinantes UMA vez por evento, dedupe pelo corpo da
  fila (`campaign:<key>`), torneio fora por construção (eixo de pool, mesma
  isenção do pin Q-7) e calendário ilegível é silencioso. Diferença deliberada
  contra o `season:<id>`: a igualdade no corpo, não LIKE — as chaves têm
  underscore e `_` é curinga; a suíte prova que `w6_alpha` e `w6_alpha_x` são
  campanhas DISTINTAS. Saída registrada consumida: `test_webhook.py` estourou o
  teto e abriu `test_push.py` (W5+W6) exatamente como a razão do C-9 previa; a
  fila do Store fatiou para `push_hooks.py` (mix-in `Store(PushQueue)`) para o
  ratchet do `server.py` voltar a caber — 13 ponteiros de linha re-ancorados
  depois dos dois cortes.
- **M-2 (pontos de guilda viram moeda)** — `BuyGuildPerk` dentro do funil
  `settleMutex + Transaction`: três perks declarados em `GuildPerkCatalog.gd`
  (vault +2 stacks/tier, boon +1% settle/tier, roster +1 assento/tier), preço
  escalonado com o NÍVEL da guilda (a guilda grande colhe pontos na mesma taxa;
  preço fixo era doação perpétua para si mesma), líder-only, maxed antes do
  saldo, e a última porta é `UPDATE ... WHERE points >= cost` conferida por
  `changes()` na MESMA conexão. Tabela nova: `guild_perk` (migração 072). Os
  consumidores leem pela boca única: cap do cofre, multiplicador do settle e o
  teto do `GuildRoster` nas DUAS pontas (`IsFull`/`IsFullLocked`). Régua de fonte
  amarra as duas pontas do teto; `SuiteGuildPerks` mede recusa-sem-saldo,
  recusa-sem-linha-fantasma, escada até o máximo e o membro que não compra.
  Morsas: (1) `int(NULL)` do subselect sem `COALESCE` derrubou as duas bocas na
  primeira corrida — 43 vermelhos, uma causa; (2) reatribuir `out` dentro do
  lambda escreve na CÓPIA capturada — o censo de captura da suíte já nomeava o
  defeito, e a primeira corrida devolveu "?" em toda recusa até a forma virar
  mutação por chave como em `CreateGuild`.
- **M-5 (flash shop — vitrine do dia)** — `FlashShop.Showcase(day, ...)`: LCG
  puro com seed = dia, três prateleiras iguais para todas as contas, prêmio do
  vocabulário existente (chests/vip_days com os caps C-7), desconto 10–30% em
  degraus de 5, preço derivado da âncora viva do catálogo (`ChestCostGems`,
  `VIP1CostGems`). O carimbo "uma vez por (dia,slot)" NÃO nasce tabela: é o
  recibo do ledger (`flash:<dia>:<slot>`) relido dentro do funil que cobra —
  append-only, sobrevive a restart, e a tela pinta o `claimed` que o servidor
  derivou, sem re-derive nenhum. A previsibilidade aqui É o produto (vitrine é
  anúncio, não loot) — o comentário do arquivo registra por que isso não é o
  P1-F. Régua congelada em dias FIXOS (1000×1001) para a régua não virar mina de
  calendário. UI no regime runtime do vendor (`FlashBox` sem .tscn), confirmação
  com preço citado antes do RPC (portão do `spend_confirm_test`), reasons todos
  com linha velha no catálogo (`unknown_offer`/`already_claimed`/
  `insufficient_gems`) — zero vocabulário novo de toast.
- Veredites do lote (métricas honestas, §24-8): `run_idle_tests` 3517 checks / 0
  failures (as três suítes novas: perks, flash, censo do passe);
  `season_liveops_test` 182/0 com o espelho novo; `test_push` 30/0,
  `test_webhook` 207/0 pós-fatiamento; `economy_design_fix` verde com a trilha
  cheia; `repo_layout_test` 61/0 com a entrada podre da cerca removida; portões
  de estrutura: god-nodes 433 arquivos / 0, doc-drift 2582 / 0 (13 ponteiros
  re-ancorados nas ondas companion/Network/Server), write-funnel 13/0,
  dead-code 14/0, untracked 5/0 (072 no índice). Sweep completa do lote (2026-10-07, máquina quieta após o jogo do dono fechar): SWEEP-EXIT=0, zero gates vermelhos, zero ruído. Nota honesta das
  duas varreduras anteriores: com o desktop sob 618% de CPU externa o `benchmarks` estourou o p99 (5,09× normalizado contra teto de 4×) e na
  primeira quieta `economy_knob_range_test` sorteou dois crashes de engine (SIGSEGV no `parse_string` de lixo sintético — caminho pré-lote, nenhum
  byte meu; no isolamento seguinte morreu uma vez e passou na retomada, classe FLAKES da casa). Nenhum dos dois virou afrouxamento: rodou-se de novo.
- Resíduo declarado: a trilha S2 declarada em `seasons.json` mantém os 5 níveis
  próprios (não é espelho; sparse por decisão de live-ops, não por acidente — e
  o censo "sem buraco" do M-1 é DO CATÁLOGO, a régua de espelho continua sendo a
  suite A); a venda de perks no painel ainda não filtra por `my_rank` na hora de
  desenhar (o servidor recusa `perk_leader` com toast, a tela é espelho do
  estado, não a decisão); o push de campanha mede antecedência só na janela de
  24 h padrão do tick — afinar por evento é decisão de ops futura; o `boon` é
  multiplicador de settle e por isso entra nos censos de faucet das suítes de
  economia (nada fixou número absoluto — as réguas derivam do catálogo).
