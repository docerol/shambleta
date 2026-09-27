# SHAMBLETA — AUDITORIA COMPLETA (2026-09-27)

Código, produto, game design e potencial comercial. Metodologia: nove auditores independentes
(arquitetura, economia/anti-exploit, segurança, game design, monetização/live ops/analytics,
performance/escalabilidade, UX/social, testes/DevOps/docs/código, pesquisa de comunidade na web),
cada afirmação P0/P1 re-verificada na fonte contra o código do commit `9e38f16` + worktree atual.
Uso de Graphify: grafo reconstruído hoje (`graphify update .`, 1153 nós, SQL habilitado); limitação
honesta registrada em §3 — Graphify não faz parse de `.gd`, então o grafo serviu para docs/companion/SQL
e o mapa GDScript veio de rastreamento direto por grep/leitura.

Etiquetas: `[CÓDIGO]` confirmado no código · `[TESTE]` confirmado por teste executado · `[DADO]`
número medido · `[COMUNIDADE]` evidência externa · `[INFERÊNCIA]` · `[HIPÓTESE]` (não pontua).

---

## 1. Executive Summary

Shambleta é um idle RPG server-authoritative (Godot 4.7, ~40k linhas de GDScript em `sources/`,
9,1k em testes, companion Python de 1.432 linhas na fronteira de pagamento) cujo núcleo técnico é
**muito acima da média de um indie** — fronteira anti-fraude exemplar (HMAC + re-fetch autoritativo +
fail-closed), ledger append-only com trigger no banco, settle idempotente, catálogo de preços
tri-validado, gate de CI quádruplo que não confia no próprio exit code, e uma cultura de auto-correção
documentada (os "quatro fechados" de `9e38f16` foram todos re-verificados: verdadeiros, com suíte
própria, nos 2.440 checks verdes `[TESTE]`).

Ainda assim o produto **não está pronto para beta pago**, por dois motivos independentes:

1. **Um CRÍTICO novo, que nenhuma auditoria anterior achou**: a perna de gold da economia é corrompida
   por design de snapshot. `UpdateStat` grava o `gp` **da memória** por cima do banco a cada 600 s
   e no disconnect, enquanto AH/vendor/chave de boss/torneio debitam e creditam `stat.gp` **no banco**
   sem sincronizar a memória do jogador online `[CÓDIGO]` (§7.1). Consequência operacional: o
   comprador online compra de graça (débito evapora) e o vendedor online não recebe (crédito evapora).
   Nenhum dos 2.440 checks modela esse entrelaçamento — 0 referências de teste a
   `BackupPlayers`/`RefreshCharacter` `[TESTE]`.

2. **Um furo de conta inteira**: o código de reset de senha é de 6 dígitos decimais (espaço 10⁶),
   vale 15 min, **não é consumido em tentativa errada**, não tem contador de tentativas, e o único
   throttle é 1 tentativa/s/peer com peers não limitados `[CÓDIGO]` (§10). Tomada de conta alheia
   sem credencial nem interação é o pior bug possível num jogo onde contas têm dinheiro.

Entre esses dois polos: moeda paga com proveniência (anti-refund-abuse de verdade), economia com
sinks conscientes, monetização F2P-friendly end-to-end **shipped** (todos os SKUs do roadmap, do
webhook ao grant em uma transação), e — do lado produto — o loop ativo→eficiência→offline é a ideia
mais elegante do jogo e está corretamente implementada.

O que a pesquisa de comunidade acrescenta de desconfortável `[COMUNIDADE]`: o cap F2P de 1 h de
offline é **o mechanic mais atacado do gênero** (a banda de tolerância é 12–24 h+; o Melvor teve que
elevar o cap sob pressão); VIP-de-conveniência tem precedente público nulo de monetização boa nessa
categoria (os bem-sucedidos venderam poder); trading P2P em idle não é demanda comprovada (Idleon
fez enquete e reprovou); e o teto do gênero F2P-idle está em queda visível (AFK Arena: receita em
quedas por 5 anos consecutivos). A diferenciação real (AH de jogador em browser, preços R$, sem
P2W) é verdadeira — mas mora exatamente nos dois recursos com pior histórico de cold-start da
indústria.

Notas consolidadas em §21. A resposta direta à pergunta §33 está em §25.

---

## 2. Estado atual do produto

**O que é**: idle RPG server-authoritative com progressão offline, Godot 4.7 (desktop/mobile/web-WASM),
SQLite WAL, transports ENet/WebSocket/WebRTC atrás de 203 `@rpc`, companion Python para webhooks de
pagamento, 49 migrations versionadas, 9 jobs de CI com gate de log, ~98 commits nos últimos 30 dias `[DADO]`.

**OFERTA SHIPPED (não planejada)** — verificado end-to-end `[CÓDIGO]`:
gems 550/1200/300 (R$19,90/39,90/79,90), VIP 1 mês/3 meses (stacking sem rebaixar tier),
pass S1/deluxe, starter.pack one-time D0–D3 (idade de conta + LIKE de histórico, dupla checagem),
founder.pack, donate.support, taxa de trade/AH em gems queimados, refund CDC 7 dias com
proveniência `gems_paid`, age gate 18+ (Lei 15.211/2025) como terceira cláusula do aceite, cobrado
inclusive no checkout `[CÓDIGO]` (`046_age_gate.sql`).

**SHIPPED-MAS-INALCANÇÁVEL**: janela completa e testada do Auction House existe
(`AuctionHouseWindow.gd`, 116 linhas) mas **nenhuma cena ou script a instancia** — o botão do HUD dá
toast "use /ah list, /ah buy" `[CÓDIGO]` (`Gui.gd:642-644`); arena/torneio resolvem no servidor e os
resultados caem em métodos de `Client` que não existem `[CÓDIGO]`; live events sem handler de cliente.

**STUB DELIBERADO (fail-closed)**: anúncios recompensados (nonce CSPRNG server-minted pronto, portal
de ads ausente — `SHAMBLETA_AD_STUB` fora do prod), WebPush morto (`CanDeliver()` false), bots do AH
por env, checkout gateway externo em sandbox.

