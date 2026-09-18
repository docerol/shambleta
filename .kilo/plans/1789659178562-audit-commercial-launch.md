# Plano de Auditoria e Gaps — Shambleta (Commercial Launch Ready)

**Data:** 2026-09-17
**Escopo:** Auditoria completa do projeto Shambleta para lançamento comercial, incluindo performance, funcionamento, segurança, UI/UX e documentação.
**Base:** Código atual (commit `7472e54c` + commits subsequentes), docs existentes em `som-idle-docs/`, e auditoria anterior de 15/09/2026.

---

## 1. Resumo Executivo

Shambleta é um projeto tecnicamente sólido para um jogo open-source comunitário. A fundação arquitetural é boa (server-authoritative, migrations versionadas, auth com KDF, CI/CD multiplataforma). No entanto, **o projeto NÃO está pronto para lançamento comercial** sem trabalho adicional em áreas específicas.

A auditoria anterior de 15/09/2026 já identificou e resolveu vários gaps. Este plano complementa com:
- Gaps **novos** ou **não cobertos** pela auditoria anterior
- Avaliação de **performance** e **funcionamento**
- Revisão de **UI/UX** para o modelo idle
- Ações concretas de **atualização de documentação**
- **Melhorias sugeridas** priorizadas

---

## 2. Gaps Críticos para Lançamento Comercial

### 2.1 Segurança (Crítica)

| # | Gap | Severidade | Ação |
|---|-----|------------|------|
| S1 | `assert()` usado para validação de produção (Godot remove asserts em release) | Alta | Substituir asserts críticos por `push_error()` + `return` seguro. Foco em `SQL.gd`, `World*.gd`, `DB.gd` |
| S2 | SQL com concatenação em queries internas (não bindings) | Média | Padronizar `QueryBindings()` em 100% das queries que usam dados externos |
| S3 | TLS opcional no servidor (depende de provisionamento externo) | Alta | Documentar processo de provisioning de certs + hard-stop se `user://server.crt` não existir em produção |
| S4 | Sem 2FA para contas admin/GM | Média | Adicionar TOTP opcional para contas `permission >= MODERATOR` |
| S5 | Sem detecção de multi-conta (anti-abuso) | Média | Telemetria + heurística IP/device fingerprint no companion |
| S6 | Auth token vinculado a IP (derruba usuários de rede móvel) | Baixa | Reavaliar: remover vinculação IP ou adicionar fallback de re-auth |

### 2.2 Performance (Alta)

| # | Gap | Severidade | Ação |
|---|-----|------------|------|
| P1 | Web build ~32MB gzip (meta <25MB) | Alta | Implementar streaming de música (`data/music/`) via PWA cache ao invés de embed no `.pck` |
| P2 | Sem testes de performance/regressão no CI | Média | Adicionar benchmark de `IdleTests` (settle, XP walk, zone catalog) como gate de CI |
| P3 | Max 128 players por servidor (hardcoded) | Média | Documentar limite + planejar sharding por zona para >128 CCU |
| P4 | Sem profiling de memória/CPU em produção | Média | Integrar Godot profiler + Sentry performance spans |

### 2.3 Funcionamento (Alta)

| # | Gap | Severidade | Ação |
|---|-----|------------|------|
| F1 | Features "implementadas mas desligadas" (shop, VIP, chests) | Alta | Documentar estado de cada feature (ligado/desligado/pendente) em `som-idle-docs/FEATURE_MATRIX.md` |
| F2 | Sem tela de checkout/billing no cliente | Alta | Implementar UI básica de checkout (web-only) + integrar com companion |
| F3 | Sem push notifications (lembrete de retorno) | Alta | Avaliar web push API para browser + e-mail transactional |
| F4 | Backup offsite não testado | Alta | Executar restore probe mensal + automatizar no CI |
| F5 | Sem ambiente de staging | Média | Provisionar staging no Coolify + pipeline de deploy separado |

### 2.4 UI/UX (Média)

| # | Gap | Severidade | Ação |
|---|-----|------------|------|
| U1 | UI herdada do MMO completo, não otimizada para idle | Média | Redesenhar HUD idle: minimizar janelas, destacar AFK report, simplificar inventário |
| U2 | Sem onboarding/tutorial para novo jogador | Média | Adicionar fluxo de first-login guiado (tutorial interativo) |
| U3 | Touch controls existem mas não validadas para loop idle | Baixa | Testar em dispositivo real + ajustar posicionamento de botões virtuais |
| U4 | Sem feedback visual de progresso offline | Baixa | Animação de "coleta de AFK" + som de notificação |
| U5 | Settings muito extenso para mobile | Baixa | Criar perfil "mobile" com configurações padrão + menos opções |

