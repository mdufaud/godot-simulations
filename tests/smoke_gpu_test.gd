extends "res://tests/test_case.gd"
## GPU gates of SmokeSolver on a 16 x 24 x 16 grid of 10 cm cells: each multigrid
## V-cycle cuts the residual on even and odd grids, the pressure
## solve converges and removes most of an impulse's divergence, the Medium tier's
## v-cycle count converges on its own grid, advection keeps mass without decay,
## heat and smoke weight move smoke the right way, air does not flow into solids
## nor smoke through a wall, clear() empties, dyed sources keep their colour,
## MacCormack keeps a transported blob sharper than first-order advection.

const DIMS := Vector3i(16, 24, 16)
const FACES := DIMS + Vector3i.ONE
const CELL_M := 0.1
const NEIGHBORS: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if RenderingServer.get_rendering_device() == null:
		_check(false, "no RenderingDevice")
		_finish("smoke_gpu")
		return
	await _multigrid_case(Vector3i(16, 24, 16))
	await _multigrid_case(Vector3i(17, 25, 17))
	await _divergence_case()
	await _tier_convergence_case()
	await _mass_case()
	await _buoyancy_case("hot", 300.0, 0.0, true)
	await _buoyancy_case("cold", -300.0, 0.0, false)
	await _buoyancy_case("heavy", 0.0, 2.0, false)
	await _obstacle_case()
	await _leak_case()
	await _dye_case()
	var first_order := await _peak_after_transport(false)
	var maccormack := await _peak_after_transport(true)
	print("SMOKE GPU transported peak first-order=%.4f maccormack=%.4f" % [first_order, maccormack])
	_check(maccormack > first_order * 1.1, "MacCormack kept no sharper peak than first order")
	_finish("smoke_gpu")


func _solver() -> SmokeSolver:
	var config := SmokeConfig.new()
	config.domain_size_m = Vector3(DIMS) * CELL_M
	config.domain_origin_m = Vector3(-0.8, 0.0, -0.8)
	config.grid_cell_budget = DIMS.x * DIMS.y * DIMS.z
	config.buoyancy_mps2_per_k = 0.0
	config.smoke_weight_mps2 = 0.0
	config.density_decay_hz = 0.0
	config.temperature_decay_hz = 0.0
	config.velocity_decay_hz = 0.0
	config.vorticity_confinement = 0.0
	config.wind_relax_hz = 0.0
	var solver := SmokeSolver.new()
	solver.config = config
	return solver


func _start(solver: SmokeSolver, dims := DIMS) -> bool:
	var error := solver.start()
	_check(error == "", "solver did not start: %s" % error)
	var deadline := Time.get_ticks_msec() + 10000
	while not solver.is_ready() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(solver.is_ready(), "solver never became ready")
	_check(solver.grid_dims() == dims, "grid is %s" % solver.grid_dims())
	return solver.is_ready()


func _steps(solver: SmokeSolver, count: int) -> void:
	for i in count:
		solver.advance(1)
		await process_frame


func _divergence_case() -> void:
	var solver := _solver()
	solver.config.pressure_vcycles = 6
	if not await _start(solver):
		return
	solver.set_sources(SmokeSolver.pack_source(Vector3(0.0, 1.2, 0.0), Vector3.ONE * 0.4, 0.0, 0.0,
		Vector3(3.0, 1.0, 0.0), 30.0))
	await _steps(solver, 1)
	var before := _rms(_channel(solver.read_field("divergence"), 0, 2))
	var after := _rms(_divergence(_read_velocity(solver)))
	var residual := _poisson_residual(solver, DIMS, CELL_M)
	print("SMOKE GPU divergence rms before=%.5f after=%.5f ratio=%.4f poisson residual=%.5f" % [
		before, after, after / maxf(before, 1e-9), residual])
	_check(before > 0.1, "the impulse produced no divergence (%f)" % before)
	_check(residual < 0.05, "6 v-cycles left a %.1f%% Poisson residual" % (100.0 * residual))
	_check(after < before * 0.01, "projection left %.2f%% of the divergence" % (100.0 * after / before))
	solver.clear()
	await process_frame
	await process_frame
	var velocity := _read_velocity(solver)
	_check(_max(solver.read_field("scalar")) == 0.0 and _max(velocity[0]) == 0.0
		and _max(velocity[1]) == 0.0 and _max(velocity[2]) == 0.0,
		"clear() left smoke or motion behind")
	solver.stop()


