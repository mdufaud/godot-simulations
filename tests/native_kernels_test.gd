extends "res://tests/test_case.gd"
## Parity of the C++ kernels (addons/physics_native) with the GDScript bodies they
## replace: every output must be bit-identical (var_to_bytes), on fixed-seed inputs.

const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")
const FRACTAL := preload("res://scripts/fractal_3d/fractal_de.gd")
const CONTROLLER := preload("res://scripts/demos/ambient_fluid_controller.gd")
const PROFILES: Array[AmbientFluidProfile3D] = [
	preload("res://resources/ambient_fluid/sphere_bem.tres"),
	preload("res://resources/ambient_fluid/body_bem.tres"),
	preload("res://resources/ambient_fluid/plate_bem.tres"),
]
const KERNELS: Array[StringName] = [&"AmbientFluidKernels", &"FractalKernels", &"PlanetKernels",
	&"SmokeKernels"]
const ROCK := preload("res://resources/fire/fire_rock_0.res")

var _rng := RandomNumberGenerator.new()
var _cases := 0


func _initialize() -> void:
	for kernel in KERNELS:
		_check(ClassDB.class_exists(kernel), "%s is not loaded: run native/build.sh" % kernel)
	if _failures == 0:
		_rng.seed = 20261022
		_test_matrices()
		_test_matrix_size_guards()
		_test_clip()
		_test_pressure()
		_test_fractal()
		_test_planet_unpack()
		_test_smoke_voxelize()
		print("native_kernels: %d cases compared, native=%s" % [_cases, Native.enabled])
	_finish("native_kernels")


func _check_identical(owner: Object, method: StringName, args: Array) -> void:
	var was_enabled := Native.enabled
	var native: Variant = owner.callv(method, args)
	Native.enabled = false
	var reference: Variant = owner.callv(method, args)
	Native.enabled = was_enabled
	_cases += 1
	_check(var_to_bytes(native) == var_to_bytes(reference),
		"%s case %d: native %s, gdscript %s" % [method, _cases, native, reference])


func _random_array(size: int, span: float) -> PackedFloat64Array:
	var values := PackedFloat64Array()
	values.resize(size)
	for index in size:
		values[index] = _rng.randf_range(-span, span)
	return values


func _random_vector(span: float) -> Vector3:
	return Vector3(_rng.randf_range(-span, span), _rng.randf_range(-span, span),
		_rng.randf_range(-span, span))


# The kernels are bound straight to ClassDB, so a caller can bypass the GDScript
# size checks: mismatched sizes must come back empty, not read past the buffer.
func _test_matrix_size_guards() -> void:
	var kernels: Object = ClassDB.instantiate(&"AmbientFluidKernels")
	var short_matrix := PackedFloat64Array([1.0, 2.0, 3.0, 4.0, 5.0])
	_check((kernels.matrix_vector_multiply(short_matrix, _random_array(6, 1.0)) as PackedFloat64Array).is_empty(),
		"matrix_vector_multiply accepted a 5-element matrix for a 6-vector")
	_check((kernels.matrix_inverse(PackedFloat64Array([1.0]), 6, 1.0e-12) as PackedFloat64Array).is_empty(),
		"matrix_inverse accepted a 1-element matrix of size 6")
	_check((kernels.matrix_inverse(_random_array(36, 1.0), -6, 1.0e-12) as PackedFloat64Array).is_empty(),
		"matrix_inverse accepted a negative size")
	var short_surface: Dictionary = kernels.surface_wrench(PackedVector3Array([Vector3.ONE]),
		PackedVector3Array([Vector3.UP]), PackedFloat64Array([1.0]), _random_array(2, 1.0),
		998.0, 0.001, PI * 0.5, 1.0, PackedFloat64Array(), PackedVector3Array())
	_check(int(short_surface.attached_faces) == 0
		and (short_surface.pressure as PackedFloat64Array) == PackedFloat64Array([0, 0, 0, 0, 0, 0]),
		"surface_wrench accepted a 2-element generalized velocity")


