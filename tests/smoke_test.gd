extends "res://tests/test_case.gd"
## Value gates of the smoke core: config and preset validation, grid sizing,
## push-constant layout, obstacle and emitter packing, brush plane math and the
## GDScript mesh voxelizer. No scene, no GPU.

const PRESETS: Array[String] = [
	"res://resources/smoke/presets/chimney_yard.tres",
	"res://resources/smoke/presets/wind_tunnel.tres",
	"res://resources/smoke/presets/vortex_cannon.tres",
	"res://resources/smoke/presets/dry_ice.tres",
]


func _initialize() -> void:
	_test_validation()
	_test_grid_sizing()
	_test_world_to_cell()
	_test_push_constants()
	_test_shader_defines()
	_test_pack_box()
	_test_emitter()
	_test_source_cap()
	_test_brush_source()
	_test_splat_hit()
	_test_voxelizer()
	_finish("smoke")


func _test_validation() -> void:
	_check(SmokeConfig.new().validate() == "", "default config is invalid")
	for path in PRESETS:
		var preset: SmokePreset = load(path)
		_check(preset != null and preset.validate() == "", "preset %s is invalid" % path)
	var bad: Array[SmokeConfig] = []
	for i in 6:
		bad.append(SmokeConfig.new())
	bad[0].domain_size_m = Vector3(6.0, -1.0, 6.0)
	bad[1].grid_cell_budget = 1000
	bad[2].pressure_iterations = 0
	bad[3].scattering_albedo = 1.5
	bad[4].phase_g = 1.0
	bad[5].light_downsample = 5
	for i in bad.size():
		_check(bad[i].validate() != "", "invalid config %d passed validation" % i)
	var thin := SmokeConfig.new()
	thin.domain_size_m = Vector3(20.0, 0.2, 20.0)
	_check(thin.validate() != "", "a domain thinner than 8 cells passed validation")


func _test_grid_sizing() -> void:
	var config := SmokeConfig.new()
	_check(config.grid_dims() == Vector3i(64, 97, 64), "yard grid is %s" % config.grid_dims())
	_check(absf(config.cell_size_m() - 0.0932170) < 1e-6, "yard cell is %f" % config.cell_size_m())
	config.domain_size_m = Vector3(12.0, 4.0, 4.0)
	_check(config.grid_dims() == Vector3i(153, 51, 51), "tunnel grid is %s" % config.grid_dims())
	config.domain_size_m = Vector3(6.0, 9.0, 6.0)
	config.grid_cell_budget = 3100000
	_check(config.grid_dims() == Vector3i(127, 191, 127), "ultra grid is %s" % config.grid_dims())
	config.grid_cell_budget = 400000
	config.light_downsample = 4
	_check(config.light_dims() == Vector3i(16, 25, 16), "quarter light grid is %s" % config.light_dims())
	_check(SmokeSolver.bytes_per_cell(true) == 120 and SmokeSolver.bytes_per_cell(false) == 96,
		"grid cells cost %d / %d bytes" % [SmokeSolver.bytes_per_cell(true),
			SmokeSolver.bytes_per_cell(false)])


func _test_world_to_cell() -> void:
	var solver := SmokeSolver.new()
	var config := solver.config
	_check(solver.world_to_cell(config.domain_origin_m).is_zero_approx(), "origin is not cell 0")
	var far := solver.world_to_cell(config.domain_origin_m + config.grid_extent_m())
	_check(far.distance_to(Vector3(64.0, 97.0, 64.0)) < 1e-3, "far corner maps to %s" % far)
	var center := solver.world_to_cell(config.domain_origin_m + config.grid_extent_m() * 0.5)
	_check(center.distance_to(Vector3(32.0, 48.5, 32.0)) < 1e-3, "centre maps to %s" % center)


