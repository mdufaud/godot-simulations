shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled,
	specular_disabled;
// Additive flame billboards drawn from a baked atlas (RGB emission, A coverage).
// Frames are blended pairwise against a normalized particle age — the cheap
// stand-in for exported motion vectors (see docs/game_fire_rdr2_model.md).
// Per-particle data rides in the MultiMesh instance slots:
//   CUSTOM.x = age 0..1, .y = seed, .z = intensity, .w = roll (radians)
//   COLOR.rgb = tint (hot-to-cool ramp), COLOR.a = birth/death envelope

uniform sampler2D atlas_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 atlas_frames = vec2(8.0, 8.0);
uniform float emissive_energy = 3.0;

// INSTANCE_CUSTOM and vertex COLOR only exist in vertex(); fragment reads them via varyings.
varying vec4 v_custom;
varying vec4 v_tint;
// Continuous-flow phase from the particle's world position + seed, scrolled by
// TIME in fragment() so the flame wobbles organically instead of looping.
varying vec2 v_flow;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_tint = COLOR;
	v_flow = vec2(MODEL_MATRIX[3].x + MODEL_MATRIX[3].z, MODEL_MATRIX[3].y)
		* 1.7 + v_custom.y * 4.0;
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), 1.0);
	// Camera-facing billboard that keeps the instance's world position: replace
	// the model basis with the camera basis, then stretch the quad by the scale
	// that was baked into the (now discarded) instance basis.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	// Per-particle roll around the view axis, pivoted on the quad's BASE so
	// tongues lean from their root; pivoting on the centre would swing the
	// bright base rows below the fuel bed as hanging spikes.
	float c = cos(v_custom.w);
	float s = sin(v_custom.w);
	vec2 pivot = vec2(0.0, -0.5);
	VERTEX.xy = pivot + mat2(vec2(c, s), vec2(-s, c)) * (VERTEX.xy - pivot);
	VERTEX.xy *= scale.xy;
}

// Godot uploads image row 0 at v=0, so cell (col,row) spans v
// [row, row+1]/frames.y with the flame tip at the cell's low v — no flip, no
// row mirroring: quad UV.y grows top-to-bottom exactly like the image.
vec2 atlas_uv(vec2 cell_uv, float frame, vec2 frames) {
	vec2 cell = 1.0 / frames;
	float col = mod(floor(frame), frames.x);
	float row = floor(frame / frames.x);
	cell_uv = clamp(cell_uv, vec2(0.02), vec2(0.98));
	return vec2((col + cell_uv.x) * cell.x,
		(row + cell_uv.y) * cell.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = fract(sin(dot(i, vec2(127.1, 311.7))) * 43758.5453);
	float b = fract(sin(dot(i + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5453);
	float c = fract(sin(dot(i + vec2(0.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
	float d = fract(sin(dot(i + vec2(1.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	float age = clamp(v_custom.x, 0.0, 1.0);
	float frame_count = atlas_frames.x * atlas_frames.y;
	float frame = age * (frame_count - 1.0);
	float blend = fract(frame);
	// Continuous upward flow: warp the atlas sampling with two time-scrolling
	// noise octaves. The flipbook alone repeats every loop — this keeps the
	// flame evolving so no cycle is ever visibly identical.
	vec2 flow = v_flow * vec2(0.9, 1.4) + vec2(0.0, -TIME * 2.3);
	float wx = vnoise(flow) * 0.65 + vnoise(flow * 2.3 + 5.1) * 0.35 - 0.5;
	float wy = vnoise(flow.yx * 1.6 + 11.3) * 0.65
		+ vnoise(flow.yx * 3.1 + 27.9) * 0.35 - 0.5;
	vec2 warped = UV + vec2(wx, wy) * vec2(0.10, 0.16);
	// QuadMesh UV.y=0 is the quad's top vertex; the atlas cell's low v is the
	// flame tip, so UV maps straight into the cell.
	vec4 a = texture(atlas_tex, atlas_uv(warped, floor(frame), atlas_frames));
	vec4 b = texture(atlas_tex, atlas_uv(warped, floor(frame) + 1.0, atlas_frames));
	vec4 frame_col = mix(a, b, blend);
	// Soft fade at the quad borders: additive quads must never show a straight
	// edge, whatever the atlas coverage looks like.
	vec2 edge = abs(UV - 0.5) * 2.0;
	float edge_mask = 1.0 - smoothstep(0.78, 0.98, max(edge.x, edge.y));
	ALBEDO = v_tint.rgb * frame_col.rgb * emissive_energy;
	ALPHA = frame_col.a * v_tint.a * edge_mask * clamp(v_custom.z * 1.4, 0.0, 1.0);
}
