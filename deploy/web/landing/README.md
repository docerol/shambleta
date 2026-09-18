# Shambleta — Landing modelo D (página de entrada + jogo Godot)

Modelo escolhido: **D — landing custom + jogo Godot Web embutido/redirecionado**.
Não é um SPA (não adiciona framework JS desnecessário); é uma página HTML estática
que serve como portal antes do `index.html` do Godot.

## Seções implementadas (ver `deploy/web/landing/index.html`)

| Seção | Conteúdo | Propósito |
|---|---|---|
| Hero | Título, descrição, botões "Entrar no jogo", "Guia", "Propostas" | Portal de entrada |
| Info (`#info`) | O que é o jogo, arquitetura (Godot 4, server headless, companion), dados técnicos | Transparência técnica |
| Guia (`#guia`) | 4 passos: Entre → Escolha zona → Colha offline → Progresso/temporada | Onboarding |
| DAO (`#dao`) | 3 propostas com botões "A favor / Contra" (stub — precisa de login no jogo) | Votação de melhorias |
| Footer | Créditos + VPS recomendada + meta de build | Referência técnica |

## Arquitetura na VPS Ampere A1 (2 vCPU, 12 GB RAM)

A stack atual (`deploy/docker-compose.yml`) já cabe com folga:

- `web` (nginx + Godot build): ~500 MB RAM, pouca CPU
- `game` (Godot headless): ~1 GB RAM, pouca CPU
- `companion` (Python webhook): ~200 MB RAM
- Folga: ~10 GB para picos e crescimento

A landing pode ser servida pelo mesmo `nginx` (`deploy/web/nginx.conf`) como uma
rota adicional (`location /landing/`) ou como a raiz (`/`) com o jogo redirecionado
para `/jogo/` (o `index.html` do Godot). Isso evita duplicar containers.

## Como rodar o jogo após o login

O usuário clica "Entrar no jogo" (link para `/index.html` — o Godot Web export).
O login é feito no próprio cliente Godot (o painel de login é parte do jogo).
Não há necessidade de um sistema de login externo — o `Server.gd` (`LoginWithPassword`)
valida credenciais via `Launcher.SQL`.

Se quiser uma separação mais clara (landing = `/`, jogo = `/jogo/`), basta:
1. Copiar `deploy/web/landing/index.html` para `deploy/web/nginx.conf` como `location / { ... }`
2. Mover o Godot build para `/usr/share/nginx/html/jogo/` e servir `/jogo/` como `location /jogo/ { alias ... }`
3. Atualizar o link do botão para `/jogo/index.html`

Isso é uma mudança de deploy (nginx), não de código. A VPS Ampere A1 comporta.
