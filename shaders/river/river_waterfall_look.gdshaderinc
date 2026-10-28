// Shading of spilled water: a clear sheet at the lip that tears and whitens as its core breaks up over the fall.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D turbulence_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D streak_texture : filter_linear_mipmap, repeat_enable;
uniform vec3 deep_color : source_color = vec3(0.035, 0.19, 0.17);
uniform float clarity = 0.82;
uniform float foam_amount = 0.65;
uniform float simulation_time_s = 0.0;
uniform float breakup_length_m = 3.0;
uniform float unit_discharge_m2_s = 0.1;
uniform float source_speed_m_s = 0.85;
// How white the sheet turns once broken up: a thin, slow sheet keeps to threads where a torrent turns to foam.
uniform float aeration_strength = 1.0;

const float GRAVITY_M_S2 = 9.81;
// Fractions of the break-up length: the sheet is clear past the lip, torn and white where its core is gone.
const float AERATION_ONSET = 0.1;
const float AERATION_FULL = 1.0;
// Streak texture tiles per metre across the lip: broad aerated streamers, fine threads of a thin sheet.
const float STREAMERS_PER_M = 0.45;
const float THREADS_PER_M = 1.2;
// Streak texture tiles per second of flight: the pattern rides the water and stretches as it speeds up.
const float RIDE_RATE = 1.0;
// Pattern level under which a broken sheet shows gaps: thin threads, or a nearly whole aerated body.
const vec2 TEAR_CUT = vec2(0.45, 0.05);
// Width of a torn edge in pattern levels: crisp threads, diffuse aerated streamers.
const vec2 TEAR_SOFTNESS = vec2(0.06, 0.3);
const float IMPACT_FOAM_M = 0.6;
// Fine grain of the foam, like falling snow: grains per metre across and per second of flight.
const vec2 SNOW_GRAIN = vec2(9.0, 14.0);
const float REFRACTION = 0.025;
// Aerated water scatters light many times, so its shading ignores the ripples under it.
const float FOAM_FLATTEN = 0.85;

// Drop below which a spill is a splash off a rock rather than a fall, and the height above a pool where it merges.
uniform vec2 short_spill_m = vec2(0.4, 1.0);

// Share of spilled water drawn apart from the water it falls into: a short spill off a rock merges with it.
float spill_apart(float above_pool_m, float fall_m) {
	return max(smoothstep(0.0, short_spill_m.x, above_pool_m), smoothstep(short_spill_m.x, short_spill_m.y, fall_m));
}

// What the water carries across its lip at one coordinate along it.
struct LipPattern {
	float broad;
	float streamer;
	vec2 slope;
	float thread;
	float snow;
};

LipPattern lip_pattern(float across_m, float ride_s) {
	LipPattern lip;
	float warp = texture(turbulence_texture, vec2(across_m * 0.16, ride_s * 0.35)).r - 0.5;
	lip.broad = texture(turbulence_texture, vec2(across_m * 0.1 + warp * 0.03, ride_s * 1.5)).r;
	vec2 streamer_uv = vec2(across_m * STREAMERS_PER_M + warp * 0.04, ride_s * RIDE_RATE);
	lip.streamer = texture(streak_texture, streamer_uv).r;
	lip.slope = vec2(texture(streak_texture, streamer_uv + vec2(0.004, 0.0)).r,
		texture(streak_texture, streamer_uv + vec2(0.0, 0.01)).r) - lip.streamer;
	lip.thread = texture(streak_texture, vec2(across_m * THREADS_PER_M + warp * 0.02 + 0.37, ride_s * RIDE_RATE * 1.6 + 0.19)).r;
	lip.snow = texture(turbulence_texture, vec2(across_m * SNOW_GRAIN.x, ride_s * SNOW_GRAIN.y) * 0.05).r;
	return lip;
}

struct WaterfallLook {
	vec3 normal;
	vec3 albedo;
	vec3 emission;
	float roughness;
	float specular;
	vec3 backlight;
	// Share of the sheet still there: gaps open between threads or streamers as it breaks up.
	float coverage;
	float foam;
};

