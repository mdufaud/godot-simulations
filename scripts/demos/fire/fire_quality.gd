class_name FireQuality extends RefCounted
## Performance ladder for the fire demo: named presets, the Auto ladder, and the
## registry that pushes a preset's values back through the menu widgets.
##
## Owns no simulation state. Every value reaches the solver, the water or the
## viewport through a control registered by the menu builder, so a preset and a
## hand-moved slider go down exactly the same path.
##
##     var quality := FireQuality.new()
##     quality.register("pressure", slider, func(v: float): solver.pressure_iterations = int(v))
##     quality.set_preset(FireQuality.Preset.AUTO)
##     # each frame, after smoothing the frame time:
##     quality.frame_ms = smoothed_ms
##     quality.update(delta)

enum Preset { REFERENCE, QUALITY, BALANCED, REALTIME_LITE, PERFORMANCE, AUTO }

const PRESET_NAMES := [
	"Reference", "Quality", "Balanced", "Realtime Lite", "Performance", "Auto"]
const SIMULATION_RATES := [5, 10, 15, 30, 60, 120]
const AUTO_MIN_HOLD := 3.0
const AUTO_INITIAL_HOLD := 5.0
const AUTO_SLOW_FRAME_MS := 18.5
const AUTO_FAST_FRAME_MS := 15.0
const AUTO_MAX_LEVEL := 5
## Where Auto starts rather than at the Reference level 0. Level 0 is the paper's
## reference configuration, which measured 8 fps on the 760M in the heavy water
## scenario, so starting there means every session opens with several seconds of
## slideshow before the ladder walks down. Auto climbs back up on its own when
## frames are fast, so a machine that can afford level 0 loses nothing permanent.
const AUTO_START_LEVEL := 2
## Phase 6 item 4. Measured on the heavy scenario at Auto level 5: the main
## viewport's GPU time is 17.16 ms at 4x, 16.17 at 2x and 14.73 with MSAA off, so
## anti-aliasing is worth ~2.4 ms — about as much as the whole vorticity stage —
## and it is pure image quality, which is what a performance ladder is for.
const MSAA_MODES := [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]
const MSAA_NAMES := ["Off", "2x", "4x"]

## Smoothed frame time the host measures, written before [method update].
var frame_ms := 16.67

var preset := Preset.AUTO
var _controls := {}
var _auto_level := 0
var _auto_hold := 0.0
var _auto_frame_ms := 16.67


## Binds a preset key to the menu widget that carries it and the callback that
## applies it, so presets move the visible control rather than bypassing it.
func register(key: String, node: Control, callback: Callable) -> void:
	_controls[key] = {node = node, callback = callback}


func set_preset(index: int) -> void:
	preset = clampi(index, 0, PRESET_NAMES.size() - 1)
	if preset == Preset.AUTO:
		_auto_level = AUTO_START_LEVEL
		_auto_hold = AUTO_INITIAL_HOLD
		_auto_frame_ms = maxf(frame_ms, 16.67)
		_apply(auto_values(_auto_level))
		return
	_apply(preset_values(preset))


## Walks the Auto ladder. A no-op under an explicit preset.
func update(delta: float) -> void:
	if preset != Preset.AUTO:
		return
	_auto_frame_ms = lerpf(_auto_frame_ms, minf(delta * 1000.0, 250.0), 0.05)
	_auto_hold -= delta
	if _auto_hold > 0.0:
		return
	var next_level := _auto_level
	if _auto_frame_ms > AUTO_SLOW_FRAME_MS and _auto_level < AUTO_MAX_LEVEL:
		# Proportional, because one level per hold is far too slow to be useful
		# from where this actually starts: the measured worst case is 121 ms, and
		# stepping one level every three seconds spends seventeen seconds walking
		# down a ladder the first adjustment could have descended. Each level is
		# worth roughly a factor of two, so the overshoot in octaves is the number
		# of levels to drop.
		var octaves := log(_auto_frame_ms / AUTO_SLOW_FRAME_MS) / log(2.0)
		next_level = mini(_auto_level + maxi(int(ceil(octaves)), 1), AUTO_MAX_LEVEL)
	elif _auto_frame_ms < AUTO_FAST_FRAME_MS and _auto_level > 0:
		# One at a time on the way back up: fast down, slow up, so the ladder
		# settles instead of oscillating around the threshold.
		next_level -= 1
	if next_level != _auto_level:
		_auto_level = next_level
		_apply(auto_values(_auto_level))
		_auto_hold = AUTO_MIN_HOLD


