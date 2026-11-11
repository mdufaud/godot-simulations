class_name WildfireSystem extends Node3D
## The cheap game fire renderer from docs/game_fire_rdr2_model.md: native
## GPUParticles3D per fire drawing procedural sprites — a still base
## glow, flame licks born in the fuel bed that rise and erode, smoke puffs and
## stretched sparks — so the CPU only drives one intensity envelope per fire.
## Each fire also gets a flickering OmniLight3D and a heat-haze volume, all
## gated by distance LOD. Emitter-driven: zero per-frame cost when no fire is
## active.
##
##     var system := WildfireSystem.new()
##     add_child(system)
##     system.build(config)
##     var id := system.add_fire(pos, preset)
##     # every frame:
##     system.update(delta, camera.global_position)

const SPRITE_SHADER := preload("res://shaders/wildfire/fire_sprite.gdshader")
const FLAME_SHADER := preload("res://shaders/wildfire/flame.gdshader")
const BED_SHADER := preload("res://shaders/wildfire/ember_bed.gdshader")
const HAZE_SHADER := preload("res://shaders/wildfire/heat_haze.gdshader")
## Upper bound of rate_scale: particle buffers are sized for it once.
const MAX_RATE_SCALE := 2.0
const FLAME_BUOYANCY := 1.2
const SMOKE_BUOYANCY := 0.9
## Fraction of the wind each layer's particles pick up per second.
const FLAME_WIND_DRAG := 0.8
const SMOKE_WIND_DRAG := 0.8
const EMBER_WIND_DRAG := 1.0
const EMBER_GRAVITY := Vector3(0.0, -0.8, 0.0)
const EMBER_LIFETIME_S := 3.2
## Flame quad: fraction of the preset flame height, and width over height.
const FLAME_QUAD_HEIGHT := 0.85
const FLAME_QUAD_ASPECT := 0.66
## Flame lean: tan(angle) gained per m/s of wind, capped near 58 degrees.
const LEAN_PER_MPS := 0.25
const MAX_LEAN := 1.6
## Unlit smoke fakes the firelight with an age tint; lit smoke takes a plain
## albedo and is lit per vertex by the nearest fire lights.
const SMOKE_TINT_UNLIT: Array[Color] = [Color(1.3, 0.5, 0.22), Color(0.65, 0.7, 0.85)]
const SMOKE_TINT_LIT: Array[Color] = [Color(1.7, 1.35, 1.15), Color(1.5, 1.5, 1.6)]
## Size of the sprite shader's light arrays.
const MAX_SMOKE_LIGHTS := 8
## Moonlit night air: what lights smoke drifting away from every fire.
const SMOKE_AMBIENT := Color(0.1, 0.095, 0.1)

var config: WildfireConfig
## CPU cost of the last update() call, for the HUD budget readout.
var last_update_ms := 0.0
## Global spawn-rate multiplier for flames and embers (menu "flame density"),
## 0..MAX_RATE_SCALE.
var rate_scale := 1.0
## Fire lights whose preset shadow_rank is at most this cast shadows; 0 = none.
var shadow_level := 1
var heat_haze := true
var lit_smoke := false
## Firelight scattering in a local volumetric-fog cloud around each fire.
var fire_fog := false

var _time := 0.0
var _wind3 := Vector3.ZERO
var _lean3 := Vector3.ZERO
var _next_id := 1
var _fires_by_id := {}
var _noise: NoiseTexture2D
var _flame_material: ShaderMaterial
var _core_material: ShaderMaterial
var _wisp_material: ShaderMaterial
var _bed_mesh: PlaneMesh
var _bed_material: ShaderMaterial
var _glow_material: ShaderMaterial
var _smoke_material: ShaderMaterial
var _haze_mesh: CylinderMesh
var _haze_material: ShaderMaterial
var _ember_mesh: QuadMesh
var _flame_scale: CurveTexture
var _smoke_scale: CurveTexture
var _ember_fade: GradientTexture1D
var _fog_material: FogMaterial
var _meshes_by_preset := {}


