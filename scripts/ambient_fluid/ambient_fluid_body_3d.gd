class_name AmbientFluidBody3D
extends RigidBody3D

const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")
const MAX_ROTATION_STEP_RAD := deg_to_rad(2.0)
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
var _derived_spherical_inertia := false
var _invalid_state_reported := false
var _invalid_medium_reported := false
var _analytic_surface_reported := false
var _last_pressure_wrench := PackedFloat64Array()
var _last_friction_wrench := PackedFloat64Array()
var _last_surface_faces := 0
var _last_surface_cpu_us := 0
var _last_integration_cpu_us := 0
var _last_substeps := 1
var _last_generalized_velocity := PackedFloat64Array()
var _last_wrench_generalized_velocity := PackedFloat64Array()
var _contact_bodies: Dictionary = {}
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
		var radius := pow(profile.volume_m3 * 3.0 / (4.0 * PI), 1.0 / 3.0)
		var spherical_inertia := 0.4 * mass * radius * radius
		body_inertia_diagonal_kg_m2 = Vector3.ONE * spherical_inertia
		_derived_spherical_inertia = true
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
	if _pending_reset:
		state.transform = _pending_transform
		state.linear_velocity = _pending_linear_velocity_world
		state.angular_velocity = _pending_angular_velocity_world
		_pending_reset = false
	var basis := state.transform.basis
	if not _basis_is_valid(basis):
		_report_invalid_state("body basis is not finite and orthonormal")
		return
	if not _finite_vector(state.linear_velocity) or not _finite_vector(state.angular_velocity):
		_report_invalid_state("body velocity is not finite")
		return
	var fluid_density := _sample_fluid_density(state.transform.origin)
	if not is_finite(fluid_density) or fluid_density < 0.0:
		if not _invalid_medium_reported:
			_invalid_medium_reported = true
			push_error("AmbientFluidBody3D: medium density sampler returned an invalid value")
		fluid_density = 0.0
	var immersion := _sample_pool_immersion(basis, state.transform.origin)
	var effective_added_mass_density := fluid_density * float(immersion.fraction)
	_ensure_tensor_cache(effective_added_mass_density)
	if not _cache_valid:
		return
	var fluid_velocity_world := _sample_fluid_velocity(state.transform.origin)
	var local_velocity := basis.transposed() * (state.linear_velocity - fluid_velocity_world)
	var local_spin := basis.transposed() * state.angular_velocity
	var generalized_velocity := PackedFloat64Array([
		local_spin.x, local_spin.y, local_spin.z,
		local_velocity.x, local_velocity.y, local_velocity.z,
	])
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
	_last_pressure_wrench.fill(0.0)
	_last_friction_wrench.fill(0.0)
	_last_surface_faces = 0
	_last_surface_cpu_us = 0
	var substeps := clampi(ceili(local_spin.length() * state.step / MAX_ROTATION_STEP_RAD), 1,
		MAX_SUBSTEPS)
	_last_substeps = substeps
	var substep := state.step / float(substeps)
	var next_momentum := momentum
	var output_basis := basis
	var next_velocity := generalized_velocity
	for _index in substeps:
		_last_pressure_wrench.fill(0.0)
		_last_surface_faces = 0
		next_velocity = MATH.matrix_vector_multiply(_combined_inverse, next_momentum)
		if not _finite_array(next_velocity):
			_report_invalid_state("substep velocity is not finite")
			return
		_last_wrench_generalized_velocity = next_velocity
		var step_spin := Vector3(next_velocity[0], next_velocity[1], next_velocity[2])
		if not is_finite(step_spin.length() * substep):
			_report_invalid_state("substep rotation is not finite")
			return
		var gravity_local := output_basis.transposed() * state.total_gravity
		immersion = _sample_pool_immersion(output_basis, state.transform.origin)
		var displaced_mass := fluid_density * float(immersion.volume_m3) \
			if pool_buoyancy_enabled else fluid_density * profile.volume_m3
		var gravity_wrench := MATH.gravity_buoyancy_wrench(
			mass, displaced_mass, gravity_local, immersion.centroid_m)
		var passive_wrench := MATH.semidirect_coupling_wrench(
			next_momentum, next_velocity)
		if fluid_density > 0.0:
			var wetted_fraction := float(immersion.wetted_area_fraction) \
				if pool_buoyancy_enabled else 1.0
			_last_friction_wrench = MATH.particle_drag_wrench(next_velocity,
				config.dynamic_viscosity_pa_s, fluid_density, profile.volume_m3,
				wetted_fraction, profile.total_area_m2)
			var relative_speed := Vector3(next_velocity[3], next_velocity[4],
				next_velocity[5]).length()
			var reynolds := fluid_density * relative_speed \
				* profile.characteristic_length_m / config.dynamic_viscosity_pa_s \
				if config.dynamic_viscosity_pa_s > 0.0 else INF
			if profile.format_version == AmbientFluidProfile3D.FORMAT_BEM \
					and reynolds >= 100.0 \
					and not profile.slip_matrix.is_empty():
				var surface_start_us := Time.get_ticks_usec()
				var surface := MATH.potential_pressure_wrench(profile.face_centers_m,
					profile.face_normals,
					profile.face_areas_m2, profile.slip_matrix, next_velocity,
					fluid_density, config.separation_angle_rad,
					immersion.wet_area_fractions if pool_buoyancy_enabled else PackedFloat64Array(),
					immersion.wet_area_centers_m if pool_buoyancy_enabled else PackedVector3Array())
				_last_pressure_wrench = surface.pressure.duplicate()
				var relative_velocity := Vector3(next_velocity[3], next_velocity[4],
					next_velocity[5])
				if relative_velocity.length_squared() > 1.0e-16:
					var pressure_force := Vector3(_last_pressure_wrench[3],
						_last_pressure_wrench[4], _last_pressure_wrench[5])
					pressure_force -= relative_velocity * (pressure_force.dot(relative_velocity)
						/ relative_velocity.length_squared())
					_last_pressure_wrench[3] = pressure_force.x
					_last_pressure_wrench[4] = pressure_force.y
					_last_pressure_wrench[5] = pressure_force.z
				if pool_buoyancy_enabled and step_spin.length_squared() > 1.0e-16:
					var pressure_torque := Vector3(_last_pressure_wrench[0],
						_last_pressure_wrench[1], _last_pressure_wrench[2])
					var spin_power := pressure_torque.dot(step_spin)
					if spin_power > 0.0:
						pressure_torque -= step_spin * (spin_power / step_spin.length_squared())
						_last_pressure_wrench[0] = pressure_torque.x
						_last_pressure_wrench[1] = pressure_torque.y
						_last_pressure_wrench[2] = pressure_torque.z
				_last_surface_faces = int(surface.attached_faces)
				_last_surface_cpu_us += Time.get_ticks_usec() - surface_start_us
			elif profile.format_version != AmbientFluidProfile3D.FORMAT_BEM \
					and not _analytic_surface_reported:
				_analytic_surface_reported = true
				push_warning("AmbientFluidBody3D: analytic profile disables surface pressure")
			passive_wrench = MATH.vector_add(passive_wrench, _last_pressure_wrench)
		if not pool_buoyancy_faces_local.is_empty():
			next_momentum = _pool_momentum_step(next_momentum, gravity_wrench,
				passive_wrench, _last_friction_wrench, substep)
		else:
			var wrench := MATH.vector_add(gravity_wrench,
				MATH.vector_add(passive_wrench, _last_friction_wrench))
			next_momentum = MATH.semi_implicit_momentum_step(next_momentum, wrench, substep)
		if not _finite_array(next_momentum):
			_report_invalid_state("substep momentum is not finite")
			return
		var rotation_increment := _rotation_increment(step_spin, substep)
		next_momentum = _rotate_generalized_momentum(next_momentum,
			rotation_increment.transposed())
		output_basis *= rotation_increment
	next_velocity = MATH.matrix_vector_multiply(_combined_inverse, next_momentum)
	if next_velocity.size() != MATH.MATRIX_SIZE or not _finite_array(next_velocity):
		_report_invalid_state("integrated velocity is not finite")
		return
	var next_local_spin := Vector3(next_velocity[0], next_velocity[1], next_velocity[2])
	state.angular_velocity = output_basis * next_local_spin
	state.linear_velocity = output_basis * Vector3(next_velocity[3], next_velocity[4], next_velocity[5]) \
		+ fluid_velocity_world
	_last_generalized_velocity = next_velocity


