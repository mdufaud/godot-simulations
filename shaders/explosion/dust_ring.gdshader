shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_lambert, specular_disabled;

uniform vec3 dust_color : source_color = vec3(0.55, 0.48, 0.38);
uniform float max_alpha = 1.0;
// 1 for the vertical dust wall (unit cylinder height), 0 for the ground annulus (UV is the disc).
uniform float wall = 1.0;
uniform float band_width = 0.22;
// Zero keeps the dust lit by the scene only: dark at night, tan in sunlight.
uniform float self_glow = 0.0;
instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform float scale_m = 1.0;

varying vec3 v_world;
varying float v_height;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_height = VERTEX.y + 0.5;
}

void fragment() {
	float scale = max(scale_m, 0.1);
	float billow = vnoise(v_world * (5.0 / scale)) * 0.6 + vnoise(v_world * (13.0 / scale)) * 0.4;
	float fade = pow(1.0 - progress, 1.2) * smoothstep(0.0, 0.04, progress);
	float shape;
	if (wall > 0.5) {
		float h = v_height;
		float soft = abs(dot(normalize(NORMAL), normalize(VIEW)));
		shape = smoothstep(0.0, 0.12, h) * (1.0 - smoothstep(0.2, 1.0, h + (billow - 0.5) * 0.7));
		shape *= smoothstep(0.2, 0.6, billow) * soft;
	} else {
		float r = length(UV - vec2(0.5)) * 2.0;
		float d = (r - (1.0 - band_width * 0.5)) / band_width;
		float band = exp(-d * d * (d < 0.0 ? 1.0 : 4.0));
		shape = band * smoothstep(0.25, 0.7, billow) * (1.0 - smoothstep(0.9, 1.0, r));
	}
	ALBEDO = dust_color * (0.8 + 0.4 * billow);
	EMISSION = ALBEDO * self_glow;
	ROUGHNESS = 1.0;
	ALPHA = clamp(shape * fade * max_alpha, 0.0, 1.0);
}
