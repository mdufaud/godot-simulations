shader_type fog;

uniform sampler3D density_texture : filter_linear, repeat_enable;
uniform vec3 albedo : source_color = vec3(0.9, 0.93, 0.95);
uniform float density = 0.6;
uniform float rise_m_s = 0.35;
uniform float scale_per_m = 0.18;

void fog() {
	vec3 sample_point = (WORLD_POSITION - vec3(0.0, TIME * rise_m_s, 0.0)) * scale_per_m;
	float churn = texture(density_texture, sample_point).r;
	vec3 centered = UVW * 2.0 - 1.0;
	float falloff = clamp(1.0 - dot(centered, centered), 0.0, 1.0);
	float low = 1.0 - smoothstep(-0.6, 1.0, centered.y);
	DENSITY = density * falloff * low * smoothstep(0.35, 0.75, churn);
	ALBEDO = albedo;
	EMISSION = albedo * 0.15 * DENSITY;
}
