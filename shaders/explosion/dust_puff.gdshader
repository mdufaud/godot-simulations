shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_lambert, specular_disabled;

uniform vec3 dust_color : source_color = vec3(0.55, 0.48, 0.38);
uniform float seed_spread = 37.0;
// Metres over which a puff fades out against the ground and props it intersects.
uniform float soft_m = 0.6;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying float v_seed;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	v_seed = fract(sin(dot(MODEL_MATRIX[3].xyz, vec3(12.9898, 78.233, 37.719))) * 43758.5453) * seed_spread;
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sx, INV_VIEW_MATRIX[1] * sy, INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float billow = vnoise(p * 2.5 + v_seed) * 0.6 + vnoise(p * 6.0 + v_seed * 1.7) * 0.4;
	float shape = smoothstep(1.0, 0.15, r + (billow - 0.5) * 0.7);
	ALBEDO = dust_color * (0.8 + 0.4 * billow);
	ROUGHNESS = 1.0;
	vec4 ndc = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, texture(depth_tex, SCREEN_UV).r, 1.0);
	float scene_depth = -ndc.z / ndc.w;
	float soft = clamp((scene_depth - (-VERTEX.z)) / soft_m, 0.0, 1.0);
	ALPHA = clamp(shape * COLOR.a * soft, 0.0, 1.0);
}
