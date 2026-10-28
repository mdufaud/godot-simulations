class_name AmbientFluidBody3D
extends RigidBody3D

const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")
## Sec. 5.4: substeps keep ||w|| dt below 0.1 rad.
const MAX_ROTATION_STEP_RAD := 0.1
const MAX_SUBSTEPS := 64

@export var profile: AmbientFluidProfile3D
@export var config: AmbientFluidConfig
@export var fluid_enabled: bool = true
@export var contacts_enabled: bool = false
@export var body_inertia_diagonal_kg_m2: Vector3 = Vector3.ZERO
var profiling := false

var _body_tensor := PackedFloat64Array()
var _combined_tensor := PackedFloat64Array()
var _combined_inverse := PackedFloat64Array()
var _cached_mass := NAN
var _cached_fluid_density := NAN
var _cached_inertia := Vector3(NAN, NAN, NAN)
var _cache_valid := false
var _derived_inertia := false
var _invalid_state_reported := false
var _invalid_medium_reported := false
var _last_pressure_wrench := PackedFloat64Array()
var _last_friction_wrench := PackedFloat64Array()
var _last_surface_faces := 0
var _last_surface_cpu_us := 0
var _last_integration_cpu_us := 0
var _last_substeps := 1
var _last_generalized_velocity := PackedFloat64Array()
var _last_wrench_generalized_velocity := PackedFloat64Array()
var _contact_bodies: Dictionary = {}
var _true_state_valid := false
var _last_end_basis := Basis.IDENTITY
var _last_end_origin := Vector3.ZERO
var _last_physics_frame := -1
var _true_linear_velocity_world := Vector3.ZERO
var _true_angular_velocity_world := Vector3.ZERO
var _given_linear_velocity_world := Vector3.ZERO
var _given_angular_velocity_world := Vector3.ZERO
var _last_fluid_density := NAN
var _last_added_mass_density := NAN
var _contacts_connected := false
var _pending_reset := false
var _pending_transform := Transform3D.IDENTITY
var _pending_linear_velocity_world := Vector3.ZERO
var _pending_angular_velocity_world := Vector3.ZERO
var _pending_central_impulse_world := Vector3.ZERO
var _pending_torque_impulse_world := Vector3.ZERO
var medium_velocity_sampler: Callable
var medium_density_sampler: Callable
var pool_buoyancy_faces_local := PackedVector3Array()
var pool_surface_height_world := NAN
var pool_buoyancy_enabled := false
var submerged_volume_m3 := 0.0
var submerged_fraction := 0.0
var wetted_area_fraction := 0.0
var center_of_buoyancy_local := Vector3.ZERO
var waterline_points_local := PackedVector3Array()
var wet_area_fractions := PackedFloat64Array()
var wet_area_centers_m := PackedVector3Array()


func _ready() -> void:
	if config == null:
		config = AmbientFluidConfig.new()
	if profile == null:
		push_error("AmbientFluidBody3D: profile is required")
		return
	var profile_error := profile.validate()
	if profile_error != "":
		push_error("AmbientFluidBody3D profile: %s" % profile_error)
		return
	var config_error := config.validate()
	if config_error != "":
		push_error("AmbientFluidBody3D config: %s" % config_error)
		return
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3.ZERO
	gravity_scale = 1.0
	custom_integrator = true
	linear_damp = 0.0
	angular_damp = 0.0
	_configure_contacts()
	mass = config.body_density_kg_m3 * profile.volume_m3
	if body_inertia_diagonal_kg_m2.x <= 0.0 or body_inertia_diagonal_kg_m2.y <= 0.0 \
		or body_inertia_diagonal_kg_m2.z <= 0.0:
		body_inertia_diagonal_kg_m2 = _profile_inertia()
		_derived_inertia = true
	if not _finite_vector(body_inertia_diagonal_kg_m2) \
		or body_inertia_diagonal_kg_m2.x <= 0.0 \
		or body_inertia_diagonal_kg_m2.y <= 0.0 \
		or body_inertia_diagonal_kg_m2.z <= 0.0:
		push_error("AmbientFluidBody3D: body inertia must be finite and positive")
		return
	inertia = body_inertia_diagonal_kg_m2
	_rebuild_tensors()
	_last_pressure_wrench.resize(MATH.MATRIX_SIZE)
	_last_friction_wrench.resize(MATH.MATRIX_SIZE)
	_last_generalized_velocity.resize(MATH.MATRIX_SIZE)
	_last_wrench_generalized_velocity.resize(MATH.MATRIX_SIZE)
	reset_state(global_transform, config.initial_velocity_m_s, config.initial_spin_rad_s)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not profiling:
		_integrate_forces_impl(state)
		_last_integration_cpu_us = 0
		return
	var integration_start_us := Time.get_ticks_usec()
	_integrate_forces_impl(state)
	_last_integration_cpu_us = Time.get_ticks_usec() - integration_start_us


