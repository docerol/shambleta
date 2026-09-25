# AUDITORIA INDEPENDENTE — SHAMBLETA (SOM-IDLE)
**Data:** 2026-09-24 · **Escopo:** repositório completo (344 arquivos `.gd`, 53.267 linhas; 10 `.py`) · **Método:** auditou read-only; as passadas de conserto que vieram depois (itens (m) a (t), §24) **alteraram código e suíte** — cada afirmação vale para o estado medido na linha do tempo em que foi escrita
**Pergunta central:** quão perto o Shambleta está de ser um jogo comercial competitivo, sustentável, seguro, escalável, divertido e capaz de gerar receita?

Marcações de evidência usadas em todo o documento: `[CÓDIGO]` confirmado no código · `[TESTE]` confirmado por execução minha ou do suite · `[DADO]` fonte externa nomeável · `[INFERÊNCIA]` conclusão derivada, não medida · `[HIPÓTESE]` não confirmado — **não reduz nota**.

---

## 1. SUMÁRIO EXECUTIVO

O Shambleta **não é um MMO idle promissor com problemas de acabamento**. É um **núcleo idle matematicamente honesto e server-authoritative, preso dentro do shell de um MMO de 2011, com a camada de identidade quebrada e o caminho do dinheiro interrompido por um detalhe de configuração**.

Quatro fatos definem o estado atual:

1. **A identidade de quem chama é fornecida por quem chama.** 100 das 101 RPCs chamáveis pelo cliente terminam em `peerID : int = NetworkCommons.PeerAuthorityID` — um argumento vindo do pacote. Não existe **nenhuma** chamada a `get_remote_sender_id()` em `sources/`. `[CÓDIGO]` Um cliente malicioso pode apagar conta, estornar compra, agir no chat e executar comandos GM **como qualquer jogador online**. Nada no sistema impede isso. Esta é a nota 2,5/10 em segurança e é o motivo pelo qual o beta não pode abrir.

2. **Se um jogador pagasse hoje, não receberia nada.** O servidor abre `testing.db` e o companion grava o grant em `live.db`. `[CÓDIGO]` A feature `production` não está em **nenhum** dos 7 `export_presets.cfg`, e o `Dockerfile` não a injeta. Isso é independente da chave do Mercado Pago faltar. É silencioso, não crasha, e nenhum teste cobre o boot de produção.

3. **O produto real é menor que o produto documentado.** Temporada e Battle Pass — a espinha de retenção sazonal escrita no repositório — estão **desligados** por `const`. Anúncios são **stub mintável pelo client**. Bots do leilão estão **OFF**. Live events têm **mecanismo e zero dados semeados** (nunca disparam). Torneio/arena só nascem depois do job de 24h acoplado ao backup. Para o jogador de uma instalação padrão, essas features **não existem**. `[CÓDIGO]`

4. **A documentação interna perdeu valor como evidência.** `AUDITORIA_SHAMBLETA.md` atribui **9,5/10 a Testes** citando `tests/gut_runner.gd`, que imprime um resultado fabricado (`1193 checks` hardcoded). A mesma auditoria cita `NetworkAuth.gd` e `NetworkSocial.gd` como prova de design — **os arquivos não existem**. `architecture.md` documenta 7 autoloads inexistentes, incluindo um `MetricsServer.gd` que só existe como `.uid` órfão — e é exatamente para a porta que esse servidor fictício escutaria que o healthcheck do Docker aponta, permanentemente falso. `[CÓDIGO]`

**E o que está certo é sério:** settle offline idempotente e determinístico dentro de transação com âncora relida; ledger append-only imposto por trigger no banco; fronteira de pagamento com HMAC constant-time, re-fetch autoritativo e idempotência por `idempotency_key`; LGPD comportamental de verdade; 1329 checks que passam de fato; zero segredos commitados; e uma disciplina de fairness rara — **não existe botão compra-poder**: favores se pagam com essência, não com gems. `[CÓDIGO]` `[TESTE]`

O risco do projeto não é falta de competência de engenharia. É que **a engenharia foi aplicada em um shell que não é o jogo que se quer vender**, e que a autoavaliação anterior mediu intenção em vez de comportamento.

**Notas consolidadas:** técnica **5,0** · produto **5,1** · potencial comercial **5,0** · prontidão para beta fechado **2,5**.

---

## 2. METODOLOGIA, FERRAMENTAS E LIMITE DE EVIDÊNCIA

- **Graphify** (v0.9.63) foi usado, conforme exigido. Resultado: o grafo exportado (`graph.json`, 1106 nós) contém **zero nós `.gd`** — a ferramenta extrai Markdown e Python, e **não suporta GDScript**. Reproduzi a limitação num diretório isolado com um `.gd` de teste. `[TESTE]` Consequência: o mapa de módulos, dependências e fluxos foi reconstruído por leitura direta e busca textual, não por grafo. É um limite real desta auditoria, declarada para não sugerir cobertura que não houve.
- **Execução, não leitura, onde era verificável:** suíte idle completa (`1329 checks, 0 failures`, exit 0, ~11 min), benchmarks, teste de reentrância de `Mutex` em probe descartável em `/tmp`, extração real do relatório i18n.
- **Decomposição em 7 trilhas** (segurança, economia, design/retenção, monetização, arquitetura, qualidade operacional, comunidade/concorrentes), com as alegações de maior peso **re-verificadas por mim no arquivo-fonte** antes de entrar no scorecard. Duas alegações de subagentes foram **rebaixadas** por não sustentarem o alcance afirmado (telemetria de conversão "invisível" — na prática derivável por SQL; "exploit do baú" — a semente é previsível, mas o ganho econômico não se confirma).
- **Comunidade:** sentimento triangulado por múltiplos fóruns com tamanho de amostra e força declarados (`[isolada]`/`[recorrente]`/`[consenso aparente]`/`[dado]`); nenhum post tratado como "a comunidade pensa X". Números quantitativos só de fontes nomeáveis. Scraping direto de Reddit e parte do `WebFetch` estavam bloqueados; o que não pôde ser lido está declarado como não lido.
- **O que esta auditoria NÃO fez:** nenhum teste de carga com clientes reais; nenhuma exploração ao vivo de V1 (a classificação é `[CÓDIGO]` para o vetor, `[INFERÊNCIA]` para o resultado exploratório); nenhuma medição de eCPM/receita; nenhuma análise jurídica — o risco legal da §21 exige parecer de advogado.

---

## 3. O QUE O SHAMBLETA É, DE FATO

| Dimensão | Documentado | Entregue por uma instalação padrão |
|---|---|---|
| Gênero | MMO social + idle | **Idle de um jogador com chat MMO por cima** `[CÓDIGO]` |
| Jogo | combate, mundo, guilda, leilão, temporada | **farming autônomo + 1 micro-decisão real** (janela de interrupt do boss, ciclo 3,0s / janela 1,2s) `[CÓDIGO]` |
| Login | sessão | `AutoFarmOnLogin` já coloca o char na zona 1 farmando — **login é farmando** `[CÓDIGO]` |
| Input ativo | agência | manual **pausa** a policy (`NoteActivity`) e retoma após 10s → jogar ativo não aumenta renda de farm `[CÓDIGO]` |
| UI | 8 janelas essenciais | shell de **~24 janelas** de MMO carregadas (`Gui.gd:129-151`), muitas em hotkey `[CÓDIGO]` |
| Mercado | Grand Exchange | **comandos de texto** `/ah list|buy|cancel|browse`; a janela é read-only e o próprio `Gui.gd:681` diz "UI gráfica em desenvolvimento" `[CÓDIGO]` |
| Moeda na UI de leilão | gems | o preço exibido é `price_gold` rotulado como **"gems"** (`AuctionHouseWindow.gd:_render_list`) `[CÓDIGO]` |
| Temporada/Passe | implementado | **OFF** (`SeasonsBetaLock=true` + env) `[CÓDIGO]` |
| Anúncios reward | portais | **stub**, token `stub:<placement>:<dia>` mintável `[CÓDIGO]` |
| Cobrança | Mercado Pago pronto | **0 entregue**: arquivos de banco diferentes `[CÓDIGO]` |

Licença: código MIT, **arte CC BY-SA 4.0** (share-alike) — conflita com conteúdo proprietário novo e é risco reputacional com a base do fork de origem (`sourceofmana`, ~6 contribuidores, ativo). `[DADO]`

---

## 4. SCORECARD — 20 CATEGORIAS (0–10)

| # | Categoria | Nota | Base do cálculo (critérios 0–2 somados) |
|---|---|---|---|
| 1 | Core Gameplay | **6,0** | execução/autoridade 2 · feedback 1,5 · gênero legível 1,5 · **agência 0,5** (só o interrupt) · polish 0,5 |
| 2 | Core Loop | **7,0** | loop curto 1,5 · médio 1,5 · longo 2 · recompensa offline 2 · motivo de retorno 0,5 |
| 3 | Meta Game | **4,0** | amplitude 1,5 · **disponibilidade real 0,5** (seasons/pass OFF, events sem dados, bots AH off, ads stub) · endgame 1 · diferenciação 1 |
| 4 | Retenção | **4,0** | D1 1,5 · D7 1 · D30 0,5 · social 0,5 · sazonal **0,5** |
| 5 | Game Design | **6,5** | curva matemática 2 · antiburnout provado 1,5 · balanceamento 1,5 · conflito MMO×idle 0,5 · legibilidade dos números 1 |
| 6 | Economia | **6,0** | anti-duplicação 1,75 · anti-RMT 1,75 · invariância de ledger 1 · atomicidade 1 · **sustentabilidade macro 0,5** |
| 7 | Monetização | **4,0** | infraestrutura 2 · catálogo 1,25 · **capacidade de cobrar-e-entregar hoje 0** · mensurabilidade 0,75 · agilidade de preço 0,5 |
| 8 | Marketplace | **4,0** | escrow/segurança transacional 1,75 · liquidez 0,5 · UX transacional 0,5 · proteção ao comprador 0,75 · governança de preço 0,5 |
| 9 | Segurança | **2,5** | SQL limpo 2 · fronteira de pagamento 2 · auth/lockout/LGPD 1,5 · **integridade de identidade do chamador 0** · primitivas 2FA/ads 0,5 |
| 10 | Arquitetura | **7,0** | server-authority 2 · transports/AOI 2 · persistência/migrations 1,5 · **acoplamento 0,5** · modelo de concorrência 1 |
| 11 | Performance | **6,0** | contenção por AOI/dirty-check 1,5 · SQLite WAL bem configurado 1,5 · **medição representativa 0,5** · burst de escrita 0,5 · mobile/web 0,5 |
| 12 | Escalabilidade | **4,0** | 200–1k CCU viável 1,5 · custo marginal por jogador 1,5 · **horizontal 0** (1 processo, 1 writer, world in-memory) · isolamento de falha 0 · caminho de evolução 1 |
| 13 | UX/UI | **4,0** | essencial-8 correta 1,5 · onboarding 1 · densidade adequada 0,5 · **honestidade dos números exibidos 0** · **botões mortos visíveis 0,5** · mobile/i18n 0,5 |
| 14 | Social | **4,5** | infraestrutura 1,5 · canais/Discord 1 · **segurança do canal 0** (BBCode injetável, sem cap de tamanho, sem filtro/denúncia) · ferramentas de moderação 1 · efeito mensurado 0,5 |
| 15 | Live Ops | **3,0** | jobs reais 1 · conteúdo operacionalizável 0,5 · **mudar preço/evento sem rebuild 0** · ferramentas de operador 1 · capacidade de A/B 0,5 |
| 16 | Analytics | **4,0** | eventos de produto 1 · funil 1,25 · **receita em dinheiro 0,75** · infraestrutura de coleta 1 · dashboards/alertas 0 |
| 17 | Testes | **6,5** | suíte real verde auto-verificável **2** · cobertura de economia/idle/LGPD/refund 1,75 · **cobertura de segurança/rede 0** · honestidade dos artefatos 0,5 · ponta-a-ponta de pagamento 0,5 · concorrência/crash 0,5 → 5,25/10 normalizado a 6,5 pela profundidade do que existe |
| 18 | DevOps | **3,0** | deploy/rollback/ofsite 1,5 · segredos 1,5 · **liveness 0** · **configuração de ambiente que entrega 0** · observabilidade 0 · staging 0 · reversão de schema 0 |
| 19 | Código | **6,0** | consistência 1,5 · gates de qualidade 1,5 · refactor sem quebrar callers 1,5 · **dead code/stubs 0,5** · acoplamento/service-locator 1 |
| 20 | Documentação | **3,0** | volume 2 · rastreabilidade de dívida 1,5 · **exatidão 0** · onboarding de dev 0,5 · docs de produto/jogador 0,5 · API/RPC 0,5 |

---

## 5. AS 4 NOTAS GERAIS E COMO FORAM CALCULADAS

**Técnica = 5,0** — média aritmética simples das 7 categorias técnicas, sem ponderação para não esconder a de segurança: (2,5 + 7,0 + 6,0 + 4,0 + 6,5 + 3,0 + 6,0) ÷ 7 = **5,00**.

**Produto = 5,1** — média das 7 categorias de experiência: (6,0 + 7,0 + 4,0 + 4,0 + 6,5 + 4,0 + 4,5) ÷ 7 = **5,14**.

**Potencial comercial = 5,0** — parte do estado atual e parte do teto, separados porque a diferença entre eles é o trabalho:
estado comercial hoje = (Economia 6,0 + Monetização 4,0 + Marketplace 4,0 + Live Ops 3,0 + Analytics 4,0) ÷ 5 = **4,2**;
**+1,8** por diferenciais estruturais verificados: save server-side cross-platform (o que Melvor não tem), economia de jogador com escrow (o que AFK não tem), ausência de gems→poder (o que Raid queimou), fronteira de pagamento já testada e HMAC-segura, precificação em R$ compatível com PIX (76% dos consumidores brasileiros) `[DADO]`;
**−1,0** de risco não resolvido: enquadramento legal de baú pago com item negociável (§21) e recepção hostil provável da base FOSS de origem `[INFERÊNCIA]`.
→ 4,2 + 1,8 − 1,0 = **5,0**.

**Prontidão para beta fechado = 2,5** — média ponderada pela dependência de operação real: Segurança ×3 (2,5), DevOps ×2 (3,0), Monetização ×2 (4,0), Produto ×1 (5,1), Testes ×1 (6,5) = (7,5 + 6,0 + 8,0 + 5,1 + 6,5) ÷ 9 = **3,68**; redutor de **−1,2** porque dois desses P0 (identidade do chamador e entrega de pagamento) **não são corrigíveis por configuração nem contornáveis por operação manual** — um beta aberto com eles presentes vaza dados e cobra sem entregar. → **2,5**.

---

## 6. CORE GAMEPLAY E CORE LOOP

**O jogo.** `IdlePolicy` é uma FSM IDLE→SEEK→COMBAT→LOOT→DEAD com substep fixo de 0,25 s de jogo. Ela farma a zona salva sozinha e produz XP/ouro/drops/chaves. Ao logar, `AutoFarmOnLogin` já coloca o personagem na zona 1 farmando. `[CÓDIGO]`

**A única decisão que altera resultado** é a janela de interrupt do boss — ciclo 3,0 s, janela 1,2 s, gerando `InterruptBonus` (`IdlePolicy.gd:85-86, 331-341`). É uma escolha de design **certa**: dá um skill-check real num gênero que normalmente não tem nenhum. Mas é também a única. Os botões "manuais" do HUD são Melee/Run e atalhos de janela, e input manual **pausa** a policy por 10 s (`IdlePolicyService.gd:198-241`). Corolário desconfortável e verificável: **jogar ativo não aumenta a renda de farm** — o jogo é tão bom ou melhor jogado desligado. `[CÓDIGO]`

**Loop médio** (sessão): coletar relatório AFK → abrir baús (pity determinístico a cada 10) → subir zona até o gate de `minPower` → gastar chaves de boss. **Loop longo** (dias/semanas): cap L60 → XP excedente vira essência → favores (`favor_xp`/`favor_gold`/`attune_offline`) compõem renda a 1,05^n contra custo 1,7^n → renascimento; Torment (cap 10) e BossRush escalam o mesmo eixo. `[CÓDIGO]`

A arquitetura do loop é honesta e o warm-start é excelente — você já está ganhando no primeiro segundo, e o relatório offline é determinístico (sem RNG no caminho golden). O que falta é **variedade**: não há segundo jogo dentro do jogo, e não há relógio que mude o que vale a pena fazer. Nota: Core Gameplay **6,0**, Core Loop **7,0**.

---

## 7. META GAME E RETENÇÃO

**O achado central da retenção não é ausência de feature — é feature boa desligada.**

| Sistema | Estado para o jogador | Evidência |
|---|---|---|
| Farm idle + offline settle | ON | núcleo |
| Rebirth / essência / favores | ON | `RebirthData.gd` |
| Boss ladder + interrupt | ON (**só 4 bosses**) | `BossService` |
| Baús + pity | ON, odds públicas | `TradeChestService` |
| VIP (caps 12/24/36 h, ×1,2) | ON | `OfflineSettle.gd:13-23` |
| Anúncios reward | ON mas **stub** | `EconomyCatalog.gd:262` `[CÓDIGO]` |
| Auction House | ON p/ jogadores, **bots OFF** | `SHAMBLETA_AH_BOTS` |
| Torneio / arena ELO | ON, **mas criado só pelo job de 24 h** | `TournamentArenaService.gd:136-260` |
| Guildas (pontos, buff 2%/nível) | ON | `GuildService` |
| Live events (`weekend_drops`, `smith_week`) | **mecanismo ON, zero dados semeados → nunca dispara** | `CommunityService.gd:18-88` `[CÓDIGO]` |
| **Temporada + Battle Pass** | **OFF por padrão** → `GetSeasonPass()` = `no_season` | `SeasonService.gd:27-30`, `SeasonsBetaLock=true` `[CÓDIGO]` |

Achado adicional de acoplamento `[CÓDIGO]`: torneio, arena, live events, referral, fraud-scan e ciclo de temporada rodam **dentro do job de backup diário** (`SQLBackups.gd:101-107`, guarded por `if not backupFilePath.is_empty()`). Numa instalação nova o `lastDailyBackupTimestamp` inicia em "agora" → **nenhum torneio ou ticket de arena existe nas primeiras ~24 h de uptime**, e se o backup for desativado ou falhar, **toda a rotação meta para**. Meta-sistema dependente de uma tarefa de backup é um risco de operação, não de design.

Contra as metas declaradas quando esta linha foi escrita (**D1 ≥ 35%, D7 ≥ 20%, D30 ≥ 8%** — a
régua de `ROADMAP_COMERCIAL.md` daquela época; hoje o arquivo bate em **D1 ≥ 27%, D7 ≥ 7%,
D30 ≥ 4%** em `ROADMAP_COMERCIAL.md:28`, reescrita pelo item 6 do §24): os benchmarks medidos de 2025 (GameAnalytics, 11.600 jogos / 1,48 bi MAU) dão mediana D1 22% e D7 3,4–3,9%; **topo de quartil** D1 25–33% e D7 7–8%, D30 single-digit `[DADO]`. As metas internas estão **2,5× acima do percentil topo medido em D7**. Isso não é um bug — é um alvo que, se mantido, vai fazer um beta bom ser julgado como fracasso, e se perseguido com UA pago não fecha: com CPI casual ~US$1,50 e D30 3,5%, o custo por jogador-vivo já é ~US$43 com ROAS D30 de casual ≈ 1/7 `[DADO]`. Leitura correta: **o beta deve ser organic-first e a régua deve ser reescrita antes de abrir.**

D30 hoje, numa instalação padrão, é essencialmente o D1 com números maiores: a esteira de rebirth continua rodando, mas o andaime sazonal, os eventos e a competição ou estão desligados ou dependem de um operador semear conteúdo. Meta Game **4,0**, Retenção **4,0**.

---

## 8. GAME DESIGN — CURVA E NÚMEROS

Aqui o projeto é genuinamente bom, e é importante dizer com números.

XP(L→L+1) = `round(8000 · 1,22^L)`, `MAX_LEVEL = 60` → cumulativo até L60 ≈ **5,5·10⁹ XP** `[CÓDIGO]`. A renda satura na **zona 24** (`ZONE_COUNT = 24`): `xpPerKill = round(1200 · 1,25²³) ≈ 203k`, e o par offline da zona é `round(3600/(24+0,9·23)) = 80 kills/h` `[CÓDIGO]`.

**Divergência documentada confirmada:** a documentação usa "20,1M XP/h" e comentários de código dizem "96/h na z24" — o `96` contradiz a própria fórmula da linha acima (80), e o "20,1M" é vazão **online medida**, não renda offline. Offline real ≈ 203k × 80 × 0,6 × eficiência × mods, ou seja **~48–60% da vazão online**. `[CÓDIGO]` Uma promessa de marketing nesse padrão cria exatamente a sensação de "penalidade por dormir" que o dossiê de comunidade registra como motivo de abandono `[recorrente]`.

O ciclo de renascimento é **17–21 dias** no ciclo 1 e a série **converge em ~3,5 meses**, pela razão 1,05^n (bônus compõe a renda) contra 1,7^n (custo cresce mais rápido) — e **não converge a zero**, isto é, não há burnout geométrico `[CÓDIGO]`. Essa é a matemática de prestígio correta: cada ciclo acelera, que é a condição documentada para prestígio ser aceito pela comunidade `[recorrente]`.

