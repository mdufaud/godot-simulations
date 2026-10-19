extends "res://tests/test_case.gd"

const Cases := preload("res://tests/ocean_parameter_cases.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scenarios := Cases.cases()
	var covered := {}
	for scenario in scenarios:
		var preset: OceanPreset = scenario.input
		var error := preset.validate()
		print("OCEAN PARAM input=%s" % JSON.stringify({"case": scenario.name,
			"preset": Cases.snapshot(preset), "expected_valid": scenario.valid}))
		_check(error.is_empty() == bool(scenario.valid),
			"%s validation expected valid=%s, got '%s'" % [scenario.name, scenario.valid, error])
		_check(Cases.unmapped_fields(preset).is_empty(),
			"exported ocean parameters have no declared binding: %s" % Cases.unmapped_fields(preset))
		if not scenario.valid or not error.is_empty():
			print("OCEAN PARAM result=%s" % JSON.stringify({"case": scenario.name, "validation": error}))
			continue
		var solver := OceanSolver.new()
		preset.apply_to(solver)
		var applied := {}
		for field: String in Cases.BINDINGS:
			var binding: Dictionary = Cases.BINDINGS[field]
			covered[field] = true
			if binding.has("solver"):
				var actual = solver.get(binding.solver)
				_check(actual == preset.get(field), "%s.%s did not reach %s" % [scenario.name, field, binding.solver])
				applied[field] = actual
		print("OCEAN PARAM result=%s" % JSON.stringify({"case": scenario.name, "applied": applied}))
	_check(covered.size() == Cases.BINDINGS.size(), "ocean parameter coverage is incomplete")
	for path: String in Cases.PRESET_PATHS:
		var preset := load(path) as OceanPreset
		var solver := OceanSolver.new()
		preset.apply_to(solver)
		_check(solver.effective_swell_period() == preset.swell_period_s,
			"%s default swell period changed" % preset.display_name)
	var extreme := OceanSolver.new()
	extreme.swell_height_m = 12.0
	extreme.swell_period_s = 2.0
	var safe_period := extreme.effective_swell_period()
	_check(safe_period > extreme.swell_period_s, "steep swell was not lengthened")
	var alpha := OceanSolver.SpectrumMetrics.compute_swell_alpha_scale(extreme)
	_check(alpha > 0.0, "lengthened swell lost its energy")
	var boosted := OceanSolver.new()
	boosted.swell_height_m = 2.0
	boosted.swell_period_s = 2.0
	var before: float = boosted.physical_moments().m1
	boosted.amplitude_scale = 2.0
	boosted.height_gain = 3.0
	_check(float(boosted.physical_moments().m1) > before,
		"boosted swell period did not invalidate cached physical moments")
	print("OCEAN PARAM swell_safety=%s" % JSON.stringify({
		"requested_period_s": extreme.swell_period_s, "effective_period_s": safe_period,
		"requested_height_m": extreme.swell_height_m, "alpha": alpha}))
	for scenario: Dictionary in Cases.CONFIG_CASES:
		var config := OceanConfig.new()
		for field: String in scenario.changes:
			var value = scenario.changes[field]
			config.set(field, PackedFloat32Array(value) if field == "clipmap_tile_lengths_m" else value)
		var error := config.validate()
		print("OCEAN CONFIG case=%s map_size=%d levels=%d cell_m=%s tiles=%s expected_valid=%s validation=%s" % [
			scenario.name, config.map_size, config.clipmap_levels, config.finest_cell_m,
			config.clipmap_tile_lengths_m, scenario.valid, error])
		_check(error.is_empty() == bool(scenario.valid),
			"config %s validation expected valid=%s, got '%s'" % [scenario.name, scenario.valid, error])
	print("OCEAN PARAM summary=%s" % JSON.stringify({"cases": scenarios.size(),
		"config_cases": Cases.CONFIG_CASES.size(), "covered_parameters": covered.keys(), "failures": _failures}))
	_finish("ocean_parameters")
