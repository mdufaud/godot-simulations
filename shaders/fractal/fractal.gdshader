shader_type canvas_item;
render_mode blend_disabled;

// ============================================================
// Fractal iteration pass — outputs DATA, not colors.
// Rendered inside an HDR SubViewport (RGBA16F), only when the
// view changes. Coloring happens in fractal_colorize.gdshader.
//
// Output packing:
//   R = floor(mu / 64)          (mu = smooth iteration count)
//   G = mu - R * 64
//   B = log-encoded orbit trap distance
//   A = coverage (fraction of AA subsamples that escaped)
//
// Types: 0 Mandelbrot, 1 Julia, 2 Burning Ship, 3 Tricorn
//
// Deep zoom (types 0/1): perturbation theory. The reference
// orbit is iterated on CPU in float64 and uploaded as an RGF32
// texture; per-pixel deltas stay small enough for float32.
// Mandelbrot uses Zhuoran rebasing to avoid glitches.
// ============================================================

uniform int fractal_type : hint_range(0, 3) = 0;
uniform vec2 julia_c = vec2(-0.7269, 0.1889);
uniform int max_iterations : hint_range(20, 20000) = 1000;

// --- View (direct path) ---
uniform vec2 view_center = vec2(-0.6, 0.0);
uniform float view_half = 1.75; // half height of view, world units

// --- Perturbation path ---
uniform bool use_perturbation = false;
uniform vec2 dc_origin = vec2(0.0); // center - reference point
uniform sampler2D ref_orbit : filter_nearest, repeat_disable;
uniform int ref_len = 0;

// --- Orbit trap ---
uniform int trap_shape : hint_range(0, 3) = 0;
uniform float trap_scale = 1.0;

// --- Quality / progressive bands ---
uniform int aa_quality : hint_range(1, 3) = 1;
uniform int band_y_min = 0;
uniform int band_y_max = 1000000;

const float BAILOUT = 256.0;
const float BAILOUT2 = BAILOUT * BAILOUT;
const int MAX_HARD = 32768;
const int ORBIT_W = 4096;

vec2 fetch_ref(int i) {
	return texelFetch(ref_orbit, ivec2(i % ORBIT_W, i / ORBIT_W), 0).rg;
}