func _test_push_constants() -> void:
	var solver := SmokeSolver.new()
	var config := solver.config
	config.domain_origin_m = Vector3(-3.0, 0.5, -2.0)
	config.smoke_weight_mps2 = 0.7
	config.wind_speed_mps = 2.0
	config.wind_direction_deg = 30.0
	solver.light_direction = Vector3(2.0, 6.0, 3.0)
	var pc := solver.make_push_constants(3, 2, 1)
	_check(pc.size() == 112, "push constants are %d bytes" % pc.size())
	var ints := {0: 64, 4: 97, 8: 64, 12: 2, 96: 3, 100: 2, 104: 1, 108: 0}
	for offset in ints:
		_check(pc.decode_s32(offset) == ints[offset], "int lane %d is %d" % [offset, pc.decode_s32(offset)])
	var floats := {16: -3.0, 20: 0.5, 24: -2.0, 28: 0.0932170, 32: 0.0166667, 36: 0.04, 40: 0.7,
		44: 0.35, 48: 0.02, 52: 0.6, 56: 0.05, 60: 0.25, 64: 1.7320508, 68: 1.0, 72: 6.0, 76: 0.0,
		80: 0.2857143, 84: 0.8571429, 88: 0.4285714, 92: 1.5}
	for offset in floats:
		_check(absf(pc.decode_float(offset) - floats[offset]) < 1e-6,
			"float lane %d is %f" % [offset, pc.decode_float(offset)])
	var common := FileAccess.get_file_as_string("res://shaders/smoke/smoke_common.comp")
	var block := common.get_slice("uniform Params {", 1).get_slice("} pc;", 0)
	var members := PackedStringArray()
	for line in block.split("\n"):
		var words := line.strip_edges().split(" ", false)
		if words.is_empty():
			continue
		_check(words[0] == "ivec4" or words[0] == "vec4", "push block member is not 16 bytes: %s" % line)
		members.append(words[1].trim_suffix(";"))
	_check(members == PackedStringArray(["dims", "domain", "sim", "decay", "wind", "light", "counts"]),
		"GLSL push block is %s" % members)
	_check(members.size() * 16 == SmokeSolver.PUSH_CONSTANT_BYTES,
		"GLSL push block has %d members" % members.size())


func _test_shader_defines() -> void:
	var defines := SmokeSolver.glsl_defines()
	for file in DirAccess.get_files_at("res://shaders/smoke"):
		if not file.ends_with(".comp"):
			continue
		var source := FileAccess.get_file_as_string("res://shaders/smoke/" + file)
		_check(not source.contains("#define"), "%s declares its own #define" % file)
	for name in ["WG_X", "WG_Y", "WG_Z", "SOURCE_VEC4S", "OBSTACLE_VEC4S", "OBSTACLE_SPHERE"]:
		_check(defines.contains("#define %s " % name), "%s is not injected" % name)


func _test_pack_box() -> void:
	var xform := Transform3D(Basis(Vector3.UP, deg_to_rad(30.0)), Vector3(1.0, 2.0, 3.0))
	var half := Vector3(0.5, 0.25, 0.75)
	var packed := SmokeSolver.pack_box(xform, half, Vector3.ZERO, Vector3.ZERO)
	_check(packed.size() == SmokeSolver.OBSTACLE_VEC4S * 4, "box packs %d floats" % packed.size())
	_check(int(packed[3]) == SmokeSolver.OBSTACLE_BOX, "box kind is %f" % packed[3])
	var r := xform * half - xform.origin
	var local := Vector3(
		Vector3(packed[8], packed[9], packed[10]).dot(r),
		Vector3(packed[12], packed[13], packed[14]).dot(r),
		Vector3(packed[16], packed[17], packed[18]).dot(r))
	_check(local.distance_to(half) < 1e-5, "yawed corner maps back to %s" % local)
	var sphere := SmokeSolver.pack_sphere(Vector3(1, 2, 3), 0.4, Vector3(1, 0, 0), Vector3(0, 2, 0))
	_check(int(sphere[3]) == SmokeSolver.OBSTACLE_SPHERE and is_equal_approx(sphere[4], 0.4)
		and is_equal_approx(sphere[20], 1.0) and is_equal_approx(sphere[25], 2.0),
		"sphere packing is wrong")


func _test_emitter() -> void:
	var emitter := SmokeEmitter.new()
	_check(emitter.is_on(0.0) and emitter.is_on(123.4), "continuous emitter switched off")
	emitter.pulse_period_s = 1.6
	emitter.pulse_on_s = 0.15
	_check(emitter.validate() == "", "pulsed emitter is invalid")
	_check(emitter.is_on(0.0) and emitter.is_on(0.1) and not emitter.is_on(0.2)
		and emitter.is_on(1.65) and not emitter.is_on(1.8), "pulse gating is wrong")
	emitter.pulse_on_s = 2.0
	_check(emitter.validate() != "", "pulse longer than its period passed validation")
	emitter.density_per_s = 4.0
	emitter.heat_k_per_s = -10.0
	emitter.velocity_mps = Vector3(2.0, 0.0, 0.0)
	emitter.relax_hz = 5.0
	var packed := emitter.pack(2.0, 3.0, 0.5)
	_check(packed.size() == SmokeSolver.SOURCE_VEC4S * 4, "emitter packs %d floats" % packed.size())
	_check(is_equal_approx(packed[3], 8.0) and is_equal_approx(packed[7], -30.0)
		and is_equal_approx(packed[8], 1.0) and is_equal_approx(packed[11], 5.0),
		"emitter scales are not applied")


func _test_source_cap() -> void:
	var solver := SmokeSolver.new()
	var packed := PackedFloat32Array()
	for i in 18:
		packed.append_array(SmokeEmitter.new().pack(1.0, 1.0, 1.0))
	solver.set_sources(packed)
	_check(solver.source_count() == 16, "source slots hold %d after overflowing" % solver.source_count())


