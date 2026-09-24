extends RefCounted


func run(tree: SceneTree) -> Dictionary:
	var translation := await _translation(tree)
	if translation.has("error"):
		return translation
	var translation_30 := await _translation(tree, 1.0 / 30.0)
	if translation_30.has("error"):
		return translation_30
	var rotation := await _rotation(tree)
	if rotation.has("error"):
		return rotation
	var rotation_rk2 := await _rotation(tree, false)
	if rotation_rk2.has("error"):
		return rotation_rk2
	var comparison := await _comparison(tree)
	if comparison.has("error"):
		return comparison
	var comparison_30 := await _comparison(tree, 1.0 / 30.0)
	if comparison_30.has("error"):
		return comparison_30
	var quality_tradeoff := await _quality_tradeoff(tree)
	if quality_tradeoff.has("error"):
		return quality_tradeoff
	var projection := await _projection_compare(tree)
	if projection.has("error"):
		return projection
	var restart := await _restart_preserves_state(tree)
	if restart.has("error"):
		return restart
	var scene: Node = load("res://scenes/lfm_demo.tscn").instantiate()
	tree.root.add_child(scene)
	var deadline := Time.get_ticks_msec() + 90000
	while not scene.capture_ready() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	var boot_ok: bool = scene.capture_ready() and scene.config.grid_dims == Vector3i(128, 64, 64) \
		and scene.config.reinit_every == 4 and scene.menu_builder.reinit_slider.value == 4.0 \
		and not scene.config.map_rk4 and scene.config.interpolate_frames \
		and scene.solver.get_display_texture_rid(1).is_valid() \
		and scene.solver.get_previous_display_texture_rid(0).is_valid() \
		and scene.solver.get_previous_display_texture_rid(1).is_valid()
	var boot_memory_bytes: int = scene.solver.get_diagnostics().get("memory_bytes", 0)
	var medium_blends := await _blend_values(tree, scene, 4)
	var boot_timings: Dictionary = scene.solver.get_timings()
	var boot_diagnostics := await _diagnostics(tree, scene.solver)
	scene.set_capture_fixed_delta(1.0 / 30.0)
	for i in 3:
		await tree.process_frame
	var runtime_30_dt: float = scene.solver.get_last_frame_dt_s()
	scene.set_capture_fixed_delta(0.7)
	for i in 3:
		await tree.process_frame
	var runtime_slow_dt: float = scene.solver.get_last_frame_dt_s()
	var actions := await _scene_actions(tree, scene)
	scene.queue_free()
	await tree.process_frame
	if not boot_ok:
		return {"error": "default scene boot differs from preset"}
	if not (medium_blends.has(0.25) and medium_blends.has(0.5) \
			and medium_blends.has(0.75) and medium_blends.has(1.0)):
		return {"error": "medium interpolation inactive: %s" % str(medium_blends)}
	if int(boot_diagnostics.get("nonfinite", -1)) != 0 \
			or boot_diagnostics.normalized_max_div > 0.001:
		return {"error": "medium runtime diagnostics: %s" % str(boot_diagnostics)}
	if actions.has("error"):
		return actions
	if absf(runtime_30_dt - 1.0 / 30.0) > 1.0e-5 \
			or runtime_slow_dt > 1.0 / 30.0 + 1.0e-5:
		return {"error": "runtime frame dt: 30 fps %.6g, slow %.6g" % [
			runtime_30_dt, runtime_slow_dt]}
	return {"translation_error_m": translation.error_m,
		"translation_30_error_m": translation_30.error_m,
		"runtime_30_dt_s": runtime_30_dt, "runtime_slow_dt_s": runtime_slow_dt,
		"rotation_error_m": rotation.error_m,
		"rotation_rk2_error_m": rotation_rk2.error_m,
		"lfm_energy": comparison.lfm_energy, "baseline_energy": comparison.baseline_energy,
		"smoke_drift": comparison.smoke_drift,
		"lfm_30_energy": comparison_30.lfm_energy,
		"baseline_30_energy": comparison_30.baseline_energy,
		"smoke_30_drift": comparison_30.smoke_drift,
		"quality_tradeoff": quality_tradeoff,
		"normalized_max_div": comparison.normalized_max_div,
		"cg_relative_residual": comparison.cg_relative_residual,
		"projection": projection, "restart_mass_drift": restart.mass_drift,
		"boot_memory_bytes": boot_memory_bytes, "boot_timings_ms": boot_timings,
		"medium_blends": medium_blends,
		"boot_diagnostics": boot_diagnostics,
		"actions": actions,
		"nonfinite": 0, "boot": true}


