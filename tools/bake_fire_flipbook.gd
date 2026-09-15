extends SceneTree
## Bakes the game-fire flipbook atlases (docs/game_fire_rdr2_model.md step 1).
##
## Preferred path: the Fire-X solver runs for real on the GPU, its raymarched
## volume is rendered into a small SubViewport by a static near-orthographic
## camera, and 64 captures are assembled into an RGBA atlas (RGB emission,
## A coverage). Fallback (no RenderingDevice, --procedural, or a bake
## failure/timeout): the CPU noise generator from ProceduralFireAtlas. The
## smoke atlas is procedural in both paths — puffs need no simulation.
##
##   godot --path . -s res://tools/bake_fire_flipbook.gd            # auto
##   godot --path . -s res://tools/bake_fire_flipbook.gd -- procedural
##   godot --path . -s res://tools/bake_fire_flipbook.gd -- firex
##
## The GPU path needs a real rendering context: run it on the virtual display
## like the GPU test suites, never under --headless.

const FireSolverScript := preload("res://scripts/fire/fire_gpu_solver.gd")
const VOLUME_SHADER := "res://shaders/fire/sparse/fire.gdshader"
const OUT_DIR := "res://resources/game_fire/atlases"
const FLAME_OUT := "flame_atlas.png"
const SMOKE_OUT := "smoke_atlas.png"
const FRAMES := Vector2i(8, 8)
const CAPTURE_PX := 256
const CAPTURE_EVERY_STEPS := 3
const WARMUP_STEPS := 90
const TIMEOUT_MSEC := 240000

var _captured := 0
var _sim_steps_since_capture := 0
var _warmup_left := WARMUP_STEPS
var _atlas: Image
var _start_msec := 0
var _debug_frame := 0


func _initialize() -> void:
	_start_msec = Time.get_ticks_msec()
	_run()


func _run() -> void:
	var mode := "auto"
	for arg in OS.get_cmdline_user_args():
		if arg in ["procedural", "firex", "auto"]:
			mode = arg
	var flame: Image = null
	if mode != "procedural":
		flame = await _bake_firex()
		if flame == null and mode == "firex":
			print("BAKE FAIL firex requested but unavailable")
			quit(1)
			return
	if flame == null:
		print("BAKE flame atlas: procedural fallback")
		flame = ProceduralFireAtlas.flame_image(FRAMES, CAPTURE_PX)
	_save(flame, FLAME_OUT)
	var smoke := ProceduralFireAtlas.smoke_image(FRAMES, 128)
	_save(smoke, SMOKE_OUT)
	print("BAKE DONE in %.1f s" % (float(Time.get_ticks_msec() - _start_msec) / 1000.0))
	quit(0)


func _save(image: Image, name: String) -> void:
	var dir := DirAccess.open("res://resources")
	if dir != null:
		dir.make_dir_recursive("game_fire/atlases")
	var path := ProjectSettings.globalize_path("%s/%s" % [OUT_DIR, name])
	var error := image.save_png(path)
	print("BAKE saved %s (%s)" % [path, "ok" if error == OK else "error %d" % error])


# --- Fire-X capture path ----------------------------------------------------


