// Interactive ripple simulation — discrete 2D wave equation, ping-pong between
// two SubViewports. Height encoded as value + 0.5 (R = current, G = previous).
// Splash injection happens via additive red sprites drawn on top of this rect.

shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D prev_texture : hint_default_black;
uniform float damping = 0.995;
uniform bool reset = false;

void fragment()
{
	if (reset)
	{
		COLOR = vec4(0.5, 0.5, 0.0, 1.0);
	}
	else
	{
		vec2 texel = 1.0 / vec2(textureSize(prev_texture, 0));
		vec2 c = texture(prev_texture, UV).rg - 0.5;
		float l = texture(prev_texture, UV - vec2(texel.x, 0.0)).r - 0.5;
		float r = texture(prev_texture, UV + vec2(texel.x, 0.0)).r - 0.5;
		float d = texture(prev_texture, UV - vec2(0.0, texel.y)).r - 0.5;
		float u = texture(prev_texture, UV + vec2(0.0, texel.y)).r - 0.5;

		float next = (l + r + u + d) * 0.5 - c.y;
		next *= damping;

		// Absorb at borders so waves don't reflect off the edges
		float edge = smoothstep(0.0, 0.02, UV.x) * smoothstep(0.0, 0.02, UV.y)
			* smoothstep(0.0, 0.02, 1.0 - UV.x) * smoothstep(0.0, 0.02, 1.0 - UV.y);
		next *= edge;

		COLOR = vec4(next + 0.5, c.x + 0.5, 0.0, 1.0);
	}
}
