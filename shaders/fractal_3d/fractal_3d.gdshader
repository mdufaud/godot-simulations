shader_type spatial;
render_mode world_vertex_coords, unshaded, cull_front, depth_test_disabled;
// Raymarch inside a large box, in camera-relative coordinates: a point is its
// offset from the camera, carried through the estimator next to the camera's
// own orbit (ref_a..ref_e, iterated in float64 by FractalReference). Float32
// then resolves a fixed fraction of the ray length at any depth, where a world
// position stops at 1e-7. Distance estimators are established formulas
// (iq/Apollonian & Menger, Jos Leys & Knighty/JosKleinian), not invented.
// Do not diverge from scripts/fractal_3d/fractal_de.gd (absolute, float64) and
// fractal_reference.gd (this offset form, CPU mirror).

// 0 Apollonian, 1 Menger (infinite), 2 Kleinian (Jos Leys)
uniform int fractal_type : hint_range(0, 2) = 0;
uniform int iterations : hint_range(2, 40) = 12;
// Extra iterations past `iterations`, each run only where its features are
// larger than a pixel: detail keeps appearing while flying in, at no cost far away.
uniform int detail_iterations : hint_range(0, 64) = 0;
// Camera orbit rows, one per iteration: see FractalReference.
uniform vec4 ref_a[65];
uniform vec4 ref_b[65];
uniform vec4 ref_c[65];
uniform vec4 ref_d[65];
uniform vec4 ref_e[65];
// Smallest feature the float64 camera orbit still places, in world units.
uniform float lod_floor = 1e-12;

uniform int max_steps : hint_range(30, 1200) = 480;
uniform float max_dist : hint_range(5.0, 200.0) = 60.0;
// Relative epsilon factor: hit tolerance = epsilon*t. Fine near, coarse far.
uniform float epsilon : hint_range(0.00002, 0.01) = 0.0001;
uniform float pixel_angle = 0.0026;
uniform float pixel_tolerance = 0.08;
uniform int ao_samples : hint_range(0, 5) = 5;

// --- Apollonian ---
uniform float apollonian_scale : hint_range(1.0, 2.5) = 1.3;

// --- Kleinian (Jos Leys & Knighty — shadertoy.com/view/XlVXzh, Fragmentarium
// "Knighty Collection/JosKleinian.frag") ---
// Kleinian group limit set. Fundamental domain is the slab 0 < y < klein_r
// wrapped in x/z: the camera is enclosed between fractal floor and ceiling by
// construction, tunnels extend forever horizontally.
uniform float klein_r : hint_range(1.8, 1.96) = 1.95859103011179;
uniform float klein_i : hint_range(-0.2, 0.2) = 0.0112785606117658;
uniform float klein_box_x : hint_range(0.3, 2.0) = 1.0;
uniform float klein_box_z : hint_range(0.3, 2.0) = 1.0;

// --- Color ---
uniform int palette : hint_range(0, 4) = 0;
uniform float color_speed : hint_range(0.0, 3.0) = 0.3;
uniform float color_offset : hint_range(0.0, 1.0) = 0.0;
uniform float glow_strength : hint_range(0.0, 3.0) = 1.0;

// With world_vertex_coords, VERTEX is world-space in vertex() but VIEW-space in
// fragment(). Ray direction needs the world position, so pass it via a varying —
// otherwise rotating the camera does not rotate the image.
varying vec3 world_pos;

const int APOLLONIAN_MAX_ITERATIONS = 64;
const int MENGER_MAX_ITERATIONS = 26;
const int KLEIN_MAX_ITERATIONS = 64;
// s * lod from which a Menger detail level starts closing its holes.
const float MENGER_FADE_FROM = 0.2;
// Smallest feature an extra iteration is spent on, in pixels.
const float DETAIL_PIXELS = 2.0;
// Ray length past which ambient occlusion probes keep their full 1 cm reach.
const float AO_FULL_RANGE_T = 1.0;

void vertex() {
	world_pos = VERTEX;
}


vec3 cospal(float t, vec3 a, vec3 b, vec3 c, vec3 d) {
	return a + b * cos(6.28318 * (c * t + d));
}

