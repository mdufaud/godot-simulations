extends RefCounted

const Cases := preload("res://tests/ocean_parameter_cases.gd")
const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const SpectrumMetrics := preload("res://scripts/ocean/ocean_spectrum_metrics.gd")
const WaveMetrics := preload("res://scripts/ocean/ocean_capture_metrics.gd")
const SCENE_PATH := "res://scenes/ocean_demo.tscn"
const READY_TIMEOUT_MS := 30000
const READ_TIMEOUT_MS := 12000
const READBACK_DTYPE_BYTES := 8
const FOAM_MAX := 0.843751


static func run(tree: SceneTree, check: Callable, mode: String,
		existing_demo: Node = null) -> void:
	var owns_demo := existing_demo == null
	var demo: Node = existing_demo
	var was_processing := false
	if owns_demo:
		demo = (load(SCENE_PATH) as PackedScene).instantiate()
		tree.root.add_child(demo)
	else:
		was_processing = demo.is_processing()
	if not await _wait_ready(tree, demo):
		check.call(false, "ocean_parameter_probe: demo did not become ready")
		if owns_demo:
			demo.queue_free()
		return
	if owns_demo:
		var boot_preset := load(Cases.PRESET_PATHS[1]) as OceanPreset
		check.call(demo.current_preset_index == 1, "ocean boot did not select Breeze")
		var boot_applied := _verify_bindings(demo, boot_preset, "boot_breeze", check, {})
		print("OCEAN PARAM boot=%s" % JSON.stringify(_json_value({
			"preset": Cases.snapshot(boot_preset), "applied": boot_applied,
			"quality": OceanQualityProfile.TIER_NAMES[demo.quality.effective],
			"shader_state": _shader_state(demo.surface_mat),
		})))
	var target_quality := OceanQualityProfile.Tier.MEDIUM if mode in ["swell", "extremes"] \
		else OceanQualityProfile.Tier.LOW
	demo.set_quality_profile(target_quality)
	if not await _wait_ready(tree, demo):
		check.call(false, "ocean_parameter_probe: requested quality did not become ready")
		if owns_demo:
			demo.queue_free()
		return
	var quality_values := OceanQualityProfile.values(target_quality)
	check.call(demo.quality.effective == target_quality
		and demo.solver.quality_tier == target_quality
		and demo.solver.map_size == int(quality_values.fft_size)
		and demo.solver.foam_near_size == int(quality_values.foam_near_size),
		"ocean_parameter_probe: active quality does not match requested profile")
	print("OCEAN PARAM quality=%s" % JSON.stringify({
		"requested": OceanQualityProfile.TIER_NAMES[target_quality],
		"active": OceanQualityProfile.TIER_NAMES[demo.quality.effective],
		"map_size": demo.solver.map_size, "foam_near_size": demo.solver.foam_near_size,
	}))
	demo.set_frozen(true)
	demo.set_process(false)
	if mode == "parameters":
		await _run_parameters(tree, demo, check)
	elif mode == "swell":
		await _run_swell(tree, demo, check)
	elif mode == "extremes":
		await _run_extremes(tree, demo, check)
	else:
		check.call(false, "ocean_parameter_probe: unknown mode %s" % mode)
	if owns_demo:
		demo.queue_free()
		await tree.process_frame
		return
	demo.set_process(true)
	demo.set_quality_profile(OceanQualityProfile.Tier.MEDIUM)
	if not await _wait_ready(tree, demo):
		check.call(false, "ocean_parameter_probe: could not restore Medium quality")
	check.call(demo.quality.effective == OceanQualityProfile.Tier.MEDIUM,
		"ocean_parameter_probe: Medium quality was not restored")
	var calm := (load(Cases.PRESET_PATHS[0]) as OceanPreset).duplicate(true) as OceanPreset
	demo.apply_sea_state(calm)
	demo.set_frozen(true)
	demo.set_process(was_processing)
	await tree.process_frame


