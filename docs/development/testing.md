# Testes

## Estrutura

Dois grupos de harness, e a diferença entre eles é mecânica, não de nome:

- **Fixos** — `EXPLICIT_HARNESSES` em `scripts/test.sh`: `run_idle_tests.gd` (o
  runner, que só sobe os serviços e carrega a folha das suítes), o kernel
  `IdleTests.gd` e a folha `IdleTestsFrontier.gd` (as suítes vivem nos dois, e o
  runner instância a folha — ver abaixo), `run_rpc_identity_test.gd`,
  `test_e2e_implementation.gd`, `test_backup_restore.gd` e `benchmarks.gd`.
  Somam-se a eles `diag_pacing.gd` e
  `dump_calibration.gd`, que são diagnóstico invocado à mão, não gate.
- **Auto-inscritos** — `harnesses_extra()` varre `tests/*_test.gd` e
  `tests/*_fuzz.gd` e transforma CADA arquivo num gate próprio (`gates_extra`, e
  o mesmo no passo `fixation` do job `idle-tests` da CI). Não existe lista para
  manter: um arquivo novo que case com o padrão já está inscrito no portão. O
  motivo é o destino que arquivos fora de lista tiveram neste repo — um runner de
  `gut` que nunca foi chamado, o próprio `check_doc_drift.sh`, `check_compose.sh`
  e o harness de restore completo, que viveu em `tests/` com nome fora do padrão
  desde que foi escrito: 184 linhas de régua que ninguém chamava (virou
  `backup_full_restore_test.gd` em 2026-09-27, e o primeiro run isolado dele já
  morreu num `player[0]` fora de índice — ver a linha da tabela acima).

Contagem derivada do registro em `scripts/test.sh` (`EXPLICIT_HARNESSES` + o globo de
`tests/`) e conferida a cada passada pelo portão de doc
— 75 harnesses no preflight, sendo os 73 das linhas abaixo (a tabela omite `IdleTests.gd` e
`IdleTestsFrontier.gd`, que não são gates próprios: `run_idle_tests` carrega a
folha, e a folha herda o kernel). A tabela não grava quantos checks cada
harness roda, de propósito: essa contagem vive na linha de resultado do próprio
harness, e reescrevê-la aqui é exatamente o número que mente no commit seguinte. O
que a tabela guarda é o estável — o QUE cada harness apura. `scripts/check_doc_drift.sh`
confere os nomes e a contagem de harnesses do preflight, e reprova linha de harness
que voltar a trazer contagem de checks:

