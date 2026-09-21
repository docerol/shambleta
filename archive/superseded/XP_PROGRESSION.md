# Progressão de XP — Sistema Granular do Idle

**Versão:** 1.0 (2026-09-09) · Relacionados: [ARCHITECTURE.md](ARCHITECTURE.md) · [ROADMAP.md](ROADMAP.md) · [BATTLE_PASS_S1.md](BATTLE_PASS_S1.md)
**Prioridade:** Fase 2 (core idle) — parte do caminho crítico de "jogo funcionando", antes de qualquer monetização.

---

## 1. Objetivo

O jogador deve **sentir** a progressão em cada sessão: números grandes e crescentes, ganhos por kill visíveis, barras que andam, níveis que sobem com frequência saudável no início e de forma cada vez mais "épica" depois. Requisito do dono do produto: **"adicionar 2–3 zeros" à XP atual**.

## 2. Diagnóstico do código atual (evidências)

| Achado | Local | Problema para idle |
|---|---|---|
| XP por nível **hardcoded** em tabela (L2 = 9 XP; L135 = 2.147.483.647) | `sources/actor/stat/Experience.gd:4-154` | Sem granularidade inicial; teto em `INT32_MAX` (herança 32-bit; Godot 4 usa `int` 64-bit — folga para ~10^18) |
| XP por kill = `baseExp` do monstro × razão de dano | `sources/actor/stat/Formula.gd:139-149` (`ApplyXp`) | `baseExp` dos mobs é de unidade/dezena → feedback "+3 XP" |
| Level up em loop dentro de `AddExperience` | `sources/actor/Stats.gd:207-218` | Ok, reaproveitável |
| 40 mapas existentes sem valor de XP por zona | `data/maps/*.tmx` | Oportunidade: XP por **zona** (não por tier) = controle fino de pacing |

## 3. Opção A — Escala ×1000 (mínima, baixo risco)

Multiplicar **tudo** por 1.000 (grants e requisitos): L2 pede 9.000 XP, mob dá ~3.000–5.000 XP. Pacing idêntico ao atual, estética "juicy".
- **Pró:** 1 alteração de constante + multiplicador em `ApplyXp`. **Contra:** curva de 135 níveis não desenhada para zonas idle; tabela continua hardcoded; sem crescimento exponencial entre zonas.
- **Veredito:** aceitável como hotfix de percepção; **não recomendado** como sistema final do idle.

## 4. Opção B — Sistema idle completo (RECOMENDADA)

### 4.1 Os 3 componentes

1. **Curva de nível exponencial, gerada por fórmula (fim da tabela hardcoded):**
   `XP_necessário(L → L+1) = round(BASE × G^L)` com `BASE = 8.000` e `G = 1,22`.
   - `MAX_LEVEL = 150` (int64 segura até ~L180 com essa base; folga de engenharia).
   - Vantagens: ajuste de um par de constantes; sem tocar código para retunar; sem cap artificial em 2^31.
2. **XP por ZONA (40 zonas = 40 constantes geradas), não por tier:**
   `baseExp_efetivo(zona) = round(1.200 × 1,25^(z − 1))` para z = 1..40 → z1 = 1.200, z20 ≈ 95k, z40 ≈ 76M.
   - Cada zona é um "knob" de pacing individual (zona desbalanceada = mexer 1 número, não a curva).
   - `Formula.ApplyXp` passa a usar o valor da **zona de farm** em que o combate ocorre (em vez do `baseExp` por mob) — mobs dentro da zona ganham variância ±20% por raridade (elite/chefe ×5–×50).
3. **Newbie boost ×5 até o nível 10** (constante, transparente): onboarding em minutos — L1 = 8.000 XP ÷ (1.200×5) = **1,3 kills**; L10 chega-se na primeira sessão. Depois o boost cai e a "parede" da zona ensina o loop de gear — que é o jogo.

### 4.2 Amostra da curva (gerador acima)

| Nível | XP p/ próximo | Nível | XP p/ próximo |
|---|---|---|---|
| 1 | 9.760 | 50 | 591M |
| 5 | 18.1k | 60 | 4.27B |
| 10 | 53.8k | 70 | 30.9B |
| 20 | 391k | 80 | 223B |
| 30 | 2.84M | 100 | 11.6T |
| 40 | 20.6M | 150 | 1.39Qa |

