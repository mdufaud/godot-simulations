shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.22, 0.34, 0.42);
uniform vec3 grid_color : source_color = vec3(0.11, 0.22, 0.29);

varying vec2 pool_position;

void vertex() {
	pool_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 cell = abs(fract(pool_position) - 0.5);
	vec2 width = max(fwidth(pool_position), vec2(0.002));
	float line = max(
		smoothstep(0.475 - width.x, 0.475 + width.x, cell.x),
		smoothstep(0.475 - width.y, 0.475 + width.y, cell.y));
	ALBEDO = mix(base_color, grid_color, line * 0.48);
	ROUGHNESS = 0.78;
	SPECULAR = 0.25;
}
