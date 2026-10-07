extends RefCounted
class_name EconomyReconcile

# P-3 (2026-10-06): o braço de reconcílio saiu da fachada de economia pelo caminho
# que o próprio `repo_layout_test` registrou como saída do cerca-encostada: a
# fachada fica com a delegação — o seam contratual é `Launcher.Economy`
# (`SQLBackups.@Run`, o painel e as suítes leem por lá) — e as pernas que somam,
# nomeiam e carimbam `reconcile_run` vivem aqui, com `_eco` injetado porque
# consultam `tournamentArenaService` e `kernel` DA fachada (o mutex de settle é
# uma só fileira: quem segura é o corpo chamado, não este contêiner).
# ReconcileDetail é o rodapé nomeado do contador; a régua da suíte de reconcile
# confere `size() == ReconcileDaily()` e foi por isso que as duas pernas ficaram
# juntas nesta fatia — separá-las do diagnóstico é como o portão mente.

var _eco : EconomyService = null

func ReconcileDaily() -> int:
	return _eco.tournamentArenaService.ReconcileDaily() + int(_eco.kernel.ReconcileWalletDaily().get("total", 0))

func ReconcileDetail() -> Array[Dictionary]:
	var rows : Array[Dictionary] = _eco.tournamentArenaService.Divergences()
	rows.append_array(_eco.kernel.DivergingWallets())
	return rows

# O job diário (SQLBackups → Launcher.Economy.RunReconcileJob). A perna de
# carteira entra na MESMA linha de `reconcile_run` que a arena abriu hoje — o
# painel lê `divergences`, e duas corridas no mesmo dia inventariam um
# reconciliar que não houve.
func RunReconcileJob() -> int:
	var arenaDivergences : int = _eco.tournamentArenaService.RunReconcileJob()
	var walletDivergences : int = int(_eco.kernel.ReconcileWalletDaily().get("total", 0))
	if walletDivergences > 0:
		Launcher.SQL.ExecuteBindings("UPDATE reconcile_run SET divergences = divergences + ? WHERE id = (SELECT MAX(id) FROM reconcile_run);", [walletDivergences])
		# O job da arena já imprimiu os nomes dela; a perna de carteira é somada
		# AQUI, então é aqui que ela precisa dar nome — senão o painel sobe de 0
		# para 3 e o plantão não tem para onde olhar. O NÚMERO continua o do
		# contador (`ReconcileWalletDaily`); a lista é só o rodapé, e a suíte de
		# reconcile confere que os dois são o mesmo tamanho.
		var named : int = 0
		for offender in _eco.kernel.DivergingWallets():
			if named >= 3:
				break
			named += 1
			Util.PrintLog("Economy", "Reconcile offender: " + JSON.stringify(offender))
	return arenaDivergences + walletDivergences
