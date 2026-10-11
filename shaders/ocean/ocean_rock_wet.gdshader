shader_type spatial;
#include "res://shaders/ocean/ocean_deformation.gdshaderinc"
render_mode blend_mix, depth_draw_never, diffuse_burley, specular_schlick_ggx;

uniform sampler2D shore_surface : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D shore_foam : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D shore_contact : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D shore_breaker : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D foam_detail : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float shore_domain_m = 160.0;
uniform bool shore_enabled = false;
uniform float foam_amount = 1.0;

varying vec3 rock_world_position;
varying vec3 rock_world_normal;

void vertex() {
	rock_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	rock_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	if (!shore_enabled) { discard; }
	vec2 outward = rock_world_normal.xz / max(length(rock_world_normal.xz), 0.01);
	float footprint = max(shore_domain_m / float(textureSize(shore_surface, 0).x), 0.5);
	vec2 uv = (rock_world_position.xz + outward * footprint * 2.0) / shore_domain_m + 0.5;
	vec4 water = texture(shore_surface, uv);
	vec2 sample_position = (uv - 0.5) * shore_domain_m;
	water.x = ocean_shore_roll(shore_breaker, sample_position, shore_domain_m).y;
	vec4 coverage = texture(shore_foam, uv);
	vec4 history = texture(shore_contact, uv);
	float live_wet = shore_enabled
		? 1.0 - smoothstep(-0.05, 0.18, rock_world_position.y - water.x) : 0.0;
	float retained_wet = history.y * (1.0 - smoothstep(-0.1, 0.2, rock_world_position.y - history.x));
	float wet = max(live_wet, retained_wet);
	if (wet < 0.001) { discard; }
	float contact = 1.0 - smoothstep(0.08, 0.5, abs(rock_world_position.y - water.x));
	vec3 weights = pow(abs(normalize(rock_world_normal)), vec3(4.0));
	weights /= max(dot(weights, vec3(1.0)), 0.001);
	vec3 detail_position = rock_world_position * 0.36;
	float breakup = texture(foam_detail, detail_position.zy).r * weights.x
		+ texture(foam_detail, detail_position.xz).r * weights.y
		+ texture(foam_detail, detail_position.xy).r * weights.z;
	float breakup_aa = max(fwidth(breakup), 0.015);
	float live_foam = wet * contact
		* smoothstep(0.04, 0.4, max(coverage.x * history.z, history.w) * foam_amount)
		* mix(0.25, 1.0, breakup);
	float residue = clamp(coverage.b * 3.0, 0.0, 0.22) * retained_wet * (1.0 - live_wet)
		* smoothstep(0.35 - breakup_aa, 0.65 + breakup_aa, breakup) * step(0.001, foam_amount);
	float foam = max(live_foam, residue);
	float opacity = clamp(wet * 0.22 + foam * 0.7, 0.0, 0.85);
	ALBEDO = mix(vec3(0.045, 0.065, 0.075), vec3(0.8, 0.87, 0.86), foam * 0.7 / max(opacity, 0.001));
	ROUGHNESS = mix(0.18, 0.85, foam);
	SPECULAR = 0.5;
	ALPHA = opacity;
}
