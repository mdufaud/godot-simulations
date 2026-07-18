// snoise is the Ashima Arts webgl-noise 3D simplex, via Keijiro Takahashi's
// NoiseShader port. Original work (webgl-noise) Copyright (C) 2011 Ashima Arts,
// distributed under the MIT License: https://github.com/ashima/webgl-noise
//
// Kept in sync with shaders/planet/planet_common.comp, which carries the same
// functions for the compute stages (those are read as raw text by
// planet_generator.gd and cannot use #include).

vec3 mod289_v3(vec3 x) {
	return x - floor(x / 289.0) * 289.0;
}

vec4 mod289_v4(vec4 x) {
	return x - floor(x / 289.0) * 289.0;
}

vec4 permute(vec4 x) {
	return mod289_v4((x * 34.0 + 1.0) * x);
}

vec4 taylor_inv_sqrt(vec4 r) {
	return 1.79284291400159 - r * 0.85373472095314;
}

float snoise(vec3 v) {
	const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);

	// First corner
	vec3 i = floor(v + dot(v, C.yyy));
	vec3 x0 = v - i + dot(i, C.xxx);

	// Other corners
	vec3 g = step(x0.yzx, x0.xyz);
	vec3 l = 1.0 - g;
	vec3 i1 = min(g.xyz, l.zxy);
	vec3 i2 = max(g.xyz, l.zxy);

	vec3 x1 = x0 - i1 + C.xxx;
	vec3 x2 = x0 - i2 + C.yyy;
	vec3 x3 = x0 - 0.5;

	// Permutations
	i = mod289_v3(i);
	vec4 p = permute(permute(permute(i.z + vec4(0.0, i1.z, i2.z, 1.0))
			+ i.y + vec4(0.0, i1.y, i2.y, 1.0))
			+ i.x + vec4(0.0, i1.x, i2.x, 1.0));

	// Gradients: 7x7 points over a square, mapped onto an octahedron.
	vec4 j = p - 49.0 * floor(p / 49.0);

	vec4 x_ = floor(j / 7.0);
	vec4 y_ = floor(j - 7.0 * x_);

	vec4 x = (x_ * 2.0 + 0.5) / 7.0 - 1.0;
	vec4 y = (y_ * 2.0 + 0.5) / 7.0 - 1.0;

	vec4 h = 1.0 - abs(x) - abs(y);

	vec4 b0 = vec4(x.xy, y.xy);
	vec4 b1 = vec4(x.zw, y.zw);

	vec4 s0 = floor(b0) * 2.0 + 1.0;
	vec4 s1 = floor(b1) * 2.0 + 1.0;
	vec4 sh = -step(h, vec4(0.0));

	vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
	vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

	vec3 g0 = vec3(a0.xy, h.x);
	vec3 g1 = vec3(a0.zw, h.y);
	vec3 g2 = vec3(a1.xy, h.z);
	vec3 g3 = vec3(a1.zw, h.w);

	// Normalise gradients
	vec4 norm = taylor_inv_sqrt(vec4(dot(g0, g0), dot(g1, g1), dot(g2, g2), dot(g3, g3)));
	g0 *= norm.x;
	g1 *= norm.y;
	g2 *= norm.z;
	g3 *= norm.w;

	// Mix final noise value
	vec4 m = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
	m = m * m;
	m = m * m;

	vec4 px = vec4(dot(x0, g0), dot(x1, g1), dot(x2, g2), dot(x3, g3));
	return 42.0 * dot(m, px);
}

// Roughly 0-1. Each layer is weighted by the previous one, so detail only appears
// where the coarse layers are already high. From FractalNoise.hlsl:92.
float continent_noise(vec3 pos, int layer_count, float persistence, float lacunarity, float scale) {
	const float gain = 1.0;

	float noise_sum = 0.0;
	float amplitude = 1.0;
	float frequency = scale;
	float weight = 1.0;

	for (int i = 0; i < layer_count; i++) {
		float noise_val = snoise(pos * frequency) * 0.5 + 0.5;
		noise_val *= weight;
		weight = clamp(noise_val * gain, 0.0, 1.0);

		noise_sum += noise_val * amplitude;
		amplitude *= persistence;
		frequency *= lacunarity;
	}
	return noise_sum;
}