*(valores gerados pelas fórmulas; arredondamento estético aplicado — ex. 9.760 em vez de 9.759,84)*

### 4.3 Alvos de pacing (o que validar em beta, não matemática fechada)

| Perfil | Jogo/dia | Experiência-alvo |
|---|---|---|
| Casual | ~1,5 h | ~1 semana por "bloco" de 4–5 zonas; L30–40 em 30 dias |
| Ativo | ~3–4 h | ~3–4 dias por bloco; L50–60 em 30 dias |
| Hardcore | ~8 h | ~1–2 dias por bloco; L80+ em 30 dias (endgame = leaderboards/season) |

Instrumentação obrigatória: telemetria `time_to_level` mediana por zona → dashboard → ajuste por zona (§4.1.2) entre temporadas.

### 4.4 Limite de segurança (int64)

`int` do Godot 4 = 64-bit (±9,2 × 10^18). Com BASE 8.000 e G 1,22, a curva atinge o teto em **~L180**. MAX_LEVEL 150 deixa margem; expansões além disso usam **prestígio/rebirth** (novo ciclo com multiplicador), padrão do gênero — nunca estourar o int.

### 4.5 Calibração implementada (2026-09) — deltas vs este spec

O inventário real (`tests/dump_calibration.gd`, sobre `data/maps/**/*.tmx` + `presets/entities/*.tres`) mostrou que o §4.1 foi desenhado sobre números de design, não sobre os assets. Ajustes que **substituem** o §4.1.2/§4.3 onde divergem:

- **Zonas: 40 → 24.** Só 28 mapas têm mobs e o nível deles cap-a em **L20**. Os 4 bosses (Dorian/Gabriel/Marvin/Splatyna) saíram do rodízio de farm (viram escada de boss-key, abaixo) e 12 placeholders sem mapa foram removidos. `MapBackedNames` reordenado por dificuldade do mob dominante → a escada é monotônica (antes a zona 8 era mais fácil que a 6). Curvas (`xpPerKill = 1200 × 1,25^(z−1)`, `gold = xp/8`) mantidas, agora terminando em z24 (≈234k/kill).
- **Tiers: 5 zonas/tier → 3 zonas/tier** (8 tiers em 24). `minPower` era `(tier−1)×30` (um char nu L2 entrava em tier 2); virou escada suave **por zona** `24 + 8·(z−1)`, amarrada ao power nu do nível-intenção (`power = level×10 + attack + defense` é **linear**: L1=25, L20≈229, L150=1620). Gear soma attack/def → loadout deixa "socar acima".
- **Par (taxa de kill) recalibrado pela taxa medida.** O par 72/h do §4.1.1 tinha sido calibrado contra um combat **doente** (bug de cancelamento de cast, corrigido em `0f56808`). Após a correção + dano-mínimo do idle, o probe mede **80–160 kills/h na zona 1**; o par foi a `3600/(24 + 0,9·(z−1))` → **~150/h (z1) … ~96/h (z24)**, o valor que alimenta o settle offline. Como o par é a base do faucet offline, o retune reprecifica toda a economia (gem sink: `ChestCostGems=120`, VIP +20% AFK).
- **Dano-mínimo do idle** (`SkillCommons.FarmDamageFloor`, 3,5% do HP máx do alvo, só para player com `idlePolicy`): os mobs de aventura têm defesa errática (Croc 41, Turtle 38) que, no auto-combat de skill única, virava 1 dano/golpe e derrubava a taxa para ~11/h. O piso garante progresso em toda zona sem tocar no caminho de aventura.

