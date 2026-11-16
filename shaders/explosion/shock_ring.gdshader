shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
// Offset as a fraction of the shell's apparent radius.
uniform float bend = 0.1;
uniform float glint = 0.1;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;

varying float v_radius_uv;

void vertex() {
	vec3 centre = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_radius_uv = min(length(MODEL_MATRIX[0].xyz) * PROJECTION_MATRIX[1][1] * 0.5 / max(-centre.z, 0.1), 1.0);
}

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float ring = smoothstep(0.5, 0.12, facing) * smoothstep(0.0, 0.1, facing);
	float fade = pow(1.0 - progress, 1.5) * smoothstep(0.0, 0.05, progress);
	float aspect = PROJECTION_MATRIX[1][1] / PROJECTION_MATRIX[0][0];
	vec2 outward = normalize(NORMAL.xy + vec2(1e-5));
	vec2 offset = -vec2(outward.x / aspect, -outward.y) * bend * v_radius_uv * ring * fade;
	vec3 refracted = textureLod(screen_tex, SCREEN_UV + offset, 0.0).rgb;
	ALBEDO = refracted + vec3(1.0, 0.8, 0.6) * glint * ring * ring * fade;
	ALPHA = ring * fade;
}
