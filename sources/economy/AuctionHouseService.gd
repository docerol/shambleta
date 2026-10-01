extends RefCounted
class_name AuctionHouseService

# SOM-IDLE Fatia 4 (ROADMAP_COMERCIAL S3): domínio de auction house extraído de
# EconomyService (E2 listings + S2 bot seed). Composição com back-reference
# (_eco): o serviço não tem transação nem mutex próprios — usa o MESMO
# settleMutex e os MESMOS helpers raw de EconomyService, então a semântica de
# locking é 100% idêntica à de antes da extração. Os wrappers públicos ficam em
# EconomyService (callers não mudam: WorldCommands + Server via Launcher.Economy).
# Gold de leilão (compra, crédito ao vendedor e fee ao criador) passa pelo
# caminho único do kernel — _eco.kernel._MoveGoldLocked na transação +
# ApplyGoldMoves no commit — porque SQL.UpdateStat persiste o stat row como
# snapshot da memória: escrita crua em stat.gp sem o espelho evapora no ciclo de
# backup de 600 s. Gems não: wallet é account-level e não tem espelho em memória.

var _eco : EconomyService = null

# ------------------------------------------------------------------ S2: AH bot seed
# A AH nasce morta sem oferta (cold start clássico de marketplace). Bots de
# sistema listam consumíveis do vendor a preço-âncora (~20% acima); jogador
# compra pelo caminho NORMAL (BuyListing), o gold do jogador paga o bot e fica
# retido (sink — o bot nunca recompra, então o estoque é finito por design).
# Trava T5-style: SHAMBLETA_AH_BOTS=1 (staging/soft-launch liga; beta off).

static func AHBotsEnabled() -> bool:
	return OS.get_environment("SHAMBLETA_AH_BOTS") == "1"

var _ahBotsChecked : bool = false

# ------------------------------------------------------------------ #93/#94/#100 (rodada 3, cadeira Marketplace 7,0/7,6)
# Quatro números e um relógio. Todos vivem AQUI (e não em `EconomyCatalog`, arquivo
# que esta rodada não me dá): são knobs do DOMÍNIO leilão, do mesmo jeito que
# `AHMaxBidFillRounds` já era do laço de preenchimento.
#
# `AHListingTtlSec` é o prazo do anúncio (achado #93.4: sem ele o ask espera o alt
# para sempre com o item trancado fora do inventário do dono — é o que torna a
# lavagem BARATA, não apenas arriscada). `AHReapBatch`/`AHLifecycleBatch` são o
# teto de linhas tocadas por passada: nenhuma varredura do leilão pode virar o
# laço O(n²) sobre a vitrine no main thread do servidor. `AHLifecycleIntervalSec`
# é o passo do relógio do processo (o sweep periódico), e `AHBootSweepBatches` é o
# teto da passada de boot — o resto continua de onde parou no tick periódico.
const AHListingTtlSec : int = 3 * 86400
const AHLifecycleIntervalSec : int = 300
const AHLifecycleBatch : int = 50
const AHBootSweepBatches : int = 20

# Volume diário por conta no leilão (achado #93.3: a troca direta tem e-mail
# verificado + cooldown de 60 s + teto diário; o leilão herdava zero disso). O
# cap não é punição e não é raro — é o fim da granja de ciclos: uma lavagem
# precisa de MUITOS anúncios e MUITAS compras por dia para mover volume, e 50
# operações por perna por dia é o mercado normal cabe folgado (o fuzzer de
# invariantes, com 700 ops sobre 4 contas, não encosta) enquanto o loop de alt
# deixa de ser esteira. Contado por conta, no mesmo bucket UTC de
# `EconomyCatalog.ShopDay`, durável em `ah_activity` (migração 063).
const AHMaxListingsPerDay : int = 50
const AHMaxBuysPerDay : int = 50

var _ahLifecycleDone : bool = false
var _ahNextTickAt : int = 0
# Cursor da varredura de re-cruzamento (keyset sobre `idx_auction_open(status,id)`).
var _ahSweepAfterID : int = 0

# O gancho é o MESMO `_process` do servidor que já chama a semente dos bots: um
# arquivo acima (`EconomyService._process`) chama `_trySeedAuctionBots()` a cada
# frame, e
# foi `EconomyService.gd`/`Server.gd`/`World.gd` que esta rodada me proibiu de
# tocar. O trabalho é uma comparação de relógio por frame depois da primeira
# passada — o mesmo formato da trava `_ahBotsChecked` de cima, que existe justamente
# porque perguntar o ambiente por frame no main thread do server é desperdício.
func TickAHLifecycle(now : int = 0) -> Dictionary:
	var ts : int = now if now > 0 else SQLCommons.Timestamp()
	var out : Dictionary = {"reaped" = 0, "matched" = 0, "swept" = 0, "adopted" = 0, "boot" = false}
	if not _ahLifecycleDone:
		_ahLifecycleDone = true
		out["boot"] = true
		var reaped : Dictionary = ReapExpiredListings(ts, AHLifecycleBatch * AHBootSweepBatches)
		out["reaped"] = int(reaped.get("reaped", 0))
		out["adopted"] = int(reaped.get("adopted", 0))
		var boot : Dictionary = ReCrossOpenListings(ts, AHLifecycleBatch, AHBootSweepBatches)
		out["matched"] = int(boot.get("matched", 0))
		out["swept"] = int(boot.get("swept", 0))
		_ahNextTickAt = ts + AHLifecycleIntervalSec
		if int(out["reaped"]) > 0 or int(out["matched"]) > 0 or int(out["adopted"]) > 0:
			Util.PrintLog("Economy", "AH boot: %d expirados, %d cruzados em %d anúncios, %d sem prazo adotados" % [int(out["reaped"]), int(out["matched"]), int(out["swept"]), int(out["adopted"])])
		return out
	if ts < _ahNextTickAt:
		return out
	_ahNextTickAt = ts + AHLifecycleIntervalSec
	var reapedTick : Dictionary = ReapExpiredListings(ts, AHLifecycleBatch)
	out["reaped"] = int(reapedTick.get("reaped", 0))
	out["adopted"] = int(reapedTick.get("adopted", 0))
	var tick : Dictionary = ReCrossOpenListings(ts, AHLifecycleBatch, 1)
	out["matched"] = int(tick.get("matched", 0))
	out["swept"] = int(tick.get("swept", 0))
	return out

# ------------------------------------------------------------------ #93.3: volume diário por conta
# Mesmo bucket UTC da loja (`EconomyCatalog.ShopDay`) e durável em `ah_activity`
# (migração 063): um cap que vive na memória do processo é um cap que se reseta com
# o boot, e o boot é justamente o que um loop de lavagem pode esperar.

func AHActivityToday(accountID : int) -> Dictionary:
	return AHActivityLocked(Launcher.SQL, accountID)


func AHActivityLocked(sql : SQLService, accountID : int) -> Dictionary:
	var day : int = EconomyCatalog.ShopDay(SQLCommons.Timestamp())
	var rows : Array = sql.db.select_rows("ah_activity", "account_id = %d AND day = %d" % [accountID, day], ["lists", "buys"])
	if rows.is_empty():
		return {"lists" = 0, "buys" = 0, "day" = day}
	var row : Dictionary = rows[0]
	return {"lists" = int(row.get("lists", 0)), "buys" = int(row.get("buys", 0)), "day" = day}


# `lists`/`buys` são deltas (0 ou 1 na prática). Retorna falso se a escrita falhou
# — o chamador faz rollback, porque "cap não contabilizado" é exatamente a conta
# que o cap existe para fechar.
func _AHBumpActivityLocked(sql : SQLService, accountID : int, lists : int, buys : int) -> bool:
	if accountID == NetworkCommons.PeerUnknownID or (lists == 0 and buys == 0):
		return true
	var now : Dictionary = AHActivityLocked(sql, accountID)
	return sql.db.query_with_bindings("INSERT INTO ah_activity (account_id, day, lists, buys) VALUES (?, ?, ?, ?) ON CONFLICT(account_id, day) DO UPDATE SET lists = excluded.lists, buys = excluded.buys;", [accountID, int(now.get("day", 0)), maxi(0, int(now.get("lists", 0)) + lists), maxi(0, int(now.get("buys", 0)) + buys)])

