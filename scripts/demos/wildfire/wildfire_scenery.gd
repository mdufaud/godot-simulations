class_name FireGameScenery extends Node3D
## Static props for the wildfire demo: ground, torches, log piles, rocks and
## the hero campfire's stone ring. The controller places soot from the cell
## grid's signals; nothing here knows about the grid itself beyond the shared
## origin constants.

const GRID_SIZE := Vector2i(32, 32)
const CELL_SIZE := 1.5
const GRID_ORIGIN := Vector3(-24.0, 0.0, -24.0)
const GROUND_HALF := 30.0

const HERO_POS := Vector3(0, 0, 4)
const TORCH_HEIGHT := 1.3
const TORCHES: Array[Vector3] = [Vector3(-8, 0, -6), Vector3(7, 0, -9), Vector3(10, 0, 5)]
const LOG_PILES: Array[Vector3] = [Vector3(-6, 0, 7), Vector3(9, 0, -3)]

const SOOT_POOL := 256

var _soot: Array[Decal] = []
var _soot_next := 0


func _ready() -> void:
	_build_ground()
	_build_props()


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


## World zones that burn as wood (log piles), for the controller's material pass.
func wood_zones() -> Array:
	var zones: Array = []
	for pos in LOG_PILES:
		zones.append({"pos": pos, "radius": 1.4})
	return zones


## World zones that cannot ignite at all (stone ring, rocks).
func inert_zones() -> Array:
	return [{"pos": HERO_POS, "radius": 2.3}]


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
	var ground := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(GROUND_HALF * 2.0, GROUND_HALF * 2.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.10, 0.095, 0.07)
	material.roughness = 1.0
	ground.mesh = mesh
	ground.material_override = material
	add_child(ground)


func _build_props() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.23, 0.15, 0.09)
	wood.roughness = 0.95
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.16, 0.16, 0.17)
	stone.roughness = 0.9
	var bark_texture := _log_texture()
	var bark := StandardMaterial3D.new()
	bark.albedo_texture = bark_texture
	bark.roughness = 1.0
	var ember_log := StandardMaterial3D.new()
	ember_log.albedo_texture = bark_texture
	ember_log.albedo_color = Color(0.42, 0.38, 0.35)
	ember_log.roughness = 0.95
	ember_log.emission_enabled = true
	ember_log.emission = Color(0.75, 0.2, 0.04)
	ember_log.emission_energy_multiplier = 0.15

	for pos in TORCHES:
		var pole := MeshInstance3D.new()
		var pole_mesh := CylinderMesh.new()
		pole_mesh.top_radius = 0.05
		pole_mesh.bottom_radius = 0.07
		pole_mesh.height = 1.3
		pole.mesh = pole_mesh
		pole.material_override = wood
		pole.position = pos + Vector3(0, 0.65, 0)
		add_child(pole)

	for pos in LOG_PILES:
		_add_log(pos + Vector3(-0.31, 0.17, 0.02), 1.15, 0.17,
			Vector3(cos(0.1), 0, sin(0.1)), bark, 0.05)
		_add_log(pos + Vector3(0.31, 0.16, -0.03), 1.05, 0.16,
			Vector3(cos(-0.12), 0, sin(-0.12)), bark, -0.1)
		_add_log(pos + Vector3(0.0, 0.17, -0.28), 1.1, 0.17,
			Vector3(cos(0.04), 0, sin(0.04)), bark, 0.2)
		_add_log(pos + Vector3(0.0, 0.26, 0.0), 1.2, 0.15,
			Vector3(cos(0.5), 0, sin(0.5)), bark, -0.35)

	_build_campfire_wood(ember_log)
	_build_soot_pool()

	for i in 6:
		var rock := MeshInstance3D.new()
		var rock_mesh := SphereMesh.new()
		rock_mesh.radius = 0.5
		rock_mesh.height = 0.7
		rock.mesh = rock_mesh
		rock.material_override = stone
		rock.position = Vector3(-22 + float(i) * 7.3, 0.1, -14 + (float(i % 3)) * 13.0)
		rock.scale = Vector3.ONE * (0.7 + 0.3 * float(i % 4))
		add_child(rock)

	var dirt := MeshInstance3D.new()
	var dirt_mesh := CylinderMesh.new()
	dirt_mesh.top_radius = 2.3
	dirt_mesh.bottom_radius = 2.3
	dirt_mesh.height = 0.04
	dirt.mesh = dirt_mesh
	var dirt_material := StandardMaterial3D.new()
	dirt_material.albedo_color = Color(0.09, 0.075, 0.06)
	dirt_material.roughness = 1.0
	dirt.material_override = dirt_material
	dirt.position = HERO_POS + Vector3(0, 0.015, 0)
	add_child(dirt)

	for k in 9:
		var angle := TAU * float(k) / 9.0
		var stone_node := MeshInstance3D.new()
		var stone_mesh := SphereMesh.new()
		stone_mesh.radius = 0.2
		stone_mesh.height = 0.32
		stone_node.mesh = stone_mesh
		stone_node.material_override = stone
		stone_node.position = HERO_POS + Vector3(cos(angle) * 1.15, 0.08,
			sin(angle) * 1.15)
		add_child(stone_node)


