class_name GrassRenderer extends Node3D

const GRASS_MESH_HIGH := preload("res://resources/grass/grass_high.obj")
const GRASS_MESH_LOW := preload("res://resources/grass/grass_low.obj")
const GRASS_MAT := preload("res://resources/grass/grass_material.tres")
const HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")
const GROUND_SHADER := preload("res://shaders/grass/ground.gdshader")
const GrassMultimeshBuilder := preload("res://scripts/grass/grass_multimesh_builder.gd")

## Tile variants repeat verbatim every 8 cells (an 80 m lattice at the default
## tile size): per-tile rotation was tried to break it and rejected — the
## re-rolled layouts exposed ground through the marginal canopy closure at
## low-clump spots, which the aligned validated layout happens to cover.
const TILE_VARIANTS := 8
const LOD_DISTANCES := [12.0, 40.0, 55.0, 70.0]

# Shadow-proxy sample rate. Below ~10% the sparse samples read as individual
# dark blobs from a top-down camera at low sun: each sample stretches a ~3 m
# streak with gaps between, instead of merging into a canopy shadow.
const SHADOW_DENSITY := 0.18
# Blades per tuft, scattered over a disc about one planting cell wide.
const SWARD_BLADES_NEAR := 14
const SWARD_BLADES_FAR := 7
const SWARD_SPREAD_M := 0.24
const WIDEN_START_M := 16.0
const RIM_FADE_M := 25.0

# Wind model, after canopy-flow measurements (Py et al. 2006, Dupont et al.
# 2010): gusts convect faster than the mean wind at canopy top, stems answer
# near their own natural frequency, and the waving wavelength is Uc / f0.
const WIND_10M_MPS_PER_UNIT := 2.0
const CANOPY_WIND_RATIO := 0.4
const GUST_TILE_M := Vector2(850.0, 300.0)
const WAVE_TILE_M := Vector2(70.0, 160.0)
const EDDY_TILE_M := 26.0
const VEER_TILE_M := 1300.0
const GUST_SPEED_RATIO := 0.7
const WAVE_CONVECTION_RATIO := 1.7
const EDDY_SPEED_RATIO := 0.5
const VEER_SPEED_RATIO := 0.25
const VEER_RAD := 0.7
const SWAY_HZ := Vector2(1.25, 1.9)

var config: GrassConfig = GrassConfig.new()
var density := 1.0
var near_detail := true
var wind_speed := 1.0
var wind_direction_degrees := 35.0
var gustiness := 0.65
var demo_stage := 3
var shadows_enabled := true
var material: ShaderMaterial
var _tiles: Array[Array] = []
var _previous_tile_id := Vector3.ZERO
var _gust_pulse := 0.0
var _gust_age := -1.0
var _gust_strength := 0.0
var _gust_speed := 15.0
var _gust_phase := 0.0
var _gust_release_start := 0.0
var _gust_duration := 0.0
var _wind_phase := [0.0, 0.0, 0.0, 0.0]
var _sway_phase := [0.0, 0.0]
var _ground_material: ShaderMaterial
var _layout_seed := 821
var _lod_variants: Array[Array] = []
var _rank_camera_position := Vector3.ZERO
var _tuft_mesh_high: ArrayMesh
var _tuft_mesh_low: ArrayMesh
var _shadow_instance: MultiMeshInstance3D


func build() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Grass config: %s" % config_error)
		return
	material = GRASS_MAT.duplicate() as ShaderMaterial
	material.set_shader_parameter("heightmap", HEIGHTMAP)
	material.set_shader_parameter("heightmap_scale", config.heightmap_scale_m)
	configure_wind(material)
	_tuft_mesh_high = GrassMultimeshBuilder.make_tuft_mesh(true, true,
		SWARD_BLADES_NEAR, SWARD_SPREAD_M)
	_tuft_mesh_low = GrassMultimeshBuilder.make_tuft_mesh(false, true,
		SWARD_BLADES_FAR, SWARD_SPREAD_M)
	set_wind_speed(wind_speed)
	set_wind_direction(wind_direction_degrees)
	set_gustiness(gustiness)
	set_demo_stage(demo_stage)
	_build_tiles()
	_apply_tile_shadows()
	_apply_rim()
	generate()