class FireRecord extends RefCounted:
	var id := 0
	var pos := Vector3.ZERO
	var preset: WildfirePreset
	var intensity := 0.0
	var target := 1.0
	var seed := 0.0
	var remove_when_cold := true
	var cold_time := 0.0
	var light: OmniLight3D
	var ground_light: OmniLight3D
	var bed: MeshInstance3D
	var haze: MeshInstance3D
	var fog: FogVolume
	var glow: GPUParticles3D
	var core: GPUParticles3D
	var flames: GPUParticles3D
	var wisps: GPUParticles3D
	var smoke: GPUParticles3D
	var embers: GPUParticles3D


func build(fire_config: WildfireConfig) -> void:
	var error := fire_config.validate()
	assert(error.is_empty(), "WildfireSystem: %s" % error)
	config = fire_config
	_noise = _noise_texture()

	# Draw order: smoke, then the base glow, then the flame layers on top.
	# Smoke: many overlapping soft puffs that fade in late and dissolve slowly,
	# so the plume reads as one column instead of separate blobs.
	_smoke_material = _sprite_material(SMOKE_TINT_UNLIT[0], SMOKE_TINT_UNLIT[1],
		1.0, 0.3, 0.45, -1)
	_smoke_material.set_shader_parameter("edge_softness", 0.5)
	_smoke_material.set_shader_parameter("light_ceiling", 1.0)
	_smoke_material.set_shader_parameter("flow_speed", 0.25)
	_smoke_material.set_shader_parameter("fade_in", 0.35)
	_smoke_material.set_shader_parameter("fade_out_start", 0.55)
	_glow_material = _sprite_material(Color(1.0, 0.42, 0.12), Color(1.0, 0.3, 0.08),
		0.5, 0.1, 0.0, 0)
	_glow_material.set_shader_parameter("edge_softness", 0.9)
	# Three flame layers: a full hot core in the fuel bed, the tongues, and thin
	# fast wisps breaking away above them.
	_core_material = flame_material(0.0)
	_core_material.set_shader_parameter("heat_bias", 0.1)
	_flame_material = flame_material(0.0)
	_wisp_material = flame_material(0.0)
	_wisp_material.set_shader_parameter("heat_bias", -0.12)
	_wisp_material.set_shader_parameter("rise_speed", 1.5)
	_bed_mesh = PlaneMesh.new()
	_bed_material = ShaderMaterial.new()
	_bed_material.shader = BED_SHADER
	_bed_material.set_shader_parameter("noise_tex", _noise)

	_flame_scale = _curve_texture([Vector2(0.0, 0.4), Vector2(0.35, 1.0), Vector2(1.0, 0.7)])
	_smoke_scale = _curve_texture([Vector2(0.0, 0.15), Vector2(0.4, 0.55), Vector2(1.0, 1.0)])
	var fade := Gradient.new()
	fade.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 0.6, 0.4, 0)])
	_ember_fade = GradientTexture1D.new()
	_ember_fade.gradient = fade

	_haze_mesh = CylinderMesh.new()
	# Tapered: the haze column follows the flame cone instead of a straight tube.
	_haze_mesh.top_radius = 0.4
	_haze_mesh.bottom_radius = 1.0
	_haze_mesh.height = 1.0
	_haze_mesh.radial_segments = 12
	_haze_mesh.cap_top = false
	_haze_mesh.cap_bottom = false
	_haze_material = ShaderMaterial.new()
	_haze_material.shader = HAZE_SHADER
	# Before every sprite: the screen copy it refracts holds no transparents, so
	# drawn later it would erase the smoke and flames behind it.
	_haze_material.render_priority = -2
	_haze_material.set_shader_parameter("strength", config.haze_strength)

	_fog_material = FogMaterial.new()
	_fog_material.density = config.fire_fog_density_per_m
	_fog_material.albedo = Color(0.6, 0.56, 0.52)
	_fog_material.edge_fade = 1.0

	_ember_mesh = QuadMesh.new()
	_ember_mesh.size = Vector2(0.025, 0.09)
	var ember_material := StandardMaterial3D.new()
	ember_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ember_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	ember_material.vertex_color_use_as_albedo = true
	# Radial falloff baked into RGB *and* alpha: additive blends that ignore
	# alpha would otherwise render the quad as a solid square spark.
	ember_material.albedo_texture = ImageTexture.create_from_image(_ember_dot_image())
	_ember_mesh.material = ember_material


