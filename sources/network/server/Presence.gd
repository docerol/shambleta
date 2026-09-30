extends RefCounted
class_name Presence

# AUDITORIA_2026-09-27 §12 — a metade durável da presença. `Peers.peers` e
# `OnlineList.byNick` vivem no processo e morrem com ele: um segundo servidor não
# enxerga os jogadores do primeiro e o "quem está online" de guild/social respondia
# sobre meia população. A migration 057 deu endereço a isso (`presence_session`,
# chave por personagem, que é a unidade que os painéis consultam); este módulo é o
# ÚNICO caminho que escreve e lê essa tabela. O índice em memória continua lá para
# a latência — ninguém bate no banco no clique de um painel — e o banco passa a ser
# a verdade compartilhada entre processos.
#
# `now` entra como parâmetro em toda função sensível a tempo, de propósito: "online"
# É `last_seen_at >= now - TTL`, e um módulo que lesse o relógio por conta própria
# não poderia ser confrontado nas duas direções do vencimento. Os relógios quem
# trazem são os chamadores: `Server.gd` nos eventos de sessão, `World.gd` no tick de
# 1 s, `SQL.gd` no boot.
#
# Custo — o que decide a forma de cada função aqui:
#  - o heartbeat NÃO é por jogador, é por processo: `Touch` renova a cauda viva
#    inteira deste `server_id` com UMA statement. Por personagem custaria um write
#    por minuto atrás da mesma `queryMutex` do settle (`sources/sql/SQL.gd:@queryMutex`), que
#    é exatamente o degrau que a auditoria apontou. Medido em
#    `tests/presence_fuzz.gd`.
#  - escrita de sessão é UPSERT de uma statement chaveada em `char_id`: reconexão
#    não abre segunda linha e `connected_at` fica o da primeira inserção — é a
#    sessão que o produto quer como "está aqui desde".
#  - `Prune` varre por `last_seen_at` e `QueryOnline`/`IsOnlineDurable` por
#    servidor/nick: cada uma casa com UM dos três índices da migration, e o plano é
#    asserido por `EXPLAIN QUERY PLAN` no mesmo harness, porque promessa de índice
#    sem régua é comentário.

# O heartbeat de 60 s é o triplo do degrau de latência da consulta social (o painel
# de guild lê o índice em memória, não daqui) e um sexto do orçamento de presença da
# auditoria: com `Touch` sendo uma statement, subir a cadência compra frescor sem
# comprar custo por jogador — descer não compra nada, porque o vencimento é 3× ela.
const HeartbeatSecEnv : String			= "SHAMBLETA_PRESENCE_HEARTBEAT_SEC"
# Identifica o ESCRITOR, não o mapa nem a shard: `ReclaimServer` apaga a cauda deste
# id no boot, então dois processos que dividissem o mesmo id apagariam a presença um
# do outro. Um `server_id` por processo que escreve em `presence_session` é o
# contrato (deploy/SCALING.md §7).
const ServerIDEnv : String				= "SHAMBLETA_SERVER_ID"

const DefaultHeartbeatSec : int			= 60
# Três batidas perdidas antes de declarar morto: uma única batida atrasada por um
# stall de checkpoint (`wal_autocheckpoint` em `sources/sql/SQL.gd:1748`) não pode
# tirar alguém da lista de online.
const TtlHeartbeats : int				= 3
# Cadência da varredura de vencidos, independentemente do heartbeat: um processo que
# morreu sem passar por `DisconnectCharacter` deixa a linha, e é isto aqui que a
# retira. Mais freqüente que isso é DELETE sem trabalho, menos é fantasma por mais
# tempo que o TTL promete.
const DefaultPruneEverySec : int		= 300
const DefaultServerID : String			= "default"

# Estado do accumulator de tick. É static porque o chamador é o `_process` do mundo
# e nenhum deles quer carregar um objeto de presença; o preço é existir um único
# relógio de acumuladores por processo — que é o desenho (um escritor por servidor).
static var _heartbeatAccum : float		= 0.0
static var _pruneAccum : float			= 0.0

# Leitura do ambiente com teto: `0` ou lixo não desliga a presença, volta ao padrão.
# Um operador que errar um dígito não pode ganhar de presente "ninguém fica online".
static func HeartbeatSec() -> int:
	var raw : String = OS.get_environment(HeartbeatSecEnv).strip_edges()
	if not raw.is_valid_int():
		return DefaultHeartbeatSec
	var secs : int = int(raw)
	return secs if secs > 0 else DefaultHeartbeatSec

static func TTLSec() -> int:
	return HeartbeatSec() * TtlHeartbeats

static func PruneEverySec() -> int:
	return DefaultPruneEverySec

static func ServerID() -> String:
	var raw : String = OS.get_environment(ServerIDEnv).strip_edges()
	return raw if not raw.is_empty() else DefaultServerID

# Corte de liveness, na única forma que o banco entende: o instante a partir do qual
# a linha ainda é "online". Existe uma só definição desta linha no repo — é daqui
# que `Prune`, `QueryOnline` e `IsOnlineDurable` saem concordando por construção.
static func LiveCutoff(now : int, ttl : int) -> int:
	return now - maxi(ttl, 0)

