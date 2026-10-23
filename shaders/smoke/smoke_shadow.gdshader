shader_type spatial;
// next_pass overlay that darkens a surface by the smoke between it and the sun.
// The light volume holds the transmittance from each cell to the sun, so a point
// outside the grid reads it where its sun ray enters the grid.
render_mode unshaded, blend_mul, depth_draw_never, cull_back, fog_disabled, shadows_disabled;

uniform sampler3D light_tex : filter_linear, repeat_disable;
uniform vec3 domain_origin_m = vec3(0.0);
uniform vec3 domain_extent_m = vec3(1.0);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_radiance = vec3(1.0);
uniform vec3 ambient_radiance = vec3(0.3);

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 dir = normalize(sun_direction);
	vec3 inv_dir = 1.0 / mix(vec3(1e-6), dir, greaterThanEqual(abs(dir), vec3(1e-6)));
	vec3 t_a = (domain_origin_m - world_pos) * inv_dir;
	vec3 t_b = (domain_origin_m + domain_extent_m - world_pos) * inv_dir;
	vec3 t_near = min(t_a, t_b);
	vec3 t_far = max(t_a, t_b);
	float t0 = max(max(max(t_near.x, t_near.y), t_near.z), 0.0);
	float t1 = min(min(t_far.x, t_far.y), t_far.z);
	float transmittance = 1.0;
	if (t1 > t0) {
		transmittance = texture(light_tex, (world_pos + dir * t0 - domain_origin_m) / domain_extent_m).r;
	}
	// Only the direct-sun share of the surface's light is shadowed.
	const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
	float sun = dot(sun_radiance, LUMA) * max(dot(normalize(world_normal), dir), 0.0);
	float share = sun / max(sun + dot(ambient_radiance, LUMA), 1e-4);
	ALBEDO = vec3(mix(1.0, transmittance, share));
}
