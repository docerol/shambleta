extends RefCounted
class_name AuctionHouseQuery

# 059(b): a ARITMÉTICA de pedir página ao servidor, separada do painel que a usa.
#
# Antes desta migração a janela do leilão era `LIMIT 40` sem OFFSET e o resto
# (filtro de preço, recorte de página, nome→item) acontecia no client sobre o que
# tinha chegado. Consequência medida: um mercado com mais de 40 anúncios era
# invisível — as linhas 41 em diante não existiam para o jogador — e o "1/1" da
# régua era o tamanho do recorte local, não o do catálogo.
#
# Hoje o servidor pagina (`BrowseListingsPage` com OFFSET e `WHERE`), e estas
# três funções só respondem "para onde vai o offset agora" e "que item é este
# nome". Nenhuma delas decide o que é entregável: `offset` além do fim devolve
# página VAZIA no serviço, e nome ambíguo devolve 0 = "sem filtro de item", que é
# o jeito honesto de não filtrar demais.

# Quantas páginas CABEM no bloco que o servidor entregou. É o recorte de DESENHO
# (`pageShape` linhas por página dentro da janela de `ServerPageSize`): quando
# acaba, quem avança é `NextOffset`, pedindo a próxima página ao servidor.
static func BlockPages(block : int, pageShape : int) -> int:
	if block <= 0:
		return 1
	var size : int = maxi(1, pageShape)
	return maxi(1, int(ceil(float(block) / float(size))))

# Régua do JOGADOR: o total do servidor dividido pelo tamanho de página com que o
# painel desenha. É o número que aparece em "Page i/N" — e é por isso que ele não
# pode vir do tamanho do bloco entregue.
static func TotalPages(total : int, pageShape : int) -> int:
	var size : int = maxi(1, pageShape)
	if total <= 0:
		return 1
	return maxi(1, int(ceil(float(total) / float(size))))

# Offset da janela seguinte/anterior. O passo é o `blockSize` que o SERVIDOR
# declarou (`page_size`), nunca a fatia desenhada: são eles que mantêm as páginas
# consecutivas sem repetir e sem pular linha. Nunca negativo (OFFSET negativo é
# erro de SQL) e nunca além do fim conhecido — chegar no fim do catálogo é parar
# na última janela, não pedir vazio.
static func NextOffset(offset : int, delta : int, blockSize : int, total : int) -> int:
	var step : int = maxi(1, blockSize)
	var next : int = maxi(0, offset + delta * step)
	if total > 0:
		var lastStart : int = maxi(0, (int(ceil(float(total) / float(step))) - 1) * step)
		next = mini(next, lastStart)
	return next

# Nome → `item_id`. O texto do painel só vira filtro SQL quando resolve para UM
# item do catálogo local; com vários candidatos (ou nenhum) devolve 0 = "sem
# filtro de item", e o refinamento por substring continua sobre a página. O
# caminho por número/hash é o caso exato (é o id que o servidor devolve na
# vitrine), o por nome é o único em que ambiguidade importa.
static func ItemIDFor(query : String, items : Dictionary) -> int:
	var q : String = query.strip_edges().to_lower()
	if q.is_empty():
		return 0
	var found : int = 0
	var hits : int = 0
	for itemHash in items.keys():
		var cell : ItemCell = items.get(itemHash, null)
		if cell == null:
			continue
		if str(itemHash) == q:
			return int(itemHash)
		if str(cell.name).to_lower().find(q) >= 0:
			hits += 1
			found = int(itemHash)
			if hits > 1:
				return 0
	return found if hits == 1 else 0

# Fatia desenhada da página: nada aqui pede ou filtra estado — é recorte de
# exibição do bloco que já foi entregue, com índice saneado.
static func Slice(listings : Array, page : int, pageShape : int) -> Array:
	var size : int = maxi(1, pageShape)
	var start : int = maxi(0, page) * size
	if start >= listings.size():
		return []
	return listings.slice(start, mini(start + size, listings.size()))