vec2 cmul(vec2 a, vec2 b) {
	return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

float smooth_iter(float n, vec2 z) {
	float log_zn = log(dot(z, z)) * 0.5;
	float nu = log(log_zn / log(BAILOUT)) / log(2.0);
	return n + 1.0 - nu;
}

float trap_dist(vec2 z) {
	float r = length(z);
	if (trap_shape == 0) return abs(r - trap_scale);
	if (trap_shape == 1) return min(abs(z.x), abs(z.y));
	if (trap_shape == 2) return min(abs(z.x), abs(z.y)) + abs(r - trap_scale) * 0.3;
	float ang = atan(z.y, z.x);
	return abs(r * (0.5 + 0.5 * cos(ang * 5.0)) - trap_scale);
}

bool mandelbrot_interior_check(vec2 c) {
	float q = (c.x - 0.25) * (c.x - 0.25) + c.y * c.y;
	if (q * (q + (c.x - 0.25)) < 0.25 * c.y * c.y) return true;
	if ((c.x + 1.0) * (c.x + 1.0) + c.y * c.y < 0.0625) return true;
	return false;
}

// Returns vec3(mu, trap, escaped 0/1)
vec3 eval_direct(vec2 c) {
	if (fractal_type == 0 && mandelbrot_interior_check(c)) {
		return vec3(float(max_iterations), 1.0, 0.0);
	}
	vec2 z = vec2(0.0);
	vec2 fc = c;
	if (fractal_type == 1) { z = c; fc = julia_c; }

	float trap = 1e10;
	float n = 0.0;
	int cap = min(max_iterations, MAX_HARD);
	bool escaped = false;

	for (int i = 0; i < MAX_HARD; i++) {
		if (i >= cap) break;
		if (fractal_type == 2) {
			z = vec2(abs(z.x), abs(z.y));
			z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + fc;
		} else if (fractal_type == 3) {
			float xt = z.x * z.x - z.y * z.y + fc.x;
			z.y = -2.0 * z.x * z.y + fc.y;
			z.x = xt;
		} else {
			float xt = z.x * z.x - z.y * z.y + fc.x;
			z.y = 2.0 * z.x * z.y + fc.y;
			z.x = xt;
		}
		trap = min(trap, trap_dist(z));
		n += 1.0;
		if (dot(z, z) > BAILOUT2) { escaped = true; break; }
	}

	float mu = escaped ? smooth_iter(n, z) : float(max_iterations);
	return vec3(mu, trap, escaped ? 1.0 : 0.0);
}

// Perturbation: z = Z_ref[i] + dz, iterate dz = (2·Z + dz)·dz (+ dc for Mandelbrot).
// Zhuoran rebasing (Mandelbrot): when |z| < |dz| or the reference orbit ends,
// restart deltas from orbit index 0 with dz = z.
vec3 eval_pert(vec2 dc) {
	vec2 dz = vec2(0.0);
	if (fractal_type == 1) dz = dc;

	int ri = 0;
	vec2 z = fetch_ref(0) + dz;
	float trap = 1e10;
	float n = 0.0;
	int cap = min(max_iterations, MAX_HARD);
	bool escaped = false;

	for (int i = 0; i < MAX_HARD; i++) {
		if (i >= cap) break;
		vec2 Z = fetch_ref(ri);
		dz = cmul(2.0 * Z + dz, dz);
		if (fractal_type == 0) dz += dc;
		ri++;
		z = fetch_ref(ri) + dz;

		trap = min(trap, trap_dist(z));
		n += 1.0;
		if (dot(z, z) > BAILOUT2) { escaped = true; break; }

		if (ri >= ref_len - 1 || dot(z, z) < dot(dz, dz)) {
			if (fractal_type == 0) {
				dz = z;
				ri = 0;
			} else if (ri >= ref_len - 1) {
				// Julia reference ended early: treat as escaped approximation
				escaped = dot(z, z) > 4.0;
				break;
			}
		}
	}

	float mu = escaped ? smooth_iter(n, z) : float(max_iterations);
	return vec3(mu, trap, escaped ? 1.0 : 0.0);
}

void fragment() {
	if (FRAGCOORD.y < float(band_y_min) || FRAGCOORD.y >= float(band_y_max)) {
		discard;
	}

	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float aspect = res.x / res.y;
	vec2 world_scale = vec2(2.0 * view_half * aspect, 2.0 * view_half);

	int ns = clamp(aa_quality, 1, 3);
	float inv_ns = 1.0 / float(ns);

	float mu_acc = 0.0;
	float esc_count = 0.0;
	float trap_acc = 0.0;
	float mu_interior = float(max_iterations);

	for (int sy = 0; sy < 3; sy++) {
		if (sy >= ns) break;
		for (int sx = 0; sx < 3; sx++) {
			if (sx >= ns) break;
			vec2 sub = (vec2(float(sx), float(sy)) + 0.5) * inv_ns - 0.5;
			vec2 uv = UV + sub * SCREEN_PIXEL_SIZE;
			vec2 off = (uv - 0.5) * world_scale;
			vec3 r = use_perturbation ? eval_pert(dc_origin + off)
			                          : eval_direct(view_center + off);
			trap_acc += r.y;
			if (r.z > 0.5) {
				mu_acc += r.x;
				esc_count += 1.0;
			}
		}
	}

	float total = float(ns * ns);
	float coverage = esc_count / total;
	float mu = esc_count > 0.0 ? mu_acc / esc_count : mu_interior;
	float trap = log(1.0 + (trap_acc / total) * 8.0) / log(9.0);

	float mu_hi = floor(mu / 64.0);
	COLOR = vec4(mu_hi, mu - mu_hi * 64.0, trap, coverage);
}
