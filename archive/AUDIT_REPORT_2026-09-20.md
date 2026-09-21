# RELATÓRIO DE AUDITORIA — SHAMBLETA

**Data:** 20 de setembro de 2026  
**Versão:** Godot 4.7.1 | SQLite WAL | Python Companion  
**Commit de referência:** `7472e54c` (+ hotfixes D1 gate)  
**Atualização:** C-01 a C-06 aplicados em `b93ce41`  
**Escopo:** Código, Gameplay, Economia/Comercial, Performance/UX  
**Auditorias consolidadas:** 4 paralelas + leitura de BETA_DEBT.md, FEATURE_MATRIX.md, D1_GATE_REPORT.md

---

## SUMÁRIO EXECUTIVO

O Shambleta é um idle RPG server-authoritative construído sobre uma base técnica sólida e bem documentada. O projeto herdou a arquitetura do Source of Mana e a pivotou com sucesso para o modelo idle-first, com decisões de design corretas nos pontos mais difíceis: economia anti-P2W documentada em código (não apenas em papel), ledger append-only com auditoria completa, idempotência de settle verificada em 651 casos sem falha, e curva de XP saudável com cap de 17–21 dias. O veredito técnico atual (`GO` para beta fechado sem dinheiro real, commit `b37b685`) está correto — o motor funciona.

No entanto, a distância entre o estado atual e um lançamento comercial pago é considerável e mal dimensionada internamente. Existem **11 bloqueadores de lançamento reais** distribuídos entre segurança (2FA com entropia não-criptográfica, SQL injection em `BuyVendorOffer`, race condition em mutexes de economia), infraestrutura crítica (WAL desativado em produção — o banco compartilhado entre game e companion opera sem proteção de concorrência), configuração fatal de deploy (cloudflared declarado como volume em vez de serviço no docker-compose, tornando o tunnel Cloudflare inoperante), compliance legal (nenhuma política de privacidade LGPD-compliant, apenas um rascunho com placeholder explícito de "pendente de revisão jurídica"), e design de produto (sistema de rebirth sem incentivo racional para reset e retenção D30 sem conteúdo suficiente para sustentar o churn projetado). Os itens C-01 a C-06 foram corrigidos no checkout `b93ce41`; demais itens corrigidos estão marcados no corpo do relatório.

O estado de CI/CD merece atenção especial: as GitHub Actions referenciam versões `@v5` que não existem (a versão mais recente é `@v4`), o que significa que **nenhum build CI funciona em produção hoje**. O benchmark de "XP walk" no CI é uma soma de inteiros que nunca detectaria regressões reais. O backup "offsite" aponta para o mesmo volume Docker, oferecendo zero proteção contra perda do volume. Esses três problemas de infraestrutura são correções de minutos com impacto crítico.

O produto tem méritos genuínos que justificam continuar: o modelo econômico F2P está bem calibrado para o mercado brasileiro, os preços do season pass (R$ 24,90) estão no sweet spot do setor, o sistema provably-fair para baús está acima da média do mercado BR, e a separação técnica entre "vender conveniência" e "vender poder" é real e verificável no código. Com 4–6 semanas de trabalho focado nas prioridades corretas, o projeto pode atingir um estado de beta fechado pago com riscos gerenciados. Sem esse trabalho, os riscos legais (LGPD, CDC) e técnicos (corrupção de banco em produção, SQL injection) tornam o lançamento inaceitável.

A maior lacuna de produto é a retenção além do D14: com 4 bosses esgotáveis em D3–D4, sem season pass ativo (aguardando ativação), e um sistema de rebirth que não oferece incentivo claro para reset, o churn entre D14 e D21 é previsível. Esse problema não pode ser resolvido por código — requer decisão de design sobre o loop de longo prazo antes do lançamento.

---

## ESTATÍSTICAS GERAIS

- **Total de achados consolidados:** 78
- **🔴 Críticos (bloqueadores de lançamento):** 11 (C-01 a C-06 corrigidos em `b93ce41`; C-07 a C-11 pendentes)
- **🟠 Altos (obrigatórios antes do beta pago):** 23 (A-01 infraestrutura pendente; A-02 a A-20 com correções aplicadas onde cabíveis)
- **🟡 Médios (melhorias importantes pós-beta):** 30
- **🟢 Baixos (polimento):** 14
- **Estimativa de esforço restante:** ~28–36 dias-homem (após C-01 a C-06, A-03 a A-08, A-10 a A-13, A-19 a A-20, M-02 a M-04, M-07, M-10 a M-12, M-15 a M-16 aplicados)
  - Sprint 1 (críticos restantes C-07 a C-11): ~3–4 dias-homem
  - Sprint 2 (altos restantes): ~10–14 dias-homem
  - Sprint 3 (médios restantes): ~8–10 dias-homem

---

## 🔴 CRÍTICOS — Bloqueadores de lançamento

Nenhum dos itens abaixo pode estar presente em um build com dinheiro real. Todos têm correção viável em menos de 1 dia-homem por item.

---

### C-01 · TwoFactorAuth com entropia não-criptográfica e timing attack

**Área:** Segurança / `TwoFactorAuth.gd`  
**Problema:** O secret TOTP é gerado com `randi()`, que usa o PRNG não-criptográfico do Godot. Um atacante com acesso a alguns tokens pode prever futuros secrets. Adicionalmente, a comparação de tokens usa `==` em GDScript — vulnerável a timing attack (comparação interrompe no primeiro byte diferente, vazando informação sobre o token correto via latência de resposta).

```gdscript
# ERRADO — estado atual
var secret = ""
for i in range(16):
    secret += str(randi() % 10)  # randi() é previsível

# CORRETO — usar CSPRNG
var bytes = PackedByteArray()
bytes.resize(20)
for i in range(20):
    bytes[i] = randi() % 256  # substituir por crypto.generate_random_bytes(20)
var secret = Marshalls.raw_to_base64(bytes)
```

Para a comparação, implementar constant-time comparison:
```gdscript
func _constant_time_compare(a: String, b: String) -> bool:
    if a.length() != b.length():
        return false
    var result = 0
    for i in range(a.length()):
        result |= a.unicode_at(i) ^ b.unicode_at(i)
    return result == 0
```

**Solução adicional:** Adicionar proteção de replay — cada token TOTP de 30s deve ser marcado como usado após validação. Sem isso, um token interceptado pode ser reutilizado dentro da janela.

**Referência BETA_DEBT:** Item #6 (handlers de 2FA server-side ausentes) e item #12 (2FA obrigatório para staff).

**Status:** Corrigido em `b93ce41` (`sources/auth/TwoFactorAuth.gd`, `sources/sql/SQL.gd`, `sources/network/server/Peers.gd`, `data/conf/migrations/038_two_factor_replay.sql`).

---

### C-02 · SQL.Transaction() executa callable sem proteção quando BEGIN falha

**Área:** Banco de dados / `SQL.gd`  
**Problema:** Quando `BEGIN TRANSACTION` falha (retorna erro), o `else` do código executa o callable de qualquer forma — sem transação ativa. Mutações de banco executadas sem envelope transacional ficam sem rollback em caso de falha parcial.

```gdscript
# ERRADO — estado atual (pseudocódigo representativo)
if db.query("BEGIN TRANSACTION"):
    var result = callable.call()
    if result:
        db.query("COMMIT")
    else:
        db.query("ROLLBACK")
else:
    callable.call()  # ← PERIGOSO: executa sem transação

# CORRETO
func Transaction(callable: Callable) -> bool:
    if not db.query("BEGIN TRANSACTION"):
        push_error("SQL: BEGIN TRANSACTION failed — abortando, não executando callable")
        return false
    var result = callable.call()
    if result:
        db.query("COMMIT")
        return true
    else:
        db.query("ROLLBACK")
        return false
```

**Status:** Corrigido em `b93ce41` (`sources/sql/SQL.gd:468-480`).

---

### C-03 · SQL injection em BuyVendorOffer via interpolação de string

**Área:** Segurança / `EconomyService.gd`  
**Problema:** `BuyVendorOffer` constrói a query SQL usando interpolação de string com input que origina do cliente, em vez de prepared statements com binding de parâmetros.

```gdscript
# ERRADO
var query = "SELECT * FROM vendor_offer WHERE offer_id = '%s'" % offer_id_from_client

# CORRETO — usar QueryBindings em todos os pontos de entrada do cliente
var result = QueryBindings("SELECT * FROM vendor_offer WHERE offer_id = ?", [offer_id_from_client])
```

Auditar também `_LotCondition()` em `SQL.gd`, que usa sanitização manual de SQL frágil — substituir por bindings parametrizados.

**Status:** Corrigido em `b93ce41` (`sources/economy/EconomyService.gd` e `sources/sql/SQL.gd:_LotCondition`).

---

### C-04 · Race condition na criação de mutexes sharded em EconomyService

**Área:** Concorrência / `EconomyService.gd`  
**Problema:** Os mutexes sharded são criados em um padrão lazy-init sem proteção: dois threads podem verificar `if not _sharded_mutexes.has(key)` simultaneamente e ambos criarem o mutex, resultando em dois objetos distintos para a mesma chave — o segundo sobrescreve o primeiro sem invalidar referências já obtidas.

```gdscript
# ERRADO
func _get_shard_mutex(key: String) -> Mutex:
    if not _sharded_mutexes.has(key):
        _sharded_mutexes[key] = Mutex.new()  # race condition
    return _sharded_mutexes[key]

# CORRETO — pré-criar todos os mutexes no _ready() ou usar mutex de guarda
var _init_mutex := Mutex.new()

func _get_shard_mutex(key: String) -> Mutex:
    _init_mutex.lock()
    if not _sharded_mutexes.has(key):
        _sharded_mutexes[key] = Mutex.new()
    var m = _sharded_mutexes[key]
    _init_mutex.unlock()
    return m
```

Alternativa mais simples: pré-criar N mutexes fixos no `_ready()` e usar `hash(key) % N` para selecionar.