func _test_matrices() -> void:
	for _case in 100:
		var matrix := _random_array(MATH.MATRIX_SCALARS, 10.0)
		_check_identical(MATH, &"matrix_vector_multiply", [matrix, _random_array(MATH.MATRIX_SIZE, 10.0)])
		_check_identical(MATH, &"matrix_inverse", [matrix])
		for index in MATH.MATRIX_SIZE:
			matrix[index * MATH.MATRIX_SIZE + index] += 60.0
		_check_identical(MATH, &"matrix_inverse", [matrix])
	_check_identical(MATH, &"matrix_inverse", [MATH.zero_matrix()])


func _test_clip() -> void:
	var fixture: Node = CONTROLLER.new()
	for type_index in PROFILES.size():
		var faces: PackedVector3Array = fixture._pool_faces_for(type_index)
		for _case in 100:
			_check_identical(MATH, &"clip_convex_mesh_below_plane", [faces, Vector3.ZERO,
				_random_vector(1.0), _rng.randf_range(-1.0, 1.0)])
	fixture.free()


func _test_pressure() -> void:
	var fixture: Node = CONTROLLER.new()
	for type_index in PROFILES.size():
		var profile := PROFILES[type_index]
		var faces: PackedVector3Array = fixture._pool_faces_for(type_index)
		for _case in 100:
			var wet := {}
			if _rng.randf() < 0.5:
				wet = MATH.clip_convex_mesh_below_plane(faces, Vector3.ZERO, _random_vector(1.0),
					_rng.randf_range(-0.3, 0.3))
			_check_identical(MATH, &"surface_wrench", [profile.face_centers_m,
				profile.face_normals, profile.face_areas_m2,
				_random_array(MATH.MATRIX_SIZE, 3.0), 998.0,
				[0.0, 0.001002, 185.13][_rng.randi_range(0, 2)],
				_rng.randf_range(PI * 0.4, PI * 1.1),
				profile.surface_length_m(),
				wet.get("wet_area_fractions", PackedFloat64Array()),
				wet.get("wet_area_centers_m", PackedVector3Array())])
	fixture.free()


func _test_fractal() -> void:
	for fractal_type in 3:
		for _case in 200:
			_check_identical(FRACTAL, &"evaluate", [_random_vector(2.0), {
				fractal_type = fractal_type,
				iterations = _rng.randi_range(1, 40),
				apollonian_scale = _rng.randf_range(1.0, 1.8),
				klein_r = _rng.randf_range(1.8, 2.0),
				klein_i = _rng.randf_range(-0.05, 0.05),
				klein_box_x = _rng.randf_range(0.8, 1.2),
				klein_box_z = _rng.randf_range(0.8, 1.2),
			}])


func _test_smoke_voxelize() -> void:
	var torus := TorusMesh.new()
	for _case in 6:
		var mesh: Mesh = ROCK if _case % 2 == 0 else torus
		var xform := Transform3D(Basis.from_euler(_random_vector(PI)).scaled(Vector3.ONE
			* _rng.randf_range(0.6, 1.4)), _random_vector(0.3) + Vector3(0.0, 0.8, 0.0))
		var faces := PackedVector3Array()
		for vertex in mesh.get_faces():
			faces.append(xform * vertex)
		_check_identical(SmokeVoxelizer, &"voxelize", [faces, Vector3(-1.0, 0.0, -1.0),
			_rng.randf_range(0.05, 0.09), Vector3i(30, 24, 30), 2 + _case % 2])


func _test_planet_unpack() -> void:
	var floats := PackedFloat32Array()
	floats.resize(1000 * PlanetGenerator.TRI_BYTES / 4)
	for index in floats.size():
		floats[index] = _rng.randf_range(-100.0, 100.0)
	var outputs := []
	var was_enabled := Native.enabled
	for enabled in [was_enabled, false]:
		Native.enabled = enabled
		var generator := PlanetGenerator.new()
		generator.triangle_count = 1000
		generator._tri_bytes = floats.to_byte_array()
		generator._unpack_vertices()
		outputs.append(var_to_bytes([generator._positions, generator._normals]))
	Native.enabled = was_enabled
	_cases += 1
	_check(outputs[0] == outputs[1], "unpack_vertices: native and gdscript vertices differ")
