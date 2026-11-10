// Shading of spilled water: a clear sheet at the lip that tears and whitens as its core breaks up over the fall.
#include "res://shaders/river/river_spill_breakup.gdshaderinc"

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D turbulence_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D streak_texture : filter_linear_mipmap, repeat_enable;
uniform vec3 deep_color : source_color = vec3(0.035, 0.19, 0.17);
uniform float clarity = 0.82;
uniform float foam_amount = 0.65;
uniform float simulation_time_s = 0.0;
uniform float unit_discharge_m2_s = 0.1;
uniform float source_speed_m_s = 0.85;
// Set from river_swe_solver.gd GRAVITY_M_S2.
uniform float gravity_m_s2 = 0.0;

// Streak texture tiles per metre across the lip: fine threads of a thin sheet, broad aerated streamers, and the ribbon
// families the streamers gather in.
const float THREADS_PER_M = 1.2;
const float STREAMERS_PER_M = 0.45;
const float FAMILIES_PER_M = 0.12;
// Share of the families in the pattern of fully aerated water.
const float FAMILY_SHARE = 0.5;
// Mip bias of threads and streamers: they stay distinct from across the pool instead of averaging to a haze.
const float STREAK_BIAS = -1.0;
// Streak texture tiles per second of flight: the pattern rides the water and stretches as it speeds up.
const float RIDE_RATE = 1.0;
const float FAMILY_RIDE_RATE = 0.5;
// Pattern level over which broken water is white: the thin threads of a calm sheet, most of an aerated body.
const vec2 WHITE_LEVEL = vec2(0.36, 0.2);
// Pattern levels a ribbon's edge spans: threads and aerated streamers thin out to clear water, never cut like bars.
const vec2 RIBBON_EDGE = vec2(0.14, 0.14);
// Pattern level the grain takes off a thread once gaps have opened: it falls on as strands and drops, not as one line.
const float STRAND_BREAK = 0.3;
// Whiteness of a thread against a streamer's: a thin strand of water is half clear.
const float THREAD_WHITE = 0.75;
// Fraction of the break-up length within which broken water has turned white.
const float WHITEN_SHARE = 0.35;
// Fractions of the break-up length fallen below the lip over which gaps open between the ribbons.
const vec2 GAP_SHARE = vec2(0.25, 0.9);
// Thin foam at a ribbon's edge against FOAM_COLOR at its dense core.
const vec3 FOAM_EDGE_COLOR = vec3(0.17, 0.25, 0.29);
// Slope of the streak pattern across and along the fall to tilt of the surface: ribbons stand in relief.
const vec2 RIBBON_TILT = vec2(1.0, 0.4);
const float IMPACT_FOAM_M = 0.6;
// Fine grain of the foam, like falling snow: grains per metre across and per second of flight.
const vec2 SNOW_GRAIN = vec2(9.0, 14.0);
const float REFRACTION = 0.025;
// Water seen through the sheet between its ribbons: it reads as the river's body, not as a pane of glass.
const float BODY_DEPTH_M = 0.6;
// Share of the light the water body scatters back: it stays dark between the white ribbons.
const float BODY_SCATTER = 0.45;

// Drop below which a spill is a splash off a rock rather than a fall, and the height above a pool where it merges.
uniform vec2 short_spill_m = vec2(0.4, 1.0);

// Share of spilled water drawn apart from the water it falls into: a short spill off a rock merges with it.
float spill_apart(float above_pool_m, float drop_m) {
	return max(smoothstep(0.0, short_spill_m.x, above_pool_m), smoothstep(short_spill_m.x, short_spill_m.y, drop_m));
}

// What the water carries across its lip at one coordinate along it.
struct LipPattern {
	float broad;
	float streamer;
	vec2 slope;
	float thread;
	float family;
	float snow;
};

