// Shading of spilled water: a clear sheet at the lip that aerates as it falls.

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
// How white the sheet turns once broken up: a thin, slow sheet stays streaky where a torrent turns to foam.
uniform float aeration_strength = 1.0;

const float GRAVITY_M_S2 = 9.81;
// Fractions of the break-up length: the sheet is clear past the lip, its surface aerated as the core breaks up.
const float AERATION_ONSET = 0.1;
const float AERATION_FULL = 1.0;
const float STREAKS_PER_M = 0.17;
const float STREAK_SPEED_M_S = 4.0;
const float THREADS_PER_M = 0.6;
const float IMPACT_FOAM_M = 0.6;
const float REFRACTION = 0.025;
// Aerated water scatters light many times, so its shading ignores the particle sphere bumps under it.
const float FOAM_FLATTEN = 0.85;

struct WaterfallLook {
	vec3 normal;
	vec3 albedo;
	vec3 emission;
	float roughness;
	float specular;
	vec3 backlight;
	float fray;
	float thin;
};

WaterfallLook waterfall_look(vec3 world, vec3 view_normal, float fall_m, float across_m, float above_pool_m,
		mat4 view_matrix, vec3 view, vec2 screen_uv) {
	float speed = sqrt(source_speed_m_s * source_speed_m_s + 2.0 * GRAVITY_M_S2 * fall_m);
	float film_m = unit_discharge_m2_s / max(speed, 0.05);
	// Streaks scroll down the water's height: its drawn drop jumps between particles and would swirl them.
	float flow_s = -world.y / STREAK_SPEED_M_S - simulation_time_s;
	float strength = smoothstep(0.0, 0.5, foam_amount);

	float warp = texture(turbulence_texture, vec2(across_m * 0.16, flow_s * 0.35)).r - 0.5;
	float broad = texture(turbulence_texture, vec2(across_m * 0.1 + warp * 0.03, flow_s * 1.5)).r;
	vec2 near_uv = vec2(across_m * STREAKS_PER_M + warp * 0.04, flow_s);
	float near = texture(streak_texture, near_uv).r;
	vec2 slope = vec2(texture(streak_texture, near_uv + vec2(0.004, 0.0)).r,
		texture(streak_texture, near_uv + vec2(0.0, 0.01)).r) - near;
	float deep = texture(streak_texture, vec2(across_m * STREAKS_PER_M * 1.35 + 0.37, flow_s * 1.35 + 0.19)).r;
	float streaks = max(near * mix(0.6, 1.0, broad), deep * 0.7);

	float column = texture(turbulence_texture, vec2(across_m * 0.08, simulation_time_s * 0.02)).r
		+ (texture(turbulence_texture, vec2(across_m * 0.29 + 0.41, simulation_time_s * 0.04 + 0.3)).r - 0.5) * 0.35;
	// The sheet surface aerates from the lip and its clear core is gone at the break-up length.
	float breakup = fall_m / breakup_length_m + (column - 0.5) * 0.2 + (streaks - 0.5) * 0.15;
	float aeration = smoothstep(AERATION_ONSET, AERATION_FULL, breakup) * aeration_strength;
	float glass = 1.0 - smoothstep(0.0, AERATION_ONSET, breakup);
	float impact = (1.0 - smoothstep(0.0, IMPACT_FOAM_M, above_pool_m)) * smoothstep(0.5, 1.5, fall_m);
	WaterfallLook look;
	look.thin = 1.0 - smoothstep(0.01, 0.06, film_m);
	// A weakly aerated sheet whitens in its streaks only, a strongly aerated one all over.
	float streak_share = mix(pow(streaks, 3.0), mix(0.55, 1.0, streaks), smoothstep(0.25, 0.4, aeration_strength));
	float aerated = max(aeration * streak_share, impact * mix(0.75, 1.0, near));
	float foam = max(aerated, strength * max(
		pow(streaks, 0.8) * max(aeration, look.thin * 0.8 * aeration_strength) * mix(0.55, 1.0, max(aeration, impact) * strength),
		smoothstep(0.55, 0.95, near) * 0.45 * (1.0 - aeration) * smoothstep(0.0, AERATION_ONSET, breakup)));

	vec2 thread_uv = vec2(across_m * THREADS_PER_M + 0.29, flow_s * 1.2);
	float thread = texture(streak_texture, thread_uv).r;
	vec2 thread_slope = vec2(texture(streak_texture, thread_uv + vec2(0.004, 0.0)).r - thread, 0.0);
	vec2 tilt = mix(slope, thread_slope * 1.5, glass) * vec2(0.4, 0.2);
	vec3 across = normalize((view_matrix * vec4(1.0, 0.0, 0.0, 0.0)).xyz);
	vec3 along = normalize(cross(view_normal, across));
	look.normal = normalize(view_normal + across * ((broad - 0.5) * 0.035 - tilt.x) - along * tilt.y);
	look.normal = normalize(mix(look.normal, view, foam * FOAM_FLATTEN));

	float absorption = mix(3.8, 0.32, clarity);
	float path_m = clamp(film_m / max(dot(look.normal, view), 0.5), 0.1, 0.6) + glass * 0.25;
	vec3 transmittance = exp(-vec3(1.25, 0.72, 0.63) * absorption * path_m);
	vec2 refraction = look.normal.xy * REFRACTION * smoothstep(0.0, 0.2, film_m);
	float blur = mix(0.3, 1.5, smoothstep(0.05, 0.5, film_m));
	vec3 behind = textureLod(screen_texture, clamp(screen_uv + refraction, vec2(0.001), vec2(0.999)), blur).rgb;
	float milky = aeration * streak_share;
	vec3 water_color = mix(vec3(0.11, 0.17, 0.17), deep_color, 0.35 + (1.0 - clarity) * 0.3);
	vec3 scatter = water_color * (vec3(1.0) - transmittance) + vec3(0.18, 0.22, 0.23) * milky;
	vec3 foam_color = vec3(0.86, 0.92, 0.94) * mix(0.85, 1.0, broad);
	look.albedo = mix(scatter, foam_color, foam);
	look.emission = behind * transmittance * (1.0 - foam) * (1.0 - milky * 0.5);
	look.roughness = mix(0.12, 0.75, foam);
	look.specular = mix(0.5, 0.2, foam);
	look.backlight = vec3(0.5, 0.6, 0.6) * mix(0.25, 0.8, foam);
	look.fray = texture(turbulence_texture, vec2(across_m * 2.1, flow_s * 1.26) + vec2(0.53, 0.71)).r - 0.5;
	return look;
}
