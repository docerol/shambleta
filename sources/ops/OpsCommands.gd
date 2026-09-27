extends CommandCollection
class_name OpsCommands

# OPS-2 (AUDITORIA_2026-09-27 §15: "sem painel admin"): a superfície de admin das
# flags é um comando de chat GM, não um HTTP novo. Motivo: o repo já tem o
# dispatcher de permissão (`CommandManager` + `Peers.GetPermission`, lido da
# coluna `account.permission` desde a correção de C1), já tem feedback ao operador
# (`Network.CommandFeedback`) e já tem precedente de comando que confere a própria
# permissão no handler (`/season create` em `WorldCommands`). Um painel novo seria
# segunda autoridade de sessão ao lado do `Peers` — exatamente o par que a
# auditoria de 2026-09-24 chamou de fronteira perigosa.
#
# Régua de quem mexe em flag de receita, na ordem e sem atalho:
#   1. kill switch `ops_flags_admin` ligado (default: desligado) — sem isto o
#      comando não existe, nem para GM. É o "config" do tripé.
#   2. `Peers.GetPermission() >= GM` conferido AQUI, não só no dispatcher: o
#      `SHAMBLETA_GM_MODE=1` de dev/staging derruba a checagem de permissão de
#      todos os comandos (`CommandManager.Handle`), e uma surface que escreve
#      estado de receita não pode herdar esse bypass.
#   3. em debug build o 2 ainda vale — o que o build liberar é só a conveniência
#      de o GM existir sem subir tabela de permissão à mão, nunca a remoção do
#      portão.
#
# Registro em `FlagsBootstrap` (não em `WorldCommands`): o arquivo dos comandos do
# mundo está na allowlist do gate anti-god-node como legado em fatiação, e a
# allowlist registra legado, não autoriza crescimento.

func RegisterCommands():
	CommandManager.Register("flags", CommandFlags, ActorCommons.Permission.GM,
		"flags [list | get <chave> | set <chave> <0|1> | reload | why <chave>]")

static func UnregisterCommands():
	CommandManager.Unregister("flags")

func CommandFlags(caller : PlayerAgent, arg : String = "") -> bool:
	if not caller:
		return false
	var peerID : int = caller.peerID
	if not FeatureFlags.Enabled(FeatureFlags.FLAGS_ADMIN):
		Network.CommandFeedback("Feature flags admin is off (ops_flags_admin)", peerID)
		return false
	if Peers.GetPermission(peerID) < ActorCommons.Permission.GM:
		Network.CommandFeedback("GMs only", peerID)
		return false

	var parts : PackedStringArray = arg.strip_edges().split(" ", false)
	var sub : String = String(parts[0]).to_lower() if not parts.is_empty() else "list"

	if sub == "list" or sub == "":
		var lines : PackedStringArray = PackedStringArray()
		lines.append("feature flags (%d no banco)" % FeatureFlags.Reload())
		for key in FeatureFlags.Known():
			lines.append("%s = %s [%s default %d] — %s" % [key, FeatureFlags.Value(key),
				FeatureFlags.Source(key), 1 if FeatureFlags.DefaultOf(key) else 0,
				String(FeatureFlags.Reasons.get(key, ""))])
		Network.CommandFeedback("\n".join(lines), peerID)
		return true

	if sub == "why":
		if parts.size() < 2:
			Network.CommandFeedback("Usage: /flags why <chave>", peerID)
			return false
		var whyKey : String = String(parts[1]).to_lower()
		var stamp : int = FeatureFlags.UpdatedAt(whyKey)
		Network.CommandFeedback("%s = %s [%s]%s" % [whyKey, FeatureFlags.Value(whyKey),
			FeatureFlags.Source(whyKey),
			" atualizado %s" % Time.get_datetime_string_from_unix_time(stamp) if stamp > 0 else ""], peerID)
		return true

	if sub == "get":
		if parts.size() < 2:
			Network.CommandFeedback("Usage: /flags get <chave>", peerID)
			return false
		var getKey : String = String(parts[1]).to_lower()
		Network.CommandFeedback("%s = %s (%s)" % [getKey, FeatureFlags.Value(getKey),
			FeatureFlags.Source(getKey)], peerID)
		return true

	if sub == "reload":
		var loaded : int = FeatureFlags.Reload()
		Network.CommandFeedback("Flags recarregadas: %d" % loaded if loaded >= 0
			else "Sem banco: flags só por env/default", peerID)
		return loaded >= 0

	if sub == "set":
		if parts.size() < 3:
			Network.CommandFeedback("Usage: /flags set <chave> <0|1>", peerID)
			return false
		var key : String = String(parts[1]).to_lower()
		var value : String = String(parts[2]).strip_edges().to_lower()
		if not FeatureFlags.IsKnown(key):
			Network.CommandFeedback("Chave desconhecida: %s (conhecidas: %s)" % [key, ", ".join(FeatureFlags.Known())], peerID)
			return false
		if value != "0" and value != "1":
			Network.CommandFeedback("Valor aceito é 0 ou 1", peerID)
			return false
		if not FeatureFlags.Set(key, value):
			Network.CommandFeedback("Não persistiu (banco indisponível?)", peerID)
			return false
		# Toda mudança de flag é telemetria de operação: o funil precisa conseguir
		# responder "o que estava ligado quando este número caiu?". Valor, fonte e
		# autor vão no meta do evento.
		if Launcher.Telemetry != null:
			Launcher.Telemetry.Record("flag_change", 0, 0, value.to_int(), JSON.stringify({
				"key" = key, "source" = "db", "by" = caller.nick, "permission" = int(Peers.GetPermission(peerID))}))
		Util.PrintLog("Ops", "%s (%d) mudou %s = %s" % [caller.nick, peerID, key, value])
		Network.CommandFeedback("%s = %s (persistido)" % [key, FeatureFlags.Value(key)], peerID)
		return true

	Network.CommandFeedback("Subcomando desconhecido. Uso: /flags list|get|set|why|reload", peerID)
	return false
