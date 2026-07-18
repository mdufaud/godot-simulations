shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform sampler2D portal_texture : filter_nearest, repeat_disable;

void fragment() {
	if (!FRONT_FACING) {
		discard;
	}
	ALBEDO = textureLod(portal_texture, SCREEN_UV, 0.0).rgb;
}
