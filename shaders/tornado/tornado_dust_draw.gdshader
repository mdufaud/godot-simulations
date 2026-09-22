shader_type spatial;
// Billboard draw pass for the tornado dust/skirt particles: each quad samples
// one puff of the atmosphere atlas' dust row, chosen by the per-particle seed
// the process shader leaves in INSTANCE_CUSTOM.y. Tint and fade still come
// from the process shader's COLOR.
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

uniform sampler2D puff_atlas : filter_linear_mipmap;
// Top v of the atlas row the puffs live in (a 4x4 grid).
uniform float row_v = 0.5;
uniform float frames = 4.0;

varying vec4 v_color;
varying float v_frame;

void vertex() {
	v_color = COLOR;
	v_frame = floor(INSTANCE_CUSTOM.y * (frames - 0.001));
	// Billboard in view space, keeping the particle scale baked in the basis.
	mat4 mv = MODELVIEW_MATRIX;
	vec3 s = vec3(length(mv[0].xyz), length(mv[1].xyz), length(mv[2].xyz));
	mv[0] = vec4(s.x, 0.0, 0.0, 0.0);
	mv[1] = vec4(0.0, s.y, 0.0, 0.0);
	mv[2] = vec4(0.0, 0.0, s.z, 0.0);
	MODELVIEW_MATRIX = mv;
}

void fragment() {
	vec2 uv = vec2((v_frame + UV.x) / frames, row_v + UV.y / frames);
	vec4 tex = texture(puff_atlas, uv);
	ALBEDO = v_color.rgb * tex.rgb;
	ALPHA = v_color.a * tex.a;
}