## One impulse solved cold by k V-cycles: the residual falls with every cycle.
func _multigrid_case(dims: Vector3i) -> void:
	var residuals := PackedFloat32Array()
	for vcycles in [1, 2, 3, 4]:
		var solver := _solver()
		solver.config.domain_size_m = Vector3(dims) * CELL_M
		solver.config.grid_cell_budget = dims.x * dims.y * dims.z
		solver.config.pressure_vcycles = vcycles
		if not await _start(solver, dims):
			return
		solver.set_sources(SmokeSolver.pack_source(Vector3(0.0, 1.2, 0.0), Vector3.ONE * 0.4, 0.0,
			0.0, Vector3(3.0, 1.0, 0.0), 30.0))
		await _steps(solver, 1)
		residuals.append(_poisson_residual(solver, dims, CELL_M))
		solver.stop()
	print("SMOKE GPU multigrid %s residual per v-cycle count %s" % [dims, residuals])
	for i in range(1, residuals.size()):
		_check(residuals[i] < residuals[i - 1] * 0.7,
			"multigrid on %s did not converge: %s" % [dims, residuals])


## A warm-started plume at the Medium tier's iteration count, on the Medium grid.
func _tier_convergence_case() -> void:
	var config := SmokeConfig.new()
	config.grid_cell_budget = SmokeQualityProfile.GRID_CELL_BUDGET[SmokeQualityProfile.Tier.MEDIUM]
	config.pressure_vcycles = SmokeQualityProfile.PRESSURE_VCYCLES[SmokeQualityProfile.Tier.MEDIUM]
	config.vorticity_confinement = 0.0
	config.wind_relax_hz = 0.0
	var solver := SmokeSolver.new()
	solver.config = config
	if not await _start(solver, config.grid_dims()):
		return
	solver.set_sources(SmokeSolver.pack_source(Vector3(0.0, 1.0, 0.0), Vector3(0.5, 0.3, 0.5), 3.0,
		400.0, Vector3(0.0, 1.5, 0.0), 4.0))
	await _steps(solver, 60)
	var residual := _poisson_residual(solver, config.grid_dims(), config.cell_size_m())
	print("SMOKE GPU medium tier %d v-cycles poisson residual=%.5f" % [config.pressure_vcycles,
		residual])
	_check(residual < 0.05, "Medium tier left a %.1f%% Poisson residual" % (100.0 * residual))
	solver.stop()


func _mass_case() -> void:
	var solver := _solver()
	if not await _start(solver):
		return
	solver.set_sources(SmokeSolver.pack_source(Vector3(0.0, 1.2, 0.0), Vector3.ONE * 0.5, 60.0, 0.0,
		Vector3.ZERO, 0.0)
		+ SmokeSolver.pack_source(Vector3(0.2, 1.2, 0.0), Vector3.ONE * 0.4, 0.0, 0.0,
			Vector3(0.0, 0.4, 0.0), 30.0)
		+ SmokeSolver.pack_source(Vector3(-0.2, 1.2, 0.0), Vector3.ONE * 0.4, 0.0, 0.0,
			Vector3(0.0, -0.4, 0.0), 30.0))
	await _steps(solver, 1)
	solver.set_sources(PackedFloat32Array())
	var initial := _channel_sum(solver.read_field("scalar"), 0)
	await _steps(solver, 60)
	var final := _channel_sum(solver.read_field("scalar"), 0)
	print("SMOKE GPU mass initial=%.4f final=%.4f drift=%.2f%%" % [initial, final,
		100.0 * (final / maxf(initial, 1e-9) - 1.0)])
	_check(initial > 1.0, "the density impulse injected nothing (%f)" % initial)
	_check(absf(final / initial - 1.0) < 0.05, "mass drifted %.2f%%" % (100.0 * (final / initial - 1.0)))
	solver.stop()


