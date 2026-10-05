shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D sand_albedo : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_albedo : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D shore_surface : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D shore_foam : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D foam_detail : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 sand_color : source_color = vec3(0.88, 0.70, 0.38);
uniform float shore_domain_m = 160.0;
uniform bool shore_enabled = false;
uniform float foam_amount = 1.0;

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
	if (shore_enabled) {
		vec2 shore_uv = p / shore_domain_m + 0.5;
		shore = texture(shore_foam, shore_uv);
		surface = texture(shore_surface, shore_uv);
	}
	float above_surface = world_position.y - surface.x;
	float submerged = surface.w > 0.002 ? 1.0 - smoothstep(-0.12, 0.08, above_surface) : 0.0;
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
	float deposit = smoothstep(0.025, 0.34, shore.b * foam_amount);
	deposit *= (1.0 - smoothstep(0.001, 0.02, surface.w)) * wetness * sand;
	float network = texture(foam_detail, p * 0.36).r;
	float foam = clamp(deposit * (0.2 + 0.8 * network), 0.0, 0.9);
	ALBEDO = mix(mix(rock, sand_albedo_value, sand), vec3(0.88, 0.91, 0.88), foam);
	ROUGHNESS = mix(0.94, 0.69, wetness * sand);
	ROUGHNESS = mix(ROUGHNESS, 0.96, foam);
	SPECULAR = mix(0.23, 0.36, wetness * sand);
	AO = 0.97;
}