Estimativa de parede final `[INFERÊNCIA sobre a curva + vazão]`: L10 em minutos/horas (newbie ×5 até L10/48h + auto-farm), L30 em ~2–4 dias, **L60 em ~2,5–3,5 semanas**, primeiro renascimento ~3 semanas. O último nível (L59→60) custa ~1,0·10⁹ XP ≈ 60 h online — existe fricção no fim, mas ela é o gatilho do prestige, não um muro morto. Custos e recompensas são coerentes em toda a parte: taxa de morte 5% + `session_efficiency` −0,05/morte com piso 0,5, corrupção/craft 500×tier², pity provably-fair com snapshot.

Game Design **6,5**. Perde ponto apenas onde o design entra em conflito consigo mesmo: um shell de MMO com 24 janelas, hotkeys F2/F6 e comandos de texto montado sobre um núcleo que se joga sozinho.

---

## 9. ECONOMIA E ANTI-EXPLOIT

Analisada como sistema ao longo do fluxo completo (aquisição → armazenamento → transformação → transferência → venda → compra → retirada → destruição), não endpoint por endpoint.

**Ouro** (`stat.gp`, por personagem) — faucets: kills live (z1 ≈ 22,5k/h; z24 ≈ 2,4M/h), settle offline com caps 12/24/36 h e newbie ×5, boss +30% na fronteira. Sinks: morte, corrupção/craft (500×tier²), chave de boss (10.000), guilda (5k + níveis até 10M), torneio (1k). **AH e trade não queimam ouro.** Rebirth preserva `gp`.

Sustentabilidade `[CÓDIGO + aritmética]`: em endgame com 16 h online + 8 h offline×0,6, a emissão é ≈ **49M ouro/semana** contra queima recorrente de ≈ 3,1M → **razão de reposição ≈ 0,06**. Não é um bug pontual: é **inflação estrutural por construção**, porque o único sink proporcional à renda é a taxa de morte. O AH — que num MMO sério é o grande queimador de ouro — queima **zero**. Correção de maior alavanca: taxa de venda do AH em ouro, queimada, 1–2% (proporcional ao volume, auto-estabilizante).

**Gemas** (`wallet.gems`, por conta, 100% com ledger) — faucets: compras (550/1200/3000), passe free 100/temporada, conquistas 450 one-shot, prêmios de temporada/torneio, referral 200±200. Sinks: baú 120, VIP 440/880, trade 10, listagem AH 5, reroll 20, boss pack 240, finale 400, skip 50×(n+1), slot de vault 200. Anúncios **não dão gems**. Para F2P a moeda é quase neutra (acumula pouco); para pagante a banda 0,8–1,2 da `ROADMAP_COMERCIAL.md:56` é atingível — mas **não verificável sem telemetria de produção**, o que é um problema de medição, não de design.

**Integridade de estado — o que a auditoria encontrou:**

| # | Achado | Classificação | Severidade |
|---|---|---|---|
| E1 | Ouro/XP dos caminhos **live** nunca entram no `ledger_transaction`; o `ReconcileDaily` **não confere ledger×gp apesar do comentário prometer** (`TournamentArenaService.gd:264-288` só confere saldos negativos e lots≡agregado) → divergência invisível a qualquer job | `[CÓDIGO]` | Média — não duplica nada, mas cega a detecção de trapaça em ouro |
| E2 | Forge/cube consomem `item_instance` (lots) **sem baixar o agregado `item.count`** → contagem fantasma detectada e nunca reparada | `[CÓDIGO]` | Baixa — **não é duplicação**: escrow do AH e do trade consome por lot, então o stock fantasma não vira item vendável |
| E3 | `ProcessPendingGrants`: `Transaction()` aplica o grant na linha 118 e o `UPDATE ... status='processed'` roda na **119, fora da transação** → se o processo morre na janela, o grant é reaplicado no boot | `[CÓDIGO]` | **Alta no caminho pago**: crash + restart = gemas em dobro para 1 pagamento. Janela estreita, mas é dinheiro |
| E4 | Reroll e VIP pagos não-atômicos (`ShopService.gd:118-138`, `CheckoutService.gd:19-33`) | `[CÓDIGO]` | Média — perde o jogador, não lucra o atacante |
| E5 | Semente do baú **sem segredo**: `serverSeed = "<chestID>:<created_at>:shambleta"` (`TradeChestService.gd:120`), e `created_at` já é devolvido ao cliente em `GetClosedChests` (`SQL.gd:777`) → o roll é função determinística de valores enumeráveis | `[CÓDIGO]` p/ a previsibilidade; `[INFERÊNCIA]` p/ o ganho | Média como honestidade (chamar isso "provably fair" não se sustenta), **baixa como exploit**: baú é grant gratuito que se abre de qualquer forma, e o pity é obtido independentemente da ordem |
| E6 | Corrida de essência em `BuyRebirthUpgrade` | `[HIPÓTESE]` | Inerte hoje — a serialização global do `Transaction()` fecha. **Não reduz nota** |

**O que NÃO encontrei, e importa:** nenhuma duplicação de item (trade e AH são all-or-nothing numa transação única com fee queimada antes da entrega); nenhum self-buy/self-trade (bloqueados); nenhum montante negativo ou count ≤0 (validados em todas as entradas); nenhum overflow de int64 alcançável; nenhum parâmetro de outcome forçado (`Corrupt`/`Cube`/`Salvage`) alcançável pelo cliente — o `force` não é passado dos handlers; `RunFraudScan` roda de fato no job diário e marcou 17 contas na execução de teste `[TESTE]`. O `balance_after` do ledger está correto dentro das transações.

Um ponto técnico que impede alarme falso: confirmei por probe que `Mutex` nesta build do Godot 4.7 é **reentrante na mesma thread** `[TESTE]` e que não há `await` em nenhum arquivo de `sources/economy/`. Portanto o aninhamento `Transaction → OfflineSettle → GuildSettle → ExecuteBindings` **não deadlocka** — mas sobrevive por acidente, não por projeto. Não classifico isso como bug.

Economia **6,0**: forte contra duplicação, fraco contra inflação, cego na auditoria de ouro.

---

## 10. MONETIZAÇÃO

**A infraestrutura é boa. O que falta não é código — e o que falta em código custa horas, não semanas.**

O fluxo ponta-a-ponta existe e é server-authoritative `[CÓDIGO]`: botão → `Network.GetCheckoutIntent` → `CheckoutService.GetCheckoutIntent` (valida SKU e elegibilidade one-time, devolve `external_reference = "<acct>:<sku>"`) → `POST /checkout/preference` no companion → preferência real no Mercado Pago → `init_point` abre no client → webhook assinado valida HMAC + anti-replay, **re-busca o pagamento na API do provedor**, exige `approved`, e faz `INSERT OR IGNORE INTO grant_queue`. Preço e grant vêm **do catálogo, nunca do corpo do webhook**. O jogo consome a fila a cada ~30 s. `companion/test_webhook.py` cobre assinatura MP/Stripe, replay, approved→grant, idempotência e one-time, e eu confirmei a execução dos três suítes standalone (`COMPANION 75/0`, `SECURITY 25/0`, `REFUND CLI 12/0`) `[TESTE]`. Isso é uma fronteira de dinheiro melhor do que a média de um indie em estágio beta.

> **Re-medido no fim da passada (2026-09-24, depois dos achados (h) e (i) de §24):** os
> três suítes python fecharam em `COMPANION 100/0`, `SECURITY 47/0`, `REFUND CLI 12/0`. E
> a frase "preço e grant vêm do catálogo" tinha uma ressalva que não estava escrita aqui:
> vinham do catálogo **por membership no dict**, e o mesmo dict carrega as chaves de
> comentário do arquivo. Até o achado (i), um `sku: "_agreements"` montava preferência de
> `unit_price` 0.0 no provedor e um `sku: "_note"` derrubava o handler sem resposta.
> Continua server-authoritative — o cliente nunca mandou preço — mas "não injetável" não
> é o mesmo que "não cobrável em R$ 0,00".

**Os quatro bloqueios, em ordem de gravidade:**

1. **O grant não chega.** `[CÓDIGO]` `LauncherCommons.gd:23`: `IsTesting = not OS.has_feature("production")`. Nenhum dos 7 presets em `export_presets.cfg` declara `custom_features="production"` (todos `""`), e `deploy/server/Dockerfile:31` é `CMD ["/app/Shambleta.x86_64", "--server"]` sem injetar feature. Logo o servidor abre `user://testing.db` (`SQLCommons.gd:47`), enquanto `deploy/companion/Dockerfile:20` abre hardcoded `.../app_userdata/Shambleta/live.db`. O volume é compartilhado (`deploy/docker-compose.yml`, comentário "MESMO volume do game") — **o nome do arquivo é que diverge**. O `grant_queue` escrito pelo companion nunca é lido pelo jogo. Silencioso, sem crash, sem teste que o pegue.
2. **Mesmo sem isso, não se cobra: `SHAMBLETA_MP_ACCESS_TOKEN` está vazio no compose** (fail-closed → 503) `[CÓDIGO]`. É onboarding de conta PJ, não engenharia.
3. **SKU morto:** `pass.s1` existe no `companion/catalog.json` mas **não** no `SHOP_CATALOG` do jogo (`EconomyCatalog.gd:65-74` traz só `.deluxe`) → `GetCheckoutIntent("pass.s1")` responde `unknown_sku`. `[CÓDIGO]` O passe padrão é incomprável pelo client. Correção de uma linha.
4. **Catálogos divergindo:** `vip.1mo` a **R$24,90** no código contra R$14,90 no ROADMAP; `pass.s1` R$24,90 contra R$19,90 no ROADMAP; `AHListFeeGems=5` contra "10 flat" no ROADMAP. `[CÓDIGO]` O preço que o jogador vê é o do client, o que o companion cobra é o do `catalog.json` — dois artefatos mantidos em sincronia manual.

**Tabela de SKUs reais:** `gems.550/.1200/.3000` R$19,90/39,90/79,90 · `vip.1mo` 24,90 · `vip.3mo` 59,90 · `starter.pack` 9,90 one-time D0–D3 · `founder.pack` 39,90 one-time · `pass.s1` 24,90 **(quebrado)** · `pass.s1.deluxe` 44,90 · `donate.support` 4,90. A curva escalona bem (R$/gem 0,036 → 0,033 → 0,027, −26% no topo), existe entrada barata (R$4,90/R$9,90) e existe segunda compra porque gems são sink recorrente. Falta um ímã de *primeira* compra de gems.

**Fairness — é P2W?** Não no sentido competitivo, e isso é verificável `[CÓDIGO]`: VIP dá cap offline 12→24→36 h, fator ×1,2, trade diário 20→40 e 2× nos prêmios de anúncio. **Favores (`favor_xp`/`favor_gold`) não são compráveis com gems** — custam essência, que vem do overflow de XP. Não existe botão gems→poder. Pior caso quantificado: logar 1×/dia com cap 36 h vs 12 h = 3× de coleta, ×1,2 de taxa → **~3,6× rendimento idle**, uma vantagem de progressão em semanas, não de ranking. O VIP é comprável com gems ganhas (440g), então um F2P dedicado chega lá de graça. Verifiquei também que a arena **não** multiplica poder por VIP — só concede tickets extras (`TournamentArenaService.gd:29-51`), o que honra a exigência da comunidade `[recorrente]`.

Ressalva honesta: parte da comunidade idle lê "VIP multiplica a velocidade de coleta" como P2W disfarçado de QoL `[consenso dividido]`. A defesa não é técnica, é de comunicação — e depende de o cap free ser generoso (ver §22).

Monetização **4,0**: infraestrutura 2/2, mas **zero** de capacidade real de cobrar-e-entregar e quase nada de mensurabilidade.

---

## 11. MARKETPLACE

Os primitivos são certos e os números são ruins.

**Certo** `[CÓDIGO]`: escrow por lot com cadeia `parent_uid`, entrega all-or-nothing numa transação, taxa de listagem 5 gems **+ creator fee 1%**, bot de estoque **finito e que nunca recompra** (portanto sink, não fonte), self-buy/self-trade bloqueados, `RunFraudScan` diário rodando.

**Errado:**
- **Não existe camada de rede.** Não há RPC de `list`/`buy`/`cancel` no `Network.gd`/`Server.gd`. `AuctionHouseService.ListItemForSale` existe como função e **não tem chamador externo**. A `AuctionHouseWindow.gd` declara isso no próprio cabeçalho ("Nota honesta: não há RPC de listagem no servidor") e o `Gui.gd:681` instrui o jogador a **digitar `/ah list`, `/ah buy`, `/ah sell`** porque a "UI gráfica [está] em desenvolvimento". Guilda tem o mesmo padrão: create/join/leave por comando. `[CÓDIGO]`
- **A janela erra a moeda:** `BrowseListings` seleciona `price_gold`, e `_render_list` imprime `"%s [%s] x%d — %d gems"`. O jogador lê "gems" onde é ouro. `[CÓDIGO]`
- **Liquidez nasce vazia:** os bots cobrem **6 consumíveis** (Apple→CactusPotion, 60–600 gold) e estão **OFF em beta**. Para equipamento, zero. Um mercado sem contraparte no primeiro dia não se recupera sozinho. `[CÓDIGO]`
- **Wash trade é detectado, não prevenido:** não há teto de preço nem appraisal por tier, então listar junk caro e comprar em ouro transfere valor por dentro do AH pagando só 5 gems + 1%. `[CÓDIGO]` p/ ausência do guard; `[INFERÊNCIA]` p/ prevalência.
- **Sem proteção ao comprador:** não há disputa, estorno de mercado, reputação nem histórico público de preço. `[CÓDIGO]`

Num idle onde 90% do público-alvo é navegador/Android e a conversão é baixa, um Grand Exchange textual é fricção em cima de fricção. **4,0**.

---

## 12. SEGURANÇA — 2,5/10

Tudo de bom primeiro, porque é real `[CÓDIGO]`: SQL param-bound em todo o DAO (as interpolações `IN (%s)` são listas de placeholders tipados, nomes de tabela são constantes, e o único `'%s'` externo vem de catálogo fixo validado por match exato antes do SQL — **não injetável**); fronteira de pagamento com HMAC `compare_digest`, anti-replay, re-fetch autoritativo e bind `auth_token→dono`; login com lockout/backoff, ban por conta **e** por faixa de IP, remember-me com hash+IP; nenhum segredo commitado; LGPD com consent, `ip_hash` e anonimização em `EraseAccount`; `_constant_time_equals` do TOTP é uma comparação constante de verdade.

**V1 — CRÍTICA — a identidade do chamador vem do chamador.** `[CÓDIGO]`

`Network.gd` expõe **101** funções `@rpc("any_peer", …)`; **100** delas terminam em `peerID : int = NetworkCommons.PeerAuthorityID`, ou seja, um valor lido do pacote. No servidor, `CallServer` (Network.gd:958-972) re-despacha `methodName` com `args + [peerID]` usando **esse** valor; `Interface.gd` faz `Network.callv(methodName, args + [peerID])` sobre `bulks[peerID]`. `Peers.GetPeer/GetAccount/GetCharacter/GetAgent/GetPermission` indexam `peers[peerID]` direto, e os ids dos peers são reais e sequenciais (atribuídos pelo transporte em `Server.gd:1208`), portanto **enumeráveis**. Contagem confirmada por mim: **130** resoluções de identidade `Peers.Get*(peerID)` em `Server.gd` e **zero** ocorrências de `get_remote_sender_id()` em todo `sources/`.

O caminho completo foi rastreado até o efeito, conforme exige o método:
`DeleteAccount` (`Server.gd:36-47`): `peer = GetPeer(peerID)` → `accountID = peer.accountID` → `SQL.EraseAccount(accountID)`.
`TriggerCommand` (`Server.gd:1194-1197`): `GetAgent(peerID)` → `CommandManager.Handle(player, command)`, executando `!ban` / `!permission` / `!item` / `!spawn` **com a permissão da vítima**.
`DeleteCharacter` (`:275`), `RequestRefund` (`:51`), `ArenaAttack` (`:909`), `ClaimOfflineSettle`/`ClaimAchievement` (`:404`, `:529`) seguem o mesmo padrão. O único portão é `Peers.Footprint(peerID, …)`, que também é chaveado no id spoofado — ou seja, o rate-limit **consome a cota da vítima**.

Nenhum outro subsistema impede isso: não há middleware de sessão, não há verificação de canal, e o `SetFormation` que acertou o ownership (`GetAccountIDForCharacter(charID) != accountID`, `:370`) prova que o padrão correto existe no código-base — só não é aplicado à identidade do chamador. Mitigações parciais: `ChangePassword` exige a senha atual (não vira takeover trivial) e as respostas RPC voltam ao `peerID` da vítima, o que limita **exfiltração** (essa parte fica `[HIPÓTESE]`: é preciso confirmar se o socket do impostor recebe a resposta). A **mutação** e a **impersonação** não são limitadas.

O exploit em si é `[INFERÊNCIA]` — não foi executado contra um servidor nesta auditoria, por estar em scope read-only. O **vetor** é `[CÓDIGO]`, e o vetor basta: não existe caminho de login que autentique o dono da conexão antes da ação.

**V2 — Janela TOTP ~±15 minutos.** `[CÓDIGO]` `TwoFactorAuth.gd:103-107`: `candidateCounter = baseCounter + drift * TOTP_STEP_SECONDS` e depois `GenerateTOTP(secret, candidateCounter * TOTP_STEP_SECONDS)` — mas `GenerateTOTP` já divide o timestamp por 30 internamente. O duplo escalonamento faz os contadores testados serem `base + {−30, 0, +30}` **steps**, com drift ∈ {−1,0,1}. Aceita códigos defasados ±900 s, com 3 contras simultâneas, onde a RFC 6238 pede ±1 step. Verifiquei linha por linha. Mitigado em parte pelo desafio single-use, expirado e vinculado ao peer (`Peers.ValidateTwoFactorChallenge`), que está bem feito — mas a primitiva está errada.

**V3 — Recompensa de anúncio mintável, e não é configurável.** `[CÓDIGO]` `EconomyCatalog.gd:262` é `const AdStubEnabled : bool = true` — **const, não env**. `_ValidAdToken` aceita `stub:<placement>:<dia>` (`AdsCosmeticsService.gd:36-43`), e o `AdProvider.ShowRewarded` chama `_MintStub` **mesmo no modo `portal`**, depois do callback do SDK: não existe prova de exibição verificável no servidor em nenhum dos dois caminhos. Um cliente forja o token e coleta o cap diário (1 baú / 2 chaves de boss / reroll / 2× AFK) sem ver anúncio. Não rouba dinheiro diretamente, mas destrói a segunda fonte de receita e faz o relatório de ads mentir.

**V4 — 2FA é inatingível.** `[CÓDIGO]` `Settings.gd:602/614/655` tem botões reais que chamam `Network.SetupTwoFactor` / `VerifyTwoFactorSetup` / `DisableTwoFactor`; os três `@rpc` existem (`Network.gd:86-96`); a persistência inteira existe (`SQL.SetTwoFactorSecret/SetTwoFactorEnabled/ConsumeTwoFactorToken`). **`Server.gd` não tem nenhum dos três handlers** — `ENetServer.callv("SetupTwoFactor", …)` cai num método inexistente. E `Settings.gd:599` ainda consulta `Launcher.SQL.IsTwoFactorEnabled(...)`, que é `null` num processo cliente (SQL só nasce em `Launcher.Server()`, `Launcher.gd:60-74`). Dois defeitos independentes no mesmo botão. Resultado: **ninguém consegue ativar 2FA no produto** — nem o staff, que é justamente a conta que a V1 torna valiosa.

**V5 — Chat interpreta BBCode de texto do jogador.** `[CÓDIGO]` Verificação própria: `Chat.gd:56` faz `tab.text += "[color=#" + cor + "]" + text + "[/color]"` com o texto cru do chat; as abas são instâncias de `ChatLabel.tscn`, que é `RichTextLabel` com **`bbcode_enabled = true`**. Então `[url=…]`, `[font_size=999]`, `[shake]`, `[rainbow]` de qualquer jogador são interpretados no cliente de todos os outros — phishing clicável e assédio visual, em canais local/global/whisper. Somando: `TriggerChat` (`Server.gd:1080-1094`) **não limita o comprimento** de `text`, não tem filtro de conteúdo, não tem ferramenta de denúncia, e o broadcast global amplifica o texto de um único peer. A V1 permite ainda enviar isso **como a identidade de outra pessoa**.

**V6 — menores.** `[CÓDIGO]` Não existe verificação de idade, gate 18+, nem restrição de acesso a menores no cliente ou no servidor. Relevante para a §21 e para a Play Store.

**Baixo/latente:** `ArenaBoardResult(..., defenderAcct)` em `sources/network/server/Server.gd:1005` roteia usando accountID como se fosse peerID (`[CÓDIGO]`, misroute/leak menor) — **corrigido em 2026-09-25**: o destino passou a sair de `Peers.accounts` e o board só é enviado quando o defensor está conectado; locks globais × por-shard protegendo o mesmo `wallet.gems` (`[HIPÓTESE]` de corrida — inerte enquanto a economia for single-thread, **não reduz nota**); o worker de backup chama `db.backup_to()` e `RunReconcileJob()` concorrentemente com `db.*` da main thread sobre o mesmo handle SQLite, área que `queryMutex` não cobre (`[INFERÊNCIA]`, janela diária de baixa frequência).

