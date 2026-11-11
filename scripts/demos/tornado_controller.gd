extends Node3D

const VirtualJoystickScript = preload("res://scripts/ui/virtual_joystick.gd")
const TornadoWindField = preload("res://scripts/tornado/tornado_wind_field.gd")
const TornadoBackdrop = preload("res://scripts/demos/tornado/tornado_backdrop.gd")

const PRESETS := [
	{name = "Classic EF4", model = TornadoWindField.Model.BURGERS_ROTT, r0 = 45.0, u = 85.0,
		h = 550.0, flare = 2.5, a = 0.15, s = 0.15, dust = 1.0, dark = 0.55},
	# Sullivan's eye downdraft is twice the Burgers-Rott axial updraft at the same
	# a_bar (published b = 3), hence the gentler suction.
	{name = "Wedge / Typhoon", model = TornadoWindField.Model.SULLIVAN, r0 = 160.0, u = 70.0,
		h = 500.0, flare = 0.8, a = 0.12, s = 0.05, dust = 1.1, dark = 0.6},
	{name = "S-curve rope", model = TornadoWindField.Model.BURGERS_ROTT, r0 = 22.0, u = 75.0,
		h = 600.0, flare = 3.5, a = 0.12, s = 0.85, dust = 0.7, dark = 0.45},
]

## Light of the clear slot under the anvil, Normal look.
const SLOT_COLOR := Color(0.82, 0.83, 0.74)
## Length of the damage path (matches trail[] in tornado_ground.gdshader).
const TRAIL_POINTS := 24
## Ambient boost at a strike's peak.
const FLASH_AMBIENT_GAIN := 1.6
## Range of the strikes that fall across the plain, from the camera.
const FAR_STRIKE_M := Vector2(700.0, 3200.0)

const STORM_TYPES := [
	{name = "Normal"},
	{name = "Fire", funnel = Color(0.9, 0.35, 0.08), cloud = Color(0.2, 0.11, 0.08),
		dust = Color(1.0, 0.5, 0.1), particles = Color(1.0, 0.55, 0.15),
		bolt = Color(1.0, 0.55, 0.15), glow = 0.12,
		sky = Color(0.34, 0.2, 0.15), ambient = Color(0.45, 0.3, 0.22),
		ground_a = Color(0.06, 0.05, 0.045), ground_b = Color(0.16, 0.115, 0.085),
		ground_accent = Color(1.0, 0.42, 0.08), ground_glow = 0.55},
	{name = "Water", funnel = Color(0.07, 0.2, 0.33), cloud = Color(0.18, 0.23, 0.3),
		dust = Color(0.55, 0.7, 0.8), particles = Color(0.7, 0.83, 0.92),
		bolt = Color(0.6, 0.85, 1.0), glow = 0.0,
		sky = Color(0.38, 0.45, 0.53), ambient = Color(0.42, 0.48, 0.55),
		ground_a = Color(0.05, 0.095, 0.145), ground_b = Color(0.1, 0.17, 0.23),
		ground_accent = Color(0.62, 0.72, 0.8), ground_glow = 0.35},
	{name = "Ice", funnel = Color(0.62, 0.76, 0.88), cloud = Color(0.55, 0.63, 0.73),
		dust = Color(0.85, 0.92, 1.0), particles = Color(0.92, 0.97, 1.0),
		bolt = Color(0.7, 0.9, 1.0), glow = 0.08,
		sky = Color(0.6, 0.68, 0.77), ambient = Color(0.6, 0.66, 0.74),
		ground_a = Color(0.8, 0.85, 0.91), ground_b = Color(0.56, 0.64, 0.76),
		ground_accent = Color(0.88, 0.93, 1.0), ground_glow = 0.0},
	{name = "Plasma", funnel = Color(0.4, 0.1, 0.62), cloud = Color(0.12, 0.06, 0.19),
		dust = Color(0.65, 0.28, 0.85), particles = Color(0.85, 0.5, 1.0),
		bolt = Color(0.9, 0.4, 1.0), glow = 0.3,
		sky = Color(0.17, 0.11, 0.24), ambient = Color(0.32, 0.24, 0.42),
		ground_a = Color(0.075, 0.05, 0.125), ground_b = Color(0.13, 0.085, 0.2),
		ground_accent = Color(0.58, 0.28, 0.95), ground_glow = 0.4},
]