**DRIFT DE DOC**: FEATURE_MATRIX diz push "Implementado"; ROADMAP diz taxa AH 10 gems, código cobra
5 (`AHListFeeGems=5`); `architecture.md` diz 5 autoloads, são 6; `docs/game_bible/` vazio; CHANGELOG
congelado em 0.0.9.

---

## 3. Arquitetura

**Mapa real** `[CÓDIGO]`: 6 autoloads (`Launcher, Network, FSM, Monitoring, WebPush, PwaUpdate`) →
`Launcher` compõe serviços como service-locator (`Launcher.SQL` 453 refs/29 arquivos, `.Economy`
160/10, `.World` 55/13). Camada de dados sem referência ascendente (verificado: `SQL.gd` não toca
`Economy/World/Telemetry`). `EconomyService.gd` fatiada de 3.839→787 linhas em 16 domínios por
back-reference, mesma superfície pública — o pior god-object foi reduzido de verdade, não cosmético.
Fronteira de dinheiro: companion valida webhook e escreve `grant_queue`; o jogo **só consome fila**.

**Achados MEDIUM** `[CÓDIGO]`:
- Disciplina transacional é convenção + detecção em runtime: dois caminhos live (reset de senha,
  `_GrantApplyAndMark`) re-travam `queryMutex` dentro de `Transaction()` — funciona hoje, e os três
  comentários do repo discordam entre si se o mutex é recursivo (`SQL.gd:528` vs `CheckoutService.gd:175`
  vs `IdleTests.gd:327`). A fronteira "raw-only dentro de lambda" não tem guarda estática.
- Gate anti-god-node (`scripts/check_god_nodes.sh:23-38`) isenta exatamente os 6 maiores arquivos sem
  teto — e **todos os 6 cresceram** no ciclo em que o gate passou verde (SQL 1267→1502). O comentário
  do gate diz que a allowlist "registra legado, não autoriza crescimento"; nada impõe isso.
- `Server.gd`: 1.486 linhas, ~40 handlers com gating de sessão **por handler**, sem middleware central.
- Protocolo: `ComputeProtocolVersion` hash da config dos `@rpc` (canal/modo) — mudança de assinatura
  pode escapar `[HIPÓTESE H1 da arquitetura; mitiga-se com lockstep deploy + PwaUpdate]`.
- SQLite: `foreign_keys` nunca ligado; single-writer reconhecido.

**Nota Arquitetura: 7/10** — honesta, desacoplada onde importa, com dívida auto-declarada e medida;
perde por gate cego ao próprio alvo e convenção não-imposta no caminho do dinheiro.

---

## 4. Game Design

**Inventário de sistemas shipped** `[CÓDIGO]` `[DADO]`: 24 zonas (8 tiers×3, gate de poder, par
24–46 s/kill, ~80–150 kills/h), escada de 4 bosses (perda queima chave), tormento 1–10 (recompensa
×(1+0,25T), HP ×(1+0,10T)), rebirth (favours +5%/nível vs custo 1,7^n — parede macia **documentada**),
pass 40 níveis/5000 PT com 3 dailies+3 weeklies, 40 dailies possíveis de pool de 8, guild com
buff 2%/nível e vault, AH com escrow all-or-nothing, crafting com aprovação GM, arena determinística
(`win = poderAtaque >= poderDefesa` — ELO é ordenação cosmética `[CÓDIGO]`).

**O que é genuinamente bom** `[CÓDIGO]`: `ComputeSessionEfficiency = 1 − downtime − 0,05×deaths`,
clamp [0,5–1,0], multiplica XP/gold/drop/chave offline — jogar ativo **sempre** paga mais, com piso
de perdão. Baús provably-fair com odds persistidas + pity. Chave queimada na derrota = risco real.
Pass nunca expira silenciosamente (auto-claim). Odds abertas no UI. Rebirth auto-claim.

**Dois bugs de balanceamento confirmados** `[CÓDIGO]`:
- **Newbie invertido**: ×5 XP+gold **offline** para l<10 (`OfflineSettle.gd:243`), só ×5 XP **online**
  (`Formula.gd:211-212` ignora gold) → no exactly o momento de formar hábito (D0–D3), o novato vê
  AFK pagar mais gold que jogar. A correção é uma linha + re-tune do faucet.
- **Craft sem teto para elementais**: `CRAFT_MOD_WEIGHTS` tem 23 entradas, enum `Modifier` vai a 36 →
  FireDamage/Burn/Poison/Bleed/Penetration/DeadlyChance pesam 0 (`ItemForgeService.gd:261
  ... else 0.0`) → item craftado com DoT arbitrário passa no budget; a única parede é aprovação GM
  humana (não escala, e contamina o drop-pool do AH).

**Profundidade**: endgame = 4 bosses + tormento, 24 zonas são ecos estatísticos (28 mapas de mob
reais), arena é corrida de status, quests são legados MMO não conectados ao loop idle. Onboarding:
tour de 6 passos ensinando teclas que **não existem no alvo web/mobile** (`F2`, `/zones`, `F12`
`[CÓDIGO]`).

**Nota Game Design: 6,5/10** — sistemas honestos e bem amarrados, feridos por dois bugs triviais de
corrigir e pela escassez de conteúdo atrás do cap.

---

## 5. Core Loop

Minuto a minuto: auto-battle em zona (FSM idle/seek/combat/loot), coleta de baús/keys, decisão de
zona/slots/poção; sessão de 5–10 min/dia fecha todo o orçamento diário (6 baús, 3 chaves, arena 3,
shop 3, 3 dailies). Loop completo login→settle→claims→boss→spend→logout validado no código e
idempotente. Nota do designer-executor: o teto de catch-up de 2 s por tick achata divergência
online/offline — escolha correta, custo: nenhum.

**Nota Core Loop: 7/10** — claro, curto, recompensado, com o gancho eficiência→offline; perde onde
o próprio design trai (newbie gold) e onde a sessão é 100% menu (agência = 1 minigame de interrupt).

---

## 6. Retenção

