class_name OceanStorm extends RefCounted

## Where the strike may land, relative to the camera.
const STRIKE_RADIUS_M := Vector2(120.0, 420.0)
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var sky_material: ShaderMaterial
var cloudscape: OceanCloudscape
## Fullscreen flash goes here, above the 3D but below the menu.
var overlay_layer: CanvasLayer

var mood_target := 0.0
var lightning_enabled := true
## Set by the host: while true the storm stops writing the environment fog, so
## the underwater tint owns it.
var underwater := false

var surface_fog_density := 0.0004
var surface_fog_color := Color(0.62, 0.72, 0.78)

var _mood := 0.0
var _applied_mood := -1.0
var _look: OceanLookPreset
var _light: OmniLight3D
var _flash_rect: ColorRect
var _bolt: MeshInstance3D
var _bolt_mesh: ImmediateMesh
var _rain_material: ShaderMaterial
var _rain_instance: MultiMeshInstance3D
var _rain_enabled := true
var _rain_intensity := 0.0
var _rain_center := Vector3.ZERO
var _rain_wind := Vector3(1.0, 0.0, 0.0)
var _rain_time := 0.0
var _timer := 4.0
var _energy := 0.0
var _pos := Vector3.ZERO
var _rng := RandomNumberGenerator.new()


func build(host: Node3D) -> void:
	assert(sun != null and world_env != null and overlay_layer != null,
		"OceanStorm: sun, world_env and overlay_layer must be assigned")
	surface_fog_density = world_env.environment.fog_density
	surface_fog_color = world_env.environment.fog_light_color

	_light = OmniLight3D.new()
	_light.light_energy = 0.0
	_light.omni_range = 500.0
	_light.omni_attenuation = 1.4
	_light.light_color = Color(0.82, 0.87, 1.0)
	_light.shadow_enabled = false
	host.add_child(_light)

	_flash_rect = ColorRect.new()
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.color = Color(0.8, 0.85, 1.0, 0.0)
	overlay_layer.add_child(_flash_rect)

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
	_bolt.material_override = mat
	_bolt.visible = false
	host.add_child(_bolt)

	var rain_quad := QuadMesh.new()
	rain_quad.size = Vector2(1.0, 1.0)
	var rain_multimesh := MultiMesh.new()
	rain_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	rain_multimesh.mesh = rain_quad
	rain_multimesh.instance_count = 192 * 80
	for i in rain_multimesh.instance_count:
		rain_multimesh.set_instance_transform(i, Transform3D.IDENTITY)
	_rain_material = ShaderMaterial.new()
	_rain_material.shader = load("res://shaders/ocean/ocean_rain.gdshader")
	_rain_instance = MultiMeshInstance3D.new()
	_rain_instance.name = "StormRain"
	_rain_instance.multimesh = rain_multimesh
	_rain_instance.material_override = _rain_material
	_rain_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rain_instance.custom_aabb = AABB(Vector3(-120.0, -50.0, -100.0),
		Vector3(240.0, 120.0, 200.0))
	_rain_instance.visible = false
	host.add_child(_rain_instance)


func apply_look(look: OceanLookPreset) -> void:
	_look = look
	_rain_intensity = look.rain_intensity
	if _rain_material != null:
		_rain_material.set_shader_parameter("rain_intensity", _rain_intensity)
	_applied_mood = -1.0
	_apply_environment()


func update(delta: float, camera: Camera3D) -> void:
	_mood = move_toward(_mood, mood_target, delta * 0.25)
	_apply_environment()
	if camera != null and _rain_material != null:
		_rain_center = camera.global_position
		_rain_instance.global_position = _rain_center
		_rain_material.set_shader_parameter("volume_center", _rain_center)
		_rain_material.set_shader_parameter("wind_direction", _rain_wind)
		_rain_material.set_shader_parameter("storm_mood", _mood)
		_rain_material.set_shader_parameter("sim_time", _rain_time)
		_rain_instance.visible = _rain_enabled and not underwater \
			and _rain_intensity > 0.001 and _mood > 0.05

	# Lightning, tornado-demo style: random strikes, flickery decay.
	if lightning_enabled and _mood > 0.65:
		_timer -= delta
		if _timer <= 0.0:
			_trigger(camera)
			_timer = _rng.randf_range(1.2, 5.0) / maxf(_mood, 0.1)
	_energy = maxf(_energy - delta * 6.0, 0.0)
	if _energy > 0.0 and _rng.randf() < 0.2:
		_energy = minf(_energy + _rng.randf() * 0.4, 1.0)
	_light.light_energy = _energy * 30.0
	if cloudscape != null:
		cloudscape.set_lightning(_pos, _energy)
	_flash_rect.color.a = _energy * _energy * 0.3
	_bolt.visible = _energy > 0.55