func _bake_firex() -> Image:
	for _frame in 3:
		await process_frame
	if not GpuPreflight.available():
		print("BAKE no RenderingDevice, falling back to procedural")
		return null
	print("BAKE Fire-X capture start")
	var solver: FireGpuSolver = FireSolverScript.new()
	var volume_vp := _make_capture_viewport()
	var volume_node := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	volume_node.mesh = box
	var noise := FastNoiseLite.new()
	noise.frequency = 0.08
	noise.fractal_octaves = 3
	var noise_tex := NoiseTexture3D.new()
	noise_tex.seamless = true
	noise_tex.width = 64
	noise_tex.height = 64
	noise_tex.depth = 64
	noise_tex.noise = noise
	var material := ShaderMaterial.new()
	material.shader = load(VOLUME_SHADER)
	material.set_shader_parameter("noise_tex", noise_tex)
	material.set_shader_parameter("temporal_blend", 1.0)
	volume_node.material_override = material
	volume_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	volume_vp.add_child(volume_node)
	RenderingServer.call_on_render_thread(solver.init_render)
	var waited := 0
	while not solver.initialized:
		await process_frame
		waited += 1
		if waited > 900:
			print("BAKE solver never initialized")
			return null
	FireVolumeBinding.bind(material, solver)
	solver.wind = Vector3.ZERO
	solver.push_event(FireGpuSolver.EVENT_IGNITE, Vector3(0, 0.5, 0), 1.0, 0.4)

	_atlas = Image.create(FRAMES.x * CAPTURE_PX, FRAMES.y * CAPTURE_PX, false,
		Image.FORMAT_RGBA8)
	while _captured < FRAMES.x * FRAMES.y:
		if Time.get_ticks_msec() - _start_msec > TIMEOUT_MSEC:
			print("BAKE timeout with %d/%d captures" % [_captured, FRAMES.x * FRAMES.y])
			return _atlas if _captured == FRAMES.x * FRAMES.y else null
		await process_frame
		var delta := root.get_process_delta_time()
		var steps := solver.schedule_steps(delta)
		var sim_dt := float(steps) * solver.timestep
		var run_fire := steps > 0
		var sim_steps := steps
		var fuel_amount := 0.2 * sim_dt
		_debug_frame += 1
		if _debug_frame % 30 == 0:
			var stats := solver.get_stats()
			print("BAKE dbg frames=%d steps=%d T=%.1f R=%.2f clip=%s" % [
				_debug_frame, steps, stats["max_temperature"],
				stats["max_reaction"], solver.display_clip_box()])
		RenderingServer.call_on_render_thread(func() -> void:
			if run_fire:
				solver.capture_interpolation_state_render()
				solver.prepare_topology_render()
				solver.push_event(FireGpuSolver.EVENT_FUEL, Vector3(0, 0.3, 0),
					0.8, fuel_amount)
				solver.step_render(sim_steps, false)
			else:
				solver.poll_render())
		FireVolumeBinding.track_proxy(material, volume_node, box, solver)
		if run_fire:
			_sim_steps_since_capture += sim_steps
		if _warmup_left > 0:
			if run_fire:
				_warmup_left -= sim_steps
			continue
		if _sim_steps_since_capture >= CAPTURE_EVERY_STEPS:
			_sim_steps_since_capture = 0
			await RenderingServer.frame_post_draw
			var image := volume_vp.get_texture().get_image()
			image.convert(Image.FORMAT_RGBA8)
			var cell_x := (_captured % FRAMES.x) * CAPTURE_PX
			var cell_y := (_captured / FRAMES.x) * CAPTURE_PX
			_atlas.blit_rect(image, Rect2i(0, 0, CAPTURE_PX, CAPTURE_PX),
				Vector2i(cell_x, cell_y))
			_captured += 1
			if _captured % 16 == 0:
				print("BAKE captured %d/%d" % [_captured, FRAMES.x * FRAMES.y])
	# Release the wrapper textures before the solver frees the RIDs underneath,
	# and stop rendering the volume first so no frame samples freed textures.
	volume_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	volume_node.visible = false
	FireVolumeBinding.unbind(material)
	await process_frame
	await process_frame
	RenderingServer.call_on_render_thread(solver.free_render)
	await process_frame
	_boost_alpha(_atlas, 2.6)
	print("BAKE Fire-X capture complete")
	return _atlas


## The raw raymarch coverage is too translucent for additive billboard use:
## scale the alpha channel up once at bake time.
func _boost_alpha(image: Image, gain: float) -> void:
	var data := image.get_data()
	for index in range(3, data.size(), 4):
		data[index] = mini(255, int(data[index]) * gain)
	image.set_data(image.get_width(), image.get_height(), false,
		image.get_format(), data)


func _make_capture_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.positional_shadow_atlas_size = 0
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.size = Vector2i(CAPTURE_PX, CAPTURE_PX)
	var camera := Camera3D.new()
	camera.fov = 28.0
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0)
	camera.environment = env
	viewport.add_child(camera)
	camera.current = true
	camera.look_at_from_position(Vector3(0.0, 2.6, 14.0), Vector3(0.0, 3.0, 0.0))
	root.add_child(viewport)
	return viewport