# Held until the stroke changes: a frame that runs no substep must lose nothing.
func _test_brush_source() -> void:
	var pointer := SmokePointer.new()
	_check(pointer.pack_source().is_empty(), "an idle brush emits a source")
	pointer._stroke = SmokePointer.Brush.INJECT
	pointer._stroke_point = Vector3(1.0, 2.0, 3.0)
	pointer._stroke_previous = pointer._stroke_point
	pointer._process(0.1)
	var inject := pointer.pack_source()
	_check(inject.size() == 12 and is_equal_approx(inject[3], 8.0) and is_equal_approx(inject[7], 20.0)
		and inject == pointer.pack_source(), "inject brush is not a steady source: %s" % inject)
	pointer._stroke = SmokePointer.Brush.PUSH
	pointer._stroke_point += Vector3(0.2, 0.0, 0.0)
	pointer._process(0.1)
	var push := pointer.pack_source()
	_check(push.size() == 12 and is_equal_approx(push[3], 0.0) and is_equal_approx(push[8], 2.0)
		and is_equal_approx(push[11], 30.0) and push == pointer.pack_source(),
		"push brush is not a steady 2 m/s source: %s" % push)
	pointer._stroke_point += Vector3(5.0, 0.0, 0.0)
	pointer._process(0.1)
	_check(is_equal_approx(pointer.pack_source()[8], 6.0), "push brush speed is not capped at 6 m/s")
	pointer._process(0.1)
	_check(pointer.pack_source().is_empty(), "a still push brush emits a source")
	pointer._stroke_point += Vector3(0.2, 0.0, 0.0)
	pointer._process(0.1)
	_check(pointer._release() and pointer.pack_source().is_empty(), "a released brush emits a source")
	pointer.free()


func _test_splat_hit() -> void:
	var hit = SmokePointer.splat_hit(Vector3(1, 2, 10), Vector3(0, 0, -1), Vector3.ZERO, Vector3(0, 0, 1))
	_check(hit != null and (hit as Vector3).distance_to(Vector3(1, 2, 0)) < 1e-6, "plane hit is %s" % hit)
	_check(SmokePointer.splat_hit(Vector3(0, 0, 10), Vector3(1, 0, 0), Vector3.ZERO,
		Vector3(0, 0, 1)) == null, "parallel ray hit the plane")
	_check(SmokePointer.splat_hit(Vector3(0, 0, 10), Vector3(0, 0, 1), Vector3.ZERO,
		Vector3(0, 0, 1)) == null, "plane behind the ray was hit")


func _test_voxelizer() -> void:
	var origin := Vector3(-1.0, 0.0, -1.0)
	var dims := Vector3i(20, 20, 20)
	var cell := 0.1
	var box := BoxMesh.new()
	var box_cells := SmokeVoxelizer.voxelize(_faces(box, Vector3(0.0, 1.0, 0.0)), origin, cell, dims, 2)
	var box_volume := _sum(box_cells) * cell * cell * cell
	_check(absf(box_volume - 1.0) < 0.02, "box volume is %f" % box_volume)
	_check(is_equal_approx(box_cells[_index(10, 10, 10, dims)], 1.0), "box centre is not solid")
	_check(box_cells[_index(1, 1, 1, dims)] == 0.0, "outside the box is solid")
	var sphere := SphereMesh.new()
	var sphere_volume := _sum(SmokeVoxelizer.voxelize(_faces(sphere, Vector3(0.0, 1.0, 0.0)),
		origin, cell, dims, 2)) * cell * cell * cell
	_check(absf(sphere_volume / 0.5235988 - 1.0) < 0.03, "sphere volume is %f" % sphere_volume)
	var torus := TorusMesh.new()
	var torus_cells := SmokeVoxelizer.voxelize(_faces(torus, Vector3(0.0, 1.0, 0.0)), origin,
		cell, dims, 2)
	_check(absf(_sum(torus_cells) * cell * cell * cell / 0.9252754 - 1.0) < 0.03,
		"torus volume is %f" % (_sum(torus_cells) * cell * cell * cell))
	_check(torus_cells[_index(10, 10, 10, dims)] == 0.0, "torus hole is solid")
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_X
	var open_cells := SmokeVoxelizer.voxelize(_faces(quad, Vector3(0.0, 1.0, 0.0)), origin, cell,
		dims, 2)
	_check(_sum(open_cells) == 0.0, "an open quad filled %f cells" % _sum(open_cells))


func _faces(mesh: Mesh, offset: Vector3) -> PackedVector3Array:
	var faces := mesh.get_faces()
	for i in faces.size():
		faces[i] += offset
	return faces


func _sum(values: PackedFloat32Array) -> float:
	var total := 0.0
	for value in values:
		total += value
	return total


func _index(x: int, y: int, z: int, dims: Vector3i) -> int:
	return x + dims.x * (y + dims.y * z)
