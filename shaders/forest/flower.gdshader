shader_type spatial;
render_mode cull_disabled;

// Crossed-quad flowers: procedural petal/stem mask, per-instance petal color
// via INSTANCE_CUSTOM, gentle wind sway. UV y=0 is the top of the quad.

uniform bool low_poly = false;
uniform float wind_strength = 1.0;
uniform vec3 stem_color : source_color = vec3(0.10, 0.25, 0.05);
uniform vec3 heart_color : source_color = vec3(0.9, 0.75, 0.15);

varying vec3 petal_color;

float hash12(vec2 x) {
	uvec2 p = floatBitsToUint(x);
	p = 1103515245U * ((p >> 1U) ^ (p.yx));
	uint h32 = 1103515245U * ((p.x) ^ (p.y >> 3U));
	uint n = h32 ^ (h32 >> 16U);
	return float(n) * (1.0 / float(0xffffffffU));
}

void vertex() {
	petal_color = INSTANCE_CUSTOM.rgb;
	float phase = hash12(MODEL_MATRIX[3].xz) * 6.28;
	float top_factor = 1.0 - UV.y;
	float sway = sin(TIME * 1.8 + phase) * 0.04 * wind_strength * top_factor;
	VERTEX.x += sway;
	VERTEX.z += sway * 0.6;
}

void fragment() {
	vec2 uv = UV;
	float alpha = 0.0;
	vec3 color = stem_color;

	// Stem: narrow strip on the lower two thirds.
	if (abs(uv.x - 0.5) < 0.035 && uv.y > 0.3) {
		alpha = 1.0;
	}

	// Flower head: petal rosette around (0.5, 0.22).
	vec2 d = (uv - vec2(0.5, 0.22)) * vec2(1.0, 1.15);
	float r = length(d);
	float theta = atan(d.y, d.x);
	float petal_r = 0.20 * (0.55 + 0.45 * abs(cos(theta * 2.5)));
	if (r < petal_r) {
		alpha = 1.0;
		color = petal_color;
	}
	if (r < 0.055) {
		color = heart_color;
	}

	ALBEDO = color;
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.8;
	if (!low_poly) {
		// Petals glow slightly in direct light.
		EMISSION = color * 0.04;
	}
}
