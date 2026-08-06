class_name ClothProps extends Node3D

const WOOD := Color(0.35, 0.3, 0.26)


func build(presets: Array[ClothPreset]) -> void:
	for preset in presets:
		var basis := Basis(Vector3.UP, preset.yaw_rad)
		var size := preset.size_m
		match preset.pin:
			ClothPreset.Pin.EDGE:
				_add_pole(preset.position_m + basis * Vector3(-size.x * 0.5 - 0.04, 0.0, 0.0),
					preset.top_m + 0.4, 0.06)
			ClothPreset.Pin.TOP:
				var left := preset.position_m + basis * Vector3(-size.x * 0.5 - 0.25, 0.0, 0.0)
				var right := preset.position_m + basis * Vector3(size.x * 0.5 + 0.25, 0.0, 0.0)
				_add_pole(left, preset.top_m + 0.15, 0.05)
				_add_pole(right, preset.top_m + 0.15, 0.05)
				_add_bar(left + Vector3.UP * preset.top_m, right + Vector3.UP * preset.top_m, 0.015)
			ClothPreset.Pin.CORNERS:
				for sx in [-1.0, 1.0]:
					for sz in [-1.0, 1.0]:
						var corner := preset.position_m + basis * Vector3(
							sx * size.x * 0.5, 0.0, sz * size.y * 0.5)
						_add_pole(corner, preset.top_m, 0.045)
		if preset.boulder_radius_m > 0.0:
			_add_boulder(preset.boulder_center(), preset.boulder_radius_m)

	for rock in [[Vector3(-4.5, 0, 6.0), 0.5], [Vector3(9.0, 0, 2.5), 0.8],
			[Vector3(-9.0, 0, -5.0), 0.65], [Vector3(3.5, 0, -7.5), 0.45]]:
		_add_boulder(rock[0] + Vector3.UP * rock[1] * 0.55, rock[1])


func _add_pole(base: Vector3, height: float, radius: float) -> void:
	var instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.85
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.material = _wood_material()
	instance.mesh = mesh
	instance.position = base + Vector3.UP * height * 0.5
	add_child(instance)


func _add_bar(from: Vector3, to: Vector3, radius: float) -> void:
	var instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = from.distance_to(to)
	mesh.material = _wood_material()
	instance.mesh = mesh
	instance.position = (from + to) * 0.5
	instance.basis = Basis(Quaternion(Vector3.UP, (to - from).normalized()))
	add_child(instance)


func _add_boulder(center: Vector3, radius: float) -> void:
	var instance := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.43, 0.4)
	material.roughness = 0.95
	mesh.material = material
	instance.mesh = mesh
	instance.position = center
	instance.scale = Vector3(1.0, 0.8, 0.92)
	add_child(instance)


func _wood_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = WOOD
	material.roughness = 0.75
	return material