**Como a nota sobe:** (a) identidade derivada do transporte em um único ponto de despacho, com o parâmetro `peerID` **removido** das assinaturas `@rpc` — ~~removido~~ **media errado, desfeito por medição em 2026-09-25**: o parâmetro é o slot de identidade no fio e a aridade é o protocolo (ver linha 1 da tabela de itens do §24 e o item (6) da retificação do rodapé); o que fechou foi o guard, passado a casar o marcador do slot em vez do nome literal; (b) TOTP em ±1 step; (c) stub de anúncio por env com default false e SSV real; (d) handlers de 2FA escritos; (e) chat renderizado como texto, com cap de tamanho.

**V7 — o cliente desligava a verificação do certificado do servidor.** `[CÓDIGO]` Achado **depois** desta auditoria, na passada de beta (2026-09-24), e ela não está na lista acima nem em (a)–(e): `sources/network/client/Client.gd:779` montava `TLSOptions.client_unsafe()` e entregava a opção tanto a `create_client(url, tlsOptions)` (WebSocket) quanto a `currentPeer.host.dtls_client_setup(serverAddress, tlsOptions)` (ENet/DTLS). `client_unsafe()` desliga as duas conferências — cadeia contra CA confiável **e** hostname. No mesmo ramo, `_ValidateServerAuth` faz `multiplayerAPI.complete_auth(peerID)` sem nenhum teste criptográfico, ou seja, o `auth_callback` não cobria o buraco. Isto não é hipótese: é a opção que o código pedia, e a linha está no histórico desde `c727e69` (2026-08-14).

O efeito foi rastreado até o canal: pelos RPCs de auth viajam a senha do login, o token de "lembrar" e o código 2FA. Sem verificação de certificado, um MITM na rota (Wi‑Fi público, DNS envenenado, proxy corporativo) apresenta **qualquer** certificado, coleta a credencial e repassa o tráfego ao servidor real — o jogador loga e não vê nada. O servidor tinha (e tem) a defesa do outro lado (`RequiresTLS()` + hard‑stop do bind inseguro), o que torna o achado fácil de perder: a borda estava fechada, o cliente não. **Esta parte é argumento de semântica de API, não reprodução**: o colhimento por MITM não foi executado localmente, e nesta máquina ele não é reproduzível — ver a limitação medida abaixo. Corrigido por `NetworkCommons.ClientTLSOptions()` — `TLSOptions.client(âncora)` com o bundle de `OS.get_system_ca_certificates()` passado explicitamente, já que o `TLSOptions.client()` sem argumento falha nesta engine antes do handshake (`SSL module failed to initialize!`, `-0x6C00`); o hostname é derivado do URL pelo próprio Godot. Medido com fixture autoassinado: com a store do sistema como âncora a conexão é **recusada** (`-0x2700`/`-0x7180`) e o mesmo certificado é aceito quando vira a âncora — a verificação está viva e discrimina. No mesmo caminho, `client_unsafe()` também não completa aqui (mesmo erro de init, `-0x6C00`), o que é exatamente por que o buraco não se demonstra por reprodução neste build: ele se demonstra pelo que a API pede (`client_unsafe` desliga cadeia e hostname) somado ao `auth_callback` oco. Guard em `SuiteOpsA2`: varre os 279 `.gd` de `sources/` atrás de `client_unsafe` fora de comentário, inspeciona as opções TLS vivas (`not is_unsafe_client()`, âncora de CA presente) e confere que a opção chega aos dois transportes. Consequência documentada em `deploy/TLS.md` e `deploy/STAGING.md`: bind direto autoassinado passa a falhar de propósito no cliente.

**Estado dos itens acima na passada de beta (2026-09-24)** — V1 a V7 **têm correção em código neste repositório**, todas na suíte gated: identidade do chamador derivada do transporte (V1), TOTP ±1 step (V2), stub de anúncio por env com default false (V3), handlers de 2FA no `Server.gd` (V4), chat como texto puro + cap + denúncia/bloqueio server-side (V5), gate de idade com a cláusula 18+ como terceira do aceite e cobrada no login **e** no checkout (V6, migration `046_age_gate.sql`; a ressalva honesta — autodeclaração não é verificação — está em `deploy/LAUNCH_HANDOFF.md`), e verificação de certificado no cliente (V7). O que continua dependente de fora do código: conta PJ e chaves do Mercado Pago, e a parecer jurídico sobre baús.

---

## 13. ARQUITETURA E CÓDIGO

**Arquitetura 7,0.** Cinco autoloads (`project.godot:29-33`); `Launcher._ready()` decide cliente vs `--server`, fixa 30 fps/30 física e instancia os serviços de servidor. Um único processo headless atende todos os peers. O caminho do pacote é limpo e legível: transporte → `multiplayerAPI.poll()` → `@rpc` no `Network` → handler em `Server.gd` → serviço → `SQL.gd` → godot-sqlite → `live.db`, com egress coalescido por peer/frame em `Interface.bulks` (reduz syscalls). Três transports abstraídos atrás da mesma interface, AOI, settle rate-based (liquida em spikes de login/claim, não por kill), ledger append-only, **42 migrations versionadas** com índices 040/041/042 cobrindo os hot-paths reais. Isso é arquitetura competente para o porte.

O que cobra o desconto: service-locator onipresente (`Launcher.SQL` / `Launcher.Economy` alcançados de qualquer lugar, sem injeção — quase nada é testável isoladamente dos autoloads); acoplamento circular facade↔kernel (`EconomyKernel` depende de `_eco.settleMutex`, reconhecido em `ROADMAP_COMERCIAL.md:45`); e o **modelo de locks é decorativo** — o `settleMutex` global que `SettleTransaction` pegaria nunca é usado porque **`SettleTransaction` não tem chamadores** `[CÓDIGO]`, enquanto `Server.gd:312,413` chama `SettlePending` direto. A serialização real é "uma thread, um pacote por vez". Se um `await` entrar num handler, vira corrida de verdade.

**Código 6,0.** 344 arquivos `.gd`, 53.267 linhas. Consistência de estilo alta, `EconomyService` foi reduzido de 3.839 para 763 linhas em 12 fatias **sem quebrar chamadores**, e existe um gate ativo (`check_god_nodes.sh`, teto de 800 linhas com allowlist declarada de 6 arquivos) `[TESTE]`. Há até comentários de honestidade raros em código-próprio — o cabeçalho da `AuctionHouseWindow` admitindo a ausência de RPC.

Contra: cinco artefatos mortos confirmados `[CÓDIGO]` — `SQLCharacter.gd` com **todos os métodos `pass`** e nenhum referência (só `docs/development/architecture.md` o cita); `SettleTransaction` sem chamadores; `WebhookValidator.gd` stub (`return true if secret.length()>10`) fora do caminho real mas ainda assim anunciado como `webhook_verified:true` em `CheckoutService.gd:88`; `sources/system/MetricsServer.gd.uid` sem `.gd`; `tests/gut_runner.gd` fabricado. E `Monitoring.SetPlayer` é chamado em `Map.gd:125` **sem existir** em `Monitoring.gd` → erro de runtime no caminho do minimapa `[CÓDIGO]`.

**Estado dos números e dos artefatos acima na passada de beta (2026-09-24).** Este
§13 foi escrito contra a árvore de 24 de manhã e três das suas medidas já não são as
medidas da árvore: são **46 migrations** (não 42 — as quatro novas são
`043_chat_moderation`, `044_grant_price_paid`, `045_cohort_view`, `046_age_gate`),
`sources/sql/` tem **três** arquivos (não "facade + 10 módulos"; a fragmentação P4
foi revertida em `bd69275` porque os `@rpc` do motor precisam viver no autoload), e
`Network.gd` está em **1062 linhas / 201 `@rpc`**. Recomptado com o escopo declarado —
`sources/` + `tests/` = **288 arquivos `.gd`**, 46.286 linhas de manhã, **46.654** na medição
das portas de dinheiro e **46.704 no fechamento desta passada** (`find … -name "*.gd" -print0 |
xargs -0 wc -l`; a diferença é o que esta passada acrescentou em `sources/` e `tests/`, e o
"344 / 53.267" acima incluía `addons/` e `archive/`). Dos cinco artefatos mortos, **quatro estão resolvidos**
nesta passada (saíram do índice `SQLCharacter.gd` e os outros `SQL*.gd` de domínio
sem chamada, `WebhookValidator.gd` e `tests/gut_runner.gd`; e `MetricsServer.gd`
agora tem `.gd`
+ `.uid` pareados); `Monitoring.SetPlayer` **passa a existir** (`Monitoring.gd:36`),
que era o erro de runtime do minimapa); e `SettleTransaction` — o método decorativo
sem chamadores — **saiu do índice em `bd69275`**, restando um settle real e único
(`OfflineSettle.SettlePending`, estático, chamado de `Server.gd:392` e `:493`). A
crítica que sobrevive a tudo isso é a estrutural: service-locator onipresente e um
`settleMutex` que não serializa nada porque o caminho real é "uma thread, um pacote
por vez". Ambas estão fora do escopo do Bloco 0.

Sobrou também o que a linha 273 acima apontava em `CheckoutService.gd`: as três
flags auto-atestadas (`gateway_ready`, `f2p_friendly`, `webhook_verified`) **saíram
da payload** na mesma passada. Não eram código morto — eram `true` literais numa
resposta ao cliente, afirmando coisas que este processo não faz (não expõe webhook,
não valida assinatura, não conhece o gateway) e que nenhum consumidor lia. Saíram
com guard anti-regressão em `SuiteCheckout`, e as cinco citações que as usavam como
prova de "economia 9.5" foram retificadas nos arquivos de origem
(`RELATORIO_FINAL_2026-09-21.md`, `CONCLUSAO_FINAL_ROUND_19.md`,
`AUDITORIA_SHAMBLETA.md`, `plano-ui-ux.md`). Ficou `grant_queue_idempotent`, que o
servidor garante e a suíte mede.

---

## 14. PERFORMANCE E ESCALABILIDADE

**Performance 6,0.** As mitigações são reais e não só de debug: WAL + `synchronous=NORMAL` + `busy_timeout` aplicados no servidor (`SQL.gd:1177-1180` `[CÓDIGO]` — corrige um item de auditoria antiga), dirty-check de entidades, pausa de física de IA ociosa, AOI, índices, batching de egress. Rodei os benchmarks `[TESTE]`: settle 1 ms (budget 500), XP walk 0 ms, catálogo 0 ms/24 zonas, load probe 200 settles P99 1 ms, 0 falhas. **O número é verdadeiro e mede pouco**: são 200 settles **sequenciais no mesmo personagem**, numa `testing.db` ociosa, sem o lock global e sem carga concorrente; e o "XP walk" é um laço `totalXp += 10` que mede zero. `[CÓDIGO]` Os jobs de CI só leem exit code, sem grep de `SCRIPT ERROR`/`PASSED`, e vazamentos de RID/recursos no teardown não alteram o exit code — classe de falha invisível ao pipeline `[TESTE]`.

Gargalos concretos: `BackupPlayers` a cada 600 s faz ~5 UPDATEs por jogador na main thread → a 1k CCU são ~5.000 UPDATEs em rajada (hitch de centenas de ms), a 10k vira stall multi-segundo com storm de desconexões; `Localizer.gd:28-71` percorre **a árvore inteira de UI a cada 1 s** alocando Array e `set_meta` por nó — ruído de GC justamente no alvo web/mobile. `[CÓDIGO]`

**SQLite não é o teto a 1k–10k** `[INFERÊNCIA]`: ~1k CCU ≈ 8–20 writes/s sustentados, folgado no WAL. O que dói é a rajada e a contenção do writer único quando game e companion escrevem no mesmo arquivo (`busy_timeout=5000` enfileira até 5 s).

**Escalabilidade 4,0.** O serviço `game` não tem réplica; `Peers` e `World.areas` vivem na memória do processo; `archive/SHARDING.md` descreve shard = processo + WAL próprio e **nunca foi implementado** — o "shard" atual é um array de 8 mutexes. Teto honesto: **~200 CCU confortável, ~1k com bursts audíveis, ~10k limitado pela CPU de um único loop, 100k+ requer o modelo que ainda não existe.** Para um beta fechado de 200, isso é suficiente, e recomendo explicitamente **não** reescrever nada agora: o gargalo do beta é segurança e dinheiro, não CCU. Uma migração de escala só se justifica com dados de retenção que ainda não existem. §24 aplicado ao pé da letra.

---

## 15. UX, UI E ONBOARDING — 4,0

Pontos verdadeiros: `_essential_windows()` retorna exatamente 8 janelas `[TESTE]`; a loja, o checkout, o passe, os baús e os cosméticos **têm UI real de compra/claim**; loading e empty states existem ("Nenhum anúncio no momento"); o tour de onboarding tem 6 passos sobrepostos com Skip em 1 clique e emite `onboarding_done`; o warm-start (já entrar farmando) é a melhor decisão de UX do produto.

Pontos que custam caro:
1. **Botão visível que não funciona.** O 2FA em `Settings.gd` aparece, clicável, e nada acontece (V4). Um botão morto ensina o jogador a não confiar na interface. `[CÓDIGO]`
2. **A interface manda o jogador usar o terminal.** `Gui.gd:681`: use `/ah list`, `/ah buy`, `/ah sell` ("UI gráfica em desenvolvimento"). Mercado é a feature social central e é texto puro. `[CÓDIGO]`
3. **Rótulo de moeda errado** na janela de leilão (ouro exibido como gems). `[CÓDIGO]`
4. **Onboarding é 100% descritivo.** Nenhuma micro-ação guiada: não manda abrir 1 baú, ver o relatório AFK, acertar 1 interrupt. Cita F2/F6 e 6 janelas de uma vez. O tour explica onde olhar, não o que fazer. `[CÓDIGO]`
5. **Densidade de MMO sobre núcleo idle:** ~24 janelas carregadas (minimap, emote, dialogue, formation, social, leaderboard, seasonPass…) para um jogo que se joga sozinho. `[CÓDIGO]`
6. **i18n das janelas novas está furado:** `AuctionHouseWindow` em português hardcoded e `Social` em inglês, ambos sem `tr()`; a re-execução real do extrator deu **213/277 (~77%)** contra o `coverage_report.md` commitado que afirma **188/188 (100%)**. `[TESTE]`
7. Para o canal que mais converte (navegador), a régua de curadoria de portais é "**nenhum setup nos primeiros 3 minutos**" `[DADO]` — e aqui o login de conta é pré-requisito. Conflito de canal, não de qualidade.

---

## 16. SOCIAL — 4,5

Existe mais infraestrutura social do que o comum num indie: canais de chat local/global/whisper, ponte com Discord, guildas com pontos e buff de 2% por nível, torneio semanal, arena assimétrica por ELO, referral anti-farma (nível 10 + e-mail verificado, janela de 72 h, teto semanal de 10, self/auto-referral bloqueado), conquistas e títulos.

A camada de **confiança** é o problema. Os três defeitos do §12 se somam aqui: BBCode injetável a partir de texto de jogador, sem cap de tamanho, sem filtro de conteúdo, **sem qualquer ferramenta de denúncia ou mute para o jogador** — a moderação existe só do lado do operador, como comandos GM (`/kick`, `/banlist`, `/ipcheck`, `WorldCommands.gd:7-42`). Não há trilha de auditoria de ações de GM (dívida assumida em `archive/BETA_DEBT.md:11`) e o 2FA de staff é opcional — na prática inatingível (V4). Numa economia com trade P2P, o canal de social é o vetor de golpe mais comum, e hoje ele é simultaneamente o meio de contato e o meio de injeção.

O valor de retenção do social é respaldado por literatura dedicada ("social features são um dos maiores motores de D7–D30") `[DADO qualitativo, ~2019/2020, sem % extraível]`, mas não é mensurável neste projeto: nenhum dos sistemas emite evento de uso (`BuyListing`, `ExecuteTrade`, guild, rebirth, passe não têm `Record()`). `[CÓDIGO]`

---

## 17. LIVE OPS E ANALYTICS

**Live Ops 3,0.** Os jobs diários existem e rodam de verdade (reconcile, fraud-scan, temporada, torneio, arena, referral) `[CÓDIGO]` — isso é mais do que muitos projetos. Mas quase tudo que um operador precisaria ajustar é `const` compilado: **todos os preços exibidos, custos de VIP em gems, bundles, missões e prêmios de temporada, entrada e prêmios de torneio, caps de anúncios, taxas de AH e trade** vivem em `EconomyCatalog.gd`. Configurável por env: provider de webhook, chaves de pagamento, `SHAMBLETA_AH_BOTS`, `SHAMBLETA_AD_PROVIDER`, `SHAMBLETA_ALLOW_DEV_*`, `SHAMBLETA_CATALOG_FILE` (só o espelho do companion). Consequência direta: **não dá para fazer flash sale, A/B de preço nem ajustar um sink sem rebuild de client e server**, e o companion precisa ser sincronizado manualmente. Sem isso, o produto não aprende.

Live events são o pior caso: o mecanismo existe (`CommunityService.gd:18-88`), os dados não são semeados por calendário nem por ferramenta, logo **nunca disparam** `[CÓDIGO]`.

**Analytics 4,0.** Há um dashboard real no companion (`/metrics`, `server.py:612`) que cruza ledger + telemetry + `grant_queue`: mint/burn/stock de gems, ouro 7d, trades e taxas, VIP ativo, contas totais/24 h, proxy de D1, settles 24 h + eficiência média, divergências de reconcile, guildas, AH aberto, `sales_by_sku` e multi-conta. Para "o mínimo", está acima da média. O painel de multi-conta é a exceção, e foi achado depois desta nota: o `GROUP BY fingerprint` lia uma coluna que o servidor preenchia com o próprio hardware — ver item (s).

O que é **impossível** de calcular hoje `[CÓDIGO]`:
- **Receita em dinheiro, ARPU, ARPPU, LTV e conversão-receita.** `grant_queue.amount` guarda **gems concedidas, não o preço pago**. As próprias metas do roadmap (conversão ≥2%, ARPPU ≥US$8, VIP ≥60% da receita) são **incomputáveis com o schema atual**. Correção mínima: `price_paid` + `currency` na fila de grant.
- D7/D30 por coorte e qualquer série temporal (só snapshots de janela; nenhuma store histórica de KPI).
- Churn; funil de features (nenhum evento de AH/trade/guilda/rebirth/passe/cosmético/tier de baú); receita por SKU por país.
- Reengajamento offline: `WebPush` não tem chamador nem tabela de subscription/VAPID `[CÓDIGO]` — o gancho de "volte" mais barato num idle está morto.

Nota de retificação a uma alegação anterior: **não** é verdade que a monetização seja invisível — `ledger_transaction.reason` (`"vip%d_purchase"`) e `grant_queue.payload` (com `sku`) já tornam ARPU e conversão **deriváveis por SQL**. É derivável à mão e não instrumentado; isso é trabalho de analytics, não buraco de dados.

---

## 18. TESTES — 6,5

**A alegação central é verdadeira e eu a reproduzi.** `godot --headless -s tests/run_idle_tests.gd` → `== RESULT: 1329 checks, 0 failures ==`, exit 0, zero `SCRIPT ERROR`, zero `Parse Error` `[TESTE]`. O gate é honesto por construção: `run_idle_tests.gd:205` encerra com `quit(suites.failures)`, então o exit code **é** a contagem de falhas, e o CI lê exatamente isso (`.github/workflows/godot-ci.yml:184`, timeout 1200). Benchmarks, backup-restore probe (migração 42=42) e os três suítes do companion também passaram `[TESTE]`. Divergência a anotar: binário local 4.7.2 vs CI pinado em 4.7.1.

A profundidade é real onde importa: settle golden com igualdade exata de gold/xp/drop/chave/baú + ledger + rollback de transação envenenada; trade/AH com escrow e conservação; refund com janela de 7 dias, reembolso duplo negado e IDOR A→B respondendo 403 sem chamar o provedor; **LGPD comportamental** provando purga de dados pessoais com preservação fiscal do ledger, tombstone e idempotência. Fronteira de dinheiro testada de verdade é a melhor área do repositório.

Os furos, todos verificados:
1. **Cobertura de segurança zero.** Nenhum teste exerce a V1: não existe o teste "cliente A envia `DeleteAccount` com `peerID=B` e B sobrevive". É o teste mais importante que falta.
2. **`tests/gut_runner.gd` é um artefato fabricado** — imprime um JUnit XML hardcoded com `tests='1193' failures='0'` e um TAP falso, sem executar nada `[CÓDIGO]`. Não está no CI. Mas é citado como **prova** da nota "Testes 9,5" em `AUDITORIA_SHAMBLETA.md:46`, `CONCLUSAO_FINAL_ROUND_19.md:13` e `RELATORIO_FINAL_2026-09-21.md:18`. O dano não é ao produto, é à credibilidade de toda medição anterior.
3. **Corrida não é testada.** `SuiteConcurrency` é sequencial (double-spend chamado duas vezes), não threads concorrentes.
4. **Crash-duplicação de grant inexistente** — e é justamente a janela da E3/§9. O item está aberto no roadmap (`roadmap:53`, `progress:53`), declarado como não feito.
5. **Ponta-a-ponta de pagamento não coberto:** nada valida o boot de produção, o caminho do DB e a entrega real do grant (que é o que quebrou — §19).
6. CI não detecta `SCRIPT ERROR` nem falhas de teardown (só exit code).

