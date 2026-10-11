extends "res://tests/test_case.gd"

const Config := preload("res://scripts/ocean/ocean_coastal_config.gd")


func _initialize() -> void:
	var config := _valid_config()
	_check(config.validate().is_empty(), "default populated coastal config is invalid")
	config.domain_m = NAN
	_check(not config.validate().is_empty(), "NaN domain was accepted")
	config = _valid_config()
	config.gravity_m_s2 = INF
	_check(not config.validate().is_empty(), "infinite gravity was accepted")
	config = _valid_config()
	config.boundary_depth_m = -1.0
	_check(not config.validate().is_empty(), "negative boundary depth was accepted")
	config = _valid_config()
	config.bathymetry_elevation_m[3] = NAN
	_check(not config.validate().is_empty(), "non-finite bathymetry was accepted")
	config = _valid_config()
	config.bathymetry_elevation_m.resize(5)
	_check(not config.validate().is_empty(), "mismatched bathymetry was accepted")
	config = _valid_config()
	config.max_supported_grid = 768
	config.grid_sizes_cells = [128, 256, 384, 768]
	_check(not config.validate().is_empty(), "resolution beyond the kernel capacity was accepted")
	config = _valid_config()
	config.break_froude_end = config.break_froude_start
	_check(not config.validate().is_empty(), "unordered breaking thresholds were accepted")
	config = _valid_config()
	config.dispersive_tolerance = 0.0
	_check(not config.validate().is_empty(), "zero solve tolerance was accepted")
	config = _valid_config()
	config.sponge_width_m = config.domain_m
	_check(not config.validate().is_empty(), "sponge larger than the active domain was accepted")
	config = _valid_config()
	config.breaker_max_radius_m = NAN
	_check(not config.validate().is_empty(), "non-finite visual breaker radius was accepted")
	config = _valid_config()
	config.contact_retention_s = 0.0
	_check(not config.validate().is_empty(), "zero rock contact retention was accepted")
	config = _valid_config()
	config.visual_blend_width_m = 0.0
	_check(not config.validate().is_empty(), "zero visual blend width was accepted")
	config.visual_blend_width_m = config.domain_m
	_check(not config.validate().is_empty(), "visual blend wider than half the domain was accepted")
	config = _valid_config()
	config.visual_foam_texture_sizes_px[1] = 500
	_check(not config.validate().is_empty(), "non-power-of-two foam texture size was accepted")
	config = _valid_config()
	_check(config.foam_texture_size_px(1, 1024) == 1024, "physical coast changed the offshore foam budget")
	_check(config.resolution_cells(1) == 256, "physical coast changed its resolution")
	config.visual_breakers_enabled = true
	_check(config.foam_texture_size_px(1, 1024) == 512, "visual Medium foam budget was not applied")
	_check(config.resolution_cells(1) == 160, "visual Medium coast budget was not applied")
	config.visual_surface_depth_blend_m = Vector2(8.0, 2.0)
	_check(not config.validate().is_empty(), "reversed surface depth blend was accepted")
	config.visual_surface_depth_blend_m = Vector2(NAN, 8.0)
	_check(not config.validate().is_empty(), "non-finite surface depth blend was accepted")
	_finish("ocean_coastal_config")


func _valid_config() -> Config:
	var config := Config.new()
	config.selected_resolution_cells = 128
	config.bathymetry_elevation_m.resize(128 * 128)
	config.bathymetry_elevation_m.fill(-16.0)
	return config