func _integrate_forces_impl(state: PhysicsDirectBodyState3D) -> void:
	# Algorithm 2 of Padilla et al.: momentum from K (Eq. 1), the wrench of
	# Eq. 4 (gyroscopic terms, gravity and buoyancy, surface forces), a momentum
	# step, velocities from K^-1, then the pose. The pose is integrated here,
	# substep by substep, and Jolt is handed the constant velocities that carry
	# it from the start pose to the same end pose in one tick; the body's true
	# end velocity is kept between ticks, and anything Jolt changed meanwhile
	# (contacts, a script setting the velocity) arrives as a velocity delta.
	var physics_frame := Engine.get_physics_frames()
	var carried := _true_state_valid and physics_frame == _last_physics_frame + 1
	_last_physics_frame = physics_frame
	_true_state_valid = false
	if _pending_reset:
		state.transform = _pending_transform
		state.linear_velocity = _pending_linear_velocity_world
		state.angular_velocity = _pending_angular_velocity_world
		_pending_reset = false
		carried = false
	var jolt_basis := state.transform.basis
	var jolt_origin := state.transform.origin
	if not _basis_is_valid(jolt_basis):
		_report_invalid_state("body basis is not finite and orthonormal")
		return
	var basis := jolt_basis
	var origin := jolt_origin
	var linear_world := state.linear_velocity
	var angular_world := state.angular_velocity
	if carried:
		var linear_change := state.linear_velocity - _given_linear_velocity_world
		var angular_change := state.angular_velocity - _given_angular_velocity_world
		linear_world = _true_linear_velocity_world + linear_change
		angular_world = _true_angular_velocity_world + angular_change
		# Left alone, Jolt lands within rounding of the internal end pose (the
		# float axis-angle hand-off of a small turn loses ~1e-5 rad). Continue
		# from the internal pose then, so that rounding cannot accumulate; any
		# contact, push or teleport hands the pose back to Jolt.
		if linear_change == Vector3.ZERO and angular_change == Vector3.ZERO \
				and jolt_origin.distance_squared_to(_last_end_origin) < 1.0e-6 \
				and (jolt_basis.x - _last_end_basis.x).length_squared() \
					+ (jolt_basis.y - _last_end_basis.y).length_squared() \
					+ (jolt_basis.z - _last_end_basis.z).length_squared() < 1.0e-6:
			basis = _last_end_basis
			origin = _last_end_origin
	if not _finite_vector(linear_world) or not _finite_vector(angular_world):
		_report_invalid_state("body velocity is not finite")
		return
	var fluid_density := _sample_fluid_density(origin)
	if not is_finite(fluid_density) or fluid_density < 0.0:
		if not _invalid_medium_reported:
			_invalid_medium_reported = true
			push_error("AmbientFluidBody3D: medium density sampler returned an invalid value")
		fluid_density = 0.0
	var immersion := _sample_pool_immersion(basis, origin)
	var effective_added_mass_density := fluid_density * float(immersion.fraction)
	var previous_tensor := _combined_tensor
	var previous_fluid_density := _last_fluid_density
	var previous_added_mass_density := _last_added_mass_density
	_ensure_tensor_cache(effective_added_mass_density)
	if not _cache_valid:
		return
	_last_fluid_density = fluid_density
	_last_added_mass_density = effective_added_mass_density
	var fluid_velocity_world := _sample_fluid_velocity(origin)
	var local_velocity := basis.transposed() * (linear_world - fluid_velocity_world)
	var local_spin := basis.transposed() * angular_world
	var generalized_velocity := PackedFloat64Array([
		local_spin.x, local_spin.y, local_spin.z,
		local_velocity.x, local_velocity.y, local_velocity.z,
	])
	if carried and fluid_density == previous_fluid_density \
			and effective_added_mass_density != previous_added_mass_density \
			and previous_tensor.size() == MATH.MATRIX_SCALARS:
		generalized_velocity = MATH.added_mass_transition(generalized_velocity,
			previous_tensor, _combined_tensor, _combined_inverse)
	var momentum := MATH.matrix_vector_multiply(_combined_tensor, generalized_velocity)
	if _pending_torque_impulse_world != Vector3.ZERO \
		or _pending_central_impulse_world != Vector3.ZERO:
		var local_torque_impulse := basis.transposed() * _pending_torque_impulse_world
		var local_central_impulse := basis.transposed() * _pending_central_impulse_world
		momentum = MATH.vector_add(momentum, PackedFloat64Array([
			local_torque_impulse.x, local_torque_impulse.y, local_torque_impulse.z,
			local_central_impulse.x, local_central_impulse.y, local_central_impulse.z,
		]))
		_pending_torque_impulse_world = Vector3.ZERO
		_pending_central_impulse_world = Vector3.ZERO
	_last_surface_cpu_us = 0
	var substeps := clampi(ceili(local_spin.length() * state.step / MAX_ROTATION_STEP_RAD), 1,
		MAX_SUBSTEPS)
	_last_substeps = substeps
	var context := {
		fluid_density = fluid_density,
		gravity = state.total_gravity,
		medium_velocity = fluid_velocity_world,
	}
	var step := {basis = basis, origin = origin, momentum = momentum}
	var substep := state.step / float(substeps)
	for _index in substeps:
		if substeps == 1:
			step = _symplectic_euler_step(step, substep, context)
		else:
			step = _runge_kutta_step(step, substep, context)
		if step.is_empty():
			return
	var end_basis: Basis = step.basis
	var end_origin: Vector3 = step.origin
	var next_velocity := MATH.matrix_vector_multiply(_combined_inverse, step.momentum)
	if not _finite_array(next_velocity) or not _basis_is_valid(end_basis) \
		or not _finite_vector(end_origin):
		_report_invalid_state("integrated state is not finite")
		return
	_last_generalized_velocity = next_velocity
	_last_end_basis = end_basis
	_true_angular_velocity_world = end_basis * Vector3(next_velocity[0], next_velocity[1],
		next_velocity[2])
	_true_linear_velocity_world = end_basis * Vector3(next_velocity[3], next_velocity[4],
		next_velocity[5]) + fluid_velocity_world
	_last_end_origin = end_origin
	var turn := (end_basis * jolt_basis.transposed()).get_rotation_quaternion()
	var angle := turn.get_angle()
	var axis := turn.get_axis() if angle > 1.0e-9 else Vector3.ZERO
	if angle > PI:
		angle = TAU - angle
		axis = -axis
	_given_angular_velocity_world = axis * (angle / state.step)
	_given_linear_velocity_world = (end_origin - jolt_origin) / state.step
	state.angular_velocity = _given_angular_velocity_world
	state.linear_velocity = _given_linear_velocity_world
	# Read back: Jolt stores (and may clamp) what it was given.
	_given_angular_velocity_world = state.angular_velocity
	_given_linear_velocity_world = state.linear_velocity
	_true_state_valid = true


