class_name FireBillboardSystem extends Node3D
## The cheap "game fire" renderer from docs/game_fire_rdr2_model.md: additive
## flame billboards and alpha smoke from baked atlases, drawn through two
## pooled MultiMeshes and advected on the CPU by an analytic field (trig
## curl stand-in + wind + thermal buoyancy) — no grid, no projection, no
## simulation. Each fire also gets a flickering OmniLight3D, an ember
## GPUParticles3D and a heat-haze volume, all gated by distance LOD.
## Emitter-driven: zero per-frame cost when no fire is active.
##
##     var system := FireBillboardSystem.new()
##     add_child(system)
##     system.build(config, flame_atlas, smoke_atlas)
##     var id := system.add_fire(pos, preset)
##     # every frame:
##     system.update(delta, camera.global_position)

const FLAME_SHADER := "res://shaders/game_fire/fire_flipbook.gdshader"
const SMOKE_SHADER := "res://shaders/game_fire/smoke_flipbook.gdshader"
const HAZE_SHADER := "res://shaders/game_fire/heat_haze.gdshader"

var config: GameFireConfig
## CPU cost of the last update() call, for the HUD budget readout.
var last_update_ms := 0.0
## Global spawn-rate multiplier (menu "flame density").
var rate_scale := 1.0

var _time := 0.0
var _wind_dir := Vector2(1.0, 0.0)
var _wind_strength := 0.0
var _wind3 := Vector3.ZERO
var _next_id := 1
var _fires_by_id := {}
var _flame_layer := Layer.new()
var _smoke_layer := Layer.new()
var _flame_mm: MultiMesh
var _smoke_mm: MultiMesh
var _hidden_transform := Transform3D(Basis.from_scale(Vector3.ZERO),
	Vector3(0.0, -1e4, 0.0))
var _haze_mesh: CylinderMesh
var _haze_material: ShaderMaterial
var _ember_mesh: QuadMesh


## One pooled billboard layer (flame or smoke): structure-of-arrays particle
## state plus a free-slot stack. Slots are released back by writing a
## degenerate transform, so MultiMesh buffers never reallocate at runtime.
class Layer extends RefCounted:
	var px := PackedFloat32Array()
	var py := PackedFloat32Array()
	var pz := PackedFloat32Array()
	var vx := PackedFloat32Array()
	var vy := PackedFloat32Array()
	var vz := PackedFloat32Array()
	var age := PackedFloat32Array()
	var life := PackedFloat32Array()
	var seed := PackedFloat32Array()
	var scl := PackedFloat32Array()
	var roll := PackedFloat32Array()
	var rate := PackedFloat32Array()
	var fire := PackedInt64Array()
	var used := PackedByteArray()
	var free_stack: Array[int] = []
	var live_count := 0

	func allocate(count: int) -> void:
		var offset := px.size()
		px.resize(count)
		py.resize(count)
		pz.resize(count)
		vx.resize(count)
		vy.resize(count)
		vz.resize(count)
		age.resize(count)
		life.resize(count)
		seed.resize(count)
		scl.resize(count)
		roll.resize(count)
		rate.resize(count)
		fire.resize(count)
		used.resize(count)
		for index in range(offset, count):
			free_stack.append(index)


class FireRecord extends RefCounted:
	var id := 0
	var pos := Vector3.ZERO
	var preset: GameFirePreset
	var intensity := 0.0
	var target := 1.0
	var seed := 0.0
	var remove_when_cold := true
	var cold_time := 0.0
	var spawn_flame := 0.0
	var spawn_smoke := 0.0
	var accum_flame := 0.0
	var accum_smoke := 0.0
	var live_flame := 0
	var live_smoke := 0
	var light: OmniLight3D
	var haze: MeshInstance3D
	var embers: GPUParticles3D