A nota seria 7,5 sem a fabrication do item 2 e sem o buraco 1; está em 6,5 porque cobertura de rede/segurança é parte do trabalho de testar um MMO.

---

## 19. DEVOPS — 3,0

**Bem:** Docker/Compose/Coolify com `provision_tls.sh` e `ROLLBACK.md`; backups **reais** via `backup_to` com tiers DAILY/WEEKLY/MONTHLY, prune e offsite **verificado por restore probe** `[TESTE]`; segredos corretamente ausentes do repositório (templates vazios, `${{ secrets.* }}` no Actions, `${VAR:-}` no compose); fail-closed sem token de pagamento.

**Bloqueantes:**
1. **A feature `production` nunca é ativada** (§10.1) — e o estrago não é só o banco. `IsTesting` também troca a **porta de bind**: `Server.gd:1316` seleciona `WebSocketPortTesting=6118` / `ENetPortTesting=6119` em vez de 6108/6109, enquanto o compose documenta "game (6108)". `[CÓDIGO]` O que precisa ser verificado por quem opera: se o domínio no Coolify foi apontado manualmente para 6118 para compensar — se sim, a stack funciona **por acidente configurado à mão**, e um redeploy limpo quebra. Nenhuma hipótese aqui reduz nota; apenas declara o que falta inspecionar no ambiente vivo.
2. **Healthcheck aponta para um servidor que não existe.** `deploy/docker-compose.yml:36` faz `curl -f http://localhost:9400/healthz`; não há `MetricsServer.gd` (só o `.uid` órfão), o `Monitoring.gd` é `print`, e a imagem base é debian-slim **sem `curl`** instalado `[CÓDIGO]`. Consequência composta: o serviço `game` **nunca fica saudável**, `web` depende de `condition: service_healthy`, e `restart: unless-stopped` não reinicia por unhealthy — só por exit. Um congelamento da main thread passa batido. `[INFERÊNCIA]` pela semântica do compose, `[CÓDIGO]` pelo alvo morto.
3. **Observabilidade zero.** `RecordSpan` nunca é chamado; Sentry é opt-in sem DSN commitado; ninguém é alertado de nada, nem quando o `Reconcile` reporta divergência.
4. **Sem reversão de schema:** 42 migrations forward-only, `SetVersion` só no fim — uma falha no meio re-executa o já aplicado. E o `ROLLBACK.md` restaura `backups/daily_*.db` enquanto o código grava em `sql-backups/DAILY/AAAA-MM-DD_HH-MM-SS.db` **com outro caminho e outro nome** → o runbook de emergência não executa como escrito. `[CÓDIGO]`
5. **Staging é parcialmente ficção:** `staging.yml` existe, mas `SHAMBLETA_ENV` e `staging.db` não aparecem em **nenhum** código — o "banco de staging" é o `testing.db` compartilhado. `[CÓDIGO]`
6. Backups offsite desligados por padrão **e sem criptografia** — uma cópia do DB contém e-mails e hashes de senha; isso é risco LGPD em repouso `[CÓDIGO]`.

---

## 20. DOCUMENTAÇÃO — 3,0

Volume e estrutura são bons: README, ROADMAP_COMERCIAL, TECH_SPEC, ECONOMY_STUDY, FEATURE_MATRIX, BETA_DEBT, COOLIFY, STAGING, ROLLBACK, LAUNCH_HANDOFF, `archive/`. E `archive/BETA_DEBT.md` é genuinamente honesto — 13 dívidas canônicas nomeadas, inclusive as que esta auditoria confirmou por conta própria.

A exatidão é o colapso, item por item verificado `[CÓDIGO]`:
- `AUDITORIA_SHAMBLETA.md` dá **9,2–9,5** a quase tudo, fundamentando em `sources/network/NetworkAuth.gd` e `NetworkSocial.gd` — **nenhum dos dois arquivos existe**.
- `architecture.md:45` descreve `Network.gd` "fragmentado em NetworkAuth/NetworkEconomy/… (facade 177 linhas)"; o arquivo real tem **1.026 linhas** (o P4 foi revertido). Lista 7 autoloads inexistentes, incluindo o `MetricsServer` que justifica o healthcheck morto. `architecture.md:64` diz que a economia é "`EconomyService` único"; a realidade é **17 módulos** em `sources/economy/`, nunca documentados.
- `setup.md`/`testing.md` ainda afirmam que `run_idle_tests.gd` está **bloqueado por Parse Error** — eu o executei verde, 1329/0. Documentação que declara quebrado o que funciona é tão cara quanto o contrário.
- `README.md:69` aponta para `som-idle-docs/` (diretório **vazio**) como fonte de "architecture, economy study, roadmap"; `docs/game_bible/` também vazio.
- `coverage_report.md` commitado: 100%. Real: 77%.
- `FEATURE_MATRIX` lista temporadas como "implementado, aguardando ativação" — tecnicamente verdadeiro, comercialmente enganoso: para o jogador a feature não existe (§7).
- Comentários de código erram números que o próprio código contradiz (`FarmZoneData.gd:141` diz "96/h na z24"; a fórmula da linha vizinha dá 80/h).
- Nenhuma API/RPC do jogo documentada; nenhuma política de privacidade ou termo de uso como artefato (só versões de consentimento no schema).

Efeito comercial direto: **uma autoavaliação que atribui 9,5 a Testes com base num script que imprime um resultado inventado invalida toda a base de decisões anterior.** Este relatório existe porque as notas internas não podiam ser usadas como premissa.

---

## 21. MERCADO: CONCORRENTES, COMUNIDADE E RISCO LEGAL

**Concorrentes e o que fazer com cada um.**

| Concorrente | Público | Monetização | Postura da comunidade | Roubar / Evitar |
|---|---|---|---|---|
| **Melvor Idle** | PC/mobile/web, idle-hardcore | **one-time premium**, sem ads nem assinatura `[dado]` | **amado** pelo modelo "paga uma vez" `[recorrente]` | Roubar o loop offline+skills; **evitar F2P/live-ops nesse público** |
| Idle Champions | F2P gacha-idle | cash shop de campeões + eventos | F2P "termina" o conteúdo, paredes de progressão `[recorrente]` | Evitar monetização que trava progresso real |
| AFK Journey/Arena | mobile global | gacha com pity + passe | dividida: elogiam arte/pity, odeiam a curva de poder `[recorrente]` | Roubar polish de temporada; evitar gacha de personagem |
| Raid: Shadow Legends | mobile massivo | gacha + energia agressivo | **símbolo de p2w**; popular ≠ querido `[consenso aparente]` | O case a não seguir |
| Albion Online | MMO sandbox | premium + Gold Market | valoriza economia de jogador; tensão com taxas/RMT `[recorrente]` | Roubar AH/guilda sérios; evitar RMT canibalizando |
| OSRS | MMO legado | assinatura + Bonds, **sem loot box paga** | **ataca a Jagex** a cada mudança que toca economia/RNG `[consenso aparente]` | Roubar o bar de qualidade; evitar fúria em RNG |
| Source of Mana (origem) | FOSS MMO | nenhuma | pequena e fiel (~6 contribuidores, 71 stars, ativo) `[dado]` | Risco de recepção hostil ao fork comercial |

O concorrente mais perigoso é **Melvor**: mesma promessa ("idle RPG profundo com progresso offline"), monetizando **one-time sem baú** — exatamente o modelo preferido pelo público idle. O segundo flanco é o **fantasma do OSRS**: o público cujo "bar de qualidade" o Shambleta corteja é o mesmo que odeia loot box.

**Preferências trianguladas** (força declarada; `[recorrente]` = multi-ano e multi-thread):
- Progressão offline é elogiada; **teto curto no free é o motivo de abandono documentado** — cap free apertado + cap maior pago flerta exatamente isso.
- Prestígio é **condicional**: odiado quando reseta sem ganho tangível, aceito quando **acelera**. O design de essência/favores está no lado certo (§8), e isso é uma vitória a proteger.
- Passe 100% cosmético é **respeitado**; FOMO obrigatório é odiado.
- "VIP sem poder" é **contestável**: multiplicar velocidade de coleta é lido por parte do público idle/MMO como P2W disfarçado de QoL `[consenso dividido]`.
- Anúncio **recompensado e opt-in é aceito**; intersticial obrigatório e back-to-back gera abandono. Não extraí um número de "X/dia" com estudo nomeável — a régua é subjetiva e o teto atual (6/dia) é defensável.
- Trade P2P + AH é desejado, com taxas transparentes aceitas; **RMT e bots são condenados**.
- Salva na nuvem sincronizado web↔Android↔desktop é **expectativa**, e o server-authoritative resolve isso nativamente — o diferencial mais defensável do produto.

**Mercado brasileiro** `[DADO]`: Android ≈ **83%** do mobile; Brasil é 4º em receita de ads Android e 5º em IAP Android — público que consome anúncio **e** compra. **PIX é o meio nº 1, com 76%** dos consumidores (CNDL/SPC Brasil, fev/2025). A precificação em R$ com PIX é correta e o `starter.pack` de R$9,90 está na faixa certa. Não encontrei ARPU/ARPPU de jogos Brasil com fonte confiável, conversão free→paid numérica, eCPM de rewarded no Brasil nem taxa de chargeback — **esses números simplesmente não foram medidos aqui**, e não devem ser inventados para preencher plano de negócio.

**Risco legal — baús.** A Lei nº 15.211/2025 ("Lei Felca", ex-PL 2628/22, aprovada em 17/09/2025) **veda loot boxes em jogos direcionados a menores de 18**: em títulos infantojuvenis em nenhuma hipótese e, em free-to-play de acesso misto, só com restrição efetiva de acesso de menores + controle parental; multa até 10% do faturamento ou R$50 milhões, com período de adaptação de ~1 ano `[Dado: Estadão set/2025; Adrenaline ago/2025]`. A lei cita expressamente Bélgica e Japão (loot box como jogo de azar); Bélgica trata como azar com sanção criminal e vários jurisdições exigem odds disclosure `[Dado]`. Em classificação etária, **todo jogo novo que venda loot box sobe para PEGI 16 no mínimo** `[Dado]`.

Aplicando ao código: o design **já fecha parte** do enquadramento — odds públicas, pity determinístico explícito, snapshot de disputa, e o baú **não é vendido diretamente por gems** (ele vem de settle/boss, e gems compram chaves/reroll/VIP). Mas três fatos deixam a combinação viva: existe item randomizado **negociável** entre jogadores (trade/AH), existe preço em R$, e a distribuição web+Android é tratada pelas lojas como acessível a menores **sem nenhum gate de idade no produto** `[CÓDIGO]`. **Isto não é parecer jurídico** — é a lista de perguntas para um advogado, e a resposta barata se ele confirmar o risco é transformadora de simples: tornar o conteúdo do baú **não negociável** (bound on pickup) ou puramente cosmético, o que remove o "valor de saída" que sustenta o enquadramento de azar.

## 22. COMUNIDADE × CÓDIGO (formato exigido)

**C1 — "O cap offline free não pode punir quem dorme."**
*Hipótese da comunidade:* `[recorrente]` em r/incremental_games, multi-ano.
*Implementação atual:* caps 12 h (free) / 24 h (VIP t1) / 36 h (VIP t2), fator 0,6→0,8, VIP ×1,2 (`OfflineSettle.gd:12-23`).
*Verificação no código:* confirmado; é o mecanismo documentado. **A penalidade relativa é 3× de coleta entre free e VIP máx.**
*Impacto:* churn no D2–D7 de F2P + percepção de P2W; também afeta a régua de D7.
*Melhoria:* subir o cap free para ~16–20 h (continua premiando log diário e o VIP continua melhor), e **mostrar XP/h real** no relatório AFK em vez de o número só existir na doc.
*Matriz negócio:* custo S, risco baixíssimo, protege retenção que sustenta LTV. **Fazer.**

**C2 — "VIP não pode tocar PvP/ranking."**
*Hipótese:* `[consenso]` contra P2W.
*Implementação:* settle VIP ×1,2; `TournamentArenaService.gd:29-51` concede apenas **tickets** extras a VIP, não poder.
*Verificação:* **confirmado como honrado** — verifiquei o eixo um por um; nenhuma taxa de arena/ELO recebe multiplicador.
*Impacto:* este é o argumento de venda de fairness do produto, e ele está intacto.
*Melhoria:* não é código — é comunicar. Publicar a regra ("VIP nunca altera resultado de arena") na página e no `/ah`-style UI.
*Matriz:* custo ~0, protege reputação e reduz risco de backlash estilo OSRS/Raid. **Registrar como invariante e testar** (um teste que falhe se alguém multiplicar poder por VIP no futuro).

**C3 — "Renascimento precisa ser claramente acelerador."**
*Hipótese:* `[recorrente]`, condição bem documentada pela comunidade.
*Implementação:* bônus composto 1,05^n vs custo 1,7^n, ciclo 17–21 dias, série converge ~3,5 meses sem zerar (`RebirthData.gd:9-49`).
*Verificação:* **confirmado no lado certo** — a matemática acelera.
*Impacto:* positivo, mas invisível: nada na UI diz "este ciclo foi X% mais rápido que o anterior".
*Melhoria:* expor tempo-para-reconquistar-a-zona-anterior como número no pós-rebirth. Custo S.
*Matriz:* transforma um sistema já correto em retenção percebida. **Fazer.**

**C4 — "Baú pago com item negociável."**
*Hipótese:* reação estrutural negativa em comunidades PC/idle/MMO `[recorrente]` + risco legal (§21) `[dado]`.
*Implementação:* baú granted por settle/boss, pity 10, odds públicas, conteúdo entra no inventário **negociável**.
*Verificação:* `[CÓDIGO]` para a negociabilidade; `[HIPÓTESE]` para a exposição jurídica — **precisa de parecer de advogado**, não reduzo nota por isso.
*Impacto:* potencialmente existencial (multa) e reputacional (o público que se corteja).
*Melhoria:* marcar drop de baú como bound-on-pickup, ou restringir a itens cosméticos; gate de idade real se o produto quiser manter aleatoriedade paga.
*Matriz:* custo de decisão alto, custo de código S-M. **Decidir antes do beta, não depois da multa.**

**C5 — "Anúncio nunca obrigatório, com teto."**
*Implementação:* `AD_DAILY_CAP = 6`, caps por placement (chest 1, bosskey 2), só placements opt-in (`AdsCosmeticsService.gd`).
*Verificação:* **conforme** com a preferência documentada. O problema não é o desenho, é a fraude do §12-V3.
*Melhoria:* SSV server-side; o desenho atual pode ficar como está.

**C6 — "Fricção de troca: taxas sim, cooldown sufocante não."**
*Implementação:* trade 20/40 por dia, cooldown 60 s, taxa 10 gems **queimadas**, e-mail verificado; AH listagem 5 gems + 1% ao criador.
*Verificação:* a taxa queimada é sink defensável; o cooldown é curto. **Não sufocante.**
*Gap real:* falta **teto de preço/appraisal** (lavagem) e falta **botão** — a fricção dominante hoje é digitar comando.

## 23. PRIORIZAÇÃO E OPORTUNIDADE

Eixos 1–10: **Ip** impacto no jogador · **Re** receita · **Rt** retenção · **Rs** risco técnico · **Ef** esforço (10 = mínimo) · **Ur** urgência.

| ID | Problema | Ip | Re | Rt | Rs | Ef | Ur | Classe |
|---|---|---|---|---|---|---|---|---|
| S1 | `peerID` spoofável em 100/101 RPCs | 10 | 8 | 6 | 9 | 3 | 10 | **P0** |
| D1 | `testing.db` × `live.db` → pagamento não entregue | 9 | 10 | 8 | 8 | 9 | 10 | **P0** |
| M1 | 2FA sem handlers no servidor (+ SQL null no client) | 8 | 5 | 4 | 8 | 7 | 8 | **P0** |
| C1 | Chat interpreta BBCode de texto do jogador | 7 | 4 | 6 | 8 | 8 | 8 | **P0** |
| E3 | `status='processed'` fora da transação do grant | 5 | 9 | 3 | 8 | 9 | 8 | **P0** |
| M2 | `AdStubEnabled` é `const true` → recompensa mintável | 6 | 8 | 4 | 8 | 9 | 8 | **P0** |
| L1 | Healthcheck em porta sem servidor; CI sem liveness | 3 | 6 | 4 | 8 | 8 | 7 | **P1** |
| V2 | Janela TOTP ±15 min | 6 | 3 | 4 | 9 | 8 | 6 | **P1** |
| M3 | `pass.s1` ausente do `SHOP_CATALOG` | 4 | 8 | 3 | 9 | 10 | 7 | **P1** |
| G1 | Temporada/Passe OFF = espinha de retenção invisível | 7 | 7 | 9 | 7 | 5 | 7 | **P1** |
| G2 | Live events sem dados semeados (nunca disparam) | 5 | 3 | 8 | 9 | 8 | 6 | **P1** |
| G3 | Torneio/arena presos ao job de backup | 5 | 2 | 7 | 8 | 8 | 6 | **P1** |
| X1 | Inflação de ouro: razão de reposição ≈0,06 | 6 | 7 | 6 | 8 | 5 | 6 | **P1** |
| K1 | Sem `price_paid` → ARPU/ARPPU/LTV incomputáveis | 1 | 9 | 2 | 9 | 8 | 7 | **P1** |
| U1 | Mercado por comando de texto, sem RPC, moeda rotulada errada | 7 | 6 | 5 | 8 | 5 | 6 | **P1** |
| B1 | Baú previsível (semente sem segredo) + interação com regra de azar | 4 | 5 | 4 | 8 | 7 | 5 | **P1** |
| T1 | `gut_runner.gd` fabricado ainda citado como prova de nota | 2 | 2 | 2 | 10 | 10 | 6 | **P1** |
| P1b | Ouro/XP live fora do ledger; reconcile não confere o que promete | 3 | 6 | 3 | 8 | 6 | 5 | **P2** |
| O1 | Preços/taxas/prêmios como `const` (sem A/B, sem oferta) | 3 | 8 | 4 | 6 | 3 | 5 | **P2** |
| U2 | Onboarding não-guiado; botão 2FA visível inerte | 6 | 2 | 6 | 8 | 6 | 5 | **P2** |
| R1 | `Monitoring.SetPlayer` inexistente; `SQLCharacter` 100% stub; `SettleTransaction` morto | 3 | 1 | 1 | 9 | 9 | 4 | **P2** |
| R2 | `BackupPlayers` em rajada; `Localizer` O(N)/s | 4 | 2 | 3 | 8 | 6 | 4 | **P2** |
| R3 | Docs descrevem arquivos/refs inexistentes | 2 | 3 | 2 | 9 | 7 | 4 | **P2** |
| W1 | Wash-trade sem teto/appraisal; fraude sem enforcement | 4 | 6 | 4 | 7 | 5 | 4 | **P2** |
| W2 | i18n 77% real vs 100% reportado; strings hardcoded em janelas novas | 4 | 1 | 3 | 9 | 7 | 3 | **P3** |
| W3 | Rollback de schema inexistente; caminho do `ROLLBACK.md` errado | 2 | 4 | 2 | 7 | 7 | 3 | **P3** |
| W4 | Backups sem criptografia; offsite desligado por default | 4 | 1 | 2 | 8 | 7 | 3 | **P3** |
| W5 | WebPush sem subscription (gancho de retorno morto) | 4 | 3 | 5 | 8 | 6 | 3 | **P3** |

**Opportunity Score = Impacto × Confiança ÷ Esforço** (confiança = quão certa está a relação causa-efeito, 0–1; esforço em pontos de história):

| Oportunidade | I | C | E | Score |
|---|---|---|---|---|
| Declarar `custom_features="production"` no preset de release + teste de boot | 10 | 0,95 | 1 | **9,5** |
| Adicionar `pass.s1` ao `SHOP_CATALOG` | 8 | 0,95 | 1 | **7,6** |
| Mover o `UPDATE status='processed'` para dentro da `Transaction` | 9 | 0,9 | 1,5 | **5,4** |
| Stub de anúncio por env com default **false** | 8 | 0,9 | 1,5 | **4,8** |
| Chat: `text` como texto puro (ou `escape_chars`/strip de `[`) + cap de 200 | 7 | 0,85 | 1,5 | **4,0** |
| Escrever os 3 handlers de 2FA no `Server.gd` (o resto já existe) | 8 | 0,85 | 2 | **3,4** |
| `price_paid` + `currency` no `grant_queue` | 9 | 0,8 | 2,5 | **2,9** |
| Derivar identidade do `multiplayerAPI` no dispatcher central | 10 | 0,8 | 3,5 | **2,3** (maior valor absoluto do documento) |
| Ligar temporada/passe com regras congeladas **ou** removê-la do shell | 9 | 0,7 | 3 | **2,1** |
| SSV real de anúncios | 8 | 0,75 | 4 | **1,5** |
| Botões comprar/anunciar no AH + RPC correspondente | 7 | 0,7 | 5 | **1,0** |
| Taxa de venda do AH em ouro queimada (anti-inflação) | 7 | 0,6 | 4 | **1,05** |

## 24. ROADMAP

