shader_type spatial;
render_mode unshaded;

uniform sampler2D position_tex : filter_nearest;
uniform int tex_width = 256;
uniform float point_size = 0.06;

varying float speed;

void vertex() {
	ivec2 texel = ivec2(INSTANCE_ID % tex_width, INSTANCE_ID / tex_width);
	vec4 data = texelFetch(position_tex, texel, 0);
	speed = data.w;
	vec3 cam_right = INV_VIEW_MATRIX[0].xyz;
	vec3 cam_up = INV_VIEW_MATRIX[1].xyz;
	VERTEX = data.xyz + (cam_right * VERTEX.x + cam_up * VERTEX.y) * (point_size / 0.08);
}

void fragment() {
	vec2 cuv = UV * 2.0 - 1.0;
	if (dot(cuv, cuv) > 1.0) {
		discard;
	}
	vec3 slow_color = vec3(0.05, 0.25, 0.85);
	vec3 fast_color = vec3(0.85, 0.95, 1.0);
	ALBEDO = mix(slow_color, fast_color, clamp(speed * 0.25, 0.0, 1.0));
}
