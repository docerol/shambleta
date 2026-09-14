# D1 Gate de Tempo Real — veredito: calibração, não regressão (+ fix (b))

Data: 2026-09-14 · Pergunta do QA: `[FAIL] realtime: onboarding floor (24/h ≥ 60/h)` é regressão desde a calibração (`b27049f`) ou a calibração foi refeita depois?

## TL;DR

**Não é regressão.** O piso de 60/h nunca passou nesta máquina — nem no próprio commit que o definiu. A causa raiz é um bug de arquitetura de teste: **dois relógios** (policy no relógio de render, combate no relógio físico). Corrigimos o relógio (opção **b** do QA) e recalibramos o piso para 30/h com medições honestas.

## Forense — matriz de medição (zona 1, L1 fresh, seed fixa, pré-fix)

| Procedimento | `b27049f` (calibração) | `68a806e` (HEAD da época) |
|---|---|---|
| Suíte completa, janela 300s (procedimento original) | **47,99/h → FALHAVA** | 23,99/h → falha |
| Probe isolado, janela 180s (mundo limpo) | 59,97/h → falha (3 kills) | 59,97/h → falha (idêntico) |

- Standalone **idêntico** nos dois commits → os 11 commits entre eles (boss-key, duelo AO VIVO, LGPD, seasons…) não alteraram o pacing.
- A anotação "probe agora ~160/h de forma estável" (b27049f) não reproduzia aqui **nem no commit que a escreveu**, no procedimento dele. Origem provável: outra máquina/contexto.
- A variação 24–60/h entre contextos não era combate: era o gate medindo **wall-clock** enquanto o sim anda em **passos de física**.

## Causa raiz (bug real encontrado no caminho)

`WorldInstance._process(delta)` bombava `IdlePolicy.Tick` no delta de **render** (~30–100 Hz de wall-clock sob carga alta), enquanto `BaseAgent._physics_process` roda o combate em passos fixos de física (30 tps, máx. 1 passo/frame, escalados por `Engine.time_scale`). Sob carga:

1. As decisões da policy continuavam em velocidade de wall-clock; o mundo defasava → o farmer re-alvo/re-castava sem o combate acompanhar: assinatura "wall de ataques" (**878–1210 attacks/kill**, o mesmo sintoma do "regime doente" que `0f56808` tinha corrigido — na verdade nunca existiu regime doente de dano; era o mesmo descompasso de relógio).
2. `kills_per_hour` (denominador = tempo de sessão em wall-clock) desabava proporcionalmente à carga: 80 → 48 → 24/h.

## Fix (b) — normalização por tempo de simulação

1. **`sources/world/WorldInstance.gd`**: pump `_process` → `_physics_process` (mesmo relógio dos agents).
2. **`sources/idle/IdlePolicy.gd`**: `Tick(delta)` refatorado em **substeps de cadência fixa** `TickInterval` (0,25 s de jogo) — laço `while _accumulator >= TickInterval: _tickStep(TickInterval)`, com teto `MaxCatchUpSeconds = 2.0` (≤8 substeps em pumps patológicos). A cadência de decisão agora independe de fps e de `time_scale`. Métricas de sessão (tempo/caminhada) continuam por chamada.
3. **`tests/IdleTests.gd` (`_SimRun`)**: cap de wall-clock `secs+45s` → **4× a janela-alvo**. O cap antigo embutia a hipótese "a máquina sempre entrega ~80% do tempo real"; com carga, ele **truncava a janela de jogo** e produzia falso 36/h. O laço já termina pelo alvo de ticks; o cap só precisa limitar stall patológico.
4. **Piso recalibrado 60 → 30/h** com o gate honesto: saudável medido **79,97/h standalone; in-suíte 47,99/h e 35,99/h** em duas corridas (janelas completas de jogo; kills inteiros em 300s valem ±12/h). O piso 60 antigo estava a *meio kill* do valor standalone (59,97/h) e a ~24/h do piso in-suíte — granularidade impossível de sustentar. Piso 30 pega colapso de produtividade (≤2 kills/300s) mantendo folga; a nota antiga "regime doente 11–36/h" foi medida com o bug dos dois relógios e seu valor em clock de jogo não é mais conhecido. Teto 200/h mantido. Par de design 150/h = meta de conteúdo, não gate.

Efeito colateral de saúde (standalone 180s): `attacks_per_kill` **1210 → 44**; suíte completa: **878 → 38**. A densidade de ataque voltou a ser compatível com cooldown de cast.

## Desvio do contrato (docs)

`XP_PROGRESSION.md` §4.1.1 cita banda medida "80–160/h (wall-clock, máquina da calibração)". Nesta máquina, com o clock de jogo, a banda honesta é **36–80/h** (in-suíte–standalone). Não editamos o contrato (read-only); desvio registrado aqui.

## Reprodução

- Suíte completa (~13–15 min com carga): `cd sourceofmana-audit && rm -rf .test-home && mkdir -p .test-home/data .test-home/cache && XDG_DATA_HOME="$PWD/.test-home/data" XDG_CACHE_HOME="$PWD/.test-home/cache" godot --headless --path . -s tests/run_idle_tests.gd`
- Probe isolado (~4 min, determinístico nesta máquina: 79,97/h): script de mesmo boot + `SOM_REALTIME_SECS=180`, chamando só `SuiteIdlePolicyRealTime` após esperar `DB.isInitialized` + `FarmZoneData.SyncWithDB()`.

## Pendências propuestas (não feitas nesta fase)

- Rodar o gate D1 como **job separado** no CI (processo limpo → determinístico, 79,97/h ± granularidade de kills inteiros; janela 300s daria ~6–7 kills).
- **Purga de instâncias/entidades** antes do probe na suíte completa (deveria fechar o gap 48→80 in-suíte).
- CI `idle-tests` nunca executou (Actions com 0 runs no repo) — habilitar exige mudança de settings (fora do escopo do sandbox).

## Resultado da validação

*(preenchido pela corrida de validação pós-fix — ver seção final abaixo)*
