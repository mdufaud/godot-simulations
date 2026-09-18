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
uniform sampler3D volume_tex_prev : filter_linear, repeat_disable;
// The indirection volume is an R32_UINT storage image on the compute side, viewed
// here as RGBA8_UNORM over the same memory because that is the widest 32-bit
// format Texture3DRD can carry (see FireTilePool._create_resources). Its four
// bytes are the slot index, little end first.
uniform sampler3D indir_tex : filter_nearest, repeat_disable;
uniform sampler3D indir_tex_prev : filter_nearest, repeat_disable;
uniform sampler3D visual_activity_tex : filter_nearest, repeat_disable;
uniform sampler3D visual_activity_tex_prev : filter_nearest, repeat_disable;
uniform float temporal_blend = 1.0;

// Pool layout, all FireTilePool's and pushed by FirePresentation: a tile is
// 1 << tile_shift cells on a side, and an indirection entry at or above
// tile_slot_max is a sentinel, meaning no tile is resident there.
uniform vec3 atlas_cells;
uniform ivec3 atlas_tiles;
uniform ivec3 virtual_tiles;
uniform int tile_shift;
uniform uint tile_slot_max;
uniform float cell_size = 0.2;
uniform vec3 virtual_origin = vec3(-204.8, 0.0, -204.8);
uniform vec3 volume_origin = vec3(-6.4, 0.0, -6.4);
uniform vec3 volume_extent = vec3(12.8, 19.2, 12.8);
uniform float visual_occupancy_threshold = 0.01;
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

int tile_cells() {
	return 1 << tile_shift;
}

// Atlas texel of the low corner of a slot's 8^3 block.
ivec3 slot_origin(uint slot) {
	int s = int(slot);
	return ivec3(s % atlas_tiles.x, (s / atlas_tiles.x) % atlas_tiles.y,
		s / (atlas_tiles.x * atlas_tiles.y)) * tile_cells();
}

// Reassemble the stored uint. The +0.5 is the exact inverse of the UNORM encode:
// a byte b comes back as b/255, so b/255*255 + 0.5 truncates to b for every b.
uint indir_slot(ivec3 vt, bool previous) {
	vec4 encoded = previous ? texelFetch(indir_tex_prev, vt, 0)
		: texelFetch(indir_tex, vt, 0);
	uvec4 b = uvec4(encoded * 255.0 + 0.5);
	return b.r | (b.g << 8u) | (b.b << 16u) | (b.a << 24u);
}

uint tile_slot(ivec3 vt, bool previous) {
	if (any(lessThan(vt, ivec3(0))) || any(greaterThanEqual(vt, virtual_tiles))) {
		return 0xFFFFFFFFu;
	}
	return indir_slot(vt, previous);
}

