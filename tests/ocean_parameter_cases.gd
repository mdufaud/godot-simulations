extends RefCounted

const BINDINGS := {
	"wave_model": {"solver": "wave_model"},
	"wind_speed_mps": {"solver": "wind_speed", "menu": "_wind_speed"},
	"fetch_km": {"solver": "fetch_km", "menu": "_fetch"},
	"swell": {"solver": "swell", "menu": "_swell"},
	"spread": {"solver": "spread", "menu": "_spread"},
	"detail": {"solver": "detail", "menu": "_detail"},
	"jonswap_gamma": {"solver": "jonswap_gamma", "menu": "_jonswap_gamma"},
	"swell_height_m": {"solver": "swell_height_m", "menu": "_swell_height"},
	"swell_period_s": {"solver": "swell_period_s", "menu": "_swell_period"},
	"swell_direction_rad": {"solver": "swell_direction_rad", "menu": "_swell_direction"},
	"swell_spread": {"solver": "swell_spread", "menu": "_swell_spread"},
	"current_velocity_m_s": {
		"solver": "current_velocity_m_s",
		"menu": ["_current_x", "_current_z"],
	},
	"choppiness": {"solver": "choppiness", "menu": "_choppiness"},
	"amplitude_scale": {"solver": "amplitude_scale"},
	"height_gain": {"solver": "height_gain", "menu": "_height_gain"},
	"long_wave_height_m": {"solver": "long_wave_height_m"},
	"long_wave_length_m": {"solver": "long_wave_length_m"},
	"mid_wave_height_m": {"solver": "mid_wave_height_m"},
	"mid_wave_length_m": {"solver": "mid_wave_length_m"},
	"wind_wave_height_m": {"solver": "wind_wave_height_m"},
	"wind_wave_length_m": {"solver": "wind_wave_length_m"},
	"crest_bias": {"solver": "crest_bias", "menu": "_crest_bias"},
	"crest_gain": {"solver": "crest_gain", "menu": "_crest_gain"},
	"whitecap": {"solver": "whitecap", "menu": "_whitecap"},
	"foam_amount": {"solver": "foam_amount", "menu": "_foam_amount"},
	"foam_persistence": {"solver": "foam_persistence", "menu": "_foam_persistence"},
	"spray_amount": {"menu": "_spray_amount", "host": "spray.amount"},
	"storm_mood": {"menu": "_mood", "host": "storm.mood_target"},
}

const PRESET_PATHS := [
	"res://resources/ocean/presets/calm.tres",
	"res://resources/ocean/presets/breeze.tres",
	"res://resources/ocean/presets/swell.tres",
	"res://resources/ocean/presets/storm.tres",
]

const CONTROLS := [
	{"menu": "_wind_direction", "host": "solver.wind_direction"},
	{"menu": "_foam_strength", "shader": "foam_strength"},
	{"menu": "_foam_distance", "host": "solver.foam_near_domain", "multiplier": 2.0},
	{"menu": "_detail_distance", "shader": "detail_distance_m"},
	{"menu": "_sun_elevation", "host": "sun_elevation"},
	{"menu": "_sun_azimuth", "host": "sun_azimuth"},
	{"menu": "_sun_glitter_intensity", "shader": "sun_glitter_strength"},
	{"key": "Waves/Time scale", "host": "time_scale"},
	{"key": "Performance/Render scale", "viewport": "scaling_3d_scale"},
]

const SWELL_REGRESSIONS := [
	{"name": "swell_spread_0.01_cardinal", "spread": 0.01, "direction": 0.0},
	{"name": "swell_spread_0.01_half_angle", "spread": 0.01, "direction": TAU / 128.0},
	{"name": "swell_spread_0.05_cardinal", "spread": 0.05, "direction": 0.0},
	{"name": "swell_spread_0.15_oblique", "spread": 0.15, "direction": 0.5},
]