LipPattern lip_pattern(float across_m, float ride_s) {
	LipPattern lip;
	float warp = texture(turbulence_texture, vec2(across_m * 0.16, ride_s * 0.35)).r - 0.5;
	lip.broad = texture(turbulence_texture, vec2(across_m * 0.1 + warp * 0.03, ride_s * 1.5)).r;
	vec2 streamer_uv = vec2(across_m * STREAMERS_PER_M + warp * 0.04, ride_s * RIDE_RATE);
	lip.streamer = texture(streak_texture, streamer_uv, STREAK_BIAS).r;
	lip.slope = vec2(texture(streak_texture, streamer_uv + vec2(0.004, 0.0), STREAK_BIAS).r,
		texture(streak_texture, streamer_uv + vec2(0.0, 0.01), STREAK_BIAS).r) - lip.streamer;
	lip.thread = texture(streak_texture, vec2(across_m * THREADS_PER_M + warp * 0.02 + 0.37, ride_s * RIDE_RATE * 1.6 + 0.19), STREAK_BIAS).r;
	lip.family = texture(streak_texture, vec2(across_m * FAMILIES_PER_M + warp * 0.02 + 0.71, ride_s * FAMILY_RIDE_RATE + 0.53)).r;
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
		float lip_aeration, float stream_share, float side_share, float above_pool_m, vec3 view, vec2 screen_uv) {
	float speed = sqrt(source_speed_m_s * source_speed_m_s + 2.0 * gravity_m_s2 * fall_m);
	float film_m = unit_discharge_m2_s / max(speed, 0.05);
	// A feature that left the lip at one time keeps the same pattern coordinate all the way down.
	float ride_s = flight_s - simulation_time_s;
	float strong = aerated(aeration_strength);

	LipPattern along_x = lip_pattern(lip_m.x, ride_s);
	LipPattern along_z = lip_pattern(lip_m.y + 17.3, ride_s);
	vec2 w = lip_weight / max(lip_weight.x + lip_weight.y, 1.0e-4);
	float broad = along_x.broad * w.x + along_z.broad * w.y;
	float streamer = along_x.streamer * w.x + along_z.streamer * w.y;
	vec2 slope = along_x.slope * w.x + along_z.slope * w.y;
	float thread = along_x.thread * w.x + along_z.thread * w.y;
	float family = along_x.family * w.x + along_z.family * w.y;
	float snow = along_x.snow * w.x + along_z.snow * w.y;
	float pattern = mix(mix(thread, streamer, strong), family, FAMILY_SHARE * strong) + (broad - 0.5) * 0.25;

	float breakup = fall_m / breakup_length_m + (broad - 0.5) * 0.2;
	float thin = 1.0 - smoothstep(0.01, 0.06, film_m);
	float trickle = 1.0 - smoothstep(0.0, 1.0, stream_share);
	float tear = max(max(smoothstep(0.0, WHITEN_SHARE, breakup), thin * (1.0 - strong)), trickle);
	float level = mix(WHITE_LEVEL.x, WHITE_LEVEL.y, strong * (1.0 - trickle));
	float edge = mix(RIBBON_EDGE.x, RIBBON_EDGE.y, strong);
	float side = smoothstep(0.0, 1.0, side_share);
	// A free side frays down to its strongest strands.
	float glass = 1.0 - smoothstep(0.0, BREAKUP_SHARE.x, breakup);
	// However aerated it arrives, water is whole at its lip: gaps open with the height fallen, at a free side, in a trickle.
	float open = max(max(smoothstep(GAP_SHARE.x, GAP_SHARE.y, breakup - lip_aeration), side), trickle);
	float strand = pattern - side * 0.5 - (snow - 0.35) * STRAND_BREAK * open * (1.0 - strong);
	WaterfallLook look;
	look.coverage = mix(1.0, smoothstep(level - edge, level, strand), open);
	// A calm sheet enters its pool with little foam, a torrent churns it white.
	float impact = (1.0 - smoothstep(0.0, IMPACT_FOAM_M, above_pool_m)) * smoothstep(0.5, 1.5, fall_m) * aeration_strength;
	// White ribbons grow out of the strongest streaks as the sheet tears and churns; the water between them stays clear.
	float white_level = mix(1.0, level, tear) - impact * 0.15;
	float dense = smoothstep(white_level, white_level + 3.0 * edge, strand);
	float foam = smoothstep(white_level, white_level + 2.0 * edge, strand) * mix(0.7, 1.0, smoothstep(0.0, 0.5, foam_amount))
		* mix(THREAD_WHITE, 1.0, strong);

	vec2 tilt = slope * RIBBON_TILT;
	vec3 across = normalize(view_across - view_normal * dot(view_across, view_normal));
	vec3 along = cross(view_normal, across);
	look.normal = normalize(view_normal + across * ((broad - 0.5) * 0.035 - tilt.x) - along * tilt.y);

	float absorption = river_water_absorption(clarity, 0.0);
	float path_m = max(film_m / max(dot(look.normal, view), 0.5), BODY_DEPTH_M) + glass * 0.25;
	vec3 transmittance = exp(-vec3(1.25, 0.72, 0.63) * absorption * path_m);
	vec2 refraction = look.normal.xy * REFRACTION * smoothstep(0.0, 0.2, film_m);
	float blur = mix(0.3, 1.5, smoothstep(0.05, 0.5, film_m));
	vec3 behind = textureLod(screen_texture, clamp(screen_uv + refraction, vec2(0.001), vec2(0.999)), blur).rgb;
	vec3 water_color = mix(vec3(0.11, 0.17, 0.17), deep_color, 0.35 + (1.0 - clarity) * 0.3);
	vec3 scatter = water_color * BODY_SCATTER * (vec3(1.0) - transmittance);
	vec3 foam_color = mix(FOAM_EDGE_COLOR, FOAM_COLOR, dense) * mix(0.85, 1.0, broad) * mix(0.8, 1.05, snow);
	look.albedo = mix(scatter, foam_color, foam);
	look.foam = foam;
	look.emission = behind * transmittance * (1.0 - foam);
	// A falling sheet is never a mirror: its rippled surface breaks reflections up.
	look.roughness = mix(0.35, 0.9, foam);
	look.specular = mix(0.2, 0.1, foam);
	look.backlight = vec3(0.5, 0.6, 0.6) * mix(0.25, 0.8, foam);
	return look;
}
