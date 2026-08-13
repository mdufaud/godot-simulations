class_name OceanStorm extends RefCounted
## Weather dressing over the FFT ocean: an FBM cloud deck dished to the horizon
## (shader derived from the tornado demo) plus camera-facing lightning -- bolt
## mesh, fullscreen flash and point light. Everything is gated by a 0-1 mood the
## presets drive; at mood 0 it is a no-op over the clear sky.
##
## The storm owns the surface fog it fades, but not the underwater fog: set
## [member underwater] and read [member surface_fog_density] /
## [member surface_fog_color] to blend the two.

const CloudDeckBuilder := preload("res://scripts/ocean/cloud_deck_builder.gd")

## Where the strike may land, relative to the camera.
const STRIKE_RADIUS_M := Vector2(120.0, 420.0)
const CLOUD_BASE_M := 420.0

var sun: DirectionalLight3D
var world_env: WorldEnvironment
## Fullscreen flash goes here, above the 3D but below the menu.
var overlay_layer: CanvasLayer

var mood_target := 0.15
## Set by the host: while true the storm stops writing the environment fog, so
## the underwater tint owns it.
var underwater := false

var surface_fog_density := 0.0004
var surface_fog_color := Color(0.62, 0.72, 0.78)

var _mood := 0.0
var _cloud_mat: ShaderMaterial
var _light: OmniLight3D
var _flash_rect: ColorRect
var _bolt: MeshInstance3D
var _bolt_mesh: ImmediateMesh
var _timer := 4.0
var _energy := 0.0
var _pos := Vector3.ZERO
var _rng := RandomNumberGenerator.new()


func build(host: Node3D) -> void:
	assert(sun != null and world_env != null and overlay_layer != null,
		"OceanStorm: sun, world_env and overlay_layer must be assigned")
	surface_fog_density = world_env.environment.fog_density
	surface_fog_color = world_env.environment.fog_light_color

	_cloud_mat = CloudDeckBuilder.build(host, CLOUD_BASE_M, 0.0, Color(0, 0, 0, 0), false)[0]

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


func update(delta: float, camera: Camera3D) -> void:
	_mood = move_toward(_mood, mood_target, delta * 0.25)
	_cloud_mat.set_shader_parameter("cover", _mood)
	sun.light_energy = lerpf(1.9, 0.52, _mood)
	sun.light_color = Color(1, 0.98, 0.95).lerp(Color(0.72, 0.78, 0.9), _mood)
	# Darken the sky itself (it drives ambient + reflections): black-storm feel.
	var sky_mat: PhysicalSkyMaterial = world_env.environment.sky.sky_material
	sky_mat.energy_multiplier = lerpf(1.45, 0.45, _mood)
	# Storm light is an overcast dome, not a dimmed clear sky. Wave faces point
	# at the viewer (measured NdotV ~0.5), so they show albedo, not reflection:
	# with only the dimmed PhysicalSky left the sea goes black under a cloud
	# deck that never dims. Fading the sky ambient out for a flat storm grey
	# keeps it readable. sky_contribution 1.0 ignores ambient_light_color, so
	# this is a no-op at mood 0.
	world_env.environment.ambient_light_sky_contribution = lerpf(1.0, 0.2, _mood)
	world_env.environment.tonemap_exposure = lerpf(1.3, 1.08, _mood)
	surface_fog_density = lerpf(0.0004, 0.0006, _mood)
	# Storm murk must approach the SEA tone (~0.06 lum), not a sky grey: fog on
	# the sea at 1-2 km blends 50%+, and anything brighter than the water reads
	# as a pale band floating over the waves ("horizon through the sea").
	# aerial_perspective pulls fog colour toward the sky, so it must drop too.
	surface_fog_color = Color(0.62, 0.72, 0.78).lerp(Color(0.12, 0.14, 0.17), _mood)
	if not underwater:
		world_env.environment.fog_density = surface_fog_density
		world_env.environment.fog_light_color = surface_fog_color
	world_env.environment.fog_aerial_perspective = lerpf(0.5, 0.1, _mood)

	# Lightning, tornado-demo style: random strikes, flickery decay.
	if _mood > 0.65:
		_timer -= delta
		if _timer <= 0.0:
			_trigger(camera)
			_timer = _rng.randf_range(1.2, 5.0) / maxf(_mood, 0.1)
	_energy = maxf(_energy - delta * 6.0, 0.0)
	if _energy > 0.0 and _rng.randf() < 0.2:
		_energy = minf(_energy + _rng.randf() * 0.4, 1.0)
	_light.light_energy = _energy * 30.0
	_cloud_mat.set_shader_parameter("flash_intensity", _energy * 5.0)
	_cloud_mat.set_shader_parameter("flash_pos", _pos)
	_flash_rect.color.a = _energy * _energy * 0.3
	_bolt.visible = _energy > 0.55


func current_mood() -> float:
	return _mood


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