# ------------------------------------------------------------------ #94: escrow com identidade
# `escrow_uids` é uma string de uid separada por vírgula: não diz QUANTAS unidades
# de cada lote entraram no anúncio, e é justamente isso que é preciso saber para
# devolver o item sem re-mintar. `ah_escrow_lot` (migração 063) é o snapshot do
# escrow — uma linha por (anúncio, uid) com o `count` tirado daquele lote e o
# resto da célula (bound, customfield, parent_uid, criador, reason, created_at).
# Invariante declarada e medida: há linha para todo anúncio ABERTO criado por este
# serviço, e nada além disso — `ListItemForSale` escreve, liquidação e reaper
# apagam.
#
# O plano de consumo replica `ConsumeItemLotsRaw` (uid ASC, take = min(have,
# remaining), só bound = 0 e customfield '') porque a função devolve só a LISTA de
# uids tocados. Roda na mesma transação, com o `settleMutex` tomado, então plano e
# consumo não podem divergir; a conferência do total depois do `ConsumeItemLotsRaw`
# é o que transforma uma divergência em rollback em vez de item duplicado.
func _LotAllocationRaw(sql : SQLService, charID : int, itemID : int, count : int) -> Array:
	if count <= 0:
		return []
	var plan : Array = []
	var remaining : int = count
	var lots : Array = sql.db.select_rows("item_instance", "char_id = %d AND item_id = %d AND storage = 0 AND bound = 0 AND customfield = ''" % [charID, itemID], ["uid", "count", "bound", "customfield", "parent_uid", "creator_account_id", "reason", "created_at"])
	for entry in lots:
		if remaining <= 0:
			break
		var lot : Dictionary = entry
		var have : int = int(lot.get("count", 0))
		if have <= 0:
			continue
		var piece : Dictionary = lot.duplicate()
		var take : int = mini(have, remaining)
		piece["take"] = take
		plan.append(piece)
		remaining -= take
	return plan if remaining == 0 else []


func _WriteEscrowSnapshotLocked(sql : SQLService, listingID : int, itemID : int, plan : Array) -> bool:
	for entry in plan:
		var piece : Dictionary = entry
		if not sql.db.query_with_bindings("INSERT INTO ah_escrow_lot (listing_id, uid, item_id, count, bound, customfield, parent_uid, creator_account_id, reason, lot_created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", [listingID, int(piece.get("uid", 0)), itemID, int(piece.get("take", 0)), int(piece.get("bound", 0)), str(piece.get("customfield", "")), int(piece.get("parent_uid", 0)), int(piece.get("creator_account_id", 0)), str(piece.get("reason", "")), int(piece.get("created_at", 0))]):
			return false
	return true


func _ClearEscrowSnapshotLocked(sql : SQLService, listingID : int) -> bool:
	return sql.DeleteRowsRaw("ah_escrow_lot", "listing_id = %d" % listingID)


# Devolve o escrow ao dono com os MESMOS uid, mesmo count por lote, mesmo
# parent_uid e mesmo created_at. É o fim do "list → cancel → re-list reseta a
# linhagem" (#94): `LotHistory` do item devolvido continua apontando para o lote
# de origem, e a cadeia que o detector de lavagem lê não se apaga com um
# cancelamento.
#
# Anúncio ANTERIOR à migração 063 não tem snapshot: não dá para reconstruir o
# count por uid a partir de `escrow_uids` (é lista sem quantidades), então o
# fallback é o comportamento antigo — uma pilha nova com parent no primeiro uid —
# e ele é medido, não escondido: `ah_escrow_fallback`.
func _RestoreEscrowLocked(sql : SQLService, listing : Dictionary, charID : int, ledgerPrefix : String) -> Dictionary:
	var listingID : int = int(listing.get("id", 0))
	var accountID : int = int(listing.get("seller_account", 0))
	var itemID : int = int(listing.get("item_id", 0))
	var count : int = int(listing.get("count", 0))
	var out : Dictionary = {"ok" = false, "restored" = 0, "fallback" = 0}
	if listingID <= 0 or itemID <= 0 or count <= 0:
		return out
	var rows : Array = sql.db.select_rows("ah_escrow_lot", "listing_id = %d" % listingID, ["*"])
	if rows.is_empty():
		out["fallback"] = 1
		var parentUID : int = int(str(listing.get("escrow_uids", "0")).split(",")[0])
		out["ok"] = _eco._GrantStackRaw(charID, accountID, itemID, count, "%s:%d" % [ledgerPrefix, listingID], ledgerPrefix, 0, parentUID) != 0
		return out
	var total : int = 0
	for entry in rows:
		var snap : Dictionary = entry
		var uid : int = int(snap.get("uid", 0))
		var back : int = int(snap.get("count", 0))
		if uid <= 0 or back <= 0:
			return out
		total += back
		var live : Array = sql.db.select_rows("item_instance", "uid = %d" % uid, ["char_id", "item_id", "count", "storage", "customfield"])
		if not live.is_empty():
			var lot : Dictionary = live[0]
			# uid vivo em outro personagem/outro item = estado que este serviço não
			# produz. Recusar a devolução (e portanto o cancelamento) é mais barato
			# que adivinhar e criar item duplicado.
			if int(lot.get("char_id", 0)) != charID or int(lot.get("item_id", 0)) != itemID or int(lot.get("storage", 0)) != 0:
				return out
			if not sql.UpdateRowsRaw("item_instance", "uid = %d" % uid, {"count" = int(lot.get("count", 0)) + back}):
				return out
		elif not sql.db.query_with_bindings("INSERT INTO item_instance (uid, char_id, item_id, count, storage, bound, customfield, reason, parent_uid, creator_account_id, created_at) VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?);", [uid, charID, itemID, back, int(snap.get("bound", 0)), str(snap.get("customfield", "")), str(snap.get("reason", ledgerPrefix)), int(snap.get("parent_uid", 0)), int(snap.get("creator_account_id", 0)), int(snap.get("lot_created_at", 0))]):
			return out
	# O snapshot tem que bater com o anúncio: se `SUM(count)` do escrow não é o
	# `count` anunciado, a linha está corrompida e devolver "o que está na tabela"
	# criaria item do nada. Recusa, rollback, anúncio fica aberto.
	if total != count:
		return out
	# Pilha agregada: a invariante `item.count == SUM(item_instance.count)` por
	# (char, item, storage) é conferida pelo reconcile diário
	# (`TournamentArenaService.gd:398`) — devolver lote sem mexer no agregado
	# grava divergência de pilha permanente.
	var agg : Array = sql.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], ["count"])
	if agg.is_empty():
		if not sql.db.insert_row("item", {"item_id" = itemID, "char_id" = charID, "count" = total, "storage" = 0, "customfield" = ""}):
			return out
	elif not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], {"count" = int(agg[0]["count"]) + total}):
		return out
	var uids : Array = []
	for snapRow in rows:
		uids.append(int((snapRow as Dictionary).get("uid", 0)))
	if not _eco._LedgerAppendLocked(accountID, charID, EconomyCatalog.LedgerKindItem, total, 0, "%s:%d:uids%s" % [ledgerPrefix, listingID, _eco._UIDList(uids)]):
		return out
	if not _ClearEscrowSnapshotLocked(sql, listingID):
		return out
	out["ok"] = true
	out["restored"] = rows.size()
	return out

# ------------------------------------------------------------------ #93.4: o anúncio vence
# Sem prazo, o item fica trancado fora do inventário do dono até alguém aparecer,
# e "até alguém aparecer" é o que torna a lavagem BARATA: o par se encontra no
# tempo que quiser. `expires_at` (migração 063) + este reaper devolvem o escrow
# AO DONO, PELO LINHAGEM (mesmo uid, mesmo count, mesmo parent) — é a #94, não uma
# re-mintagem. A taxa de anúncio NÃO é devolvida: era serviço prestado, e devolvê-
# la transformar expiração em granja de anúncio grátis.
func ReapExpiredListings(now : int, limit : int) -> Dictionary:
	var ts : int = now if now > 0 else SQLCommons.Timestamp()
	var out : Dictionary = {"reaped" = 0, "failed" = 0, "adopted" = 0}
	var batch : int = clampi(limit, 0, AHLifecycleBatch * AHBootSweepBatches)
	if batch <= 0:
		return out
	# Adoção ANTES da colheita: uma linha `expires_at = 0` (anterior à migração 063,
	# ou criada por um caminho que não é o do leilão) ganha prazo a partir do
	# `created_at` real dela, nunca a partir de agora — senão o boot de um servidor
	# com vitrine velha expiria o mercado inteiro na hora, e um fixture recém-lido
	# venceria antes de vencer. Um único statement, limitado por subquery: o UPDATE
	# de `auction_listing` não tem LIMIT nativo no SQLite.
	if Launcher.SQL.ExecuteBindings("UPDATE auction_listing SET expires_at = created_at + ? WHERE id IN (SELECT id FROM auction_listing WHERE status = 'open' AND expires_at = 0 ORDER BY id ASC LIMIT ?);", [AHListingTtlSec, batch]):
		var changed : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT changes() AS c;", [])
		out["adopted"] = int(changed[0].get("c", 0)) if not changed.is_empty() else 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM auction_listing WHERE status = 'open' AND expires_at > 0 AND expires_at <= ? ORDER BY expires_at ASC, id ASC LIMIT ?;", [ts, batch])
	for row in rows:
		if _ReapListing(int((row as Dictionary).get("id", 0)), ts):
			out["reaped"] = int(out["reaped"]) + 1
		else:
			out["failed"] = int(out["failed"]) + 1
	return out


