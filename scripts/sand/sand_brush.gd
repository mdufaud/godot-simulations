class_name SandBrush extends RefCounted
## The sculpting tool [HeightfieldSand] applies each step: which operation, where
## it lands and how hard. Kept apart from the solver so a host can aim it from a
## mouse ray, an animation or a script without touching the simulation.
##
## [codeblock]
## solver.brush.mode = SandBrush.DIG
## solver.brush.pos_m = Vector2(0.2, -0.1)
## [/codeblock]

enum { NONE, DIG, POUR, SMOOTH }

var mode := NONE
## World-space xz, in the domain [HeightfieldSand] spans.
var pos_m := Vector2.ZERO
var radius_m := 0.3
var strength := 1.2


func idle() -> bool:
	return mode == NONE


func clear() -> void:
	mode = NONE