func status_text() -> String:
	if preset == Preset.AUTO:
		var scope := "simulation reduced" if _auto_level >= 4 else "rendering only"
		return "Auto level %d/%d · %s · %.1f ms" % [
			_auto_level, AUTO_MAX_LEVEL, scope, _auto_frame_ms]
	return "%s · explicit, reversible settings" % PRESET_NAMES[preset]


## Quality knobs per preset.
##
## [code]catchup[/code] is the substep budget a frame may spend catching the
## simulation clock up. It is the largest single lever measured on the 760M — the
## solver runs the whole grid loop once per substep, so a frame that takes four of
## them costs four times a frame that takes one, and a slow frame asks for MORE
## substeps than a fast one. Left at four for Reference, which is the fidelity
## control; every playable preset caps it and lets the temporal interpolation
## cover the difference.
##
## [code]pressure[/code] counts dispatches of the projection, and the playable
## presets are at half what they used to be because the solver behind it changed
## (Phase 2: block Gauss-Seidel plus a tile-level coarse solve). Measured at 2048
## resident tiles, the new solver at 32 passes leaves a residual of 0.015 where
## the old one left 0.087 at 64, so every one of these halvings buys accuracy as
## well as milliseconds. Reference keeps the paper's 64 (Tab. 3 range 64-128): it
## is the control, and there it now costs 23 % more for an 18x lower residual.
##
## [code]advection[/code] has a middle rung since Phase 3: mode 2 corrects the
## scalars with MacCormack and leaves the velocity on plain semi-Lagrangian.
## Measured at 2048 tiles it is 5.1 ms against 8.8 for the full correction and 0
## for none, and it holds the plume at 2118 K / 9.07 total reaction where dropping
## the correction entirely gives 1984 K / 7.05. That is roughly proportional — it
## is a rung on the ladder, not a free lunch — so it goes where the ladder used to
## step straight from full MacCormack to none.
static func preset_values(index: int) -> Dictionary:
	match index:
		Preset.QUALITY:
			return {pressure = 32, advection = 0, vorticity_mode = 0,
				vorticity_frequency = 1, simulation_hz = 30, temporal = false,
				catchup = 3, water_substeps = 16, water_adaptive = true,
				water_cap = 16384, march_step = 1.0, march_budget = 280,
				march_distance = 72.0, water_scale = 0.8, render_scale = 1.0,
				msaa = 2, volume_half = false}
		Preset.BALANCED:
			return {pressure = 24, advection = 0, vorticity_mode = 1,
				vorticity_frequency = 2, simulation_hz = 30, temporal = false,
				catchup = 2, water_substeps = 14, water_adaptive = true,
				water_cap = 12288, march_step = 1.5, march_budget = 192,
				march_distance = 56.0, water_scale = 0.55, render_scale = 0.8,
				msaa = 1, volume_half = true}
		Preset.REALTIME_LITE:
			return {pressure = 16, advection = 2, vorticity_mode = 1,
				vorticity_frequency = 2, simulation_hz = 15, temporal = true,
				catchup = 1, water_substeps = 12, water_adaptive = true,
				water_cap = 8192, march_step = 2.0, march_budget = 128,
				march_distance = 40.0, water_scale = 0.4, render_scale = 0.65,
				msaa = 1, volume_half = true}
		Preset.PERFORMANCE:
			return {pressure = 16, advection = 1, vorticity_mode = 2,
				vorticity_frequency = 4, simulation_hz = 30, temporal = false,
				catchup = 1, water_substeps = 12, water_adaptive = true,
				water_cap = 8192, march_step = 2.0, march_budget = 128,
				march_distance = 40.0, water_scale = 0.4, render_scale = 0.65,
				msaa = 0, volume_half = true}
		_:
			return {pressure = 64, advection = 0, vorticity_mode = 0,
				vorticity_frequency = 1, simulation_hz = 30, temporal = false,
				catchup = 4, water_substeps = 16, water_adaptive = false,
				water_cap = 16384, march_step = 0.75, march_budget = 320,
				march_distance = 80.0, water_scale = 1.0, render_scale = 1.0,
				msaa = 2, volume_half = false}


