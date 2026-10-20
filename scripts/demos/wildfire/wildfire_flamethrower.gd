class_name WildfireFlamethrower extends Node3D
## The flamethrower's visible stream and what it sets alight. Flame-lick
## particles leave the muzzle fast, slow down, swell and rise, drift with the
## wind and slide along the ground on GPU particle collision; the grid cells the
## stream reaches take fire damage every frame. The stream lives outside the
## weapon so flames already thrown finish their flight when it is holstered.

## Reach: v0^2 / (2 * damping) ~ 12 m, of which a 0.9 s lifetime covers ~9 m.
const SPEED_MPS := 14.0
const DAMPING_MPS2 := 8.0
const REACH_M := 9.0
const LIFETIME_S := 0.9
const DAMAGE_PER_S := 90.0
## The stream keeps sliding past where it lands: the next cell along takes half.
const SPLASH_M := 1.2
const LIFT := Vector3(0.0, 1.5, 0.0)
const WIND_DRAG := 1.0

var firing := false

var _grid: CellPropagation
var _system: WildfireSystem
var _muzzle: Node3D
var _stream_process: ParticleProcessMaterial
var _stream: GPUParticles3D
var _light: OmniLight3D
var _light_level := 0.0
var _time := 0.0


func setup(grid: CellPropagation, muzzle: Node3D, system: WildfireSystem) -> void:
	_grid = grid
	_system = system
	_muzzle = muzzle
	_stream_process = ParticleProcessMaterial.new()
	_stream_process.direction = Vector3(0.0, 0.0, -1.0)
	_stream_process.spread = 4.0
	_stream_process.initial_velocity_min = SPEED_MPS * 0.9
	_stream_process.initial_velocity_max = SPEED_MPS
	_stream_process.damping_min = DAMPING_MPS2
	_stream_process.damping_max = DAMPING_MPS2
	_stream_process.gravity = LIFT
	_stream_process.scale_min = 0.8
	_stream_process.scale_max = 1.2
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.3))
	curve.add_point(Vector2(0.35, 0.6))
	curve.add_point(Vector2(1.0, 1.0))
	_stream_process.scale_curve = CurveTexture.new()
	(_stream_process.scale_curve as CurveTexture).curve = curve
	_stream_process.angle_min = -180.0
	_stream_process.angle_max = 180.0
	_stream_process.anim_offset_max = 1.0
	_stream_process.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	_stream_process.collision_friction = 0.6
	_stream_process.collision_bounce = 0.0

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * 1.4
	quad.material = system.sprite_material(WildfireSystem.FLAME_CELLS,
		Color(1.3, 1.2, 1.1), Color(1.0, 0.45, 0.2), 2.5, 0.5, 0.6, 0.08, 1)
	# Visible right out of the nozzle, so the jet reads as one rope of fire.
	(quad.material as ShaderMaterial).set_shader_parameter("fade_in", 0.02)
	_stream = GPUParticles3D.new()
	_stream.process_material = _stream_process
	_stream.draw_pass_1 = quad
	# 60 Hz steps and a dense stream: at 14 m/s a 30 Hz step leaves 0.5 m gaps.
	_stream.amount = 160
	_stream.fixed_fps = 60
	_stream.lifetime = LIFETIME_S
	_stream.emitting = false
	_stream.collision_base_size = 0.1
	_stream.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_stream.visibility_aabb = AABB(Vector3(-REACH_M, -4.0, -REACH_M - 2.0),
		Vector3(REACH_M * 2.0, 10.0, REACH_M * 2.0 + 4.0))
	add_child(_stream)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.55, 0.2)
	_light.omni_range = 7.0
	_light.visible = false
	add_child(_light)


func set_firing(on: bool) -> void:
	firing = on
	if on:
		_stream.global_transform = _muzzle.global_transform
	_stream.emitting = on


func _process(delta: float) -> void:
	var gravity := LIFT + _system.wind_vector() * WIND_DRAG
	if not _stream_process.gravity.is_equal_approx(gravity):
		_stream_process.gravity = gravity
	# The light lingers while the last flames are still in flight.
	_light_level = 1.0 if firing else maxf(_light_level - delta / LIFETIME_S, 0.0)
	_light.visible = _light_level > 0.0
	if not firing:
		if _light.visible:
			_light.light_energy = 3.5 * _light_level
		return
	_time += delta
	_stream.global_transform = _muzzle.global_transform
	_light.global_position = _muzzle.to_global(Vector3(0.0, 0.0, -2.0))
	_light.light_energy = 3.5 + 0.8 * sin(_time * 31.0) + 0.4 * sin(_time * 53.0)
	var from := _stream.global_position
	var forward := -_stream.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(from, from + forward * REACH_M)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	_grid.ignite_at(hit.position, DAMAGE_PER_S * delta)
	var along := Vector3(forward.x, 0.0, forward.z)
	if along.length() > 0.01:
		_grid.ignite_at(hit.position + along.normalized() * SPLASH_M,
			DAMAGE_PER_S * 0.5 * delta)
