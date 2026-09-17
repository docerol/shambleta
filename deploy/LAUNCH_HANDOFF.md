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

O que **depende de terceiros** e por isso NÃO foi (nem pode ser) codado aqui.

## 1. Jurídico / fiscal (advogado + contador)
- **CNPJ/MEI/Simples** como pessoa jurídica emissora (jogo pago/compra in-app é
  atividade econômica). NF-e para as compras (se aplicável ao modelo).
- **Texto final** de Termos de Uso + Política de Privacidade **revisados por
  advogado** alinhados à LGPD e ao CDC. `data/db/agreement.json` ainda traz o
  texto herdado ("operates under U.S. law") — **trocar por jurisdição brasileira**
  e, ao publicar, bump `NetworkCommons.AgreementTosVersion/AgreementPrivacyVersion`
  (isso força re-aceite dos ativos). As versões ficam gravadas por conta
  (`account.consent_*`).
- **Classificação indicativa (CLASSIND/ERB)** para o país-alvo antes de monetizar
  público menor.

## 2. Pagamentos (onboarding de gateway) — **provedor: Mercado Pago**
- Abrir conta **Mercado Pago** como PJ e criar a aplicação/integração de checkout.
  Configurar o endpoint de **webhook (v2)** apontando para o companion
  (`/webhooks/payments`), gerar a **credencial/secret** do webhook e setar
  `SHAMBLETA_WEBHOOK_PROVIDER=mercadopago` + `SHAMBLETA_MP_WEBHOOK_SECRET=<secret>`
  + `SHAMBLETA_MP_ACCESS_TOKEN=<access_token>` (o companion é fail-closed sem o
  secret). Com o access_token, ele **re-busca o pagamento** na API do MP e só
  concede com `status=approved` — não confia no corpo.
- **Contrato do checkout**: criar a preferência/payment com
  `external_reference = "<account_id>:<sku>"` (o companion faz o parse disso no
  pagamento re-buscado). Manter `SHAMBLETA_CATALOG_FILE` com o **mesmo** preço
  anunciado = cobrado; o amount concedido vem do catálogo, nunca do corpo.
- **Catálogo real**: publicado em `companion/catalog.json` (gems/vip/starter/founder,
  Pix + cartão) — usar via `SHAMBLETA_CATALOG_FILE`. O `DEFAULT_CATALOG` embutido
  espelha o arquivo (fallback sandbox).
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
- **Rewarded ads (Fase E, abstração + stubs)**: `AdProvider` (token stub que o
  servidor valida por formato + dia; SDK real pluga sem mudar RPCs), 4
  placements opt-in (2×/4× no claim AFK, baú 1/dia, reroll grátis dividido
  com o pago, chave 2/dia), teto global 6/dia, VIP dobra quantidade, janelas
  AFK/Chests/Shop/Boss com botões. **SDK de portal ou ad network = follow-up
  de integração** (válvula fail-closed: formato errado nunca credita).
- **Reembolso do dinheiro**: `RequestGemRefund` reverte as gems + marca
  `grant_queue.status='refunded'`; o companion faz a varredura com
  `server.py refund-sweep` (exige `SHAMBLETA_MP_REFUNDS=1` + access token;
  `--dry-run` p/ auditar). **Pendente: conta MP PJ** (handoff §2).

## 3. Operação
- **Backups offsite testados**: `SHAMBLETA_OFFSITE_BACKUPS` + restore probe já
  existem; apontar para S3/objeto e fazer **restore de verdade** em ambiente
  isolado (provar RPO/RTO).
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
- **Para bater <25 MB**: as alavancas de `WEB_SLIM.md` (re-compressão de
  texturas, pack de áudio remoto) exigem QA visual.

## 5. Git
Há commits locais ainda **não enviados** ao remoto (`SOM-IDLE: …`). Fazer
`git push` quando o fluxo de branch/revisão estiver definido (nunca foi
autorizado nesta esteira).
