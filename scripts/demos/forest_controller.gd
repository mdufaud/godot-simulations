extends Node3D
## Forest Walk demo: procedural rolling-hill terrain, procedurally generated
## trees (broadleaf + conifer) with mesh LODs + billboard impostors, tiled
## LOD grass, flowers in clearings, sunny sky with light clouds.
## Two looks switchable at runtime: photoreal (PBR textures, SSAO/SSIL,
## volumetric fog) and low-poly (flat shading, vertex colors, gradient sky).

const TERRAIN_SHADER := preload("res://shaders/forest/terrain.gdshader")
const FLOWER_SHADER := preload("res://shaders/forest/flower.gdshader")
const BARK_SHADER := preload("res://shaders/forest/tree_bark.gdshader")
const LEAVES_SHADER := preload("res://shaders/forest/tree_leaves.gdshader")
const IMPOSTOR_SHADER := preload("res://shaders/forest/tree_impostor.gdshader")
const TreeGen := preload("res://scripts/demos/forest_tree_generator.gd")
const Lib := preload("res://scripts/demos/forest_scanned_lib.gd")
const GRASS_MESH_HIGH := preload("res://resources/grass/grass_high.obj")
const GRASS_MESH_LOW := preload("res://resources/grass/grass_low.obj")
const GRASS_MAT := preload("res://resources/grass/grass_material.tres")

const SCANNED_CONIFERS: Array[String] = [
	"pine_tree_01_a", "pine_tree_01_b", "pine_tree_01_c",
	"fir_tree_01_a", "fir_tree_01_b", "fir_tree_01_c",
]
const SCANNED_BROADLEAF: Array[String] = ["jacaranda_tree", "island_tree_01", "tree_small_02"]

const MAP_TEXELS := 512  # heightmap texels; 1 texel = 1 m (grass.gdshader convention)
const HEIGHT_SCALE := 14.0
const TERRAIN_SIZE := 400.0
const BLEND_TEXELS := 96  # cross-fade band that makes the noise wrap-continuous
const PLAY_RADIUS := 185.0
const FOREST_TEX_DIR := "res://resources/forest"

const TILE_SIZE := 10.0
const GRASS_RADIUS := 80.0
const GRASS_SHADOW_DISTANCE := 40.0

const FLOWER_SECTOR := 45.0
const FLOWER_RADIUS := 90.0

const VARIANT_COUNT := 6
const TREE_RADIUS := 190.0
# Distance bands per bucket; the last bucket (impostors) catches the rest.
# Vertex throughput is the measured wall: tight ULTRA/MID reach keeps the
# near-field detail without feeding millions of tris to the shadow passes.
const BUCKET_DISTS: Array[float] = [18.0, 45.0, 90.0]
const BUCKET_COUNT := 4
const REBUCKET_MOVE := 8.0

var _height_data: PackedFloat32Array
var _height_tex: ImageTexture
var _noise: FastNoiseLite
var _clearing_noise: FastNoiseLite
var _path_noise: FastNoiseLite
var _spawn_point := Vector3.ZERO
var _terrain_mat: ShaderMaterial
var _textures_missing := false

var _grass_mat: ShaderMaterial
var _grass_tiles: Array[Array] = []
var _grass_density := 0.6
var _previous_tile := Vector3.INF
var _flower_mat: ShaderMaterial
var _flower_count := 0

var _cloud_mat: ShaderMaterial
var _cloud_deck: MeshInstance3D
var _sky_photoreal: Sky
var _sky_lowpoly: Sky
var _time_of_day := 0.45

var _bark_mat_broadleaf: ShaderMaterial
var _bark_mat_conifer: ShaderMaterial
var _leaves_mat: ShaderMaterial
var _tree_sets := {}  # 0 = scanned photoreal, 1 = procedural low-poly
var _tree_variants: Array[Dictionary] = []
var _scanned_missing := false
var _cards_baked := false
var _tree_body: RID
var _tree_shapes: Array[RID] = []
var _tree_density := 1.0
var _tree_total := 0
var _bucket_counts := [0, 0, 0, 0]
var _last_bucket_pos := Vector3.INF

var _clump_tiles: Array[Array] = []
var _patch_defs: Array[Dictionary] = []
var _understory_counts := {}
var _flowers_lp: Node3D
var _flowers_pr: Node3D
var _understory: Node3D

var _mode := 0
var _impostor_cache := {}  # mode -> Array[Texture2D]
var _baking := false
var _grass_instances := 0
var _profiler_label: Label
var _profile_accum := 0.0
var _loaded := false
var _loading_label: Label
var _load_cache := {}  # "P|asset|tris|follow" / "T|variant" -> loaded Dictionary
var _work_list: Array = []
var _work_results: Array = []
var _next_job := 0
var _threads_done := 0
var _job_mutex := Mutex.new()
var _load_threads: Array[Thread] = []

@onready var menu: SimMenu = $UI/SimMenu
@onready var player: FpsWalker = $Player
@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment


func _ready() -> void:
	# Instant part: a walkable, visible world on the very first frame. Heavy
	# texture/model loading streams in afterwards (see _stream_content) so the
	# window never looks frozen/crashed while it opens.
	Lib.reset()
	_build_heightfield()
	RenderingServer.global_shader_parameter_set("heightmap", _height_tex)
	RenderingServer.global_shader_parameter_set("heightmap_scale", HEIGHT_SCALE)
	RenderingServer.global_shader_parameter_set("player_position", Vector3.ZERO)
	_clearing_noise = FastNoiseLite.new()
	_clearing_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_clearing_noise.seed = 777
	_clearing_noise.frequency = 0.012
	_path_noise = FastNoiseLite.new()
	_path_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_path_noise.seed = 4321
	_path_noise.frequency = 0.004
	_spawn_point = _find_spawn()
	_setup_terrain()
	_setup_environment()
	player.set_pose(_spawn_point + Vector3(0, 1.0, 0), 0.0, 0.0)
	_show_loading_banner()
	call_deferred("_setup_profiler")
	_stream_content.call_deferred()


## Streams the world in after the first present. The heavy work (glTF parse +
## meshopt LOD + texture decode of every tree and plant) runs in parallel on a
## background thread pool; the main thread only assembles scene nodes from the
## cached results, so the window stays responsive and CPU load is ~3x faster.
func _stream_content() -> void:
	await get_tree().process_frame
	_set_loading_banner("Loading ground…")
	_load_terrain_textures()

	await _preload_all()

	_set_loading_banner("Loading grass…")
	_grass_density = GameManager.get_setting("forest_grass_density", 0.6)
	_setup_grass_instances()
	_setup_clump_patches()

	await get_tree().process_frame
	_set_loading_banner("Loading trees…")
	_tree_density = GameManager.get_setting("forest_tree_density", 1.0)
	_setup_trees()

	await get_tree().process_frame
	_set_loading_banner("Loading flowers…")
	_setup_flowers()

	await get_tree().process_frame
	_set_loading_banner("Loading understory…")
	await _setup_understory()

	await get_tree().process_frame
	_apply_mode(GameManager.get_setting("forest_quality_mode", 0))
	await _build_tree_collision_async()
	_loaded = true
	_setup_ui()
	_hide_loading_banner()


## Every plant/tree resource the setup steps will need, loaded in parallel on
## background threads (see forest_scanned_lib mutex) into _load_cache.
func _preload_all() -> void:
	_work_list = []
	for variant in SCANNED_CONIFERS + SCANNED_BROADLEAF:
		_work_list.append({kind = "T", asset = variant})
	_work_list.append({kind = "T", asset = "island_tree_03"})
	var plant_jobs := [
		["grass_medium_01", 450, true], ["grass_medium_02", 450, true],
		["dandelion_01", 500, false], ["periwinkle_plant", 500, false],
		["fern_02", 900, false], ["nettle_plant", 700, false],
		["weed_plant_02", 700, false], ["periwinkle_plant", 700, false],
		["pine_sapling_small", 4000, false], ["tree_stump_01", 4000, false],
		["dead_tree_trunk", 5000, false], ["rock_moss_set_01", 3000, false],
		["pine_roots", 5000, false], ["shrub_01", 2200, false],
		["shrub_02", 2200, false], ["shrub_03", 2200, false],
		["shrub_04", 2200, false],
	]
	for job: Array in plant_jobs:
		_work_list.append({kind = "P", asset = job[0], tris = job[1], follow = job[2]})
	_work_results.resize(_work_list.size())
	_next_job = 0
	_threads_done = 0

	# Manual Thread pool (NOT WorkerThreadPool — that segfaults doing glTF /
	# meshopt concurrent with the live renderer; verified). Each thread pulls
	# jobs from a mutex-guarded index and writes its own result slot. LOW
	# priority + leaving cores free keeps the render thread smooth during load.
	var n_threads := clampi(OS.get_processor_count() - 3, 2, 4)
	for t in n_threads:
		var th := Thread.new()
		th.start(_load_worker, Thread.PRIORITY_LOW)
		_load_threads.append(th)
	while _threads_done < n_threads:
		await get_tree().process_frame
	for th in _load_threads:
		th.wait_to_finish()
	_load_threads.clear()
	for i in _work_list.size():
		_load_cache[_work_key(_work_list[i])] = _work_results[i]


