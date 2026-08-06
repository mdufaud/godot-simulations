class_name SandPreset extends Resource
## A sand scene: the height field it starts from, where the camera looks and
## which brush is armed.
##
## Presets live in [code]resources/sand/presets/[/code].
##
## [codeblock]
## var preset: SandPreset = preload("res://resources/sand/presets/dunes.tres")
## solver.set_seed(preset.build_seed(solver.grid_n, solver.world_size))
## [/codeblock]

enum Terrain { FLAT, DUNES }

@export var display_name := "Sandbox dig"
@export_enum("None", "Dig", "Pour", "Smooth") var default_tool: int = SandBrush.DIG
@export var walls_visible := true

@export_group("Terrain")
@export var terrain: Terrain = Terrain.FLAT
## Starting column height, and the floor the dunes rise from.
@export_range(0.0, 2.0, 0.001) var base_height_m := 0.35
@export_range(0.0, 2.0, 0.001) var dune_amplitude_m := 0.45
@export_range(0.05, 4.0, 0.01) var dune_frequency := 0.55
@export_range(1, 8, 1) var dune_octaves := 4
@export var dune_seed := 7

@export_group("Camera")
@export var camera_target_m := Vector3(0.0, 0.3, 0.0)
@export_range(0.5, 40.0, 0.1) var camera_distance_m := 4.5

@export_group("Auto pour")
## Radius of the slow pouring orbit that runs when the user is not sculpting.
## 0 disables it: the scene only moves under the brush.
@export_range(0.0, 4.0, 0.01) var auto_pour_radius_m := 0.0
@export_range(0.0, 4.0, 0.01) var auto_pour_rate_rad_s := 0.5
@export_range(0.0, 4.0, 0.01) var auto_pour_strength := 1.8


func validate() -> String:
	if base_height_m < 0.0:
		return "base_height_m cannot be negative"
	if camera_distance_m <= 0.0:
		return "camera_distance_m must be positive"
	if auto_pour_radius_m < 0.0:
		return "auto_pour_radius_m cannot be negative"
	return ""


func pours_by_itself() -> bool:
	return auto_pour_radius_m > 0.0


## grid_n * grid_n column heights in metres, row-major, x fastest -- the layout
## [method HeightfieldSand.set_seed] expects.
func build_seed(grid_n: int, world_size: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(grid_n * grid_n)
	if terrain == Terrain.FLAT:
		out.fill(base_height_m)
		return out
	var noise := FastNoiseLite.new()
	noise.seed = dune_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = dune_frequency
	noise.fractal_octaves = dune_octaves
	var cell := world_size / float(grid_n)
	for j in grid_n:
		var z := (float(j) + 0.5) * cell - world_size * 0.5
		var row := j * grid_n
		for i in grid_n:
			var x := (float(i) + 0.5) * cell - world_size * 0.5
			out[row + i] = base_height_m + dune_amplitude_m * (noise.get_noise_2d(x, z) * 0.5 + 0.5)
	return out
