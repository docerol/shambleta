# Plano — Polimento UI/UX (Idle-First) — Shambleta

**Objetivo (confirmado pelo usuário):** Polimento (não redesign total) — HUD idle aprimorado, onboarding refinado, simplificação mobile/touch, layout responsivo, settings simplificadas. **Sem tocar core loop, monetização (bloqueado pelo dono) ou rede de features já implementadas.**

**Base:** `FEATURE_MATRIX.md` §7 (UI/UX), `sources/gui/Gui.gd`, `Onboarding.gd`, `Localizer.gd`, `WebPush.gd`, `Settings.gd`. `README.md` confirma design idle-first.

---

## 1. Gaps UI/UX confirmados (código verificado, não inventados)

| Gap | Arquivo / Linha | Estado real | Impacto no jogador idle |
|---|---|---|---|
| HUD MMO herdado (20+ janelas) | `Gui.gd` — `ToggleIdleMode()` só oculta; não simplifica layout | ⚠️ Funcional mas não otimizado | Jogador precisa navegar por janelas MMO para um loop simples de farm |
| Onboarding highlights parciais | `Onboarding.gd` `_highlight_node()` = `Launcher.GUI.set_visible(true)` — não destaca elemento real | ⚠️ Passos existem (6), mas sem destaque visual | Novo jogador não sabe onde clicar; guia é texto apenas |
| Settings overwhelming (mobile) | `FEATURE_MATRIX.md` §7 — "Muitas opções, overwhelming para mobile" | ⚠️ `WebPushRow`, `LanguageRow`, `Render-*` adicionados em runtime | Tela de configurações confusa em telas pequenas |
| Touch não otimizado | `FEATURE_MATRIX.md` §8 — "Touch não otimizado" (`Mobile: Parcial`) | ⚠️ Joystick virtual existe; layout não responsivo | Experiência ruim em web/mobile — principal canal idle |
| Localizer meta stashed por `:` (não `:` válido) | `Localizer.gd` — meta prefix usa `som_i18n_`, mas documento `I18N_PHASE1_REPORT.md` menciona `:` como não válido para meta | ⚠️ Funciona (underscore usado), mas doc precisa de atualização | Nenhum impacto direto — apenas clareza técnica |

---

## 2. Fase de polimento — Prioridade alta (não depende de terceiros)

Todas as tarefas abaixo são **puro código/design de interface** — nenhuma exige dono, gateway, artista externo ou infraestrutura.

### P-A1 — HUD Idle: simplificar modo idle (`Gui.gd`)
- **Atual:** `ToggleIdleMode()` alterna entre `fullModeWindows.clear()` e restauração completa — 20+ janelas escondidas/reveladas brutas.
- **Polimento:** Definir `essentialWindows` (stats, chat, minimap, AFK report, zone, shop, boss, season pass) como lista explícita. Modo idle mostra apenas essas; não apenas oculta as outras.
- **Arquivo:** `sources/gui/Gui.gd` (linha 245 `ToggleIdleMode` + `fullModeWindows`).
- **Critério:** Jogador em modo idle vê ≤ 8 janelas; não precisa navegar por menus para ver progresso.

### P-A2 — Onboarding: completar highlights (`Onboarding.gd`)
- **Estado atual (verificado no código 2026-09-21):** `_highlight_node()` aplica border 3px + `ColorRect` pulse animado (`_OnboardPulse`) com tween de loop (0.8s fade in/out). Não apenas `set_visible`.
- **Polimento concluído:** Implementado highlight visual real conforme feedback da comunidade (GameRefinery / Apptrove: onboarding precisa de destaque visual, não só texto).
- **Arquivo:** `sources/gui/Onboarding.gd` (linha 130 `_highlight_node`).
- **Critério atendido:** Cada passo mostra visualmente onde interagir (border + pulse).

### P-A3 — Settings: simplificar para mobile/web (`Settings.gd` + `Gui.gd`)
- **Atual:** `renderAccessors` adicionam `General-Language` (linha 130+ `Gui.gd`) e `WebPushRow` (linha 452+ `Settings.gd`) no topo; `Render-*` ainda visível em web (`isWeb` oculta `WindowSize`/`Fullscreen`, mas não simplifica opções).
- **Polimento:** Em web/mobile (`LauncherCommons.isWeb` ou `isMobile`), ocultar ou agrupar opções não-essenciais de render (escala, tema CRT/HQ4x podem ser agrupadas em um submenu). Manter `WebPushRow` e `LanguageRow` visíveis mas compactas.
- **Arquivo:** `sources/gui/Settings.gd` (linha 385+ `init_webpush`, 478+ 2FA, 452+ web push); `Gui.gd` (linha 130+ `LanguageRow`).
- **Critério:** Tela de settings em mobile/web não excede altura da viewport; opções agrupadas logicamente.

### P-A4 — Touch / layout responsivo (`Gui.gd` + input)
- **Atual:** `FEATURE_MATRIX.md` confirma "Touch não otimizado"; joysticks virtuais existem (`InputBindings`) mas layout não se adapta.
- **Polimento:** Adicionar verificação de `OS.get_name()` / `LauncherCommons.isWeb` / `isMobile` na construção das janelas principais (`Gui.gd` `_ready`): redimensionar fontes, botões maiores, margens reduzidas. Não redesign total — apenas ajuste responsivo.
- **Arquivo:** `sources/gui/Gui.gd` (fontes, botões), `sources/input/` (mapa de input).
- **Critério:** Janelas principais legíveis em telas de 360px de largura (mobile web); botões tocáveis com dedo.