func build(fire_config: GameFireConfig, flame_atlas: Texture2D,
		smoke_atlas: Texture2D) -> void:
	var error := fire_config.validate()
	assert(error.is_empty(), "FireBillboardSystem: %s" % error)
	config = fire_config
	_flame_layer.allocate(config.flame_pool)
	_smoke_layer.allocate(config.smoke_pool)

	_flame_mm = _make_multimesh()
	_flame_mm.instance_count = config.flame_pool
	for index in config.flame_pool:
		_flame_mm.set_instance_transform(index, _hidden_transform)
	_smoke_mm = _make_multimesh()
	_smoke_mm.instance_count = config.smoke_pool
	for index in config.smoke_pool:
		_smoke_mm.set_instance_transform(index, _hidden_transform)
	var flame_instance := MultiMeshInstance3D.new()
	flame_instance.multimesh = _flame_mm
	flame_instance.material_override = _make_flipbook_material(FLAME_SHADER,
		flame_atlas, 0.85)
	flame_instance.custom_aabb = AABB(Vector3(-160, -6, -160), Vector3(320, 130, 320))
	add_child(flame_instance)
	var smoke_instance := MultiMeshInstance3D.new()
	smoke_instance.multimesh = _smoke_mm
	smoke_instance.material_override = _make_flipbook_material(SMOKE_SHADER,
		smoke_atlas, 1.0, 0.3)
	smoke_instance.custom_aabb = AABB(Vector3(-160, -6, -160), Vector3(320, 130, 320))
	add_child(smoke_instance)

	_haze_mesh = CylinderMesh.new()
	# Tapered: the haze column follows the flame cone instead of a straight tube.
	_haze_mesh.top_radius = 0.4
	_haze_mesh.bottom_radius = 1.0
	_haze_mesh.height = 1.0
	_haze_mesh.radial_segments = 12
	_haze_mesh.cap_top = false
	_haze_mesh.cap_bottom = false
	_haze_material = ShaderMaterial.new()
	_haze_material.shader = load(HAZE_SHADER)
	_haze_material.set_shader_parameter("strength", config.haze_strength)
	_haze_material.set_shader_parameter("height_m", config.haze_height_m)

	_ember_mesh = QuadMesh.new()
	_ember_mesh.size = Vector2(0.045, 0.045)
	# Radial falloff baked into RGB *and* alpha: additive blends that ignore
	# alpha would otherwise render the quad as a solid square spark.
	var ember_sprite := ImageTexture.create_from_image(_ember_dot_image())
	var ember_material := StandardMaterial3D.new()
	ember_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ember_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	ember_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	ember_material.albedo_color = Color(1.0, 0.55, 0.18)
	ember_material.albedo_texture = ember_sprite
	_ember_mesh.material = ember_material


func add_fire(pos: Vector3, preset: GameFirePreset, remove_when_cold := true) -> int:
	var error := preset.validate()
	assert(error.is_empty(), "FireBillboardSystem: %s" % error)
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
	record.light.shadow_enabled = false
	record.light.position = pos + Vector3(0.0, preset.flame_height_m * 0.7, 0.0)
	add_child(record.light)
	record.haze = MeshInstance3D.new()
	record.haze.mesh = _haze_mesh
	record.haze.material_override = _haze_material
	record.haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	record.haze.position = pos + Vector3(0.0, config.haze_height_m * 0.5, 0.0)
	record.haze.scale = Vector3(preset.haze_radius_m, config.haze_height_m,
		preset.haze_radius_m)
	record.haze.visible = false
	add_child(record.haze)
	record.embers = _make_embers(preset, pos)
	add_child(record.embers)
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
	_drop_extras(record)


func clear_all() -> void:
	for id in _fires_by_id.keys():
		remove_fire(id)


func fire_count() -> int:
	return _fires_by_id.size()


func live_particles() -> int:
	return _flame_layer.live_count + _smoke_layer.live_count


func set_wind(direction: Vector2, strength: float) -> void:
	_wind_dir = direction.normalized() if direction.length() > 0.001 \
		else Vector2.RIGHT
	_wind_strength = strength


func update(delta: float, camera_position: Vector3) -> void:
	var start_usec := Time.get_ticks_usec()
	_time += delta
	_wind3 = Vector3(_wind_dir.x, 0.0, _wind_dir.y) * _wind_strength
	for id in _fires_by_id.keys():
		var record: FireRecord = _fires_by_id[id]
		record.live_flame = 0
		record.live_smoke = 0
		_update_envelope(record, delta)
		_update_extras(record, camera_position)
	_integrate_flame(delta)
	_integrate_smoke(delta)
	_cull_cold(delta)
	last_update_ms = float(Time.get_ticks_usec() - start_usec) / 1000.0


# --- setup helpers ----------------------------------------------------------


func _make_multimesh() -> MultiMesh:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.use_colors = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	multimesh.mesh = quad
	return multimesh


func _make_flipbook_material(shader_path: String, atlas: Texture2D,
		energy: float, alpha: float = 1.0) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(shader_path)
	material.set_shader_parameter("atlas_tex", atlas)
	material.set_shader_parameter("atlas_frames",
		Vector2(config.atlas_cols, config.atlas_rows))
	material.set_shader_parameter("emissive_energy", energy)
	material.set_shader_parameter("alpha_scale", alpha)
	return material