@onready var cam_rig: FreeFlyCamera = $CameraRig
@onready var tornado_node: Node3D = $Tornado
@onready var funnel_volume: MeshInstance3D = $Tornado/FunnelVolume
@onready var cloud_deck: MeshInstance3D = $Tornado/CloudDeck
@onready var dust_particles: GPUParticles3D = $Tornado/DustParticles
@onready var skirt_particles: GPUParticles3D = $Tornado/SkirtParticles
@onready var lightning_light: OmniLight3D = $Tornado/LightningLight
@onready var menu = $UI/SimMenu
@onready var debris_pool: TornadoDebrisPool = $DebrisPool
@onready var ground_mesh: MeshInstance3D = $Ground/MeshInstance3D
@onready var _viewport := ViewportGuard.attach(self)

var field := TornadoWindField.new()
var config: TornadoConfig = TornadoConfig.new()
var s_amount := 0.15
var travel_speed := 6.0
var lightning_enabled := true
var dust_color := Color(0.46, 0.46, 0.48)
var storm_color := Color(0.3, 0.31, 0.36)
var storm_type := 0

var _time := 0.0
## Unwrapped rotation of the vortex at its base radius of maximum wind (rad).
var _spin_phase := 0.0
var _frozen := false
var _wander_noise := FastNoiseLite.new()
var _track := TornadoTrack.new()
var _lead := PackedVector2Array()
var _debris_bar: ProgressBar
var _funnel_mat: ShaderMaterial
var _cloud_mat: ShaderMaterial
var _ground_mat: ShaderMaterial
var _renderer := TornadoRenderer.new()
var _sliders := {}
var _model_btn: OptionButton
var _preset_btn: OptionButton
var _look_btn: OptionButton
var _rng := RandomNumberGenerator.new()

var _lightning_timer := 3.0
var _flash_pos := Vector3.ZERO
var _flash_tint := Color(0.8, 0.85, 1.0)
var _lightning := TornadoLightning.new()
var _backdrop := TornadoBackdrop.new()
var _trail := PackedVector2Array()
var _trail_count := 0
var _environment: Environment
var _ambient_energy := 1.0

var _pending_cap := -1
var _cap_debounce := 0.0
var _skirt_density := 0.5
var quality := SimQualityState.new()
## Set once the initial debris pool exists; a tier switch past this point
## rebuilds it through the debounced cap path.
var _pool_built := false
## Steps live on the funnel shader, which restore() reaches before the
## materials are captured in _ready — the var carries the value across.
var _raymarch_steps := 48
## Capture harness state: the named pose follows the travelling foot, and a
## fixed step replays minutes of travel in a few frames.
var _capture_view := ""
var _capture_delta := 0.0


