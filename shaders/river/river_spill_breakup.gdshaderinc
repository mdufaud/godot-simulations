// How spilled water breaks up over its fall, shared by its sheet (river_waterfall_look.gdshaderinc) and its particle
// streaks (river_spill_foam.gdshader), so the streaks take over from the sheet over the same span.

// How white the sheet turns once broken up: a thin, slow sheet keeps to threads where a torrent turns to foam.
uniform float aeration_strength = 1.0;
uniform float breakup_length_m = 3.0;

// Fractions of the break-up length: the sheet is clear past its lip and torn and white where its core is gone; the
// streaks take over from it in between.
const vec2 BREAKUP_SHARE = vec2(0.1, 1.0);

// How far a fall of this aeration strength turns from threads to streamers and foam.
float aerated(float strength) {
	return smoothstep(0.25, 0.6, strength);
}