static func _run_parameters(tree: SceneTree, demo: Node, check: Callable) -> void:
	var checked := 0
	var covered := {}
	for scenario: Dictionary in Cases.cases():
		if not scenario.valid:
			continue
		var preset: OceanPreset = scenario.input
		print("OCEAN PARAM input=%s" % JSON.stringify(_json_value({
			"case": scenario.name,
			"preset": Cases.snapshot(preset),
		})))
		check.call(preset.validate().is_empty(), "%s preset validation failed" % scenario.name)
		check.call(bool(demo.apply_sea_state(preset)), "%s was rejected by runtime application" % scenario.name)
		var applied := _verify_bindings(demo, preset, scenario.name, check, covered)
		var camera_position: Vector3 = demo.main_camera.global_position
		var center := Vector2(camera_position.x, camera_position.z)
		demo.solver.near_center = center
		demo.solver.take_render_refresh_request()
		var time_s := 20.0
		for frame in 3:
			time_s += 1.0 / 30.0
			demo._sim_time = time_s
			demo.solver.sim_time = time_s
			RenderingServer.call_on_render_thread(Callable(demo, "_render_step").bind(
				1.0 / 30.0, time_s, center))
			await RenderingServer.frame_post_draw
		demo.solver.take_render_refresh_request()
		await _sync_process(tree, demo)
		var shader_state := _shader_state(demo.surface_mat)
		var metrics := await _read_fields(tree, demo, scenario.name, check, true)
		if metrics.is_empty():
			return
		var expects_fft_energy := preset.wave_model == OceanPreset.WaveModel.FFT \
			and preset.height_gain > 0.0 and preset.amplitude_scale > 0.0
		if expects_fft_energy:
			check.call(float(metrics.total_variance) > 1.0e-12,
				"%s FFT emitted no measurable displacement" % scenario.name)
		var run_state := {
			"quality": OceanQualityProfile.TIER_NAMES[demo.quality.effective],
			"map_size": demo.solver.map_size,
			"water_depth_m": demo.solver.water_depth,
			"finest_cell_m": demo.config.finest_cell_m,
			"foam_near_size": demo.solver.foam_near_size,
			"foam_near_domain_m": demo.solver.foam_near_domain,
			"foam_domains_m": demo.solver.foam_field_domains(),
			"shader_state": shader_state,
			"gpu_fields": metrics.layers,
		}
		check.call(shader_state.get("foam_feedback_enabled")
			== (demo.solver.foam_feedback_enabled and demo.solver.foam_amount > 0.0),
			"%s shader foam feedback state is stale" % scenario.name)
		check.call(is_equal_approx(float(shader_state.get("sim_time", -INF)), time_s),
			"%s shader simulation clock is stale" % scenario.name)
		check.call(shader_state.get("fft_surface")
			== (preset.wave_model == OceanPreset.WaveModel.FFT),
			"%s shader wave model is stale" % scenario.name)
		print("OCEAN PARAM result=%s" % JSON.stringify(_json_value({
			"case": scenario.name,
			"applied": applied,
			"runtime": run_state,
		})))
		checked += 1
	for field: String in Cases.BINDINGS:
		check.call(covered.has(field), "ocean_parameter_probe did not exercise %s" % field)
	var controls := await _run_controls(tree, demo, check)
	if controls.is_empty():
		return
	print("OCEAN PARAM summary=%s" % JSON.stringify({
		"mode": "parameters",
		"cases": checked,
		"covered_parameters": covered.keys(),
		"controls": controls,
	}))


