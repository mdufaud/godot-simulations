extends SceneTree
## Wall time per call of each native kernel against its GDScript body, headless:
##   godot --headless --path . -s res://tools/native_benchmark.gd

const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")
const FRACTAL := preload("res://scripts/fractal_3d/fractal_de.gd")
const CONTROLLER := preload("res://scripts/demos/ambient_fluid_controller.gd")
const PROFILE := preload("res://resources/ambient_fluid/sphere_bem.tres")
const CALLS := 20000
const PLANET_TRIANGLES := 327680
const PLANET_RUNS := 3


func _initialize() -> void:
	if not ClassDB.class_exists(&"AmbientFluidKernels"):
		printerr("native kernels are not loaded: run native/build.sh")
		quit(1)
		return
	var fixture: Node = CONTROLLER.new()
	var faces: PackedVector3Array = fixture._pool_faces_for(0)
	fixture.free()
	var matrix := MATH.diagonal_matrix(Vector3(2.0, 3.0, 4.0), 5.0)
	for index in MATH.MATRIX_SCALARS:
		matrix[index] += 0.1 * float(index % 7)
	var velocity := PackedFloat64Array([0.3, -0.2, 0.1, 1.2, -0.4, 0.8])
	var wet: Dictionary = MATH.clip_convex_mesh_below_plane(faces, Vector3.ZERO, Vector3.UP, 0.1)
	var tilted := Vector3(0.2, 1.0, -0.1)
	var fractal_params: Array[Dictionary] = [
		{fractal_type = 0, iterations = 12},
		{fractal_type = 1, iterations = 8},
		{fractal_type = 2, iterations = 12},
	]
	var point := Vector3(0.37, -0.21, 0.46)
	var planet_bytes := _planet_bytes()

	var timings := {}
	for enabled in [true, false]:
		Native.enabled = enabled
		var start := Time.get_ticks_usec()
		for _call in CALLS:
			MATH.matrix_vector_multiply(matrix, velocity)
		_record(timings, "matrix_vector_multiply", start, CALLS)
		start = Time.get_ticks_usec()
		for _call in CALLS:
			MATH.matrix_inverse(matrix)
		_record(timings, "matrix_inverse", start, CALLS)
		start = Time.get_ticks_usec()
		for _call in CALLS:
			MATH.clip_convex_mesh_below_plane(faces, Vector3.ZERO, tilted, 0.1)
		_record(timings, "clip_convex_mesh_below_plane", start, CALLS)
		start = Time.get_ticks_usec()
		for _call in CALLS:
			MATH.potential_pressure_wrench(PROFILE.face_centers_m, PROFILE.face_normals,
				PROFILE.face_areas_m2, PROFILE.slip_matrix, velocity, 998.0, 2.0,
				wet.wet_area_fractions, wet.wet_area_centers_m)
		_record(timings, "potential_pressure_wrench", start, CALLS)
		for params in fractal_params:
			start = Time.get_ticks_usec()
			for _call in CALLS:
				FRACTAL.evaluate(point, params)
			_record(timings, "fractal_de type %d" % params.fractal_type, start, CALLS)
		var best_us := INF
		for _run in PLANET_RUNS:
			var generator := PlanetGenerator.new()
			generator.triangle_count = PLANET_TRIANGLES
			generator._tri_bytes = planet_bytes
			start = Time.get_ticks_usec()
			generator._unpack_vertices()
			best_us = minf(best_us, float(Time.get_ticks_usec() - start))
		timings["planet unpack %d tris" % PLANET_TRIANGLES] = timings.get(
			"planet unpack %d tris" % PLANET_TRIANGLES, []) + [best_us]
	Native.enabled = true

	for label: String in timings:
		var native_us: float = timings[label][0]
		var gdscript_us: float = timings[label][1]
		print("BENCH %-36s native %10.2f us  gdscript %10.2f us  x%.1f" % [label, native_us,
			gdscript_us, gdscript_us / native_us])
	quit(0)


func _record(timings: Dictionary, label: String, start_us: int, calls: int) -> void:
	timings[label] = timings.get(label, []) + [float(Time.get_ticks_usec() - start_us) / calls]


func _planet_bytes() -> PackedByteArray:
	var floats := PackedFloat32Array()
	floats.resize(PLANET_TRIANGLES * PlanetGenerator.TRI_BYTES / 4)
	for index in floats.size():
		floats[index] = float(index % 977) * 0.01
	return floats.to_byte_array()