func _ReapListing(listingID : int, ts : int) -> bool:
	if listingID <= 0:
		return false
	# Dicionário e não `var`: o flag escrito dentro do lambda não atravessaria a
	# captura por valor (lição documentada em `BuyListing`).
	var done : Dictionary = {"ok" = false, "fallback" = 0, "char" = 0}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open' AND expires_at > 0 AND expires_at <= %d" % [listingID, ts], ["*"])
		if rows.is_empty():
			return false
		var listing : Dictionary = rows[0]
		done["char"] = int(listing.get("seller_char", 0))
		var back : Dictionary = _RestoreEscrowLocked(sql, listing, int(listing.get("seller_char", 0)), "ah_expire")
		done["fallback"] = int(back.get("fallback", 0))
		if not bool(back.get("ok", false)):
			return false
		if not sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"status" = "expired"}):
			return false
		done["ok"] = true
		return true):
		pass
	_eco.settleMutex.unlock()
	if bool(done["ok"]):
		_RecordAH("ah_expire", int(done["char"]), {"listing" = listingID, "fallback" = int(done["fallback"])})
	return bool(done["ok"])

# ------------------------------------------------------------------ #100: o leilão re-cruza no boot
# O cruzamento acontecia UMA vez, na cauda de `ListItemForSale`, com o anúncio
# recém-criado. Ordem de compra deposited depois do último anúncio da mesma
# mercadoria esperava outro anúncio nascer para ser atendida — e se o processo
# caísse no meio, nem isso. Este é o sweep que fecha o buraco, e ele reusa a
# ÚNICA funil de liquidação que existe (`_TryMatchListing` → `_FillFromBuyOrder` →
# `_SettleListingLocked`): não há segunda rota de settlement para divergir.
#
# Custo: keyset sobre `idx_auction_open(status, id)` (`id > cursor ORDER BY id`),
# nunca OFFSET, e o trabalho por linha é o de um `_TryMatchListing` (3 leituras
# indexadas). Um tick varre no máximo `batch × batches` anúncios e guarda o cursor
# entre passadas: com N anúncios abertos o boot custa O(batch × batches), não O(N),
# e o sweep periódico continua de onde o boot parou.
func ReCrossOpenListings(now : int, batch : int, batches : int) -> Dictionary:
	var out : Dictionary = {"swept" = 0, "matched" = 0, "resumed" = _ahSweepAfterID}
	var size : int = clampi(batch, 0, AHLifecycleBatch)
	var passes : int = clampi(batches, 0, AHBootSweepBatches)
	if size <= 0 or passes <= 0:
		return out
	for passN in passes:
		var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM auction_listing WHERE status = 'open' AND id > ? ORDER BY id ASC LIMIT ?;", [_ahSweepAfterID, size])
		if rows.is_empty():
			# Fim da vitrine: volta ao começo para o próximo tick (um anúncio novo
			# que nasceu depois do cursor ainda é puxado pelo cruzamento inline).
			_ahSweepAfterID = 0
			break
		for row in rows:
			var listingID : int = int((row as Dictionary).get("id", 0))
			_ahSweepAfterID = listingID
			out["swept"] = int(out["swept"]) + 1
			if listingID > 0 and _TryMatchListing(listingID) > 0:
				out["matched"] = int(out["matched"]) + 1
		if int(out["swept"]) >= size * passes:
			break
	return out

# ------------------------------------------------------------------ S2: AH bot seed
# Boot-once via _process (server): roda quando o SQL abre, decide uma vez e
# nunca mais pergunta. `SHAMBLETA_AH_BOTS` é do processo e não muda depois do
# boot; com a trava desligada — que é o estado do beta — a versão antiga fazia
# um `OS.get_environment` por frame no main thread do server, para sempre.
# É também o gancho do ciclo de vida do leilão (#100): a mesma chamada de um
# arquivo acima já roda por frame, então o sweep entra SEM tocar
# `EconomyService.gd`, `Server.gd` ou `World.gd`.
func _trySeedAuctionBots():
	if _ahBotsChecked:
		return
	_ahBotsChecked = true
	TickAHLifecycle()
	if not AHBotsEnabled():
		return
	var created : int = EnsureAuctionBots()
	if created > 0:
		Util.PrintLog("Economy", "AH bot seed: %d listings" % created)

# Idempotente: garante 1 conta/char de bot + 1 open listing por seed (uid
# marker no escrow). Retorna quantos listings NOVOS criou.
func EnsureAuctionBots() -> int:
	if not AHBotsEnabled():
		return 0
	var sql : SQLService = Launcher.SQL
	var created : int = 0
	_eco.settleMutex.lock()
	for botIndex in EconomyCatalog.AH_BOT_ACCOUNTS.size():
		var botUser : String = EconomyCatalog.AH_BOT_ACCOUNTS[botIndex]
		var spec : Dictionary = EconomyCatalog.AH_BOT_LISTINGS[botIndex % EconomyCatalog.AH_BOT_LISTINGS.size()]
		var itemHash : int = str(spec.get("item", "")).hash()
		# já seedado? QUALQUER listing do bot p/ o item (open OU sold) → pula.
		# Estoque finito por design: bot não reabastece (senão vira faucet de
		# gold/itens sem custo — o sink do comprador precisa ficar retido).
		var botAccount : int = sql.GetAccountID(botUser)
		if botAccount != NetworkCommons.PeerUnknownID:
			var existing : Array = sql.QueryBindings("SELECT id FROM auction_listing WHERE seller_account = ? AND item_id = ?;", [botAccount, itemHash])
			if not existing.is_empty():
				continue
		var botChar : int = 0
		if botAccount == NetworkCommons.PeerUnknownID:
			if not sql.AddAccount(botUser, Hasher.GenerateSalt(), botUser + "@system.local"):
				continue
			botAccount = sql.GetAccountID(botUser)
			if botAccount == NetworkCommons.PeerUnknownID:
				continue
			if not sql.AddCharacter(botAccount, botUser, ActorCommons.DefaultStats, ActorCommons.DefaultTraits, ActorCommons.DefaultAttributes):
				continue
		botChar = sql.GetCharacterID(botAccount, botUser)
		if botChar == NetworkCommons.PeerUnknownID:
			continue
		# transação: stock (lot) + listagem (consume + escrow), sem fee de gem
		# (bots não têm carteira; o sink real é o gold do comprador, retido)
		#
		# #93: o seed do bot NÃO passa pela banda de preço nem pelo cap diário, e
		# isso é decisão, não buraco. (1) O preço do bot é a ÂNCORA do vendor
		# (`AH_BOT_LISTINGS` é derivado do catálogo da loja); ancorar a âncora em si
		# mesma seria um ciclo. (2) O cap diário existe para limitar a esteira de um
		# jogador; um bot listando 1× por item de catálogo não é volume, e queimar a
		# cota de `ah_activity` de um bot derrubaria a vitrine de todo mundo depois de
		# alguns boots. O que o seed passa a ter, igual ao caminho do jogador:
		# `expires_at` (senão o item do bot fica preso para sempre se ninguém
		# comprar) e snapshot de escrow (senão cancel/expira do bot viraria re-mint).
		if not sql.Transaction(func() -> bool:
			var qty : int = int(spec.get("count", 1))
			if not sql.AddItemToCharacter(botChar, itemHash, qty, "ah_bot_seed"):
				return false
			var plan : Array = _LotAllocationRaw(sql, botChar, itemHash, qty)
			var consumed : Array = sql.ConsumeItemLotsRaw(botChar, itemHash, qty, false)
			if consumed.is_empty():
				return false
			var stock : int = _eco._ItemCountRaw(botChar, itemHash)
			if stock > qty:
				if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemHash, botChar], {"count" = stock - qty}):
					return false
			elif stock > 0 and not stock == qty:
				return false
			elif stock == qty:
				if not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemHash, botChar]):
					return false
			var seededAt : int = SQLCommons.Timestamp()
			if not sql.db.query_with_bindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, escrow_uids, creator_account_id, status, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, 0, 'open', ?, ?);", [botChar, botAccount, itemHash, qty, int(spec.get("price", 1)), _eco._UIDList(consumed), seededAt, seededAt + AHListingTtlSec]):
				return false
			var seedID : int = sql.LastInsertRowIDRaw()
			if seedID <= 0:
				return false
			if not plan.is_empty() and not _WriteEscrowSnapshotLocked(sql, seedID, itemHash, plan):
				return false
			return _eco._LedgerAppendLocked(botAccount, botChar, EconomyCatalog.LedgerKindItem, -qty, 0, "ah_list:%d:uids%s" % [itemHash, _eco._UIDList(consumed)])):
			continue
		created += 1
	_eco.settleMutex.unlock()
	return created