func _load_worker() -> void:
	while true:
		_job_mutex.lock()
		var i := _next_job
		_next_job += 1
		_job_mutex.unlock()
		if i >= _work_list.size():
			break
		var w: Dictionary = _work_list[i]
		if w.kind == "T":
			_work_results[i] = Lib.load_baked_tree(w.asset)
		else:
			_work_results[i] = Lib.load_plants(w.asset, int(w.tris), bool(w.follow))
	_job_mutex.lock()
	_threads_done += 1
	_job_mutex.unlock()


func _work_key(w: Dictionary) -> String:
	if w.kind == "T":
		return "T|%s" % w.asset
	return "P|%s|%d|%s" % [w.asset, int(w.tris), bool(w.follow)]


## Cached parallel-loaded result, or a synchronous load if it was not preloaded
## (keeps every call site working even off the streaming path).
func _plants(asset: String, tris: int, follow: bool = false) -> Dictionary:
	var key := "P|%s|%d|%s" % [asset, tris, follow]
	if _load_cache.has(key):
		return _load_cache[key]
	var r := Lib.load_plants(asset, tris, follow)
	_load_cache[key] = r
	return r


func _baked_tree(variant: String) -> Dictionary:
	var key := "T|%s" % variant
	if _load_cache.has(key):
		return _load_cache[key]
	var r := Lib.load_baked_tree(variant)
	_load_cache[key] = r
	return r


func _process(delta: float) -> void:
	if _profiler_label == null or not _profiler_label.visible:
		return
	_profile_accum += delta
	if _profile_accum >= 0.25:
		_profile_accum = 0.0
		_update_overlay()


func _show_loading_banner() -> void:
	_loading_label = Label.new()
	_loading_label.add_theme_font_size_override("font_size", 22)
	_loading_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_loading_label.add_theme_constant_override("outline_size", 6)
	_loading_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_loading_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_loading_label.position.y = -80.0
	_loading_label.text = "Loading forest…"
	$UI.add_child(_loading_label)


func _set_loading_banner(text: String) -> void:
	if _loading_label != null:
		_loading_label.text = text


func _hide_loading_banner() -> void:
	if _loading_label != null:
		_loading_label.queue_free()
		_loading_label = null


func _physics_process(_delta: float) -> void:
	RenderingServer.global_shader_parameter_set("player_position", player.global_position)
	# Keep the player on the terrain mesh.
	var xz := Vector2(player.global_position.x, player.global_position.z)
	if xz.length() > PLAY_RADIUS:
		xz = xz.normalized() * PLAY_RADIUS
		player.global_position.x = xz.x
		player.global_position.z = xz.y

	# Recenter the grass/clump tile grids on the player's tile.
	var tile_id: Vector3 = ((player.global_position + Vector3.ONE * TILE_SIZE * 0.5)
			/ TILE_SIZE * Vector3(1, 0, 1)).floor()
	if tile_id != _previous_tile:
		for data in _grass_tiles:
			data[0].global_position = data[1] + Vector3(1, 0, 1) * TILE_SIZE * tile_id
		for data in _clump_tiles:
			data[0].global_position = data[1] + Vector3(1, 0, 1) * TILE_SIZE * tile_id
		_previous_tile = tile_id

	_rebucket_trees()


# ── Terrain ──────────────────────────────────────────────────────────────────

func _build_heightfield() -> void:
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = 1337
	_noise.frequency = 0.006
	_noise.fractal_octaves = 3
	_height_data.resize(MAP_TEXELS * MAP_TEXELS)
	for j in MAP_TEXELS:
		var row := j * MAP_TEXELS
		for i in MAP_TEXELS:
			_height_data[row + i] = _tileable_noise(_noise, i + 0.5, j + 0.5) * 0.5 + 0.5
	var img := Image.create_from_data(
		MAP_TEXELS, MAP_TEXELS, false, Image.FORMAT_RF, _height_data.to_byte_array())
	_height_tex = ImageTexture.create_from_image(img)


## Noise made continuous across the MAP_TEXELS wrap by cross-fading with copies
## shifted one period back; texture repeat then never shows a seam (the grass
## shader samples world.xz / textureSize with repeat_enable).
func _tileable_noise(noise: FastNoiseLite, x: float, y: float) -> float:
	var n := float(MAP_TEXELS)
	var wx := clampf((x - (n - BLEND_TEXELS)) / BLEND_TEXELS, 0.0, 1.0)
	var wy := clampf((y - (n - BLEND_TEXELS)) / BLEND_TEXELS, 0.0, 1.0)
	var v := noise.get_noise_2d(x, y)
	if wx > 0.0:
		v = lerpf(v, noise.get_noise_2d(x - n, y), wx)
	if wy > 0.0:
		var v1 := noise.get_noise_2d(x, y - n)
		if wx > 0.0:
			v1 = lerpf(v1, noise.get_noise_2d(x - n, y - n), wx)
		v = lerpf(v, v1, wy)
	return v


