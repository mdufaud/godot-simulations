class_name OceanBuoy
extends RigidBody3D
## Floating crate riding the FFT ocean. The controller submits the crate's
## four corner probes (plus every other crate and the camera) as GPU point
## queries against the rendered surface and hands the results back here:
## buoyancy and righting torque from the probe depths, downhill push from the
## sampled surface normal. No CPU wave sampling anywhere.

const PROBES: Array[Vector3] = [
	Vector3(-0.45, 0.0, -0.45), Vector3(0.45, 0.0, -0.45),
	Vector3(-0.45, 0.0, 0.45), Vector3(0.45, 0.0, 0.45),
]
const BOX_SIZE := Vector3(1.2, 1.2, 1.2)
const BODY_DENSITY_KG_M3 := 450.0
const WATER_DENSITY_KG_M3 := OceanSolver.WATER_DENSITY_KG_M3
const DRAG_COEFFICIENT := 0.8
const BUOYANCY := 32.0
const MAX_DEPTH := 1.4
## The old CPU path pushed along the finite-difference slope over a 4 m
## baseline; the query normal encodes the same gradient, so the force keeps
## the original span (SLOPE_PUSH x 4 m) for identical ride behaviour.
const SLOPE_PUSH := 1.2
const SLOPE_BASELINE_M := 4.0
const BUOYANCY_MATH := preload("res://scripts/ocean/ocean_buoyancy_math.gd")

@export var physical_model_enabled := false:
	set(value):
		physical_model_enabled = value
		if is_node_ready():
			mass = _physical_mass() if value else 30.0
			_sync_gravity()

var last_water_impulse: Vector3 = Vector3.ZERO
var last_support_force_n: Vector3 = Vector3.ZERO
var last_drag_force_n: Vector3 = Vector3.ZERO


func _ready() -> void:
	mass = _physical_mass() if physical_model_enabled else 30.0
	_sync_gravity()
	can_sleep = false
	var box := BoxMesh.new()
	box.size = BOX_SIZE
	var mesh := MeshInstance3D.new()
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.52, 0.36, 0.2)
	mat.roughness = 0.85
	mesh.material_override = mat
	add_child(mesh)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = BOX_SIZE
	shape.shape = box_shape
	add_child(shape)


## One frame of query results for this crate: one depth (water height minus
## probe y, <= 0 = dry) per corner probe and the averaged surface normal.
func apply_water_frame(probe_depths: PackedFloat32Array, surface_normal: Vector3,
		valid_mask: PackedByteArray = PackedByteArray(),
		water_velocities: PackedVector3Array = PackedVector3Array(),
		query_probe_positions: PackedVector3Array = PackedVector3Array(),
		physics_delta_s: float = 0.0) -> void:
	last_water_impulse = Vector3.ZERO
	last_support_force_n = Vector3.ZERO
	last_drag_force_n = Vector3.ZERO
	if probe_depths.size() < PROBES.size():
		return
	if not valid_mask.is_empty() and valid_mask.size() < PROBES.size():
		return
	if physical_model_enabled:
		_apply_physical_water_frame(probe_depths, surface_normal, valid_mask,
		water_velocities, query_probe_positions, physics_delta_s)
		return
	var submerged := 0
	for i in PROBES.size():
		if not valid_mask.is_empty() and valid_mask[i] == 0:
			continue
		var depth: float = probe_depths[i]
		if depth <= 0.0:
			continue
		submerged += 1
		var p := global_transform * PROBES[i]
		apply_force(
			Vector3.UP * mass * BUOYANCY * clampf(depth, 0.0, MAX_DEPTH) / PROBES.size(),
			p - global_position
		)
	if submerged > 0:
		var slope := Vector2(
			surface_normal.x / maxf(surface_normal.y, 0.25),
			surface_normal.z / maxf(surface_normal.y, 0.25))
		apply_central_force(Vector3(-slope.x, 0.0, -slope.y)
			* (mass * SLOPE_PUSH * SLOPE_BASELINE_M))
		linear_damp = 1.4
		angular_damp = 1.6
	else:
		linear_damp = 0.05
		angular_damp = 0.05


func _apply_physical_water_frame(probe_depths: PackedFloat32Array,
		surface_normal: Vector3, valid_mask: PackedByteArray,
		water_velocities: PackedVector3Array,
		query_probe_positions: PackedVector3Array, physics_delta_s: float) -> void:
	var current_probe_positions := PackedVector3Array()
	var valid_count := 0
	var water_velocity := Vector3.ZERO
	for i in PROBES.size():
		var position := global_transform * PROBES[i]
		current_probe_positions.append(position)
		if not valid_mask.is_empty() and valid_mask[i] == 0:
			continue
		valid_count += 1
		if water_velocities.size() >= PROBES.size():
			water_velocity += water_velocities[i]
	if valid_count == 0:
		linear_damp = 0.05
		angular_damp = 0.05
		return
	var plane_probe_positions := query_probe_positions \
		if query_probe_positions.size() >= PROBES.size() else current_probe_positions
	var plane: Dictionary = BUOYANCY_MATH.water_plane(plane_probe_positions,
		probe_depths, valid_mask, surface_normal)
	if plane.is_empty():
		return
	if water_velocities.size() >= PROBES.size():
		water_velocity /= float(valid_count)
	var clipped: Dictionary = BUOYANCY_MATH.clipped_box(BOX_SIZE,
		global_transform, plane.point, plane.normal)
	var displaced_volume: float = clipped.volume
	var full_volume := BOX_SIZE.x * BOX_SIZE.y * BOX_SIZE.z
	var immersion_fraction := clampf(displaced_volume / full_volume, 0.0, 1.0)
	if displaced_volume <= 0.000001:
		linear_damp = 0.05
		angular_damp = 0.05
		return
	var center_of_buoyancy: Vector3 = clipped.centroid
	var offset := center_of_buoyancy - global_position
	var buoyancy_force := Vector3.UP * (WATER_DENSITY_KG_M3 * OceanSolver.GRAVITY * displaced_volume)
	last_support_force_n = buoyancy_force
	apply_force(buoyancy_force, offset)
	if water_velocities.size() >= PROBES.size():
		var body_velocity := linear_velocity + angular_velocity.cross(offset)
		var relative_velocity := body_velocity - water_velocity
		var projected_area: float = BUOYANCY_MATH.projected_box_area(
			BOX_SIZE, global_transform, relative_velocity) * immersion_fraction
		var drag_force: Vector3 = BUOYANCY_MATH.quadratic_drag(
			relative_velocity, projected_area, WATER_DENSITY_KG_M3,
			DRAG_COEFFICIENT)
		last_drag_force_n = drag_force
		apply_force(drag_force, offset)
		var physics_delta := physics_delta_s if physics_delta_s > 0.0 \
			else 1.0 / float(Engine.physics_ticks_per_second)
		last_water_impulse = -Vector3(drag_force.x, 0.0, drag_force.z) * physics_delta
	linear_damp = 0.05
	angular_damp = 0.05


func _physical_mass() -> float:
	return BODY_DENSITY_KG_M3 * BOX_SIZE.x * BOX_SIZE.y * BOX_SIZE.z


func _sync_gravity() -> void:
	var project_gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	gravity_scale = OceanSolver.GRAVITY / project_gravity if physical_model_enabled else 1.0
