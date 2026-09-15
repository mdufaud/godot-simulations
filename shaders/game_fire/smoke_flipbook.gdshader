shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled,
	specular_disabled;
// Alpha-blended smoke billboards from a small procedural puff atlas. Same
// instance-data contract as fire_flipbook.gdshader; drawn above the additive
// flame layer. Smoke cannot be per-particle sorted inside one MultiMesh, so it
// keeps a soft low alpha and relies on gameplay viewing distances to hide the
// classic intersecting-billboard artifacts.

uniform sampler2D atlas_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 atlas_frames = vec2(8.0, 8.0);
uniform float alpha_scale = 0.5;

// INSTANCE_CUSTOM and vertex COLOR only exist in vertex(); fragment reads them via varyings.
varying vec4 v_custom;
varying vec4 v_tint;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_tint = COLOR;
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), 1.0);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	VERTEX.xy *= scale.xy;
}

// Godot uploads image row 0 at v=0, so cell (col,row) spans v
// [row, row+1]/frames.y — no flip, no row mirroring.
vec2 atlas_uv(vec2 cell_uv, float frame, vec2 frames) {
	vec2 cell = 1.0 / frames;
	float col = mod(floor(frame), frames.x);
	float row = floor(frame / frames.x);
	// Clamp inside the cell so linear filtering never bleeds a neighbour in.
	cell_uv = clamp(cell_uv, vec2(0.03), vec2(0.97));
	return vec2((col + cell_uv.x) * cell.x,
		(row + cell_uv.y) * cell.y);
}

void fragment() {
	float age = clamp(v_custom.x, 0.0, 1.0);
	float frame_count = atlas_frames.x * atlas_frames.y;
	float frame = age * (frame_count - 1.0);
	float blend = fract(frame);
	// Same straight UV mapping as fire_flipbook.
	vec4 a = texture(atlas_tex, atlas_uv(UV, floor(frame), atlas_frames));
	vec4 b = texture(atlas_tex, atlas_uv(UV, floor(frame) + 1.0, atlas_frames));
	vec4 frame_col = mix(a, b, blend);
	ALBEDO = v_tint.rgb * frame_col.rgb;
	ALPHA = frame_col.a * v_tint.a * alpha_scale * v_custom.z;
}
