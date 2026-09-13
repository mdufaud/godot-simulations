class_name TerrainBrush extends RefCounted
## The sculpting tool [HeightfieldTerrain] applies each step: which operation, where
## it lands and how hard. Kept apart from the solver so a host can aim it from a
## mouse ray, an animation or a script without touching the simulation.
##
## [codeblock]
## solver.brush.mode = TerrainBrush.DIG
## solver.brush.pos_m = Vector2(0.2, -0.1)
## [/codeblock]

enum { NONE, DIG, POUR, SMOOTH, WATER, PACK, SNOW }
## SNOW deliberately sits last: presets serialize tool indices by number, so
## appending keeps every existing .tres valid.

var mode := NONE
## World-space xz, in the domain [HeightfieldTerrain] spans.
var pos_m := Vector2.ZERO
var radius_m := 0.3
var strength := 1.2


func idle() -> bool:
	return mode == NONE


func clear() -> void:
	mode = NONE