## The Auto ladder. Levels 1-3 give up rendering only, 4-5 then reduce the
## simulation — except for the pressure count, which every level overrides off
## Reference's 64: Reference keeps the paper's iteration count because it is the
## fidelity control, but there is no reason for an automatic ladder to pay for it
## when 32 passes of the Phase 2 solver already leave a lower residual than 64 of
## the old one.
##
## Water render scale falls first and fastest: the screen-space droplet pipeline
## (five sub-viewports) measured ~54 ms of a 121 ms frame with the hose open, more
## than the whole solver, and it is the one cost that scales with the square of a
## single number.
static func auto_values(level: int) -> Dictionary:
	var values := preset_values(Preset.REFERENCE)
	match level:
		1:
			values.merge({pressure = 32, march_step = 1.0, march_budget = 280,
				march_distance = 72.0, water_scale = 0.6}, true)
		2:
			values.merge({pressure = 32, march_step = 1.25, march_budget = 240,
				march_distance = 64.0, water_scale = 0.5, render_scale = 0.9,
				volume_half = true}, true)
		3:
			values.merge({pressure = 32, march_step = 1.5, march_budget = 192,
				march_distance = 56.0, water_scale = 0.45, render_scale = 0.8,
				msaa = 1, volume_half = true}, true)
		4:
			values.merge({pressure = 24, advection = 2, vorticity_mode = 1,
				vorticity_frequency = 2,
				catchup = 2, water_substeps = 12, water_adaptive = true,
				water_cap = 12288, march_step = 1.75,
				march_budget = 160, march_distance = 48.0, water_scale = 0.4,
				render_scale = 0.75, msaa = 1, volume_half = true}, true)
		5:
			values = preset_values(Preset.PERFORMANCE)
	return values


func _apply(values: Dictionary) -> void:
	_push("pressure", values.pressure)
	_push("advection", values.advection)
	_push("vorticity_mode", values.vorticity_mode)
	_push("vorticity_frequency", values.vorticity_frequency)
	_push("simulation_hz", SIMULATION_RATES.find(values.simulation_hz))
	_push("temporal", values.temporal)
	_push("catchup", values.catchup)
	_push("water_substeps", values.water_substeps)
	_push("water_adaptive", values.water_adaptive)
	_push("water_cap", values.water_cap)
	_push("march_step", values.march_step)
	_push("march_budget", values.march_budget)
	_push("march_distance", values.march_distance)
	_push("water_scale", values.water_scale)
	_push("render_scale", values.render_scale)
	_push("msaa", values.msaa)
	_push("volume_half", values.volume_half)


func _push(key: String, value: Variant) -> void:
	if not _controls.has(key):
		return
	var entry: Dictionary = _controls[key]
	var node: Control = entry.node
	var callback: Callable = entry.callback
	if node is HSlider:
		var slider := node as HSlider
		if is_equal_approx(slider.value, float(value)):
			callback.call(float(value))
		else:
			slider.value = float(value)
	elif node is OptionButton:
		var option := node as OptionButton
		option.select(int(value))
		callback.call(int(value))
	elif node is CheckButton:
		var toggle := node as CheckButton
		toggle.set_pressed_no_signal(bool(value))
		callback.call(bool(value))
