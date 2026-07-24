extends CompositorEffect
## Publishes the main render's opaque depth as a half-resolution distance texture
## (Phase 6 item 1).
##
## The volume raymarch moved into its own half-res SubViewport, and a SubViewport
## only ever sees its own depth buffer — the campfire's logs and boulders are not
## in it, so the ray had nothing to stop at. This effect runs on the main camera
## right after the opaque pass, linearises the depth into a distance from the
## camera and halves it, which is both what the raymarch needs to truncate its
## rays and what the composite needs to weight its upsample.
##
## The consumer is a SubViewport, and sub-viewports are drawn BEFORE the main
## viewport within a frame, so what the raymarch reads is the previous frame's
## occlusion. Only the truncation lags: the volume itself is current, and the
## composite that puts it on screen weights against the current frame's depth.

const SHADER_PATH := "res://shaders/fire/scene_distance.comp"

## Half-res distance texture, valid once the first callback has run. Read from the
## main thread to bind it into the raymarch and composite materials.
var output_rid := RID()
var output_size := Vector2i.ZERO

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _set := RID()
var _set_depth := RID()
## Textures replaced by a resize, each with the number of callbacks left before it
## is freed. See _retire().
var _retired: Array = []


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE
	# Without this the depth texture handed over is the multisampled one, which a
	# plain sampler2D cannot read at all.
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(_init_render)


func _init_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	var src := FileAccess.get_file_as_string(SHADER_PATH)
	var spirv := ShaderCache.compile(_rd, "fire_scene_distance", src)
	if not spirv.compile_error_compute.is_empty():
		push_error("scene_distance.comp compile error:\n%s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)


## Queued by the owner on the render thread; the Callable keeps this effect alive
## until it has run, which a PREDELETE hook could not promise.
func free_render() -> void:
	if _rd == null:
		return
	for entry in _retired:
		_rd.free_rid(entry[0])
	_retired.clear()
	for rid in [_pipeline, _shader, _sampler, output_rid]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_pipeline = RID()
	_shader = RID()
	_sampler = RID()
	output_rid = RID()


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if _rd == null or not _pipeline.is_valid() \
			or callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE:
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return

	_retire()
	var internal := buffers.get_internal_size()
	if internal.x <= 0 or internal.y <= 0:
		return
	var half := Vector2i(maxi(internal.x / 2, 1), maxi(internal.y / 2, 1))
	if half != output_size:
		_resize(half)
	var depth := buffers.get_depth_texture()
	if not depth.is_valid() or not output_rid.is_valid():
		return
	# The depth texture is a fresh RID whenever the buffers are rebuilt, so the set
	# is keyed on it rather than cached once.
	if depth != _set_depth or not _rd.uniform_set_is_valid(_set):
		_set_depth = depth
		if _set.is_valid() and _rd.uniform_set_is_valid(_set):
			_rd.free_rid(_set)
		var tex := RDUniform.new()
		tex.binding = 0
		tex.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		tex.add_id(_sampler)
		tex.add_id(depth)
		var img := RDUniform.new()
		img.binding = 1
		img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		img.add_id(output_rid)
		_set = _rd.uniform_set_create([tex, img], _shader, 0)

	var push := PackedFloat32Array()
	var inv_proj := scene_data.get_view_projection(0).inverse()
	for column in 4:
		var c: Vector4 = inv_proj[column]
		push.append_array(PackedFloat32Array([c.x, c.y, c.z, c.w]))
	var bytes := push.to_byte_array()
	bytes.append_array(PackedInt32Array([half.x, half.y, internal.x, internal.y]).to_byte_array())

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _set, 0)
	_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
	_rd.compute_list_dispatch(cl, ceili(half.x / 8.0), ceili(half.y / 8.0), 1)
	_rd.compute_list_end()


## A resized texture cannot be freed on the spot: the main thread is still sampling
## the old one through a Texture2DRD and only rebinds on a later frame, which the
## driver would otherwise report as "Uniforms supplied for set (3) ... are not the
## same format". Retired textures are freed a few callbacks later instead.
const RETIRE_CALLBACKS := 4


func _retire() -> void:
	var keep := []
	for entry in _retired:
		entry[1] -= 1
		if entry[1] <= 0:
			_rd.free_rid(entry[0])
		else:
			keep.append(entry)
	_retired = keep


func _resize(half: Vector2i) -> void:
	if output_rid.is_valid():
		_retired.append([output_rid, RETIRE_CALLBACKS])
		output_rid = RID()
	var format := RDTextureFormat.new()
	format.width = half.x
	format.height = half.y
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	# CAN_COPY_FROM only so a probe can read the exported distances back; it costs
	# nothing at run time.
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	output_rid = _rd.texture_create(format, RDTextureView.new(), [])
	output_size = half
	_set = RID()
	_set_depth = RID()