func _scene_actions(tree: SceneTree, scene: Node) -> Dictionary:
	if absf(scene.viewport_guard.render_scale() - 0.5) > 1.0e-4:
		return {"error": "LFM boot render scale is not 0.5"}
	scene.menu_builder.render_scale_slider.value = 1.0
	if absf(scene.viewport_guard.render_scale() - 1.0) > 1.0e-4:
		return {"error": "render scale action failed"}
	scene.menu_builder.render_scale_slider.value = 0.5
	scene.menu_builder.quality_button.select(0)
	scene.menu_builder.quality_button.item_selected.emit(0)
	if not await _scene_ready(tree, scene):
		return {"error": "low quality action did not initialize"}
	if scene.config.grid_dims != Vector3i(64, 32, 32) or scene.config.reinit_every != 2 \
			or scene.config.map_rk4 or not scene.config.interpolate_frames \
			or not scene.solver.get_previous_display_texture_rid(0).is_valid() \
			or absf(scene.config.bounded_frame_dt_s(1.0 / 20.0) - 1.0 / 24.0) > 1.0e-5 \
			or scene.menu_builder.reinit_slider.value != 2.0 \
			or scene.menu_builder.quality_button.selected != 0:
		return {"error": "low quality action does not match menu"}
	scene.set_capture_fixed_delta(-1.0)
	var low_blends := await _blend_values(tree, scene, 2)
	scene.set_capture_fixed_delta(0.7)
	if not low_blends.has(0.5) or not low_blends.has(1.0):
		return {"error": "low interpolation inactive: %s" % str(low_blends)}
	for i in 20:
		await tree.process_frame
	var low_timings: Dictionary = scene.solver.get_timings()
	var low_diagnostics := await _diagnostics(tree, scene.solver)
	var low_runtime_dt_s: float = scene.solver.get_last_frame_dt_s()
	if low_diagnostics.nonfinite != 0 or low_diagnostics.normalized_max_div > 0.001 \
			or absf(low_runtime_dt_s - 1.0 / 24.0) > 1.0e-5:
		return {"error": "low quality projection: %s" % str(low_diagnostics)}
	scene.menu_builder.preset_button.select(1)
	scene.menu_builder.preset_button.item_selected.emit(1)
	if not await _scene_ready(tree, scene):
		return {"error": "ring preset did not initialize"}
	if scene.config.scenario != LfmConfig.Scenario.VORTEX_RING \
			or scene.view_index != 0 or scene.wing.visible \
			or scene.menu_builder.inlet_speed_slider.editable \
			or absf(scene.menu_builder.inlet_speed_slider.value) > 1.0e-4:
		return {"error": "ring preset controls disagree with runtime"}
	scene.menu_builder.view_button.select(1)
	scene.menu_builder.view_button.item_selected.emit(1)
	if scene.view_index != 1:
		return {"error": "vorticity view action failed"}
	scene.menu_builder.view_button.select(0)
	scene.menu_builder.view_button.item_selected.emit(0)
	if scene.view_index != 0:
		return {"error": "density view action failed"}
	scene.menu_builder.method_button.select(1)
	scene.menu_builder.method_button.item_selected.emit(1)
	for i in 2:
		await tree.process_frame
	if scene.solver.method != 1 or scene.menu_builder.method_button.selected != 1:
		return {"error": "method action failed"}
	scene.menu_builder.reinit_slider.value = 3.0
	if not await _scene_ready(tree, scene):
		return {"error": "reinit action did not initialize"}
	scene.menu_builder.clamp_toggle.button_pressed = false
	for i in 2:
		await tree.process_frame
	if scene.solver.config.reinit_every != 3 or scene.solver.config.bfecc_clamp \
			or scene.menu_builder.reinit_slider.value != 3.0 \
			or scene.menu_builder.clamp_toggle.button_pressed:
		return {"error": "reinit or clamp action failed"}
	scene.menu_builder.reset_button.pressed.emit()
	if not await _scene_ready(tree, scene):
		return {"error": "reset action did not initialize"}
	scene.menu_builder.preset_button.select(0)
	scene.menu_builder.preset_button.item_selected.emit(0)
	if not await _scene_ready(tree, scene):
		return {"error": "wind preset did not initialize"}
	if scene.config.scenario != LfmConfig.Scenario.WIND_TUNNEL \
			or not scene.wing.visible or scene.view_index != 1 \
			or not scene.menu_builder.inlet_speed_slider.editable \
			or absf(scene.menu_builder.inlet_speed_slider.value - 0.6) > 0.01 \
			or absf(scene.menu_builder.inlet_angle_slider.value - 20.0) > 0.01:
		return {"error": "wind preset controls disagree with runtime: scenario=%d wing=%s view=%d editable=%s speed=%.3f angle=%.3f" % [
			scene.config.scenario, scene.wing.visible, scene.view_index,
			scene.menu_builder.inlet_speed_slider.editable,
			scene.menu_builder.inlet_speed_slider.value,
			scene.menu_builder.inlet_angle_slider.value]}
	scene.menu_builder.inlet_speed_slider.value = 0.8
	scene.menu_builder.inlet_angle_slider.value = 10.0
	for i in 2:
		await tree.process_frame
	if absf(scene.solver.config.inlet_speed_mps - 0.8) > 0.01 \
			or absf(scene.solver.config.inlet_angle_deg - 10.0) > 0.01 \
			or absf(scene.menu_builder.inlet_speed_slider.value - 0.8) > 0.01 \
			or absf(scene.menu_builder.inlet_angle_slider.value - 10.0) > 0.01:
		return {"error": "inlet actions failed"}
	return {"render_scale": scene.viewport_guard.render_scale(),
		"quality": scene.quality_index, "presets": 2,
		"low_blends": low_blends,
		"low_runtime_dt_s": low_runtime_dt_s,
		"low_timings_ms": low_timings,
		"low_normalized_max_div": low_diagnostics.normalized_max_div,
		"method": true, "reinit": true, "clamp": true, "reset": true, "inlet": true}