func _ready() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Tornado config: %s" % config_error)
		return
	field.model = config.model
	field.u_max = config.maximum_wind_mps
	field.r_core0 = config.core_radius_m
	field.height = config.height_m
	field.flare = config.flare
	field.a_bar = config.radial_inflow
	s_amount = config.centerline_s_curve
	travel_speed = config.travel_speed_mps
	_track.extent_m = config.travel_extent_m
	_track.noise.seed = 1337
	_lead.resize(TornadoWindField.NUM_SLICES)
	_trail.resize(TRAIL_POINTS)
	_wander_noise.seed = 1337
	_rng.seed = 4242
	debris_pool.field = field
	quality.setup(TornadoQualityProfile, "tornado_quality_profile", _apply_quality)
	quality.restore()
	debris_pool.build_pool(debris_pool.debris_cap)
	# Sparse ground scatter: every scattered prop the wind lifts joins the
	# ring around the core, and at spawn distance sub-meter pieces render as
	# white dots — a dense scatter reads as noise veiling the funnel neck.
	debris_pool.scatter_props(0.15)
	debris_pool.camera = cam_rig.get_camera()
	_pool_built = true
	_funnel_mat = funnel_volume.material_override
	_funnel_mat.set_shader_parameter("steps", _raymarch_steps)
	_cloud_mat = cloud_deck.material_override
	_ground_mat = ground_mesh.get_surface_override_material(0) as ShaderMaterial
	_ground_mat.set_shader_parameter("vortex_radius", field.r_core0)
	_renderer.setup(_funnel_mat, _cloud_mat, [
		dust_particles.process_material as ShaderMaterial,
		skirt_particles.process_material as ShaderMaterial,
	])
	_renderer.push_wind(field)
	var sun: Vector3 = -($DirectionalLight3D as DirectionalLight3D).global_basis.z
	_funnel_mat.set_shader_parameter("sun_dir", sun)
	_cloud_mat.set_shader_parameter("sun_dir", sun)
	_ground_mat.set_shader_parameter("sun_dir", sun)
	_ground_mat.set_shader_parameter("swirl_sign", field.swirl_sign)
	_ground_mat.set_shader_parameter("vortex_pos", tornado_node.position)
	_environment = ($WorldEnvironment as WorldEnvironment).environment
	_ambient_energy = _environment.ambient_light_energy
	add_child(_lightning)
	_backdrop.setup(_environment, $Ground, cam_rig.get_camera(), sun)
	_update_funnel_bounds()
	cam_rig.set_pose(Vector3(0.0, 1.8, _camera_distance(380.0)), 0.0, 12.0)
	_setup_ui()
	# Boot through the SAME look path as the UI switch: without this the
	# funnel/particles keep their BROWN shader-default dust at runtime (the
	# capture harness always calls apply_look, masking the divergence).
	_apply_storm_type(storm_type)


## Aspect compensation shared with the framing gate. Portrait pulls back at
## most x1.5: just enough that the full column clears the frame. The old
## unbounded (16/9)/aspect put phones at ~3.9x the distance.
func _camera_distance(base_distance: float) -> float:
	return camera_distance(base_distance, DisplayServer.window_get_size())


static func camera_distance(base_distance: float, window_size: Vector2i) -> float:
	var aspect := float(window_size.x) / maxf(float(window_size.y), 1)
	return base_distance * clampf((16.0 / 9.0) / aspect, 1.0, 1.5)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and cam_rig.is_captured():
		_throw_from_camera()


func _throw_from_camera() -> void:
	var cam := cam_rig.get_camera()
	debris_pool.queue_throw(cam.global_position, -cam.global_basis.z)


func _process(delta: float) -> void:
	_spin_phase += field.u_max / field.r_core0 * delta
	_renderer.push_spin(_spin_phase)
	_ground_mat.set_shader_parameter("spin_phase", _spin_phase)
	var cam := cam_rig.get_camera()
	if cam != null:
		var cam_pos := cam.global_position
		for pm: ShaderMaterial in [dust_particles.process_material, skirt_particles.process_material]:
			pm.set_shader_parameter("camera_position", cam_pos)
	if not _frozen:
		if _capture_delta > 0.0:
			delta = _capture_delta
		_time += delta
		_track.advance(delta, travel_speed)
		field.base_pos = _track.position_at(field.axis_lag_s(0.0))
		for i in TornadoWindField.NUM_SLICES:
			var z01 := float(i) / (TornadoWindField.NUM_SLICES - 1)
			var ahead := _track.position_at(field.axis_lag_s(z01)) - field.base_pos
			_lead[i] = Vector2(ahead.x, ahead.z)
		field.update_centerline(_time * 0.05, s_amount, _wander_noise, _lead)
		tornado_node.position = field.base_pos
		_ground_mat.set_shader_parameter("vortex_pos", tornado_node.position)
		_record_trail()
		if _capture_view != "":
			_apply_capture_view()
	# Outside the Freeze gate: Freeze holds the vortex in place, but slider edits
	# must still reach the grid the debris sample and the shaders' uniforms. Both
	# calls are no-ops unless a wind parameter changed (or, for the centerline
	# uniform, a single cheap array per frame).
	field.bake_wind_grid()
	_renderer.push_wind(field)
	_update_lightning(delta)
	if _debris_bar:
		_debris_bar.value = debris_pool.active_count
	if _pending_cap > 0:
		_cap_debounce -= delta
		if _cap_debounce <= 0.0:
			debris_pool.build_pool(_pending_cap)
			# Same sparse fraction as the initial scatter in _ready: the
			# default 0.6 quadrupled the ground props after every preset,
			# quality or cap change — the ground visibly changed mid-session.
			debris_pool.scatter_props(0.15)
			_debris_bar.max_value = _pending_cap
			_pending_cap = -1


