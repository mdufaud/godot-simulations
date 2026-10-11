shader_type spatial;
#include "res://shaders/ocean/ocean_deformation.gdshaderinc"
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D sand_albedo : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_albedo : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D shore_surface : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D shore_foam : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D shore_breaker : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D shore_contact : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D foam_detail : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 sand_color : source_color = vec3(0.88, 0.70, 0.38);
uniform float shore_domain_m = 160.0;
uniform bool shore_enabled = false;
uniform float foam_amount = 1.0;
uniform vec3 sky_zenith : source_color = vec3(0.055, 0.18, 0.43);
uniform vec3 sky_horizon : source_color = vec3(0.95, 0.43, 0.18);
uniform sampler2D cloud_reflection : hint_default_black, filter_linear, repeat_disable;
uniform bool cloud_reflection_enabled = true;
uniform float sky_energy = 1.35;

varying vec3 world_position;
varying vec3 world_normal;
varying float sand_coverage;

float hash(vec2 point) {
	return fract(sin(dot(point, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 f = fract(point);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(cell), hash(cell + vec2(1.0, 0.0)), f.x),
		mix(hash(cell + vec2(0.0, 1.0)), hash(cell + vec2(1.0)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	sand_coverage = COLOR.r;
}

void fragment() {
	vec2 p = world_position.xz;
	float sand = sand_coverage * smoothstep(0.62, 0.89, normalize(world_normal).y);
	vec3 sample_color = texture(sand_albedo, p * 0.16).rgb;
	float texture_luminance = dot(sample_color, vec3(0.2126, 0.7152, 0.0722));
	vec3 dry_sand = sand_color * mix(0.82, 1.1, texture_luminance);
	dry_sand *= 0.94 + 0.10 * noise(p * 0.43) + 0.055 * noise(p * 17.0);
	float speckle = smoothstep(0.84, 0.94, noise(p * 42.0));
	dry_sand *= 1.0 - speckle * 0.13;
	vec3 rock = texture(rock_albedo, p * 0.24).rgb * vec3(0.86, 0.88, 0.87);
	vec4 shore = vec4(0.0);
	vec4 surface = vec4(0.0);
	float recent_water = 0.0;
	if (shore_enabled) {
		vec2 shore_uv = p / shore_domain_m + 0.5;
		shore = ocean_shore_roll(shore_foam, p, shore_domain_m);
		surface = texture(shore_surface, shore_uv);
		surface.x = ocean_shore_roll(shore_breaker, p, shore_domain_m).y;
		recent_water = ocean_shore_roll(shore_contact, p, shore_domain_m).g;
	}
	float above_surface = world_position.y - surface.x;
	float submerged = shore_enabled ? 1.0 - smoothstep(-0.12, 0.08, above_surface) : 0.0;
	float wetness = max(shore.a, submerged);
	float footprint = max(length(dFdx(p)), length(dFdy(p)));
	float grain_weight = sand * (1.0 - wetness) * (1.0 - smoothstep(0.015, 0.07, footprint));
	float grain_height = noise(p * 42.0) * 0.002 * grain_weight;
	vec3 normal_world = normalize(world_normal);
	vec3 dx = dFdx(world_position);
	vec3 dy = dFdy(world_position);
	vec3 r1 = cross(dy, normal_world);
	vec3 r2 = cross(normal_world, dx);
	float determinant = dot(dx, r1);
	if (abs(determinant) > 0.00000001) {
		normal_world = normalize(abs(determinant) * normal_world - sign(determinant)
			* (dFdx(grain_height) * r1 + dFdy(grain_height) * r2));
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(normal_world, 0.0)).xyz);
	vec3 wet_sand = dry_sand * vec3(0.64, 0.61, 0.54);
	vec3 sand_albedo_value = mix(dry_sand, wet_sand, wetness);
	float deposit = clamp(shore.b * 1.5, 0.0, 0.45) * step(0.001, foam_amount);
	deposit *= (1.0 - smoothstep(0.0, 0.05, -above_surface)) * wetness * sand;
	float network = texture(foam_detail, p * 0.36).r;
	float network_aa = max(fwidth(network), 0.015);
	float foam = deposit * smoothstep(0.35 - network_aa, 0.65 + network_aa, network);
	ALBEDO = mix(mix(rock, sand_albedo_value, sand), vec3(0.88, 0.91, 0.88), foam);
	float water_film = smoothstep(0.2, 0.7, recent_water)
		* smoothstep(-0.02, 0.08, above_surface) * sand;
	ROUGHNESS = mix(0.96, 0.84, wetness * sand);
	ROUGHNESS = mix(ROUGHNESS, 0.08, water_film);
	ROUGHNESS = mix(ROUGHNESS, 0.96, foam);
	SPECULAR = mix(mix(0.28, 0.25, wetness * sand), sqrt(0.02 / 0.16), water_film);
	float film_fresnel = (0.02 + 0.98 * pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0))
		* water_film * (1.0 - foam);
	ALBEDO *= 1.0 - film_fresnel;
	AO = 0.97;
	vec3 reflected_view = reflect(-VIEW, NORMAL);
	vec3 reflected_world = (INV_VIEW_MATRIX * vec4(reflected_view, 0.0)).xyz;
	float sky_height = smoothstep(0.015, 0.34, reflected_world.y);
	vec3 reflected_sky = mix(sky_horizon, sky_zenith, sky_height) * sky_energy;
	if (cloud_reflection_enabled && water_film > 0.001 && reflected_view.z < -0.02) {
		vec4 cloud_clip = PROJECTION_MATRIX * vec4(reflected_view, 0.0);
		vec2 cloud_uv = cloud_clip.xy / max(cloud_clip.w, 0.0001) * 0.5 + 0.5;
		float edge = min(cloud_uv.x, 1.0 - cloud_uv.x);
		vec4 cloud = textureLod(cloud_reflection, clamp(cloud_uv, vec2(0.001), vec2(0.999)), 2.0);
		reflected_sky = mix(reflected_sky, cloud.rgb / max(cloud.a, 0.25),
			smoothstep(0.04, 0.22, cloud.a) * smoothstep(0.0, 0.16, edge)
			* smoothstep(0.0, 0.15, reflected_world.y));
	}
	RADIANCE = vec4(reflected_sky, water_film * (1.0 - foam));
}
