class_name WildfireScenery extends Node3D
## Static props for the wildfire demo, built from the Fire-X demo's assets:
## scorched ground, torches, log piles, rocks and the campfire's stone ring.
## The controller places soot and heats log piles from the cell grid's
## signals; nothing here knows about the grid beyond the shared origin
## constants.

const GRID_SIZE := Vector2i(32, 32)
const CELL_SIZE := 1.5
const GRID_ORIGIN := Vector3(-24.0, 0.0, -24.0)
const GROUND_HALF := 30.0

const HERO_POS := Vector3(0, 0, 4)
const TORCH_HEIGHT := 1.3
const TORCHES: Array[Vector3] = [Vector3(-8, 0, -6), Vector3(7, 0, -9), Vector3(10, 0, 5)]
const LOG_PILES: Array[Vector3] = [Vector3(-6, 0, 7), Vector3(9, 0, -3)]

const SOOT_POOL := 256
const PILE_RADIUS := 1.4
## Seconds a freshly lit log pile takes to reach full red heat.
const PILE_HEAT_UP_S := 8.0

const EMBER_LOG_SHADER := preload("res://shaders/wildfire/ember_log.gdshader")
const LOG_MESH := preload("res://resources/fire/fire_log.res")
const BARK_MATERIAL := preload("res://resources/fire/fire_bark.tres")
const STONE_MATERIAL := preload("res://resources/fire/fire_stone.tres")
const GROUND_TEXTURE := preload("res://resources/fire/fire_scorched_ground.png")
const ROCK_MESHES: Array[Mesh] = [
	preload("res://resources/fire/fire_rock_0.res"),
	preload("res://resources/fire/fire_rock_1.res"),
	preload("res://resources/fire/fire_rock_2.res"),
]

var _soot: Array[Decal] = []
var _soot_next := 0
var _pulse: NoiseTexture2D
## Per log pile: its [bark, endgrain] materials, current heat and target heat.
var _pile_materials: Array[Array] = []
var _pile_heat := PackedFloat32Array()
var _pile_target := PackedFloat32Array()


func _ready() -> void:
	_build_ground()
	_build_props()


func _process(delta: float) -> void:
	for index in _pile_heat.size():
		if _pile_heat[index] == _pile_target[index]:
			continue
		_pile_heat[index] = move_toward(_pile_heat[index], _pile_target[index],
			delta / PILE_HEAT_UP_S)
		for material: ShaderMaterial in _pile_materials[index]:
			material.set_shader_parameter("heat", _pile_heat[index])


func place_soot(world_pos: Vector3) -> void:
	var decal := _soot[_soot_next]
	_soot_next = (_soot_next + 1) % _soot.size()
	decal.position = world_pos + Vector3(0, 0.02, 0)
	decal.rotation.y = randf() * TAU
	var size := randf_range(1.2, 2.0)
	decal.size = Vector3(size, 1.0, size)
	decal.visible = true


func clear_soot() -> void:
	for decal in _soot:
		decal.visible = false
	_soot_next = 0


## Starts heating the log pile under a burning wood cell.
func ignite_pile_near(world_pos: Vector3) -> void:
	for index in LOG_PILES.size():
		if LOG_PILES[index].distance_to(world_pos) <= PILE_RADIUS + 0.5:
			_pile_target[index] = 1.0


func extinguish_piles() -> void:
	_pile_target.fill(0.0)


## World zones that burn as wood (log piles), for the controller's material pass.
func wood_zones() -> Array:
	var zones: Array = []
	for pos in LOG_PILES:
		zones.append({"pos": pos, "radius": PILE_RADIUS})
	return zones


func _build_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GROUND_HALF * 2.0, 0.4, GROUND_HALF * 2.0)
	shape.shape = box
	shape.position = Vector3(0, -0.2, 0)
	body.add_child(shape)
	add_child(body)
	# The flamethrower stream's particles slide along this.
	var particle_floor := GPUParticlesCollisionBox3D.new()
	particle_floor.size = box.size
	particle_floor.position = shape.position
	add_child(particle_floor)
	var ground := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(GROUND_HALF * 2.0, GROUND_HALF * 2.0)
	var material := StandardMaterial3D.new()
	material.albedo_texture = GROUND_TEXTURE
	material.roughness = 1.0
	material.uv1_scale = Vector3(20.0, 20.0, 20.0)
	ground.mesh = mesh
	ground.material_override = material
	add_child(ground)


