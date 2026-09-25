# Runbook de deploy — Coolify (beta fechado web)

Stack: 3 serviços em `deploy/docker-compose.yml` — `web` (client Godot Web +
nginx), `game` (server headless Godot, WebSocket plain :6108), `companion`
(webhooks de pagamento → `grant_queue`).

```
Browser ──wss 443──▶ Coolify proxy (TLS) ──ws──▶ game:6108
Browser ──https 443─▶ Coolify proxy (TLS) ──80──▶ web (nginx, COOP/COEP)
Mercado Pago / Stripe / Pix sandbox ──webhook──▶ companion:8901 ──SQLite WAL──▶ live.db ◀── game
```

## 1. Pré-requisitos

- Coolify ≥ 4.x com proxy Traefik ativo.
- Dois domínios (ou subdomínios) apontando para o servidor:
  `seudominio.com` (client web) e `ws.seudominio.com` (WebSocket do jogo).
- Um segredo para webhooks: `openssl rand -hex 32`.

## 2. TLS (segurança da camada de transporte)

### Modo recomendado: Proxy TLS (Coolify)

O Coolify/Traefik termina o TLS na borda. O game server binda WebSocket
plain em `:6108` — **não precisa de `server.crt`/`server.key`** no container.

No ambiente do compose, defina:
- `SHAMBLETA_PROXY_TLS=1`

O server loga:
```
[TLS] TLS terminated upstream (reverse proxy) — binding plain WebSocket
```

### Modo alternativo: TLS direto

Se o game server exposto diretamente (sem proxy), gere certificados:

```bash
# Gera self-signed para dev/test
./tools/provision_tls.sh --self-signed --domain ws.seudominio.com

# Ou use Let's Encrypt (produção)
sudo certbot certonly --standalone -d ws.seudominio.com
sudo cp /etc/letsencrypt/live/ws.seudominio.com/fullchain.pem \
  /data/.local/share/Shambleta/server.crt
sudo cp /etc/letsencrypt/live/ws.seudominio.com/privkey.pem \
  /data/.local/share/Shambleta/server.key
```

Monte no compose:
```yaml
volumes:
  - ./certs:/data/.local/share/Shambleta
```

**Hard-stop**: se `SHAMBLETA_PROXY_TLS` não estiver setado e os certificados
`user://server.crt`/`user://server.key` não existirem, o server recusa o bind
e loga `FATAL: missing user://server.crt/user://server.key — refusing insecure
public bind`. Veja `deploy/TLS.md` para o guia completo.

## 2. Criar o projeto

