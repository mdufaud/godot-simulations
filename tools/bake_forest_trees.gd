extends SceneTree
## Bakes Poly Haven film-quality tree scans (millions of tris) into game-ready
## LOD meshes using the engine's meshoptimizer LOD chain. Run once after
## tools/fetch_assets.py:
##   godot --headless --path . -s tools/bake_forest_trees.gd
## Optionally pass asset names after "--" to bake a subset.
## Outputs resources/forest/baked/<variant>_lod{0,1}.res + <variant>.json

const Lib := preload("res://scripts/demos/forest_scanned_lib.gd")
const FOREST_DIR := "res://resources/forest"
const OUT_DIR := "res://resources/forest/baked"
const SOURCES := ["island_tree_01", "island_tree_03", "tree_small_02", "jacaranda_tree",
		"fir_tree_01", "pine_tree_01"]
# Three mesh levels per variant: ULTRA (near, FSR2 pays for it), MID, LOW.
# Needle canopies ride on cards, so conifer budgets only feed the trunks.
const BROADLEAF_BUDGETS := [350000, 55000, 8000]
const CONIFER_BUDGETS := [90000, 45000, 8000]
# island_tree_03 is scattered as a dense hero bush, not a canopy tree.
const ASSET_BUDGETS := {"island_tree_03": [30000, 12000, 2500]}
const LOD_SUFFIX := ["lod0", "lodm", "lod1"]
# MID/LOW must actually shrink: a stuck chain level 2x over target feeds
# millions of tris to the mid ring.
const LOD_TOLERANCE := [2.0, 2.0, 1.45]


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var sources := OS.get_cmdline_user_args()
	if sources.is_empty():
		sources = SOURCES
	for asset in sources:
		_bake_asset(asset)
	print("BAKE: done")
	quit()


func _bake_asset(asset: String) -> void:
	var gltf_path := "%s/%s/%s_2k.gltf" % [FOREST_DIR, asset, asset]
	var abs_path := ProjectSettings.globalize_path(gltf_path)
	if not FileAccess.file_exists(abs_path):
		print("BAKE: skip %s (not downloaded)" % asset)
		return
	var t0 := Time.get_ticks_msec()
	var mat_table := Lib.material_table(abs_path)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(abs_path, state)
	if err != OK:
		print("BAKE: FAILED to load %s (err %d)" % [asset, err])
		return
	print("BAKE: %s loaded in %.1f s" % [asset, (Time.get_ticks_msec() - t0) / 1000.0])
	var gltf_meshes := state.meshes
	for m in gltf_meshes.size():
		var im: ImporterMesh = gltf_meshes[m].mesh
		var variant := asset if gltf_meshes.size() == 1 else "%s_%s" % [asset, char(97 + m)]
		_bake_tree(variant, asset, im, mat_table)
	print("BAKE: %s finished in %.1f s" % [asset, (Time.get_ticks_msec() - t0) / 1000.0])


