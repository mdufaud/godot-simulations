// Procedural starfield and sun disk. The original ships a black background with a
// separate sun sphere mesh; a sky shader is cheaper and gives the atmosphere
// something to sit against.
shader_type sky;

uniform vec3 sun_direction = vec3(0.5, 0.4, 0.75);
uniform vec3 sun_color : source_color = vec3(1.0, 0.98, 0.92);
uniform float sun_size : hint_range(0.0, 0.2) = 0.018;
uniform float sun_glow : hint_range(1.0, 4000.0) = 900.0;
uniform float sun_intensity : hint_range(0.0, 40.0) = 14.0;

uniform vec3 space_color : source_color = vec3(0.008, 0.010, 0.020);
uniform float star_density : hint_range(0.0, 1.0) = 0.03;
uniform float star_brightness : hint_range(0.0, 4.0) = 1.4;
uniform float twinkle_speed : hint_range(0.0, 4.0) = 1.0;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// One star per cell of a coarse direction grid, jittered inside its cell so the
// grid never reads as a grid.
float stars(vec3 dir, float cell_size) {
	vec3 scaled = dir * cell_size;
	vec3 cell = floor(scaled);
	float presence = hash13(cell);
	if (presence > star_density) {
		return 0.0;
	}

	vec3 jitter = vec3(hash13(cell + 11.0), hash13(cell + 23.0), hash13(cell + 37.0));
	float dist = length(fract(scaled) - jitter);
	float core = smoothstep(0.14, 0.0, dist);

	float magnitude = hash13(cell + 57.0);
	float twinkle = 0.75 + 0.25 * sin(TIME * twinkle_speed + magnitude * 40.0);
	return core * magnitude * magnitude * twinkle;
}

void sky() {
	vec3 dir = EYEDIR;
	vec3 sun_dir = normalize(sun_direction);

	float star = stars(dir, 60.0) + stars(dir, 140.0) * 0.6;
	vec3 color = space_color + vec3(star * star_brightness);

	float cos_angle = dot(dir, sun_dir);
	float disc = smoothstep(1.0 - sun_size, 1.0 - sun_size * 0.5, cos_angle);
	float glow = pow(max(cos_angle, 0.0), sun_glow);
	color += sun_color * (disc * sun_intensity + glow * sun_intensity * 0.35);

	COLOR = color;
}
