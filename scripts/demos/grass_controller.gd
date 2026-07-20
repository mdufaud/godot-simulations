extends Node3D
## Grass shader demo based on GodotGrass (2Retr0/GodotGrass)
## Features LOD multimesh system, wind animation, heightmap terrain

const GRASS_MESH_HIGH := preload("res://resources/grass/grass_high.obj")
const GRASS_MESH_LOW := preload("res://resources/grass/grass_low.obj")
const GRASS_MAT := preload("res://resources/grass/grass_material.tres")
const HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")
const GrassMultimeshBuilder := preload("res://scripts/grass_multimesh_builder.gd")

const TILE_SIZE := 10.0
const MAP_RADIUS := 80.0  # Smaller for demo
const HEIGHTMAP_SCALE := 5.0
const SHADOW_DISTANCE := 40.0

var grass_multimeshes: Array[Array] = []
var previous_tile_id := Vector3.ZERO
var density_modifier := 1.0

@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var menu: SimMenu = $UI/SimMenu


func _ready() -> void:
	# Setup global shader uniforms
	RenderingServer.global_shader_parameter_set("heightmap", HEIGHTMAP)
	RenderingServer.global_shader_parameter_set("heightmap_scale", HEIGHTMAP_SCALE)
	RenderingServer.global_shader_parameter_set("player_position", Vector3.ZERO)
	
	# Configure orbit camera
	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 20.0
	orbit_cam.pitch = -25.0
	orbit_cam.yaw = 45.0
	orbit_cam.min_distance = 5.0
	orbit_cam.max_distance = 100.0
	orbit_cam.rotation_speed = 0.4
	orbit_cam.zoom_speed = 2.0
	
	# Setup heightmap collision for ground
	_setup_heightmap_collision()
	
	# Create grass instances
	_setup_grass_instances()
	_generate_grass_multimeshes()
	
	call_deferred("_setup_ui")


func _physics_process(_delta: float) -> void:
	RenderingServer.global_shader_parameter_set("player_position", orbit_cam.target)
	
	# Update LOD tiles based on camera position
	var tile_id: Vector3 = ((orbit_cam.target + Vector3.ONE * TILE_SIZE * 0.5) / TILE_SIZE * Vector3(1, 0, 1)).floor()
	if tile_id != previous_tile_id:
		for data in grass_multimeshes:
			data[0].global_position = data[1] + Vector3(1, 0, 1) * TILE_SIZE * tile_id
		previous_tile_id = tile_id



## Creates a HeightMapShape3D from the NoiseTexture2D
func _setup_heightmap_collision() -> void:
	var noise: FastNoiseLite = HEIGHTMAP.noise
	var heightmap_image := noise.get_image(512, 512)
	var dims := Vector2i(heightmap_image.get_height(), heightmap_image.get_width())
	heightmap_image.convert(Image.FORMAT_RF)
	var map_data := heightmap_image.get_data().to_float32_array()

	for i in map_data.size():
		map_data[i] = (map_data[i] - 0.5) * HEIGHTMAP_SCALE

	var heightmap_shape := HeightMapShape3D.new()
	heightmap_shape.map_width = dims.x
	heightmap_shape.map_depth = dims.y
	heightmap_shape.map_data = map_data
	$Ground/CollisionShape3D.shape = heightmap_shape


## Creates initial tiled multimesh instances
func _setup_grass_instances() -> void:
	var half := TILE_SIZE * 0.5
	var tile_aabb := AABB(
		Vector3(-half - 2.0, -HEIGHTMAP_SCALE * 0.5 - 0.5, -half - 2.0),
		Vector3(TILE_SIZE + 4.0, HEIGHTMAP_SCALE + 3.0, TILE_SIZE + 4.0)
	)
	for i in range(-MAP_RADIUS, MAP_RADIUS, TILE_SIZE):
		for j in range(-MAP_RADIUS, MAP_RADIUS, TILE_SIZE):
			var instance := MultiMeshInstance3D.new()
			instance.material_override = GRASS_MAT
			instance.position = Vector3(i, 0.0, j)
			instance.custom_aabb = tile_aabb
			var near := instance.position.length() < SHADOW_DISTANCE
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if near else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			$GrassContainer.add_child(instance)
			grass_multimeshes.append([instance, instance.position])


## Generates multimeshes with LOD based on distance to origin
func _generate_grass_multimeshes() -> void:
	var multimesh_lods: Array[MultiMesh] = [
		GrassMultimeshBuilder.build(1.0 * density_modifier, TILE_SIZE, GRASS_MESH_HIGH),
		GrassMultimeshBuilder.build(0.5 * density_modifier, TILE_SIZE, GRASS_MESH_HIGH),
		GrassMultimeshBuilder.build(0.25 * density_modifier, TILE_SIZE, GRASS_MESH_LOW),
		GrassMultimeshBuilder.build(0.1 * density_modifier, TILE_SIZE, GRASS_MESH_LOW),
		GrassMultimeshBuilder.build(0.02 * (1.0 if density_modifier != 0.0 else 0.0), TILE_SIZE, GRASS_MESH_LOW),
	]
	
	for data in grass_multimeshes:
		var distance = data[1].length()  # Distance from center tile
		if distance > MAP_RADIUS:
			continue
		if distance < 12.0:
			data[0].multimesh = multimesh_lods[0]
		elif distance < 40.0:
			data[0].multimesh = multimesh_lods[1]
		elif distance < 55.0:
			data[0].multimesh = multimesh_lods[2]
		elif distance < 70.0:
			data[0].multimesh = multimesh_lods[3]
		else:
			data[0].multimesh = multimesh_lods[4]

func _setup_ui() -> void:
	menu.add_label("Drag: rotate | Scroll: zoom")

	menu.add_separator()
	menu.add_section("🌿 Grass Properties")
	menu.add_slider("Density", 0.0, 1.0, density_modifier, func(v: float):
		density_modifier = v
		_generate_grass_multimeshes())
	menu.add_slider("Clumping", 0.0, 1.0, 0.5, func(v: float):
		GRASS_MAT.set_shader_parameter("clumping_factor", v))
	menu.add_slider("Wind Speed", 0.0, 5.0, 1.0, func(v: float):
		GRASS_MAT.set_shader_parameter("wind_speed", v))

	menu.add_separator()
	menu.add_section("🎨 Colors")
	menu.add_color_picker("Base Color", Color(0.05, 0.2, 0.01), func(c: Color):
		GRASS_MAT.set_shader_parameter("base_color", c))
	menu.add_color_picker("Tip Color", Color(0.5, 0.5, 0.1), func(c: Color):
		GRASS_MAT.set_shader_parameter("tip_color", c))
	menu.add_color_picker("SSS Color", Color(1.0, 0.75, 0.1), func(c: Color):
		GRASS_MAT.set_shader_parameter("subsurface_scattering_color", c))

	menu.add_separator()
	menu.add_section("⚙️ Rendering")
	menu.add_toggle("Cast Shadows", true, _on_shadows_changed)
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, _set_render_scale)


func _set_render_scale(v: float) -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = v


func _on_shadows_changed(enabled: bool) -> void:
	for data in grass_multimeshes:
		var near: bool = data[1].length() < SHADOW_DISTANCE
		data[0].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled and near else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