## Log lying along [param axis], [param center] is the log's midpoint. The
## basis is built directly; the cylinder mesh's axis is its local Y.
func _add_log(center: Vector3, length: float, radius: float, axis: Vector3,
		material: StandardMaterial3D, roll := 0.0) -> void:
	var log_mesh := CylinderMesh.new()
	log_mesh.top_radius = radius
	log_mesh.bottom_radius = radius
	log_mesh.height = length
	var log_node := MeshInstance3D.new()
	log_node.mesh = log_mesh
	log_node.material_override = material
	var y := axis.normalized()
	var x := y.cross(Vector3.UP)
	x = x.normalized() if x.length() > 0.001 else Vector3.RIGHT
	var z := x.cross(y).normalized()
	log_node.basis = Basis(x.rotated(y, roll), y, z.rotated(y, roll))
	log_node.position = center
	add_child(log_node)


## Fuel bed of the hero campfire: five logs radiating from the middle, inner
## ends raised, glowing slightly through the ember material.
func _build_campfire_wood(ember_log: StandardMaterial3D) -> void:
	for k in 5:
		var angle := TAU * float(k) / 5.0 + 0.3
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var inner := HERO_POS + dir * 0.08 + Vector3(0, 0.26, 0)
		var outer := HERO_POS + dir * 0.92 + Vector3(0, 0.1, 0)
		_add_log((inner + outer) * 0.5, inner.distance_to(outer), 0.1,
			outer - inner, ember_log, float(k) * 1.7)
	for k in 2:
		var angle := 1.1 + TAU * float(k) / 2.0
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		_add_log(HERO_POS + dir * 0.12 + Vector3(0, 0.36, 0), 0.7, 0.075,
			Vector3(-dir.z, 0.25, dir.x), ember_log, 0.8)


## Bark on the cylinder side (UV v < 0.5), growth rings on both caps
## (CylinderMesh paints them as circles at UV (0.25, 0.75) and (0.75, 0.75)).
func _log_texture() -> ImageTexture:
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var bark := Color(0.25, 0.165, 0.095)
	var bark_dark := Color(0.13, 0.085, 0.05)
	var wood_light := Color(0.66, 0.52, 0.34)
	var wood_dark := Color(0.42, 0.3, 0.17)
	for y in size:
		var v := 1.0 - float(y) / float(size)
		for x in size:
			if v < 0.5:
				var groove := 0.5 + 0.5 * sin(float(x) * 0.42
					+ 2.6 * sin(float(x) * 0.11))
				var crack := smoothstep(0.82, 0.95, 0.5 + 0.5
					* sin(float(x) * 0.21 + float(y) * 0.047))
				img.set_pixel(x, y, bark.lerp(bark_dark,
					0.55 * groove + 0.45 * crack))
				continue
			var cap_x := 64.0 if x < 128 else 192.0
			var d := Vector2(float(x) - cap_x, float(y) - 64.0).length()
			if d > 62.0:
				img.set_pixel(x, y, bark_dark)
				continue
			var ring := 0.5 + 0.5 * sin(d * 0.62)
			var col := wood_light.lerp(wood_dark, ring)
			if sin(atan2(float(y) - 64.0, float(x) - cap_x) * 7.0) > 0.88:
				col = col * 0.55
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


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
