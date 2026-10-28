// Evaluates tw_wind (the GLSL mirror every tornado shader uses) at the points the
// parity test passes in, one output pixel per velocity component, so the test can
// compare the GPU field against TornadoWindField.wind_at on the CPU.
//
// Each component is written as 16-bit fixed point split across two 8-bit
// channels: an 8-bit target with blending off stores k/255 exactly, which keeps
// the readback free of any colour-space or half-float rounding.
shader_type canvas_item;
render_mode blend_disabled, unshaded;

#include "res://shaders/tornado/tornado_wind.gdshaderinc"

const int MAX_POINTS = 64;
// Encoded range, in units of u_max.
const float ENCODE_SPAN = 10.0;

uniform vec3 sample_points[64];

void fragment() {
	int pixel = int(FRAGCOORD.x);
	int index = min(pixel / 3, MAX_POINTS - 1);
	int component = pixel - (pixel / 3) * 3;
	vec3 wind = tw_wind(sample_points[index]) / u_max;
	float value = component == 0 ? wind.x : (component == 1 ? wind.y : wind.z);
	float q = clamp(round((value / ENCODE_SPAN + 0.5) * 65535.0), 0.0, 65535.0);
	float high = floor(q / 256.0);
	COLOR = vec4(high / 255.0, (q - high * 256.0) / 255.0, 0.0, 1.0);
}
