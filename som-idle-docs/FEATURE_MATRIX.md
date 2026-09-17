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
| HUD MMO (herdado) | Implementado | 20+ janelas, não otimizado para idle |
| AFK report | Implementado | Mostra progresso offline |
| Settings | Implementado | Muitas opções, overwhelming para mobile |
| Touch controls | Implementado | Joystick virtual, reposicionado |
| Rebind de controles | Implementado | Input map completo |
| Temas visuais (CRT/HQ4x) | Implementado | Shader-based |
| Onboarding/tutorial | Não planejado | Falta documentado |
| Notificações push | Não planejado | Falta documentado |

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
| Staging environment | Planejado | Falta documentado |

---

## 9. Segurança

| Feature | Status | Observações |
|---------|--------|-------------|
| TLS (proxy) | Implementado | Coolify/Traefik termina TLS |
| TLS (direto) | Planejado | Precisa provisioning manual |
| 2FA admin/GM | Planejado | TOTP opcional |
| Multi-conta detection | Planejado | IP/device fingerprint |
| WebRTC TURN | Não planejado | Apenas STUN público |

---

## 10. Performance

| Feature | Status | Observações |
|---------|--------|-------------|
| Server-authoritative | Implementado | Cliente nunca envia estado |
| Rate limiting | Implementado | Footprint por RPC |
| SQLite WAL | Implementado | Single-node |
| IdleTests CI | Implementado | XP curve, settle, ledger |
| Benchmarks CI | Planejado | Falta documentado |
| Profiling produção | Planejado | Godot profiler + Sentry spans |
| Sharding | Planejado | Por zona ou população |

---

## 11. Features Desligadas do Build

| Feature | Motivo | Reativar? |
|---------|--------|-----------|
| Música no web export | Peso (26MB no first-load) | Quando <25MB atingido + streaming |
| Mapa pequeno/cidades | Peso assets | Quando assets otimizados |
| Discord bot | Sem token/configurado | Quando token disponível |
| Some MMO commands | Pivô idle | Não — manter desligado |

---

## Decisões Pendentes

1. Reativar música no web build? (depende de <25MB + streaming)
2. Adicionar checkout UI real (Mercado Pago/Stripe)?
3. Implementar onboarding para primeiro login?
4. Adicionar 2FA obrigatório para admin?
5. Implementar detecção de multi-conta?