**Escada de boss-key (novo):** mobs de farm dropam **chaves** (`KeyDropPPM = 2000` = 0,2%/kill, ao vivo **e** acumulado no settle offline — idle-first). Uma chave abre o próximo boss de uma escada **sequencial de 4** (Dorian→Gabriel→Marvin→Splatyna). O boss **escala ao nível do char** (`stat.level = playerLevel`, tanque de HP ×6) e a luta é **renderizada ao vivo numa arena privada** (instância dedicada por char) — como o char e os bosses têm animações completas (Attack/Death/Idle/Walk 4-dir) e a instância anima com o player dentro, **o jogador VÊ o duelo**; o boss revida (`GetMostValuableAttacker`). Vitória = o boss cair (recompensa liquidada no hook de morte, `Formula.ApplyXp`); derrota = o char cair (consolação, sem avanço). Pagamento: vitória = **60 kills de farm** de xp + gold ×1,5 + 1 chest. Uma **sim determinística** (`BossService.Resolve`) sobrevive só como **fallback** (challenge sem sessão de farm, ou arena que não aquece) para nunca desperdiçar a chave. Schema: `character.boss_keys`, `character.bosses_beaten` (migration 019). Implementação: `sources/idle/BossService.gd` + `IdlePolicyService` (arena/duelo) + janela `Boss` na GUI (que se esconde no desafio pra liberar a tela e reabre no desfecho).

## 5. UX de feedback — "notar desenvolvimento"

| Momento | Mecânica |
|---|---|
| Cada kill | Floating "+1.2K XP" (formatação §6) já suportado pelo caminho `TargetAlteration(EXP)` existente |
| Barra de nível | Progresso **% visível** na StatPanel (hoje não há % — adicionar) |
| Level up | Burst visual/sonoro existente (`LevelUp` broadcast) + a cada **5 níveis**: milestone de recompensa pequena (gold/baú) — gera "próximo marco" mental |
| AFK Report | Delta grande em destaque: "+1.24M XP · +340K gold · 12 níveis" |
| Zona nova | Primeira kill na zona mostra "Zona 12: XP ×38" — reforça a sensação de crescimento |

## 6. Formatação de números (client)

- < 100.000 → dígitos completos com separador (`53.800`)
- ≥ 100.000 → sufixos: `K, M, B, T, Qa, Qi` (`1.24M`, `11.6T`) — padrão idle; implementa em `Util` (o caminho `Util.GetFormatedText` já é usado na StatPanel)
- **Sem notação científica para o jogador** (mantém a leitura "juicy"); científica só em telemetria/logs.

## 7. Migração de dados

- **Recomendação: reset de progressão no launch do pivô** (migration `018_reset_progress_idle`) — precedente já existe no repo (migrations `005` e `006_reset_progress_veteran_legacy`). O idle é um produto novo; inventário/equips legados não fazem sentido no novo pacing.
- Alternativa (se quiser manter contas veteranas): multiplicar `stat.experience` × 1000 e remapear nível pela nova curva — mais trabalho, ganho duvidoso.
- Reset é anunciado no changelog com "wipe da Era MMORPG" + cosmético de veterano como compensação simbólica (fideliza a comunidade upstream).

## 8. Touchpoints de implementação (para a F2)

| Arquivo | Mudança |
|---|---|
| `sources/actor/stat/Experience.gd` | Tabela hardcoded → fórmula (`BASE`, `G`, `MAX_LEVEL`) |
| `sources/actor/stat/Formula.gd` | `ApplyXp`: fonte de XP = zona de farm (com variância/raridade) em vez de `baseExp` |
| `presets/cells/entities` (monstros) | `baseExp` mantido p/ NPCs/edge cases; idle usa tabela de zona (`farm_zone.xp_per_hour` do ARCHITECTURE §6 — agora em escala nova) |
| `sources/util/Util.gd` | Formatter K/M/B/T/Qa/Qi |
| `sources/gui/StatPanel.*` | Barra % de nível + formatação nova |
| `sources/sql/` | Sem mudança de schema (`stat.experience` já é INTEGER 64-bit no SQLite) |
| `data/conf/migrations/018` | Reset de progressão |

## 9. Impacto cruzado nos outros docs

- **BATTLE_PASS_S1.md:** XP do passe ≠ XP do jogo → passe renomeado para **"Pontos de Temporada (PT)"** (evita "XP do passe = 40" ao lado de "+1.2M XP do jogo"). Números do passe inalterados.
- **ARCHITECTURE.md §6:** `zone_drop_rate`/`farm_zone` ganham coluna `xp_per_kill` na escala nova.
- **Leaderboard "Power Level":** power score usa contribuição **sub-linear** do nível (ex. √nível × gear score) — senão nível domina gear no ranking.
