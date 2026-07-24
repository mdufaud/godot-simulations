class_name FireTilePool
extends RefCounted
## GPU sparse tile pool for the fire solver (sparse-grid refactor, Phase 3).
##
## Owns an indirection volume over a virtual tile grid that covers the whole map,
## an atlas of [constant NSLOTS] resident tiles, a free-list stack and compact
## active tile/slot lists. Five compute passes run once per frame — mark, dilate, free,
## alloc, compact — to keep exactly the tiles that contain fire (plus a dilation
## band) resident, at cost proportional to the burning volume rather than the map.
##
## The pool is not yet wired into the simulation stages; that is Phase 4. Here it
## is a standalone, independently verifiable allocator. The RenderingDevice is
## injected so it can run on a local device in a test and on the solver's shared
## device in production.

const SHADER_DIR := "res://shaders/fire/"
const PASSES: Array[String] = ["mark", "dilate", "free", "alloc", "compact"]

## Resident tiles. 16 x 8 x 16 atlas layout = 128 x 64 x 128 atlas cells.
const NSLOTS := 2048
## Virtual tile grid: 256 x 64 x 256 tiles of 8 cells = 409.6 x 102.4 x 409.6 m.
const VTILES := Vector3i(256, 64, 256)
const ATLAS_TILES := Vector3i(16, 8, 16)
const ATLAS_CELLS := Vector3i(128, 64, 128)
const TILE := 8

const INACTIVE := 0xFFFFFFFF

# counts[] words, mirroring tile_common.comp. C_ACTIVE and C_NEW each head a
# three-word dispatch-indirect triple whose y and z are pinned to 1 at bootstrap,
# so the counts buffer doubles as the args buffer for both indirect dispatches.
const C_FREE := 0
const C_REQUEST := 1
const C_FRAME := 2
const C_EXHAUST := 3
const C_PEAK := 4
const C_ACTIVE := 6
const C_NEW := 9
const COUNTS_WORDS := 12
## Byte offsets of the two VkDispatchIndirectCommand triples inside the counts
## buffer, for [method RenderingDevice.compute_list_dispatch_indirect].
const ACTIVE_ARGS_OFFSET := C_ACTIVE * 4
const NEW_ARGS_OFFSET := C_NEW * 4

var initialized := false

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _sets := {}
var _tex := {}     # "indir", "activity"
var _buf := {}     # "slot_meta", "free_list", "active_list", "active_slots", "alloc_request", "counts", "new_list"
var _owns_activity := false
var _budget := NSLOTS
var _pin_lo := Vector3i(1, 1, 1)
var _pin_hi := Vector3i(0, 0, 0)


## Compile the passes and allocate every resource on [param rd]. Returns false on
## a device that cannot run a 512-invocation workgroup or on a compile error;
## the caller must not step a pool that failed to initialise.
##
## [param activity_tex] is the R32F atlas tile_mark reduces. The solver passes its
## own field texture so fire_display can write the keep signal straight into it;
## an invalid RID makes the pool allocate a private one (standalone driver).
func init_render(rd: RenderingDevice, activity_tex := RID(), budget := NSLOTS) -> bool:
	_rd = rd
	_budget = clampi(budget, 1, NSLOTS)
	if activity_tex.is_valid():
		_tex["activity"] = activity_tex
		_owns_activity = false
	else:
		_owns_activity = true
	if _rd == null:
		push_error("FireTilePool needs a RenderingDevice.")
		return false
	if _rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_INVOCATIONS) < 512:
		push_error("FireTilePool needs maxComputeWorkGroupInvocations >= 512.")
		return false

	var common := FileAccess.get_file_as_string(SHADER_DIR + "tile_common.comp")
	for pass_name in PASSES:
		var src := FileAccess.get_file_as_string(SHADER_DIR + "tile_" + pass_name + ".comp")
		var spirv := ShaderCache.compile(_rd, "tile_" + pass_name, "#version 450\n\n" + common + "\n" + src)
		if not spirv.compile_error_compute.is_empty():
			push_error("Tile pass '%s' compile error:\n%s" % [pass_name, spirv.compile_error_compute])
			return false
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[pass_name] = shader
		_pipelines[pass_name] = _rd.compute_pipeline_create(shader)

	_create_resources()
	_build_uniform_sets()
	initialized = true
	return true


