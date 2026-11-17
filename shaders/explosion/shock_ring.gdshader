shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
// Offset as a fraction of the shell's apparent radius.
uniform float bend = 0.1;
uniform float glint = 0.0;
// Longest refraction shift, in screen heights: a big shell would drag the sky over the horizon band.
uniform float max_shift = 0.01;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
// Refraction is dropped where the shifted sample lands on a surface this many times nearer or farther: it would drag sky over the horizon band.
uniform float depth_ratio_max = 1.1;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
// Small blasts: a brief thin brightening on the rim and a stronger distortion; the big ones stay refraction-only.
instance uniform float rim_glow = 0.0;
instance uniform float distortion = 1.0;

varying float v_radius_uv;

void vertex() {
	vec3 centre = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_radius_uv = min(length(MODEL_MATRIX[0].xyz) * PROJECTION_MATRIX[1][1] * 0.5 / max(-centre.z, 0.1), 1.0);
}

float view_depth(vec2 uv, mat4 inv_proj) {
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, texture(depth_tex, uv).r, 1.0);
	return -v.z / v.w;
}

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float ring = smoothstep(0.6, 0.3, facing) * smoothstep(0.0, 0.3, facing);
	float fade = pow(1.0 - progress, 1.5) * smoothstep(0.0, 0.05, progress);
	float aspect = PROJECTION_MATRIX[1][1] / PROJECTION_MATRIX[0][0];
	vec2 outward = normalize(NORMAL.xy + vec2(1e-5));
	vec2 offset = -vec2(outward.x / aspect, -outward.y) * min(bend * v_radius_uv, max_shift) * distortion * ring * fade;
	float d0 = view_depth(SCREEN_UV, INV_PROJECTION_MATRIX);
	float d1 = view_depth(SCREEN_UV + offset, INV_PROJECTION_MATRIX);
	float jump = max(d0, d1) / max(min(d0, d1), 1e-3);
	ring *= 1.0 - smoothstep(depth_ratio_max, depth_ratio_max * 1.5, jump);
	vec3 refracted = textureLod(screen_tex, SCREEN_UV + offset, 0.0).rgb;
	float flash = pow(1.0 - progress, 16.0) * ring * ring * ring;
	ALBEDO = refracted + vec3(1.0, 0.8, 0.6) * (glint * ring * ring * fade + rim_glow * flash);
	ALPHA = ring * fade;
}