## Clearing noise (R) + path band (G) baked into a repeat texture with the
## same world mapping as the heightmap: grass lands in clearings, pebbles on
## the path.
func _build_clearing_mask() -> ImageTexture:
	var data := PackedByteArray()
	data.resize(MAP_TEXELS * MAP_TEXELS * 2)
	for j in MAP_TEXELS:
		var row := j * MAP_TEXELS * 2
		for i in MAP_TEXELS:
			var v := _tileable_noise(_clearing_noise, i + 0.5, j + 0.5) * 0.5 + 0.5
			var ridge := absf(_tileable_noise(_path_noise, i + 0.5, j + 0.5))
			var path := 1.0 - smoothstep(0.016, 0.034, ridge)
			data[row + i * 2] = int(clampf(v, 0.0, 1.0) * 255.0)
			data[row + i * 2 + 1] = int(clampf(path, 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(MAP_TEXELS, MAP_TEXELS, false, Image.FORMAT_RG8, data)
	return ImageTexture.create_from_image(img)


## Clearing noise with the same wrap-continuous mapping as the baked mask, so
## scatter decisions and the terrain grass layer agree everywhere.
func _clearing_sample(x: float, z: float) -> float:
	return _tileable_noise(_clearing_noise, fposmod(x, float(MAP_TEXELS)),
			fposmod(z, float(MAP_TEXELS)))


## Distance-ish to the walking path: |ridge| of a low-frequency noise, wrap
## continuous. Below ~0.045 is on the path.
func _path_sample(x: float, z: float) -> float:
	return absf(_tileable_noise(_path_noise, fposmod(x, float(MAP_TEXELS)),
			fposmod(z, float(MAP_TEXELS))))


func _on_path(x: float, z: float, margin: float = 0.0) -> bool:
	return _path_sample(x, z) < 0.028 + margin


## Spawn on the path, under the canopy, on gentle ground — the reference look
## is an interior view down a path, not an open lawn.
func _find_spawn() -> Vector3:
	var best := Vector3.ZERO
	var best_score := -INF
	for gi in range(-80, 81, 4):
		for gj in range(-80, 81, 4):
			var x := float(gi)
			var z := float(gj)
			if not _on_path(x, z):
				continue
			if _terrain_slope(x, z) > deg_to_rad(18.0):
				continue
			var canopy := -_clearing_sample(x, z)  # more negative noise = denser trees
			var score := canopy - Vector2(x, z).length() * 0.004
			if score > best_score:
				best_score = score
				best = Vector3(x, 0.0, z)
	if best_score == -INF:
		best = Vector3.ZERO
	best.y = _terrain_height(best.x, best.z)
	return best


## Bilinear height at world (x, z) — replicates GPU texture(heightmap, xz/size)
## with repeat wrapping, so scatter/collision/mesh all agree.
func _terrain_height(x: float, z: float) -> float:
	var u := x - 0.5
	var v := z - 0.5
	var i0 := posmod(int(floorf(u)), MAP_TEXELS)
	var j0 := posmod(int(floorf(v)), MAP_TEXELS)
	var i1 := (i0 + 1) % MAP_TEXELS
	var j1 := (j0 + 1) % MAP_TEXELS
	var fx := u - floorf(u)
	var fz := v - floorf(v)
	var h00 := _height_data[j0 * MAP_TEXELS + i0]
	var h10 := _height_data[j0 * MAP_TEXELS + i1]
	var h01 := _height_data[j1 * MAP_TEXELS + i0]
	var h11 := _height_data[j1 * MAP_TEXELS + i1]
	var h := lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)
	return (h - 0.5) * HEIGHT_SCALE


## Slope in radians at world (x, z), from central differences.
func _terrain_slope(x: float, z: float) -> float:
	var e := 1.0
	var dx := (_terrain_height(x + e, z) - _terrain_height(x - e, z)) / (2.0 * e)
	var dz := (_terrain_height(x, z + e) - _terrain_height(x, z - e)) / (2.0 * e)
	return atan(sqrt(dx * dx + dz * dz))


func _setup_terrain() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(TERRAIN_SIZE, TERRAIN_SIZE)
	plane.subdivide_width = 199
	plane.subdivide_depth = 199
	_terrain_mat = ShaderMaterial.new()
	_terrain_mat.shader = TERRAIN_SHADER
	_terrain_mat.set_shader_parameter("clearing_mask", _build_clearing_mask())

	var mesh_instance: MeshInstance3D = $Terrain/MeshInstance3D
	mesh_instance.mesh = plane
	mesh_instance.material_override = _terrain_mat
	# Displaced in the vertex shader: widen the AABB so it never gets culled.
	mesh_instance.custom_aabb = AABB(
		Vector3(-TERRAIN_SIZE * 0.5, -HEIGHT_SCALE, -TERRAIN_SIZE * 0.5),
		Vector3(TERRAIN_SIZE, HEIGHT_SCALE * 2.0, TERRAIN_SIZE))

	var shape := HeightMapShape3D.new()
	var points := MAP_TEXELS + 1
	shape.map_width = points
	shape.map_depth = points
	var map_data := PackedFloat32Array()
	map_data.resize(points * points)
	var half := (points - 1) / 2.0
	for j in points:
		for i in points:
			map_data[j * points + i] = _terrain_height(i - half, j - half)
	shape.map_data = map_data
	$Terrain/CollisionShape3D.shape = shape


## Ground/grass/pebble textures, loaded after the first frame so opening the
## scene is instant (flat fallback ground shows until this swaps them in).
func _load_terrain_textures() -> void:
	var diff := _load_forest_tex("forest_floor", "diff")
	var nor := _load_forest_tex("forest_floor", "nor_gl")
	var arm := _load_forest_tex("forest_floor", "arm")
	if diff != null and nor != null and arm != null:
		_terrain_mat.set_shader_parameter("albedo_tex", diff)
		_terrain_mat.set_shader_parameter("normal_tex", nor)
		_terrain_mat.set_shader_parameter("arm_tex", arm)
		_terrain_mat.set_shader_parameter("use_textures", true)
	var g_diff := _load_forest_tex("leafy_grass", "diff")
	var g_nor := _load_forest_tex("leafy_grass", "nor_gl")
	var g_arm := _load_forest_tex("leafy_grass", "arm")
	if g_diff != null and g_nor != null and g_arm != null:
		_terrain_mat.set_shader_parameter("grass_albedo_tex", g_diff)
		_terrain_mat.set_shader_parameter("grass_normal_tex", g_nor)
		_terrain_mat.set_shader_parameter("grass_arm_tex", g_arm)
		_terrain_mat.set_shader_parameter("use_grass_layer", true)
	var layer_ok := true
	for pair in [["forest_ground_06", "ground"], ["dry_river_pebbles", "pebble"]]:
		var l_diff := _load_forest_tex(pair[0], "diff")
		var l_nor := _load_forest_tex(pair[0], "nor_gl")
		var l_arm := _load_forest_tex(pair[0], "arm")
		if l_diff == null or l_nor == null or l_arm == null:
			layer_ok = false
			continue
		_terrain_mat.set_shader_parameter(pair[1] + "_albedo_tex", l_diff)
		_terrain_mat.set_shader_parameter(pair[1] + "_normal_tex", l_nor)
		_terrain_mat.set_shader_parameter(pair[1] + "_arm_tex", l_arm)
	_terrain_mat.set_shader_parameter("use_ground_layers", layer_ok)


func _load_forest_tex(asset: String, kind: String) -> Texture2D:
	var path := "%s/%s/%s_%s_2k.jpg" % [FOREST_TEX_DIR, asset, asset, kind]
	var tex := load(path) as Texture2D
	if tex == null:
		_textures_missing = true
		return null
	return tex


# ── Grass (tile/LOD system ported from grass_controller.gd) ─────────────────

func _setup_grass_instances() -> void:
	# Duplicate: shader params set on the shared .tres would leak into grass_demo.
	_grass_mat = GRASS_MAT.duplicate()
	var half := TILE_SIZE * 0.5
	var tile_aabb := AABB(
		Vector3(-half - 2.0, -HEIGHT_SCALE * 0.5 - 0.5, -half - 2.0),
		Vector3(TILE_SIZE + 4.0, HEIGHT_SCALE + 3.0, TILE_SIZE + 4.0)
	)
	for i in range(-GRASS_RADIUS, GRASS_RADIUS, TILE_SIZE):
		for j in range(-GRASS_RADIUS, GRASS_RADIUS, TILE_SIZE):
			var instance := MultiMeshInstance3D.new()
			instance.material_override = _grass_mat
			instance.position = Vector3(i, 0.0, j)
			instance.custom_aabb = tile_aabb
			var near := instance.position.length() < GRASS_SHADOW_DISTANCE
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if near \
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			$GrassContainer.add_child(instance)
			_grass_tiles.append([instance, instance.position])


func _generate_grass_multimeshes() -> void:
	var density := _grass_density * (0.7 if _mode == 1 else 1.0)
	var multimesh_lods: Array[MultiMesh] = [
		_create_grass_multimesh(1.0 * density, GRASS_MESH_HIGH),
		_create_grass_multimesh(0.5 * density, GRASS_MESH_HIGH),
		_create_grass_multimesh(0.25 * density, GRASS_MESH_LOW),
		_create_grass_multimesh(0.1 * density, GRASS_MESH_LOW),
		_create_grass_multimesh(0.02 * (1.0 if density != 0.0 else 0.0), GRASS_MESH_LOW),
	]
	for data in _grass_tiles:
		var distance: float = data[1].length()
		if distance > GRASS_RADIUS:
			continue
		if distance < 12.0:
			data[0].multimesh = multimesh_lods[0]
		elif distance < 30.0:
			data[0].multimesh = multimesh_lods[1]
		elif distance < 50.0:
			data[0].multimesh = multimesh_lods[2]
		elif distance < 65.0:
			data[0].multimesh = multimesh_lods[3]
		else:
			data[0].multimesh = multimesh_lods[4]
	_grass_instances = 0
	for data in _grass_tiles:
		if data[0].multimesh != null:
			_grass_instances += data[0].multimesh.instance_count


func _create_grass_multimesh(density: float, mesh: Mesh) -> MultiMesh:
	var row_size := int(ceil(TILE_SIZE * lerpf(0.0, 10.0, density)))
	var multimesh := MultiMesh.new()
	multimesh.mesh = mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = row_size * row_size
	var jitter := TILE_SIZE / float(row_size) * 0.5 * 0.9 if row_size > 0 else 0.0
	for i in row_size:
		for j in row_size:
			var pos := Vector3(i / float(row_size) - 0.5, 0, j / float(row_size) - 0.5) * TILE_SIZE
			var offset := Vector3(randf_range(-jitter, jitter), 0, randf_range(-jitter, jitter))
			multimesh.set_instance_transform(i + j * row_size, Transform3D(Basis(), pos + offset))
	return multimesh


# ── Photoreal clump grass (scanned patches on the textured ground) ──────────

const CLUMP_RADIUS := 45.0

## Merges scanned grass clumps into ~1.5 m patch meshes: one instance covers
## far more ground than a single clump, keeping instance counts sane.
func _setup_clump_patches() -> void:
	for asset in ["grass_medium_01", "grass_medium_02"]:
		var plants := _plants(asset, 450, true)
		if plants.is_empty():
			continue
		var items: Array = plants.items
		var rng := RandomNumberGenerator.new()
		rng.seed = asset.hash()
		for p in 2:
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var mat: ShaderMaterial = null
			for c in 6:
				var item: Dictionary = items[rng.randi_range(0, items.size() - 1)]
				var mesh: ArrayMesh = item.mesh
				if mesh.get_surface_count() == 0:
					continue
				mat = mesh.surface_get_material(0)
				var basis := Basis(Vector3.UP, rng.randf() * TAU)
				basis = basis.scaled(Vector3.ONE * rng.randf_range(0.9, 1.4))
				var xf := Transform3D(basis,
						Vector3(rng.randf_range(-0.7, 0.7), 0.0, rng.randf_range(-0.7, 0.7)))
				for s in mesh.get_surface_count():
					st.append_from(mesh, s, xf)
			var patch := st.commit()
			if patch.get_surface_count() > 0 and mat != null:
				mat.set_shader_parameter("albedo_boost", 1.3)
				patch.surface_set_material(0, mat)
				_patch_defs.append({mesh = patch})
	if _patch_defs.is_empty():
		return
	var half := TILE_SIZE * 0.5
	var tile_aabb := AABB(
		Vector3(-half - 2.0, -HEIGHT_SCALE * 0.5 - 0.5, -half - 2.0),
		Vector3(TILE_SIZE + 4.0, HEIGHT_SCALE + 2.0, TILE_SIZE + 4.0))
	for i in range(-CLUMP_RADIUS, CLUMP_RADIUS, TILE_SIZE):
		for j in range(-CLUMP_RADIUS, CLUMP_RADIUS, TILE_SIZE):
			var instance := MultiMeshInstance3D.new()
			instance.position = Vector3(i, 0.0, j)
			instance.custom_aabb = tile_aabb
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			$ClumpContainer.add_child(instance)
			_clump_tiles.append([instance, instance.position])


func _generate_clump_multimeshes() -> void:
	if _patch_defs.is_empty():
		return
	var density := _grass_density
	var near_mms: Array[MultiMesh] = []
	var far_mms: Array[MultiMesh] = []
	for def in _patch_defs:
		near_mms.append(_create_clump_multimesh(def.mesh, int(14.0 * density)))
		far_mms.append(_create_clump_multimesh(def.mesh, int(6.0 * density)))
	var counted := 0
	for t in _clump_tiles.size():
		var data: Array = _clump_tiles[t]
		var distance: float = data[1].length()
		var pool := near_mms if distance < 25.0 else far_mms
		data[0].multimesh = pool[t % pool.size()]
		counted += data[0].multimesh.instance_count
	if not $GrassContainer.visible:
		_grass_instances = counted


func _create_clump_multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.mesh = mesh
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = maxi(count, 1)
	var half := TILE_SIZE * 0.5 - 0.4
	for k in mm.instance_count:
		var basis := Basis(Vector3.UP, randf() * TAU)
		basis = basis.scaled(Vector3.ONE * randf_range(1.8, 3.0))
		mm.set_instance_transform(k, Transform3D(basis,
				Vector3(randf_range(-half, half), 0.0, randf_range(-half, half))))
	return mm


# ── Sky / environment ────────────────────────────────────────────────────────

## Sunny-day dressing: physical sky driven by the sun light, a light FBM cloud
## deck (ocean_clouds shader with low cover), distance fog for the horizon and
## a touch of volumetric haze. The low-poly sky is prebuilt for instant swaps.
func _setup_environment() -> void:
	var pmat := PhysicalSkyMaterial.new()
	pmat.ground_color = Color(0.3, 0.28, 0.2)
	pmat.turbidity = 5.0
	pmat.energy_multiplier = 1.5
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 110.0
	sun.directional_shadow_blend_splits = true
	_sky_photoreal = Sky.new()
	_sky_photoreal.sky_material = pmat

	var lmat := ProceduralSkyMaterial.new()
	lmat.sky_top_color = Color(0.3, 0.5, 0.85)
	lmat.sky_horizon_color = Color(0.72, 0.82, 0.92)
	lmat.sky_curve = 0.2
	lmat.ground_bottom_color = Color(0.35, 0.42, 0.28)
	lmat.ground_horizon_color = Color(0.55, 0.62, 0.5)
	lmat.sun_angle_max = 15.0
	_sky_lowpoly = Sky.new()
	_sky_lowpoly.sky_material = lmat

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.02
	var ntex := NoiseTexture3D.new()
	ntex.noise = noise
	ntex.width = 128
	ntex.height = 128
	ntex.depth = 32
	ntex.seamless = true
	_cloud_mat = ShaderMaterial.new()
	_cloud_mat.shader = load("res://shaders/ocean/ocean_clouds.gdshader")
	_cloud_mat.set_shader_parameter("noise_tex", ntex)
	_cloud_mat.set_shader_parameter("cover", 0.3)
	_cloud_mat.set_shader_parameter("cloud_color", Color(0.94, 0.95, 0.99))
	var plane := PlaneMesh.new()
	plane.size = Vector2(10000, 10000)
	plane.subdivide_width = 48
	plane.subdivide_depth = 48
	_cloud_deck = MeshInstance3D.new()
	_cloud_deck.mesh = plane
	_cloud_deck.material_override = _cloud_mat
	_cloud_deck.position = Vector3(0, 460, 0)
	_cloud_deck.extra_cull_margin = 2000.0
	_cloud_deck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cloud_deck)

	var env := world_env.environment
	env.sky = _sky_photoreal
	env.tonemap_exposure = 1.1
	env.fog_enabled = true
	env.fog_density = 0.0035
	env.fog_light_color = Color(0.75, 0.82, 0.9)
	env.fog_sky_affect = 0.03
	env.fog_aerial_perspective = 0.55
	_apply_time_of_day(_time_of_day)