# ------------------------------------------------------------------ E2: listings
# Escrow em lots, taxa flat queimada. Destaque pago (15 gems, fila em cima) +
# slots extras (+1 por 50×(n+1) gems, máx +5). Taxa flat e guards RMT inalterados.

func AHOpenCap(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT extra FROM ah_slots WHERE account_id = ?;", [accountID])
	var extra : int = int(rows[0].get("extra", 0)) if not rows.is_empty() else 0
	return EconomyCatalog.AHMaxOpenPerAccount + mini(maxi(extra, 0), EconomyCatalog.AHSlotsMaxExtra)

func BuyAHSlot(accountID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT extra FROM ah_slots WHERE account_id = ?;", [accountID])
	var extra : int = int(rows[0].get("extra", 0)) if not rows.is_empty() else 0
	if extra >= EconomyCatalog.AHSlotsMaxExtra:
		return {"ok": false, "reason": "slots_cap"}
	var cost : int = EconomyCatalog.AHSlotBaseCost * (extra + 1)
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < cost:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - cost):
			return false
		if not sql.ExecuteBindings("INSERT OR REPLACE INTO ah_slots (account_id, extra) VALUES (?, ?);", [accountID, extra + 1]):
			return false
		if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -cost, gems - cost, "ah_slot"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		result["slots"] = EconomyCatalog.AHMaxOpenPerAccount + extra + 1
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

func HighlightListing(accountID : int, listingID : int) -> Dictionary:
	var result : Dictionary = {"ok": false, "reason": "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["seller_account", "highlight"])
		if rows.is_empty():
			result["reason"] = "not_found"
			return false
		if int(rows[0].get("seller_account", 0)) != accountID:
			result["reason"] = "not_yours"
			return false
		if int(rows[0].get("highlight", 0)) == 1:
			result["reason"] = "already_highlighted"
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < EconomyCatalog.AHHighlightFeeGems:
			result["reason"] = "insufficient_gems"
			return false
		if not sql.SetGemsRaw(accountID, gems - EconomyCatalog.AHHighlightFeeGems):
			return false
		if not sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"highlight" = 1}):
			return false
		if not _eco._LedgerAppendLocked(accountID, 0, EconomyCatalog.LedgerKindGems, -EconomyCatalog.AHHighlightFeeGems, gems - EconomyCatalog.AHHighlightFeeGems, "ah_highlight_fee"):
			return false
		result["ok"] = true
		result["reason"] = "ok"
		return true):
		pass
	_eco.settleMutex.unlock()
	return result

func BrowseListings(limit : int = 20) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT id, seller_char, item_id, count, price_gold, highlight, created_at FROM auction_listing WHERE status = 'open' ORDER BY highlight DESC, id DESC LIMIT ?;", [limit])

# ------------------------------------------------------------------ JUIZ MARKETPLACE 2026-09-27
# Três pernas que faltavam no leilão: PÁGINA (offset + filtro no servidor, com o
# total para a régua de páginas), MEMÓRIA (preço realizado em `ah_price_history`,
# migração 059) e DEMANDA (ordem de compra com gold em escrow, espelho do escrow
# de item de `ListItemForSale`). Nada aqui decide ouro, taxa ou saldo por fora do
# kernel: cada movimento de gold passa por `_eco.kernel._MoveGoldLocked` dentro
# da transação e por `ApplyGoldMoves` no commit, pela mesma razão documentada no
# cabeçalho deste arquivo (o snapshot de 600 s de `SQL.UpdateStat` apaga escrita
# crua em `stat.gp`).

# (b) Página de verdade. O teto de 40 linhas de antes (`AHMaxBrowseWindow` em
# Server.gd) sobrevive como TAMANHO de página; quem pagina é o servidor, com
# OFFSET, e quem filtra é o SQL (`maxPrice`/`itemID`, 0 = sem filtro).
func BrowseListingsPage(limit : int, offset : int, maxPrice : int, itemID : int) -> Dictionary:
	var size : int = clampi(limit, 1, EconomyCatalog.AHBrowsePageSize)
	var start : int = maxi(0, offset)
	var where : String = "status = 'open'"
	var params : Array = []
	if itemID > 0:
		where += " AND item_id = ?"
		params.append(itemID)
	if maxPrice > 0:
		where += " AND price_gold <= ?"
		params.append(maxPrice)
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT id, seller_char, item_id, count, price_gold, highlight, created_at FROM auction_listing WHERE %s ORDER BY highlight DESC, id DESC LIMIT ? OFFSET ?;" % where,
		params + [size, start])
	var countParams : Array = params.duplicate()
	var totalRows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT COUNT(*) AS n FROM auction_listing WHERE %s;" % where, countParams)
	var total : int = int(totalRows[0].get("n", 0)) if not totalRows.is_empty() else 0
	return {
		"ok" = true,
		"listings" = rows,
		"total" = total,
		"offset" = start,
		"page_size" = size,
		"max_page" = maxi(0, int(ceil(float(total) / float(size))) - 1),
	}

# (a) Preço REALIZADO. O painel lê daqui em vez da própria memória de sessão
# (`AuctionHouseWindow._history`), então "o que este item vendeu" sobrevive ao
# fechar a janela, é o mesmo para duas contas e não depende de a venda ter
# acontecido NAQUELA sessão.
func RecentSoldPrices(itemID : int, limit : int) -> Array[Dictionary]:
	var size : int = clampi(limit, 1, 50)
	if itemID > 0:
		return Launcher.SQL.QueryBindings("SELECT listing_id, item_id, count, unit_price, price_gold, via, sold_at FROM ah_price_history WHERE item_id = ? ORDER BY sold_at DESC, id DESC LIMIT ?;", [itemID, size])
	return Launcher.SQL.QueryBindings("SELECT listing_id, item_id, count, unit_price, price_gold, via, sold_at FROM ah_price_history ORDER BY sold_at DESC, id DESC LIMIT ?;", [size])

# Resumo numérico do preço realizado + o menor ask aberto da mesma faixa: é o
# par "quanto foi / quanto pedem" que falta a quem vai pôr um preço.
func RecentSoldSummary(itemID : int, limit : int) -> Dictionary:
	var rows : Array[Dictionary] = RecentSoldPrices(itemID, limit)
	var sum : int = 0
	var low : int = 0
	var high : int = 0
	var last : int = 0
	for row in rows:
		var unit : int = int(row.get("unit_price", 0))
		sum += unit
		if low == 0 or unit < low:
			low = unit
		if unit > high:
			high = unit
		if last == 0:
			last = unit
	var asks : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COALESCE(MIN(CAST(price_gold AS INTEGER) / MAX(count, 1)), 0) AS unit FROM auction_listing WHERE status = 'open' AND item_id = ?;", [itemID])
	# MIN() sobre zero linhas é NULL, não 0, e `int(null)` é erro de runtime no
	# GDScript (a chamada INTEIRA de `RecentSoldSummary` arrebentava no item sem
	# anúncios abertos — exatamente o estado de um item que acabou de esvaziar).
	var askRaw : Variant = asks[0].get("unit", 0) if not asks.is_empty() else null
	var askUnit : int = 0 if askRaw == null else int(askRaw)
	return {
		"samples" = rows.size(),
		"avg_unit" = int(round(float(sum) / float(maxi(1, rows.size())))) if not rows.is_empty() else 0,
		"low_unit" = low,
		"high_unit" = high,
		"last_unit" = last,
		"ask_unit" = askUnit,
	}

