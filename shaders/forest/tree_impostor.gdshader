shader_type spatial;
render_mode unshaded, cull_disabled;

// Far-tree billboard: a single quad rotated around its instance Y axis toward
// the camera. Lighting is baked into the atlas at capture time; a distance
// tint melts the far ring into the horizon haze. Instance transforms for this
// bucket carry uniform scale only (identity rotation), so model axes are
// world-aligned and the billboard basis can be built directly in model space.

uniform sampler2D impostor_tex : source_color, filter_linear_mipmap;
uniform vec3 fog_tint : source_color = vec3(0.75, 0.82, 0.9);
uniform float fog_start = 90.0;
uniform float fog_end = 260.0;

varying float fog_amount;

void vertex() {
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	vec2 to_cam = CAMERA_POSITION_WORLD.xz - inst_pos.xz;
	float dist = length(to_cam);
	to_cam = dist > 0.001 ? to_cam / dist : vec2(0.0, 1.0);
	vec3 right = vec3(to_cam.y, 0.0, -to_cam.x);
	VERTEX = right * VERTEX.x + vec3(0.0, VERTEX.y, 0.0);
	fog_amount = smoothstep(fog_start, fog_end, dist);
}

void fragment() {
	vec4 tex = texture(impostor_tex, UV);
	ALBEDO = mix(tex.rgb, fog_tint, fog_amount * 0.7);
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
