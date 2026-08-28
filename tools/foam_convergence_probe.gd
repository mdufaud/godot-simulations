extends SceneTree
## Fix plan 0.2: tranche la divergence "13,6 % à l'équilibre / 0 % à la frame 180"
## en journalisant la couverture d'écume du preset Storm sur une simulation vive
## longue (dt = 1/30 s). Attendu si l'hypothèse M1 (équilibre non atteint) est
## la bonne : montée logistique vers l'équilibre avec constante de temps
## ~3-4 x foam_persistence (13-17 s). Si la couverture reste ~0 à f1800, le bug
## est dans le chemin de lecture (indices ping-pong).
##
##   godot -s res://tools/foam_convergence_probe.gd   (sur affichage GPU virtuel)

const SAMPLE_FRAMES := [60, 120, 180, 600, 1800]
const FIXED_DT := 1.0 / 30.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	for frame in 360:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	if not demo.solver.initialized or not demo.texture_bound:
		push_error("FOAM PROBE FAIL: ocean did not initialize")
		quit(1)
		return
	demo.apply_preset(3)
	demo.set_backend(OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)
	demo.set_capture_time(20.0)
	demo.set_capture_fixed_delta(FIXED_DT)
	demo.set_capture_ui(false)
	demo.set_capture_interaction(false)
	demo.set_frozen(false)
	var elapsed := 0
	for target in SAMPLE_FRAMES:
		while elapsed < target:
			await process_frame
			elapsed += 1
		demo.set_frozen(true)
		var meta: String = await demo.capture_metadata_async("probe_frame_%d" % target)
		var seconds := float(target) * FIXED_DT
		print("FOAM CONVERGENCE frame=%d seconds=%.1f foam_cov=%s foam_cov_visible=%s breaking_cov_visible=%s foam_layers=%s" % [
			target, seconds,
			_extract(meta, " foam_cov="), _extract(meta, " foam_cov_visible="),
			_extract(meta, " breaking_cov_visible="),
			_extract(meta, " foam_cov_layers=")])
		demo.set_frozen(false)
	demo.queue_free()
	await process_frame
	print("FOAM CONVERGENCE DONE")
	quit(0)


func _extract(meta: String, key: String) -> String:
	var index := meta.find(key)
	if index < 0:
		return "n/a"
	var rest := meta.substr(index + key.length())
	var end := rest.find(" ")
	return rest.substr(0, end) if end >= 0 else rest
