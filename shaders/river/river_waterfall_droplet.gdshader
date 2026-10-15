shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;

uniform sampler2D noise_texture : filter_linear_mipmap, repeat_enable;
uniform float opacity = 0.9;
varying float seed;
varying vec3 side_view;

void vertex() {
	seed = fract(float(INSTANCE_ID) * 0.754877);
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 axis = MODEL_MATRIX[1].xyz;
	float size = max(length(axis), 0.0001);
	axis /= size;
	vec3 side = cross(axis, normalize(CAMERA_POSITION_WORLD - center));
	side = length(side) > 0.0001 ? normalize(side) : normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 facing = cross(side, axis);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(side * size, 0.0), vec4(axis * size, 0.0), vec4(facing * size, 0.0), vec4(center, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	side_view = normalize(MODELVIEW_MATRIX[0].xyz);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float width = mix(1.0, 0.2, UV.y);
	float body = smoothstep(0.0, 0.5, 1.0 - abs(p.x) / width) * (1.0 - smoothstep(0.75, 1.0, abs(p.y)));
	float clumps = texture(noise_texture, vec2(UV.x * 0.3 + seed * 5.0, UV.y * 0.8 + seed * 3.0)).r;
	float density = body * smoothstep(0.35, 0.6, clumps + (1.0 - UV.y) * 0.3);
	NORMAL = normalize(NORMAL + side_view * p.x * 0.8);
	ALBEDO = vec3(0.85, 0.92, 0.95);
	ROUGHNESS = 0.15;
	SPECULAR = 0.6;
	ALPHA = density * opacity * COLOR.a;
}