func _pool_momentum_step(momentum: PackedFloat64Array,
		gravity_wrench: PackedFloat64Array, passive_wrench: PackedFloat64Array,
		drag_wrench: PackedFloat64Array, delta: float) -> PackedFloat64Array:
	var forced := MATH.semi_implicit_momentum_step(momentum, gravity_wrench, delta)
	var forced_velocity := MATH.matrix_vector_multiply(_combined_inverse, forced)
	var energy_before := 0.5 * MATH.vector_dot(forced, forced_velocity)
	var passive := MATH.semi_implicit_momentum_step(forced, passive_wrench, delta)
	var passive_velocity := MATH.matrix_vector_multiply(_combined_inverse, passive)
	var energy_after := 0.5 * MATH.vector_dot(passive, passive_velocity)
	if energy_after > energy_before and energy_after > 0.0:
		passive = MATH.vector_scale(passive,
			sqrt(maxf(energy_before, 0.0) / energy_after))
		passive_velocity = MATH.matrix_vector_multiply(_combined_inverse, passive)
	var drag_impulse := MATH.vector_scale(drag_wrench, delta)
	var drag_power := MATH.vector_dot(drag_impulse, passive_velocity)
	if drag_power >= 0.0:
		return passive
	var drag_velocity := MATH.matrix_vector_multiply(_combined_inverse, drag_impulse)
	var drag_curvature := MATH.vector_dot(drag_impulse, drag_velocity)
	if drag_curvature <= 0.0:
		return passive
	var drag_scale := minf(1.0, -drag_power / drag_curvature)
	return MATH.vector_add(passive, MATH.vector_scale(drag_impulse, drag_scale))


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
	if _derived_spherical_inertia:
		var radius := pow(profile.volume_m3 * 3.0 / (4.0 * PI), 1.0 / 3.0)
		body_inertia_diagonal_kg_m2 = Vector3.ONE * (0.4 * mass * radius * radius)
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
	if _derived_spherical_inertia:
		var radius := pow(profile.volume_m3 * 3.0 / (4.0 * PI), 1.0 / 3.0)
		body_inertia_diagonal_kg_m2 = Vector3.ONE * (0.4 * mass * radius * radius)
		inertia = body_inertia_diagonal_kg_m2
	_rebuild_tensors()
	sleeping = false