func _buoyancy_case(label: String, heat_k_per_s: float, weight_mps2: float, rises: bool) -> void:
	var solver := _solver()
	solver.config.buoyancy_mps2_per_k = 0.05
	solver.config.smoke_weight_mps2 = weight_mps2
	if not await _start(solver):
		return
	var source_y := 0.5 if rises else 1.9
	solver.set_sources(SmokeSolver.pack_source(Vector3(0.0, source_y, 0.0), Vector3.ONE * 0.2,
		4.0, heat_k_per_s, Vector3.ZERO, 0.0))
	await _steps(solver, 120)
	var centroid := _centroid_y(solver.read_field("scalar"))
	print("SMOKE GPU %s centroid y=%.3f from %.2f" % [label, centroid, source_y])
	if rises:
		_check(centroid > source_y + 0.3, "%s smoke centroid at %.3f m" % [label, centroid])
	else:
		_check(centroid < source_y - 0.3, "%s smoke centroid at %.3f m" % [label, centroid])
	solver.stop()


func _obstacle_case() -> void:
	var solver := _solver()
	solver.set_static_occupancy(SmokeVoxelizer.voxelize(_box_faces(Vector3(0.4, 0.6, 0.0), 0.4),
		solver.config.domain_origin_m, CELL_M, DIMS, 2))
	if not await _start(solver):
		return
	solver.set_obstacles(SmokeSolver.pack_sphere(Vector3(-0.3, 1.4, 0.0), 0.3, Vector3.ZERO,
		Vector3.ZERO))
	solver.set_sources(SmokeSolver.pack_source(Vector3(0.0, 1.0, 0.0), Vector3.ONE * 0.8, 5.0, 0.0,
		Vector3(0.0, 0.5, 0.0), 2.0))
	await _steps(solver, 30)
	var obstacle := solver.read_field("obstacle")
	var velocity := _read_velocity(solver)
	var solid_cells := 0
	var faces := 0
	var inflow := 0.0
	for z in DIMS.z:
		for y in DIMS.y:
			for x in DIMS.x:
				var cell := _index(Vector3i(x, y, z))
				if obstacle[cell * 4 + 3] > 0.5:
					solid_cells += 1
					continue
				for offset in NEIGHBORS:
					var n := Vector3i(x, y, z) + offset
					if not _in_grid(n) or obstacle[_index(n) * 4 + 3] <= 0.5:
						continue
					var axis := 0 if offset.x != 0 else (1 if offset.y != 0 else 2)
					var side := float(offset[axis])
					var face := _face(velocity, n if side > 0.0 else Vector3i(x, y, z), axis)
					faces += 1
					inflow = maxf(inflow, side * (face - obstacle[_index(n) * 4 + axis]))
	var expected := (4.0 / 3.0 * PI * 0.027 + 0.064) / (CELL_M * CELL_M * CELL_M)
	print("SMOKE GPU solids=%d expected=%.0f fluid faces=%d max inflow=%f m/s" % [solid_cells,
		expected, faces, inflow])
	_check(absf(solid_cells / expected - 1.0) < 0.25, "%d solid cells for %.0f expected" % [
		solid_cells, expected])
	_check(faces > 100 and inflow < 1e-5, "air flows into a solid at %f m/s" % inflow)
	_check(_max(solver.read_field("scalar")) > 0.1, "the source injected no smoke around the solids")
	solver.stop()