static func _run_controls(tree: SceneTree, demo: Node, check: Callable) -> Array[Dictionary]:
	var baseline := (load(Cases.PRESET_PATHS[1]) as OceanPreset).duplicate(true) as OceanPreset
	demo.apply_sea_state(baseline)
	var builder: OceanMenu = demo._menu_builder
	var menu: SimMenu = demo.menu
	var persist_id: String = menu.persist_id
	menu.persist_id = ""
	var override_flags := [builder._foam_strength_override, builder._foam_distance_override,
		builder._detail_distance_override]
	var entries: Array[Dictionary] = []
	for field: String in Cases.BINDINGS:
		var binding: Dictionary = Cases.BINDINGS[field]
		if not binding.has("menu"):
			continue
		var menu_controls: Array = binding.menu if binding.menu is Array else [binding.menu]
		for component in menu_controls.size():
			var name: String = menu_controls[component]
			var slider: HSlider = builder.get(name)
			entries.append({"kind": "binding", "field": field, "name": name,
				"component": component if binding.menu is Array else -1,
				"binding": binding, "slider": slider,
				"entry": _slider_entry(menu, slider), "initial": slider.value})
	for control: Dictionary in Cases.CONTROLS:
		var slider: HSlider = _control_slider(demo, control)
		var entry: Dictionary = _slider_entry(menu, slider)
		entries.append({"kind": "control", "control": control, "slider": slider, "entry": entry,
			"initial": slider.value})
	var results: Array[Dictionary] = []
	for bound_name: String in ["lower", "upper"]:
		for row: Dictionary in entries:
			var slider: HSlider = row.slider
			var requested: float = slider.min_value if bound_name == "lower" else slider.max_value
			_set_slider(row, requested)
			var applied := _check_menu_destination(demo, row, slider, check, bound_name)
			var name: String = row.name if row.kind == "binding" else \
				String(row.control.get("menu", row.control.get("key", "control")))
			results.append({"name": name, "bound": bound_name,
				"requested": requested, "applied": _json_value(applied)})
			print("OCEAN PARAM CONTROL=%s" % JSON.stringify(_json_value({
				"name": name, "bound": bound_name, "requested": requested,
				"preset": Cases.snapshot(baseline), "applied": applied,
			})))
		demo.solver.take_render_refresh_request()
		demo._sim_time = 20.0
		demo.solver.sim_time = 20.0
		await _render_and_sync(tree, demo, 1.0 / 30.0, 20.0)
		var metrics := await _read_fields(tree, demo, "controls_%s" % bound_name, check, true)
		if metrics.is_empty():
			return []
		var shader_state := _shader_state(demo.surface_mat)
		check.call(shader_state.get("foam_feedback_enabled")
			== (demo.solver.foam_feedback_enabled and demo.solver.foam_amount > 0.0)
			and is_equal_approx(float(shader_state.get("sim_time", -INF)), 20.0),
			"controls_%s shader state did not sync after render step" % bound_name)
		if bound_name == "upper":
			check.call(float(metrics.total_variance) > 1.0e-12,
				"controls_upper produced no measurable FFT displacement")
		print("OCEAN PARAM CONTROL GPU=%s" % JSON.stringify(_json_value({
			"bound": bound_name, "map_size": demo.solver.map_size,
			"foam_near_size": demo.solver.foam_near_size,
			"foam_near_domain_m": demo.solver.foam_near_domain,
			"shader_state": shader_state, "layers": metrics.layers,
		})))
	for row: Dictionary in entries:
		var slider: HSlider = row.slider
		_set_slider(row, float(row.initial))
	builder._foam_strength_override = override_flags[0]
	builder._foam_distance_override = override_flags[1]
	builder._detail_distance_override = override_flags[2]
	menu.persist_id = persist_id
	return results


static func _set_slider(row: Dictionary, value: float) -> void:
	var slider: HSlider = row.slider
	var previous: float = slider.value
	slider.value = value
	if is_equal_approx(previous, slider.value):
		row.entry.cb.call(slider.value)


