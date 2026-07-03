// Fullscreen underwater overlay — wobbly refraction, blue-green tint, vignette.
// Toggled by water_controller.gd when the camera goes below the water surface.

shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.1, 0.4, 0.5, 1.0);
uniform float distortion = 0.004;
uniform float darkness = 0.45;

void fragment()
{
	vec2 uv = SCREEN_UV;
	uv += vec2(
		sin(uv.y * 22.0 + TIME * 1.4),
		cos(uv.x * 18.0 - TIME * 1.1)) * distortion;
	uv = clamp(uv, vec2(0.001), vec2(0.999));

	vec3 color = textureLod(screen_texture, uv, 0.0).rgb;
	color = mix(color, color * tint.rgb, 0.55);

	float vignette = smoothstep(1.1, 0.35, length(SCREEN_UV - 0.5));
	color *= mix(1.0 - darkness, 1.0, vignette);

	COLOR = vec4(color, 1.0);
}