func _apply_time_of_day(t: float) -> void:
	_time_of_day = t
	var elevation := lerpf(12.0, 68.0, t)
	sun.rotation_degrees = Vector3(-elevation, -35.0, 0.0)
	var warmth := clampf(1.0 - t * 1.6, 0.0, 1.0)
	sun.light_color = Color(1.0, 0.93, 0.80).lerp(Color(1.0, 0.74, 0.5), warmth)
	sun.light_energy = lerpf(1.7, 1.25, warmth)


# ── Trees ────────────────────────────────────────────────────────────────────

func _setup_trees() -> void:
	_bark_mat_broadleaf = _make_bark_material("bark_brown_02")
	_bark_mat_conifer = _make_bark_material("pine_bark")
	_leaves_mat = ShaderMaterial.new()
	_leaves_mat.shader = LEAVES_SHADER

	var forest_aabb := AABB(
		Vector3(-TREE_RADIUS - 20.0, -HEIGHT_SCALE, -TREE_RADIUS - 20.0),
		Vector3(TREE_RADIUS * 2.0 + 40.0, HEIGHT_SCALE + 30.0, TREE_RADIUS * 2.0 + 40.0))

	var procedural: Array[Dictionary] = []
	for v in VARIANT_COUNT:
		var params := TreeGen.variant_params(v)
		var bark_mat := _bark_mat_conifer if params.conifer else _bark_mat_broadleaf
		var lod0 := TreeGen.generate(params, 0)
		lod0.surface_set_material(0, bark_mat)
		lod0.surface_set_material(1, _leaves_mat)
		var lod1 := TreeGen.generate(params, 1)
		lod1.surface_set_material(0, bark_mat)
		lod1.surface_set_material(1, _leaves_mat)

		var side := TreeGen.measure(lod0)
		var quad_size := maxf(side.x, side.y)
		var variant := {
			conifer = params.conifer,
			meshes = [lod0, lod0, lod1, _build_impostor_quad(quad_size)],
			quad_size = quad_size,
			fallback_tex = _fallback_impostor_texture(params.leaf_color, params.bark_color),
			scale_range = Vector2(0.8, 1.3),
			collision_radius = 0.28,
			transforms = [] as Array[Transform3D],
			mmis = [],
			buffers = [],
		}
		_add_variant_nodes(variant, forest_aabb)
		procedural.append(variant)
	_tree_sets[1] = procedural

	var scanned: Array[Dictionary] = []
	if Lib.baked_available():
		for variant_name in SCANNED_CONIFERS + SCANNED_BROADLEAF:
			var data := _baked_tree(variant_name)
			if data.is_empty():
				continue
			var conifer := SCANNED_CONIFERS.has(variant_name)
			var height := float(data.height)
			var quad_size := maxf(height, float(data.width)) * 1.02
			var scale_range := Vector2(0.85, 1.15)
			if height > 16.0:
				scale_range = Vector2(0.6, 0.85)  # jacaranda / tallest pines
			elif height < 7.0:
				scale_range = Vector2(1.0, 1.5)  # understory broadleaf
			var variant := {
				conifer = conifer,
				meshes = [data.lods[0], data.lods[1], data.lods[2],
						_build_impostor_quad(quad_size)],
				quad_size = quad_size,
				fallback_tex = _fallback_impostor_texture(
						Color(0.15, 0.3, 0.1), Color(0.3, 0.24, 0.18)),
				scale_range = scale_range,
				collision_radius = clampf(height * 0.022, 0.16, 0.5),
				scan_data = data,
				transforms = [] as Array[Transform3D],
				mmis = [],
				buffers = [],
			}
			_add_variant_nodes(variant, forest_aabb)
			scanned.append(variant)
	if scanned.is_empty():
		_scanned_missing = true
		_tree_sets[0] = procedural
	else:
		_tree_sets[0] = scanned

	_tree_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_tree_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_space(_tree_body, get_world_3d().space)


