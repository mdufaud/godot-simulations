shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled,
	specular_disabled;
// Heat haze: screen-space refraction on a soft volume around each fire, instead
// of a full-screen post-process (see docs/game_fire_rdr2_model.md). The mesh
// masks itself (radial fade to the silhouette, fade with height), so idle fires
// pay nothing and no scene-depth pass is needed.
// Driven per fire through instance shader parameters:
//   haze_intensity 0..1, haze_seed phase, haze_rise upward scroll speed.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float strength = 0.035; // UV offset amplitude at full intensity
uniform float height_m = 3.0; // matches the haze volume mesh height

instance uniform float haze_intensity = 0.0;
instance uniform float haze_seed = 0.0;
instance uniform float haze_rise = 1.2;

varying vec3 v_local;

vec2 hash2(vec2 p) {
	return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2(i).x;
	float b = hash2(i + vec2(1.0, 0.0)).x;
	float c = hash2(i + vec2(0.0, 1.0)).x;
	float d = hash2(i + vec2(1.0, 1.0)).x;
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	// Soft cylinder mask: strongest where the surface faces the camera, gone at
	// the silhouette; ramps in just above the ground and fades out near the top.
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float h = clamp(v_local.y / height_m + 0.5, 0.0, 1.0);
	float vertical = smoothstep(0.02, 0.2, h) * (1.0 - smoothstep(0.35, 0.85, h));
	float intensity = haze_intensity * smoothstep(0.0, 0.55, facing) * vertical;
	if (intensity >= 0.003) {
		float t = TIME * haze_rise + haze_seed * 17.0;
		vec2 p = SCREEN_UV * vec2(14.0, 26.0) - vec2(0.0, t);
		float n = value_noise(p) * 0.65 + value_noise(p * 2.3 + 5.1) * 0.35;
		vec2 offset = (vec2(n, value_noise(p.yx * 1.7 + 11.3)) - 0.5)
			* strength * intensity * facing;
		vec3 refracted = textureLod(screen_tex, SCREEN_UV + offset, 0.0).rgb;
		ALBEDO = refracted;
		ALPHA = intensity * 0.7;
	} else {
		ALPHA = 0.0;
	}
}
