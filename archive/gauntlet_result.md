# Resultado do Gauntlet Loop — Shambleta Beta Comercial

Bar: Old School RuneScape (https://oldschool.runescape.com)

Métrica: FPS 60 | Load < 3s | 30min zero crash | Comerciais end-to-end

## Resultado Cego (7 peças avaliadas)

Todas as 7 peças foram comparadas cegamente contra OSRS. Nenhuma peça do Shambleta venceu.

| Peça | Vencedor | Lacuna Principal | Ação Recomendada |
|---|---|---|---|
| Loop de jogo | OSRS | Interação estratégica contínua; feedback visual do combate | Implementado híbrido (`Gui.gd` `AddManualSkillButtons` + `IdlePolicy` fallback); falta melhorar interação tática contínua. |
| Economia | OSRS | Falta UI visual do leilão integrada ao gameplay | Criar uma janela de leilão gráfica (como Grand Exchange) integrada ao HUD, com busca e filtros visuais. |
| Guildas | OSRS | Falta interface visual de guilda e interação social contínua | Desenvolver uma tela de guilda com informações visuais, chat de guilda integrado e eventos colaborativos. |
| UI e gráficos | OSRS | HUD herdado de MMO (20+ janelas) não simplificado para idle; onboarding parcial; touch não otimizado | Implementar `ToggleIdleMode()` com janelas essenciais (≤8), completar highlights de onboarding (`Onboarding.gd`), simplificar settings para mobile/web e adicionar layout responsivo. |
| Performance | OSRS | SQLite single-node, profiling stub, sem sharding | Implementar profiling de produção (`Monitoring.gd` com spans), avaliar sharding por zona e otimizar benchmarks de settle/XP/catalog. |
| Comerciais | OSRS | Checkout real (Mercado Pago/Stripe) ainda planejado; shop UI parcial | Implementar integração de pagamento real com gateway (companion + webhook + catálogo SKU), completar UI de checkout e ativar temporadas após lançamento. |
| Rede/Servidor | OSRS | Infra documentada mas não confirmada em produção; webhooks em sandbox; TLS via proxy não testado diretamente | Testar deploy em ambiente de staging (Coolify) com TLS direto, validar webhooks de pagamento em sandbox e confirmar estabilidade em sessão de 30min contínua. |

## Métrica Mensurável — Estado Atual

- FPS 60: Não confirmado (sem profiling de produção).
- Load inicial < 3s: Não medido em ambiente de produção.
- 30min zero crash: Não confirmado (sem ambiente estável de produção).
- Comerciais end-to-end: Não confirmado (checkout planejado, webhooks em sandbox).

## Próximos Passos (antes do beta comercial)

1. **UI/UX Polimento** — Prioridade alta. Simplificar HUD para idle, completar onboarding, otimizar mobile/web (`plano-ui-ux.md`).
2. **Checkout Real** — Prioridade alta. Implementar gateway de pagamento (Mercado Pago ou Stripe) com companion, catálogo SKU e webhook assinado (`deploy/COOLIFY.md`).
3. **Performance** — Prioridade média. Ativar profiling (`Monitoring.gd`), validar benchmarks e considerar sharding (`FEATURE_MATRIX.md` §10).
4. **Estabilidade** — Prioridade alta. Configurar ambiente de staging, testar TLS direto, validar backup/offsite e rodar sessão contínua de 30min.
5. **Loop de Jogo** — Prioridade média. Melhorar interação estratégica e feedback visual (comparação com OSRS mostra que o jogador precisa sentir que está no controle, mesmo no modo idle).

## Conclusão do Loop

O jogo não vence a barra (OSRS) em nenhuma peça. Isso não significa que o jogo não é bom — significa que, para um lançamento beta comercial, ainda há lacunas críticas (UI polida, pagamento real, estabilidade de produção) que precisam ser fechadas antes de competir com um RPG online estabelecido.

O loop deve continuar até que pelo menos as peças de UI/UX, Comerciais e Rede/Servidor vençam cegamente. As outras peças podem ser melhoradas em paralelo.

Fan out subagents: um subagente para UI/UX (`plano-ui-ux.md`), outro para Comerciais (`EconomyService.gd` checkout), outro para Rede/Servidor (`deploy/COOLIFY.md`), outro para Performance (`tests/benchmarks.gd`).