# Uma venda liquidada vira UMA linha de histórico, na mesma transação que move o
# ouro — ou a venda não aconteceu. `UNIQUE(listing_id)` (migração 059) é o que
# torna a segunda tentativa na mesma linha um erro visível em vez de dois
# registros de um mesmo fato.
func _RecordSoldLocked(sql : SQLService, listing : Dictionary, buyerAccount : int, via : String) -> bool:
	var count : int = maxi(1, int(listing.get("count", 1)))
	var price : int = int(listing.get("price_gold", 0))
	return sql.db.query_with_bindings("INSERT INTO ah_price_history (listing_id, item_id, count, unit_price, price_gold, buyer_account, seller_account, via, sold_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);", [
		int(listing.get("id", 0)), int(listing.get("item_id", 0)), count,
		maxi(1, int(round(float(price) / float(count)))), price,
		buyerAccount, int(listing.get("seller_account", 0)), via, SQLCommons.Timestamp()])

# Versão com VEREDITO. `ListItemForSale` (abaixo) sempre devolveu um inteiro, e
# `0` não diz a ninguém por que o anúncio não nasceu: "slot cheio", "fora da banda
# de preço" e "cap do dia" são três comportamentos de jogador diferentes e o
# RPC (`Server.gd` → `Launcher.Economy.ListItemForSale`) só conseguia dizer
# "rejected". O dicionário existe para o serviço de facade/testes lerem o motivo;
# o inteiro continua sendo o contrato dos callers antigos — nenhum deles mudou.
func ListItemForSaleChecked(sellerChar : int, itemID : int, count : int, priceGold : int) -> Dictionary:
	var result : Dictionary = {"id" = 0, "reason" = "rejected", "band" = {}}
	if itemID <= 0 or count <= 0 or priceGold <= 0:
		result["reason"] = "bad_input"
		return result
	# SOM-CRAFT: matéria-prima não pisa no mercado. O carimbo bound na concessão
	# já faria o ConsumeItemLotsRaw(allowBound=false) abaixo falhar; esta é a porta
	# estrutural lida da célula — um lote de material criado por qualquer outro
	# caminho (seed, migração, GM) continua sem anúncio, e o money math do leilão
	# (fee em gem + sink do gold retido) não ganha uma segunda mercadoria.
	if CellCommons.IsMaterial(DB.ItemsDB.get(itemID, null)):
		result["reason"] = "material"
		return result
	# #93.1: a régua que julga o ask é `AHPriceBand` (`sources/economy/AuctionHousePricing.gd:@AHPriceBand`),
	# que mora em `AuctionHousePricing` e saiu do serviço quando o ratchet
	# anti-god-node dele estourou. Lida FORA da transação de propósito — é leitura
	# de âncora (`QueryBindings` pega o queryMutex, que não pode ser pego dentro de
	# `Transaction()`), e uma divergência de âncora entre a leitura e o commit
	# recusa ou aceita um preço na borda: não move ouro nem duplica item.
	var unit : int = maxi(1, int(round(float(priceGold) / float(maxi(1, count)))))
	var band : Dictionary = AuctionHousePricing.AHPriceBand(itemID, unit)
	result["band"] = band
	if not bool(band.get("ok", false)):
		result["reason"] = str(band.get("reason", "price_out_of_band"))
		_RecordAH("ah_list_reject", sellerChar, {"item" = itemID, "count" = count,
			"price_gold" = priceGold, "unit" = unit, "reason" = result["reason"],
			"anchor" = int(band.get("anchor", 0)), "min" = int(band.get("min", 0)),
			"max" = int(band.get("max", 0))})
		return result
	var out : Dictionary = {"id" = 0, "reason" = "rejected"}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var accountID : int = _eco._AccountIDForCharacterRaw(sellerChar)
		if accountID == NetworkCommons.PeerUnknownID:
			out["reason"] = "unknown_account"
			return false
		var openRows : Array = sql.db.select_rows("auction_listing", "seller_account = %d AND status = 'open'" % accountID, ["id"])
		if openRows.size() >= AHOpenCap(accountID):
			out["reason"] = "slot_cap"
			return false
		# #93.3: volume diário. Dentro da transação porque o contador tem que
		# subir com o anúncio: cap lido na memória do processo resets no boot.
		var today : Dictionary = AHActivityLocked(sql, accountID)
		if int(today.get("lists", 0)) >= AHMaxListingsPerDay:
			out["reason"] = "list_day_cap"
			return false
		if _eco._ItemCountRaw(sellerChar, itemID) < count:
			out["reason"] = "not_enough_items"
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < EconomyCatalog.AHListFeeGems:
			out["reason"] = "need_fee"
			return false
		# SOM-IDLE Fase H §7: capture creator_account_id BEFORE consume deletes lots
		# (ConsumeItemLotsRaw deletes item_instance rows). Read from the seller's
		# existing lots, defaulting to 0 (non-crafted items → no fee).
		var creatorAccount : int = 0
		# #94: o plano de consumo FIFO é a única forma de saber quantas unidades de
		# CADA lote entram no escrow — `ConsumeItemLotsRaw` devolve só a lista de
		# uid tocados. Lê as MESMAS linhas que o consumo vai tocar, na mesma
		# transação, sob o mesmo mutex.
		var plan : Array = _LotAllocationRaw(sql, sellerChar, itemID, count)
		if plan.is_empty():
			out["reason"] = "no_lots"
			return false
		for lot in plan:
			var ca : int = int((lot as Dictionary).get("creator_account_id", 0))
			if ca != 0:
				creatorAccount = ca
				break
		var consumed : Array = sql.ConsumeItemLotsRaw(sellerChar, itemID, count, false)
		if consumed.is_empty():
			out["reason"] = "consume_failed"
			return false
		# Plano ≠ consumo é a divergência que transformaria um cancelamento em item
		# duplicado: recusa o anúncio inteiro em vez de adivinhar.
		if consumed.size() != plan.size():
			out["reason"] = "plan_mismatch"
			return false
		var stock : int = _eco._ItemCountRaw(sellerChar, itemID)
		if stock < count:
			out["reason"] = "not_enough_items"
			return false
		if stock > count:
			if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, sellerChar], {"count" = stock - count}):
				out["reason"] = "stack_update"
				return false
		elif not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, sellerChar]):
			out["reason"] = "stack_delete"
			return false
		if not sql.SetGemsRaw(accountID, gems - EconomyCatalog.AHListFeeGems):
			out["reason"] = "fee_failed"
			return false
		if not _eco._LedgerAppendLocked(accountID, sellerChar, EconomyCatalog.LedgerKindGems, -EconomyCatalog.AHListFeeGems, gems - EconomyCatalog.AHListFeeGems, "ah_list_fee"):
			out["reason"] = "fee_ledger"
			return false
		# #93.4: o anúncio nasce com prazo. `created_at + AHListingTtlSec`, no mesmo
		# commit do escrow — um anúncio sem prazo é um item sequestrado. Uma leitura do
		# relógio só: duas leituras davam `expires_at = created_at + ttl + 1` quando o
		# segundo virava entre elas, e foi assim que o CI mediu 259201 contra 259200.
		var born : int = SQLCommons.Timestamp()
		if not sql.db.query_with_bindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, escrow_uids, creator_account_id, status, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?, ?);", [sellerChar, accountID, itemID, count, priceGold, _eco._UIDList(consumed), creatorAccount, born, born + AHListingTtlSec]):
			out["reason"] = "insert_failed"
			return false
		var listingID : int = sql.LastInsertRowIDRaw()
		if listingID <= 0:
			out["reason"] = "insert_failed"
			return false
		# #94: snapshot do escrow (uid + count + linhagem) na mesma transação do
		# anúncio. É isto que `CancelListing` e o reaper devolvem, em vez de mintar
		# um lote novo.
		if not _WriteEscrowSnapshotLocked(sql, listingID, itemID, plan):
			out["reason"] = "snapshot_failed"
			return false
		if not _AHBumpActivityLocked(sql, accountID, 1, 0):
			out["reason"] = "activity_failed"
			return false
		if not _eco._LedgerAppendLocked(accountID, sellerChar, EconomyCatalog.LedgerKindItem, -count, 0, "ah_list:%d:uids%s" % [itemID, _eco._UIDList(consumed)]):
			out["reason"] = "ledger_failed"
			return false
		out["id"] = listingID
		out["reason"] = "ok"
		return true):
		pass
	_eco.settleMutex.unlock()
	if int(out["id"]) > 0:
		# 059(c): anúncio novo cruza a melhor ordem de compra aberta ANTES de
		# voltar para a vitrine — é assim que um mercado com demanda forma preço.
		# Roda depois do commit do anúncio (com o lock já solto) de propósito: se
		# o cruzamento falhar por qualquer motivo, o anúncio continua vivo e a
		# taxa de anúncio não foi paga duas vezes.
		var matched : int = _TryMatchListing(int(out["id"]))
		_RecordAH("ah_list", sellerChar, {"listing" = int(out["id"]), "item" = itemID,
			"count" = count, "price_gold" = priceGold, "via" = "bid" if matched > 0 else "ask"})
	elif str(out.get("reason", "")) == "list_day_cap" or str(out.get("reason", "")) == "slot_cap":
		_RecordAH("ah_list_reject", sellerChar, {"item" = itemID, "count" = count,
			"price_gold" = priceGold, "reason" = str(out["reason"])})
	return out


