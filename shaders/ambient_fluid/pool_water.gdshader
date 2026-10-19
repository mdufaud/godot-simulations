shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, diffuse_burley, specular_schlick_ggx;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec3 shallow_color : source_color = vec3(0.16, 0.52, 0.57);
uniform vec3 deep_color : source_color = vec3(0.04, 0.24, 0.32);
uniform vec3 absorption_color : source_color = vec3(0.16, 0.07, 0.045);
uniform float wave_height : hint_range(0.0, 0.2) = 0.045;
uniform float contact_foam_strength : hint_range(0.0, 1.0) = 0.35;
uniform float transmission_strength : hint_range(0.0, 1.0) = 0.84;
uniform float surface_alpha : hint_range(0.0, 1.0) = 0.3;

varying float surface_view_depth_v;
varying float wave_crest_v;
varying vec2 wave_slope_v;
varying vec2 surface_position_v;

void vertex() {
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float first_phase = world_position.x * 1.25 + TIME * 1.7;
	float second_phase = world_position.z * 1.65 - TIME * 1.25;
	float third_phase = (world_position.x + world_position.z) * 2.1 + TIME * 0.8;
	surface_position_v = world_position.xz;
	float edge = smoothstep(0.0, 0.55, 6.8 - abs(world_position.x))
		* smoothstep(0.0, 0.55, 4.8 - abs(world_position.z));
	VERTEX.y += wave_height * edge * (sin(first_phase) * 0.5
		+ sin(second_phase) * 0.35 + sin(third_phase) * 0.15);
	surface_view_depth_v = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	vec2 gradient = vec2(
		cos(first_phase) * 0.625 + cos(third_phase) * 0.315,
		cos(second_phase) * 0.5775 + cos(third_phase) * 0.315) * wave_height * edge;
	wave_slope_v = gradient;
	NORMAL = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	wave_crest_v = clamp((sin(first_phase) + sin(second_phase) + 2.0) * 0.25, 0.0, 1.0);
}

void fragment() {
	float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 view_position = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
	float opaque_view_depth = -view_position.z / max(abs(view_position.w), 1.0e-6);
	float water_depth = max(opaque_view_depth - surface_view_depth_v, 0.0);
	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	vec2 refracted_uv = clamp(SCREEN_UV + wave_slope_v * min(water_depth, 4.0) * 0.018,
		vec2(0.001), vec2(0.999));
	vec3 scene_color = textureLod(screen_texture, refracted_uv, 0.0).rgb;
	vec3 transmitted = scene_color * exp(-absorption_color * min(water_depth, 12.0));
	vec3 water_color = mix(shallow_color, deep_color, clamp(water_depth / 4.0, 0.0, 1.0));
	vec3 color = mix(water_color, transmitted, transmission_strength);
	float contact_foam = 1.0 - smoothstep(0.012, 0.14, water_depth);
	contact_foam *= contact_foam_strength * (0.16 + wave_crest_v * 0.25);
	color = mix(color, vec3(0.72, 0.91, 0.91), clamp(contact_foam, 0.0, 0.5));
	float ripple = 0.5 + 0.5 * sin(surface_position_v.x * 2.2
		+ surface_position_v.y * 0.7 + sin(surface_position_v.y * 1.8 + TIME) * 0.4
		- TIME * 1.4);
	color += vec3(0.025, 0.038, 0.04) * ripple;
	ALBEDO = color;
	ROUGHNESS = mix(0.16, 0.24, clamp(water_depth / 5.0, 0.0, 1.0));
	SPECULAR = 0.5;
	ALPHA = clamp(surface_alpha + fresnel * 0.3, 0.0, 0.85);
}