## The damage path the ground shader scours: one point every half core radius,
## the newest always at the vortex foot.
func _record_trail() -> void:
	var foot := Vector2(field.base_pos.x, field.base_pos.z)
	if _trail_count < 2:
		_trail[0] = foot
		_trail_count = 2
	elif _trail[_trail_count - 2].distance_to(foot) > maxf(0.5 * field.r_core0, 15.0):
		if _trail_count == TRAIL_POINTS:
			for i in TRAIL_POINTS - 1:
				_trail[i] = _trail[i + 1]
		else:
			_trail_count += 1
	_trail[_trail_count - 1] = foot
	_ground_mat.set_shader_parameter("trail", _trail)
	_ground_mat.set_shader_parameter("trail_count", _trail_count)


func _update_funnel_bounds() -> void:
	# Worst-case centerline excursion: S bow (0.12 H) + wander noise (0.05 H)
	# + the travelling top's lead over the base.
	var max_off: float = (0.12 * s_amount + 0.05) * field.height + minf(
		field.axis_lag_s(0.0) * travel_speed, TornadoWindField.AXIS_LEAD_LIMIT * field.height)
	var half_xz: float = maxf(1.8 * field.r_core0 * (1.0 + field.flare),
		(3.4 + 1.2 * _skirt_density) * field.r_core0) + max_off
	var size := Vector3(2.0 * half_xz, field.height, 2.0 * half_xz)
	(funnel_volume.mesh as BoxMesh).size = size
	funnel_volume.position = Vector3(0.0, field.height * 0.5, 0.0)
	_funnel_mat.set_shader_parameter("box_size", size)
	if _ground_mat != null:
		_ground_mat.set_shader_parameter("vortex_radius", field.r_core0)
	cloud_deck.position = Vector3(0.0, field.height, 0.0)


# ── Lightning ────────────────────────────────────────────────────────────────

func _update_lightning(delta: float) -> void:
	if lightning_enabled:
		_lightning_timer -= delta
		if _lightning_timer <= 0.0:
			_trigger_lightning()
			_lightning_timer = _rng.randf_range(0.6, 4.0) / maxf(field.u_max / 85.0, 0.3)
	_lightning.tick(delta)
	var flash := _lightning.flash()
	lightning_light.light_energy = flash * 25.0
	# The whole sky lights the ground and the far relief, not only the strike's foot.
	_environment.ambient_light_energy = _ambient_energy * (1.0 + FLASH_AMBIENT_GAIN * flash)
	# x2 peak: past it the in-scatter saturates the whole column to white and
	# the storm disappears for the flash duration.
	_funnel_mat.set_shader_parameter("flash_intensity", flash * 2.0)
	_funnel_mat.set_shader_parameter("flash_pos", _flash_pos)
	_cloud_mat.set_shader_parameter("flash_intensity", flash * 1.5)
	_cloud_mat.set_shader_parameter("flash_pos", _flash_pos)


