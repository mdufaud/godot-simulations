extends RefCounted
## Loader for Poly Haven photoscanned vegetation. Trees come from the LOD
## meshes pre-baked by tools/bake_forest_trees.gd; small plants are decimated
## straight from their glTF at load time. Textures load from disk, bypassing
## the import system, so missing downloads degrade instead of breaking.

const VEG_SHADER := preload("res://shaders/forest/scanned_veg.gdshader")
const CARD_SHADER := preload("res://shaders/forest/needle_card.gdshader")
const FOREST_DIR := "res://resources/forest"
const BAKED_DIR := "res://resources/forest/baked"

static var materials: Array[ShaderMaterial] = []
static var card_materials := {}
static var _tex_cache := {}
static var _mat_cache := {}
# Guards the shared caches above so load_plants / load_baked_tree can run on
# WorkerThreadPool threads in parallel. The expensive work (glTF parse,
# generate_lods, image decode, mesh build) stays OUTSIDE the lock; only the
# cache lookups/inserts and the materials array are serialized.
static var _mutex := Mutex.new()


static func reset() -> void:
	_mutex.lock()
	materials.clear()
	card_materials.clear()
	_tex_cache.clear()
	_mat_cache.clear()
	_mutex.unlock()


static func baked_available() -> bool:
	return FileAccess.file_exists(
		ProjectSettings.globalize_path(BAKED_DIR + "/jacaranda_tree.json"))


static func set_wind(strength: float) -> void:
	for mat in materials:
		mat.set_shader_parameter("wind_strength", strength)


static func load_texture(abs_path: String, max_dim: int = 2048) -> Texture2D:
	var key := "%s@%d" % [abs_path, max_dim]
	_mutex.lock()
	var cached: bool = _tex_cache.has(key)
	var cached_tex: Texture2D = _tex_cache.get(key)
	_mutex.unlock()
	if cached:
		return cached_tex
	var tex: ImageTexture = null
	if FileAccess.file_exists(abs_path):
		var img := Image.load_from_file(abs_path)
		if img != null:
			if maxi(img.get_width(), img.get_height()) > max_dim:
				var scale := float(max_dim) / float(maxi(img.get_width(), img.get_height()))
				img.resize(int(img.get_width() * scale), int(img.get_height() * scale),
						Image.INTERPOLATE_BILINEAR)
			img.generate_mipmaps()
			tex = ImageTexture.create_from_image(img)
	_mutex.lock()
	_tex_cache[key] = tex
	_mutex.unlock()
	return tex


static func make_material(asset: String, uris: Dictionary, foliage: bool, height_ref: float,
		follow_terrain: bool) -> ShaderMaterial:
	var key := "%s|%s|%s|%.1f|%s" % [asset, uris.get("diff", ""), foliage, height_ref, follow_terrain]
	_mutex.lock()
	var cached: bool = _mat_cache.has(key)
	var cached_mat: ShaderMaterial = _mat_cache.get(key)
	_mutex.unlock()
	if cached:
		return cached_mat
	var dir := ProjectSettings.globalize_path("%s/%s" % [FOREST_DIR, asset])
	var mat := ShaderMaterial.new()
	mat.shader = VEG_SHADER
	mat.set_shader_parameter("albedo_tex",
			load_texture("%s/%s" % [dir, uris.get("diff", "")], 2048))
	mat.set_shader_parameter("normal_tex",
			load_texture("%s/%s" % [dir, uris.get("nor", "")], 1024))
	mat.set_shader_parameter("arm_tex",
			load_texture("%s/%s" % [dir, uris.get("arm", "")], 1024))
	mat.set_shader_parameter("sway_amount", 1.0 if foliage else 0.12)
	mat.set_shader_parameter("height_ref", height_ref)
	mat.set_shader_parameter("follow_terrain", follow_terrain)
	if foliage:
		mat.set_shader_parameter("backlight_color", Color(0.4, 0.45, 0.18))
	_mutex.lock()
	# Another thread may have built the same material meanwhile; keep one.
	if _mat_cache.has(key):
		mat = _mat_cache[key]
	else:
		materials.append(mat)
		_mat_cache[key] = mat
	_mutex.unlock()
	return mat


