shader_type sky;
render_mode use_debanding;

uniform vec3 zenith_color : source_color = vec3(0.055, 0.18, 0.43);
uniform vec3 horizon_color : source_color = vec3(0.95, 0.43, 0.18);
uniform vec3 haze_color : source_color = vec3(0.82, 0.3, 0.13);
uniform vec3 sun_color : source_color = vec3(1.0, 0.78, 0.42);
uniform vec3 sun_direction = vec3(0.0, 0.14, -0.99);
uniform float sun_radius = 0.0057;
uniform float energy = 1.35;
uniform float storm_mood = 0.0;
uniform float gradient_height = 0.34;
uniform float haze_strength = 0.38;
uniform float sun_disk_energy = 9.0;
uniform float sun_halo_energy = 1.5;

void sky() {
	float up = clamp(EYEDIR.y, -0.08, 1.0);
	float gradient = smoothstep(0.015, gradient_height, clamp(up, 0.0, 1.0));
	vec3 color = mix(horizon_color, zenith_color, gradient);
	float horizon_haze = exp(-abs(EYEDIR.y) * 11.0);
	color = mix(color, haze_color, horizon_haze * haze_strength);
	float sun_dot = clamp(dot(normalize(EYEDIR), normalize(sun_direction)), -1.0, 1.0);
	float angular = acos(sun_dot);
	float disk = 1.0 - smoothstep(sun_radius * 0.7, sun_radius, angular);
	float mie = exp(-angular * mix(18.0, 55.0, clamp(sun_direction.y * 2.0, 0.0, 1.0)));
	float storm_sun = 1.0 - smoothstep(0.68, 0.94, storm_mood);
	color += sun_color * (disk * sun_disk_energy + mie * sun_halo_energy) * storm_sun;
	COLOR = color * energy;
}
