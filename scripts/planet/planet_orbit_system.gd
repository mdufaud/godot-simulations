class_name PlanetOrbitSystem extends Node3D

const RING_SHADER: Shader = preload("res://shaders/planet/planet_ring.gdshader")
const LOW_ROCK_COUNT: int = 180
const MEDIUM_ROCK_COUNT: int = 420
const HIGH_ROCK_COUNT: int = 760

var moon_nodes: Array[MeshInstance3D] = []
var ring_root: Node3D
var ring_rock_count: int = 0
var elapsed: float = 0.0

var _config: PlanetConfig
var _planet_radius: float = 1.0
var _surface_radius: float = 1.0
var _detail: int = 1
var _sun_direction: Vector3 = Vector3(0.5, 0.4, 0.75).normalized()
var _dust_material: ShaderMaterial
var _rock_instance: MultiMeshInstance3D
var _moon_phases: Array[float] = []
var _moon_signature: Array = []
var _ring_signature: Array = []
var _ring_outer_m: float = 0.0


func configure(config: PlanetConfig, radius: float, surface_radius: float, detail: int) -> void:
	if config == null or not config.validate().is_empty():
		push_error("PlanetOrbitSystem requires a valid PlanetConfig")
		return
	_config = config
	_planet_radius = maxf(radius, 0.001)
	_surface_radius = maxf(surface_radius, 0.001)
	_detail = clampi(detail, 0, 2)
	_configure_ring()
	_configure_moons()
	_update_moon_positions()
	if is_instance_valid(_rock_instance):
		_rock_instance.rotation.y = elapsed * 0.08


func set_sun_direction(direction: Vector3) -> void:
	if direction.length_squared() > 0.000001:
		_sun_direction = direction.normalized()
	if _dust_material != null:
		_dust_material.set_shader_parameter("sun_direction", _sun_direction)


func advance(delta: float) -> void:
	if _config == null:
		return
	elapsed += maxf(delta, 0.0) * clampf(_config.orbit_speed, 0.0, 3.0)
	_update_moon_positions()
	if is_instance_valid(_rock_instance):
		_rock_instance.rotation.y = elapsed * 0.08


func stop() -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	moon_nodes.clear()
	ring_root = null
	_rock_instance = null
	_dust_material = null
	_config = null
	_moon_signature.clear()
	_ring_signature.clear()
	ring_rock_count = 0
	_ring_outer_m = 0.0
	_config = null


func moon_orbit_radius(index: int) -> float:
	if _config == null or index < 0 or index >= _config.moon_count:
		return 0.0
	return _moon_semimajor_axis(index)


func extent_radius() -> float:
	if _config == null:
		return 0.0
	var extent := maxf(_surface_radius, _ring_outer_m if _config.ring_enabled else 0.0)
	if not moon_nodes.is_empty():
		extent = maxf(extent, _moon_semimajor_axis(moon_nodes.size() - 1)
			* (1.0 + _config.moon_eccentricity) + _config.moon_size_ratio * _planet_radius)
	return extent


func ring_outer_radius() -> float:
	return _ring_outer_m if ring_root != null else 0.0


func moon_position(index: int, time_seconds: float) -> Vector3:
	if _config == null or index < 0 or index >= _config.moon_count:
		return Vector3.ZERO
	var axis: float = _moon_semimajor_axis(index)
	var eccentricity: float = clampf(_config.moon_eccentricity, 0.0, 0.25)
	var mean_motion: float = 0.55 * pow(_planet_radius / axis, 1.5)
	var mean_anomaly: float = fposmod(time_seconds * mean_motion + _moon_phase(index), TAU)
	var eccentric_anomaly: float = mean_anomaly
	for iteration: int in 5:
		eccentric_anomaly -= (eccentric_anomaly - eccentricity * sin(eccentric_anomaly) - mean_anomaly) / maxf(1.0 - eccentricity * cos(eccentric_anomaly), 0.001)
	var x: float = axis * (cos(eccentric_anomaly) - eccentricity)
	var z: float = axis * sqrt(1.0 - eccentricity * eccentricity) * sin(eccentric_anomaly)
	return Basis(Vector3.RIGHT, deg_to_rad(_config.ring_tilt_deg)) * Vector3(x, 0.0, z)


