class_name FireBillowConfig extends Resource
## Render-time billow detail of the fire volume: noise lattices carried by the flow that
## erode, cool and soot the flame surface. Render-side only, the simulated fields do not
## depend on it. Mode 0 is off; FirePresentation.apply_billow pushes it to the material and
## the solver's rest period is reset_s.

## 0 off, 1 erode, 2 erode + crevice cooling, 3 = 2 + crevice soot.
@export_range(0, 3, 1) var mode := 0
@export_range(0.0, 1.0, 0.01) var strength := 1.0
## Fraction of the emission temperature removed in a full crevice.
@export_range(0.0, 0.9, 0.01) var crevice_cooling_fraction := 0.3
## Extra soot absorption in a full crevice, as a fraction of the soot term.
@export_range(0.0, 4.0, 0.05) var crevice_soot_gain := 1.5
## Longest octave wavelength in grid cells.
@export_range(0.5, 64.0, 0.5) var wavelength_cells := 8.0
## Vertical lattice scale: 0.4 stretches every feature 2.5x along y into licks.
@export_range(0.05, 1.0, 0.01) var vertical_stretch := 1.0
## Height above the ground over which the strength ramps from rise_base to 1; 0 = constant.
@export_range(0.0, 50.0, 0.1) var rise_m := 0.0
@export_range(0.0, 1.0, 0.01) var rise_base := 0.3
## Period of the flow-carried lattices; 0 leaves the detail fixed in world space.
@export_range(0.0, 5.0, 0.05) var reset_s := 0.0
## Temperature window over which the strength fades in: 0 below fade_start_k, full from
## fade_full_k; both 0 = no fade. Keeps cold translucent smoke free of the crease sheets.
@export_range(0.0, 4000.0, 10.0) var fade_start_k := 0.0
@export_range(0.0, 4000.0, 10.0) var fade_full_k := 0.0
## Fraction of the carried displacement applied to the noise lookup.
@export_range(0.0, 1.0, 0.01) var anchor := 1.0


func validate() -> String:
	if mode < 0 or mode > 3:
		return "mode must be 0..3"
	if strength < 0.0 or strength > 1.0:
		return "strength must be within 0..1"
	if crevice_cooling_fraction < 0.0 or crevice_cooling_fraction > 0.9:
		return "crevice_cooling_fraction must be within 0..0.9"
	if crevice_soot_gain < 0.0:
		return "crevice_soot_gain must not be negative"
	if wavelength_cells <= 0.0:
		return "wavelength_cells must be positive"
	if vertical_stretch < 0.05 or vertical_stretch > 1.0:
		return "vertical_stretch must be within 0.05..1"
	if rise_m < 0.0:
		return "rise_m must not be negative"
	if rise_base < 0.0 or rise_base > 1.0:
		return "rise_base must be within 0..1"
	if reset_s < 0.0:
		return "reset_s must not be negative"
	if anchor < 0.0 or anchor > 1.0:
		return "anchor must be within 0..1"
	if fade_start_k < 0.0 or (fade_start_k > 0.0 or fade_full_k > 0.0) and fade_full_k <= fade_start_k:
		return "fade_full_k must exceed fade_start_k, both 0 disables the fade"
	return ""


func rest_active() -> bool:
	return mode > 0 and reset_s > 0.0


## Applies capture overrides named after the shader uniforms (billow_mode, billow_strength,
## billow_cool, billow_soot, billow_stretch_y, billow_rise_m, billow_rise_base,
## billow_anchor) plus billow_wavelength_cells, billow_reset_s and billow_rest. Returns the
## keys it did not consume.
func apply_overrides(values: Dictionary) -> Array[String]:
	var unknown: Array[String] = []
	for key: String in values:
		var value := float(values[key])
		match key:
			"billow_mode": mode = int(value)
			"billow_strength": strength = value
			"billow_cool": crevice_cooling_fraction = value
			"billow_soot": crevice_soot_gain = value
			"billow_wavelength_cells": wavelength_cells = value
			"billow_stretch_y": vertical_stretch = value
			"billow_rise_m": rise_m = value
			"billow_rise_base": rise_base = value
			"billow_reset_s": reset_s = value
			"billow_anchor": anchor = value
			"billow_fade_start_k": fade_start_k = value
			"billow_fade_full_k": fade_full_k = value
			"billow_rest":
				if value == 0.0:
					reset_s = 0.0
			_: unknown.append(key)
	return unknown