1. New Resource → **Docker Compose** → aponte para o repositório (branch
   `master`), compose path: `deploy/docker-compose.yml`.
 2. No ambiente do compose, defina:
    - `SHAMBLETA_PROXY_TLS` = `1` (padrão para Coolify). Quando setado, o proxy
      do Coolify termina o TLS e o game server binda WebSocket plain. **Não**
      precisa de certificados no container do game.
    - `SHAMBLETA_WEBHOOK_PROVIDER` = `mercadopago` (padrão, produção), `stripe`
      (alternativa) ou `shared` (só sandbox). O companion é **fail-closed**: com
      `mercadopago` exige `SHAMBLETA_MP_WEBHOOK_SECRET`; com `stripe` exige
      `SHAMBLETA_STRIPE_WEBHOOK_SECRET` (`whsec_...`); com `shared` exige
      `SHAMBLETA_WEBHOOK_SECRET` **e** `SHAMBLETA_ALLOW_DEV_WEBHOOK=1` (este último
      nunca ligado enquanto houver dinheiro real).
   - `SHAMBLETA_MP_WEBHOOK_SECRET` = a **credencial/secret** que você cadastra no
     endpoint de webhook do painel do Mercado Pago (o MP usa esse segredo para
     assinar o header `x-signature`). Antes do onboarding do MP estiver pronto,
     suba em modo sandbox (`shared`) só para smoke-test.
   - `SHAMBLETA_MP_ACCESS_TOKEN` = access_token privado do MP. Quando presente, o
     companion **re-busca o pagamento** na API do MP (autoritativo: status
     `approved` + `external_reference="<account_id>:<sku>"`). Sem ele, só o corpo
     plano é aceito (sandbox/teste) — em produção **configure o token**.
   - `SHAMBLETA_STRIPE_WEBHOOK_SECRET` = `whsec_...` (só se usar provider=stripe).
   - `SHAMBLETA_WEBHOOK_SECRET` = segredo HMAC do modo sandbox (`openssl rand -hex 32`).
   - `SHAMBLETA_MP_BACK_URLS_BASE` = a origem pública do jogo (`https://seudominio.com`).
     É o que faz a preferência mandar o jogador de volta para
     `deploy/web/checkout_return.html` depois de pagar. Vazio funciona (o grant chega
     pelo webhook de qualquer forma), mas o jogador fica preso na página do MP.
   - `SHAMBLETA_CATALOG_FILE` = só para apontar um JSON **diferente**: a imagem do
     companion já carrega o catálogo canônico do repositório
     (`data/conf/paid_catalog.json`, copiado para `/app/paid_catalog.json`), que é a
     mesma fonte que o jogo valida no boot. Vazio sem o arquivo no caminho → cai no
     `DEFAULT_CATALOG` embutido (sandbox). O valor concedido vem do catálogo, nunca
     do corpo do webhook.
   - `SHAMBLETA_SERVER_ADDRESS` = `ws.seudominio.com` — **atenção: é valor de BUILD do
     serviço `web`, não de runtime.** O Dockerfile do web faz `sed` em
     `data/conf/settings.cfg` com este ARG e o resultado vai horneado dentro do pck;
     o container final é nginx puro, que não lê variável de ambiente alguma. O
     compose base consome `${SHAMBLETA_SERVER_ADDRESS:-}` em `web.build.args`, então
     pelo Coolify funciona — mas mudar aqui exige **rebuild** do `web`, e o endereço
     tem que ser o do proxy de WebSocket (§3: `ws.…` → `game:6108`), nunca o domínio
     do próprio site: no browser o client monta `wss://<Server-Address>` sem porta
     (`sources/network/client/Client.gd`), e o nginx do `web` não faz upgrade — no
     outro caso o handshake recebe o `index.html`. A suíte amarra isto nos dois
     arquivos de deploy (`SuiteDeployMode`).
   - `SHAMBLETA_OFFSITE_BACKUPS` = vazio (ou caminho de montagem offsite).
   - `SHAMBLETA_AD_STUB` = já vem `"1"` no `deploy/docker-compose.yml` (game).
     Rewarded ads do beta rodam no token stub, que é mintável pelo client; o
     servidor é **fechado por default** e só credita com esta env. Ao plugar o
     SDK real com verificação no servidor (SSV), **apague a linha** — sem ela
     nenhum `stub:*` credita. `SHAMBLETA_AD_PROVIDER` (`stub`|`portal`) é do
     client e não muda a regra do servidor.
   - `SHAMBLETA_AH_BOTS` = trava de feature, desligada no beta (bots de AH só em
     staging/soft-launch; o beta aposta no mercado entre jogadores reais).
   - `SHAMBLETA_ENABLE_SEASONS` = **ligada no beta** — já vem `"1"` no
     `deploy/docker-compose.yml` (game). O espinho sazonal é a decisão G1 do
     beta: com a env posta, o job diário abre a temporada de 30 dias com regras
     congeladas, fecha a vencida e liquida os prêmios em gems; sem ela, Season
     Pass e placar de temporada ficam vazios e o shell continua no ar.
3. Domínios por serviço (aba Domains):
   - `web` → `https://seudominio.com` (porta 80 do container).
   - `game` → `https://ws.seudominio.com` (porta **6108** do container). O
     proxy termina o TLS e encaminha ws plain — o server roda com
     `SHAMBLETA_PROXY_TLS=1` (já no compose) e por isso aceita bind sem cert.
   - `companion` → **sem domínio próprio, e sem porta publicada**: ele só escuta na
     rede interna do compose. A entrada dele é o domínio do `web`, que faz proxy de
     `/checkout/` (o client do browser) e `/webhooks/payments` (o provedor) para
     `companion:8901` — ver `deploy/web/nginx.conf`. Portanto a URL que você registra
     no painel do Mercado Pago é **`https://seudominio.com/webhooks/payments`**, e
     nada precisa saber do hostname `companion`.
4. Volumes: o compose já declara `game-data:/data` (live.db + backups). Garanta
   que o Coolify o trate como volume persistente (não remova em redeploys).
5. Deploy. O build do `web` leva vários minutos (import + export Godot).

## 3. Credenciais do game server (e-mail)

O server lê `user://credential.cfg` = `/data/.local/share/Shambleta/credential.cfg`
(`HOME=/data` no container). Sem esse arquivo o server sobe normalmente, mas
reset de senha não envia e-mail.

1. Coolify → serviço `game` → **Persistent Storage / File Config**: crie um
   arquivo montado no caminho acima com o conteúdo:

   ```ini
   [Email]
   Email-ApiKey="<brevo api key>"
   Email-SenderName="Shambleta"
   Email-SenderAddress="noreply@seudominio.com"
   ```

2. Restart no serviço `game`.

> O `credential.cfg` do **client web** é gravado pelo build (só seção
> `[Network]`, sem segredos) — nunca coloque chaves de API no settings.cfg
> do repositório.