---

## 3. Performance e Funcionamento — Detalhamento

### 3.1 Pontos Fortes
- Server-authoritative de verdade (cliente nunca envia estado)
- Migrations versionadas + template de DB
- Rate-limiting por RPC + protocol handshake
- Sentry com opt-out de privacidade
- CI multiplataforma funcional
- Testes de idle (XP curve, settle, ledger) rodando no CI

### 3.2 Pontos Fracos
- **Web build pesado:** 32MB gzip (meta 25MB). Principal culpado: `data/music/` embutido no `.pck`
- **Sem performance tests no CI:** os `IdleTests` existem mas não medem tempo de forma estruturada
- **SQLite WAL:** funciona para single-node, mas não há métricas de contention
- **Max 128 players:** pode ser suficiente para beta fechado, mas não para launch comercial sem sharding
- **Sem cache de assets no cliente web:** primeiro load baixa tudo, sem service worker para cache progressivo

### 3.3 Funcionamento
- **O jogo funciona:** login, create char, farm idle, combat, settle offline — tudo testado
- **Rede:** ENet/WebSocket/WebRTC funcionais, mas WebRTC sem TURN (pode falhar em NATs restritivos)
- **Economia:** ledger, gems, rebirth, boss keys, chests — implementados e testados
- **Pagamentos:** companion funciona em sandbox, mas sem checkout UI no cliente

---

## 4. Segurança — Detalhamento

### 4.1 Pontos Fortes
- KDF com 12000 iterações SHA-256 (Hasher.gd)
- Salt CSPRNG via `Crypto.generate_random_bytes()`
- Lockout exponencial (5 tentativas → 300s a 7200s)
- Token de sessão com expiry 30 dias
- Reset de senha com código de 6 dígitos + cooldown 5min
- LGPD: consentimento versionado, direito ao esquecimento, reembolso CDC
- Anti-enumeração em login (resposta genérica)
- Bans por conta + IP

### 4.2 Pontos Fracos
- **Asserts como validação:** `assert()` não roda em release builds do Godot → caminhos de erro silenciosos
- **SQL por concatenação:** algumas queries internas ainda usam string formatting
- **TLS opcional:** se cert não existe, servidor sobe sem criptografia
- **Sem 2FA:** admin/GM sem segundo fator
- **Sem multi-conta detection:** heurísticas básicas de IP/device ausentes
- **WebRTC sem TURN:** apenas STUN público do Google

---

## 5. UI/UX — Detalhamento

### 5.1 Pontos Fortes
- Suporte a touch implementado (joystick virtual, TouchScreenButton)
- Rebind de controles completo
- Múltiplas janelas flutuantes (inventário, skills, chat, etc.)
- Temas visuais (CRT, HQ4x)
- Sistema de highlights e tutoriais UI

### 5.2 Pontos Fracos
- **UI herdada do MMO:** muitas janelas, muitos botões — não é idle-first
- **Sem onboarding:** jogador novo cai no mundo sem orientação
- **AFK report não intuitivo:**界面 não destaca claramente o progresso offline
- **Settings overwhelming:** muitas opções para um jogo idle
- **Touch não otimizado:** botões virtuais podem estar mal posicionados para gameplay idle

---

## 6. Documentação — Estado Atual

### 6.1 Existente (bom)
- `som-idle-docs/ARCHITECTURE.md` — arquitetura completa
- `som-idle-docs/ECONOMY_STUdy.md` — economia detalhada
- `som-idle-docs/TECH_SPEC_CORE.md` — contratos técnicos
- `som-idle-docs/ROADMAP.md` — roadmap com fases
- `som-idle-docs/MONETIZATION.md` — design de monetização
- `docs/adding-a-quest.md` — guia de criação de quests
- `CONTRIBUTING.md` — guia de contribuição

### 6.2 Ausente ou Desatualizado
- `README.md` não reflete o pivô idle (fala de "MMORPG" genérico)
- Sem documentação de API/RPCs
- Sem guia de deploy para desenvolvedores
- Sem documentação de testes (como rodar, como escrever)
- Sem documentação de UI/UX (design tokens, padrões de janela)
- `som-idle-docs/` tem relatórios de fase mas falta índice atualizado

---

## 7. Plano de Ação Priorizado

### Fase 1 — Critical Path (2–3 semanas)
**Objetivo:** Fechar gaps que bloqueiam launch comercial

