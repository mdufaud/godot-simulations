shader_type spatial;

// Bark for procedural trees. Photoreal: PBR maps + per-instance tint.
// Low-poly: quantized vertex color + screen-space face normals.

uniform bool low_poly = false;
uniform bool use_textures = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D arm_tex : hint_default_white, filter_linear_mipmap;
uniform vec3 fallback_color : source_color = vec3(0.25, 0.19, 0.13);
uniform float wind_strength = 1.0;

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
	// Subtle trunk sway, growing with height.
	float h = clamp(VERTEX.y * 0.1, 0.0, 1.0);
	float phase = instance_hash * 6.28;
	VERTEX.x += sin(TIME * 0.9 + phase) * h * h * 0.05 * wind_strength;
	VERTEX.z += cos(TIME * 0.7 + phase) * h * h * 0.04 * wind_strength;
}

void fragment() {
	if (low_poly) {
		vec3 face_n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
		if (face_n.z < 0.0) {
			face_n = -face_n;
		}
		NORMAL = face_n;
		vec3 c = COLOR.rgb;
		float lum = dot(c, vec3(0.33));
		ALBEDO = c * (0.9 + floor(lum * 4.0) / 4.0 * 0.5);
		ROUGHNESS = 1.0;
	} else {
		float tint = 0.85 + instance_hash * 0.3;
		if (use_textures) {
			vec2 uv = UV * vec2(1.0, 1.0);
			ALBEDO = texture(albedo_tex, uv).rgb * tint;
			NORMAL_MAP = texture(normal_tex, uv).rgb;
			vec3 arm = texture(arm_tex, uv).rgb;
			AO = arm.r;
			AO_LIGHT_AFFECT = 0.5;
			ROUGHNESS = arm.g;
		} else {
			ALBEDO = fallback_color * tint;
			ROUGHNESS = 0.9;
		}
	}
}