static func _check_menu_destination(demo: Node, row: Dictionary, slider: HSlider,
		check: Callable, bound_name: String) -> Dictionary:
	var actual: Variant
	var expected: Variant = slider.value
	if row.kind == "binding":
		var binding: Dictionary = row.binding
		if binding.has("solver"):
			actual = demo.solver.get(binding.solver)
			if row.field == "current_velocity_m_s":
				var component: int = row.component
				var actual_component: float = actual.x if component == 0 else actual.y
				check.call(is_equal_approx(actual_component, slider.value), "%s %s did not update vector component" % [row.name, bound_name])
			else:
				check.call(_equal(actual, expected), "%s %s did not reach solver.%s" % [
					row.name, bound_name, binding.solver])
		if binding.has("host"):
			actual = _host_value(demo, String(binding.host))
			check.call(_equal(actual, expected), "%s %s did not reach %s" % [
				row.name, bound_name, binding.host])
	else:
		var control: Dictionary = row.control
		var target := _control_target(demo, control)
		actual = target.value
		expected = slider.value * float(control.get("multiplier", 1.0))
		check.call(_equal(actual, expected), "%s %s callback did not reach destination" % [
			control.get("menu", control.get("key", "control")), bound_name])
	return {"menu": slider.value, "target": _json_value(actual)}


static func _render_and_sync(tree: SceneTree, demo: Node, delta: float, time_s: float) -> void:
	var camera_position: Vector3 = demo.main_camera.global_position
	var center := Vector2(camera_position.x, camera_position.z)
	demo.solver.near_center = center
	demo._sim_time = time_s
	demo.solver.sim_time = time_s
	demo.solver.take_render_refresh_request()
	RenderingServer.call_on_render_thread(Callable(demo, "_render_step").bind(delta, time_s, center))
	await RenderingServer.frame_post_draw
	demo.solver.take_render_refresh_request()
	await _sync_process(tree, demo)


static func _sync_process(tree: SceneTree, demo: Node) -> void:
	demo.set_process(true)
	await tree.process_frame
	await RenderingServer.frame_post_draw
	demo.set_process(false)


static func _control_slider(demo: Node, control: Dictionary) -> HSlider:
	if control.has("menu"):
		return demo._menu_builder.get(control.menu)
	return demo.menu._entries[control.key].node


static func _slider_entry(menu: SimMenu, slider: HSlider) -> Dictionary:
	for key: String in menu._entries:
		var entry: Dictionary = menu._entries[key]
		if entry.node == slider:
			return entry
	return {}


static func _control_target(demo: Node, control: Dictionary) -> Dictionary:
	if control.has("host"):
		return {"kind": "host", "value": _host_value(demo, control.host)}
	if control.has("shader"):
		return {"kind": "shader", "value": demo.surface_mat.get_shader_parameter(control.shader)}
	return {"kind": "viewport", "value": demo._viewport.render_scale()}


