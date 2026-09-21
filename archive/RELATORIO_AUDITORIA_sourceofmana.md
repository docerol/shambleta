# Relatório de Auditoria — Fork `docerol/sourceofmana`

**Data:** 09/09/2026
**Commit auditado:** `48029cc` (idêntico ao upstream `sourceofmana/sourceofmana@master` no momento da análise — o fork está 100% sincronizado, sem commits próprios)
**Escopo:** prontidão para lançamento comercial + existência de sistema de moedas premium
**Método:** análise estática do código-fonte (23.370 linhas de GDScript em `sources/`, 231 arquivos), schema do banco (`data/conf/migrations/`, `data/conf/templates/sqlite.template.db`), pipelines de CI (`/.github/workflows/`), licenças (`LICENSE.md`, `CC BY-SA 4.0`) e dados de conteúdo (`presets/`, `data/maps/`).

---

## 1. Sumário Executivo

| Dimensão | Veredito |
|---|---|
| **O jogo está pronto para lançamento comercial?** | **Não.** Há fundação técnica sólida, mas faltam camadas inteiras exigidas por um serviço comercial: pagamentos, conta/e-mail verificado, hardening de segurança, operação de servidor e compliance. |
| **Já existe sistema de moedas premium?** | **Não.** Não existe nenhum traço de cash shop, moeda premium, loja, ledger de transações ou integração de pagamento no código. A única moeda é o **GP** (gold do jogo, coluna `stat.gp`). |
| **É viável implementar moedas premium neste código?** | **Sim**, com esforço moderado — o projeto já tem os ganchos certos (stats autoritativos no servidor, persistência SQL, rate-limiting por RPC, comandos com permissão). O ponto mais sensível não é técnico: é **licenciamento e conformidade de pagamentos**. |
| **Maior risco geral** | **Jurídico**, não técnico: arte 100% CC BY-SA 4.0 (obrigações de atribuição/share-alike), marca "Mana" ligada a projetos comunitários preexistentes (The Mana World / Manasource) e regulamentação de monetização (IAP obrigatório em lojas de apps, LGPD/GDPR, menores de idade). |

**Pontuação de prontidão (0–10):** Técnica 7 · Segurança 5 · Operações 4 · Monetização 0 · Legal/compliance 2 · **Média: ~3,5/10 para lançamento comercial** (vs. ~8/10 para lançamento *comunitário* gratuito, que o projeto já suporta).

---

## 2. O que o projeto é (contexto técnico)

MMORPG 2D em **Godot 4.7**, originado por veteranos de *The Mana World* (Manasource). Um único projeto gera três alvos: **client**, **server** e **launcher** (`sources/launcher/Launcher.gd`). Pontos relevantes mapeados:

- **Rede:** ENet (UDP), WebSocket e WebRTC (para web), com upgrade dinâmico ENet→WebRTC (`sources/network/Network.gd`, `sources/network/server/Server.gd`). Handshake de protocolo via hash da config RPC (`NetworkCommons.ComputeProtocolVersion`).
- **Arquitetura de confiança:** correta para MMO — o cliente envia *intenções* (`TriggerSkill`, `SetMovePos`, `UseItem`…) e o servidor valida e executa (`sources/network/server/Server.gd`). Estado nunca é aceito do cliente.
- **Persistência:** SQLite (`addons/godot-sqlite`), template em `data/conf/templates/sqlite.template.db`, migrações versionadas `001–008` em `data/conf/migrations/`. Tabelas: `account`, `character`, `stat`, `trait`, `attribute`, `item`, `equipment`, `skill`, `quest`, `bestiary`, `ban`, `ip_ban`, `auth_token`, `migration`.
- **Auth:** conta/senha + token "manter conectado" (30 dias, hash SHA-256, vinculado ao IP), reset de senha por e-mail via Brevo (`sources/network/server/EmailService.gd`), sistema de ban por conta e faixa de IP.
- **Moderação:** comandos `/kick`, `/ban`, `/ipban`, `/permission` etc. com níveis NONE→MODERATOR→GM→ADMIN (`sources/world/WorldCommands.gd`, `sources/debug/CommandManager.gd`).
- **Economia atual:** GP em `stat.gp`, drop/quest via NPCs (`NpcCommons.AddItem`), um NPC com custo fixo em GP (`sources/scripts/tonori/desertpit/Pachua.gd`, `COST_GP = 10000`) e trocas de quest (`Eridu.gd`). **Não há NPC vendedor genérico, player-to-player trading, leilão ou loja.**
- **CI/CD:** export Linux/Windows/macOS/Android + servidor headless (`godot-ci.yml`), release por workflow manual (`release.yml`), Snap package. **Sem iOS e sem build Web no CI**, embora `export_presets.cfg` contenha presets de iOS.
- **Observabilidade:** Sentry opcional com opt-out de privacidade do usuário (`sources/system/Monitoring.gd`); backups automáticos diários/semanais do SQLite (`sources/sql/SQLBackups.gd`).
- **Conteúdo:** 40 mapas TMX, 17 quests, 84 scripts de NPC/diálogo — mundo pequeno, mas coeso e jogável.

---

## 3. Moedas Premium — Resposta Direta e Impacto de Licença

### 3.1 Estado atual (evidências)

- Busca por `premium|cash|shop|store|coin|currency|payment|monetiz` em todo o repositório: **zero ocorrências no código do jogo** (apenas no addon Discord, não relacionado).
- `presets/privacy/collected_data/payment_info/collected=false` em `export_presets.cfg` — coerente: nada coleta pagamento.
- Nenhuma tabela SQL de transações/ledger; nenhuma RPC de compra; nenhuma UI de loja.

### 3.2 O que um sistema premium precisaria tocar (quando implementado)

1. **Ledger servidor-only:** tabela nova `premium_wallet(account_id, balance, updated_at)` + `premium_transaction(id, account_id, char_id, type[grant|spend|refund|adjust], amount, balance_after, ref, created_at)` — *append-only* (nunca UPDATE em saldo sem linha de transação; é o que permite auditoria, suporte e defesa em chargeback).
2. **Moeda em `ActorStats`** (`sources/actor/Stats.gd`): campo `premium` (ou dicionário de moedas), replicado pelo padrão existente `UpdatePrivateStats` (`Network.gd:340`, `Client.gd:207`, `PlayerAgent.gd:99-127`).
3. **Persistência:** migração `009_add_premium_wallet.sql` (o mecanismo de migrations já existe e é sólido).
4. **Loja:** janela GUI no padrão `WindowPanel` (ex.: `presets/gui/Emote.tscn` como molde) + catálogo data-driven (o padrão `.tres` de `presets/cells/items/` já dá o modelo; catálogo de ofertas pode ser JSON como `data/db/entities.json`).
5. **Comandos admin:** `/grantpremium <player> <amount>` via `WorldCommands.gd` (padrão do comando `gp`), para suporte/correção manual.
6. **Serviço de pagamentos:** aqui está a mudança estrutural — o servidor de jogo atual **não** deve receber webhooks diretos de gateway. Recomenda-se um microserviço companion (REST) que grava no mesmo banco (ou replica grants), porque o processo Godot é um game server, não um serviço web exposto.

### 3.3 ⚠️ O ponto crítico antes de monetizar

**Leia o LICENSE.md antes de vender qualquer coisa.**

