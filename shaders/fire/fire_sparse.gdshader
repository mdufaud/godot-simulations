shader_type spatial;
// Volume raymarcher over the SPARSE fire grid (sparse-grid refactor, Phase 6).
// Same render modes and the same emission model as the dense fire.gdshader; what
// differs is where the volume lives and how the ray gets through it.
render_mode unshaded, blend_mix, cull_front, depth_draw_never, depth_test_disabled;

#include "res://shaders/fire/fire_volume.gdshaderinc"

// The display field is no longer the domain: it is an atlas of the resident 8^3
// tiles, and the ray works in VIRTUAL cell coordinates over the whole 409.6 x
// 102.4 x 409.6 m map. tile_indir maps a virtual tile to its atlas slot, exactly
// as fire_common.comp's sparse_texel does for the solver, and the march is a 3D
// DDA over it: a tile with no slot in it is skipped whole, so the step count
// tracks the depth of plume along the ray rather than the size of the domain.
uniform sampler3D volume_tex : filter_linear, repeat_disable;
// The indirection volume is an R32_UINT storage image on the compute side, viewed
// here as RGBA8_UNORM over the same memory because that is the widest 32-bit
// format Texture3DRD can carry (see FireTilePool._create_resources). Its four
// bytes are the slot index, little end first.
uniform sampler3D indir_tex : filter_nearest, repeat_disable;

uniform vec3 atlas_cells = vec3(128.0, 64.0, 128.0);
uniform ivec3 atlas_tiles = ivec3(16, 8, 16);
uniform ivec3 virtual_tiles = ivec3(256, 64, 256);
uniform float cell_size = 0.2;
// The extent of the resident set in the mesh's object space, refreshed every frame
// from the solver's reduction (FireGpuSolver.display_clip_box). The mesh has to
// span the whole virtual domain — it is the proxy geometry a fire anywhere on the
// map needs pixels from — but the ray is clipped to the part of it that has tiles
// in it, so a pixel looking at empty sky discards on the slab test instead of
// walking hundreds of metres of indirection volume. Defaults to the whole domain,
// which is correct and merely slow.
uniform vec3 clip_min = vec3(-204.8, -51.2, -204.8);
uniform vec3 clip_max = vec3(204.8, 51.2, 204.8);
// Fine step inside an active tile, in cells. The dense march samples roughly
// every 1.25 cells over its box diagonal, so this is the same sampling density.
uniform float march_step : hint_range(0.25, 4.0) = 0.75;
// The virtual domain is 410 m across and the camera stands in it, so a ray aimed
// at the sky would otherwise walk a quarter of a kilometre of empty tiles for
// nothing. Fire past this is not what the player is looking at.
uniform float max_distance = 80.0;
// Total iterations a ray may spend, tile skips and fine samples together — past
// that the budget runs out rather than the frame. A diagonal ray across
// max_distance costs about 110 tile steps, leaving the rest for samples.
//
// A UNIFORM rather than a constant on purpose: with a literal bound the compiler
// unrolls the march, and 250 copies of a body holding an eight-tap trilinear
// fetch is enough to exhaust the machine's memory while linking the shader.
uniform int march_budget : hint_range(64, 512) = 320;

const int TILE = 8;
// Mirrors fire_tile_pool.gd: at or above this an indirection entry is a sentinel,
// meaning no tile is resident there.
const uint SLOT_MAX = 0xFFFFFFF0u;

// Atlas texel of the low corner of a slot's 8^3 block.
ivec3 slot_origin(uint slot) {
	int s = int(slot);
	return ivec3(s % atlas_tiles.x, (s / atlas_tiles.x) % atlas_tiles.y,
		s / (atlas_tiles.x * atlas_tiles.y)) * TILE;
}

// Reassemble the stored uint. The +0.5 is the exact inverse of the UNORM encode:
// a byte b comes back as b/255, so b/255*255 + 0.5 truncates to b for every b.
uint indir_slot(ivec3 vt) {
	uvec4 b = uvec4(texelFetch(indir_tex, vt, 0) * 255.0 + 0.5);
	return b.r | (b.g << 8u) | (b.b << 16u) | (b.a << 24u);
}

uint tile_slot(ivec3 vt) {
	if (any(lessThan(vt, ivec3(0))) || any(greaterThanEqual(vt, virtual_tiles))) {
		return 0xFFFFFFFFu;
	}
	return indir_slot(vt);
}

// Nearest tap at a virtual cell. A cell whose tile is not resident reads as
// nothing at all — which is the right answer and not an approximation: the pool
// keeps two tiles of dilation band past anything visible, so a missing tile is
// always clear air, and it is what the dense build's edge fade approximated.
vec4 tap(ivec3 vc) {
	uint slot = tile_slot(vc >> 3);
	if (slot >= SLOT_MAX) {
		return vec4(0.0);
	}
	return texelFetch(volume_tex, slot_origin(slot) + (vc & ivec3(7)), 0);
}

