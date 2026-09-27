extends RefCounted
class_name HudWindows

# Fatia do HUD (teto de 800 linhas do `Gui` — mesma regra de `ManualHudBar`): as
# janelas flutuantes novas nascem da CENA, como `Gui.EnsureGuildPanel` já faz com
# `GuildPanel.tscn`. Motivo medido: o TitleBar de fechar mora na cena; um painel
# criado por `.new()` abre mas não tem botão de fechar no mouse/touch — exatamente
# a classe de defeito do §13 da auditoria (alvo web/mobile sem teclado).
#
# O `.new()` continua existindo como degradação (cena removida/corrompida → a
# janela abre sem TitleBar em vez de não abrir), e é também o caminho que os
# harnesses headless usam para construir fora da árvore. Em produção a cena vence.
#
# `class_name` aqui, e não `const preload` dentro de `Gui.gd`: cada const custaria
# uma linha num arquivo que está EXATAMENTE no teto.

const AuctionHouseScene : PackedScene = preload("res://presets/gui/AuctionHouse.tscn")
const ArenaScene : PackedScene = preload("res://presets/gui/Arena.tscn")

static func NewAuctionHouse() -> Control:
	if AuctionHouseScene != null:
		return AuctionHouseScene.instantiate() as Control
	return AuctionHousePanel.new() as Control

static func NewArena() -> Control:
	if ArenaScene != null:
		return ArenaScene.instantiate() as Control
	return ArenaPanel.new() as Control