## One symplectic Euler step with the Lie-group rotation update (Alg. 2):
## the momentum takes the wrench kick, the body turns at the kicked angular
## velocity, then moves at its end velocity (so the velocity Jolt is handed is
## the body's true end velocity). Turning the momentum into the new body frame
## applies the l x w and p x w terms of Eq. 4 exactly and keeps |l| a Casimir;
## the turn uses the velocity of a half-turned trial state (Lie-group midpoint),
## so a free top's energy holds to second order instead of drifting.
func _symplectic_euler_step(step: Dictionary, delta: float, context: Dictionary) -> Dictionary:
	var basis: Basis = step.basis
	var momentum: PackedFloat64Array = step.momentum
	var velocity := MATH.matrix_vector_multiply(_combined_inverse, momentum)
	if not _finite_array(velocity):
		_report_invalid_state("substep velocity is not finite")
		return {}
	var wrench := MATH.vector_add(_external_wrench(basis, step.origin, velocity, context),
		MATH.semidirect_coupling_wrench(momentum, velocity))
	var forced := MATH.semi_implicit_momentum_step(momentum, wrench, delta)
	var forced_velocity := MATH.matrix_vector_multiply(_combined_inverse, forced)
	if not _finite_array(forced_velocity):
		_report_invalid_state("substep momentum is not finite")
		return {}
	var trial_turn := _rotation_increment(Vector3(forced_velocity[0], forced_velocity[1],
		forced_velocity[2]), delta * 0.5)
	var midpoint := MATH.matrix_vector_multiply(_combined_inverse,
		_rotate_generalized_momentum(forced, trial_turn.transposed()))
	if not _finite_array(midpoint):
		_report_invalid_state("substep momentum is not finite")
		return {}
	var rotation_increment := _rotation_increment(Vector3(midpoint[0], midpoint[1],
		midpoint[2]), delta)
	var end_basis := (basis * rotation_increment).orthonormalized()
	var end_momentum := _rotate_generalized_momentum(forced, rotation_increment.transposed())
	var end_velocity := MATH.matrix_vector_multiply(_combined_inverse, end_momentum)
	var linear_world: Vector3 = end_basis * Vector3(end_velocity[3], end_velocity[4],
		end_velocity[5]) + context.medium_velocity
	return {
		basis = end_basis,
		origin = step.origin + linear_world * delta,
		momentum = end_momentum,
	}