// lip_m, lip_weight: lip point and how much the lip runs along x and z (a turning tangent races the pattern).
WaterfallLook waterfall_look(vec3 view_normal, vec3 view_across, float fall_m, float flight_s, vec2 lip_m, vec2 lip_weight,
		float stream_share, float side_share, float above_pool_m, vec3 view, vec2 screen_uv) {
	float speed = sqrt(source_speed_m_s * source_speed_m_s + 2.0 * GRAVITY_M_S2 * fall_m);
	float film_m = unit_discharge_m2_s / max(speed, 0.05);
	// A feature that left the lip at one time keeps the same pattern coordinate all the way down.
	float ride_s = flight_s - simulation_time_s;
	float strong = smoothstep(0.25, 0.6, aeration_strength);

	LipPattern along_x = lip_pattern(lip_m.x, ride_s);
	LipPattern along_z = lip_pattern(lip_m.y + 17.3, ride_s);
	vec2 w = lip_weight / max(lip_weight.x + lip_weight.y, 1.0e-4);
	float broad = along_x.broad * w.x + along_z.broad * w.y;
	float streamer = along_x.streamer * w.x + along_z.streamer * w.y;
	vec2 slope = along_x.slope * w.x + along_z.slope * w.y;
	float thread = along_x.thread * w.x + along_z.thread * w.y;
	float snow = along_x.snow * w.x + along_z.snow * w.y;
	float pattern = mix(thread, streamer, strong) + (broad - 0.5) * 0.25;

	float breakup = fall_m / breakup_length_m + (broad - 0.5) * 0.2;
	float thin = 1.0 - smoothstep(0.01, 0.06, film_m);
	float trickle = 1.0 - smoothstep(0.0, 1.0, stream_share);
	float tear = max(max(smoothstep(AERATION_ONSET, AERATION_FULL, breakup), thin * (1.0 - strong)), trickle);
	float cut = mix(-0.4, mix(TEAR_CUT.x, TEAR_CUT.y, strong * (1.0 - trickle)), tear);
	float softness = mix(TEAR_SOFTNESS.x, TEAR_SOFTNESS.y, strong);
	cut = mix(cut, max(cut, 0.0) + 0.6, smoothstep(0.0, 1.0, side_share));
	float glass = 1.0 - smoothstep(0.0, AERATION_ONSET, breakup);
	// Aerated water turns grainy below its lip; it thins only low in the fall and at its sides, so no hole at the lip.
	float grainy = strong * smoothstep(0.03, 0.25, breakup);
	float apart = grainy * max(smoothstep(0.5, 1.2, breakup), smoothstep(0.0, 1.0, side_share));
	WaterfallLook look;
	look.coverage = smoothstep(cut - softness, cut + softness, pattern) * mix(1.0, mix(0.7, 1.0, snow), apart);
	// White along a calm sheet's threads, all over aerated water within a third of its break-up length.
	float body = smoothstep(cut, cut + 0.25, pattern);
	float white = max(tear * body * mix(0.85, 1.0, strong), strong * smoothstep(0.0, 0.35, breakup) * mix(0.7, 1.0, streamer));
	// A calm sheet enters its pool with little foam, a torrent churns it white.
	float impact = (1.0 - smoothstep(0.0, IMPACT_FOAM_M, above_pool_m)) * smoothstep(0.5, 1.5, fall_m) * aeration_strength;
	float foam = max(white, impact * mix(0.75, 1.0, streamer)) * mix(0.7, 1.0, smoothstep(0.0, 0.5, foam_amount));
	foam *= mix(1.0, mix(0.8, 1.05, snow), grainy * (1.0 - impact));

	vec2 tilt = slope * vec2(0.4, 0.2) * (1.0 - foam);
	vec3 across = normalize(view_across - view_normal * dot(view_across, view_normal));
	vec3 along = cross(view_normal, across);
	look.normal = normalize(view_normal + across * ((broad - 0.5) * 0.035 - tilt.x) - along * tilt.y);
	look.normal = normalize(mix(look.normal, view, foam * FOAM_FLATTEN));

	float absorption = mix(3.8, 0.32, clarity);
	float path_m = clamp(film_m / max(dot(look.normal, view), 0.5), 0.1, 0.6) + glass * 0.25;
	vec3 transmittance = exp(-vec3(1.25, 0.72, 0.63) * absorption * path_m);
	vec2 refraction = look.normal.xy * REFRACTION * smoothstep(0.0, 0.2, film_m);
	float blur = mix(0.3, 1.5, smoothstep(0.05, 0.5, film_m));
	vec3 behind = textureLod(screen_texture, clamp(screen_uv + refraction, vec2(0.001), vec2(0.999)), blur).rgb;
	vec3 water_color = mix(vec3(0.11, 0.17, 0.17), deep_color, 0.35 + (1.0 - clarity) * 0.3);
	vec3 scatter = water_color * (vec3(1.0) - transmittance);
	vec3 foam_color = vec3(0.86, 0.92, 0.94) * mix(0.85, 1.0, broad) * mix(0.88, 1.04, snow);
	look.albedo = mix(scatter, foam_color, foam);
	look.foam = foam;
	look.emission = behind * transmittance * (1.0 - foam);
	// A falling sheet is never a mirror: its rippled surface breaks reflections up.
	look.roughness = mix(0.35, 0.9, foam);
	look.specular = mix(0.2, 0.1, foam);
	look.backlight = vec3(0.5, 0.6, 0.6) * mix(0.25, 0.8, foam);
	return look;
}
