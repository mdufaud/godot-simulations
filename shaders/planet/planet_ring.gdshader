shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform float planet_radius = 1.0;
uniform float density = 0.7;
uniform float seed = 0.0;
uniform vec3 sun_direction = vec3(0.5, 0.4, 0.75);

varying vec3 ring_world_position;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float smooth_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(cell), hash21(cell + vec2(1.0, 0.0)), f.x),
		mix(hash21(cell + vec2(0.0, 1.0)), hash21(cell + vec2(1.0)), f.x), f.y);
}

void vertex() {
	ring_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float radial = UV.y;
	float edge = smoothstep(0.0, 0.035, radial) * (1.0 - smoothstep(0.965, 1.0, radial));
	float fine_filter = 1.0 - smoothstep(0.4, 1.4, fwidth(radial) * 290.0);
	float bands = 0.72 + 0.17 * sin(radial * 30.0 + seed * 0.17)
		+ 0.08 * sin(radial * 83.0) + fine_filter * 0.07 * sin(radial * 290.0);
	float gap_width = max(0.012, fwidth(radial));
	float gaps = smoothstep(0.025, 0.025 + gap_width, abs(radial - 0.36))
		* smoothstep(0.014, 0.014 + gap_width, abs(radial - 0.71));
	float noise = smooth_noise(vec2(UV.x * 48.0, radial * 20.0 + seed));
	float clumps = mix(0.75, 1.0, noise);
	float opacity = edge * density * bands * gaps * clumps * 0.8;
	if (opacity < 0.008) {
		discard;
	}
	vec3 pale_ice = vec3(0.68, 0.58, 0.43);
	vec3 warm_dust = vec3(0.4, 0.28, 0.18);
	ALBEDO = mix(warm_dust, pale_ice, clamp(bands * 0.72 + noise * 0.2, 0.0, 1.0));
	vec3 sun = normalize(sun_direction);
	float along_sun = dot(ring_world_position, sun);
	float closest_to_center = length(ring_world_position - sun * min(along_sun, 0.0));
	float eclipse = smoothstep(planet_radius * 0.92, planet_radius * 1.08, closest_to_center);
	eclipse = mix(0.16, 1.0, eclipse);
	ALBEDO *= eclipse;
	ALPHA = opacity;
}
