extends RefCounted
## Backdrop of the tornado demo: the storm sky behind the cloud deck and the
## ring of far ground rising into the horizon range (the grass demo's scenery
## mesh, shaded for a storm). Demo-only.

const GrassScenery := preload("res://scripts/demos/grass/grass_scenery.gd")
const SKY_SHADER := preload("res://shaders/tornado/tornado_sky.gdshader")
const MOUNTAINS_SHADER := preload("res://shaders/tornado/tornado_mountains.gdshader")
const HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")

## Lower and farther than the grass demo's range: it must fit the clear slot
## under the cloud deck, whose rim hides anything taller.
const MOUNTAIN_HEIGHT_M := 750.0
const MOUNTAIN_RANGE_M := Vector2(4500.0, 12000.0)

var _sky := ShaderMaterial.new()
var _mountains := ShaderMaterial.new()


func setup(environment: Environment, ground: Node3D, camera: Camera3D, sun_dir: Vector3) -> void:
	_sky.shader = SKY_SHADER
	_sky.set_shader_parameter("sun_dir", sun_dir)
	var sky := Sky.new()
	sky.sky_material = _sky
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	_mountains.shader = MOUNTAINS_SHADER
	_mountains.set_shader_parameter("heightmap", HEIGHTMAP)
	ground.add_child(GrassScenery.build_far_ground(_mountains))
	_mountains.set_shader_parameter("mountain_height_m", MOUNTAIN_HEIGHT_M)
	_mountains.set_shader_parameter("mountain_range_m", MOUNTAIN_RANGE_M)
	camera.far = GrassScenery.CAMERA_FAR_M


func set_sky(zenith: Color, horizon: Color) -> void:
	_sky.set_shader_parameter("zenith_color", zenith)
	_sky.set_shader_parameter("horizon_color", horizon)


func set_relief(plain: Color, rock: Color, snow_amount: float) -> void:
	_mountains.set_shader_parameter("plain_color", plain)
	_mountains.set_shader_parameter("rock_color", rock)
	_mountains.set_shader_parameter("snow_amount", snow_amount)
