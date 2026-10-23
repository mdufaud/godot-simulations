shader_type spatial;
// Front-to-back raymarch of the smoke density through the domain box. The proxy
// has no rotation, so object space differs from world space by a translation.
render_mode unshaded, blend_mix, cull_front, depth_draw_never, depth_test_disabled;

uniform sampler3D density_tex : filter_linear, repeat_disable;
uniform sampler3D light_tex : filter_linear, repeat_disable;
// Density-weighted albedo of the sources: dye / density is the local smoke colour.
uniform sampler3D dye_tex : filter_linear, repeat_disable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D jitter_noise : filter_nearest, repeat_enable;
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
// One row per omni or spot light (SmokeRenderer.pack_light), object space.
uniform sampler2D light_table : filter_nearest, repeat_disable;
uniform int light_count = 0;

// Multiple scattering (Wrenninge 2015): octave i sees the smoke OCTAVE_EXTINCTION^i
// as thick, weighs OCTAVE_WEIGHT^i and scatters with a phase OCTAVE_PHASE^i as
// eccentric. Weights are normalized so unshadowed smoke keeps its single-scatter
// brightness: the octaves only lift the shadowed core.
const int OCTAVES = 3;
const float OCTAVE_EXTINCTION = 0.5;
const float OCTAVE_WEIGHT = 0.5;
const float OCTAVE_PHASE = 0.5;

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
float phase(float g, float cos_theta) {
	float denom = 1.0 + g * g - 2.0 * g * cos_theta;
	return (1.0 - g * g) / (denom * sqrt(denom));
}

// In-scattered radiance of the light table at p, with Godot's own range window,
// distance decay and spot cone falloff.
vec3 local_lights(vec3 p, vec3 ray_dir) {
	vec3 total = vec3(0.0);
	for (int l = 0; l < light_count; l++) {
		vec4 head = texelFetch(light_table, ivec2(0, l), 0);
		vec4 radiance = texelFetch(light_table, ivec2(1, l), 0);
		vec4 cone = texelFetch(light_table, ivec2(2, l), 0);
		vec3 to_light = head.xyz - p;
		float d = length(to_light);
		float window = d / head.w;
		window *= window;
		window = max(1.0 - window * window, 0.0);
		float falloff = window * window * pow(max(d, 1e-4), -radiance.w);
		vec3 l_dir = to_light / max(d, 1e-4);
		if (cone.w > -1.5) {
			float scos = max(dot(-l_dir, cone.xyz), cone.w);
			float rim = max(1e-4, (1.0 - scos) / (1.0 - cone.w));
			falloff *= 1.0 - pow(rim, texelFetch(light_table, ivec2(3, l), 0).x);
		}
		total += radiance.rgb * falloff * phase(phase_g, dot(l_dir, ray_dir));
	}
	return total;
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
	float cos_theta = dot(normalize(sun_direction), ray_dir);
	float octave_phase[OCTAVES];
	float weight_sum = (1.0 - pow(OCTAVE_WEIGHT, float(OCTAVES))) / (1.0 - OCTAVE_WEIGHT);
	for (int o = 0; o < OCTAVES; o++) {
		octave_phase[o] = pow(OCTAVE_WEIGHT, float(o)) / weight_sum
			* phase(phase_g * pow(OCTAVE_PHASE, float(o)), cos_theta);
	}
	vec3 tint = smoke_color * scattering_albedo;
	float ds = cell_size_m * march_step_cells;
	// Static blue noise: no shimmer without temporal accumulation, and no pattern.
	float jitter = texelFetch(jitter_noise, ivec2(FRAGCOORD.xy) % textureSize(jitter_noise, 0), 0).r;
	float t = t0 + ds * jitter;
	vec3 color = vec3(0.0);
	float transmittance = 1.0;
	for (int i = 0; i < march_budget && t < t1; i++) {
		vec3 p = cam_obj + ray_dir * t;
		vec3 uvw = p / volume_extent + 0.5;
		// Open sides and top fade out instead of cutting the plume at the box.
		vec3 inset = half_size - abs(p);
		float edge = min(min(inset.x, inset.z), half_size.y - p.y);
		float raw_density = texture(density_tex, uvw).r;
		float density = raw_density * smoothstep(0.0, edge_fade_m, edge);
		if (density > 1e-4) {
			vec3 albedo = tint * clamp(texture(dye_tex, uvw).rgb / raw_density, 0.0, 1.0);
			float absorbed = 1.0 - exp(-extinction_per_m * density * ds);
			vec2 light = texture(light_tex, uvw).rg;
			float log_sun = log(max(light.r, 1e-6));
			float sun = 0.0;
			for (int o = 0; o < OCTAVES; o++) {
				sun += octave_phase[o] * exp(log_sun * pow(OCTAVE_EXTINCTION, float(o)));
			}
			// The zenith ray stands for the whole sky dome, which sees thinner smoke.
			vec3 radiance = albedo * (sun_radiance * sun + ambient_radiance * sqrt(light.g)
				+ local_lights(p, ray_dir));
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