- **Código = MIT** → você pode fechar/comercializar modificações de código livremente. ✅
- **Arte = CC BY-SA 4.0** (lista item por item no LICENSE.md + `data/db/credits.json`) → uso comercial é **permitido**, mas você **deve** (a) creditar os autores com link para `https://github.com/sourceofmana`, e (b) **ShareAlike**: se você *modificar/remixar* as obras CC BY-SA, a versão modificada precisa continuar CC BY-SA. Conteúdo novo seu pode ser proprietário (não é derivado), mas a linha é fina em assets de jogo — prefira manter os assets derivados sob CC BY-SA.
- **Marca ("Mana", "Source of Mana", logos)** → não é licenciada pelo MIT. O projeto pertence à comunidade Manasource/TMW. Um fork **comercial** precisa de: (a) acordo explícito com o upstream/manasource.org (e-mail no LICENSE.md: `som@manasource.org`) para uso da marca, ou (b) **rebranding completo** do seu fork. Recomendo o (b) ou uma conversa formal com o upstream antes de qualquer cobrança.
- **Lojas de aplicativos:** moeda premium comprada com dinheiro real em **iOS/Android exige IAP nativo** (30%/15% da plataforma) — Stripe/PayPal direto é proibido para bens digitais nesses canais. No PC/web, gateway direto é permitido. Isso deve moldar o design de pagamentos desde o dia 1 (abstração de "provedor de pagamento").

---

## 4. Gaps para Lançamento Comercial (por área, com severidade)

### A. Jurídico & Compliance — severidade **CRÍTICA** (bloqueante)

| # | Gap | Evidência | Mitigação |
|---|---|---|---|
| A1 | Sem ToS/EULA dedicado ao serviço comercial; `data/db/agreement.json` é um código de conduta de comunidade, não termos de venda | `data/db/agreement.json` | Redigir Terms of Service, EULA, Política de Reembolso (exigidos por Steam/lojas e por processadoras) |
| A2 | Marca/logo "Mana" sem direito de uso comercial definido | LICENSE.md §contact | Acordo com upstream ou rebranding |
| A3 | Obrigações CC BY-SA (atribuição + share-alike) não documentadas para contexto comercial | LICENSE.md linhas 42–48 + créditos | Manter credits.json, adicionar página de créditos no jogo/launcher |
| A4 | LGPD/GDPR: coleta de e-mail + IP + Sentry, sem política de privacidade, sem base legal/consentimento documentado, sem processo de exclusão de dados | `EmailService.gd`, `Monitoring.gd`, export_presets (declarações de privacidade iOS zeradas) | Política de privacidade, consentimento no cadastro, DPA com Sentry/Brevo, rota de deleção de conta (LGPD art. 18) |
| A5 | Menores de idade: jogo F2P com monetização exige fluxos de consentimento parental em várias jurisdições | — | Avaliação etária (CLASSIND no BR), gate de idade no cadastro |
| A6 | Dados de pagamento **nunca** devem tocar o game server — arquitetura atual não tem onde isolá-los | Seção 3.2 | Gateway tokenizado (Stripe/PayPal/xadrez: nunca armazenar PAN) |

### B. Monetização & Pagamentos — severidade **CRÍTICA** (não existe nada)

- B1: nenhuma moeda premium, loja, catálogo, ledger ou RPC de compra (Seção 3).
- B2: nenhum serviço REST/companion para webhooks de pagamento (o game server não deve expor isso).
- B3: sem IAP mobile (plugin Godot para Google Play Billing / StoreKit).
- B4: sem suporte a reembolso/chargeback/estorno (fluxo + reversão de itens).
- B5: sem antifraude mínimo (velocity check por conta/IP, flags de estorno → ban).
- B6: economia do jogo ainda não tem pia nem torneira maduras (sem vendors NPCs, sem trading P2P) — a introdução de loja premium requer *game design* de economia antes, senão o GP fica sem valor e a loja Premium desequilibra tudo.

### C. Segurança — severidade **ALTA**

