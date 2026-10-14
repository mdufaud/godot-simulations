shader_type canvas_item;
render_mode blend_disabled;
#include "res://shaders/river/river_swe.gdshaderinc"

uniform sampler2D previous_foam : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D flow_map : filter_linear, repeat_disable;
uniform sampler2D turbulence_texture : filter_linear, repeat_enable;
uniform vec2 domain_m = vec2(1.0);
uniform float speed_m_s = 0.85;
uniform float delta_s = 0.016;
uniform float foam_amount = 0.65;
uniform float simulation_time_s = 0.0;
uniform float whitewater_strength = 0.12;
uniform bool reset = true;

void fragment() {
	vec4 field = texture(flow_map, UV);
	vec2 position = (UV - 0.5) * domain_m;
	float weight = river_swe_weight(position);
	vec2 velocity = mix(field.rg * speed_m_s, texture(swe_surface, river_swe_uv(position)).xy, weight);
	vec2 previous_uv = UV - velocity * delta_s / domain_m;
	vec2 inside = step(vec2(0.0), previous_uv) * step(previous_uv, vec2(1.0));
	float history = texture(previous_foam, clamp(previous_uv, vec2(0.0), vec2(1.0))).r;
	history *= inside.x * inside.y;
	float noise = texture(turbulence_texture, (position - field.rg * river_render_time(simulation_time_s) * speed_m_s) * 0.24).r;
	float breakup = mix(0.25, 1.0, smoothstep(0.3, 0.7, noise));
	float source = field.b * breakup * foam_amount * sqrt(max(speed_m_s, 0.0)) * (1.0 + whitewater_strength);
	float wet = field.a;
	float source_rate = source * 1.8;
	float reference_survival = wet * exp(-(1.1 + source_rate) / 60.0);
	float equilibrium = wet * (1.0 - exp(-source_rate / 60.0)) / max(1.0 - reference_survival, 0.000001);
	float survival = wet > 0.0 ? pow(wet, delta_s * 60.0) * exp(-(1.1 + source_rate) * delta_s) : 0.0;
	float foam = mix(equilibrium, history, survival);
	vec2 result = mix(vec2(foam, source / (1.0 + source)), texture(swe_foam, river_swe_uv(position)).rg, weight);
	COLOR = vec4(reset ? vec2(0.0) : result, 0.0, 1.0);
}