static func _run_swell(tree: SceneTree, demo: Node, check: Callable) -> void:
	demo.set_process(false)
	var storm := (load(Cases.PRESET_PATHS[3]) as OceanPreset).duplicate(true) as OceanPreset
	storm.wind_speed_mps = 0.5
	storm.fetch_km = 5.0
	storm.swell_height_m = 1.0
	storm.swell_period_s = 12.0
	var checked := 0
	for swell_case: Dictionary in Cases.SWELL_REGRESSIONS:
		var preset := storm.duplicate(true) as OceanPreset
		preset.swell_spread = swell_case.spread
		preset.swell_direction_rad = swell_case.direction
		print("OCEAN PARAM input=%s" % JSON.stringify(_json_value({
			"case": swell_case.name,
			"preset": Cases.snapshot(preset),
		})))
		check.call(preset.validate().is_empty(), "%s preset validation failed" % swell_case.name)
		check.call(bool(demo.apply_sea_state(preset)), "%s was rejected by runtime application" % swell_case.name)
		demo.solver.take_render_refresh_request()
		demo._sim_time = 20.0
		demo.solver.sim_time = 20.0
		var camera_position: Vector3 = demo.main_camera.global_position
		var center := Vector2(camera_position.x, camera_position.z)
		RenderingServer.call_on_render_thread(Callable(demo, "_render_step").bind(0.0, 20.0, center))
		await RenderingServer.frame_post_draw
		demo.solver.take_render_refresh_request()
		await _sync_process(tree, demo)
		var metrics := await _read_fields(tree, demo, swell_case.name, check, false)
		if metrics.is_empty():
			return
		var cpu_wind_variance := 0.0
		var cpu_swell_variance := 0.0
		for reference: Dictionary in demo.solver.spectral_references():
			cpu_wind_variance += maxf(float(reference.wind_variance_m2), 0.0)
			cpu_swell_variance += maxf(float(reference.swell_variance_m2), 0.0)
		var cpu_swell_height := 4.0 * sqrt(cpu_swell_variance)
		var gpu_variance: float = metrics.total_variance
		var target_variance := preset.swell_height_m * preset.swell_height_m / 16.0
		var gpu_reference_variance := target_variance + cpu_wind_variance
		var variance_ratio := gpu_variance / maxf(gpu_reference_variance, 1.0e-12)
		var alpha := SpectrumMetrics.compute_swell_alpha_scale(demo.solver)
		var shader_state := _shader_state(demo.surface_mat)
		check.call(variance_ratio >= 0.25 and variance_ratio <= 2.5,
			"%s GPU/CPU height variance ratio %.4f is outside 0.25..2.5"
			% [swell_case.name, variance_ratio])
		check.call(preset.swell_height_m > 0.0 and is_finite(cpu_swell_variance)
			and is_finite(cpu_wind_variance)
			and absf(cpu_swell_height - preset.swell_height_m) <= 0.0001,
			"%s CPU swell height %.4f m differs from target %.4f m"
			% [swell_case.name, cpu_swell_height, preset.swell_height_m])
		check.call(shader_state.get("foam_feedback_enabled")
			== (demo.solver.foam_feedback_enabled and demo.solver.foam_amount > 0.0)
			and is_equal_approx(float(shader_state.get("sim_time", -INF)), 20.0),
			"%s shader state did not sync after render step" % swell_case.name)
		print("OCEAN SWELL result=%s" % JSON.stringify(_json_value({
			"alpha": alpha,
			"target_hs_m": preset.swell_height_m,
			"cpu_swell_hs_m": cpu_swell_height,
			"cpu_swell_variance_m2": cpu_swell_variance,
			"cpu_wind_variance_m2": cpu_wind_variance,
			"target_swell_variance_m2": target_variance,
			"gpu_total_variance_m2": gpu_variance,
			"gpu_to_cpu_variance_ratio": variance_ratio,
			"cascade_height_variance_m2": metrics.cascade_variances,
			"shader_state": shader_state,
			"inputs": Cases.snapshot(preset),
		})))
		checked += 1
	print("OCEAN PARAM summary=%s" % JSON.stringify({"mode": "swell", "cases": checked}))