func ListItemForSale(sellerChar : int, itemID : int, count : int, priceGold : int) -> int:
	return int(ListItemForSaleChecked(sellerChar, itemID, count, priceGold).get("id", 0))

# Liquidação de um anúncio: UM caminho para as duas origens da demanda — o
# comprador que aceita um ask (`BuyListing`) e a ordem de compra que cruza o ask
# (`PlaceBuyOrder`, `ListItemForSale`). Ordem dos movimentos de ouro, fee do
# criador, entrega do lote em escrow, ledger de item e linha de histórico são os
# mesmos nos dois lados: bifurcar isso é exatamente a classe de defeito que o
# fuzzer de invariantes caça (duas operações legalmente individuais, um centavo
# a mais ou a menos conforme o caminho).
func _SettleListingLocked(sql : SQLService, listing : Dictionary, buyerChar : int, buyerAccount : int, via : String, goldMoves : Dictionary) -> bool:
	var listingID : int = int(listing.get("id", 0))
	var sellerChar : int = int(listing.get("seller_char", 0))
	var sellerAccount : int = int(listing.get("seller_account", 0))
	var itemID : int = int(listing.get("item_id", 0))
	var count : int = int(listing.get("count", 1))
	var price : int = int(listing.get("price_gold", 0))
	if listingID <= 0 or itemID <= 0 or count <= 0 or price <= 0:
		return false
	# Nunca comprar de si mesmo — vale para o ask e para o bid cruzado.
	if buyerAccount == NetworkCommons.PeerUnknownID or buyerAccount == sellerAccount or buyerChar == sellerChar:
		return false
	# SOM-IDLE Fase H §7: creator fee 1% — `creator_account_id` foi capturado no
	# anúncio (os lotes consumidos já não existem). Só fire se o criador não é o
	# vendedor, e sai do preço: o comprador nunca paga duas vezes.
	var creatorAccount : int = int(listing.get("creator_account_id", 0))
	var creatorFee : int = 0
	var sellerNet : int = price
	if creatorAccount != 0 and creatorAccount != sellerAccount:
		creatorFee = maxi(0, roundi(float(price) * float(CraftCatalog.CREATOR_FEE_PCT) / 100.0))
		sellerNet = price - creatorFee
		# Credit the creator's gold (stat.gp on their first char)
		var creatorChars : PackedInt64Array = sql.GetCharacters(creatorAccount)
		if creatorChars.is_empty():
			return false
		if not _eco.kernel._MoveGoldLocked(sql, int(creatorChars[0]), creatorAccount, creatorFee, "ah_creator_fee:%d" % listingID, goldMoves):
			return false
	if not _eco.kernel._MoveGoldLocked(sql, buyerChar, buyerAccount, -price, "ah_buy:%d" % listingID, goldMoves):
		return false
	if not _eco.kernel._MoveGoldLocked(sql, sellerChar, sellerAccount, sellerNet, "ah_sell:%d" % listingID, goldMoves):
		return false
	# #93.3: teto de compras por conta/dia. Está AQUI, e não em `BuyListing`, porque
	# este é o funil único: ask aceito, bid cruzada por anúncio novo e bid cruzada
	# pelo sweep do boot passam todas por esta função. Uma ordem que encosta no teto
	# para de preencher e continua aberta com o escrow intacto — nada pela metade.
	var buyerDay : Dictionary = AHActivityLocked(sql, buyerAccount)
	if int(buyerDay.get("buys", 0)) >= AHMaxBuysPerDay:
		return false
	# #94: o lote do comprador nasce com PAI de verdade. Antes desta perna havia um
	# `split(",")[0]`: numa pilha de N lotes escrowed, só o PRIMEIRO uid virava
	# parent e o resto da linhagem se perdia. Agora é uma concessão por uid do
	# snapshot, cada uma com `parent_uid` = o uid de onde aquelas unidades saíram, e
	# `count` = exatamente quantas unidades saíram. Anúncio anterior à migração 063
	# não tem snapshot (de `escrow_uids` não dá para recuperar o count por uid) e
	# cai no caminho antigo, declarado: um lote, parent no primeiro uid.
	var snapshot : Array = sql.db.select_rows("ah_escrow_lot", "listing_id = %d" % listingID, ["*"])
	var granted : int = 0
	var grantedUnits : int = 0
	if snapshot.is_empty():
		var parentUID : int = int(str(listing.get("escrow_uids", "0")).split(",")[0])
		granted = sql.GrantItemLotRaw(buyerChar, itemID, count, "ah_buy", 0, "", parentUID)
		if granted == 0:
			return false
		grantedUnits = count
	else:
		for entry in snapshot:
			var snap : Dictionary = entry
			var piece : int = int(snap.get("count", 0))
			var uid : int = int(snap.get("uid", 0))
			if piece <= 0 or uid <= 0:
				return false
			var lotUID : int = sql.GrantItemLotRaw(buyerChar, itemID, piece, "ah_buy", 0, "", uid)
			if lotUID == 0:
				return false
			if granted == 0:
				granted = lotUID
			grantedUnits += piece
			if not _eco._LedgerAppendLocked(buyerAccount, buyerChar, EconomyCatalog.LedgerKindItem, piece, 0, "ah_in:%d:lot%d" % [itemID, lotUID]):
				return false
	if grantedUnits != count:
		return false
	var existing : Array = sql.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, buyerChar], ["count"])
	if existing.is_empty():
		if not sql.db.insert_row("item", {"item_id" = itemID, "char_id" = buyerChar, "count" = grantedUnits, "storage" = 0, "customfield" = ""}):
			return false
	elif not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, buyerChar], {"count" = int(existing[0]["count"]) + grantedUnits}):
		return false
	if not sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"status" = "sold"}):
		return false
	# O escrow acabou: vendido, não há mais o que devolver. Manter só os anúncios
	# abertos em `ah_escrow_lot` é o que faz a tabela ser um retrato de "mercadoria
	# sequestrada agora", lável por qualquer auditoria.
	if not _ClearEscrowSnapshotLocked(sql, listingID):
		return false
	# 059(a): o preço realizado nasce DENTRO deste commit. Sem o par "venda +
	# histórico" na mesma transação, o histórico seria uma projeção do cliente.
	if not _RecordSoldLocked(sql, listing, buyerAccount, via):
		return false
	# #26: o AH tinha o próprio namespace de ledger (ah_list/ah_sell/ah_buy),
	# mas esta perna — a única que ainda não tinha — escrevia `trade_in:`, o
	# mesmo formato da troca direta. Consequência medida (run K1, ledger
	# 18433): LastTradeTimestampRaw casa 'trade_out:%'/'trade_in:%', então
	# COMPRAR NO LEILÃO armava o cooldown de 60 s de troca direta no
	# comprador; e _FlagFlipTrades lia o mesmo par, abrindo flag de lavagem em
	# quem vendeu um item e o recomprou no mercado (compra pública, não
	# bilateral). O motivo do cooldown é a troca entre duas contas conhecidas;
	# o AH já tem fricção própria (ouro + taxa + slot).
	# No caminho com snapshot a perna de item do comprador já foi escrita lote por
	# lote acima — reescrevê-la aqui seria contar a mesma compra duas vezes no
	# ledger, e é exatamente destas linhas que o detector de lavagem (#93.2) lê.
	if snapshot.is_empty() and not _eco._LedgerAppendLocked(buyerAccount, buyerChar, EconomyCatalog.LedgerKindItem, count, 0, "ah_in:%d:lot%d" % [itemID, granted]):
		return false
	# #93.3: a compra só conta quando ela ACONTECEU — mesma transação do ouro e do
	# lote, cap diário durável.
	return _AHBumpActivityLocked(sql, buyerAccount, 0, 1)

