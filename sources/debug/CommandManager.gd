extends RefCounted
class_name CommandManager

# GM bypass deixou de ser consequência de build: um export acidental de debug
# entregava a conta de qualquer jogador com permissão plena de comando. A
# régua agora é sempre conferida; a única saída é o operador declarar
# SHAMBLETA_GM_MODE=1 (dev/staging). Lido por função porque um static var só
# seria atualizado por um bootstrap que não existe para esta classe.
const GM_MODE_ENV : String = "SHAMBLETA_GM_MODE"

static func GMModeEnabled() -> bool:
	return OS.get_environment(GM_MODE_ENV) == "1"

# Variables
static var commands : Dictionary[StringName, Command]				= {}

# Handling

# Handling
static func Register(commandName : StringName, callable : Callable, permission : ActorCommons.Permission, description : String):
	if commands.has(commandName):
		push_error("Command '%s' could not be registered as it is already registered" % commandName)
		return
	commands[commandName] = Command.new(callable, permission, description)

static func Unregister(commandName : StringName):
	if not commands.has(commandName):
		push_error("Command '%s' could not be un-registered as it has not been previously registered" % commandName)
		return
	commands.erase(commandName)

static func Handle(caller : PlayerAgent, commandStr : String):
	if commandStr.is_empty():
		Network.CommandFeedback("Empty command sent", caller.peerID)
		return

	var args : Array = Parse(commandStr)
	if args.is_empty():
		Network.CommandFeedback("Invalid command sent", caller.peerID)
		return

	var commandName : StringName = args.pop_front().to_lower()
	var command : Command = commands.get(commandName, null)
	var playerPermission : ActorCommons.Permission = Peers.GetPermission(caller.peerID)
	if not command:
		Network.CommandFeedback("Command '%s' is not registered" % commandName, caller.peerID)
	elif not GMModeEnabled() and command._permission > playerPermission:
		Network.CommandFeedback("Command '%s' could not be called due to unmet permissions" % commandName, caller.peerID)
	elif not args.is_empty() and args[0] == "?":
		Network.CommandFeedback("Command usage: %s" % command._description, caller.peerID)
	elif not command.Call(caller, args):
		Network.CommandFeedback("Command '%s' could not be called due to incorrect arguments" % commandName, caller.peerID)
	# Command succeeded
	elif command._permission > ActorCommons.Permission.NONE:
		Util.PrintLog("Command", "%s (%d) used: %s" % [caller.nick, caller.peerID, commandStr])

# Utils
static func Parse(command : String) -> Array:
	var tokens : Array = []
	var current : String = ""
	var withinQuotes : bool = false

	for c in command:
		match c:
			'"':
				withinQuotes = !withinQuotes
			' ':
				if withinQuotes:
					current += c
				elif not current.is_empty():
					tokens.append(current)
					current = ""
			_:
				current += c

	if not current.is_empty():
		tokens.append(current)

	return tokens
