shader_type sky;
// Storm sky behind the cloud deck: dark overhead, with the clear slot under the
// anvil glowing along the horizon, brightest on the sun's side. The deck hides
// everything but that band, which is what silhouettes the funnel and the range.
// No lightning term here: the sky feeds the radiance map, and a per-frame
// uniform would re-render it every strike. The deck and the ambient flash instead.
render_mode use_debanding;

uniform vec3 zenith_color : source_color = vec3(0.2, 0.215, 0.26);
uniform vec3 horizon_color : source_color = vec3(0.82, 0.83, 0.74);
uniform vec3 sun_dir = vec3(-0.5, 0.0, -0.6); // world, sun -> scene (funnel convention)
uniform float band_sharpness = 9.0;

void sky() {
	float band = exp(-max(EYEDIR.y, 0.0) * band_sharpness);
	float toward_sun = 0.5 - 0.5 * dot(normalize(EYEDIR.xz + vec2(1e-5, 0.0)),
		normalize(sun_dir.xz + vec2(1e-5, 0.0)));
	COLOR = mix(zenith_color, horizon_color * mix(0.7, 1.15, toward_sun), band);
}