// Trilinear fetch at a continuous virtual cell position (cell centres sit on
// integers + 0.5).
//
// When the eight taps share one tile — everything but the outermost half cell of
// each tile face, so about two thirds of the volume — the whole stencil is inside
// one atlas block and the hardware filter does it in a single fetch. Otherwise
// the corners are resolved one at a time. Filtering the atlas directly across a
// block edge is what would bleed an unrelated part of the map into the seam,
// since two slots that are adjacent in the atlas are almost never adjacent in
// the world.
vec4 sample_virtual(vec3 vp) {
	vec3 g = vp - vec3(0.5);
	ivec3 c0 = ivec3(floor(g));
	vec3 f = g - vec3(c0);
	ivec3 vt = c0 >> 3;
	if (all(equal(vt, (c0 + ivec3(1)) >> 3))) {
		uint slot = tile_slot(vt);
		if (slot >= SLOT_MAX) {
			return vec4(0.0);
		}
		vec3 uvw = (vec3(slot_origin(slot) + (c0 & ivec3(7))) + vec3(0.5) + f) / atlas_cells;
		return texture(volume_tex, uvw);
	}
	vec4 s000 = tap(c0);
	vec4 s100 = tap(c0 + ivec3(1, 0, 0));
	vec4 s010 = tap(c0 + ivec3(0, 1, 0));
	vec4 s110 = tap(c0 + ivec3(1, 1, 0));
	vec4 s001 = tap(c0 + ivec3(0, 0, 1));
	vec4 s101 = tap(c0 + ivec3(1, 0, 1));
	vec4 s011 = tap(c0 + ivec3(0, 1, 1));
	vec4 s111 = tap(c0 + ivec3(1, 1, 1));
	return mix(mix(mix(s000, s100, f.x), mix(s010, s110, f.x), f.y),
		mix(mix(s001, s101, f.x), mix(s011, s111, f.x), f.y), f.z);
}

void fragment() {
	vec3 ray_dir = normalize(pos_obj - cam_obj);
	vec3 half_size = box_size * 0.5;

	float t0;
	float t1;
	if (!box_span(cam_obj, ray_dir, clip_min, clip_max, t0, t1)) {
		discard;
	}
	t1 = min(t1, scene_depth_distance(SCREEN_UV, INV_PROJECTION_MATRIX,
		INV_VIEW_MATRIX, CAMERA_POSITION_WORLD));
	t1 = min(t1, t0 + max_distance);
	if (t1 <= t0) {
		discard;
	}

	// A zero direction component would make the DDA's 1/d infinite and its first
	// boundary crossing a NaN; nudged off zero it is merely enormous, which is
	// what "never crosses a plane on this axis" should compute as.
	vec3 sgn = sign(ray_dir);
	sgn += vec3(1.0) - abs(sgn);
	vec3 inv_dir = 1.0 / (sgn * max(abs(ray_dir), vec3(1e-6)));

	// ---- DDA setup, in tiles (Amanatides & Woo) ----
	float tile_world = float(TILE) * cell_size;
	vec3 entry = cam_obj + ray_dir * t0 + half_size;
	ivec3 ti = clamp(ivec3(floor(entry / tile_world)), ivec3(0), virtual_tiles - ivec3(1));
	ivec3 tstep = ivec3(sgn);
	vec3 t_delta = abs(tile_world * inv_dir);
	// t at which the ray leaves this tile through each of the three axes.
	vec3 plane = (vec3(ti) + max(vec3(tstep), vec3(0.0))) * tile_world - half_size;
	vec3 t_next = (plane - cam_obj) * inv_dir;

	// The sample lattice is global along the ray rather than restarted per tile:
	// re-phasing it at every boundary would print the tile grid into the jitter.
	float ds = cell_size * march_step;
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))) + TIME * 0.61);
	float t_cursor = t0 + ds * jitter;

	vec3 col = vec3(0.0);
	float trans = 1.0;
	float debug_max = 0.0;

	// One flat loop: an iteration either takes a sample inside the tile the ray is
	// in, or skips to the next tile. Flat rather than a fine loop nested in the
	// tile loop so the whole march stays one basic block the compiler will not try
	// to unroll (see march_budget).
	float t_exit = min(min(t_next.x, t_next.y), t_next.z);
	float seg_end = min(t_exit, t1);
	bool resident = indir_slot(ti) < SLOT_MAX;

	for (int i = 0; i < march_budget; i++) {
		if (resident && t_cursor < seg_end) {
			vec3 p = cam_obj + ray_dir * t_cursor;
			vec4 s = sample_virtual((p + half_size) / cell_size);
			if (debug_mode == 1) {
				debug_max = max(debug_max, s.r);
			} else {
				accumulate(s, p, p.y + half_size.y, ds, TIME, col, trans);
			}
			t_cursor += ds;
			if (trans < 0.01) {
				break;
			}
			continue;
		}
		if (t_exit >= t1) {
			break;
		}
		float t_enter = t_exit;
		if (t_next.x <= t_next.y && t_next.x <= t_next.z) {
			ti.x += tstep.x;
			t_next.x += t_delta.x;
		} else if (t_next.y <= t_next.z) {
			ti.y += tstep.y;
			t_next.y += t_delta.y;
		} else {
			ti.z += tstep.z;
			t_next.z += t_delta.z;
		}
		if (any(lessThan(ti, ivec3(0))) || any(greaterThanEqual(ti, virtual_tiles))) {
			break;
		}
		t_exit = min(min(t_next.x, t_next.y), t_next.z);
		seg_end = min(t_exit, t1);
		resident = indir_slot(ti) < SLOT_MAX;
		// Skipped tiles cost the sample lattice nothing: the cursor is snapped
		// forward onto it rather than restarted, so the jitter pattern does not
		// re-phase at every tile boundary and print the tile grid into the plume.
		if (resident && t_cursor < t_enter) {
			t_cursor += ds * ceil((t_enter - t_cursor) / ds);
		}
	}

	if (debug_mode == 1) {
		ALBEDO = vec3(debug_max);
		ALPHA = debug_max > 0.005 ? 0.85 : 0.0;
	} else {
		float alpha = 1.0 - trans;
		ALBEDO = col / max(alpha, 1e-4);
		ALPHA = alpha;
	}
}
