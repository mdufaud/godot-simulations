class_name PortalRigidBody3D
extends RigidBody3D

const CLIP_SHADER := preload("res://shaders/non_euclidean/portal_clip.gdshader")

@export var albedo := Color(0.34, 0.38, 0.42)
@export var material_roughness := 0.55
@export var material_metallic := 0.05

var gravity_vector := Vector3.DOWN * 12.0
var gravity_field: GravityField3D

var _pending_mapping := Transform3D.IDENTITY
var _pending_exit: Portal3D
var _has_pending_teleport := false
var _portal_lock: Portal3D
var _last_portal_tick := -1
var _portal_previous_position := Vector3.ZERO
var _preview_portal: Portal3D
var _source_mesh: MeshInstance3D
var _preview_mesh: MeshInstance3D
var _source_material: ShaderMaterial
var _preview_material: ShaderMaterial


func _ready() -> void:
	add_to_group("portal_traveller")
	process_physics_priority = 200
	gravity_scale = 0.0
	_portal_previous_position = global_position
	_source_mesh = _find_mesh(self)
	if _source_mesh != null:
		_source_material = _make_material()
		_source_mesh.material_override = _source_material
		call_deferred("_create_preview")


func _process(_delta: float) -> void:
	_update_portal_lock()
	_update_preview()


func _physics_process(_delta: float) -> void:
	_portal_previous_position = global_position


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _has_pending_teleport:
		state.transform = PortalMath.map_transform(_pending_mapping, state.transform)
		state.linear_velocity = PortalMath.map_vector(_pending_mapping, state.linear_velocity)
		state.angular_velocity = PortalMath.map_vector(_pending_mapping, state.angular_velocity)
		gravity_vector = PortalMath.map_vector(_pending_mapping, gravity_vector)
		gravity_field = null
		_portal_lock = _pending_exit
		if _pending_exit != null:
			state.transform.origin += _pending_exit.get_normal() * _pending_exit.exit_clearance
			if _pending_exit.gravity_override_enabled:
				gravity_vector = _pending_exit.gravity_override
			_preview_portal = _pending_exit
		state.sleeping = false
		_has_pending_teleport = false
		_portal_previous_position = state.transform.origin
		call_deferred("reset_physics_interpolation")
	var sampled_gravity := gravity_vector
	if gravity_field != null:
		sampled_gravity = gravity_field.sample_gravity(state.transform.origin)
	state.linear_velocity += sampled_gravity * state.step


func request_portal_teleport(mapping_transform: Transform3D, exit_portal: Portal3D) -> void:
	if _last_portal_tick == Engine.get_physics_frames():
		return
	_last_portal_tick = Engine.get_physics_frames()
	_pending_mapping = mapping_transform
	_pending_exit = exit_portal
	_has_pending_teleport = true


func can_use_portal(portal: Portal3D) -> bool:
	return not _has_pending_teleport \
		and _last_portal_tick != Engine.get_physics_frames() \
		and portal != _portal_lock


func get_portal_previous_position() -> Vector3:
	return _portal_previous_position


func set_portal_preview(portal: Portal3D) -> void:
	_preview_portal = portal


func clear_portal_preview(portal: Portal3D) -> void:
	if _preview_portal == portal:
		_preview_portal = null


func set_gravity_field(field: GravityField3D) -> void:
	gravity_field = field
	gravity_vector = field.sample_gravity(global_position)


func clear_gravity_field(field: GravityField3D) -> void:
	if gravity_field == field:
		gravity_field = null


func _create_preview() -> void:
	if _source_mesh == null or not is_inside_tree():
		return
	_preview_mesh = MeshInstance3D.new()
	_preview_mesh.name = "%sPortalPreview" % name
	_preview_mesh.mesh = _source_mesh.mesh
	_preview_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_mesh.layers = 8
	_preview_mesh.top_level = true
	_preview_material = _make_material()
	_preview_mesh.material_override = _preview_material
	_preview_mesh.visible = false
	var host := get_tree().current_scene
	if host == null:
		host = get_tree().root
	host.add_child(_preview_mesh)


func _update_preview() -> void:
	if _preview_mesh == null or _source_material == null:
		return
	if _preview_portal == null or not is_instance_valid(_preview_portal):
		_preview_mesh.visible = false
		_source_material.set_shader_parameter("clip_enabled", false)
		return
	var source_plane := _preview_portal.get_plane()
	var destination := _preview_portal.linked_portal
	if destination == null:
		_preview_mesh.visible = false
		_source_material.set_shader_parameter("clip_enabled", false)
		return
	_source_material.set_shader_parameter("clip_enabled", true)
	_source_material.set_shader_parameter("clip_plane", source_plane)
	_preview_material.set_shader_parameter("clip_enabled", true)
	_preview_material.set_shader_parameter("clip_plane", destination.get_plane())
	_preview_mesh.global_transform = PortalMath.map_transform(_preview_portal.get_mapping(), global_transform)
	_preview_mesh.visible = true


func _update_portal_lock() -> void:
	if _portal_lock == null:
		return
	var release_distance := _portal_lock.activation_depth * 0.65 + 0.1
	if absf(_portal_lock.signed_distance(global_position)) > release_distance:
		_portal_lock = null


func _make_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = CLIP_SHADER
	material.set_shader_parameter("albedo", Vector3(albedo.r, albedo.g, albedo.b))
	material.set_shader_parameter("roughness", material_roughness)
	material.set_shader_parameter("metallic", material_metallic)
	return material


func _find_mesh(node: Node) -> MeshInstance3D:
	for child in node.get_children():
		if child is MeshInstance3D:
			return child as MeshInstance3D
		var nested := _find_mesh(child)
		if nested != null:
			return nested
	return null


func _exit_tree() -> void:
	if _preview_mesh != null and is_instance_valid(_preview_mesh):
		_preview_mesh.queue_free()
