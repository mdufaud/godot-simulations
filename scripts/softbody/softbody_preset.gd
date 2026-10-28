class_name SoftBodyPreset extends Resource
## A soft body scene: its bodies, the body the Drop action spawns, which props
## stand on the floor, how many rocks fall at the start, and the camera.
##
## Presets live in [code]resources/softbody/presets/[/code].

enum Layout { OPEN, STAIRS, PEGS, PRESS }

@export var display_name := "Jelly drop"
@export var hint := ""
@export var layout: Layout = Layout.OPEN
## Material and solver. Its Quality group is overwritten by the active tier.
@export var config: SoftBodyConfig
@export var bodies: Array[SoftBodyShape] = []
## Spawned by the Drop action above the camera target; its position is ignored.
@export var drop_shape: SoftBodyShape
## Rigid rocks that fall onto the scene when it starts.
@export_range(0, 64, 1) var rock_count := 0

@export_group("Camera")
@export var camera_target_m := Vector3(0.0, 0.6, 0.0)
@export_range(1.0, 30.0, 0.1) var camera_distance_m := 5.0
@export_range(-80.0, -5.0, 0.5) var camera_pitch_deg := -20.0
@export_range(-180.0, 180.0, 0.5) var camera_yaw_deg := 30.0


func validate() -> String:
	if config == null:
		return "config is missing"
	if drop_shape == null:
		return "drop_shape is missing"
	if bodies.is_empty():
		return "a preset needs at least one body"
	var error := config.validate()
	if error != "":
		return error
	for shape in bodies + [drop_shape]:
		error = shape.validate()
		if error != "":
			return error
	return ""
