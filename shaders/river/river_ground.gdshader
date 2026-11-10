shader_type spatial;
#include "res://shaders/river/scenery_clip.gdshaderinc"

uniform sampler2D gravel_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_roughness : filter_linear_mipmap, repeat_enable;
uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_roughness : filter_linear_mipmap, repeat_enable;
uniform float rock_scale = 0.48;
uniform sampler2D caustics_texture : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D water_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float water_detail = 0.0;
uniform float water_clarity = 0.82;
uniform float flow_distance_m = 0.0;

varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

vec3 triplanar_weights(vec3 face) {
	vec3 weights = pow(abs(face), vec3(4.0));
	return weights / (weights.x + weights.y + weights.z);
}

vec3 triplanar_gravel(vec3 point, vec3 dx, vec3 dy, vec3 weights) {
	return textureGrad(gravel_albedo, point.zy, dx.zy, dy.zy).rgb * weights.x + textureGrad(gravel_albedo, point.xz, dx.xz, dy.xz).rgb * weights.y
		+ textureGrad(gravel_albedo, point.xy, dx.xy, dy.xy).rgb * weights.z;
}

void fragment() {
	if (river_reflection_clipped(world_position, CAMERA_VISIBLE_LAYERS)) { discard; }
	vec2 uv = world_position.xz * 0.48;
	float variation = sin(world_position.x * 0.9 + sin(world_position.z * 0.47));
	float height = world_position.y - river_surface_height(world_position);
	float vegetation = smoothstep(0.55, 1.0, river_growth_height(world_position, height) - river_plane.w + variation * 0.08);

	vec3 normal = normalize(world_normal);
	float breakup = sin(world_position.x * 0.9 + world_position.z * 0.6) * 0.5 + sin(world_position.y * 2.3 + world_position.x * 0.4) * 0.5;
	float rock = smoothstep(0.82, 0.62, normal.y + breakup * 0.1 + (textureLod(gravel_albedo, world_position.xz * 0.05, 4.0).g - 0.45) * 0.4);
	vec3 face = normalize(cross(dFdx(world_position), dFdy(world_position)));
	face = dot(face, normal) < 0.0 ? -face : face;
	vec3 rock_color = vec3(0.0);
	vec3 rock_normal_world = normal;
	float rock_rough = 1.0;
	vec3 rock_point = world_position * rock_scale;
	vec3 rock_dx = dFdx(rock_point);
	vec3 rock_dy = dFdy(rock_point);
	if (rock > 0.0) {
		vec3 weights = triplanar_weights(face);
		vec3 side = sign(face);
		float coarse = dot(triplanar_gravel(rock_point * 0.23, rock_dx * 0.23, rock_dy * 0.23, weights), vec3(0.333));
		float strata = sin(world_position.y * 2.7 + sin(world_position.x * 0.8 + world_position.z * 0.55) * 1.4);
		rock_color = triplanar_gravel(rock_point, rock_dx, rock_dy, weights) * vec3(0.57, 0.47, 0.36) * pow(clamp(coarse / 0.25, 0.6, 1.5), 1.5) * (1.0 + 0.12 * strata);
		vec2 detail_x = textureGrad(gravel_normal, rock_point.zy, rock_dx.zy, rock_dy.zy).rg * 2.0 - 1.0;
		vec2 detail_y = textureGrad(gravel_normal, rock_point.xz, rock_dx.xz, rock_dy.xz).rg * 2.0 - 1.0;
		vec2 detail_z = textureGrad(gravel_normal, rock_point.xy, rock_dx.xy, rock_dy.xy).rg * 2.0 - 1.0;
		vec3 detail = vec3(0.0, -side.x * detail_x.y, detail_x.x) * weights.x + vec3(detail_y.x, 0.0, -side.y * detail_y.y) * weights.y
			+ vec3(detail_z.x, side.z * detail_z.y, 0.0) * weights.z;
		rock_normal_world = normalize(normal + detail * 0.6);
		rock_rough = textureGrad(gravel_roughness, rock_point.zy, rock_dx.zy, rock_dy.zy).r * weights.x + textureGrad(gravel_roughness, rock_point.xz, rock_dx.xz, rock_dy.xz).r * weights.y
			+ textureGrad(gravel_roughness, rock_point.xy, rock_dx.xy, rock_dy.xy).r * weights.z;
	}
	vec3 gravel = texture(gravel_albedo, uv).rgb;
	vec3 grass = texture(grass_albedo, uv * 0.9).rgb * vec3(0.50, 0.76, 0.35);
	float wet = river_cliff_wetness(world_position, 1.0 - smoothstep(0.02, river_wet_band(world_position), height));
	ALBEDO = mix(mix(gravel * vec3(0.94, 0.91, 0.81), grass, vegetation), rock_color, rock) * river_wet_darkening(wet, height);
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
	NORMAL_MAP_DEPTH = 0.6 * (1.0 - rock);
	NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(rock_normal_world, 0.0)).xyz, rock));
	ROUGHNESS = mix(mix(mix(texture(gravel_roughness, uv).r, texture(grass_roughness, uv * 0.9).r, vegetation), rock_rough, rock), 0.22, wet * 0.7);
	SPECULAR = mix(0.3, 0.55, wet);
}