# UPSERT de uma statement (ver cabeçalho). `connected_at` não sai na cláusula de
# atualização de propósito: é a primeira inserção que responde "desde quando".
static func Report(sql : Object, charID : int, accountID : int, nick : String, zoneID : int, now : int, serverID : String = "") -> bool:
	if sql == null or charID <= 0:
		return false
	var server : String = ServerID() if serverID.is_empty() else serverID
	return bool(sql.ExecuteBindings(
		"INSERT INTO presence_session (char_id, account_id, nick, server_id, zone_id, connected_at, last_seen_at)"
		+ " VALUES (?, ?, ?, ?, ?, ?, ?)"
		+ " ON CONFLICT(char_id) DO UPDATE SET nick = excluded.nick, server_id = excluded.server_id,"
		+ " zone_id = excluded.zone_id, last_seen_at = excluded.last_seen_at;",
		[charID, accountID, nick, server, zoneID, now, now]))

# Desconexão limpa: a linha sai, e o que fica para trás é só o que o TTL ainda não
# alcançou (processo morto). `char_id` é PK, então é seek, não varredura.
static func Forget(sql : Object, charID : int) -> bool:
	if sql == null or charID <= 0:
		return false
	return bool(sql.ExecuteBindings("DELETE FROM presence_session WHERE char_id = ?;", [charID]))

# UMA statement por tick, para quantos personagens forem: renova a cauda viva deste
# escritor. É a resposta ao "custo marginal de presença" que a migration promete
# limitado pelo heartbeat — com o id no `WHERE` casa no prefixo `server_id` de
# `idx_presence_server`, que é o mesmo plano asserido no harness.
static func Touch(sql : Object, now : int, serverID : String = "") -> bool:
	if sql == null:
		return false
	var server : String = ServerID() if serverID.is_empty() else serverID
	return bool(sql.ExecuteBindings("UPDATE presence_session SET last_seen_at = ? WHERE server_id = ?;", [now, server]))

# Vencidos saem. Sem escopo por servidor de propósito: a cauda de um `server_id`
# aposentado não tem mais nenhum processo para reclamá-la, e o índice desta varredura
# é justamente o `idx_presence_seen` que a migration criou para ela.
static func Prune(sql : Object, now : int, ttl : int) -> bool:
	if sql == null:
		return false
	return bool(sql.ExecuteBindings("DELETE FROM presence_session WHERE last_seen_at < ?;", [LiveCutoff(now, ttl)]))

# Quem está online neste servidor, na voz do banco. Ordem por nick é a ordem do
# painel; o teto de linhas é o CCU declarado do §12, então um `ORDER BY` aqui não é
# risco de memória — é o caminho que um segundo processo usa para não depender da
# própria lista.
static func QueryOnline(sql : Object, serverID : String, now : int, ttl : int = 0) -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	if sql == null:
		return out
	var ttlSec : int = TTLSec() if ttl <= 0 else ttl
	var rows : Array = sql.QueryBindings(
		"SELECT nick FROM presence_session WHERE server_id = ? AND last_seen_at >= ? ORDER BY nick;",
		[serverID, LiveCutoff(now, ttlSec)])
	for row in rows:
		out.append(str(row.get("nick", "")))
	return out

# Presença durável por nick: o complemento do `OnlineList.byNick` em memória. É O(1)
# por `idx_presence_nick` e `LIMIT 1` porque a pergunta é binária.
static func IsOnlineDurable(sql : Object, nick : String, now : int, ttl : int = 0) -> bool:
	if sql == null or nick.is_empty():
		return false
	var ttlSec : int = TTLSec() if ttl <= 0 else ttl
	var rows : Array = sql.QueryBindings(
		"SELECT char_id FROM presence_session WHERE nick = ? AND last_seen_at >= ? LIMIT 1;",
		[nick, LiveCutoff(now, ttlSec)])
	return not rows.is_empty()

# Boot: qualquer linha com o MEU id veio de um processo que não passou por
# `DisconnectCharacter` — inclusive eu, na vida anterior. Reclamar no boot é o que
# faz o restart não herdar fantasma; um processo vivo com id próprio nunca apaga a
# cauda alheia. Fica ao lado da limpeza de tokens vencidos em `sources/sql/SQL.gd`.
static func ReclaimServer(sql : Object, serverID : String = "") -> bool:
	if sql == null:
		return false
	var server : String = ServerID() if serverID.is_empty() else serverID
	return bool(sql.ExecuteBindings("DELETE FROM presence_session WHERE server_id = ?;", [server]))

# Coração do caminho quente: acumula o delta do tick e despeja no banco no máximo
# uma statement por cadência. Os dois acumuladores são separados porque os dois
# trabalhos têm frequências diferentes (renovar é minuto, podar é cinco) — e é a
# separação que permite ao harness asserir "um tick de heartbeat = UMA statement".
static func Tick(sql : Object, deltaSec : float, now : int) -> void:
	if sql == null:
		return
	_heartbeatAccum += deltaSec
	if _heartbeatAccum >= float(HeartbeatSec()):
		_heartbeatAccum = 0.0
		Touch(sql, now)
	_pruneAccum += deltaSec
	if _pruneAccum >= float(PruneEverySec()):
		_pruneAccum = 0.0
		Prune(sql, now, TTLSec())

# Régua do harness: o tick é estado static, e medir "uma statement por tick" pede
# partir do zero sem reiniciar o processo.
static func ResetTickState() -> void:
	_heartbeatAccum = 0.0
	_pruneAccum = 0.0