## Soil material displacing a ground mesh with the same heightmap the blades
## sample; assign it to a subdivided ground plane so the visible ground
## matches the field the grass grows on.
func ground_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = GROUND_SHADER
	mat.set_shader_parameter("heightmap", HEIGHTMAP)
	mat.set_shader_parameter("heightmap_scale", config.heightmap_scale_m)
	mat.set_shader_parameter("clump_noise", material.get_shader_parameter("clump_noise"))
	for parameter in ["wind_noise", "wind_gust_wave_tile_m", "wind_eddy_veer_tile_m",
			"wind_veer_rad", "wind_speed", "wind_direction", "gustiness"]:
		mat.set_shader_parameter(parameter, material.get_shader_parameter(parameter))
	_ground_material = mat
	_apply_rim()
	return mat


func _set_wind_parameter(parameter: String, value: Variant) -> void:
	material.set_shader_parameter(parameter, value)
	if _ground_material != null:
		_ground_material.set_shader_parameter(parameter, value)


## Pushes the wind layer geometry; every material including wind_field needs it.
static func configure_wind(target: ShaderMaterial) -> void:
	target.set_shader_parameter("wind_gust_wave_tile_m",
		Vector4(GUST_TILE_M.x, GUST_TILE_M.y, WAVE_TILE_M.x, WAVE_TILE_M.y))
	target.set_shader_parameter("wind_eddy_veer_tile_m", Vector2(EDDY_TILE_M, VEER_TILE_M))
	target.set_shader_parameter("wind_veer_rad", VEER_RAD)


## Noise tiles per second for the gust, wave, eddy and veer layers.
static func wind_phase_rates(speed: float) -> Array[float]:
	var wind_10m := speed * WIND_10M_MPS_PER_UNIT
	return [wind_10m * GUST_SPEED_RATIO / GUST_TILE_M.x,
		wind_10m * CANOPY_WIND_RATIO * WAVE_CONVECTION_RATIO / WAVE_TILE_M.x,
		wind_10m * EDDY_SPEED_RATIO / EDDY_TILE_M, wind_10m * VEER_SPEED_RATIO / VEER_TILE_M]


static func sway_wavenumber(speed: float) -> float:
	return TAU * SWAY_HZ.x / maxf(
		speed * WIND_10M_MPS_PER_UNIT * CANOPY_WIND_RATIO * WAVE_CONVECTION_RATIO, 1.0)


## Drives a grass material from an absolute clock, for hosts whose wind speed
## never changes (a varying speed needs the accumulated phases of tick()).
static func apply_wind_clock(target: ShaderMaterial, time_s: float, speed: float) -> void:
	var rates := wind_phase_rates(speed)
	target.set_shader_parameter("wind_phase", Vector4(fposmod(time_s * rates[0], 1.0),
		fposmod(time_s * rates[1], 1.0), fposmod(time_s * rates[2], 1.0),
		fposmod(time_s * rates[3], 1.0)))
	target.set_shader_parameter("sway_phase", Vector2(fposmod(time_s * TAU * SWAY_HZ.x, TAU),
		fposmod(time_s * TAU * SWAY_HZ.y, TAU)))
	target.set_shader_parameter("sway_wavenumber", sway_wavenumber(speed))


func set_wind_speed(value: float) -> void:
	wind_speed = clampf(value, 0.0, 5.0)
	if material != null:
		_set_wind_parameter("wind_speed", wind_speed)


func set_wind_direction(value_degrees: float) -> void:
	wind_direction_degrees = fposmod(value_degrees, 360.0)
	var angle := deg_to_rad(wind_direction_degrees)
	if material != null:
		_set_wind_parameter("wind_direction", Vector2(cos(angle), sin(angle)))


func set_gustiness(value: float) -> void:
	gustiness = clampf(value, 0.0, 1.0)
	if material != null:
		_set_wind_parameter("gustiness", gustiness)