vec3 palette_color(int idx, float t) {
	if (idx == 0) // Nacre: iridescent green <-> magenta
		return cospal(t, vec3(0.5, 0.5, 0.5), vec3(0.45, 0.45, 0.5), vec3(1.0, 0.9, 1.1), vec3(0.30, 0.55, 0.15));
	if (idx == 1) // Rainbow
		return cospal(t, vec3(0.5), vec3(0.5), vec3(1.0), vec3(0.0, 0.33, 0.67));
	if (idx == 2) // Fire / thermal
		return cospal(t, vec3(0.5, 0.35, 0.2), vec3(0.5, 0.35, 0.2), vec3(1.0, 1.0, 1.0), vec3(0.0, 0.1, 0.2));
	if (idx == 3) // Ocean / ice
		return cospal(t, vec3(0.2, 0.5, 0.6), vec3(0.3, 0.4, 0.5), vec3(1.0, 1.0, 1.0), vec3(0.4, 0.2, 0.6));
	return cospal(t, vec3(0.6, 0.5, 0.2), vec3(0.4, 0.4, 0.2), vec3(1.0, 1.0, 0.5), vec3(0.0, 0.15, 0.3)); // Gold
}

// ---- Distance estimators, at the camera plus `d`. ----
// trap = orbit trap (min over the base iterations of abs(z), r2).
// lod = world size under which a feature is not worth an iteration (one pixel
// of the ray reaching the point). Every estimator only adds surface per
// iteration, so a coarser lod never moves the surfaces already there.

// k w - K Z for an inversion of radius^2 `radius2`, w = Z + d, without
// subtracting two near-equal vectors: d' = radius2 (d |Z|^2 - Z (2 Z.d + d.d)) / (|Z|^2 |w|^2).
vec3 inverted_offset(vec3 ref, float ref_r2, vec3 d, float r2, float radius2) {
	return radius2 * (d * ref_r2 - ref * (2.0 * dot(ref, d) + dot(d, d))) / (ref_r2 * r2);
}

float de_apollonian(vec3 d, float lod, bool track_trap, out vec4 trap) {
	float s = 1.0;
	trap = vec4(1e10);
	int total = min(iterations + detail_iterations, APOLLONIAN_MAX_ITERATIONS);
	vec3 z1 = ref_e[0].xyz + d + 1.0;
	vec3 z2 = z1 - 2.0;
	int last = 0;
	for (int i = 0; i < APOLLONIAN_MAX_ITERATIONS; i++) {
		if (i >= total) break;
		vec3 z = ref_e[i].xyz + d;
		if (i >= iterations) {
			if (abs(s) * lod > 1.0) break;
			// Away from the set the orbit settles on a 2-cycle: nothing more to
			// find. Left on the parity of the base count, whose estimate it keeps.
			vec3 dz = z - z2;
			if (((i - iterations) & 1) == 0 && dot(dz, dz) < 1e-10) break;
		}
		z2 = z1;
		z1 = z;
		// Fold: the offset only changes by the cell the point lands in.
		vec3 folded = ref_a[i].xyz;
		d -= 2.0 * floor(0.5 * (folded + d) + 0.5);
		vec3 w = folded + d;
		float r2 = max(dot(w, w), 1e-9);
		if (track_trap && i < iterations) trap = min(trap, vec4(abs(w), r2));
		d = inverted_offset(folded, ref_a[i].w, d, r2, apollonian_scale);
		s *= apollonian_scale / r2;
		last = i + 1;
	}
	return 0.25 * abs(ref_e[last].y + d.y) / max(abs(s), 1e-30);
}

// |1 - |u|| - 1 for u = cell + f (cell in 0..5, period 6) with no subtraction
// between cell-sized terms: every wall sits on an integer u, and float32
// cannot resolve a 1e-6 view against a cell-sized coordinate.
float menger_axis(float cell, float f) {
	if (cell < 0.5) return -abs(f);
	if (cell < 1.5 || cell > 4.5) return abs(f) - 1.0;
	if (cell < 2.5) return f;
	if (cell < 3.5) return 1.0 - abs(f);
	return -f;
}