## Half of the strikes land beside the funnel (cloud-to-ground outside the
## condensation wall, so the channel silhouettes against the sky instead of
## drowning in the volume); the rest fall across the plain in front of the
## camera, down to a flicker on the horizon.
func _trigger_lightning(beside_funnel := _rng.randf() < 0.5) -> void:
	var top: Vector3
	var ground: Vector3
	var amplitude := 1.0
	if beside_funnel:
		var ang := _rng.randf_range(0.0, TAU)
		var rad := _rng.randf_range(1.3, 2.6) * field.core_radius_at(field.height)
		top = field.centerline_at(field.height) + Vector3(cos(ang), 0.0, sin(ang)) * rad
		ground = top + Vector3(_rng.randf_range(-0.5, 0.5), 0.0, _rng.randf_range(-0.5, 0.5)) * rad
	else:
		var cam := cam_rig.get_camera()
		var forward := -cam.global_basis.z
		var yaw := atan2(forward.x, forward.z) + _rng.randf_range(-1.1, 1.1)
		var distance := _rng.randf_range(FAR_STRIKE_M.x, FAR_STRIKE_M.y)
		ground = cam.global_position + Vector3(sin(yaw), 0.0, cos(yaw)) * distance
		top = ground + Vector3(_rng.randf_range(-150.0, 150.0), 0.0, _rng.randf_range(-150.0, 150.0))
		amplitude = clampf(FAR_STRIKE_M.x / distance, 0.2, 0.8)
	# Start inside the deck, which dishes down away from the vortex
	# (tornado_cloud.gdshader vertex()), and end under the ground.
	var from_vortex := Vector2(top.x - field.base_pos.x, top.z - field.base_pos.z).length()
	top.y = field.height - 200.0 * pow(from_vortex / 4200.0, 3.0) + 40.0
	ground.y = -20.0
	_flash_pos = Vector3(top.x, 0.75 * field.height, top.z)
	lightning_light.omni_range = maxf(6.0 * field.r_core0, 300.0)
	lightning_light.global_position = Vector3(ground.x, 80.0, ground.z)
	_lightning.strike(top, ground, amplitude)


# ── UI ───────────────────────────────────────────────────────────────────────

func apply_preset(idx: int) -> void:
	var p: Dictionary = PRESETS[idx]
	_preset_btn.selected = idx
	field.model = p.model
	field.height = p.h
	_model_btn.selected = p.model
	_sliders["r0"].value = p.r0
	_sliders["u"].value = p.u
	_sliders["flare"].value = p.flare
	_sliders["a"].value = p.a
	_sliders["s"].value = p.s
	_sliders["dust"].value = p.dust
	_sliders["dark"].value = p.dark
	_update_funnel_bounds()
	dust_particles.restart()
	skirt_particles.restart()
	cam_rig.set_pose(Vector3(0.0, 1.8,
		_camera_distance(maxf(6.0 * field.r_core0, 380.0))), 0.0, 12.0)


func apply_look(idx: int) -> void:
	_look_btn.selected = idx
	_apply_storm_type(idx)


## Action-strip cycle across the elemental looks: Normal → Fire → Water →
## Ice → Plasma → Normal. Wraps and keeps the panel dropdown on the same entry.
func cycle_storm_type() -> void:
	apply_look((storm_type + 1) % STORM_TYPES.size())


## Action-strip cycle across the funnel genres (presets): EF4 → Wedge →
## S-curve rope → EF4. The Preset dropdown is the live selection, kept in sync
## by apply_preset itself.
func cycle_genre() -> void:
	apply_preset((_preset_btn.selected + 1) % PRESETS.size())


## Named poses for tools/capture.sh (view=spawn|near|macro|merge|high|far|top|
## ground): controlled angles for visual checks, relative to the vortex foot and
## following it. Anything else keeps the spawn framing untouched.
func set_capture_view(view: String) -> void:
	_capture_view = view
	_apply_capture_view()


func _apply_capture_view() -> void:
	var foot := field.base_pos
	match _capture_view:
		"spawn":
			cam_rig.set_pose(foot + Vector3(0.0, 1.8, _camera_distance(380.0)), 0.0, 12.0)
		"near":
			cam_rig.set_pose(foot + Vector3(0.0, 6.0, 240.0), 0.0, 8.0)
		"macro":
			cam_rig.set_pose(foot + Vector3(0.0, 210.0, 200.0), 0.0, 0.0)
		"merge":
			# Frames the funnel-top-to-deck junction AND the foot in one shot:
			# the region the default/near/far poses each cut out of frame.
			cam_rig.set_pose(foot + Vector3(0.0, field.height * 0.28,
				maxf(3.5 * field.r_core0, 320.0)), 0.0, 25.0)
		"high":
			cam_rig.set_pose(foot + Vector3(0.0, field.height * 0.55,
				maxf(5.0 * field.r_core0, 420.0)), 0.0, -6.0)
		"far":
			cam_rig.set_pose(foot + Vector3(0.0, 60.0, 1600.0), 0.0, 6.0)
		"top":
			cam_rig.set_pose(foot + Vector3(0.0, 30.0, 420.0), 0.0, 48.0)
		"ground":
			cam_rig.set_pose(foot + Vector3(0.0, 300.0, 380.0), 0.0, -42.0)
		_:
			_capture_view = ""