func _add_variant_nodes(variant: Dictionary, forest_aabb: AABB) -> void:
	var impostor_mat := ShaderMaterial.new()
	impostor_mat.shader = IMPOSTOR_SHADER
	impostor_mat.set_shader_parameter("impostor_tex", variant.fallback_tex)
	(variant.meshes[BUCKET_COUNT - 1] as ArrayMesh).surface_set_material(0, impostor_mat)
	variant.impostor_mat = impostor_mat
	for b in BUCKET_COUNT:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = variant.meshes[b]
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.custom_aabb = forest_aabb
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if b <= 1 \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visible = false
		$TreeContainer.add_child(mmi)
		variant.mmis.append(mmi)
		variant.buffers.append(PackedFloat32Array())


func _exit_tree() -> void:
	# Join any still-running loader threads before teardown.
	for th in _load_threads:
		if th.is_started():
			th.wait_to_finish()
	_load_threads.clear()
	for shape in _tree_shapes:
		PhysicsServer3D.free_rid(shape)
	if _tree_body.is_valid():
		PhysicsServer3D.free_rid(_tree_body)


func _make_bark_material(asset: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = BARK_SHADER
	var diff := _load_forest_tex(asset, "diff")
	var nor := _load_forest_tex(asset, "nor_gl")
	var arm := _load_forest_tex(asset, "arm")
	if diff != null and nor != null and arm != null:
		mat.set_shader_parameter("albedo_tex", diff)
		mat.set_shader_parameter("normal_tex", nor)
		mat.set_shader_parameter("arm_tex", arm)
		mat.set_shader_parameter("use_textures", true)
	return mat


## Jittered-grid scatter gated by the clearing noise (trees avoid clearings,
## flowers fill them); a shifted sample of the same noise zones conifer groves.
## Fixed seed and a fixed number of rng draws per accepted tree keep positions
## identical across the scanned and procedural sets.
func _scatter_trees() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	for variant in _tree_variants:
		variant.transforms.clear()
	_tree_total = 0

	var conifers: Array[int] = []
	var broadleaf: Array[int] = []
	for v in _tree_variants.size():
		if _tree_variants[v].conifer:
			conifers.append(v)
		else:
			broadleaf.append(v)
	if conifers.is_empty():
		conifers = broadleaf
	if broadleaf.is_empty():
		broadleaf = conifers

	var threshold := lerpf(-0.5, 0.38, _tree_density)
	var cell := 5.5
	var steps := int(TREE_RADIUS * 2.0 / cell)
	for gi in steps:
		for gj in steps:
			var x := -TREE_RADIUS + (gi + 0.5) * cell + rng.randf_range(-2.2, 2.2)
			var z := -TREE_RADIUS + (gj + 0.5) * cell + rng.randf_range(-2.2, 2.2)
			if Vector2(x, z).length() > TREE_RADIUS:
				continue
			if Vector2(x - _spawn_point.x, z - _spawn_point.z).length() < 5.0:
				continue
			if _on_path(x, z, 0.012):
				continue
			if _clearing_sample(x, z) > threshold:
				continue
			if _terrain_slope(x, z) > deg_to_rad(30.0):
				continue
			var conifer_zone := _clearing_noise.get_noise_2d(x + 1000.0, z + 1000.0) > 0.0
			var r_variant := rng.randf()
			var r_yaw := rng.randf()
			var r_scale := rng.randf()
			# Mixed forest: broadleaf zones still grow the odd conifer.
			var pool := conifers
			if not conifer_zone and fmod(r_variant * 7.13, 1.0) > 0.25:
				pool = broadleaf
			var variant_idx: int = pool[int(r_variant * pool.size()) % pool.size()]
			var variant: Dictionary = _tree_variants[variant_idx]
			# Big broadleaf (jacaranda) stays rare: reroll most picks to others.
			if not conifer_zone and float(variant.get("quad_size", 0.0)) > 18.0 \
					and r_variant * pool.size() - floorf(r_variant * pool.size()) > 0.3:
				variant_idx = pool[(pool.find(variant_idx) + 1) % pool.size()]
				variant = _tree_variants[variant_idx]
			var scale_range: Vector2 = variant.scale_range
			var basis := Basis(Vector3.UP, r_yaw * TAU)
			basis = basis.scaled(Vector3.ONE * lerpf(scale_range.x, scale_range.y, r_scale))
			var origin := Vector3(x, _terrain_height(x, z) - 0.15, z)
			variant.transforms.append(Transform3D(basis, origin))
			_tree_total += 1

	for variant in _tree_variants:
		var count: int = variant.transforms.size()
		for b in BUCKET_COUNT:
			variant.mmis[b].multimesh.instance_count = count
			variant.buffers[b].resize(count * 12)
	_last_bucket_pos = Vector3.INF
	_rebucket_trees()


## One static PhysicsServer body holds a cylinder per trunk, so the walker
## cannot pass through trees. Built once (tree positions are identical across
## quality modes — same scatter seed — so a mode toggle never rebuilds it).
func _rebuild_tree_collision() -> void:
	for shape in _tree_shapes:
		PhysicsServer3D.free_rid(shape)
	_tree_shapes.clear()
	PhysicsServer3D.body_clear_shapes(_tree_body)
	for variant in _tree_variants:
		var radius: float = variant.collision_radius
		for t: Transform3D in variant.transforms:
			_add_trunk_shape(radius, t)


## Same, but yields every 512 shapes so the initial 3000-trunk build never
## hitches the main thread (called from the streaming loader).
func _build_tree_collision_async() -> void:
	for shape in _tree_shapes:
		PhysicsServer3D.free_rid(shape)
	_tree_shapes.clear()
	PhysicsServer3D.body_clear_shapes(_tree_body)
	var n := 0
	for variant in _tree_variants:
		var radius: float = variant.collision_radius
		for t: Transform3D in variant.transforms:
			_add_trunk_shape(radius, t)
			n += 1
			if n % 512 == 0:
				await get_tree().process_frame


func _add_trunk_shape(radius: float, t: Transform3D) -> void:
	var shape := PhysicsServer3D.cylinder_shape_create()
	var s := t.basis.x.length()
	PhysicsServer3D.shape_set_data(shape, {radius = radius * s, height = 5.0})
	PhysicsServer3D.body_add_shape(_tree_body, shape,
			Transform3D(Basis(), t.origin + Vector3(0, 2.5, 0)))
	_tree_shapes.append(shape)


## Re-partitions every variant's transforms into the distance buckets
## (ULTRA/MID/LOW/impostor). Runs only after the player moves REBUCKET_MOVE m.
func _rebucket_trees() -> void:
	var p := player.global_position
	if p.distance_to(_last_bucket_pos) < REBUCKET_MOVE:
		return
	_last_bucket_pos = p
	_bucket_counts = [0, 0, 0, 0]

	var last := BUCKET_COUNT - 1
	for variant in _tree_variants:
		var transforms: Array[Transform3D] = variant.transforms
		var counts := [0, 0, 0, 0]
		for t in transforms:
			var d := t.origin.distance_to(p)
			var bucket := last
			for band in BUCKET_DISTS.size():
				if d < BUCKET_DISTS[band]:
					bucket = band
					break
			var buf: PackedFloat32Array = variant.buffers[bucket]
			var i: int = counts[bucket] * 12
			if bucket == last:
				# Impostors need world-aligned axes: keep scale, drop rotation.
				var s := t.basis.x.length()
				buf[i] = s; buf[i + 1] = 0.0; buf[i + 2] = 0.0; buf[i + 3] = t.origin.x
				buf[i + 4] = 0.0; buf[i + 5] = s; buf[i + 6] = 0.0; buf[i + 7] = t.origin.y
				buf[i + 8] = 0.0; buf[i + 9] = 0.0; buf[i + 10] = s; buf[i + 11] = t.origin.z
			else:
				var b := t.basis
				buf[i] = b.x.x; buf[i + 1] = b.y.x; buf[i + 2] = b.z.x; buf[i + 3] = t.origin.x
				buf[i + 4] = b.x.y; buf[i + 5] = b.y.y; buf[i + 6] = b.z.y; buf[i + 7] = t.origin.y
				buf[i + 8] = b.x.z; buf[i + 9] = b.y.z; buf[i + 10] = b.z.z; buf[i + 11] = t.origin.z
			counts[bucket] += 1
		for b in BUCKET_COUNT:
			var mm: MultiMesh = variant.mmis[b].multimesh
			if mm.instance_count > 0:
				mm.buffer = variant.buffers[b]
			mm.visible_instance_count = counts[b]
			_bucket_counts[b] += counts[b]


func _build_impostor_quad(size: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := size * 0.5
	st.set_normal(Vector3(0, 0, 1))
	st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(-half, 0, 0))
	st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(half, 0, 0))
	st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(half, size, 0))
	st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-half, size, 0))
	st.add_index(0); st.add_index(2); st.add_index(1)
	st.add_index(0); st.add_index(3); st.add_index(2)
	return st.commit()