float de_menger(vec3 d, float lod, bool track_trap, out vec4 trap) {
	// No bounding box: the mod() grid is periodic, so the sponge tiles all of
	// space — an infinite lattice of tunnels ("Menger Journey" style).
	float dist = -1e10;
	float s = 1.0;
	trap = vec4(1e10);
	int total = min(iterations + detail_iterations, MENGER_MAX_ITERATIONS);
	for (int i = 0; i < MENGER_MAX_ITERATIONS; i++) {
		if (i >= total || (i >= iterations && s * lod > 1.0)) break;
		// A detail level closes its holes over the last octaves before its cut
		// (they are 1/s wide): popping them in at pixel size rings the view
		// with aliased pits at every cut distance.
		float closing = i >= iterations ? smoothstep(MENGER_FADE_FROM, 1.0, s * lod) : 0.0;
		vec3 f = ref_a[i].xyz + 3.0 * d * s;
		vec3 shift = round(f);
		f -= shift;
		vec3 cell = mod(ref_b[i].xyz + shift, 6.0);
		s *= 3.0;
		vec3 g = vec3(menger_axis(cell.x, f.x), menger_axis(cell.y, f.y), menger_axis(cell.z, f.z));
		if (track_trap && i < iterations) {
			vec3 a = (cell - 6.0 * step(3.5, cell) + f) / 3.0;
			trap = min(trap, vec4(abs(a), dot(a, a)));
		}
		float c = (min(max(g.x, g.y), min(max(g.y, g.z), max(g.z, g.x))) - closing) / s;
		dist = max(dist, c);
	}
	return dist;
}

bool klein_flips(vec2 p) {
	float a = klein_r;
	float b = klein_i;
	return p.y >= a * 0.5 + sign(b) * (2.0 * a - 1.95) / 4.0 * sign(p.x + b * 0.5)
			* (1.0 - exp(-(7.2 - (1.95 - a) * 15.0) * abs(p.x + b * 0.5)));
}

float de_jos_kleinian(vec3 d, float lod, bool track_trap, out vec4 trap) {
	// JosKleinian (Jos Leys & Knighty; shadertoy XlVXzh / Fragmentarium Knighty
	// Collection). Shear + wrap + separation-line fold + sphere inversion
	// (TransA). DF uses the conservative max(1,iR) variant from the source.
	vec3 lz = ref_e[0].xyz + d + 1.0;
	vec3 llz = lz - 2.0;
	float DF = 1.0;
	float a = klein_r;
	float b = klein_i;
	trap = vec4(1e10);
	int total = min(iterations + detail_iterations, KLEIN_MAX_ITERATIONS);
	int last = 0;
	for (int i = 0; i < KLEIN_MAX_ITERATIONS; i++) {
		if (i >= total || (i >= iterations && DF * lod > 1.0)) break;
		// Shear, wrap by whole cells, unshear: translations only.
		float sheared = d.x + b / a * d.y;
		sheared -= 2.0 * klein_box_x * floor((ref_a[i].x + sheared + klein_box_x) / (2.0 * klein_box_x));
		d.z -= 2.0 * klein_box_z * floor((ref_a[i].y + d.z + klein_box_z) / (2.0 * klein_box_z));
		d.x = sheared - b / a * d.y;
		// Point reflection about C / 2, on the point's own side of the line.
		bool flips = klein_flips(ref_b[i].xy + d.xy);
		bool reference_flips = ref_a[i].z > 0.5;
		if (flips && reference_flips) {
			d = -d;
		} else if (flips) {
			d = ref_c[i].xyz - d;
		} else if (reference_flips) {
			d -= ref_c[i].xyz;
		}
		// Inversion, then the mirror of x.
		vec3 v = ref_d[i].xyz;
		vec3 w = v + d;
		float r2 = max(dot(w, w), 1e-12);
		vec3 q = inverted_offset(v, ref_a[i].w, d, r2, 1.0);
		d = vec3(q.x, -q.y, -q.z);
		DF *= max(1.0, 1.0 / r2);
		last = i + 1;
		vec3 z = ref_e[last].xyz + d;
		if (track_trap && i < iterations) trap = min(trap, vec4(abs(z), dot(z, z)));
		if (dot(z - llz, z - llz) < 1e-5) break;
		llz = lz;
		lz = z;
	}
	float y = min(ref_e[last].y + d.y, ref_e[last].w - d.y);
	return min(y, 0.3) / max(DF, 2.0);
}

float scene(vec3 d, float lod, bool track_trap, out vec4 trap) {
	if (fractal_type == 0) return de_apollonian(d, lod, track_trap, trap);
	if (fractal_type == 1) return de_menger(d, lod, track_trap, trap);
	return de_jos_kleinian(d, lod, track_trap, trap);
}