## Baked tree variant: {lods: [ultra, mid, low], height, width} or {} when
## not baked.
static func load_baked_tree(variant: String, mobile: bool = OS.has_feature("mobile")) -> Dictionary:
	var json_abs := ProjectSettings.globalize_path("%s/%s.json" % [BAKED_DIR, variant])
	if not FileAccess.file_exists(json_abs):
		return {}
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(json_abs))
	var suffixes: Array[String] = ["lod0", "lodm", "lod1"]
	if mobile:
		suffixes = ["lodm", "lod1"]
	var lods: Array = []
	for suffix in suffixes:
		var path := "%s/%s_%s.res" % [BAKED_DIR, variant, suffix]
		if not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
			# Old two-level bakes: reuse lod0 for the mid slot.
			if suffix == "lodm" and lods.size() == 1:
				lods.append(lods[0])
				continue
			return {}
		lods.append(load(path))
	if mobile:
		lods = [lods[0], lods[0], lods[1]]
	var height := float(meta.height)
	var surfaces: Array = meta.surfaces
	for s in surfaces.size():
		var mat := make_material(String(meta.asset), surfaces[s], bool(surfaces[s].foliage),
				height, false)
		for mesh: ArrayMesh in lods:
			if s < mesh.get_surface_count():
				mesh.surface_set_material(s, mat)
	var data := {lods = lods, height = height, width = float(meta.width)}
	if meta.has("cards") and not mobile:
		_mutex.lock()
		var mats: Array = card_materials.get(variant, [])
		if mats.is_empty():
			for m in 2:
				var card_mat := ShaderMaterial.new()
				card_mat.shader = CARD_SHADER
				card_mat.set_shader_parameter("height_ref", height)
				card_mat.set_shader_parameter("card_tex", _fallback_card_texture())
				materials.append(card_mat)
				mats.append(card_mat)
			card_materials[variant] = mats
		_mutex.unlock()
		var cards: Array = meta.cards
		if not is_same(lods[1], lods[0]):
			_append_cards(lods[1], _sparse_cards(cards, 2), 1.45, mats)
		_append_cards(lods[0], cards, 1.0, mats)
		_append_cards(lods[2], _sparse_cards(cards, 3), 1.7, mats)
		data.twig = meta.twig
		data.twig_asset = meta.asset
		data.sample_paths = [
			"%s/%s_twigs.res" % [BAKED_DIR, variant],
			"%s/%s_twigs2.res" % [BAKED_DIR, variant],
		]
		data.sample_size = float(meta.get("sample_size", 2.8))
		data.variant = variant
		data.has_cards = true
	return data


## Renders the baked needle-branch samples into transparent viewports and
## swaps them onto the variant's card materials. No-op headless.
static func bake_card_texture(host: Node, data: Dictionary) -> void:
	if DisplayServer.get_name() == "headless" or not data.get("has_cards", false):
		return
	var mats: Array = card_materials.get(String(data.variant), [])
	var paths: Array = data.sample_paths
	for k in mats.size():
		var sample: ArrayMesh = load(paths[mini(k, paths.size() - 1)])
		if sample == null:
			continue
		var tex := await _render_sample(host, sample, float(data.sample_size),
				String(data.get("twig_asset", "")), data.twig, String(data.variant))
		if tex != null:
			(mats[k] as ShaderMaterial).set_shader_parameter("card_tex", tex)


static func _render_sample(host: Node, sample: ArrayMesh, size: float, twig_asset: String,
		twig_uris: Dictionary, variant: String) -> ImageTexture:
	var twig_mat := make_material(twig_asset, twig_uris, true, 100.0, false)
	var vp := SubViewport.new()
	vp.size = Vector2i(1024, 1024)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	host.add_child(vp)
	# Needle normals point everywhere: without ambient, half the sample reads
	# near-black. Flat ambient keeps the card texture in albedo range.
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.9, 0.95)
	env.ambient_light_energy = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var mi := MeshInstance3D.new()
	mi.mesh = sample
	mi.material_override = twig_mat
	vp.add_child(mi)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35.0, 25.0, 0.0)
	key.light_energy = 1.25
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20.0, 200.0, 0.0)
	fill.light_energy = 0.5
	vp.add_child(fill)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = size * 1.02
	cam.position = Vector3(0, 0, size * 2.0)
	cam.far = size * 4.0
	vp.add_child(cam)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	if img == null or img.is_empty():
		return null
	# Dark twig atlases (pine reads near-black at forest light levels):
	# normalize the opaque-pixel luminance toward a mid tone.
	var lum := 0.0
	var count := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				lum += c.get_luminance()
				count += 1
	if count > 50:
		var scale := clampf(0.30 / maxf(lum / count, 0.02), 1.0, 2.2)
		print("Forest: card texture %s lum %.3f boost %.2f" % [variant, lum / count, scale])
		if scale > 1.05:
			img.adjust_bcs(scale, 1.0, 1.0)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Crossed quads (2 vertical X + 1 tilted horizontal) per card, appended as
