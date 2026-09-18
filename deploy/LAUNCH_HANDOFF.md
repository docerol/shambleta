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
  `fraud_flag` kind `multi_account` (revisão manual, sem ban automático) a
  partir da heurística de `Peers.FinalizeLogin` (não-bloqueante); `FEATURE_MATRIX
  §6` corrigida (estava "Planejado", o certo era "Implementado (parcial)").
  **Decisão do dono (2026-09-18): fica só como sinal** (item 13-residual encerrado).
- **Correções de lançamento encontradas no caminho** (HEAD não bootava neste
  toolchain Godot estrito; todas cobertas pela suíte verde): `Peers.gd` sem
  `try/except` (GDScript não tem exceções — guards explícitos), `Map.gd`
  `GetMapBoundaries` restaurado, `Stats.Init` restaurando `actor = actorNode`
  (sem isso TODO XP/gold/essência online era no-op!), `FarmZoneData`
  revertido aos nomes reais do MapsDB (o rebrand 1021878 quebrava as 24 zonas),
  roleta de drops com spread via `hash` (o passo multiplicativo deixava 28/57
  itens inalcançáveis com pesos não-uniformes), `Settings/Shop/WebPush/
  Monitoring/DeviceFingerprint/Checkout` parse-safe, chave `Agreements Update`
  restaurada no `ui.csv`, timeout do job `idle-tests` 300→1200s.
- **T7** seasons verificada (não era gap de código): snapshots das 4 corridas +
  boards + premiação automática + `TickSeasonLifecycle` existem e passam
  (`SuiteSeasonRaces`/`SuiteSeasonPayout`); `SEASONS_GAP.md` e `FEATURE_MATRIX
  §5` corrigidos. **Decisão do dono (2026-09-18): pós-lançamento** — ativar a
  1ª temporada depois, com regras congeladas + changelog público (sem código).

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
  **Status técnico (T1 entregue)**: o companion já cria a preferência sozinho
  (`POST /checkout/preference` — só falta setar `SHAMBLETA_MP_ACCESS_TOKEN` +
  `SHAMBLETA_MP_BACK_URLS_BASE=<url-pública-do-jogo>`); o client já abre a
  `payment_url` e o grant já entra pelo webhook sem intervenção. Falta só o
  lado conta/credenciais abaixo.
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
- **Rewarded ads (Fase E, integração técnica entregue — T3)**: `AdProvider`
  com provider trocável (`SHAMBLETA_AD_PROVIDER=stub|portal`), 4 placements
  opt-in migrados p/ `ShowRewarded` async (token só após conclusão real no modo
  portal), teto global 6/dia, VIP dobra quantidade, contrato JS + modo de teste
  em `deploy/web/ads_bridge.js`. **Decisão do dono (2026-09-18): CrazyGames** —
  falta criar a conta no portal e trocar o corpo do `ads_bridge.js` pelo SDK
  real (só `ads_bridge.js` + env, sem mudar jogo). (Válvula fail-closed intacta:
  formato errado nunca credita.)
- **Reembolso do dinheiro**: `RequestGemRefund` reverte as gems + marca
  `grant_queue.status='refunded'`; o companion faz a varredura com
  `server.py refund-sweep` (exige `SHAMBLETA_MP_REFUNDS=1` + access token;
  `--dry-run` p/ auditar). **Pendente: conta MP PJ** (handoff §2).

## 3. Operação
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
- **Para bater <25 MB**: as alavancas de `WEB_SLIM.md` (re-compressão de
  texturas, pack de áudio remoto) exigem QA visual.

## 5. Git + CI (T4 parcial)
Há commits locais ainda **não enviados** ao remoto (`SOM-IDLE: …`). Fazer
`git push` quando o fluxo de branch/revisão estiver definido (nunca foi
autorizado nesta esteira).
**CI**: workflows verificados no repo (`godot-ci.yml` com idle-tests,
backup-restore, benchmarks e export Web com aviso de peso >25 MB;
`staging.yml` p/ `develop`). Timeout do `idle-tests` ajustado p/ 1200s
(a suíte com sims reais não cabe em 300s). **Pendente (dono, só com acesso
ao GitHub)**: confirmar em Settings → Actions que as execuções aparecem
p/ os commits recentes e que o job Web emite o aviso de peso corretamente.