func add_fire(pos: Vector3, preset: WildfirePreset, remove_when_cold := true) -> int:
	var error := preset.validate()
	assert(error.is_empty(), "WildfireSystem: %s" % error)
	var record := FireRecord.new()
	record.id = _next_id
	_next_id += 1
	record.pos = pos
	record.preset = preset
	record.seed = randf() * 100.0
	record.remove_when_cold = remove_when_cold
	record.light = OmniLight3D.new()
	record.light.light_color = preset.light_color
	record.light.omni_range = preset.light_range_m
	record.light.shadow_enabled = _casts_shadow(preset)
	record.light.position = pos + Vector3(0.0, preset.flame_height_m * 0.45, 0.0)
	add_child(record.light)
	if preset.ground_light_energy > 0.0:
		record.ground_light = OmniLight3D.new()
		record.ground_light.light_color = preset.light_color
		record.ground_light.omni_range = preset.emitter_radius_m * 5.0
		record.ground_light.position = pos + Vector3(0.0, preset.emitter_radius_m * 0.5, 0.0)
		add_child(record.ground_light)
	if preset.ember_bed_radius_m > 0.0:
		record.bed = MeshInstance3D.new()
		record.bed.mesh = _bed_mesh
		record.bed.material_override = _bed_material
		record.bed.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		record.bed.scale = Vector3.ONE * preset.ember_bed_radius_m
		record.bed.position = pos + Vector3(0.0, 0.02 - preset.ember_bed_drop_m, 0.0)
		record.bed.visible = false
		add_child(record.bed)
	record.haze = MeshInstance3D.new()
	record.haze.mesh = _haze_mesh
	record.haze.material_override = _haze_material
	record.haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	record.haze.visible = false
	add_child(record.haze)
	# One fog cloud per cluster: a log pile's burning cells would stack theirs.
	if not _fog_near(pos, preset.haze_radius_m):
		record.fog = FogVolume.new()
		record.fog.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
		record.fog.material = _fog_material
		record.fog.size = Vector3(preset.haze_radius_m * 2.5, config.haze_height_m * 1.6,
			preset.haze_radius_m * 2.5)
		record.fog.visible = false
		add_child(record.fog)
	record.glow = _make_glow(preset, pos)
	var height := preset.flame_height_m * FLAME_QUAD_HEIGHT
	var meshes := _preset_meshes(preset)
	record.core = _flame_layer(preset, pos + Vector3(0.0, height * 0.15, 0.0), meshes[3],
		preset.flame_count * 0.35, 0.7, 0.6, Vector2(0.1, 0.35))
	record.flames = _flame_layer(preset, pos + Vector3(0.0, height * 0.35, 0.0), meshes[1],
		preset.flame_count, 1.0, 0.7, Vector2(0.4, 0.9))
	record.wisps = _flame_layer(preset, pos + Vector3(0.0, height * 0.6, 0.0), meshes[4],
		preset.flame_count * 0.35, 0.75, 0.45, Vector2(1.4, 2.4))
	record.smoke = _make_smoke(preset, pos)
	record.embers = _make_embers(preset, pos)
	_apply_wind(record)
	_fires_by_id[record.id] = record
	return record.id


func set_target(id: int, value: float) -> void:
	var record: FireRecord = _fires_by_id.get(id)
	if record != null:
		record.target = clampf(value, 0.0, 1.0)


func remove_fire(id: int) -> void:
	var record: FireRecord = _fires_by_id.get(id)
	if record == null:
		return
	_fires_by_id.erase(id)
	# add_fire gives a cluster one fog cloud, owned by its first fire. Hand it to a
	# neighbour still burning, or the cluster loses its fog when that fire goes out.
	if record.fog != null:
		for other: FireRecord in _fires_by_id.values():
			if other.fog == null and other.preset == record.preset \
					and other.pos.distance_to(record.pos) < record.preset.haze_radius_m:
				other.fog = record.fog
				record.fog = null
				_apply_wind(other)
				break
	_drop_extras(record)