static func _run_extremes(tree: SceneTree, demo: Node, check: Callable) -> void:
	demo.set_scene_mode(0, false)
	check.call(await _wait_ready(tree, demo), "extreme open ocean did not become ready")
	demo.set_process(false)
	for scenario: Dictionary in Cases.EXTREME_REGRESSIONS:
		var preset := (load(Cases.PRESET_PATHS[3]) as OceanPreset).duplicate(true) as OceanPreset
		for field: String in scenario.changes:
			preset.set(field, scenario.changes[field])
		print("OCEAN EXTREME input=%s" % JSON.stringify({"case": scenario.name,
			"preset": Cases.snapshot(preset)}))
		check.call(demo.apply_sea_state(preset), "%s runtime rejected preset" % scenario.name)
		demo.solver.take_render_refresh_request()
		demo._sim_time = 20.0
		demo.solver.sim_time = 20.0
		var camera: Vector3 = demo.main_camera.global_position
		demo.solver.near_center = Vector2(camera.x, camera.z)
		await demo.warmup_foam(3.0)
		await _sync_process(tree, demo)
		var fields := await _read_fields(tree, demo, scenario.name, check, true, true)
		if fields.is_empty():
			return
		var hs := 4.0 * sqrt(float(fields.total_variance))
		check.call(float(fields.geometry.folded_fraction) == 0.0,
			"%s combined surface folds over %.2f%% of samples" % [
				scenario.name, float(fields.geometry.folded_fraction) * 100.0])
		check.call(hs >= float(scenario.minimum_hs_m),
			"%s lost its large waves: Hs %.3f m" % [scenario.name, hs])
		check.call(float(fields.geometry.slope_rms) >= float(scenario.get("minimum_slope_rms", 0.0)),
			"%s swell is too flat: slope RMS %.4f" % [scenario.name, fields.geometry.slope_rms])
		for layer: Dictionary in fields.layers:
			check.call(float(layer.foam.coverage) < 0.95,
				"%s foam blankets more than 95%% of a layer" % scenario.name)
		print("OCEAN EXTREME result=%s" % JSON.stringify({"case": scenario.name,
			"gpu_hs_m": hs, "effective_swell_period_s": demo.solver.effective_swell_period(),
			"fields": fields}))
	print("OCEAN EXTREME summary=%s" % JSON.stringify({"cases": Cases.EXTREME_REGRESSIONS.size()}))


static func _verify_bindings(demo: Node, preset: OceanPreset, case_name: String,
		check: Callable, covered: Dictionary) -> Dictionary:
	var result := {}
	for field: String in Cases.BINDINGS:
		var binding: Dictionary = Cases.BINDINGS[field]
		var expected = preset.get(field)
		var applied := {}
		if binding.has("solver"):
			var actual = demo.solver.get(binding.solver)
			check.call(_equal(actual, expected), "%s.%s did not reach solver.%s" % [
				case_name, field, binding.solver])
			applied.solver = _json_value(actual)
		if binding.has("host"):
			var host_value = _host_value(demo, String(binding.host))
			check.call(_equal(host_value, expected), "%s.%s did not reach %s" % [
				case_name, field, binding.host])
			applied.host = _json_value(host_value)
		if binding.has("menu"):
			var menu_values: Array = []
			var controls: Array = binding.menu if binding.menu is Array else [binding.menu]
			var expected_values: Array = [expected.x, expected.y] if expected is Vector2 else [expected]
			for index in controls.size():
				var slider: HSlider = demo._menu_builder.get(controls[index])
				var requested: float = float(expected_values[index])
				var clamped := clampf(requested, slider.min_value, slider.max_value)
				var snapped := clamped
				if slider.step > 0.0:
					snapped = slider.min_value + round((clamped - slider.min_value) / slider.step) * slider.step
				var tolerance := maxf(absf(slider.step) * 0.51, 0.00001)
				check.call(absf(slider.value - snapped) <= tolerance,
					"%s.%s menu %s is %.6f, expected %.6f±%.6f" % [
					case_name, field, controls[index], slider.value, snapped, tolerance])
				menu_values.append(slider.value)
			applied.menu = menu_values
		covered[field] = true
		result[field] = applied
	return result