## Classical RK4 on (q, y, l, p) with the full gyroscopic terms of Eq. 4, used
## when the spin needs substeps (Sec. 5.4).
func _runge_kutta_step(step: Dictionary, delta: float, context: Dictionary) -> Dictionary:
	var orientation: Quaternion = (step.basis as Basis).get_rotation_quaternion()
	var origin: Vector3 = step.origin
	var momentum: PackedFloat64Array = step.momentum
	var k1 := _state_derivative(orientation, origin, momentum, context)
	if k1.is_empty():
		return {}
	var k2 := _state_derivative((orientation + k1.orientation * (delta * 0.5)).normalized(),
		origin + k1.origin * (delta * 0.5),
		MATH.vector_add(momentum, MATH.vector_scale(k1.momentum, delta * 0.5)), context)
	if k2.is_empty():
		return {}
	var k3 := _state_derivative((orientation + k2.orientation * (delta * 0.5)).normalized(),
		origin + k2.origin * (delta * 0.5),
		MATH.vector_add(momentum, MATH.vector_scale(k2.momentum, delta * 0.5)), context)
	if k3.is_empty():
		return {}
	var k4 := _state_derivative((orientation + k3.orientation * delta).normalized(),
		origin + k3.origin * delta,
		MATH.vector_add(momentum, MATH.vector_scale(k3.momentum, delta)), context)
	if k4.is_empty():
		return {}
	var sixth := delta / 6.0
	var orientation_rate: Quaternion = k1.orientation + (k2.orientation + k3.orientation) * 2.0 \
		+ k4.orientation
	var origin_rate: Vector3 = k1.origin + (k2.origin + k3.origin) * 2.0 + k4.origin
	var momentum_rate := MATH.vector_add(MATH.vector_add(k1.momentum, k4.momentum),
		MATH.vector_scale(MATH.vector_add(k2.momentum, k3.momentum), 2.0))
	return {
		basis = Basis((orientation + orientation_rate * sixth).normalized()),
		origin = origin + origin_rate * sixth,
		momentum = MATH.vector_add(momentum, MATH.vector_scale(momentum_rate, sixth)),
	}


## d/dt of (q, y, l, p): q' = q w / 2, y' = R v + medium (Eq. 3), and Eq. 4.
func _state_derivative(orientation: Quaternion, origin: Vector3,
		momentum: PackedFloat64Array, context: Dictionary) -> Dictionary:
	var velocity := MATH.matrix_vector_multiply(_combined_inverse, momentum)
	if not _finite_array(velocity):
		_report_invalid_state("substep velocity is not finite")
		return {}
	var basis := Basis(orientation)
	var spin := Vector3(velocity[0], velocity[1], velocity[2])
	var linear := Vector3(velocity[3], velocity[4], velocity[5])
	var wrench := MATH.vector_add(_external_wrench(basis, origin, velocity, context),
		MATH.gyroscopic_wrench(momentum, velocity))
	return {
		orientation = orientation * Quaternion(spin.x, spin.y, spin.z, 0.0) * 0.5,
		origin = basis * linear + context.medium_velocity,
		momentum = wrench,
	}


