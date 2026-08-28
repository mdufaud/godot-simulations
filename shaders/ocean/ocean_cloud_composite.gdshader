shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;

uniform sampler2D cloud_texture : filter_linear, repeat_disable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform float cloud_far = 8000.0;
uniform float cloud_base = 300.0;
uniform float cloud_top = 720.0;
uniform float density = 0.75;
uniform float storm_mood = 0.0;
uniform mat4 inverse_projection;
uniform mat4 inverse_view;

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
	vec4 cloud = texture(cloud_texture, SCREEN_UV);
	float coverage = smoothstep(0.018, 0.24, cloud.a) * density;
	if (coverage < 0.002) {
		discard;
	}

	vec3 ray = world_ray(SCREEN_UV);
	float base_t = max((cloud_base - CAMERA_POSITION_WORLD.y) / max(ray.y, 0.0001), 0.0);
	vec3 cloud_position = CAMERA_POSITION_WORLD + ray * base_t;
	float broad_shape = 0.5 + 0.5 * sin(cloud_position.x * 0.0011
		+ sin(cloud_position.z * 0.0017) * 2.4);
	float detail_shape = 0.5 + 0.5 * sin(cloud_position.x * 0.0043
		- cloud_position.z * 0.0031);
	float cloud_t = cloud_far;
	if (abs(ray.y) > 0.0001) {
		float ta = (cloud_base - CAMERA_POSITION_WORLD.y) / ray.y;
		float tb = (cloud_top - CAMERA_POSITION_WORLD.y) / ray.y;
		float near_t = max(min(ta, tb), 0.0);
		float far_t = min(max(ta, tb), cloud_far);
		if (far_t <= near_t || far_t <= 0.0) {
			discard;
		}
		cloud_t = near_t;
	} else {
		discard;
	}

	float raw_depth = texture(depth_texture, SCREEN_UV).r;
	if (raw_depth > 0.00001) {
		vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
		vec4 view = inverse_projection * ndc;
		view.xyz /= max(view.w, 1e-5);
		vec3 scene_world = (inverse_view * vec4(view.xyz, 1.0)).xyz;
		float scene_t = distance(CAMERA_POSITION_WORLD, scene_world);
		if (scene_t + 6.0 < cloud_t) {
			discard;
		}
	}

	vec3 cloud_color = cloud.rgb / max(cloud.a, 0.025);
	vec3 storm_floor = vec3(0.028, 0.04, 0.036) * storm_mood;
	vec3 storm_shape = vec3(0.05, 0.065, 0.058) * broad_shape
		+ vec3(0.018, 0.024, 0.021) * detail_shape;
	ALBEDO = max(cloud_color, storm_floor + storm_shape * storm_mood);
	ALPHA = clamp(coverage, 0.0, 0.96);
}
