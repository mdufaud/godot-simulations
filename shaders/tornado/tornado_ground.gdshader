shader_type spatial;
// Ground that belongs to its storm. Shaded by the per-look environment and
// re-graded per storm_type from the controller — the old unshaded constant
// slab ignored ambient, fog and shadows, so it read as a pasted rectangle
// under every tornado type. Horizon melt is left to engine fog, whose color
// already follows the look on purpose.
render_mode cull_back;

uniform int storm_type = 0; // 0 normal, 1 fire, 2 water, 3 ice, 4 plasma
uniform vec3 sun_dir = vec3(-0.5, 0.0, -0.6); // world, sun -> scene (funnel convention)
uniform vec3 ground_a : source_color = vec3(0.27, 0.235, 0.19); // base tone
uniform vec3 ground_b : source_color = vec3(0.185, 0.17, 0.15); // variation tone
uniform vec3 ground_accent : source_color = vec3(0.14, 0.135, 0.13); // collar / ember / foam / veins
uniform float ground_glow : hint_range(0.0, 1.0) = 0.0;
uniform vec3 vortex_pos = vec3(0.0);
uniform float vortex_radius = 45.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int k = 0; k < 4; k++) {
		v += amp * vnoise(p);
		p = p * 2.03 + vec2(17.3, 9.1);
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 q = v_world.xz;
	// VERTEX is view-space: length is the camera distance. Noise detail dies
	// with it so the grazing far field cannot shimmer; past the fade the
	// ground is a flat tone for fog to swallow.
	float dist = length(VERTEX);
	float detail = 1.0 - smoothstep(600.0, 2600.0, dist);

	float rf = max(length(q - vortex_pos.xz), 0.001);
	float r0 = max(vortex_radius, 10.0);
	float foot = exp(-rf / (2.2 * r0));
	float ring = exp(-rf / (7.0 * r0));

	vec3 albedo = ground_a;
	float rough = 1.0;
	vec3 emission = vec3(0.0);
	if (storm_type == 1) {
		// Scorched crust: char with ash patches; embers breathe in the
		// cracks, strongest around the foot.
		float crust = fbm(q * 0.05);
		albedo = mix(ground_a, ground_b, smoothstep(0.35, 0.75, crust));
		float cracks = smoothstep(0.62, 0.78, fbm(q * 0.22 + vec2(3.7)));
		emission = ground_accent * cracks * ground_glow * (0.25 + 0.75 * foot)
			* (0.7 + 0.3 * sin(TIME * 2.3 + crust * 6.0));
	} else if (storm_type == 2) {
		// Churned sea: swells drift toward the vortex, foam collar at the
		// foot, low roughness so the sun lays a glint on the water.
		vec2 to_v = (vortex_pos.xz - q) / rf;
		float swell = fbm((q * 0.03 - to_v * TIME * 0.35) * 2.0);
		albedo = mix(ground_a, ground_b, smoothstep(0.3, 0.8, swell));
		float foam = smoothstep(0.55, 0.8, fbm(q * 0.14 - to_v * TIME * 0.9)) * ring;
		albedo = mix(albedo, ground_accent, foam * 0.85);
		emission = ground_accent * foam * ground_glow * 0.4;
		rough = 0.12;
		if (detail > 0.01) {
			// Ripple normals from the swell gradient, faded with detail.
			float e = 1.2;
			float hx = fbm(((q + vec2(e, 0.0)) * 0.03 - to_v * TIME * 0.35) * 2.0);
			float hz = fbm(((q + vec2(0.0, e)) * 0.03 - to_v * TIME * 0.35) * 2.0);
			vec3 nw = normalize(vec3((swell - hx) / e * 0.6, 1.0, (swell - hz) / e * 0.6));
			NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
		}
	} else if (storm_type == 3) {
		// Snow field scoured toward blue in the hollows, wind-blasted bright
		// around the foot. No glints: a hashed cell lights up as a whole
		// square, which grazing angles squash into floating white bars.
		float drift = fbm(q * 0.045);
		albedo = mix(ground_b, ground_a, smoothstep(0.25, 0.75, drift));
		albedo = mix(albedo, ground_accent, foot * 0.4);
		rough = 0.75;
	} else if (storm_type == 4) {
		// Dark basalt under violet energy; veins crawl and concentrate at
		// the foot.
		float rock = fbm(q * 0.06);
		albedo = mix(ground_a, ground_b, smoothstep(0.3, 0.75, rock));
		float veins = smoothstep(0.66, 0.8, fbm(q * 0.11 + vec2(11.0, 5.0)));
		emission = ground_accent * veins * ground_glow * (0.3 + 0.7 * foot)
			* (0.75 + 0.25 * sin(TIME * 1.7 + rock * 9.0));
		rough = 0.9;
	} else {
		// Storm-muted prairie: two-tone dirt with clods and a debris collar
		// darkening toward the core.
		float patch = fbm(q * 0.035);
		float clods = fbm(q * 0.21);
		albedo = mix(ground_b, ground_a, smoothstep(0.25, 0.8, patch));
		albedo *= 0.9 + 0.2 * clods;
		albedo = mix(albedo, ground_accent, ring * 0.5);
	}

	albedo = mix((ground_a + ground_b) * 0.5, albedo, detail);
	// Depth cue on top of fog: the far plane darkens toward the horizon so
	// sky and ground separate without a hard line.
	albedo *= mix(1.0, 0.55, smoothstep(1400.0, 4300.0, dist));
	ALBEDO = albedo;
	ROUGHNESS = rough;
	EMISSION = emission;
}