## Gravity and buoyancy (Eq. 21) plus the surface forces (Eq. 20, 22) on the
## body at (basis, origin) moving at the medium-relative velocity, in the body
## frame. Records the surface diagnostics of the latest evaluation.
func _external_wrench(basis: Basis, origin: Vector3, velocity: PackedFloat64Array,
		context: Dictionary) -> PackedFloat64Array:
	var fluid_density: float = context.fluid_density
	var immersion := _sample_pool_immersion(basis, origin)
	var displaced_mass := fluid_density * float(immersion.volume_m3) \
		if pool_buoyancy_enabled else fluid_density * profile.volume_m3
	var wrench := MATH.gravity_buoyancy_wrench(mass, displaced_mass,
		basis.transposed() * (context.gravity as Vector3), immersion.centroid_m)
	_last_wrench_generalized_velocity = velocity
	_last_surface_faces = 0
	if fluid_density <= 0.0:
		_last_pressure_wrench = PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
		_last_friction_wrench = PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
		return wrench
	var surface_start_us := Time.get_ticks_usec()
	var surface := MATH.surface_wrench(profile.face_centers_m, profile.face_normals,
		profile.face_areas_m2, velocity, fluid_density, config.dynamic_viscosity_pa_s,
		config.separation_angle_rad, profile.surface_length_m(),
		immersion.wet_area_fractions if pool_buoyancy_enabled else PackedFloat64Array(),
		immersion.wet_area_centers_m if pool_buoyancy_enabled else PackedVector3Array())
	_last_pressure_wrench = surface.pressure
	_last_friction_wrench = surface.friction
	_last_surface_faces = int(surface.attached_faces)
	_last_surface_cpu_us += Time.get_ticks_usec() - surface_start_us
	return MATH.vector_add(wrench, MATH.vector_add(surface.pressure, surface.friction))


func set_fluid_enabled(enabled: bool) -> void:
	fluid_enabled = enabled
	_last_pressure_wrench.fill(0.0)
	_last_friction_wrench.fill(0.0)
	_last_surface_faces = 0
	_last_surface_cpu_us = 0
	sleeping = false
	_rebuild_tensors()


func set_profile(value: AmbientFluidProfile3D) -> void:
	if value == null:
		push_error("AmbientFluidBody3D: profile is required")
		return
	var profile_error := value.validate()
	if profile_error != "":
		push_error("AmbientFluidBody3D profile: %s" % profile_error)
		return
	profile = value
	mass = config.body_density_kg_m3 * profile.volume_m3
	if _derived_inertia:
		body_inertia_diagonal_kg_m2 = _profile_inertia()
		inertia = body_inertia_diagonal_kg_m2
	sleeping = false
	_rebuild_tensors()


func set_contacts_enabled(enabled: bool) -> void:
	contacts_enabled = enabled
	_configure_contacts()
	sleeping = false


func set_fluid_density_kg_m3(value: float) -> void:
	if not is_finite(value) or value < 0.0:
		push_error("AmbientFluidBody3D: fluid density must be finite and non-negative")
		return
	config.fluid_density_kg_m3 = value
	sleeping = false
	_rebuild_tensors()


func set_dynamic_viscosity_pa_s(value: float) -> void:
	if not is_finite(value) or value < 0.0:
		push_error("AmbientFluidBody3D: dynamic viscosity must be finite and non-negative")
		return
	config.dynamic_viscosity_pa_s = value
	sleeping = false


func set_separation_angle_rad(value: float) -> void:
	if not is_finite(value) or value < PI * 0.5 or value > PI:
		push_error("AmbientFluidBody3D: separation angle must be finite in [PI/2, PI]")
		return
	config.separation_angle_rad = value
	sleeping = false


func set_body_density_kg_m3(value: float) -> void:
	if not is_finite(value) or value <= 0.0:
		push_error("AmbientFluidBody3D: body density must be finite and positive")
		return
	config.body_density_kg_m3 = value
	mass = value * profile.volume_m3
	if _derived_inertia:
		body_inertia_diagonal_kg_m2 = _profile_inertia()
		inertia = body_inertia_diagonal_kg_m2
	_rebuild_tensors()
	sleeping = false


func set_body_mass_kg(value: float) -> void:
	if not is_finite(value) or value <= 0.0:
		push_error("AmbientFluidBody3D: body mass must be finite and positive")
		return
	mass = value
	config.body_density_kg_m3 = mass / profile.volume_m3
	if _derived_inertia:
		body_inertia_diagonal_kg_m2 = _profile_inertia()
		inertia = body_inertia_diagonal_kg_m2
	_rebuild_tensors()
	sleeping = false


func set_body_inertia_diagonal_kg_m2(value: Vector3) -> void:
	if not _finite_vector(value) or value.x <= 0.0 or value.y <= 0.0 or value.z <= 0.0:
		push_error("AmbientFluidBody3D: body inertia must be finite and positive")
		return
	body_inertia_diagonal_kg_m2 = value
	_derived_inertia = false
	inertia = value
	_rebuild_tensors()
	sleeping = false


func set_medium_velocity_sampler(value: Callable) -> void:
	medium_velocity_sampler = value
	sleeping = false


func set_medium_density_sampler(value: Callable) -> void:
	medium_density_sampler = value
	_cache_valid = false
	sleeping = false


