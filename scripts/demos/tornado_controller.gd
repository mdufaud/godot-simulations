extends Node3D

const TornadoWindField = preload("res://scripts/demos/tornado_wind_field.gd")

const PRESETS := [
	{name = "Classic EF4", model = TornadoWindField.Model.BURGERS_ROTT, r0 = 45.0, u = 85.0,
		h = 550.0, flare = 2.5, a = 0.15, s = 0.15, dust = 1.0, dark = 0.55},
	{name = "Wedge / Typhoon", model = TornadoWindField.Model.SULLIVAN, r0 = 160.0, u = 70.0,
		h = 500.0, flare = 0.8, a = 0.25, s = 0.05, dust = 1.1, dark = 0.6},
	{name = "S-curve rope", model = TornadoWindField.Model.BURGERS_ROTT, r0 = 22.0, u = 75.0,
		h = 600.0, flare = 3.5, a = 0.12, s = 0.85, dust = 0.7, dark = 0.45},
]

const STORM_TYPES := [
	{name = "Normal"},
	{name = "Fire", funnel = Color(0.9, 0.35, 0.08), cloud = Color(0.2, 0.11, 0.08),
		dust = Color(1.0, 0.5, 0.1), particles = Color(1.0, 0.55, 0.15),
		bolt = Color(1.0, 0.55, 0.15), glow = 0.12,
		sky = Color(0.34, 0.2, 0.15), ambient = Color(0.45, 0.3, 0.22)},
	{name = "Water", funnel = Color(0.07, 0.2, 0.33), cloud = Color(0.18, 0.23, 0.3),
		dust = Color(0.55, 0.7, 0.8), particles = Color(0.7, 0.83, 0.92),
		bolt = Color(0.6, 0.85, 1.0), glow = 0.0,
		sky = Color(0.38, 0.45, 0.53), ambient = Color(0.42, 0.48, 0.55)},
	{name = "Ice", funnel = Color(0.62, 0.76, 0.88), cloud = Color(0.55, 0.63, 0.73),
		dust = Color(0.85, 0.92, 1.0), particles = Color(0.92, 0.97, 1.0),
		bolt = Color(0.7, 0.9, 1.0), glow = 0.08,
		sky = Color(0.6, 0.68, 0.77), ambient = Color(0.6, 0.66, 0.74)},
	{name = "Plasma", funnel = Color(0.4, 0.1, 0.62), cloud = Color(0.12, 0.06, 0.19),
		dust = Color(0.65, 0.28, 0.85), particles = Color(0.85, 0.5, 1.0),
		bolt = Color(0.9, 0.4, 1.0), glow = 0.3,
		sky = Color(0.17, 0.11, 0.24), ambient = Color(0.32, 0.24, 0.42)},
]

@onready var cam_rig: FreeFlyCamera = $CameraRig
@onready var tornado_node: Node3D = $Tornado
@onready var funnel_volume: MeshInstance3D = $Tornado/FunnelVolume
@onready var cloud_deck: MeshInstance3D = $Tornado/CloudDeck
@onready var dust_particles: GPUParticles3D = $Tornado/DustParticles
@onready var skirt_particles: GPUParticles3D = $Tornado/SkirtParticles
@onready var lightning_light: OmniLight3D = $Tornado/LightningLight
@onready var flash_rect: ColorRect = $UI/FlashRect
@onready var menu = $UI/SimMenu
@onready var debris_pool: TornadoDebrisPool = $DebrisPool

var field := TornadoWindField.new()
var s_amount := 0.15
var wander_speed := 0.3
var wander_radius := 120.0
var lightning_enabled := true
var dust_color := Color(0.55, 0.42, 0.28)
var storm_color := Color(0.3, 0.31, 0.36)
var storm_type := 0

var _time := 0.0
var _wander_noise := FastNoiseLite.new()
var _debris_bar: ProgressBar
var _funnel_mat: ShaderMaterial
var _cloud_mat: ShaderMaterial
var _wind_mats: Array[ShaderMaterial] = []
var _sliders := {}
var _model_btn: OptionButton
var _rng := RandomNumberGenerator.new()

var _lightning_timer := 3.0
var _flash_energy := 0.0
var _flash_pos := Vector3.ZERO
var _flash_tint := Color(0.8, 0.85, 1.0)
var _bolt: MeshInstance3D
var _bolt_mesh: ImmediateMesh
var _bolt_mat: StandardMaterial3D

