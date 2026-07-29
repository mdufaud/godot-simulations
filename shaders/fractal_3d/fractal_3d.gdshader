shader_type spatial;
render_mode world_vertex_coords, unshaded, cull_front, depth_test_disabled;
// Raymarch inside a large box. Ray origin = camera world pos, dir toward the
// interpolated world vertex. VR-correct: each XR eye renders the same world-space
// field with its own pose. Distance estimators below are established formulas
// (iq/Apollonian & Menger, Jos Leys & Knighty/JosKleinian), not invented.
// Do not diverge from
// scripts/fractal_3d/fractal_de.gd (CPU mirror).

// 0 Apollonian, 1 Menger (infinite), 2 Kleinian (Jos Leys)
uniform int fractal_type : hint_range(0, 2) = 0;
uniform int iterations : hint_range(2, 40) = 12;

uniform int max_steps : hint_range(30, 1200) = 480;
uniform float max_dist : hint_range(5.0, 200.0) = 60.0;
// Relative epsilon factor: hit tolerance = max(epsilon*t, 5e-5). Fine near, coarse far.
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

// ---- Distance estimators. trap = orbit trap (min over iters of abs(z), r2). ----

float de_apollonian(vec3 p, bool track_trap, out vec4 trap) {
	vec3 z = p;
	float s = 1.0;
	trap = vec4(1e10);
	for (int i = 0; i < 40; i++) {
		if (i >= iterations) break;
		z = -1.0 + 2.0 * fract(0.5 * z + 0.5);
		float r2 = max(dot(z, z), 1e-9);
		if (track_trap) trap = min(trap, vec4(abs(z), r2));
		float k = apollonian_scale / r2;
		z *= k;
		s *= k;
	}
	return 0.25 * abs(z.y) / max(abs(s), 1e-9);
}

float de_menger(vec3 p, bool track_trap, out vec4 trap) {
	// No bounding box: the mod() grid is periodic, so the sponge tiles all of
	// space — an infinite lattice of tunnels ("Menger Journey" style).
	float d = -1e10;
	float s = 1.0;
	trap = vec4(1e10);
	for (int i = 0; i < 10; i++) {
		if (i >= iterations) break;
		vec3 a = mod(p * s, 2.0) - 1.0;
		s *= 3.0;
		vec3 r = abs(1.0 - 3.0 * abs(a));
		if (track_trap) trap = min(trap, vec4(abs(a), dot(a, a)));
		float c = (min(max(r.x, r.y), min(max(r.y, r.z), max(r.z, r.x))) - 1.0) / s;
		d = max(d, c);
	}
	return d;
}

vec2 klein_wrap(vec2 x, vec2 a, vec2 s) {
	x -= s;
	return (x - a * floor(x / a)) + s;
}

float de_jos_kleinian(vec3 p, bool track_trap, out vec4 trap) {
	// JosKleinian (Jos Leys & Knighty; shadertoy XlVXzh / Fragmentarium Knighty
	// Collection). Shear + wrap + separation-line fold + sphere inversion
	// (TransA). DF uses the conservative max(1,iR) variant from the source.
	vec3 z = p;
	vec3 lz = z + vec3(1.0);
	vec3 llz = z + vec3(-1.0);
	float DF = 1.0;
	float a = klein_r;
	float b = klein_i;
	float f = sign(b);
	trap = vec4(1e10);
	for (int i = 0; i < 40; i++) {
		if (i >= iterations) break;
		z.x += b / a * z.y;
		z.xz = klein_wrap(z.xz, vec2(2.0 * klein_box_x, 2.0 * klein_box_z),
				vec2(-klein_box_x, -klein_box_z));
		z.x -= b / a * z.y;
		if (z.y >= a * 0.5 + f * (2.0 * a - 1.95) / 4.0 * sign(z.x + b * 0.5)
				* (1.0 - exp(-(7.2 - (1.95 - a) * 15.0) * abs(z.x + b * 0.5)))) {
			z = vec3(-b, a, 0.0) - z;
		}
		float iR = 1.0 / max(dot(z, z), 1e-12);
		z *= -iR;
		z.x = -b - z.x;
		z.y = a + z.y;
		DF *= max(1.0, iR);
		if (track_trap) trap = min(trap, vec4(abs(z), dot(z, z)));
		if (dot(z - llz, z - llz) < 1e-5) break;
		llz = lz;
		lz = z;
	}
	float y = min(z.y, a - z.y);
	return min(y, 0.3) / max(DF, 2.0);
}

