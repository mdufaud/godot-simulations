class_name ForestTreeGenerator
extends RefCounted
## Procedural tree meshes: recursive branch turtle (tapered cylinder rings) with
## leaf-card clusters. Broadleaf trees branch recursively; conifers grow whorls
## of near-horizontal branches along a straight trunk (conical silhouette).
## Surface 0 = bark, surface 1 = leaves. Vertex COLOR carries the low-poly
## palette. Leaf UV2 stores the quad center for rigid per-quad wind phase.
## The same seed yields the same skeleton at every LOD.

const MIN_RADIUS := 0.02


## LOD 0 = full detail, LOD 1 = reduced (fewer sides/segments/levels, merged
## leaf clusters). Impostors are baked from LOD 0 by the controller.
static func generate(params: Dictionary, lod: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = params.seed
	var sides: int = 7 if lod == 0 else 5
	var segments: int = 3 if lod == 0 else 2
	var levels: int = params.get("levels", 0)
	var level_cap: int = levels if lod == 0 else levels - 1
	var leaf_factor: float = 1.0 if lod == 0 else 0.34
	var leaf_size_factor: float = 1.0 if lod == 0 else 1.8

	var bark := SurfaceTool.new()
	bark.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leaf_clusters: Array = []  # [position: Vector3, size_scale: float]

	var ctx := {
		rng = rng, params = params, bark = bark, sides = sides,
		segments = segments, level_cap = level_cap, leaves = leaf_clusters,
		vert_count = 0,
	}
	if params.conifer:
		_grow_conifer(ctx)
	else:
		_grow_branch(ctx, Transform3D.IDENTITY, params.trunk_height, params.trunk_radius, 0)

	bark.generate_normals()
	var mesh := bark.commit()

	var leaves := SurfaceTool.new()
	leaves.begin(Mesh.PRIMITIVE_TRIANGLES)
	var leaf_rng := RandomNumberGenerator.new()
	leaf_rng.seed = params.seed + 101
	var quad_count := 0
	for cluster in leaf_clusters:
		quad_count += _emit_leaf_cluster(
			leaves, leaf_rng, cluster[0], cluster[1], params, leaf_factor, leaf_size_factor,
			quad_count)
	mesh = leaves.commit(mesh)
	return mesh


## Bounding size of the mesh as (width, height), for impostor quads.
static func measure(mesh: ArrayMesh) -> Vector2:
	var aabb := mesh.get_aabb()
	return Vector2(maxf(aabb.size.x, aabb.size.z), aabb.size.y + aabb.position.y)


## Preset parameter sets: 4 broadleaf shapes + 2 conifers.
static func variant_params(index: int) -> Dictionary:
	var presets := [
		# Tall, sparse broadleaf
		{conifer = false, trunk_height = 4.6, trunk_radius = 0.30, levels = 3,
			children_min = 2, children_max = 3, branch_pitch_deg = 32.0,
			length_ratio = 0.72, segment_bend_deg = 7.0,
			leaf_cluster_radius = 1.25, leaf_quads = 10, leaf_quad_size = 1.0,
			bark_color = Color(0.36, 0.28, 0.20), leaf_color = Color(0.16, 0.32, 0.09)},
		{conifer = false, trunk_height = 4.0, trunk_radius = 0.26, levels = 3,
			children_min = 2, children_max = 4, branch_pitch_deg = 40.0,
			length_ratio = 0.68, segment_bend_deg = 9.0,
			leaf_cluster_radius = 1.1, leaf_quads = 9, leaf_quad_size = 0.95,
			bark_color = Color(0.32, 0.26, 0.20), leaf_color = Color(0.19, 0.36, 0.11)},
		# Mid, round crown
		{conifer = false, trunk_height = 3.0, trunk_radius = 0.24, levels = 3,
			children_min = 3, children_max = 4, branch_pitch_deg = 46.0,
			length_ratio = 0.64, segment_bend_deg = 10.0,
			leaf_cluster_radius = 1.0, leaf_quads = 8, leaf_quad_size = 0.9,
			bark_color = Color(0.38, 0.30, 0.22), leaf_color = Color(0.15, 0.30, 0.08)},
		# Short, bushy
		{conifer = false, trunk_height = 2.2, trunk_radius = 0.20, levels = 3,
			children_min = 3, children_max = 4, branch_pitch_deg = 52.0,
			length_ratio = 0.60, segment_bend_deg = 12.0,
			leaf_cluster_radius = 0.9, leaf_quads = 8, leaf_quad_size = 0.85,
			bark_color = Color(0.34, 0.27, 0.21), leaf_color = Color(0.21, 0.35, 0.12)},
		# Conifers
		{conifer = true, trunk_height = 9.0, trunk_radius = 0.32,
			whorl_step = 0.8, whorl_size = 6, first_whorl = 0.22,
			leaf_cluster_radius = 0.55, leaf_quads = 6, leaf_quad_size = 0.8,
			bark_color = Color(0.30, 0.22, 0.16), leaf_color = Color(0.07, 0.20, 0.08)},
		{conifer = true, trunk_height = 7.0, trunk_radius = 0.26,
			whorl_step = 0.7, whorl_size = 5, first_whorl = 0.28,
			leaf_cluster_radius = 0.5, leaf_quads = 6, leaf_quad_size = 0.7,
			bark_color = Color(0.28, 0.21, 0.15), leaf_color = Color(0.09, 0.22, 0.09)},
	]
	var p: Dictionary = presets[index % presets.size()].duplicate()
	p.seed = 9000 + index * 37
	return p


# ── Branch turtle ────────────────────────────────────────────────────────────

## Grows one branch as `segments` tapered ring extrusions, then recurses.
static func _grow_branch(
		ctx: Dictionary, xform: Transform3D, length: float, radius: float, depth: int) -> void:
	var params: Dictionary = ctx.params
	var rng: RandomNumberGenerator = ctx.rng
	var segments: int = ctx.segments
	var end_radius := maxf(radius * 0.6, MIN_RADIUS)
	var step := length / float(segments)
	var bend := deg_to_rad(params.segment_bend_deg)

	var t := xform
	var v_offset := 0.0
	var color: Color = params.bark_color * rng.randf_range(0.85, 1.1)
	var prev_ring := _emit_ring(ctx, t, radius, v_offset, color)
	for s in segments:
		# Random lean plus a gentle straightening bias toward vertical for the
		# trunk, so trees don't all topple the same way.
		var lean_axis := (t.basis.x * rng.randf_range(-1.0, 1.0)
				+ t.basis.z * rng.randf_range(-1.0, 1.0)).normalized()
		var lean := rng.randf_range(0.3, 1.0) * bend
		t.basis = Basis(lean_axis, lean) * t.basis
		if depth == 0:
			var up_error := t.basis.y.angle_to(Vector3.UP)
			if up_error > 0.05:
				var fix_axis := t.basis.y.cross(Vector3.UP).normalized()
				t.basis = Basis(fix_axis, up_error * 0.35) * t.basis
		t.origin += t.basis.y * step
		v_offset += step
		var r := lerpf(radius, end_radius, float(s + 1) / float(segments))
		var ring := _emit_ring(ctx, t, r, v_offset, color)
		_connect_rings(ctx, prev_ring, ring)
		prev_ring = ring

	if depth >= ctx.level_cap or end_radius <= MIN_RADIUS:
		ctx.leaves.append([t.origin, 1.0])
		return

	# Terminal-ish clusters partway up the crown fill it out.
	if depth == ctx.level_cap - 1 and rng.randf() < 0.4:
		ctx.leaves.append([t.origin, 0.8])

	var children: int = rng.randi_range(params.children_min, params.children_max)
	var yaw0 := rng.randf() * TAU
	for c in children:
		var yaw := yaw0 + float(c) * 2.4 + rng.randf_range(-0.3, 0.3)  # golden angle
		var pitch := deg_to_rad(params.branch_pitch_deg + rng.randf_range(-12.0, 12.0))
		var child := t
		child.basis = child.basis * Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
		_grow_branch(ctx, child, length * params.length_ratio * rng.randf_range(0.85, 1.1),
				end_radius * 0.85, depth + 1)
	if rng.randf() < 0.3:
		var cont := t
		cont.basis = cont.basis * Basis(Vector3.UP, rng.randf() * TAU) \
				* Basis(Vector3.RIGHT, deg_to_rad(rng.randf_range(2.0, 10.0)))
		_grow_branch(ctx, cont, length * params.length_ratio, end_radius * 0.8, depth + 1)


## Conifer: straight tapered trunk + whorls of near-horizontal branches whose
## length shrinks with height (cone), leaf clusters along the outer halves.
static func _grow_conifer(ctx: Dictionary) -> void:
	var params: Dictionary = ctx.params
	var rng: RandomNumberGenerator = ctx.rng
	var height: float = params.trunk_height
	var trunk_segments: int = 5 if ctx.segments == 3 else 3
	var step := height / float(trunk_segments)
	var color: Color = params.bark_color * rng.randf_range(0.9, 1.05)

	var t := Transform3D.IDENTITY
	var prev_ring := _emit_ring(ctx, t, params.trunk_radius, 0.0, color)
	for s in trunk_segments:
		t.origin += Vector3.UP * step
		var r := lerpf(params.trunk_radius, MIN_RADIUS, float(s + 1) / float(trunk_segments))
		var ring := _emit_ring(ctx, t, r, step * float(s + 1), color)
		_connect_rings(ctx, prev_ring, ring)
		prev_ring = ring
	ctx.leaves.append([Vector3(0, height, 0), 0.7])  # crown tip

	var max_branch_len := height * 0.42
	var y: float = params.first_whorl * height
	var whorl_yaw := rng.randf() * TAU
	while y < height * 0.92:
		var frac := y / height
		var branch_len := max_branch_len * pow(1.0 - frac, 0.9) * rng.randf_range(0.85, 1.05)
		if branch_len > 0.5:
			var count: int = params.whorl_size + rng.randi_range(-1, 1)
			for b in count:
				var yaw := whorl_yaw + TAU * float(b) / float(count) + rng.randf_range(-0.2, 0.2)
				var pitch := deg_to_rad(rng.randf_range(80.0, 100.0))
				var branch := Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch),
						Vector3(0, y, 0))
				var trunk_r := lerpf(params.trunk_radius, MIN_RADIUS, frac)
				_grow_conifer_branch(ctx, branch, branch_len, minf(trunk_r * 0.6, 0.09), color)
		whorl_yaw += 2.4
		y += params.whorl_step * (1.0 + frac * 0.4)