**Bloco 0 — antes de qualquer beta (dias).** Tudo aqui é correção pontual, nenhuma reescrita.
1. S1 — identidade derivada da conexão no dispatcher único; ~~remover `peerID` das assinaturas `@rpc`~~ *(desfeito por medição em 2026-09-25: o parâmetro é o slot de identidade no fio e a aridade é o protocolo; o que cabia era o guard, e ele passou a casar o marcador do slot, não o nome — §24 linha 1)*. Regressão por transporte.
2. D1 — `production` no preset de release (e/ou `--features production` no `Dockerfile`), teste de boot asserindo `GetDBPath()` == o arquivo que o companion abre, e alinhar o `Dockerfile`/compose às portas que o servidor realmente binda.
3. M1, C1, E3, M2 — 2FA funcional, chat como texto puro com cap, grant atômico, stub de anúncio por env.
4. T1 — apagar `gut_runner.gd` (ou torná-lo real) e rebaixar publicamente as notas que o citavam como prova.
5. Abrir a conta PJ Mercado Pago e setar as chaves (não é código; é o gate de "existe receita").

**Bloco 1 — beta fechado (200 CCU, organic-first).**
6. Reescrever as metas de retenção para a realidade medida (D1 ≥ 27%, D7 ≥ 7%, D30 ≥ 4%) `[DADO]` e declarar que UA pago não fecha conta com esses benchmarks.
7. Decidir G1/G2/G3: ligar o espinho sazonal com regras congeladas, semear live events por calendário e criar o primeiro torneio na criação do personagem (não 24 h depois). Ou remover do shell.
8. L1 — healthcheck real (bind `:9400`) e spans de verdade, ou remover a ficção; CI com grep de `SCRIPT ERROR`/`RESULT`.
9. K1 — `price_paid`/`currency` + eventos de `checkout_intent`, `purchase`, `ah_*`, `trade`, `rebirth`, `pass_claim`; view de coorte D1/D7/D30.
10. M3 + harmonizar os dois catálogos numa fonte única (o `catalog.json` servindo de espelho validado no boot).
11. Gate de idade e parecer jurídico sobre baús (§21/§25) **antes** de aceitar dinheiro de menores.

### Execução do §24 (estado medido em 2026-09-24)

A régua é a lista acima; este bloco registra o estado de cada item com o ponteiro de
evidência e a medição que o fecha. Nada aqui é intenção. **Uma ressalva que vale para a tabela
inteira:** "feito" quer dizer *na árvore de trabalho*, e isso é mais fraco do que parece. **Doze**
arquivos desta passada são **não rastreados**: `data/conf/paid_catalog.json` (item 10),
`data/conf/migrations/043`–`046.sql` (itens 3, 9 e 11), `sources/system/MetricsServer.gd` (item 8),
`sources/network/server/ChatModeration.gd` com o `.uid` (item 3, C1c), `scripts/ci_gate_log.sh`
(o portão), `tests/run_rpc_identity_test.gd` com o `.uid` (item 1) e este arquivo. Medido em `HEAD`
(`git grep -l` contra o commit): nenhum desses nomes existe lá — `paid_catalog.json`,
`ChatModeration`, `ci_gate_log.sh`, `run_rpc_identity_test.gd` e `044`–`046` retornam **zero**
arquivos (só `docs/development/architecture.md` menciona `MetricsServer`) e a pasta de migrations
para em `042`, com 42 arquivos. Então **`HEAD` não é uma árvore quebrada: é o jogo pré-auditoria** —
ele boota o que era, e a CI dele roda o portão antigo. O que não existe fora desta máquina é o beta.
**O risco concreto é o commit parcial**, porque os arquivos rastreados já chamam os soltos pelo nome:
`scripts/test.sh:25,40` e `.github/workflows/godot-ci.yml:187,212,220,234,256,278` executam
`ci_gate_log.sh` e o harness de identidade; `Server.gd:1177,1181`, `SQL.gd:1275` e
`WorldCommands.gd:1295` usam `class_name ChatModeration`; `Launcher.gd:26,75` e
`IdleTests.gd:5314,5468,5474` usam `class_name MetricsServer`. Commitar o conjunto `M` sem o
conjunto `??` entrega uma árvore que não parseia e um portão que não roda. A conta completa está em
`deploy/LAUNCH_HANDOFF.md` §5, e fechar isso é commit — não
código.

**Portão de qualidade.** `./scripts/test.sh all` roda os **oito** harnesses pelo gate quádruplo
de §24-8 (`scripts/ci_gate_log.sh`: zero `SCRIPT ERROR`/`Parse Error`, linha de resultado
presente, contagem de falhas lida DA LINHA, exit code conferido à parte). Medido no fim desta
passada (2026-09-24 21:56 -0300, `/tmp/suite_beta_final16.log`, `SUITE_EXIT=0`):
**8× `Gate §24-8 OK`** —
**5× `godot exit=0`** + **3× `python exit=0`** — com `== RESULT: 2222 checks, 0 failures ==`
(idle), `== RPC IDENTITY: 10 checks, 0 failures ==`, `== RESULT: 0 failures ==` (e2e),
`== Backup Restore Probe: 8 checks, 0 failures ==`, `== Benchmarks: 0 failures ==`,
`== COMPANION: 100 checks, 0 failures ==`, `== SECURITY: 47 checks, 0 failures ==`,
`== REFUND CLI: 12 checks, 0 failures ==`.

**O gate de aceite tinha só o predicate coberto; as portas agora têm guard.** O `SuiteLGPD`
media `IsConsentAccepted` e as strings pt_BR, mas nada amarrava **quem chama** o predicate: as
três portas (`LoginWithPassword`, `LoginWithToken`, `AcceptConsent`) vivem em RPCs que exigem
peer de rede, então um `true` literal no lugar do gate passaria verde hoje. Doze checks novos
fecham isso por fiação de fonte (a mesma técnica dos guards de catálogo, com um extrator
`_FnBody` que corta o corpo da função e remove linhas de comentário, para que uma citação em
comentário não valide o guard): as duas portas de login chamam `IsConsentAccepted` e devolvem
`ERR_CONSENT_REQUIRED`; **o gate vem antes da derivação de `ERR_2FA_REQUIRED`** (a porta de 2FA
não repete a conferência e é segura exatamente por essa ordem — inverter as duas linhas a
reabriria sem nenhuma cobertura); `AcceptConsent` só grava depois de `err == ERR_OK and accountData` e
revalida senha **ou** token respeitando o lockout; o cliente trata o código e abre o diálogo de
re-aceite (sem esse ramo, um bump seria bloqueio definitivo); e `AcceptConsent`/`CreateAccount`
derivam o peer de `AuthPeerID`, não do argumento — S1 vale para RPC novo também.

**Achado de processo (esta passada): o portão tinha um caminho de 20 minutos para descobrir
um arquivo que não compila.** `run_idle_tests.gd:76` faz `load("res://tests/IdleTests.gd")` e
`.new()`; quando um `CheckEq` recebeu `String` onde a assinatura é `(int, int, String)`, o
`load()` devolveu um GDScript inválido, `.new()` falhou, **nenhuma suíte rodou** e o job só
morreria no `timeout 1200`. Três execuções foram perdidas assim antes de o erro aparecer
(vivo em `/tmp/shambleta-idle.log`, não no log do `test.sh`, que é block-buffered). A correção
é um **preflight de parse** de ~1 s, nos seis arquivos (`godot --check-only --script`, régua
ancorada em `SCRIPT ERROR: Parse Error` — o `ERROR: …tscn - Parse Error: [ext_resource]` que o
modo emite para scripts com autoload é falso positivo do modo), ligado no `all`/`idle`/`quick`
do `scripts/test.sh` **e** no job `idle-tests` da CI. Verificado contra o defeito real: o
preflight devolve `2` para a linha semeadora e `0` nos seis arquivos bons, e a linha
`Preflight parse OK: 6 harnesses, zero SCRIPT ERROR: Parse Error.` está no log desta execução
verde. Varridos também, ancorados: **58 arquivos `.gd` modificados/não rastreados, zero parse
error** (a varredura foi re-feita às 00:19 -0300 de 2026-09-25, depois da última leva de edições — a fatia
(t) —, com o mesmo
comando do preflight — `godot --headless --path . --check-only --script`, grep em
`^SCRIPT ERROR: Parse Error` — arquivo por arquivo. Dos 73 caminhos `.gd` sujos, **15** são
arquivos deletados — os 10 `SQL*.gd` do fracionamento (consolidado em `SQL.gd`),
`WebhookValidator.gd`, `DeviceFingerprint.gd` (o coletor que o achado (s) tirou de cena, sem chamador)
e o trio de multiplayer morto (`MultiplayerTests.gd`, `gut_runner.gd`,
`run_multiplayer_tests.gd`) — e ficam fora porque não há
o que parsear.)

| # | Item | Estado | Evidência |
|---|---|---|---|
| 1 | S1 identidade derivada do transporte | **vulnerabilidade fechada; residual redefinido por medição** | `Network.gd:982 TransportSenderID()` varre as três interfaces e só aceita sender ≠ 0; `:990 AuthPeerID()` devolve o sender real e usa o `peerID` declarado apenas onde não há borda de rede (offline/servidor local). Regressão ao vivo em `tests/run_rpc_identity_test.gd` (dois peers WebSocket reais, forja no corpo recusada, verificação na direção inversa). ~~**Residual:** 106 assinaturas `@rpc` ainda declaram `peerID : int = PeerAuthorityID`. Elas não são mais enviadas no `Array` de args do `CallServer` — o parâmetro sobrevive só como o valor que `AuthPeerID` usa quando não há borda de rede. É cosmético, mas é superfície para uma regressão futura: um handler novo que ler `peerID` direto, sem passar por `AuthPeerID`, reabre a forja.~~ **A frase acima media errado e foi desfeita na passada seguinte, antes de servir de pauta:** os 106 parâmetros **estão** no fio. `CallServer` e `CallClient` acrescentam a identidade em `args + [identidade]` em **todas** as ramificações (`sources/network/Network.gd:994` dispatcher, `:1010` caminho do client) e o handler do servidor recebe exatamente esse último parâmetro — `Server.ArenaAttack(defenderAccountID, peerID)`, `Server.SetupTwoFactor(peerID)`. Logo a aridade é o protocolo: apagar os parâmetros não é limpeza cosmética, é quebrar 626 chamadas `Network.<envoltório>()` medidas no repositório e reescrever 106 assinaturas com 106 handlers de uma vez. O resíduo verdadeiro era outro, e menor: o guard de fronteira casava a **string literal** `peerID : int`, então um wrapper declarando `who : int = NetworkCommons.PeerAuthorityID` passava sem autenticar nada. Fechado na passada de 2026-09-25 por regra baseada no **marcador do slot** (` : int = NetworkCommons.PeerAuthorityID`, lido por String e não por regex) com `identitySites == anyPeerDispatch` como trava anti-degenerescência — 106/106 hoje, nenhum cru. |
| 2 | D1 produção nos artefatos do deploy | **feito, e com um segundo defeito da mesma raiz encontrado ao verificar** | `export_presets.cfg` exporta `production`; `deploy/server/Dockerfile` liga `SHAMBLETA_PRODUCTION=1`; `EXPOSE 6108` == `NetworkCommons.WebSocketPort`; healthcheck sonda a porta que o servidor binda. Guard `SuiteDeployMode` compara `GetDBPath()` com o `--db` do companion por **igualdade derivada de `OS.get_user_data_dir()`**. Ao escrever esse guard descobriu-se que o caminho comparado antes era o layout `godot/app_userdata/` do **Godot 3** — `project.godot` usa `use_custom_user_dir`, então o real é `$HOME/.local/share/Shambleta` (medido). O companion abria arquivo inexistente (`server.py:1299` → exit 2): **nenhuma compra seria creditada**, e `tools/provision_tls.sh` gravava o certificado fora do `user://server.crt` que o bind cobra. Corrigidos os dois, mais TLS.md/COOLIFY.md/ROLLBACK.md/debugging.md/`scripts/test.sh clean`/exemplos do `server.py`. |
| 3 | M1, C1, E3, M2 | **feito** | 2FA: `SuiteTwoFactor`, `SuiteTwoFactorSetup`, `SuiteTwoFactorVectors` (janela ±1 step V2 incl.). Chat: `SuiteChatHardening` (texto puro + cap) e C1b/C1c (balão morto reativado; denúncia/bloqueio server-side). Grant: `SuiteGrantQueue` com status dentro da transação (E3). Anúncio: `SuiteAds` + stub fechado por default, aberto só pelo compose (`SHAMBLETA_AD_STUB: "1"`), com guard que falha se a linha cair. |
| 4 | T1 apagar `gut_runner.gd` e rebaixar as notas | **feito** | Arquivo removido; notas rebaixadas em `RELATORIO_FINAL_2026-09-21.md`, `auditoria-tecnica-shambleta.md` (claims 1193 checks e E2E de multiplayer riscados) e nos arquivos citados em §13. |
| 5 | Conta PJ Mercado Pago + chaves | **não é código** | Gate de "existe receita" continua com o dono do projeto. Sem `SHAMBLETA_MP_ACCESS_TOKEN` a porta não abre em modo suave: `POST /checkout/preference` responde **503 `checkout_unavailable`** antes de chamar o gateway (`companion/server.py`) — a loja fica incapaz de cobrar, não "operando em sandbox" (sandbox é outra rota: `POST /checkout/simulate`, exigindo `allow_dev_checkout` + segredo compartilhado). A primeira versão desta linha apontava para um `gateway_ready` de `EconomyService`, que era um `"true"` literal sem consumidor nem verificador; removido, ver §13. |
| 6 | Retenção reescrita para a realidade medida | **feito** | D1 ≥ 27% / D7 ≥ 7% / D30 ≥ 4% em `ROADMAP_COMERCIAL.md`, com a declaração explícita de que UA pago não fecha conta nesses benchmarks. |
| 7 | Decidir G1/G2/G3 | **feito (ligado, com regras congeladas)** | `SHAMBLETA_ENABLE_SEASONS: "1"` no compose; `SuiteSeasonBootstrap` cobre abrir→congelar→liquidar→substituir; `EnsureWeeklyTournament` chamado no primeiro login (`sources/network/server/Peers.gd:270`) e não 24 h depois no job diário; live events com predicate de tick e semeadura por calendário. |
| 8 | L1 healthcheck real + CI com grep | **feito — e a metade dos spans resolvida como "remover a ficção"** | Bind `:9400` (`MetricsServer`), probe HTTP ao vivo em `SuiteMetrics` (200/404/405/400/431 e `Destroy()` liberando a porta), `test:` na forma lista sem operador de shell, `curl` instalado na imagem (sem ele o `service_healthy` nunca passa). O item pedia "spans de verdade, **ou** remover a ficção": `git log --all -S"func StartSpan"` retorna **zero** commits (`StartSpan`/`FinishSpan`/`ActiveSpans` só existiam no texto do `archive/FEATURE_MATRIX.md`), e o único `RecordSpan` que chegou a ser declarado nunca teve chamador — medição em `git grep RecordSpan HEAD` devolve apenas a própria linha 14 de `Monitoring.gd`. O código órfão saiu da árvore e ficou um aviso no topo do arquivo (`sources/system/Monitoring.gd:18`) dizendo onde medir de verdade (`tests/benchmarks.gd`, profiler do editor, `MetricsServer`). A retificação das notas que citavam spans como prova está publicada em `RELATORIO_FINAL_2026-09-21.md:88`, `CONCLUSAO_FINAL_ROUND_19.md:22`, `auditoria-tecnica-shambleta.md:131`, `plano-ui-ux.md:91` e `ROADMAP_COMERCIAL.md:131-145`. |
| 9 | K1 dinheiro e coorte | **feito** | `044_grant_price_paid.sql` (`price_paid`/`currency`), eventos `checkout_intent`/`purchase`/`ah_*`/`trade`/`rebirth`/`pass_claim`, `045_cohort_view.sql` com a view `cohort_retention`; cobertos por `SuiteMoneyFunnel` (funil + coorte D1/D7/D30 na quinta metade) e `SuiteTelemetry`. |
| 10 | M3 + catálogo único | **feito** | `data/conf/paid_catalog.json` é a fonte, copiado para a imagem do companion e validado no boot (`EconomyCatalog.ValidatePaidCatalog`); `SuiteCatalogConsistency` bate os dois lados. As chaves de comentário do arquivo (`_note`, `_agreements_note`, `_agreements`) não são SKU para nenhum leitor: `load_catalog` pula na validação e preserva no dict, o validador do boot compara `_agreements` com os três consts, e nenhuma das portas de dinheiro aceita uma delas como `sku` — ver achado (i), que foi aberto por esta linha. |
| 11 | Gate de idade | **metade em código feita; parecer jurídico em aberto** | `046_age_gate.sql` + `SQL.IsConsentAccepted/SetConsentAccepted` exigem igualdade com `AgreementAgeVersion` (`NetworkCommons.gd:277`, predicate em `sources/sql/SQL.gd:101` — a versão de idade não é parâmetro porque só existe uma vigente); login barra sem aceite (`Server.gd:79,:185`) e checkout recusa com `reason "consent_required"` (`CheckoutService.gd:74-75`). **É autodeclaração afirmativa, não verificação de idade** — o checkbox de `Login.gd:466` declara "18 years old or older", mas nada em código impede mentir a data. O enquadramento legal dos baús (§21/§25) continua com o advogado. **Segunda porta fechada nesta passada:** a recusa existia só no processo do jogo, enquanto `POST /checkout/intents`, `/checkout/preference` e `/checkout/simulate` do companion aceitavam qualquer `auth_token` válido — e o nginx do serviço `web` expõe `/checkout/` na mesma origem do jogo. Uma conta pré-046 (`consent_age_version = ''`) ou com token emitido antes de um bump não conseguia logar e conseguia pagar. Hoje as três rotas chamam `consent_currently_accepted` (espelho de `IsConsentAccepted`: igualdade com as versões vigentes, fail-closed sem coluna ou sem declaração), o `/webhooks/payments` fica deliberadamente sem gate — recusar ali descartaria entrega já paga — e os dois lados são medidos em `companion/test_security.py` (C1–C5). As versões vigentes passaram a viajar em `data/conf/paid_catalog.json` (`_agreements`), validadas contra os consts no boot e na suíte, e uma SKU de comentário (`_agreements`, `_note`) deixou de ser cobrável — ver achado (i). **A fiação das portas passou a ter guard** (12 checks em `SuiteLGPD`, nesta passada): até aqui só o predicate era medido, e as três portas `@rpc` não têm peer em harness — hoje o guard exige `IsConsentAccepted`+`ERR_CONSENT_REQUIRED` nas duas portas de login, o gate **antes** da derivação de `ERR_2FA_REQUIRED` (é a ordem que torna a porta de 2FA segura), a gravação depois de credencial validada em `AcceptConsent`, o ramo de cliente (`Login.gd:105` → `OpenReconsentDialog`) e `AuthPeerID` nos dois RPCs. |

