# Runbook de deploy — Coolify (beta fechado web)

Stack: 6 serviços em `deploy/docker-compose.yml` — `web` (client Godot Web +
nginx), `game` (server headless Godot, WebSocket plain :6108), `companion`
(webhooks de pagamento → `grant_queue`), `cloudflared` (túnel opcional; ele é um
serviço declarado, então um `docker compose up -d` sem removê-lo pede o token do
túnel), `prometheus` (scrapeia o `/metrics` do jogo — compartilha o namespace de
rede do `game` para alcançar o loopback 127.0.0.1:9400 — e avalia as regras de
alerta) e `alertmanager` (roteia esses alertas por severidade: page e ticket). A
contagem é conferida por `scripts/check_doc_drift.sh` contra o `services:`
do compose — não é número copiado de doc antiga.

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
plain na porta 6108 (`static var WebSocketPort` em `sources/network/NetworkCommons.gd:@WebSocketPort`)
— **não precisa de `server.crt`/`server.key`** no container.

No ambiente do compose, defina:
- `SHAMBLETA_PROXY_TLS=1`

O server loga (o grupo é `Server`, porque a linha é um `Util.PrintLog("Server", ...)`
chamado dentro do `func _enter_tree()` de `sources/network/server/Server.gd:@_enter_tree`
— o formato `[msec][Grupo]` vem do corpo de `PrintLog` (`sources/util/Util.gd:@PrintLog`);
um `grep '\[TLS\]'` no log volta vazio e você conclui que o modo proxy não pegou,
quando pegou):
```
[Server] TLS terminated upstream (reverse proxy) — binding plain WebSocket
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
   - `SHAMBLETA_OFFSITE_BACKUPS` = **deixe como o compose já define: `/data-backups`**
     (`deploy/docker-compose.yml`, `SHAMBLETA_OFFSITE_BACKUPS: ${...:-/data-backups}`).
     **Não** se põe vazio: vazio desliga o push inteiro — `PushOffsite()` sai na
     primeira linha (`sources/sql/SQLBackups.gd:@PushOffsite`) porque
     `GetOffsiteBackupPath()` devolve `""` (`sources/sql/SQLCommons.gd:@GetOffsiteBackupPath`) — e o gate
     `scripts/check_compose.sh` recusa compose com este valor diferente de
     `/data-backups`, porque o `/data-backups` do default é justamente o mount do
     volume `game-backups`. Só troque quando houver montagem offsite real (NFS /
     S3-fuse) no serviço `game`, e aponte a env para ela.
   - `SHAMBLETA_AD_STUB` = **não vai no compose** (C2, auditoria 2026-09-24). É o
     interruptor do servidor para "acredito na afirmação de exibição do client":
     ligado, `MintAdSlot` passa a reservar a cota do placement e devolver o nonce
     de uso único; desligado (o default, e o de produção), nenhum placement
     credita e o botão recebe `Ad rejected: ad_source`. O beta que quiser ads
     antes do SSV do portal liga esta env **no painel**, sabendo que o teto do
     abuso é a cota (12 horas, 1 baú, 2 chaves, 3 rerolls por conta/dia) e não
     uma verificação. `SHAMBLETA_AD_PROVIDER` (`stub`|`portal`) é do client e não
     muda a regra do servidor.
   - `SHAMBLETA_AH_BOTS` = trava de feature, desligada no beta (bots de AH só em
     staging/soft-launch; o beta aposta no mercado entre jogadores reais).
   - `SHAMBLETA_ENABLE_SEASONS` = **ligada no beta** — já vem `"1"` no
     `deploy/docker-compose.yml` (game). O espinho sazonal é a decisão G1 do
     beta: com a env posta, o job diário abre a temporada de 30 dias com regras
     congeladas, fecha a vencida e liquida os prêmios em gems; sem ela, Season
     Pass e placar de temporada ficam vazios e o shell continua no ar.
   - `SHAMBLETA_TAG` = **o knob do rollback** (não é env do jogo: é variável de
     interpolação do compose, lida em cada invocação). É o que nomeia a imagem
     que o `build:` produz — `image: shambleta/game:${SHAMBLETA_TAG:-local-unpinned}`
     e os outros quatro serviços buildados. Posta no ambiente do recurso com o
     sha curto que você está deployando, cada deploy ganha um alvo nomeado e o
     §7 deixa de depender exclusivamente do histórico do painel. Sem ela, os
     cinco serviços resolvem para `local-unpinned`: o stack sobe igual, mas não
     existe "a versão anterior" para nomear no compose — ver
     `deploy/ROLLBACK.md`, "Artefato versionado". **Ponha um valor fixo aqui e
     deixe o auto-deploy no push ligado é o mesmo defeito do tag `latest`:** todo
     push reescreve a mesma etiqueta e não sobra nada para voltar.
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
   `{"error": "missing_token"}` — é a string que o companion devolve, não uma
   frase legível; ver `Handler._resolve_checkout_account` (`companion/server.py:@Handler._resolve_checkout_account`);
   se vier o 404 em HTML do nginx, o proxy não está no ar e
   nenhuma compra começa:
   ```bash
   curl -i -X POST https://seudominio.com/checkout/intents \
     -H 'Content-Type: application/json' -d '{"sku":"gems.550"}'
   ```
   A mesma prova vale para a leitura de preço: `GET /catalog` é a ÚNICA rota
   pública que TOCA o banco do jogo, e é dela que a vitrine sabe qual passe a
   temporada em vigor vende. Sem proxy → 404 em HTML do nginx; com proxy mas sem
   companion → o `location` devolve 502. O veredito de temporada tem de aparecer
   no corpo, para cada `pass_premium`, com preço intacto:
   ```bash
   curl -s https://seudominio.com/catalog | grep -o 'season_eligible' | wc -l
   ```
   Número esperado = quantidade de passes do catálogo (`data/conf/paid_catalog.json`);
   zero ou 404 aqui = a loja está oferecendo um SKU que o checkout pode recusar.
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
| Backup | Automático: diário local em `/data/.../sql-backups/DAILY/` (o nome do diretório é a chave do enum `BackupFrequency` em `sources/sql/SQLCommons.gd:@BackupFrequency`, portanto MAIÚSCULO — construído em `CreateDailyBackup` (`sources/sql/SQLBackups.gd:@CreateDailyBackup`); `ls .../daily` devolve vazio mesmo com backups) + offsite em `SHAMBLETA_OFFSITE_BACKUPS` (default `/data-backups`) com **restore probe** embutido. |
| Reconciliação | Timer **próprio**, desacoplado do backup: `MetaJobIntervalSec` = 24 h (`sources/sql/SQLCommons.gd:@MetaJobIntervalSec`), disparado pela própria `Run()` (`sources/sql/SQLBackups.gd:@Run`) — o porquê do desacoplamento está no comentário `#28` logo acima do disparo; saiu do guard do backup de propósito (#28), porque disco cheio parava reconcile, copas, temporada, referral e tickets junto. Divergências aparecem no `/metrics` do companion → `reconcile.divergences`. |
| Wipe de progresso (pré-beta) | migration `014_reset_progress_idle` ou reset do volume `game-data` antes dos convites. |
| Logs do server | Logs do container `game` (Util.PrintLog vai ao stdout). |
| Atualizar jogo | Push no branch → rebuild (client web é imutável por build; o server ignora clientes com protocol version diferente — força refresh). |
| Voltar atrás | §7: `SHAMBLETA_TAG` no ambiente do recurso dá alvo de compose; sem ele, o rollback é o histórico do painel. A fronteira do schema (§7.3) vale nos dois caminhos. |

