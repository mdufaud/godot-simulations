shader_type spatial;
render_mode blend_premul_alpha, unshaded, cull_disabled, depth_draw_never, shadows_disabled,
	specular_disabled, skip_vertex_transform;
// Procedural flame tongue on a camera-facing GPU particle: a tapered body eroded
// by noise scrolling upward, coloured by a blackbody-like ramp on the remaining
// heat. No atlas, so every sprite is unique and animates on its own. Late in
// life the foot lifts off, leaving a detached lick. wind_lean shears the sprite
// downwind, base pinned.
//   INSTANCE_CUSTOM.x = roll (rad), .y = age 0..1, .z = random seed 0..1
//   COLOR.a = fire intensity 0..1

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float emission_energy = 0.9;
uniform float opacity = 0.92;
uniform float rise_speed = 0.9;
uniform float soft_fade_m = 0.3;
// 0 upright tongue; 1 round fireball for sprites that roll freely (flamethrower).
uniform float puff = 0.0;
// Added to the heat: positive fills the body out, negative thins it to wisps.
uniform float heat_bias = 0.0;
// World-space top offset per metre of sprite height (tan of the lean angle).
uniform vec3 wind_lean = vec3(0.0);

varying float v_age;
varying float v_seed;
varying float v_intensity;

vec3 flame_ramp(float t) {
	vec3 c = mix(vec3(0.35, 0.01, 0.0), vec3(1.0, 0.16, 0.01), smoothstep(0.0, 0.3, t));
	c = mix(c, vec3(1.0, 0.5, 0.06), smoothstep(0.25, 0.6, t));
	return mix(c, vec3(1.0, 0.8, 0.3), smoothstep(0.65, 1.0, t));
}

void vertex() {
	v_age = INSTANCE_CUSTOM.y;
	v_seed = INSTANCE_CUSTOM.z;
	v_intensity = COLOR.a;
	float c = cos(INSTANCE_CUSTOM.x);
	float s = sin(INSTANCE_CUSTOM.x);
	vec2 size = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	vec2 local = mat2(vec2(c, -s), vec2(s, c)) * (VERTEX.xy * size);
	float top = (1.0 - UV.y) * abs(VERTEX.y) * 2.0 * size.y;
	local.x += sin(TIME * 4.3 + v_seed * 40.0) * 0.07 * top * (1.0 - puff);
	vec3 world = MODEL_MATRIX[3].xyz + INV_VIEW_MATRIX[0].xyz * local.x
		+ INV_VIEW_MATRIX[1].xyz * local.y;
	world += wind_lean * top;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	float y = 1.0 - UV.y;
	float x = (UV.x - 0.5) * 2.0;
	float t = TIME * rise_speed;
	vec2 offset = vec2(v_seed * 13.7, v_seed * 5.3);
	x += (texture(noise_tex, vec2(x * 0.12, y * 0.3 - t * 0.45) + offset).r - 0.5) * 2.2 * y;
	float n = texture(noise_tex, vec2(x * 0.2, y * 0.45 - t) + offset).r * 0.65
		+ texture(noise_tex, vec2(x * 0.5, y * 1.1 - t * 1.8) + offset.yx).r * 0.35;
	n = clamp((n - 0.5) * 2.4 + 0.5, 0.0, 1.0);
	float width = mix(0.95, 0.2, y);
	float body = clamp(1.0 - abs(x) / width, 0.0, 1.0);
	// Noisy cut heights: a straight cut would show as a horizontal bar.
	float cut_y = y + (n - 0.5) * 0.35;
	float shaped = smoothstep(0.0, 0.12, y) * (1.0 - smoothstep(0.7, 1.0, cut_y))
		* smoothstep(v_age * 0.9 - 0.35, v_age * 0.9 - 0.05, cut_y);
	float ball = clamp(1.0 - length(vec2(x, y * 2.0 - 1.0)), 0.0, 1.0);
	body = mix(body, ball, puff);
	float heat = body * mix((1.25 - y) * 1.5, 1.7, puff) + (n - 0.5) * (0.9 + 1.3 * y)
		+ heat_bias - 0.3 - 0.3 * v_age - (1.0 - v_intensity) * 0.4;
	// Soft shoulder instead of a clamp: the hot core keeps a gradient.
	heat = (1.0 - exp(-max(heat, 0.0) * 1.3)) * smoothstep(0.0, 0.3, body) * mix(shaped, 1.0, puff);
	float life = smoothstep(0.0, 0.1, v_age) * (1.0 - smoothstep(0.75, 1.0, v_age));
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float soft = clamp((VERTEX.z - scene.z / scene.w) / soft_fade_m, 0.0, 1.0);
	float coverage = smoothstep(0.0, 0.25, heat) * life * soft * v_intensity;
	ALBEDO = flame_ramp(heat) * emission_energy * coverage;
	ALPHA = coverage * opacity * smoothstep(0.1, 0.5, heat);
}
