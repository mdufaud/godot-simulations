class_name FractalPoi extends RefCounted
## A curated point of interest: where to dive and how deep it stays interesting.
##
## Coordinates are float64 literals, so they survive the deep zoom.

var x := 0.0
var y := 0.0
## Linear zoom beyond which the point stops resolving.
var max_zoom := 1.0


func _init(px: float, py: float, pmax_zoom: float) -> void:
	x = px
	y = py
	max_zoom = pmax_zoom


## Points worth diving into for [param fractal_type], in tour order.
static func list_for(fractal_type: int) -> Array[FractalPoi]:
	match fractal_type:
		1:
			return [FractalPoi.new(0.0, 0.0, 30.0)]
		2:
			return [
				FractalPoi.new(-1.7595, -0.0285, 8.0e3),
				FractalPoi.new(-1.625, -0.028, 5.0e3),
			]
		3:
			return [
				FractalPoi.new(-0.85, 0.0, 3.0e3),
				FractalPoi.new(0.0, 0.8, 3.0e3),
			]
		_:
			return [
				FractalPoi.new(-0.743643887037151, 0.131825904205330, 1.0e10),
				FractalPoi.new(-0.77568377, 0.13646737, 3.0e6),
				FractalPoi.new(-1.7548776662466927, 0.0, 1.0e7),
				FractalPoi.new(0.001643721971153, -0.822467633298876, 1.0e10),
				FractalPoi.new(0.285, 0.01, 3.0e4),
			]
