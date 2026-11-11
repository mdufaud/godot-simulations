// Lightning channel ribbons (TornadoLightning): quads turned to the camera.
// Shared by the opaque core and the additive halo; each defines its fragment().

// The strike's channel envelope from TornadoLightning, 0..1.
uniform float bolt_level = 0.0;
uniform vec3 bolt_color : source_color = vec3(0.78, 0.84, 1.0);
// A far bolt is metres wide and kilometres away: it holds at least this many
// pixels across instead of vanishing between them.
uniform float min_core_px = 2.2;
uniform float min_halo_px = 40.0;

varying float v_side;
varying float v_intensity;
varying float v_thin;

void vertex() {
	vec3 position = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 along = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 side = cross(along, normalize(position));
	side = length(side) > 1e-4 ? normalize(side) : vec3(1.0, 0.0, 0.0);
	float metres_per_px = 2.0 * max(-position.z, 0.1)
			/ (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float floor_m = mix(min_core_px, min_halo_px, UV2.y) * metres_per_px;
	float width = max(UV2.x, floor_m);
	// A ribbon widened to its pixel floor spreads the same light: dim it so a
	// far bolt stays a thin bright line, not a fat one.
	v_thin = clamp(UV2.x / width, 0.25, 1.0);
	// Each segment reaches half a width past both of its ends (COLOR.r: 0 at
	// the start, 1 at the end), so a kinked channel has no gap at its joints.
	VERTEX = position + side * UV.x * width * 0.5 + along * (COLOR.r * 2.0 - 1.0) * width * 0.5;
	v_side = UV.x;
	v_intensity = UV.y;
}