static func _grow_conifer_branch(
		ctx: Dictionary, xform: Transform3D, length: float, radius: float, color: Color) -> void:
	var rng: RandomNumberGenerator = ctx.rng
	var segments: int = mini(ctx.segments, 2)
	var step := length / float(segments)
	var t := xform
	var prev_ring := _emit_ring(ctx, t, radius, 0.0, color)
	for s in segments:
		# Slight droop, then tip lift — the classic conifer silhouette.
		var droop := deg_to_rad(6.0 if s == 0 else -8.0) + rng.randf_range(-0.05, 0.05)
		t.basis = t.basis * Basis(Vector3.RIGHT, droop)
		t.origin += t.basis.y * step
		var r := maxf(lerpf(radius, MIN_RADIUS, float(s + 1) / float(segments)), MIN_RADIUS)
		var ring := _emit_ring(ctx, t, r, step * float(s + 1), color)
		_connect_rings(ctx, prev_ring, ring)
		prev_ring = ring
		ctx.leaves.append([t.origin, 0.75 + 0.35 * float(s)])


# ── Mesh emission ────────────────────────────────────────────────────────────

## Emits one ring of `sides` vertices in the branch cross-section plane.
## Returns the index of the first vertex.
static func _emit_ring(
		ctx: Dictionary, t: Transform3D, radius: float, v_offset: float, color: Color) -> int:
	var bark: SurfaceTool = ctx.bark
	var sides: int = ctx.sides
	var first: int = ctx.vert_count
	for k in sides + 1:  # duplicated seam vertex for clean UV wrap
		var angle := TAU * float(k) / float(sides)
		var local := Vector3(cos(angle) * radius, 0, sin(angle) * radius)
		bark.set_color(color)
		bark.set_uv(Vector2(float(k) / float(sides), v_offset * 0.4))
		bark.set_smooth_group(0)
		bark.add_vertex(t.origin + t.basis * local)
	ctx.vert_count += sides + 1
	return first


