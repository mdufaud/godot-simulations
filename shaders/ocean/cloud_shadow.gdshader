shader_type canvas_item;

#include "res://shaders/ocean/cloud_density.gdshaderinc"

uniform vec2 shadow_center = vec2(0.0);
uniform float shadow_extent = 256.0;

void fragment() {
	vec2 world_xz = shadow_center + (UV - 0.5) * shadow_extent;
	COLOR = vec4(vec3(cloud_shadow_at(vec3(world_xz.x, 0.0, world_xz.y))), 1.0);
}