| # | Gap | Evidência | Impacto |
|---|---|---|---|
| C1 | Senhas com **SHA-256 + salt de PRNG não-criptográfico** — sem KDF (bcrypt/scrypt/argon2); `RandomNumberGenerator` para salt e códigos de reset | `sources/util/Hasher.gd:10-21` | Se o DB vazar, quebra de senhas é trivial; códigos de reset 6 dígitos previsíveis. Comercial = obrigatório migrar para KDF (Godot não tem bcrypt nativo — usar Crypto `hmac_digest` + iterações, ou mover auth para o serviço companion) |
| C2 | SQL por concatenação de string nas queries internas (`Query("... %d")`, critérios de `update_rows`) | `sources/sql/SQL.gd:11-22, 426-489` | Risco real baixo hoje (valores internos; inputs de usuário usam `QueryBindings`), mas é dívida: um deslize futuro vira injeção. Padronizar bindings em 100% |
| C3 | Sem transações ACID explícitas: `AddItem`/`RemoveItem` e futuras compras são queries separadas sob mutex | `sources/sql/SQL.gd:255-280` | Crash no meio = item duplicado/sumido. Em moeda premium isso vira perda financeira; envolver compra em `BEGIN/COMMIT` |
| C4 | Reset de senha: e-mail **opcional e não validado** no cadastro (`CheckEmailInformation` existe mas não é chamado em `CreateAccount`) | `Server.gd:5-22`, `NetworkCommons.gd:205` | Contas irrecuperáveis; e-mail inválido polui base; sem unicidade de e-mail (impede 1 conta por e-mail, comum em pagamentos) |
| C5 | Rate-limiting por RPC (Footprint, 1s para login) é o único controle anti-bruteforce; sem lockout, sem CAPTCHA, sem análise | `Peers.gd:99-111`, `NetworkCommons.gd:54` | Credential stuffing viável; criação massiva de contas por bot |
| C6 | Auth token vinculado ao IP (`ValidateAuthToken` exige mesmo IP) | `SQL.gd:381-391` | Segurança ok, mas derruba usuários de rede móvel; decisão de produto |
| C7 | TLS **opcional**: se `user://server.crt` não existir, ENet sobe sem DTLS e WebSocket sem WSS | `Server.gd:512-529` | Em produção, credenciais trafegam em claro; precisa de provisioning de certificado + exigir TLS |
| C8 | WebRTC usa STUN público do Google apenas, sem TURN | `NetworkCommons.gd:93` | Alguns NATs corporativos/carriers falham a conexão; TURN próprio custa dinheiro (operacional) |
| C9 | Comandos admin dependem só de `permission` na conta; sem 2FA, sem auditoria persistente de ações de staff | `WorldCommands.gd`, `CommandManager.gd` | Risco interno/alta de conta GM; adicionar audit log |
| C10 | `assert()` como validação em código de produção (Godot: asserts não rodam em release) | vários, ex. `SQL.gd:62` | Caminhos de erro silenciosos em release |

**Pontos positivos (não-gap):** validação server-side consistente (o cliente não manda estado), checagem de protocol version, bans por conta/IP, rate-limit básico, `CheckTraits/CheckAttributes` na criação de personagem — acima da média de projetos amadores.

### D. Operações & Infraestrutura — severidade **ALTA**

- D1: **SQLite em arquivo único** para MMO comercial: sem acesso concorrente multi-processo, sem replicação, limite prático de writes. OK para centenas de players; bloqueante para milhares. Migração para PostgreSQL no serviço companion é o caminho natural.
- D2: **Servidor = processo único Godot** (128 players max configurados, `MaxPlayerCount`, mundo single-instance com áreas). Sem processos múltiplos/sharding, sem restart sem derrubar todos (netcode não tem handoff de sessão).
- D3: Sem provisionamento de deploy (Docker/systemd, configuração por env), semhealthcheck externo; Sentry cobre erros, não métricas de negócio (CCU, retenção, receita).
- D4: Backups locais no mesmo host (`SQLBackups.gd`) — sem offsite/restore testado.
- D5: CI sem iOS e sem Web (presets existem, workflow não constrói); lojas exigem binários assinados (notarização macOS, keystore Android já previsto via secret).
- D6: Sem ambiente de staging (flags Testing existem — ports 6118/6119 — mas não há pipeline/infra dedicada).