## 6. Limitações conhecidas (beta)

- **Peso do primeiro load**: **35 MiB gzip** (`36.734.788 B`, 18 arquivos) medidos
  no export local de 2026-09-26 (`scripts/export_web.sh`, template 4.7 dlink;
  `deploy/WEB_SLIM.md` §"Corte 2026-09-26") — engine 12 MiB + `.pck` 20 MiB + shell
  3 MiB, sendo o splash `index.png` sozinho ~2,4 MiB do shell. A janela anterior,
  2026-09-25, media **36 MiB** (`37.723.399 B`) e é a que aparece nas tabelas de
  "antes/depois" do WEB_SLIM — não são duas verdades: é o mesmo número uma
  medição depois do corte de `tests/` e dos logos de imprensa. A **meta de <25 MB
  perdeu a causa**: ela nasceu com um culpado nomeado — `data/music` (26 MB
  embutidos no pck) — e esse corte já foi executado (`deploy/WEB_SLIM.md`, −44%; a
  música saiu do preset Web). Não existe limite técnico de tamanho para
  instalar/abrir o build no navegador, então 25 MB passa a ser meta de pipeline de
  arte pós-beta (re-compressão de texturas, exige QA visual — WEB_SLIM §"Para
  chegar a <25 MB"), não portão de lançamento. O que vale para o beta é o aviso:
  **~35 MiB** de download na primeira visita, avise os testers.
- **SQLite compartilhado game+companion** só é válido em single-node (é o
  desenho do companion v0). Multi-node/CCU alto → Postgres (ARCHITECTURE §15).
- `ws.seudominio.com` publica o WebSocket do jogo **atrás do proxy**; nunca
  abra a 6108 do container na internet.

## 7. Rollback (voltar atrás)

O fluxo de deploy deste arquivo é "push no branch → rebuild" (§5). O rollback tem
de ser lido no mesmo eixo, e há exatamente dois caminhos — escolha **um** e registre
a escolha em `deploy/LAUNCH_HANDOFF.md`, porque os dois deixam evidências diferentes
no host.

### 7.1 Pelo histórico do próprio recurso (o caminho padrão do Coolify)

1. Abra o recurso Docker Compose → o serviço que ficou ruim (`game` é o caso comum).
2. No histórico de deployments do recurso, selecione o deployment anterior ao que
   quebrou e acione a reimplantação dele — o Coolify re-aponta para o artefato que ele
   mesmo buildou naquele deployment. Não há registry no meio (§2 do compose:
   `pull_policy: never` nos cinco serviços buildados), então quem tem a imagem é o
   host, e o painel é a única coisa que sabe qual deployment é qual.
3. Confira por fora, com o passo "Ver o que está no ar agora" de
   `deploy/ROLLBACK.md` — `docker inspect --format '{{.Config.Image}}'` no container
   do `game`. O que a UI diz é o que foi *pedido*; o `inspect` diz o que está
   *rodando*, e num deploy interrompido os dois não batem.

Os nomes exatos das telas e o comportamento de retenção de imagem do painel não foram
medidos nesta máquina — não há Coolify aqui **[NÃO MEDIDO]**. O que se exige do
operador é o resultado do passo 3, não a confiança na tela.

### 7.2 Pela tag do compose (quando você pisa `SHAMBLETA_TAG`)

Com o knob do §2 posto no ambiente do recurso, cada deploy ganha um nome, e a volta é
a do `deploy/ROLLBACK.md` — no host, com o repositório clonado:

```bash
docker images | grep '^shambleta/'                        # que tags este host guarda
export SHAMBLETA_TAG=<sha-anterior-da-lista>
docker compose -f deploy/docker-compose.yml up -d --no-build game web companion
```

O `--no-build` não é opcional aqui: sem ele, um tag que não está no host faz o compose
**reconstruir o fonte do branch** e subir o build que você acabou de rejeitar com a
etiqueta do que você queria. Com `pull_policy: never` + `--no-build`, o compose não pode
buildar nem puxar: ou usa aquela imagem, ou falha — e falha é a resposta correta.

Se você usa auto-deploy no push **e** um `SHAMBLETA_TAG` fixo no ambiente, os dois
caminhos se cancelam: todo push reescreve a mesma etiqueta e `docker images` mostra um
`shambleta/game:<mesmo-tag>` para sempre. Nesse estado o §7.2 não existe e o rollback é
100% o painel (§7.1). As três posturas honestas são: tag fixo + rollback pelo painel;
tag por release posta a cada deploy manual; ou deixar o knob de fora e assumir que os
serviços ficam em `local-unpinned`, sabendo que não há alvo de compose.

### 7.3 A fronteira: o binário volta, o schema não

Migração é forward-only e roda no boot do `game`. Um binário com menos patches do que a
versão gravada na base não rebaixa nada — ele recusa e loga
`SQL: <N> patches visíveis contra a base na versão <M> — binário mais velho que o
schema. Nada aplicado.`, e o chão do rollback passa a ser **o último build cujo número
de `data/conf/migrations/*.sql` é >= a versão do `live.db`**. O comando dos dois números
e as três saídas quando não há tal build (corrigir para a frente, restaurar backup com
perda, reparar o schema para cima) estão em `deploy/ROLLBACK.md`, "A fronteira do
schema". Redeploy pelo Coolify de um commit antigo **não** reescreve este fato: o painel
troca a imagem, não o volume `game-data`.

### 7.4 O que o rollback não apaga

* `docker compose down -v` num stack Coolify remove os volumes nomeados — `game-data`
  é o `live.db` e `game-backups` é o histórico. Reimplantar não traz de volta.
* Limpeza de imagem (`docker image prune -a`) no host remove os artefatos que o §7.2
  endereça. Se o painel tem sua própria política de retenção, confira antes de rodar
  poda "para liberar disco": o disco que você libera é o caminho de volta.
* O endereço do game server no client web é **de build** (`SHAMBLETA_SERVER_ADDRESS`,
  §2): voltar o `web` para um artefato antigo também volta o endereço antigo horneado
  no `.pck`. Se o incidente foi troca de domínio, o rollback do `web` sozinho não
  resolve — é rebuild com o ARG certo.

