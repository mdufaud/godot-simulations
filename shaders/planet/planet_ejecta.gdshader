shader_type spatial;
render_mode unshaded;

uniform float lava_glow = 4.0;
uniform float activity = 1.0;
varying float age;

void vertex() {
	age = INSTANCE_CUSTOM.r;
}

void fragment() {
	float heat = 1.0 - smoothstep(0.0, 0.9, age);
	vec3 molten = mix(vec3(0.9, 0.08, 0.01), vec3(1.0, 0.8, 0.28), heat * heat);
	ALBEDO = mix(vec3(0.08, 0.055, 0.04), molten * 0.3, heat);
	ALBEDO += molten * heat * lava_glow * activity;
}