## extra surfaces. Cards alternate between the two card materials (two baked
## branch textures) to break repetition. Normals blend outward+up.
static func _append_cards(mesh: ArrayMesh, cards: Array, scale: float, mats: Array) -> void:
	for m in mats.size():
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var rng := RandomNumberGenerator.new()
		rng.seed = cards.size() * 7919 + m
		var vi := 0
		var used := false
		for c in range(m, cards.size(), mats.size()):
			used = true
			var card: Array = cards[c]
			var p := Vector3(float(card[0]), float(card[1]), float(card[2]))
			var s := float(card[3]) * scale
			var out := Vector3(p.x, 0.0, p.z)
			out = out.normalized() if out.length() > 0.4 else \
					Vector3(rng.randf() - 0.5, 0.0, rng.randf() - 0.5).normalized()
			var normal := (out + Vector3.UP * 0.8).normalized()
			var yaw := atan2(out.x, out.z) + rng.randf_range(-0.4, 0.4)
			for q in 3:
				var basis: Basis
				if q < 2:
					basis = Basis(Vector3.UP, yaw + PI * 0.5 * q)
					basis = basis * Basis(Vector3.RIGHT, rng.randf_range(-0.25, 0.25))
				else:
					basis = Basis(Vector3.UP, yaw + rng.randf_range(0.0, PI)) \
							* Basis(Vector3.RIGHT, PI * 0.5 + rng.randf_range(-0.3, 0.3))
				var right := basis * Vector3(s * 0.5, 0, 0)
				var up := basis * Vector3(0, s * 0.5, 0)
				st.set_normal(normal)
				st.set_uv(Vector2(0, 1)); st.add_vertex(p - right - up)
				st.set_uv(Vector2(1, 1)); st.add_vertex(p + right - up)
				st.set_uv(Vector2(1, 0)); st.add_vertex(p + right + up)
				st.set_uv(Vector2(0, 0)); st.add_vertex(p - right + up)
				st.add_index(vi); st.add_index(vi + 2); st.add_index(vi + 1)
				st.add_index(vi); st.add_index(vi + 3); st.add_index(vi + 2)
				vi += 4
		if used:
			st.commit(mesh)
			mesh.surface_set_material(mesh.get_surface_count() - 1, mats[m])


static func _sparse_cards(cards: Array, step: int) -> Array:
	var out := []
	for k in range(0, cards.size(), step):
		out.append(cards[k])
	return out


## Blotchy green RGBA blob: card look until the real bake lands, and forever
## in headless runs.
static func _fallback_card_texture() -> ImageTexture:
	if _tex_cache.has("__fallback_card"):
		return _tex_cache["__fallback_card"]
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.18
	noise.seed = 99
	for y in n:
		for x in n:
			var r := Vector2(x - n * 0.5, y - n * 0.5).length() / (n * 0.5)
			var a := clampf((1.0 - r) * 1.2 + noise.get_noise_2d(x, y) * 0.9 - 0.35, 0.0, 1.0)
			var g := 0.28 + noise.get_noise_2d(x + 100, y) * 0.1
			img.set_pixel(x, y, Color(0.07, g, 0.05, 1.0 if a > 0.45 else 0.0))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache["__fallback_card"] = tex
	return tex


## Small plants from glTF, decimated to ~target_tris per mesh and rebased so
## each clump sits base-at-origin. Returns {items: [{mesh, size}], height}.
static func load_plants(asset: String, target_tris: int, follow_terrain: bool) -> Dictionary:
	var gltf_abs := ProjectSettings.globalize_path(
			"%s/%s/%s_2k.gltf" % [FOREST_DIR, asset, asset])
	if not FileAccess.file_exists(gltf_abs):
		return {}
	var mat_table := material_table(gltf_abs)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(gltf_abs, state) != OK:
		return {}
	var items: Array = []
	var max_height := 0.0
	for gltf_mesh in state.meshes:
		var im: ImporterMesh = gltf_mesh.mesh
		var base_arrays: Array = []
		var total := 0
		for s in im.get_surface_count():
			var arr := im.get_surface_arrays(s)
			base_arrays.append(arr)
			total += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		if total > target_tris:
			im.generate_lods(60.0, 25.0, [])
		var aabb_min := Vector3.INF
		var aabb_max := -Vector3.INF
		for arr: Array in base_arrays:
			for p: Vector3 in arr[Mesh.ARRAY_VERTEX]:
				aabb_min = aabb_min.min(p)
				aabb_max = aabb_max.max(p)
		var offset := Vector3(
				(aabb_min.x + aabb_max.x) * 0.5, aabb_min.y, (aabb_min.z + aabb_max.z) * 0.5)
		var height := aabb_max.y - aabb_min.y
		max_height = maxf(max_height, height)
		var mesh := ArrayMesh.new()
		for s in im.get_surface_count():
			var share := int(float(target_tris) * float(
					(base_arrays[s][Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3)
					/ float(total))
			var indices := pick_indices(im, s, base_arrays[s], maxi(share, 200))
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
					compact_surface(base_arrays[s], indices, offset))
			var mat := im.get_surface_material(s)
			var mat_name := mat.resource_name if mat != null else im.get_surface_name(s)
			mesh.surface_set_material(s, make_material(
					asset, mat_table.get(mat_name, {}), true, height, follow_terrain))
		items.append({
			mesh = mesh,
			size = maxf(maxf(aabb_max.x - aabb_min.x, aabb_max.z - aabb_min.z), height),
		})
	return {items = items, height = max_height}


## Per-material texture URIs and alpha mode, straight from the glTF JSON.
static func material_table(gltf_abs_path: String) -> Dictionary:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(gltf_abs_path))
	var images: Array = data.get("images", [])
	var textures: Array = data.get("textures", [])
	var table := {}
	for mat: Dictionary in data.get("materials", []):
		var pbr: Dictionary = mat.get("pbrMetallicRoughness", {})
		table[mat.name] = {
			diff = _tex_uri(pbr.get("baseColorTexture"), textures, images),
			nor = _tex_uri(mat.get("normalTexture"), textures, images),
			arm = _tex_uri(pbr.get("metallicRoughnessTexture"), textures, images),
			alpha_mode = mat.get("alphaMode", "OPAQUE"),
		}
	return table


