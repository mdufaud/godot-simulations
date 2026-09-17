class_name ShaderCache
extends RefCounted
## Persistent SPIR-V cache for runtime-compiled compute shaders.
##
## GLSL sources are compiled once and the resulting bytecode is stored under
## user://shader_cache, keyed by a hash of the exact source string, so any edit
## to a .comp file (or to the #define preamble) produces a new entry.

## Kept distinct from user://shader_cache, which the engine owns.
const CACHE_DIR := "user://compute_shader_cache"
## Files start with this header; anything else on disk (a truncated write from
## a previous implementation, a crash mid-store) is recompiled over.
# static var, not const: PackedByteArray(...) is not a constant expression.
static var MAGIC := PackedByteArray([0x50, 0x47, 0x53, 0x50, 0x56, 0x31])

static var _hits: int = 0
static var _misses: int = 0


## Returns SPIR-V for [param source], reusing the on-disk cache when possible.
## The caller must still check [code]compile_error_compute[/code].
static func compile(rd: RenderingDevice, name: String, source: String) -> RDShaderSPIRV:
	# The engine version joins the key so a driver/Godot upgrade cannot serve
	# SPIR-V produced by a different glslang.
	var path := "%s/%s_%s_%s.spv" % [CACHE_DIR, name,
		"%x" % int(Engine.get_version_info().get("hex", 0)),
		source.sha256_text().substr(0, 16)]

	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		var stored := f.get_buffer(f.get_length())
		f.close()
		if stored.size() > MAGIC.size() and stored.slice(0, MAGIC.size()) == MAGIC:
			var cached := RDShaderSPIRV.new()
			cached.set_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE,
				stored.slice(MAGIC.size()))
			_hits += 1
			return cached

	var src := RDShaderSource.new()
	src.source_compute = source
	var spirv := rd.shader_compile_spirv_from_source(src)
	_misses += 1
	if spirv.compile_error_compute.is_empty():
		_store(path, spirv.get_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE))
	return spirv


## Deletes every cached shader. Returns the number of files removed.
static func clear() -> int:
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return 0
	var removed := 0
	for file in dir.get_files():
		if dir.remove(file) == OK:
			removed += 1
	_hits = 0
	_misses = 0
	return removed


## Total bytes currently held by the cache.
static func size_bytes() -> int:
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return 0
	var total := 0
	for file in dir.get_files():
		var f := FileAccess.open(CACHE_DIR + "/" + file, FileAccess.READ)
		if f != null:
			total += f.get_length()
			f.close()
	return total


static func file_count() -> int:
	var dir := DirAccess.open(CACHE_DIR)
	return 0 if dir == null else dir.get_files().size()


static func _store(path: String, bytecode: PackedByteArray) -> void:
	if bytecode.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	# Write-then-rename: a crash mid-write leaves a .tmp behind instead of a
	# poisoned entry that later launches would trust.
	var file_name := path.get_file()
	var temp := CACHE_DIR + "/" + file_name + ".tmp"
	var f := FileAccess.open(temp, FileAccess.WRITE)
	if f == null:
		push_warning("Shader cache write failed: %s" % temp)
		return
	f.store_buffer(MAGIC)
	f.store_buffer(bytecode)
	f.close()
	var dir := DirAccess.open(CACHE_DIR)
	if dir != null and dir.rename(file_name + ".tmp", file_name) == OK:
		return
	DirAccess.remove_absolute(temp)