### E. Jogo & Conteúdo — severidade **MÉDIA**

- E1: Mundo pequeno para reter pagantes: 40 mapas, 17 quests, cap de level curto (curva em `sources/util/Experience.gd`).
- E2: Sem loops econômicos: 0 NPCs vendedor, 0 crafting, 0 trading P2P, 0 auction house — GP quase não tem uso (`Pachua.gd` é a exceção isolada). **Pré-requisito de qualquer loja premium.**
- E3: Sem sistema de guild/party/clã, PvP, matchmaking — features de retenção padrão do gênero.
- E4: Anticheat de movimento/timing: como o servidor é autoritativo, o risco é moderado, mas não há detecção de speedhack/teleport (delta checks) nem heurísticas de farm.
- E5: Sem i18n: strings de UI/dialogue hardcoded em inglês; para o mercado BR isso é decisão de produto imediata (Godot tem i18n nativo; é trabalho mecânico, mas extenso).

### F. Produto & Distribuição — severidade **MÉDIA**

- F1: Sem página de produto/store page pronta (itch.io citado nas notícias; Steam exige build_PIPE, preço, requisitos, conquistas…).
- F2: Launcher atual não faz auto-update patchado (redownload completo esperado); para serviço comercial, patcher incremental reduz custo de suporte.
- F3: Sem telemetria de produto (funil de criação de conta, retenção D1/D7/D30) — sem isso, precificação/loja são tiros no escuro.
- F4: Suporte: sem canal de suporte/CS, sem FAQ de cobrança, sem processo de reembolso.

### G. Processos de Engenharia — severidade **BAIXA/MÉDIA**

- G1: Zero testes automatizados (nenhum arquivo de teste no repo; `LauncherCommons.IsTesting` sugere modo testing, mas não há suite). Ponto de partida barato: testes de integração das migrações SQL + validações de auth (Godot roda headless no CI).
- G2: Sem lint/format check de GDScript no CI (`gdscript/warnings/treat_warnings_as_errors=true` no project.godot ajuda em editor, não no CI).
- G3: CONTRIBUTING.md bom, mas sem SECURITY.md e sem processo de release versionado (releases são manuais e sem tags semânticas).

---

## 5. O que já está bem feito (para ser justo)

1. **Arquitetura client/server no mesmo codebase** com strip de recursos por lado (`DB.StripUnused`) — profissional e incomum em projetos desse porte.
2. **Server-authoritative de verdade**: todas as ações passam por handlers validados; o cliente nunca envia estado.
3. **Migrations versionadas + template de DB + backups automáticos** — base rara em projetos Godot.
4. **Rate-limiting por método RPC + protocolo com handshake** — anti-abuse básico já presente.
5. **Moderação completa** (ban conta/IP, permissões, kick, broadcast) e **reset de senha por e-mail com anti-enumeration** (resposta genérica).
6. **CI de export multiplataforma** + Snap + release workflow.
7. **Licenciamento documentado arquivo a arquivo** (LICENSE.md + credits.json) — o upstream leva atribuição a sério, o que ajuda você a cumpri-la.

---

## 6. Roadmap Recomendado

### Fase 0 — Decisões (antes de qualquer código) · 2–4 semanas
1. Definir relacionamento com o upstream (usar marca? contribuir de volta?) **ou** planejar rebranding.
2. Definir modelo de negócio (B2P? F2P + cosméticos? subscription?) — isso muda o design da moeda.
3. Estrutura legal (empresa, LGPD, termos) e escolha de gateway + política IAP mobile.