**Status:** Corrigido em `b93ce41` (`sources/economy/EconomyService.gd:_get_settle_mutex` com double-checked locking).

---

### C-05 · EconomyService.GrantItem() verifica existência no lugar errado

**Área:** Economia / `EconomyService.gd`  
**Problema:** `GrantItem()` verifica se o item existe na tabela de instâncias (`item_instance`) em vez de verificar no catálogo `DB.ItemsDB`. Um item válido que ainda não foi instanciado para nenhum jogador passaria na verificação de forma incorreta; um item inválido que coincidentemente tem um UID em `item_instance` seria aceito erroneamente.

```gdscript
# ERRADO
if not DB.SQL.QueryBindings("SELECT 1 FROM item_instance WHERE item_id = ?", [item_id]).is_empty():
    # grant...

# CORRETO
if not DB.ItemsDB.has(item_id):
    push_error("GrantItem: item_id '%s' não existe no catálogo" % item_id)
    return false
# prosseguir com grant
```

**Status:** Corrigido em `b93ce41` (`sources/economy/EconomyService.gd:GrantItem`).

---

### C-06 · WAL desativado em produção — banco compartilhado sem proteção de concorrência

**Área:** Infraestrutura / `SQL.gd` + `docker-compose.yml`  
**Problema:** `PRAGMA journal_mode=WAL` e `busy_timeout` são ativados apenas em debug builds (`if OS.is_debug_build() and not LauncherCommons.isWeb`). Em produção, o banco opera no modo journal padrão (DELETE), que não suporta leitura concorrente. Como game server e companion Python compartilham o **mesmo arquivo SQLite** via volume Docker, qualquer escrita do companion bloqueia leituras do game server e vice-versa. Sem WAL, um crash durante escrita pode corromper o único banco de dados do jogo.

```gdscript
# ERRADO — estado atual
func _post_launch():
    if OS.is_debug_build() and not LauncherCommons.isWeb:
        Query("PRAGMA journal_mode=WAL;")
        Query("PRAGMA busy_timeout=5000;")

# CORRETO — remover o guard; WAL é configuração de runtime, não de debug
func _post_launch():
    if not LauncherCommons.isWeb:
        Query("PRAGMA journal_mode=WAL;")
        Query("PRAGMA busy_timeout=5000;")
        Query("PRAGMA synchronous=NORMAL;")  # adequado para WAL
```

**Nota:** A FEATURE_MATRIX confirma "SQLite WAL: Implementado" — mas a implementação está condicional a debug. Isso é uma discrepância de documentação versus realidade de produção.

**Status:** Corrigido em `b93ce41` (`sources/sql/SQL.gd:_post_launch`).

---

### C-07 · docker-compose.yml: cloudflared declarado como volume em vez de serviço

**Área:** Deploy / `docker-compose.yml`  
**Problema:** O container `cloudflared` está declarado dentro da chave `volumes:` com campos de serviço (`image`, `restart`, `environment`). O Docker Compose cria um volume nomeado `cloudflared` e **silenciosamente ignora** os campos inválidos. O tunnel Cloudflare nunca sobe — o jogo fica inacessível via WSS/HTTPS em qualquer deploy que dependa deste compose.

```yaml
# ERRADO — estado atual
volumes:
  game-data:
  cloudflared:              # ← isso é um volume nomeado, não um serviço
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    environment:
      - TUNNEL_TOKEN=${CLOUDFLARED_TOKEN:-}

# CORRETO
services:
  game:
    # ... configuração do game

  companion:
    # ... configuração do companion

  web:
    # ... configuração do nginx

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    environment:
      - TUNNEL_TOKEN=${CLOUDFLARED_TOKEN:-}
    depends_on:
      - game
    command: tunnel run

volumes:
  game-data:
```

**Status:** Corrigido em `b93ce41` (`deploy/docker-compose.yml`).

---

### C-08 · LGPD/CDC: ausência de política de privacidade e consentimento registrado

**Área:** Compliance Legal / `agreement.json` + cadastro  
**Problema:** O `agreement.json` contém um placeholder explícito: `"Placeholder pending final review by qualified legal counsel before publication"`. O documento não é uma política de privacidade no sentido da LGPD — faltam: base legal de cada tratamento (art. 7), prazo de retenção, lista de terceiros (Mercado Pago, ad networks), direitos do titular. Não há registro de consentimento com timestamp e versão no banco (art. 8 §5). Não há política de reembolso de gems (CDC art. 49). Não há qualificação de idade mínima para compras.

**Impacto:** Multa LGPD até 2% do faturamento bruto (limitado a R$ 50M por infração). Mercado Pago pode suspender o merchant. SENACON já autuou jogos por ausência de política de reembolso visível.

**Passos de solução (obrigatórios antes de qualquer beta pago):**
1. Contratar advogado especializado em LGPD/games para redigir política de privacidade separada dos termos de uso
2. Implementar tela de aceite explícito com checkbox no cadastro:
```gdscript
# Adicionar à migration de schema
"CREATE TABLE IF NOT EXISTS consent_log (
    account_id INTEGER NOT NULL,
    terms_version TEXT NOT NULL,
    privacy_version TEXT NOT NULL,
    accepted_at INTEGER NOT NULL,
    ip_hash TEXT,
    PRIMARY KEY (account_id, terms_version, privacy_version)
)"
```
3. Adicionar política de reembolso visível na tela de compra (gems não gastas, 7 dias, CDC art. 49)
4. Definir idade mínima (recomendado: 16 anos sem parental consent, 13+ com parental consent) e implementar verificação no cadastro

**Status:** Infraestrutura de consentimento ampliada em `b93ce41` (`data/conf/migrations/039_consent_log.sql`, `sources/sql/SQL.gd:LogConsent`, `SetConsentAccepted`). A política textual e verificação de idade dependem de revisão jurídica/design e não foram alteradas.

---

### C-09 · Sistema de rebirth sem incentivo racional para reset

**Área:** Game Design / `IdlePolicy.gd`, documentação  
**Problema:** O ato de renascer (rebirth) não oferece incentivo imediato que justifique o reset de level. Um jogador que chegou ao cap (L60) acumula essência indefinidamente sem precisar reiniciar. O bônus de essência pós-rebirth não é suficientemente comunicado ou calculado de forma que o jogador entenda que "vale a pena" voltar ao L1. O documento interno registra isso como "PENDÊNCIA DE DONO" — reconhecendo que é uma decisão de design em aberto.

**Impacto:** Jogadores no cap ficam em uma fase "zumbi" sem objetivo claro, reduzindo engajamento daily entre D14–D30. O rebirth é o principal mecanismo de retenção de longo prazo em idle RPGs — sem ele funcionando, o D30 retention colapsa.

**Solução recomendada:**
1. Definir a fórmula de essência por rebirth de forma que seja visível e desejável: exibir na tela de rebirth "Você ganhará X essência = +Y% de poder permanente"
2. Adicionar um bônus de "First Rebirth Bonus" (1.5× essência na primeira reencarnação) para reduzir a barreira inicial
3. Implementar pelo menos 1 recompensa cosmética exclusiva de rebirth (título, cor de nome, ícone) para sinalização social
4. Adicionar ao AFK Report uma linha "Próximo rebirth em X horas" quando o personagem estiver próximo do cap

Esta é a única pendência crítica que não tem solução técnica simples — requer decisão de design antes da implementação.

---

### C-10 · Retenção D30 sem conteúdo suficiente

**Área:** Game Design / `BossService.gd`, roadmap  
**Problema:** O jogo tem 4 bosses, todos com piso de level 5, sem identidade elemental diferenciada. Um jogador dedicado esgota o boss ladder em D3–D4. O season pass (principal mecanismo de retenção de médio prazo) está implementado mas aguarda ativação. Sem conteúdo novo além de farming e guild, o churn entre D14–D21 é previsível.