func _blend_values(tree: SceneTree, scene: Node, count: int) -> Array[float]:
	var values: Array[float] = []
	for i in count:
		await tree.process_frame
		values.append(float((scene.volume.material_override as ShaderMaterial).get_shader_parameter(
			"frame_blend")))
	return values


func _scene_ready(tree: SceneTree, scene: Node) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while not scene.capture_ready() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	return scene.capture_ready()


func _translation(tree: SceneTree, frame_dt_s: float = 1.0 / 60.0) -> Dictionary:
	var config := LfmConfig.new()
	config.grid_dims = Vector3i(32, 32, 32)
	config.domain_size_m = Vector3.ONE
	config.reinit_every = 2
	config.solid_enabled = false
	config.inlet_speed_mps = 0.4
	config.inlet_angle_deg = 0.0
	var solver := LfmSolver3D.new()
	solver.start(config)
	if not await _ready(tree, solver):
		return {"error": "translation solver did not initialize"}
	await _step(tree, solver, 2, frame_dt_s)
	var sample := await _map(tree, solver, 0, Vector3i(16, 16, 16))
	var pos: Vector3 = sample.position
	var shift := Vector3(config.inlet_speed_mps * frame_dt_s, 0, 0)
	var error := maxf((sample.psi - (pos - shift)).length(),
		(sample.phi - (pos + shift)).length())
	error = maxf(error, (sample.T - Vector3.RIGHT).length())
	error = maxf(error, (sample.F - Vector3.RIGHT).length())
	solver.stop()
	await tree.process_frame
	return {"error_m": error} if error < 0.001 else {"error": "uniform map error %.6g" % error}