func set_capture_fixed_delta(value: float) -> void:
	_capture_delta = value


func set_capture_ui(visible: bool) -> void:
	$UI.visible = visible


## The funnel shader's TIME is engine-global, so the capture harness anchors an
## old-session look by offsetting it instead of waiting minutes of wall clock.
func set_capture_time(value: float) -> void:
	_funnel_mat.set_shader_parameter("time_offset", value)


func set_capture_travel_speed(value: float) -> void:
	travel_speed = value
	_update_funnel_bounds()


func set_quality_profile(tier: int) -> void:
	quality.set_tier(tier)


func _set_storm_color(col: Color) -> void:
	# One color drives the whole storm: funnel body + cloud deck (deck pulled
	# slightly toward the sky tint so the horizon still blends). The funnel's
	# top grade targets the SAME deck tone, so the column melts into the deck.
	var deck_tone: Color = col.lerp(Color(0.5, 0.52, 0.57), 0.22)
	storm_color = col
	_funnel_mat.set_shader_parameter("funnel_color", col)
	_funnel_mat.set_shader_parameter("deck_color", deck_tone)
	_cloud_mat.set_shader_parameter("cloud_color", deck_tone)


func _apply_storm_type(idx: int) -> void:
	storm_type = idx
	_funnel_mat.set_shader_parameter("storm_type", idx)
	_cloud_mat.set_shader_parameter("storm_type", idx)
	_ground_mat.set_shader_parameter("storm_type", idx)
	var env := _environment
	if idx == 0:
		_set_storm_color(storm_color)
		# Storm-gray dust: the user reads the warm default as "brown mud" at
		# the foot; the apron must read as gray storm debris.
		_set_dust_color(Color(0.46, 0.46, 0.48))
		# Storm-lit prairie: dry grass, green grass, and the scoured earth of
		# the damage path. Muted: the environment is cool and overcast.
		_set_ground_colors(Color(0.33, 0.31, 0.17), Color(0.15, 0.2, 0.1),
			Color(0.17, 0.14, 0.11), 0.0)
		_sliders["glow"].value = 0.0
		_flash_tint = Color(0.8, 0.85, 1.0)
		_backdrop.set_sky(Color(0.2, 0.215, 0.26), SLOT_COLOR)
		_cloud_mat.set_shader_parameter("horizon_color", SLOT_COLOR)
		_backdrop.set_relief(Color(0.24, 0.255, 0.135), Color(0.2, 0.19, 0.19), 0.6)
		env.fog_light_color = Color(0.3, 0.32, 0.37)
		env.ambient_light_color = Color(0.5, 0.52, 0.57)
	else:
		var t: Dictionary = STORM_TYPES[idx]
		_funnel_mat.set_shader_parameter("funnel_color", t.funnel)
		_funnel_mat.set_shader_parameter("deck_color", t.cloud)
		_cloud_mat.set_shader_parameter("cloud_color", t.cloud)
		_set_dust_color(t.dust)
		_set_ground_colors(t.ground_a, t.ground_b, t.ground_accent, t.ground_glow)
		for pm: ShaderMaterial in [dust_particles.process_material, skirt_particles.process_material]:
			pm.set_shader_parameter("particle_color", t.particles)
		_sliders["glow"].value = t.glow
		_flash_tint = t.bolt
		_backdrop.set_sky((t.sky as Color).darkened(0.35), t.dust)
		_cloud_mat.set_shader_parameter("horizon_color", t.dust)
		_backdrop.set_relief((t.ground_a as Color).lerp(t.ground_b, 0.5), t.ground_b,
			1.0 if idx == 3 else 0.0)
		env.fog_light_color = (t.sky as Color).darkened(0.08)
		env.ambient_light_color = t.ambient
	_funnel_mat.set_shader_parameter("fog_color", env.fog_light_color)
	_funnel_mat.set_shader_parameter("fog_density", env.fog_density)
	_lightning.set_color(_flash_tint)
	lightning_light.light_color = _flash_tint
	_funnel_mat.set_shader_parameter("flash_color", _flash_tint)
	_cloud_mat.set_shader_parameter("flash_color", _flash_tint)