var _pending_cap := -1
var _cap_debounce := 0.0
var _skirt_density := 0.5


func _ready() -> void:
	_wander_noise.seed = 1337
	debris_pool.field = field
	debris_pool.build_pool(debris_pool.debris_cap)
	debris_pool.scatter_props()
	_funnel_mat = funnel_volume.material_override
	_cloud_mat = cloud_deck.material_override
	var sun: Vector3 = -($DirectionalLight3D as DirectionalLight3D).global_basis.z
	_funnel_mat.set_shader_parameter("sun_dir", sun)
	_cloud_mat.set_shader_parameter("sun_dir", sun)
	_wind_mats = [
		_funnel_mat,
		_cloud_mat,
		dust_particles.process_material,
		skirt_particles.process_material,
	]
	_make_bolt()
	_set_storm_color(storm_color)
	_update_funnel_bounds()
	cam_rig.set_pose(Vector3(0.0, 1.8, 380.0), 0.0, 12.0)
	_set_render_scale(0.75)
	_setup_ui()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and cam_rig.is_captured():
		_throw_from_camera()


func _throw_from_camera() -> void:
	var cam := cam_rig.get_camera()
	debris_pool.queue_throw(cam.global_position, -cam.global_basis.z)


func _process(delta: float) -> void:
	_time += delta
	var wt := _time * wander_speed * 0.02
	field.base_pos = Vector3(
		_wander_noise.get_noise_2d(wt * 100.0, 0.0),
		0.0,
		_wander_noise.get_noise_2d(wt * 100.0, 500.0)
	) * wander_radius
	field.update_centerline(_time * 0.05, s_amount, _wander_noise)
	tornado_node.position = field.base_pos
	_push_wind_uniforms()
	_update_lightning(delta)
	if _debris_bar:
		_debris_bar.value = debris_pool.active_count
	if _pending_cap > 0:
		_cap_debounce -= delta
		if _cap_debounce <= 0.0:
			debris_pool.build_pool(_pending_cap)
			debris_pool.scatter_props()
			_debris_bar.max_value = _pending_cap
			_pending_cap = -1


func _update_funnel_bounds() -> void:
	# Worst-case centerline excursion: S bow (0.12 H) + wander noise (0.05 H).
	var max_off: float = (0.12 * s_amount + 0.05) * field.height
	var half_xz: float = maxf(1.8 * field.r_core0 * (1.0 + field.flare),
		(3.4 + 1.2 * _skirt_density) * field.r_core0) + max_off
	var size := Vector3(2.0 * half_xz, field.height, 2.0 * half_xz)
	(funnel_volume.mesh as BoxMesh).size = size
	funnel_volume.position = Vector3(0.0, field.height * 0.5, 0.0)
	_funnel_mat.set_shader_parameter("box_size", size)
	cloud_deck.position = Vector3(0.0, field.height, 0.0)


func _push_wind_uniforms() -> void:
	for mat: ShaderMaterial in _wind_mats:
		mat.set_shader_parameter("wind_model", field.model)
		mat.set_shader_parameter("u_max", field.u_max)
		mat.set_shader_parameter("r_core0", field.r_core0)
		mat.set_shader_parameter("funnel_height", field.height)
		mat.set_shader_parameter("flare", field.flare)
		mat.set_shader_parameter("a_bar", field.a_bar)
		mat.set_shader_parameter("swirl_sign", field.swirl_sign)
		mat.set_shader_parameter("centerline", field.get_shader_centerline())
		mat.set_shader_parameter("sullivan_curve", field.get_sullivan_texture())


# ── Lightning ────────────────────────────────────────────────────────────────

func _make_bolt() -> void:
	_bolt_mesh = ImmediateMesh.new()
	_bolt = MeshInstance3D.new()
	_bolt.mesh = _bolt_mesh
	_bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(0.85, 0.9, 1.0)
	mat.emission_energy_multiplier = 8.0
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	_bolt_mat = mat
	_bolt.material_override = mat
	_bolt.visible = false
	add_child(_bolt)