func _rotation(tree: SceneTree, rk4: bool = true) -> Dictionary:
	var config := LfmConfig.new()
	config.scenario = LfmConfig.Scenario.VORTEX_RING
	config.grid_dims = Vector3i(32, 32, 32)
	config.domain_size_m = Vector3.ONE
	config.reinit_every = 2
	config.map_rk4 = rk4
	var solver := LfmSolver3D.new()
	solver.start(config)
	if not await _ready(tree, solver):
		return {"error": "rotation solver did not initialize"}
	var seed: Array[PackedFloat32Array] = []
	for axis in 3:
		var fd := config.grid_dims + Vector3i(1 if axis == 0 else 0,
			1 if axis == 1 else 0, 1 if axis == 2 else 0)
		var field := PackedFloat32Array()
		field.resize(fd.x * fd.y * fd.z)
		for x in fd.x:
			for y in fd.y:
				for z in fd.z:
					var p := Vector3(x + (0.0 if axis == 0 else 0.5),
						y + (0.0 if axis == 1 else 0.5),
						z + (0.0 if axis == 2 else 0.5)) * config.cell_size_m()
					field[(x * fd.y + y) * fd.z + z] = \
						-(p.y - 0.5) if axis == 0 else ((p.x - 0.5) if axis == 1 else 0.0)
		seed.append(field)
	RenderingServer.call_on_render_thread(solver.march_seed_maps_render.bind(seed))
	await tree.process_frame
	var sample := await _map(tree, solver, 0, Vector3i(24, 16, 16))
	var p: Vector3 = sample.position - Vector3(0.5, 0.5, 0.0)
	var angle := config.frame_dt_s
	var backward := Vector3(0.5 + cos(angle) * p.x + sin(angle) * p.y,
		0.5 - sin(angle) * p.x + cos(angle) * p.y, sample.position.z)
	var forward := Vector3(0.5 + cos(angle) * p.x - sin(angle) * p.y,
		0.5 + sin(angle) * p.x + cos(angle) * p.y, sample.position.z)
	var error := maxf((sample.psi - backward).length(), (sample.phi - forward).length())
	error = maxf(error, (sample.T - Vector3(cos(angle), -sin(angle), 0)).length())
	error = maxf(error, (sample.F - Vector3(cos(angle), sin(angle), 0)).length())
	solver.stop()
	await tree.process_frame
	return {"error_m": error} if error < 0.003 else {"error": "rotating map error %.6g" % error}


func _comparison(tree: SceneTree, frame_dt_s: float = 1.0 / 60.0) -> Dictionary:
	var config := LfmConfig.new()
	config.scenario = LfmConfig.Scenario.VORTEX_RING
	config.grid_dims = Vector3i(32, 32, 32)
	config.domain_size_m = Vector3.ONE
	config.reinit_every = 2
	var mass0 := 0.0
	for value in LfmShapes.initial_smoke(config):
		mass0 += value * config.cell_size_m() ** 3
	var lfm := LfmSolver3D.new()
	lfm.start(config)
	if not await _ready(tree, lfm):
		return {"error": "ring solver did not initialize"}
	await _step(tree, lfm, 1, frame_dt_s)
	var first := await _diagnostics(tree, lfm)
	var drift := absf(first.smoke_mass - mass0) / maxf(mass0, 1e-10)
	await _step(tree, lfm, 19, frame_dt_s)
	var last := await _diagnostics(tree, lfm)
	lfm.stop()
	await tree.process_frame
	var baseline := LfmSolver3D.new()
	baseline.start(config)
	if not await _ready(tree, baseline):
		return {"error": "baseline solver did not initialize"}
	baseline.set_method(1)
	await _step(tree, baseline, 20, frame_dt_s)
	var reference := await _diagnostics(tree, baseline)
	print("LFM RING dt=%.6f lfm=%s baseline=%s drift=%.6f" % [
		frame_dt_s, str(last), str(reference), drift])
	baseline.stop()
	await tree.process_frame
	if int(last.get("nonfinite", -1)) != 0 or int(reference.get("nonfinite", -1)) != 0:
		return {"error": "nonfinite values in ring comparison"}
	if last.normalized_max_div > 0.001 or last.cg_relative_residual > 0.00001:
		return {"error": "ring projection failed: %s" % str(last)}
	if drift > 0.05:
		return {"error": "smoke drift %.4f" % drift}
	if last.kinetic_energy < reference.kinetic_energy:
		return {"error": "LFM energy %.6g < baseline %.6g" % [
			last.kinetic_energy, reference.kinetic_energy]}
	return {"lfm_energy": last.kinetic_energy,
		"baseline_energy": reference.kinetic_energy, "smoke_drift": drift,
		"normalized_max_div": last.normalized_max_div,
		"cg_relative_residual": last.cg_relative_residual}