static func _read_fields(tree: SceneTree, demo: Node, case_name: String,
		check: Callable, include_foam: bool, include_geometry: bool = false) -> Dictionary:
	var solver: OceanSolver = demo.solver
	var size: int = solver.map_size
	var expected_bytes := size * size * READBACK_DTYPE_BYTES
	var foam_size: int = solver.foam_near_size
	var foam_expected := _mip_bytes(foam_size)
	var result := {"layers": [], "total_variance": 0.0, "cascade_variances": []}
	var displacements: Array[PackedFloat32Array] = []
	var derivatives: Array[PackedFloat32Array] = []
	for layer in 3:
		var displacement_bytes: PackedByteArray = await TextureReadback.new().read_layer(
			solver.get_displacement_tex_rid(), layer, expected_bytes, READ_TIMEOUT_MS)
		if displacement_bytes.size() != expected_bytes:
			check.call(false, "%s displacement readback failed on layer %d" % [case_name, layer])
			return {}
		var derivative_bytes: PackedByteArray = await TextureReadback.new().read_layer(
			solver.get_derivative_tex_rid(), layer, expected_bytes, READ_TIMEOUT_MS)
		if derivative_bytes.size() != expected_bytes:
			check.call(false, "%s derivative readback failed on layer %d" % [case_name, layer])
			return {}
		var displacement := _half_rgba(displacement_bytes, size)
		var derivative := _half_rgba(derivative_bytes, size)
		if include_geometry:
			displacements.append(displacement)
			derivatives.append(derivative)
		var field := _measure_layer(displacement, derivative)
		check.call(bool(field.finite), "%s has non-finite FFT fields on layer %d" % [case_name, layer])
		result.layers.append(field)
		result.total_variance += float(field.height_variance_m2)
		result.cascade_variances.append(field.height_variance_m2)
		if include_foam:
			var foam_bytes: PackedByteArray = await TextureReadback.new().read_layer(
				solver.get_foam_near_read_tex_rid(), layer, foam_expected, READ_TIMEOUT_MS)
			if foam_bytes.size() != foam_expected:
				check.call(false, "%s foam readback failed on layer %d" % [case_name, layer])
				return {}
			var foam_mips := foam_bytes.to_float32_array()
			var mips_valid := true
			for index in range(foam_size * foam_size * 2, foam_mips.size()):
				var value: float = foam_mips[index]
				if not is_finite(value) or value < 0.0 or value > FOAM_MAX:
					mips_valid = false
					break
			check.call(mips_valid, "%s has invalid foam mipmaps on layer %d" % [case_name, layer])
			var foam := foam_mips.slice(0, foam_size * foam_size * 2)
			var foam_stats := _measure_foam(foam)
			foam_stats.mips_valid = mips_valid
			check.call(bool(foam_stats.finite), "%s has non-finite foam on layer %d" % [case_name, layer])
			check.call(bool(foam_stats.bounded), "%s has foam outside 0..%.6f on layer %d"
				% [case_name, FOAM_MAX, layer])
			field.foam = foam_stats
	if include_geometry:
		result.geometry = WaveMetrics.measure(displacements, derivatives, size,
			solver.tile_lengths, solver.whitecap)
	return result


static func _measure_layer(displacement: PackedFloat32Array,
		derivative: PackedFloat32Array) -> Dictionary:
	var finite := true
	var height_sum := 0.0
	var height_square_sum := 0.0
	var max_abs_height := 0.0
	var max_strain := 0.0
	var texel_count := displacement.size() / 4
	for index in range(0, displacement.size(), 4):
		var height: float = displacement[index + 1]
		finite = finite and is_finite(height)
		height_sum += height
		height_square_sum += height * height
		max_abs_height = maxf(max_abs_height, absf(height))
		for channel in 4:
			finite = finite and is_finite(displacement[index + channel])
			finite = finite and is_finite(derivative[index + channel])
		var strain := Vector3(derivative[index], derivative[index + 1], derivative[index + 2])
		max_strain = maxf(max_strain, strain.length())
	var height_mean := height_sum / maxf(float(texel_count), 1.0)
	var height_variance := maxf(height_square_sum / maxf(float(texel_count), 1.0)
		- height_mean * height_mean, 0.0)
	return {
		"finite": finite,
		"height_mean_m": height_mean,
		"height_variance_m2": height_variance,
		"max_abs_height_m": max_abs_height,
		"max_strain": max_strain,
	}