func set_pool_buoyancy_mesh(faces_local: PackedVector3Array,
			surface_height_world: float) -> void:
	if faces_local.is_empty() or faces_local.size() % 3 != 0 \
		or not is_finite(surface_height_world):
		push_error("AmbientFluidBody3D: pool buoyancy mesh and surface height must be valid")
		return
	pool_buoyancy_faces_local = faces_local.duplicate()
	pool_surface_height_world = surface_height_world
	pool_buoyancy_enabled = true
	_cache_valid = false
	sleeping = false


func set_pool_buoyancy_enabled(enabled: bool) -> void:
	if pool_buoyancy_faces_local.is_empty():
		return
	pool_buoyancy_enabled = enabled
	_cache_valid = false
	sleeping = false


func set_initial_state(velocity_m_s: Vector3, spin_rad_s: Vector3) -> void:
	config.initial_velocity_m_s = velocity_m_s
	config.initial_spin_rad_s = spin_rad_s


func reset_state(reset_transform: Transform3D, velocity_m_s: Vector3, spin_rad_s: Vector3) -> void:
	_contact_bodies.clear()
	_pending_transform = reset_transform
	_pending_linear_velocity_world = velocity_m_s
	_pending_angular_velocity_world = spin_rad_s
	_pending_central_impulse_world = Vector3.ZERO
	_pending_torque_impulse_world = Vector3.ZERO
	_pending_reset = true
	_true_state_valid = false
	sleeping = false


func queue_impulses(central_impulse_world: Vector3, torque_impulse_world: Vector3) -> void:
	if not _finite_vector(central_impulse_world) or not _finite_vector(torque_impulse_world):
		push_error("AmbientFluidBody3D: queued impulses must be finite")
		return
	_pending_central_impulse_world += central_impulse_world
	_pending_torque_impulse_world += torque_impulse_world
	sleeping = false


func effective_fluid_density_kg_m3() -> float:
	return _effective_fluid_density()


func current_generalized_velocity() -> PackedFloat64Array:
	return _last_generalized_velocity.duplicate()


func current_generalized_momentum() -> PackedFloat64Array:
	_ensure_tensor_cache()
	return MATH.matrix_vector_multiply(_combined_tensor, current_generalized_velocity())


## World-frame angular momentum about the centre of mass, paired with the pose
## it was integrated to. Godot runs _integrate_forces before physics_frame and
## Jolt moves the body after it, so global_transform still holds the start of
## the tick when scripts read the end-of-tick momentum.
func world_angular_momentum() -> Vector3:
	var momentum := current_generalized_momentum()
	return _last_end_basis * Vector3(momentum[0], momentum[1], momentum[2])


func kinetic_energy_j() -> float:
	var velocity := current_generalized_velocity()
	var momentum := MATH.matrix_vector_multiply(_combined_tensor, velocity)
	return 0.5 * MATH.vector_dot(velocity, momentum)


## The body's world velocity at the end of the last tick. linear_velocity and
## angular_velocity hold what Jolt moves the body with over the tick: equal
## for a single step, the substep average when the spin needed substeps.
func current_linear_velocity() -> Vector3:
	return _true_linear_velocity_world if _true_state_valid else linear_velocity


func current_angular_velocity() -> Vector3:
	return _true_angular_velocity_world if _true_state_valid else angular_velocity


func speed_m_s() -> float:
	return current_linear_velocity().length()


func angular_speed_rad_s() -> float:
	return current_angular_velocity().length()


func pressure_wrench() -> PackedFloat64Array:
	return _last_pressure_wrench


func friction_wrench() -> PackedFloat64Array:
	return _last_friction_wrench


func surface_faces() -> int:
	return _last_surface_faces


func pressure_power_w() -> float:
	return _wrench_power(_last_pressure_wrench, _last_wrench_generalized_velocity)


func friction_power_w() -> float:
	return _wrench_power(_last_friction_wrench, _last_wrench_generalized_velocity)


func surface_cpu_time_us() -> int:
	return _last_surface_cpu_us


func integration_cpu_time_us() -> int:
	return _last_integration_cpu_us


func integration_substeps() -> int:
	return _last_substeps


func contact_count() -> int:
	return _contact_bodies.size()


func contact_warning() -> String:
	return "Jolt contact impulses use body inertia Kb; fluid K is rebuilt from post-contact velocity."


func finite_state() -> bool:
	return _cache_valid and _finite_vector(global_position) and _finite_vector(linear_velocity) \
		and _finite_vector(angular_velocity) and _finite_array(_combined_tensor) \
		and _finite_array(_combined_inverse)