func set_mood_immediate(value: float) -> void:
	_mood = clampf(value, 0.0, 1.0)
	mood_target = _mood
	_energy = 0.0
	_bolt.visible = false
	_apply_environment()
	if _rain_material != null:
		_rain_material.set_shader_parameter("storm_mood", _mood)


func current_mood() -> float:
	return _mood


func set_rain_wind(direction: Vector3) -> void:
	_rain_wind = direction.normalized()


func set_rain_time(value: float) -> void:
	_rain_time = value


func set_render_features(on: bool) -> void:
	_rain_enabled = on
	lightning_enabled = on
	if not on:
		_energy = 0.0
		_light.light_energy = 0.0
		_bolt.visible = false
		_flash_rect.color.a = 0.0
	if _rain_instance != null:
		_rain_instance.visible = on and not underwater and _mood > 0.05


func set_capture_rain(on: bool) -> void:
	_rain_enabled = on
	if _rain_instance != null:
		_rain_instance.visible = on and not underwater and _mood > 0.05


func _apply_environment() -> void:
	if _look == null or is_equal_approx(_mood, _applied_mood):
		return
	_applied_mood = _mood
	var env := world_env.environment
	var cold_zenith := Color(0.045, 0.075, 0.075)
	var cold_horizon := Color(0.18, 0.24, 0.21)
	var cold_haze := Color(0.13, 0.17, 0.15)
	sun.light_energy = lerpf(_look.sun_energy, _look.sun_energy * 0.55, _mood)
	sun.light_color = _look.sun_color.lerp(Color(0.72, 0.76, 0.78), _mood)
	sky_material.set_shader_parameter("zenith_color", _look.sky_zenith.lerp(cold_zenith, _mood))
	sky_material.set_shader_parameter("horizon_color", _look.sky_horizon.lerp(cold_horizon, _mood))
	sky_material.set_shader_parameter("haze_color", _look.haze_color.lerp(cold_haze, _mood))
	sky_material.set_shader_parameter("sun_color",
		_look.sun_disk_color.lerp(Color(0.26, 0.34, 0.42), _mood))
	sky_material.set_shader_parameter("energy", lerpf(_look.sky_energy, 0.62, _mood))
	sky_material.set_shader_parameter("storm_mood", _mood)
	env.ambient_light_sky_contribution = lerpf(1.0, 0.58, _mood)
	env.tonemap_exposure = lerpf(_look.exposure, maxf(_look.exposure * 0.82, 0.82), _mood)
	surface_fog_density = lerpf(_look.fog_density, maxf(_look.fog_density, 0.001), _mood)
	surface_fog_color = _look.fog_color.lerp(Color(0.1, 0.15, 0.17), _mood)
	if not underwater:
		env.fog_density = surface_fog_density
		env.fog_light_color = surface_fog_color
	env.fog_aerial_perspective = lerpf(_look.fog_aerial_perspective, 0.34, _mood)
	if cloudscape != null:
		cloudscape.apply_look(_look, _mood)


func _trigger(camera: Camera3D) -> void:
	if camera == null:
		return
	var ang := _rng.randf_range(0.0, TAU)
	var rad := _rng.randf_range(STRIKE_RADIUS_M.x, STRIKE_RADIUS_M.y)
	_pos = camera.global_position + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	_pos.y = _rng.randf_range(280.0, 380.0)
	_energy = 1.0
	_light.global_position = Vector3(_pos.x, 140.0, _pos.z)
	_build_bolt_mesh(camera)


## Camera-facing jittered triangle strip from cloud base to the water.
func _build_bolt_mesh(camera: Camera3D) -> void:
	var bottom := Vector3(
		_pos.x + _rng.randf_range(-25.0, 25.0), 0.0,
		_pos.z + _rng.randf_range(-25.0, 25.0)
	)
	var view := (camera.global_position - _pos).normalized()
	var axis := bottom - _pos
	var side := axis.cross(view).normalized() * 2.5
	var segs := 11
	_bolt_mesh.clear_surfaces()
	_bolt_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in segs + 1:
		var t := float(i) / segs
		var p := _pos + axis * t
		if i > 0 and i < segs:
			p += side.normalized() * _rng.randf_range(-14.0, 14.0)
			p += view.cross(side).normalized() * _rng.randf_range(-6.0, 6.0)
		var w := side * (1.0 - 0.5 * t)
		_bolt_mesh.surface_add_vertex(p - w)
		_bolt_mesh.surface_add_vertex(p + w)
	_bolt_mesh.surface_end()
