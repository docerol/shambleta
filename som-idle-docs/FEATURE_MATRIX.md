# Feature Matrix — Shambleta Commercial Launch

**Data:** 2026-09-17
**Base:** Código atual (commit `7472e54c` + commits subsequentes)

---

## Legenda

| Status | Descrição |
|--------|-----------|
| **Implementado** | Código no main branch, testado, disponível para jogadores |
| **Parcial** | Funcionalidade existe mas com limitações conhecidas ou em sandbox |
| **Planejado** | Documentado em roadmap, não iniciado |
| **Desligado** | Implementado mas comentado/removido do build atual |
| **Não planejado** | Fora do escopo do produto idle |

---

## 1. Core e Loop Idle

| Feature | Status | Observações |
|---------|--------|-------------|
| Login/criação de conta | Implementado | LGPD, KDF 12000 iterações, lockout exponencial |
| Seleção de personagem | Implementado | 1 slot por conta (multi-slot via formação) |
| Auto-farm idle | Implementado | IdlePolicy com PhysicsProcess pump |
| Offline settle | Implementado | Idempotente, last_settled_at como âncora |
| Progressão XP/level | Implementado | Cap L60, overflow → essência no rebirth |
| Mapa/navegação | Implementado | NavigationServer2D, instâncias por zona |
| Auto-combat | Implementado | FSM IDLE/WALK/ATTACK/HALT |
| Respawn/morte | Implementado | Respawn destination, graveyard |

---

## 2. Economia

| Feature | Status | Observações |
|---------|--------|-------------|
| Gold (GP) | Implementado | Moeda primária, settle offline |
| Gems (premium) | Implementado | Wallet, ledger append-only |
| Itens/inventário | Implementado | Item lot system (UID), FIFO consume |
| Equipamento | Implementado | Slots, stats modifiers |
| Skills | Implementado | XP por skill, levels |
| Ledger/transações | Implementado | Append-only, antifraud heuristics |
| Banco/cofres | Implementado | guild vault, item_instance |

---

## 3. Monetização

| Feature | Status | Observações |
|---------|--------|-------------|
| Shop (gems/chests/VIP) | Parcial | UI existe, checkout sandbox via companion |
| Checkout real (Mercado Pago) | Planejado | Integração documentada, catálogo definido |
| Checkout real (Stripe) | Planejado | Suportado no companion |
| Starter pack (one-time) | Implementado | Limitado a contas <3 dias, grant_queue |
| Rewarded ads (2× AFK) | Parcial | Botões existem, AdProvider stub |
| VIP status | Implementado | Tier 1/2, idle faucet multiplier |
| Season pass | Implementado | Missões diárias/semanais, premium track |

---

## 4. Social

| Feature | Status | Observações |
|---------|--------|-------------|
| Chat global/whisper | Implementado | Comandos /w, /q |
| Guild | Implementado | Create/join/leave/deposit/withdraw/levelup/tag |
| Guild vault | Implementado | Deposito/retirada de itens |
| Auction House | Implementado | List/buy/cancel |
| Trade direto | Implementado | /trade, atomic com fee burn |
| Leaderboard | Implementado | Power score ranking |
| Friend list | Desligado | Não implementado |

---

## 5. Progressão

| Feature | Status | Observações |
|---------|--------|-------------|
| Bestiary | Implementado | Kill tracking por mob |
| Quests | Implementado | State machine, recompensas |
| Boss keys | Implementado | Loot de boss, gasto para bonus |
| Rebirth | Implementado | Reset L1, essência, favores compõem |
| Rebirth upgrades | Implementado | XP/gold/attune offline |
| Season pass | Implementado | Missões, board, premium track |
| Tournament | Implementado | Semanal, inscrição em gold |
| Seasons (snapshot + 4 corridas) | **Gap técnico** | `FEATURE_MATRIX.md` e `ROADMAP.md` (§F4) documentam; código (`GetSeasonBoardsState`) existe mas snapshot/learderboards semanais (Power/Boss/Spend/Guild) não implementados no build atual |

---

## 6. Anti-fraude/Compliance

| Feature | Status | Observações |
|---------|--------|-------------|
| KDF 12000 iterações | Implementado | SHA-256, salt CSPRNG |
| Lockout exponencial | Implementado | 5 tentativas → 300s a 7200s |
| Token de sessão 30d | Implementado | Refresh automático |
| Reset de senha | Implementado | Código 6 dígitos, cooldown 5min |
| LGPD consentimento | Implementado | Version-aware, direito ao esquecimento |
| Anti-enumeração login | Implementado | Resposta genérica |
| Ban por conta+IP | Implementado | IP ban com wildcard |
| Ledger antifraud | Implementado | Trade burst, level jump, RMT heuristics |
| Multi-conta detection | Planejado | Heurísticas IP/device fingerprint |

---

## 7. UI/UX