## 32px soft round dot for ember sprites (RGB and alpha share the falloff).
func _ember_dot_image() -> Image:
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 15.5, y - 15.5).length() / 15.5
			var f := pow(clampf(1.0 - d, 0.0, 1.0), 1.6)
			image.set_pixel(x, y, Color(f, f, f, f))
	return image


func _make_embers(preset: GameFirePreset, pos: Vector3) -> GPUParticles3D:
	var embers := GPUParticles3D.new()
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = preset.emitter_radius_m
	process.direction = Vector3.UP
	process.spread = 22.0
	process.initial_velocity_min = preset.ember_speed_m * 0.5
	process.initial_velocity_max = preset.ember_speed_m
	process.gravity = Vector3(0.0, -3.2, 0.0)
	process.scale_min = 0.35
	process.scale_max = 1.0
	# Native curl-noise turbulence: the embers' "fluid" motion for free.
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 1.4
	process.turbulence_noise_scale = 2.4
	embers.process_material = process
	embers.draw_pass_1 = _ember_mesh
	embers.amount = maxi(preset.ember_count, 1)
	embers.lifetime = 1.6
	embers.emitting = false
	embers.position = pos + Vector3(0.0, preset.flame_height_m * 0.5, 0.0)
	return embers


# --- per-fire envelope, light flicker, LOD ----------------------------------


func _update_envelope(record: FireRecord, delta: float) -> void:
	var rate := config.ignite_rate_per_s if record.target > record.intensity \
		else config.extinguish_rate_per_s
	record.intensity = move_toward(record.intensity, record.target, rate * delta)


func _update_extras(record: FireRecord, camera_position: Vector3) -> void:
	var preset := record.preset
	var intensity := record.intensity
	var distance := camera_position.distance_to(record.pos)
	var flicker := 0.82 + 0.13 * sin(_time * 11.0 + record.seed * 7.0) \
		+ 0.05 * sin(_time * 23.0 + record.seed * 13.0)
	record.light.light_energy = preset.light_energy * intensity * flicker
	record.light.position = record.pos + Vector3(0.0,
		preset.flame_height_m * 0.7 * intensity, 0.0)
	record.light.visible = intensity > 0.01 and distance < config.light_cutoff_m
	record.haze.visible = intensity > 0.02 and distance < config.haze_cutoff_m
	if record.haze.visible:
		# Refraction reads as a smeared band over the flames up close: fade the
		# haze in with distance so near views get crisp fire, far views shimmer.
		var haze_gate := clampf((distance - 6.0) / 16.0, 0.0, 1.0)
		record.haze.set_instance_shader_parameter("haze_intensity",
			intensity * haze_gate)
		record.haze.set_instance_shader_parameter("haze_seed", record.seed)
	record.embers.emitting = intensity > 0.03 and distance < config.ember_cutoff_m
	record.embers.amount_ratio = clampf(intensity, 0.05, 1.0)
	record.spawn_flame = preset.flame_rate_hz * intensity * rate_scale \
		if distance < config.flame_cutoff_m else 0.0
	record.spawn_smoke = preset.smoke_rate_hz * intensity * rate_scale \
		if distance < config.smoke_cutoff_m else 0.0


func _cull_cold(delta: float) -> void:
	var dead: Array[int] = []
	for id in _fires_by_id.keys():
		var record: FireRecord = _fires_by_id[id]
		if record.target == 0.0 and record.intensity <= 0.004 \
				and record.live_flame == 0 and record.live_smoke == 0:
			record.cold_time += delta
			if record.remove_when_cold and record.cold_time > 0.25:
				dead.append(id)
	for id in dead:
		var record: FireRecord = _fires_by_id.get(id)
		_fires_by_id.erase(id)
		if record != null:
			_drop_extras(record)


## Particles still referencing this record die on their next integration pass.
func _drop_extras(record: FireRecord) -> void:
	record.light.queue_free()
	record.haze.queue_free()
	record.embers.queue_free()


# --- flame layer ------------------------------------------------------------