### Fase 1 — Fundação comercial (sem vender nada ainda) · 1–2 meses
- Auth: KDF para senhas, e-mail obrigatório + verificado + único, lockout/2FA opcional. *(Idealmente mover auth para serviço companion)*
- Serviço companion (Go/Node + PostgreSQL) com: REST de conta, webhooks de pagamento (modo sandbox), ledger de moeda premium **sem** loja pública ainda.
- `BEGIN/COMMIT` nas operações econômicas; padronizar SQL com bindings.
- TLS obrigatório + provisioning de certificado; staging environment; backups offsite com restore testado.
- Testes automatizados de migração/auth/economia no CI.

### Fase 2 — Moedas premium + loja · 1–2 meses (paralelo à Fase 1 do companion)
- `premium_wallet` + `premium_transaction` (append-only), RPC de saldo/compra server-side, UI de loja (WindowPanel), catálogo data-driven, comandos `/grantpremium` e reversões.
- **Comece 100% cosmético** (vestes, cores, emotes, títulos): evita pay-to-win e reduz risco de rebalance.
- IAP mobile via plugin nativo (Google Billing/StoreKit) como segundo provedor.

### Fase 3 — Conteúdo e retenção · contínuo
- Vendors NPCs, trading P2P, guild/party, +10 quests, i18n pt-BR/en, patcher incremental, telemetria de produto.

**Esforço estimado total até um "lançamento comercial mínimo" (F0–F2): 3–5 meses de 1–2 engenheiros + suporte jurídico/design.** A parte de moedas premium em si (código no jogo) é a menor fatia: ~2–4 semanas. O grosso é a camada de pagamentos/operação que não existe.

---

## 7. Conclusão

- **Há gaps para lançamento comercial? Sim, e são estruturais** — não por má qualidade do código (a fundação técnica é boa), mas porque um jogo gratuito open-source e um serviço comercial são produtos diferentes: pagamentos, privacidade, segurança de credenciais, operação 24/7 e questões de marca/licença simplesmente não existem ainda no repositório.
- **Moedas premium: não existem hoje** — implementar é viável e o código dá bons pontos de encaixe (stats autoritativos, migrations, RPC com rate-limit, janelas GUI padronizadas), **mas** o prerequisite crítico é o serviço de pagamentos externo + as decisões de licença/marca da Seção 3.3.
- **Recomendação:** não monetize sobre o estado atual. Execute a Fase 0 (decisões legais/negócio) e a Fase 1 (fundação) antes de escrever a primeira linha da loja.

---

## Apêndice — Evidências-chave (arquivo:linha)

| Achado | Local |
|---|---|
| Moeda GP única; sem premium | `sources/actor/Stats.gd:7`, coluna `stat.gp` em `data/conf/templates/sqlite.template.db` |
| Sem KDF / PRNG fraco | `sources/util/Hasher.gd:10-29` |
| RPCs de auth (nenhuma de compra) | `sources/network/Network.gd:36-70` |
| Validade server-side das ações | `sources/network/server/Server.gd:237-390` |
| Rate-limit RPC | `sources/network/server/Peers.gd:99-111` |
| SQL por concatenação | `sources/sql/SQL.gd:11-22, 457, 492-498` |
| Sem transação ACID em item | `sources/sql/SQL.gd:255-280` |
| Token 30d vinculado a IP | `sources/sql/SQL.gd:381-391` |
| TLS opcional | `sources/network/server/Server.gd:512-529` |
| E-mail não validado no cadastro | `sources/network/server/Server.gd:5-22` |
| Sem i18n | strings hardcoded em `sources/gui/*.gd` |
| CI sem iOS/Web | `.github/workflows/godot-ci.yml` (matrix Linux/Windows/macOS/Android) |
| Licenças | `LICENSE.md` (MIT + lista CC BY-SA 4.0), `CC BY-SA 4.0`, `data/db/credits.json` |
| Permissões/comandos admin | `sources/actor/ActorCommons.gd:13-19`, `sources/world/WorldCommands.gd` |
