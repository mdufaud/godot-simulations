extends "res://tests/test_case.gd"

const SHADER_DIR := "res://shaders/ocean/"
const SpectrumMetrics := preload("res://scripts/ocean/ocean_spectrum_metrics.gd")
const GDSCRIPT_OWNED_DEFINES := ["NUM_SPECTRA", "LOCAL_SPECTRA", "MAX_IMPULSES", "WATER_DENSITY",
	"LOCAL_COAST_DOMAIN_M", "LOCAL_WAKE_DOMAIN_M"]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_glsl_has_no_owned_defines()
	_check_injected_headers()
	_check_jonswap_push_constants()
	_check_cascade_capacity()
	_check_spray_grid()
	_check_shared_values()
	_finish("ocean_ssot")


func _check_glsl_has_no_owned_defines() -> void:
	var define := RegEx.create_from_string("#define\\s+(\\w+)")
	var fixed_array := RegEx.create_from_string("\\w+\\s*\\[\\s*\\d+\\s*\\]\\s*;")
	for file in DirAccess.get_files_at(SHADER_DIR):
		if not file.ends_with(".comp"):
			continue
		var source := FileAccess.get_file_as_string(SHADER_DIR + file)
		for found in define.search_all(source):
			_check(not GDSCRIPT_OWNED_DEFINES.has(found.get_string(1)),
				"%s re-defines GDScript-owned %s" % [file, found.get_string(1)])
		if file == "ocean_local_common.comp":
			_check(fixed_array.search(source) == null,
				"%s sizes a buffer array with a literal instead of MAX_IMPULSES" % file)


func _check_injected_headers() -> void:
	var ocean := OceanSolver.shader_header(512)
	_check(ocean.contains("#define NUM_SPECTRA %du\n" % OceanSolver.NUM_SPECTRA),
		"ocean header lacks NUM_SPECTRA %d" % OceanSolver.NUM_SPECTRA)
	_check(ocean.contains("#define MAP_SIZE 512u\n"), "ocean header lacks MAP_SIZE")
	var velocity := OceanVelocitySolver.shader_header()
	_check(velocity.contains("#define NUM_SPECTRA %du\n" % OceanVelocitySolver.NUM_SPECTRA),
		"velocity header lacks NUM_SPECTRA %d" % OceanVelocitySolver.NUM_SPECTRA)
	var shore := OceanShoreSolver.shader_header()
	_check(shore.contains("#define NUM_SPECTRA %du\n" % OceanShoreSolver.NUM_SPECTRA),
		"shore header lacks NUM_SPECTRA %d" % OceanShoreSolver.NUM_SPECTRA)
	var local := OceanLocalSolver.shader_header(128)
	_check(local.contains("#define LOCAL_SPECTRA %du\n" % OceanLocalSolver.NUM_SPECTRA),
		"local header lacks LOCAL_SPECTRA %d" % OceanLocalSolver.NUM_SPECTRA)
	_check(local.contains("#define MAX_IMPULSES %du\n" % OceanLocalSolver.MAX_IMPULSES),
		"local header lacks MAX_IMPULSES %d" % OceanLocalSolver.MAX_IMPULSES)
	_check(local.contains("#define WATER_DENSITY %.6f\n" % OceanSolver.WATER_DENSITY_KG_M3),
		"local header lacks WATER_DENSITY %.1f" % OceanSolver.WATER_DENSITY_KG_M3)
	var domains := OceanLocalSolver.domain_defines()
	_check(domains.contains("#define LOCAL_COAST_DOMAIN_M %.6f\n" % OceanLocalSolver.COAST_DOMAIN_M)
		and domains.contains("#define LOCAL_WAKE_DOMAIN_M %.6f\n" % OceanLocalSolver.WAKE_DOMAIN_M),
		"local domain defines do not carry the solver domain lengths")
	var spray := FileAccess.get_file_as_string(SHADER_DIR + "ocean_spray_update.comp")
	_check(spray.contains("LOCAL_COAST_DOMAIN_M") and spray.contains("LOCAL_WAKE_DOMAIN_M"),
		"spray update samples local fields without the injected domain lengths")


func _check_jonswap_push_constants() -> void:
	var evolve := FileAccess.get_file_as_string(SHADER_DIR + "ocean_spectrum_evolve.comp")
	_check(not evolve.contains("0.076") and not evolve.contains("22.0"),
		"spectrum_evolve re-derives the JONSWAP alpha / peak frequency")
	var solver := OceanSolver.new()
	for wind in [0.5, 4.0, 11.0, 22.0, 35.0]:
		for fetch in [5.0, 120.0, 1000.0]:
			for amplitude in [0.0, 0.4, 1.0, 2.5]:
				solver.wind_speed = wind
				solver.fetch_km = fetch
				solver.amplitude_scale = amplitude
				var pc := solver._pack_push_constant(0)
				var scale := solver.effective_amplitude_scale()
				var alpha := SpectrumMetrics.jonswap_alpha(wind, fetch * 1000.0) * scale * scale
				var peak := SpectrumMetrics.jonswap_peak_frequency(wind, fetch * 1000.0)
				var label := "wind=%.1f fetch=%.0f amplitude=%.1f" % [wind, fetch, amplitude]
				_check(is_equal_approx(pc.decode_float(52), scale),
					"%s: pushed amplitude %.6f != %.6f" % [label, pc.decode_float(52), scale])
				_check(is_equal_approx(pc.decode_float(4), alpha),
					"%s: pushed alpha %.8f != %.8f" % [label, pc.decode_float(4), alpha])
				_check(is_equal_approx(pc.decode_float(8), peak),
					"%s: pushed peak %.6f != %.6f" % [label, pc.decode_float(8), peak])


func _check_cascade_capacity() -> void:
	_check(OceanSolver.TILE_LENGTHS.size() == OceanConfig.CASCADE_COUNT,
		"TILE_LENGTHS has %d cascades, OceanConfig.CASCADE_COUNT is %d" % [
			OceanSolver.TILE_LENGTHS.size(), OceanConfig.CASCADE_COUNT])
	_check(OceanSolver.CHOP_PER_CASCADE.size() == OceanConfig.CASCADE_COUNT,
		"CHOP_PER_CASCADE size differs from OceanConfig.CASCADE_COUNT")
	var capacity := RegEx.create_from_string("#define\\s+(?:MAX_)?CASCADES\\s+(\\d+)")
	for file in ["ocean_surface.gdshader", "ocean_intersection_capture.gdshader", "ocean_spray.gdshader"]:
		var found := capacity.search(FileAccess.get_file_as_string(SHADER_DIR + file))
		_check(found != null and int(found.get_string(1)) == OceanConfig.CASCADE_COUNT,
			"%s cascade capacity differs from OceanConfig.CASCADE_COUNT %d" % [file, OceanConfig.CASCADE_COUNT])


func _check_spray_grid() -> void:
	var source := FileAccess.get_file_as_string(SHADER_DIR + "ocean_spray.gdshader")
	_check(not RegEx.create_from_string("#define\\s+GRID\\b").search(source),
		"ocean_spray.gdshader re-types the spray GRID owned by ocean_spray.gd")
	_check(source.contains("uniform int grid_cells"), "ocean_spray.gdshader lacks the pushed grid_cells")


func _check_shared_values() -> void:
	_check(OceanBuoy.WATER_DENSITY_KG_M3 == OceanSolver.WATER_DENSITY_KG_M3,
		"buoy and solver water density differ")
	_check(OceanLocalSolver.VELOCITY_MAP_N == OceanVelocitySolver.VELOCITY_SIZE,
		"local solver velocity map size differs from the velocity solver")