1. **S1:** Substituir `assert()` por validação de produção em `SQL.gd`, `World*.gd`, `DB.gd`
2. **S2:** Padronizar `QueryBindings()` em todas as queries com dados externos
3. **S3:** Documentar + automatizar provisioning de TLS (script + CI gate)
4. **P1:** Reduzir web build para <25MB (streaming de música)
5. **F1:** Criar `FEATURE_MATRIX.md` documentando estado de cada feature
6. **F4:** Automatizar restore probe de backup no CI

### Fase 2 — Polish (2–3 semanas)
**Objetivo:** Melhorar UX e preparar para beta aberto

7. **U1:** Simplificar HUD idle (minimizar janelas, destacar AFK)
8. **U2:** Adicionar onboarding de first-login
9. **F2:** Implementar checkout UI básico (web-only)
10. **F3:** Avaliar e implementar web push notifications
11. **P2:** Adicionar benchmarks de performance no CI
12. **S4:** Adicionar 2FA para admin/GM

### Fase 3 — Scale Ready (3–4 semanas)
**Objetivo:** Preparar para escala comercial

13. **P3:** Documentar limite de 128 players + planejar sharding
14. **P4:** Integrar Godot profiler + Sentry performance
15. **F5:** Provisionar ambiente de staging
16. **S5:** Implementar detecção de multi-conta
17. **Atualizar documentação:** README, API docs, deploy guide

---

## 8. Melhorias Sugeridas

### Código
1. **Remover asserts de produção:** criar `Util.AssertProduction()` que usa `push_error()` + `return`
2. **Adicionar property caching no GUI:** reduzir `GetVal()` calls em `Settings.gd`
3. **Implementar service worker para web:** cache de assets + offline fallback
4. **Adicionar retry logic em network RPCs:** reconnect automático com backoff
5. **Separar economia em microserviço:** companion atual (Python) → Go/Node para escala

### UX
1. **Modo "Idle Only":** esconder todas as janelas exceto AFK report + chat
2. **Quick actions:** botão de "Claim All" + "Open All Chests"
3. **Tutorial interativo:** primeiro login com passo-a-passo guiado
4. **Notificações sonoras:** som distinto para level up, chest, boss pronto
5. **Estatísticas visuais:** gráfico de XP/hora, gold/hora no AFK report

### Performance
1. **Asset streaming:** carregar mapas/sprites sob demanda (não tudo no startup)
2. **LOD para entities:** simplificar sprites quando muitos mobs na tela
3. **Batch RPCs:** agrupar updates de entidades em bulk (já existe, mas pode ser otimizado)
4. **Compressão de rede:** usar delta compression para posições de entidades

---

## 9. Documentação a Atualizar

| Arquivo | Ação |
|---------|------|
| `README.md` | Re-escrever para refletir pivô idle + comercial |
| `som-idle-docs/README.md` | Atualizar índice com novos docs |
| `som-idle-docs/FEATURE_MATRIX.md` | **Criar** — estado de cada feature |
| `docs/` | Adicionar guia de deploy + API reference |
| `CONTRIBUTING.md` | Adicionar seção de idle-first design |
| `deploy/COOLIFY.md` | Atualizar com processo de TLS provisioning |

---

## 10. Validação

- [ ] Todos os `assert()` críticos substituídos por validação de produção
- [ ] Web build <25MB gzip
- [ ] Checkout UI funcional (web-only)
- [ ] Onboarding de first-login implementado
- [ ] Restore probe de backup automatizado no CI
- [ ] FEATURE_MATRIX.md criado e atualizado
- [ ] README.md reflete realidade do projeto

---

## 11. Riscos e Mitigações

| Risco | Mitigação |
|-------|-----------|
| S1 (asserts) quebrar release | Testar em export release + Godot headless |
| P1 (web weight) não atingir meta | Fallback: PWA com cache progressive + lazy load |
| U1 (UI idle) ser rejeitado por players | A/B test com HUD clássico vs simplificado |
| F2 (checkout) atrasar launch | Usar companion sandbox como MVP; UI real depois |
| S3 (TLS) falhar em produção | Script de provisioning + CI gate + alerta Sentry |

---

## 12. Decisões Pendentes (para o usuário)

1. **Rebranding:** Manter marca "Shambleta" ou rebranding completo? (afeta legal/compliance)
2. **Mobile IAP:** Usar Google Play Billing / StoreKit ou apenas web? (afita F2)
3. **Push notifications:** Web push apenas ou também e-mail? (afita F3)
4. **Sharding:** Escolher sharding por zona ou por população? (afita P3)
5. **2FA:** Obrigatório para admin ou opcional? (afita S4)