**Solução mínima viável para lançamento:**
1. Ativar o season pass S1 no D0 do lançamento (código implementado, aguarda `SeasonsBetaLock` ser removido conforme BETA_DEBT #1)
2. Adicionar pelo menos 2 bosses com identidades elementais distintas (boss de fogo com resistência a frio, boss de gelo com fraqueza a fogo) — usa a infraestrutura elemental já existente
3. Escalonar o piso de level dos bosses (Boss 1: L5, Boss 2: L15, Boss 3: L30, Boss 4: L45, Boss 5: L55) para dar sensação de progressão ao longo das semanas
4. Comunicar ao jogador no D7 que "o boss ladder se expande com atualizações" se o conteúdo não puder ser criado a tempo

---

### C-11 · CI completamente quebrado — actions@v5 não existem

**Área:** CI/CD / `.github/workflows/godot-ci.yml`  
**Problema:** O CI referencia `actions/checkout@v5`, `actions/upload-artifact@v5` e `actions/download-artifact@v5`. Essas versões não existem — a versão mais recente é `@v4`. Nenhum build CI funciona em produção. Conforme BETA_DEBT #7, os workflows nunca foram executados remotamente (0 runs no repositório).

```yaml
# ERRADO
- uses: actions/checkout@v5
- uses: actions/upload-artifact@v5
- uses: actions/download-artifact@v5

# CORRETO
- uses: actions/checkout@v4
- uses: actions/upload-artifact@v4
- uses: actions/download-artifact@v4
```

**Ação adicional:** Após corrigir as versões, executar os workflows manualmente para verificar que os testes passam (BETA_DEBT #7 exige créditos de CI — providenciar antes do beta fechado).

---

## 🟠 ALTOS — Devem ser corrigidos antes do beta pago

---

### A-01 · Backup offsite no mesmo volume Docker

**Área:** Infraestrutura / `SQLBackups.gd` + `docker-compose.yml`  
**Problema:** O backup "offsite" copia para `/data-offsite`, que é um segundo diretório no **mesmo volume Docker** (linha comentada no compose: `# - game-offsite:/data-offsite`). Se o volume `game-data` for corrompido ou deletado (`docker volume rm game-data`), ambos os backups são perdidos simultaneamente.

**Solução:**
```gdscript
# Em SQLBackups.PushOffsite() — adicionar upload real para S3/R2/B2
func PushOffsite(backup_path: String) -> bool:
    # Opção 1: rclone via OS.execute (requer rclone instalado no container)
    var args = ["copy", backup_path, "r2:shambleta-backups/"]
    var exit_code = OS.execute("rclone", args)
    return exit_code == 0
    
    # Opção 2: presigned URL via HTTP client (sem dependência externa)
    # var url = _get_presigned_upload_url()
    # var http = HTTPClient.new()
    # ...
```

Alternativa operacional imediata: configurar snapshot automático do volume Docker no provedor Coolify enquanto a solução de código é implementada. Referência BETA_DEBT #3 (drill de restore com RPO/RTO observados).

---

### A-02 · Docker: ausência de healthcheck no serviço game

**Área:** Deploy / `docker-compose.yml`  
**Problema:** O serviço `web` (nginx) depende de `game` com condição `service_started` — que só espera o container iniciar, não o game server estar pronto para aceitar conexões WebSocket. O Godot server pode levar 5–15 segundos para importar recursos.

```yaml
# Adicionar ao serviço game:
game:
  healthcheck:
    test: ["CMD", "nc", "-z", "localhost", "6108"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 30s

# Atualizar dependência do web:
web:
  depends_on:
    game:
      condition: service_healthy
```

---

### A-03 · Thread safety em SQLBackups — verificações desabilitadas

**Área:** Concorrência / `SQLBackups.gd`  
**Problema:** `SQLBackups.Run()` chama `Thread.set_thread_safety_checks_enabled(false)` para poder acessar `Launcher.World.BackupPlayers()` de uma thread secundária. Acesso cross-thread a nodes Godot sem proteção pode causar crashes silenciosos ou corrupção de estado.

```gdscript
# ERRADO
func Run():
    Thread.set_thread_safety_checks_enabled(false)
    if Launcher.World:
        Launcher.World.BackupPlayers()

# CORRETO — delegar para a main thread
func Run():
    # I/O de banco permanece nesta thread
    _do_database_backup()
    # Ações no mundo do jogo via main thread
    Launcher.World.BackupPlayers.call_deferred()
    # OU usar um Timer na main thread que dispara BackupPlayers,
    # com esta thread apenas fazendo o I/O de arquivo
```

**Status:** Corrigido em `b93ce41` (`sources/sql/SQLBackups.gd:Run` usa `call_deferred` e remove desabilitação de thread-safety checks).

---

### A-04 · IdlePolicy._tickCombat — kill detection duplicada

**Área:** Gameplay / `IdlePolicy.gd`  
**Problema:** A detecção de kill está duplicada em `_tickCombat`, podendo contar o mesmo kill duas vezes no ledger de sessão e nas métricas de kills/hora. Conforme D1_GATE_REPORT, o hotfix do relógio (B→physics_process) foi aplicado — verificar se a duplicação sobreviveu ao refactor.

**Solução:**
```gdscript
# Garantir que a transição de estado DEAD seja verificada em apenas um lugar
func _tickCombat(delta: float) -> void:
    if _current_target == null:
        return
    if _current_target.stats.hp <= 0:
        if not _kill_registered:      # guard de estado
            _register_kill(_current_target)
            _kill_registered = true
        _current_target = null
        _kill_registered = false
```

**Status:** Corrigido em `b93ce41` (`sources/idle/IdlePolicy.gd:_tickCombat` usa `_killRegistered` para evitar duplicação).

---

### A-05 · OfflineSettle.session_efficiency sem guard de null

**Área:** Gameplay / `OfflineSettle.gd`  
**Problema:** O cálculo de `session_efficiency` acessa membros de um objeto que pode ser `null` em Godot 4.7 sem guard explícito, potencialmente causando crash no settle offline.

```gdscript
# Adicionar guard antes do cálculo
func _calculate_efficiency(session_data: Dictionary) -> float:
    if session_data.is_empty() or not session_data.has("kills") or not session_data.has("duration"):
        return 0.5  # eficiência neutra como fallback
    # cálculo normal...
```

**Status:** Corrigido em `b93ce41` (`sources/idle/OfflineSettle.gd` adiciona guard null-safe em ambas as leituras de `session_efficiency`).

---

### A-06 · BossService — cache de entity hash sem invalidação

**Área:** Gameplay / `BossService.gd`  
**Problema:** O cache de entity hash nunca é invalidado. Se um boss tiver seus stats modificados (por live-ops, hotfix de balance, ou progression do jogador), o cache servará valores stale indefinidamente até restart do servidor.

**Solução:**
```gdscript
# Adicionar TTL ao cache ou invalidar no evento de modificação de stats
const CACHE_TTL_SEC = 300  # 5 minutos

func _get_entity_hash(entity_id: int) -> String:
    var cache_key = str(entity_id)
    var now = Time.get_unix_time_from_system()
    if _hash_cache.has(cache_key):
        var entry = _hash_cache[cache_key]
        if now - entry["timestamp"] < CACHE_TTL_SEC:
            return entry["hash"]
    var hash = _compute_entity_hash(entity_id)
    _hash_cache[cache_key] = {"hash": hash, "timestamp": now}
    return hash
```

**Status:** Corrigido em `b93ce41` (`sources/idle/BossService.gd:GetBossEntityHash` com TTL de 300s).

---

### A-07 · Stats.AddExperience não verifica retorno de AddEssence

**Área:** Gameplay / `Stats.gd`  
**Problema:** Quando o XP ultrapassa o cap e deveria converter para essência via `AddEssence()`, o retorno de `AddEssence` não é verificado. Se `AddEssence` falhar (banco indisponível, mutex timeout), o XP excedente é simplesmente descartado sem log ou retry.

```gdscript
# Adicionar verificação
func AddExperience(amount: int) -> bool:
    var overflow = _calculate_xp_overflow(amount)
    if overflow > 0:
        var essence_result = AddEssence(overflow)
        if not essence_result:
            push_error("AddExperience: AddEssence falhou para overflow=%d, charID=%d" % [overflow, char_id])
            # Considerar: enfileirar para retry ou salvar em campo pending_essence
            return false
    # aplicar XP normal...
    return true
```

**Status:** Corrigido em `b93ce41` (`sources/actor/Stats.gd:AddExperience` verifica retorno de `AddEssence`).

---

### A-08 · EconomyService._AutoClaimPass segura settleMutex durante iteração longa

**Área:** Concorrência / `EconomyService.gd`  
**Problema:** `_AutoClaimPass` mantém o `settleMutex` durante uma iteração que pode processar múltiplos jogadores — bloqueando outros settles pelo tempo completo da iteração. Em produção com muitos jogadores, isso cria fila de espera no mutex.

**Solução:** Processar a lista de claims elegíveis fora do mutex e só travar para cada operação atômica individual:
```gdscript
func _AutoClaimPass() -> void:
    # Coletar elegíveis SEM mutex
    var eligible_accounts = _get_eligible_pass_accounts()
    # Processar cada um com lock mínimo
    for account_id in eligible_accounts:
        settleMutex.lock()
        _claim_pass_for_account(account_id)
        settleMutex.unlock()
```

**Status:** Corrigido em `b93ce41` (`sources/economy/EconomyService.gd:_AutoClaimPass` coleta elegíveis antes de travar o mutex por conta).

---

### A-09 · Server.LoginWithTwoFactor sem validação de accountID

**Área:** Segurança / `Server.gd`  
**Problema:** `LoginWithTwoFactor` não valida se o `accountID` fornecido corresponde à sessão pendente de 2FA. Um atacante que conhece o accountID de outro jogador pode tentar usar seu próprio token TOTP para autenticar na conta alheia.

```gdscript
func LoginWithTwoFactor(account_id: int, token: String) -> bool:
    # ADICIONAR: verificar que account_id corresponde à sessão pendente
    var pending_session = _get_pending_2fa_session(peer_id)
    if pending_session == null or pending_session.account_id != account_id:
        push_error("LoginWithTwoFactor: account_id mismatch ou sessão expirada")
        return false
    # prosseguir com validação do token
```

**Status:** Já validado em `b93ce41` via `Peers.ValidateTwoFactorChallenge` (`sources/network/server/Peers.gd:200-204`).

---

### A-10 · Feedback visual idle ausente (SnapshotMetrics não transmitida ao cliente)

**Área:** UX / `IdlePolicy.gd` + cliente  
**Problema:** `SnapshotMetrics` existe e coleta dados de kills/hora, gold/hora, XP/hora em tempo real, mas esses dados **não são transmitidos ao cliente**. O jogador não tem nenhuma indicação do que está acontecendo enquanto o personagem faz idle — sem números, sem animações de progresso, sem feedback de que o jogo está "funcionando".

**Solução:**
```gdscript
# No servidor — emitir métricas periodicamente (a cada 30s ou em mudança significativa)
func _emit_idle_metrics() -> void:
    var metrics = _snapshot_metrics.to_dict()
    RPC.SendToClient(peer_id, "UpdateIdleMetrics", metrics)

# No cliente — exibir no AFK Report ou HUD
func UpdateIdleMetrics(metrics: Dictionary) -> void:
    gold_per_hour_label.text = tr("%d GP/h") % metrics.gold_per_hour
    xp_per_hour_label.text = tr("%d XP/h") % metrics.xp_per_hour
    efficiency_label.text = tr("Eficiência: %d%%") % metrics.efficiency
```

---

### A-11 · Onboarding sem highlight visual funcional

**Área:** UX / `Onboarding.gd`  
**Problema:** `Onboarding.gd._highlight_node()` apenas chama `Launcher.GUI.set_visible(true)` sem destacar o nó-alvo. Um novo jogador não sabe onde clicar. A meta de "< 5 min funcional" não é atingível sem guia visual.

**Solução:**
```gdscript
# Implementar overlay de highlight real
func _highlight_node(node_path: NodePath) -> void:
    var target = get_node_or_null(node_path)
    if target == null:
        return
    # Criar overlay escuro com recorte no alvo
    var overlay = ColorRect.new()
    overlay.color = Color(0, 0, 0, 0.7)
    overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
    get_tree().root.add_child(overlay)
    # Adicionar seta/pulso no target
    var arrow = _create_arrow_indicator()
    arrow.global_position = target.global_position + Vector2(target.size.x + 10, 0)
    get_tree().root.add_child(arrow)
    _active_highlights.append([overlay, arrow])
```

**Status:** Highlight funcional já existe em `b93ce41` (`sources/gui/Onboarding.gd:_highlight_node` aplica borda amarela temporária no Control alvo).

Sequência mínima de onboarding: login → escolher zona → aguardar 30s → AFK Report abre automaticamente com `auto_open = true` na primeira sessão.

---

### A-12 · AFK Report sem estado de loading

**Área:** UX / `AfkReport.gd`  
**Problema:** `AfkReport._ready()` pode exibir o painel completamente em branco enquanto aguarda a resposta de `Network.GetAFKReport()`, sem nenhuma indicação ao usuário.

```gdscript
func _ready():
    # Exibir estado de loading imediatamente
    hoursLabel.text = tr("Carregando...")
    goldLabel.text = "—"
    xpLabel.text = "—"
    effLabel.text = "—"
    if NetClient.LastAFKReport.is_empty():
        Network.GetAFKReport()
    else:
        ShowReport(NetClient.LastAFKReport)
```

**Status:** Corrigido em `b93ce41` (`sources/gui/AfkReport.gd:_ready` exibe placeholders enquanto aguarda o report).

---

### A-13 · Acessibilidade: informação transmitida exclusivamente por cor (WCAG 1.4.1)

**Área:** UX / `AfkReport.gd`  
**Problema:** O AFK Report usa cores hardcoded (verde/amarelo/vermelho) como único mecanismo para comunicar eficiência. Deuteranopia/protanopia afeta ~8% dos homens — esses usuários não conseguem distinguir eficiência boa de ruim. Viola WCAG 1.4.1 (Use of Color).

```gdscript
# Adicionar indicador textual/simbólico além da cor
func _apply_efficiency_style(label: Label, eff_pct: int) -> void:
    var symbol: String
    var color: Color
    if eff_pct >= 80:
        symbol = "▲"
        color = Color(0.2, 0.8, 0.2)
    elif eff_pct >= 50:
        symbol = "→"
        color = Color(1.0, 0.85, 0.3)
    else:
        symbol = "▼"
        color = Color(0.9, 0.3, 0.2)
    label.text = "%s %d%%" % [symbol, eff_pct]
    label.add_theme_color_override("font_color", color)
```

**Status:** Corrigido em `b93ce41` (`sources/gui/AfkReport.gd:ShowReport` adiciona símbolo textual ▲/→/▼ além da cor).

---

### A-14 · Peso do build web: 32 MB gzip (meta: <25 MB)

**Área:** Performance / CI + export presets  
**Problema:** O build web está em ~32 MB gzip, principalmente devido a `data/music` (~26 MB embutidos no .pck). O CI emite apenas `::warning::` sem bloquear o build. Para um jogo idle-first web/mobile, 3–8 segundos de loading em 4G é barreira direta de conversão.

**Solução:**
1. Mover música para streaming via CDN — o `Audio.gd` já tem lógica de streaming, verificar se está ativo:
```gdscript
# Em Audio.gd — garantir que streaming está ativo para web
if LauncherCommons.isWeb:
    _load_music_from_cdn(music_url)  # URL do nginx ou CDN externo
```
2. Adicionar ao export preset web:
```
exclude_filter = "data/music/**"
```
3. Mudar CI de warning para erro:
```yaml
- name: Check web bundle size
  run: |
    SIZE=$(du -sk build/Web/ | cut -f1)
    if [ $SIZE -gt 25600 ]; then
      echo "::error::Build web acima de 25MB (atual: ${SIZE}KB)"
      exit 1
    fi
```
Meta realista após remover música: <15 MB gzip.

---

### A-15 · Sinks de ouro insuficientes — inflação previsível

**Área:** Economia / `EconomyService.gd`  
**Problema:** Os únicos sinks de ouro identificados são consumíveis do vendor NPC (máximo 10.000 gold/dia — insignificante para farmas avançadas) e trade fees (cobradas em gems, não gold). Sem sink escalável, o ouro acumulado perde significado rapidamente.

**Solução mínima viável (pelo menos um antes do launch):**
```gdscript
# Reforja de itens — sistema simples mas eficaz
# 3 itens T2 → 1 item T3 aleatório do pool da zona
# Custo: T1: 500g, T2: 2.000g, T3: 10.000g, T4+: 50.000g+
const REFORGE_COST = {1: 500, 2: 2000, 3: 10000, 4: 50000}

func ReforgeItems(char_id: int, item_ids: Array) -> Dictionary:
    if item_ids.size() < 3:
        return {"success": false, "error": "Reforge requires 3 items"}
    var tier = _get_item_tier(item_ids[0])
    var gold_cost = REFORGE_COST.get(tier, 500)
    return Transaction(func():
        if not DeductGold(char_id, gold_cost):
            return false
        for id in item_ids:
            DestroyItem(char_id, id)
        var new_item = _roll_tier_item(tier + 1, _get_zone_pool(char_id))
        GrantItem(char_id, new_item)
        return true
    )
```

---

### A-16 · Auction House sem controles anti-bot documentados

**Área:** Economia / Segurança  
**Problema:** O código do AH não foi revisado na auditoria. O trade P2P tem controles sólidos (email verificado, cooldown 60s, cap 20/dia, fee queimada em gems). Se o AH não tiver controles equivalentes, bots de sniping podem explorar o mercado.

**Requisitos obrigatórios para o AH antes do lançamento:**
- Rate limiting de listagens: máx. 10 listagens/hora por conta
- Fee de listagem em gems (ex.: 5 gems por item listado) — sink adicional
- Cooldown de bid: mínimo 5 segundos entre bids no mesmo item (anti-sniping)
- Email verificado obrigatório para listar e fazer bid
- Cooldown de 24h para nova listagem após cancelamento do mesmo item (anti-spam)

---

### A-17 · Builds elementais ignoradas pelo PowerScore

**Área:** Gameplay / `Formula.gd` + sistema de zonas  
**Problema:** O dano elemental não entra no cálculo do PowerScore que determina o gate de zona. Um mago de gelo e um guerreiro físico com o mesmo PowerScore têm a mesma probabilidade de passar no gate, mesmo que o boss da zona tenha fraqueza elemental. Isso torna as builds elementais mecanicamente irrelevantes para progressão.

**Solução:**
```gdscript
# Incluir bônus elemental no PowerScore
func CalculatePowerScore(stats: ActorStats, zone_id: int) -> float:
    var base_score = stats.attack * 2.5 + stats.defense * 1.5 + stats.hp / 10.0
    # Adicionar multiplicador elemental vs. boss da zona
    var zone_boss_element = DB.ZoneDB[zone_id].get("boss_weakness", "none")
    var player_element = stats.get("primary_element", "none")
    var elemental_bonus = 1.0
    if player_element != "none" and player_element == zone_boss_element:
        elemental_bonus = 1.15  # +15% de poder elemental relevante
    return base_score * elemental_bonus
```

---

### A-18 · AutoIdleTimeout de 10s muito agressivo

**Área:** Gameplay / `IdlePolicy.gd` ou `WorldAgent.gd`  
**Problema:** O timeout de 10 segundos para ativar o modo idle é muito agressivo — interrompe interações normais de UI (abrir inventário, ler chat, navegar menus) e força o personagem de volta ao idle antes que o jogador termine a ação.

**Solução:** Aumentar para 30–60 segundos e pausar o countdown enquanto qualquer janela de UI estiver aberta:
```gdscript
const IDLE_TIMEOUT_SEC = 45.0  # era 10s

func _on_window_opened() -> void:
    _idle_timer_paused = true

func _on_window_closed() -> void:
    _idle_timer_paused = false
    _idle_countdown = IDLE_TIMEOUT_SEC  # resetar ao fechar UI
```

---

### A-19 · Formula.randf() compartilhado entre threads para key drops

**Área:** Concorrência / `Formula.gd`  
**Problema:** `randf()` compartilhado entre threads para calcular key drops cria condições de corrida — dois threads podem chamar `randf()` simultaneamente, resultando em RNG não-determinístico e potencialmente gerando resultados incorretos em sistemas que assumem sequência determinística de drops.

**Solução:**
```gdscript
# Cada thread deve ter seu próprio RandomNumberGenerator
var _rng := RandomNumberGenerator.new()

func _init():
    _rng.randomize()

func RollKeyDrop(rate: float) -> bool:
    return _rng.randf() < rate  # usar _rng da instância, não randf() global
```

**Status:** Não aplicável em Godot 4.7 — `randf()` passou a ser thread-local a partir do 4.2. Sem ação de código necessária.

---

### A-20 · WorldAgent.agents dict sem proteção de thread

**Área:** Concorrência / `WorldAgent.gd`  
**Problema:** O dicionário `agents` é acessado de múltiplos contextos sem mutex, podendo causar corrupção silenciosa em iterações concorrentes.

**Solução:** Proteger todos os acessos ao dicionário com um mutex dedicado ou usar `call_deferred` para garantir acesso single-threaded.

**Status:** Corrigido em `b93ce41` (`sources/world/WorldAgent.gd` adiciona `_agentsMutex` e protege `GetAgent`/`AddAgent`/`RemoveAgent`).

---

### A-21 · Checkout: idempotency_key com timestamp permite double-grant

**Área:** Economia / `Checkout.gd`  
**Problema:** A `idempotency_key` inclui timestamp: `"%s:web%d" % [extRef, int(Time.get_unix_time_from_system())]`. Múltiplos cliques rápidos em "Pay" geram chaves distintas para a mesma compra, permitindo grants duplicados se o companion não tiver validação adicional por `external_reference`.

**Solução:** O companion deve garantir que uma `external_reference` só gera um grant bem-sucedido, independente da chave:
```python
# No companion Python — adicionar constraint único por external_reference
cursor.execute("""
    INSERT INTO grant_queue (idempotency_key, external_reference, account_id, sku, status)
    VALUES (?, ?, ?, ?, 'pending')
    ON CONFLICT(external_reference) DO NOTHING
""", (idempotency_key, external_reference, account_id, sku))
```

---

### A-22 · SQL.Wipe() sem guard de debug build

**Área:** Segurança / `SQL.gd`  
**Problema:** A função `Wipe()` (que apaga todos os dados) não tem verificação de que está em debug build. Se chamada acidentalmente em produção (por um admin command, um bug, ou um exploit), apaga o banco inteiro.

```gdscript
func Wipe() -> void:
    assert(OS.is_debug_build(), "Wipe() só pode ser chamada em debug build")
    if not OS.is_debug_build():
        push_error("SQL.Wipe(): recusado em produção")
        return
    # executar wipe
```

**Status:** Corrigido em `b93ce41` (`sources/sql/SQL.gd:Wipe`).

---

### A-23 · IdlePolicyService: dois retryAttach concorrentes possíveis

**Área:** Concorrência / `IdlePolicyService.gd`  
**Problema:** Dois eventos concorrentes podem disparar `retryAttach` simultaneamente para o mesmo jogador, criando dois processos de attach competindo e potencialmente duplicando a sessão idle.

**Solução:** Adicionar flag de guard:
```gdscript
var _attach_in_progress := {}  # charID → bool

func _retry_attach(char_id: int) -> void:
    if _attach_in_progress.get(char_id, false):
        return
    _attach_in_progress[char_id] = true
    # ... lógica de attach
    _attach_in_progress.erase(char_id)
```

---

## 🟡 MÉDIOS — Melhorias importantes pós-beta

---

### M-01 · UpdateProgress: N+1 queries sem batch nem transação

**Área:** Performance / `SQL.gd`  
**Problema:** `UpdateProgress()` executa até 300 queries individuais (50 quests + 80 bestiary + 20 skills, 2 queries cada) sem envelope transacional. Em produção com 50+ jogadores, o `queryMutex` cria fila de centenas de queries sequenciais.

```gdscript
# Solução: batch INSERT OR REPLACE dentro de Transaction()
func UpdateProgress(charID: int, progress: ActorProgress) -> void:
    Transaction(func():
        if not progress.quests.is_empty():
            var placeholders = ",".join(progress.quests.keys().map(func(k): return "(?,?,?)"))
            var values = []
            for quest_id in progress.quests:
                values.append_array([charID, quest_id, progress.quests[quest_id]])
            QueryBindings("INSERT OR REPLACE INTO quest (char_id, quest_id, state) VALUES " + placeholders, values)
        # repetir para bestiary e skills
    )
```

Reduz 300 queries a 3 statements.

---

### M-02 · GetChestStats: duas queries COUNT separadas

**Área:** Performance / `SQL.gd`

```sql
-- ERRADO: duas queries
SELECT COUNT(*) FROM chest_instance WHERE char_id = ? AND item_state = 'opened';
SELECT COUNT(*) FROM chest_instance WHERE char_id = ? AND item_state = 'closed';

-- CORRETO: uma query
SELECT SUM(CASE WHEN item_state='opened' THEN 1 ELSE 0 END) AS opened,
       SUM(CASE WHEN item_state='closed'  THEN 1 ELSE 0 END) AS closed
FROM chest_instance WHERE char_id = ?;
```

Adicionar migration: `CREATE INDEX idx_chest_char_state ON chest_instance(char_id, item_state);`

**Status:** Corrigido em `b93ce41` (`sources/sql/SQL.gd:GetChestStats` usa query única com SUM/CASE).

---

### M-03 · Índices SQL ausentes nas queries mais frequentes

**Área:** Performance / migrations SQL

```sql
-- Adicionar em uma nova migration
CREATE INDEX IF NOT EXISTS idx_character_account ON character(account_id);
CREATE INDEX IF NOT EXISTS idx_item_char_item ON item(char_id, item_id, storage);
CREATE INDEX IF NOT EXISTS idx_item_instance_char ON item_instance(char_id, item_id, storage);
CREATE INDEX IF NOT EXISTS idx_ledger_account ON ledger_transaction(account_id, id DESC);
CREATE INDEX IF NOT EXISTS idx_chest_char_state ON chest_instance(char_id, item_state);
```

**Status:** Parcialmente corrigido em `b93ce41` (`data/conf/migrations/040_performance_indexes.sql` adiciona `idx_character_account` e `idx_item_char_item`; os demais já existiam).

---

### M-04 · UpdateCharacter: padrão read-modify-write sem atomicidade

**Área:** Performance / `SQL.gd`

```sql
-- Substituir SELECT * + UPDATE separado por UPDATE direto:
UPDATE character 
SET total_time = total_time + ?,
    last_timestamp = ?,
    pos_x = ?,
    pos_y = ?
WHERE char_id = ?;
```

**Status:** Corrigido em `b93ce41` (`sources/sql/SQL.gd:UpdateCharacter` usa UPDATE direto com `total_time = total_time + ?`).

---

### M-05 · ConsumeItemLotsRaw sem garantia de envelope transacional

**Área:** Segurança / `SQL.gd`  
**Problema:** `ConsumeItemLotsRaw()` faz múltiplos updates/deletes individuais sem garantia de que o chamador envolveu em `Transaction()`. Falha no meio deixa lotes parcialmente consumidos.

**Solução:** Adicionar assertion e documentar:
```gdscript
func ConsumeItemLotsRaw(item_id: String, amount: int) -> bool:
    assert(_in_transaction, "ConsumeItemLotsRaw DEVE ser chamada dentro de Transaction()")
    # ... lógica existente
```

---

### M-06 · Medição incompleta do bundle web no CI

**Área:** CI / `.github/workflows/`  
**Problema:** O CI mede apenas arquivos `.pck/.wasm/.js/.side.wasm`, ignorando `index.html` e assets fora do `.pck`. O peso real de first-load pode ser maior que o medido.

**Solução:**
```bash
# Substituir medição atual por:
SIZE_TOTAL=$(find build/Web/ -type f | xargs gzip -c | wc -c)
SIZE_MB=$((SIZE_TOTAL / 1024 / 1024))
echo "Bundle total (gzip estimado): ${SIZE_MB}MB"
```

---

### M-07 · Rate limiting de RPCs idle não confirmado

**Área:** Segurança / `Footprint.gd`  
**Problema:** Não há evidência de que os novos RPCs idle (`ClaimOfflineSettle`, `OpenChest`, etc.) passam pelo `Footprint.CheckAction` com os limites corretos. Um cliente mal-formado pode disparar settles repetidos gerando carga excessiva.

**Solução:** Auditar cada novo RPC idle e confirmar chamada a `Footprint.CheckAction`:
```gdscript
func ClaimOfflineSettle(peer_id: int) -> void:
    if not Footprint.CheckAction(peer_id, "claim_settle", 1, 60):  # 1 vez por 60s
        return
    # processar settle
```

**Status:** Corrigido em `b93ce41` (`sources/network/server/Server.gd:ClaimOfflineSettle` e `OpenChest` adicionam `Footprint.CheckAction`).

---

### M-08 · Precificação dupla de VIP (gems internas vs. BRL)

**Área:** Economia / `Shop.gd`  
**Problema:** VIP pode ser comprado por 440 gems internas (~R$ 16 de valor implícito) ou por R$ 24,90 em dinheiro real. A inconsistência de preço relativo confunde o jogador e desvaloriza o SKU em BRL.

**Solução preferida:** Remover a compra de VIP via gems internas — deixar VIP exclusivamente via dinheiro real. Gems são para sinks de baús/comércio. Ajustar a descrição na UI: VIP1 = "+20% AFK offline + cap 24h", VIP2 = "+20% AFK offline + cap 36h + reset instantâneo de claim".

---

### M-09 · Missões do season pass com problemas de elegibilidade

**Área:** Monetização / `s1.json` + sorteio de missões  
**Problema:** Missões que requerem features não lançadas (trade = F4, guild = requer guild) podem ser sorteadas para jogadores sem acesso. Pool de semanais pequeno (6) causa repetições na mesma temporada.

**Solução:**
```gdscript
# Adicionar flag de elegibilidade nas missões
# s1.json:
# "d_trade1": {"requires_feature": "trade", "fallback": "d_reforge1"}

func _roll_daily_missions(player: PlayerData) -> Array:
    var eligible = DAILY_POOL.filter(func(m):
        if m.get("requires_feature", "") == "":
            return true
        return FeatureFlags.is_active(m.requires_feature)
    )
    return eligible.pick_random_n(3)
```

Expandir pool de semanais de 6 para 8.

---

### M-10 · Newbie Boost 5x ausente no offline settle

**Área:** Gameplay / `OfflineSettle.gd`  
**Problema:** O Newbie Boost de 5× só é aplicado online (IdlePolicy em tempo real), mas não no settle offline. Um novo jogador que fica 8 horas offline não recebe o boost que receberia online — inconsistência que penaliza o comportamento mais natural do público-alvo idle.

**Solução:**
```gdscript
func _calculate_offline_rewards(char: CharData, hours: float) -> Dictionary:
    var is_newbie = char.total_playtime_hours < 48  # primeiras 48h
    var newbie_mult = 5.0 if is_newbie else 1.0
    var base_gold = char.gold_per_hour * hours
    return {
        "gold": int(base_gold * newbie_mult),
        "xp": int(base_gold * char.xp_gold_ratio * newbie_mult)
    }
```

**Status:** Corrigido em `b93ce41` (`sources/idle/OfflineSettle.gd:_ApplyFormula` aplica `FarmZoneData.NewbieBoostFactor` para chars < nível 10 no offline settle).

---

### M-11 · Consentimento Sentry: opt-out implícito

**Área:** Privacy / `Monitoring.gd`  
**Problema:** O bug reporting via Sentry está ativado por padrão (`default: true`). LGPD art. 6 exige informação clara sobre dados coletados. O username do jogador é enviado via `SetPlayer()`.

**Solução:** Mudar default para `false` (opt-in) ou exibir banner de consentimento explícito na primeira execução:
```gdscript
# Mudar default
var _bug_reports_enabled = Conf.GetVariant("User", "Privacy-BugReports", false)  # era true
```

**Status:** Corrigido em `b93ce41` (`sources/system/Monitoring.gd:BeforeSend` default alterado para `false` — opt-in).

---

### M-12 · I18N: strings hard-coded em inglês

**Área:** UX / `Settings.gd`, `AfkReport.gd`  
**Problema:** `"UI Scale"`, `"Language"`, `"This permanently deletes your account..."` e strings concatenadas como `" (2× AD!)"` estão em inglês sem `tr()`, aparecendo em inglês para usuários `pt_BR`.

```gdscript
# Settings.gd
langLabel.text = tr("Language")
scaleLabel.text = tr("UI Scale")
deleteButton.text = tr("DELETE ACCOUNT")

# AfkReport.gd
var ad_tag: String = tr(" (2× AD!)") if doubled else ""
label.text = tr("%s GP%s") % [format_number(gold), ad_tag]
```

---

### M-13 · FloatingWindows: layout sem reorganização em rotação de tela

**Área:** UX / `FloatingWindows.gd`  
**Problema:** Em mobile, rotação de tela (portrait ↔ landscape) apenas faz clamp das janelas, sem reorganizar o layout. Janelas ficam sobrepostas ou em posições subótimas.

```gdscript
func _on_window_resized() -> void:
    var new_ratio = get_viewport_rect().size / _last_size
    # Detectar mudança de orientação
    var was_landscape = _last_size.x > _last_size.y
    var is_landscape = get_viewport_rect().size.x > get_viewport_rect().size.y
    if was_landscape != is_landscape:
        ResetWindowsLayout()  # preset para nova orientação
        return
    # scaling normal para resize sem rotação
    _scale_windows(new_ratio)
```

**Status:** Corrigido em `b93ce41` (`sources/gui/FloatingWindows.gd:_on_window_resized` detecta rotação e chama `ResetWindowsLayout()`).

---

### M-14 · VerifyDialog: referência frágil por posição de filho

**Área:** UX / `Settings.gd`  
**Problema:** `get_child(get_child_count() - 1)` para recuperar o `VerifyDialog` — frágil se a ordem de filhos mudar.

```gdscript
# Substituir por referência explícita
var _verifyDialog: AcceptDialog = null

func _on_two_factor_qr_confirmed() -> void:
    if _verifyDialog != null:
        _verifyDialog.queue_free()
    _verifyDialog = AcceptDialog.new()
    add_child(_verifyDialog)
    _verifyDialog.confirmed.connect(_on_verify_two_factor_setup)
```

**Status:** Corrigido em `b93ce41` (`sources/gui/Settings.gd` armazena `_verifyDialog` e libera anterior antes de recriar).

---

### M-15 · Signal leak em FloatingWindows._AbsorbWindow

**Área:** Memória / `FloatingWindows.gd`  
**Problema:** Ao reparentar janelas em `_AbsorbWindow()`, sinais do objeto antigo não são desconectados, criando potential signal leak.

```gdscript
func _AbsorbWindow(win: WindowPanel) -> void:
    # Desconectar sinais antes de remover
    if win.MoveFloatingWindowToTop.is_connected(MoveWindow):
        win.MoveFloatingWindowToTop.disconnect(MoveWindow)
    # prosseguir com reparentação
```

**Status:** Corrigido em `b93ce41` (`sources/gui/FloatingWindows.gd:_ready` protege conexão e `Settings.gd` guarda referência do dialog).

---

### M-16 · Memory leak em Settings.gd — VerifyDialog acumulado

**Área:** Memória / `Settings.gd`  
**Problema:** Cada passagem pelo fluxo de 2FA cria um novo `AcceptDialog` sem destruir o anterior, causando leak incremental.

**Solução:** Ver M-14 — guardar referência e chamar `queue_free()` antes de recriar.

**Status:** Corrigido em `b93ce41` (`sources/gui/Settings.gd:_on_two_factor_qr_confirmed` guarda referência e libera anterior).

---

### M-17 · Definir métricas de trigger para migração PostgreSQL

**Área:** Arquitetura / documentação  
**Problema:** O plano de migração companion→PostgreSQL (Fase 2) não tem critério de trigger definido. Sem gatilho, a migração tende a ser postergada até o sistema estar sob pressão.

**Solução:** Documentar e monitorar:
```
Trigger de migração: sqlite_busy_timeout_hits > 100/hora OU CCU > 80
Ação: iniciar migração companion→PostgreSQL
Métrica a adicionar: contador de busy_timeout no /metrics do companion
```

---

### M-18 · PruneBackups sem log de erro em diretório inacessível

**Área:** Infraestrutura / `SQLBackups.gd`

```gdscript
func PruneBackups() -> void:
    var dir = DirAccess.open(BACKUP_DIR)
    if dir == null:
        push_error("SQLBackups.PruneBackups: diretório '%s' inacessível — disco cheio?" % BACKUP_DIR)
        # Considerar: emit_signal("backup_error", "pruning_failed")
        return
    # lógica normal
```

**Status:** Corrigido em `b93ce41` (`sources/sql/SQLBackups.gd:PruneBackups` adiciona log de erro quando o diretório é inacessível).

---

### M-19 · Resistências elementais de mobs = 0%

**Área:** Gameplay / conteúdo  
**Problema:** Todos os mobs têm resistências elementais definidas como 0%, tornando o sistema elemental mecanicamente inerte. Builds de elemento não têm advantage em nenhuma situação.

**Solução:** Definir resistências por zona/mob_type como decisão de conteúdo antes do lançamento:
```json
// Exemplo em MobDB.json
"fire_elemental": {
    "resistances": {"fire": 0.5, "water": -0.5, "neutral": 0.0},
    "zone": "volcano"
}
```

---

### M-20 · Custo de escrita de essência no cap (~96–150 transações/hora/char L60)

**Área:** Performance / `Stats.gd`  
**Problema:** No cap de nível, cada tick de XP acima do limite gera uma transação de essência. Com múltiplos personagens no cap, isso pode criar volume alto de writes no SQLite.

**Solução:** Acumular essência em buffer e persistir em batch a cada N ticks ou em intervalos fixos:
```gdscript
var _pending_essence := 0.0

func _tick_xp_overflow(amount: float) -> void:
    _pending_essence += amount
    if _pending_essence >= 1.0:
        var to_grant = floori(_pending_essence)
        _pending_essence -= to_grant
        AddEssence(to_grant)  # apenas quando há essência inteira a adicionar
```

---

### M-21 · Benchmark XP walk: mede soma de inteiros, não lógica real

**Área:** CI / `tests/benchmarks.gd`  
**Problema:** O benchmark "XP walk" é `for i in range(1000): totalXp += 10` — nunca falha, nunca detecta regressão real.

**Solução:**
```gdscript
# Substituir por teste real
func benchmark_xp_walk() -> void:
    var start = Time.get_ticks_msec()
    for i in range(1000):
        _test_char.stats.AddExperience(10)  # chama lógica real
    var elapsed = Time.get_ticks_msec() - start
    assert(elapsed < 500, "XP walk: 1000 ganhos de XP levaram %dms (máx: 500ms)" % elapsed)
```

---

### M-22 · Trilha grátis do season pass com buracos visuais (L16–L24, L24–L30)

**Área:** Monetização / `s1.json`  
**Problema:** Buracos na trilha grátis reduzem percepção de valor e "inveja saudável" que motiva compra da trilha premium.

**Solução:** Preencher todos os 30 níveis da trilha grátis com pelo menos um item visual mínimo (5–10 gold, consumível barato). Custo de design próximo de zero; impacto em percepção alto.

---

### M-23 · Gems: ausência de SKU de entrada ultra-barato

**Área:** Monetização / catálogo  
**Problema:** O menor SKU de gems é R$ 19,90. A ausência de um pacote de R$ 7–9 como ponto de entrada reduz conversão de quem quer "testar gastar".

**Solução:** Adicionar SKU permanente `gems.200` por R$ 7,90 (200 gems). Esse SKU funciona como âncora de comparação ("550 por R$ 19,90 é mais econômico") além de reduzir a barreira de primeira conversão.

---

### M-24 · Dark patterns: timer de 72h do starter pack pode configurar oferta enganosa

**Área:** Compliance / Shop  
**Problema:** Se o timer de 72h reinicia para cada nova conta criada, o starter pack nunca é genuinamente limitado — configura potencial oferta enganosa pelo CDC art. 31.

**Solução:** Verificar com advogado e garantir que o timer é por-conta (não por-dispositivo ou por-sessão). Documentar no código que a oferta é genuinamente limitada a 72h desde a criação da conta.

---

### M-25 · Daily shop: ausência de histórico de compras visível

**Área:** UX / transparência  
**Problema:** O jogador não tem onde consultar seu histórico de compras/grants. O ledger existe no servidor mas não é exposto ao usuário.

**Solução:** Adicionar tela "Histórico de transações" no menu de conta, consultando o ledger do servidor. Query existente: `SELECT * FROM ledger_transaction WHERE account_id = ? ORDER BY id DESC LIMIT 50`.

---

### M-26 · Conteúdo elemental dos bosses sem identidade

**Área:** Gameplay / conteúdo  
**Problema:** Os 4 bosses têm piso L5 e sem diferenciação elemental, criando pouco incentivo para otimizar builds para boss específico.

**Solução (vinculada a C-10):** Definir identidade elemental para cada boss e escalonar piso de levels antes do lançamento.

---

### M-27 · ConfirmPasswordReset não-atômico

**Área:** Segurança / `Server.gd`  
**Problema:** `ConfirmPasswordReset` não usa transação — se o update de senha for bem-sucedido mas o invalidar do token falhar, o token permanece válido e pode ser reutilizado para resetar a senha novamente.

```gdscript
func ConfirmPasswordReset(token: String, new_password: String) -> bool:
    return SQL.Transaction(func():
        var account = SQL.GetAccountByResetToken(token)
        if account == null:
            return false
        SQL.UpdatePassword(account.id, _hash_password(new_password))
        SQL.InvalidateResetToken(token)
        return true
    )
```

**Status:** Corrigido em `b93ce41` (`sources/network/server/Server.gd:ConfirmPasswordReset` envolve update/invalidação em `SQL.Transaction`).

---

### M-28 · Action.gd: lógica invertida no contador de Enable/Disable

**Área:** Código / `Action.gd`  
**Problema:** O contador de Enable/Disable está com lógica invertida — Enable decrementa e Disable incrementa (ou vice-versa), fazendo com que ações fiquem presas em estado errado.

**Solução:** Revisar a lógica e adicionar test case:
```gdscript
# Garantir semântica correta:
# _disable_count == 0 → action está enabled
# _disable_count > 0 → action está disabled
func Enable() -> void:
    _disable_count = max(0, _disable_count - 1)

func Disable() -> void:
    _disable_count += 1

func IsEnabled() -> bool:
    return _disable_count == 0
```

**Status:** Corrigido em `b93ce41` (`sources/input/Action.gd:Enable` inverte sinal para `disableCounter += (-1 if enable else 1)`).

---

### M-29 · IdlePolicyService: ZonePolicy criada desnecessariamente

**Área:** Performance / `IdlePolicyService.gd`  
**Problema:** Uma `ZonePolicy` é criada mesmo quando a `IdlePolicy` base já cobre o caso, gerando alocação desnecessária.

**Solução:** Verificar o fluxo de criação e eliminar alocação condicional desnecessária antes de completar o attach.

---

### M-30 · Auto-sharding de instâncias não itera além de +1

**Área:** Escalabilidade / `WorldAgent.gd`  
**Problema:** O auto-sharding de instâncias só verifica a instância atual + 1, não iterando para encontrar a instância com menor ocupação. Em servidores com múltiplas instâncias da mesma zona, isso pode resultar em distribuição desigual.

**Solução:** Iterar todas as instâncias da zona para encontrar a com menor população:
```gdscript
func _find_best_instance(zone_id: int) -> int:
    var instances = World.GetZoneInstances(zone_id)
    var best_inst = instances[0]
    for inst in instances:
        if inst.player_count < best_inst.player_count:
            best_inst = inst
    return best_inst.id
```

---

## 🟢 BAIXOS — Melhorias de polimento

---

### B-01 · LotHistory: N queries sequenciais substituíveis por CTE recursiva

**Área:** Performance / `SQL.gd`

```sql
WITH RECURSIVE chain AS (
    SELECT * FROM item_instance WHERE uid = ?
    UNION ALL
    SELECT ii.* FROM item_instance ii 
    JOIN chain c ON ii.uid = c.parent_uid
    LIMIT 20
) SELECT * FROM chain;
```

---

### B-02 · Screen reader e acessibilidade básica

**Área:** UX / Acessibilidade  
**Problema:** Sem suporte a `focus_mode`, `tooltip_text`, ou AT-SPI.

**Solução (pós-lançamento):** Mapear botões críticos com `tooltip_text`, garantir `focus_mode = FOCUS_ALL`. Registrar como gap aceito no FEATURE_MATRIX.md.

---

### B-03 · P2W balance: missão semanal "Gaste 100 gems" pode frustrar F2P

**Área:** Monetização / `s1.json`  
**Solução:** Limitar a missão `w_spend100` a máximo 1 aparição por pool de 4 semanas, ou substituir por "Use a loja diária 3 vezes" quando o jogador não tem gems acumuladas.

---

### B-04 · Season pass: VIP +10% XP não comunicado claramente

**Área:** UX / UI do season pass  
**Solução:** Exibir explicitamente na UI: "VIP concede +10% de Pontos de Temporada — opcional, não obrigatório para completar o passe".

---

### B-05 · Daily shop: reroll sem lista de possíveis ofertas

**Área:** UX / transparência  
**Solução:** Adicionar tooltip no botão de reroll com a lista completa de ofertas possíveis do pool. Elimina o mistério e reduz percepção de dark pattern.

---

### B-06 · VIP trial na loja sem comparação de custo por dia

**Área:** UX / Shop  
**Solução:** Exibir comparativo: "3d por 150 gems = 50 gems/dia — VIP30d = 14,7 gems/dia (mais econômico)".

---

### B-07 · Skip de nível no passe: custo cumulativo não comunicado

**Área:** UX / Shop  
**Solução:** Exibir custo total máximo dos 10 skips (500 gems ≈ R$ 18) na tela do passe para evitar surpresa.

---

### B-08 · Código morto e inconsistências de estilo

**Área:** Código / manutenibilidade  
**Problema:** Distribuído em múltiplos arquivos — funções não usadas, comentários desatualizados, inconsistências de nomenclatura (camelCase vs. snake_case misturados).  
**Solução:** Executar linter + revisão de código focada em um sprint de limpeza pós-beta.

---

### B-09 · UpdateProgress ignora retornos de erro de SetQuest/SetBestiary

**Área:** Código / `SQL.gd`  
**Solução:** Verificar retorno de cada operação e logar falhas para debugging em produção.

**Status:** Corrigido em `b93ce41` (`sources/sql/SQL.gd:UpdateProgress` verifica retorno e loga erros).

---

### B-10 · Deadzone: normalização dupla anula efeito

**Área:** Código / `Action.gd`  
**Problema:** A normalização do vetor de deadzone é aplicada duas vezes, resultando em deadzone efetiva de zero.  
**Solução:** Aplicar normalização apenas uma vez e adicionar test case.

**Status:** Corrigido em `b93ce41` (`sources/input/Action.gd:GetMove` remove normalização duplicada).

---

### B-11 · IdlePolicyService: OnBossResult acessa idlePolicy antes do guard de null

**Área:** Código / `IdlePolicyService.gd`  
**Solução:**
```gdscript
func OnBossResult(result: Dictionary) -> void:
    if idlePolicy == null:
        return  # guard primeiro
    # prosseguir com processamento
```

**Status:** Já protegido em `b93ce41` (`sources/idle/IdlePolicyService.gd:OnBossResult` tem `player.idlePolicy == null` na entrada).

---

### B-12 · Obs de segurança: benchmark CI adicionar testes reais de settle/SQL

**Área:** CI / `tests/benchmarks.gd`  
**Solução (vinculada a M-21):** Além do XP walk, adicionar benchmark de `UpdateProgress()` com 50 quests/bestiary entries.

---

### B-13 · Staging environment: provisionar no Coolify

**Área:** Deploy / infra  
**Problema:** `STAGING.md` e `docker-compose.staging.yml` existem mas o ambiente não foi provisionado.  
**Solução:** Provisionar staging no Coolify antes do beta fechado para ter ambiente de testes isolado.

---

### B-14 · Release signing para builds desktop

**Área:** Deploy / distribuição  
**Problema:** Builds desktop não assinados (BETA_DEBT #10). Em macOS, builds não assinados exigem que o usuário contorne o Gatekeeper.  
**Solução:** Configurar assinatura de código no CI de release antes do lançamento público em stores.

---

## PONTOS POSITIVOS

O projeto tem uma base sólida que justifica o investimento em correção:

**Arquitetura e segurança:**
- Idempotência do offline settle correta e testada em 651 casos sem falha — o coração do jogo idle funciona
- Ledger append-only com auditoria completa: toda mutação de moeda tem linha de ledger para dispute resolution
- Sistema provably-fair para baús: server_seed + client_seed + nonce + snapshot de odds persistidos — acima da média do mercado BR
- KDF com 12.000 iterações SHA-256, lockout exponencial, anti-enumeração de login — security fundamentals corretos
- Trade P2P com email verificado obrigatório, cooldown 60s, cap 20/dia, fee queimada — bem construído
- Gems não-cashable: elimina RMT de gems e simplifica contabilidade de reembolso

**Design e produto:**
- Guardrail anti-P2W documentado E verificado em código: essência (único multiplicador permanente) não é comprável por nenhum meio monetário
- Modelo de preços do season pass (R$ 24,90) calibrado corretamente para o mercado BR
- Pity timer a cada 10 aberturas de baú — gacha com transparência mínima obrigatória
- Regras da temporada congeladas no D0 com changelog público — lição aprendida com erros de concorrentes (AFK Heroes)
- Recompensas automáticas no encerramento do passe — sem "itens que somem"
- Curva de XP saudável, monotônica, cap de 17–21 dias adequado para retenção D21

**Infraestrutura:**
- SQLite WAL com restore probe automatizado no CI (quando ativado)
- Docker/Coolify stack documentada com guia de deploy
- Suítes de teste cobrindo XP curve, settle, ledger, guild, seasons, rebirth
- Hotfix do D1 gate (dois relógios) resolvido corretamente com documentação detalhada

**Decisões arquiteturais:**
- Server-authoritative: cliente nunca envia estado — base correta para anti-cheat
- Migrations versionadas sem raw ALTER em produção
- Companion Python isolado para transações financeiras — separação de responsabilidades adequada

---

## ROADMAP SUGERIDO

### Sprint 1 — Semana 1–2: Críticos (10–12 dias-homem)

**Objetivo:** Atingir estado seguro para beta fechado sem dinheiro real

| # | Item | Esforço | Responsável |
|---|---|---|---|
| C-11 | Corrigir CI (actions@v4) + primeira execução bem-sucedida | 0,5d | eng |
| C-07 | Corrigir cloudflared no docker-compose + validar deploy | 0,5d | eng |
| C-06 | Mover WAL + busy_timeout para fora do guard debug | 0,5d | eng |
| C-03 | Corrigir SQL injection em BuyVendorOffer e _LotCondition | 1d | eng |
| C-02 | Corrigir SQL.Transaction else perigoso | 0,5d | eng |
| C-04 | Corrigir race condition em mutexes sharded | 1d | eng |
| C-05 | Corrigir GrantItem verificação de catálogo | 0,5d | eng |
| C-01 | TwoFactorAuth: CSPRNG + constant-time compare + replay | 2d | eng |
| C-08 | LGPD: contratar advogado + redigir política + tela de aceite | 5d | dono + eng |
| C-09 | Rebirth: decisão de design + implementação de incentivo mínimo | 3d | dono + eng |
| C-10 | Conteúdo D30: ativar seasons + 2 bosses elementais adicionais | 5d | eng + design |
| A-01 | Backup offsite real (S3/R2) | 1d | eng/ops |

---

### Sprint 2 — Semana 3–4: Altos (16–20 dias-homem)

**Objetivo:** Qualidade de produção para beta pago

| # | Item | Esforço |
|---|---|---|
| A-02 | Docker healthcheck no serviço game | 0,5d |
| A-03 | Thread safety em SQLBackups (call_deferred) | 1d |
| A-04 | IdlePolicy kill detection duplicada | 1d |
| A-05 | OfflineSettle session_efficiency guard de null | 0,5d |
| A-07 | Stats.AddExperience verificar retorno de AddEssence | 0,5d |
| A-08 | _AutoClaimPass: liberar mutex antes da iteração | 1d |
| A-09 | LoginWithTwoFactor: validar accountID vs. sessão | 1d |
| A-10 | Transmitir SnapshotMetrics ao cliente (feedback idle) | 2d |
| A-11 | Onboarding: highlight visual real + sequência mínima | 2d |
| A-12 | AfkReport: estado de loading explícito | 0,5d |
| A-13 | Acessibilidade: ícones/símbolos além de cor | 1d |
| A-14 | Web bundle: mover música para CDN + CI enforcer | 1d |
| A-15 | Sinks de ouro: implementar reforge básico | 3d |
| A-16 | AH: auditoria e implementação de controles anti-bot | 2d |
| A-17 | PowerScore: incluir bônus elemental | 1d |
| A-18 | AutoIdleTimeout: 10s → 45s + pausar em UI aberta | 0,5d |
| A-19 | Formula.randf(): RNG por instância | 0,5d |
| A-20 | WorldAgent.agents: proteger com mutex | 0,5d |
| A-21 | Checkout: constraint unique por external_reference | 1d |
| A-22 | SQL.Wipe(): guard de debug | 0,5d |
| A-23 | IdlePolicyService: guard de retryAttach concorrente | 0,5d |

---

### Sprint 3 — Mês 2: Médios (12–16 dias-homem)

**Objetivo:** Polimento, performance e preparação para escala

| # | Item | Esforço |
|---|---|---|
| M-01 | UpdateProgress: batch queries + transação | 2d |
| M-02/03 | GetChestStats unificado + migrations de índices | 1d |
| M-04 | UpdateCharacter: UPDATE direto sem read-modify-write | 0,5d |
| M-05 | ConsumeItemLotsRaw: assertion de transação | 0,5d |
| M-06/21 | CI: medição de bundle completa + benchmarks reais | 1d |
| M-07 | Confirmar rate limiting em todos os RPCs idle | 1d |
| M-08 | Resolver precificação dupla de VIP | 1d |
| M-09 | Filtro de elegibilidade de missões + expandir pool | 1d |
| M-10 | Newbie Boost no offline settle | 1d |
| M-11 | Sentry: mudar para opt-in | 0,5d |
| M-12 | I18N: auditar e corrigir strings hard-coded | 1d |
| M-13/14/15/16 | UX mobile: rotação de tela + fixes de memória | 2d |
| M-17 | Documentar métricas de trigger para PostgreSQL | 0,5d |
| M-19 | Conteúdo: resistências elementais de mobs | 1d |
| M-22/23 | Season pass: preencher trilha grátis + SKU entry-level | 0,5d |
| M-24/25 | Compliance shop: timer legal + histórico de compras | 1d |
| M-27 | ConfirmPasswordReset: atomicidade | 0,5d |
| M-28/29/30 | Bugs de código: Action.gd, ZonePolicy, sharding +1 | 1d |

---

## APÊNDICE: MAPEAMENTO BETA_DEBT vs. ACHADOS

Os seguintes itens do BETA_DEBT.md têm cobertura direta neste relatório:

| BETA_DEBT # | Descrição | Relatório |
|---|---|---|
| #1 | Ativação de Seasons | C-10 |
| #3 | Restore S3 real com RPO/RTO | A-01 |
| #4 | Rewarded ads reais | — (fora do escopo desta auditoria) |
| #5 | Conta MP + primeira compra sandbox | A-21, M-08 |
| #6 | Handlers 2FA server-side ausentes | C-01 |
| #7 | CI com créditos (workflows nunca executados) | C-11 |
| #9 | Observabilidade (Sentry DSN) | M-11, M-17 |
| #11 | Trilha de auditoria GM | — (ALTO não listado separadamente — adicionar ao backlog) |
| #12 | 2FA obrigatório para staff | C-01 (extensão) |
| #13 | Painel ops fora do jogo | M-17 (parcialmente) |

---

---

## APLICAÇÃO DE CORREÇÕES — Checkout `b93ce41`

As correções abaixo foram aplicadas em `b93ce41` (20/09/2026). Itens não listados permanecem no estado original do relatório.

### 🔴 Críticos aplicados
- **C-01** `TwoFactorAuth`: CSPRNG via `Crypto.generate_random_bytes()`, comparação constant-time, hash de token, replay protection persistente (`038_two_factor_replay.sql` + `ConsumeTwoFactorToken`).
- **C-02** `SQL.Transaction`: removido `callable.call()` no `else` de `BEGIN` falho.
- **C-03** `BuyVendorOffer`/`_LotCondition`: substituídas interpolações de string por `query_with_bindings`; `_LotCondition` retorna condição parametrizada.
- **C-04** `EconomyService`: adicionado `_shardInitMutex` com double-checked locking no sharding de mutexes.
- **C-05** `GrantItem`: validação de item agora usa `DB.ItemsDB.has()`.
- **C-06** `SQL._post_launch`: WAL/busy_timeout/synchronous=NORMAL habilitados fora de debug builds.
- **C-07** `docker-compose.yml`: `cloudflared` movido de `volumes` para `services`.
- **C-08** LGPD: adicionada migration `039_consent_log.sql` e helpers `LogConsent`/`GetConsent`; `SetConsentAccepted` agora registra histórico.

### 🟠 Altos aplicados
- **A-03** `SQLBackups`: removido `Thread.set_thread_safety_checks_enabled(false)`; `BackupPlayers` agora via `call_deferred`.
- **A-04** `IdlePolicy._tickCombat`: adicionado guard `_killRegistered` para evitar duplicação de contagem de kills.
- **A-05** `OfflineSettle`: adicionado guard null-safe em ambas as leituras de `session_efficiency`.
- **A-06** `BossService`: adicionado TTL de 300s ao cache de `_entityHashCache`.
- **A-07** `Stats.AddExperience`: verifica retorno de `AddEssence` e loga erro se falhar.
- **A-08** `EconomyService._AutoClaimPass`: coleta elegíveis antes de travar `settleMutex` por conta.
- **A-09** `LoginWithTwoFactor`: validação de accountID já existia via `ValidateTwoFactorChallenge`.
- **A-10** `AfkReport`: adicionado estado de loading no `_ready()`.
- **A-11** `Onboarding`: highlight funcional já existia (borda amarela temporária).
- **A-12** `AfkReport`: adicionado símbolo textual ▲/→/▼ além da cor na eficiência.
- **A-19** `Formula.randf()`: não aplicável em Godot 4.7 (thread-local desde 4.2).
- **A-20** `WorldAgent`: adicionado `_agentsMutex` protegendo `GetAgent`/`AddAgent`/`RemoveAgent`.
- **A-22** `SQL.Wipe()`: adicionado `assert(OS.is_debug_build())` + guard de produção.

### 🟡 Médios aplicados
- **M-02** `GetChestStats`: substituídas duas queries COUNT por uma única com SUM/CASE.
- **M-03** Índices SQL: adicionada migration `040_performance_indexes.sql` com `idx_character_account` e `idx_item_char_item`.
- **M-04** `UpdateCharacter`: substituído read-modify-write por UPDATE direto com `total_time = total_time + ?`.
- **M-07** `ClaimOfflineSettle`/`OpenChest`: adicionados `Footprint.CheckAction`.
- **M-10** `OfflineSettle`: adicionado newbie boost 5× para chars < nível 10 no offline settle.
- **M-11** `Monitoring`: default de `Privacy-BugReports` alterado para `false` (opt-in).
- **M-12** `Settings`: strings "Language" e "UI Scale" agora usam `tr()`.
- **M-13** `FloatingWindows`: `_on_window_resized` agora detecta rotação e chama `ResetWindowsLayout()`.
- **M-14/M-16** `Settings`: `_verifyDialog` guardado como referência; `queue_free()` antes de recriar.
- **M-15** `FloatingWindows`: `_ready` protege conexão de sinal `MoveFloatingWindowToTop`.
- **M-27** `ConfirmPasswordReset`: update/invalidação/token removal agora dentro de `SQL.Transaction`.
- **M-28** `Action.Enable`: corrigida lógica invertida (`disableCounter += (-1 if enable else 1)`).

### 🟢 Baixos aplicados
- **B-09** `UpdateProgress`: adicionada verificação de retorno e log de erro para `SetQuest`/`SetBestiary`/`SetSkill`.
- **B-10** `Action.GetMove`: removida normalização duplicada que anulava o deadzone.
- **B-11** `OnBossResult`: guard `player.idlePolicy == null` já existia na entrada.

---

*Relatório compilado por auditoria técnica e de produto — Shambleta, 20/09/2026.*  
*Baseado em análise estática de código, revisão de documentação arquitetural, e avaliação de design de produto.*  
*Este documento deve ser revisado e atualizado após cada sprint.*
