extends "res://tests/test_case.gd"
## GPU check of the solver's Shomate heat capacities, through the live display
## stage's Cp probe (fire_display.comp, cfg.diag bit 1). The pure-species molar
## Cp at a probe temperature is compared against NIST-JANAF anchor values at
## 300 K, against a transcription of the shader coefficients, and across the
## Shomate band joints (continuity). No anchor or mirror value is taken from the
## shader itself, so coefficient drift breaks this test.

const FireSolver = preload("res://scripts/fire/fire_gpu_solver.gd")

## NIST-JANAF molar Cp anchors [J/(mol.K)]: N2, O2, CO2 at 300 K, H2O at 500 K
## (its Shomate band starts at 500 K, so the shader clamps there and the probe
## reports the band-floor value below it).
const ANCHORS := {"n2": [300.0, 29.12], "o2": [300.0, 29.38],
	"co2": [300.0, 37.13], "h2o": [500.0, 35.22]}

## Transcription of the fire_common.comp Shomate bands, for a drift check. Rows:
## [joint_low_kK, joint_high_kK, low_band_clamp_kK, coeffs_low, coeffs_mid,
## coeffs_high] where each coeff set is (a, b, c, d, e) in the Shomate kK
## convention. The clamp mirrors the shader's max(t, floor) on each low band.
const BANDS := {
	"n2": [0.5, 2.0, 0.1,
		[28.98641, 1.853978, -9.647459, 16.63537, 0.000117],
		[19.50583, 19.88705, -8.598535, 1.369784, 0.527601],
		[35.51872, 1.128728, -0.196103, 0.014662, -4.553760]],
	"o2": [0.7, 2.0, 0.1,
		[31.32234, -20.23531, 57.86644, -36.50624, -0.007374],
		[30.03235, 8.772972, -3.988133, 0.788313, -0.741599],
		[20.91111, 10.72071, -2.020498, 0.146449, 9.245722]],
	"co2": [1.2, -1.0, 0.298,
		[24.99735, 55.18696, -33.69137, 7.948387, -0.136638],
		[58.16639, 2.720074, -0.492289, 0.038844, -6.447293],
		[]],
	"h2o": [1.7, -1.0, 0.5,
		[30.09200, 6.832514, 6.793435, -2.534480, 0.082139],
		[41.96426, 8.622053, -1.499780, 0.098119, -11.15764],
		[]],
}


func _shomate(coeffs: Array, t_kk: float) -> float:
	return coeffs[0] + coeffs[1] * t_kk + coeffs[2] * t_kk * t_kk \
		+ coeffs[3] * t_kk * t_kk * t_kk + coeffs[4] / (t_kk * t_kk)


func _mirror_cp(species: String, t_k: float) -> float:
	var band: Array = BANDS[species]
	var t: float = clampf(t_k, 100.0, 6000.0) * 0.001
	if t < band[0]:
		return _shomate(band[3], maxf(t, band[2]))
	if band[1] > 0.0 and t < band[1]:
		return _shomate(band[4], t)
	return _shomate(band[5] if band[1] > 0.0 else band[4], minf(t, 6.0))


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var demo = load("res://scenes/fire_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	demo.set_frozen(true)
	demo.apply_preset(4) # Performance: the probe does not need a converged plume
	for frame in 360:
		await process_frame
		if demo.capture_ready():
			break
	_check(demo.capture_ready(), "fire demo did not initialize")
	if not demo.capture_ready():
		demo.queue_free()
		_finish("fire_cp_probe")
		return

	var solver = demo.solver
	solver.diagnostic_cp_probe = true
	solver.max_catchup_steps = 1
	demo.set_capture_fixed_delta(1.0 / 30.0)
	demo.set_frozen(false)

	# One probe temperature per block of frames; the readback lags and may catch
	# a cleared or half-written buffer, so keep the median of the nonzero words.
	var probes := {
		300.0: "anchor",
		500.0: "anchor", # H2O's Shomate band floor: its anchor lives here
		1995.0: "joint", 2005.0: "joint", # N2 and O2 band joint at 2000 K
		1195.0: "joint", 1205.0: "joint", # CO2 band joint at 1200 K
		1695.0: "joint", 1705.0: "joint", # H2O band joint at 1700 K
	}
	var results := {}
	for temperature: float in probes:
		solver.diagnostic_probe_temperature = temperature
		var samples := [[], [], [], []]
		for frame in 24:
			await process_frame
			var stats: Dictionary = solver.get_stats()
			var row := [stats["diag_cp_n2"], stats["diag_cp_o2"],
				stats["diag_cp_co2"], stats["diag_cp_h2o"]]
			for i in 4:
				if row[i] > 0.0:
					samples[i].append(row[i])
		var medians := [0.0, 0.0, 0.0, 0.0]
		for i in 4:
			_check(samples[i].size() >= 8,
				"Cp probe at %s K: only %d of 24 frames produced values" % [
					str(temperature), samples[i].size()])
			if samples[i].size() > 0:
				medians[i] = _median(samples[i])
		results[temperature] = medians

	var names := ["n2", "o2", "co2", "h2o"]
	for i in 4:
		var species: String = names[i]
		# Anchor: the real NIST value, at each species' band-valid temperature.
		var anchor: Array = ANCHORS[species]
		var got_anchor: float = results[anchor[0]][i]
		_check(absf(got_anchor - anchor[1]) <= 0.02 * anchor[1],
			"%s molar Cp at %s K: GPU says %s, NIST anchor is %s" % [
				species, str(anchor[0]), str(got_anchor), str(anchor[1])])
		# Mirror: the GPU band must match the test's transcription everywhere.
		for temperature: float in probes:
			var got: float = results[temperature][i]
			var expected := _mirror_cp(species, temperature)
			_check(absf(got - expected) <= 0.005 * expected,
				"%s molar Cp at %s K: GPU %s vs band transcription %s" % [
					species, str(temperature), str(got), str(expected)])
	# Continuity: the two probes straddling a band joint must agree closely.
	var pairs := [[1995.0, 2005.0, ["n2", "o2"]], [1195.0, 1205.0, ["co2"]],
		[1695.0, 1705.0, ["h2o"]]]
	for pair: Array in pairs:
		for j in pair[2].size():
			var species: String = pair[2][j]
			var index := ["n2", "o2", "co2", "h2o"].find(species)
			var lo: float = results[pair[0]][index]
			var hi: float = results[pair[1]][index]
			_check(absf(hi - lo) <= 0.05 * maxf(absf(hi), 1.0),
				"%s Cp jumps across its %s/%s K band joint: %s -> %s" % [
					species, str(pair[0]), str(pair[1]), str(lo), str(hi)])

	demo.queue_free()
	await process_frame
	print("BALANCE cp_probe results: %s" % str(results))
	_finish("fire_cp_probe")