**Achados novos, fora da lista acima, descobertos ao verificar a lista:** (a) o cliente
montava `TLSOptions.client_unsafe()` no canal por onde passam senha, token e código 2FA —
corrigido com âncora explícita e varredura da árvore inteira (`V7`, §12); (b) o layout
`user://` de Godot 3 nos artefatos de deploy, que travava dinheiro e TLS ao mesmo tempo
(item 2 acima); (c) o boot de base nova nunca tinha sido medido — medido: 002→046 aplicam
limpo sobre o template e fecham com o mesmo schema da base de desenvolvimento (53 tabelas,
1 view, 362 pares `table.column`, `version = 46`), com o contrato de contiguidade/ordem
amarrado em `SuiteOpsA2`; (d) `docs/development/debugging.md` anunciava um painel de
performance em F3 que não existe (nenhum binding; `ServerDisplay.gd` é script órfão, sem
cena nem referenciador); (e) **a fronteira do dinheiro não era alcançável no export
web** — o client resolvia a base do companion por variável de ambiente, que em browser
não existe, e caía no default `http://127.0.0.1:8901`, que era exatamente o bind do
próprio container (loopback): nenhum jogador web poderia comprar. Fechado com
`NetworkCommons.CompanionURL` resolvido uma vez no boot (`Launcher._ready`, origem da
página no web), proxy same-origin `^/(checkout|webhooks)/` no nginx do serviço `web` e
bind não-loopback no companion; o guard não confia na minha leitura do nginx — ele
**compila a regex da `location`** contra as URLs reais que o client monta; (f) **staging
tinha o endereço do game server no canal errado**: `web.environment`, lido em runtime
por um container que não lê runtime (`nginx:1.27-alpine` puro; o valor entra no `pck`
pelo `ARG` + `sed` do `deploy/web/Dockerfile`), com `${VAR:-}` do compose base
interpolando do `.env` do projeto; movido para `build.args` literais no override;
(g) **o token de sessão do checkout era lido do `var` errado** — `Checkout.gd` lia
`Launcher.nPanel.savedToken`, que o `Connect()` do login zera logo depois do auto-login,
e o `Conf` onde `SaveToken` grava ficava intocado: 401 `missing_token` na frente do
pagamento para qualquer sessão, com a janela aconselhando "lembrar" justamente a quem
já tinha marcado; (h) **a segunda fechadura do gate de idade** — o aceite era cobrado no
processo do jogo e ignorado nas três rotas HTTP que tomam dinheiro, que são alcançáveis
direto na mesma origem do site (item 11 da tabela acima); (i) **chave de comentário não é
SKU, e a porta do dinheiro comparava membership** — o item (h) fez o catálogo passar a
declarar `_agreements` dentro do MESMO JSON que os preços, e as três rotas de checkout
validavam o `sku` do request por `sku not in catalog`. Medido sobre o arquivo canônico
antes da correção: `build_preference_payload(cat, "_agreements")` devolvia payload com
`unit_price` 0.0 (uma preferência de R$ 0,00 no provedor — cobrar zero é entregar de
graça, e sem `kind`/`amount` não havia o que conceder) e `sku="_note"`, que já estava no
arquivo antes desta passada, levantava `AttributeError` dentro do handler, sem resposta.
Fechado com `is_sellable_sku` — a mesma predicate que `load_catalog` usa ao validar o
arquivo, aplicada nas três portas que tomam dinheiro, nas três funções puras (grant, grants
de bundle, preferência) e na projeção do `/catalog`, que publicava as chaves de comentário
como itens de loja. Coberto por `companion/test_security.py` parte D (15 checagens, 32→47)
e por guard estático em `SuiteCatalogConsistency` que conta os três callsites e falha se
algum voltar a membership; (j) **tecla anunciada na tela de bindings e morta no jogo** —
três classes de defeito na mesma cadeia. `Action.gd:179` tinha um
`elif FSM.IsGameState():` aninhado, e uma cadeia `if/elif` para no primeiro ramo verdadeiro:
assim que o jogador entrava em `IN_GAME` o ramo era tomado, os quatro toggles internos não
correspondiam à tecla e **nada depois dele era avaliado** — F2/F4/F5 (hub de personagem),
F9 (social), P (screenshot) e F11 (fullscreen) só funcionavam no menu, o
exato contrário do que a tela de bindings anuncia. `OpenCharacterHub` tem três callsites em
`sources/`, todos naquela cauda morta (medido), então o hub nunca abriu por teclado dentro do
jogo. Na mesma varredura, duas mortes independentes do mesmo guard: `ui_settings` (F10)
existia no `project.godot` e na tabela de rótulos do `DeviceManager` sem um único consumidor
— a linha do painel rebindava o nada, em qualquer estado; e o `ui_f10` de
`Gui.gd:_input`, único caminho de teclado para `ToggleIdleMode`, nunca existiu no InputMap —
`is_action_pressed` de ação inexistente devolve `false` para sempre, sem erro e sem log.
Fix: guard condicionado linha a linha (comportamento fora do jogo preservado, `ui_validate`
explícito só em menu porque Enter é do `LineEdit` do chat durante o jogo), `ui_settings`
ligado a `ToggleControl(settingsWindow)`, e o HUD idle movido para F12 crua — F10 já era
`ui_settings`. O que sustentou a medição: `project.godot` declara 70 ações e o `InputMap` em
runtime tem 150 (nativos do motor inclusos); os bindings vivem em `physical_keycode` com
`keycode: 0`, o que fez F1–F11 parecerem soltos na primeira leitura. Guard novo em
`SuiteInputHotkeys`: (1) varre as 130 linhas de consumidor de `sources/` (18 tokens, incluindo
os wrappers `TryJustPressed`/`IsUsable`) e exige existência no `InputMap` para as 66 ações
coletadas; (2) cada uma das 56 linhas do painel precisa existir **e** ter consumidor; (2b) as
69 chaves da tabela de rótulos do `DeviceManager` precisam existir; (3) aperta a tecla de
verdade — `Input.action_press` + `InputEventAction` entregue ao `_input` do serviço, porque
`Input.parse_input_event` popula `pressed` mas nunca `just_pressed` em headless — e exige
inversão de visibilidade em seis janelas, aba certa em três atalhos de hub, `ui_validate`
negado dentro do jogo e aceito fora dele, e F12 com eco. **Por que nada pegava:** o harness
`tests/test_e2e_implementation.gd` é de existência (`get_script_method_list`), não de
comportamento — a linha 22 dele "prova" `ToggleIdleMode` enquanto o atalho que o chama estava
morto há sempre. **A limitação vira (j2) e é corrigida na mesma passada:** teclado era a única
porta do HUD idle — `ToggleIdleMode` tinha um chamador só no repositório, a tecla crua F12 dentro
de `Gui._input` — e Web/touch não têm essa tecla, na plataforma em que o beta entrega o cliente.
Entrou `IdleHudButton` na barra que `AddManualSkillButtons()` monta (a mesma função que o caminho
de jogo chama em `Gui.gd:383`), `toggle_mode` para que o estado do modo apareça sem ler texto, e
a sincronia nos dois sentidos: `ToggleIdleMode` devolve `set_pressed_no_signal(idleMode)` no botão,
porque sem isso F12 vira o HUD e o botão continua marcando o modo anterior — o jogador toca no
"OFF" e não acontece nada, que é a mesma classe de defeito deste achado. Oito checks novos em
`SuiteInputHotkeys` cobrem existência, os dois sentidos da sincronia e o toque; medidos com
mordaça: arrancar a linha de sincronia → 2 falhas, botão vivo mas com `pressed` desconectado →
1 falha, árvore real → 201/0 no harness reduzido. **O que continua não medível neste host:** se o
botão aparece e responde ao dedo no navegador (sem export Web nem navegador aqui) — a régua prova
fiação e estado, não renderização.

**(k) ordem de listagem virou número de migration** — `FileSystem.ParseExtension` devolvia o
que `DirAccess` listasse, sem ordenar, e `SQL.ApplyMigrations()` usa o índice do array como
versão (`patches[currentVersion]` num `while patchCount > currentVersion`). Não é cosmética: com
46 patches na pasta, uma listagem trocada aplica o patch errado e grava a versão certa — o schema
fica divergente do número sem levantar nenhum erro. Medido nesta passada: no source tree a
listagem nativa já vinha ordenada (001..046, zero pares fora de ordem) e um boot limpo replayou
os 45 patches com zero erros até `version = 46` e 53 tabelas (`/tmp/fresh_boot.db`). O que **não**
foi medido — e por isso a metade seguinte fica registrada como HIPÓTESE, sem redução de nota — é
o caminho do servidor de produção: ele roda de um `.pck` exportado (`deploy/server/Dockerfile`) e
a ordem dentro do pacote não é observável neste host (sem templates de export instalados), enquanto
o teste de contrato (`boot: a base corrente chegou à versão do diretório de patches`,
`tests/IdleTests.gd:4966`) enxerga só o source. Fechado por contrato explícito: `patches.sort()`
em `sources/system/FileSystem.gd:250`, que tem exatamente dois consumidores — o `ApplyMigrations`
e o teste — e não muda nada do que roda hoje nos dois caminhos medidos.

**(k2) a outra metade de (k): o que entra no `.pck`, e o que eu desmenti no caminho** — a
pergunta que sobrava em (k) não era só ordem, era *presença*: o servidor roda de um `.pck` com
`export_filter="customized"` + `customized_files={"res://": "strip"}` e
`include_filter="data/db/*,data/conf/*,data/themes/*"` (`export_presets.cfg`, preset
`Linux/X11 Headless Server`), e as 46 migrations moram em `data/conf/migrations/` — ou seja, a
presença do schema de produção depende desse filtro alcançar um subdiretório. Medido nesta
máquina, sem templates de export: `match` e `matchn` em Godot 4.7.2 tratam `*` **atravessando**
`/` (probe direto no engine, com os nomes reais: `data/conf/migrations/046_age_gate.sql` e
`data/conf/paid_catalog.json` → `true` nos dois métodos; `data/maps/faro/descida.json` → `true`
em `data/maps/*`, que é o exclude do mesmo preset — o autor já conta com matching recursivo dos
dois lados), então o aninhamento do padrão não é o problema. O que continua não medível é a
precedência entre `strip`
em `res://` e o `include_filter` — e é isso, não a ordem, que faria um boot de produção não ver
patch nenhum. Fechado com o que dá para fechar aqui: `ApplyMigrations()` agora distingue os
quatro casos numa função pura (`SQLService.MigrationPlan`: `empty` / `stale` / `uptodate` /
`apply`) e **reclama** nos dois primeiros, que antes eram no-op silencioso — `0 == 0` devolvia
antes de tudo e o server subia sem schema nenhum, saudável no healthcheck (que não olha schema)
e morto no primeiro login; e binário mais velho que o schema (rollback de deploy, rotina) não
aplica nada sem dizer nada. Mais dois checks travam o texto do preset (`data/conf` no include,
ausente do exclude) e um trava a fiação (`ApplyMigrations` consulta `MigrationPlan`).

**Retração registrada, do mesmo passo.** Eu classifiquei `patchCount < currentVersion` como
hazard de corruptibilidade: "o `SetVersion` do fim regrava a versão PARA BAIXO e o boot seguinte
reaplica migrations não idempotentes (23 arquivos com `ALTER TABLE`/`RENAME`/`DROP`, erro engolido
por `Query()`, que devolve resultado e não status)". **Não é verdade**, e foi o próprio teste que
desmentiu: desativar a guarda por mutação manteve os 26 checks verdes, porque `currentVersion` é
lido de `GetVersion()` e o `while` nunca o decrementa — `SetVersion` regrava o número que já
estava lá. O check que eu tinha escrito para provar a tese (`"ver com menos patches que a base
não regrava a versão"`) era tautológico: passaria verde com o defeito de volta, exatamente a
classe de verde-falso que o gate de §24-8 existe para pegar. Os dois checks foram retirados, a
justificativa no fonte foi corrigida, e o que sobrou é a afirmação menor e verdadeira: os dois
casos eram *mudos*, não destrutivos. Nada aqui reduz nota do projeto — não havia bug confirmado
para reduzir; havia um gap de observabilidade meu, agora fechado.

**(l) `AuctionHouseWindow.gd` existe e nada o instancia — medido, e não vira achado.** O painel
(116 linhas, `extends WindowPanel`, filtros de nome/tipo/teto + histórico das últimas 10 vendas)
não tem um único referência em `sources/` (`grep -rln AuctionHouseWindow sources` devolve só o
próprio arquivo), e os dois botões de HUD "AH"/"Leilão" (`sources/gui/ManualHudBar.gd:63-78`, depois da fatia (t)) caem em
`_on_ah_pressed`, que manda uma notificação dizendo para o jogador digitar `/ah list`, `/ah buy`,
`/ah sell`. Não é bug e não foi "esquecido na passada": o servidor tem `BrowseListings`
(`sources/economy/AuctionHouseService.gd:161`) mas a resposta sai por `Network.CommandFeedback` —
texto no chat, não estrutura — então ligar o painel exigiria **RPC novo de listagem**, e o §24 já
colou isso como **U1, pós-beta** ("AH com RPC e botões"). Ligar agora seria embarcar uma UI sem
canal de dados, que abre vazia e diz "nenhum anúncio" para sempre: pior que o comando de texto
honesto que existe hoje. Registrado para que o próximo leitor não conte o painel órfão como
trabalho pela metade do beta.

A varredura que sustenta o parágrafo, medida na mesma passada (não é anedota de um arquivo só):
todos os `.gd` de `sources/gui/` com `class_name` foram procurados por referência cruzada —
**um** resultado, `AuctionHouseWindow`. Repetida sobre `sources/` inteiro (todas as classes), a
lista subiu para seis nomes sem referência por classe, e cinco deles **estão vivos**:
`AmbientPolygon` (5 cenas), `PortGlobal`, `SnakePitClueGlobal`, `RedQueenGlobal`, `JumpAbility`
(1 cena cada) são carregados por caminho em `.tscn`/`.tres`, onde `class_name` não aparece. A
conclusão que o número permite é estreita e escura ao mesmo tempo: `AuctionHouseWindow` é o único
painel do repositório sem host de cena **e** sem chamador — e, ainda assim, a lógica pura dele já
está sob a régua (cinco checks em `tests/IdleTests.gd:3492-3497`: busca, ordenação por preço,
filtro de tipo, teto de preço e histórico). Falta host, não falta teste.

**(m) a porta do dinheiro não tinha maçaneta — um `_ready` que abortava, e o buraco de cobertura
que o escondeu.** `sources/gui/Checkout.gd:63` era `_statusLabel.autowrap = true`. `autowrap` é
nome de propriedade do Godot 3; em 4 é `autowrap_mode`. Escrever numa propriedade que não existe
não é warning — é `SCRIPT ERROR` no meio da função, e o erro **aborta a função**:

```
SCRIPT ERROR: Invalid assignment of property or key 'autowrap' with value of type 'bool'
          on a base object of type 'Label'.
          at: _BuildUI (res://sources/gui/Checkout.gd:63)
          GDScript backtrace (most recent call first):
              [0] _BuildUI (res://sources/gui/Checkout.gd:63)
              [1] _ready (res://sources/gui/Checkout.gd:32)
```

`_BuildUI` constrói os controles em fila, e a linha 63 estava no meio da fila: tudo que vinha
depois dela nunca existia. (As duas linhas citadas — 63 no `_BuildUI`, 32 no `_ready` — são do
registro, com o arquivo como estava antes da correção; a correção acrescenta campos no topo e
empurra tudo para baixo.) O `_payButton` vem depois. Ou seja, no cliente Web o diálogo de
checkout do Mercado Pago abria com título, preço e detalhe, e **sem botão de pagar** — a rota
inteira do item 5 do §24 (chave PJ, `POST /checkout/preference`, intent assinado) terminava numa
janela que não tinha o que apertar. Terceiro caso desta família registrado no repositório — os
dois primeiros estão narrados na suíte que cuida do `Onboarding` (um `_label.autowrap` e um método
que não existia, um em cima do outro): `tests/IdleTests.gd:1498-1504` narra
exatamente a mesma coisa no `Onboarding` (`_label.autowrap` derrubando `_ready`, "os três botões
nunca eram criados"), com uma segunda peça morta em cima (o `get_sessionfirstlogin` que não
existia). Varredura da família em `sources/` — `.rect_*`, `.valign`, `.align =`, `.autowrap =`,
`.percent_visible`, `.uppercase`, `.readonly`, `.enabled =`, `.custom_*` — devolveu zero outras
ocorrências; este era o último.