func _configure_ring() -> void:
	var enabled: bool = _config.ring_enabled
	if not enabled:
		if is_instance_valid(ring_root):
			remove_child(ring_root)
			ring_root.queue_free()
		ring_root = null
		_dust_material = null
		_rock_instance = null
		ring_rock_count = 0
		_ring_signature.clear()
		return
	var inner_radius: float = maxf(_planet_radius * clampf(_config.ring_inner_ratio, 1.5, 2.6), _surface_radius * 1.05)
	var outer_radius: float = maxf(_planet_radius * clampf(_config.ring_outer_ratio, 2.8, 5.0), inner_radius + _planet_radius * 0.2)
	var signature: Array = [inner_radius, outer_radius, _detail, _config.seed]
	if ring_root == null or signature != _ring_signature:
		if is_instance_valid(ring_root):
			remove_child(ring_root)
			ring_root.queue_free()
		ring_root = Node3D.new()
		ring_root.name = "PlanetRings"
		ring_root.rotation.x = deg_to_rad(_config.ring_tilt_deg)
		add_child(ring_root)
		var dust := MeshInstance3D.new()
		dust.name = "DustBands"
		dust.mesh = _build_annulus(inner_radius, outer_radius, 256 if _detail == 2 else 144, 1)
		_dust_material = ShaderMaterial.new()
		_dust_material.shader = RING_SHADER
		dust.material_override = _dust_material
		_dust_material.render_priority = 2
		ring_root.add_child(dust)
		_rock_instance = _build_ring_rocks(inner_radius, outer_radius)
		ring_root.add_child(_rock_instance)
		_ring_signature = signature
	else:
		ring_root.rotation.x = deg_to_rad(_config.ring_tilt_deg)
	_ring_outer_m = outer_radius
	_dust_material.set_shader_parameter("planet_radius", _planet_radius)
	_dust_material.set_shader_parameter("density", clampf(_config.ring_density, 0.0, 1.0))
	_dust_material.set_shader_parameter("seed", float(_config.seed % 997))
	_dust_material.set_shader_parameter("sun_direction", _sun_direction)
	ring_rock_count = int(round([LOW_ROCK_COUNT, MEDIUM_ROCK_COUNT, HIGH_ROCK_COUNT][_detail] * clampf(_config.ring_rocks, 0.0, 1.0)))
	_rock_instance.visible = _config.ring_rocks > 0.01
	_rock_instance.multimesh.visible_instance_count = ring_rock_count if _rock_instance.visible else 0