const EXTREME_REGRESSIONS := [
	{"name": "storm", "changes": {}, "minimum_hs_m": 0.0},
	{"name": "storm_gain5", "changes": {"height_gain": 5.0}, "minimum_hs_m": 10.0},
	{"name": "long_swell_max", "changes": {"wind_speed_mps": 35.0,
		"fetch_km": 1000.0, "swell_height_m": 12.0, "swell_period_s": 30.0,
		"amplitude_scale": 2.0, "height_gain": 5.0, "choppiness": 1.8,
		"jonswap_gamma": 7.0}, "minimum_hs_m": 10.0},
	{"name": "short_swell_max", "changes": {"wind_speed_mps": 35.0,
		"fetch_km": 1000.0, "swell_height_m": 12.0, "swell_period_s": 2.0,
		"amplitude_scale": 2.0, "height_gain": 5.0, "choppiness": 1.8,
		"jonswap_gamma": 7.0}, "minimum_hs_m": 10.0, "minimum_slope_rms": 0.17},
]

const CONFIG_CASES := [
	{"name": "default", "changes": {}, "valid": true},
	{"name": "fft_low", "changes": {"map_size": 256}, "valid": true},
	{"name": "fft_high", "changes": {"map_size": 1024}, "valid": true},
	{"name": "fft_non_power", "changes": {"map_size": 768}, "valid": false},
	{"name": "fft_too_small", "changes": {"map_size": 128}, "valid": false},
	{"name": "fft_too_large", "changes": {"map_size": 2048}, "valid": false},
	{"name": "levels_lower", "changes": {"clipmap_levels": 1}, "valid": true},
	{"name": "levels_upper", "changes": {"clipmap_levels": 32}, "valid": true},
	{"name": "levels_below", "changes": {"clipmap_levels": 0}, "valid": false},
	{"name": "levels_above", "changes": {"clipmap_levels": 33}, "valid": false},
	{"name": "cell_lower", "changes": {"finest_cell_m": 0.001}, "valid": true},
	{"name": "cell_upper", "changes": {"finest_cell_m": 100.0}, "valid": true},
	{"name": "cell_below", "changes": {"finest_cell_m": 0.0005}, "valid": false},
	{"name": "cell_above", "changes": {"finest_cell_m": 100.001}, "valid": false},
	{"name": "cell_nan", "changes": {"finest_cell_m": NAN}, "valid": false},
	{"name": "cell_inf", "changes": {"finest_cell_m": INF}, "valid": false},
	{"name": "tiles_count", "changes": {"clipmap_tile_lengths_m": [2039.0, 111.0]}, "valid": false},
	{"name": "tiles_order", "changes": {"clipmap_tile_lengths_m": [25.0, 111.0, 2039.0]}, "valid": false},
	{"name": "tiles_nan", "changes": {"clipmap_tile_lengths_m": [NAN, 111.0, 25.0]}, "valid": false},
	{"name": "tiles_gap", "changes": {"clipmap_tile_lengths_m": [2039.0, 30.0, 5.0]}, "valid": false},
]


static func snapshot(preset: OceanPreset) -> Dictionary:
	var result := {}
	for property in _exported_properties(preset):
		var field: String = property.name
		var value = preset.get(field)
		if value is Vector2:
			value = [_logged_number(value.x), _logged_number(value.y)]
		elif value is float and not is_finite(value):
			value = "NaN" if is_nan(value) else ("Infinity" if value > 0.0 else "-Infinity")
		result[field] = value
	return result


static func _logged_number(value: float) -> Variant:
	return value if is_finite(value) else ("NaN" if is_nan(value)
		else ("Infinity" if value > 0.0 else "-Infinity"))


static func unmapped_fields(preset: OceanPreset) -> PackedStringArray:
	var result := PackedStringArray()
	for property in _exported_properties(preset):
		var field: String = property.name
		if field != "display_name" and not BINDINGS.has(field):
			result.append(field)
	return result


