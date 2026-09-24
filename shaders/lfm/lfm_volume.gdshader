shader_type spatial;
render_mode unshaded, blend_mix, cull_front, depth_draw_never;

uniform sampler3D density_tex : filter_linear, repeat_disable;
uniform sampler3D vorticity_tex : filter_linear, repeat_disable;
uniform sampler3D density_prev_tex : filter_linear, repeat_disable;
uniform sampler3D vorticity_prev_tex : filter_linear, repeat_disable;
uniform float frame_blend = 1.0;
uniform int view_mode = 1;
uniform float intensity = 1.0;
uniform vec3 box_size = vec3(2.0, 1.0, 1.0);

varying vec3 local_position;
varying vec3 local_camera;

void vertex() {
	local_position = VERTEX;
	local_camera = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

void fragment() {
	vec3 ray = normalize(local_position - local_camera);
	vec3 half_size = box_size * 0.5;
	vec3 safe_ray = sign(ray) * max(abs(ray), vec3(1e-5));
	vec3 t_a = (-half_size - local_camera) / safe_ray;
	vec3 t_b = (half_size - local_camera) / safe_ray;
	float near_t = max(0.0, max(max(min(t_a.x, t_b.x), min(t_a.y, t_b.y)), min(t_a.z, t_b.z)));
	float far_t = min(min(max(t_a.x, t_b.x), max(t_a.y, t_b.y)), max(t_a.z, t_b.z));
	if (far_t <= near_t) discard;
	float step_size = (far_t - near_t) / 96.0;
	vec3 color = vec3(0.0);
	float transmittance = 1.0;
	for (int i = 0; i < 96; i++) {
		vec3 p = local_camera + ray * (near_t + (float(i) + 0.5) * step_size);
		vec3 uvw = p / box_size + vec3(0.5);
		float signal = view_mode == 0 ? texture(density_tex, uvw).r : texture(vorticity_tex, uvw).r;
		if (frame_blend < 0.999) {
			float previous = view_mode == 0 ? texture(density_prev_tex, uvw).r :
				texture(vorticity_prev_tex, uvw).r;
			signal = mix(previous, signal, frame_blend);
		}
		float core = view_mode == 0 ? smoothstep(0.16, 0.48, abs(signal)) :
			smoothstep(0.7, 1.6, abs(signal));
		float opacity = 1.0 - exp(-core * intensity * step_size * 12.0);
		vec3 tint = view_mode == 0 ? vec3(0.28, 0.74, 0.92) :
			(signal < 0.0 ? vec3(0.21, 0.58, 0.98) : vec3(0.96, 0.47, 0.17));
		color += transmittance * opacity * tint;
		transmittance *= 1.0 - opacity;
		if (transmittance < 0.02) break;
	}
	float alpha = 1.0 - transmittance;
	ALBEDO = color / max(alpha, 1e-4);
	ALPHA = alpha;
}
