shader_type spatial;
render_mode cull_disabled;

// Leaf cards for procedural trees: procedural leaf-blob alpha mask
// (alpha scissor: stays in the opaque pass), two-octave wind sway with a rigid
// per-quad phase (quad center packed in UV2), grass-style SSS backlighting.
// Low-poly: solid quads, quantized vertex color, no SSS.

uniform bool low_poly = false;
uniform float wind_strength = 1.0;
uniform vec3 sss_color : source_color = vec3(0.7, 0.85, 0.3);

varying float instance_hash;

float hash12(vec2 x) {
	uvec2 p = floatBitsToUint(x);
	p = 1103515245U * ((p >> 1U) ^ (p.yx));
	uint h32 = 1103515245U * ((p.x) ^ (p.y >> 3U));
	uint n = h32 ^ (h32 >> 16U);
	return float(n) * (1.0 / float(0xffffffffU));
}

void vertex() {
	instance_hash = hash12(MODEL_MATRIX[3].xz);
	float quad_phase = hash12(UV2) * 6.28;
	float phase = instance_hash * 6.28 + quad_phase;
	float sway = sin(TIME * 1.6 + phase) * 0.06 + sin(TIME * 3.7 + phase * 1.7) * 0.025;
	sway *= wind_strength;
	VERTEX.x += sway;
	VERTEX.z += sway * 0.7;
	VERTEX.y += cos(TIME * 2.3 + phase) * 0.02 * wind_strength;
}

void fragment() {
	float alpha = 1.0;
	if (!low_poly) {
		// Three elliptical lobes make an irregular leaf-tuft silhouette.
		vec2 uv = UV - 0.5;
		float d1 = length((uv - vec2(-0.12, -0.08)) * vec2(2.6, 3.4));
		float d2 = length((uv - vec2(0.15, 0.05)) * vec2(3.0, 2.5));
		float d3 = length((uv - vec2(-0.02, 0.16)) * vec2(3.5, 2.8));
		alpha = float(min(d1, min(d2, d3)) < 0.5);
	}

	vec3 c = COLOR.rgb;
	if (low_poly) {
		float lum = dot(c, vec3(0.33));
		ALBEDO = c * (1.1 + floor(lum * 4.0) / 4.0 * 0.6);
		ROUGHNESS = 1.0;
	} else {
		ALBEDO = c * (0.85 + instance_hash * 0.3);
		ROUGHNESS = 0.85;
	}
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}

void light() {
	if (low_poly) {
		DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.15, 1.0) * ATTENUATION * LIGHT_COLOR;
	} else {
		// Diffuse floor fakes canopy ambient bounce; view-aligned backlight = SSS.
		float diffuse_factor = pow(4.0, dot(NORMAL, LIGHT)) / 4.0;
		float sss_factor = max(-dot(VIEW, LIGHT), 0.0) * 0.2;
		DIFFUSE_LIGHT += (diffuse_factor + sss_factor * sss_color) * ATTENUATION * LIGHT_COLOR;
	}
}
