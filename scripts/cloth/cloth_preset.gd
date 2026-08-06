class_name ClothPreset extends Resource
## One sheet of cloth: its size, where it hangs, which vertices are pinned and how
## it looks. Owns the seed the solver starts from, so the sheet's geometry is
## described in one place instead of being split between the scene and the solver.
##
## Presets live in [code]resources/cloth/presets/[/code].

## Which vertices are kinematic. [code]EDGE[/code] pins the left column (a flag on
## a pole), [code]TOP[/code] the top row (a sheet on a clothesline), and
## [code]CORNERS[/code] the four corners of a sheet started horizontally.
enum Pin { EDGE, TOP, CORNERS }

@export var display_name := "Flag"
@export var pin: Pin = Pin.EDGE

@export_group("Geometry")
@export var size_m := Vector2(4.0, 2.6)
## Where the sheet hangs, on the ground plane.
@export var position_m := Vector3(-7.0, 0.0, 0.5)
@export_range(-PI, PI, 0.01) var yaw_rad := 0.0
## Height of the pinned edge above the ground.
@export_range(0.5, 12.0, 0.1) var top_m := 5.8
## Radius of the boulder the sheet drapes over; 0 means none.
@export_range(0.0, 4.0, 0.05) var boulder_radius_m := 0.0

@export_group("Look")
@export var color := Color(0.75, 0.15, 0.12)
@export var stripes := false


func validate() -> String:
	if size_m.x <= 0.0 or size_m.y <= 0.0:
		return "size_m must be positive on both axes"
	if top_m <= 0.0:
		return "top_m must be positive"
	return ""


## Centre of the boulder this sheet drapes over. Only meaningful when
## [member boulder_radius_m] is positive.
func boulder_center() -> Vector3:
	return position_m + Vector3(0.0, boulder_radius_m * 0.72, 0.0)


## One vertex per [param rest_spacing], so a bigger sheet gets more vertices rather
## than longer springs — stiffness stays comparable across sheets.
func grid_dims(rest_spacing: float) -> Vector2i:
	return Vector2i(
		clampi(int(size_m.x / rest_spacing), 8, 160),
		clampi(int(size_m.y / rest_spacing), 8, 160))


## 4 floats per vertex: rest position + pin flag (1 = kinematic). Flags and the
## clothesline hang vertically; a CORNERS sheet starts horizontal, its four pinned
## corners holding it above the boulder it drapes over.
func build_seed(w: int, h: int) -> PackedFloat32Array:
	var basis := Basis(Vector3.UP, yaw_rad)
	var out := PackedFloat32Array()
	out.resize(w * h * 4)
	for y in h:
		for x in w:
			var i := y * w + x
			var u := float(x) / (w - 1)
			var v := float(y) / (h - 1)
			var local: Vector3
			if pin == Pin.CORNERS:
				local = Vector3((u - 0.5) * size_m.x, top_m, (v - 0.5) * size_m.y)
			else:
				local = Vector3((u - 0.5) * size_m.x, top_m - v * size_m.y, 0.0)
			var pos := position_m + basis * local
			out[i * 4] = pos.x
			out[i * 4 + 1] = pos.y
			out[i * 4 + 2] = pos.z
			out[i * 4 + 3] = 1.0 if _is_pinned(x, y, w, h) else 0.0
	return out


func _is_pinned(x: int, y: int, w: int, h: int) -> bool:
	match pin:
		Pin.EDGE:
			return x == 0
		Pin.TOP:
			return y == 0
		Pin.CORNERS:
			return (x == 0 or x == w - 1) and (y == 0 or y == h - 1)
	return false