func set_body_mass_kg(value: float) -> void:
	if not is_finite(value) or value <= 0.0:
		push_error("AmbientFluidBody3D: body mass must be finite and positive")
		return
	mass = value
	config.body_density_kg_m3 = mass / profile.volume_m3
	if _derived_spherical_inertia:
		var radius := pow(profile.volume_m3 * 3.0 / (4.0 * PI), 1.0 / 3.0)
		body_inertia_diagonal_kg_m2 = Vector3.ONE * (0.4 * mass * radius * radius)
		inertia = body_inertia_diagonal_kg_m2
	_rebuild_tensors()
	sleeping = false


func set_body_inertia_diagonal_kg_m2(value: Vector3) -> void:
	if not _finite_vector(value) or value.x <= 0.0 or value.y <= 0.0 or value.z <= 0.0:
		push_error("AmbientFluidBody3D: body inertia must be finite and positive")
		return
	body_inertia_diagonal_kg_m2 = value
	_derived_spherical_inertia = false
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


func kinetic_energy_j() -> float:
	var velocity := current_generalized_velocity()
	var momentum := MATH.matrix_vector_multiply(_combined_tensor, velocity)
	return 0.5 * MATH.vector_dot(velocity, momentum)


func speed_m_s() -> float:
	return linear_velocity.length()


func angular_speed_rad_s() -> float:
	return angular_velocity.length()


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
	if _derived_spherical_inertia and not is_nan(_cached_mass) \
		and not is_equal_approx(_cached_mass, mass):
		var radius := pow(profile.volume_m3 * 3.0 / (4.0 * PI), 1.0 / 3.0)
		body_inertia_diagonal_kg_m2 = Vector3.ONE * (0.4 * mass * radius * radius)
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
