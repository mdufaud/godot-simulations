class_name ExplosionScenery extends RefCounted

const POST_COUNT := 8
const POST_RING_M := 9.0
const POST_HEIGHT_M := 3.0
const RANGE_CONFIG := preload("res://resources/explosion/presets/range.tres")
const FIREBALL_RANGE_CONFIG := preload("res://resources/explosion/presets/fireball_range.tres")
const MUSHROOM_CONFIG := preload("res://resources/explosion/presets/mushroom.tres")
const NUKE_CHARGE := preload("res://resources/explosion/presets/nuke_charge.tres")
const FIREBALL_CHARGE := preload("res://resources/explosion/presets/fireball_charge.tres")
## Cell size the raymarcher's metre constants were tuned at.
const REFERENCE_CELL_M := 0.2
const BARREL_CHARGE := preload("res://resources/explosion/presets/barrel_charge.tres")
const PLAIN_SIZE_M := 60000.0
## Metres per texture tile on the plain.
const PLAIN_TILE_M := 333.0
## Depth fog starts here and reaches full strength at the camera far plane, hiding the plain's far edge.
const FOG_BEGIN_M := 6000.0
## Night smoke is lit by a faint ambient that scales with its albedo.
const NIGHT_AMBIENT_GAIN := 0.35
const SMOKE_ABSORPTION_PER_M := 4.5
## Scales the sun and the sky fill; the fill is a quarter of the sun's strength at most.
const SUN_GAIN := 0.8
const SKY_GAIN := 0.04
const SUN_SHADOW_TAPS := 6
const SUN_SHADOW_LENGTH_M := 16.0
## Taps at mid-step: a blue-noise offset prints a 1 px stipple into the sunlit smoke.
const SUN_JITTER_STRENGTH := 0.0
const SUN_PHASE_G := 0.2
## Sun seen from the default camera: from the side, so the cap has a lit and a shaded flank.
const SUN_YAW_DEG := 80.0
const SUN_ELEVATION_DEG := 35.0
## Per scene: orbit camera target, distance range, pitch, fov, far plane, then the wheel step and the move speed
## (metres): the mushroom's km scale needs them scaled with its distance, nothing else differs.
const FRAMING := [
	{target = Vector3(0.0, 2.5, 0.0), distance = 14.0, min_distance = 4.0, max_distance = 40.0,
		pitch = -10.0, fov = 60.0, far = 300.0, zoom_speed = 1.0, move_speed = 15.0},
	{target = Vector3(0.0, 2.2, 0.0), distance = 15.0, min_distance = 4.0, max_distance = 40.0,
		pitch = -22.0, fov = 60.0, far = 300.0, zoom_speed = 1.0, move_speed = 15.0},
	{target = Vector3(0.0, 529.0, 0.0), distance = 3700.0, min_distance = 1500.0, max_distance = 3800.0,
		pitch = 7.9, fov = 19.5, far = 14000.0, zoom_speed = 150.0, move_speed = 1500.0},
]

var world_env: WorldEnvironment
## Never the preloaded const's radius scaled in place: the host hands a scaled duplicate.
var barrel_charge: ExplosionCharge = BARREL_CHARGE
var sun: DirectionalLight3D
var ground: Node3D

var _root: Node3D
var _dust: ExplosionDustRing
var _index := 0
var _metric_scale := 1.0
var _barrels: Array[ExplosiveBarrel] = []
var _yard: ExplosionBarrelYard
var _on_barrels_full: Callable
var _night_env: Environment
var _night_sun := {}


static func config_for(index: int) -> ExplosionConfig:
	if index == ExplosionMenu.SCENE_MUSHROOM:
		return MUSHROOM_CONFIG
	return RANGE_CONFIG if index == ExplosionMenu.SCENE_BARRELS else FIREBALL_RANGE_CONFIG


static func base_charge(index: int) -> ExplosionCharge:
	if index == ExplosionMenu.SCENE_MUSHROOM:
		return NUKE_CHARGE
	return BARREL_CHARGE if index == ExplosionMenu.SCENE_BARRELS else FIREBALL_CHARGE


## Metre constants only grow with coarse cells; a finer grid resolves the same picture.
static func metric_scale(config: ExplosionConfig) -> float:
	return maxf(config.cell_size_m / REFERENCE_CELL_M, 1.0)


func bind(host_env: WorldEnvironment, host_sun: DirectionalLight3D, host_ground: Node3D, on_barrels_full := Callable()) -> void:
	_on_barrels_full = on_barrels_full
	world_env = host_env
	sun = host_sun
	ground = host_ground


