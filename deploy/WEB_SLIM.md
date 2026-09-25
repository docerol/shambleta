# Payload web — medição e cortes (SOM-IDLE, etapa 2)

Primeiro load do cliente web em **gzip** (o que o navegador baixa). Medido com
export headless real (`godot --export-release "Web"`, template 4.7.stable) em
2026-09, comparando artefatos `gzip -9`.

## Antes

| Artefato | raw | gzip |
|---|---|---|
| `index.pck` | 62 MB | 46.3 MB |
| `index.side.wasm` (engine, threads/DLink) | 42 MB | 10.0 MB |
| `index.wasm` (stub loader) | 1.6 MB | 0.6 MB |
| `libgdsqlite…wasm` | 2.4 MB | 0.7 MB |
| `libsentry…wasm` | 2.6 MB | 0.4 MB |
| **total first-load** | — | **≈ 57.9 MB** |

Bate com o `BETA_DEPLOY_REPORT §2` (57.8 MB).

## Corte aplicado — música fora do export Web

Diagnóstico: a trilha sonora está **desligada no build idle** — `Audio.Load()`
(único ponto que lê/toca um `.ogg`) não tem chamador; só `SetVolume` é usado.
Os 7 `.ogg` (26 MB) eram **peso morto no pck**. Exclusão só no preset **Web**
(desktop/mobile mantêm), removendo `data/music/*` **e** `presets/music/*` juntos
(presets referenciam os `.ogg`; remover os dois mantém o `DB` carregando limpo —
sem asserts). `Audio.gd` ficou tolerante a trilha ausente (log no lugar de
`assert(false)`) como cinto de segurança.

## Depois (export 4.7.stable, régua antiga — ver "Re-medição 2026-09-25" abaixo)

| Artefato | raw | gzip |
|---|---|---|
| `index.pck` | 36 MB | 20.7 MB |
| `index.side.wasm` | 42 MB | 10.0 MB |
| outros wasm (sqlite+sentry+stub) | 6.6 MB | 1.7 MB |
| **total first-load** | — | **≈ 32.4 MB** (−44%)** |

Sem erros/asserts de música no boot do export. `maps`/`press`/`docs` já eram
excluídos no preset Web antes disto. (Nota de 2026-09-25: esta frase só ficou verdadeira
depois do guard `FileSystem.DirExists` em `DB.Preload()`/`DB.Populate()` — antes dele o
console do navegador empilhava `File path "res://presets/music/" is not accessible` a cada
boot, medido em `scripts/qa_web.mjs`; a ausência de erro é verificada a cada export pelo
check `web: nenhum erro de console` do QA, verde em `/tmp/qa_web_3.log`.)

## Para chegar a <25 MB (follow-through — exige QA visual)

O piso sem mexer em arte é ~32 MB: `side.wasm` 10 MB (engine, fixo para o set de
features com threads+gdsqlite+webrtc) + `pck` 20.7 MB. Os ~7,4 MB restantes estão
no `data/graphics` (15 MB raw, sobretudo PNG de sprites/tiles, que quase não
comprime em gzip). Alavancas (cada uma precisa revisar o resultado no navegador):

- **Re-compressão de texturas p/ web**: forçar formatos compactados por GPU/ATF e
  lossless WebP no lugar de PNG no pipeline de import (per-texture `compress/*`);
  validar nitidez/paleta.
- **Pack de áudio opcional (patch `.pck`)** servido via HTTP e montado em runtime
  (`ProjectSettings.load_resource_pack` de um `audio.pck` baixado), caso a trilha
  volte a ser ligada — aí a música entra sem pesar no primeiro load. Requer
  `Cross-Origin-Resource-Policy` no host do `.pck` (o nginx já serve COOP/COEP).
- **Lazy/remote das artes não-criticas da zona 1** (mesma técnica do patch .pck).

Estas são escolhas de arte/pipeline com verificação visual — ficam como
handoff; o corte acima é o ganho grande, seguro e já medido.

## Re-medição 2026-09-25 — a régua estava mentindo e a meta perdeu a causa

Primeiro export local depois que o GitHub Actions morreu (sem créditos):
`scripts/export_web.sh`, Godot 4.7.2 + template dlink. **Primeiro load real:
36 MiB gzip (37.723.399 bytes, 18 arquivos)** — engine 12 MiB, `.pck` 21 MiB,
shell 3 MiB. Três correções de medição, todas medidas antes de escrever número:

| O que a régua antiga dizia | O que é | Medido |
|---|---|---|
| "~32 MB first-load" | lista lembrada de arquivos (`.pck`, `.js`, `.wasm`) que **não** contava `index.png` — o splash que o próprio shell baixa em `<img id="status-splash" src="index.png">` (build/Web/index.html:149) | +2.507.842 B que o navegador paga e a régua não via |
| — | `.pck` trazia `graphify-out/` (7,1 MB de artefatos de análise) e a saída de exports anteriores (`binary/`, `build/`) re-importada como recurso do jogo | `index.pck` gzip 24.947 → 21.845 KB (−3,0 MiB) com `exclude_filter` + `.gdignore` no preset Web |
| GDExtension fora da conta | glob expandido no diretório errado no job da CI, `continue` engolia a ausência | `libgdsqlite` 0,7 MiB + `libsentry` 0,4 MiB agora entram |

**Sobre os 25 MB.** A meta não é nossa e a causa dela já foi executada. Origem: a
linha **P1** do plano de auditoria comercial que a gerou —

> `| P1 | Web build ~32MB gzip (meta <25MB) | Alta | Implementar streaming de música (`data/music/`) via PWA cache ao invés de embed no `.pck` |`

com o culpado nomeado na própria linha: música embutida no `.pck`, os 26 MB
cortados acima. O arquivo de origem (`.kilo/plans/1789659178562-audit-commercial-launch.md:39`)
foi **removido do repositório pelo dono em 2026-09-25** (".kilo só tinha lixo");
a citação fica registrada aqui porque foi daqui que o número veio, e quem
precisar do contexto completo lê `git show HEAD:.kilo/plans/1789659178562-audit-commercial-launch.md`.
O `::aviso::` do script virou `::nota::`: **não existe limite técnico de tamanho
para abrir ou instalar** um web app (sem cota de instalação por peso em
Chrome/Android nem iOS; o que o navegador exige para instalar é HTTPS + manifest
com ícone/`display` + service worker, e isso o preset já emite), e nenhuma
consequência de estourar os 25 MB está escrita em `deploy/`. Continuar com 25 MB
como número de portão seria escolher uma meta que só se alcança mexendo em arte —
que é exatamente o handoff abaixo.

**O maior item único que sobrou é uma imagem de boot, três vezes.** Medido em
gzip: `.godot/imported/splashscreen.png-….ctex` 2.507.947 B dentro do `.pck` +
cópia raw `data/press/splash/splashscreen.png` 2.507.528 B dentro do `.pck` (o
empacotador traz o arquivo apontado por `application/boot_splash/image`, e no Web
quem aparece na tela é `index.png`, o arquivo separado) + `index.png` 2.507.842 B
baixado pelo shell = **7,5 MiB dos 36 MiB (21%) para 1920×1080 de splash**.
Das três cópias, a removível sem tocar em arte é a raw dentro do `.pck`; se ela é
de fato morta no Web é verificação de boot no navegador, não suposição — e a
redução da imagem em si (o `.ctex` é quase do mesmo tamanho do PNG de origem,
2.507.489 B, ou seja: a arte não comprime) é decisão de arte com QA visual.
