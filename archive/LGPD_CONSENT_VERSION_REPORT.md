# LGPD — Gate de versão de consentimento (re-aceite obrigatório em bump)

Data: 2026-09-15 · Origem (QA): "`SQL.HasConsent` hoje só checa se a versão salva é não-vazia, não se ela bate com a versão atual — bumpar a constante não obriga contas existentes a reaceitar."

Confirmado — e pior: o predicate chamava-se `IsConsentAccepted(accountID)` e **não tinha nenhum chamador no fluxo de login**; o único gate real era o checkbox de cadastro (`consentAccepted` em `CreateAccount`). Além disso, a comparação antiga `str(...) != ""` trataria `NULL` (colunas de contas pré-migração, via `ALTER TABLE ADD COLUMN`) como consentimento (`str(null) == "<null>"` não é vazio).

## O que mudou

**`sources/sql/SQL.gd`**
- `IsConsentAccepted(accountID, tosVersion, privacyVersion)`: exige **igualdade exata** com as versões passadas (bump em qualquer um dos dois → `false`); `null` no storage → `false`; e vazio em qualquer lado da comparação → `false` (uma versão de aceite nunca é string vazia).
- `SetConsentAccepted(accountID, tos, privacy, ip)`: persiste as versões + `consent_timestamp` + `consent_ip` (update single-row `db.update_rows`, mesmo estilo de `UpdatePowerScore` — fora de transação).

**`sources/network/server/Server.gd`**
- `LoginWithPassword` e `LoginWithToken`: após a validação de credencial (lockout/validade de token inalterados), gate `IsConsentAccepted(<versões atuais>)` → `ERR_CONSENT_REQUIRED` **antes** de `FinalizeLogin` (nenhuma meia-sessão autenticada fica exposta; no fluxo token, `RefreshAuthToken` só roda no sucesso completo, como antes).
- Novo RPC `AcceptConsent(accountName, password, token, rememberMe, platform, peerID)`: **re-verifica a credencial que o cliente enviou** (password com o mesmo predicado de lockout do login, ou token válido via `ValidateAuthToken`) — nunca aceita um `accountName` nu — então grava as versões correntes com IP/ts e **completa o login original** na mesma resposta (`FinalizeLogin` → `ERR_OK` conduz o FSM do cliente pelo caminho normal; sem replay de senha pelo usuário).

**`sources/network/Network.gd`** — stub `@rpc` `AcceptConsent(...)` seguindo o padrão `LoginWithToken` (dispatch por nome `callv`, sem allowlist a registrar).

**`sources/gui/Login.gd`** — caches `lastAuthAccount/Password/Token` da última tentativa; no ramo `ERR_CONSENT_REQUIRED` de `FillWarningLabel`, se o contexto é LOGIN (checkbox de cadastro não visível), abre um `AcceptDialog` de re-aceite gerado em runtime (title "Agreements Update", OK = aceite afirmativo) que chama `Network.AcceptConsent(...)` com as credenciais em cache; o contexto de cadastro mantém o comportamento antigo (foco no checkbox).

## Sem impacto em contas existentes hoje

As versões gravadas no aceite de cadastro são exatamente as constantes correntes (`2026-09`/`2026-09`) — inclusive a conta `dev` no DB real de QA: o gate passa. O efeito aparece no próximo bump de `NetworkCommons.AgreementTosVersion`/`AgreementPrivacyVersion`: todas as contas param no `AcceptConsent` até re-aceitar.

## Testes (SuiteLGPD, +6 checks: 561→567)

- aceite com versões atuais → `true`; qualquer versão divergente (ToS ou Privacy) → `false`;
- `SetConsentAccepted` grava e passa na nova, e faz as versões antigas **deixarem de contar**;
- conta sem aceite (`""`) → `false`; pós-erase (`""` + `null`-safe) → `false` mesmo contra `("","")`.

## Validação

Suíte completa headless pós-mudança, janela default de 300s: **567 checks, 0 failures**. (Nota operacional: o teto de 200/h é calibrado para janelas ≥180s; com `SOM_REALTIME_SECS=60` o burst inicial da instância recém-warm lida ~4 kills no primeiro minuto e aciona o teto — não usar janelas menores que ~120s para esse gate.)
