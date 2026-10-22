class_name SmokePreset extends Resource
## A smoke scene: the air and look it runs with, its emitters, which props stand
## in the domain, where the camera looks and where the sun sits.
##
## Presets live in [code]resources/smoke/presets/[/code].

enum Layout { YARD, TUNNEL, CANNON, DRY_ICE }

@export var display_name := "Chimney yard"
@export var hint := ""
@export var layout: Layout = Layout.YARD
## Physics, look and domain. Its Quality group is overwritten by the active tier.
@export var config: SmokeConfig
@export var emitters: Array[SmokeEmitter] = []

@export_group("Camera")
@export var camera_target_m := Vector3(0.0, 3.0, 0.0)
@export_range(1.0, 60.0, 0.1) var camera_distance_m := 14.0
@export_range(-80.0, -5.0, 0.5) var camera_pitch_deg := -12.0
@export_range(-180.0, 180.0, 0.5) var camera_yaw_deg := 0.0

@export_group("Sun")
@export_range(2.0, 90.0, 0.5) var sun_elevation_deg := 35.0
@export_range(0.0, 360.0, 1.0) var sun_azimuth_deg := 0.0
@export var sun_color := Color(1.0, 0.95, 0.88)
@export_range(0.0, 8.0, 0.05) var sun_energy := 1.6


func validate() -> String:
	if config == null:
		return "config is missing"
	var error := config.validate()
	if error != "":
		return error
	if emitters.size() > SmokeSolver.MAX_SOURCES:
		return "more than %d emitters" % SmokeSolver.MAX_SOURCES
	for emitter in emitters:
		error = emitter.validate()
		if error != "":
			return error
	return ""