func _create_resources() -> void:
	# Sampling: the raymarcher walks the indirection volume with a DDA, so it is
	# read by the render pipeline as well as by the topology passes.
	var img_usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT

	# One volume, two views of the same memory, because the two sides need
	# different formats and neither can be given the other's:
	#
	#   compute  R32_UINT — tile_dilate reserves an entry with an atomic
	#                       compare-and-swap, which only exists on r32ui.
	#   render   RGBA8_UNORM — Texture3DRD maps an RD texture back to an Image
	#                       format to hand it to a material, and no Image format is
	#                       a 32-bit unsigned int. The shader reassembles the four
	#                       bytes; an 8-bit UNORM round-trips through a float
	#                       exactly, which no float format could promise for a slot
	#                       index (0..2047 as raw bits are denormals, and the
	#                       INACTIVE sentinel is a NaN).
	#
	# Both are members of Vulkan's 32-bit format compatibility class, so one can be
	# a shared view of the other. It is the RENDER format that owns the storage:
	# Texture3DRD refuses a shared texture, and texture_update refuses one too, so
	# the owner is the side that has to be sampled and uploaded to.
	var indir_fmt := _make_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, img_usage, VTILES)
	indir_fmt.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	indir_fmt.add_shareable_format(RenderingDevice.DATA_FORMAT_R32_UINT)
	_tex["indir"] = _rd.texture_create(indir_fmt, RDTextureView.new(), [])
	var uint_view := RDTextureView.new()
	uint_view.format_override = RenderingDevice.DATA_FORMAT_R32_UINT
	_tex["indir_storage"] = _rd.texture_create_shared(uint_view, _tex["indir"])
	if _owns_activity:
		_tex["activity"] = _rd.texture_create(
			_make_format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, img_usage, ATLAS_CELLS),
			RDTextureView.new(), [])

	_buf["slot_meta"] = _new_buffer(NSLOTS * 4)
	_buf["free_list"] = _new_buffer(NSLOTS)
	_buf["active_list"] = _new_buffer(NSLOTS)
	_buf["active_slots"] = _new_buffer(NSLOTS)
	_buf["alloc_request"] = _new_buffer(NSLOTS)
	_buf["new_list"] = _new_buffer(NSLOTS)
	# The counts buffer is also the source of both indirect dispatches.
	_buf["counts"] = _new_buffer(COUNTS_WORDS,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	_buf["active_args"] = _new_buffer(3,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)


func _new_buffer(words: int, usage := 0) -> RID:
	var zero := PackedByteArray()
	zero.resize(words * 4)
	return _rd.storage_buffer_create(zero.size(), zero, usage)


func _make_format(format: int, usage: int, dims: Vector3i) -> RDTextureFormat:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = dims.x
	fmt.height = dims.y
	fmt.depth = dims.z
	fmt.format = format
	fmt.usage_bits = usage
	return fmt


func _build_uniform_sets() -> void:
	# One binding layout for every pass; tile_common declares all seven, so a set
	# built against any pass' shader is valid for it. Build one per pass to match
	# the shader each is validated against.
	for pass_name in PASSES:
		var uniforms: Array[RDUniform] = []
		for pair in [[0, _tex["indir_storage"]], [6, _tex["activity"]]]:
			var img := RDUniform.new()
			img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			img.binding = pair[0]
			img.add_id(pair[1])
			uniforms.append(img)
		var bufs := [[1, "slot_meta"], [2, "free_list"], [3, "active_list"],
			[4, "alloc_request"], [5, "counts"], [7, "new_list"], [8, "active_slots"],
			[9, "active_args"]]
		for pair in bufs:
			var b := RDUniform.new()
			b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			b.binding = pair[0]
			b.add_id(_buf[pair[1]])
			uniforms.append(b)
		_sets[pass_name] = _rd.uniform_set_create(uniforms, _shaders[pass_name], 0)


# =========================================================================
#  BOOTSTRAP — seed the resident set (emitter tiles in production, the test's
#  initial cluster here). Rendering thread only.
# =========================================================================

## Make [param vtis] resident, assigned to slots 0..n-1, with every other slot on
## the free list. Overwrites the whole pool state, so it is a reset, not an add.
##
## [param pin_lo]/[param pin_hi] is the inclusive virtual-tile box tile_mark holds
## resident whatever its activity — the emitter's tiles, which must never age out.
## Leave them at the default for an empty box.
func bootstrap(vtis: PackedInt32Array, pin_lo := Vector3i(1, 1, 1),
		pin_hi := Vector3i(0, 0, 0)) -> void:
	var n := mini(vtis.size(), _budget)
	_pin_lo = pin_lo
	_pin_hi = pin_hi

	# Indirection: whole volume to INACTIVE (0xFF bytes), then the seeded entries.
	var indir_bytes := PackedByteArray()
	indir_bytes.resize(VTILES.x * VTILES.y * VTILES.z * 4)
	indir_bytes.fill(0xFF)
	for i in n:
		indir_bytes.encode_u32(vtis[i] * 4, i)
	_rd.texture_update(_tex["indir"], 0, indir_bytes)

	# Atlas starts empty. The solver clears its own fields (this texture among
	# them) when it owns the activity image, so only touch a private one.
	if _owns_activity:
		var act_bytes := PackedByteArray()
		act_bytes.resize(ATLAS_CELLS.x * ATLAS_CELLS.y * ATLAS_CELLS.z * 4)
		_rd.texture_update(_tex["activity"], 0, act_bytes)

	# Slot metadata: seeded slots used, the rest free.
	var meta := PackedByteArray()
	meta.resize(NSLOTS * 4 * 4)
	meta.fill(0)
	for i in n:
		meta.encode_u32((i * 4 + 0) * 4, vtis[i])  # vti
		meta.encode_u32((i * 4 + 1) * 4, 0)         # wanted_frame
		meta.encode_u32((i * 4 + 2) * 4, 1)         # used
		meta.encode_u32((i * 4 + 3) * 4, 0)         # keep
	# Free slots carry INACTIVE as their vti for readback clarity.
	for i in range(n, NSLOTS):
		meta.encode_u32((i * 4 + 0) * 4, INACTIVE)
	_rd.buffer_update(_buf["slot_meta"], 0, meta.size(), meta)

	# Free list: the remaining budgeted slots, stack top = budget - n.
	var free := PackedByteArray()
	free.resize(NSLOTS * 4)
	for i in range(n, _budget):
		free.encode_u32((i - n) * 4, i)
	_rd.buffer_update(_buf["free_list"], 0, free.size(), free)

	var counts := PackedByteArray()
	counts.resize(COUNTS_WORDS * 4)
	counts.encode_u32(C_FREE * 4, _budget - n)
	# The y and z of both dispatch-indirect triples. Written once; nothing else
	# ever touches these four words.
	for word in [C_ACTIVE + 1, C_ACTIVE + 2, C_NEW + 1, C_NEW + 2]:
		counts.encode_u32(word * 4, 1)
	_rd.buffer_update(_buf["counts"], 0, counts.size(), counts)
	var active_args := PackedByteArray()
	active_args.resize(12)
	active_args.encode_u32(0, n)
	active_args.encode_u32(4, 1)
	active_args.encode_u32(8, 1)
	_rd.buffer_update(_buf["active_args"], 0, active_args.size(), active_args)


# =========================================================================
#  PER-FRAME TOPOLOGY
# =========================================================================

## Zero the transient counters. Call before [method RenderingDevice.compute_list_begin],
## since a buffer cannot be updated mid-list.
func reset_frame_counts(frame: int) -> void:
	var zero := PackedByteArray()
	zero.resize(4)
	for word in [C_ACTIVE, C_REQUEST, C_NEW]:
		_rd.buffer_update(_buf["counts"], word * 4, 4, zero)
	var f := PackedByteArray()
	f.resize(4)
	f.encode_u32(0, frame)
	_rd.buffer_update(_buf["counts"], C_FRAME * 4, 4, f)


## Record the five topology passes into an open compute list. Barriers between
## passes make each one see the previous one's writes.
func record(cl: int, frame: int, threshold: float, hold_frames: int, dilate_radius: int) -> void:
	var pc := PackedByteArray()
	pc.resize(48)
	pc.encode_u32(0, frame)
	pc.encode_float(4, threshold)
	pc.encode_u32(8, hold_frames)
	pc.encode_u32(12, dilate_radius)
	for i in 3:
		pc.encode_s32(16 + i * 4, _pin_lo[i])
		pc.encode_s32(32 + i * 4, _pin_hi[i])

	var per_slot := ceili(float(_budget) / 64.0)
	_pass(cl, "mark", _budget, 1, 1, pc)     # one workgroup per slot
	_pass(cl, "dilate", _budget, 1, 1, pc)   # one workgroup per slot
	_pass(cl, "free", per_slot, 1, 1, pc)
	_pass(cl, "alloc", NSLOTS, 1, 1, pc)    # one workgroup per possible request
	_pass(cl, "compact", per_slot, 1, 1, pc)


func _pass(cl: int, name: String, gx: int, gy: int, gz: int, pc: PackedByteArray) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[name])
	_rd.compute_list_bind_uniform_set(cl, _sets[name], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, gz)
	_rd.compute_list_add_barrier(cl)


