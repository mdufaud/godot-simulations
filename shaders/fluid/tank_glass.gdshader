// Clear glass pane: a mirror blended by its Fresnel reflectance, so the pane is
// almost invisible face-on and reflects the sky and sun at grazing angles,
// instead of a uniform milky film.
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_never, specular_schlick_ggx;

uniform vec3 tint : source_color = vec3(0.86, 0.96, 0.94);
uniform float roughness : hint_range(0.0, 1.0) = 0.03;
// Absorption through the pane seen face-on; low-iron glass is nearly clear.
uniform float face_alpha : hint_range(0.0, 1.0) = 0.06;

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = 0.04 + 0.96 * pow(1.0 - facing, 5.0);
	ALBEDO = tint;
	METALLIC = 1.0;
	ROUGHNESS = roughness;
	ALPHA = clamp(fresnel + face_alpha, 0.0, 1.0);
}
