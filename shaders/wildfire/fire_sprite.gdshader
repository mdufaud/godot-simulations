shader_type spatial;
render_mode blend_premul_alpha, unshaded, cull_disabled, depth_draw_never, shadows_disabled,
	specular_disabled, skip_vertex_transform;
// Camera-facing GPU particle drawing one random cell of a 4x4 VFX atlas: flame
// licks, glow or smoke depending on the cell list. The sprite rises with its
// particle and erodes with age; premultiplied alpha lets flames add light while
// smoke still occludes. wind_lean shears the sprite downwind, base pinned.
// With light_count > 0 the sprite is lit per vertex by up to 8 fire lights
// (Godot's omni falloff, forward scattering), the usual game particle lighting.
//   INSTANCE_CUSTOM.x = roll (rad), .y = age 0..1, .z = random seed 0..1
//   COLOR.rgb = tint, COLOR.a = fire intensity 0..1

uniform sampler2D atlas_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform int cells[4];
uniform int cell_count = 4;
uniform vec3 tint_young : source_color = vec3(1.0);
uniform vec3 tint_old : source_color = vec3(1.0);
uniform float emission_energy = 1.0;
uniform float opacity = 1.0;
uniform float erosion = 0.6;
uniform float edge_softness = 0.25;
uniform float distortion = 0.05;
uniform float flow_speed = 0.9;
uniform float fade_in = 0.08;
uniform float fade_out_start = 0.7;
uniform float soft_fade_m = 0.4;
// 1 fades the sprite to a disc: atlas cells whose art touches the cell border.
uniform float radial_fade = 0.0;
// World-space top offset per metre of sprite height (tan of the lean angle).
uniform vec3 wind_lean = vec3(0.0);
uniform int light_count = 0;
// xyz world position, w range in m.
uniform vec4 light_pos_range[8];
// rgb colour times energy.
uniform vec3 light_color[8];
uniform vec3 ambient_light = vec3(0.0);
// Summed light saturates towards this, so overlapping fires cannot blow out.
uniform float light_ceiling = 2.5;

varying float v_age;
varying float v_seed;
varying vec4 v_tint;
varying vec3 v_light;

void vertex() {
	v_age = INSTANCE_CUSTOM.y;
	v_seed = INSTANCE_CUSTOM.z;
	v_tint = COLOR;
	float c = cos(INSTANCE_CUSTOM.x);
	float s = sin(INSTANCE_CUSTOM.x);
	vec2 size = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	vec2 local = mat2(vec2(c, -s), vec2(s, c)) * (VERTEX.xy * size);
	vec3 world = MODEL_MATRIX[3].xyz + INV_VIEW_MATRIX[0].xyz * local.x
		+ INV_VIEW_MATRIX[1].xyz * local.y;
	world += wind_lean * (1.0 - UV.y) * abs(VERTEX.y) * 2.0 * size.y;
	v_light = vec3(1.0);
	if (light_count > 0) {
		vec3 to_eye = normalize(CAMERA_POSITION_WORLD - world);
		vec3 sum = ambient_light;
		for (int i = 0; i < light_count; i++) {
			vec3 d = light_pos_range[i].xyz - world;
			float dist = max(length(d), 1.0);
			float window = max(1.0 - pow(dist / light_pos_range[i].w, 4.0), 0.0);
			float forward = pow(max(dot(d / dist, -to_eye), 0.0), 4.0);
			sum += light_color[i] * window * window / dist * (0.5 + 1.5 * forward);
		}
		v_light = light_ceiling * (1.0 - exp(-sum / light_ceiling));
	}
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	int cell = cells[clamp(int(v_seed * float(cell_count)), 0, cell_count - 1)];
	vec2 flow = UV * 1.3 + vec2(v_seed * 7.1, v_seed * 3.7 - TIME * flow_speed);
	float n = texture(noise_tex, flow).r;
	vec2 uv = UV + (vec2(n, texture(noise_tex, flow.yx + 0.37).r) - 0.5)
		* distortion * (1.2 - UV.y);
	uv = (vec2(float(cell % 4), float(cell / 4)) + clamp(uv, 0.01, 0.99)) * 0.25;
	vec4 texel = texture(atlas_tex, uv);
	float cut = mix(0.0, erosion, v_age) + (1.0 - v_tint.a) * 0.4;
	float mask = smoothstep(cut, cut + edge_softness, texel.a * (0.6 + 0.4 * n))
		* mix(1.0, 1.0 - smoothstep(0.25, 0.5, length(UV - 0.5)), radial_fade);
	float life = smoothstep(0.0, fade_in, v_age) * (1.0 - smoothstep(fade_out_start, 1.0, v_age));
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float soft = clamp((VERTEX.z - scene.z / scene.w) / soft_fade_m, 0.0, 1.0);
	float coverage = mask * life * soft * v_tint.a;
	vec3 tint = mix(tint_young, tint_old, v_age) * v_tint.rgb * v_light;
	ALBEDO = texel.rgb * tint * emission_energy * coverage;
	ALPHA = coverage * opacity;
}