func BuyListing(buyerChar : int, listingID : int) -> bool:
	var bought : bool = false
	# Deltas de gold aplicados no banco pela transação, espelhados no agente
	# carregado depois do commit (EconomyKernel._MoveGoldLocked). Sem o espelho,
	# o snapshot absoluto de SQL.UpdateStat (RefreshCharacter, ciclo de 600 s)
	# escrevia de volta o gold antigo: o comprador ficava com o que gastou e o
	# vendedor perdia o que recebeu.
	var goldMoves : Dictionary = {}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["*"])
		if rows.is_empty():
			return false
		var listing : Dictionary = rows[0]
		var buyerAccount : int = _eco._AccountIDForCharacterRaw(buyerChar)
		if buyerAccount == NetworkCommons.PeerUnknownID:
			return false
		# Pré-checagem do saldo só refina o motivo; o kernel recusa carteira
		# negativa de qualquer forma.
		if _eco._CharGoldRaw(buyerChar) < int(listing.get("price_gold", 0)):
			return false
		return _SettleListingLocked(sql, listing, buyerChar, buyerAccount, "ask", goldMoves)):
		# O flag é escrito FORA do lambda, de propósito: lambda GDScript captura
		# locais por valor, então `bought = true` dentro da closure não chegava
		# aqui — a compra dava commit, movia ouro e item no banco, e o RPC
		# respondia falso (e `ApplyGoldMoves` nunca espelhava o delta na memória,
		# que é exatamente o que o snapshot de 600 s revertia).
		bought = true
	_eco.settleMutex.unlock()
	if bought:
		_eco.kernel.ApplyGoldMoves(goldMoves)
		_RecordAH("ah_buy", buyerChar, {"listing" = listingID})
	return bought

# K1: AH sem evento é marketplace no escuro — quantos anunciam, quantos compram,
# quantos desistem (e o último é o que diz se o preço está errado). É ouro/gems de
# jogo, não dinheiro, então vai pelo funil comum (buffer de 60 s) em vez do
# caminho de flush imediato do `purchase`. Sempre fora da transação: o flush da
# telemetria pega o queryMutex, e chamá-lo de dentro do lambda seria lock
# recursivo numa Mutex não-recursiva.
func _RecordAH(kind : String, charID : int, meta : Dictionary) -> void:
	if Launcher.Telemetry == null:
		return
	Launcher.Telemetry.RecordFunnel(kind, _eco._AccountIDForCharacterRaw(charID), charID, JSON.stringify(meta))

func CancelListing(charID : int, listingID : int) -> bool:
	var done : bool = false
	# Dicionário e não `var`: `fallback` é escrito DENTRO do lambda, e local
	# capturado por valor não atravessa (lição documentada em `BuyListing`).
	var tally : Dictionary = {"fallback" = 0}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["*"])
		if rows.is_empty() or int(rows[0]["seller_char"]) != charID:
			return false
		var listing : Dictionary = rows[0]
		# #94: cancelar DEVOLVE o escrow, não mintar um item novo. A linha antiga
		# chamava `_GrantStackRaw(..., "ah_cancel")`, que cria um uid do zero: list
		# → cancel → re-list apagava a linhagem do item e transformava `LotHistory`
		# em página em branco exatamente para quem está testando se alguém está
		# lavando mercadoria. O snapshot (`ah_escrow_lot`) tem uid, count por uid,
		# parent, criador e created_at originais.
		var back : Dictionary = _RestoreEscrowLocked(sql, listing, charID, "ah_cancel")
		tally["fallback"] = int(back.get("fallback", 0))
		if not bool(back.get("ok", false)):
			return false
		return sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"status" = "cancelled"})):
		done = true
	_eco.settleMutex.unlock()
	if done:
		_RecordAH("ah_cancel", charID, {"listing" = listingID, "fallback" = int(tally["fallback"])})
	return done

# ------------------------------------------------------------------ 059(c): ordens de compra (bid)
# O leilão tinha só oferta: sem demanda depositada, o spread não fecha e "preço
# justo" é o que o vendedor acha justo. Uma ordem de compra é o espelho exato de
# um anúncio — onde o anúncio tranca ITEM por uid (`ListItemForSale`, acima), a
# ordem tranca GOLD pela conta do kernel. Depósito: `ah_bid_escrow:<ordem>`;
# cruzamento: libera o valor das unidades na carteira e a mesma
# `_SettleListingLocked` paga vendedor e criador (o caminho único do fee, sem
# segunda versão dele); sobra volta como `ah_bid_release:<ordem>`; cancelamento
# devolve o inteiro depósito. Preenchimento parcial é a regra: `quantity` é
# regressiva e o escrow acompanha, unidade a unidade.
#
# Invariante de contabilidade que o fuzzer pressiona: em todo instante
# `escrow_gold == quantity × unit_price` para ordem aberta, e a carteira do
# comprador já foi debitada desse valor. O ouro do escrow NÃO existe na carteira
# de ninguém enquanto a ordem estiver em pé — é o mesmo estatuto do item em
# escrow de um anúncio, e é por isso que a ordem que preenche recebe o depósito
# DE VOLTA na carteira antes de pagar: um débito duplo no comprador (escrow + o
# `-price` do assentamento) seria criar gold do nada no vendedor.