## Flat two-tone placeholder shown until the real bake lands (and forever in
## headless runs, where nothing is drawn).
func _fallback_impostor_texture(leaf: Color, bark: Color) -> ImageTexture:
	var img := Image.create(8, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 16:
		for x in 8:
			if y > 11:
				if x >= 3 and x <= 4:
					img.set_pixel(x, y, bark)
			elif absf(x - 3.5) < 3.0:
				img.set_pixel(x, y, leaf.darkened(float(y) / 24.0))
	return ImageTexture.create_from_image(img)


## Renders each variant's LOD0 mesh once into an offscreen viewport and swaps
## the billboard texture. Baked per quality mode (cached) so far billboards
## match the near-tree look. Skipped headless (nothing is ever drawn there).
func _bake_impostors() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if _impostor_cache.has(_mode):
		_assign_impostors(_impostor_cache[_mode])
		return
	if _baking:
		return
	_baking = true
	var baked_mode := _mode
	var textures: Array = []
	for variant in _tree_variants:
		var size: float = variant.quad_size
		var vp := SubViewport.new()
		vp.size = Vector2i(512, 512) if baked_mode == 0 and not _scanned_missing \
				else Vector2i(256, 256)
		vp.transparent_bg = true
		vp.own_world_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		add_child(vp)

		# Ambient floor: canopy normals point everywhere, sun alone reads black.
		var bake_env := Environment.new()
		bake_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		bake_env.ambient_light_color = Color(0.75, 0.8, 0.88)
		bake_env.ambient_light_energy = 0.45
		var bake_we := WorldEnvironment.new()
		bake_we.environment = bake_env
		vp.add_child(bake_we)

		var mi := MeshInstance3D.new()
		mi.mesh = variant.meshes[0]
		vp.add_child(mi)
		var light := DirectionalLight3D.new()
		light.rotation_degrees = Vector3(-40.0, 30.0, 0.0)
		light.light_energy = 1.2
		vp.add_child(light)
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = size * 1.02
		cam.position = Vector3(0, size * 0.5, size * 2.0)
		cam.far = size * 4.0
		vp.add_child(cam)

		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		vp.queue_free()
		if img != null and not img.is_empty():
			img.generate_mipmaps()
			textures.append(ImageTexture.create_from_image(img))
		else:
			push_warning("Forest: impostor bake produced no image; keeping fallback")
			textures.append(variant.fallback_tex)
	_impostor_cache[baked_mode] = textures
	_baking = false
	if _mode == baked_mode:
		_assign_impostors(textures)
	else:
		_bake_impostors()  # mode changed mid-bake


func _assign_impostors(textures: Array) -> void:
	for v in _tree_variants.size():
		_tree_variants[v].impostor_mat.set_shader_parameter("impostor_tex", textures[v])


# ── Quality mode ─────────────────────────────────────────────────────────────

## Swaps photoreal <-> low-poly: scanned tree set + clump grass + scanned
## flowers/understory vs procedural everything, plus shader uniforms, prebuilt
## skies and environment fields. Impostors and needle cards bake lazily.
func _apply_mode(mode: int) -> void:
	_mode = mode
	GameManager.set_setting("forest_quality_mode", mode)
	var lp := mode == 1
	for mat: ShaderMaterial in [
			_terrain_mat, _bark_mat_broadleaf, _bark_mat_conifer, _leaves_mat, _flower_mat]:
		mat.set_shader_parameter("low_poly", lp)

	var target_set: Array[Dictionary] = _tree_sets[1] if lp else _tree_sets[0]
	if not is_same(_tree_variants, target_set):
		for variant in _tree_variants:
			for mmi: MultiMeshInstance3D in variant.mmis:
				mmi.visible = false
		_tree_variants = target_set
		for variant in _tree_variants:
			for mmi: MultiMeshInstance3D in variant.mmis:
				mmi.visible = true
		_scatter_trees()

	# Low-poly: stylized blade grass. Photoreal: scanned clump patches on the
	# textured ground (the blade sim look is exactly what photoreal must avoid).
	var has_clumps := not _patch_defs.is_empty()
	$GrassContainer.visible = lp or not has_clumps
	if _clump_tiles.size() > 0:
		$ClumpContainer.visible = not lp
	if $GrassContainer.visible:
		if lp:
			_grass_mat.set_shader_parameter("base_color", Color(0.10, 0.32, 0.08))
			_grass_mat.set_shader_parameter("tip_color", Color(0.22, 0.45, 0.12))
			_grass_mat.set_shader_parameter("subsurface_scattering_color", Color(0.35, 0.5, 0.2))
		else:
			_grass_mat.set_shader_parameter("base_color", Color(0.06, 0.22, 0.02))
			_grass_mat.set_shader_parameter("tip_color", Color(0.38, 0.5, 0.12))
			_grass_mat.set_shader_parameter("subsurface_scattering_color", Color(0.9, 0.75, 0.15))
		_generate_grass_multimeshes()
	else:
		_generate_clump_multimeshes()
	if _flowers_pr != null:
		_flowers_pr.visible = not lp
	if _flowers_lp != null:
		_flowers_lp.visible = lp or _flowers_pr == null
	if _understory != null:
		_understory.visible = not lp

	var env := world_env.environment
	env.sky = _sky_lowpoly if lp else _sky_photoreal
	_cloud_deck.visible = not lp
	env.ssao_enabled = not lp
	env.ssil_enabled = false  # measured: no visible gain under the canopy
	# SDFGI carries the green bounce of a real forest interior.
	env.sdfgi_enabled = not lp
	env.sdfgi_use_occlusion = true
	env.sdfgi_bounce_feedback = 0.5
	# Volumetric fog is back for god rays through the canopy — sky_affect 0
	# keeps it from greying the sky (the failure mode measured earlier).
	env.volumetric_fog_enabled = not lp
	env.volumetric_fog_density = 0.0035
	env.volumetric_fog_anisotropy = 0.75
	env.volumetric_fog_sky_affect = 0.0
	env.volumetric_fog_albedo = Color(1.0, 0.98, 0.9)
	env.fog_density = 0.0015 if lp else 0.002
	env.fog_light_color = Color(0.78, 0.86, 0.95) if lp else Color(0.75, 0.82, 0.9)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR if lp else Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0 if lp else 1.1
	env.glow_enabled = not lp
	env.glow_intensity = 0.25
	env.glow_bloom = 0.02
	env.glow_hdr_threshold = 1.3
	env.adjustment_enabled = not lp
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.12

	# Photoreal renders through FSR2 at reduced scale: the tri/overdraw budget
	# goes to density instead of raw pixels. Low-poly stays native.
	var viewport := get_viewport()
	if lp:
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		viewport.scaling_3d_scale = 1.0
	else:
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
		viewport.scaling_3d_scale = GameManager.get_setting("forest_render_scale", 0.5)

	if lp:
		sun.light_color = Color.WHITE
		sun.light_energy = 1.5
	else:
		_apply_time_of_day(_time_of_day)
	_run_photoreal_bakes()


## Needle-card textures must land before the impostor bake renders the LOD0
## meshes that use them.
func _run_photoreal_bakes() -> void:
	if _mode == 0 and not _scanned_missing and not _cards_baked:
		_cards_baked = true
		for variant in _tree_sets[0]:
			if variant.has("scan_data"):
				await Lib.bake_card_texture(self, variant.scan_data)
	_bake_impostors()


# ── Flowers ──────────────────────────────────────────────────────────────────

## Static scatter in clearings, chunked into sectors so far chunks distance-cull.
## Two sets share the same positions: stylized quads (low-poly) and scanned
## dandelion/periwinkle meshes (photoreal).
func _setup_flowers() -> void:
	_flower_mat = ShaderMaterial.new()
	_flower_mat.shader = FLOWER_SHADER
	var mesh := _build_flower_mesh()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	_flowers_lp = Node3D.new()
	$FlowerContainer.add_child(_flowers_lp)

	var sectors := {}
	var cell := 1.8
	var steps := int(FLOWER_RADIUS * 2.0 / cell)
	for gi in steps:
		for gj in steps:
			var x := -FLOWER_RADIUS + (gi + 0.5) * cell + rng.randf_range(-0.7, 0.7)
			var z := -FLOWER_RADIUS + (gj + 0.5) * cell + rng.randf_range(-0.7, 0.7)
			if Vector2(x, z).length() > FLOWER_RADIUS:
				continue
			if _clearing_sample(x, z) < 0.42:
				continue
			if _on_path(x, z, 0.01) or _terrain_slope(x, z) > deg_to_rad(20.0):
				continue
			var key := Vector2i(int(floorf(x / FLOWER_SECTOR)), int(floorf(z / FLOWER_SECTOR)))
			if not sectors.has(key):
				sectors[key] = []
			sectors[key].append(Vector3(x, _terrain_height(x, z), z))

	for key: Vector2i in sectors:
		var center := Vector3(
			(key.x + 0.5) * FLOWER_SECTOR, 0.0, (key.y + 0.5) * FLOWER_SECTOR)
		var positions: Array = sectors[key]
		var mm := MultiMesh.new()
		mm.mesh = mesh
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.instance_count = positions.size()
		for idx in positions.size():
			var pos: Vector3 = positions[idx]
			var basis := Basis.from_euler(Vector3(0, rng.randf() * TAU, 0))
			basis = basis.scaled(Vector3.ONE * rng.randf_range(0.7, 1.2))
			mm.set_instance_transform(idx, Transform3D(basis, pos - center))
			var petal := Color.from_hsv(
				rng.randf_range(0.0, 1.0), rng.randf_range(0.45, 0.8), rng.randf_range(0.75, 1.0))
			mm.set_instance_custom_data(idx, petal)
		var instance := _make_sector_mmi(mm, center, 55.0)
		instance.material_override = _flower_mat
		_flowers_lp.add_child(instance)
		_flower_count += positions.size()

	_setup_scanned_flowers(sectors)


## Photoreal flowers: scanned dandelion + periwinkle split over the same
## clearing positions (thinned — real flowers carry more geometry than quads).
func _setup_scanned_flowers(sectors: Dictionary) -> void:
	var dandelion := _plants("dandelion_01", 500, false)
	var periwinkle := _plants("periwinkle_plant", 500, false)
	var species: Array = []
	for plants: Dictionary in [dandelion, periwinkle]:
		if not plants.is_empty():
			species.append(plants.items)
	if species.is_empty():
		return
	_flowers_pr = Node3D.new()
	_flowers_pr.visible = false
	$FlowerContainer.add_child(_flowers_pr)
	var rng := RandomNumberGenerator.new()
	rng.seed = 515
	for key: Vector2i in sectors:
		var center := Vector3(
			(key.x + 0.5) * FLOWER_SECTOR, 0.0, (key.y + 0.5) * FLOWER_SECTOR)
		var positions: Array = sectors[key]
		for sp in species.size():
			var items: Array = species[sp]
			var mm := MultiMesh.new()
			mm.mesh = items[rng.randi_range(0, items.size() - 1)].mesh
			mm.transform_format = MultiMesh.TRANSFORM_3D
			var kept: Array[Transform3D] = []
			for idx in positions.size():
				if idx % species.size() != sp or rng.randf() > 0.75:
					continue
				var basis := Basis(Vector3.UP, rng.randf() * TAU)
				basis = basis.scaled(Vector3.ONE * rng.randf_range(2.2, 3.4))
				kept.append(Transform3D(basis, positions[idx] - center))
			mm.instance_count = kept.size()
			for k in kept.size():
				mm.set_instance_transform(k, kept[k])
			if kept.size() > 0:
				_flowers_pr.add_child(_make_sector_mmi(mm, center, 45.0))


func _make_sector_mmi(mm: MultiMesh, center: Vector3, vis_range: float) -> MultiMeshInstance3D:
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = mm
	instance.position = center
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = vis_range
	instance.visibility_range_end_margin = 8.0
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return instance


## Photoreal understory — the layer that turns "park" into "forest interior":
## fern/nettle/weed carpet, bush walls at clearing edges, pine saplings as
## midstory, stumps/logs/mossy rocks as clutter, roots along the path.
func _setup_understory() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 909
	_understory = Node3D.new()
	_understory.visible = false
	$UnderstoryContainer.add_child(_understory)
	var layers: Array = [
		# ferns are the hero of the carpet — the raw scans are only 0.43 m, scale
		# them to knee/waist height so they read like a real fern understory
		[["fern_02", 900], {cell = 1.5, radius = 75.0, noise_max = 0.12, vis = 70.0,
				scale = Vector2(2.4, 4.2), keep = 0.97, tilt = 0.35}],
		[["nettle_plant", 700], {cell = 2.0, radius = 60.0, noise_max = 0.06, vis = 55.0,
				scale = Vector2(1.6, 3.2), keep = 0.9, tilt = 0.25}],
		[["weed_plant_02", 700], {cell = 2.1, radius = 60.0, noise_max = 0.14, vis = 55.0,
				scale = Vector2(1.4, 2.6), keep = 0.9, tilt = 0.3}],
		[["periwinkle_plant", 700], {cell = 2.2, radius = 58.0, noise_max = 0.1, vis = 52.0,
				scale = Vector2(1.3, 2.4), keep = 0.85, tilt = 0.3}],
		# midstory saplings
		[["pine_sapling_small", 4000], {cell = 6.0, radius = 120.0, noise_max = 0.05,
				vis = 90.0, scale = Vector2(1.1, 2.0), keep = 0.6, boost = 0.85}],
		# clutter
		[["tree_stump_01", 4000], {cell = 20.0, radius = 150.0, noise_max = 0.1,
				vis = 130.0, scale = Vector2(0.9, 1.3), keep = 0.7}],
		[["dead_tree_trunk", 5000], {cell = 24.0, radius = 150.0, noise_max = 0.05,
				vis = 130.0, scale = Vector2(0.9, 1.3), keep = 0.7}],
		[["rock_moss_set_01", 3000], {cell = 18.0, radius = 150.0, noise_max = 0.15,
				vis = 130.0, scale = Vector2(0.9, 1.5), keep = 0.7}],
		[["pine_roots", 5000], {cell = 8.0, radius = 110.0, noise_max = 0.3, vis = 80.0,
				scale = Vector2(0.8, 1.2), keep = 0.85, near_path = true}],
	]
	for layer: Array in layers:
		var plants := _plants(layer[0][0], layer[0][1], false)
		if plants.is_empty():
			continue
		layer[1].tag = layer[0][0]
		if layer[1].has("boost"):
			_boost_albedo(plants.items, float(layer[1].boost))
		_scatter_understory(plants.items, rng, layer[1])
		await get_tree().process_frame

	# Thickets: single Poly Haven shrubs are thin vertical wisps — merging a
	# few per patch builds the eye-level green walls of a real forest edge.
	var thicket_items: Array = []
	for asset in ["shrub_01", "shrub_02", "shrub_03", "shrub_04"]:
		var plants := _plants(asset, 2200, false)
		if plants.is_empty():
			continue
		for p in 2:
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var mat: Material = null
			for c in 4:
				var item: Dictionary = plants.items[rng.randi_range(0, plants.items.size() - 1)]
				var mesh: ArrayMesh = item.mesh
				if mesh.get_surface_count() == 0:
					continue
				mat = mesh.surface_get_material(0)
				var basis := Basis(Vector3.UP, rng.randf() * TAU)
				basis = basis.scaled(Vector3.ONE * rng.randf_range(0.9, 1.5))
				var xf := Transform3D(basis,
						Vector3(rng.randf_range(-0.7, 0.7), 0.0, rng.randf_range(-0.7, 0.7)))
				for s in mesh.get_surface_count():
					st.append_from(mesh, s, xf)
			var thicket := st.commit()
			if thicket.get_surface_count() > 0 and mat != null:
				thicket.surface_set_material(0, mat)
				thicket_items.append({mesh = thicket})
	if not thicket_items.is_empty():
		_scatter_understory(thicket_items, rng, {cell = 2.4, radius = 120.0, noise_max = 0.3,
				vis = 100.0, scale = Vector2(1.0, 1.8), keep = 0.75, edge_boost = true,
				tag = "thicket"})
	await get_tree().process_frame

	# Hero bushes: island_tree_03 is the one genuinely dense scanned bush.
	var bush := _baked_tree("island_tree_03")
	if not bush.is_empty():
		_boost_albedo([{mesh = bush.lods[1]}], 1.3)
		_scatter_understory([{mesh = bush.lods[1]}], rng, {cell = 4.5, radius = 130.0,
				noise_max = 0.3, vis = 120.0, scale = Vector2(0.8, 1.7), keep = 0.7,
				edge_boost = true, sink = 0.22, tag = "hero_bush"})


func _boost_albedo(items: Array, boost: float) -> void:
	for item: Dictionary in items:
		var mesh: ArrayMesh = item.mesh
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s)
			if mat is ShaderMaterial:
				mat.set_shader_parameter("albedo_boost", boost)