float scene(vec3 p, bool track_trap, out vec4 trap) {
	if (fractal_type == 0) return de_apollonian(p, track_trap, trap);
	if (fractal_type == 1) return de_menger(p, track_trap, trap);
	return de_jos_kleinian(p, track_trap, trap);
}

float scene_d(vec3 p) {
	vec4 t;
	return scene(p, false, t);
}

float hit_epsilon(float t) {
	return max(max(epsilon, pixel_angle * pixel_tolerance) * max(t, 0.01), 2e-6);
}

vec3 calc_normal(vec3 p, float t) {
	float e = max(hit_epsilon(t) * 2.0, pixel_angle * max(t, 0.01) * 0.12);
	vec2 k = vec2(1.0, -1.0);
	return normalize(
		k.xyy * scene_d(p + k.xyy * e) +
		k.yyx * scene_d(p + k.yyx * e) +
		k.yxy * scene_d(p + k.yxy * e) +
		k.xxx * scene_d(p + k.xxx * e));
}

float calc_ao(vec3 p, vec3 n) {
	float ao = 0.0;
	float w = 1.0;
	float dist = 0.01;
	for (int i = 0; i < 5; i++) {
		if (i >= ao_samples) break;
		float d = scene_d(p + n * dist);
		ao += w * (dist - d);
		w *= 0.5;
		dist *= 1.9;
	}
	return clamp(1.0 - ao * 1.2, 0.0, 1.0);
}

void fragment() {
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 rd = normalize(world_pos - ro);

	float t = 0.0;
	float d = 0.0;
	bool hit = false;
	for (int i = 0; i < 1200; i++) {
		if (i >= max_steps) break;
		vec3 p = ro + rd * t;
		d = scene_d(p);
		float eps = hit_epsilon(t);
		if (d < eps) { hit = true; break; }
		t += max(d * 0.75, 1e-6);
		if (t > max_dist) break;
	}

	vec3 col;
	if (hit) {
		vec3 p = ro + rd * t;
		vec4 trap;
		scene(p, true, trap);
		vec3 n = calc_normal(p, t);
		float ot = clamp(sqrt(trap.w) * 0.6, 0.0, 1.0);
		float fres = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), 3.0);
		float phase = ot * 1.2 + fres * 0.8 + TIME * color_speed * 0.15 + color_offset;
		vec3 base = palette_color(palette, phase);

		vec3 ld = normalize(vec3(0.5, 0.8, 0.4));
		float diff = max(dot(n, ld), 0.0) * 0.7 + 0.3;
		vec3 h = normalize(ld - rd);
		float spec = pow(max(dot(n, h), 0.0), 32.0) * 0.5;
		float ao = calc_ao(p, n);

		col = base * diff * ao + vec3(spec);
		col += base * fres * 0.5;                      // iridescent rim

		float fog = 1.0 - exp(-t * 0.03);
		col = mix(col, vec3(0.02, 0.01, 0.05), fog * 0.6);
		EMISSION = max(col - vec3(0.72), vec3(0.0)) * glow_strength * 0.35;
	} else {
		float sky = rd.y * 0.5 + 0.5;
		col = mix(vec3(0.02, 0.01, 0.06), vec3(0.04, 0.02, 0.10), sky);
	}
	ALBEDO = col;
}