func set_demo_stage(value: int) -> void:
	demo_stage = clampi(value, 0, 3)
	if material != null:
		material.set_shader_parameter("demo_stage", demo_stage)
	for lods in _lod_variants:
		for lod_index in lods.size():
			var multimesh: MultiMesh = lods[lod_index]
			multimesh.mesh = _mesh_for_lod(lod_index)
	if _shadow_instance != null and _shadow_instance.multimesh != null:
		_shadow_instance.multimesh.mesh = _mesh_for_lod(3)


func set_near_detail(enabled: bool) -> void:
	if near_detail == enabled:
		return
	near_detail = enabled
	set_demo_stage(demo_stage)


func add_gust(strength: float = 1.0, center: Vector3 = Vector3.ZERO) -> void:
	if material == null:
		return
	_gust_age = 0.0
	_gust_strength = clampf(strength / 4.0, 0.0, 1.0)
	_gust_pulse = 0.0
	# Each burst sweeps at its own pace and carries its own noise offset, so
	# repeated triggers never replay the identical front.
	_gust_phase = randf() * TAU
	var angle := deg_to_rad(wind_direction_degrees)
	var direction := Vector2(cos(angle), sin(angle))
	var origin := Vector2(center.x, center.z)
	var half_extent := config.tile_size_m * 0.5 * (absf(direction.x) + absf(direction.y))
	var upwind := INF
	var downwind := -INF
	for data in _tiles:
		var position: Vector3 = data[0].global_position
		var distance := (Vector2(position.x, position.z) - origin).dot(direction)
		upwind = minf(upwind, distance - half_extent)
		downwind = maxf(downwind, distance + half_extent)
	_gust_speed = (downwind - upwind) / randf_range(2.7, 3.3)
	origin += direction * (upwind - 9.0)
	var travel_distance := downwind - upwind + 9.0
	_gust_release_start = (travel_distance + 190.0) / _gust_speed
	_gust_duration = (travel_distance + 275.0) / _gust_speed
	material.set_shader_parameter("gust_origin", origin)
	material.set_shader_parameter("gust_direction", direction)
	material.set_shader_parameter("gust_age", _gust_age)
	material.set_shader_parameter("gust_pulse", 0.0)
	material.set_shader_parameter("gust_speed", _gust_speed)
	material.set_shader_parameter("gust_phase", _gust_phase)


func tick(delta: float, camera_target: Vector3, camera_position: Vector3) -> void:
	# _physics_process drives this even when build() bailed on an invalid config.
	if material == null:
		return
	# TIME grows without bound in the shader, so after hours its float32 steps
	# get coarser than a frame and the wind scroll shimmers; accumulate every
	# phase here in 64-bit instead, each wrapped on its own period.
	var rates := wind_phase_rates(wind_speed)
	for layer in 4:
		_wind_phase[layer] = fposmod(_wind_phase[layer] + delta * rates[layer], 1.0)
	_sway_phase[0] = fposmod(_sway_phase[0] + delta * TAU * SWAY_HZ.x, TAU)
	_sway_phase[1] = fposmod(_sway_phase[1] + delta * TAU * SWAY_HZ.y, TAU)
	_set_wind_parameter("wind_phase",
		Vector4(_wind_phase[0], _wind_phase[1], _wind_phase[2], _wind_phase[3]))
	material.set_shader_parameter("sway_phase", Vector2(_sway_phase[0], _sway_phase[1]))
	material.set_shader_parameter("sway_wavenumber", sway_wavenumber(wind_speed))
	if _gust_age >= 0.0:
		_gust_age += delta
		var attack := smoothstep(0.0, 0.15, _gust_age)
		var release := 1.0 - smoothstep(_gust_release_start, _gust_duration, _gust_age)
		# The pulse breathes while it travels so the front surges and slackens
		# instead of marching at a constant amplitude.
		_gust_pulse = _gust_strength * attack * release \
			* (0.85 + 0.15 * sin(_gust_age * 9.0))
		material.set_shader_parameter("gust_pulse", _gust_pulse)
		material.set_shader_parameter("gust_age", _gust_age)
		if _gust_age >= _gust_duration:
			_gust_age = -1.0
			_gust_pulse = 0.0
			material.set_shader_parameter("gust_age", -1.0)
			material.set_shader_parameter("gust_pulse", 0.0)
	var tile_id := ((camera_target + Vector3.ONE * config.tile_size_m * 0.5)
		/ config.tile_size_m * Vector3(1, 0, 1)).floor()
	var camera_moved := camera_position.distance_squared_to(_rank_camera_position) > 1.0
	if tile_id == _previous_tile_id and not camera_moved:
		return
	_rank_camera_position = camera_position
	var tile_shifted := tile_id != _previous_tile_id
	if tile_shifted:
		for data in _tiles:
			var instance: MultiMeshInstance3D = data[0]
			instance.global_position = data[1] + Vector3(1, 0, 1) * config.tile_size_m * tile_id
		_shadow_instance.global_position = Vector3(1, 0, 1) * config.tile_size_m * tile_id
		_previous_tile_id = tile_id
	_rank_tiles()
	if tile_shifted:
		_build_shadow_multimesh()