## Connects two consecutive rings with quads (Godot front faces are clockwise
## seen from outside the cylinder).
static func _connect_rings(ctx: Dictionary, ring_a: int, ring_b: int) -> void:
	var bark: SurfaceTool = ctx.bark
	var sides: int = ctx.sides
	for k in sides:
		var a0 := ring_a + k
		var a1 := ring_a + k + 1
		var b0 := ring_b + k
		var b1 := ring_b + k + 1
		bark.add_index(a0); bark.add_index(b1); bark.add_index(b0)
		bark.add_index(a0); bark.add_index(a1); bark.add_index(b1)


## Emits a cluster of leaf card quads around `center`. Normals point away from
## the cluster center so the canopy shades like a rounded volume.
static func _emit_leaf_cluster(
		st: SurfaceTool, rng: RandomNumberGenerator, center: Vector3, size_scale: float,
		params: Dictionary, quad_factor: float, size_factor: float, start_quads: int) -> int:
	var quads: int = maxi(int(ceilf(params.leaf_quads * quad_factor)), 2)
	var cluster_r: float = params.leaf_cluster_radius * size_scale
	var base_index := start_quads * 4
	for q in quads:
		var offset := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 0.8),
				rng.randf_range(-1, 1)).normalized() * cluster_r * rng.randf()
		var pos := center + offset
		var size: float = params.leaf_quad_size * size_factor * rng.randf_range(0.7, 1.3) * size_scale
		var color: Color = params.leaf_color * rng.randf_range(0.8, 1.15)

		# Orientation biased toward horizontal cards (±40°).
		var yaw := rng.randf() * TAU
		var tilt := rng.randf_range(-0.7, 0.7)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, tilt)
		var right := basis.x * size * 0.5
		var fwd := basis.z * size * 0.5
		var n := (pos - center).normalized()
		if n.length_squared() < 0.5:
			n = Vector3.UP

		var uv2 := Vector2(pos.x, pos.z)
		var corners := [pos - right - fwd, pos + right - fwd, pos + right + fwd, pos - right + fwd]
		var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
		for i in 4:
			st.set_color(color)
			st.set_normal(n)
			st.set_uv(uvs[i])
			st.set_uv2(uv2)
			st.add_vertex(corners[i])
		var v := base_index + q * 4
		st.add_index(v); st.add_index(v + 2); st.add_index(v + 1)
		st.add_index(v); st.add_index(v + 3); st.add_index(v + 2)
	return quads
