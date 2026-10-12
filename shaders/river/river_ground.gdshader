shader_type spatial;
#include "res://shaders/river/scenery_clip.gdshaderinc"

uniform sampler2D gravel_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_roughness : filter_linear_mipmap, repeat_enable;
uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_roughness : filter_linear_mipmap, repeat_enable;
uniform sampler2D caustics_texture : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D water_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float water_detail = 0.0;
uniform float water_clarity = 0.82;
uniform float flow_distance_m = 0.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (river_reflection_clipped(world_position, CAMERA_VISIBLE_LAYERS)) { discard; }
	vec2 uv = world_position.xz * 0.48;
	float variation = sin(world_position.x * 0.9 + sin(world_position.z * 0.47));
	float height = world_position.y - river_surface_height(world_position);
	float vegetation = smoothstep(0.55, 1.0, height - river_plane.w + variation * 0.08);
	vec3 gravel = texture(gravel_albedo, uv).rgb;
	vec3 grass = texture(grass_albedo, uv * 0.9).rgb * vec3(0.50, 0.76, 0.35);
	float wet = 1.0 - smoothstep(0.02, 0.35, height);
	ALBEDO = mix(gravel * vec3(0.94, 0.91, 0.81), grass, vegetation) * mix(1.0, 0.48, wet);
	if (water_detail > 0.0 && height < 0.0) {
		vec2 drift = vec2(0.015, 0.045) * flow_distance_m;
		vec2 distortion = texture(water_normal, world_position.xz * 0.18 + drift * 0.3).rg * 2.0 - 1.0;
		vec2 caustic_uv = world_position.xz * 0.06 + distortion * 0.012;
		float first = texture(caustics_texture, caustic_uv + drift).r;
		float second = texture(caustics_texture, caustic_uv * 1.17 - drift * 0.7 + vec2(0.37, 0.19)).r;
		float focus = pow(min(first, second), 2.5);
		float submerged = smoothstep(0.01, 0.12, -height) * exp(height * 1.8);
		ALBEDO *= 1.0 + focus * submerged * water_clarity * water_clarity * water_detail * 1.7;
	}
	NORMAL_MAP = mix(texture(gravel_normal, uv).rgb, texture(grass_normal, uv * 0.9).rgb, vegetation);
	NORMAL_MAP_DEPTH = 0.6;
	ROUGHNESS = mix(mix(texture(gravel_roughness, uv).r, texture(grass_roughness, uv * 0.9).r, vegetation), 0.22, wet * 0.7);
	SPECULAR = mix(0.3, 0.55, wet);
}