## Rebuilds the tile grid; the far soil and the blade widening follow the rim.
func set_map_radius(value_m: float) -> void:
	if is_equal_approx(value_m, config.map_radius_m) and not _tiles.is_empty():
		return
	config.map_radius_m = value_m
	if material == null:
		return
	for data in _tiles:
		data[0].free()
	_tiles.clear()
	if _shadow_instance != null:
		_shadow_instance.free()
	_build_tiles()
	_apply_tile_shadows()
	var offset := Vector3(1, 0, 1) * config.tile_size_m * _previous_tile_id
	for data in _tiles:
		data[0].global_position = data[1] + offset
	_shadow_instance.global_position = offset
	_apply_rim()
	if not _lod_variants.is_empty():
		_rank_tiles()
		_build_shadow_multimesh()


func _apply_rim() -> void:
	material.set_shader_parameter("widen_distance_m",
		Vector2(WIDEN_START_M, config.map_radius_m - RIM_FADE_M * 0.2))
	if _ground_material != null:
		_ground_material.set_shader_parameter("grass_cover_m",
			Vector2(config.map_radius_m - RIM_FADE_M, config.map_radius_m + RIM_FADE_M * 0.6))


func set_density(value: float) -> void:
	value = clampf(value, 0.0, 2.0)
	if is_equal_approx(value, density):
		return
	density = value
	generate()


func set_clumping(value: float) -> void:
	material.set_shader_parameter("clumping_factor", clampf(value, 0.0, 1.0))


func set_colors(base: Color, tip: Color, sss: Color) -> void:
	material.set_shader_parameter("base_color", base)
	material.set_shader_parameter("tip_color", tip)
	material.set_shader_parameter("subsurface_scattering_color", sss)


func set_base_color(color: Color) -> void:
	material.set_shader_parameter("base_color", color)


func set_tip_color(color: Color) -> void:
	material.set_shader_parameter("tip_color", color)


func set_sss_color(color: Color) -> void:
	material.set_shader_parameter("subsurface_scattering_color", color)


func set_plume_color(color: Color) -> void:
	material.set_shader_parameter("plume_color", color)


func set_height_scale(value: float) -> void:
	material.set_shader_parameter("height_scale", clampf(value, 0.2, 1.5))


func set_plume_density(value: float) -> void:
	material.set_shader_parameter("plume_density", clampf(value, 0.0, 1.0))


func set_chromatic_strength(value: float) -> void:
	material.set_shader_parameter("chromatic_strength", value)


func set_shadows(enabled: bool) -> void:
	shadows_enabled = enabled
	_apply_tile_shadows()


func regenerate() -> void:
	_layout_seed += 1
	generate()


func generate() -> void:
	_lod_variants.clear()
	var high_mesh := _mesh_for_lod(0)
	var low_mesh := _mesh_for_lod(3)
	for variant_id in TILE_VARIANTS:
		_lod_variants.append(GrassMultimeshBuilder.build_lods(
			density, config.tile_size_m, high_mesh, low_mesh,
			_layout_seed + variant_id * 7919))
	_rank_tiles()
	_build_shadow_multimesh()


