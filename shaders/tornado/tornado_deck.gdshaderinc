// Tone of the cloud deck's dark collar right above the funnel: the deck shades
// with it and the funnel grades its top toward it, so the two meet in one colour.
vec3 tornado_collar_tone(vec3 deck, vec3 dust) {
	return deck * 0.2 + dust * 0.1;
}
