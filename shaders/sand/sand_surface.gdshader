// Sand surface over the heightfield texture: the vertex shader displaces a
// flat grid mesh (COLOR.r masks the skirt ring to the floor so the sheet has
// closed sides), the fragment shader rebuilds normals from the height texture
// so shading resolves finer than the mesh. The sand look is procedural: a
// low-frequency tone wander, per-millimetre speckle, darker avalanche faces,
// and sparse specular glints — all faded with distance to avoid shimmer.
shader_type spatial;
// Normals come from the height texture, not the winding, so culling buys
// nothing and the skirt ring is visible from either side.
render_mode cull_disabled;

uniform sampler2D height_tex : filter_linear, repeat_disable, hint_default_black;
uniform float world_size = 4.0;
uniform float grid_n = 512.0;
uniform vec3 color_light : source_color = vec3(0.88, 0.75, 0.53);
uniform vec3 color_dark : source_color = vec3(0.62, 0.46, 0.29);

varying vec3 world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

void vertex() {
	float h = texture(height_tex, UV).r;
	VERTEX.y = h * COLOR.r;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float texel = 1.0 / grid_n;
	float cell = world_size / grid_n;
	float hl = texture(height_tex, UV - vec2(texel, 0.0)).r;
	float hr = texture(height_tex, UV + vec2(texel, 0.0)).r;
	float hd = texture(height_tex, UV - vec2(0.0, texel)).r;
	float hu = texture(height_tex, UV + vec2(0.0, texel)).r;
	vec3 n_world = normalize(vec3(hl - hr, 2.0 * cell, hd - hu));

	vec2 g = world_pos.xz;
	// Fade world-anchored grain detail as it drops under a pixel.
	float fw = fwidth(g.x + g.y) * 700.0;
	float detail = 1.0 / (1.0 + fw * fw * 0.15);

	// Micro-relief: two noise octaves bump the normal so close-ups don't look
	// like smooth dough — clumps at ~2 cm, grain-scale rough at ~4 mm. Finite
	// differences at roughly half a noise cell give a coherent gradient.
	float c1 = vnoise(g * 55.0);
	float c2 = vnoise(g * 260.0);
	float e1 = 0.008;
	float e2 = 0.0018;
	vec2 slope = vec2(
		(vnoise((g + vec2(e1, 0.0)) * 55.0) - c1) * 0.5 + vnoise((g + vec2(e2, 0.0)) * 260.0) - c2,
		(vnoise((g + vec2(0.0, e1)) * 55.0) - c1) * 0.5 + vnoise((g + vec2(0.0, e2)) * 260.0) - c2
	);
	n_world = normalize(n_world + vec3(slope.x, 0.0, slope.y) * 0.9 * detail);
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	float macro = vnoise(g * 1.7) * 0.6 + vnoise(g * 6.3) * 0.4;
	float speck = hash(floor(g * 700.0));
	float tone = 0.55 + 0.30 * (macro - 0.5) + 0.55 * (speck - 0.5) * detail;
	vec3 albedo = mix(color_dark, color_light, clamp(tone, 0.0, 1.0));

	// Freshly slumped faces read darker, like the shaded flank of a dune.
	float steep = 1.0 - n_world.y;
	albedo *= 1.0 - 0.30 * smoothstep(0.04, 0.35, steep);

	float glint = hash(floor(g * 900.0) + vec2(7.31, 3.77));
	float sparkle = step(0.994, glint) * detail;
	ALBEDO = albedo + vec3(0.35) * sparkle;
	ROUGHNESS = mix(0.94, 0.35, sparkle);
	SPECULAR = 0.2;
}
