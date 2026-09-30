shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/ocean/cloud_density.gdshaderinc"
uniform vec3 top_color : source_color = vec3(0.94, 0.98, 1.0);
uniform vec3 base_color : source_color = vec3(0.32, 0.43, 0.55);
uniform vec3 rim_color : source_color = vec3(1.0, 0.95, 0.78);
uniform vec3 flash_pos = vec3(0.0, 400.0, 0.0);
uniform float flash_intensity = 0.0;
uniform float rim_strength = 0.8;
uniform float light_scale = 1.0;
uniform float cloud_far = 8000.0;
uniform int march_steps = 40;
uniform vec2 viewport_size = vec2(640.0, 360.0);
uniform mat4 inverse_projection;
uniform mat4 inverse_view;

float light_transmittance(vec3 p, vec3 to_sun) {
	float shadow = 0.0;
	shadow += cloud_density_at(p + to_sun * 70.0) * 0.55;
	shadow += cloud_density_at(p + to_sun * 145.0) * 0.3;
	shadow += cloud_density_at(p + to_sun * 260.0) * 0.15;
	return exp(-shadow * 1.25);
}

vec3 world_ray(vec2 uv) {
	uv.y = 1.0 - uv.y;
	vec4 view = inverse_projection * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	view.xyz /= max(view.w, 1e-5);
	return normalize((inverse_view * vec4(view.xyz, 0.0)).xyz);
}

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 rd = world_ray(SCREEN_UV);
	if (abs(rd.y) < 0.0001) {
		discard;
	}

	float ta = (cloud_base - ro.y) / rd.y;
	float tb = (cloud_top - ro.y) / rd.y;
	float t0 = max(min(ta, tb), 0.0);
	float t1 = min(max(ta, tb), cloud_far);
	if (t1 <= t0) {
		discard;
	}

	int steps = clamp(int(ceil((t1 - t0) / 45.0)), 8, march_steps);
	float step_length = (t1 - t0) / float(steps);
	float transmittance = 1.0;
	float opacity = 0.0;
	vec3 radiance = vec3(0.0);
	vec3 to_sun = normalize(sun_direction);
	float view_sun = max(dot(rd, to_sun), 0.0);
	float jitter = mix(0.25, 0.75, cloud_hash(floor(FRAGCOORD.xy)));
	for (int i = 0; i < 80; i++) {
		if (i >= steps || transmittance < 0.025) {
			break;
		}
		float t = t0 + (float(i) + jitter) * step_length;
		vec3 p = ro + rd * t;
		float d = cloud_density_at(p);
		if (d <= 0.002) {
			continue;
		}
		float h = clamp((p.y - cloud_base) / max(cloud_top - cloud_base, 1.0), 0.0, 1.0);
		float shadow = light_transmittance(p, to_sun);
		float phase = 0.58 + 0.42 * pow(view_sun, 3.0);
		vec3 light_color = mix(base_color * 0.62, top_color * 1.05,
			smoothstep(0.38, 0.92, h));
		light_color *= 0.3 + shadow * 1.02 * phase;
		light_color *= mix(0.5, 1.0, smoothstep(0.05, 0.48, h));
		float rim = pow(view_sun, 16.0) * (1.0 - smoothstep(0.08, 0.3, d));
		light_color += rim_color * rim * shadow * rim_strength * 0.55;
		float flash = flash_intensity * exp(-distance(p, flash_pos) / 330.0);
		light_color += vec3(0.72, 0.82, 1.0) * flash;
		light_color *= light_scale;
		float distance_fade = 1.0 - smoothstep(1800.0, 6500.0, t);
		// Overcast decks read as one solid ceiling, not separate puffs.
		float thickness = mix(0.008, 0.016, storm_mood);
		float sample_alpha = 1.0 - exp(-d * distance_fade * step_length * thickness);
		radiance += transmittance * sample_alpha * light_color;
		transmittance *= 1.0 - sample_alpha;
		opacity += (1.0 - opacity) * sample_alpha;
	}

	if (opacity < 0.002) {
		discard;
	}
	ALBEDO = radiance / max(opacity, 0.001);
	ALPHA = clamp(opacity, 0.0, 0.96);
}
