# Branding — Shambleta

**Decisão:** o jogo se chamará **Shambleta** (era "Source of Mana", fork de
`docerol/sourceofmana`).

## Fase 1 — rebranding funcional (implementada)

Tudo que identifica o jogo para jogadores, builds e infraestrutura:

| Local | Antes | Depois |
|---|---|---|
| `project.godot` `config/name` | `Source of Mana` | `Shambleta` |
| `project.godot` `custom_user_dir_name` | `SourceOfMana` | `Shambleta` (data dir do jogador/DB) |
| `LauncherCommons.ProjectName` | `Source of Mana` | `Shambleta` |
| `Gui.gd` welcome boxes | `Welcome to Source of Mana!` | `Welcome to Shambleta!` |
| `EmailService.gd` senderName | `Source of Mana` | `Shambleta` |
| `data/db/news.json` (títulos/corpo) | `Source of Mana` | `Shambleta` |
| `data/db/agreement.json` (ToS) | `Source of Mana` | `Shambleta` |
| `export_presets.cfg` | product/package/path names | `Shambleta`, ids `com.shambleta.game` |
| CI (`godot-ci.yml`, `release.yml`, `package-builds`) | `EXPORT_NAME`/artefatos | `Shambleta` |
| `README.md` / `CONTRIBUTING.md` | título e intro | Shambleta com crédito ao upstream |

## O que NÃO muda (decisões conscientes)

1. **Atribuição upstream (obrigação de licença):** `LICENSE.md`, linhas de copyright em
   `data/db/credits.json` (Mana World / Evol Online / Manasource contributors) e links de
   organização permanecem intactos.
2. **Lore:** "a Source of Mana" como *item/mistério* dentro do mundo de Aemil
   (ex.: `ManaTree.gd`, menção no news de lançamento) é narrativa, não marca — permanece.
3. **Servidores:** `som.manasource.org` (`NetworkCommons`) é infraestrutura upstream real;
   trocar endereço é decisão de deploy, não de marca.
4. **Links comunitários** (Discord/IRC nos JSONs) apontam para o upstream — manter até
   existirem canais próprios do Shambleta.

## Fase 2 — pendências (arte e identidade)

**Resultado da varredura (sem gerar assets):**

- ✅ **Logos/ícones preservados 100%** — `logo_seed.svg` (ícone do jogo/janela), `logo_colored.svg/.ico`,
  `logo_bw.svg`, `appstore.png`, `playstore.png`, `data/press/logo/android/` (mipmaps) e
  `Assets.xcassets/` (iOS) são gráficos **sem texto embutido** (verificado no XML dos SVGs) —
  brand-neutrais, reutilizados como identidade visual do Shambleta sem nenhuma geração.
- ✅ **Snap rebrandado** — `snapcraft.yaml` (name: shambleta, paths `usr/share/shambleta`,
  binário `Shambleta.x86_64` coerente com o export preset) + `snap/gui/shambleta.desktop`.
- ✅ **Áudio preservado** — metadata `ALBUM: The Mana World` nos OGGs é atribuição do
  artista/comunidade, mantida (nenhum arquivo tocado).
- ✅ **Headers de copyright** nos addons (`tiled_importer`) preservados (obrigação de licença).
- ℹ️ **Posts históricos de news** (0.0.1/0.0.2) mantidos como registro histórico.

**Restante (não-asset / decisão externa):**

- [ ] Renomear `docerol/sourceofmana` → `shambleta` no GitHub (UI web) + links de arte
      (`sourceofmana/artdesign`) quando os repos forem renomeados.
- [ ] Revisão jurídica do `agreement.json` (entidade responsável, jurisdição, canais).
- [ ] Canais próprios (Discord/IRC/site) para substituir os links herdados.
- [x] ~~Verificação visual~~ **confirmado (sem nome desenhado)**: `data/press/readme/header.png`,
      `appstore.png` e `playstore.png` não contêm o nome antigo no raster — **rebranding de
      assets concluído com zero geração de imagens**.
