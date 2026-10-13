shader_type particles;
render_mode disable_velocity;

uniform sampler2D swe_surface : filter_linear, repeat_disable;
uniform sampler2D swe_foam : filter_linear, repeat_disable;
uniform sampler2D swe_terrain : filter_linear, repeat_disable;
uniform vec4 swe_region_m;
uniform vec4 emitters[13];
uniform int emitter_count = 1;
uniform float strength = 1.0;
uniform float gravity_m_s2 = 9.81;

float random_value(uint value) {
	value ^= value >> uint(16);
	value *= uint(73244475);
	value ^= value >> uint(16);
	return float(value & uint(65535)) / 65535.0;
}

void start() {
	uint seed = NUMBER + RANDOM_SEED;
	vec4 emitter = emitters[int(INDEX) % max(emitter_count, 1)];
	vec2 jitter = vec2(random_value(seed + uint(1)), random_value(seed + uint(2))) * 2.0 - 1.0;
	vec2 point = emitter.xy + jitter * emitter.z;
	vec2 uv = (point - swe_region_m.xy) / swe_region_m.zw;
	vec4 surface = texture(swe_surface, uv);
	float activity = texture(swe_foam, uv).b;
	ACTIVE = emitter_count > 0 && all(greaterThan(uv, vec2(0.05))) && all(lessThan(uv, vec2(0.95)))
		&& surface.w > 0.025 && random_value(seed + uint(3)) < activity * strength * 0.65;
	TRANSFORM = mat4(1.0);
	TRANSFORM[3].xyz = vec3(point.x, surface.z + 0.035, point.y);
	VELOCITY = vec3(surface.x * 0.5 + jitter.x * 0.45,
		0.9 + activity * 1.8 + random_value(seed + uint(4)) * 0.5,
		surface.y * 0.5 + jitter.y * 0.45);
	CUSTOM = vec4(0.0, mix(0.7, 1.4, random_value(seed + uint(5))), activity, 0.0);
	COLOR = vec4(1.0);
}

void process() {
	CUSTOM.x += DELTA;
	VELOCITY.y -= gravity_m_s2 * DELTA;
	TRANSFORM[3].xyz += VELOCITY * DELTA;
	vec2 uv = (TRANSFORM[3].xz - swe_region_m.xy) / swe_region_m.zw;
	float surface = texture(swe_surface, uv).z;
	float bed = texture(swe_terrain, uv).r;
	if (CUSTOM.x > 0.04 && TRANSFORM[3].y < max(surface, bed) + 0.01) { ACTIVE = false; }
	float size = CUSTOM.y * (1.0 - smoothstep(LIFETIME * 0.55, LIFETIME, CUSTOM.x));
	TRANSFORM[0].xyz = vec3(size, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, size * 1.4, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, size);
}