func _mesh_for_lod(lod_index: int) -> Mesh:
	var detailed := near_detail and lod_index == 0
	if demo_stage == 0:
		return GRASS_MESH_HIGH if detailed else GRASS_MESH_LOW
	return _tuft_mesh_high if detailed else _tuft_mesh_low


func _build_tiles() -> void:
	var tile_step := maxi(int(config.tile_size_m), 1)
	if int(config.map_radius_m * 2.0) % tile_step != 0:
		push_warning("Grass: tile_size_m should divide 2 * map_radius_m, "
			+ "or the tile grid ends asymmetric and tiles overlap")
	var half := config.tile_size_m * 0.5
	# The 4.25 m margin covers the tuft spread plus the worst converging wind
	# bend (~2.6 m: gust band, wave and turbulence all peaking together) with
	# headroom, so culling never clips bending blades at a tile edge.
	var tile_aabb := AABB(Vector3(-half - 4.25, -3.5, -half - 4.25),
		Vector3(config.tile_size_m + 8.5, 9.0, config.tile_size_m + 8.5))
	for x in range(-int(config.map_radius_m), int(config.map_radius_m), int(config.tile_size_m)):
		for z in range(-int(config.map_radius_m), int(config.map_radius_m), int(config.tile_size_m)):
			var instance := MultiMeshInstance3D.new()
			instance.material_override = material
			instance.position = Vector3(x, 0.0, z)
			instance.custom_aabb = tile_aabb
			add_child(instance)
			_tiles.append([instance, instance.position])
	_shadow_instance = MultiMeshInstance3D.new()
	_shadow_instance.material_override = material
	var extent := config.map_radius_m + config.tile_size_m
	_shadow_instance.custom_aabb = AABB(Vector3(-extent, -3.5, -extent),
		Vector3(extent * 2.0, 9.0, extent * 2.0))
	add_child(_shadow_instance)


func _apply_tile_shadows() -> void:
	for data in _tiles:
		var instance: MultiMeshInstance3D = data[0]
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shadow_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY \
		if shadows_enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## LOD rings follow the camera; orbit and zoom must re-rank tiles.
func _rank_tiles() -> void:
	if _lod_variants.is_empty():
		return
	for data in _tiles:
		var instance: MultiMeshInstance3D = data[0]
		var distance := _camera_distance(instance)
		var lod_index := 0
		while lod_index < LOD_DISTANCES.size() and distance >= LOD_DISTANCES[lod_index]:
			lod_index += 1
		instance.multimesh = _lod_variants[_variant_for_tile(instance)][lod_index]


func _build_shadow_multimesh() -> void:
	var source_count: int = _lod_variants[0][2].instance_count
	var samples_per_tile := ceili(float(source_count) * SHADOW_DENSITY)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = _mesh_for_lod(3)
	multimesh.instance_count = _tiles.size() * samples_per_tile
	var target_index := 0
	for data in _tiles:
		var instance: MultiMeshInstance3D = data[0]
		var source: MultiMesh = _lod_variants[_variant_for_tile(instance)][2]
		for source_index in samples_per_tile:
			var transform := source.get_instance_transform(source_index)
			transform.origin += data[1]
			multimesh.set_instance_transform(target_index, transform)
			multimesh.set_instance_custom_data(target_index,
				source.get_instance_custom_data(source_index))
			target_index += 1
	_shadow_instance.multimesh = multimesh


func _variant_for_tile(instance: MultiMeshInstance3D) -> int:
	var tile_x := int(round(instance.global_position.x / config.tile_size_m))
	var tile_z := int(round(instance.global_position.z / config.tile_size_m))
	var key := tile_x * 73856093 + tile_z * 19349663 + _layout_seed * 83492791
	return absi(key) % TILE_VARIANTS


func _camera_distance(instance: MultiMeshInstance3D) -> float:
	return instance.global_position.distance_to(_rank_camera_position)