func _update_lightning(delta: float) -> void:
	if lightning_enabled:
		_lightning_timer -= delta
		if _lightning_timer <= 0.0:
			_trigger_lightning()
			_lightning_timer = _rng.randf_range(0.6, 4.0) / maxf(field.u_max / 85.0, 0.3)
	_flash_energy = maxf(_flash_energy - delta * 6.0, 0.0)
	if _flash_energy > 0.0 and _rng.randf() < 0.2:
		_flash_energy = minf(_flash_energy + _rng.randf() * 0.4, 1.0)
	lightning_light.light_energy = _flash_energy * 40.0
	_funnel_mat.set_shader_parameter("flash_intensity", _flash_energy * 6.0)
	_funnel_mat.set_shader_parameter("flash_pos", _flash_pos)
	_cloud_mat.set_shader_parameter("flash_intensity", _flash_energy * 6.0)
	_cloud_mat.set_shader_parameter("flash_pos", _flash_pos)
	var c := Color(_flash_tint, _flash_energy * _flash_energy * 0.3)
	flash_rect.color = c
	_bolt.visible = _flash_energy > 0.55


func _trigger_lightning() -> void:
	# Strike outside the condensation wall (cloud-to-ground beside the funnel)
	# so the bolt silhouettes against the sky instead of drowning in the volume.
	var y := _rng.randf_range(0.5, 0.9) * field.height
	var c: Vector3 = field.centerline_at(y)
	var rc: float = field.core_radius_at(y)
	var ang := _rng.randf_range(0.0, TAU)
	var rad := _rng.randf_range(1.3, 2.4) * rc
	_flash_pos = c + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	_flash_pos.y = y
	_flash_energy = 1.0
	lightning_light.omni_range = 4.0 * field.r_core0
	lightning_light.global_position = Vector3(_flash_pos.x, minf(_flash_pos.y, 120.0), _flash_pos.z)
	_build_bolt_mesh()


func _build_bolt_mesh() -> void:
	var bottom := Vector3(
		_flash_pos.x + _rng.randf_range(-20.0, 20.0),
		0.0,
		_flash_pos.z + _rng.randf_range(-20.0, 20.0)
	)
	var cam := cam_rig.get_camera()
	var view: Vector3 = (cam.global_position - _flash_pos).normalized()
	var axis: Vector3 = (bottom - _flash_pos)
	var side: Vector3 = axis.cross(view).normalized() * 2.5
	var segs := 11
	_bolt_mesh.clear_surfaces()
	_bolt_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in segs + 1:
		var t := float(i) / segs
		var p: Vector3 = _flash_pos + axis * t
		if i > 0 and i < segs:
			p += side.normalized() * _rng.randf_range(-14.0, 14.0)
			p += view.cross(side).normalized() * _rng.randf_range(-6.0, 6.0)
		var w: Vector3 = side * (1.0 - 0.5 * t)
		_bolt_mesh.surface_add_vertex(p - w)
		_bolt_mesh.surface_add_vertex(p + w)
	_bolt_mesh.surface_end()


# ── UI ───────────────────────────────────────────────────────────────────────

func _apply_preset(idx: int) -> void:
	var p: Dictionary = PRESETS[idx]
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
	cam_rig.set_pose(Vector3(0.0, 1.8, maxf(6.0 * field.r_core0, 380.0)), 0.0, 12.0)


func _set_storm_color(col: Color) -> void:
	# One color drives the whole storm: funnel body + cloud deck (deck pulled
	# slightly toward the sky tint so the horizon still blends).
	storm_color = col
	_funnel_mat.set_shader_parameter("funnel_color", col)
	_cloud_mat.set_shader_parameter("cloud_color", col.lerp(Color(0.5, 0.52, 0.57), 0.22))


func _apply_storm_type(idx: int) -> void:
	storm_type = idx
	_funnel_mat.set_shader_parameter("storm_type", idx)
	_cloud_mat.set_shader_parameter("storm_type", idx)
	var env: Environment = ($WorldEnvironment as WorldEnvironment).environment
	if idx == 0:
		_set_storm_color(storm_color)
		_set_dust_color(Color(0.55, 0.42, 0.28))
		_sliders["glow"].value = 0.0
		_flash_tint = Color(0.8, 0.85, 1.0)
		env.background_color = Color(0.45, 0.47, 0.52)
		env.fog_light_color = Color(0.3, 0.32, 0.37)
		env.ambient_light_color = Color(0.5, 0.52, 0.57)
	else:
		var t: Dictionary = STORM_TYPES[idx]
		_funnel_mat.set_shader_parameter("funnel_color", t.funnel)
		_cloud_mat.set_shader_parameter("cloud_color", t.cloud)
		_set_dust_color(t.dust)
		for pm: ShaderMaterial in [dust_particles.process_material, skirt_particles.process_material]:
			pm.set_shader_parameter("particle_color", t.particles)
		_sliders["glow"].value = t.glow
		_flash_tint = t.bolt
		env.background_color = t.sky
		env.fog_light_color = (t.sky as Color).darkened(0.08)
		env.ambient_light_color = t.ambient
	_bolt_mat.emission = _flash_tint
	lightning_light.light_color = _flash_tint
	_funnel_mat.set_shader_parameter("flash_color", _flash_tint)
	_cloud_mat.set_shader_parameter("flash_color", _flash_tint)