func combined_tensor() -> PackedFloat64Array:
	_ensure_tensor_cache()
	return _combined_tensor


func combined_inverse() -> PackedFloat64Array:
	_ensure_tensor_cache()
	return _combined_inverse


func _rebuild_tensors(fluid_density_override := NAN) -> void:
	if profile == null or profile.added_mass_tensor.size() != MATH.MATRIX_SCALARS:
		_cache_valid = false
		return
	_body_tensor = MATH.diagonal_matrix(body_inertia_diagonal_kg_m2, mass)
	var fluid_density := _effective_fluid_density() if is_nan(fluid_density_override) else fluid_density_override
	var density_scale := fluid_density / profile.reference_density_kg_m3
	_combined_tensor = MATH.matrix_add(_body_tensor,
		MATH.matrix_scale(profile.added_mass_tensor, density_scale))
	_combined_inverse = MATH.matrix_inverse(_combined_tensor)
	_cache_valid = _combined_inverse.size() == MATH.MATRIX_SCALARS \
		and MATH.is_positive_definite(_combined_tensor)
	_cached_mass = mass
	_cached_fluid_density = fluid_density
	_cached_inertia = body_inertia_diagonal_kg_m2
	if not _cache_valid:
		_report_invalid_state("combined inertia tensor is not positive definite")


func _ensure_tensor_cache(fluid_density_override := NAN) -> void:
	if _derived_inertia and not is_nan(_cached_mass) \
		and not is_equal_approx(_cached_mass, mass):
		body_inertia_diagonal_kg_m2 = _profile_inertia()
	if inertia != body_inertia_diagonal_kg_m2:
		inertia = body_inertia_diagonal_kg_m2
	var fluid_density := fluid_density_override
	if is_nan(fluid_density):
		fluid_density = _cached_fluid_density if _cache_valid else _effective_fluid_density()
	if not fluid_enabled:
		fluid_density = 0.0
	if not _cache_valid or not is_equal_approx(_cached_mass, mass) \
		or not is_equal_approx(_cached_fluid_density, fluid_density) \
		or _cached_inertia != body_inertia_diagonal_kg_m2:
		_rebuild_tensors(fluid_density)


## Uniform-density inertia of the profile's own polyhedron (Sec. 5.2); the
## equal-volume sphere's when a profile carries no triangles.
func _profile_inertia() -> Vector3:
	var polyhedral := MATH.polyhedron_inertia_diagonal(profile.face_vertices_m, mass)
	if polyhedral.x > 0.0 and polyhedral.y > 0.0 and polyhedral.z > 0.0:
		return polyhedral
	var radius := pow(profile.volume_m3 * 3.0 / (4.0 * PI), 1.0 / 3.0)
	return Vector3.ONE * (0.4 * mass * radius * radius)


func _effective_fluid_density() -> float:
	if not fluid_enabled or config == null:
		return 0.0
	return config.fluid_density_kg_m3


func _configure_contacts() -> void:
	contact_monitor = contacts_enabled
	max_contacts_reported = 4 if contacts_enabled else 0
	can_sleep = contacts_enabled
	continuous_cd = contacts_enabled
	collision_layer = 1 if contacts_enabled else 0
	collision_mask = 1 if contacts_enabled else 0
	if contacts_enabled and not _contacts_connected:
		body_entered.connect(_on_contact_entered)
		body_exited.connect(_on_contact_exited)
		_contacts_connected = true
	elif not contacts_enabled and _contacts_connected:
		body_entered.disconnect(_on_contact_entered)
		body_exited.disconnect(_on_contact_exited)
		_contacts_connected = false
	_contact_bodies.clear()


func _on_contact_entered(other: Node) -> void:
	if other != self:
		_contact_bodies[other.get_instance_id()] = other


func _on_contact_exited(other: Node) -> void:
	_contact_bodies.erase(other.get_instance_id())


func _sample_fluid_velocity(world_center: Vector3) -> Vector3:
	if not fluid_enabled or not medium_velocity_sampler.is_valid():
		return Vector3.ZERO
	var sampled: Variant = medium_velocity_sampler.call(world_center)
	if sampled is Vector3 and _finite_vector(sampled):
		return sampled
	if not _invalid_medium_reported:
		_invalid_medium_reported = true
		push_error("AmbientFluidBody3D: medium velocity sampler returned an invalid value")
	return Vector3.ZERO


