// Raymarched Rayleigh atmosphere, shared by the atmosphere quad and the fluid
// composite. Both are full-screen transparent quads reading the same single
// pre-transparent SCREEN_TEXTURE copy, so whichever draws last overwrites the
// other -- the fluid cannot be fogged by a separate pass and has to scatter its
// own output. Deliberately declares no screen/depth sampler: the two shaders
// bind those with different filter hints.
uniform sampler2D baked_optical_depth : filter_linear, repeat_disable;
uniform sampler2D dither_tex : filter_linear, repeat_enable;

uniform vec3 planet_centre = vec3(0.0);
uniform float planet_radius = 22.6;
uniform float atmosphere_radius = 31.75;
uniform vec3 dir_to_sun = vec3(0.5, 0.4, 0.75);

uniform int num_in_scattering_points : hint_range(2, 24) = 10;
uniform vec3 scattering_coefficients = vec3(2.164, 6.583, 11.605);
uniform float intensity = 1.0;
uniform float density_falloff = 4.6;
uniform float dither_strength = 1.0;
uniform float dither_scale = 3.9;

const float MAX_DIST = 3.402823466e+38;

// Returns (distance to sphere, distance through sphere).
vec2 ray_sphere(vec3 centre, float radius, vec3 ray_origin, vec3 ray_dir) {
	vec3 offset = ray_origin - centre;
	float b = 2.0 * dot(offset, ray_dir);
	float c = dot(offset, offset) - radius * radius;
	float d = b * b - 4.0 * c;

	if (d > 0.0) {
		float s = sqrt(d);
		float dst_to_near = max(0.0, (-b - s) * 0.5);
		float dst_to_far = (-b + s) * 0.5;
		if (dst_to_far >= 0.0) {
			return vec2(dst_to_near, dst_to_far - dst_to_near);
		}
	}
	return vec2(MAX_DIST, 0.0);
}

float density_at_point(vec3 p) {
	float height = length(p - planet_centre) - planet_radius;
	float height01 = height / (atmosphere_radius - planet_radius);
	return exp(-height01 * density_falloff) * (1.0 - height01);
}

float optical_depth_baked(vec3 ray_origin, vec3 ray_dir) {
	float height = length(ray_origin - planet_centre) - planet_radius;
	float height01 = clamp(height / (atmosphere_radius - planet_radius), 0.0, 1.0);
	float uv_x = 1.0 - (dot(normalize(ray_origin - planet_centre), ray_dir) * 0.5 + 0.5);
	return texture(baked_optical_depth, vec2(uv_x, height01)).r;
}

// Differencing the table from both ends and blending keeps precision where either
// single-ended difference would cancel to noise.
float optical_depth_baked2(vec3 ray_origin, vec3 ray_dir, float ray_length) {
	vec3 end_point = ray_origin + ray_dir * ray_length;
	float d = dot(ray_dir, normalize(ray_origin - planet_centre));

	const float blend_strength = 1.5;
	float w = clamp(d * blend_strength + 0.5, 0.0, 1.0);

	float d1 = optical_depth_baked(ray_origin, ray_dir) - optical_depth_baked(end_point, ray_dir);
	float d2 = optical_depth_baked(end_point, -ray_dir) - optical_depth_baked(ray_origin, -ray_dir);

	return mix(d2, d1, w);
}

vec3 calculate_light(vec3 ray_origin, vec3 ray_dir, float ray_length, vec3 original_col,
		vec2 screen_uv, vec2 viewport_size) {
	float dither = texture(dither_tex, screen_uv * viewport_size / 1000.0 * dither_scale).r;
	dither = (dither - 0.5) * dither_strength;

	vec3 in_scatter_point = ray_origin;
	float step_size = ray_length / float(num_in_scattering_points - 1);
	vec3 in_scattered_light = vec3(0.0);
	vec3 transmittance = vec3(1.0);

	for (int i = 0; i < num_in_scattering_points; i++) {
		float sun_ray_optical_depth = optical_depth_baked(
				in_scatter_point + dir_to_sun * dither_strength, dir_to_sun);
		float local_density = density_at_point(in_scatter_point);
		float view_ray_optical_depth = optical_depth_baked2(ray_origin, ray_dir, step_size * float(i));
		transmittance = exp(-(sun_ray_optical_depth + view_ray_optical_depth) * scattering_coefficients);

		in_scattered_light += local_density * transmittance;
		in_scatter_point += ray_dir * step_size;
	}
	in_scattered_light *= scattering_coefficients * intensity * step_size / planet_radius;
	in_scattered_light += dither * 0.01;

	return original_col * transmittance + in_scattered_light;
}
