shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;

uniform sampler2D noise_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform vec3 tint : source_color = vec3(0.92, 0.95, 0.97);
uniform float opacity = 0.6;
uniform float churn_per_s = 0.08;
uniform float soft_fade_m = 0.8;
uniform float wrap_light = 0.6;
uniform float glow = 0.1;
uniform float rainbow_strength = 0.0;
varying vec2 seed;

void vertex() {
	seed = vec2(fract(float(INSTANCE_ID) * 0.6180339), fract(float(INSTANCE_ID) * 0.7548777));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float drift = TIME * churn_per_s;
	float slow = texture(noise_texture, UV * 0.3 + seed * 5.0 + vec2(0.0, drift)).r;
	float fast = texture(noise_texture, UV * 0.6 - seed * 3.0 + vec2(drift * 0.7, -drift * 1.3)).r;
	float churn = slow * 0.65 + fast * 0.35;
	float body = 1.0 - smoothstep(0.15, 1.0, length(p) + (churn - 0.5) * 0.7);
	float scene_depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	float soft = clamp((VERTEX.z - scene.z / scene.w) / soft_fade_m, 0.0, 1.0) * smoothstep(0.5, 2.0, -VERTEX.z);
	NORMAL = normalize(vec3(p * 0.7, 1.0));
	ALBEDO = tint * mix(0.88, 1.0, churn);
	EMISSION = tint * glow;
	ALPHA = body * opacity * COLOR.a * soft;
}

void light() {
	float wrap = clamp((dot(NORMAL, LIGHT) + wrap_light) / (1.0 + wrap_light), 0.0, 1.0);
	float forward = pow(clamp(dot(-VIEW, LIGHT), 0.0, 1.0), 8.0);
	DIFFUSE_LIGHT += (wrap + forward * 1.5) * LIGHT_COLOR * ATTENUATION / PI;
	if (LIGHT_IS_DIRECTIONAL && rainbow_strength > 0.0) {
		float angle = degrees(acos(clamp(dot(VIEW, LIGHT), -1.0, 1.0)));
		float t = (angle - 40.0) / 2.5;
		float band = smoothstep(-0.25, 0.1, t) * (1.0 - smoothstep(0.9, 1.25, t));
		float hue = (1.0 - clamp(t, 0.0, 1.0)) * 0.75;
		vec3 spectrum = clamp(abs(fract(hue + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
		DIFFUSE_LIGHT += spectrum * band * rainbow_strength * LIGHT_COLOR * ATTENUATION / PI;
	}
}
