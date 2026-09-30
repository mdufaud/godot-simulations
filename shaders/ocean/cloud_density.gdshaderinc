uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform vec2 wind_offset = vec2(0.0);
uniform float coverage = 0.7;
uniform float density = 0.7;
uniform float storm_mood = 0.0;
uniform vec3 sun_direction = vec3(0.0, 0.55, -0.8);
uniform float cloud_base = 220.0;
uniform float cloud_top = 680.0;
uniform float shape_scale = 0.00072;
uniform float detail_scale = 0.0031;
uniform float cloud_shadow_strength = 0.0;

float cloud_hash(highp vec2 p) {
	highp vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yxz + 33.33);
	return fract((q.x + q.y) * q.z);
}

float cloud_value_noise(highp vec2 p) {
	highp vec2 cell = floor(p);
	highp vec2 f = fract(p);
	vec2 smooth_f = f * f * (3.0 - 2.0 * f);
	float a = cloud_hash(cell);
	float b = cloud_hash(cell + vec2(1.0, 0.0));
	float c = cloud_hash(cell + vec2(0.0, 1.0));
	float d = cloud_hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, smooth_f.x), mix(c, d, smooth_f.x), smooth_f.y);
}

float cloud_density_at(vec3 p) {
	float h = clamp((p.y - cloud_base) / max(cloud_top - cloud_base, 1.0), 0.0, 1.0);
	float vertical = smoothstep(0.015, 0.16, h) * (1.0 - smoothstep(0.56, 1.0, h));
	vec3 shape_uv = vec3(p.xz * shape_scale - wind_offset * shape_scale, h * 0.78 + 0.11);
	vec3 detail_uv = vec3(p.xz * detail_scale - wind_offset * detail_scale * 0.7, h * 1.9 + 0.37);
	float macro = max(textureLod(noise_tex, shape_uv, 0.0).r,
		cloud_value_noise(p.xz * 0.00115 - wind_offset * 0.001));
	float detail = max(textureLod(noise_tex, detail_uv, 0.0).r,
		cloud_value_noise(p.xz * 0.0038 - wind_offset * 0.0017));
	float weather = textureLod(noise_tex, vec3(p.xz * shape_scale * 0.24
		- wind_offset * shape_scale * 0.18, 0.43), 0.0).r;
	float threshold = mix(mix(0.92, 0.78, clamp(coverage, 0.0, 1.0)), 0.65, storm_mood);
	float shape = smoothstep(threshold - 0.06, threshold + 0.08, macro + detail * 0.12);
	float cluster = smoothstep(mix(0.58, 0.44, coverage), 0.78, weather);
	shape *= mix(0.35, 1.0, cluster);
	float erosion = smoothstep(0.22, 0.78, detail + macro * 0.28);
	float storm_deck = smoothstep(0.02, 0.22, h)
		* (1.0 - smoothstep(0.58, 0.88, h)) * storm_mood * 0.46;
	return vertical * max(shape, storm_deck) * mix(0.76, 1.0, erosion) * density;
}

float cloud_shadow_at(vec3 p) {
	if (cloud_shadow_strength <= 0.0) {
		return 1.0;
	}
	vec3 to_sun = normalize(sun_direction);
	float thickness = cloud_top - cloud_base;
	float extinction = 0.0;
	for (int i = 0; i < 3; i++) {
		float height = cloud_base + thickness * (0.2 + float(i) * 0.25);
		vec3 sample_position = p + to_sun * max(height - p.y, 0.0) / max(to_sun.y, 0.02);
		extinction += cloud_density_at(sample_position);
	}
	return mix(1.0, exp(-extinction * thickness * 0.004), cloud_shadow_strength);
}
