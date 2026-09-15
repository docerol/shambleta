# som-idle-docs — Documentação canônica do pivô idle (Shambleta)

Índice dos documentos de contrato/arquitetura do repo. **Estes arquivos são a
fonte de verdade canônica**: o código e os testes citam suas seções
(ex.: `TECH_SPEC_CORE.md §2`, `XP_PROGRESSION.md §4.1.2`, `ARCHITECTURE §7`),
portanto mudanças de parâmetro devem atualizar o documento **no mesmo commit**
que muda o código (regra preamble de `TECH_SPEC_CORE.md`).

## Contratos de sistema (referenciados pelo código)

| Documento | Conteúdo |
|---|---|
| [TECH_SPEC_CORE.md](TECH_SPEC_CORE.md) | Contrato técnico: arquitetura dos serviços idle, spawns/respawn por zona (§2), relógio de tick D1 (§3), banda de pacing (§4), invariantes de items/ledger (§5), infra e escala (§11) |
| [XP_PROGRESSION.md](XP_PROGRESSION.md) | Curva de progressão: banda 30–200 kills/h (§4.1.1), fórmulas por zona (§4.1.2), boost de novato (§4.1.3), uso pelo OfflineSettle (§5) |
| [ECONOMY_STUDY.md](ECONOMY_STUDY.md) | Contrato de economia: moedas/ledger (§1), trade fee sink (§2), baús pity + provably-fair (§3), VIP (§4), liquidação offline (§5), boss economy (§6) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Arquitetura completa do pivô (componentes, RPCs, migrations, settle, guilds, trades, deploy web, escalabilidade) — citada por `WorldInstance.gd`/`EconomyService.gd` |
| [MONETIZATION.md](MONETIZATION.md) | Modelo de monetização Brasil (Pix, escada de conversão, mix de receita) — citada por `SQL.gd`/`OfflineSettle.gd`/`EconomyService.gd` |

## Design e planejamento

| Documento | Conteúdo |
|---|---|
| [ROADMAP.md](ROADMAP.md) | Gaps consolidados → fases e critérios de saída |
| [BATTLE_PASS_S1.md](BATTLE_PASS_S1.md) | Design do Passe da Temporada 1 |
| [BENCHMARK_AFK_HEROES.md](BENCHMARK_AFK_HEROES.md) | Benchmark de referência de produto |
| [BRANDING.md](BRANDING.md) | Decisões de marca/rebranding |
| [RELATORIO_AUDITORIA_sourceofmana.md](RELATORIO_AUDITORIA_sourceofmana.md) | Auditoria original do fork (09/09/2026, commit `48029cc`) — base dos gaps herdados |

## Relatórios de fase (histórico de decisões, versionado)

| Documento | Cobertura |
|---|---|
| [D1_GATE_REPORT.md](D1_GATE_REPORT.md) | Gate D1: forense do bug de dois relógios, normalização do tick, hotfixes produção (SyncWithDB, `_Attach`) |
| [LGPD_CONSENT_VERSION_REPORT.md](LGPD_CONSENT_VERSION_REPORT.md) | Gate de consentimento por versão + fluxo de re-aceite (`AcceptConsent`) |

## Onde está o resto

- **Relatórios de fases antigas** (F2 spike, F3, F4, beta deploy) e as
  **versões superseded** dos três contratos (pré-pivô/2026-09 antigos):
  arquivados fora do repo, em `shambleta/som-idle-docs/archive/`
  (não-versionados; o conteúdo vigente vive nos documentos canônicos acima).
- Docs de operação: `deploy/LAUNCH_HANDOFF.md`, `deploy/WEB_SLIM.md`,
  `deploy/COOLIFY.md`.
- Docs upstream do jogo (não-nossas): `docs/` na raiz do repo.

## Pontas soltas conhecidas (dangling references)

`TECH_SPEC_CORE.md §11`, `ECONOMY_STUDY.md §5` e `XP_PROGRESSION.md` citam uma
**"auditoria comercial" (`auditoria-shambleta-idle-comercial.md`) itens
11/13/15** — esse arquivo **não existe no repo nem no workspace** (a numeração
não bate com a auditoria real, que usa seções A–G). As afirmações citadas
(escala SQLite nó-único, anti-cheat de relógio/reconexão, validação do loop de
gear) estão inline nos próprios contratos, então nada se perde hoje; quando a
auditoria comercial for escrita, publicar em `som-idle-docs/` e os cites
fecham. Alternativa: renomear as referências para as seções equivalentes do
`RELATORIO_AUDITORIA_sourceofmana.md` — decisão pendente do dono do projeto.