func _set_dust_color(col: Color) -> void:
	dust_color = col
	_funnel_mat.set_shader_parameter("dust_color", col)
	_cloud_mat.set_shader_parameter("dust_color", col)
	for pm: ShaderMaterial in [dust_particles.process_material, skirt_particles.process_material]:
		pm.set_shader_parameter("particle_color", col)


func _setup_ui() -> void:
	menu.add_section("Tornado")
	menu.add_option_button("Preset", PRESETS.map(func(p: Dictionary) -> String: return p.name), 0,
		_apply_preset)
	_model_btn = menu.add_option_button("Vortex model", ["Rankine", "Burgers-Rott", "Sullivan"],
		field.model, func(idx: int) -> void: field.model = idx)
	_sliders["r0"] = menu.add_slider("Size R0 (m)", 10.0, 200.0, field.r_core0,
		func(v: float) -> void:
			field.r_core0 = v
			_update_funnel_bounds())
	_sliders["u"] = menu.add_slider("Intensity (m/s)", 20.0, 140.0, field.u_max,
		func(v: float) -> void: field.u_max = v)
	_sliders["a"] = menu.add_slider("Suction", 0.05, 0.6, field.a_bar,
		func(v: float) -> void: field.a_bar = v)
	_sliders["flare"] = menu.add_slider("Flare", 0.0, 4.0, field.flare,
		func(v: float) -> void:
			field.flare = v
			_update_funnel_bounds())
	_sliders["s"] = menu.add_slider("S-curve", 0.0, 1.0, s_amount,
		func(v: float) -> void:
			s_amount = v
			_update_funnel_bounds())
	menu.add_slider("Wander", 0.0, 1.0, wander_speed,
		func(v: float) -> void: wander_speed = v)

	menu.add_section("Look")
	menu.add_option_button("Storm type", STORM_TYPES.map(func(t: Dictionary) -> String: return t.name),
		0, _apply_storm_type)
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
	menu.add_toggle("Lightning", lightning_enabled,
		func(on: bool) -> void: lightning_enabled = on)

	menu.add_section("Debris")
	menu.add_slider("Spawn rate (/s)", 0.0, 20.0, debris_pool.spawn_rate,
		func(v: float) -> void: debris_pool.spawn_rate = v)
	menu.add_slider("Throw speed", 20.0, 80.0, debris_pool.throw_speed,
		func(v: float) -> void: debris_pool.throw_speed = v)
	menu.add_slider("Debris cap", 50.0, 400.0, float(debris_pool.debris_cap),
		func(v: float) -> void:
			_pending_cap = int(v)
			_cap_debounce = 0.6)
	# On touch there is no LMB: the button is the only way to throw.
	var throw_action: Button = menu.add_action("🎯", "Throw", _throw_from_camera)
	throw_action.tooltip_text = ("Throw object" if VirtualJoystick.is_touch_ui()
		else "Throw object (LMB)")
	menu.add_action("🌾", "Scatter", func() -> void: debris_pool.scatter_props())
	_debris_bar = menu.add_progress_bar("Active debris", float(debris_pool.debris_cap))

	menu.add_section("Performance")
	menu.add_slider("Render scale", 0.4, 1.0, 0.75, _set_render_scale)
	menu.add_slider("Raymarch steps", 16.0, 96.0, 48.0,
		func(v: float) -> void: _funnel_mat.set_shader_parameter("steps", int(v)))
	menu.add_button("Dust 4k", func() -> void: _set_dust_amount(4000))
	menu.add_button("Dust 14k", func() -> void: _set_dust_amount(14000))
	menu.add_button("Dust 28k", func() -> void: _set_dust_amount(28000))


func _set_render_scale(v: float) -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = v


func _set_dust_amount(n: int) -> void:
	dust_particles.amount = n
	skirt_particles.amount = maxi(n / 7, 500)
