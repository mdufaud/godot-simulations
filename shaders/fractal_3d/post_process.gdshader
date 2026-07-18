shader_type canvas_item;

uniform float aberration_strength : hint_range(0.0, 0.02) = 0.0015;
uniform float vignette_strength : hint_range(0.0, 2.0) = 0.35;
uniform float grain_strength : hint_range(0.0, 0.2) = 0.015;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

float hash(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 center_dir = uv - vec2(0.5);

	vec2 offset = center_dir * aberration_strength;
	float r = textureLod(SCREEN_TEXTURE, uv - offset, 0.0).r;
	float g = textureLod(SCREEN_TEXTURE, uv, 0.0).g;
	float b = textureLod(SCREEN_TEXTURE, uv + offset, 0.0).b;
	vec3 col = vec3(r, g, b);

	float vignette = 1.0 - vignette_strength * dot(center_dir, center_dir);
	col *= clamp(vignette, 0.0, 1.0);

	float grain = (hash(uv + fract(TIME)) - 0.5) * grain_strength;
	col += grain;

	COLOR = vec4(col, 1.0);
}