func _sample_fluid_density(world_center: Vector3) -> float:
	if not fluid_enabled:
		return 0.0
	if medium_density_sampler.is_valid():
		var sampled: Variant = medium_density_sampler.call(world_center)
		if sampled is float or sampled is int:
			return float(sampled)
		return NAN
	return config.fluid_density_kg_m3


func _sample_pool_immersion(body_basis: Basis, body_origin: Vector3) -> Dictionary:
	if not pool_buoyancy_enabled:
		submerged_volume_m3 = profile.volume_m3
		submerged_fraction = 1.0
		center_of_buoyancy_local = profile.center_of_volume_m
		waterline_points_local = PackedVector3Array()
		wet_area_fractions = PackedFloat64Array()
		wet_area_centers_m = PackedVector3Array()
		return {
			volume_m3 = profile.volume_m3,
			fraction = 1.0,
			centroid_m = profile.center_of_volume_m,
			wet_area_fractions = PackedFloat64Array(),
			wet_area_centers_m = PackedVector3Array(),
			wetted_area_fraction = 1.0,
		}
	var local_up := body_basis.transposed() * Vector3.UP
	var clipped: Dictionary = MATH.clip_convex_mesh_below_plane(
		pool_buoyancy_faces_local, profile.center_of_volume_m,
		local_up, pool_surface_height_world - body_origin.y)
	if clipped.is_empty():
		return {
			volume_m3 = 0.0,
			fraction = 0.0,
			centroid_m = profile.center_of_volume_m,
			wet_area_fractions = PackedFloat64Array(),
			wet_area_centers_m = PackedVector3Array(),
			wetted_area_fraction = 0.0,
		}
	submerged_volume_m3 = clampf(float(clipped.volume_m3), 0.0, profile.volume_m3)
	submerged_fraction = submerged_volume_m3 / profile.volume_m3
	center_of_buoyancy_local = clipped.centroid_m
	waterline_points_local = clipped.waterline_points
	wet_area_fractions = clipped.wet_area_fractions
	wet_area_centers_m = clipped.wet_area_centers_m
	wetted_area_fraction = clipped.wetted_area_fraction
	return {
		volume_m3 = submerged_volume_m3,
		fraction = submerged_fraction,
		centroid_m = center_of_buoyancy_local,
		wet_area_fractions = wet_area_fractions,
		wet_area_centers_m = wet_area_centers_m,
		wetted_area_fraction = wetted_area_fraction,
	}


func _basis_is_valid(basis: Basis) -> bool:
	return _finite_vector(basis.x) and _finite_vector(basis.y) and _finite_vector(basis.z) \
		and absf(basis.x.length() - 1.0) <= 1.0e-3 \
		and absf(basis.y.length() - 1.0) <= 1.0e-3 \
		and absf(basis.z.length() - 1.0) <= 1.0e-3 \
		and absf(basis.x.dot(basis.y)) <= 1.0e-3 \
		and absf(basis.x.dot(basis.z)) <= 1.0e-3 \
		and absf(basis.y.dot(basis.z)) <= 1.0e-3 \
		and absf(basis.determinant() - 1.0) <= 1.0e-3


func _rotation_increment(local_spin: Vector3, delta: float) -> Basis:
	var rotation_vector := local_spin * delta
	var angle := rotation_vector.length()
	if angle <= 1.0e-10:
		return Basis.IDENTITY
	return Basis(rotation_vector / angle, angle)


func _rotate_generalized_momentum(momentum: PackedFloat64Array,
		rotation: Basis) -> PackedFloat64Array:
	var angular := rotation * Vector3(momentum[0], momentum[1], momentum[2])
	var linear := rotation * Vector3(momentum[3], momentum[4], momentum[5])
	return PackedFloat64Array([
		angular.x, angular.y, angular.z,
		linear.x, linear.y, linear.z,
	])


func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _finite_array(values: PackedFloat64Array) -> bool:
	# The math helpers signal failure (singular matrix, size mismatch) with an
	# empty array; treating that as finite let the caller index it and crash.
	if values.is_empty():
		return false
	for value in values:
		if not is_finite(value):
			return false
	return true


func _report_invalid_state(message: String) -> void:
	if _invalid_state_reported:
		return
	_invalid_state_reported = true
	push_error("AmbientFluidBody3D: %s" % message)


func _wrench_power(wrench: PackedFloat64Array, generalized_velocity: PackedFloat64Array) -> float:
	if wrench.size() != MATH.MATRIX_SIZE or generalized_velocity.size() != MATH.MATRIX_SIZE:
		return NAN
	return MATH.vector_dot(wrench, generalized_velocity)