static func _tex_uri(ref: Variant, textures: Array, images: Array) -> String:
	if ref == null:
		return ""
	var tex_index := int((ref as Dictionary).get("index", -1))
	if tex_index < 0:
		return ""
	var source := int((textures[tex_index] as Dictionary).get("source", -1))
	return "" if source < 0 else String((images[source] as Dictionary).get("uri", ""))


## Smallest LOD level at/above the target if it stays within tolerance, else
## the largest level below the target (meshopt chains on leaf soup are
## sparse); base indices if the surface is already small enough.
static func pick_indices(im: ImporterMesh, s: int, arrays: Array, target_tris: int,
		tolerance: float = 2.0) -> PackedInt32Array:
	var base: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if base.size() / 3 <= target_tris:
		return base
	var above := PackedInt32Array()
	var below := PackedInt32Array()
	for l in im.get_surface_lod_count(s):
		var idx := im.get_surface_lod_indices(s, l)
		var tris := idx.size() / 3
		if tris >= target_tris:
			if above.is_empty() or idx.size() < above.size():
				above = idx
		elif idx.size() > below.size():
			below = idx
	if not above.is_empty() and above.size() / 3 <= int(target_tris * tolerance):
		return above
	if not below.is_empty():
		return below
	return above if not above.is_empty() else base


## Rebuilds a compact vertex buffer holding only the vertices the chosen LOD
## index set references (LOD indices point into the full film-res buffer).
static func compact_surface(arrays: Array, indices: PackedInt32Array, offset: Vector3) -> Array:
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var has_nor: bool = arrays[Mesh.ARRAY_NORMAL] != null
	var has_tan: bool = arrays[Mesh.ARRAY_TANGENT] != null
	var has_uv: bool = arrays[Mesh.ARRAY_TEX_UV] != null
	var remap := PackedInt32Array()
	remap.resize(pos.size())
	remap.fill(-1)
	var new_indices := PackedInt32Array()
	new_indices.resize(indices.size())
	var order := PackedInt32Array()
	var next := 0
	for k in indices.size():
		var old := indices[k]
		if remap[old] == -1:
			remap[old] = next
			order.append(old)
			next += 1
		new_indices[k] = remap[old]

	var out := []
	out.resize(Mesh.ARRAY_MAX)
	var new_pos := PackedVector3Array()
	new_pos.resize(next)
	for n in next:
		new_pos[n] = pos[order[n]] - offset
	out[Mesh.ARRAY_VERTEX] = new_pos
	if has_nor:
		var nor: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var new_nor := PackedVector3Array()
		new_nor.resize(next)
		for n in next:
			new_nor[n] = nor[order[n]]
		out[Mesh.ARRAY_NORMAL] = new_nor
	if has_tan:
		var tan: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		var new_tan := PackedFloat32Array()
		new_tan.resize(next * 4)
		for n in next:
			for c in 4:
				new_tan[n * 4 + c] = tan[order[n] * 4 + c]
		out[Mesh.ARRAY_TANGENT] = new_tan
	if has_uv:
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var new_uv := PackedVector2Array()
		new_uv.resize(next)
		for n in next:
			new_uv[n] = uv[order[n]]
		out[Mesh.ARRAY_TEX_UV] = new_uv
	out[Mesh.ARRAY_INDEX] = new_indices
	return out
