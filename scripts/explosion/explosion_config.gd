class_name ExplosionConfig extends Resource
## Grid and clock of one explosion system. Charges are separate resources.

## The solver refreshes its tile topology once per frame (or every topology_interval_steps) and keeps a one-tile
## dilation band, so the field may not travel further than this between refreshes.
const BAND_CELLS := 8.0
## Shortest curl-noise wavelength in cells, and the tile edge it may not be a multiple of.
const TURBULENCE_MIN_CELLS := 5.0
const TILE_CELLS := float(FireTilePool.TILE)
## Seconds over which confinement fades in once the detonation pulse has ended.
const VORTICITY_RAMP_S := 0.3

@export_range(0.05, 5.0, 0.01) var cell_size_m := 0.2
@export_range(5, 120, 1) var simulation_hz := 60
@export_range(1, 4, 1) var max_substeps_per_frame := 2
## Substeps between tile topology refreshes within a frame; 0 refreshes once per frame.
@export_range(0, 4, 1) var topology_interval_steps := 0
@export_range(5.0, 300.0, 0.5) var velocity_clamp_mps := 45.0
@export_range(0.05, 20.0, 0.05) var keep_speed_mps := 0.5
## Resident tile capacity: 2048 or 4096 (the large atlas needs 16 KB of compute shared memory, else the solver falls back).
@export_range(2048, 4096, 2048) var pool_slots := 2048
## Multiplies the cut-offs that keep a tile resident; above 1 the faint smoke tail is released sooner.
@export_range(1.0, 16.0, 0.5) var tile_keep_scale := 1.0
## Dimensionless confinement applied after the pulse only; during it the field is off, at 8 it carves terraces into the fireball.
@export_range(0.0, 50.0, 0.1) var vorticity_strength := 0.0
## Fire-X Tab. 3 radiative loss; higher cools the fireball into smoke sooner.
@export_range(0.0, 6.0, 0.1) var radiation_coefficient := 1.0
## Soot settling per second in cold cells.
@export_range(0.0, 0.1, 0.005) var residual_dissipation := 0.03
## Curl-noise disturbance, scaled by |u - wind|^2 / wavelength: dimensionless, 0 disables it. Acts after the pulse, on the same ramp as confinement.
@export_range(0.0, 2.0, 0.01) var turbulence_strength := 0.0
@export_range(0.1, 50.0, 0.05) var turbulence_wavelength_m := 1.0
## Window of face temperature the disturbance acts in: zero at both edges, peak in the middle.
@export_range(250.0, 4000.0, 10.0) var turbulence_band_lo_k := 500.0
@export_range(250.0, 4000.0, 10.0) var turbulence_band_hi_k := 1800.0
## Time the noise pattern takes to drift one wavelength.
@export_range(0.05, 10.0, 0.05) var turbulence_evolution_s := 0.5
## Emission temperature window of the render: no glow below the first, full glow from the second; both 0 = off.
## Soot stops glowing near 800 K (Draper point), so the cold smoke skin is drawn dark instead of red-brown.
@export_range(0.0, 4000.0, 10.0) var glow_visible_from_k := 800.0
@export_range(0.0, 4000.0, 10.0) var glow_visible_full_k := 1200.0
## Render-time billow detail; its reset_s is the period of the lattices that ride the flow.
@export var billow := FireBillowConfig.new()


## One octave at the wavelength, two when half of it still spans TURBULENCE_MIN_CELLS.
func turbulence_octaves() -> int:
	return 2 if turbulence_wavelength_m * 0.5 / cell_size_m >= TURBULENCE_MIN_CELLS else 1


## Cells a field moving at [param speed_mps] crosses in one frame's substeps.
func band_cells(speed_mps: float) -> float:
	var steps := max_substeps_per_frame if topology_interval_steps <= 0 else mini(max_substeps_per_frame, topology_interval_steps)
	return speed_mps * float(steps) / (float(simulation_hz) * cell_size_m)


func validate() -> String:
	if cell_size_m <= 0.0:
		return "cell_size_m must be positive"
	if simulation_hz < 5:
		return "simulation_hz must be at least 5"
	if max_substeps_per_frame < 1:
		return "max_substeps_per_frame must be at least 1"
	if pool_slots != FireTilePool.NSLOTS and pool_slots != FireTilePool.NSLOTS_LARGE:
		return "pool_slots must be 2048 or 4096"
	if velocity_clamp_mps <= 0.0 or keep_speed_mps <= 0.0:
		return "velocity_clamp_mps and keep_speed_mps must be positive"
	if band_cells(velocity_clamp_mps) > BAND_CELLS:
		return "velocity_clamp_mps crosses %.1f cells per frame, tile band is %d" % [
			band_cells(velocity_clamp_mps), int(BAND_CELLS)]
	if billow == null:
		return "billow is required"
	var billow_error := billow.validate()
	if billow_error != "":
		return "billow: " + billow_error
	if glow_visible_from_k > 0.0 or glow_visible_full_k > 0.0:
		if glow_visible_full_k <= glow_visible_from_k:
			return "glow_visible_full_k must exceed glow_visible_from_k, both 0 disables the fade"
	if turbulence_strength > 0.0:
		var cells := turbulence_wavelength_m / cell_size_m
		if cells < TURBULENCE_MIN_CELLS:
			return "turbulence_wavelength_m is %.1f cells, at least %d needed" % [cells, int(TURBULENCE_MIN_CELLS)]
		var tiles := maxf(roundf(cells / TILE_CELLS), 1.0)
		if absf(cells - tiles * TILE_CELLS) < 0.1 * tiles * TILE_CELLS:
			return "turbulence_wavelength_m is %.1f cells, within 10%% of a multiple of the %d-cell tile" % [
				cells, int(TILE_CELLS)]
		if turbulence_band_hi_k <= turbulence_band_lo_k:
			return "turbulence_band_hi_k must exceed turbulence_band_lo_k"
		if turbulence_evolution_s <= 0.0:
			return "turbulence_evolution_s must be positive"
	return ""