static func _measure_foam(values: PackedFloat32Array) -> Dictionary:
	var finite := true
	var bounded := true
	var max_value := 0.0
	var covered := 0
	var count := values.size() / 2
	for index in range(0, values.size(), 2):
		for channel in 2:
			var value: float = values[index + channel]
			finite = finite and is_finite(value)
			bounded = bounded and value >= 0.0 and value <= FOAM_MAX
			max_value = maxf(max_value, value)
		if maxf(values[index], values[index + 1]) > OceanConfig.MEASURE_FOAM_THRESHOLD:
			covered += 1
	return {
		"finite": finite,
		"bounded": bounded,
		"mean_persistent": _mean_even(values),
		"mean_fresh": _mean_odd(values),
		"max": max_value,
		"coverage": float(covered) / maxf(float(count), 1.0),
	}


static func _half_rgba(bytes: PackedByteArray, size: int) -> PackedFloat32Array:
	var base_layer := bytes.slice(0, size * size * READBACK_DTYPE_BYTES)
	var image := Image.create_from_data(size, size, false, Image.FORMAT_RGBAH, base_layer)
	image.convert(Image.FORMAT_RGBAF)
	return image.get_data().to_float32_array()


static func _mip_bytes(size: int) -> int:
	var result := 0
	var mip_size := size
	while mip_size > 0:
		result += mip_size * mip_size * READBACK_DTYPE_BYTES
		mip_size /= 2
	return result


static func _mean_even(values: PackedFloat32Array) -> float:
	var total := 0.0
	for index in range(0, values.size(), 2):
		total += values[index]
	return total / maxf(float(values.size() / 2), 1.0)


static func _mean_odd(values: PackedFloat32Array) -> float:
	var total := 0.0
	for index in range(1, values.size(), 2):
		total += values[index]
	return total / maxf(float(values.size() / 2), 1.0)


static func _shader_state(material: ShaderMaterial) -> Dictionary:
	var result := {"shader_class": material.shader.get_class() if material.shader != null else "null"}
	for property: Dictionary in material.get_property_list():
		var property_name: String = property.name
		if property_name.begins_with("shader_parameter/"):
			var field := property_name.trim_prefix("shader_parameter/")
			result[field] = _json_value(material.get_shader_parameter(field))
	return result


static func _host_value(root: Object, path: String) -> Variant:
	var value: Variant = root
	for field: String in path.split("."):
		value = value.get(field)
	return value


static func _equal(actual: Variant, expected: Variant) -> bool:
	if actual is float and expected is float:
		return is_equal_approx(actual, expected)
	if actual is Vector2 and expected is Vector2:
		return actual.is_equal_approx(expected)
	return actual == expected


static func _json_value(value: Variant) -> Variant:
	if value is Vector2:
		return [value.x, value.y]
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector4:
		return [value.x, value.y, value.z, value.w]
	if value is Vector4i:
		return [value.x, value.y, value.z, value.w]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Resource:
		return value.get_class()
	if value is float and not is_finite(value):
		return "NaN" if is_nan(value) else ("Infinity" if value > 0.0 else "-Infinity")
	if value is Dictionary:
		var result := {}
		for key in value:
			result[String(key)] = _json_value(value[key])
		return result
	if value is Array or value is PackedByteArray or value is PackedInt32Array \
			or value is PackedInt64Array or value is PackedFloat32Array \
			or value is PackedFloat64Array or value is PackedStringArray \
			or value is PackedVector2Array or value is PackedVector3Array \
			or value is PackedVector4Array or value is PackedColorArray:
		var result: Array = []
		for item in value:
			result.append(_json_value(item))
		return result
	return value


static func _wait_ready(tree: SceneTree, demo: Node) -> bool:
	var deadline := Time.get_ticks_msec() + READY_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await tree.process_frame
	return demo.capture_ready()