func _scatter_understory(items: Array, rng: RandomNumberGenerator, opts: Dictionary) -> void:
	var cell: float = opts.cell
	var radius: float = opts.radius
	var noise_max: float = opts.noise_max
	var keep: float = opts.get("keep", 0.6)
	var edge_boost: bool = opts.get("edge_boost", false)
	var near_path: bool = opts.get("near_path", false)
	var scale_range: Vector2 = opts.scale
	var sectors := {}
	var steps := int(radius * 2.0 / cell)
	for gi in steps:
		for gj in steps:
			var x := -radius + (gi + 0.5) * cell + rng.randf_range(-cell * 0.4, cell * 0.4)
			var z := -radius + (gj + 0.5) * cell + rng.randf_range(-cell * 0.4, cell * 0.4)
			var r_keep := rng.randf()
			if Vector2(x, z).length() > radius:
				continue
			if Vector2(x - _spawn_point.x, z - _spawn_point.z).length() < 3.0:
				continue
			var clearing := _clearing_sample(x, z)
			if clearing > noise_max:
				continue
			if near_path:
				# Roots hug the path verge without blocking it.
				if _path_sample(x, z) > 0.10 or _on_path(x, z, -0.01):
					continue
			elif _on_path(x, z, 0.008):
				continue
			if _terrain_slope(x, z) > deg_to_rad(28.0):
				continue
			var accept := keep
			if edge_boost and clearing > 0.24 and clearing < 0.44:
				accept = minf(keep * 2.4, 0.95)  # walls of green at the treeline
			if r_keep > accept:
				continue
			var key := Vector2i(int(floorf(x / FLOWER_SECTOR)), int(floorf(z / FLOWER_SECTOR)))
			if not sectors.has(key):
				sectors[key] = []
			sectors[key].append(Vector3(x, _terrain_height(x, z) - float(opts.get("sink", 0.03)), z))
	var tilt: float = opts.get("tilt", 0.0)
	for key: Vector2i in sectors:
		var center := Vector3(
			(key.x + 0.5) * FLOWER_SECTOR, 0.0, (key.y + 0.5) * FLOWER_SECTOR)
		var positions: Array = sectors[key]
		# Split the sector's instances across every mesh the species provides,
		# so a patch of ferns is a mix of all 4 fern scans, not one stamped 20x.
		var by_mesh: Array = []
		by_mesh.resize(items.size())
		for m in items.size():
			by_mesh[m] = [] as Array[Transform3D]
		for pos: Vector3 in positions:
			var m := rng.randi_range(0, items.size() - 1)
			var basis := Basis(Vector3.UP, rng.randf() * TAU)
			if tilt > 0.0:
				basis = basis * Basis(Vector3.RIGHT, rng.randf_range(-tilt, tilt)) \
						* Basis(Vector3.BACK, rng.randf_range(-tilt, tilt))
			basis = basis.scaled(Vector3.ONE * rng.randf_range(scale_range.x, scale_range.y))
			by_mesh[m].append(Transform3D(basis, pos - center))
		for m in items.size():
			var xforms: Array = by_mesh[m]
			if xforms.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.mesh = items[m].mesh
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.instance_count = xforms.size()
			for idx in xforms.size():
				mm.set_instance_transform(idx, xforms[idx])
			_understory.add_child(_make_sector_mmi(mm, center, float(opts.vis)))
		_understory_counts[str(opts.get("tag", "layer"))] = \
				int(_understory_counts.get(str(opts.get("tag", "layer")), 0)) + positions.size()