func clear_all() -> void:
	for id in _fires_by_id.keys():
		remove_fire(id)


func fire_count() -> int:
	return _fires_by_id.size()


func set_shadow_level(level: int) -> void:
	shadow_level = level
	for record: FireRecord in _fires_by_id.values():
		record.light.shadow_enabled = _casts_shadow(record.preset)


func set_lit_smoke(on: bool) -> void:
	lit_smoke = on
	var tints := SMOKE_TINT_LIT if on else SMOKE_TINT_UNLIT
	_smoke_material.set_shader_parameter("tint_young", tints[0])
	_smoke_material.set_shader_parameter("tint_old", tints[1])
	_smoke_material.set_shader_parameter("ambient_light", SMOKE_AMBIENT)
	if not on:
		_smoke_material.set_shader_parameter("light_count", 0)


## Feeds the smoke shader the fire lights nearest to the camera.
func _update_smoke_lights(camera_position: Vector3) -> void:
	var lit: Array[FireRecord] = []
	for record: FireRecord in _fires_by_id.values():
		if record.light.visible:
			lit.append(record)
	lit.sort_custom(func(a: FireRecord, b: FireRecord) -> bool:
		return a.pos.distance_squared_to(camera_position) \
			< b.pos.distance_squared_to(camera_position))
	var count := mini(lit.size(), MAX_SMOKE_LIGHTS)
	var positions := PackedVector4Array()
	var colors := PackedVector3Array()
	positions.resize(MAX_SMOKE_LIGHTS)
	colors.resize(MAX_SMOKE_LIGHTS)
	for i in count:
		var light := lit[i].light
		var at := light.global_position
		positions[i] = Vector4(at.x, at.y, at.z, light.omni_range)
		var color := light.light_color * light.light_energy
		colors[i] = Vector3(color.r, color.g, color.b)
	_smoke_material.set_shader_parameter("light_count", count)
	_smoke_material.set_shader_parameter("light_pos_range", positions)
	_smoke_material.set_shader_parameter("light_color", colors)


func _fog_near(pos: Vector3, radius: float) -> bool:
	for record: FireRecord in _fires_by_id.values():
		if record.fog != null and record.pos.distance_to(pos) < radius:
			return true
	return false


func _casts_shadow(preset: WildfirePreset) -> bool:
	return preset.shadow_rank > 0 and preset.shadow_rank <= shadow_level


func live_particles() -> int:
	var count := 0
	for record: FireRecord in _fires_by_id.values():
		for particles: GPUParticles3D in [record.glow, record.core, record.flames,
				record.wisps, record.smoke]:
			if particles.emitting:
				count += int(particles.amount * particles.amount_ratio)
	return count


func set_wind(direction: Vector2, strength: float) -> void:
	var heading := direction.normalized() if direction.length() > 0.001 else Vector2.RIGHT
	var wind := Vector3(heading.x, 0.0, heading.y) * strength
	if wind.is_equal_approx(_wind3):
		return
	_wind3 = wind
	_lean3 = (wind * LEAN_PER_MPS).limit_length(MAX_LEAN)
	for material in [_core_material, _flame_material, _wisp_material]:
		material.set_shader_parameter("wind_lean", _lean3)
	for record: FireRecord in _fires_by_id.values():
		_apply_wind(record)


func wind_vector() -> Vector3:
	return _wind3


func update(delta: float, camera_position: Vector3) -> void:
	var start_usec := Time.get_ticks_usec()
	_time += delta
	for id in _fires_by_id.keys():
		var record: FireRecord = _fires_by_id[id]
		_update_envelope(record, delta)
		_update_extras(record, camera_position)
	_cull_cold(delta)
	if lit_smoke:
		_update_smoke_lights(camera_position)
	last_update_ms = float(Time.get_ticks_usec() - start_usec) / 1000.0


# --- setup helpers ----------------------------------------------------------


func _noise_texture() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 4
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.generate_mipmaps = true
	texture.noise = noise
	return texture