static func cases() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for path: String in PRESET_PATHS:
		var preset := load(path) as OceanPreset
		result.append({
			"name": "preset_%s" % preset.display_name.to_lower().replace(" ", "_"),
			"input": preset.duplicate(true),
			"parameter": "",
			"value": snapshot(preset),
			"valid": true,
			"tags": ["preset", "baseline"],
		})

	var baseline := load(PRESET_PATHS[1]) as OceanPreset
	for property in _exported_properties(baseline):
		var field: String = property.name
		if field == "display_name" or not BINDINGS.has(field):
			continue
		if property.hint == PROPERTY_HINT_RANGE:
			var limits := _range_limits(String(property.hint_string))
			if limits.size() == 2:
				for bound_index in 2:
					var value: float = limits[bound_index]
					var input := baseline.duplicate(true) as OceanPreset
					input.set(field, value)
					result.append({
						"name": "%s_%s" % [field, "lower" if bound_index == 0 else "upper"],
						"input": input,
						"parameter": field,
						"value": value,
						"valid": true,
						"tags": ["range", "lower" if bound_index == 0 else "upper"],
					})
				for entry in [
					{"name": "below", "value": limits[0] - 0.001},
					{"name": "above", "value": limits[1] + 0.001},
				]:
					var input := baseline.duplicate(true) as OceanPreset
					input.set(field, entry.value)
					result.append({"name": "%s_%s" % [field, entry.name],
						"input": input, "parameter": field, "value": entry.value,
						"valid": false, "tags": ["outside_range"]})
		if property.type == TYPE_FLOAT:
			for invalid_value in [{"suffix": "nan", "value": NAN}, {"suffix": "inf", "value": INF}]:
				var input := baseline.duplicate(true) as OceanPreset
				var value: float = invalid_value.value
				input.set(field, value)
				result.append({
					"name": "%s_%s" % [field, invalid_value.suffix],
					"input": input,
					"parameter": field,
					"value": value,
					"valid": false,
					"tags": ["nonfinite", invalid_value.suffix],
				})

	var enum_property := _property(baseline, "wave_model")
	var enum_values: PackedStringArray = String(enum_property.hint_string).split(",")
	for enum_index in enum_values.size():
		var input := baseline.duplicate(true) as OceanPreset
		input.wave_model = enum_index as OceanPreset.WaveModel
		result.append({
			"name": "wave_model_%s" % enum_values[enum_index].to_lower(),
			"input": input,
			"parameter": "wave_model",
			"value": enum_index,
			"valid": true,
			"tags": ["enum"],
		})
	var invalid_model := baseline.duplicate(true) as OceanPreset
	invalid_model.set("wave_model", 99)
	result.append({"name": "wave_model_invalid", "input": invalid_model,
		"parameter": "wave_model", "value": 99, "valid": false, "tags": ["enum"]})

	for entry in [
		{"name": "negative", "value": Vector2(-5.0, -5.0)},
		{"name": "zero", "value": Vector2.ZERO},
		{"name": "positive", "value": Vector2(5.0, 5.0)},
		{"name": "nan_x", "value": Vector2(NAN, 0.0)},
		{"name": "nan_z", "value": Vector2(0.0, NAN)},
		{"name": "inf_x", "value": Vector2(INF, 0.0)},
		{"name": "inf_z", "value": Vector2(0.0, INF)},
	]:
		var input := baseline.duplicate(true) as OceanPreset
		input.current_velocity_m_s = entry.value
		result.append({
			"name": "current_%s" % entry.name,
			"input": input,
			"parameter": "current_velocity_m_s",
			"value": entry.value,
			"valid": (entry.value as Vector2).is_finite(),
			"tags": ["vector", "current"],
		})

	for swell_case: Dictionary in SWELL_REGRESSIONS:
		var input := baseline.duplicate(true) as OceanPreset
		input.swell_height_m = 1.0
		input.swell_spread = swell_case.spread
		input.swell_direction_rad = swell_case.direction
		result.append({
			"name": swell_case.name,
			"input": input,
			"parameter": "swell_height_m+swell_spread+swell_direction_rad",
			"value": {
				"height_m": 1.0,
				"spread": swell_case.spread,
				"direction_rad": swell_case.direction,
			},
			"valid": true,
			"tags": ["swell_normalization", "narrow"],
		})

	return result


static func _exported_properties(preset: OceanPreset) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for property: Dictionary in preset.get_property_list():
		var usage: int = property.usage
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_STORAGE:
			result.append(property)
	return result


static func _property(preset: OceanPreset, field: String) -> Dictionary:
	for property in _exported_properties(preset):
		if property.name == field:
			return property
	return {}


static func _range_limits(hint_string: String) -> PackedFloat64Array:
	var parts := hint_string.split(",")
	if parts.size() < 2:
		return PackedFloat64Array()
	return PackedFloat64Array([float(parts[0]), float(parts[1])])
