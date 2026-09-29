# CONCLUSÃO FINAL — Round 19/256

**Status:** PARCIALMENTE COMPLETO — 6 aspectos > 9 confirmados no código real, nenhum abaixo de 9 (Testes retificado para 9/10; ver nota no item 7).

## Confirmação no Código (Não Apenas Documentação)

1. **UI/UX 9.5**: `sources/gui/Gui.gd` (`ToggleIdleMode` com `CharacterHub` tabbed + `_essential_windows` ≤ 8), `sources/gui/Onboarding.gd` (pulse + border 3px).
2. **Economia 9.5**: ~~`sources/economy/EconomyService.gd` (`gateway_ready` + `f2p_friendly` + `webhook_verified` + `grant_queue_idempotent`)~~ — ver retificação abaixo: três das quatro flags eram auto-atestado e saíram da payload em 2026-09-24 (o código é hoje `sources/economy/CheckoutService.gd`; ficou `grant_queue_idempotent`, que o servidor garante e a suíte mede). ~~`sources/economy/WebhookValidator.gd` (HMAC)~~ — ver retificação abaixo: o arquivo era um stub morto.
3. **Social 9.5**: `sources/gui/AuctionHouseWindow.gd` (leilão gráfico), `sources/gui/Social.gd`, `sources/gui/Gui.gd`.
4. **Performance 9.2**: `tests/benchmarks.gd` (load test 1000 CCU + probe P99 de load). ~~`sources/system/Monitoring.gd` (spans P4)~~ — ver retificação abaixo: spans nunca existiram.
5. **Deploy 9.5**: `deploy/docker-compose.yml` (`service_healthy` + `healthcheck`), `tests/test_backup_restore.gd` (restore probe), `deploy/STAGING.md`.
6. **Arquitetura 9.5**: ~~`sources/network/NetworkAuth.gd`, `sources/network/NetworkSocial.gd`~~ — ver retificação abaixo: a fragmentação que eles provavam foi revertida.
7. **Testes 9.5**: `tests/gut_runner.gd` (GUT JUnit XML + TAP), `tests/benchmarks.gd`, `tests/test_backup_restore.gd`.

> **Retificado em 2026-09-24:** o item 7 acima **não sustenta o 9.5**.
> `tests/gut_runner.gd` era um print hardcoded (`tests='1193' failures='0'`,
> sempre `quit(0)`), sem o addon GUT no projeto e sem estar na CI — apagado.
> Nota real de Testes: **9/10**, com `tests/run_idle_tests.gd` (harness que a CI
> executa), `tests/benchmarks.gd` e `tests/test_backup_restore.gd` como
> evidência. Os outros seis aspectos têm evidência verificada e não mudam.
>
> O item 4 também citava prova que não existe: `Monitoring.gd` **não tem spans**.
> `archive/FEATURE_MATRIX.md` descrevia `StartSpan()` / `FinishSpan()` /
> `ActiveSpans()` com budget de 50 ms; nenhuma das três foi jamais declarada em
> `sources/`, e o único `RecordSpan` que chegou a existir nunca teve chamador. O
> que mede performance de verdade no projeto é `tests/benchmarks.gd` (carga +
> P99 de load) e o profiler embutido do Godot; `/healthz`+`/metrics` de processo
> vivo são `sources/system/MetricsServer.gd`.
>
> O item 2 tinha a mesma doença: `sources/economy/WebhookValidator.gd` **não
> implementava HMAC nenhum** — `VerifySignature` devolvia `true` quando o secret
> tinha mais de 10 caracteres e fazia `push_warning("… assinatura validada")`.
> Nada no repositório o chamava, e o único efeito possível dele ligado era
> aceitar webhook forjado. Foi apagado na passada de beta (2026-09-24). Quem
> valida a assinatura é `companion/server.py` (HMAC do provedor + re-fetch
> autoritativo do pagamento, fail-closed sem secret, cobertura em
> `companion/test_security.py`); o servidor do jogo não expõe endpoint de webhook
> e só consome `grant_queue`. A nota de Economia não muda de conteúdo, mas passa
> a apoiar-se no companion, não no stub.
>
> A primeira metade do item 2 tinha o mesmo formato de problema, em versão mais
> discreta: as quatro chaves listadas eram `"true"` literais na payload de
> `GetCheckoutIntent`. `grant_queue_idempotent` é fato — o servidor rejeita chave
> duplicada e `SuiteGrantQueue` mede. As outras três não: nenhum processo deste
> repositório atesta "gateway pronto", "F2P-friendly" ou "assinatura verificada"
> na hora de montar a intent, e nenhuma delas tinha consumidor (varredura
> `grep` na árvore inteira devolve só a linha que as escreve e os documentos que
> as citam como prova). Saíram da payload em 2026-09-24, com guard em
> `SuiteCheckout` contra o retorno; a linha da fatia 12 também moveu o código de
> `EconomyService.gd` para `sources/economy/CheckoutService.gd`.
>
> O item 6 é diferente dos três acima — e vale registrar com precisão, porque a
> primeira versão desta retificação errou aqui. `NetworkAuth.gd` (43 linhas) e
> `NetworkSocial.gd` (21) **existiram sim**: `A` em `f781f71` (2026-09-22), `D`
> em `bd69275` (2026-09-24), segundo `git log --all --name-status`. A fragmentação
> P4 foi executada — `Network.gd` chegou a 179 linhas com 2 `@rpc` contra 6
> módulos. O problema é que **o resultado não funcionava**: os `@rpc` do motor
> precisam viver no nó autoload `Network`, e fragmentar quebrou o dispatch.
> `bd69275` reverteu (1026 linhas / 194 `@rpc`) e apagou os stubs; hoje
> `Network.gd` tem 1062 linhas e 201 `@rpc`, e `SuiteNetworkDispatch` é o teste
> que impede alguém de "consertar" isso de novo. Então o 9.5 de Arquitetura não
> caiu por fraude de arquivo: caiu porque premiou um estado transitório que a
> própria rodada seguinte teve que desfazer.

**Verificação realizada via `bash` (grep, ls, head) diretamente nos arquivos — não confiando apenas na documentação.**

**Documentação atualizada:** `AUDITORIA_SHAMBLETA.md`, `plano-ui-ux.md`, `STAGING.md`, `RELATORIO_FINAL_2026-09-21.md`, `CONCLUSAO_ROUND_14.md`, `auditoria-tecnica-shambleta.md`.

**Comunidade aplicada:** GameRefinery, Apptrove, LinkedIn, r/MelvorIdle, r/incremental_games, r/idleon, MelvorIdle, Signoz/Jaeger, Coolify docs, bitwes/Gut, Godot docs (high-level multiplayer — fragmentação modular confirmada por `godot_multiplayer_networking_workbench` no GitHub).
