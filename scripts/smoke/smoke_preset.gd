class_name SmokePreset extends Resource
## A smoke scene: the air and look it runs with, its emitters and scene action,
## which set stands in the domain, its sky, where the camera looks and where the
## sun sits.
##
## Presets live in [code]resources/smoke/presets/[/code].

enum Layout { FLARES, STACKS, CANNON, TUNNEL, STAGE }

@export var display_name := "Smoke flares"
@export var hint := ""
@export var layout: Layout = Layout.FLARES
## Sky, fog, ambient light and tone mapping; its ambient colour also lights the smoke.
@export var environment: Environment
## Physics, look and domain. Its Quality group is overwritten by the active tier.
@export var config: SmokeConfig
@export var emitters: Array[SmokeEmitter] = []
## The scene action fires every emitter with a trigger_s.
@export var action_icon := ""
@export var action_label := ""

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
	if environment == null:
		return "environment is missing"
	var error := config.validate()
	if error != "":
		return error
	if emitters.size() > SmokeSolver.MAX_SOURCES:
		return "more than %d emitters" % SmokeSolver.MAX_SOURCES
	var triggered := false
	for emitter in emitters:
		error = emitter.validate()
		if error != "":
			return error
		triggered = triggered or emitter.trigger_s > 0.0
	if triggered != (action_label != ""):
		return "action_label must be set exactly when an emitter has a trigger_s"
	return ""
