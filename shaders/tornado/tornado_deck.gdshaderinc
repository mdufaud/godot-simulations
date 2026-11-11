// Shared look of the storm's rotation: the cloud deck's collar and wall cloud,
// and the spiral bands the deck, the dust bowl and the ground all turn with.

// Unwrapped rotation angle (rad) of the vortex at its base radius of maximum
// wind, integrated by the host: a rate times TIME would jump on a slider edit.
uniform float spin_phase = 0.0;

// Tone of the cloud deck's dark collar right above the funnel: the deck shades
// with it and the funnel grades its top toward it, so the two meet in one colour.
vec3 tornado_collar_tone(vec3 deck, vec3 dust) {
	return deck * 0.2 + dust * 0.1;
}

// Wall cloud: the deck sags around the funnel top by WALL_CLOUD_DROP of the
// funnel height, fully inside WALL_CLOUD_INNER top core radii and back on the
// deck plane by WALL_CLOUD_OUTER. The funnel ends where it enters it.
const float WALL_CLOUD_DROP = 0.16;
const float WALL_CLOUD_INNER = 1.3;
const float WALL_CLOUD_OUTER = 4.0;

float tornado_wall_cloud_drop(float r, float rc_top, float height) {
	return WALL_CLOUD_DROP * height
		* (1.0 - smoothstep(WALL_CLOUD_INNER * rc_top, WALL_CLOUD_OUTER * rc_top, r));
}

// Trailing log-spiral bands around the axis, 0 in the grooves to 1 on the
// crests. ang = atan(rel.z, rel.x), r_bar in the caller's radius unit, turn the
// fraction of spin_phase the bands rotate by, warp a noise offset (rad) that
// frays them. The spiral turns rigidly, so it never winds up.
float tornado_spiral_bands(float ang, float r_bar, float arms, float pitch, float turn,
		float vortex_sign, float warp) {
	float phase = arms * (ang + vortex_sign * turn * spin_phase)
		- vortex_sign * pitch * log(max(r_bar, 0.05)) + warp;
	float crest = 0.5 + 0.5 * sin(phase);
	return crest * crest * (3.0 - 2.0 * crest);
}
