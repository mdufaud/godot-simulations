shader_type spatial;
// Front-to-back raymarch of the smoke density through the domain box. The proxy
// has no rotation, so object space differs from world space by a translation.
render_mode unshaded, blend_mix, cull_front, depth_draw_never, depth_test_disabled;

uniform sampler3D density_tex : filter_linear, repeat_disable;
uniform sampler3D light_tex : filter_linear, repeat_disable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform vec3 volume_extent = vec3(1.0);
uniform float cell_size_m = 0.1;
uniform float march_step_cells = 0.75;
uniform float edge_fade_m = 1.0;
// A uniform bound on purpose: a literal one gets the march unrolled.
uniform int march_budget = 1024;
uniform float extinction_per_m = 6.0;
uniform float scattering_albedo = 0.9;
uniform float phase_g = 0.35;
uniform vec3 smoke_color : source_color = vec3(0.85);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_radiance = vec3(1.0);
uniform vec3 ambient_radiance = vec3(0.3);

varying vec3 pos_obj;
varying vec3 cam_obj;

void vertex() {
	pos_obj = VERTEX;
	cam_obj = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

bool box_span(vec3 ray_origin, vec3 ray_dir, vec3 lo, vec3 hi, out float t0, out float t1) {
	vec3 inv_dir = 1.0 / ray_dir;
	vec3 t_a = (lo - ray_origin) * inv_dir;
	vec3 t_b = (hi - ray_origin) * inv_dir;
	vec3 t_near = min(t_a, t_b);
	vec3 t_far = max(t_a, t_b);
	t0 = max(max(max(t_near.x, t_near.y), t_near.z), 0.0);
	t1 = min(min(t_far.x, t_far.y), t_far.z);
	return t1 > t0;
}

// Forward+ is reversed-Z: the raw depth is the NDC z.
float scene_distance(vec2 screen_uv, mat4 inv_projection, mat4 inv_view, vec3 camera_world) {
	vec4 view_pos = inv_projection * vec4(screen_uv * 2.0 - 1.0, texture(depth_texture, screen_uv).r, 1.0);
	view_pos.xyz /= view_pos.w;
	return distance((inv_view * vec4(view_pos.xyz, 1.0)).xyz, camera_world);
}

// Henyey-Greenstein relative to isotropic scattering.
float phase(float cos_theta) {
	float denom = 1.0 + phase_g * phase_g - 2.0 * phase_g * cos_theta;
	return (1.0 - phase_g * phase_g) / (denom * sqrt(denom));
}

void fragment() {
	vec3 ray_dir = normalize(pos_obj - cam_obj);
	vec3 half_size = volume_extent * 0.5;
	float t0;
	float t1;
	if (!box_span(cam_obj, ray_dir, -half_size, half_size, t0, t1)) {
		discard;
	}
	t1 = min(t1, scene_distance(SCREEN_UV, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, CAMERA_POSITION_WORLD));
	if (t1 <= t0) {
		discard;
	}
	vec3 sun_light = sun_radiance * phase(dot(normalize(sun_direction), ray_dir));
	vec3 tint = smoke_color * scattering_albedo;
	float ds = cell_size_m * march_step_cells;
	// Static interleaved gradient noise: no shimmer without temporal accumulation.
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float t = t0 + ds * jitter;
	vec3 color = vec3(0.0);
	float transmittance = 1.0;
	for (int i = 0; i < march_budget && t < t1; i++) {
		vec3 p = cam_obj + ray_dir * t;
		vec3 uvw = p / volume_extent + 0.5;
		// Open sides and top fade out instead of cutting the plume at the box.
		vec3 inset = half_size - abs(p);
		float edge = min(min(inset.x, inset.z), half_size.y - p.y);
		float density = texture(density_tex, uvw).r * smoothstep(0.0, edge_fade_m, edge);
		if (density > 1e-4) {
			float absorbed = 1.0 - exp(-extinction_per_m * density * ds);
			vec3 radiance = tint * (sun_light * texture(light_tex, uvw).r + ambient_radiance);
			color += transmittance * absorbed * radiance;
			transmittance *= 1.0 - absorbed;
			if (transmittance < 0.01) {
				break;
			}
		}
		t += ds;
	}
	ALPHA = 1.0 - transmittance;
	if (ALPHA < 0.002) {
		discard;
	}
	ALBEDO = color / ALPHA;
}