func _integrate_flame(delta: float) -> void:
	var layer := _flame_layer
	for id in _fires_by_id.keys():
		var record: FireRecord = _fires_by_id[id]
		record.accum_flame += record.spawn_flame * delta
		while record.accum_flame >= 1.0:
			if layer.free_stack.is_empty():
				record.accum_flame = 0.0
				break
			record.accum_flame -= 1.0
			_spawn_flame(layer, record)
	for index in layer.px.size():
		if layer.used[index] == 0:
			continue
		var record: FireRecord = _fires_by_id.get(layer.fire[index])
		if record == null:
			_release(layer, index)
			continue
		layer.age[index] += delta * layer.rate[index]
		var age_norm := layer.age[index] / layer.life[index]
		if age_norm >= 1.0:
			_release(layer, index)
			continue
		var position := Vector3(layer.px[index], layer.py[index], layer.pz[index])
		var velocity := Vector3(layer.vx[index], layer.vy[index], layer.vz[index])
		var acceleration := _turbulence(position, 0.55)
		acceleration += _wind3 * (0.5 + 1.2 * age_norm)
		# Gentle buoyancy: the flipbook carries the flame motion, the emitter
		# point must stay near the fuel bed or the fire detaches from the ground.
		acceleration.y += 0.35 + 0.55 * (1.0 - age_norm)
		# Pull toward the fire axis as the tongue ages: the ensemble narrows
		# into the campfire cone instead of drifting into a straight wall.
		acceleration.x -= (position.x - record.pos.x) * 1.2 * age_norm
		acceleration.z -= (position.z - record.pos.z) * 1.2 * age_norm
		velocity += acceleration * delta
		velocity *= maxf(0.0, 1.0 - 1.6 * delta)
		position += velocity * delta
		layer.px[index] = position.x
		layer.py[index] = position.y
		layer.pz[index] = position.z
		layer.vx[index] = velocity.x
		layer.vy[index] = velocity.y
		layer.vz[index] = velocity.z
		var preset := record.preset
		var size_scale := clampf(record.intensity, 0.15, 1.0)
		# One billboard = one flame tongue: it stretches up and thins as it
		# ages, so the live ensemble tapers like real fire instead of widening.
		# flame_width_m drives the tongue's base aspect (width over height).
		var aspect := clampf(preset.flame_width_m / preset.flame_height_m,
			0.55, 0.95)
		var sy := preset.flame_height_m * 0.85 * (0.5 + 0.8 * age_norm) \
			* size_scale * layer.scl[index]
		# Young tongues start wide so their bases merge into one continuous
		# fire bed; they thin as they rise (no blowtorch spike row).
		var sx := sy * aspect * (0.95 - 0.3 * age_norm)
		var tint := preset.flame_tint(age_norm)
		var fade := clampf(age_norm / 0.14, 0.0, 1.0) \
			* (1.0 - smoothstep(0.55, 1.0, age_norm))
		# The particle position is the flame's base: lift the quad origin half a
		# height so the billboard is rooted there instead of centered on it.
		_flame_mm.set_instance_transform(index, Transform3D(
			Basis.from_scale(Vector3(sx, sy, 1.0)),
			position + Vector3(0.0, sy * 0.5, 0.0)))
		_flame_mm.set_instance_custom_data(index, Color(age_norm, layer.seed[index],
			record.intensity, layer.roll[index]))
		_flame_mm.set_instance_color(index, Color(tint.r, tint.g, tint.b, fade))
		record.live_flame += 1


func _spawn_flame(layer: Layer, record: FireRecord) -> void:
	var index: int = layer.free_stack.pop_back()
	layer.used[index] = 1
	layer.live_count += 1
	layer.fire[index] = record.id
	var preset := record.preset
	var radius := preset.emitter_radius_m * sqrt(randf())
	var angle := randf() * TAU
	layer.px[index] = record.pos.x + cos(angle) * radius
	# Base sits at the fuel bed so the tongue's wide root is hidden among logs.
	layer.py[index] = record.pos.y + randf_range(0.0, 0.12)
	layer.pz[index] = record.pos.z + sin(angle) * radius
	# The atlas frames already crawl upward; the quad itself stays near its bed.
	layer.vx[index] = (randf() - 0.5) * 0.3
	layer.vy[index] = randf_range(0.05, 0.3)
	layer.vz[index] = (randf() - 0.5) * 0.3
	# Stagger the atlas phase so simultaneous particles do not share a frame.
	layer.age[index] = randf() * 0.15 * preset.flame_lifetime_s
	layer.life[index] = preset.flame_lifetime_s * randf_range(0.6, 1.4)
	layer.seed[index] = randf() * 10.0
	layer.scl[index] = randf_range(0.7, 1.45)
	layer.roll[index] = randf_range(-0.35, 0.35)
	# Desynchronized playback: no two tongues pulse through the loop together.
	layer.rate[index] = randf_range(0.8, 1.25)


