class_name OceanHeightSampler extends RefCounted
## CPU-side reader of the FFT wave height. [OceanSolver] keeps the displacement
## field on the GPU, so cascade 0 is copied back asynchronously (no stall) and
## sampled from that copy: metre-level lag, enough for buoyancy and for testing
## whether a point is under water.
##
## The host must assign [member solver] and call [method poll] every frame.
##
## [codeblock]
## var waves := OceanHeightSampler.new()
## waves.solver = solver
## # in _process:
## waves.poll(delta)
## var h := waves.sample(Vector2(p.x, p.z))
## [/codeblock]

## Choppy displacement shifts a texel's xz away from where it is sampled; only
## the height channel is read, so that error stays sub-wavelength.
const HEIGHT_CHANNEL_OFFSET := 2
const TEXEL_BYTES := 8

var solver: OceanSolver
## Readback period. ~7 Hz is invisible on a wave that takes seconds to pass.
var interval_s := 0.15

var _data := PackedByteArray()
var _accum := 1e9


## Schedules a readback when one is due. Cheap on every other frame.
func poll(delta: float) -> void:
	assert(solver != null, "OceanHeightSampler: solver must be assigned")
	_accum += delta
	if _accum < interval_s:
		return
	_accum = 0.0
	RenderingServer.call_on_render_thread(_request_render)


## Wave height in metres at a world-space xz, 0.0 until the first copy lands.
func sample(world_xz: Vector2) -> float:
	var n := solver.map_size
	if _data.size() < n * n * TEXEL_BYTES:
		return 0.0
	var tile: float = solver.tile_lengths[0]
	var xi := int(fposmod(world_xz.x / tile, 1.0) * n) % n
	var yi := int(fposmod(world_xz.y / tile, 1.0) * n) % n
	return _half_to_float(_data.decode_u16((yi * n + xi) * TEXEL_BYTES + HEIGHT_CHANNEL_OFFSET))


## Bound [method sample], for consumers that take a sampler instead of the whole
## object -- [OceanBuoy], for one.
func sampler() -> Callable:
	return Callable(self, "sample")


func _request_render() -> void:
	var rd := GpuPreflight.device("OceanHeightSampler")
	if rd == null:
		return
	rd.texture_get_data_async(solver.get_displacement_tex_rid(), 0, _store_render)


# Render thread (async readback callback): hop back to the main thread.
func _store_render(data: PackedByteArray) -> void:
	call_deferred("_set_data", data)


func _set_data(data: PackedByteArray) -> void:
	_data = data


func _half_to_float(h: int) -> float:
	var sign := -1.0 if h & 0x8000 else 1.0
	var expo := (h >> 10) & 0x1F
	var mant := h & 0x3FF
	if expo == 0:
		return sign * mant * pow(2.0, -24)
	if expo == 31:
		return sign * 65504.0
	return sign * (1.0 + mant / 1024.0) * pow(2.0, expo - 15)
