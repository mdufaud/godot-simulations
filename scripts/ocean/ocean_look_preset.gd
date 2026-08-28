class_name OceanLookPreset extends Resource

@export var display_name := "Golden Hour"

@export_group("Sun")
@export_range(2.0, 80.0, 0.1) var sun_elevation := 8.0
@export_range(0.0, 360.0, 0.1) var sun_azimuth := 180.0
@export var sun_color := Color(1.0, 0.62, 0.32)
@export_range(0.0, 8.0, 0.05) var sun_energy := 2.4
@export_range(0.1, 2.0, 0.05) var sun_angular_distance := 0.65

@export_group("Sky")
@export var sky_zenith := Color(0.055, 0.18, 0.43)
@export var sky_horizon := Color(0.95, 0.43, 0.18)
@export var sun_disk_color := Color(1.0, 0.78, 0.42)
@export var haze_color := Color(0.82, 0.3, 0.13)
@export_range(0.0, 4.0, 0.05) var sky_energy := 1.35

@export_group("Environment")
@export_range(0.1, 4.0, 0.05) var exposure := 1.15
@export_range(1.0, 16.0, 0.1) var white_point := 10.0
@export var fog_color := Color(0.63, 0.31, 0.18)
@export_range(0.0, 0.01, 0.00005) var fog_density := 0.00045
@export_range(0.0, 1.0, 0.01) var fog_aerial_perspective := 0.42
@export_range(0.0, 2.0, 0.01) var glow_intensity := 0.32
@export_range(0.0, 1.0, 0.01) var glow_bloom := 0.08
@export_range(0.0, 4.0, 0.05) var glow_hdr_threshold := 1.0

@export_group("Water")
@export var deep_color := Color(0.015, 0.12, 0.22)
@export var shallow_color := Color(0.025, 0.52, 0.52)
@export var foam_color := Color(0.88, 0.88, 0.76)
@export_range(0.02, 0.8, 0.01) var roughness := 0.11
@export_range(0.0, 3.0, 0.01) var sss_strength := 1.35
@export_range(0.002, 0.06, 0.001) var sun_path_width := 0.018
@export_range(0.0, 3.0, 0.01) var sun_glitter_strength := 0.72
@export_range(0.0, 2.0, 0.01) var sky_reflection_strength := 0.7
@export_range(0.0, 2.0, 0.01) var micro_normal_strength := 0.13
@export var micro_normal_scales := Vector2(0.085, 0.23)
@export_range(5.0, 500.0, 1.0) var micro_normal_fade_start := 70.0
@export_range(10.0, 1000.0, 1.0) var micro_normal_fade_end := 360.0
# Far-water aerial convergence toward the sky (P0-C.3), 1/m.
@export_range(0.0, 0.001, 0.00001) var aerial_density := 0.00025

@export_group("Clouds")
@export_range(0.0, 1.0, 0.01) var cloud_coverage := 0.78
@export_range(0.0, 1.0, 0.01) var cloud_density := 0.78
@export var cloud_top_color := Color(1.0, 0.77, 0.55)
@export var cloud_base_color := Color(0.23, 0.19, 0.24)
@export var cloud_rim_color := Color(1.0, 0.64, 0.3)
@export_range(0.0, 3.0, 0.01) var cloud_rim_strength := 1.25

@export_group("Storm")
@export_range(0.0, 1.0, 0.01) var rain_intensity := 0.0


func validate() -> String:
	if display_name.is_empty():
		return "display_name cannot be empty"
	if micro_normal_fade_end <= micro_normal_fade_start:
		return "micro_normal_fade_end must exceed micro_normal_fade_start"
	if cloud_coverage < 0.0 or cloud_coverage > 1.0:
		return "cloud_coverage must be in 0..1"
	if rain_intensity < 0.0 or rain_intensity > 1.0:
		return "rain_intensity must be in 0..1"
	return ""