## 4. Smoke test pós-deploy

1. `https://seudominio.com` abre o jogo (splash → login). No DevTools,
   confirme headers: `Cross-Origin-Opener-Policy: same-origin` e
   `Cross-Origin-Embedder-Policy: require-corp` no HTML **e** nos .wasm/.pck
   (sem COOP/COEP o browser bloqueia SharedArrayBuffer e o jogo não sobe).
2. Crie conta no client → deve entrar e auto-farmar zona 1.
3. `curl https://ws.seudominio.com` deve responder (upgrade de WS recusado em
   HTTP "puro" é esperado; o que importa é o handshake do jogo).
4. Antes do corpo assinado, prove que a rota de entrada existe — o companion não
   tem porta publicada, então quem responde é o proxy do `web`. Um `POST` em
   `/checkout/intents` sem token deve devolver **JSON** do companion (`401`,
   `missing auth_token`); se vier o 404 em HTML do nginx, o proxy não está no ar e
   nenhuma compra começa:
   ```bash
   curl -i -X POST https://seudominio.com/checkout/intents \
     -H 'Content-Type: application/json' -d '{"sku":"gems.550"}'
   ```
5. Webhook de teste (só faz sentido em modo sandbox `shared`; agora o corpo
   referencia um **SKU** — o valor vem do catálogo, não do corpo):
   ```bash
   BODY='{"idempotency_key":"smoke1","username":"SeuNick","sku":"gems.550"}'
   SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SHAMBLETA_WEBHOOK_SECRET" | awk '{print $2}')
   curl -X POST https://seudominio.com/webhooks/payments -H "X-Signature: $SIG" -d "$BODY"
   ```
   Em produção (`provider=mercadopago`) o MP envia `x-signature: ts=...,v1=...` (HMAC sobre `id:<data.id>;request-id:<x-request-id>;ts:<ts>;`); o companion valida com anti-replay e **re-busca o pagamento** na API do MP (`external_reference="<account_id>:<sku>"`, concede só se `status=approved`) — o **amount vem do catálogo**, nunca do corpo. (Em `provider=stripe`, o `checkout.session.completed` traz `metadata.shambleta_sku` + `client_reference_id=<account_id>`.)
   O saldo aparece no jogo com `/gems` (o server consome a fila a cada poucos
   segundos). `/health` e `/metrics` do companion ficam na rede interna —
   consulte via `docker compose exec companion wget -qO- localhost:8901/metrics`
   ou exponha atrás de auth se precisar.

## 5. Operação

| Tarefa | Como |
|---|---|
| Backup | Automático: diário local em `/data/.../sql-backups/daily/` + offsite (se configurado) com **restore probe** embutido. |
| Reconciliação | Diária pós-backup (`RunReconcileJob`); divergências aparecem em `/metrics` → `reconcile.divergences`. |
| Wipe de progresso (pré-beta) | migration `014_reset_progress_idle` ou reset do volume `game-data` antes dos convites. |
| Logs do server | Logs do container `game` (Util.PrintLog vai ao stdout). |
| Atualizar jogo | Push no branch → rebuild (client web é imutável por build; o server ignora clientes com protocol version diferente — força refresh). |

## 6. Limitações conhecidas (beta)

- **Peso do primeiro load**: **36 MiB gzip** medidos no export local de
  2026-09-25 (`scripts/export_web.sh`, Godot 4.7.2, template dlink): engine
  12 MiB (`index.side.wasm` 10,0 + `index.wasm` 0,6 + `libgdsqlite` 0,7 +
  `libsentry` 0,4 + `index.js` 0,4 + `sentry-bundle.js` 0,03), `.pck` 21 MiB,
  shell 2,7 MiB (o splash `index.png` sozinho é 2,4). A **meta de <25 MB perdeu a
  causa**: ela nasceu com um culpado nomeado — `data/music` (26 MB embutidos no
  pck) — e esse corte já foi executado (`deploy/WEB_SLIM.md`, −44%; a música saiu
  do preset Web). Não existe limite técnico de tamanho para instalar/abrir o
  build no navegador, então 25 MB passa a ser meta de pipeline de arte pós-beta
  (re-compressão de texturas, exige QA visual — WEB_SLIM §"Para chegar a <25 MB"),
  não portão de lançamento. O que vale para o beta é o aviso: **~36 MiB** de
  download na primeira visita, avise os testers.
- **SQLite compartilhado game+companion** só é válido em single-node (é o
  desenho do companion v0). Multi-node/CCU alto → Postgres (ARCHITECTURE §15).
- `ws.seudominio.com` publica o WebSocket do jogo **atrás do proxy**; nunca
  abra a 6108 do container na internet.
