extends NpcScript

#
func OnStart():
	Mes("If you follow the western pass right there you'll leave Damasco Valley and venture into the Shiraz.")
	Mes("Do you know where you're going?")
	Choice("I am looking for the Petra Mines.", OnMines)
	Choice("I am looking for Damasco.", OnDamasco)

func OnMines():
	LookAtNpc("To Mines")
	Mes("If you follow this road you will be walking further away from the Petra Mines.")
	ResetCamera()
	Mes("You should head back west and aim for the southern side of this valley.")

func OnDamasco():
	LookAtNpc("To Damasco")
	Mes("You can follow that path to the north up to the city wall.")
	ResetCamera()
	Mes("You can't miss it, the city wall is almost visible from there!")