// Nearest tap at a virtual cell. A cell whose tile is not resident reads as
// nothing at all — which is the right answer and not an approximation: the pool
// keeps two tiles of dilation band past anything visible, so a missing tile is
// always clear air, and it is what the dense build's edge fade approximated.
vec4 tap(ivec3 vc, ivec3 current_tile, uint current_slot, ivec3 current_atlas,
	bool previous) {
	ivec3 vt = vc >> ivec3(tile_shift);
	uint slot = all(equal(vt, current_tile)) ? current_slot : tile_slot(vt, previous);
	if (slot >= tile_slot_max) {
		return vec4(0.0);
	}
	ivec3 atlas = all(equal(vt, current_tile)) ? current_atlas : slot_origin(slot);
	return previous ? texelFetch(volume_tex_prev, atlas + (vc & ivec3(tile_cells() - 1)), 0)
		: texelFetch(volume_tex, atlas + (vc & ivec3(tile_cells() - 1)), 0);
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
vec4 sample_virtual(vec3 vp, ivec3 current_tile, uint current_slot,
	ivec3 current_atlas, bool previous) {
	vec3 g = vp - vec3(0.5);
	ivec3 c0 = ivec3(floor(g));
	vec3 f = g - vec3(c0);
	ivec3 vt = c0 >> ivec3(tile_shift);
	if (all(equal(vt, (c0 + ivec3(1)) >> ivec3(tile_shift)))) {
		uint slot = all(equal(vt, current_tile)) ? current_slot : tile_slot(vt, previous);
		if (slot >= tile_slot_max) {
			return vec4(0.0);
		}
		ivec3 atlas = all(equal(vt, current_tile)) ? current_atlas : slot_origin(slot);
		vec3 uvw = (vec3(atlas + (c0 & ivec3(tile_cells() - 1))) + vec3(0.5) + f) / atlas_cells;
		return previous ? texture(volume_tex_prev, uvw) : texture(volume_tex, uvw);
	}
	vec4 s000 = tap(c0, current_tile, current_slot, current_atlas, previous);
	vec4 s100 = tap(c0 + ivec3(1, 0, 0), current_tile, current_slot, current_atlas, previous);
	vec4 s010 = tap(c0 + ivec3(0, 1, 0), current_tile, current_slot, current_atlas, previous);
	vec4 s110 = tap(c0 + ivec3(1, 1, 0), current_tile, current_slot, current_atlas, previous);
	vec4 s001 = tap(c0 + ivec3(0, 0, 1), current_tile, current_slot, current_atlas, previous);
	vec4 s101 = tap(c0 + ivec3(1, 0, 1), current_tile, current_slot, current_atlas, previous);
	vec4 s011 = tap(c0 + ivec3(0, 1, 1), current_tile, current_slot, current_atlas, previous);
	vec4 s111 = tap(c0 + ivec3(1, 1, 1), current_tile, current_slot, current_atlas, previous);
	return mix(mix(mix(s000, s100, f.x), mix(s010, s110, f.x), f.y),
		mix(mix(s001, s101, f.x), mix(s011, s111, f.x), f.y), f.z);
}

float visual_tile_signal(ivec3 atlas, bool previous) {
	return previous ? texelFetch(visual_activity_tex_prev, atlas, 0).r
		: texelFetch(visual_activity_tex, atlas, 0).r;
}

void fragment() {
	vec3 ray_dir = normalize(pos_obj - cam_obj);
	vec3 half_size = volume_extent * 0.5;
	vec3 volume_center = volume_origin + half_size;

	float t0;
	float t1;
	if (!box_span(cam_obj, ray_dir, -half_size, half_size, t0, t1)) {
		discard;
	}
	t1 = min(t1, scene_depth_distance(SCREEN_UV, INV_PROJECTION_MATRIX,
		INV_VIEW_MATRIX, CAMERA_POSITION_WORLD));
	t1 = min(t1, t0 + max_distance);
	if (t1 <= t0) {
		discard;
	}

	// The water surface splits the accumulation (lot H): samples in front of it
	// go on top of the water shading already in the framebuffer, samples behind
	// are added back through the water's own transmittance. The plane does not
	// truncate the ray — the water is transparent, unlike the scene depth above.
	float t_water = water_ray_distance(SCREEN_UV, ray_dir, INV_VIEW_MATRIX);
	vec3 water_tw = water_transmittance(SCREEN_UV);
	// Hearth light in object space, once per fragment: the march mixes tap
	// positions in object coordinates and the model is unrotated, so distances
	// are unchanged.
	vec3 light_obj = (inverse(MODEL_MATRIX) * vec4(fire_light_pos, 1.0)).xyz;

	// A zero direction component would make the DDA's 1/d infinite and its first
	// boundary crossing a NaN; nudged off zero it is merely enormous, which is
	// what "never crosses a plane on this axis" should compute as.
	vec3 sgn = sign(ray_dir);
	sgn += vec3(1.0) - abs(sgn);
	vec3 inv_dir = 1.0 / (sgn * max(abs(ray_dir), vec3(1e-6)));

	// ---- DDA setup, in tiles (Amanatides & Woo) ----
	float tile_world = float(tile_cells()) * cell_size;
	vec3 entry = (cam_obj + ray_dir * t0 + volume_center - virtual_origin) / tile_world;
	ivec3 ti = clamp(ivec3(floor(entry)), ivec3(0), virtual_tiles - ivec3(1));
	ivec3 tstep = ivec3(sgn);
	vec3 t_delta = abs(tile_world * inv_dir);
	// t at which the ray leaves this tile through each of the three axes.
	vec3 plane = virtual_origin
		+ (vec3(ti) + max(vec3(tstep), vec3(0.0))) * tile_world;
	plane -= volume_center;
	vec3 t_next = (plane - cam_obj) * inv_dir;

	// The sample lattice is global along the ray rather than restarted per tile:
	// re-phasing it at every boundary would print the tile grid into the jitter.
	float ds = cell_size * march_step;
	float jitter = march_jitter(FRAGCOORD.xy);
	float t_cursor = t0 + ds * jitter;

	vec3 col = vec3(0.0);
	float trans = 1.0;
	float debug_max = 0.0;
	// Accumulation snapshot at the water plane (lot H): col - col_front is then
	// exactly the behind-the-water contribution, gathered with the same scalar
	// transmittance and attenuated once at the end.
	vec3 col_front = vec3(0.0);
	float trans_front = 1.0;
	bool crossed_water = false;

	// One flat loop: an iteration either takes a sample inside the tile the ray is
	// in, or skips to the next tile. Flat rather than a fine loop nested in the
	// tile loop so the whole march stays one basic block the compiler will not try
	// to unroll (see march_budget).
	float t_exit = min(min(t_next.x, t_next.y), t_next.z);
	float seg_end = min(t_exit, t1);
	// Without temporal interpolation the previous frame's atlas is never read, so
	// its indirection fetch and its activity fetch are two texelFetch per tile
	// step for nothing. Hoisted out of the loop as a uniform-valued flag.
	bool use_prev = temporal_blend < 0.999;
	uint current_slot = indir_slot(ti, false);
	ivec3 current_atlas = current_slot < tile_slot_max ? slot_origin(current_slot) : ivec3(0);
	uint previous_slot = 0xFFFFFFFFu;
	ivec3 previous_atlas = ivec3(0);
	if (use_prev) {
		previous_slot = indir_slot(ti, true);
		previous_atlas = previous_slot < tile_slot_max ? slot_origin(previous_slot) : ivec3(0);
	}
	bool resident = current_slot < tile_slot_max
		&& visual_tile_signal(current_atlas, false) >= visual_occupancy_threshold;
	resident = resident || (use_prev && previous_slot < tile_slot_max
		&& visual_tile_signal(previous_atlas, true) >= visual_occupancy_threshold);

	for (int i = 0; i < march_budget; i++) {
		if (resident && t_cursor < seg_end) {
			vec3 p = cam_obj + ray_dir * t_cursor;
			vec3 sample_pos = p + volume_center;
			vec3 virtual_pos = (sample_pos - virtual_origin) / cell_size;
			if (!crossed_water && t_cursor >= t_water) {
				crossed_water = true;
				col_front = col;
				trans_front = trans;
			}
			vec4 s = sample_virtual(virtual_pos, ti, current_slot, current_atlas, false);
			if (use_prev) {
				vec4 previous = sample_virtual(virtual_pos, ti, previous_slot,
					previous_atlas, true);
				s = mix(previous, s, temporal_blend);
			}
			if (debug_mode == 1) {
				debug_max = max(debug_max, s.r);
			} else {
				// Self-shadow taps for the lit smoke: 1 or 2 samples of the
				// volume between this point and the hearth, read through the
				// same virtual-grid fetch the march itself uses. The light
				// path is clamped to a short range — beyond it the inverse-
				// square has already killed the term.
				vec4 light_a = vec4(0.0);
				vec4 light_b = vec4(0.0);
				float light_dist = 0.0;
				if (smoke_light_taps > 0 && s.g > 0.001
						&& fire_light_rgb.r + fire_light_rgb.g + fire_light_rgb.b > 1e-5) {
					light_dist = min(distance(sample_pos, fire_light_pos), 8.0);
					float frac = smoke_light_taps == 1 ? 0.5 : 0.33;
					light_a = sample_virtual(
						(mix(p, light_obj, frac) + volume_center - virtual_origin) / cell_size,
						ti, current_slot, current_atlas, false);
					if (smoke_light_taps == 2) {
						light_b = sample_virtual(
							(mix(p, light_obj, 0.66) + volume_center - virtual_origin) / cell_size,
							ti, current_slot, current_atlas, false);
					}
				}
				float blue = 0.0;
				accumulate(s, p, sample_pos, sample_pos.y, ds, TIME, light_a,
					light_b, light_dist, col, trans, blue);
				if (debug_mode == 2) {
					debug_max = max(debug_max, s.b);
				} else if (debug_mode == 3) {
					debug_max = max(debug_max, blue);
				}
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
		current_slot = indir_slot(ti, false);
		current_atlas = current_slot < tile_slot_max ? slot_origin(current_slot) : ivec3(0);
		if (use_prev) {
			previous_slot = indir_slot(ti, true);
			previous_atlas = previous_slot < tile_slot_max ? slot_origin(previous_slot) : ivec3(0);
		}
		resident = current_slot < tile_slot_max
			&& visual_tile_signal(current_atlas, false) >= visual_occupancy_threshold;
		resident = resident || (use_prev && previous_slot < tile_slot_max
			&& visual_tile_signal(previous_atlas, true) >= visual_occupancy_threshold);
		// Skipped tiles cost the sample lattice nothing: the cursor is snapped
		// forward onto it rather than restarted, so the jitter pattern does not
		// re-phase at every tile boundary and print the tile grid into the plume.
		if (resident && t_cursor < t_enter) {
			t_cursor += ds * ceil((t_enter - t_cursor) / ds);
		}
	}

	if (debug_mode >= 1) {
		ALBEDO = vec3(debug_max);
		ALPHA = debug_max > 0.005 ? 0.85 : 0.0;
	} else if (crossed_water) {
		// The water composite is already in the framebuffer (it draws at a
		// lower render priority), so blending with alpha = 1 - trans_front
		// leaves the water — and everything behind it — multiplied by exactly
		// the fire's transmittance at the plane, while the behind-the-water
		// fire is added back through the water's own per-channel extinction:
		//   out = col_front + trans_front * T_water * col_behind
		//       + trans_front * framebuffer
		// The 0.02 floor keeps ALBEDO * ALPHA exact without dividing a
		// vanishing alpha into an overflow.
		float a = max(1.0 - trans_front, 0.02);
		vec3 behind = col - col_front;
		ALBEDO = (col_front + trans_front * water_tw * behind) / a;
		ALPHA = a;
	} else {
		float alpha = 1.0 - trans;
		ALBEDO = col / max(alpha, 1e-4);
		ALPHA = alpha;
	}
}