## Hot smoke in a closed shell with 2-cell walls never reaches the air outside.
func _leak_case() -> void:
	var solver := _solver()
	solver.config.buoyancy_mps2_per_k = 0.05
	var center := Vector3(0.0, 1.0, 0.0)
	solver.set_static_occupancy(SmokeVoxelizer.voxelize(_box_faces(center, 1.0)
		+ _box_faces(center, 0.6), solver.config.domain_origin_m, CELL_M, DIMS, 2))
	if not await _start(solver):
		return
	solver.set_sources(SmokeSolver.pack_source(center, Vector3.ONE * 0.2, 5.0, 300.0, Vector3.ZERO,
		0.0))
	await _steps(solver, 60)
	var scalar := solver.read_field("scalar")
	var inside := 0.0
	var outside := 0.0
	for z in DIMS.z:
		for y in DIMS.y:
			for x in DIMS.x:
				var density := scalar[_index(Vector3i(x, y, z)) * 2]
				if x >= 3 and x < 13 and y >= 5 and y < 15 and z >= 3 and z < 13:
					inside = maxf(inside, density)
				else:
					outside = maxf(outside, absf(density))
	print("SMOKE GPU shell max smoke inside=%f outside=%f" % [inside, outside])
	_check(inside > 0.1, "the source injected no smoke inside the shell")
	_check(outside < 1e-6, "smoke leaked through a 2-cell wall: %f" % outside)
	solver.stop()


## A red and a blue source rising side by side: each half of the grid keeps the
## colour of its source once advected.
func _dye_case() -> void:
	var solver := _solver()
	if not await _start(solver):
		return
	solver.set_sources(SmokeSolver.pack_source(Vector3(-0.4, 0.6, 0.0), Vector3.ONE * 0.2, 5.0,
		0.0, Vector3(0.0, 0.8, 0.0), 10.0, Color.RED)
		+ SmokeSolver.pack_source(Vector3(0.4, 0.6, 0.0), Vector3.ONE * 0.2, 5.0, 0.0,
		Vector3(0.0, 0.8, 0.0), 10.0, Color.BLUE))
	await _steps(solver, 40)
	var scalar := solver.read_field("scalar")
	var dye := solver.read_field("dye")
	var halves: Array[Vector4] = [Vector4.ZERO, Vector4.ZERO]
	for z in DIMS.z:
		for y in DIMS.y:
			for x in DIMS.x:
				var i := _index(Vector3i(x, y, z))
				halves[0 if x < DIMS.x / 2 else 1] += Vector4(dye[i * 4], dye[i * 4 + 1],
					dye[i * 4 + 2], scalar[i * 2])
	var left := Vector3(halves[0].x, halves[0].y, halves[0].z) / maxf(halves[0].w, 1e-6)
	var right := Vector3(halves[1].x, halves[1].y, halves[1].z) / maxf(halves[1].w, 1e-6)
	print("SMOKE GPU dye left=%s right=%s mass=%.3f/%.3f" % [left, right, halves[0].w, halves[1].w])
	_check(halves[0].w > 0.1 and halves[1].w > 0.1, "the dyed sources injected no smoke")
	_check(left.distance_to(Vector3(1.0, 0.0, 0.0)) < 0.05, "red smoke is %s" % left)
	_check(right.distance_to(Vector3(0.0, 0.0, 1.0)) < 0.05, "blue smoke is %s" % right)
	solver.stop()


## Peak density of a blob carried 0.4 m by a uniform breeze.
func _peak_after_transport(maccormack: bool) -> float:
	var solver := _solver()
	solver.config.maccormack = maccormack
	if not await _start(solver):
		return 0.0
	var breeze := SmokeSolver.pack_source(Vector3(0.0, 1.2, 0.0), Vector3.ONE * 3.0, 0.0, 0.0,
		Vector3(0.6, 0.0, 0.0), 10.0)
	solver.set_sources(breeze + SmokeSolver.pack_source(Vector3(-0.3, 1.2, 0.0), Vector3.ONE * 0.25,
		60.0, 0.0, Vector3.ZERO, 0.0))
	await _steps(solver, 1)
	solver.set_sources(breeze)
	await _steps(solver, 39)
	var peak := 0.0
	var scalar := solver.read_field("scalar")
	for i in range(0, scalar.size(), 2):
		peak = maxf(peak, scalar[i])
	solver.stop()
	return peak


