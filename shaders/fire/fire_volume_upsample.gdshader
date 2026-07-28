shader_type spatial;
// Puts the half-resolution volume pass on screen (Phase 6 item 1).
//
// The raymarch renders into a SubViewport at half the linear resolution — a
// quarter of the rays — over a cleared transparent target, so what comes back is
// already premultiplied: blend_mix against alpha 0 leaves colour * alpha in RGB
// and alpha in A. blend_premul_alpha is therefore the composite, not blend_mix.
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled,
	blend_premul_alpha;

uniform sampler2D volume_tex : filter_linear, repeat_disable;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_nearest;
// The same half-res distance the raymarch truncated its rays against, so a tap
// can be told whether it was marched against the surface this pixel sits on.
uniform sampler2D scene_distance_tex : filter_nearest, repeat_disable;
uniform vec2 low_res_size = vec2(640.0, 360.0);
// Relative distance mismatch past which a tap is treated as belonging to another
// surface. 5 % of the distance rather than an absolute metre so it holds at both
// ends of an 80 m march.
uniform float depth_tolerance = 0.05;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float scene_distance(vec2 uv, mat4 inv_projection) {
	float raw = texture(DEPTH_TEXTURE, uv).r;
	vec4 view = inv_projection * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return length(view.xyz / view.w);
}

void fragment() {
	// Bilinear is right wherever the four taps marched against the same surface,
	// and wrong exactly at a silhouette, where one of them stopped at the log in
	// front and the others went past it. So: bilinear weights, scaled by how well
	// each tap's own truncation distance matches this pixel's, which collapses to
	// nearest-depth at an edge and to plain bilinear everywhere else.
	vec2 texel = SCREEN_UV * low_res_size - vec2(0.5);
	vec2 base = floor(texel);
	vec2 f = texel - base;
	float d_full = scene_distance(SCREEN_UV, INV_PROJECTION_MATRIX);

	vec4 acc = vec4(0.0);
	float wsum = 0.0;
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			ivec2 t = ivec2(clamp(base + vec2(float(i), float(j)),
				vec2(0.0), low_res_size - vec2(1.0)));
			float bilinear = (i == 0 ? 1.0 - f.x : f.x) * (j == 0 ? 1.0 - f.y : f.y);
			float d_tap = texelFetch(scene_distance_tex, t, 0).r;
			float mismatch = abs(d_tap - d_full) / max(d_full, 1e-3);
			float w = bilinear / (1.0 + mismatch / max(depth_tolerance, 1e-4));
			acc += texelFetch(volume_tex, t, 0) * w;
			wsum += w;
		}
	}
	vec4 c = wsum > 1e-6 ? acc / wsum : texture(volume_tex, SCREEN_UV);

	ALBEDO = c.rgb;
	ALPHA = c.a;
}
