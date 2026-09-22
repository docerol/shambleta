extends Node

func _ready():
    var resource = load("res://sources/network/client/Client.gd")
    print("Type: ", typeof(resource))
    print("Is Script: ", resource is Script)