| harness | o que apura |
|---|---|
| `run_idle_tests` | as suítes do kernel `IdleTests.gd` mais as da folha `IdleTestsFrontier.gd` — jogo, economia, rede, docs, ponteiros de evidência |
| `economy_invariant_fuzz` | fuzzer de invariantes da fronteira do dinheiro (marker `== FUZZ:`): pares de operações legalmente individuais que intercaladas somam errado |
| `faucet_census_test` | censo de torneira e pia (gold sink) medido do ledger e do estado do banco por `EconomyKernel.CensusSupply`: funil conservado (para a população limpa `Σ amount == último balance_after == carteira`, dono a dono, e `unattested == 0`), censo não-vazio com as pias do catálogo somando valor MEDIDO, mundo fechado (o catálogo cobre os escritores de `sources/`, conferido lendo o fonte) e controles negativos plantados (faucet cru sem e COM ledger, pia crua sem ledger, faucet cru de gemas) que mordem pelo mesmo predicado da perna conservada |
| `gold_sink_scale_test` | a taxa de forja lê a zona do personagem (achado #107 — `base × tier²` era cega ao mapa e a pia encolhia onde a torneira explode): monotonicidade medida na curva real do `FarmZoneData`, zona a zona e tier a tier, zona 1 bit-for-bit igual a `EconomyCatalog.CORRUPT_FEE_BASE × tier²` e `CraftCatalog.SubmitFee(tier)` conferida pelo caminho do produto (o `stat.gp` que sai), a banda declarada — uma ação de forja de tier 9 custa entre 60 e 180 minutos de fazenda par em todo par (zona, tier) alcançável — com a tabela antes/depois das 27 zonas e o pior caso impressos, mais a prova de que a banda é justa nas duas arestas, medida pelo mesmo predicado: 886 é o MENOR inteiro que passa porque 885 já fura o piso, 1099 é o MAIOR porque 1100 estoura o teto, e os dois furam exatamente UM par — zona 27, tier 9 — que é a célula que decide as duas arestas; o knob lido do arquivo por `EconomyCatalog.ApplyBaseCatalog` (valor novo dentro da banda muda a taxa cobrada, valor fora é recusado com o erro do próprio validador e não entra no estado), fail-closed em knob ausente/não-inteiro/zero, ledger de gold fechando depois de pagar a taxa escalada (`kind = gold`, débito negativo, reason `corrupt_fee:<item>` e `craft_submit_fee:tier<slot>` preservados, `balance_after` encadeado e origem + Σ == carteira) e o controle negativo plantado que roda o MESMO predicado contra a fórmula sem fator de zona e volta vermelho nomeando o par |
| `step_budget_metric_test` | o orçamento de passo do server existe como grandeza EXPORTADA e a régua que o pagina aponta para o nome que o processo serve: `Launcher.StepBudgetRecord` conferida por mesa com passos sintéticos (sequência dentro do orçamento devolve `overBudget == 0`, predícado estritamente `>` orçamento+folga — controle negativo da cauda), `MetricsServer.StepBudgetLines` conferida como texto Prometheus puro (baldes cumulativos e monótonos, `+Inf == count`, `_sum`/`_count` batendo com amostras, estado sem passo renderiza AUSENCIA não zero), todo nome `shambleta_*` de `deploy/alerts.rules.yml` precisa ser emitido pelo servidor, e uma emenda de parede com `Burn` de 40 ms/passo real move o contador e o bucket |
| `spend_confirm_test` | os gastos irreversíveis só falam com a rede depois do `ConfirmPending()` |
| `season_liveops_test` | temporada, passe e calendário de live ops lidos pelo caminho do produto (`LiveOpsCalendar.CurrentRaw`/`Entries`/`ActiveEntriesAt`): a agenda embarcada valida limpa, arquivo quebrado é fail-closed (nenhum evento no ar), janela `[start, end)` com fim exclusivo, multiplicador resolvido por timestamp; e a suite E do Achado #98 — há campanha no ar NO INSTANTE do run e acima do neutro, nenhum vão de cobertura passa da cadência de uma copa (`EconomyCatalog.TOURNAMENT_DAYS`, lido do fonte), todo dia de temporada agendada tem algum kind no ar, o horizonte da agenda não abandona temporada em serviço, nenhuma janela paga o neutro, e o controle negativo retira o eixo da copa para medir o vão que o arquivo tinha antes; e o espelho da trilha — a S1, a temporada que está no ar, declara `pass_tiers` no arquivo, e a régua compara nível a nível pelos dois sentidos, usando o leitor do produto (`PassTiers`), mais os três escalares, contra o catálogo que o jogador já recebia |
| `season_schedule_test` | a AGENDA de temporada no arquivo real do repo, lida pelo caminho do produto (`CurrentRaw` → `ValidateSeasons` → `Entries`): duas temporadas declaradas com `id` único, sucessora com janela futura (piso 2026-12-01 UTC, para não reescrever a régua de 30 dias do beta), `duration_days` batendo com a janela, `premium_sku` que resolve no catálogo que a loja cobra nos dois sentidos, `race` conhecida por `EconomyCatalog.SEASON_KINDS`, e a rotação com preempt+`rules_frozen` exercitada com os dados embarcados; cópias mutadas em memória (janela divergente, SKU inexistente, `id` repetido, corrida fora do catálogo, typo de chave) são RECUSADAS com `Entries()` vazio — o controle negativo de que "0 failures" não é a régua relendo um arquivo que não sabe falhar |
| `season_campaign_alignment_test` | o CASAMENTO entre os dois arquivos de agenda, lidos pelos caminhos reais do produto (`SeasonConfig.CurrentRaw`/`Entries` + `LiveOpsCalendar.CurrentRaw`/`Entries`): cada temporada com janela futura tem campanha cuja janela `[start_unix, end_unix)` intercepta os primeiros 7 dias dela, o marco em si abre com algum kind no ar e nenhum dia da abertura fica em branco; os `value` estão na banda que o próprio validador cobra (faixa lida das constantes `MinBonusValue`/`MaxBonusValue` e `MinPoolMod`/`MaxPoolMod`, não redigitada na régua); o multiplicador que o calendário resolve é o que os consumidores pagam no marco (`OfflineSettle.LiveOpsXpMods`/`LiveOpsChestMods`, `TournamentArenaService.PrizePoolMod`); nenhum `double_xp` cobre o instante do run (`SuiteSettleGolden` continua em mods 1.0); e controles negativos em memória acusam tudo que a agenda pode fazer de errado — campanha jogada para depois do fim da temporada, calendário reduzido às linhas que não servem abertura nenhuma (o estado anterior a esta régua), `value` acima do teto RECUSADO com `Entries()` vazio, janelas sobrepostas do MESMO kind acusadas e nunca compostas, cauda de campanha antiga terminando dentro da abertura, copa com `value` fora da banda do consumidor — com o estado embarcado lendo limpo de novo no fim |
| `pass_season_alignment_test` | o PASSE QUE A TEMPORADA VENDE, amarrado entre as duas linguagens (`== PASS SEASON:`): cada entrada do calendário embarcado resolve o próprio `premium_sku` pela ordem de autoridade (congelado na linha → entrada do calendário → default do catálogo); a vitrine filtra por temporada e não inventa botão para SKU fantasma; `companion/server.py` e `SeasonConfig.gd` partilham o MESMO literal de default e resolvem o mesmo passe para a MESMA linha congelada, inclusive a legada `{}` e os congelados ilegíveis (`null`, número, texto vazio, JSON quebrado), que são recusa nos dois lados; e nenhum literal de passe sobra no transporte do botão (`Server.BuyPass` / `CheckoutService.GetPassCheckoutIntent`), que é como a S2 no ar acabou vendendo o passe da S1 |
| `reason_toast_test` | nenhum reason token cru do servidor chega à tela: enumera o que `sources/` emite e confere catálogo/degradação nos dois sentidos |
| `accounts_fix_test` | conta, sessão, 2FA, reset de senha |
| `balance_test` | varredura de nível com invariante — jogar nunca paga menos por hora que esperar, para XP e gold — mais peso de `Modifier` e streak diário server-side |
| `fraud_test` | fila anti-fraude, referral guard |
| `read_pool_test` | pool de leitura: certificação e concordância dos dois caminhos |
| `login_hardening_test` | tentativas de reset, lockout, hash |
| `scale_test` | retenção de ledger medida no DB que o boot migrou: contrato do predicado, poda com retomada, dinheiro conservado, leitura de cauda e VACUUM |
| `presence_fuzz` | presença durável (migration 057) medida, não acreditada: os símbolos que o cabeçalho da migration nomeia existem, os três `EXPLAIN QUERY PLAN` prometidos saem SEARCH no índice certo, UPSERT de uma statement preserva `connected_at`, TTL poda nas duas direções do relógio com contagem exata, fantasma de processo morto sai por `ReclaimServer` e por TTL, DOIS `SQLService` sobre o mesmo arquivo se enxergam, e o heartbeat de 1000 personagens custa UMA statement (`== PRESENCE:`) |
| `economy_design_fix_test` | cap offline, forge, moeda, passe |
| `economy_knob_range_test` | o catálogo base virou dado de rebalance: cada knob de `data/conf/economy_base_catalog.json` traz uma FAIXA (`_knob_ranges`) e `ValidateBaseCatalog` cobra a faixa, não a igualdade com o const — número diferente do default dentro da banda passa (o rebalance que a jaula proibia), fora dela é recusa, knob sem banda é fail-closed, e o JSON do repo valida limpo. O const passou a ser o default documentado, usado só quando o arquivo não entra |
| `gameplay_fix_test` | prioridade de skill, elemental, escada de boss |
| `doc_facts_test` | fatos de doc cuja única fonte é o runtime: enum de diretório de backup, colunas depois de todas as migrations, autoload registrado, e a contagem de janelas por kind que a prosa embarcada do próprio `liveops_calendar.json` afirma — medida contra `Entries()` e conferida em algarismo OU por extenso, com controle que troca o numeral |
| `hud_wiring_test` | cadeia botão HUD → handler `Gui` → painel e o portão de gasto |
| `social_fix_test` | guilda, chat, lista de online |
| `social_graph_test` | o grafo social autoritativo da migration 061, medido no runtime: amizade como par simétrico, auto-relacionamento recusado, bloqueio unilateral, o teto na borda (amigos e bloqueios), cada token de recusa com exatamente uma frase no `PlayerReasons`, `EXPLAIN QUERY PLAN` do hot path saindo `SEARCH` no índice e nunca `SCAN`, custo da checagem por linha, a DIREÇÃO da entrega numa sessão viva (quem manda recebe o que?), e `/friend`, `/unfriend`, `/ignore`, `/unignore`, `/social` executados no `WorldCommands` real (`== SOCIAL GRAPH:`) |
| `test_e2e_implementation` | tabela chamador→método entre arquivos |
| `skill_content_reach_test` | alcance do catálogo de skills, medido no produto: toda célula `.tres` de `presets/cells/skills` tem origem declarada em `SkillOrigins` e nenhuma origem nomeia skill inexistente; cada origem aponta para conteúdo real do outro lado (kit padrão = `ActorCommons.DefaultSkills`, starter = `ClassBonus.starter_skill`, treinador = linha table-driven no script REAL da Elanore, sem literal de skill no NPC); os marcos de nível cabem na primeira metade da curva de `Experience` e cada classe fecha o próprio kit; personagem criado pelo RPC `Server.CreateCharacter` — sem comando de depurador — chega ao que as origens prometem; e a caminhada do jogador (`InteractChoice` na opção de treino) põe a skill em `Progress` E no `SQL`, que é o que a distinguia de perder a lição no relog (`== SKILL REACH:`) |
| `quest_reward_test` | recompensa DECLARADA de quest paga pelo servidor via ledger: `QuestData` tem campos numéricos próprios antes de qualquer parse de prose (o `reward` continua vitrine, default 0/0 — nada é mintado até o dado declarar); só a TRANSIÇÃO para 255 paga (reentregar 255 e regredir estado não pagam); fechar quest credita exatamente o declarado e escreve UMA linha de ledger, e o dupe não paga de novo nem depois de reabrir/apagar o estado no banco — a prova é o ledger append-only, não o estado, e o guard é por QUEST, não por personagem; quest sem recompensa declarada não paga e não erro; a perna de XP exige agente carregado (sem agente nada é mintado, linha inclusa); a frase do pagamento sai dos números; `SetQuest` chama o pagamento pelo funil que todo diálogo e o comando de GM usam, sem somar `stat.gp` cru; e a migração dos diálogos para o preset é conferida com censo dos que ainda pagam mais ratchet por nome |
| `backup_full_restore_test` | restore completo: fixture semeada pela API de produção, corrompe, restaura em base separada, confere ledger/wallet/stat da fixture |
| `web_delivery_test` | push honesto (gate + contrato + e2e python), ads bridge. A perna e2e precisa de interpretador: onde ele não existe as checks da perna viram SKIP visível e contado, com o binário exigido, o código de saída e o ambiente que rodou a perna no rótulo — nunca vermelho mudo nem verde por ausência de ferramenta. O verde nunca vem só da máquina de quem escreve: uma check lê o workflow e exige que o job containerizado que roda este harness proveja o interpretador, então remover o passo acende o vermelho em vez de esconder a perna |
| `webpush_subscription_test` | o GESTO do toggle de web push, executando o corpo real de `WebPush` (o `web_delivery_test` mede o caminho): `set_webpush` é o que chama o fluxo e `item_selected` mapeia ÍNDICE para bool antes da função tipada; com ponte e `Network` de mentira, "On" concedido faz `subscribe()` com a pública observada e os três campos chegarem ao servidor exatamente uma vez, e permissão negada fecha o navegador E o `Network` — "nada é enviado sem permissão" vira fato medido; "Off" só afirma remoção ao servidor depois do desassinar CONFIRMADO, e a dívida é quitada na leitura seguinte com teto de tentativas; e OFERTA != ENTREGA — a linha é desenhada por `CanOfferToggle()`, que abre com o que o gesto cria, enquanto `CanDeliver()` continua false |
| `perf_fix_test` | regressões de performance medidas |
| `deploy_ops_test` | flags de operação, runbooks |
| `i18n_catalog_test` | a tabela `ui.csv` e o catálogo COMPILADO que o `TranslationServer` lê dizem a mesma coisa, chave por chave |
| `run_rpc_identity_test` | WebSocket real + clients forjando peerID |
| `test_backup_restore` | probe de backup/restore |
| `gm_gate_fix_test` | portão de GM |
| `auction_house_wiring_test` | alcançabilidade do leilão: cada alvo da tabela do painel tem braço literal no `NetworkSend`, RPC no `Network` e handler no `Server`, e clique real (painel montado na árvore) manda o nome e os args certos para a rua — inclusive os da migração de market depth (GetAuctionPage/AuctionBid/AuctionBidCancel) — enquanto o "armar sem confirmar" não emite nada |
| `marketplace_depth_test` | economia das três pernas de mercado: preço realizado persistido na MESMA transação que liquida a venda, `BrowseListingsPage` com OFFSET/filtro/total no servidor, escrow/cancel/cruzamento, sem auto-negócio, e exatamente uma linha de histórico por liquidação (inclusive `via='bid'`) |
| `drop_band_content_test` | régua de CONTEÚDO das faixas de drop por tier, travada como dados e não como contagem: a faixa declara o próprio conteúdo em `FarmZoneData.BandMaterialNames` e toda declaração resolve para célula real do ItemsDB, que é `ItemCell.material` de verdade e está no tier que a declara (é o que impede a faixa de responder loot de tier errado, a face do fallback que existia); toda zona da escada tem pool não-vazia e toda entrada é item do catálogo ou template de craft aprovado com tier dentro da faixa |
| `conf_type_guard_test` | a folha de configuração tem que ser folha, e `Conf` não pode vazar credencial. `Type.NONE = -1` encontra o índice negativo do `Array` do Godot: `confFiles[-1]` é o ÚLTIMO arquivo, `AUTH_TOKEN` — um getter que esquecia o tipo lia o token de login e devolvia como preferência do usuário, em silêncio. `Usable()` fecha o intervalo e `Ensure()` fecha o array vazio (`Init()` só vinha do `Launcher._ready`, e em qualquer caminho que não passou por ali o primeiro acesso estourava out-of-bounds e a preferência caía no chão — foram os 20 `SCRIPT ERROR` do `WebPush._Save`). Além das sondas de valor há três réguas: varre o fonte e exige `Ensure()`+`Usable(type)` antes de todo `confFiles[` em cada acesso público (o getter novo que esquecer pega aqui); prova que `Init()` descarta o cache keyed por (seção,chave,tipo), que não sabe de que arquivo o valor veio; e caminha o grafo de classes a partir de `Conf`/`Util`/`LauncherCommons`/`FileSystem` — com os autoloads lidos do `project.godot`, não de lista à mão — e falha se qualquer arquivo alcançado nomeia um autoload, porque isso faz o mundo inteiro compilar antes do registro deles. Medido: uma única aresta `Util → SkillCommons` bastava para 41 `Compile Error` tocando `Util`, 43 tocando `Conf`, 42 tocando `LauncherCommons`; podada a aresta, os três viram 0 — e com eles ia embora o SIGABRT do `webpush_subscription_test` e a `LoadConfig` devolvendo null |
| `content_hygiene_test` | higiene de conteúdo: o censo do `EntitiesDB` é feito pelo DIRETÓRIO, não pelo dicionário — todo `.tres` de entidade de `presets/entities/` tem de ter `_id` igual ao hash de `_name` e estar no catálogo, e `|EntitiesDB|` bate com a contagem de arquivos (quem só lê o dicionário julga o que sobreviveu ao parse; era assim que o `return` que a reescrita de `0c5cb56` deixou em `DB.ParseEntitiesDB` sumia com toda entidade depois da primeira com id stale sem que nada acusasse); todo grupo de mob de toda zona resolve para entidade com nome, nível > 0 e contagem > 0; a pool de drop de cada zona É exatamente o conjunto de itens da própria faixa (fallback vazio deletado); a perna nova de boss é conteúdo real, não string |
| `craft_authority_test` | autoridade da forja ponta a ponta: char e conta vêm do PEER (não do pacote), o insumo tem DOIS preços — ouro (`SubmitFee`) e a matéria-prima declarada da faixa do tier (`CraftCatalog.MaterialPerCraft`) — sem material o `pending` não nasce (motivo `no_stock`, o ouro fica no char), o lote consumido é o BOUND que o drop produz, e a taxa de material/h é recalculada das três constantes de `FarmZoneData` para exigir que um craft de tier 1 custe entre 1 e 3 horas de fazenda; porta de e-mail e teto diário decididos no servidor, `pending` não cria item, e só depois do OK de um GM o template nasce |
| `craft_wiring_test` | ALCANÇABILIDADE da forja (a lacuna que segurou o juiz do core loop): a corrente inteira é apertada por botão real — `CraftAccess` da barra do HUD → `Gui._on_craft_pressed` → `OpenCraft` → `EnsureCraftPanel` nascendo da CENA (`presets/gui/CraftPanel.tscn`, com TitleBar de fechar) → clique em "submeter" só ARMA a prévia → `ConfirmPending` é a única porta e emite `Network.SubmitCraft` com os quatro args do RPC, nenhum char/account no payload (identidade é do PEER, provado por peer fantasma no handler vivo que não cria linha em `craft_submission`) — mais vitrine recomputada de `CraftCatalog`/`FarmZoneData`/`ItemsDB` contra uma recomputação independente (nenhum nome de slot, matéria-prima ou item como literal no painel ou na cena, pares bloqueados do catálogo nunca aparecem) e fechar/reabrir pelo HUD sem segunda janela; a MORDIDA é medida: cada elo da fonte real é copiado para a memória, uma linha é cortada de cada vez e o MESMO predicado tem que dizer AUSENTE sem derrubar o elo vizinho, e o arquivo relido no fim sai byte a byte e verde |
| `formation_priority_ui_test` | ordem de prioridade de skill alcançável pela UI: o painel declara a ordem e emite a string do comando via RPC do chat, a cena `presets/gui/Formation.tscn` está ligada, o servidor decide o que persiste (payload adulterado barrado) e a relog re-monta a `IdlePolicy` a partir do banco |
| `guild_chat_fanout_test` | fan-out do chat de guilda com EXECUÇÃO, não texto: um guildmate em segunda sessão recebe a linha (no canal e nick certos), quem não é da guilda não recebe nada, o fan-out é exatamente a lista resolvida (falante incluído), e as guardas de tamanho/mute continuam dentro do ramo |
| `guild_rpc_wiring_test` | as cinco ESCRITAS de guilda costuradas ponta a ponta e EXECUTADAS: painel → `@rpc` → handler autoritativo → `GuildFeedback`/`GuildState` de volta. Régua de fonte por corpo de método (braço literal no painel, assinatura igual nos dois lados, `@rpc any_peer` no canal ACTION, pacote que não nomeia conta nem personagem) mais execução real: peer sem sessão não move nada, painel que SE DECLARA outra conta mexe só no peer, cliente puro (`Launcher.Economy` ausente no clique) consegue fundar/entrar/sair/depositar/retirar no servidor, e o teto por ação mais a 4ª retirada da janela são recusados PELO SERVIDOR por chamada direta ao handler, sem UI no caminho — com o motivo cru do servidor ficando atrás do catálogo de toasts — marker `== GUILD RPC:` |
| `guild_vault_gate_test` | metade do SERVIDOR do portão anti-dreno do vault (§14): teto por ação recusado antes da transação e sem linha no rastro, dreno por chamada direta ao service parado em 3 ações, portão de cliente zerado que NÃO reabre crédito, janela que reabre só retrodatando o `guild_vault_log` (durável, não memória), crédito por conta, depósito que não consome orçamento de saque, painel que recusa o 4º clique sem ir ao banco, fronteira estrita de `WindowSec` com relógio injetado, `EXPLAIN QUERY PLAN` = SEARCH em `idx_vault_log_window` (migration 060), vault == rastro, e SELECT quebrada devolvendo recusa (999) — marker `== VAULT GATE:` |
| `admission_gate_test` | a PORTA pré-autenticação do servidor, medida nos dois transportes pelo MESMO caminho (`Admission.OpenTransport`): S1 cobra que ENet e WebSocket saiam com o MESMO teto (`NetworkCommons.ConnectionCeiling()`), porque a API do motor não expõe contagem de clientes no WebSocket e foi aí que a divergência 128/x morava; S2 mede o orçamento de handshake por endereço antes de qualquer credencial e a recusa de quem estoura a janela; S3 abre um WebSocket de verdade e conecta N+1 para ver a recusa chegar até o cliente (byte do auth, não só o log); S4 é a cerca do God Mode — nenhum arquivo de deploy ou job de CI pode expor a env, e `CommandManager` recusa o comando pela permissão quando o modo está off; S5 é a porta do esquema parado: migration que estourou no boot deixava o processo atendendo handshake (autenticava e morria na primeira RPC de tabela ausente), então `SQL.MigrationBlocked()` recusa com reason próprio ANTES do teto, conferido nos dois lados do flag, na função pura, na fiação viva de `Server._ValidateAuth` e sobre socket real, mais o `/healthz` caindo junto por `MetricsServer.ServingFor`. Morder em memória: tirar a linha do teto derruba cinco checks de uma vez, e um `SHAMBLETA_GM_MODE=1` num compose imaginário fica vermelho com o `arquivo:linha` do culpado |
| `aggro_cap_test` | a lista de quem bate num mob: `AICommons.MaxAttackerCount` é cobrado no runtime (cap+6 ataques viram exatamente o teto, e a lista nunca passa dele), o que sai é o MAIS VELHO pelo `time` declarado e sai exatamente um, três golpes do mesmo atacante somam numa linha só em vez de inflar, e a classe do bug é varrida do repo — nenhum `.gd`/`.py` sob `sources/`, `tests/` ou `companion/` chama `Array.erase(<literal inteiro>)`, porque `erase()` recebe VALOR e o `erase(0)` antigo não removia nada enquanto despejava um erro por chamada dentro do passo físico |
| `guild_governance_test` | governança de guilda no SERVIDOR: promote/demote/kick decididos pelo `account` autenticado e pelo rank LIDO DO BANCO (nunca por role declarado pelo cliente), cada ação aceita deixando rastro append-only em `guild_governance_log` (migration 062) na forma do `guild_vault_log`, promote por não-líder recusado SEM rastro, alvo inexistente e ator de fora caindo em `not_member`/`not_leader`, ninguém se chuta, `RemoveMember` não apaga o líder, e o teto de roster mora em UM constante (`GuildRoster.MaxMembers`) que o service não redeclara — cheio até o teto, o (N+1)-ésimo join é recusado com `roster_full` sem estourar a contagem |
| `hud_decision_fit_test` | os widgets de DECISÃO cabem num telefone: a moldura (390×844 CSS px) e o piso de área de toque (48 px, o maior entre `GuiUiScale.TouchTarget`/`TouchTargetFloor`) são lidos do PRODUTO por `get_script_constant_map()`, não redigitados no teste, e para cada controle visível de confirmar/cancelar/escolher o harness mede no runtime que o retângulo global intersecta e cabe na área visível (ou está atrás de `ScrollContainer` no eixo que estoura), que é maior que o piso declarado, e que nenhum outro controle lhe rouba o toque (caminhada de pintura com `z_index` acumulado achando o topo sobre o centro). Foi ele que achou o `MessageBox` — o diálogo global de confirmar/cancelar — com o botão primário a 665 px numa tela de 390, fora do radar do `panel_fit_test` porque não herda de `WindowPanel`. Morder: um `global_position.x += 1200` injetado em cópia de scratch derruba os três botões pelo nome |
| `map_load_test` | a CORRENTE de carga do mapa, elo por elo e em todos os mapas do `MapsDB` (o censo é lido do banco, não digitado aqui): a instância nasce, a franja `Fringe` é achada por uma varredura INDEPENDENTE do nó e comparada ao `currentFringe` do serviço (é assim que se prova que `RefreshTileMap()` rodou, e não que o serviço concorda consigo mesmo), o nó entra NA ÁRVORE sob `Launcher`, fica visível, `currentMapID` acompanha o mapa em pé e `MapLoaded` dispara exatamente uma vez — o sinal único do `Camera`, que é quem define a fronteira. Mais idempotência do `not force`, recarga com `force` sem deixar segundo nó, troca de mapa sem empilhar cena, e a metade NEGATIVA: um id inexistente não empurra nada, não grava id, não emite sucesso e deixa o `pool` SEM chave fantasma, porque é o sentinela `DB.UnknownHash` que destrava o retry do warp seguinte. Foi ele que achou o `MapPool.LoadMapLayers` guardando `null` no pool — `RefreshPool` decide adjacente por `not in pool` (o mapa que falhou uma vez nunca mais tentava) e `ClearUnused` conta a chave no tamanho mas não consegue apagá-la (teto do pool estourado para sempre). Morder (medido, não afirmado): trocar o `Launcher.add_child` por `pass` derruba quatro afirmações por mapa percorrido — árvore, pai, visibilidade e o nó único depois do `force` — mais as duas da troca e do retry, e o exit code do harness É a conta das falhas; voltar a guardar `null` no `MapPool` derruba exatamente as duas afirmações que nomeiam a chave fantasma e a drenagem |
| `migration_atomicity_test` | o carimbo de migration é conseqüência do que o banco aceitou, não do que o loop tentou: cada patch vira transação e só anda a versão se o `Query` devolveu sucesso (o `Query()` antigo devolvia `Array` e jogava o bit de erro fora, então um patch que estourava no boot era marcado como aplicado e nunca rodava de novo — com as tabelas do dinheiro no meio), a falha PARA sem avançar e é exposta (contagem, índice e arquivo do patch travado, `stalled`), a causa corrigida reaplica o patch falho e os enfileirados atrás, arquivo vazio/ilegível não é aplicado nem carimbado, os guardas `uptodate`/`empty`/`stale` continuam de pé e agora são observáveis, e cada patch do diretório anda o carimbo — a versão final é o
número de patches, conferido no próprio harness com `PRAGMA integrity_check = ok` — a
prova de que embrulhar em transação não quebrou as migrations que já trazem o próprio
`BEGIN TRANSACTION`. A série do `/metrics` e a alerta que pagina por ela são conferidas no mesmo harness |

| `multi_instance_tick_test` | a escada medida de instâncias × players no MESMO processo: cada degrau (piso 0, 1, 20, 40, 100, 200, 300, 400) é medido três vezes, a linha do meio é a mediana das medianas, e a convergência entre passadas é três réguas (maioria dentro de ±25% da mediana, a PIOR passada ainda dentro do orçamento, e spread total abaixo de um período de frame — sem isso um GC de 360 ms virava "teto", e com a régua antiga de `max−mín` um degrau são vermelhava por um tiro de um monitor de média móvel); o custo marginal por player co-residente é aferido contra um spin injetado de 4 ms — o que o monitor do motor capture (68–85%) é medido e declarado, não escondido num verde; os três relógios (trabalho, período, Hz entregue) têm de concordar antes de um degrau ser chamado de estouro; a cauda é régua nos degraus afirmados — p95 e max do TRABALHO na PIOR passada dentro do orçamento, e a cauda do DESPACHO (a janela `_physics_process`→`_process` do mesmo node, a grandeza que o predícado do produto lê desde #136) cobrada por TAXA de passos acima de orçamento+folga contra o corte LIDO de `deploy/alerts.rules.yml`, o mesmo número que pagina, com a mordida provada (40 ms/passo injetados têm de passar desse corte); o período de parede saiu da régua e virou testemunha porque cobrá-lo era paginar o sono do throttle, e o bracket deste harness é conferido como sub-intervalo do período do mesmo índice (`drift 0`, com o único excedente legítimo sendo o último passo ainda sem sucessora); o período é medido na FRONTEIRA DE TICK (um node comum em `_physics_process`), não no instante em que `await physics_frame` acorda, e a régua de concordância exige que o contador exportado por `/metrics` e esta janela contem o mesmo passo (banda de 6 numa janela de 120) — lido em `await physics_frame`, o harness via 33,6 ms lisos num degrau em que o produto contava 16 passos estourados; fd e threads por instância e o `RLIMIT_NOFILE`/`RLIMIT_NPROC` lidos de `/proc/self/limits` dizem o que NÃO limita; e os números que vão para `deploy/SCALING.md` são âncoras `<!-- DRIFT ... -->` conferidas contra a medição, no mesmo mecanismo do portão de doc |
| `nginx_hardening_test` | cerca do proxy da fronteira do dinheiro: faz parse de `deploy/web/nginx.conf` e confere diretiva por diretiva rate-limit, teto de corpo, CSP, X-Frame-Options e `server_tokens off` nas quatro rotas proxied — `/checkout/`, `/webhooks/`, a leitura exata `GET /push/vapid` e a leitura exata `GET /catalog` (suíte G, que lê `companion/server.py` para conferir que a vitrine chama o MESMO gate de temporada do checkout), respeitando a precedência real de `location`; confere também o contexto das diretivas — nenhuma de contexto `http|server` (a lista é `client_header_timeout`, `client_header_buffer_size`, `large_client_header_buffers`, `server_tokens`, `limit_req_status`) dentro de bloco de rota, que é o erro com que o `nginx -t` do build recusou o arquivo em 2026-09-30; roda `nginx -t` se o binário existir no host, e quando não existe o SKIP é impresso por nome, nunca `[ok]` |
| `d1_return_metric_test` | origem da métrica `d1_return`: dirige `Peers.FinalizeLogin` — o caminho vivo do login, não o predicado chamado por fora — e confere o `d1_return` que SAI do emisor contra `TelemetryService.IsD1Return` na mesma base. A heurística própria de `COUNT(DISTINCT date(...))` decidia o evento antes do funil e suprimia exatamente o caso "criada ontem, loga hoje pela primeira vez", puxando o número do funil para baixo; agora a única autoridade é `IsD1Return`, atingida via `RecordFunnel`, dos dois lados |
| `ops_fix_test` | lacuna de analytics/ops medida (não só prometida em comentário): telemetria com predicado d1_return, funil diário servido, `MetricsServer` e calendário de live ops fazendo o que o fonte afirma |
| `panel_fit_test` | cerca da CLASSE de bug "botão fora da tela": instancia todo painel `WindowPanel` no container de janelas flutuantes real do `Gui`, roda layout de verdade e mede retângulos contra o viewport de projeto, para nenhum controle nascer abaixo da borda |
| `password_timing_path_test` | comparação de senha em tempo constante: os dois ramos de versão de hash de `Hasher.VerifyPassword` convergem para um comparador sem saída antecipada, e "senha errada" e "conta inexistente" percorrem o MESMO caminho de custo |
| `repo_layout_test` | forma do repo: sonda rastreada na raiz que não compila/não emite marcador `== ...:`/`quit()` é falsa, e gate de estrutura escrito sem chamador no portão é pego. Todo censo desta gate é lido do índice do git, então o portão também mede a própria leitura: quando o git não deixa ler o diretório (dentro do container da CI o dono do workspace é outro usuário) cada rótulo de contagem vazia carrega o código de saída e a recusa literal do git, e o vermelho continua vermelho — índice ilegível nunca vira "repo vazio logo está limpo" |
| `shard_capacity_test` | lotação de shard pelo caminho real: `WorldAgent.CreateAgent` distribui cheio-na-ordem e nenhuma instância da família passa de `MAX_PLAYERS_PER_INSTANCE`, e a espera na `queryMutex` deixa de ser invisível |
| `tick_capacity_test` | capacidade de tick medida, não estimada: quantos players por zona o processo aguenta, cada nível numa zona isolada (instância dedicada por zona), e a tabela que vai transcrita no runbook de escalabilidade. A monotonia da escada re-mede o degrau anterior antes de acusar (zona diferente tem conteúdo diferente, e ruído só pode encarecer uma janela) e declara a troca no gancho de ruído |
| `core_loop_cycle_test` | ande um personagem pelo ciclo real numa sessão só (ganhar → liquidar → gastar → subir de zona → afundar → renascer) e emende as pontas que os testes de serviço deixavam soltas: nenhuma transição do ciclo existia como asserção antes |
| `gate_marker_control_test` | controle plantado do `harness_marker()`: um harness com marcador mixed-case, um com marcador tardio e um sem marcador, para a classe "verde lido como vermelho por ordem textual" (#81) não voltar sem portão |
| `guild_roster_race_test` | corrida no roster da guilda: promote/kick e teto de roster disputados pela porta real, com o texto velho que permitia a corrida conservado como controle |
| `i18n_coverage_test` | cobertura de i18n lida do fonte: toda chave usada por código/conteúdo tem texto nos idiomas declarados em `project.godot`, com o censo do que falta por arquivo |
| `preauth_ledger_test` | a cesta pré-auth de `Admission` é podada e tem teto por endereço: spray de IPs distintos deixa de comprar uma entrada de dicionário para sempre dentro do processo que segura o mundo (#85) |
| `refund_revocation_test` | estorno e chargeback de SKU não-gem revogam o direito, não só o dinheiro: `pass.*` derruba `premium`, `vip.*` corta `vip_until`/`vip_tier`, cosmético sai da posse e do equip; idempotência nos três sentidos, regra TOTAL (não pro-rata) decidida em código, e o controle negativo planta a remoção da revogação |
| `season_race_delta_test` | placar de temporada apura a JANELA, não a vida: a abertura grava o marco zero das três corridas lidas de contador corrente (`power_score`, `bosses_beaten`, `guild.points`) na MESMA transação do `INSERT` de `season`, e o congelado é diferença contra ele — quem nasce depois da abertura entra pelo total, quem cai dentro da janela congela em zero e sai do placar, o teto `limit` é ordenado pelo delta (um absoluto alto não desaloja um delta alto), o prêmio segue a ordem do delta, e o controle negativo planta uma temporada anterior à 064, sem carimbo, para a vitrine confessar `scoring = "current"` em vez de vender a vida do personagem como temporada — os dois regimes do mesmo campo amarrados, porque só o legado deixaria passar uma facade que devolvesse `current` para todo mundo; a perna S9 tira `season_score_baseline` do banco pela hora (renomeada, não fingida) para a abertura falhar pelo caminho real de um banco pré-064 e exige `0` de volta, census de `season` inalterado e, com a tabela de volta, a MESMA abertura cometendo — porque "devolve 0" também é verdade de uma facade morta |
| `rpc_receive_budget_test` | orçamento de RPC na porta do servidor, não na vontade do chamador: chat e fan-out global cobrados por cota no handler, com o intervalo mínimo do cliente rebaçado a intervalo e não a permissão |
| `telemetry_census_test` | censo de `telemetry_event`: todo `kind` escrito por fonte é lido por alguém, a tabela é podada por janela declarada, e a lista de órfãos é medida do diretório em vez de transcrita |
| `benchmarks` | orçamentos de performance (linha de resultado própria) |
| companion (python) | a fronteira do dinheiro em python e a régua de definição do painel: toda `companion/test_*.py` nomeada por `companion_gates()` (`scripts/test.sh:@companion_gates`); a cobertura é conferida ANTES de rodar, então uma suíte sem `gate_py` derruba o portão em vez de viver verde e invisível. `test_retention` é a que prende o D1 servido pelo `/metrics` à mesma view `cohort_retention` do servidor, e recalcula a régua velha de janela móvel como sombra para acusar quem a reimplantar; `test_season_offer` é a que prende o passe à temporada que o congela — aplica a migration 018 real, recusa o passe da temporada encerrada com `season_mismatch` (e a sombra da régua antiga, que o vendia), trata congelado ilegível como `season_rules_unreadable` nos dois sentidos, confere nas três portas de cobrança que a recusa vem antes de qualquer 200, e no bloco 11 prende o corpo de `GET /catalog` ao MESMO gate (marca `season_eligible`, nunca filtra) e proíbe literal de temporada na cópia embarcada — com a lista de arquivos derivada do `deploy/web/Dockerfile`, não escrita à mão |
| structure | os gates que medem o repo sem rodar jogo: `check_boot_sandbox.sh`, `check_compose.sh`, `check_dead_code.sh`, `check_doc_drift.sh`, `check_gate_log.sh`, `check_god_nodes.sh`, `check_secrets.sh`, `check_ci.sh`, `check_untracked.sh` — cada um imprime a própria contagem na sua linha de resultado, então o total é o do run, não uma promessa |

Todos passam pelo mesmo
`scripts/ci_gate_log.sh`, que não aceita exit code sozinho: o log não pode ter
`SCRIPT ERROR`/`Parse Error`, a linha de resultado tem que existir, a contagem de
falhas é lida DA LINHA DE RESULTADO (alimentar `0` à mão não aprova mais nada) e
o exit code do runner é conferido à parte. A linha tem que dizer
`N checks, M failures` — um `PASSED` sem contagem é rejeitado, porque "terminou"
não prova que a suíte iterou alguma coisa. E o run é conferido também depois da
última linha do harness: o Godot grava no teardown quantas instâncias ficaram
presas (`N ObjectDB instances were leaked at exit`), a soma desses números é
confrontada com um teto **por harness** em `data/conf/teardown_baseline.txt`, e
um harness novo que vaza sem entrada no arquivo é reprovado no teto do boot
magro. O teto é medido (`TEARDOWN_RECORD=1` regrava com folga), não escolhido, e
um teto que ficou muito acima do medido também reprova — teto que não desce
deixa de descrever o run e vira permissão. Antes disso o gate era cego ao
teardown: um run com 1066 instâncias presas era verde igual.
A chave dessa linha na baseline é o **nome do harness**, passado pelo chamador
como quarto argumento — nunca o nome do arquivo de log. O mesmo boot tem três
nomes conforme o caminho (`all` o chama de `rpc`, a CI de `rpc-identity`, quem
roda `one` o chama de `run_rpc_identity_test`), e derivar do log dava três tetos
para um harness só, dois deles inexistentes: a busca caía no teto padrão de 64,
o boot do mundo vaza ~1700, e o único caminho que um juiz usa sem pedir licença
virava acusação de regressão. A segunda lição vem do mesmo harness: ele era o
único que abria `SQLite` e saía sem juntar os preloads em thread do `DB`, então
o número de teardown dependia de quando o preload terminava — 30 dentro do
`all`, 1747 rodado sozinho, três vezes seguidas. `DrainPendingPreloads` bloqueia
em cada request antes do `quit()`, e com ele o teto volta a ser propriedade do
harness em vez de propriedade da carga da máquina. Antes de rodar qualquer harness,
`scripts/test.sh all|idle|quick` (e o job `idle-tests` da CI, no mesmo passo) faz
o **preflight de compilação** de todos os harnesses: `godot --check-only --script` em
cada arquivo (um processo `--check-only` por arquivo, então o tempo cresce com a
tabela — é por isso que esta seção não grava segundos). O motivo é um defeito que custou três execuções do
portão: `_run_tests()` (`run_idle_tests.gd:@_run_tests`) faz `load("res://tests/IdleTestsFrontier.gd")` e chama
`.new()` — se o arquivo não compila (um `CheckEq` recebendo `String` onde a
assinatura é `(int, int, String)`), nenhuma suíte roda, `== RESULT:` nunca
aparece e o gate descobre isso só no timeout de 1200 s. A régua é ancorada no
prefixo `SCRIPT ERROR:`, e não na palavra "Parse Error" em qualquer lugar, porque em
`--check-only` um script que referencia autoload também emite
`ERROR: ….tscn - Parse Error: [ext_resource] referenced non-existent resource`, que
é falso positivo do modo, não do código.
Desde 2026-09-28 o mesmo grepe aceita `Parse Error` e `Compile Error`: a classe
"este harness não levanta o processo" não é só parse. O caso que provou o buraco é
um harness `-s SceneTree` que classificava recurso com `is EntityData` — amarrar o
nome global de um recurso ao script do `SceneTree` joga a árvore de dependências
dele no compile do main loop, que roda ANTES dos autoloads, e o boot inteiro cai com
`Compile Error: Identifier not found: Launcher` em `Peers.gd`, `DB.gd`, `World.gd`;
o comentário que fixa essa regra está em `tests/content_hygiene_test.gd`. Medido nos dois
estados do mesmo arquivo: 40 linhas mutado, 0 consertado — e o preflight antigo
dava verde para os dois. A contagem tolerada por harness é gravada, medida e sem
folga, em `data/conf/preflight_baseline.txt` (`PREFLIGHT_RECORD=1` regrava); sem
linha o teto é 0, e os dois únicos tetos acima de zero são o kernel do harness e a
folha que referenciam o autoload `Launcher`. Os dois lados acusam: acima do gravado
é erro novo; abaixo é a linha que deixou de descrever o run (erro consertado e teto
que não desceu), que é o teto virando permissão.
Antes de 2026-09-24 o companion era o
único pedaço do portão com CI e local provando coisas diferentes: a CI chamava
`python3` direto e o `test.sh all` local não o rodava nenhum — hoje os dois chamam
`./scripts/test.sh companion`. `test_e2e_implementation.gd` estava
no repositório sem job nenhum até 2026-09-24 — é a tabela chamador→método entre
arquivos que teria pego `_show_char_menu` (`Gui.gd:@_show_char_menu`) chamando `Settings.get_sessionfirstlogin`,
um método que nunca existiu em nenhuma revisão (a chamada abortava o primeiro
login e o tour de onboarding não abria para ninguém). `test_backup_restore.gd`
saiu do mesmo jeito: ele terminava em `quit(0)` sem contagem, então o job
`backup-restore` ficava verde sobre um segfault.

A tabela acima não é mantida à mão. `scripts/check_doc_drift.sh` deriva a lista de
harnesses do próprio `scripts/test.sh` — `EXPLICIT_HARNESSES` mais o que
`harnesses_extra()` varre — e reclama nos dois sentidos: harness de gate sem linha,
e linha de tabela nomeando algo que o portão não executa. Uma régua com a própria
lista copiada passaria verde para si mesma e cega para o portão real, que é o defeito
que deixou `backup_full_restore_test` 184 linhas sem ninguém chamar. A coluna de
contagem de checks saiu desta tabela de vez: quantos checks um harness roda vive na
linha de resultado DELE, e regrava-la na doc é a doença que este arquivo existe para
caçar. Além de conferir os nomes e a contagem de harnesses do preflight, a régua agora
REPROVA linha de harness que voltar a trazer contagem de checks.

### As três réguas de âncora

Uma linha de doc que aponta para `arquivo:linha` é a única parte deste repo que envelhece
em silêncio: o código muda de linha e o texto continua parecendo verdadeiro até alguém
abrir o arquivo citado. `scripts/check_doc_drift.sh` confere as âncoras em três camadas
sobre ponteiro — identidade, nome de arquivo e literal — e o que é caminho em duas: a de
prosa (seção 24) e a de comando (seção 27). O corpo julgado é a doc `.md`, o comentário de
`.gd/.py/.sh` e, desde 2026-09-29, o JSON de `data/conf`: lá a régua mora no valor de
`_note`/`_campos`/`_estado_atual`, que é prosa sem marcador de comentário, e o censo do dia
achou três ponteiros e os três eram falsos. Cada régua traz o próprio self-test, controles
que têm de morder, porque um zero sem controles não é verde, é cegueira:

- **identidade (seção 23)**: se a frase nomeia um identificador, o nome tem de morar na
  linha citada. Roda em dois cortes (`narrow` e `wide`) porque um corte que só existe num
  sentido já perdeu metade do repo sem avisar. E as duas bordas do intervalo têm de ter
  texto: um intervalo 503-509 cujo topo está em branco não mostra nada para quem abre
  no número,
  e foi assim que o portão rápido deixou passar três ponteiros que o `run_idle_tests` —
  mesmo check, 20 minutos de run — acusou três vezes seguidas. A régua do branco mora no
  gate barato porque é o gate barato que muda o que quem edita vê antes do commit.
- **nome de arquivo (seção 23, mesma mordida)**: um token entre backticks com forma de
  `arquivo.ext` **sem caminho** entra na cobra, com duas tolerâncias a mais — a linha
  vizinha e o quinhão delimitado por linha em branco, porque citar o bloco onde o arquivo
  aparece é prosa honesta. A classe existia porque as duas réguas acima são cegas a ela
  por construção: `IDENT` rejeita o ponto, e a régua de literal só pinha o que mora uma
  vez no alvo — e `check_secrets.sh` mora duas vezes no runner. Foi por essa fresta que
  `tests/IdleTests.gd:6018` apontou para `scripts/test.sh:431` dizendo que o gate de
  segredo tinha entrado no portão, quando a entrada era a linha 532 daquele estado (o gate
  é hoje `scripts/test.sh:721`, e esses números andam com o arquivo): linha citada existia,
  tinha texto, e era outra coisa. Medido antes e depois: com a régua no ar, o mesmo
  ponteiro plantado de volta devolve `[FAIL] arquivo:` apontando onde o nome mora; sem
  ela, a passada fica verde sobre a mentira.
- **âncora (seção 28, corpo na seção 23)**: `arquivo:@símbolo` em vez de `arquivo:NN`.
  A motivação não é elegância, é preço: `arquivo:NN` é verdadeiro até a linha de cima
  ganhar um comentário, e o custo de consertar é marreta pura — `tests/benchmarks.gd`
  cresceu de 400 para 690 linhas numa rodada e isso sujou ponteiros que **nenhuma**
  régua acusava, porque a cláusula deles não nomeava símbolo declarado nenhum ("linha
  existe e tem texto" bastava). O veredito cobra três coisas e não afrouxou nenhuma das
  que a linha já cobrava: o símbolo tem de ser declarado no arquivo (zero declarações é
  `inexistente`, duas é `duplo` — âncora ambígua é acusação, não escolha), tem de ser
  nomeado na cláusula (senão a âncora só prova que o nome existe, que é exatamente a
  mentira que a régua de identidade caça), e todo literal pinado pela frase tem de morar
  **dentro do bloco** do símbolo. Arquivo sem modelo de declaração — `.md`, `.json`,
  `.conf`, `.tscn` — é acusado (`arquivo`), não silencioso: âncora onde ninguém sabe onde
  o bloco começa é linha disfarçada. Diferente do número, a âncora também é julgada nos
  registros datados (`CHANGELOG.md`, `progress.md`, `ROADMAP_COMERCIAL.md`,
  `BLIND_JUDGE_PROTOCOL.md`): o que é história ali é o número, e reescrever número
  gravado é falsificar diário; mas âncora que hoje aponta para outro lugar mente igual, e
  é por isso que o walk entrou nesses arquivos.
- **caminho (seção 24)**: um `.md` citado entre backticks tem de existir na árvore. A
  classe nasceu quando os relatórios de auditoria foram para `archive/` e a prosa
  continuou citando a raiz. exceção só com motivo em `scripts/dead_paths.txt`, e caminho
  registrado que volta a existir é acusado — senão o registro vira licença para citar
  fantasma.
- **caminho de comando (seção 27)**: a régua de cima lê prosa e só julga `.md`, porque
  estender aquele corpo a `.py` e `.sh` foi medido e devolveu ruído. Um comando dentro de
  bloco de código não é citação, é instrução: quem cola a linha no terminal recebe "No
  such file or directory". Esta camada cobre os docs que alguém executa — inclusive as
  receitas de `docs/`, que nenhuma outra régua de caminho lia — e achou na primeira
  passada uma receita mandando gerar os `.translation` com um script que não existe; o
  `.translation` vem do importador `csv_translation` do motor, e a ferramenta real está
  noutro caminho.
- **literal (seção 25)**: se a frase PROMETE um trecho entre backticks, o trecho tem de
  existir uma vez no arquivo-alvo e estar na linha citada, no mesmo quinhão delimitado
  por linha em branco, ou com todas as palavras dele no span. É a camada que faltava: as
  23 âncoras falsas da passada de 2026-09-28 satisfaziam "a linha tem texto" enquanto
  apontavam para outro código, e nenhuma das duas réguas acima tinha como ver isso.

Medido no run de 2026-09-28: 218 ponteiros nomeados em cada corte, 126 caminhos de doc e
54 ponteiros com literal único, tudo zero acusação, com 34, 18 e 19 controles mordendo
respectivamente. Os pisos (`IDENT_MIN`, `LIT_MIN`) são queda-para-baixo, não meta: uma
régua que passa a enxergar menos é uma régua quebrada, e o gate diz isso em vez de ficar
mudo. A régua de comando entrou em 2026-09-29 medindo 76 caminhos em 19 docs de
receita, zero acusação depois de consertada a receita, com 8 controles mordendo.

A âncora entrou em 2026-09-30 com 11 `arquivo:@símbolo` e 8 controles mordendo. As onze
estão em `BLIND_JUDGE_PROTOCOL.md` (dez) e `deploy/LAUNCH_HANDOFF.md` (uma), escritas a
partir de ponteiros de linha que o crescimento de `tests/benchmarks.gd` de 400 para 690
linhas tinha sujado, e que foram escritos de novo em vez de caçados linha a linha. O
ratchet tem dois sentidos e um só afrouxamento possível: `ANCHOR_MIN` é piso e só sobe,
`LINE_MAX` é teto de `arquivo:linha` e só desce. As duas direções foram conferidas na
árvore verdadeira, não só no self-test: âncora para símbolo que ninguém declara, âncora
cujo literal mora fora do bloco, âncora sem o nome na cláusula (inclusive escrita dentro
de `CHANGELOG.md`, que a régua de linha não lê) e âncora convertida de volta em número
devolvem cada uma o seu `[FAIL] âncora:` e um failure no laudo.

### A régua de registro (seção 26)

As três camadas acima julgam ponteiros. Existe uma quarta forma de a doc mentir sem
ponteiro nenhum: a frase que afirma um fato de código em português — "os nove gates de
estrutura" — e não cita arquivo, linha nem trecho, então nada tem o que conferir. Esta
classe nasceu da própria passada: `structure_gates()` ganhou o gate-log e o boot-sandbox e
a contagem velha ficou escrita em quatro lugares dizendo sete, três e dois.

A régua lê o registro de onde ele é verdadeiro — o corpo de `structure_gates()` em
`scripts/test.sh`, medido como as chamadas `gate_sh` que ele faz — e acusa qualquer prosa
`<numeral> gates de estrutura` cujo numeral diverja, em `.md`, comentário de código e
workflow YAML. O escopo é estreito de propósito:

- prosa que **enumera** sem numeral (o estilo desta casa, e o do parágrafo acima) não
  afirma contagem nenhuma e não é julgada;
- palavra que parece numeral e não é ("outros gates de estrutura", "os gates de estrutura")
  é isenta, com controle próprio;
- `scripts/test.sh` ilegível **não é registro vazio**: sem ler o fonte a régua reprova
  toda afirmação de contagem em vez de aprovar por ausência.

Medido: 4 prosas afirmando a contagem contra um registro de nove gates, com 11 controles
mordendo. A mordida foi conferida na árvore de verdade — o README plantado dizendo "sete"
devolve `[FAIL] registro:` e um failure no laudo. `REG_MIN` é queda-para-baixo como os
outros pisos: prosa de contagem que suma do repo é a régua ficando muda, não a honestidade
chegando.

### O eixo de linha dentro de `.md` (a suíte dos ponteiros de evidência)

As camadas acima conferem âncora no portão barato. O mesmo corpo é conferido de novo, linha
por linha, por `SuiteEvidencePointers`, e ali havia um buraco recortado por construção: a
régua de identidade pergunta se o símbolo nomeado pela cláusula mora na linha citada, e num
alvo `.md` não existe declaração nenhuma para indexar — o índice chega vazio de propósito, e
o braço que responde pelo arquivo inteiro devolvia "o nome está neste documento" e calava
sobre o número. Foi assim que a frase plantando `companion_gates()` em testing.md na linha 99
ficava verde enquanto a linha que o nomeia é a 115.

O quarto braço é `_ProseTargetVerdict` (`tests/IdleTestsFrontier.gd:@_ProseTargetVerdict`),
escolhido por `_IsProseTarget` (`tests/IdleTestsFrontier.gd:@_IsProseTarget`), e troca o
arquivo inteiro pela JANELA citada: se o documento escreve o nome em algum lugar mas fora do
intervalo, a acusação nomeia o símbolo e o número; se não o escreve em lugar nenhum, vale o
mesmo silêncio da régua de série — um nome que a prosa não soletra é caso do caminho e do
literal, não daqui.

A suíte também lê a ÂNCORA (`arquivo:@símbolo`), mas só pela estrutura: `_AnchorStruct`
acusa o alvo sem modelo de declaração, o nome que nenhuma linha declara e o nome declarado
duas vezes, e imprime quantas âncoras a varredura viu — censo abaixo de oito é a régua verde
por não olhar, não a árvore honesta. Os dois vereditos que faltam (`prosa` e `bloco`) ficam
deliberadamente com `scripts/check_doc_drift.sh`: cada um depende do modelo de cláusula, e
dois modelos de cláusula em duas réguas é a discórdia encomendada, não cobertura dobrada. O
piso daqui também não é copiado do `ANCHOR_MIN` da bash porque os corpos são diferentes; o
que as duas amarras têm em comum é o sentido — só apertam.

A mordida é conferida a cada gate com três controles sobre um fixture de prosa montado em
memória (nome na linha errada acusa, na certa cala, ausente cala) e a exigência de que o braço
tenha opinião sobre exatamente dois dos três; o piso da varredura é o número medido no corpo
de hoje, recalibrado quando o corpo muda, e nunca uma meta. O que fica fora, registrado: um
ponteiro para arquivo de código cuja cláusula não nomeia símbolo declarado — um local, um
arquivo, ou nada — não tem span a conferir, e foi por essa fresta que nove locadores de
`IdleTestsFrontier.gd` apodreceram ~1300 linhas sem uma reclamação.

## Execução

```bash
./scripts/test.sh all           # cada harness do portão, pelo quádruplo
./scripts/test.sh idle          # só a suíte idle
./scripts/test.sh rpc           # só identidade de RPC
./scripts/test.sh companion     # só a fronteira do dinheiro (python)
./scripts/test.sh one <harness> [timeout]   # UM harness pelo machinery inteiro
./scripts/test.sh clean         # descarta bases de teste
```

`test.sh` não chama `godot` direto: cada harness é gravado em `/tmp/shambleta-*.log`
e avaliado por `scripts/ci_gate_log.sh`, exatamente como na CI. Rodar local e a CI
com réguas diferentes é como o job de backup ficou verde sobre um segfault. Os
sandboxs de `user://`/cache ficam em `.test-home/<harness>/`, então um harness não
herda o `testing.db` do outro e o seu `~/.local/share/Shambleta` (o `user://` real
deste projeto, que usa `use_custom_user_dir`) não é tocado.

Esse isolamento tem um ângulo morto que virou mecanismo: um harness **morto no meio**
deixa o sandbox sujo — banco e WAL de um teardown que nunca aconteceu — e o próximo
boot do mesmo harness abre por cima desse estado e morre antes de dar veredito.
Medido em 2026-09-28: `run_idle_tests` duas vezes seguidas com `godot exit=134`, nos
mesmos offsets de engine, com o `testing.db` de 3,4 MB e um `testing.db-wal` de 16 MB
herdados de um run que eu mesmo matei. Por isso `gate()` escreve
`.test-home/<harness>/.booting` **antes** do engine e só apaga a marca com veredito
verde, e `_reap_interrupted_sandbox()`, chamado antes de marcar presença, remove
`data/` e `cache/` e diz isso na saída
(`sandbox <harness>: último boot não terminou — data/ e cache/ reapados antes deste
run`). A ordem é a régua, não é estilo: reap antes da marca (invertida, ela apagaria o
cache a cada boot), marca antes do engine (depois, nenhuma interrupção fica
registrada). Um sandbox **limpo** é intocado de propósito — o cache e as migrações
existentes são o que torna a passada barata, então "apaga sempre" não passa no controle
do gate `scripts/check_boot_sandbox.sh`. E como a marca só sai no verde, a retratada de
flaky abre um sandbox limpo em vez do mesmo estado que derrubou a primeira tentativa.

Log e sandbox são nomeados **por harness**, o que tem uma consequência medida: duas
execuções do mesmo harness — o `all` de uma janela e um gate disparado por outra, um
agente e o operador — escrevem no mesmo arquivo ao mesmo tempo, e o veredito lido de
um log misturado pode ser um verde falso (uma execução imprime `0 failures` enquanto
a outra ainda nem terminou). Por isso `gate`/`gate_py`/`gate_sh` seguram um
`flock /tmp/shambleta-<harness>.lock`: o segundo processo **espera**
(`SHAMBLETA_GATE_WAIT`, padrão 1800 s) e, se o espera estourar, o gate é registrado
vermelho com `GATE BLOQUEADO` em vez de ler log alheio. Harnesses diferentes seguem
em paralelo, e onde o host não tem `flock` o portão roda normalmente — a ausência do
utilitário não pode travar um lançamento. Verificado nesta máquina: com o lock do
`check_doc_drift.sh` tomado por outro processo e `SHAMBLETA_GATE_WAIT=1`, a passada
fechou `== GATES VERMELHOS: check_doc_drift.sh ==`.

O lock por harness não cobre o que o projeto tem de **compartilhado**: dois boots de
`godot` no mesmo projeto dividem `.godot/`, o `testing.db` local e a porta 9400 do
`MetricsServer`. Daí dois domínios de exclusão, e a paralelidade por harness continua
valendo só dentro do primeiro:

1. `flock /tmp/shambleta-boot.lock` (fd próprio, 8) — um gate **godot** por vez,
   inclusive o `--import` do cache de `class_name`. O fd é argumento de `_acquire`
   porque um gate segura dois locks; com fd fixo o segundo `exec` fecharia o primeiro.
2. `boot_guard()` antes de qualquer dispatch (exceto `clean`) — se existe `godot` com
   cwd neste projeto que **não** passou por este script, o portão recusa:
   `GATE PULADO: godot estrangeiro (pid …)`, fechado por `== GATES VERMELHOS: boot_guard ==`.
   Esperar por processo que não é nosso seria travar o lançamento indefinidamente; a
   fuga é `SHAMBLETA_ALLOW_FOREIGN=1`, que assume o risco explicitamente. Um `godot`
   reconhecido como descendente de OUTRA instância deste script — caminhada de
   ancestrais em `foreign_godot_pids()` — não é estrangeiro: o portão imprime
   `GATE SERIALIZADO` com o pid e o comando e segue, porque são exatamente os dois
   locks acima que ordenam os dois.

Os dois sentidos da cerca foram medidos nesta máquina: com o estrangeiro vivo,
`structure` saiu 1 com o `GATE PULADO` acima; sem ele, `structure` voltou
`== GATES VERMELHOS: none ==`.

A exclusão, porém, não matou o crash de teardown, e esta doc não vai fingir que sabe o
motivo. O que foi **medido** nesta máquina em 2026-09-28: 60 boots da passada completa,
DOIS harnesses saindo 134 (`SIGSEGV` numa thread worker, assinatura idêntica nos dois —
mesmos offsets de engine) depois de a linha de resultado já dizer `0 failures`; os
mesmos dois harnesses, três vezes cada um por `test.sh one`, voltaram 6/6 verdes. O
veredito do harness estava certo e o processo que o imprimiu, não. A leitura que
distingue os dois estados é repetir o boot, com teto de **uma** retratada por harness
(dois seria roleta) e disparada só por assinatura — e são duas assinaturas, porque o
crash tem dois modos de cair: exit ≠ 0 com marcador de zero falhas, ou morte por sinal
(exit ≥ 128) **sem marcador nenhum**. O segundo modo foi medido nesta máquina em
2026-09-28, às 20:27: `test_backup_restore` morreu por sinal (`exit=134`, com a linha
`timeout: o comando monitorado despejou núcleo`) sem chegar a imprimir o próprio
marcador, no meio de uma passada otherwise verde, e como a régua antiga só conhecia a
primeira assinatura o portão vermelhou um run que não chegou a dar veredito — crash de
engine contado como defeito de produto, que é exatamente o engano que um juiz anotaria na
categoria errada. Timeout fica fora das duas
de propósito (exit 124 < 128): retratar lentidão custaria o dobro de relógio sem provar
nada. Harness que falha de verdade continua vermelho na primeira, porque aí não há
contradição a resolver. A retratada acontece sob o mesmo lock de boot, o log do crash é
preservado em `<log>.crash` — sem a primeira tentativa salva, "instabilidade registrada"
seria frase sem prova — e cada retratada sai na linha `== FLAKES: … ==`, impressa em
**todo** run, verde ou vermelho. O que o portão esconde, ele escreve.

## Ruído externo: a régua que declara "não medi" em vez de acusar o produto

Uma fence de wall-clock só mede o produto se a janela for do produto. Medido em
2026-09-28, num host de 12 núcleos com um jogo do usuário em execução (load 11,6-15): o
piso do processo no `multi_instance_tick_test` saiu 60,66 ms/passo contra 11,11 ms
medidos dois minutos antes, e o custo por player 370 µs contra a fence de 340 µs.
Nenhum daqueles números é regressão — é o scheduler de outra pessoa dentro do meu
relógio. Remarcar até dar verde seria esconder a mesma coisa; o portão agora diz.

Três peças, cada uma ligada a uma leitura:

1. **A sonda.** Cada janela compara o agregado de `/proc/stat` com o `utime+stime` do
   próprio processo (`/proc/self/stat`) sobre `wall × núcleos` e devolve a fração da
   máquina que foi embora com OUTRO processo. O limite declarado é 25%, e ele é
   conseqüência, não escolha: o `cpus: 2` do compose num host de 12 núcleos admite
   16,7% de vizinhança; o dobro disso já não é o contrato do beta. A mesa da perna (e)
   — nove casos construídos, entre eles o discriminante "nós ocupamos oito núcleos e a
   máquina é nossa" (uma sonda que esquece de subtrair a si mesma diria 66,7% de ruído
   nesse caso) e os dois que fecham a borda por baixo e por cima — é o que impede a
   régua de virar prosa.
2. **A espera, com três bordas.** Janela suja é remedida enquanto couber em 15 s de
   janela, 90 s de orçamento do run (`SHAMBLETA_NOISE_WAIT_MS`, teto 600 s) e apenas
   para as janelas que a sonda declarou sujas. Sem a borda do run, um host tomado
   trocaria um veredito falso por um timeout — que é outro veredito falso.
3. **A leitura, em duas direções.** Sob ruído uma asserção *relacional* (o player
   aparece na medida? o degrau fundo custa menos que o raso? a pausa devolveu o
   previsto?) não é lida em nenhum sentido: a janela de referência infla junto, e aí o
   verde passa a ser fabricável pelo vizinho. Uma asserção de *teto* que saiu cumprida
   continua sendo leitura, porque preemption só pode AUMENTAR o tempo de uma janela: o
   que coube no orçamento com a máquina tomada coube de verdade. Vermelho de teto sob
   ruído é `[RUIDO]`, não `[FAIL]`. As duas decisões são funções puras
   (`readsTiming`, `readsCeiling`) conferidas por mesa na mesma perna (e), porque
   inverter um sinal ali faria o portão ler vermelhos fabricados — ou recusar verdes
   válidos — sem que nada no repo contasse qual dos dois aconteceu.

O censo é o que o portão repõe. `== NOISE-DECLARED: N ==` é impresso por todo harness
que tem a régua, sempre, inclusive em zero; `scripts/ci_gate_log.sh` transforma isso em
nota do job (verde com lacuna, dita) e `scripts/test.sh` fecha a passada com
`== GATES COM RUÍDO: <harness>:<janelas> ==` ao lado de `== GATES VERMELHOS: … ==` e
`== FLAKES: … ==`. Ler a ausência dessa linha como zero é exatamente o defeito que o
§24-8 combate, então o formato do gancho é vigiado por `scripts/check_gate_log.sh`: um
auto-teste do próprio leitor de veredito, com fixtures sintéticos escritos pelo script
(verde simples, verde com três janelas declaradas, verde sem linha nenhuma, check falho,
`SCRIPT ERROR`, leak acima do teto) e o extrator de `test.sh` extraído do arquivo e
executado contra os mesmos logs. Três mutações foram medidas nele — arrancar o bloco de
nota do leitor, quebrar a âncora do extrator, mudar o texto do gancho no harness — e
cada uma deixa o fixture vermelho. Ele roda em `structure_gates()`, então `all` e CI o
chamam pela mesma porta.

E ele se acusou. O stdout de um gate rodado por `gate_sh` É o log que `ci_gate_log.sh`
varre, então um rótulo de `afere` que cite o texto do marcador fatal faz o portão achar
`SCRIPT ERROR` num run verde: `check_gate_log.sh` imprimiu `16 checks, 0 failures` e
mesmo assim foi declarado vermelho pela passada. `fatal_labels()` lê toda string que cada
gate registrado em `structure_gates()` imprime e recusa nela os marcadores fatais — a
agulha continua no código, fora da prosa — com dois controles plantados: um rótulo que só
diz `SCRIPT ERROR` tem de ser pego pela régua, e um fixture cuja *linha de dados* é o
marcador tem de continuar sendo pego pelo leitor. São 27 checks.

O que isto NÃO é: um verde. Um run listado em `GATES COM RUÍDO` passou nos checks que
leu e não leu os outros; antes de citar qualquer número de `deploy/SCALING.md` como
verificado, a passada daquele harness precisa fechar com `GATES COM RUÍDO: none`.

O portão fez o serviço dele na primeira passada quieta que encontrou — `NOISE-DECLARED: 0`
em 2026-09-28, 182 checks, **duas réguas lidas pela primeira vez e ambas vermelhas**.
Uma delas era a régua que estava errada, e é bom que esteja escrito: a perna de
sobrecarga previa que 40 ms/passo de spin subiria 10 pontos a fração da máquina
atribuída ao processo, e mediu 8,4% → 8,3%. O laço de tick é **um thread só**, e no
degrau-sonda ele já estava colado em 1,00 núcleo — que num host de 12 núcleos são
exatamente os 8,33% observados. Num processo `work-bound` a queima não compra fração,
compra **período**; a fórmula agora devolve `min(núcleos pedidos, folga até 1,00)` e a
conferência de fração morou para o calibre do degrau mais leve (0,04 núcleo, folga de
sobras), onde a predição vale e pode mordê-la. As quatro linhas construídas dessa
fórmula estão na perna (e), incluindo a saturada, que tem de devolver zero.

A outra régua era a de convergência entre passadas, e ela continua uma régua — só que
estava cobrando a estatística errada. `medianMs` é a mediana de 90 amostras de
monitores de **média móvel de 1 s** da engine, então uma janela inteira tem ~3
observações de fato, e `max − mín` sobre três medianas não limita nada além de si
mesma: o censo quieto foi 0,06 / 0,49 / 0,25 / 2,53 / 1,29 / 1,55 / 1,63 / 10,50 ms, e
2x20 vermelhou com `[5,13 7,66 5,52]` enquanto o período de parede não saía dos
33,60 ms. As três perguntas que o beta decide entraram no lugar, cada uma na régua do
seu tipo: a **maioria** das passadas cabe em ±25% da mediana (relacional, `CheckTiming`
— um tiro sozinho não veto o degrau, duas fora é nível bimodal), **até a pior passada**
cabe no orçamento de 33,33 ms (teto de uma janela, `CheckCeiling` — a única que
sobrevive ao vizinho, e a mais forte das três), e o spread total não passa de **um
período de frame** (relacional, testemunha de legibilidade). Nove linhas construídas,
com o caso real deste host e o bimodal que morde.

## Ferramenta de mão: `tests/_probe_readonly.gd` (sonda das duas suítes read-only)

```bash
stdbuf -oL -eL env XDG_DATA_HOME="$PWD/.test-home/probe/data" \
    XDG_CACHE_HOME="$PWD/.test-home/probe/cache" \
    timeout 300 godot --headless --path . -s tests/_probe_readonly.gd
```

O arquivo instancia a folha `tests/IdleTestsFrontier.gd` (as suítes vivem lá
desde o fatiamento de 2026-09-28; a instância é uma só, então o placar impresso é o
delas, não uma soma) e chama os três leitores de doc que não escrevem em disco nem
tocam estado de jogo — `SuiteEvidencePointers()`, `SuiteHarnessCitations()` e
`SuiteExternalLinksWebBranch()`, na mesma ordem do `run_idle_tests.gd`. O boot do
`Launcher` (e portanto do servidor local) acontece mesmo assim, porque a sonda sobe a
árvore normal. A régua de citação de harness entrou na sonda em 2026-09-28 pelo
motivo que a sonda existe: o controle de fantasma dela ficou vermelho e ninguém viu
por 20 min — só o gate completo a roda. Medido em 2026-10-01, nesta máquina:
**641 checks, 0 failures** em menos de um minuto, contra os ~20 min do gate `idle`,
que executa as 93 suítes chamadas por
`tests/run_idle_tests.gd` <!-- DRIFT idle_suites 93 -->. Este número é o único da
seção recalculado a cada passada: a régua 22 de `scripts/check_doc_drift.sh` conta os
chamados no runner e compara com a âncora, porque a frase anterior dizia "137 suítes"
e nenhum lugar do repo reproduzia 137. Existe porque mexer numa citação
`arquivo:linha`
de doc embarcada exige o veredito da régua, e iteração com ciclo de 20 min é como
ninguém confere as réguas — a régua apodrece e o `all` avisa três horas depois.

Ele é deliberadamente **fora do glob de descoberta** (`tests/*_test.gd`,
`tests/*_fuzz.gd`): as duas suítes já rodam dentro de `run_idle_tests`, e um segundo
par de pernas no `all` dobraria o custo sem medir nada novo. O prefixo `_` é o que o
mantém fora, e `repo_layout_test` exige que uma exceção assim seja ferramenta de mão
documentada — esta seção é a receita; sem ela o harness é considerado morto.

## Ferramenta de mão: `DRIFT_WORKLIST=1` (a lista do que falta converter)

```bash
DRIFT_WORKLIST=1 timeout 900 bash scripts/check_doc_drift.sh | grep '^WORKLIST '
```

O #124 trocou ponteiro de linha por âncora, e o custo que sobrou é a procura: para
cada `arquivo:NN` cobrado, abrir o alvo, caçar a declaração cujo bloco contém aquela
linha e conferir se a frase já nomeia o nome. Esta variável de ambiente faz o **mesmo
walk** que cobra os ponteiros devolver esse resultado linha a linha — classe, sítio,
alvo, símbolo candidato e a cláusula que a régua lê — em vez de um script próprio com
um segundo modelo de declaração, que seria dois leitores vendo duas geografias do
mesmo arquivo (o #116). As classes são `gratis` (a cláusula já nomeia; converter é
sintaxe), `prosa` (o símbolo existe, a frase não o nomeia; converter é reescrever),
`fora` (nenhum bloco cobre a linha citada), `sem modelo` (o alvo é Dockerfile, nginx,
CSV, SQL — ali não há declaração a ancorar) e `morto` (o arquivo não resolve).

A ferramenta não é régua: ela não muda veredito, censo nem saída do portão, e o seu
self-test é o invariante da lista — as classes têm de somar os ponteiros julgados do
corte narrow mais os alvos mortos, e uma classe que pare de registrar é acusada,
porque lista mais curta que a árvore é o único modo de ela mentir. Medido em
2026-10-01: 231 ponteiros cobrados, sendo 1 `gratis`, 174 `prosa`, 4 `fora`, 45
`sem modelo` e 7 `morto`. O `sem modelo` é o número que diz que o teto de linha não
zerou por falta de frase: quarenta e cinco deles não têm âncora a oferecer enquanto
Dockerfile e nginx não tiverem modelo de declaração.

## Nota histórica: o harness multiplayer (P4)

Este parágrafo afirmava que `MultiplayerTests.gd` "dependia de `Parse Error`
pré-existente em `Network.gd`/`FSM.gd`" e que a causa raiz era o cache `.godot/`
nunca importado. As duas coisas eram falsas, medidas em 2026-09-24: `Network.gd`
e `FSM.gd` compilam, e `run_idle_tests.gd` roda verde há várias passadas. Os
erros eram de `MultiplayerTests.gd` contra a API real de `Network` —
`BulkCall(peerA, "Ping", [])` inverte a assinatura (`methodName, bulkedArgs,
peerID`) e devolve `void`; `NotifyNeighbours/NotifyInstance/NotifyArea` recebem
`BaseAgent`/`WorldInstance`/`WorldMap`, não inteiros. O arquivo não compilava
desde que essas assinaturas mudaram, e 4 dos 5 checks dele eram
`Check(true, "não crashou")`. Ele foi apagado: o único assert verdadeiro
(registro/identidade/desregistro de peer em `Peers`) foi portado para
`SuiteAuthHardening` em `IdleTests.gd`, e a cobertura real de rede é
`run_rpc_identity_test.gd` (transporte WebSocket de verdade) mais as suítes de
simulação que exercitam os callers de produção de `Notify*` (`BaseAgent`,
`PlayerAgent`, `NpcCommons`, `Inventory`). A fragmentação de `Network.gd` em
seis módulos autoload (P4) continua revertida; ver
`docs/development/architecture.md`.

## Escrevendo novos testes

- Use `Check(condition, label)`, `CheckEq(value, expected, label)`, `CheckNear(value, expected, tolerance, label)`
- Crie fixtures com cleanup explícito (DELETE no final)
- Use `Transaction()` para testes que modificam o banco