func _quality_tradeoff(tree: SceneTree) -> Dictionary:
	var result := {}
	for substeps in [2, 3, 4, 5]:
		var config := LfmConfig.new()
		config.scenario = LfmConfig.Scenario.VORTEX_RING
		config.grid_dims = Vector3i(32, 32, 32)
		config.domain_size_m = Vector3.ONE
		config.reinit_every = substeps
		config.map_rk4 = substeps == 5
		var solver := LfmSolver3D.new()
		solver.start(config)
		if not await _ready(tree, solver):
			return {"error": "quality tradeoff solver did not initialize"}
		await _step(tree, solver, 30)
		var diagnostic := await _diagnostics(tree, solver)
		solver.stop()
		await tree.process_frame
		if diagnostic.nonfinite != 0 or diagnostic.normalized_max_div > 0.001:
			return {"error": "quality tradeoff projection: %s" % str(diagnostic)}
		result[str(substeps)] = {"kinetic_energy": diagnostic.kinetic_energy,
			"smoke_mass": diagnostic.smoke_mass,
			"peak_vorticity": diagnostic.peak_vorticity,
			"normalized_max_div": diagnostic.normalized_max_div}
	for substeps in [2, 3, 4]:
		var candidate: Dictionary = result[str(substeps)]
		var reference: Dictionary = result["5"]
		if absf(candidate.kinetic_energy / reference.kinetic_energy - 1.0) > 0.02 \
				or absf(candidate.smoke_mass / reference.smoke_mass - 1.0) > 0.02 \
				or absf(candidate.peak_vorticity / reference.peak_vorticity - 1.0) > 0.02:
			return {"error": "quality tradeoff exceeds 2%% at R%d: %s" % [
				substeps, str(result)]}
	return result


func _projection_compare(tree: SceneTree) -> Dictionary:
	var config := LfmConfig.new()
	config.grid_dims = Vector3i(64, 32, 32)
	config.domain_size_m = Vector3(2.0, 1.0, 1.0)
	config.reinit_every = 2
	var results := {}
	for enabled in [false, true]:
		var solver := LfmSolver3D.new()
		solver.start(config)
		if not await _ready(tree, solver):
			return {"error": "projection comparison solver did not initialize"}
		solver.set_multigrid(enabled)
		await _step(tree, solver, 4)
		var diagnostic := await _diagnostics(tree, solver)
		results["multigrid" if enabled else "jacobi"] = {
			"relative_residual": diagnostic.cg_relative_residual,
			"normalized_max_div": diagnostic.normalized_max_div,
			"peak_vorticity": diagnostic.peak_vorticity,
			"peak_axial_vorticity": diagnostic.peak_axial_vorticity,
			"timings_ms": solver.get_timings()}
		solver.stop()
		await tree.process_frame
	print("LFM PROJECTION ", results)
	var mg: Dictionary = results.multigrid
	var jacobi: Dictionary = results.jacobi
	if mg.relative_residual > 0.0001 or mg.normalized_max_div > 0.001 \
			or mg.relative_residual >= jacobi.relative_residual:
		return {"error": "obstacle projection: %s" % str(results)}
	return results


func _restart_preserves_state(tree: SceneTree) -> Dictionary:
	var config := LfmConfig.new()
	config.scenario = LfmConfig.Scenario.VORTEX_RING
	config.grid_dims = Vector3i(32, 32, 32)
	config.domain_size_m = Vector3.ONE
	config.reinit_every = 2
	var solver := LfmSolver3D.new()
	solver.start(config)
	if not await _ready(tree, solver):
		return {"error": "restart solver did not initialize"}
	await _step(tree, solver, 3)
	var before := await _diagnostics(tree, solver)
	config.reinit_every = 3
	solver.restart_preserving(config)
	if not await _ready(tree, solver):
		return {"error": "restart did not initialize"}
	var after := await _diagnostics(tree, solver)
	solver.stop()
	await tree.process_frame
	var drift: float = absf(after.smoke_mass - before.smoke_mass) / before.smoke_mass
	if drift > 0.0001 or absf(after.kinetic_energy - before.kinetic_energy) \
			> before.kinetic_energy * 0.01:
		return {"error": "restart changed the state: %.6g" % drift}
	return {"mass_drift": drift}


func _ready(tree: SceneTree, solver: LfmSolver3D) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while not solver.is_initialized() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	return solver.is_initialized()


func _step(tree: SceneTree, solver: LfmSolver3D, frames: int,
		frame_dt_s: float = -1.0) -> void:
	for i in frames:
		solver.step_frame(frame_dt_s)
		await tree.process_frame
	await tree.process_frame


func _map(tree: SceneTree, solver: LfmSolver3D, axis: int, c: Vector3i) -> Dictionary:
	RenderingServer.call_on_render_thread(solver.capture_map_sample_render.bind(axis, c))
	await tree.process_frame
	await tree.process_frame
	return solver.get_map_sample()


func _diagnostics(tree: SceneTree, solver: LfmSolver3D) -> Dictionary:
	RenderingServer.call_on_render_thread(solver.capture_diagnostics_render)
	await tree.process_frame
	await tree.process_frame
	return solver.get_diagnostics()
