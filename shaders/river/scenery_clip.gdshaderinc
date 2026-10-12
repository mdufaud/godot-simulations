#include "res://shaders/river/river_swe.gdshaderinc"
uniform vec4 river_plane = vec4(0.0, 1.0, 0.0, 0.0);
uniform uint river_reflection_layer = uint(0);
uniform sampler2D river_height_texture : filter_linear, repeat_disable;
uniform vec2 river_domain_m = vec2(1.0);

float river_surface_height(vec3 position) {
	return river_swe_height(position.xz, texture(river_height_texture, position.xz / river_domain_m + 0.5).g);
}

bool river_reflection_clipped(vec3 position, uint camera_layers) {
	return (camera_layers & river_reflection_layer) != uint(0)
		&& position.y < river_surface_height(position);
}
