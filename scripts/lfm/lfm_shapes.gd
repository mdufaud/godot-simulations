class_name LfmShapes extends RefCounted


static func wing_mesh(half_thickness: float) -> Mesh:
	var outline := [Vector2(-0.375, 0.0), Vector2(0.375, -0.27),
		Vector2(0.375, 0.27)]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		var corners := outline if side < 0.0 else [outline[0], outline[2], outline[1]]
		for corner in corners:
			surface.add_vertex(Vector3(corner.x, side * half_thickness, corner.y))
	for edge in 3:
		var next := (edge + 1) % 3
		var a: Vector2 = outline[edge]
		var b: Vector2 = outline[next]
		for point in [Vector3(a.x, -half_thickness, a.y),
			Vector3(b.x, -half_thickness, b.y),
			Vector3(b.x, half_thickness, b.y),
			Vector3(a.x, -half_thickness, a.y),
			Vector3(b.x, half_thickness, b.y),
			Vector3(a.x, half_thickness, a.y)]:
			surface.add_vertex(point)
	surface.generate_normals()
	return surface.commit()


static func cell_sdf(config: LfmConfig) -> PackedFloat32Array:
	var d := config.grid_dims
	var h := config.cell_size_m()
	var out := PackedFloat32Array()
	out.resize(d.x * d.y * d.z)
	for x in d.x:
		for y in d.y:
			for z in d.z:
				var p := Vector3(x + 0.5, y + 0.5, z + 0.5) * h
				var value := 100.0
				if config.scenario == LfmConfig.Scenario.WIND_TUNNEL and config.solid_enabled:
					var reach := clampf((p.x - 0.55) / 0.75, 0.0, 1.0)
					var span := 0.27 * reach
					value = maxf(absf(p.y - 0.5) - h, absf(p.z - 0.5) - span)
					value = maxf(value, 0.55 - p.x)
					value = maxf(value, p.x - 1.30)
				out[(x * d.y + y) * d.z + z] = value
	return out


static func cylinder_sdf(p: Vector3, center: Vector3, radius_m: float,
		half_length_m: float) -> float:
	var radial := Vector2(p.y - center.y, p.z - center.z).length() - radius_m
	var axial := absf(p.x - center.x) - half_length_m
	return minf(maxf(radial, axial), 0.0) + Vector2(maxf(radial, 0.0),
		maxf(axial, 0.0)).length()


static func initial_velocity(config: LfmConfig, axis: int) -> PackedFloat32Array:
	var d := config.grid_dims
	var fd := d + Vector3i(1 if axis == 0 else 0, 1 if axis == 1 else 0,
		1 if axis == 2 else 0)
	var h := config.cell_size_m()
	var result := PackedFloat32Array()
	result.resize(fd.x * fd.y * fd.z)
	var angle := deg_to_rad(config.inlet_angle_deg)
	for x in fd.x:
		for y in fd.y:
			for z in fd.z:
				var pos := Vector3(x + (0.0 if axis == 0 else 0.5),
					y + (0.0 if axis == 1 else 0.5),
					z + (0.0 if axis == 2 else 0.5)) * h
				var vel := Vector3(config.inlet_speed_mps * cos(angle),
					config.inlet_speed_mps * sin(angle), 0.0)
				if config.scenario == LfmConfig.Scenario.VORTEX_RING:
					vel = _ring_velocity(pos)
				result[(x * fd.y + y) * fd.z + z] = vel[axis]
	return result


static func initial_smoke(config: LfmConfig) -> PackedFloat32Array:
	var d := config.grid_dims
	var h := config.cell_size_m()
	var result := PackedFloat32Array()
	result.resize(d.x * d.y * d.z)
	for x in d.x:
		for y in d.y:
			for z in d.z:
				var p := Vector3(x + 0.5, y + 0.5, z + 0.5) * h
				var value := 0.0
				if config.scenario == LfmConfig.Scenario.VORTEX_RING:
					var radius := Vector2(p.y - 0.5, p.z - 0.5).length()
					var q := (p.x - 0.5) ** 2 + (radius - 0.20) ** 2
					value = exp(-q / (2.0 * 0.055 ** 2))
				result[(x * d.y + y) * d.z + z] = value
	return result


static func _ring_velocity(p: Vector3) -> Vector3:
	var x := p.x - 0.5
	var y := p.y - 0.5
	var z := p.z - 0.5
	var r := sqrt(y * y + z * z)
	var sigma2 := 0.055 ** 2
	var g := exp(-(x * x + (r - 0.20) ** 2) / (2.0 * sigma2))
	var strength := 0.10
	var axial := strength * g * (2.0 - r * (r - 0.20) / sigma2)
	var radial_factor := strength * x * g / sigma2
	return Vector3(axial, radial_factor * y, radial_factor * z)