func build(parent: Node3D, index: int, system: ExplosionSystem) -> void:
	clear()
	_index = index
	_metric_scale = metric_scale(system.config)
	_root = Node3D.new()
	parent.add_child(_root)
	_set_daylight(index == ExplosionMenu.SCENE_MUSHROOM)
	if index == ExplosionMenu.SCENE_BARRELS:
		_build_barrels(system)
	elif index == ExplosionMenu.SCENE_MUSHROOM:
		_build_plain()
	else:
		_build_posts()
	_add_dust(system)


func ground_height_m() -> float:
	return ExplosionBarrelYard.SLAB_THICKNESS_M if _yard != null else 0.0


## Stops what a detonation set going besides the gas: the dust rings.
func clear_effects() -> void:
	if _dust != null:
		_dust.clear()


func clear() -> void:
	_barrels = []
	_yard = null
	_dust = null
	if _root != null:
		_root.queue_free()
		_root = null


static func scale_distance(orbit: OrbitCamera, factor: float) -> void:
	orbit.distance = clampf(orbit.distance * factor, orbit.min_distance, orbit.max_distance)


static func apply_framing(orbit: OrbitCamera, camera: Camera3D, index: int) -> void:
	var framing: Dictionary = FRAMING[index]
	orbit.target = framing.target
	orbit.min_distance = framing.min_distance
	orbit.max_distance = framing.max_distance
	orbit.distance = framing.distance
	orbit.pitch = framing.pitch
	orbit.zoom_speed = framing.zoom_speed
	orbit.move_speed = framing.move_speed
	orbit.max_pitch = maxf(-5.0, framing.pitch)
	camera.fov = framing.fov
	camera.far = framing.far


func detonate_first() -> bool:
	for barrel in _barrels:
		if is_instance_valid(barrel) and not barrel.detonated:
			barrel.detonate()
			return true
	return false


func set_barrel_charge(charge: ExplosionCharge) -> void:
	barrel_charge = charge
	if _yard != null:
		_yard.charge = charge
	for barrel in _barrels:
		if is_instance_valid(barrel):
			barrel.charge = charge


func add_cluster_at(camera: Camera3D, screen_position: Vector2) -> bool:
	return _yard != null and _yard.add_cluster_at_screen(camera, screen_position)


## The standing barrel a ball centred at [param point] touches, or null.
func barrel_at(point: Vector3, reach_m: float) -> ExplosiveBarrel:
	for barrel in _barrels:
		if is_instance_valid(barrel) and not barrel.detonated \
				and ExplosionActions.barrel_touched(barrel.global_position, barrel.global_basis.y, point, reach_m):
			return barrel
	return null


func detonate_touching(point: Vector3, reach_m: float) -> bool:
	var barrel := barrel_at(point, reach_m)
	if barrel != null:
		barrel.detonate()
	return barrel != null


static func make_presentation(solver: FireGpuSolver, volume: MeshInstance3D, camera: Camera3D,
		light: OmniLight3D, metric_scale: float) -> FirePresentation:
	var presentation := FirePresentation.new()
	presentation.solver = solver
	presentation.fire_volume = volume
	presentation.camera = camera
	presentation.fire_light = light
	presentation.proxy_margin_m *= metric_scale
	presentation.smoke_light_gain = 0.06 if metric_scale <= 1.0 else 0.0
	return presentation


## Smoke lighting of the built scene for a smoke of [param albedo]; the ambient fill follows the albedo.
func smoke_lighting(albedo: Vector3) -> Dictionary:
	if _index != ExplosionMenu.SCENE_MUSHROOM:
		return {sun_rgb = Vector3.ZERO, sun_shadow_taps = 0,
			smoke_ambient_rgb = albedo * NIGHT_AMBIENT_GAIN, smoke_albedo = albedo}
	var per_m := SMOKE_ABSORPTION_PER_M / _metric_scale
	var sun_color := Vector3(sun.light_color.r, sun.light_color.g, sun.light_color.b)
	var sky := world_env.environment.ambient_light_color
	var sky_rgb := Vector3(sky.r, sky.g, sky.b) * world_env.environment.ambient_light_energy
	return {
		sun_dir = sun.global_basis.z,
		sun_rgb = sun_color * (sun.light_energy * SUN_GAIN * per_m),
		smoke_ambient_rgb = albedo * sky_rgb * (SKY_GAIN * per_m),
		smoke_albedo = albedo,
		sun_shadow_taps = SUN_SHADOW_TAPS,
		sun_jitter_strength = SUN_JITTER_STRENGTH,
		sun_shadow_length = SUN_SHADOW_LENGTH_M * _metric_scale,
		sun_phase_g = SUN_PHASE_G,
	}


