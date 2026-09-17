extends SceneTree

## F-GRA-3 probe: does the grass blade fill (GrassRenderer.generate) run more
## than once at launch? Each generate() rebuilds all five LOD MultiMeshes, so
## sampling the identity of _lod_meshes[0] every frame counts the fills without
## touching the runtime path.
##
## seed=0  fresh settings (no persisted Density slider value)
## seed=1  persisted Density that differs from the tier density (0.7)
## seed=2  persisted Density equal to the tier density
##
## Log lines start with "GRA3 ".

const SAMPLE_FRAMES := 120
const TIER_DENSITY := 0.7 # GrassQualityProfile MEDIUM, the tier the probe pins
const DENSITY_KEY := "🌿 Grass Properties/Density"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for i in 2:
		await process_frame
	var seed_mode := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("seed="):
			seed_mode = int(arg.get_slice("=", 1))
	var settings: Node = root.get_node("/root/UserSettings")
	settings.clear_sim("grass_demo")
	# SimMenu derives its persistence section from GameManager.current_demo;
	# without the real launch flow it stays empty and restore is disabled.
	root.get_node("/root/GameManager").current_demo = "grass_demo"
	root.get_node("/root/GameManager").set_setting("grass_quality_profile", 1)
	if seed_mode == 1:
		settings.set_sim_value("grass_demo", DENSITY_KEY, 0.5)
	elif seed_mode == 2:
		settings.set_sim_value("grass_demo", DENSITY_KEY, TIER_DENSITY)

	var demo: Node = load("res://scenes/grass_demo.tscn").instantiate()

	var last_lod_id := 0
	var generates := 0
	var frames: Array = []
	var densities: Array = []

	# The first fill runs inside _ready during add_child, before the first
	# awaitable frame, so sample synchronously here and then every frame.
	root.add_child(demo)
	if not demo.grass._lod_meshes.is_empty():
		generates += 1
		frames.append(-1)
		densities.append(demo.grass.density)
		last_lod_id = (demo.grass._lod_meshes[0] as MultiMesh).get_instance_id()

	for frame in SAMPLE_FRAMES:
		await process_frame
		var grass: Node = demo.grass
		if grass == null:
			continue
		var meshes: Array = grass._lod_meshes
		if meshes.is_empty():
			continue
		var id: int = (meshes[0] as MultiMesh).get_instance_id()
		if id != last_lod_id:
			generates += 1
			frames.append(frame)
			densities.append(grass.density)
			last_lod_id = id

	print("GRA3 PROBE DONE seed=%d generates=%d frames=%s densities=%s final_density=%.3f" % [
		seed_mode, generates, str(frames), str(densities), demo.grass.density])
	quit(0)
