shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform sampler2D portal_texture : filter_linear, repeat_disable;
uniform bool screen_space = true;

void fragment() {
	if (!FRONT_FACING) {
		discard;
	}
	ALBEDO = textureLod(portal_texture, screen_space ? SCREEN_UV : UV, 0.0).rgb;
}
