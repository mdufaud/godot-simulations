// Cloth surface: the mesh is a flat UV grid whose vertices are fetched from the
// solver's position image, one texel per vertex. Normals come from the same
// texture (central differences on the grid), so the CPU never sees a vertex.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D position_tex : filter_nearest;
uniform vec2 grid_size = vec2(96.0, 72.0);
uniform vec3 cloth_color : source_color = vec3(0.75, 0.15, 0.12);
uniform vec3 stripe_color : source_color = vec3(0.92, 0.9, 0.85);
uniform float stripe_count = 5.0;
uniform float stripe_mix = 0.0;

varying vec3 world_normal;

vec3 fetch(ivec2 t) {
	ivec2 c = clamp(t, ivec2(0), ivec2(grid_size) - ivec2(1));
	return texelFetch(position_tex, c, 0).xyz;
}

void vertex() {
	ivec2 texel = ivec2(round(UV * (grid_size - vec2(1.0))));
	VERTEX = fetch(texel);
	vec3 du = fetch(texel + ivec2(1, 0)) - fetch(texel - ivec2(1, 0));
	vec3 dv = fetch(texel + ivec2(0, 1)) - fetch(texel - ivec2(0, 1));
	vec3 n = cross(du, dv);
	NORMAL = length(n) > 1e-8 ? normalize(n) : vec3(0.0, 1.0, 0.0);
	world_normal = NORMAL;
}

void fragment() {
	// A sheet has two faces and the solver has no idea which way is "out":
	// flip the shading normal for whichever side the camera is looking at.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	float stripe = step(0.5, fract(UV.y * stripe_count));
	ALBEDO = mix(cloth_color, stripe_color, stripe * stripe_mix);
	ROUGHNESS = 0.85;
	SPECULAR = 0.2;
	// Fabric is thin: let a little light bleed through from behind.
	BACKLIGHT = vec3(0.25);
}