## Two crossed vertical quads, 0.55 m tall, pivot at the ground. UV y=0 on top.
func _build_flower_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := 0.85
	var w := 0.2
	for quad in 2:
		var basis := Basis.from_euler(Vector3(0, PI * 0.5 * quad, 0))
		var right := basis * Vector3(w, 0, 0)
		var normal := basis * Vector3(0, 0, 1)
		var base := 4 * quad
		st.set_normal(normal)
		st.set_uv(Vector2(0, 1)); st.add_vertex(-right)
		st.set_uv(Vector2(1, 1)); st.add_vertex(right)
		st.set_uv(Vector2(1, 0)); st.add_vertex(right + Vector3(0, h, 0))
		st.set_uv(Vector2(0, 0)); st.add_vertex(-right + Vector3(0, h, 0))
		st.add_index(base + 0); st.add_index(base + 2); st.add_index(base + 1)
		st.add_index(base + 0); st.add_index(base + 3); st.add_index(base + 2)
	return st.commit()


# ── UI / profiler ────────────────────────────────────────────────────────────

func _setup_ui() -> void:
	menu.add_label("WASD/ZQSD walk · Shift sprint\nSpace jump · Esc menu")
	if _textures_missing:
		menu.add_label("⚠ Textures missing —\nrun tools/fetch_assets.py")
	if _scanned_missing:
		menu.add_label("⚠ Scanned trees missing —\nrun tools/fetch_assets.py then\ntools/bake_forest_trees.gd")

	menu.add_separator()
	menu.add_section("🎨 Look")
	menu.add_option_button("Mode", ["Photorealistic", "Low-poly"], _mode, _apply_mode)
	menu.add_slider("Time of day", 0.0, 1.0, _time_of_day, func(v: float):
		if _mode == 0:
			_apply_time_of_day(v)
		else:
			_time_of_day = v)
	menu.add_slider("Clouds", 0.0, 0.8, 0.3, func(v: float):
		_cloud_mat.set_shader_parameter("cover", v))

	menu.add_separator()
	menu.add_section("🌲 Vegetation")
	menu.add_slider("Tree density", 0.2, 1.0, _tree_density, func(v: float):
		_tree_density = v
		GameManager.set_setting("forest_tree_density", v)
		_scatter_trees()
		_rebuild_tree_collision())
	menu.add_slider("Grass density", 0.0, 1.0, _grass_density, func(v: float):
		_grass_density = v
		GameManager.set_setting("forest_grass_density", v)
		if $GrassContainer.visible:
			_generate_grass_multimeshes()
		else:
			_generate_clump_multimeshes())
	menu.add_slider("Wind", 0.0, 3.0, 1.0, _on_wind_changed)
	menu.add_toggle("Flowers", true, func(on: bool):
		$FlowerContainer.visible = on)

	menu.add_separator()
	menu.add_section("⚙️ Performance")
	menu.add_slider("Render scale", 0.5, 1.0,
			GameManager.get_setting("forest_render_scale", 0.5), func(v: float):
		GameManager.set_setting("forest_render_scale", v)
		if _mode == 0:
			get_viewport().scaling_3d_scale = v)
	menu.add_toggle("Sun shadows", true, func(on: bool):
		sun.shadow_enabled = on)
	menu.add_toggle("Vegetation shadows", true, _on_vegetation_shadows)
	menu.add_toggle("SDFGI", true, func(on: bool):
		world_env.environment.sdfgi_enabled = on)
	menu.add_toggle("Profiler overlay", false, _on_profiler_toggled)


func _on_wind_changed(v: float) -> void:
	_grass_mat.set_shader_parameter("wind_speed", v)
	for mat: ShaderMaterial in [_bark_mat_broadleaf, _bark_mat_conifer, _leaves_mat, _flower_mat]:
		mat.set_shader_parameter("wind_strength", v)
	Lib.set_wind(v)


func _on_vegetation_shadows(on: bool) -> void:
	for data in _grass_tiles:
		var near: bool = data[1].length() < GRASS_SHADOW_DISTANCE
		data[0].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on and near \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for variant in _tree_variants:
		variant.mmis[0].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _setup_profiler() -> void:
	_profiler_label = Label.new()
	_profiler_label.position = Vector2(8, 8)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["monospace"])
	_profiler_label.add_theme_font_override("font", mono)
	_profiler_label.add_theme_font_size_override("font_size", 13)
	_profiler_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_profiler_label.add_theme_constant_override("outline_size", 4)
	_profiler_label.visible = false
	menu.get_parent().add_child(_profiler_label)


func _on_profiler_toggled(on: bool) -> void:
	_profiler_label.visible = on
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), on)


func _update_overlay() -> void:
	var lines := PackedStringArray()
	lines.append("FPS %d  frame %.2f ms" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
	])
	lines.append("viewport GPU %.2f ms" % RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()))
	lines.append("trees %d  (U %d · M %d · L %d · imp %d)" % [
		_tree_total, _bucket_counts[0], _bucket_counts[1],
		_bucket_counts[2], _bucket_counts[3]])
	lines.append("grass %d  flowers %d" % [_grass_instances, _flower_count])
	lines.append("draw calls %d" % Performance.get_monitor(
		Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_profiler_label.text = "\n".join(lines)
