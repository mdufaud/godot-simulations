class_name Portal3D
extends Node3D

signal teleported(body: Node3D, destination: Portal3D)

const WORLD_LAYER := 1
const MAIN_PORTAL_LAYER := 2
const PROXY_LAYER := 8
const SCREEN_OFFSET := -0.03
const SCREEN_OVERSCAN := Vector2(0.06, 0.06)
const SURFACE_SHADER := preload("res://shaders/non_euclidean/portal_surface.gdshader")

@export var linked_portal: Portal3D
@export var opening_size := Vector2(2.6, 3.4)
@export var activation_depth := 0.9
@export var exit_clearance := 0.001
@export var gravity_override_enabled := false
@export var gravity_override := Vector3.DOWN * 12.0

var _area: Area3D
var _screen: MeshInstance3D
var _surface_material: ShaderMaterial
var _debug_volume: MeshInstance3D


func _ready() -> void:
	add_to_group("portals")
	process_physics_priority = 100
	_build_portal()


func _physics_process(_delta: float) -> void:
	if linked_portal == null:
		return
	for candidate in get_tree().get_nodes_in_group("portal_traveller"):
		var body := candidate as Node3D
		if body == null or not body.has_method("get_portal_previous_position") \
				or not body.has_method("can_use_portal") \
				or not body.has_method("request_portal_teleport"):
			continue
		if not body.can_use_portal(self):
			continue
		var previous_local := to_local(body.get_portal_previous_position())
		var current_local := to_local(body.global_position)
		if previous_local.z <= 0.0 or current_local.z > 0.0:
			continue
		var hit := PortalMath.crossing_point(previous_local, current_local)
		if not PortalMath.inside_aperture(hit, opening_size):
			continue
		body.request_portal_teleport(get_mapping(), linked_portal)
		teleported.emit(body, linked_portal)


func get_mapping() -> Transform3D:
	if linked_portal == null:
		return Transform3D.IDENTITY
	return PortalMath.mapping(global_transform, linked_portal.global_transform)


func map_transform(value: Transform3D) -> Transform3D:
	return PortalMath.map_transform(get_mapping(), value)


func map_vector(value: Vector3) -> Vector3:
	return PortalMath.map_vector(get_mapping(), value)


func map_position(value: Vector3) -> Vector3:
	return get_mapping() * value


func get_normal() -> Vector3:
	return global_basis.z.normalized()


func signed_distance(world_position: Vector3) -> float:
	return PortalMath.signed_distance(global_transform, world_position)


func get_plane() -> Vector4:
	var normal := get_normal()
	return Vector4(normal.x, normal.y, normal.z, -normal.dot(global_position))


func get_aperture_corners() -> Array[Vector3]:
	var half := opening_size * 0.5
	return [
		to_global(Vector3(-half.x, -half.y, 0.0)),
		to_global(Vector3(half.x, -half.y, 0.0)),
		to_global(Vector3(half.x, half.y, 0.0)),
		to_global(Vector3(-half.x, half.y, 0.0)),
	]


func is_visible_from(camera: Camera3D) -> bool:
	if linked_portal == null or signed_distance(camera.global_position) < -0.001:
		return false
	var radius := opening_size.length() * 0.5
	var distance := camera.global_position.distance_to(global_position)
	if distance > camera.far + radius:
		return false
	if distance <= radius * 1.5:
		return true
	if camera.is_position_in_frustum(global_position):
		return true
	for corner in get_aperture_corners():
		if camera.is_position_in_frustum(corner):
			return true
	return false


func set_render_texture(texture: Texture2D) -> void:
	if _surface_material != null:
		_surface_material.set_shader_parameter("portal_texture", texture)


func set_debug_enabled(enabled: bool) -> void:
	if _debug_volume != null:
		_debug_volume.visible = enabled


func _build_portal() -> void:
	_surface_material = ShaderMaterial.new()
	_surface_material.shader = SURFACE_SHADER
	var quad := QuadMesh.new()
	quad.size = opening_size + SCREEN_OVERSCAN
	_screen = MeshInstance3D.new()
	_screen.name = "PortalScreen"
	_screen.mesh = quad
	_screen.position.z = SCREEN_OFFSET
	_screen.layers = MAIN_PORTAL_LAYER
	_screen.material_override = _surface_material
	_screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_screen.extra_cull_margin = opening_size.length()
	add_child(_screen)

	_area = Area3D.new()
	_area.name = "PortalArea"
	_area.collision_layer = 0
	_area.collision_mask = 1
	_area.monitoring = true
	var area_shape := CollisionShape3D.new()
	var area_box := BoxShape3D.new()
	area_box.size = Vector3(opening_size.x * 0.98, opening_size.y * 0.98, activation_depth)
	area_shape.shape = area_box
	_area.add_child(area_shape)
	add_child(_area)
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)

	var debug_mesh := BoxMesh.new()
	debug_mesh.size = area_box.size
	var debug_material := StandardMaterial3D.new()
	debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	debug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	debug_material.albedo_color = Color(0.08, 0.65, 1.0, 0.12)
	_debug_volume = MeshInstance3D.new()
	_debug_volume.name = "DebugVolume"
	_debug_volume.mesh = debug_mesh
	_debug_volume.layers = MAIN_PORTAL_LAYER
	_debug_volume.material_override = debug_material
	_debug_volume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_volume.visible = false
	add_child(_debug_volume)


func _on_body_entered(body: Node3D) -> void:
	if body.has_method("set_portal_preview"):
		body.set_portal_preview(self)


func _on_body_exited(body: Node3D) -> void:
	if body.has_method("clear_portal_preview"):
		body.clear_portal_preview(self)


func _exit_tree() -> void:
	if _surface_material != null:
		_surface_material.set_shader_parameter("portal_texture", null)
