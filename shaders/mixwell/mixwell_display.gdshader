shader_type canvas_item;
render_mode unshaded;

uniform sampler2D display_tex : filter_linear, repeat_disable;
uniform sampler2D source_tex : filter_linear, repeat_disable;
uniform sampler2D diagnostic_tex : filter_linear, repeat_disable;
uniform int display_mode = 0;
uniform int comparison_mode = 0;


vec3 heat(float value) {
	float t = clamp(value, 0.0, 1.0);
	return vec3(
		clamp(1.5 * t, 0.0, 1.0),
		clamp(1.5 - abs(2.0 * t - 1.0) * 1.5, 0.0, 1.0),
		clamp(1.5 * (1.0 - t), 0.0, 1.0));
}


void fragment() {
	vec4 result = texture(display_tex, UV);
	vec4 source = texture(source_tex, UV);
	vec4 diagnostic = texture(diagnostic_tex, UV);
	if (comparison_mode == 1) {
		if (UV.x < 0.5) {
			COLOR = texture(source_tex, vec2(UV.x * 2.0, UV.y));
		} else {
			COLOR = texture(display_tex, vec2((UV.x - 0.5) * 2.0, UV.y));
		}
	} else if (display_mode == 1) {
		COLOR = source;
	} else if (display_mode == 2) {
		COLOR = vec4(heat(diagnostic.z * 6.0), 1.0);
	} else if (display_mode == 3) {
		vec2 vector_value = diagnostic.xy;
		float magnitude = clamp(length(vector_value) * 5.0, 0.0, 1.0);
		COLOR = vec4(vec3(0.5) + vec3(vector_value, 0.0) * 0.5, 1.0);
		COLOR.rgb = mix(vec3(0.04), COLOR.rgb, magnitude);
	} else if (display_mode == 4) {
		COLOR = vec4(heat(abs(diagnostic.w) * 40.0), 1.0);
	} else {
		COLOR = result;
	}
}