func _build_ring_rocks(inner_radius: float, outer_radius: float) -> MultiMeshInstance3D:
	var base_count: int = [LOW_ROCK_COUNT, MEDIUM_ROCK_COUNT, HIGH_ROCK_COUNT][_detail]
	ring_rock_count = int(round(base_count * clampf(_config.ring_rocks, 0.0, 1.0)))
	var rock_mesh := SphereMesh.new()
	rock_mesh.radial_segments = 6
	rock_mesh.rings = 3
	rock_mesh.radius = 0.5
	rock_mesh.height = 1.0
	var rock_material := StandardMaterial3D.new()
	rock_material.albedo_color = Color(0.42, 0.37, 0.31)
	rock_material.roughness = 0.96
	rock_mesh.material = rock_material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = rock_mesh
	multimesh.instance_count = base_count
	multimesh.visible_instance_count = ring_rock_count
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_config.seed) ^ 0x4A71
	var radial_width: float = outer_radius - inner_radius
	for index: int in base_count:
		var angle: float = rng.randf_range(0.0, TAU)
		var orbit_radius: float = inner_radius + pow(rng.randf(), 0.78) * radial_width
		var position := Vector3(cos(angle) * orbit_radius, rng.randf_range(-0.045, 0.045) * _surface_radius, sin(angle) * orbit_radius)
		var size: float = _planet_radius * rng.randf_range(0.006, 0.025)
		var scale := Vector3(size * rng.randf_range(0.8, 1.6), size * rng.randf_range(0.35, 0.75), size * rng.randf_range(0.65, 1.25))
		var transform := Transform3D(Basis.from_euler(Vector3(rng.randf_range(0.0, TAU), angle, rng.randf_range(0.0, TAU))).scaled(scale), position)
		multimesh.set_instance_transform(index, transform)
	var instance := MultiMeshInstance3D.new()
	instance.name = "RingRocks"
	instance.multimesh = multimesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _build_annulus(inner_radius: float, outer_radius: float, angular_segments: int, radial_segments: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for radial_index: int in radial_segments + 1:
		var radial_t: float = float(radial_index) / float(radial_segments)
		var radius: float = lerpf(inner_radius, outer_radius, radial_t)
		for angular_index: int in angular_segments + 1:
			var angle_t: float = float(angular_index) / float(angular_segments)
			var angle: float = angle_t * TAU
			vertices.append(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
			uvs.append(Vector2(angle_t, radial_t))
	for radial_index: int in radial_segments:
		for angular_index: int in angular_segments:
			var a: int = radial_index * (angular_segments + 1) + angular_index
			var b: int = a + angular_segments + 1
			indices.append_array(PackedInt32Array([a, a + 1, b, a + 1, b + 1, b]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _configure_moons() -> void:
	var count: int = clampi(_config.moon_count, 0, 3)
	var size: float = clampf(_config.moon_size_ratio, 0.06, 0.3) * _planet_radius
	var signature: Array = [count, size, _detail, _config.seed]
	if signature != _moon_signature:
		for moon: MeshInstance3D in moon_nodes:
			remove_child(moon)
			moon.queue_free()
		moon_nodes.clear()
		_moon_phases.clear()
		var rng := RandomNumberGenerator.new()
		rng.seed = int(_config.seed) ^ 0x61C3
		for index: int in count:
			var moon := MeshInstance3D.new()
			moon.name = "Moon%d" % (index + 1)
			moon.mesh = _build_moon_mesh(size, index * 7919)
			var moon_material := StandardMaterial3D.new()
			moon_material.roughness = 0.96
			moon_material.albedo_color = Color(0.66, 0.62, 0.54).lerp(Color(0.48, 0.50, 0.51), rng.randf())
			moon.material_override = moon_material
			moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(moon)
			moon_nodes.append(moon)
			_moon_phases.append(rng.randf_range(0.0, TAU))
		_moon_signature = signature


func _build_moon_mesh(radius: float, profile_seed: int) -> ArrayMesh:
	var rings: int = [10, 15, 22][_detail]
	var segments: int = rings * 2
	var rng := RandomNumberGenerator.new()
	rng.seed = (int(_config.seed) ^ 0x2CA5) + profile_seed
	var crater_centers: Array[Vector3] = []
	var crater_sizes: Array[float] = []
	for crater_index: int in 18:
		crater_centers.append(Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).normalized())
		crater_sizes.append(rng.randf_range(0.045, 0.19))
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for latitude_index: int in rings:
		var v0: float = float(latitude_index) / float(rings)
		var v1: float = float(latitude_index + 1) / float(rings)
		for longitude_index: int in segments:
			var u0: float = float(longitude_index) / float(segments)
			var u1: float = float(longitude_index + 1) / float(segments)
			var p00: Vector3 = _moon_surface_point(u0, v0, radius, crater_centers, crater_sizes)
			var p10: Vector3 = _moon_surface_point(u1, v0, radius, crater_centers, crater_sizes)
			var p01: Vector3 = _moon_surface_point(u0, v1, radius, crater_centers, crater_sizes)
			var p11: Vector3 = _moon_surface_point(u1, v1, radius, crater_centers, crater_sizes)
			surface.add_vertex(p00)
			surface.add_vertex(p10)
			surface.add_vertex(p01)
			surface.add_vertex(p10)
			surface.add_vertex(p11)
			surface.add_vertex(p01)
	surface.generate_normals()
	var mesh := surface.commit() as ArrayMesh
	return mesh


func _moon_surface_point(u: float, v: float, radius: float, crater_centers: Array[Vector3], crater_sizes: Array[float]) -> Vector3:
	var latitude: float = (v - 0.5) * PI
	var longitude: float = u * TAU
	var direction := Vector3(cos(latitude) * cos(longitude), sin(latitude), cos(latitude) * sin(longitude))
	var displacement: float = 0.0
	for crater_index: int in crater_centers.size():
		var angular_distance: float = acos(clampf(direction.dot(crater_centers[crater_index]), -1.0, 1.0))
		var crater_radius: float = crater_sizes[crater_index]
		var crater_t: float = angular_distance / crater_radius
		if crater_t < 1.0:
			var bowl: float = 1.0 - smoothstep(0.0, 0.82, crater_t)
			var rim: float = exp(-pow((crater_t - 0.88) / 0.11, 2.0)) * 0.22
			displacement += crater_radius * radius * (-0.075 * bowl + 0.035 * rim)
	return direction * (radius + displacement)


func _update_moon_positions() -> void:
	for index: int in moon_nodes.size():
		var moon: MeshInstance3D = moon_nodes[index]
		moon.position = moon_position(index, elapsed)
		var radial_direction: Vector3 = moon.position.normalized()
		if radial_direction.length_squared() > 0.000001:
			var orbit_normal: Vector3 = Basis(Vector3.RIGHT, deg_to_rad(_config.ring_tilt_deg)) * Vector3.UP
			moon.basis = Basis.looking_at(-radial_direction, orbit_normal)


func _moon_semimajor_axis(index: int) -> float:
	var requested_axis: float = clampf(_config.moon_distance_ratio, 3.0, 8.0) * _planet_radius
	var moon_clearance: float = clampf(_config.moon_size_ratio, 0.06, 0.3) * _planet_radius + _planet_radius * 0.15
	var surface_clearance: float = _surface_radius + moon_clearance
	var minimum_clearance: float = maxf(surface_clearance, _ring_outer_m + moon_clearance) if _config.ring_enabled else surface_clearance
	var eccentricity: float = clampf(_config.moon_eccentricity, 0.0, 0.25)
	var base_axis: float = maxf(requested_axis, minimum_clearance / maxf(1.0 - eccentricity, 0.75))
	return base_axis + float(index) * 1.7 * _planet_radius


func _moon_phase(index: int) -> float:
	if index < _moon_phases.size():
		return _moon_phases[index]
	var rng := RandomNumberGenerator.new()
	rng.seed = (int(_config.seed) ^ 0x61C3) + index
	return rng.randf_range(0.0, TAU)