## The procedural flame shader on the system's noise; puff 1 is the round
## fireball variant for sprites that roll freely.
func flame_material(puff: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = FLAME_SHADER
	material.render_priority = 1
	material.set_shader_parameter("noise_tex", _noise)
	material.set_shader_parameter("puff", puff)
	return material


func _sprite_material(tint_young: Color, tint_old: Color, energy: float, opacity: float,
		erosion: float, priority: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SPRITE_SHADER
	material.render_priority = priority
	material.set_shader_parameter("noise_tex", _noise)
	material.set_shader_parameter("tint_young", tint_young)
	material.set_shader_parameter("tint_old", tint_old)
	material.set_shader_parameter("emission_energy", energy)
	material.set_shader_parameter("opacity", opacity)
	material.set_shader_parameter("erosion", erosion)
	return material


func _curve_texture(points: Array[Vector2]) -> CurveTexture:
	var curve := Curve.new()
	for point in points:
		curve.add_point(point)
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


## 32px soft round dot for ember sprites (RGB and alpha share the falloff).
func _ember_dot_image() -> Image:
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 15.5, y - 15.5).length() / 15.5
			var f := pow(clampf(1.0 - d, 0.0, 1.0), 1.6)
			image.set_pixel(x, y, Color(f, f, f, f))
	return image


## Glow, flame, smoke, core and wisp quads, shared by every fire of one preset.
func _preset_meshes(preset: WildfirePreset) -> Array:
	if not _meshes_by_preset.has(preset):
		var quads := []
		var flame_height := preset.flame_height_m * FLAME_QUAD_HEIGHT
		for spec in [[Vector2.ONE * preset.emitter_radius_m * 2.2, _glow_material],
				[Vector2(flame_height * FLAME_QUAD_ASPECT, flame_height), _flame_material],
				[Vector2.ONE * preset.smoke_size_m * 1.8, _smoke_material],
				[Vector2.ONE * flame_height * 0.5, _core_material],
				[Vector2(0.5, 1.0) * flame_height * 0.4, _wisp_material]]:
			var quad := QuadMesh.new()
			quad.size = spec[0]
			quad.material = spec[1]
			quads.append(quad)
		_meshes_by_preset[preset] = quads
	return _meshes_by_preset[preset]


func _particles(process: ParticleProcessMaterial, mesh: Mesh, amount: int,
		lifetime: float, pos: Vector3, extent: Vector3) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.process_material = process
	particles.draw_pass_1 = mesh
	particles.amount = maxi(amount, 1)
	particles.lifetime = lifetime
	particles.preprocess = lifetime
	particles.emitting = false
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.position = pos
	particles.visibility_aabb = AABB(Vector3(-extent.x, -0.5, -extent.z),
		Vector3(extent.x * 2.0, extent.y + 0.5, extent.z * 2.0))
	add_child(particles)
	return particles


## A few large, slow glow sprites sitting on the fuel bed: they tie the rising
## licks to the logs.
func _make_glow(preset: WildfirePreset, pos: Vector3) -> GPUParticles3D:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = preset.emitter_radius_m * 0.3
	process.direction = Vector3.UP
	process.initial_velocity_min = 0.02
	process.initial_velocity_max = 0.08
	process.gravity = Vector3.ZERO
	process.scale_min = 0.9
	process.scale_max = 1.1
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.angular_velocity_min = -10.0
	process.angular_velocity_max = 10.0
	process.anim_offset_max = 1.0
	var extent := Vector3.ONE * (preset.emitter_radius_m * 2.0 + 1.0)
	return _particles(process, _preset_meshes(preset)[0], 3, 1.6,
		pos + Vector3(0.0, preset.emitter_radius_m * 0.4, 0.0), extent)


## One flame layer: sprites born small in the fuel bed that stretch as they
## rise on buoyancy, drift with the wind and erode as they age, so the fire's
## shape travels up and licks detach at the top.
func _flame_layer(preset: WildfirePreset, pos: Vector3, mesh: Mesh, count: float,
		lifetime_scale: float, radius_scale: float, speed_mps: Vector2) -> GPUParticles3D:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = preset.emitter_radius_m * radius_scale
	process.emission_shape_scale = Vector3(1.0, 0.3, 1.0)
	process.direction = Vector3.UP
	process.spread = 10.0
	process.initial_velocity_min = speed_mps.x
	process.initial_velocity_max = speed_mps.y
	process.damping_min = 0.5
	process.damping_max = 0.8
	process.scale_min = 0.55
	process.scale_max = 1.25
	process.scale_curve = _flame_scale
	process.angle_min = -8.0
	process.angle_max = 8.0
	process.anim_offset_max = 1.0
	process.lifetime_randomness = 0.35
	var extent := Vector3(preset.emitter_radius_m + 3.0, preset.flame_height_m * 3.0,
		preset.emitter_radius_m + 3.0)
	return _particles(process, mesh, ceili(count * MAX_RATE_SCALE),
		preset.flame_lifetime_s * lifetime_scale, pos, extent)


func _make_smoke(preset: WildfirePreset, pos: Vector3) -> GPUParticles3D:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = preset.emitter_radius_m * 0.3
	process.direction = Vector3.UP
	process.spread = 6.0
	process.initial_velocity_min = 1.1
	process.initial_velocity_max = 1.7
	process.damping_min = 0.4
	process.damping_max = 0.6
	process.scale_min = 0.8
	process.scale_max = 1.2
	process.scale_curve = _smoke_scale
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.angular_velocity_min = -10.0
	process.angular_velocity_max = 10.0
	process.anim_offset_max = 1.0
	process.color = Color(preset.smoke_tint, 0.0)
	# Curl-noise drift: the puffs billow and shear instead of rising in lockstep.
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 1.0
	process.turbulence_noise_scale = 3.0
	process.turbulence_influence_min = 0.04
	process.turbulence_influence_max = 0.12
	var extent := Vector3(preset.smoke_size_m + 12.0, preset.smoke_lifetime_s * 4.0,
		preset.smoke_size_m + 12.0)
	# Born inside the flame tops, where the licks hide the fade-in.
	return _particles(process, _preset_meshes(preset)[2],
		roundi(preset.smoke_rate_hz * preset.smoke_lifetime_s * MAX_RATE_SCALE),
		preset.smoke_lifetime_s, pos + Vector3(0.0, preset.flame_height_m * 0.6, 0.0), extent)


func _make_embers(preset: WildfirePreset, pos: Vector3) -> GPUParticles3D:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = preset.emitter_radius_m
	process.direction = Vector3.UP
	process.spread = 22.0
	process.initial_velocity_min = preset.ember_speed_m * 0.5
	process.initial_velocity_max = preset.ember_speed_m
	process.scale_min = 0.5
	process.scale_max = 1.0
	# HDR colour: the sparks feed the glow pass instead of reading as dull dots.
	process.color = Color(3.0, 1.2, 0.3)
	process.color_ramp = _ember_fade
	# Native curl-noise turbulence: the embers' "fluid" motion for free.
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 1.4
	process.turbulence_noise_scale = 2.4
	var extent := Vector3(6.0, 12.0, 6.0)
	var particles := _particles(process, _ember_mesh,
		ceili(preset.ember_count * MAX_RATE_SCALE), EMBER_LIFETIME_S,
		pos + Vector3(0.0, preset.flame_height_m * 0.3, 0.0), extent)
	particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	particles.preprocess = 0.0
	return particles


## Particles drift with the wind; the haze column shears with the flame lean.
func _apply_wind(record: FireRecord) -> void:
	for layer: GPUParticles3D in [record.core, record.flames, record.wisps]:
		(layer.process_material as ParticleProcessMaterial).gravity = \
			_wind3 * FLAME_WIND_DRAG + Vector3(0.0, FLAME_BUOYANCY, 0.0)
	(record.smoke.process_material as ParticleProcessMaterial).gravity = \
		_wind3 * SMOKE_WIND_DRAG + Vector3(0.0, SMOKE_BUOYANCY, 0.0)
	(record.embers.process_material as ParticleProcessMaterial).gravity = \
		_wind3 * EMBER_WIND_DRAG + EMBER_GRAVITY
	var radius := record.preset.haze_radius_m
	var axis := (Vector3.UP + _lean3) * config.haze_height_m
	record.haze.basis = Basis(Vector3(radius, 0.0, 0.0), axis, Vector3(0.0, 0.0, radius))
	record.haze.position = record.pos + axis * 0.5
	if record.fog != null:
		record.fog.position = record.pos + (Vector3.UP + _lean3) * record.fog.size.y * 0.35


# --- per-fire envelope, light flicker, LOD ----------------------------------


func _update_envelope(record: FireRecord, delta: float) -> void:
	var rate := config.ignite_rate_per_s if record.target > record.intensity \
		else config.extinguish_rate_per_s
	record.intensity = move_toward(record.intensity, record.target, rate * delta)


func _update_extras(record: FireRecord, camera_position: Vector3) -> void:
	var preset := record.preset
	var intensity := record.intensity
	var distance := camera_position.distance_to(record.pos)
	var flicker := 0.85 + 0.35 * _noise.noise.get_noise_1d(_time * 320.0 + record.seed * 500.0)
	record.light.light_energy = preset.light_energy * intensity * flicker
	record.light.position = record.pos + (Vector3.UP + _lean3) \
		* preset.flame_height_m * 0.45 * intensity
	record.light.visible = intensity > 0.01 and distance < config.light_cutoff_m
	if record.fog != null:
		record.fog.visible = fire_fog and record.light.visible
	record.haze.visible = heat_haze and intensity > 0.02 and distance < config.haze_cutoff_m
	if record.haze.visible:
		# Refraction reads as a smeared band over the flames up close: fade the
		# haze in with distance so near views get crisp fire, far views shimmer.
		var haze_gate := clampf((distance - 6.0) / 16.0, 0.0, 1.0)
		record.haze.set_instance_shader_parameter("haze_intensity",
			intensity * haze_gate)
		record.haze.set_instance_shader_parameter("haze_seed", record.seed)
	var ratio := clampf(intensity * rate_scale / MAX_RATE_SCALE, 0.0, 1.0)
	var in_flame_range := distance < config.flame_cutoff_m
	record.glow.emitting = intensity > 0.02 and in_flame_range
	(record.glow.process_material as ParticleProcessMaterial).color = Color(1, 1, 1, intensity)
	for layer: GPUParticles3D in [record.core, record.flames, record.wisps]:
		layer.emitting = intensity > 0.02 and in_flame_range
		layer.amount_ratio = ratio
		(layer.process_material as ParticleProcessMaterial).color = Color(1, 1, 1, intensity)
	if record.ground_light != null:
		record.ground_light.visible = record.light.visible
		record.ground_light.light_energy = preset.ground_light_energy * intensity \
			* (0.5 + 0.5 * flicker)
	if record.bed != null:
		record.bed.visible = intensity > 0.01 and in_flame_range
		record.bed.set_instance_shader_parameter("bed_intensity", intensity)
		record.bed.set_instance_shader_parameter("bed_seed", record.seed)
	record.smoke.emitting = intensity > 0.05 and distance < config.smoke_cutoff_m
	record.smoke.amount_ratio = ratio
	(record.smoke.process_material as ParticleProcessMaterial).color = Color(
		preset.smoke_tint, intensity)
	record.embers.emitting = intensity > 0.03 and distance < config.ember_cutoff_m
	record.embers.amount_ratio = maxf(ratio, 0.025)


func _cull_cold(delta: float) -> void:
	var dead: Array[int] = []
	for id in _fires_by_id.keys():
		var record: FireRecord = _fires_by_id[id]
		if record.target == 0.0 and record.intensity <= 0.004:
			record.cold_time += delta
			# Wait for the last smoke puff to die before freeing its emitter.
			if record.remove_when_cold and record.cold_time > record.preset.smoke_lifetime_s:
				dead.append(id)
		else:
			record.cold_time = 0.0
	for id in dead:
		remove_fire(id)


func _drop_extras(record: FireRecord) -> void:
	record.light.queue_free()
	record.haze.queue_free()
	if record.fog != null:
		record.fog.queue_free()
	record.glow.queue_free()
	record.core.queue_free()
	record.flames.queue_free()
	record.wisps.queue_free()
	if record.ground_light != null:
		record.ground_light.queue_free()
	if record.bed != null:
		record.bed.queue_free()
	record.smoke.queue_free()
	record.embers.queue_free()