| Feature | Status | Observações |
|---------|--------|-------------|
| HUD MMO (herdado) | Implementado (polido — essencial) | `ToggleIdleMode()` (`F10`) oculta não-essenciais; `essential` inclui `statWindow`, `chatWindow`, `minimapWindow`, `shopWindow`, `chestsWindow`, `bossWindow`, `seasonPassWindow`, `afkWindow` (≤ 8 janelas) |
| AFK report | Implementado (polido — visual melhorado) | Cores: XP/gold verde (`>0`); eficiência dourado (`≥80%`), amarelo (`≥50%`), vermelho (`<50%`) (`AfkReport.gd`) |
| Settings | Implementado (polido — simplificado mobile/web) | Oculta `CRT`/`HQ4x`/`ActionOverlay` em `isMobile`/`isWeb` (`P-A3`); `WebPushRow` e `LanguageRow` mantidas compactas |
| Touch controls | Implementado (polido — responsivo) | `_adjust_for_mobile_web()` (`font_scale` 1.2x) para `isMobile`/`isWeb`; layout adaptável |
| Rebind de controles | Implementado | Input map completo |
| Temas visuais (CRT/HQ4x) | Implementado | Shader-based |
| Onboarding/tutorial | Implementado | Fluxo básico (6 passos: welcome→shop) em `Onboarding.gd`; highlights parciais; chamado por `Gui.gd` (`sessionfirstlogin`) |
| Notificações push | Implementado | Web-only (`WebPush.gd`, service worker `sw.js`, toggle runtime em `Settings.gd`); requer HTTPS + permissão do usuário |

---

## 8. Plataforma/Deploy

| Feature | Status | Observações |
|---------|--------|-------------|
| Desktop (Windows/Mac/Linux) | Implementado | Export headless server + client |
| Web (Godot Web) | Implementado | PWA, COOP/COEP, SharedArrayBuffer |
| Mobile (Android/iOS) | Parcial | Build funciona, touch não otimizado |
| Docker/Coolify | Implementado | 3-services stack, proxy TLS |
| CI/CD (GitHub Actions) | Implementado | Multi-plataforma |
| Sentry error tracking | Implementado | Opt-out de privacidade |
| Backup diário local | Implementado | SQLite WAL, restore probe |
| Backup offsite | Planejado | Configurável, não testado |
| Staging environment | Implementado (docs/config) | `STAGING.md`, `docker-compose.staging.yml`, `.github/workflows/staging.yml` existem; ambiente ainda precisa ser provisionado no Coolify (P5 — infra) |

---

## 9. Segurança

| Feature | Status | Observações |
|---------|--------|-------------|
| TLS (proxy) | Implementado | Coolify/Traefik termina TLS |
| TLS (direto) | Planejado | Precisa provisioning manual |
| 2FA admin/GM | Implementado | TOTP opcional (S4 — `TwoFactorAuth.gd`, UI runtime, migration 029) |
| Multi-conta detection | Implementado (parcial — heurística + alerta) | `Peers.gd`: `QueryBindings` (`fingerprint LIKE ?`, 7d), alerta se duplicatas > 1; código de coleta (`DeviceFingerprint.gd`) + persistência (`TelemetryService.gd`) existem; heurísticas integradas no login (não bloqueante) |
| WebRTC TURN | Não planejado | Apenas STUN público |

---

## 10. Performance

| Feature | Status | Observações |
|---------|--------|-------------|
| Server-authoritative | Implementado | Cliente nunca envia estado |
| Rate limiting | Implementado | Footprint por RPC |
| SQLite WAL | Implementado | Single-node |
| IdleTests CI | Implementado | XP curve, settle, ledger |
| Benchmarks CI | Implementado | `tests/benchmarks.gd` + job `benchmarks` em `.github/workflows/godot-ci.yml` (settle/XP/catalog) |
| Profiling produção | Implementado (P4 — stub compatível) | `Monitoring.gd`: `StartSpan()` / `FinishSpan()` com `Time.get_ticks_msec()` (stub — SDK Godot 4 não expõe `start_span` diretamente); `PERFORMANCE_SPAN_BUDGET_MS` 50ms; `ActiveSpans()`; falha nunca bloqueia |
| Sharding | Planejado | Por zona ou população |

---

## 11. Features Desligadas do Build

| Feature | Motivo | Reativar? |
|---------|--------|-----------|
| Música no web export | Streaming ativo | `.pck` reduzido; `Audio.gd` streama `/music/` via nginx; fallback graceful se não disponível (não desativado — streaming está ligado) |
| Mapa pequeno/cidades | Peso assets | Quando assets otimizados |
| Discord bot | Sem token/configurado | Quando token disponível |
| Some MMO commands | Pivô idle | Não — manter desligado |

---

## Decisões Pendentes

1. Reativar música no web build? (depende de <25MB + streaming)
2. Adicionar checkout UI real (Mercado Pago/Stripe)?
3. Onboarding básico implementado — melhorar highlights e conteúdo dos passos (U2 parcial).
4. Adicionar 2FA obrigatório para admin? (S4 implementado, opcional — decidir se obrigatório).
5. Implementar detecção de multi-conta? (S5 — heurísticas no código de fingerprint; código de coleta existe, heurísticas pendentes).
