# Handoff de lançamento — itens que NÃO são código

Entregáveis de código da sequência de lançamento comercial já implementados e
com a suíte verde em cada commit (`SOM-IDLE: …`, "== RESULT: N checks, 0
failures =="):

- **1a** consentimento LGPD afirmativo no cadastro (versão/ts/IP persistidos).
- **1b** exclusão/anonimização de conta (art. 18) preservando o ledger financeiro.
- **1c** webhook com assinatura de provedor (Stripe, anti-replay) + catálogo
  autoritativo de SKUs (o valor concedido nunca vem do corpo).
- **1d** reembolso CDC art. 49 (7 dias, só gems não gastas) no EconomyService.
- **2** payload web: música morta removida do export Web — first-load medido
  57,9 MB → 32,4 MB gzip (ver `WEB_SLIM.md`).
- **3b** premiação de temporada automática (fecha + liquida no job diário).
- **3c** companion multi-thread + hook de alerta/uptime opt-in.
- **3a** scaffold de i18n pt-BR (CSV + TranslationServer + `tr()` nas strings de
  código de login/conta/chefe/AFK).
- **T1** checkout real Mercado Pago, integração técnica (`SOM-IDLE: …`, suíte
  `== RESULT: 1015 checks, 0 failures ==` + companion 75/75): companion
  `POST /checkout/preference` (Checkout Pro, valor do catálogo, fail-closed sem
  `SHAMBLETA_MP_ACCESS_TOKEN`) + `Checkout.gd` pedindo a preferência e abrindo
  a URL (`JavaScriptBridge window.open` no Web, `OS.shell_open` no Desktop) +
  página estática de retorno (`deploy/web/checkout_return.html`, servida na raiz
  do web) + `/checkout/simulate` preservado atrás de `SHAMBLETA_ALLOW_DEV_CHECKOUT`.
- **T2** escala de UI (`SOM-IDLE: …`, `SuiteUIScale` verde): `Gui.ApplyUIScale()`
  (mecanismo único — auto 1.2x mobile/web + manual Desktop), opção "Escala da
  interface" 100/125/150% em Settings (persiste, aplica no boot e ao vivo),
  `window/stretch/mode="canvas_items"` + janela default 1600×900 (viewport de
  design 1280×720 mantido), `ThemeDB.fallback_font_size` como API de fonte
  global. Auditoria das 6 janelas mais usadas (Game/Shop/AfkReport/Formation/
  Chests/SeasonPass): sem `clip_text` nem tamanho fixo — só mínimos, nenhum
  ajuste manual necessário.
- **T3** rewarded ads, integração técnica trocável (`SuiteAds` +2 checks):
  `AdProvider.ShowRewarded(placement, on_token)` via `SHAMBLETA_AD_PROVIDER`
  (`stub` = imediato p/ dev; `portal` = SDK via `JavaScriptBridge` objeto
  `ShambletaAds`, token só após confirmação de conclusão), 4 placements
  migrados p/ o caminho async, contrato JS + modo de teste em
  `deploy/web/ads_bridge.js`. Servidor inalterado (fail-closed + caps intactos).
- **T5** antifraude, sinal unificado: `EconomyService.FlagMultiAccount` abre
  `fraud_flag` kind `multi_account` (revisão manual, sem ban automático);
  `FEATURE_MATRIX §6` corrigida (estava "Planejado", o certo era "Implementado
  (parcial)"). **Decisão do dono (2026-09-18): fica só como sinal** (item 13-residual
  encerrado). **ATUALIZAÇÃO (2026-09-24): o produtor do sinal não media nada** — a
  heurística coletava a impressão digital no processo do servidor, então todas as
  contas gravavam o mesmo hash e a fila abria para todo mundo a cada login. Coleta e
  `LIKE` removidos do login; a API da fila fica, `SuiteFraud` amarra que a coleta não
  volta. Para ter detector de multi-conta é preciso entropia por instalação coletada
  no cliente (id persistido), base legal para esses campos e custo de falso positivo
  medido — **não é trabalho de beta**, e as três heurísticas com sinal verdadeiro
  (rajada de trade, velocidade de level, flip do mesmo item) continuam ligadas no job
  diário via `RunFraudScan`.
- **Correções de lançamento encontradas no caminho** (HEAD não bootava neste
  toolchain Godot estrito; todas cobertas pela suíte verde): `Peers.gd` sem
  `try/except` (GDScript não tem exceções — guards explícitos), `Map.gd`
  `GetMapBoundaries` restaurado, `Stats.Init` restaurando `actor = actorNode`
  (sem isso TODO XP/gold/essência online era no-op!), `FarmZoneData`
  revertido aos nomes reais do MapsDB (o rebrand 1021878 quebrava as 24 zonas),
  roleta de drops com spread via `hash` (o passo multiplicativo deixava 28/57
  itens inalcançáveis com pesos não-uniformes), `Settings/Shop/WebPush/
  Monitoring/DeviceFingerprint/Checkout` parse-safe (o `DeviceFingerprint.gd`
  dessa lista **não existe mais**: o achado (s) da auditoria tirou a coleta do
  caminho de login, o arquivo ficou sem chamador e foi removido — a lista acima
  é o registro do que não bootava, não o inventário de hoje), chave `Agreements Update`
  restaurada no `ui.csv`, timeout do job `idle-tests` 300→1200s.
- **T7** seasons verificada (não era gap de código): snapshots das 4 corridas +
  boards + premiação automática + `TickSeasonLifecycle` existem e passam
  (`SuiteSeasonRaces`/`SuiteSeasonPayout`); `SEASONS_GAP.md` e `FEATURE_MATRIX
  §5` corrigidos. **Decisão do dono (2026-09-18): pós-lançamento** — ativar a
  1ª temporada depois, com regras congeladas + changelog público (sem código).
- **Gate de idade (2026-09-24)** — cláusula "18+" virou a terceira do aceite
  afirmativo existente (migration `046_age_gate.sql`), cobrada no login **e** no
  checkout. Detalhe e limitações em §1 abaixo.

O que **depende de terceiros** e por isso NÃO foi (nem pode ser) codado aqui.

## 1. Jurídico / fiscal (advogado + contador)
- **CNPJ/MEI/Simples** como pessoa jurídica emissora (jogo pago/compra in-app é
  atividade econômica). NF-e para as compras (se aplicável ao modelo).
- **Texto final** de Termos de Uso + Política de Privacidade **revisados por
  advogado** alinhados à LGPD e ao CDC. A jurisdição **já é brasileira** no texto
  em vigor (`data/db/agreement.json`: "governed by Brazilian law, including the
  Consumer Protection Code (CDC) and the General Data Protection Law (LGPD)"), e
  o bump `AgreementPrivacyVersion = 2026-09-b` (e `AgreementTosVersion = 2026-09-c`, que
  saiu do canal de suporte do aceite em 2026-09-25) já força
  re-aceite dos ativos. O que falta é a **revisão profissional** em si: o texto
  continua marcado como placeholder pendente de advogado. As versões gravam por
  conta (`account.consent_tos_version`, `consent_privacy_version`,
  `consent_age_version`).
- **Idioma do corpo do aceite — entrega do dono, não ajuste de código.** O texto que o
  jogador aceita (`data/db/agreement.json`: 8 categorias, 5.315 caracteres) está todo em
  **inglês**, e não existe segunda versão para escolher: `Scrollable.AddContent`
  (`sources/gui/Scrollable.gd:44-49`) concatena `entry["content"]` cru — o arquivo inteiro
  não tem uma chamada `tr(` —, então o painel do aceite renderiza o JSON como ele é enquanto
  o resto da interface é i18n com PT-BR como língua fonte. Um aceite afirmativo cobrado por
  lei, prestado numa língua que o público-alvo não tem obrigatoriamente, é decisão de
  jurídico + produto. Não escrevo texto legal nesta casa: a entrega é "traduzir e revisar
  por profissional" **ou** "declarar a política de idioma" — as duas saídas são legítimas,
  a terceira (deixar como está sem decidir) não é.
- **Gate de idade (Lei 15.211/2025, "Lei Felca") — metade em código entregue, nas
  duas portas do dinheiro.**
  A declaração "tenho 18+" é a **terceira cláusula do mesmo aceite afirmativo**
  (migration `046_age_gate.sql`, `NetworkCommons.AgreementAgeVersion`), cobrada
  em dois lugares independentes: no login/criação (`SQL.IsConsentAccepted` →
  `ERR_CONSENT_REQUIRED`) e **no dinheiro** (`CheckoutService.GetCheckoutIntent`
  recusa `consent_required` antes de nem devolver preço). Bump da constante força
  re-afirmação dos ativos; `EraseAccount` zera a coluna junto (esquecimento).
  **Limitações que só o parecer jurídico fecha:**
  1. É **autodeclaração, não verificação de idade** — a lei exige "restrição
     efetiva de acesso de menores" + controle parental. Se o advogado entender que
     autodeclaração não satisfaz §21, o gate precisa de documento/birth-date
     verificado, e isso é produto novo, não ajuste.
  2. ~~As rotas HTTP do companion **não re-validam** a cláusula de idade.~~
     **Fechado em 2026-09-24.** A porta do dinheiro tem duas fechaduras e só uma
     tinha chave: `Server.gd`/`CheckoutService.gd` recusavam sem aceite vigente,
     mas `POST /checkout/intents` e `/checkout/preference` aceitavam qualquer
     `auth_token` válido — e o nginx do serviço `web` proxya `/checkout/` na mesma
     origem do jogo. Uma conta pré-046 (`consent_age_version = ''`) ou com token
     emitido antes de um bump não conseguia jogar e **conseguia pagar**. Hoje as
     três portas que tomam dinheiro (intent, preferência e o sandbox de staging)
     chamam `consent_currently_accepted`, que espelha `SQL.IsConsentAccepted`:
     igualdade com as versões vigentes, fail-closed se a declaração ou a coluna
     não estiver lá. O `/webhooks/payments` continua **sem** gate de propósito —
     ali o dinheiro já foi tomado e recusar seria descartar uma entrega paga
     (coberto por teste dos dois lados: `companion/test_security.py` C1–C5).
     **Procedimento de bump:** bumpar `NetworkCommons.Agreement*Version` exige
     bumpar `_agreements` em `data/conf/paid_catalog.json` no mesmo commit — o
     validador de boot (`EconomyCatalog.ValidatePaidCatalog`) e
     `SuiteCatalogConsistency` recusam as duas pontas desalinhadas, e como o
     catálogo é copiado para dentro da imagem do companion, rebuildar o companion
     faz parte do bump (igual ao bump de preço).
  3. Baús aleatórios pagos continuam ligados a essa interpretação (§21/§25 do
     relatório): sem parecer, o beta não aceita dinheiro de menores.
- **Classificação indicativa (CLASSIND/ERB)** para o país-alvo antes de monetizar
  público menor.

## 2. Pagamentos (onboarding de gateway) — **provedor: Mercado Pago**
- Abrir conta **Mercado Pago** como PJ e criar a aplicação/integração de checkout.
  Configurar o endpoint de **webhook (v2)** apontando para
  **`https://seudominio.com/webhooks/payments`** (a mesma origem do jogo — não
  existe URL própria de companion: ele não tem porta publicada e o tráfego entra
  pelo proxy do serviço `web`, ver `deploy/COOLIFY.md §3`), gerar a
  **credencial/secret** do webhook e setar
  `SHAMBLETA_WEBHOOK_PROVIDER=mercadopago` + `SHAMBLETA_MP_WEBHOOK_SECRET=<secret>`
  + `SHAMBLETA_MP_ACCESS_TOKEN=<access_token>` (o companion é fail-closed sem o
  secret). Com o access_token, ele **re-busca o pagamento** na API do MP e só
  concede com `status=approved` — não confia no corpo.
- **Contrato do checkout**: criar a preferência/payment com
  `external_reference = "<account_id>:<sku>"` (o companion faz o parse disso no
  pagamento re-buscado). Manter `SHAMBLETA_CATALOG_FILE` com o **mesmo** preço
  anunciado = cobrado; o amount concedido vem do catálogo, nunca do corpo.
  **Status técnico (T1 entregue, com uma correção de rota em 2026-09-24)**: o
  companion já cria a preferência sozinho
  (`POST /checkout/preference` — só falta setar `SHAMBLETA_MP_ACCESS_TOKEN` +
  `SHAMBLETA_MP_BACK_URLS_BASE=<url-pública-do-jogo>`); o client já abre a
  `payment_url` e o grant já entra pelo webhook sem intervenção. **Nada disso
  era alcançável no export web até esta data**: o client resolvia a base do
  companion por variável de ambiente — que browser não tem — e caía no default
  `http://127.0.0.1:8901`, ou seja, na máquina do próprio jogador; e o
  container bindava loopback. Agora `NetworkCommons.CompanionURL` é resolvido
  uma vez no boot (`Launcher._ready`), e no web a resposta é a origem da própria
  página, servida pelo proxy `/checkout/` + `/webhooks/` do serviço `web`. A
  suíte amarra as duas pontas (`SuiteDeployMode`). Prova de rota antes de
  assinar qualquer segredo: `deploy/COOLIFY.md §4` passo 4. Falta só o
  lado conta/credenciais abaixo.
- **Catálogo real**: fonte única em `data/conf/paid_catalog.json` (gems/vip/pass/
  starter/founder/donate, Pix + cartão). É o arquivo que o companion cobra (a imagem
  copia para `/app/paid_catalog.json` e o `--catalog` default resolve nele) e o mesmo
  que o game server valida no boot contra `EconomyCatalog.SHOP_CATALOG`
  (`EconomyCatalog.ValidatePaidCatalog`); a CI amarra anúncio, JSON e o
  `DEFAULT_CATALOG` embutido (fallback sandbox) na suíte `SuiteCatalogConsistency`.
  Só seta `SHAMBLETA_CATALOG_FILE` se o operator usar um JSON diferente.
- **Checkout "comprar gems" (Fase A, sandbox)**: `POST /checkout/intents`
  (valida SKU + elegibilidade starter, devolve `external_reference`) +
  `POST /checkout/simulate` (allow_dev, enfileira os grants) + loja no client
  (`Shop.gd` seção "Buy gems (sandbox)", `GetCheckoutIntent`/`CheckoutIntent` RPCs,
  `catalog`/`starter_offer`/`pending_grants` no `GetEconomyState`). Produção troca
  o simulate pelo checkout MP com o mesmo `external_reference`; o grant entra pelo
  `grant_queue` idempotente (chave = payment id; bundles = chaves derivadas).
- **Passe S1 (Fase C, backend pronto)**: PT/curva 5000 (L40), missões diárias/
  semanais/m marcos 100% server-side (ledger + telemetry), premium via grant
  `pass.s1` (R$ 24,90 no catálogo), skip 50 gems (máx 10), compra tardia com
  retroativo, auto-claim no encerramento, cosméticos em `cosmetic_grant` (uso
   pleno na Fase D), janela SeasonPass no client. **Deluxe implementado**
   (SKU `pass.s1.deluxe`, premium + 10 níveis + emote + 150 gems — preço
   R$ 44,90 **a confirmar pelo dono**, BATTLE_PASS_S1 §10.1).
- **Cosméticos (Fase D, dados prontos)**: catálogo (passe S1 + vitrine do
  renascimento + apoio), posse em `cosmetic_grant`, um equipado por slot,
  vitrine avulsa em gems com trava de marco, básico grátis no 1º ciclo,
  backfill Recruta/Fundador, janela Coleção, títulos nos leaderboards + skin
   na Formation. **Visuais (sprites/partículas) = follow-up de arte**.
- **Follow-ups executados**: tags de guild (`/guild tag`, visíveis no painel,
  board e corridas) e grant kind `cosmetic` (doação `donate.support`).
- **Fase F (guild/AH/torneios/doação, backend + UI prontos)**: pontos de guild
  no settle/vitória + board semanal + level-up fast (2× gems) + vault com
  teto expansível; AH com destaque pago e slots extras (taxa flat intacta);
  4 corridas (power/spend/boss_kills/guild_points) com prêmios; copa semanal
  gold-entry com título de Campeão; SKU `donate.support` (R$ 4,90 → título
  Apoiador). **Fora de escopo**: tags de guild e efeitos visuais (arte),
  **portais web** (decisão de distribuição + contas CrazyGames/Poki).
- **Rewarded ads (Fase E, integração técnica entregue — T3)**: `AdProvider`
  com provider trocável (`SHAMBLETA_AD_PROVIDER=stub|portal`), 4 placements
  opt-in migrados p/ `ShowRewarded` async (token só após conclusão real no modo
  portal), `afkhoras` compra +1 h de offline por view (F2P líquida 1 h, VIP 24 h sem assistir), caps por placement (1 baú, 2 chaves), VIP dobra quantidade, contrato JS + modo de teste
  em `deploy/web/ads_bridge.js`. **Decisão do dono (2026-09-18): CrazyGames** —
  falta criar a conta no portal e trocar o corpo do `ads_bridge.js` pelo SDK
  real (só `ads_bridge.js` + env, sem mudar jogo). (Válvula fail-closed intacta:
  formato errado nunca credita.)
- **Reembolso do dinheiro**: `RequestGemRefund` reverte as gems + marca
  `grant_queue.status='refunded'`; o companion faz a varredura com
  `server.py refund-sweep` (exige `SHAMBLETA_MP_REFUNDS=1` + access token;
  `--dry-run` p/ auditar). **Pendente: conta MP PJ** (handoff §2).

## 3. Operação
- **Schema dentro do container (única peça do boot não verificável neste host)**: o `game`
  roda do binário com o `.pck` embutido (`deploy/server/Dockerfile`) e as 46 migrations vêm de
  `res://data/conf/migrations/`, que só entra no pacote se o `include_filter` do preset
  `Linux/X11 Headless Server` (`export_presets.cfg`) alcançar o subdiretório. Medido aqui:
  `data/conf/*` alcança — `*` cruza `/` nos dois matchers do Godot 4.7.2. **Não medido:** a
  precedência entre `customized_files={"res://": "strip"}` e o `include_filter`. Desde
  2026-09-24 o boot reclama sozinho se o diretório não vier
  (`SQL: nenhum patch visível em res://data/conf/migrations/`). Confirmar no primeiro deploy:
  `docker compose logs game | grep "nenhum patch"` vazio **e**
  `sqlite3 /data/.local/share/Shambleta/live.db "SELECT version FROM migration;"` = 46. O 46 no
  primeiro boot é a prova de que o pacote trouxe o schema; número menor é o filtro de export,
  não o código.
- **Destinos de suporte: a hipótese confirmar-se, e o destino resolveu-se por remoção.**
  Em 2026-09-25 o dono confirmou que **nenhum** dos caminhos é do projeto: os links são do
  upstream de que Shambleta fez fork, e não existe servidor Discord próprio. A função saiu
  inteira do jogo com isso — a ponte (`sources/discord/`, 2 arquivos), o addon
  `addons/discord_gd` (33 arquivos, 224 KB de fonte, que iam dentro do pacote Web porque nenhum
  `exclude_filter` dos presets os tirava de lá — medido no `index.pck` exportado hoje: 38 entradas
  `discord_gd` antes, **zero** depois do re-export, e o pacote cai de 37 542 164 para 37 457 048
  bytes), o botão `OpenDiscord`, o endereço
  horneado em `LauncherCommons` e as duas frases de erro que o apontavam (`Login.gd`,
  `Character.gd`). O corpo do aceite parou de oferecer `discord.com/invite/UnY77dR` e o
  canal `#sourceofmana` na Libera e passou a dizer que perguntas sobre as políticas —
  reembolso incluso — se resolvem pelo canal de suporte publicado pelo projeto; como o
  texto que o jogador aceita mudou, `AgreementTosVersion` foi bumpado a `2026-09-c` nas
  três pontas que o guard amarra (const do jogo, `_agreements` do `paid_catalog.json`,
  fallback do companion), o que força re-aceite dos ativos. **O custo da limpeza é a
  entrega que fica:** hoje o jogo não tem canal de contato nenhum — não no aceite, não no
  erro de rede, não no `CONTRIBUTING.md`. Antes de abrir o beta o dono precisa publicar
  um destino (e-mail, formulário, o que for) e escrever os três lugares que precisam dele;
  até lá, quem leva o erro de rede lê um código e não tem para onde ir.
- **Backups offsite (T6 parcial)**: `SHAMBLETA_OFFSITE_BACKUPS` + restore probe
  existem e o mecanismo é testado (`SuiteOpsA2` + job CI); procedimento de
  restore S3 documentado em `som-idle-docs/archive/reports/
  OFFSITE_RESTORE_REPORT.md`. **Pendente (dono/infra)**: apontar para o bucket
  S3 real e executar o drill em container isolado (provar RPO/RTO e anotar no
  relatório).
- **Alertas/uptime**: setar `SHAMBLETA_ALERT_WEBHOOK` (healthchecks/Discord).
  Sugerido: um ping periódico externo ao `/health` do companion (dead-man's switch).
- **Promoção do companion**: reescrever em Go/Node + **Postgres** quando o CCU
  exigir (hoje SQLite/WAL single-node — `ARCHITECTURE §11`). A tabela
  `grant_queue` e a idempotência não mudam.
- **Medição de KPIs do beta**: D7 ≥ 20%, conversão ≥ 2%, ARPPU ≥ R$ 25,
  custo infra, ±15%/sem em faucet/sink — os dados já saem do `/metrics` do
  companion (D1, retention, gems mint/burn, trades, fees, VIP, settles). Requer
  jogadores reais no beta aberto.

## 4. QA web (só em navegador — não dá pra fechar headless)
- Smoke pós-deploy: primeiro load real (confirmar ~32 MB e tempo de boot), WSS,
  duelo de boss **ao vivo** na tela, `Formation` read-back, abrir baú, comprar
  VIP, fluxo de consentimento/cadastro, botão de exclusão de conta, idioma pt-BR
  via `TranslationServer.set_locale`.
- **Comprar gems do browser (fronteira do dinheiro)**: o que a suíte prova é a
  rota do proxy (curl) e a resolução pura da base
  (`NetworkCommons.ResolveCompanionURL`); o que só existe navegando é o ramo web
  de `Launcher._ready` — `JavaScriptBridge.eval("window.location.origin")` não
  roda headless. Confirmar na aba Network que o `POST /checkout/preference` sai
  na **mesma origem** da página, retorna `payment_url` e o `window.open` abre o
  Checkout Pro. Se aparecer `127.0.0.1` ou CORS no caminho, a regressão é real.
- **A credencial do mesmo POST (porta de sessão, decidida de propósito)**: o
  companion só aceita o checkout apresentando o `auth_token` do login, e o server
  emite esse token **somente com "lembrar" marcado**
  (`sources/network/server/Peers.gd` → `if rememberMe:`). Testar então os dois
  casos: com "lembrar" o corpo leva `auth_token` não-vazio e a resposta é 200;
  sem "lembrar" a janela deve mostrar **"Entre com lembrar-me para ativar o
  checkout"** (chave `Log in with remember-me to enable checkout`, `ui.csv:925`)
  e **nem sair o POST**. Um 401 `missing_token` com "lembrar" marcado é
  a volta do defeito corrigido em 2026-09-24 — `Checkout.gd` lia o token de sessão
  do `var` do painel (sempre vazio: o `Connect()` do login o aparava depois do
  auto-login) em vez do `Conf` onde `SaveToken` grava, e a loja ficou muda para
  100% dos jogadores. Nenhuma tela do jogo avisa melhor do que essa.
- **O 403 do aceite (`consent_required`)**: com uma conta cujo
  `consent_age_version` não é a versão vigente (pré-046, ou depois de um bump), o
  `POST /checkout/preference` tem que devolver 403 e a janela tem que dizer
  **"Pagamento bloqueado: entre na conta de novo para aceitar os textos
  vigentes."** (chave `Payment blocked: log in again to accept the current agreements.`,
  linha acrescentada em 2026-09-24 — antes dessa linha o `tr()` devolvia a chave e o
  jogador BR lia inglês justamente na tela que explica por que a cobrança não andou)
  — não o genérico "try again later". O lado server disso está coberto por
  `companion/test_security.py` (C1–C5); o que só existe navegando é a mensagem.
- **Nome da conta e 2FA no navegador (defeito de membro inexistente, corrigido em 2026-09-25):**
  três chamadas de 2FA em `sources/gui/Settings.gd:654` passavam `Launcher.Peer.peerID` e duas telas
  de compra liam `Launcher.nPanel.nameText` / `.savedToken` (`sources/gui/Shop.gd:173`,
  `sources/gui/Checkout.gd:252`). `Launcher` não tem `Peer` nem `nPanel` — GDScript **compila**
  acesso a propriedade inexistente de um autoload, porque o autoload é visto como `Node` e a busca
  pelo membro é em runtime: o erro nasce no clique do jogador, e nenhum gate desta máquina clica.
  Hoje a identidade é omitida (o destino de uma chamada de conta é a authority, e o sender vem do
  transporte) e o painel lido é `Launcher.GUI.loginPanel`. A varredura de superfície de autoload
  passou a conferir chamada **e** propriedade contra o objeto vivo (`SuiteAutoloadSurface`, 1678
  acessos, zero quebrados), então a volta dessa classe de defeito pega no portão — mas o clique em
  si continua sendo teste de mão: Settings → ativar 2FA (botão → QR → código de 6 dígitos) e compra
  em sandbox conferindo o nome da conta no recibo.
- **Popup bloqueado na página de pagamento (a segunda porta)**: a URL que volta do
  `POST /checkout/preference` chega depois de um round trip, e `window.open` disparado
  fora da *user activation* é exatamente o que o bloqueador de popup come. Com o bloqueio
  desligado a aba abre sozinha; com ele ligado, a janela tem que mostrar
  **"Abrir página de pagamento"** e esse clique tem que abrir o Checkout Pro. Testar com
  o bloqueio ligado de propósito — é o único caso em que a segunda porta aparece.
  No mesmo caminho, conferir o rótulo: depois de uma corrida, reabrir a loja para outro
  SKU tem que mostrar **"Pagar agora"**, nunca "Fechar" — botão rotulado Fechar que,
  apertado, cobra, é a pior mensagem possível numa tela de dinheiro.
- **As 18 linhas novas do lote de i18n (2026-09-24)**: a suíte trava que nenhuma
  `tr("literal")` de `sources/` fica sem `pt_BR` no catálogo compilado, mas o que ela não
  vê é o **caixa** — texto traduzido é texto mais longo. Conferir em pt-BR: o fluxo de
  2FA inteiro (ativar → QR → código de 6 dígitos → errado/desativar — 13 chaves, das
  quais 12 liam inglês e `OK` é igual nos dois idiomas), o rótulo **"Itens obtidos:"**
  e **"Eficiência:"** no relatório AFK,
  **"Offline no teto — cada anúncio adiciona 1 hora"** no painel de anúncio (a antiga "Anúncio 2× armado" saiu em 2026-09-25, quando o anúncio passou a comprar hora), e
  **"no máximo"** na janela de personagem. Se alguma linha estourar o painel ou cortar
  com `…`, o defeito é de layout e só aparece agora, porque até ontem essas telas eram
  medidas em inglês.
- **Instalável e atualizável (o service worker é do engine, não nosso)**: o preset `Web`
  liga `progressive_web_app` e quem registra o worker é o próprio shell do engine, no
  `index.html` exportado (`engine.installServiceWorker()`). O worker cacheia o primeiro
  load de forma ávida e declara uma página offline, que sai no pacote
  (`index.offline.html`). Nada nesta árvore registra worker próprio de propósito:
  `deploy/web/sw.js` não é copiado pelo `Dockerfile` e registrá-lo no escopo raiz
  deslocaria o worker do engine, matando o cache do primeiro load (a razão está escrita
  em `sources/web/WebPush.gd`). O `scripts/qa_web.mjs` já confere de graça o manifest
  (`display: standalone` + ícone) e **exatamente um worker registrado no escopo raiz**.
  Instalar no celular ("Adicionar à tela inicial", iOS e Android) continua teste de mão.
- **Deploy novo não entra sozinho — o diálogo de update**: o worker do engine não chama
  `skipWaiting` no install, então um release novo fica `waiting` e só assume quando
  recebe `postMessage('update')`. `sources/web/PwaUpdate.gd` (autoload) pulsa a cada
  60 s, **só com o FSM em estado de login**, uma vez por sessão, e oferece
  "Atualizar agora" / "Depois" (chaves `Update now` e `Later` em `data/i18n/ui.csv`).
  A suíte trava o contrato da fiação — pulso web-only, porta de login,
  `pwa_needs_update`, diálogo, `pwa_update` e a porta reavaliada no clique. O que ela
  **não** mede, porque exige dois deploys: o caminho ponta a ponta. Na staging, então:
  abrir o build velho e publicar de novo → na tela de login a janela tem que aparecer em
  ≤ 60 s; "Atualizar agora" tem que recarregar na versão nova (comparar o `CACHE_VERSION`
  de `index.service.worker.js` antes e depois); "Depois" não pode voltar a perguntar na
  mesma sessão; e deixar o diálogo aberto enquanto se entra no jogo não pode resultar em
  reload no meio da partida — é para isso que a guarda é reavaliada no clique, não só na
  abertura.
- **Para bater <25 MB**: as alavancas de `WEB_SLIM.md` (re-compressão de
  texturas, pack de áudio remoto) exigem QA visual.

## 5. Git + CI (T4 parcial)
**FEITO em 2026-09-25, nesta máquina, depois da cópia de HD:** a passada inteira está
commitada e no remoto — `6277671` ("Beta entra no índice: a passada da auditoria inteira
num commit só"), push `da2531c..6277671` em `origin/master`, com **148 caminhos** no
commit (98 `M`, 31 `D`, 18 `A` e 1 `R` — o rename que o git detectou sozinho foi
`companion/catalog.json` → `data/conf/paid_catalog.json`, 54% de similaridade). A árvore
ficou limpa e `HEAD` passou a conter as 46 migrations e cada módulo que antes só existia
solto. Autorização do dono obtida antes de commitar e enviar, como este parágrafo exigia.
A régua foi re-medida **antes** do commit, aqui: os nove gates com as mesmas contagens do
parágrafo abaixo, e o pacote Web re-produzido do zero nesta máquina fechou o QA de
navegador em `== RESULT: 10 checks, 0 failures ==` (boot do engine no Chromium,
`crossOriginIsolated`, `SharedArrayBuffer`, canvas, manifest standalone, exatamente um
service worker no escopo raiz, zero requisição falha, zero erro de console), com
first-load medido em **36 MiB** gzip. O texto a seguir descreve o estado **pré-commit** e
continua válido pelo motivo estrutural — os arquivos têm que entrar juntos — mas onde ele
diz "nenhum arquivo da passada de beta está commitado", hoje é histórico.

**Estado re-medido nesta passada (2026-09-24, 23:15 -0300 / 2026-09-25 02:15 UTC):** `HEAD` ==
`origin/master` ==
`da2531c` ("Conserta exports do CI", 2026-09-24 02:32 -0300) — o remoto está no mesmo
commit do local, e **nenhum arquivo da passada de beta está commitado**: `git status
--porcelain` retorna **149 caminhos** (98 `M`, 32 `D` — 26 deletados no worktree e 6
deletos já no índice — , 19 `??`; a contagem é `git status --porcelain | cut -c1-2 | sort | uniq -c`,
que é como ela foi refeita aqui depois de uma primeira passada de contagem que não batia). Nada foi commitado nem
enviado por mim — commit e push pedem autorização explícita do dono.

**A régua está verde, medida agora** (`./scripts/test.sh all`, `/tmp/suite_beta_final28.log`):
**9× `Gate §24-8 OK`** com `SUITE_EXIT=0` — idle `== RESULT: 2257 checks, 0 failures ==`,
`== RPC IDENTITY: 10 checks, 0 failures ==`, e2e `== RESULT: 0 failures ==`,
backup `8 checks, 0 failures`, `== Benchmarks: 0 failures ==`,
`== COMPANION: 100 checks, 0 failures ==`, `== SECURITY: 47 checks, 0 failures ==`,
`== REFUND CLI: 12 checks, 0 failures ==` (5× `godot exit=0` + 3× `python exit=0`). O passo
novo do portão — preflight de parse dos seis harnesses, ~1 s, local e no job `idle-tests` da
CI — existe porque um `CheckEq` com `String` derrubava o `load()`/`.new()` do runner e o gate
só descobria no timeout de 1200 s; três execuções foram perdidas assim nesta passada.

Dos 19 untracked, um é documentação e um é scratch: `AUDITORIA_INDEPENDENTE_2026-09-24.md`
e `build/` (saída do `scripts/export_web.sh` — pacote gerado, nunca se commita).
Os 17 restantes são o que o boot e o portão exigem (cada linha conferida contra os
chamadores na árvore): `scripts/ci_gate_log.sh` (o quádruplo que `scripts/test.sh`
chama), `scripts/export_web.sh` + `scripts/qa_web.mjs` (os produtores locais do
pacote web — ver §CI abaixo), `data/conf/paid_catalog.json` (a fonte única que
`EconomyService` valida no boot), `data/conf/migrations/043..046.sql` (chat moderação,
`price_paid`/`currency`, view de coorte, `consent_age_version`),
`sources/system/MetricsServer.gd` (`/healthz`+`/metrics`; instanciado em `Launcher`),
`sources/gui/ManualHudBar.gd` (a construção da barra de HUD que `Gui` monta),
`sources/web/PwaUpdate.gd` (o autoload do update do PWA, registrado em `project.godot`),
`sources/network/server/ChatModeration.gd` (usado em `Server`, `SQL` e `WorldCommands`)
e `tests/run_rpc_identity_test.gd` (o gate de identidade S1), mais os sidecars `.uid`
destes quatro últimos. (`data_tables.txt`, o scratch de medição que estava nessa lista,
foi removido da árvore na passada do item (m) — não é artefato de nada.)
Em `HEAD` o
workflow também **não** chama o gate (zero ocorrências de `ci_gate_log`) e o
`deploy/companion/Dockerfile` **não** copia o catálogo (zero ocorrências de
`paid_catalog`) — as duas linhas só existem na árvore de trabalho.

**E, ao contrário do que a primeira versão desta linha dizia, `HEAD` não é uma árvore quebrada**:
`git grep -l` contra o commit retorna **zero** ocorrências de `ChatModeration`, `paid_catalog.json`,
`ci_gate_log.sh`, `run_rpc_identity_test.gd` e `044`–`046` (só `docs/development/architecture.md`
cita `MetricsServer`), e as migrations param em `042`. `HEAD` é autocoerente — é o jogo
**pré-auditoria**, que boota o que era e roda o portão antigo. O que não existe fora desta máquina
é o beta. É por isso que os dezoito entram **no mesmo commit** dos rastreados que já os chamam pelo
nome (`scripts/test.sh` chama o avaliador quádruplo, o workflow tem os jobs que o espelho
cobre, `Launcher` instancia o `MetricsServer`, `project.godot` registra o autoload `PwaUpdate`,
`Gui` monta o `ManualHudBar`, `Server`/`SQL`/`WorldCommands` usam o `ChatModeration`):
separados, o índice fica com um `M` que referencia um `??` que ninguém versionou.

**Os sidecars `.uid` entram no mesmo commit** (medição: `git ls-tree -r HEAD | grep -c '\.uid$'`
= 362, então este repositório versiona `.uid`): dos cinco scripts novos acima,
`ChatModeration.gd.uid`, `run_rpc_identity_test.gd.uid`, `ManualHudBar.gd.uid` e
`PwaUpdate.gd.uid` estão **fora do índice** (`??`) e
`MetricsServer.gd.uid` está o contrário — **já está em `HEAD` enquanto `MetricsServer.gd` não
está**, i.e. `da2531c` carrega um `.uid` órfão. Nenhum `.tscn`/`.tres` referencia os cinco uid
(`grep -r "uid://<id>"` = 0 ocorrências cada), então o efeito não é referência quebrada: é o
Godot regenerar UUID em quem clonar e o `.uid` virar ruído de diff depois. Conferido: **todo
`.gd` sob `sources/` e `tests/` tem o sidecar na árvore de trabalho** (varredura null-safe,
zero sem `.uid` — o `for` sem `quote-while-read` quebra no diretório com espaço, ver abaixo).
A varredura dos `.uid` do índice contra `git cat-file -e` não acha outro órfão além de
`MetricsServer.gd.uid` — e ela mesma tem uma armadilha registrada porque vale para qualquer
script nesse repositório: `sources/scripts/tonori/tulimshar outskirts/` tem **espaço no nome
do diretório**, então um `for u in $(git ls-tree …)` sem `quote-while-read` parte o caminho,
o `cat-file` falha e o par `Chest.gd`/`Chest.gd.uid` — que está inteiro em `HEAD` — aparece
como falso órfão.

**Estado re-medido na passada de monetização idle + vitrine (2026-09-25):** `HEAD` ==
`origin/master` == `2fbbc40`. Durante a passada `git status --porcelain` chegou a retornar
**34 caminhos** (26 `M` e 8 `??`); apagado o scratch, o estado é **28 caminhos** — 26 `M` e 2 `??`,
nenhum `D`. Os dois soltos são produto: `sources/economy/Storefront.gd` e o sidecar
`Storefront.gd.uid`, que entra junto exatamente pela regra do parágrafo acima (este repositório
versiona `.uid`). Os seis `??` que não sobraram são scratch e foram apagados: quatro `tools/*.py`
usados para re-mapear ponteiros e dois `tools/win_probe*.gd` da sonda de janelas do registro abaixo.
Ordem honesta das medições: a **primeira** régua de nove gates foi corrida com o scratch ainda na
árvore e derrubou no e2e — `godot exit=124` depois de o harness imprimir `== RESULT: 0 failures ==`,
então os quatro gates seguintes (backup, benchmarks, companion, refund) nem rodaram e o run fechou
`ALL_EXIT=1`. O harness solo fecha em 2,2 s contra o cap de 120 s do gate, em quatro execuções
seguidas na mesma máquina sob a mesma carga: é saída atrasada, não regressão de código — e o run
vermelho fica registrado aqui em vez de apagado por conveniência. O run que **sustenta o commit** é o
segundo, já com o scratch fora, os três docs guardados re-medidos (a contagem de ponteiros abaixo é
dele) e o preço em vigor do `pass.s1` registrado no ROADMAP: `ALL_EXIT=0`, 9× `Gate §24-8 OK`.
Nenhum gate lê `tools/` (o preflight parseia os 6 harnesses, o anti-god-node mede `sources/` e
`companion/`), então a limpeza não invalidaria a medição de qualquer forma. Nada foi commitado nem
enviado por mim — commit e push pedem autorização explícita do dono.

**A régua está verde, medida agora** (`./scripts/test.sh all`, com o exit code gravado no fim do
log em vez de lido de pipe — pipe a `tail` destrói o código de saída, erro já cometido nesta
sessão): os mesmos **9× `Gate §24-8 OK`**, com preflight de parse nos 6 harnesses e anti-god-node
em 0 falhas nos 278 arquivos medidos (teto de 800 linhas, 6 em allowlist; `EconomyService.gd` está
em 787 e `EconomyCatalog.gd` voltou a 758 porque a política de vitrine saiu para o arquivo novo),
idle `== RESULT: 2327 checks, 0 failures ==` (contra os 2257 do snapshot datado acima — o
acréscimo é a regra de hora comprada e a vitrine honesta, cada uma com suíte própria), RPC
`10 checks`, e2e `0 failures`, backup `8 checks`, benchmarks `0 failures`, companion
`== COMPANION: 170 checks, 0 failures ==` (a varredura de rótulo de cobrança nos dois catálogos é
a parcela nova), security `47 checks`, refund CLI `12 checks`, fechando com 5× `godot exit=0` e
3× `python exit=0`.

**O export Web foi re-rodado depois da passada e a QA de navegador passou** (`scripts/export_web.sh`,
`EXPORT_EXIT=0` gravado no fim do log): primeiro-load gzip **36 MiB** (`37666178` bytes, 18 arquivos),
sendo engine 12 MiB + `.pck` 21 MiB + shell 3 MiB — a remoção do addon do Discord medida, não
estimada, é o que consta em `2fbbc40`. O `playwright` do gate de browser fechou com
`== RESULT: 10 checks, 0 failures ==`.

**Passada de performance (2026-09-26) — o que ela achou, e é a parte que importa para o handoff.**
`HEAD` == `origin/master` == `e72f0af`, e a árvore está com **20 caminhos** sujos (19 `M` + 1 `??`),
nenhum `D`: o único solto é `data/conf/migrations/047_performance_indexes_iii.sql`, produto, que entra
junto com os 19. Dos 19 modificados, cinco são documentação (esta, o roadmap, as duas auditorias e o
`WEB_SLIM.md`), um é o preset Web, nove são `sources/` e três são harnesses de teste. O achado não é de
performance, é de **medição**: o teto de checkpoint do WAL tinha
sido posto como um tick de `PRAGMA wal_checkpoint(PASSIVE)` dentro de `_process`, e os gates entram
por `godot --headless -s` — que chama `_process`, mas só entre frames, e o probe é um laço síncrono que
não abre frame nenhum (sondado nesta máquina com um `Node` contador: 400 ms de laço devolvem `_process=0`,
12 `await process_frame` devolvem 11). O gate de benchmark rodou com o default do
SQLite e fechou vermelho na régua: `p99 249273 µs` contra orçamento de 200000 µs, 2 de 200 settles a
249 ms e 270 ms (`/tmp/shambleta-all.log`, `== Benchmarks: 1 failures ==`, `wrapper exit=1`). Ou seja:
o verde anterior era verde sobre a ausência do remédio. O tick saiu e virou
`PRAGMA wal_autocheckpoint=4000` no bloco do servidor (`sources/sql/SQL.gd:1316`), junto das outras três
pragmas. A cadeia de medição completa — 64 páginas (pior: 26 de 200 hitches), 4000 páginas com 200
iterações (verde **cego**: `max 667 µs`, nunca cruza a fronteira do checkpoint), e 4000 com 800
(`p50 382 µs / p99 527 µs / max 427118 µs`, 2 hitches de 800, orçamento 16, reproduzido em
`/tmp/shambleta-bench-4.log` e `/tmp/shambleta-bench-5.log`) — está em `deploy/WEB_SLIM.md` e no item (8)
da auditoria. Lição que vale para qualquer mitigação futura neste repositório: **se mora em
`_process`, nenhum benchmark daqui a exercita**; ou se expõe o efeito no laço medido, ou se declara no
endereço do runtime real.

**O gate de benchmark foi reconstruído junto**, porque o probe antigo media o que não existia: o
XP walk era `totalXp += 10` (a auditoria chamou de medir zero) e saiu; entraram leaderboard com
asserção de `EXPLAIN QUERY PLAN` (usa `idx_character_leaderboard`, ordem `power_score DESC`, nenhum
temp B-tree — é o guard da migration 047), browse do leilão via `idx_auction_browse`, progresso em
lote (`1 ms, 3 queries, 1 tx para 150 entradas`) e orçamento de **taxa** de hitch além do p99
(`tests/benchmarks.gd:301`), porque com 800 amostras 1% de hitch cai exatamente no furo do p99.
Medido agora: `Settle benchmark: 1 ms, 11 queries, 1 tx` · `Zone catalog: 0 ms for 24 zones` ·
`Leaderboard: 1 ms, 50 de 60 personagens` · `Auction browse: 0 ms, 20 de 200 listing(s)` ·
`Progress save: 1 ms, 3 queries, 1 tx` · `== Benchmarks: 0 failures ==`, `godot exit=0`. A suíte idle
subiu para `2356 checks, 0 failures` (`/tmp/shambleta-idle.log`) com `SuiteProgressUpsert`, que é a
parte de **semântica** do save em lote (linha que não atualiza, chave que colide com outro personagem,
chunk que engole o resto) — o benchmark mede custo, a suíte mede correção.

**Fecho da passada, medido com a documentação já congelada:** `./scripts/test.sh all` fecha
`ALL_EXIT=0` com os nove `Gate §24-8 OK` — preflight de parse nos 6 harnesses, anti-god-node 0 falhas
em 278 arquivos, idle `2356 checks, 0 failures` (os 165 ponteiros `arquivo:linha` dos três documentos de
evidência conferidos, 11 com mensagem de check batendo na linha, 33 nomes de suíte resolvidos), RPC 10,
e2e 0 falhas, backup 8 (migration 47 = live 47), benchmarks 0 falhas (`p50 383 µs / p99 566 µs / max
479731 µs`, 2 hitches de 800), companion 170, security 47, refund CLI 12, com 5× `godot exit=0` e 3×
`python exit=0` (`/tmp/shambleta-all-final2.log`). Terceira execução independente do probe, e a única
que roda o gate inteiro na mesma árvore que descreve.

**Peso de pacote, medido depois:** quatro padrões a mais no `exclude_filter` do preset Web (`tests/*`
e três arquivos de logo de imprensa) → first-load gzip **35 MiB** (`36734788` bytes, 18 arquivos,
`−931390` B contra a medição de `2fbbc40`), `.pck` 21 → 20 MiB, engine 12 e shell 3 inalterados
(`scripts/export_web.sh`, saída em `/tmp/shambleta-export-B.log`). Boot
revificado em Chromium real: `== RESULT: 10 checks, 0 failures ==`, e a string da migration 047 continua
dentro do `.pck` (o `include_filter` de `data/conf/*` não foi tocado). **Armadilha registrada, porque
custa caro e é silenciosa:** um bloco de comentário `#` acima de `exclude_filter` em
`export_presets.cfg` faz `ConfigFile.load()` devolver OK e a chave **desaparecer** — o export passa a
empacotar tudo e nada reclama. O arquivo ficou sem linha iniciada por `#`; o rationale vive na
documentação. Também fica aberto, com número e sem execução: `application/boot_splash/embed=false`
cortaria 2,4 MiB de uma cópia raw do splash dentro do `.pck`, mas nenhuma asserção cobre o splash do
engine no Web (`scripts/qa_web.mjs:174` só coleta `splashLoaded` do `<img>` do shell) — é verificação
de navegador, não suposição.

**As janelas abertas de fato (2026-09-25)** — nenhum teste cobre o render, então a passada abriu
cada janela num `godot --headless -s` com SceneTree próprio, autoloads reais e um fixture criado por
`SQL.CreateFixture` (`tools/win_probe.gd` + `tools/win_probe_impl.gd`, apagadas depois; o print da
rodada é a evidência, não o script). `economy.GetEconomyState` no fixture: `season_active=false
catalog=8`. Loja instanciada de `presets/gui/Shop.tscn`: rótulos `VIP 1 — 440 gems / 30 days (24h
offline, no ads)`, `VIP 2 — 880 gems / 30 days (24h offline, loot 2×)`, `VIP: inactive (offline cap
1h + 1h per ad)`, e **8** botões de catálogo (550/1200/3000 gems, VIP 30d/90d, Starter, Founder,
Support) com as duas assinaturas **ausentes** — que é o `season_active=false` virando vitrine honesta
na tela, o comportamento que a Fatia 2 promete. Checkout com `ShowCheckoutIntent` do `42:pass.s1`:
no nativo (`LauncherCommons.isWeb = false`) o rótulo é `Intent 42:pass.s1 — Passe S1 R$ 24.90.
Compra apenas na versão web (o sandbox do companion responde 403 no nativo).` com o botão
`disabled = true`; na web, `Press Pay to open secure checkout.` com `disabled = false`. AFK com
4h/4h dobrada: `Ausente: 4.0h (teto 4h)`, `Itens obtidos: 2 (2×)`, `Baús: 1`, `Eficiência: → 60%`,
`Offline no teto — cada anúncio adiciona 1 hora` e o botão `+1 hour offline (ad)` com
`disabled = false`; a segunda rodada F2P (1h, sem dobrar) mostra `Ausente: 1.0h (teto 1h)` e
`+300 XP` sem o `2×`. Cosméticos: exatamente **1** botão comprável na vitrine,
`Renascido III — locked (rebirths 3)`. Os três strings novos do `.tscn`/`AfkReport` têm paridade no
`data/i18n/ui.csv` — linha 15 (a linha do teto), 969 (o hint do anúncio) e 974 (o rótulo do botão).

**Um detalhe que a sonda achou, e que não é bug do produto.** Na primeira rodada passei
`"drops": []` no `NetClient.LastAFKReport` e o `ShowReport` morreu em
`SCRIPT ERROR: Trying to assign value of type 'Array' to a variable of type 'Dictionary'` em
`sources/gui/AfkReport.gd:42`, abortando o render no meio (`Baús: 0` e hint vazio). É bug da sonda:
`OfflineSettle` declara `var drops : Dictionary[int,int]` e o `AfkReport.gd:42` tipa o mesmo
`Dictionary`, então o caminho servidor-cliente de hoje nunca entrega `Array`. Vale registrar
mesmo assim porque é uma fronteira: um payload malformado vindo da rede não degrada a janela, ele
interrompe o método. Corrigido o fixture para `{9001: 2}`, o render completo saiu como acima.

**Os 32 deletados foram re-verificados em 2026-09-25 e estão limpos.** Dos 15 `.gd`, dez são o
fracionamento `SQL*.gd` (consolidado em `SQL.gd`), mais `WebhookValidator.gd`,
`DeviceFingerprint.gd` (o coletor de hardware que a S5 proíbe no servidor — sem chamador
fora da própria suíte) e o trio de multiplayer morto (`MultiplayerTests.gd`, `gut_runner.gd`,
`run_multiplayer_tests.gd`); nenhuma chamada sobrevive — a varredura de parse dos `.gd` sujos
voltou verde com a mesma âncora do preflight, e uma `preload`/`class_name` pendurada daria `SCRIPT ERROR: Parse Error`. Os
15 sidecars `.uid` correspondentes não são referenciados por cena nenhuma (`grep "uid://<id>"` em
`.tscn`, `.tres` e `project.godot`: **0** de 14). E `companion/catalog.json`, o único deletado que
não é script nem sidecar, tem **zero** referência funcional: `grep -rn "catalog\.json"` em
`companion/*.py`, `deploy/`, `scripts/`, `.github/`, `sources/`, `tests/` e `data/`, descontado o
novo `paid_catalog.json`, não retorna nada — o que sobra é menção de documentação de auditoria,
que é histórico, não link.

Consequência prática para quem for fechar o beta: `da2531c` é um estado antigo e
**autoconsistente** (migra até 042, compila, roda), então o risco não é "commit parcial
quebrar o remoto" — é a passada inteira viver fora do índice. Ela tem que entrar **junto e
numa ordem coerente**, porque as dependências são circulares no sentido operacional: o
código que lê `consent_age_version` não funciona sem a migration 046, o `COPY` do
Dockerfile do companion falha no build sem `paid_catalog.json`, e o job de testes falha
sem `ci_gate_log.sh`. Commit de metade = boot com `IsConsentAccepted` caindo em coluna
ausente (ninguém loga) ou imagem do companion que não builda. A régua antes de commitar é
`./scripts/test.sh all` nos nove gates, com o log no formato que o gate quádruplo lê.
**Medida em 2026-09-25 03:10 -0300, na árvore exata desta passada: verde** — `SUITE_EXIT=0`,
9× `Gate §24-8 OK`, idle 2257/0, rpc 10/0, e2e 0, backup 8/0, bench 0, companion 100/0,
security 47/0, refund 12/0 (`/tmp/suite_beta_final28.log`). Ela vale para o commit enquanto
nada em `sources/`, `tests/`, `companion/` ou `data/conf/` mudar depois; mudou, é `quick` +
os três python antes de commitar.

**O comando que fecha isso** — **executado em 2026-09-25 (`6277671`, push feito); preservado
abaixo porque é o procedimento de qualquer leva futura do mesmo tipo.** Nada aqui roda
sozinho: commit e push pedem autorização do dono.
Um `git add -A && git commit` é o que mantém os dois conjuntos juntos, porque `-A` pega os 98
modificados, os 32 deletados **e** os 18 soltos (o décimo nono `??`, `build/`, é saída de
export — **não** entra: `scripts/export_web.sh` o regenera a cada rodada; a ressalva medida
no commit real é que `build/` colapsa num único path adicionável, `build/.gdignore`, porque
o `.gitignore` tem `!build/.gdignore` de propósito — ele entrou, são 0 bytes e é o marcador
que impede o import da rodada seguinte de empacotar o export anterior; nenhum byte de artefato
entra). A alternativa explícita, listada como foi medida
em `git status --porcelain | grep '^??'` (menos `build/`), é adicionar um por um:

```
AUDITORIA_INDEPENDENTE_2026-09-24.md
data/conf/migrations/043_chat_moderation.sql
data/conf/migrations/044_grant_price_paid.sql
data/conf/migrations/045_cohort_view.sql
data/conf/migrations/046_age_gate.sql
data/conf/paid_catalog.json
scripts/ci_gate_log.sh
scripts/export_web.sh
scripts/qa_web.mjs
sources/gui/ManualHudBar.gd
sources/gui/ManualHudBar.gd.uid
sources/network/server/ChatModeration.gd
sources/network/server/ChatModeration.gd.uid
sources/system/MetricsServer.gd
sources/web/PwaUpdate.gd
sources/web/PwaUpdate.gd.uid
tests/run_rpc_identity_test.gd
tests/run_rpc_identity_test.gd.uid
```

(`sources/system/MetricsServer.gd.uid` não está nessa lista porque **já está** em `HEAD` — é o
`.uid` órfão descrito acima.) Antes de commitar, a mesma consulta tem que retornar exatamente
estes dezoito mais `build/`; qualquer outro caminho novo é scratch que não deveria entrar. E o `add` de cada
`??` é obrigatório junto com o `M` do rastreado que o chama pelo nome (parágrafo acima) —
`M` sem o seu `??` é boot que referencia arquivo que ninguém versionou.

**CI — os créditos voltaram e os jobs rodam (medido em 2026-09-25, nesta máquina).** O que
este parágrafo afirmava antes ("nenhum job roda") está superado, e a primeira execução do
beta serviu exatamente para nada: o run de `6277671` falhou em `Companion Money Tests` com
**exit 126**. Não era o companion — era o bit de execução. O step roda `./scripts/test.sh
companion` e `scripts/test.sh` vivia no índice como `100644`; localmente funcionava porque o
disco desta máquina está 755 em tudo (artefato da cópia de HD) e `core.fileMode=false` manda
o git ignorar a divergência. Ou seja: **um clone novo não conseguia rodar a régua de
lançamento**, invocada por caminho em 29 lugares da documentação. Reproduzi a falha em
checkout limpo ("Permissão negada"), corrigi só o modo em `ccc927a` (mesmos blobs) e provei
partindo do clone. **O run de `ccc927a` fechou verde nos 12 jobs**, incluindo
`Companion Money Tests` e `SOM-IDLE Idle Tests` — a suíte de 2257 checks passando num
checkout limpo, em Godot 4.7.1. É a primeira vez que o beta tem evidência construída fora da
máquina de quem o escreveu; antes, a única prova eram logs em `/tmp`, que morreram com a
máquina antiga junto de `/tmp/suite_beta_final28.log`, `/tmp/web_export_4.log` e
`/tmp/qa_web_3.log` (as re-medidas atuais: `/tmp/export_web_remedia.log`, mais os runs em
`gh run list --repo docerol/shambleta`). Radar de segurança conferido no mesmo run: o passo
`Publish snap` ficou **skipped** (sem `SNAPCRAFT_STORE_CREDENTIALS`), então nenhum push
publicou artefato público — mas o `if` dele é `github.ref == 'refs/heads/master'` com o
segredo, então publicar a cada master push é o que acontece assim que alguém preencher a
credencial. Timeout do `idle-tests` segue em 1200 s (a suíte com sims reais não cabe em 300 s).

**CI não é produtor do artefato** — continua vero, e agora com a ressalva de que ela *prova*
sem *produzir*: os produtores reais do beta, medidos nos arquivos, são três e nenhum é a CI:
`deploy/server/Dockerfile` (export headless), `deploy/web/Dockerfile` (multi-stage que
horneia `SHAMBLETA_SERVER_ADDRESS` no `settings.cfg` antes do `--export-release "Web"` —
é ele que o Coolify builda) e `scripts/export_web.sh` (pacote local + régua de peso +
boot no navegador via `scripts/qa_web.mjs`). Sobre o peso: o export Web emite
`::nota::`, não aviso-gate — os 25 MB são meta de arte pós-beta, ver `deploy/WEB_SLIM.md`.
**Fechado (era "pendente, só com acesso ao GitHub")**: as execuções foram confirmadas pela
API, e a régua de "a CI não exercita os gates desta passada" não vale mais — `ccc927a` é o
beta inteiro nos doze jobs. Histórico medido dos runs, do mais antigo ao mais novo:
`f781f71` / `7d5e514` / `bd69275` falhando nos cinco jobs de export (keystore e templates —
foi o que `da2531c` consertou, e ele fechou verde), `6277671` verde em onze e vermelho só
em `Companion Money Tests` (o exit 126 acima), `ccc927a` **success**. A evidência do beta
deixou de ser local: `gh run list --repo docerol/shambleta`.

**Pós-beta: música na web (achado #69).** `Audio._StreamMusicFromWeb` está inerte por dois
bloqueadores independentes (não investigados nesta passada — trabalho de beta é só o boot
limpo, que o guard de `DB.gd` + `FileSystem.DirExists` já entrega): o streaming em si e o
caminho que o alimentaria. Não é fiação de beta; fica como handoff, junto com o pack de
áudio remoto já descrito em `deploy/WEB_SLIM.md`.