## |L p - div| / |div| over fluid cells, with the pressure pass's own neighbour codes.
func _poisson_residual(solver: SmokeSolver, dims: Vector3i, cell_m: float) -> float:
	var div_code := solver.read_field("divergence")
	var pressure := solver.read_field("pressure")
	var residual_sq := 0.0
	var div_sq := 0.0
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var cell := x + dims.x * (y + dims.y * z)
				var code := int(div_code[cell * 2 + 1])
				if code >= 512:
					continue
				var total := 0.0
				for bit in 6:
					if code & (1 << bit):
						var n: Vector3i = Vector3i(x, y, z) + NEIGHBORS[bit]
						total += pressure[n.x + dims.x * (n.y + dims.y * n.z)]
				var count := _bitcount(code & 63) + ((code >> 6) & 7)
				var div := div_code[cell * 2]
				var r := (total - count * pressure[cell]) / (cell_m * cell_m) - div
				residual_sq += r * r
				div_sq += div * div
	return sqrt(residual_sq / maxf(div_sq, 1e-18))


func _bitcount(value: int) -> int:
	var count := 0
	while value != 0:
		count += value & 1
		value >>= 1
	return count


func _box_faces(center: Vector3, size: float) -> PackedVector3Array:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * size
	var faces := box.get_faces()
	for i in faces.size():
		faces[i] += center
	return faces


# Net outflow of every cell through its six faces, per second.
func _divergence(velocity: Array[PackedFloat32Array]) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(DIMS.x * DIMS.y * DIMS.z)
	for z in DIMS.z:
		for y in DIMS.y:
			for x in DIMS.x:
				var c := Vector3i(x, y, z)
				var div := 0.0
				for axis in 3:
					div += _face(velocity, c + NEIGHBORS[axis * 2], axis) - _face(velocity, c, axis)
				out[_index(c)] = div / CELL_M
	return out


func _read_velocity(solver: SmokeSolver) -> Array[PackedFloat32Array]:
	return [solver.read_field("velocity_x"), solver.read_field("velocity_y"),
		solver.read_field("velocity_z")]


## Axis velocity on the low face of cell t.
func _face(velocity: Array[PackedFloat32Array], t: Vector3i, axis: int) -> float:
	return velocity[axis][t.x + FACES.x * (t.y + FACES.y * t.z)]


func _in_grid(c: Vector3i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x < DIMS.x and c.y < DIMS.y and c.z < DIMS.z


func _index(c: Vector3i) -> int:
	return c.x + DIMS.x * (c.y + DIMS.y * c.z)


func _rms(values: PackedFloat32Array) -> float:
	var total := 0.0
	for value in values:
		total += value * value
	return sqrt(total / maxf(values.size(), 1.0))


func _max(values: PackedFloat32Array) -> float:
	var best := 0.0
	for value in values:
		best = maxf(best, absf(value))
	return best


func _channel(values: PackedFloat32Array, channel: int, stride: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in range(channel, values.size(), stride):
		out.append(values[i])
	return out


func _channel_sum(values: PackedFloat32Array, channel: int) -> float:
	var total := 0.0
	for i in range(channel, values.size(), 2):
		total += values[i]
	return total


func _centroid_y(scalar: PackedFloat32Array) -> float:
	var mass := 0.0
	var moment := 0.0
	for cell in scalar.size() / 2:
		var density := scalar[cell * 2]
		var y := (cell / DIMS.x) % DIMS.y
		mass += density
		moment += density * (float(y) + 0.5) * CELL_M
	return moment / maxf(mass, 1e-9)