func BuyOrderCount(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT COUNT(*) AS n FROM ah_buy_order WHERE buyer_account = ? AND status = 'open';", [accountID])
	return int(rows[0].get("n", 0)) if not rows.is_empty() else 0

func BuyOrdersFor(charID : int, limit : int) -> Array[Dictionary]:
	return BuyOrdersForAccount(_eco._AccountIDForCharacterRaw(charID), charID, limit)

# Órdenes abertas da CONTA (o cap é por conta, não por personagem), já com o nome
# do item: `item_id` é um hash e escrow sem rosto não é decisão — quem cancela uma
# ordem precisa saber qual item está travando ouro dele. O nome vem do catálogo
# local do servidor (`DB.ItemsDB`), nunca do pacote do cliente; vazio = item que o
# servidor não conhece (o painel cai em "item <id>").
#
# O pedido por personagem continua restrito à própria conta: a linha de ordem é
# apenas visibilidade, e a chave de quem pode cancelá-la é `buyer_char`
# (`CancelBuyOrder`), conferida no servidor contra a sessão.
func BuyOrdersForAccount(accountID : int, charID : int, limit : int) -> Array[Dictionary]:
	if accountID == NetworkCommons.PeerUnknownID:
		return []
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, buyer_char, item_id, quantity, unit_price, escrow_gold, status, created_at FROM ah_buy_order WHERE buyer_account = ? AND status = 'open' ORDER BY id DESC LIMIT ?;", [accountID, clampi(limit, 1, 50)])
	for row in rows:
		row["item_name"] = str(_ItemName(int(row.get("item_id", 0))))
		# O personagem que pediu é o único que vê o botão de cancelar na linha.
		row["mine"] = int(row.get("buyer_char", 0)) == charID
	return rows

func _ItemName(itemID : int) -> String:
	if DB.ItemsDB == null or not DB.ItemsDB.has(itemID):
		return ""
	var cell : ItemCell = DB.ItemsDB.get(itemID, null)
	return str(cell.name) if cell != null else ""

func BuyOrderRow(orderID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, buyer_char, buyer_account, item_id, quantity, unit_price, escrow_gold, status, created_at FROM ah_buy_order WHERE id = ?;", [orderID])
	return {} if rows.is_empty() else rows[0]

# Depósito do escrow + linha da ordem, numa transação só. A ordem nasce com
# `escrow_gold = 0` e só ganha valor depois do `_MoveGoldLocked` passar: se o
# débito recusar (carteira insuficiente), o rollback leva a linha e não existe
# ordem sem ouro — o inverso seria demanda falsificada de graça.
func PlaceBuyOrder(buyerChar : int, itemID : int, count : int, unitPrice : int) -> int:
	if itemID <= 0 or count <= 0 or unitPrice <= 0:
		return 0
	# SOM-CRAFT: mesma porta do ListItemForSale, no lado da demanda — ordem de
	# compra em material nunca cruzaria (não pode haver anúncio) e deixaria o
	# gold do comprador sequestrado em escrow para sempre.
	if CellCommons.IsMaterial(DB.ItemsDB.get(itemID, null)):
		return 0
	if count > EconomyCatalog.AHMaxBidQuantity or unitPrice > EconomyCatalog.AHMaxBidUnitPrice:
		return 0
	var escrow : int = count * unitPrice
	if escrow <= 0 or escrow > EconomyCatalog.AHMaxBuyOrderGold:
		return 0
	var out : Dictionary = {"id" = 0}
	var goldMoves : Dictionary = {}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var accountID : int = _eco._AccountIDForCharacterRaw(buyerChar)
		if accountID == NetworkCommons.PeerUnknownID:
			return false
		if BuyOrderCount(accountID) >= EconomyCatalog.AHMaxBuyOrdersPerAccount:
			return false
		if _eco._CharGoldRaw(buyerChar) < escrow:
			return false
		if not sql.db.query_with_bindings("INSERT INTO ah_buy_order (buyer_char, buyer_account, item_id, quantity, unit_price, escrow_gold, status, created_at) VALUES (?, ?, ?, ?, ?, 0, 'open', ?);", [buyerChar, accountID, itemID, count, unitPrice, SQLCommons.Timestamp()]):
			return false
		var orderID : int = sql.LastInsertRowIDRaw()
		if orderID <= 0:
			return false
		if not _eco.kernel._MoveGoldLocked(sql, buyerChar, accountID, -escrow, "ah_bid_escrow:%d" % orderID, goldMoves):
			return false
		if not sql.UpdateRowsRaw("ah_buy_order", "id = %d" % orderID, {"escrow_gold" = escrow}):
			return false
		out["id"] = orderID
		return true):
		pass
	_eco.settleMutex.unlock()
	var orderID : int = int(out["id"])
	if orderID <= 0:
		return 0
	_eco.kernel.ApplyGoldMoves(goldMoves)
	_FillFromBuyOrder(orderID)
	_RecordAH("ah_bid", buyerChar, {"order" = orderID, "item" = itemID, "count" = count, "unit_price" = unitPrice, "escrow_gold" = escrow})
	return orderID

# Cancelar é o espelho do cancelamento de anúncio: devolve o depósito inteiro e
# fecha a linha. Sem taxa de volta — a fricção do leilão é a mesma dos dois lados.
func CancelBuyOrder(charID : int, orderID : int) -> bool:
	var done : bool = false
	var goldMoves : Dictionary = {}
	_eco.settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("ah_buy_order", "id = %d AND status = 'open'" % orderID, ["buyer_char", "buyer_account", "escrow_gold"])
		if rows.is_empty() or int(rows[0].get("buyer_char", 0)) != charID:
			return false
		var accountID : int = int(rows[0].get("buyer_account", 0))
		var held : int = int(rows[0].get("escrow_gold", 0))
		if held > 0 and not _eco.kernel._MoveGoldLocked(sql, charID, accountID, held, "ah_bid_release:%d" % orderID, goldMoves):
			return false
		return sql.UpdateRowsRaw("ah_buy_order", "id = %d" % orderID, {"status" = "cancelled", "escrow_gold" = 0})):
		# Escrito fora do lambda pelo mesmo motivo documentado em `BuyListing`.
		done = true
	_eco.settleMutex.unlock()
	if done:
		_eco.kernel.ApplyGoldMoves(goldMoves)
		_RecordAH("ah_bid_cancel", charID, {"order" = orderID})
	return done

# A ordem varre a vitrine enquanto houver demanda coberta. Uma rodada = um
# anúncio liquidado = um commit com o lock próprio; o laço para quando nada
# fecha ou quando o teto de rodadas chega (uma ordem nunca pode traver o
# main thread do servidor num laço sobre um mercado grande).
func _FillFromBuyOrder(orderID : int) -> int:
	var units : int = 0
	for passN in EconomyCatalog.AHMaxBidFillRounds:
		var goldMoves : Dictionary = {}
		# Dicionário e não `var`: lambda GDScript captura locais por valor, então
		# um inteiro escrito dentro da closure não chega aqui (lição documentada em
		# `BuyListing`). `Dictionary` é referência — o conteúdo atravessa.
		var tally : Dictionary = {"units" = 0, "listing" = 0, "char" = 0}
		_eco.settleMutex.lock()
		var done : bool = Launcher.SQL.Transaction(func() -> bool:
			var sql : SQLService = Launcher.SQL
			var rows : Array = sql.db.select_rows("ah_buy_order", "id = %d AND status = 'open'" % orderID, ["*"])
			if rows.is_empty():
				return false
			var order : Dictionary = rows[0]
			var need : int = int(order.get("quantity", 0))
			var unitCap : int = int(order.get("unit_price", 0))
			var held : int = int(order.get("escrow_gold", 0))
			var buyerChar : int = int(order.get("buyer_char", 0))
			var buyerAccount : int = int(order.get("buyer_account", 0))
			if need <= 0 or unitCap <= 0:
				return false
			# Escrow menor que a demanda é ordem corrompida: recusar preencher é
			# mais barato que descobrir tarde que se está pagando vendedor com ouro
			# que ninguém depositou.
			if held < need * unitCap:
				return false
			var itemID : int = int(order.get("item_id", 0))
			var candidates : Array = sql.db.select_rows("auction_listing", "status = 'open' AND item_id = %d AND price_gold <= %d AND count <= %d AND seller_account != %d" % [itemID, unitCap, need, buyerAccount], ["*"])
			var best : Dictionary = {}
			for cand in candidates:
				var c : Dictionary = cand
				if best.is_empty():
					best = c
					continue
				if int(c.get("price_gold", 0)) < int(best.get("price_gold", 0)):
					best = c
				elif int(c.get("price_gold", 0)) == int(best.get("price_gold", 0)) and int(c.get("id", 0)) < int(best.get("id", 0)):
					best = c
			if best.is_empty():
				return false
			var qty : int = int(best.get("count", 1))
			var cost : int = int(best.get("price_gold", 0))
			var heldFor : int = qty * unitCap
			# Devolve as unidades ao comprador e deixa a `_SettleListingLocked`
			# cobrá-las: é o MESMO caminho do fee e do ledger de uma compra normal,
			# e o único jeito de o preço realizado das duas origens bater.
			if not _eco.kernel._MoveGoldLocked(sql, buyerChar, buyerAccount, heldFor, "ah_bid_release:%d" % orderID, goldMoves):
				return false
			if not _SettleListingLocked(sql, best, buyerChar, buyerAccount, "bid", goldMoves):
				return false
			var remain : int = need - qty
			var newEscrow : int = maxi(0, held - heldFor)
			if remain <= 0 and newEscrow > 0:
				if not _eco.kernel._MoveGoldLocked(sql, buyerChar, buyerAccount, newEscrow, "ah_bid_release:%d" % orderID, goldMoves):
					return false
				newEscrow = 0
			var patch : Dictionary = {"quantity" = maxi(0, remain), "escrow_gold" = newEscrow, "status" = "open" if remain > 0 else "filled"}
			if not sql.UpdateRowsRaw("ah_buy_order", "id = %d" % orderID, patch):
				return false
			tally["units"] = qty
			tally["listing"] = int(best.get("id", 0))
			tally["char"] = buyerChar
			return true)
		_eco.settleMutex.unlock()
		if not done:
			break
		_eco.kernel.ApplyGoldMoves(goldMoves)
		units += int(tally["units"])
		_RecordAH("ah_bid_fill", int(tally["char"]), {"order" = orderID, "listing" = int(tally["listing"]), "units" = int(tally["units"])})
	return units

# Anúncio novo pede passagem pela melhor ordem aberta (maior teto primeiro, em
# empate a mais antiga). Devolve o id do anúncio se ele foi liquidado a bid.
func _TryMatchListing(listingID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT seller_account, item_id, count, price_gold FROM auction_listing WHERE id = ? AND status = 'open';", [listingID])
	if rows.is_empty():
		return 0
	var listing : Dictionary = rows[0]
	var orders : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM ah_buy_order WHERE status = 'open' AND item_id = ? AND unit_price >= ? AND quantity >= ? AND buyer_account != ? ORDER BY unit_price DESC, id ASC LIMIT 1;", [int(listing.get("item_id", 0)), int(listing.get("price_gold", 0)), int(listing.get("count", 1)), int(listing.get("seller_account", 0))])
	if orders.is_empty():
		return 0
	if _FillFromBuyOrder(int(orders[0]["id"])) <= 0:
		return 0
	var after : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT status FROM auction_listing WHERE id = ?;", [listingID])
	if not after.is_empty() and str(after[0].get("status", "")) == "sold":
		return listingID
	return 0
