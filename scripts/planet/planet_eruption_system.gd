class_name PlanetEruptionSystem extends Node3D

const DRAW_SHADER: Shader = preload("res://shaders/planet/planet_ejecta.gdshader")
const CAPACITIES: Array[int] = [96, 192, 320]

var active_count := 0
var capacity := 0
var emitted_count := 0
var elapsed := 0.0

var _config: PlanetConfig
var _centres := PackedVector4Array()
var _radius := 1.0
var _height_ratio := 0.18
var _signature: Array = []
var _draw: MultiMeshInstance3D
var _material: ShaderMaterial
var _positions := PackedVector3Array()
var _velocities := PackedVector3Array()
var _ages := PackedFloat32Array()
var _lifetimes := PackedFloat32Array()
var _sizes := PackedFloat32Array()
var _ground_radii := PackedFloat32Array()
var _spawn_accumulator := 0.0
var _rng := RandomNumberGenerator.new()


func start(config: PlanetConfig, centres: PackedVector4Array, radius: float,
		size_ratio: float, height_ratio: float, detail: int) -> void:
	if not config.validate().is_empty():
		push_error("PlanetEruptionSystem requires a valid PlanetConfig")
		return
	if centres.is_empty():
		stop()
		return
	var tier := clampi(detail, 0, CAPACITIES.size() - 1)
	var signature: Array = [centres, radius, size_ratio, height_ratio, tier, config.seed]
	if signature != _signature:
		stop()
		_config = config
		_centres = centres.duplicate()
		_radius = radius
		_height_ratio = height_ratio
		capacity = CAPACITIES[tier]
		_positions.resize(capacity)
		_velocities.resize(capacity)
		_ages.resize(capacity)
		_lifetimes.resize(capacity)
		_sizes.resize(capacity)
		_ground_radii.resize(capacity)
		_rng.seed = config.seed ^ 0x38A5
		var mesh := SphereMesh.new()
		mesh.radius = 1.0
		mesh.height = 2.0
		mesh.radial_segments = 6
		mesh.rings = 3
		_material = ShaderMaterial.new()
		_material.shader = DRAW_SHADER
		mesh.material = _material
		var instances := MultiMesh.new()
		instances.transform_format = MultiMesh.TRANSFORM_3D
		instances.use_custom_data = true
		instances.mesh = mesh
		instances.instance_count = capacity
		instances.visible_instance_count = 0
		_draw = MultiMeshInstance3D.new()
		_draw.multimesh = instances
		_draw.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var extent := 0.0
		for centre in _centres:
			extent = maxf(extent, centre.w)
		extent = radius * (extent + height_ratio * PlanetConfig.VOLCANO_FLOOR_FRACTION + 0.7)
		_draw.custom_aabb = AABB(Vector3.ONE * -extent, Vector3.ONE * extent * 2.0)
		add_child(_draw)
		_signature = signature
	_config = config
	_material.set_shader_parameter("lava_glow", config.lava_glow)
	_material.set_shader_parameter("activity", config.volcano_activity)


func stop() -> void:
	if _draw != null:
		remove_child(_draw)
		_draw.queue_free()
	_draw = null
	_material = null
	_config = null
	_centres.clear()
	_signature.clear()
	_positions.clear()
	_velocities.clear()
	_ages.clear()
	_lifetimes.clear()
	_sizes.clear()
	_ground_radii.clear()
	active_count = 0
	capacity = 0
	emitted_count = 0
	elapsed = 0.0
	_spawn_accumulator = 0.0


func advance(delta: float) -> void:
	if _draw == null or delta <= 0.0:
		return
	var duration := minf(delta, 0.25)
	var steps := maxi(1, int(ceil(duration / (1.0 / 30.0))))
	var dt := duration / float(steps)
	for step in steps:
		_advance_step(dt)
	for index in active_count:
		var age := _ages[index] / _lifetimes[index]
		var scale := _sizes[index] * lerpf(1.0, 0.65, age)
		_draw.multimesh.set_instance_transform(index,
			Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale), _positions[index]))
		_draw.multimesh.set_instance_custom_data(index, Color(age, 0.0, 0.0, 0.0))
	_draw.multimesh.visible_instance_count = active_count


func projectile_positions() -> PackedVector3Array:
	return _positions.slice(0, active_count)


func _advance_step(dt: float) -> void:
	elapsed += dt
	var index := 0
	while index < active_count:
		_ages[index] += dt
		_velocities[index] -= _positions[index].normalized() * (_radius * 0.8 * dt)
		_positions[index] += _velocities[index] * dt
		if _ages[index] >= _lifetimes[index] or (_ages[index] > 0.15
				and _positions[index].length() <= _ground_radii[index]):
			active_count -= 1
			_positions[index] = _positions[active_count]
			_velocities[index] = _velocities[active_count]
			_ages[index] = _ages[active_count]
			_lifetimes[index] = _lifetimes[active_count]
			_sizes[index] = _sizes[active_count]
			_ground_radii[index] = _ground_radii[active_count]
		else:
			index += 1
	if _config.eruption_rate_hz <= 0.0 or _config.volcano_activity <= 0.0:
		_spawn_accumulator = 0.0
		return
	_spawn_accumulator += dt * _config.eruption_rate_hz * _config.volcano_activity * _centres.size()
	while _spawn_accumulator >= 1.0 and active_count < capacity:
		_spawn_accumulator -= 1.0
		_spawn()
	_spawn_accumulator = minf(_spawn_accumulator, 1.0)


func _spawn() -> void:
	var centre := _centres[emitted_count % _centres.size()]
	var direction := Vector3(centre.x, centre.y, centre.z)
	var tangent := direction.cross(Vector3.UP).normalized()
	if tangent.length_squared() < 0.01:
		tangent = direction.cross(Vector3.RIGHT).normalized()
	var bitangent := direction.cross(tangent).normalized()
	var angle := _rng.randf_range(0.0, TAU)
	var spread := tangent * cos(angle) + bitangent * sin(angle)
	var phase := elapsed * 4.0 + direction.dot(Vector3(13.1, 27.7, 43.3))
	var surge := 0.5 + 0.5 * sin(phase)
	var jet := (direction + tangent * sin(phase * 0.7) * 0.08
		+ bitangent * cos(phase * 0.9) * 0.06).normalized()
	var ground_radius := _radius * (centre.w + _height_ratio * PlanetConfig.VOLCANO_FLOOR_FRACTION)
	_positions[active_count] = direction * (ground_radius + _radius * 0.012)
	_velocities[active_count] = _radius * (jet * _rng.randf_range(0.45, 0.70) * lerpf(0.85, 1.15, surge)
		+ spread * _rng.randf_range(0.07, 0.22))
	_ages[active_count] = 0.0
	_lifetimes[active_count] = _rng.randf_range(1.6, 2.4)
	_sizes[active_count] = _radius * _rng.randf_range(0.006, 0.013)
	_ground_radii[active_count] = ground_radius
	active_count += 1
	emitted_count += 1