# =========================================================================
#  ATLAS / READBACK — production binds its own atlas; these serve the Phase 3
#  standalone driver.
# =========================================================================

## Overwrite the whole activity image (128 x 64 x 128 floats, slot-block layout).
func set_activity(bytes: PackedByteArray) -> void:
	_rd.texture_update(_tex["activity"], 0, bytes)


## Indirection volume and tile lists, for the solver to bind into its own stage
## uniform sets. Invalid until [method init_render] has succeeded.
## The r32ui view, for the compute passes that store into it.
func indir_rid() -> RID:
	return _tex.get("indir_storage", RID())


## The same volume as RGBA8_UNORM, which is the view a Texture3DRD can hand to the
## raymarcher. Sampled only — every write goes through [method indir_rid].
func indir_bytes_rid() -> RID:
	return _tex.get("indir", RID())


func active_list_rid() -> RID:
	return _buf.get("active_list", RID())


func active_slots_rid() -> RID:
	return _buf.get("active_slots", RID())


func active_args_rid() -> RID:
	return _buf.get("active_args", RID())


func new_list_rid() -> RID:
	return _buf.get("new_list", RID())


## Also the dispatch-indirect args buffer; see [constant ACTIVE_ARGS_OFFSET].
func counts_rid() -> RID:
	return _buf.get("counts", RID())


