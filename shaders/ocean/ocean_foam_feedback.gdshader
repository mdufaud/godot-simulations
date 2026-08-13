shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D previous_foam : filter_linear, repeat_disable;
uniform sampler2D injection_mask : filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(0.001953125);
uniform vec2 scroll_uv = vec2(0.0);
uniform float decay = 0.98;
uniform float blur_amount = 0.1;
uniform float injection_strength = 0.2;

float previous_at(vec2 uv) {
	vec2 inside = step(vec2(0.0), uv) * step(uv, vec2(1.0));
	return texture(previous_foam, clamp(uv, vec2(0.0), vec2(1.0))).r * inside.x * inside.y;
}

void fragment() {
	vec2 previous_uv = UV + scroll_uv;
	float history = previous_at(previous_uv);
	float spread = previous_at(previous_uv + vec2(texel_size.x, 0.0))
		+ previous_at(previous_uv - vec2(texel_size.x, 0.0))
		+ previous_at(previous_uv + vec2(0.0, texel_size.y))
		+ previous_at(previous_uv - vec2(0.0, texel_size.y));
	spread *= 0.25;
	history = mix(history, spread, blur_amount) * decay;

	vec2 ring_texel = texel_size * 2.5;
	float mask_center = texture(injection_mask, UV).r;
	float mask_min = mask_center;
	float mask_max = mask_center;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float sample_mask = texture(injection_mask,
				UV + vec2(float(x), float(y)) * ring_texel).r;
			mask_min = min(mask_min, sample_mask);
			mask_max = max(mask_max, sample_mask);
		}
	}
	float ring = smoothstep(0.04, 0.65, mask_max - mask_min);
	float foam = max(history, ring * injection_strength);
	COLOR = vec4(foam, foam, foam, foam);
}
