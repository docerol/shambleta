# I18N PHASE 1 — pipeline de tradução pt-BR do cliente

Data: 2026-09-15 · Escopo: item 10 da auditoria comercial (fase 1 de 2; fase 2 = conteúdo NPC).

## Descoberta que define o pipeline

**Godot 4 não auto-traduz `Control.text`** vindo de cena ou código — verificado
empiricamente nesta 4.7 headless (`Label` com chave existente no CSV permaneceu
em inglês com `set_locale("pt_BR")` ativo; só `tr()`/`TranslationServer.translate`
resolvem). Um `Localizer.gd` próprio é obrigatório; nenhuma das ~140 chaves de
cena se traduziria sozinha.

## Componentes

1. **`tools/extract_i18n.py`** — extrator/gap: varre `tr()` em `sources/**/*.gd`,
   `text =` estático em .gd, `text/title =` em `presets/gui/**/*.tscn` (exclui
   mapas/sprites/partículas) e diálogos `Mes()/Say()` em `sources/scripts/`
   (domínio conteúdo), cruza com `data/i18n/ui.csv` e escreve
   `data/i18n/coverage_report.md`. Com `--write-gaps` gera pendências vazias p/ o
   tradutor. Conjunto `IDENTITY` documenta as chaves de identidade deliberada
   (símbolos, números, loanwords da comunidade BR: Mana/Slot/Gems:/Odds:/…).
2. **`sources/gui/Localizer.gd`** — pass periódico (1s) sobre a árvore do GUI
   (anexado em `Gui.gd._ready`, filho `I18N`): traduz `text`, `title` e
   `placeholder_text` de todo `Control`, guardando `[original, saída]` em
   meta. Idempotente; string dinâmica escrita pelo app (nome de player, "5
   gems") rebaseia e passa sem alteração (tr() de não-chave é identidade);
   troca de locale re-traduz do original guardado. Não cobre (residual
   documentado): itens de `OptionButton` e títulos de `TabContainer` (APIs de
   item, não propriedades) — fase 2.
3. **`data/i18n/ui.csv`** — lote de fase 1: 120 chaves pt-BR novas (tudo que a
   varredura achou na UI: personagem/status, settings, inventory, loja/baús/
   boss, chat/partia/guilda, login/recuperação, incluindo chaves com espaço
   líder que vêm das cenas). Cobertura pós-lote: **UI 174/174 (100%)**;
   conteúdo 730 pendentes (fase 2).

## Locale: resolução e pendência

`project.godot` já registra as traduções (`[internationalization]
locale/translations`, fallback `en`); sem override, o Godot usa o locale do SO
→ jogador BR com sistema em pt-BR vê GUI em português imediatamente. **Pendente
(decisão de UX)**: seletor explícito en/pt-BR na janela Settings gravando
override (`TranslationServer.set_locale` + cfg) — não feito aqui para manter o
commit dentro do pipeline; é trabalho de GUI, não de corpus.

## Testes (+6 na SuiteI18n existente, suíte 574→580)

Três traduções resolvendo por tipo de propriedade (label/button/placeholder),
idempotência do pass, rebase de texto dinâmico e re-tradução do stash na troca
de locale. O guard de tradução das strings de consentimento LGPD (fase anterior)
continua valendo.

## Validação

Suíte headless completa: **580 checks, 0 failures**, sem erros de script no boot (a pass do Localizer roda no GUI real do teste). Companion não é tocado.