func budget() -> int:
	return _budget


func atlas_origin(slot: int) -> Vector3i:
	return Vector3i(slot % ATLAS_TILES.x,
		(slot / ATLAS_TILES.x) % ATLAS_TILES.y,
		slot / (ATLAS_TILES.x * ATLAS_TILES.y)) * TILE


static func vti_of(vt: Vector3i) -> int:
	return vt.x + vt.y * VTILES.x + vt.z * VTILES.x * VTILES.y


static func vt_of(vti: int) -> Vector3i:
	return Vector3i(vti % VTILES.x, (vti / VTILES.x) % VTILES.y,
		vti / (VTILES.x * VTILES.y))


func read_counts() -> PackedInt32Array:
	var bytes := _rd.buffer_get_data(_buf["counts"], 0, COUNTS_WORDS * 4)
	var out := PackedInt32Array()
	out.resize(COUNTS_WORDS)
	for i in COUNTS_WORDS:
		out[i] = bytes.decode_u32(i * 4)
	return out


func read_slot_meta() -> PackedInt32Array:
	var bytes := _rd.buffer_get_data(_buf["slot_meta"], 0, NSLOTS * 4 * 4)
	var out := PackedInt32Array()
	out.resize(NSLOTS * 4)
	for i in NSLOTS * 4:
		out[i] = bytes.decode_u32(i * 4)
	return out


func read_free_list() -> PackedInt32Array:
	var bytes := _rd.buffer_get_data(_buf["free_list"], 0, NSLOTS * 4)
	var out := PackedInt32Array()
	out.resize(NSLOTS)
	for i in NSLOTS:
		out[i] = bytes.decode_u32(i * 4)
	return out


## Virtual tile indices of the resident tiles, compacted by tile_compact. This is
## what the solver's stages index by gl_WorkGroupID; it holds tiles, not slots.
func read_active_list(count: int) -> PackedInt32Array:
	return _read_words(_buf["active_list"], count)


func _read_words(buf: RID, count: int) -> PackedInt32Array:
	var n := clampi(count, 0, NSLOTS)
	var out := PackedInt32Array()
	if n == 0:
		return out
	var bytes := _rd.buffer_get_data(buf, 0, n * 4)
	out.resize(n)
	for i in n:
		out[i] = bytes.decode_u32(i * 4)
	return out


## Virtual tiles allocated this frame, which the solver's clear stage resets to
## ambient air before anything reads them.
func read_new_list(count: int) -> PackedInt32Array:
	return _read_words(_buf["new_list"], count)


## Slot occupying virtual tile [param vt] per the indirection volume, or -1 if
## inactive. Reads back the whole 16 MB volume, so use it for spot checks only.
func read_indir_slot(vt: Vector3i) -> int:
	var bytes := _rd.texture_get_data(_tex["indir"], 0)
	var off := (vt.x + vt.y * VTILES.x + vt.z * VTILES.x * VTILES.y) * 4
	var v := bytes.decode_u32(off)
	return -1 if v >= 0xFFFFFFF0 else v


func free_render() -> void:
	if _rd == null:
		return
	initialized = false
	for name in _sets:
		if _sets[name].is_valid():
			_rd.free_rid(_sets[name])
	_sets.clear()
	for key in _buf:
		if _buf[key].is_valid():
			_rd.free_rid(_buf[key])
	_buf.clear()
	# Before its owner: freeing the indirection volume first would drop the shared
	# view with it and the loop below would then free an ID that is already gone.
	var shared: RID = _tex.get("indir_storage", RID())
	if shared.is_valid():
		_rd.free_rid(shared)
	_tex.erase("indir_storage")
	for key in _tex:
		# A borrowed activity image belongs to the solver, which frees it itself.
		if _tex[key].is_valid() and (key != "activity" or _owns_activity):
			_rd.free_rid(_tex[key])
	_tex.clear()
	for name in _pipelines:
		if _pipelines[name].is_valid():
			_rd.free_rid(_pipelines[name])
	_pipelines.clear()
	for name in _shaders:
		if _shaders[name].is_valid():
			_rd.free_rid(_shaders[name])
	_shaders.clear()