func _build_props() -> void:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.01
	_pulse = NoiseTexture2D.new()
	_pulse.seamless = true
	_pulse.noise = noise

	for pos in TORCHES:
		var pole := MeshInstance3D.new()
		var pole_mesh := CylinderMesh.new()
		pole_mesh.top_radius = 0.05
		pole_mesh.bottom_radius = 0.07
		pole_mesh.height = 1.3
		pole.mesh = pole_mesh
		pole.material_override = BARK_MATERIAL
		pole.position = pos + Vector3(0, 0.65, 0)
		add_child(pole)

	for pos in LOG_PILES:
		var materials := _log_materials(pos, PILE_RADIUS, 0.0)
		_pile_materials.append(materials)
		_pile_heat.append(0.0)
		_pile_target.append(0.0)
		_add_log(pos + Vector3(-0.31, 0.17, 0.02), 1.15, 0.17,
			Vector3(cos(0.1), 0, sin(0.1)), materials, 0.05)
		_add_log(pos + Vector3(0.31, 0.16, -0.03), 1.05, 0.16,
			Vector3(cos(-0.12), 0, sin(-0.12)), materials, -0.1)
		_add_log(pos + Vector3(0.0, 0.17, -0.28), 1.1, 0.17,
			Vector3(cos(0.04), 0, sin(0.04)), materials, 0.2)
		_add_log(pos + Vector3(0.0, 0.26, 0.0), 1.2, 0.15,
			Vector3(cos(0.5), 0, sin(0.5)), materials, -0.35)

	_build_campfire_wood(_log_materials(HERO_POS, 0.95, 1.0))
	_build_soot_pool()

	for i in 6:
		_add_rock(Vector3(-22 + float(i) * 7.3, 0.12, -14 + (float(i % 3)) * 13.0),
			Vector3.ONE * (0.8 + 0.35 * float(i % 4)), float(i) * 1.3, i)

	for k in 9:
		var angle := TAU * float(k) / 9.0
		_add_rock(HERO_POS + Vector3(cos(angle) * 1.2, 0.06, sin(angle) * 1.2),
			Vector3(0.42, 0.32, 0.36), angle, k)


## [bark, endgrain] ember materials for one group of logs heated around
## [param center].
func _log_materials(center: Vector3, radius: float, heat: float) -> Array:
	var materials := []
	for surface in [["fire_bark.png", "fire_bark_ember.png"],
			["fire_endgrain.png", "fire_endgrain_ember.png"]]:
		var material := ShaderMaterial.new()
		material.shader = EMBER_LOG_SHADER
		material.set_shader_parameter("albedo_tex", load("res://resources/fire/" + surface[0]))
		material.set_shader_parameter("ember_tex", load("res://resources/fire/" + surface[1]))
		material.set_shader_parameter("pulse_tex", _pulse)
		material.set_shader_parameter("heat_center", center)
		material.set_shader_parameter("heat_radius_m", radius)
		material.set_shader_parameter("heat", heat)
		materials.append(material)
	materials[0].set_shader_parameter("normal_tex",
		load("res://resources/fire/fire_bark_normal.png"))
	materials[0].set_shader_parameter("use_normal", true)
	return materials


## Fire-X log mesh (unit length along local Y, unit radius) lying along
## [param axis]; [param center] is the log's midpoint.
func _add_log(center: Vector3, length: float, radius: float, axis: Vector3,
		materials: Array, roll := 0.0) -> void:
	var log_node := MeshInstance3D.new()
	log_node.mesh = LOG_MESH
	log_node.set_surface_override_material(0, materials[0])
	log_node.set_surface_override_material(1, materials[1])
	var y := axis.normalized()
	var x := y.cross(Vector3.UP)
	x = x.normalized() if x.length() > 0.001 else Vector3.RIGHT
	var z := x.cross(y).normalized()
	log_node.basis = Basis(x.rotated(y, roll) * radius, y * length,
		z.rotated(y, roll) * radius)
	log_node.position = center
	add_child(log_node)


func _add_rock(pos: Vector3, size: Vector3, yaw: float, variant: int) -> void:
	var rock := MeshInstance3D.new()
	rock.mesh = ROCK_MESHES[variant % ROCK_MESHES.size()]
	rock.material_override = STONE_MATERIAL
	rock.basis = Basis(Vector3.UP, yaw) * Basis.from_scale(size)
	rock.position = pos
	add_child(rock)


## Fuel bed of the hero campfire: five logs radiating from the middle, inner
## ends raised.
func _build_campfire_wood(materials: Array) -> void:
	for k in 5:
		var angle := TAU * float(k) / 5.0 + 0.3
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var inner := HERO_POS + dir * 0.08 + Vector3(0, 0.26, 0)
		var outer := HERO_POS + dir * 0.92 + Vector3(0, 0.1, 0)
		_add_log((inner + outer) * 0.5, inner.distance_to(outer), 0.1,
			outer - inner, materials, float(k) * 1.7)
	for k in 2:
		var angle := 1.1 + TAU * float(k) / 2.0
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		_add_log(HERO_POS + dir * 0.12 + Vector3(0, 0.36, 0), 0.7, 0.075,
			Vector3(-dir.z, 0.25, dir.x), materials, 0.8)


func _build_soot_pool() -> void:
	var soot_texture := GradientTexture2D.new()
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([Color(0.03, 0.028, 0.025, 0.9),
		Color(0.03, 0.028, 0.025, 0.0)])
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	soot_texture.gradient = gradient
	soot_texture.fill = GradientTexture2D.FILL_RADIAL
	soot_texture.fill_from = Vector2(0.5, 0.5)
	soot_texture.fill_to = Vector2(0.5, 0.0)
	soot_texture.width = 128
	soot_texture.height = 128
	for i in SOOT_POOL:
		var decal := Decal.new()
		decal.texture_albedo = soot_texture
		decal.cull_mask = 1
		decal.visible = false
		add_child(decal)
		_soot.append(decal)