## Every per-metre raymarcher constant follows the cell size, so a 2 m grid draws the same picture ten times larger.
static func scale_volume(presentation: FirePresentation, metric_scale: float, config: ExplosionConfig) -> void:
	var coarse := metric_scale > 1.0
	var values := {
		max_distance = 80.0 * metric_scale, smoke_light_range = 8.0 * metric_scale,
		noise_scale = 0.35 / metric_scale, emission_strength = 12.0,
		flame_absorption = 1.0 / metric_scale, smoke_absorption = SMOKE_ABSORPTION_PER_M / metric_scale,
		steam_strength = 6.0 / metric_scale, steam_absorption = 4.0 / metric_scale,
		march_step = 1.5 if coarse else 0.75, march_budget = 512 if coarse else 320,
		external_scene_depth = false, scene_distance_tex = null,
		noise_detail = 0.0, scroll_speed = 0.0,
		glow_visible_from_k = config.glow_visible_from_k, glow_visible_full_k = config.glow_visible_full_k,
	}
	for key: String in values:
		presentation.set_volume_parameter(key, values[key])
	presentation.apply_billow(config.billow, config.cell_size_m)


func _add_dust(system: ExplosionSystem) -> void:
	_dust = ExplosionDustRing.new()
	_dust.system = system
	_root.add_child(_dust)
	_dust.start()


func _build_barrels(system: ExplosionSystem) -> void:
	_yard = ExplosionBarrelYard.new()
	_yard.system = system
	_yard.charge = barrel_charge
	if _on_barrels_full.is_valid():
		_yard.full_changed.connect(_on_barrels_full)
	_root.add_child(_yard)
	_barrels = _yard.barrels


func _build_posts() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.08
	mesh.bottom_radius = 0.08
	mesh.height = POST_HEIGHT_M
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.23, 0.26)
	mat.roughness = 0.9
	mesh.material = mat
	for i in POST_COUNT:
		var angle := TAU * float(i) / float(POST_COUNT)
		var post := MeshInstance3D.new()
		post.mesh = mesh
		post.position = Vector3(cos(angle) * POST_RING_M, POST_HEIGHT_M * 0.5, sin(angle) * POST_RING_M)
		_root.add_child(post)


func _set_daylight(day: bool) -> void:
	if _night_env == null:
		_night_env = world_env.environment
		_night_sun = {color = sun.light_color, energy = sun.light_energy, basis = sun.basis}
	ground.visible = not day
	if not day:
		world_env.environment = _night_env
		sun.light_color = _night_sun.color
		sun.light_energy = _night_sun.energy
		sun.basis = _night_sun.basis
		return
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.22, 0.42, 0.78)
	sky_material.sky_horizon_color = Color(0.66, 0.78, 0.9)
	sky_material.ground_horizon_color = sky_material.sky_horizon_color
	sky_material.ground_bottom_color = sky_material.sky_horizon_color
	var sky := Sky.new()
	sky.sky_material = sky_material
	var env := _night_env.duplicate() as Environment
	env.sky = sky
	env.ambient_light_color = Color(0.6, 0.7, 0.85)
	env.ambient_light_energy = 0.8
	env.glow_intensity = 0.4
	env.glow_hdr_threshold = 2.5
	env.tonemap_exposure = 1.6
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.1
	env.adjustment_saturation = 1.4
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = FOG_BEGIN_M
	env.fog_depth_end = FRAMING[ExplosionMenu.SCENE_MUSHROOM].far
	env.fog_light_color = sky_material.sky_horizon_color
	env.fog_sky_affect = 0.0
	world_env.environment = env
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.light_energy = 1.3
	sun.basis = Basis.from_euler(Vector3(deg_to_rad(-SUN_ELEVATION_DEG), deg_to_rad(SUN_YAW_DEG), 0.0))


func _build_plain() -> void:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.04
	noise.fractal_octaves = 4
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray([Color(0.3, 0.3, 0.2), Color(0.46, 0.43, 0.3)])
	var texture := NoiseTexture2D.new()
	texture.noise = noise
	texture.color_ramp = ramp
	texture.seamless = true
	texture.width = 512
	texture.height = 512
	var plain_mat := StandardMaterial3D.new()
	plain_mat.albedo_texture = texture
	plain_mat.uv1_scale = Vector3.ONE * (PLAIN_SIZE_M / PLAIN_TILE_M)
	plain_mat.roughness = 1.0
	plain_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var plain := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * PLAIN_SIZE_M
	plane.material = plain_mat
	plain.mesh = plane
	_root.add_child(plain)
