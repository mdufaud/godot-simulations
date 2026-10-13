shader_type spatial;
#include "res://shaders/river/scenery_clip.gdshaderinc"

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D roughness_texture : filter_linear_mipmap;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform bool roughness_green = false;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (river_reflection_clipped(world_position, CAMERA_VISIBLE_LAYERS)) { discard; }
	float height = world_position.y - river_surface_height(world_position);
	float wet = 1.0 - smoothstep(0.03, 0.3, height);
	vec3 color = texture(albedo_texture, UV).rgb * albedo_tint.rgb;
	float world_normal_y = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
	float moss = smoothstep(0.35, 0.8, world_normal_y) * smoothstep(0.3, 0.75, height);
	ALBEDO = mix(color, color * vec3(0.57, 0.75, 0.38), moss * 0.3) * mix(1.0, 0.45, wet);
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	NORMAL_MAP_DEPTH = 0.65;
	vec4 rough = texture(roughness_texture, UV);
	ROUGHNESS = mix(roughness_green ? rough.g : rough.r, 0.16, wet * 0.82);
	SPECULAR = mix(0.3, 0.55, wet);
}
