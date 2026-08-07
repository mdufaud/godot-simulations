shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.08, 0.55, 0.72);
uniform vec3 deep_color : source_color = vec3(0.015, 0.16, 0.3);
uniform float wave_height : hint_range(0.0, 0.2) = 0.075;

varying float wave_crest;

void vertex() {
	float a = sin(VERTEX.x * 1.25 + TIME * 1.7);
	float b = sin(VERTEX.z * 1.65 - TIME * 1.25);
	float c = sin((VERTEX.x + VERTEX.z) * 2.1 + TIME * 0.8);
	VERTEX.y += (a + b * 0.7 + c * 0.25) * wave_height;
	float dx = (cos(VERTEX.x * 1.25 + TIME * 1.7) * 1.25
		+ cos((VERTEX.x + VERTEX.z) * 2.1 + TIME * 0.8) * 0.525) * wave_height;
	float dz = (cos(VERTEX.z * 1.65 - TIME * 1.25) * 1.155
		+ cos((VERTEX.x + VERTEX.z) * 2.1 + TIME * 0.8) * 0.525) * wave_height;
	NORMAL = normalize(vec3(-dx, 1.0, -dz));
	wave_crest = clamp((a + b + 2.0) * 0.25, 0.0, 1.0);
}

void fragment() {
	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = mix(shallow_color, deep_color, fresnel * 0.7);
	ALBEDO += vec3(0.08, 0.16, 0.18) * wave_crest;
	ROUGHNESS = 0.12;
	SPECULAR = 0.9;
	ALPHA = mix(0.58, 0.82, fresnel);
}
