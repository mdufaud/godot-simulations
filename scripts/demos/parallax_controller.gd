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
@onready var _viewport := ViewportGuard.attach(self)

var parallax_material: ShaderMaterial

var _settings := ParallaxConfig.new()
var _textures := ParallaxTextureFactory.new()
var _menu_builder: ParallaxMenu
var _current_mesh := 0 # 0=plane, 1=cube
var quality := SimQualityState.new()
# The active preset's unscaled raymarch budgets; tiers scale around these.
var _base_min_layers := 8
var _base_max_layers := 32


func _ready() -> void:
	parallax_material = ShaderMaterial.new()
	parallax_material.shader = preload("res://shaders/parallax/parallax.gdshader")

	_base_min_layers = _settings.min_layer_count
	_base_max_layers = _settings.max_layer_count
	quality.setup(ParallaxQualityProfile, "parallax_quality_profile", _apply_quality)
	quality.restore()
	_menu_builder = ParallaxMenu.new(_settings, _apply_settings, _on_preset_selected,
		_on_mesh_selected, quality)
	_menu_builder.build(menu, _preset_names())
	_menu_builder.sync_sliders()

	var error := _settings.validate()
	if error != "":
		push_error("Parallax settings: %s" % error)

	# Restore saved values as-is; presets only apply on explicit selection
	_apply_surface_textures()
	_apply_settings()

	menu.add_section("Performance")
	var scale_slider: HSlider = menu.add_slider("Render scale", 0.4, 1.0,
		_viewport.render_scale(), _set_render_scale)
	quality.bind("render_scale", scale_slider, _set_render_scale)
	quality.attach_menu_option(menu)

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
	_base_min_layers = _settings.min_layer_count
	_base_max_layers = _settings.max_layer_count
	# Re-scale the new preset's step counts, then refresh every slider display.
	quality.reapply()
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


func _set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


## The layer counts scale around the active preset's base. render_scale and
## self_shadow are widget-bound — absent from values on a tier push (the
## widget callbacks already applied them), so they fall back to the live
## values.
func _apply_quality(values: Dictionary) -> void:
	_set_render_scale(values.get("render_scale", _viewport.render_scale()))
	_settings.min_layer_count = clampi(
		int(round(_base_min_layers * values.min_factor)), 4, 128)
	_settings.max_layer_count = clampi(
		int(round(_base_max_layers * values.max_factor)),
		_settings.min_layer_count, 128)
	_settings.self_shadow_enabled = values.get("self_shadow",
		_settings.self_shadow_enabled)
	_apply_settings()
