shader_type spatial;
// Procedural running-bond brickwork driven by the wall-space UV baked into the
// fracture mesh, so the pattern runs unbroken across chunks until they separate.
// COLOR.r < 1 marks a fracture face: those show the raw clay core, not bricks.

uniform vec3 brick_color: source_color = vec3(0.58, 0.25, 0.18);
uniform vec3 brick_color2: source_color = vec3(0.44, 0.18, 0.14);
uniform vec3 mortar_color: source_color = vec3(0.72, 0.69, 0.63);
uniform vec3 core_color: source_color = vec3(0.52, 0.31, 0.24);
uniform vec2 brick_size = vec2(0.42, 0.14);
uniform float mortar_width = 0.013;

varying vec2 wall_uv;
varying float exterior;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	wall_uv = UV;
	exterior = COLOR.r;
}

void fragment() {
	vec2 cell = wall_uv / brick_size;
	float row = floor(cell.y);
	cell.x += mod(row, 2.0) * 0.5;
	vec2 id = floor(cell);
	vec2 f = fract(cell) * brick_size;
	vec2 edge = min(f, brick_size - f);
	float mortar = 1.0 - step(mortar_width, min(edge.x, edge.y));

	vec3 brick = mix(brick_color, brick_color2, hash21(id));
	brick *= 0.88 + 0.24 * hash21(id + 7.0);
	vec3 col = mix(brick, mortar_color, mortar);
	col = mix(core_color, col, step(0.95, exterior));

	ALBEDO = col;
	ROUGHNESS = mix(0.92, 0.75, mortar);
}