func _bake_tree(variant: String, asset: String, im: ImporterMesh, mat_table: Dictionary) -> void:
	var nsurf := im.get_surface_count()
	var base_arrays: Array = []
	var mat_names: Array[String] = []
	var total_tris := 0
	var card_surface := -1
	for s in nsurf:
		var arr := im.get_surface_arrays(s)
		base_arrays.append(arr)
		total_tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var mat := im.get_surface_material(s)
		var mat_name := mat.resource_name if mat != null else im.get_surface_name(s)
		mat_names.append(mat_name)
		# Needle canopies are millions of disconnected quads: meshopt decimation
		# leaves skeletons, so they become clustered branch cards instead.
		if mat_name.contains("twig"):
			card_surface = s
	var t0 := Time.get_ticks_msec()
	im.generate_lods(60.0, 25.0, [])
	print("  %s: %d tris, %d surfaces, LOD chain in %.1f s" % [
		variant, total_tris, nsurf, (Time.get_ticks_msec() - t0) / 1000.0])

	var offset := _base_offset(base_arrays)
	var aabb_min := Vector3.INF
	var aabb_max := -Vector3.INF
	for arr: Array in base_arrays:
		var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for k in range(0, pos.size(), 64):
			aabb_min = aabb_min.min(pos[k] - offset)
			aabb_max = aabb_max.max(pos[k] - offset)
	var meta := {
		asset = asset,
		surfaces = [],
		height = aabb_max.y - minf(aabb_min.y, 0.0),
		width = maxf(aabb_max.x - aabb_min.x, aabb_max.z - aabb_min.z),
	}

	var mesh_tris := total_tris
	if card_surface >= 0:
		mesh_tris -= (base_arrays[card_surface][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	var budgets: Array = ASSET_BUDGETS.get(asset,
			CONIFER_BUDGETS if card_surface >= 0 else BROADLEAF_BUDGETS)
	for budget_idx in budgets.size():
		var budget: int = budgets[budget_idx]
		var mesh := ArrayMesh.new()
		var baked_tris := 0
		for s in nsurf:
			if s == card_surface:
				continue
			var share := int(float(budget) * float(
				(base_arrays[s][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3) / float(mesh_tris))
			var indices := Lib.pick_indices(im, s, base_arrays[s], maxi(share, 300),
					LOD_TOLERANCE[budget_idx])
			var compacted := Lib.compact_surface(base_arrays[s], indices, offset)
			baked_tris += indices.size() / 3
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, compacted)
			mesh.surface_set_name(mesh.get_surface_count() - 1, mat_names[s])
			if budget_idx == 0:
				var uris: Dictionary = mat_table.get(mat_names[s], {})
				meta.surfaces.append({
					name = mat_names[s],
					diff = uris.get("diff", ""),
					nor = uris.get("nor", ""),
					arm = uris.get("arm", ""),
					foliage = uris.get("alpha_mode", "OPAQUE") != "OPAQUE"
							or mat_names[s].contains("twig") or mat_names[s].contains("leaves"),
				})
		ResourceSaver.save(mesh, "%s/%s_%s.res" % [OUT_DIR, variant, LOD_SUFFIX[budget_idx]],
				ResourceSaver.FLAG_COMPRESS)
		print("    %s: %d tris" % [LOD_SUFFIX[budget_idx], baked_tris])

	if card_surface >= 0:
		var twig_uris: Dictionary = mat_table.get(mat_names[card_surface], {})
		meta.twig = {
			diff = twig_uris.get("diff", ""),
			nor = twig_uris.get("nor", ""),
			arm = twig_uris.get("arm", ""),
		}
		meta.cards = _cluster_cards(base_arrays[card_surface], offset)
		meta.sample_size = _save_twig_samples(variant, base_arrays[card_surface], offset,
				float(meta.height), meta.cards)
		print("    cards: %d, twig samples saved" % (meta.cards as Array).size())

	var f := FileAccess.open(
		ProjectSettings.globalize_path("%s/%s.json" % [OUT_DIR, variant]), FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, "  "))
	f.close()


const CARD_VOXEL := 1.0
const CARD_MAX := 550

## Clusters needle-triangle centroids into a voxel grid; each dense voxel
## becomes one branch card [x, y, z, size]. Reproduces the scanned silhouette.
func _cluster_cards(arrays: Array, offset: Vector3) -> Array:
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var tri_count := indices.size() / 3
	var step := maxi(1, tri_count / 60000)
	var counts := {}
	var sums := {}
	var samples := 0
	for t in range(0, tri_count, step):
		var c := (pos[indices[t * 3]] + pos[indices[t * 3 + 1]]
				+ pos[indices[t * 3 + 2]]) / 3.0 - offset
		var key := Vector3i((c / CARD_VOXEL).floor())
		counts[key] = counts.get(key, 0) + 1
		sums[key] = sums.get(key, Vector3.ZERO) + c
		samples += 1
	var keys := counts.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return counts[a] > counts[b])
	var threshold := maxi(4, samples / (keys.size() * 4))
	var mean_count := float(samples) / float(keys.size())
	var cards := []
	for key: Vector3i in keys:
		if cards.size() >= CARD_MAX or counts[key] < threshold:
			break
		var center: Vector3 = sums[key] / counts[key]
		var size := CARD_VOXEL * clampf(0.9 + 0.35 * float(counts[key]) / mean_count, 1.0, 1.9)
		cards.append([snappedf(center.x, 0.01), snappedf(center.y, 0.01),
				snappedf(center.z, 0.01), snappedf(size, 0.01)])
	return cards


## Extracts two dense needle clusters (low and high in the canopy) as small
## meshes; the demo renders each once into a transparent viewport and the two
## card textures alternate across cards to break repetition.
func _save_twig_samples(variant: String, arrays: Array, offset: Vector3, height: float,
		cards: Array) -> float:
	var half := 1.4
	var picks: Array[Vector3] = []
	for band: Vector2 in [Vector2(0.3, 0.55), Vector2(0.55, 0.8)]:
		for card: Array in cards:
			if card[1] > height * band.x and card[1] < height * band.y:
				var c := Vector3(card[0], card[1], card[2])
				if picks.is_empty() or picks[0].distance_to(c) > half:
					picks.append(c)
					break
	if picks.is_empty():
		picks.append(Vector3(cards[0][0], cards[0][1], cards[0][2]))
	if picks.size() == 1:
		picks.append(picks[0])

	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var tri_count := indices.size() / 3
	for pick_idx in picks.size():
		var best := picks[pick_idx]
		var flags := PackedByteArray()
		flags.resize(pos.size())
		var lo := best - Vector3.ONE * half + offset
		var hi := best + Vector3.ONE * half + offset
		for v in pos.size():
			var p := pos[v]
			flags[v] = 1 if (p.x > lo.x and p.x < hi.x and p.y > lo.y and p.y < hi.y
					and p.z > lo.z and p.z < hi.z) else 0
		var kept := PackedInt32Array()
		for t in tri_count:
			var i0 := indices[t * 3]
			if flags[i0] == 0:
				continue
			var i1 := indices[t * 3 + 1]
			var i2 := indices[t * 3 + 2]
			if flags[i1] == 1 and flags[i2] == 1:
				kept.append(i0)
				kept.append(i1)
				kept.append(i2)
		if kept.size() / 3 > 150000:
			var thinned := PackedInt32Array()
			var keep_step := kept.size() / 3 / 150000 + 1
			for t in range(0, kept.size() / 3, keep_step):
				thinned.append(kept[t * 3])
				thinned.append(kept[t * 3 + 1])
				thinned.append(kept[t * 3 + 2])
			kept = thinned
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
				Lib.compact_surface(arrays, kept, best + offset))
		var suffix := "twigs" if pick_idx == 0 else "twigs2"
		ResourceSaver.save(mesh, "%s/%s_%s.res" % [OUT_DIR, variant, suffix],
				ResourceSaver.FLAG_COMPRESS)
	return half * 2.0


## Trunk-bottom offset: XZ centroid of the lowest 60 cm of vertices, so each
## baked variant sits base-at-origin (pine/fir files pack 3 trees side by side).
func _base_offset(base_arrays: Array) -> Vector3:
	var min_y := INF
	for arr: Array in base_arrays:
		for p: Vector3 in arr[Mesh.ARRAY_VERTEX]:
			min_y = minf(min_y, p.y)
	var centroid := Vector3.ZERO
	var count := 0
	for arr: Array in base_arrays:
		for p: Vector3 in arr[Mesh.ARRAY_VERTEX]:
			if p.y < min_y + 0.6:
				centroid += p
				count += 1
	centroid /= maxf(count, 1)
	return Vector3(centroid.x, min_y, centroid.z)


