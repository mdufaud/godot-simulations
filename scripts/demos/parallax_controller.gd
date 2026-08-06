extends Node3D
## Contact Refinement Parallax Occlusion Mapping demo
## State-of-the-art CRPOM with self-shadowing and multiple surface presets

const PRESETS := [
	preload("res://resources/parallax/presets/rock.tres"),
	preload("res://resources/parallax/presets/bricks.tres"),
	preload("res://resources/parallax/presets/cobblestone.tres"),
	preload("res://resources/parallax/presets/dunes.tres"),
]

const MIN_DISTANCE := 1.5
const MAX_DISTANCE := 12.0

@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var menu: SimMenu = $UI/SimMenu
@onready var parallax_mesh: MeshInstance3D = $ParallaxSurface
@onready var parallax_mesh_cube: MeshInstance3D = $ParallaxCube

var parallax_material: ShaderMaterial

var _settings := ParallaxConfig.new()
var _textures := ParallaxTextureFactory.new()
var _menu_builder: ParallaxMenu
var _current_mesh := 0 # 0=plane, 1=cube


func _ready() -> void:
	parallax_material = ShaderMaterial.new()
	parallax_material.shader = preload("res://shaders/parallax/parallax.gdshader")

	_menu_builder = ParallaxMenu.new(_settings, _apply_settings, _on_preset_selected,
		_on_mesh_selected)
	_menu_builder.build(menu, _preset_names())

	var error := _settings.validate()
	if error != "":
		push_error("Parallax settings: %s" % error)

	# Restore saved values as-is; presets only apply on explicit selection
	_apply_surface_textures()
	_apply_settings()

	orbit_cam.distance = 4.0
	orbit_cam.pitch = -35.0
	orbit_cam.yaw = 45.0
	orbit_cam.min_distance = MIN_DISTANCE
	orbit_cam.max_distance = MAX_DISTANCE
	orbit_cam.rotation_speed = 0.4
	orbit_cam.zoom_speed = 0.3


func _preset_names() -> Array:
	var names := []
	for preset in PRESETS:
		names.append((preset as ParallaxConfig).display_name)
	return names


func _on_preset_selected(index: int) -> void:
	_settings.adopt_surface(PRESETS[index] as ParallaxConfig)
	_menu_builder.sync_sliders()
	_apply_surface_textures()
	_apply_settings()


func _on_mesh_selected(index: int) -> void:
	_current_mesh = index
	_update_mesh_visibility()


func _apply_surface_textures() -> void:
	var maps := _textures.maps_for(_settings.surface)
	parallax_material.set_shader_parameter("texture_albedo", maps.albedo)
	parallax_material.set_shader_parameter("texture_normal", maps.normal)
	parallax_material.set_shader_parameter("texture_height", maps.height)
	_update_mesh_visibility()


func _apply_settings() -> void:
	_settings.apply_to(parallax_material)


func _update_mesh_visibility() -> void:
	parallax_mesh.visible = (_current_mesh == 0)
	parallax_mesh_cube.visible = (_current_mesh == 1)

	var active_mesh := parallax_mesh if _current_mesh == 0 else parallax_mesh_cube
	active_mesh.set_surface_override_material(0, parallax_material)
