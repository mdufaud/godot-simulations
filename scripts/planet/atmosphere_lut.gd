class_name AtmosphereLut
extends RefCounted
## Bakes the atmosphere's optical-depth lookup table on the GPU and hands it back as
## an R-float texture. One dispatch at startup and whenever the falloff or shell
## thickness changes; the atmosphere shader samples it every step instead of
## raymarching towards the sun.

const SHADER_PATH := "res://shaders/planet/atmosphere_lut.comp"
const SIZE := 256
const WG := 8

var texture: ImageTexture

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _buffer := RID()
var _uniform_set := RID()


func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("Atmosphere LUT: no RenderingDevice")
		return

	var spirv := ShaderCache.compile(_rd, "atmosphere_lut", FileAccess.get_file_as_string(SHADER_PATH))
	if not spirv.compile_error_compute.is_empty():
		push_error("Atmosphere LUT compile error:\n%s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)

	_buffer = _rd.storage_buffer_create(SIZE * SIZE * 4)
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(_buffer)
	_uniform_set = _rd.uniform_set_create([u], _shader, 0)


## Runs on the render thread. Fills `texture` before returning.
func bake(atmosphere_radius_ratio: float, density_falloff: float, num_steps: int) -> void:
	if not _pipeline.is_valid():
		return

	var pc := PackedFloat32Array([atmosphere_radius_ratio, density_falloff, 0.0, 0.0]).to_byte_array()
	pc.encode_u32(8, SIZE)
	pc.encode_s32(12, num_steps)

	var groups := SIZE / WG
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, groups, 1)
	_rd.compute_list_end()

	var bytes := _rd.buffer_get_data(_buffer)
	var image := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RF, bytes)
	if texture == null:
		texture = ImageTexture.create_from_image(image)
	else:
		texture.update(image)


func free_render() -> void:
	if _rd == null:
		return
	if _uniform_set.is_valid() and _rd.uniform_set_is_valid(_uniform_set):
		_rd.free_rid(_uniform_set)
	for rid in [_buffer, _pipeline, _shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_uniform_set = RID()
	_buffer = RID()
	_pipeline = RID()
	_shader = RID()