float scene_d(vec3 d, float lod) {
	vec4 t;
	return scene(d, lod, false, t);
}

// Everything below is relative to the ray length t, so a view from 1e-9 of a
// surface resolves like one from 1.
float hit_epsilon(float t) {
	return max(max(epsilon, pixel_angle * pixel_tolerance) * t, 0.25 * lod_floor);
}

float pixel_lod(float t) {
	return max(pixel_angle * t * DETAIL_PIXELS, lod_floor);
}

vec3 calc_normal(vec3 p, float t) {
	// Half a pixel footprint: finer offsets sample DE noise below the pixel and
	// turn into grain on the surface.
	float e = max(max(hit_epsilon(t) * 2.0, pixel_angle * t * 0.5), lod_floor);
	float lod = pixel_lod(t);
	vec2 k = vec2(1.0, -1.0);
	return normalize(
		k.xyy * scene_d(p + k.xyy * e, lod) +
		k.yyx * scene_d(p + k.yyx * e, lod) +
		k.yxy * scene_d(p + k.yxy * e, lod) +
		k.xxx * scene_d(p + k.xxx * e, lod));
}

float calc_ao(vec3 p, vec3 n, float t) {
	float ao = 0.0;
	float w = 1.0;
	// Probe reach follows the view distance once closer than AO_FULL_RANGE_T.
	float reach = min(1.0, t / AO_FULL_RANGE_T);
	float dist = 0.01 * reach;
	float lod = pixel_lod(t);
	for (int i = 0; i < 5; i++) {
		if (i >= ao_samples) break;
		// Never under zero: a detail hole closed by its level-of-detail cut ends
		// in a cap whose probes sit deep in the coarser solid, and went black.
		float d = max(scene_d(p + n * dist, lod), 0.0);
		ao += w * (dist - d);
		w *= 0.5;
		dist *= 1.9;
	}
	return clamp(1.0 - ao * 1.2 / max(reach, 1e-30), 0.0, 1.0);
}

void fragment() {
	vec3 rd = normalize(world_pos - CAMERA_POSITION_WORLD);

	// Nothing is closer than the camera's own free distance: the first march
	// steps need no more detail than a pixel shows at that range.
	float free_distance = max(scene_d(vec3(0.0), lod_floor), 0.0);
	float t = 0.0;
	float d = 0.0;
	bool hit = false;
	bool escaped = false;
	for (int i = 0; i < 1200; i++) {
		if (i >= max_steps) break;
		d = scene_d(rd * t, pixel_lod(max(t, free_distance)));
		float eps = hit_epsilon(t);
		if (d < eps) { hit = true; break; }
		t += max(d * 0.75, eps * 0.5);
		if (t > max_dist) { escaped = true; break; }
	}
	// Out of steps short of max_dist: the ray is crawling along a surface
	// (grazing tunnels), not flying through empty space, so shade what it
	// reached instead of punching a sky-coloured hole.
	if (!hit && !escaped) hit = true;

	vec3 fog_color = vec3(0.02, 0.01, 0.05);
	vec3 col;
	if (hit) {
		vec3 p = rd * t;
		vec4 trap;
		scene(p, pixel_lod(t), true, trap);
		vec3 n = calc_normal(p, t);
		float ot = clamp(sqrt(trap.w) * 0.6, 0.0, 1.0);
		float fres = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), 3.0);
		float phase = ot * 1.2 + fres * 0.8 + TIME * color_speed * 0.15 + color_offset;
		vec3 base = palette_color(palette, phase);

		vec3 ld = normalize(vec3(0.5, 0.8, 0.4));
		float diff = max(dot(n, ld), 0.0) * 0.7 + 0.3;
		vec3 h = normalize(ld - rd);
		float spec = pow(max(dot(n, h), 0.0), 32.0) * 0.5;
		float ao = calc_ao(p, n, t);

		col = base * diff * ao + vec3(spec);
		col += base * fres * 0.5;                      // iridescent rim

		// Full fog, the same colour misses get: surfaces fade into the void
		// instead of ending at a darker hole at max_dist.
		float fog = 1.0 - exp(-t * 0.03);
		col = mix(col, fog_color, fog);
		EMISSION = max(col - vec3(0.72), vec3(0.0)) * glow_strength * 0.35;
	} else {
		col = fog_color;
	}
	ALBEDO = col;
}