**Plumbing de pull excelente** `[CÓDIGO]`: orçamento diário (6 baús), resets (shop/account+day seed,
arena tickets, rush), semanal (weeklies, torneio, live events com seed UTC), mensal (temporada 30 d,
passe ≈ comprimento da temporada, de propósito). F2P sem anúncio liquida 1 h; anúncio soma +1 h;
VIP 24 h.

**Furos de ping e de hábito** `[CÓDIGO]`: WebPush morto, sem streaks em lugar nenhum (grep
negativo), anúncios fail-closed em produção (logo, hoje, F2P = cap de 1 h **sem extensão**),
notify só de UI. Primeiro motivo de abandono da categoria `[COMUNIDADE]`: caps curtos que forçam
check-in são o gatilho de uninstall mais citado em r/incremental_games ("a long cap means I still
build resources"; Melvor elevou 12→24 h sob pressão da própria base). A régua do próprio roadmap
(D1≥27%, D7≥7%, D30≥4%) assume ganchos que o build não entrega.

**Nota Retenção: 5/10** — a máquina de pull é boa; faltam os gatilhos de retorno que a arquitetura
assume existirem, e o cap atual é hostil fora da banda de tolerância do gênero.

---

## 7. Economia

### 7.1 O CRÍTICO: snapshot de memória por cima do banco `[CÓDIGO]` — NOVO (nem a auditoria de 24/09 tinha visto)

- `UpdateStat` escreve `"gp" = stats.gp` **absoluto** da memória (`SQL.gd:1003-1016`), chamado por
  `RefreshCharacter` a cada `BackupPlayersSec = 10*60` (`SQLBackups.gd:167`, `SQLCommons.gd:11`) e
  no disconnect (`Server.gd:434`).
- Gold kill ao vivo (`Stats.AddGP`, `Formula.gd:221`) só existe em memória — é o lado que o snapshot
  preserva.
- Todo o resto opera no banco: AH compra/vende/fee de criador (`AuctionHouseService.gd:262-270`,
  `UpdateRowsRaw("stat", ... {"gp" = ...})`), vendor, chave de boss, corrupt/craft fee, salvamento,
  guild create, entrada de torneio, settle. **Nenhum handler sincroniza `player.stat.gp` depois da
  transação** (verificado por inspeção; apenas settle/rebirth operam pré-load/mirror por design).
- Consequências: jogador online compra no AH e o débito evapora ≤10 min depois (**faucet ilimitado**,
  nullifica todos os sinks); vendedor online tem o crédito evaporado (**roubo silencioso entre
  jogadores**); `ReconcileDaily` não vê (só checa soma negativa do ledger + lots, `§16`).
- Testes: 0 referências a `RefreshCharacter`/`BackupPlayers` em `tests/*.gd` `[TESTE]`. O
  SuiteConcurrency é sequencial e não modela o interleaving.
- **Correção recomendada**: um único escritor para `gp` de personagem online — rotear deltas
  (AH/vendor/etc.) por `AddGP`/`SubGP` server-side que atualiza memória E banco na mesma transação,
  com linha de ledger por delta de kill (`reason kill_z<N>`); em alternativa, deltas puros no banco
  e snapshot sem `gp`. + asserção diária `stat.gp == último balance_after do ledger` por char
  (exige a linha de kill no ledger, §16). + teste: agente online, crédito DB-side, dispara
  `RefreshCharacter`, asserta conservação.

### 7.2 Faucets/sinks e integridade parcial

- Ledger espelha settle/fees/sinks mas **não espelha o faucet vivo** (kill/boss XP/gold sem linha) →
  auditoria `balance_after` fica incompleta `[CÓDIGO]` (Agrava 7.1: o `balance_after` gravado depois
  vem do DB driftado).
- Chest RNG determinístico de inputs públicos (serverSeed = `id:created_at:shambleta` persistida,
  clientSeed = `charID:nonce`) → cliente pode pré-computar conteúdo de baús e escolher ordem de
  abertura `[CÓDIGO]` (previsibilidade); prevalência de uso `[INFERÊNCIA]`; odds divulgadas ≠
  resultado realizado. Fix barato: misturar segredo server-only por roll (revelar depois, mantém
  verifiable).
- `beaten` escrito incondicional no rush (`BossProgressionService.gd:259`) → regressão de progresso
  documentada `[CÓDIGO]`; o re-grant alegado (chests/keys/pontos) está **guardado** por
  `index+1 > prevBeaten`/`maxi` na frente do frontier e do tormento — impacto residual: estado da
  escada reabre e o pass milestone pode creditar de novo por índice `[HIPÓTESE — verificar
  idempotência de _PassMilestoneCredit]`. Fix: `maxi(prevBeaten, index+1)`. Gravidade revista
  de HIGH para MEDIUM pela checagem cruzada (o segundo auditor não localizou o vetor; a linha é real,
  o dano é menor que o reportado).
- `PurchaseVIP`: burn de gems e `SetVIPUntil` em transações separadas → crash entre as duas cobra
  sem entregar `[CÓDIGO]` (mesma aula que o grant aprendeu). Fix: uma transação.
- `RerollDailyShop`: burn fora do lock de salt/rerolls → reroll pago pode sumir `[CÓDIGO]`.
- Equipamento é snapshot de cell-ID, não lot-backed → vender item equipado mantém os stats
  até relog (stat-ghost) `[CÓDIGO]` (mecanismo) / `[INFERÊNCIA]` (severidade visual).
- Key→rush no endgame: 1 key ≈ 22 s de farm de gold ao custo de 10.000; rush = 4 vitórias + baús
  isentos do cap de settle; teto de baú é por personagem (6 chars ≈ 60 baús/dia) `[DADO]`/`[INFERÊNCIA]`.

### 7.3 O que está certo (e é raro)

Ledger append-only por trigger + teste; settle idempotente com âncora re-lida na transação; clock
100% server-side; refund com proveniência `gems_paid` drenada em todo gasto; escrow all-or-nothing
com linhagem de lots, anti self-trade, fee burn 10 gems + cooldown 60 s + 20/dia; curva de rebirth
convergente (1,05^n vs 1,7^n); gems sem faucet jogável (só prize tables). `[CÓDIGO]`

**Nota Economia: 5/10** — a disciplina de ledger, caps e proveniência merecia 8; a perna de gold do
mercado entre jogadores está quebrada no mecanismo central, e metade do faucet vivo é invisível à
auditoria.

---

## 8. Monetização

**Mecânica** `[CÓDIGO]`: todos os SKUs entregues fim-a-fim (intent com prova de sessão → MP/Stripe →
webhook HMAC constant-time + re-fetch → grant em transação única claim/apply/mark, idempotente por
payment-id; checkout_return é informativa, zero confiança no cliente; companion recusa vender pass
sem temporada; consent+idade cobrados nos dois portões). ARPU hoje: tudo que é pago entrega gems ou
conveniência, validado contra um único catálogo.

**Vazios confirmados**:
- **Chargeback inexistente** — o webhook não trata `charged_back`/dispute; sem clawback `[CÓDIGO]`
  (ausência verificada por grep). Buraco de receita pós-venda.
- `founder.pack` anuncia title que não existe no catálogo do bundle (validador compara preço, não
  conteúdo) `[CÓDIGO]`.
- Ads off em produção: o SKU-vitrine "assistir para estender cap" não existe para F2P `[CÓDIGO]`.
- Sem e-mail/dinheiro de volta no refund fora de gems (gap operacional, não código).

**Leitura de mercado** `[COMUNIDADE]`: conversão F2P típica ~3%, attach de pass 8–20%; eCPM de
rewarded $15–40 tier-1 (web ~€30 CPM reportado por publisher; Brasil sem dado textível — obter o
relatório Tenjin); escada de preços R$9,90–44,90 ≈ US$2–12, coerente com a tabela Valve-Brasil
(50–70% abaixo do USD); Pix/parcelado importam no tier R$44,90. Mas: **nenhum comparável de sucesso
desta categoria monetizou conveniência pura** (os vencedores venderam poder/roster), e Idleon — o
experimento natural de "pay for convenience" — é polarizado exatamente no "VIP = pay to progress".
Expectativa realista: VIP+pass carregam a receita, conversion <3%, ARPPU abaixo dos US$8 da régua.

**Nota Monetização: 7,5/10 para a máquina; 5,5–6,5 para a oferta** (nota final §21 usa a máquina,
com o risco de oferta descontado no potencial comercial).

---

## 9. Marketplace

O backend é bom (escrow, taxas que queimam, linhagem, anti-self-dealing, bots env-gated finitos)
`[CÓDIGO]`; a camada de jogador é um chat: a janela existe testada e **não é instanciada**; sem UI de
trade; confirmação zero em ações irreversíveis (corrupt queima 25% do gold e gasta com clique único;
`UICommons.MessageBox` já protege ops de conta, não de dinheiro) `[CÓDIGO]`. Somando 7.1: o
comprador online não paga, o vendedor online não recebe, e o índice `auction_listing(seller_account)`
não existe → 37 ms de varredura **dentro do mutex global** por listagem a 200k listings `[DADO]`.
O AH é, hoje, o recurso mais diferenciado do produto **e o mais doente** — e é dele que vem o
"p2p market em browser a preço R$" que nenhum concorrente tem `[COMUNIDADE]`.

**Nota Marketplace: 4/10** (economia dizia 5; a UI inexistente e o clobber baixam para 4).

---

## 10. Segurança

Nota geral do lane: **7,5/10** — identidade inforjável (transport sender, testado com WS real
`[TESTE]`), SQL injecção fechada e re-verificada, replay de ads fechado, TLS do cliente agora com
âncora de sistema (correção V7 de 24/09 verificada), segredos sem hardcoded, KDF iterado com rehash
transparente, lockout de login exponencial. Os furos restantes não são de fronteira de dinheiro:

- **P0 — brute-force do código de reset** `[CÓDIGO]`: 6 dígitos (`Hasher.gd:49`, `bytes[i] % 10`),
  15 min, `ValidateReset` só compara hash (tentativa errada não consome, sem contador), throttle
  1/s/peer, peers ilimitados, IP compartilhado atrás do proxy (`Peers.gd:174-190` → IP-binding e
  /ipban viram decorativos `[CÓDIGO]`/`[INFERÊNCIA]`). ~1.100 conexões cobrem 10⁶ em <15 min →
  **troca de senha + revoke de tokens = takeover total**, com bônus de DoS por KDF por tentativa.
  Fix (≈1 dia): alfabetio alfanumérico ≥8, contador ≤5 tentativas com consumo do código, limite por
  conta (não por peer), resets persistidos em banco. Teste: asserting erradas invalidam entrada.
- **P1 — autorização acoplada a build** `[CÓDIGO]` (`CommandManager.gd:35`: o gate de permissão só
  roda em non-debug; produção shipa release e está protegida pelo Dockerfile, mas rodar o servidor
  do editor/fonte = qualquer jogador logado vira GM). Fix: flag de role real, não build type.
- **P2 — enumeração de e-mail no cadastro** (`Server.gd:22-25`) — é o oráculo que alimenta o P0;
  colapsar para mensagem genérica.
- P2: `==` não-constant-time em hash de reset/senha/TOTP (explorável apenas com timing local);
  PII em log de e-mail; sem CSP/XFO no nginx; backups sem permissão hardening.
- `[HIPÓTESE]` (não pontuam): cap de conexões por IP no orquestrador; Origin check WS; XSS em
  tooling administrativo externo (nenhum sink no repo).

**Nota Segurança: 7,5/10** com o reset como único item capaz de derrubar um beta — e é P0.

---

## 11. Performance

Base medida hoje (harness rodado nesta auditoria, exit 0 `[TESTE]` `[DADO]`): settle completo
414 µs p50 / 864 µs p99 (2 hitches de 800), `UpdateProgress` 3 queries para 150 entradas, leaderboard
e browse 0 ms com plano asserido. WAL gate (4b2afa2) funciona como documentado. Web first-load
34,21 MiB gzip, SW cache-versionado no engine.

Achas:
- **Gate de pegada 1000× frouxo** `[CÓDIGO]`: `Peers.Footprint` compara `ticks_msec` e recebe
  `60` em `open_chest` e `claim_settle` (`Server.gd:885`, `:489`) — onde o comentário do próprio
  OfflineSettle (§269-271) diz que o gate é de **60 s**; `NetworkCommons.DelayMinute=60000` existe.
  ~16,6 aberturas de baú/s × ~570 µs serializados ≈ 9,5 ms/s de writer por cliente spamador (a
  economia está a salvo pelo teto diário de baús — quebra é o writer único).
- `BackupPlayers` na game thread: 1000 online = ~300 ms de freeze a cada 600 s `[DADO]`.
- `ReconcileDaily`: 923 ms de queryMutex a 100k chars, cresce linear com um ledger que não pode ser
  podado (trigger append-only) `[DADO]`.
- Presença: broadcast O(N) por conecta/desconecta com `GetPlayerNames()` construído e descartado
  (const path vazio) → O(N²) em storm de reconexão `[CÓDIGO]`.
- ZonePolicy "batch O(1)" anunciado pelo doc é **código morto** — zero chamadas de `AttachPolicy`
  `[CÓDIGO]`; o pump real é O(jogadores)×guard de 0,25 s.
- gzip -9 sem brotli/gzip_static: 9× CPU e mais bytes que nível 6 `[DADO nginx]`.

**Nota Performance: 7/10** — o que foi afinado é afinado com medição e plano asserido (raro); o que
dói está listado acima e é barato de consertar.

---

## 12. Escalabilidade

Custo marginal por jogador escala bem (~0,2 stmt/s ≈ 7,6 µs de writer/jogador-s); **a estrutura,
não** `[DADO]` `[INFERÊNCIA]`: um processo, um `queryMutex`, um SQLite writer, presença in-memory,
`MaxPeers=128` hoje, ledger sem política de arquivo, `SHARDING.md` é paper. Escada estimada:
100 sem nada; 1k → freeze do snapshot; 5k → presença + 250 WorldInstances; 10k → snapshot 3 s +
CPU do pump; 100k → writer único a 76% e reconcile ~9 s; 1M → 20M linhas/dia de ledger, arquivo
51 GB, arquitetura não comporta. Teto honesto: **5–10k CCU num box**. Para o plano (soft-launch
BR, régua do roadmap) isso basta — mas é o teto estrutural e a comunidade de origem (MMO fork) vai
cobrar.

**Nota Escalabilidade: 3/10.**

---

## 13. UX/UI

Craft por tela acima da média (AfkReport explica o loop; Checkout sobrevive a popup-blocker com o
segundo botão deliberado; odds abertas nos baús; zona explica "precisa poder X"; Settings reduz
sozinho no mobile com LGPD/2FA confirmados) `[CÓDIGO]`. A camada conectiva falta: AH/arena/eventos
inalcançáveis (comandos de chat), reason tokens do servidor vazando no toast (`"Shop rejected:
insufficient_gems"` ~25 códigos sem i18n), onboarding ensinando teclas F2/F12 no alvo web, 9 painéis
flutuantes sobrepostos num canvas_items 1280×720 com só 3 janelas respondendo ao UI scale, Shop/
Chests fixos 360–400 px sem ScrollContainer (risco de corte real só medido ao rodar
`[HIPÓTESE H1/H2/H4 do UX auditor]`), i18n 82% com as strings críticas (login, onboarding) no 18%,
zero confirmação em gasto irreversível.

**Nota UX/UI: 4/10** — desktop honesto, alvo principal (web/mobile) ainda sem história.

---

## 14. Social

Backends bons (mute server-side cobrado no envio, denúncias com trecho que o servidor viu, referral
com 3 heurísticas anti-fraude, boards com title equipado, fraud scan diário) vs superfície tocável
pobre: guild é texto de comando (sem join/kick/demote/disband UI, vault drenável por qualquer
oficer sem limite, log existe e ninguém mostra), sem guild chat, sem amigos, sem party/co-op, sem
gifting, sem streaks, sem botão de denúncia, reportável só digitando `[CÓDIGO]`. A literatura de
midcore diz que mecânicas comunais (co-op tasks, barras compartilhadas) são o substrato de retenção
de quem fica `[COMUNIDADE]` — não há nada disso, e a confiança de vault é justamente o vetor de
golpe que derruba guilds em jogos-live (Throne & Liberty) `[COMUNIDADE]`.

**Nota Social: 4/10.**

---

## 15. Live Ops

Flags env fail-closed honestas (9 gates), temporada abre/fecha/liquida sozinha, live events na DB
com auto-seed, moderação por comando, runbooks de rollback/staging que se auto-corrigem com medição
(excepcional). Mas: preço/promo/SKU/temporada nova = **deploy**, nada hot-reload; sem A/B; sem
anúncio a jogadores; mute efêmero em memória; sem painel admin `[CÓDIGO]`. Nota **5/10**.

---

## 16. Analytics

Respondível hoje de SQL puro: DAU, D1/D7/D30 por view de cohort, funil pós-intent por SKU, ARPPU
anti-sandbox, mint/burn de gems, leaderboard de gasto, multi-account por fingerprint, fila de grant
com gauges `[CÓDIGO]`. Buracos: **topo do funil morto na única plataforma publicável** —
`onboarding_done` é chamado client-side onde `Launcher.Telemetry` só existe no servidor → nunca
grava no build web `[CÓDIGO]` (`Onboarding.gd:96` null-safe); checkout_intent não grava SKU (não dá
pra ver abandono por preço); nenhum evento de recusa/chargeback; canal de aquisição inexistente;
e `ReconcileDaily` — o job que existe para pegar 7.1 — não compara `SUM(ledger)` com saldos nem
exporta divergência para métrica alguma `[CÓDIGO]`.

**Nota Analytics: 6/10.**

---

## 17. Testes

2.440 checks, 0 falhas, rodados nesta auditoria `[TESTE]`; 92 suítes reais contra SQLite real; os
quatro fechados da última passada verificados um a um; gate CI quádruplo que lê o log e não o exit
code; asserções de plano de execução no benchmarks. Mas a cobertura segue o mapa de risco com
três buracos: **nenhum teste modela o snapshot gp** (zero referências a BackupPlayers/RefreshCharacter),
nenhum teste toca reset de senha, nenhum teste prende a paridade de pesos de craft ou a simetria
newbie. Reconcile só roda em dados limpos. Lacunas reconhecidas: corrida de threads reais,
e2e de compra com provider fake, soak/load, down-migration.

**Nota Testes: 7/10** — profundidade acima do padrão indie; o buraco é o que ainda não entrou no
mapa de risco, não a qualidade do que está.

---

## 18. DevOps

Healthcheck real (era fictício; foi corrigido), rotação de backup com restore probe, TLS testado,
staging com overlay honesto. Itens que doem em produção `[CÓDIGO]`: rollback por compose quebrado
(`pull` em serviço build-only), override de staging troca volume do `game` e não do `companion`
(divergindo do próprio comentário), `stop_grace_period` ausente (crash perde ≤10 min de ganhos em
memória), canary drain existe mas nenhum doc de deploy o menciona, offsite desligado por default,
migrations forward-only sem nota de compatibilidade com restore antigo (005/006/014 são data-reset),
segredos por env-interpolation sem docker-secrets, alert: divergência de reconcile não gera métrica
nem sinal.

**Nota DevOps: 6/10.**

---

## 19. Comunidade (método e limites)

Método do research agent: API pública de reviews Steam (amostras 15–20/reviews totais), pullpush
para threads do Reddit (Reddit direto bloqueado), relatórios de mercado (Poki/AppMagic/Tenjin —
flag: studies encomendadas por vendor), sem tamanho de subreddit recuperável, sem eCPM Brasil em
texto. Recorrência reportada por upvote da citação, nunca "a comunidade pensa X".

Achas estruturais `[COMUNIDADE]`:
- **Caps de offline**: a tolerância da categoria é 12–24 h ou accrual-irrestrito-com-storage-cap;
  cap curto forçando check-in é gatilho de uninstall citado com mais força que qualquer outro.
  1 h + anúncios desligados = fora da banda.
- **Ads recompensados**: aceitos como *extra* opt-in (60% dos top-grossing têm, >90% completion);
  hostis quando substituem paywall ou viram grind (caso Atlas Earth). No público web/PC entusiasta
  o valor "0 anúncios" é anunciado como feature (Torn). A ad-block exposure não quantificada.
- **Conveniência paga**: Idleon é o experimento natural — "pay for convenience, not P2W" (6↑) vs
  "systems artificially slowed to sell you a solution" — a defesa só se sustenta em framing não-
  competitivo; leaderboard + guild stakes = o cap vira P2W na leitura.
- **Pass/temporada**: pass fatigue é mainstream; auto-claim/rollover (Marvel Rivals) virou
  diferencial *vendido*; mas reset de temporada é também evento de churn (AFKJ servidor morrendo;
  PoE2 recusando league).
- **AH/P2P**: 2–5% de tax está na janela Overton; bots de snipe são normalizados e não resolvidos
  em WoW/Idle Heroes; RMT é a primeira objação quando trade aparece em idle; e **demanda por trade
  em idle não é comprovada** (Idleon enquetou e reprovou).
- **Abandono, ordem**: check-ins coagidos > conveniência paga percebida como P2W > reset de
  temporada > dependência server-authoritative sem fallback (outage do Melvor travou pagantes) >
  mercado morto/inflação > fricção web (guest accounts pedidas) > seca de conteúdo.
- **Gênero**: 558 jogos tag "Idle" no Steam só em 2025 — oferta no fundo é commodity; os breaks
  recentes do segmento são premium (Gnorps 120k cópias/mês a US$7). A aposta F2P+ads+pass de
  Shambleta é a mais difícil do mapa para essa audiência.

---

## 20. Concorrentes

| Eixo | Melvor Idle | Idleon | AFK Arena/Journey | OSRS (bar do roadmap) | **Shambleta hoje** |
|---|---|---|---|---|---|
| Core loop | skills ativas idle | auto-combat + rebirth | gacha+AFK chest | MMO skilling | auto-farm+efficiency→offline (próprio, elegante) |
| Offline | 24 h (elevado sob pressão) | 10 h | AFK chest ~10 h | n/a (log-in) | **1 h F2P + ads (stub)** / 24 h VIP |
| Mercado | sem AH | trade fraco/reprovado | sem AH real | GE = âncora cultural | **AH escrowed completo, UI inexistente** |
| Monetização | premium DLC | multipliers+packs (P2W-adjacent) | gacha+pass+subs | sub+bonds | **QoL+pass+cosméticos, P2W-free by design** |
| Retenção social | clan fraco | guilds ativas | guilds+subs | clan/ironman | guild sem UI de gestão, sem friends/party |
| Sinal público | 14.658 reviews Very Positive | longo ativo | $1,5 bi lifetime, −5 anos seguidos | maior ano histórico 2025 | — (pré-beta) |

Onde eles tropeçaram e o código daqui já respondeu: proveniência de moeda (gems_paid), escrow
all-or-nothing, fee queimando, anti-RMT por design de moeda fechada — a postura certa segundo o
histórico (RMAH morta por isso, Last Epoch em hiperinflação por dupe). Onde ainda não:
liquidez fria (bots env-gated são mitigação parcial e conhecida de baixa qualidade), e o
"marketplace depois da densidade" (Idleon) não foi o caminho escolhido — o AH é central no pitch.

**Oportunidade de diferenciação real**: a única combinação browser + AH de jogador + sem P2W +
preço local. **O risco correspondente**: é exatamente o par (cap agressivo × mercado frio) que os
dados de comunidade mostram quebrar no lançamento.

---

## 21. Scorecard

| Categoria | Nota | | Categoria | Nota |
|---|---:|---|---|---:|
| Core Gameplay | 5/10 | | Segurança | 7,5/10 |
| Core Loop | 7/10 | | Arquitetura | 7/10 |
| Meta Game | 7/10 | | Performance | 7/10 |
| Game Design | 6,5/10 | | Escalabilidade | 3/10 |
| Retenção | 5/10 | | UX/UI | 4/10 |
| Economia | 5/10 | | Social | 4/10 |
| Monetização | 7,5/10 | | Live Ops | 5/10 |
| Marketplace | 4/10 | | Analytics | 6/10 |
| | | | Testes | 7/10 |
| | | | DevOps | 6/10 |
| | | | Documentação | 6/10 |
| | | | Código | 7/10 |

**Técnica geral = 6,3** — média das 7 técnicas (7 + 7,5 + 7 + 3 + 7 + 6 + 7 = 44,5 ÷ 7). Não
esconde o P0: ele vive em Economia (5), Marketplace (4), Testes (7) explicitamente.
**Produto = 5,4** — média das 7 de experiência (5 + 7 + 7 + 5 + 6,5 + 4 + 4 = 38,5 ÷ 7).
**Potencial comercial = 5,5** — estado comercial (5 + 7,5 + 4 + 5 + 6 ÷ 5 = 5,5) + 1,5 de
diferenciais verificados (AH real em browser sem P2W a preço R$, fronteira de pagamento testada,
save server-side cross-platform, auto-claim-friendly) − 1,5 de risco externo (cap fora da banda de
tolerância; QoL-only sem precedente de monetização na categoria; F2P+ads numa audiência que premia
premium e "0 ads"; cold-start de AH documentalmente hostil). = **5,5**.
**Prontidão para beta fechado = 4,5** — média ponderada pela dependência de operação real
(7,5×3 + 6×2 + 7,5×2 + 5×1 + 7×1 ÷ 9 = 6,5) − 2,0 porque **dois P0 (gp-snapshot e reset ATO) estão
abertos e nenhum dos dois é contornável por operação manual** — um beta com eles cobra sem entregar
e pode tomar conta de pagante.

---

## 22. Problemas críticos (P0/P1)

### P0-1 — Duplicação/sumiço de gold por snapshot de memória (§7.1)
Prova: `SQL.gd:1003-1016` + `SQLBackups.gd:167` + `AuctionHouseService.gd:266-270` + 0 refs em
testes. Impacto: integridade da moeda central; mercado entre jogadores; reconciliação cega.
Correção: escritor único de `gp` online (delta mem+DB na mesma txn + linha de ledger para kill);
regra estática: nenhum `UpdateRowsRaw("stat"...{"gp"}) sem mirror; teste de interleaving.
Risco da correção: touch em todos os paths de gold — a suíte de 2.440 é a rede; rodar idle+bac
kups+bench. Validar: crédito DB-side com agente online sobrevive a `RefreshCharacter` e ao logout.

### P0-2 — Takeover de conta via brute-force do código de reset (§10)
Prova: `Hasher.gd:7,49`, `EmailService.gd:96-101`, throttle 1/s/peer. Correção (≈1 dia): código
≥8 alfanumérico, 5 tentativas com consumo por tentativa errada, limite por conta, resets na DB.
Teste nova suíte I18n-par-AUTH: erradas invalidam entrada + cooldown persiste restart.

### P1-1 — Auction House sem UI / arena e eventos sem handlers de cliente
Prova: `Gui.gd:642-644` toast; `AuctionHouseWindow.gd` só em testes; `Network.gd:551-575` cai em
métodos inexistentes. Fix: instanciar a janela (1 dia), aba de arena, banner de live event.

### P1-2 — Zero confirmação em gasto irreversível + reason tokens cru (`F2/F3`)
### P1-3 — Newbie ×5 gold invertido (§4)
### P1-4 — Crafting com pesos faltantes para elementais/DoT (fix: completar tabela + fail-closed + assert de tamanho no boot + teste `{"FireDamage":99999}` rejeitado)
### P1-5 — Gate de pegada 60 ms em vez de 60 s (§11; corrigir `60` → `NetworkCommons.DelayMinute`)
### P1-6 — Chargeback ausente no companion (status `charged_back`/dispute → clawback de gems_paid + flag)
### P1-7 — `onboarding_done` nunca grava no web (`RPC de servidor ao Stop()` do onboarding, como login)
### P1-8 — `ReconcileDaily` cega para gp/gems sem métrica de divergência (window WHERE por dia + gauge)
### P1-9 — `beaten` regredido no rush (§7.2, `maxi`)
### P1-10 — `PurchaseVIP` e reroll em duas transações (fechar numa só)
### P1-11 — Índice `auction_listing(seller_account)` + fatiar BackupPlayers por frame + presença O(1)
### P1-12 — Debug-build GM bypass (`CommandManager.gd:35` desacoplar de build) + XFF atrás do proxy + enumeração no cadastro

### P2 (curto): leaderboard/§docs drift, god-node ratchet com teto, rollback pull, staging volume
do companion, stop_grace_period + canary documentado, offsite default-on, muted persistido,
fund title, ledger row de kill, chest seed com segredo, equip ghost, reroll txn, gzip level 6,
i18n reason codes, guild vault log exposto + limites + kick UI, botão de denúncia, streak opcional,
mobile scale em todas as janelas/ScrollContainer, onboarding device-aware, guest account (demanda
de beta web explícita da comunidade).

---

## 23. Oportunidades (Opportunity Score = impacto × confiança ÷ esforço)

| Oportunidade | Imp | Conf | Esf | Score | Por quê |
|---|---:|---:|---:|---:|---|
| Cap F2P para 8–12 h com storage-cap expansível, ads como *bônus* | 9 | 8 | 2 | **36** | 1 h está fora da banda de tolerância documentada da categoria; é a causa de abandono #1 listada; uma constante + UI de cap. |
| Instanciar AH window + confirmações em gasto irreversível | 9 | 9 | 2 | **40** | Feature flagship inexistente para o jogador; custo de dias. |
| Fechar P0-1 gp-snapshot | 10 | 10 | 3 | **33** | Sem isso o beta paga sem entregar. |
| Reset hardening | 10 | 10 | 1 | **100** | Um dia de trabalho contra o pior cenário (conta de pagante tomada). |
| Chargeback + `onboarding_done` server-side + gauge de reconcile | 7 | 9 | 2 | **31** | Fecha o triângulo receita-integridade-funil sem redeploy de design. |
| Weights de craft + assert no boot | 7 | 10 | 1 | **70** | Uma tabela de 15 floats + 1 teste. |
| Gate 60 ms→60 s + índice AH + presence O(1) | 6 | 10 | 2 | **30** | Três linhas + uma migration. |
| Guild management UI + vault log + limites | 7 | 8 | 4 | **14** | Confiança de guild é o que os comparáveis mostram quebrar primeiro. |
| "Semana XP-free"/rollover opcional do pass | 6 | 7 | 3 | **14** | Pass fatigue + reset-churn comprovados; protege D30. |
| Modo premium/early-access como segunda oferta | 6 | 6 | 5 | 7 | Os breaks do segmento são premium; testar disposição a pagar BR sem queimar o F2P. |

---

## 24. Roadmap

**Antes do beta fechado (P0/P1 curtos: 2–3 semanas de esforço)**
1. P0-1 gp single-writer + ledger de kill + teste de interleaving.
2. P0-2 reset hardening.
3. AH window + confirmações + gate 60 s + índice AH + beaten maxi + VIP/reroll txn única.
4. Chargeback handler + onboarding_done via RPC + reconcile windowed com gauge.
5. Cap F2P de offline para a banda da categoria (8–12 h; storage-cap em vez de tempo-cap;
   anúncios viram extensão de armazenamento quando o SDK chegar).
6. Doc-drift sweep único (autoloads, 203 rpc, taxas, FEATURE_MATRIX, game_bible vazio removido
   ou preenchido) e god-node ratchet com teto nos allowlisted.

**Beta fechado (validar com jogadores reais, 30–60 dias)**
- Funil real: `onboarding_done`→`first_boss`→`first_chest`→`d1_return`→conversão (é o que o
  §3 da oferta promete medir); guest-play no web antes do cadastro; resposta ao cap novo;
  densidade do AH por servidor/zona com bots limitados; disposição a pagar em R$ (testar os
  dois lados: pass vs starter vs VIP); sentimento sobre "P2W?" em arena/leaderboard com stakes;
  fraud scan falsos positivos (LAN/cybercafé BR).

**Pós-beta**
- Live SDK de anúncios + push (WebPush) reais; streaks; guild UI completa + vault limites;
  i18n reason codes + onboarding device-aware + mobile scale; segunda temporada (S2 precisa de
  código — fatorar); ferramenta de preço sem deploy; painel de operador; ledger com tabela fria
  de arquivamento; migração da presença para fora do loop de escrita.

**Longo prazo**
- Caminho de sharding real (SHARDING.md de paper para plano com prova de writer único por conta);
  party/co-op/guild events (substrato comunal = retenção de midcore); economia de crafting
  re-pesada e aberta; avaliação honesta da oferta F2P vs premium híbrida com dados BR.

---

## 25. Plano de ação (lista concreta de alterações, por arquivo)

1. `sources/sql/SQL.gd` + `sources/actor/Stats.gd` + paths de gold: introduzir `DeltaGoldLocked(char, delta, reason)`
   (atualiza memória + banco + ledger na txn) e trocar todos os `UpdateRowsRaw("stat"…"gp")` por ele;
   retirar `gp` do snapshot `UpdateStat` ou espelhar sempre. + `tests/IdleTests.gd` suite interleaving.
2. `sources/util/Hasher.gd`: alfabeto 32+ chars, length ≥8. `EmailService/Server`: contador de
   tentativas, consumo por tentativa errada, persistência DB, limite por conta.
3. `sources/gui/Gui.gd`: instanciar `AuctionHouseWindow`, conectar os dois botões; handlers Client
   para arena/eventos; `UICommons.MessageBox` nos 6 gastos irreversíveis.
4. `sources/network/server/Server.gd`: `60` → `NetworkCommons.DelayMinute` em `open_chest`/`claim_settle`.
5. `companion/server.py`: handler `charged_back/refused` → clawback de `gems_paid` disponíveis + flag.
6. `sources/gui/Onboarding.gd`: emitir via comando de servidor (como login faz).
7. `TournamentArenaService.ReconcileDaily`: janela diária + soma de gems por wallet + gp-vs-ledger +
   gauge de divergência em `/metrics`.
8. `data/conf/migrations/0XX`: `idx_auction_seller`; `ItemForgeService/EconomyCatalog`: pesos 23–36 +
   assert de tamanho no boot; `OfflineSettle`: cap F2P 1 h → banda nova; `BossProgressionService`:
   `maxi(prevBeaten, index+1)`.
9. `deploy/docker-compose.yml`: `stop_grace_period`, staging companion volume, docs do canary,
   `pull` → rebuild no ROLLBACK.md.
10. `scripts/check_god_nodes.sh`: teto congelado por arquivo (ratchet).

**Cada item toca os gates: `./scripts/test.sh all` + companion gates; nada entra sem suíte nova
que falhe sem a correção.**

---

### A resposta para quem responde pelo dinheiro

**Maiores riscos:** (1) a perna de gold quebrada — não é exploit teórico, é o mecanismo central
do marketplace pagando/ não-cobrando silenciosamente; (2) reset de senha com 10⁶ de espaço e sem
tentativas — conta de pagante tomada = reembolso + reputação; (3) o pitch inteiro aposta no AH e
no cap de 1 h, exatamente os dois pontos onde os dados da categoria apontam contra; (4) chargeback
ausente num produto que já aceita dinheiro real. **Maiores oportunidades:** as correções acima são
dias, não semanas — a base técnica onde os concorrentes indie falham já existe aqui (integridade
de webhook, proveniência de moeda, gates honestos, runbooks); o par AH-browser-sem-P2W-preço-local
é o único espaço de mercado onde ninguém está; e fechar o cap + UI do AH + telemetria de funil
transforma a régua de 30/90 dias do roadmap em algo que finalmente pode ser medido. **Primeiro:**
P0-1 e P0-2 antes de convidar qualquer beta; depois, dias de trabalho nas P1 de UI/gates; só então
investir em conteúdo, ads e push.
