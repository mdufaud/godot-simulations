shader_type spatial;
render_mode cull_disabled;

// Branch cards for scanned conifers: crossed quads textured with a real
// needle-branch sample rendered to RGBA at load. Alpha scissor keeps them in
// the opaque pass; sway matches the scanned foliage shader.

uniform sampler2D card_tex : source_color, filter_linear_mipmap;
uniform float wind_strength = 1.0;
uniform float height_ref = 15.0;
uniform vec3 backlight_color : source_color = vec3(0.35, 0.42, 0.16);

varying float ihash;

float hash12(vec2 x) {
	uvec2 p = floatBitsToUint(x);
	p = 1103515245U * ((p >> 1U) ^ (p.yx));
	uint h32 = 1103515245U * ((p.x) ^ (p.y >> 3U));
	uint n = h32 ^ (h32 >> 16U);
	return float(n) * (1.0 / float(0xffffffffU));
}

void vertex() {
	ihash = hash12(MODEL_MATRIX[3].xz);
	float rel = clamp(VERTEX.y / max(height_ref, 0.001), 0.0, 1.0);
	float phase = ihash * 6.283 + VERTEX.y * 0.6;
	float gust = sin(TIME * 0.9 + phase) + 0.45 * sin(TIME * 2.1 + phase * 1.7);
	float amp = wind_strength * rel * rel * 0.09;
	VERTEX.x += gust * amp;
	VERTEX.z += gust * amp * 0.6;
}

void fragment() {
	vec4 c = texture(card_tex, UV);
	ALBEDO = c.rgb * (0.85 + ihash * 0.3);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.4;
	ROUGHNESS = 0.9;
	SPECULAR = 0.15;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}

void light() {
	// Card normals are fabricated (outward+up): wrapped diffuse keeps the
	// canopy lit from any view, view-aligned backlight fakes needle SSS.
	float wrap = pow(2.6, dot(NORMAL, LIGHT)) / 2.6;
	float sss = max(-dot(VIEW, LIGHT), 0.0) * 0.15;
	DIFFUSE_LIGHT += (wrap + sss * backlight_color) * ATTENUATION * LIGHT_COLOR;
}