func _set_dust_color(col: Color) -> void:
	dust_color = col
	_funnel_mat.set_shader_parameter("dust_color", col)
	_cloud_mat.set_shader_parameter("dust_color", col)
	for pm: ShaderMaterial in [dust_particles.process_material, skirt_particles.process_material]:
		pm.set_shader_parameter("particle_color", col)


func _set_ground_colors(a: Color, b: Color, accent: Color, glow: float) -> void:
	_ground_mat.set_shader_parameter("ground_a", a)
	_ground_mat.set_shader_parameter("ground_b", b)
	_ground_mat.set_shader_parameter("ground_accent", accent)
	_ground_mat.set_shader_parameter("ground_glow", glow)


func _setup_ui() -> void:
	menu.add_section("Tornado")
	_preset_btn = menu.add_option_button("Preset", PRESETS.map(func(p: Dictionary) -> String: return p.name), 0,
		apply_preset)
	_model_btn = menu.add_option_button("Vortex model", ["Vatistas", "Burgers-Rott", "Sullivan"],
		field.model, func(idx: int) -> void: field.model = idx)
	_sliders["r0"] = menu.add_slider("Size R0 (m)", 10.0, 200.0, field.r_core0,
		func(v: float) -> void:
			field.r_core0 = v
			_update_funnel_bounds())
	_sliders["u"] = menu.add_slider("Intensity (m/s)", 20.0, 140.0, field.u_max,
		func(v: float) -> void: field.u_max = v)
	# The axial updraft scales as 2 a_bar UPDRAFT_DEPTH u_max: 0.35 keeps it near 2 u_max.
	_sliders["a"] = menu.add_slider("Suction", 0.05, 0.35, field.a_bar,
		func(v: float) -> void: field.a_bar = v)
	_sliders["flare"] = menu.add_slider("Flare", 0.0, 4.0, field.flare,
		func(v: float) -> void:
			field.flare = v
			_update_funnel_bounds())
	_sliders["s"] = menu.add_slider("S-curve", 0.0, 1.0, s_amount,
		func(v: float) -> void:
			s_amount = v
			_update_funnel_bounds())
	menu.add_slider("Travel speed (m/s)", 0.0, 30.0, travel_speed,
		func(v: float) -> void:
			travel_speed = v
			_update_funnel_bounds())

	menu.add_section("Look")
	_look_btn = menu.add_option_button("Storm type", STORM_TYPES.map(func(t: Dictionary) -> String: return t.name),
		0, apply_look)
	_sliders["dust"] = menu.add_slider("Dust density", 0.0, 10.0, 1.0,
		func(v: float) -> void: _funnel_mat.set_shader_parameter("dust_density", v))
	_sliders["dark"] = menu.add_slider("Darkness", 0.0, 1.0, 0.55,
		func(v: float) -> void: _funnel_mat.set_shader_parameter("darkness", v))
	menu.add_color_picker("Storm color (Normal)", storm_color, _set_storm_color)
	menu.add_color_picker("Dust color", dust_color, _set_dust_color)
	_sliders["glow"] = menu.add_slider("Glow", 0.0, 1.0, 0.0,
		func(v: float) -> void: _funnel_mat.set_shader_parameter("glow_amount", v))
	menu.add_option_button("Skirt style", ["Debris storm", "Multi-vortex", "Shockwaves"], 0,
		func(idx: int) -> void: _funnel_mat.set_shader_parameter("skirt_style", idx))
	menu.add_slider("Skirt density", 0.0, 4.0, 0.5,
		func(v: float) -> void:
			_skirt_density = v
			skirt_particles.emitting = v > 0.05
			_funnel_mat.set_shader_parameter("skirt_density", v)
			_update_funnel_bounds())
	menu.add_slider("Cloud size", 0.25, 1.0, 1.0,
		func(v: float) -> void: _cloud_mat.set_shader_parameter("deck_radius", 4200.0 * v))

	menu.add_section("Debris")
	menu.add_slider("Spawn rate (/s)", 0.0, 20.0, debris_pool.spawn_rate,
		func(v: float) -> void: debris_pool.spawn_rate = v)
	menu.add_slider("Throw speed", 20.0, 80.0, debris_pool.throw_speed,
		func(v: float) -> void: debris_pool.throw_speed = v)
	var cap_slider: HSlider = menu.add_slider("Debris cap", 50.0, 400.0, float(debris_pool.debris_cap),
		func(v: float) -> void:
			_pending_cap = int(v)
			_cap_debounce = 0.6)
	# On touch there is no LMB: the button is the only way to throw.
	var throw_action: Button = menu.add_action("🎯", "Throw", _throw_from_camera)
	throw_action.tooltip_text = ("Throw object" if VirtualJoystickScript.is_touch_ui()
		else "Throw object (LMB)")
	menu.add_action("🌾", "Scatter", func() -> void: debris_pool.scatter_props())
	menu.add_action("⚡", "Strike", _trigger_lightning.bind(true))
	menu.add_action_toggle("🌩", "Storm", lightning_enabled,
		func(on: bool) -> void: lightning_enabled = on)
	# Freezes the funnel's drift and centerline so a shot can be framed; debris keeps flying.
	menu.add_action_toggle("⏸", "Freeze", false, func(on: bool) -> void: _frozen = on)
	# One-tap switches so the elemental look and the funnel genre can be stepped
	# through without opening the panel; both keep their panel dropdown in sync.
	var type_action: Button = menu.add_action("🧪", "Type", cycle_storm_type)
	type_action.tooltip_text = "Next storm type: Normal → Fire → Water → Ice → Plasma"
	var genre_action: Button = menu.add_action("🌪", "Genre", cycle_genre)
	genre_action.tooltip_text = "Next tornado genre: EF4 → Wedge → Rope"
	_debris_bar = menu.add_progress_bar("Active debris", float(debris_pool.debris_cap))

	menu.add_section("Performance")
	quality.attach_menu_option(menu)
	menu.add_slider("Render scale", 0.4, 1.0,
		_viewport.render_scale(), _set_render_scale)
	var steps_slider: HSlider = menu.add_slider("Raymarch steps", 16.0, 160.0,
		float(_raymarch_steps),
		func(v: float) -> void:
			_raymarch_steps = int(v)
			_funnel_mat.set_shader_parameter("steps", _raymarch_steps))
	quality.bind("raymarch_steps", steps_slider,
		func(v: float) -> void: _funnel_mat.set_shader_parameter("steps", int(v)))
	var dust_labels: Array = []
	for amount in TornadoQualityProfile.DUST_AMOUNTS:
		dust_labels.append("%dk" % int(amount / 1000))
	var dust_option: OptionButton = menu.add_option_button("Dust amount", dust_labels,
		TornadoQualityProfile.DUST_AMOUNTS.find(dust_particles.amount),
		func(idx: int): _set_dust_amount(TornadoQualityProfile.DUST_AMOUNTS[idx]))
	quality.bind("dust_amount", dust_option,
		func(amount): _set_dust_amount(amount),
		func(amount): return TornadoQualityProfile.DUST_AMOUNTS.find(amount))
	quality.bind("debris_cap", cap_slider,
		func(v: float) -> void:
			_pending_cap = int(v)
			_cap_debounce = 0.6)


func _set_render_scale(v: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, v)


func _set_dust_amount(n: int) -> void:
	dust_particles.amount = n
	skirt_particles.amount = maxi(n / 7, 500)


## Sets the fields a quality tier bundles. Before the debris pool exists the
## cap lands on the pool directly (build_pool below picks it up); afterwards a
## cap change goes through the same debounced rebuild as the slider.
func _apply_quality(values: Dictionary) -> void:
	_raymarch_steps = int(values.raymarch_steps)
	if _funnel_mat != null:
		_funnel_mat.set_shader_parameter("steps", _raymarch_steps)
	_set_dust_amount(values.dust_amount)
	if _pool_built:
		_pending_cap = int(values.debris_cap)
		_cap_debounce = 0.6
	else:
		debris_pool.debris_cap = int(values.debris_cap)