---

## 3. Fase de polimento — Prioridade média (não depende de terceiros)

### P-B1 — AFK Report: visual aprimorado (`sources/gui/AfkReport.gd` / `Gui.gd`)
- **Atual:** AFK report existe (`Gui.gd` referência `afkWindow`). Não verificado código específico de formatação.
- **Polimento:** Confirmar formatação de números grandes (K/M/B/T — já implementado em `Localizer.gd` / `UICommons`), cores para valores positivos/negativos, resumo de eficiência de sessão.
- **Arquivo:** `sources/gui/AfkReport.gd` (se existir — verificado apenas referência em `Gui.gd`).

### P-B2 — Localizer: meta stash idempotente (`Localizer.gd`)
- **Atual:** Meta prefix `som_i18n_` + `original,output` stash. Funciona.
- **Polimento:** Confirmar que `OptionButton` item labels e `TabContainer` tab titles (documentados como "não cobertos" em `I18N_PHASE1_REPORT.md`) estão tratados ou documentados como aceitos.
- **Arquivo:** `sources/gui/Localizer.gd` (linha 5+ `Props`, `MetaPrefix`).
- **Critério:** Nenhum gap oculto — documentado claramente.

---

## 4. Fase de polimento — Baixa prioridade / pós-lançamento (não bloqueante)

| Tarefa | Motivo de baixa | Dependência |
|---|---|---|
| Redesign completo do HUD (não polimento) | Escopo maior que polimento; requer redesign de arte e layout | Nenhuma — mas sai do escopo do usuário ("polimento, não redesign") |
| Themes CRT/HQ4x simplificados | Já funcionais; simplificar é opcional | Nenhuma |
| ~~Discord bot / social extra~~ | **Removido em 2026-09-25**: ponte, addon `discord_gd` e botão saíram do jogo com o projeto (o dono não tem servidor e os links eram do upstream do fork) | Nenhuma |
| Tutorial avançado (vídeos, animações) | `Onboarding.gd` básico funciona; conteúdo avançado requer arte | Nenhuma — mas além de polimento |

---

## 5. Critério de saída (polimento UI/UX)

- [x] `CharacterHub` (tabbed: Status, Skills, Progresso, Formação) ativado no modo idle (`ToggleIdleMode`) — `Gui.gd`. Implementado 2026-09-21 (P-A1 completo + U1 hub unificado).
- [x] `Onboarding.gd` `_highlight_node()` aplica highlight visual real (border 3px + ColorRect pulse animado `_OnboardPulse`). Implementado e documentado 2026-09-21.
- [ ] `Settings.gd` simplificado para web/mobile — sem overflow de opções; `WebPushRow` e `LanguageRow` compactas.
- [ ] Layout responsivo (`Gui.gd`) — fontes/botões legíveis em telas pequenas; `isMobile` / `isWeb` considerados.
- [ ] `Localizer.gd` — gap `OptionButton` / `TabContainer` documentado (aceito ou corrigido).
- [ ] `FEATURE_MATRIX.md` §7 atualizado com status final pós-polimento.
- [ ] Nenhuma alteração no core loop (`IdlePolicy`, `OfflineSettle`, `CombatPolicy`), monetização (`Checkout.gd`, `EconomyService.gd`), ou rede de features (guild, AH, trade, season).

---

## 6. Relação com gaps corrigidos (P4 / S5)

- **P4 (profiling)** — nunca realizado: `Monitoring.gd` não tem spans (`StartSpan`/`FinishSpan`/`ActiveSpans` só existiram no texto do `FEATURE_MATRIX.md` arquivado). Medir performance percebida de UI é trabalho a fazer com o profiler embutido do Godot e com `tests/benchmarks.gd`, não com o que está no repositório hoje.
- **S5 (multi-account)** — heurística no `Peers.gd` protege contra abuso; não afeta UI diretamente, mas garante que testes de polimento (múltiplas sessões) não sejam comprometidos por duplicatas.

---

**Status recomendado para `FEATURE_MATRIX.md`:**
- UI/UX: `HUD MMO` → Implementado (polido — essencial, ≤8 janelas); `Onboarding` → Implementado (polido — pulse + border); `Touch` → Parcial (polido — responsivo); `Settings` → Implementado (polido — simplificado para mobile/web).
- Economia/Monetização: `Checkout` → Implementado (~~P1 — gateway_ready flag + F2P-friendly~~; **retificado 2026-09-24**: a flag era um `"true"` literal na intent, sem consumidor, e saiu — o gateway real é o `companion/server.py`, fail-closed sem `SHAMBLETA_MP_ACCESS_TOKEN`); `VIP` → Implementado (sandbox); `Season Pass` → Implementado.
- Social: `Guild` → Implementado (`Social.gd` + botão HUD); `AuctionHouse` → Implementado (`AuctionHouseWindow.gd` — UI gráfica estilo Grand Exchange, busca/filtros/histórico).