# --- smoke layer ------------------------------------------------------------


func _integrate_smoke(delta: float) -> void:
	var layer := _smoke_layer
	for id in _fires_by_id.keys():
		var record: FireRecord = _fires_by_id[id]
		record.accum_smoke += record.spawn_smoke * delta
		while record.accum_smoke >= 1.0:
			if layer.free_stack.is_empty():
				record.accum_smoke = 0.0
				break
			record.accum_smoke -= 1.0
			_spawn_smoke(layer, record)
	for index in layer.px.size():
		if layer.used[index] == 0:
			continue
		var record: FireRecord = _fires_by_id.get(layer.fire[index])
		if record == null:
			_release(layer, index)
			continue
		layer.age[index] += delta
		var age_norm := layer.age[index] / layer.life[index]
		if age_norm >= 1.0:
			_release(layer, index)
			continue
		var position := Vector3(layer.px[index], layer.py[index], layer.pz[index])
		var velocity := Vector3(layer.vx[index], layer.vy[index], layer.vz[index])
		var acceleration := _turbulence(position, 0.5)
		acceleration += _wind3 * (0.8 + 1.8 * age_norm)
		velocity += acceleration * delta
		velocity *= maxf(0.0, 1.0 - 0.8 * delta)
		position += velocity * delta
		layer.px[index] = position.x
		layer.py[index] = position.y
		layer.pz[index] = position.z
		layer.vx[index] = velocity.x
		layer.vy[index] = velocity.y
		layer.vz[index] = velocity.z
		var preset := record.preset
		var size := preset.smoke_size_m * (0.4 + 1.2 * age_norm)
		# Delayed fade-in: the puff must be above the flame body before it shows,
		# otherwise blend_mix smoke paints a dark veil over the additive flames.
		var fade := smoothstep(0.25, 0.45, age_norm) \
			* (1.0 - smoothstep(0.6, 1.0, age_norm))
		_smoke_mm.set_instance_transform(index, Transform3D(
			Basis.from_scale(Vector3(size, size, 1.0)), position))
		_smoke_mm.set_instance_custom_data(index, Color(age_norm, layer.seed[index],
			record.intensity, 0.0))
		var tint := preset.smoke_tint
		_smoke_mm.set_instance_color(index, Color(tint.r, tint.g, tint.b, fade))
		record.live_smoke += 1


func _spawn_smoke(layer: Layer, record: FireRecord) -> void:
	var index: int = layer.free_stack.pop_back()
	layer.used[index] = 1
	layer.live_count += 1
	layer.fire[index] = record.id
	var preset := record.preset
	var radius := preset.emitter_radius_m * sqrt(randf())
	var angle := randf() * TAU
	layer.px[index] = record.pos.x + cos(angle) * radius * 0.5
	# Spawn at the flame tip: smoke born inside the flame body veils it.
	layer.py[index] = record.pos.y + preset.flame_height_m * record.intensity \
		* randf_range(0.95, 1.35)
	layer.pz[index] = record.pos.z + sin(angle) * radius * 0.5
	layer.vx[index] = (randf() - 0.5) * 0.3
	layer.vy[index] = randf_range(0.6, 1.1)
	layer.vz[index] = (randf() - 0.5) * 0.3
	layer.age[index] = 0.0
	layer.life[index] = preset.smoke_lifetime_s * randf_range(0.8, 1.2)
	layer.seed[index] = randf() * 10.0


# --- shared -----------------------------------------------------------------


## Divergence-free-ish trig field: the analytic stand-in for curl noise.
func _turbulence(position: Vector3, amplitude: float) -> Vector3:
	var s := 1.7
	return Vector3(
		sin(position.y * s + _time * 2.1) + 0.6 * cos(position.z * 2.9 - _time * 1.7),
		0.4 * sin(position.x * 2.3 - _time * 1.9),
		cos(position.x * 1.9 + _time * 2.3) + 0.6 * sin(position.y * 2.7 + _time * 1.3)
	) * amplitude


func _release(layer: Layer, index: int) -> void:
	layer.used[index] = 0
	layer.live_count -= 1
	layer.free_stack.append(index)
	var mm := _flame_mm if layer == _flame_layer else _smoke_mm
	mm.set_instance_transform(index, _hidden_transform)
