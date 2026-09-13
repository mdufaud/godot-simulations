shader_type particles;
// Dust/sand advected by the analytic wind field (same math as debris and funnel).
// skirt_mode 1 = ground debris-cloud bowl, 0 = column sheath.

#include "res://shaders/tornado/tornado_wind.gdshaderinc"

uniform int skirt_mode = 0;
uniform vec3 particle_color : source_color = vec3(0.55, 0.42, 0.28);
uniform float size_min = 0.5;
uniform float size_max = 2.6;
uniform float follow = 3.0;
// Camera-driven distance fade, INWARD this time: a 2 m billboard at 400+ m
// spans ~3 px and aliases into a white dot. Any particle system advected by
// the wind converges on the core band, so at mid-range those dots stack into
// a dotted pillar veiling the neck. Real dust is sub-pixel there — fade the
// sprites out past ~150 m and let the volumetric funnel carry the look.
uniform vec3 camera_position = vec3(0.0, 80.0, 1000.0);
uniform float fade_start = 150.0;
uniform float fade_end = 480.0;

float hash1(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

void start() {
	uint seed = RANDOM_SEED + uint(INDEX) * 747796405u;
	float r1 = hash1(seed);
	float r2 = hash1(seed + 1u);
	float r3 = hash1(seed + 2u);
	float r4 = hash1(seed + 3u);

	float y;
	float rad;
	if (skirt_mode == 1) {
		y = r1 * r1 * 0.08 * funnel_height;
		rad = r_core0 * mix(0.2, 2.6, sqrt(r2));
	} else {
		// Sheath spawns above 30% height only: below that, the volumetric
		// funnel and the dust bowl own the base. Particles advected into the
		// neck band paint a dotted veil right over it (screen-space, any
		// radius) — the one defect every steady-state capture kept showing.
		y = mix(0.3, 0.98, pow(r1, 1.4)) * funnel_height;
		float y01 = y / max(funnel_height, 1.0);
		rad = tw_core_radius(y) * mix(0.55, 1.35, r2)
			+ (1.0 - y01) * (1.0 - y01) * r_core0 * mix(0.3, 1.6, r2);
	}
	float ang = r3 * 6.2831853;
	vec3 c = tw_centerline(y);
	vec3 pos = vec3(c.x + cos(ang) * rad, y, c.z + sin(ang) * rad);

	TRANSFORM[3].xyz = pos;
	float s = mix(size_min, size_max, r4 * r4);
	TRANSFORM[0].xyz = vec3(s, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, s, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, s);
	CUSTOM.x = 0.7 + 0.6 * hash1(seed + 4u);
	CUSTOM.y = r4;
	VELOCITY = tw_wind(pos) * CUSTOM.x;
}

void process() {
	vec3 pos = TRANSFORM[3].xyz;
	vec3 w = tw_wind(pos) * CUSTOM.x;
	// Relax toward the local wind: particles lag slightly, like heavy dust.
	VELOCITY = mix(VELOCITY, w, clamp(DELTA * follow, 0.0, 1.0));
	if (skirt_mode == 1) {
		VELOCITY.y -= 6.0 * DELTA;
	}

	// Steady-state guard: the wind field converges on the core radius, so any
	// sheath particle drifting into the neck band stacks into the dotted veil
	// that hides the lower funnel. Kill it — the base belongs to the volume.
	if (skirt_mode == 0 && pos.y < 0.28 * funnel_height) {
		ACTIVE = false;
	}

	float y01 = clamp(pos.y / funnel_height, 0.0, 1.0);
	float fade_top = 1.0 - smoothstep(0.75, 1.0, y01);
	float fade_life = sin(clamp(CUSTOM.w / LIFETIME, 0.0, 1.0) * 3.14159265);
	float fade_dist = 1.0 - smoothstep(fade_start, fade_end, length(pos - camera_position));
	float shade = mix(0.85, 0.3, y01);
	// Low per-particle alpha: at spawn distance each billboard spans a few
	// pixels, and anything denser turns the column sheath into a dotted pillar
	// of dots. Faint and many reads as haze.
	COLOR = vec4(particle_color * shade, 0.13 * fade_top * fade_life * fade_dist);
	CUSTOM.w += DELTA;

	if (length(w) < 0.3 || pos.y > funnel_height || pos.y < -1.0) {
		ACTIVE = false;
	}
}