**Por que nada via:** o painel não nasce do scene nem do boot — nasce sob demanda, e só quando o
jogador pede compra (`Shop.gd:265`, `Launcher.GUI.checkoutWindow = CheckoutDialog.new()`, com
`const CheckoutDialog = preload(...)` em `Shop.gd:9`; `Checkout.gd` não tem `class_name`, por isso o
medidor de baixo o endereça por caminho). Dor de cabeça de cobertura é assim: dos seis painéis de
`.new()` do repositório, quatro são montados dentro de `Gui._ready`
(`Localizer` `Gui.gd:707`, `Onboarding` `Gui.gd:287`, `BossInterruptOverlay` `Gui.gd:722`,
`UIHighlight` `Gui.gd:162) e portanto têm `_ready` rodado junto com o HUD; dois são adiados
(`ActivitiesWindow` por `EnsureActivities()` `Gui.gd:75-77`, já montado na suíte em
`tests/IdleTests.gd:850`, e `Checkout`). A fronteira é literal, e é o que dá peso à frase
"rodado junto com o HUD": o boot do cliente faz `Root.add_child.call_deferred(Scene)` sobre a
instância de `presets/Client.tscn` e depois **`await Scene.ready`** (`Launcher.gd:202-214`), com
`Launcher.GUI = Scene.get_node("Canvas")` — `Canvas` é `presets/gui/Game.tscn`, que em
`Overlay/VSections/Contexts` carrega `Character.tscn` (`Game.tscn:349`), cujos quatro scripts
(`Character`, `Traits`, `Attributes`, `Stats`) moram em `sources/gui/character/`. Todo `_ready` de
painel **montado por cena** roda, portanto, em cada passada headless, e o `grep ^SCRIPT ERROR` do
gate é uma prova sobre ele. O que não roda é o que só existe depois de um clique — e o único
deles sem suíte era este. Um `_ready` que aborta num dos primeiros aparece como
`SCRIPT ERROR` em qualquer passada; o mesmo defeito no último não aparecia em lugar nenhum, porque
nada o construída — e o gate da CI prova `^SCRIPT ERROR` no log (`scripts/ci_gate_log.sh`), mas um
`SCRIPT ERROR` só existe quando o código roda. Correção de uma afirmação que eu teria feito semana
passada: `BossInterruptOverlay` e `UIHighlight` **já eram construídos no boot**; o que neles estava
descoberto eram os métodos de comportamento, não a construção. O único dos painéis de runtime que
nenhum caminho do repositório — nem teste, nem jogador — jamais tinha montado era este.

**A segunda porta, que é o motivo pelo qual o bloco foi escrito.** Abrir a URL de pagamento do
clique funciona; abrir a URL que volta do `POST /checkout/preference` não, porque ela chega de um
round trip e um `window.open` fora da *user activation* é descartado pelo bloqueador de popup do
navegador. O jogador ficaria olhando "awaiting confirmation" de uma aba que nunca abriu, e o grant
do webhook não teria o que confirmar. Então `_open_payment_url` foi partido em
`_show_payment_url` (metade visual: status, rótulo, guardar a URL, mostrar a porta — **não toca o
navegador**, portanto verificável headless) e `_launch_payment_url` (o único caminho para fora da
tela: `JavaScriptBridge.eval` no Web, `OS.shell_open` no desktop), e apareceu um botão comum
"Abrir página de pagamento" — comum de propósito, porque quem abre a aba tem que ser um clique do
jogador, e um clique é o que reabre a janela de activation; um `LinkButton` não seria. Escrever o
bloco de checks ainda achou um defeito de estado no caminho: `_show_payment_url` relabela o
`_payButton` para "Close", e reabrir a janela para outro SKU sem resetar deixava um botão rotulado
"Fechar" que, apertado, iniciava uma cobrança. `StartCheckout` agora limpa `_openPaymentURL`,
esconde a porta e devolve o rótulo para `tr("Pay now")` com o botão desabilitado.

**A régua que ficou, e as duas mordaças que não mordiam.** O controle (`SuiteGuiPanels` num harness
de ~10 s) andou 50 → 57 com o bloco do checkout → 76 com o do overlay/highlight/inventário → 77.
Depois disso biteria? Lote 1: 10 mutações, todas derrubaram exatamente o check esperado. Lote 2
inicial: duas **não** derrubavam nada, e as duas eram checagens minhas mal formadas, não sorte do
código. (i) `clear_nao_devolve_modulate` — apagar `_target.modulate = _originalModulate` de
`UIHighlight.Clear()` passava igual, porque em headless nenhum frame roda, o `Tween` do `Show` não
avança e o `modulate` nunca sai do lugar: o check era tautológico. Conserto: escrever o valor do
primeiro step do tween (`Color(2.0, 1.5, 1.5, 0.2)`) entre `Show` e `Clear`, o que além de fazer a
devolução morder ainda põe a **ordem de captura** do `Show` na régua (duas mutações a mais,
`show_sem_captura` e `show_nao_adota_alvo`, agora mordem). (ii) `flash_empilha` — contar retângulos
por `find_children("RewardFlash")` é **cego ao empilhamento**: probe direto no engine mediu que o
segundo `ColorRect` com o mesmo nome entra renomeado (`["@ColorRect@3"]`), então a busca por nome
devolve 1 tanto no reuso quanto na falha. Conserto: contar `ColorRect` filhos e medir o delta entre
dois `Flash` seguidos — o que também desemparelhou o check do pulso do veredito (a versão antiga
contava `get_child_count()` depois do `ShowFeedback("perfect")`, e uma mordaça no `ShowFeedback`
derrubava o check de empilhamento por tabela). Lote 3 final: 13 mutações, todas mordendo, com
`sources/`, `tests/` e `data/i18n/ui.csv` restaurados byte-idênticos ao digest do início
(`íntegro no fim: True`).

**O inventário que saiu disso.** A pergunta "quantos painéis nascem de `.new()` e nunca são
construídos por nenhum harness?" não merece uma resposta de memória, então virou medidor:
`_RuntimeBuiltGuiPanels()` varre `sources/**/*.gd` procurando `class_name` e os `preload` + `X.new()`
correspondentes e devolve painel → construtores; o resultado (seis: `Activities`,
`BossInterruptOverlay`, `Checkout`, `Localizer`, `Onboarding`, `UIHighlight`) está colado no const
`runtimeBuiltGuiPanels` (`tests/IdleTests.gd:1104-1111`) e a suíte compara os dois. A primeira versão
do medidor achou **um** dos seis: o PCRE do Godot não trata `^` como início de linha sem `(?m)`, e
o padrão de `class_name` era ancorado. O const é a parte incômoda de propósito — nascer um painel
novo em runtime faz a suíte falhar com os dois conjuntos impressos, e o que se faz quando ela falha
é montar o painel numa suíte, não editar o const no escuro. `WindowPanel` fica fora por ser a base
de quase todo o HUD. A legenda nova (`"Open payment page"` → "Abrir página de pagamento") entrou em
`data/i18n/ui.csv` e os `.translation` rastreados foram regerados pelo mesmo passo da CI
(`godot --headless --editor --import --quit`); o `check` de pt_BR falhou antes disso, e é assim que
se sabe que o `.csv` editado ainda não virou o que o cliente lê.

**(n) dezenove `tr()` pedindo chave que ninguém cadastra — a auditoria manual de i18n virou
invariante.** O bloco de i18n da suíte cobrava algumas chaves escolhidas a dedo (exclusão de conta,
placeholders do `Localizer`, amostras de conteúdo). Isso não diz nada sobre a string que alguém
acrescenta amanhã. Então varri o texto: `_GdFilesUnder("res://sources")` são **279 arquivos `.gd`**,
e sobre eles `tr\("…"\)` depois de `_StripCommentLines` acha **95 chamadas literais**, **83 chaves
distintas**. A régua de cada chave é `get_message(chave) == ""` no `data/i18n/ui.pt_BR.translation`
**compilado**, não no `.csv`: em runtime o `tr()` lê o `.translation`, e medir pelo csv seria passar
por cima exatamente do estado que o item (m) descreveu — o texto já mudou no `.csv` e o que o cliente
lê ainda não mudou. Dezenove chamadas não tinham linha. Distribuição medida, arquivo por arquivo:

- `sources/gui/Settings.gd` — **13**, e não são 13 strings soltas: é **o fluxo 2FA inteiro**
  (título dos dois diálogos, a instrução do QR code, a do código de 6 dígitos, "I have saved the
  code", "OK", as mensagens de ativado/desativado, "That code did not match…", "Wrong password —
  two-factor authentication stays enabled."). Ou seja, o jogador BR que liga autenticação em dois
  fatores lê a tela de segurança do produto **em inglês**, inclusive quando erra o código. É a
  superfície mais sensível que existe para erro de tradução, porque é onde um texto mal entendido
  custa a conta.
- `sources/gui/Checkout.gd:242` — **1**: `Payment blocked: log in again to accept the current agreements.`
  É a string que explica **por que** a cobrança está bloqueada, na porta do dinheiro. Sem linha, a
  conta barrada no gate de idade — ou qualquer conta sem o aceite vigente, inclusive as pré-046 — lê
  `Payment blocked…` em inglês e não sabe o que fazer.
- `sources/gui/AfkReport.gd` — **4**. Três são linhas faltantes (`Drops: %d`, `Efficiency: %s %d%%`,
  `2× ad armed — applies on Collect (4× with VIP)`). A quarta é outra coisa e o medidor é que mostra:
  `AfkReport.gd:19` chamava `tr("Carregando...")` — **chave escrita em português**. O catálogo já tinha
  `"Loading..."` → "Carregando...", então não faltava tradução nenhuma; sobrava uma chave que ninguém
  cadastra, e `tr()` de chave ausente devolve a própria chave. O conserto certo foi trocar a chamada
  por `tr("Loading...")`, não acrescentar a 19ª linha — duplicar a linha deixaria duas entradas para a
  mesma string na mesma tela.
- `sources/gui/character/Stats.gd:68` — **1**: `maxed`.

Lote: **18 linhas novas** no `ui.csv` (957 → **975** linhas no arquivo, 973 de dados; contra `HEAD`,
que tem 956, o saldo da árvore é +19 — as 18 deste lote mais a `"Open payment page"` do item (m), com
4 linhas reescritas no meio), os dois `.translation` regerados pelo mesmo passo da CI, sem um
`SCRIPT ERROR` na importagem. Medido no catálogo de hoje: **0 linhas com `pt_BR` vazio** e **9 linhas
de eco** (`en == pt_BR == chave`: `"+%s XP"`, `"..."`, `"ARGH."`, `"Blackjack!"`, `"Arena"`,
`"Tickets: %d"`, `"ELO: %d"`, `"Evento: %s (até %s)"` e o `"OK"` deste lote). Eco não é regra de
falha: o `pt_BR` das strings de consentimento é cobrado uma a uma no bloco LGPD, e uma regra
"eco = falha" derrubaria a suíte por linhas que estão certas.

**A invariante.** `tests/IdleTests.gd:1038-1050`, dentro de `SuiteGuiPanels()` — que
`tests/run_idle_tests.gd:258` chama, então ela roda no gate da CI e não só no harness rápido. Se o
pt_BR compilado não carregar, o guard falha;
senão varre as 95 chamadas e exige `semTraducao == 0`, imprimindo `arquivo :: chave` de cada uma. O
harness de checkout foi de 77 para **79 checks** com ela (a presença do catálogo + a varredura).
Mordaças (`/tmp/bite_i18n.py`, quatro rondas, todas com comportamento esperado):

| mutação | resultado |
|---|---|
| chave literal nova sem linha no csv (título do diálogo 2FA trocado por uma inventada) | 1 falha, exatamente a da varredura |
| a mesma chave **dentro de comentário** | 0 falhas — `_StripCommentLines` a tira antes |
| linha `"maxed"` removida do csv **e recompilada** | 1 falha em `character/Stats.gd :: maxed` |
| `AfkReport.gd` voltando a pedir `tr("Carregando...")` | 1 falha |

O terceiro caso é o que fecha o argumento do catálogo compilado: sem o re-import a linha removida
**não** é vista (o `.translation` antigo continua no disco e o jogador ainda veria "no máximo"), e é a
CI reimportando que transforma o csv na fonte autoritativa. No fim das quatro rondas os quatro
arquivos mexidos (`Settings.gd`, `AfkReport.gd`, `ui.csv`, `ui.pt_BR.translation`) estavam
byte-idênticos ao digest do início — incluindo o `.translation`, que foi reimportado duas vezes e
saiu igual, então a importagem é determinística nesta máquina e o digest serve como prova de
restauração.

**O cruzamento com o medidor que já existia.** O repositório tinha `tools/extract_i18n.py`
(varre `tr()`/`Mes()` em `sources/`, `text =` em `.gd` e `text/title =` em `presets/**/*.tscn`, compara
com o csv e escreve `data/i18n/coverage_report.md`) e o relatório rastreado estava desatualizado em
relação a esta passada. Rodei sem `--write-gaps` e ele bate com o guard em tudo que os dois medem:
**83 chaves `tr()` distintas** — o mesmo número que a varredura da suíte achou, por dois scanners
independentes — e, depois das 18 linhas, **0 faltando** nesse domínio (antes: 81 chaves, 17 faltando).
Os dois medidores divergem numa regra e a divergência é instrutiva: o tool chama de faltante toda linha
cujo `pt_BR` é eco do próprio `key`, exceto uma allowlist `IDENTITY`; o guard aceita eco (o csv tem
linhas idênticas por design). Foi assim que apareceu **uma** chave órfã depois do lote: `OK`, cuja linha
que eu acrescenta diz `"OK","OK","OK"`. Não é um defeito de tradução — é a allowlist que não conhecia o
loanword novo, e `OK` entrou em `IDENTITY` ao lado de `"..."`, `"ARGH."` e `"Blackjack!"`. O
`coverage_report.md` regerado fecha em **UI: 231 de 285 cobertas (81%)**, e as 54 faltantes estão
**fora do alcance do guard**, medida por domínio: 36 em `text = "…"` atribuído em `.gd` e 20 em
`text/title =` dos `.tscn` — as duas superfícies que o `Localizer.gd` resolve em runtime, e que são
justamente o i18n de painéis de Bloco 2/3.

**Limitação que fica dita, não escondida:** a invariante nova é de **literal em `sources/`**.
`tr("A" + b)` escapa de qualquer leitura de texto, e as 56 strings dos outros dois domínios não passam
por ela. Mas há um motivo concreto para o medidor ser o catálogo **compilado** e não o csv: o próprio
tool tem `--write-gaps`, que acrescenta linha como `[key, key, ""]` — isto é, uma linha **presente**
no csv com `pt_BR` **vazio**. Uma régua que pergunta "a chave existe no csv" passa por isso; a que
pergunta `get_message(chave) == ""` não.

**(o) ponteiro de evidência é um endereço que a própria passada invalida.** Os três documentos do
beta (`AUDITORIA_INDEPENDENTE_2026-09-24.md`, `ROADMAP_COMERCIAL.md`, `deploy/LAUNCH_HANDOFF.md`)
citam prova no formato `arquivo:linha`. Toda edição no arquivo citado desloca a linha citada, e esta
passada levou `tests/IdleTests.gd` de **4.115** linhas (o arquivo em `HEAD`) para **7.018** — 2.903
linhas no meio do caminho em que os ponteiros apontavam. A varredura manual achou oito números de
linha fora do lugar e um caminho errado; uma das oito veio da régua nova no primeiro run:

- `sources/sql/SQL.gd:71` → `:101` (o predicate `IsConsentAccepted`).
- `tests/IdleTests.gd:4603` → `:4879` (o check de boot `boot: a base corrente chegou à versão do diretório de patches`).
- `tests/IdleTests.gd:3163-3175` com "seis checks" → `:3405-3410`, **cinco**, e dentro de `SuiteChestOdds`. O caso pior da série: o ponteiro existia, caía numa suíte que a prosa não nomeia, e a contagem da prosa estava errada.
- `tests/IdleTests.gd:1382-1388` → `:1411-1427` (narrativa + checks de `SuiteOnboarding`, `func` em `:1366`).
- `SQL.gd:1245` → `:1275`, em `deploy/LAUNCH_HANDOFF.md`.
- `tests/IdleTests.gd:2611` → `:3772`, em `ROADMAP_COMERCIAL.md` (a escrita de classe que mantém os knobs na fachada).
- `ROADMAP_COMERCIAL.md:90` → a linha das metas declaradas é `:28`.
- `auditoria-tecnica-shambleta.md:116-118` → `:123-125` (a retificação dos spans). **Esta não foi achada por leitura: foi o primeiro run da régua que a devolveu.**
- `server/Peers.gd:270` → o caminho certo é `sources/network/server/Peers.gd:270`. A linha estava certa; achou-a a resolução por nome cru da régua, que é o item (1) abaixo.

Régua: `SuiteEvidencePointers` em `tests/IdleTests.gd` (registrada por último em
`tests/run_idle_tests.gd`, porque não toca estado nenhum — só relê a documentação contra a árvore
atual). Três regras:

- **(1) linha cabe no arquivo, com resolução por nome cru.** Se o arquivo citado existe, a linha
citada tem que caber nele. A documentação escreve ponteiro das duas formas — re-medido em 2026-09-25
na linha `[info]` do próprio run, são **145** ocorrências `arquivo:linha` nos três docs: **56** com
caminho e **89** com nome cru
(`Gui.gd:681`). No começo a régua só resolvia caminho, ou seja: das 145 ocorrências de hoje ela veria 56 —
um terço da evidência que dizia estar olhando. Por isso ela agora indexa a árvore (`res://`, pulando dot-dirs) e resolve nome
cru quando o nome é **único** na árvore; ausente é histórico legítimo (a prosa sobre o `gut_runner.gd`
apagado tem que poder existir) e ambíguo não tem como decidir. Dos 47 nomes crus citados, 46 são únicos;
a exceção é `README.md`, para a qual vale a raiz do projeto. Foi essa resolução que achou o nono ponteiro da
lista, um erro de caminho que a varredura de linha não podia ver.
- **(2) mensagem bate com a linha.** Se a prosa na janela do ponteiro cita uma mensagem de check
entre aspas **e** essa mensagem existe no arquivo, ela tem que cair no intervalo citado (±2). A regra
estreitou depois de abrir a resolução por nome: aí apareceram quatro ponteiros acusados de citar
check quando citavam **rótulo de interface** (`"UI gráfica em desenvolvimento"` em `Gui.gd`,
`"SetupTwoFactor"` em `Settings.gd`, `"18 years old or older"` em `Login.gd`). Em arquivo de código a
linha encontrada agora precisa ser uma chamada de check de verdade — âncora `Check…(`, e não o
substring `Check`, que casava com `consentCheckBox` e fingia um teste onde há um `CheckBox`. Em `.md`
a citação é prosa sobre prosa e o match continua solto, que é o ramo que pegou a oitava referência da
lista.
- **(3) nome de suíte existe.** Todo `Suite*` citado nos docs tem que ser `func` em
`tests/IdleTests.gd`. Medido antes de escrever a regra: os 89 `func Suite*` do repositório inteiro
vivem todos naquele arquivo (`grep -rn "^func Suite" tests/*.gd` por arquivo), e os 29 nomes citados
nos três docs resolvem contra eles — um scanner independente em Python e a regra em GDScript
chegaram ao mesmo 29, que é o tipo de concordância que justifica a regra ficar. Nome não drifta com
edição, e é a classe de defeito que já foi achado nesta auditoria: documentação afirmando
cobertura de um teste inexistente.

Cobertura medida no run de hoje: **148** referências `arquivo:linha` resolvidas e dentro do arquivo;
**6** pares de ponteiro + mensagem de check citada na prosa e batendo com a linha; **29** nomes de
suíte existentes.
O guard imprime os três números no log, porque um "0 falhas" sozinho não diz quanto foi olhado — que
é exatamente a classe do problema. Das 150 ocorrências do parágrafo acima, duas ficam de fora por
construção, e as duas são o mesmo ponteiro: `server/Peers.gd:270`, que este documento cita duas vezes
exatamente como exemplo do desvio de caminho — e é este próprio achado. Nome com barra não é chutado
por matching de sufixo, então a régua não adivinha nem ali; o outro lado do par
(`sources/network/server/Peers.gd:270`) está dentro das 148. Custo medido na sonda rápida que roda a
suíte sozinha: 2.000 a 2.409 ms em quatro medições seguidas nesta máquina (2.409, 2.286, 2.184 e
2.000), porque a régua é O(tree) e o número individual não é reprodutível entre runs — o índice da árvore
(varredura recursiva de `res://` pulando dot-dirs, balde de três caminhos por nome; 3.753 arquivos na
árvore de hoje pelo mesmo critério) é construído uma vez por processo. Os números da régua bateram com
os do scanner independente em Python escrito do zero fora da árvore: 148 resolvidas e 29 nomes citados,
zero fantasmas contra os 89 `func Suite*` definidos.

As três têm prova de que **discriminam**, não só de que passam. (1): mutação do ponteiro do check de boot (a linha que hoje é `:4879`) → `:999999`
devolveu uma falha com o diagnóstico linha-exata (`tem 6897 linhas`, o tamanho do arquivo naquele
instante) e o arquivo voltou byte-idêntico (digest `3dd28b1d…` antes e depois). (2): dois ramos
sondados — reverter o ponteiro `.md` para o drift antigo (`:123-125` → `:116-118`) devolve
`cita "func StartSpan", que está em :125`, e citar a mensagem real do check de boot apontando para
`:5000` devolve `que está em :4861`; nos dois casos o documento voltou byte-idêntico. (3): acrescentar
um sufixo inventado a um nome citado, no arquivo, não aqui — devolveu `1 vs 0` nomeando o fantasma,
com o documento restaurado byte-idêntico (digest `108887175…`). O texto desta frase não pode grafar o
nome inventado por extenso: a regra (3) varre prosa, não só backticks, e o documento passou a falhar
na própria régua até eu cortar o token.

**O limite, dito em vez de escondido, e a razão do formato.** Probei uma quarta regra — exigir que o
identificador logo depois do ponteiro apareça na linha citada. Medido na árvore de hoje, com a mesma
varredura independente em Python: dos 148 ponteiros que a régua resolve, **127** têm um identificador
colado no ponteiro, e **114 deles falhariam** — nove de cada dez ponteiros acusados por run. A classe
está medida, não deduzida: 23 são prosa pura, palavra da frase que vem depois (`ating`, `corrige`,
`muitas`, `narrativa`), e 91 são tokens que existem na árvore mas não na linha citada — nome do
*próximo* arquivo de uma lista (`CONCLUSAO_FINAL_ROUND_19`, `RELATORIO_FINAL_2026`,
`ROADMAP_COMERCIAL`), começo de frase seguinte (`Dois`), ou símbolo que a sentença discute em outro
lugar (`SeasonsBetaLock`, `CheckoutService`, `OpenReconsentDialog`, `WorldCommands`). Não entrei a
regra: uma régua com uma centena de falsos positivos por run é uma régua que alguém manda calar na segunda
semana. Consequência
real — o deslocamento *dentro* do arquivo, que é a classe que mordeu aqui, só é pegado quando a prosa
cita a mensagem literal do check ou nomeia a suíte. Então ponteiro novo se escreve com **nome +
mensagem** (a suíte e o texto do check), e o número de linha é conveniência de navegação, não
evidência. Os ponteiros das seções de achado (§1–§12) estão sob a mesma varredura, sem exceção
concedida: passam na (1), a (2) não os testa porque a prosa de lá não cita mensagem literal, e a (3)
os cobre porque nome de suíte não depende de janela.

**(p) Clique dentro do aceite não navegava no export Web.** `[CÓDIGO]` `[TESTE]` — **corrigido e
guardado nesta passada.** O beta roda no navegador, e o export Web é o alvo medido do produto. O
caminho do dinheiro já tinha aprendido isso da pior maneira: abrir a página de pagamento com
`OS.shell_open` não leva ninguém a lugar nenhum no Web, e por isso `sources/gui/Checkout.gd:194-198`
faz `JavaScriptBridge.eval` com `window.open` quando `LauncherCommons.isWeb` (`sources/launcher/LauncherCommons.gd:34`,
`OS.has_feature("web")`) e só cai no `shell_open` no desktop. Dois outros sites navegavam para fora com
o `shell_open` cru: o handler de clique de link do painel de texto, `sources/gui/Scrollable.gd:51-58`,
que é **exatamente o painel do aceite** — o jogador marcando a caixa de 18+ com o corpo dos Termos na
frente, e o corpo tem dois `[url=]` (`data/db/agreement.json:63`); e o botão do Discord,
`sources/gui/Gui.gd:266-273`, cujo destino chega ao jogador na primeira mensagem de erro de rede
(`sources/gui/Login.gd:128`). A cobertura que existia não podia ver: os guards do checkout leem o corpo
de quatro funções **de um arquivo** e afirmam que navegar mora num lugar só — régua de um arquivo para
um problema de cliente inteiro.
**O que entrou:** os dois ramos nos dois sites (mesma forma do checkout, sem abstração nova), e
`SuiteExternalLinksWebBranch` (`tests/IdleTests.gd:7213-7245`, chamada em `tests/run_idle_tests.gd:268`
logo depois da régua de ponteiros, pelo mesmo motivo — só lê a árvore, nenhum estado tocado). A régua é
por **bloco**: varre os `.gd` de `sources/`, e para cada `OS.shell_open(` exige que a função contenedora
tenha `JavaScriptBridge` **e** `isWeb`; linha de comentário não conta como ramo. Medido: 3 sítios em
`sources/`, todos com ramo — **dois** na árvore de hoje, porque o terceiro era o botão do Discord e ele
saiu com a ponte (retificação (4) no rodapé) —, 360–420 ms (quatro medições: 283 na escrita, 396, 399 e 361 na re-medida). Discriminação provada com duas sondas, cada uma revertida
byte-idêntica: arrancar o ramo de `OpenDiscord` devolve `sem ramo: res://sources/gui/Gui.gd:270 em
OpenDiscord` (digest `fb5f899…` antes e depois), e trocar o ramo de `Scrollable` por um comentário que
contém as duas palavras devolve a mesma falha em `_richtextlabel_on_meta_clicked` (digest `0aefcc4…`
antes e depois) — ou seja, a régua não se engana com prosa dentro do código.
**O que esta passada NÃO fecha, e não finge que fecha:** se o link abre de verdade no browser é
exatamente a classe de coisa que não existe nesta máquina (sem templates de export Web, item §Não
medível). O que foi verificado é a consistência com o padrão que o próprio repositório já afirma para
Web, não o comportamento observado na aba.

**(q) O corpo do acordo é inglês-único, e nenhum `tr()` alcança.** `[CÓDIGO]` — **entregável de dono,
não de código.** Duas hipóteses morreram no caminho e valem registradas, porque foram elas que quase
inventaram um problema: os textos **existem** (`data/db/agreement.json`, 8 categorias) e **são mostrados**
no login (`presets/gui/Login.tscn:6` embute o JSON como `ext_resource` no `Scrollable.jsonFile`, e
`_ready()` renderiza); e o arquivo **shipa** em todos os presets, porque `export_presets.cfg:17` tem
`include_filter="data/db/*,data/conf/*,data/themes/*"`. O que sobra, medido: o `content` do JSON está em
inglês, `find` por `*agreement*` devolve um arquivo só (nenhuma variante `pt`), e
`Scrollable.AddContent` monta `label.text` direto da string do JSON — sem `tr()`, então o guard de i18n
não tem como vê-lo: a régua varre `tr("literal")` de `sources/`, e aqui o texto é **dado**, não código.
Consequência para o jogador brasileiro: a caixa que ele marca está em português
(`data/i18n/ui.csv:3`) e o texto que ele lê em cima está em inglês. Cai dentro do perímetro do item 11
(gate de idade + parecer) e é decisão de dono com advogado — traduzir o corpo, ou declarar a política de
idioma. Não escrevo texto legal inventado nesta casa.

**(r) Os dois destinos de suporte que o produto oferece não são o mesmo destino, e nenhum é verificável
aqui.** `[HIPÓTESE]` — **não reduz nota.** ~~`sources/launcher/LauncherCommons.gd:6` fixa um Discord
numérico (servidor + canal), usado pelo botão e pela mensagem de erro de rede; `data/db/agreement.json:63`
fixa um invite vanity e um canal Libera (`#sourceofmana`).~~ A hipótese foi **confirmada pelo dono em
2026-09-25 e resolvida por remoção**: nenhum dos destinos é do projeto — os links eram do upstream do
fork, e o projeto não tem servidor Discord. A ponte (`sources/discord/`), o addon `addons/discord_gd`,
o botão, o endereço horneado em `LauncherCommons` e as duas frases de erro que o apontavam saíram da
árvore; o aceite parou de oferecer invite e canal IRC e `AgreementTosVersion` foi bumpado a `2026-09-c`.
O que este item **não** resolveu é a parte que era do dono: o jogo agora não tem destino de suporte
nenhum, e publicar um continua em aberto (`deploy/LAUNCH_HANDOFF.md` §"Destinos de suporte"). Nenhuma
ferramenta desta máquina decide isso.

**(s) A "heurística multi-conta" coletava a impressão digital do próprio servidor.** `[CÓDIGO]`
`[TESTE]` — **corrigido (coleta removida).** `sources/network/server/Peers.gd:248` é o que sobrou de um
bloco que abria com `DeviceFingerprint.Collect()` dentro de `FinalizeLogin`. Essa função é de servidor —
o chamador está no caminho de autenticação de `sources/network/server/Server.gd:32` — e o coletor tinha
**um único chamador no repositório inteiro**, que era aquele. Consequência: cada conta que logava
gravava em `telemetry_event.fingerprint` o hash do hardware da máquina que serve o jogo, não o do
jogador. Daí descia o resto — a consulta de 7 dias por `fingerprint LIKE` casava com todas as outras
contas, `FlagMultiAccount` abria `fraud_flag` `kind='multi_account'` para quem logava **mais até dez
outras contas**, a cada login, e `multi_account_suspicions` do companion (`companion/server.py:765`), que
agrupa por fingerprint e exige três ou mais contas, só podia devolver um balde. Quatro efeitos lidos no
código antes de qualquer execução: a fila de revisão manual em que o beta se apoia nasceria 100 %
falsa; um `LIKE` com curinga inicial — que nenhum índice atende — no caminho crítico do login; o
evento de login só era gravado se o hash não viesse vazio, ou seja, o funil `d1_return` dependia de uma
coleta que não media nada; e nada disto estava em nenhum dos dois blocos do §24.

O conserto tirou a coleta e o `LIKE` do login (a gravação do evento passou a ser incondicional) e
removeu o coletor, que ficou sem chamador. Amarrei a volta dele por fonte, em `SuiteFraud`, porque o
defeito era justamente uma chamada que *parecia* certa e nenhum comportamento desta suíte a distingue de
uma coleta honesta. Dois checks, cada mensagem inteira na mesma linha do ponteiro — quebrada entre duas
linhas a régua não acha na fonte e **pula a citação em silêncio**:
`tests/IdleTests.gd:3908` "S5: o servidor não coleta hardware próprio como identidade do jogador"
e `tests/IdleTests.gd:3910` "S5: o evento de login continua registrado (funil d1_return vivo)". A API
`EconomyService.FlagMultiAccount` ficou (fila, dedupe e validação já cobertos por check), e o que falta
agora é o produtor — o que não é fiação: exige entropia por instalação (um id persistido no cliente),
coleta no cliente e base legal para levar esses campos. Decisão de dono, e pós-beta: sem detector, a fila
continua servindo as três heurísticas que têm sinal verdadeiro (rajada de trade, velocidade de level,
flip).

**(t) Oito `Gate §24-8 OK` verdes nesta máquina e a CI vermelha no mesmo commit.** `[CÓDIGO]` `[TESTE]` —
**corrigido (a barra de HUD foi fatiada e o gate passou a rodar dos dois lados).** `scripts/check_god_nodes.sh`
é o gate anti-god-node — teto de 800 linhas, allowlist declarada de seis arquivos de legado, listagem
`git ls-files --cached --others --exclude-standard`, então um serviço novo já nasce medido — e a CI o executa
no job `code-health` (`.github/workflows/godot-ci.yml:128`). O `scripts/test.sh all` rodava oito harnesses e
nenhum deles era esse gate. Medido: `sources/gui/Gui.gd` saiu da passada anterior com 772 linhas e estava com
**815** — os +43 são os consertos (j) e (p), os dois caídos na barra de HUD — e o gate devolvia
`::error::god-node: sources/gui/Gui.gd tem 815 linhas (teto 800)`. Não é um defeito de execução e por isso
nenhum check de comportamento o pega: é estrutura, e a régua dela vivia só na CI, que ninguém rodou.
A allowlist do próprio script diz "registra legado, não autoriza crescimento", então a saída era fatiar, não
alargar. Fatiada a **construção** da barra para `sources/gui/ManualHudBar.gd` (92 linhas; `extends
RefCounted`, sem `class_name`, uma função estática só — mesma forma de `sources/ads/AdProvider.gd`, portanto
nunca nasce de `.new()` e não toca o inventário medido de painéis de runtime). O estado (`manualSkillBar`,
`manualSkillButtons`, `idleHudButton`) e o que cada botão faz ficaram no `Gui`: é de lá que `_input`,
`ToggleIdleMode` e a suíte de hotkeys leem, e `tests/test_e2e_implementation.gd:20` exige
`AddManualSkillButtons` como método do `Gui.gd`. Medido depois: `Gui.gd` **749** linhas, gate verde.
O segundo defeito é o que interessa para o beta, e não é do `Gui` — é do radar: gate que só a CI conhece não
é gate de lançamento, é surpresa de diff — e aqui ele nem chega a ser conhecido, porque **o dono está sem
créditos no GitHub Actions e a CI não roda** (decisão registrada em 2026-09-25: a verificação é local).
Espelhei o gate dentro do `all` pelo mesmo quádruplo de §24-8
(`gate_sh`, marcador `Gate anti-god-node:` com a contagem de falhas lida DA LINHA de resultado,
`scripts/check_god_nodes.sh:57`) e amarrei a divergência por fonte, em `SuiteOpsA2`:
`tests/IdleTests.gd:5042` "portão: todo gate de script da CI também roda no scripts/test.sh" varre o yaml
atrás de `scripts/*.sh`, descarta os dois que não são gate (o avaliador do quádruplo e o próprio `test.sh`)
e exige o resto no runner; `tests/IdleTests.gd:5041` "portão: a CI roda exatamente um gate de script próprio"
é o âncora do número, para o guard não passar verde por varredura vazia nem continuar verde quando alguém
abre um segundo gate na CI. Verificado contra o estado que produziu a CI vermelha: com o `scripts/test.sh`
de HEAD, a varredura devolve `mirrored=1`, `missing=[scripts/check_god_nodes.sh]` — o guard falha; com o
espelho, `missing` esvazia. O `all` passou de oito para nove gates (cinco Godot, três Python, um shell).

**(u) O catálogo tinha chave duplicada, e a que morria era a que o jogador lê.** `[DADO]` `[TESTE]` —
**corrigido e amarado por censo.** Medido contra `HEAD`: `data/i18n/ui.csv` tem **954** linhas-chave
com **949** distintas — cinco repetidas: `Attack`, `Next`, `Checkout is only available on web builds`,
`Checkout unavailable: %s` e `Processing sandbox payment...`. O importador de CSV do Godot resolve a
primeira coluna como chave e a última linha vence, então das duas traduções de cada par uma morria no
`.translation` compilado. Quatro dos cinco eram eco inofensivo (`Next` = "Próximo" nos dois lados, e as
três do checkout eram o bloco reanexado com o mesmo texto). A quinta não: `"Attack"` estava cadastrada
como **"Ataque"** (substantivo, o rótulo da coluna de status do personagem) e de novo como **"Atacar"**
(verbo, linha de ação). Confirmado no compilado: `strings data/i18n/ui.pt_BR.translation` devolvia
`Atacar` e nenhuma ocorrência de `Ataque` — ou seja, no locale de lançamento a planilha de personagem
se escreve com o verbo. Não é o defeito do item (n): (n) é chave que ninguém cadastrou, e o guard dele
varre `tr("literal")` contra o compilado, onde uma chave cadastrada duas vezes **passa** — ela existe.
O buraco é o catálogo por dentro, e nenhum dos dois lados (nem o `tr()`, nem o `get_message`) o vê.
Tirei as quatro linhas repetidas, regerei os dois `.translation` pelo mesmo passo da CI
(`godot --headless --path . --import`) e bati no compilado: `Attack` → **Ataque**, zero `Atacar`.
Amarrei por censo na mesma passada, com o tamanho ancorado de always-green que é a regra da casa:
`tests/IdleTests.gd:1071` "i18n: o censo do ui.csv olhou um catálogo inteiro" e `:1072` "i18n: nenhuma
chave repetida no ui.csv". Re-medido no fim: **971** chaves, **971** distintas.

**O que separa "beta" de "pronto" hoje, em uma linha por dono:** código — nada pendente em
Bloco 0 ou Bloco 1, com uma ressalva que vale como método: as passadas que escreveram os itens (m), (n),
(p), (s), (t) e (u) acharam, cada uma, um defeito que **não estava em nenhum dos dois blocos** — na porta do
dinheiro, `_BuildUI` abortando antes de criar o botão de pagar; no i18n, o fluxo de 2FA inteiro e a
string que explica um pagamento bloqueado sem linha no catálogo, e uma chave duplicada que trocava o
rótulo de status pelo verbo; na navegação externa, o clique do
aceite sem ramo Web; na fila antifraude, um detector que media o próprio servidor; na estrutura, um gate
que só a CI conhecia e uma CI vermelha convivendo com oito gates verdes na máquina. "Nada pendente" quer dizer "nada pendente do que a auditoria
sabia listar", e o que ela não sabia listar tinha uma suíte descoberta por cima. Dono do projeto — chave PJ do Mercado Pago (item 5), parecer jurídico
sobre baús/gacha antes de aceitar dinheiro de maiores declarados (item 11), idioma do corpo do acordo
(item q) e posse dos dois destinos de suporte (item r). **Não medível
nesta máquina, e por isso ainda aberto:** as três coisas que só existem fora do headless.
`docker`, `podman` e `nginx` não estão no host e `~/.local/share/godot/export_templates`
está vazio (medido nesta passada) — logo ninguém booted a stack do compose, ninguém exportou
o Web, e nenhuma das ramificações de navegador foi vista rodar: primeiro load real (~32 MB),
WSS, `JavaScriptBridge.eval("window.location.origin")` na rota de checkout, o `POST
/checkout/preference` saindo na mesma origem da página e o 403 `consent_required` aparecendo
na janela. Isso é a lista do `deploy/LAUNCH_HANDOFF.md` §4, e fechar código não a fecha.

**Bloco 2 — pós-beta.**
12. U1 — AH com RPC e botões (comprar/anunciar slots/histórico), moeda rotulada corretamente, seed de gear ou fricção menor para vendedor.
13. X1 — sink de ouro proporcional (taxa de venda queimada 1–2%), com a razão de reposição virando KPI observado.
14. B1 — SSV de anúncios; semente de baú com HMAC de segredo do servidor (se o baú sobreviver à decisão legal).
15. O1 — economia para config hot-reload (JSON/tabela), que destrava preço dinâmico, oferta e A/B; **só com dados de conversão reais** para justificar o esforço.
16. W1 — painel GM com trilha de auditoria, enforcement do fraud-scan, denúncias de jogador.

**Bloco 3 — longo prazo.**
17. Sharding real de `archive/SHARDING.md` — **somente** se a retenção sustentar CCU que justifique; hoje é prematuro.
18. iOS + cross-save declarado como produto, não subproduto.
19. Reavaliar a decisão "shell de MMO" quando houver dados de quais janelas são abertas.

## 25. PLANO DE AÇÃO E A RESPOSTA SOBRE O DINHEIRO

**Se eu fosse responsável pelo capital investido no Shambleta:**

**Os três maiores riscos.**
1. **Risco de fidúcia, não de tecnologia.** O produto anuncia a si mesmo com notas 9,2–9,5 fundamentadas em arquivos que não existem e num script que fabrica o resultado de teste. Um investidor que leia `AUDITORIA_SHAMBLETA.md` compra uma imagem que o repositório não sustenta. Isso é o mais caro, porque invalida o processo de decisão e já produziu dois resultados concretos: um healthcheck que aponta para um servidor fictício, e uma nota de "Testes 9,5" enquanto nenhum teste de segurança existia. `[CÓDIGO]`
2. **Risco de caixa imediato.** Se alguém abrir o beta com as chaves do Mercado Pago postas, o produto **cobra e não entrega** (D1), e em caso de crash **entrega duas vezes** (E3), sem nenhum caminho de medição para saber qual foi o erro (K1). Receita nula, reembolso em massa, reputação queimada no canal onde o boca-a-boca é o único crescimento possível.
3. **Risco de conta.** Com S1, um único cliente malicioso apaga contas alheias, estorna em nome de outros e executa comando GM como a vítima. Isso não é "vulnerabilidade futura": é o produto em pé sobre uma primitiva de identidade quebrada, e um incidente no dia 1 de beta é suficiente para encerrar o projeto com a base FOSS de origem já predisposta contra o fork comercial.

**Os três maiores oportunidades.**
1. **O diferencial existe e ninguém mais entrega:** MMO idle com **save server-side cross-platform web↔Android↔desktop** + economia de jogador com escrow + **ausência verificável de gems→poder**. Melvor é single-player e sem mercado; AFK não tem trade; Albion não é idle; OSRS não é free. E o argumento de fairness (arena não multiplica poder por VIP) **está intacto no código** — C2 confirmado. É posicionamento defensável, não aspiracional.
2. **A fronteira de dinheiro já foi construída e testada** — HMAC, re-fetch autoritativo, idempotência, refund CDC de 7 dias, LGPD comportamental. A maioria dos indie-teams chega ao beta sem nada disso. O trabalho que falta nela é de **chave e coluna**, não de arquitetura.
3. **A curva é matematicamente correta** — o prestígio acelera, não pune, e a série converge sem burnout geométrico. Isso é retenção estrutural pronta; o que a impede hoje é que as features que dariam motivo de retorno no dia 30 estão atrás de um `const` ou sem dados semeados.

**O que eu faria na primeira semana, em ordem.**
(1) corrigir D1 e S1; (2) escrever os handlers de 2FA e fechar o chat; (3) tornar o grant atômico e o stub de anúncio configurável; (4) apagar `gut_runner.gd` e republicar as notas honestas — inclusive para mim mesmo, para que qualquer decisão futura parta de números que passaram; (5) só então abrir conta e chaves no Mercado Pago e validar **uma compra real ponta-a-ponta**; (6) decidir baú pago com um advogado na mesa.

**O que eu não faria**, e é a parte mais valiosa deste documento: **não reescrever**. Não trocar SQLite no meio de um beta com 200 CCU-alvo, não fragmentar `Network.gd` de novo (o P4 já foi revertido), não introduzir sharding, não re-arquiteturar a economia (o fatiamento em 12 serviços já foi feito e está verde), não migrar de motor nem de linguagem, não reescrever o cliente em HTML só para resolver a densidade de janelas. Cada um desses teria custo em semanas e benefício mensurável nenhum em receita, retenção ou segurança. Os quatro P0 somam dias e destravam o beta inteiro.

**Veredito final.** O Shambleta está a **uma semana de engenharia** de poder abrir um beta fechado honesto, e a **zero reescritas** disso. Está também a uma distância parecida de virar um negócio, e essa distância não é código: é conta PJ, chave de mercado, decisão legal sobre baús e um número real de retenção medido em gente de verdade. O produto que o código entrega hoje é melhor do que o produto que a documentação afirma, e muito pior do que a autoavaliação anterior alegava. As quatro notas: técnica **5,0**, produto **5,1**, potencial comercial **5,0**, prontidão para beta **2,5**. As duas primeiras sobem rápido com os P0; a terceira sobe só com tráfego medido; a quarta sobe só com coragem de abrir com números menores do que os que foram escritos no roadmap.

---

*Relatório gerado por auditoria independente. O read-only durou até a primeira passada de conserto: as
passadas de 2026-09-24/25 mudaram código e suíte, e o estado medido da árvore em 2026-09-25 00:20 -0300 é
`git status --porcelain` com **138 caminhos sujos** (58 `.gd` vivos + 15 `.gd` deletados + o resto em
dados, companion, deploy e documentação). Nada disso está commitado — só commit fecha a conta, e commit
precisa de ordem do dono. Verificação: a CI do GitHub **não roda** (dono sem créditos no Actions, avisado
em 2026-09-25), então o portão autoritativo é o `./scripts/test.sh all` desta máquina — nove gates, agora
incluindo o gate de estrutura que antes só existia na CI.*

> **Retificação de 2026-09-25 (passada seguinte), porque este relatório é usado para priorizar e dois
> fatos do rodapé acima deixaram de valer.**
> (1) *"Nada disso está commitado"* — a passada inteira entrou em `6277671` com push em `origin/master`
> (motivo de entrar junta em `deploy/LAUNCH_HANDOFF.md` §5). O veredito "a uma semana de engenharia"
> foi consumido pela passada de conserto, não por nova arquitetura.
> (2) *"A CI não roda"* — ela roda, e o primeiro run do beta derrubou uma coisa que **nenhuma**
> autoavaliação e nem este relatório verificaram: `./scripts/test.sh` está no índice sem o bit de
> execução, então o job da fronteira do dinheiro morria com **exit 126** e um clone novo não consegue
> rodar a régua que este próprio documento cita como autoritativa. Reproduzido em checkout limpo,
> consertado em `ccc927a` (só modo), run verde nos 12 jobs. É o tipo de defeito que só aparece onde o
> disco não é o do autor — a mesma lição do achado (b) sobre layout `user://`.
> (3) Uma limitação que vale para as negativas deste relatório e que não estava registrada:
> **o repositório é shallow** — a fronteira é `c727e69` (2026-08-14), 107 commits. Onde está escrito
> "`git log --all -S"X"` retorna zero commits" (ex.: `func StartSpan`, §13 e §19) o zero é **até essa
> fronteira**. As negativas continuam bem fundamentadas para o período em que as decisões foram tomadas,
> mas não são prova sobre o histórico anterior a 2026-08-14, que não existe neste clone.
> (4) O achado **(r)** — os dois destinos de suporte serem do upstream — foi decidido pelo dono e
> resolvido por remoção na passada seguinte: a ponte do Discord, o addon, o botão, o endereço horneado
> e as duas frases de erro que o apontavam saíram da árvore, e o aceite parou de mandar o jogador para
> o Discord/IRC de outra pessoa. A linha "canais/Discord 1" da tabela de notas do item 14 e a menção à
> "ponte com Discord" do §14 descrevem o jogo **antes** dessa passada. O que o item não resolveu —
> publicar um canal de suporte — continua entrega do dono.
> (5) A régua mordiu a própria documentação: o run de `8b7459c` (só docs) falhou o job
> `SOM-IDLE Idle Tests` com 1 falha em 2257 checks, porque o ponteiro que este relatório fazia para a
> retificação das notas tinha derrapado três linhas quando o ROADMAP mudou de tamanho. É exatamente a
> classe de defeito que o guard foi escrito para pegar, e a correção entrou nesta passada. O registro
> fica: **o portão local não cobriu aquele run** — a falha é de prosa editada *depois* da medição
> local, e só a CI a viu.
> (6) A classe de defeito que **nenhum** gate desta máquina via, descoberta ao medir o item 1 acima:
> acesso a **propriedade** de autoload. `SuiteAutoloadSurface` casa `Nome.metodo(` — com parêntese —,
> então `Launcher.Peer.peerID` nunca foi olhado, e GDScript compila acesso a membro inexistente de um
> autoload (o autoload é visto como `Node`; a busca pelo membro é em runtime): sete sentenças em três
> painéis (`sources/gui/Settings.gd:654`, `:666`, `:707` — 2FA; `sources/gui/Shop.gd:173`,
> `sources/gui/Checkout.gd:252`, `:266` — nome e token da conta no checkout) chamavam
> `Launcher.Peer` / `Launcher.nPanel`, membros que não existem na árvore. Nem o preflight de parse,
> nem o boot headless, nem os 2256 checks viram: o único caminho até elas é um jogador clicar.
> Corrigidos os dois nomes (`Launcher.GUI.loginPanel`, o painel real), e o guard passou a varrer
> chamada **e** propriedade contra o objeto vivo — 1678 acessos, zero quebrados. Duas lições
> adicionais: `RegExMatch.get_string()` devolve fatia deslocada em fonte com acento (o `Launcher.SQL`
> de `sources/economy/GuildService.gd:18` chega como `SQ`), então a varredura agora é por String; e um
> `int` no lugar de um peerID viaja longe — `sources/network/server/Server.gd:1005` mandava o board
> pós-ataque para `defenderAccountID` no slot de destino de transporte, agora resolvido por
> `Peers.accounts` e só enviado quando o defensor está conectado.
> (7) Inserir guard no meio de `tests/IdleTests.gd` moveu as citações que **este** documento faz a ele:
> a passada somou 62 linhas antes de `:1009`/`:3846`/`:4979` e passou a somar 98 a partir de `:5990`,
> e `SuiteEvidencePointers` devolveu seis derrapes na hora. Reapontados catorze ponteiros de código deste
> relatório mais um do `ROADMAP_COMERCIAL.md`, e o bloco de histórico (`:1005-1009`) ficou intencional
> — ele registra o reapontamento anterior, não o endereço de agora. Duas coisas a tirar disso: o bloco
> de §Vulnerabilidades (V1–V5, itens (m)/(n)) cita linhas da revisão auditada em 2026-09-24 e **não**
> da árvore atual, então serve como descrição do achado, não como ponteiro de trabalho; e a régua só
> consegue ver o ponteiro cuja prosa cita uma mensagem de check entre aspas — dos 17 ponteiros a
> `tests/IdleTests.gd` neste arquivo (quatro deles no próprio bloco de histórico), 6 tinham mensagem
> citável e foram pegos; os outros 11 passam por cima de qualquer derrape. Enquanto um `arquivo:linha`
> for a forma de evidência, a metade muda continua sendo conferida por mão.
