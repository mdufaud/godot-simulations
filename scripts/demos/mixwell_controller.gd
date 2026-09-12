extends Control

const Gallery := preload("res://scripts/mixwell/mixwell_gallery.gd")
const SOURCE_NAMES := ["Fig. 15 bands", "Fig. 16 checkerboard", "Fig. 21 rings", "Fig. 17 drops"]
const SOURCE_DESCRIPTIONS := [
	"Horizontal bands used to expose curved deformations",
	"Red, white and black checkerboard from Figure 16",
	"Concentric blue, white and orange input from Figures 11 and 21",
	"Orange and green drop rows from the BirdWing input in Figure 17",
]
const DISPLAY_NAMES := ["Result", "Source", "RDF magnitude", "Displacement vectors", "Area error"]
const BOUNDARY_NAMES := ["Fullscreen", "Periodic RDF", "Slip walls"]
const SPP_NAMES := ["1", "4", "16", "64", "256"]
const CHAPTER_NAMES := ["Principle", "Constructions", "Validation"]
const COMPARISON_NAMES := [
	"Single view", "Source | Result", "Single pass | Full pattern",
	"Fullscreen | Periodic", "Open walls | Slip walls", "Mixwell | Lu2012",
]
const OFFICIAL_EXAMPLE_NAMES := [
	"Fig. 21 · Brush stroke", "Fig. 11a · Pinch brush", "Fig. 11b · Twist brush",
	"BirdWing · Fig. 17", "Circle grid · Fig. 15", "Sine wave · Fig. 15",
	"Nonpareil · Fig. 16",
]
const OFFICIAL_EXAMPLE_PRESETS := [
	Gallery.FREEHAND_LAB, Gallery.PINCH, Gallery.TWIST, Gallery.BIRD_WING,
	Gallery.CIRCLE_GRID, Gallery.SINE_CURVE, Gallery.NONPAREIL,
]
const OFFICIAL_EXAMPLE_SOURCES := [2, 2, 2, 3, 0, 0, 1]
const OFFICIAL_EXAMPLE_TITLES := [
	"FIG. 21 · SINGLE BRUSH", "FIG. 11a · PINCH BRUSH", "FIG. 11b · TWIST BRUSH",
	"FIG. 17 · BIRDWING", "FIG. 15 · CIRCLE GRID", "FIG. 15 · SINE WAVE",
	"FIG. 16 · NONPAREIL",
]
const OFFICIAL_EXAMPLE_HELP := [
	"Draw a continuous path across the Figure 21 input. Each retained segment is applied in sequence.",
	"Figure 11a: the published divergence-free Pinch brush on the shared ring input.",
	"Figure 11b: the published divergence-free Twist brush on the same Figure 11 input.",
	"Published BirdWing sequence applied to its orange/green drop input.",
	"Published circle-grid RDF construction. Use the step buttons to expose each pass.",
	"Published sine-wave RDF construction. Use the step buttons to expose the pass.",
	"Published Nonpareil construction on the Figure 16 checkerboard input.",
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var display: ColorRect = $Display
@onready var experience: Control = $UI/Experience
@onready var stroke_preview: Line2D = $UI/Experience/StrokePreview
@onready var guide_title: Label = $UI/Experience/Guide/Text/Title
@onready var guide_explanation: Label = $UI/Experience/Guide/Text/Explanation
@onready var before_label: Label = $UI/Experience/BeforeLabel
@onready var after_label: Label = $UI/Experience/AfterLabel
@onready var comparison_divider: ColorRect = $UI/Experience/Divider
@onready var official_example: OptionButton = $UI/Experience/Controls/VBox/Actions/Example
@onready var previous_pass: Button = $UI/Experience/Controls/VBox/Actions/Previous
@onready var next_pass: Button = $UI/Experience/Controls/VBox/Actions/Next
@onready var restart_example: Button = $UI/Experience/Controls/VBox/Actions/Restart
@onready var experience_undo: Button = $UI/Experience/Controls/VBox/Actions/Undo
@onready var guided_step: Label = $UI/Experience/Controls/VBox/StepSummary
@onready var guided_progress: ProgressBar = $UI/Experience/Controls/VBox/Progress
@onready var guided_hint: Label = $UI/Experience/Controls/VBox/Hint

var solver := MixwellSolver.new()
var config := MixwellConfig.new()
var display_texture: Texture2DRD
var texture_bound := false
var source_mode := 2
var motion_mode := Gallery.FREEHAND_LAB
var display_mode := 0
var chapter_index := 0
var comparison_mode := 0
var sample_index := 0
var status_label: Label
var source_info_label: Label
var pattern_step_label: Label
var pattern_stack_label: Label
var chapter_label: Label
var capability_label: Label
var comparison_label: Label
var progress_bar: ProgressBar
var gallery_option: OptionButton
var strokes: Array[MixwellStroke] = []
var stroke_batches: Array[int] = []
var active_stroke: MixwellStroke
var source_texture: Texture2DRD
var diagnostic_texture: Texture2DRD
var user_source_texture: Texture2D
var source_texture_dialog: FileDialog
var user_source_path := ""
var undo_action: Button
var clear_action: Button

var _drawing := false
var _touch_points := {}
var _preview_active := false
var _render_transition := false
var _requested_size := Vector2i.ZERO
var _last_viewport_size := Vector2i.ZERO
var _viewport_profiling := false
var _last_metrics_request := -1
var _mobile_profile := false
var quality := SimQualityState.new()
var _stroke_preview_tween: Tween
var _official_example_index := 0


func _ready() -> void:
	_mobile_profile = OS.has_feature("mobile") or OS.get_environment("FORCE_TOUCH_UI") == "1"
	config.source_mode = source_mode
	quality.setup(MixwellQualityProfile, "mixwell_quality_profile", _apply_quality)
	if _mobile_profile:
		quality.fallback_tier = MixwellQualityProfile.Tier.LOW
	quality.restore()
	_last_viewport_size = _viewport_size()
	solver.initialize(_render_size(config.final_scale), config, _last_viewport_size)
	solver.set_source_mode(source_mode)
	solver.set_preset(motion_mode)
	_setup_ui()
	_setup_experience()
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	RenderingServer.call_on_render_thread(solver.init_render.bind(solver.create_render_snapshot()))


func _process(delta: float) -> void:
	if _render_transition:
		if not solver.is_initialized() or solver.get_render_size() != _requested_size:
			_update_status()
			return
		_render_transition = false
	if not solver.is_initialized():
		_update_status()
		return
	if not texture_bound:
		if display_texture == null:
			display_texture = Texture2DRD.new()
		if source_texture == null:
			source_texture = Texture2DRD.new()
		if diagnostic_texture == null:
			diagnostic_texture = Texture2DRD.new()
		display_texture.texture_rd_rid = solver.get_display_texture()
		source_texture.texture_rd_rid = solver.get_source_texture()
		diagnostic_texture.texture_rd_rid = solver.get_diagnostic_texture()
		var display_material := display.material as ShaderMaterial
		display_material.set_shader_parameter("display_tex", display_texture)
		display_material.set_shader_parameter("source_tex",
			user_source_texture if user_source_texture != null else source_texture)
		display_material.set_shader_parameter("diagnostic_tex", diagnostic_texture)
		display_material.set_shader_parameter("display_mode", display_mode)
		display_material.set_shader_parameter("comparison_mode", comparison_mode)
		texture_bound = true
	var spp_limit := 1 if _preview_active else config.target_spp
	var batch := solver.get_samples_for_budget(sample_index, spp_limit, _preview_active)
	if batch > 0:
		var index := sample_index
		sample_index += batch
		RenderingServer.call_on_render_thread(solver.render_samples.bind(index, batch,
			solver.create_render_snapshot()))
	if solver.diagnostics_enabled() and sample_index != _last_metrics_request and (sample_index == 1 \
			or sample_index % 4 == 0 or sample_index >= spp_limit):
		_last_metrics_request = sample_index
		RenderingServer.call_on_render_thread(solver.update_metrics)
	if solver.is_profiling():
		RenderingServer.call_on_render_thread(solver.poll_timings)
	_update_status()


func _exit_tree() -> void:
	if display_texture != null:
		display_texture.texture_rd_rid = RID()
	if source_texture != null:
		source_texture.texture_rd_rid = RID()
	if diagnostic_texture != null:
		diagnostic_texture.texture_rd_rid = RID()
	if _viewport_profiling:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)
	RenderingServer.call_on_render_thread(solver.free_render)


func _viewport_size() -> Vector2i:
	var viewport_size := get_viewport_rect().size
	return Vector2i(maxi(64, int(viewport_size.x)), maxi(64, int(viewport_size.y)))


func _render_size(scale: float) -> Vector2i:
	var viewport_size := _viewport_size()
	return Vector2i(maxi(64, int(viewport_size.x * scale)),
			maxi(64, int(viewport_size.y * scale)))


func _setup_ui() -> void:
	menu.add_section("Mixwell")
	status_label = menu.add_label("Starting GPU solver")
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu.add_option_button("Chapter", CHAPTER_NAMES, chapter_index, _select_chapter)
	chapter_label = menu.add_label("")
	capability_label = menu.add_label("")
	comparison_label = menu.add_label("")
	for info_label in [chapter_label, capability_label, comparison_label]:
		info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu.add_option_button("Comparison", COMPARISON_NAMES, comparison_mode,
		_select_comparison)
	for info in [
		"Model: ideal 2D, incompressible, irrotational, inviscid, quasi-static",
		"Excludes: temperature, diffusion, thickness, rheology, turbulence, deposition",
		"Published RDF constructions: line combs, TriWaves, affine brushes and slip images",
		"Quality: %s" % ("Android Forward+ mobile profile" if _mobile_profile \
				else "desktop profile"),
		"Left drag: draw a retained freehand Mixwell path",
	]:
		var info_label := menu.add_label(info)
		info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu.add_option_button("Source", SOURCE_NAMES, source_mode, _select_source)
	source_info_label = menu.add_label(SOURCE_DESCRIPTIONS[source_mode])
	source_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu.add_button("Load source texture", _open_source_texture)
	menu.add_button("Use procedural source", _clear_source_texture)
	gallery_option = menu.add_option_button("Gallery", Gallery.all_preset_names(), motion_mode,
			_select_motion)
	menu.add_section("Pattern construction")
	pattern_step_label = menu.add_label("")
	pattern_stack_label = menu.add_label("")
	pattern_stack_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pattern_stack_label.custom_minimum_size.y = 32.0
	menu.add_button("Previous pass", _previous_pattern_step)
	menu.add_button("Next pass", _next_pattern_step)
	menu.add_button("Show all passes", _show_all_pattern_steps)
	menu.add_section("Rendering")
	menu.add_option_button("Display", DISPLAY_NAMES, display_mode, _select_display)
	menu.add_option_button("Boundary", BOUNDARY_NAMES, config.boundary_mode,
		_set_boundary_mode)
	menu.add_button("Run periodic A/B", _run_periodic_gpu_ab)
	menu.add_option_button("Drift compensation", Gallery.compensation_names(),
			config.drift_compensation, _select_drift_compensation)
	menu.add_slider("Brush radius", 2.0, 64.0, config.brush_radius_px,
		_set_brush_radius)
	menu.add_slider("Midpoint alpha", 0.05, 0.25, config.midpoint_alpha,
		_set_midpoint_alpha)
	menu.add_slider("Cutoff gamma", 1.0, 32.0, config.cutoff_gamma,
		_set_cutoff_gamma)
	var spp_option: OptionButton = menu.add_option_button("Target spp", SPP_NAMES,
		MixwellConfig.SPP_TARGETS.find(config.target_spp), _select_target_spp)
	quality.bind("target_spp", spp_option, _select_target_spp,
		func(spp: int) -> int: return MixwellConfig.SPP_TARGETS.find(spp))
	var budget_slider: HSlider = menu.add_slider("GPU budget (ms)", 0.5, 33.0,
		config.gpu_budget_ms, _set_gpu_budget)
	quality.bind("gpu_budget_ms", budget_slider, _set_gpu_budget)
	var preview_slider: HSlider = menu.add_slider("Preview scale", 0.25, 1.0,
		config.preview_scale, _set_preview_scale)
	quality.bind("preview_scale", preview_slider, _set_preview_scale)
	var final_slider: HSlider = menu.add_slider("Final scale", 0.5, 1.0,
		config.final_scale, _set_final_scale)
	quality.bind("final_scale", final_slider, _set_final_scale)
	quality.attach_menu_option(menu)
	menu.add_slider("Affine strength", -2.0, 2.0, config.affine_strength,
		_set_affine_strength)
	menu.add_slider("Affine radius", 16.0, 512.0, config.affine_radius_px,
		_set_affine_radius)
	menu.add_separator()
	progress_bar = menu.add_progress_bar("Progressive accumulation", config.target_spp)
	undo_action = menu.add_action("↶", "Undo stroke", _undo)
	clear_action = menu.add_action("⌫", "Clear drawing", _clear)
	_set_freehand_actions(false)
	menu.add_debug_toggle("📊", "GPU timings", false,
		_set_profiling)
	_update_pattern_panel()
	_update_exhibit_panel()


func _setup_experience() -> void:
	for example_name in OFFICIAL_EXAMPLE_NAMES:
		official_example.add_item(example_name)
	official_example.select(_official_example_index)
	official_example.item_selected.connect(_select_official_example)
	previous_pass.pressed.connect(_previous_official_pass)
	next_pass.pressed.connect(_next_official_pass)
	restart_example.pressed.connect(_restart_official_example)
	experience_undo.pressed.connect(_undo)
	menu.panel_toggled.connect(func(open: bool): experience.visible = not open)
	_set_comparison_overlay(false)
	_set_freehand_actions(false)
	_update_official_panel()


func _select_official_example(index: int) -> void:
	if index < 0 or index >= OFFICIAL_EXAMPLE_NAMES.size():
		return
	_official_example_index = index
	if official_example != null:
		official_example.select(index)
	source_mode = OFFICIAL_EXAMPLE_SOURCES[index]
	config.source_mode = source_mode
	solver.set_source_mode(source_mode)
	motion_mode = OFFICIAL_EXAMPLE_PRESETS[index]
	_drawing = false
	active_stroke = null
	strokes.clear()
	stroke_batches.clear()
	solver.set_preset(motion_mode)
	solver.set_pattern_step(-1)
	_preview_active = false
	if gallery_option != null:
		gallery_option.select(motion_mode)
	_update_source_info()
	_update_pattern_panel()
	_update_exhibit_panel()
	_request_reset()
	_update_official_panel()


func _previous_official_pass() -> void:
	var total := solver.get_pattern_operation_count()
	if total <= 0:
		return
	var steps := _official_pass_steps(total)
	var active := total if solver.get_pattern_step() < 0 else solver.get_pattern_step()
	var index := steps.find(active)
	var next_active: int = steps[maxi((steps.size() - 1) if index < 0 else index - 1, 0)]
	solver.set_pattern_step(-1 if next_active >= total else next_active)
	_request_reset()
	_update_pattern_panel()
	_update_official_panel()


func _next_official_pass() -> void:
	var total := solver.get_pattern_operation_count()
	if total <= 0:
		return
	var steps := _official_pass_steps(total)
	var active := total if solver.get_pattern_step() < 0 else solver.get_pattern_step()
	var index := steps.find(active)
	var next_index := 1 if index < 0 or index >= steps.size() - 1 else index + 1
	var next_active: int = steps[next_index]
	solver.set_pattern_step(-1 if next_active >= total else next_active)
	_request_reset()
	_update_pattern_panel()
	_update_official_panel()


func _restart_official_example() -> void:
	_select_official_example(_official_example_index)


func _official_pass_steps(total: int) -> Array[int]:
	if _official_example_index == 3 and total == 5:
		return [0, 2, 3, 4, 5]
	var result: Array[int] = []
	for step in total + 1:
		result.append(step)
	return result


func _set_comparison_overlay(enabled: bool) -> void:
	comparison_mode = 1 if enabled else 0
	var display_material := display.material as ShaderMaterial
	if display_material != null:
		display_material.set_shader_parameter("comparison_mode", comparison_mode)
	before_label.visible = enabled
	after_label.visible = enabled
	comparison_divider.visible = enabled
func _set_freehand_actions(enabled: bool) -> void:
	if undo_action != null:
		undo_action.visible = enabled
	if clear_action != null:
		clear_action.visible = enabled


func _update_official_panel() -> void:
	if guided_step == null:
		return
	guide_title.text = OFFICIAL_EXAMPLE_TITLES[_official_example_index]
	guide_explanation.text = OFFICIAL_EXAMPLE_HELP[_official_example_index]
	var total := solver.get_pattern_operation_count()
	if motion_mode == Gallery.FREEHAND_LAB:
		guided_step.text = "Interactive reproduction · %d stroke%s" % [
			stroke_batches.size(), "" if stroke_batches.size() == 1 else "s"]
	else:
		var active := total if solver.get_pattern_step() < 0 else solver.get_pattern_step()
		if _official_example_index == 3:
			var birdwing_labels := {0: "Input drops", 2: "Gel-Git", 3: "Noisy Nonpareil",
					4: "TriWave 1", 5: "TriWave 2 · complete"}
			guided_step.text = "Published BirdWing sequence · %s" % birdwing_labels.get(
					active, "TriWave 2 · complete")
		else:
			guided_step.text = "Published construction · %d/%d passes active" % [active, total]
		if not stroke_batches.is_empty():
			guided_step.text += " · %d retained stroke%s" % [stroke_batches.size(),
					"" if stroke_batches.size() == 1 else "s"]
	previous_pass.disabled = total <= 0
	next_pass.disabled = total <= 0
	experience_undo.disabled = stroke_batches.is_empty()


func _select_source(index: int) -> void:
	source_mode = index
	_update_source_info()
	solver.set_source_mode(index)
	_request_reset()


func _select_display(index: int) -> void:
	display_mode = clampi(index, 0, DISPLAY_NAMES.size() - 1)
	solver.set_diagnostics_enabled(display_mode != 0 or solver.is_profiling())
	var display_material := display.material as ShaderMaterial
	display_material.set_shader_parameter("display_mode", display_mode)


func _select_chapter(index: int) -> void:
	chapter_index = clampi(index, 0, CHAPTER_NAMES.size() - 1)
	_update_exhibit_panel()


func _select_comparison(index: int) -> void:
	comparison_mode = clampi(index, 0, COMPARISON_NAMES.size() - 1)
	var display_material := display.material as ShaderMaterial
	if display_material != null:
		display_material.set_shader_parameter("comparison_mode", comparison_mode)
	if comparison_mode == 1:
		display_mode = 0
		if display_material != null:
			display_material.set_shader_parameter("display_mode", display_mode)
	before_label.visible = comparison_mode == 1
	after_label.visible = comparison_mode == 1
	comparison_divider.visible = comparison_mode == 1
	_update_exhibit_panel()


func _open_source_texture() -> void:
	if source_texture_dialog == null:
		source_texture_dialog = FileDialog.new()
		source_texture_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		source_texture_dialog.access = FileDialog.ACCESS_FILESYSTEM
		source_texture_dialog.filters = PackedStringArray([
			"*.png, *.jpg, *.jpeg, *.webp; Image textures",
		])
		source_texture_dialog.file_selected.connect(_load_source_texture)
		add_child(source_texture_dialog)
	source_texture_dialog.popup_centered_ratio(0.75)


func _load_source_texture(path: String) -> void:
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		user_source_texture = null
		user_source_path = ""
		_update_source_info("Texture load failed; using procedural source")
		return
	image.convert(Image.FORMAT_RGBA8)
	user_source_texture = ImageTexture.create_from_image(image)
	user_source_path = path
	_update_source_info()
	var display_material := display.material as ShaderMaterial
	if display_material != null:
		display_material.set_shader_parameter("source_tex", user_source_texture)


func _clear_source_texture() -> void:
	user_source_texture = null
	user_source_path = ""
	_update_source_info()
	var display_material := display.material as ShaderMaterial
	if display_material != null and source_texture != null:
		display_material.set_shader_parameter("source_tex", source_texture)


func _update_source_info(override_text := "") -> void:
	if source_info_label == null:
		return
	if not override_text.is_empty():
		source_info_label.text = override_text
	elif user_source_texture != null:
		source_info_label.text = "User texture preview: %s; solver input remains procedural" \
			% user_source_path.get_file()
	else:
		source_info_label.text = SOURCE_DESCRIPTIONS[source_mode]


func _update_exhibit_panel() -> void:
	if chapter_label == null:
		return
	var descriptions := [
		"∇²φ = 0 · u = ∇φ · reversible 2D potential flow",
		"RDF lines, segments, combs, curves and divergence-free affine brushes",
		"Area/Jacobian, periodic A/B, slip images and progressive convergence",
	]
	chapter_label.text = descriptions[chapter_index]
	capability_label.text = "Active capability: %s · %s" % [
		Gallery.preset_name(motion_mode), CHAPTER_NAMES[chapter_index]]
	var comparison_text := "Visual comparison: source left / result right"
	if comparison_mode == 2:
		comparison_text = "Single pass/full pattern: use Pattern construction steps"
	elif comparison_mode == 3:
		comparison_text = "Fullscreen/periodic: Run periodic A/B for numeric validation"
	elif comparison_mode == 4:
		comparison_text = "Open/slip walls: select Boundary and compare diagnostics"
	elif comparison_mode == 5:
		comparison_text = "Mixwell/Lu2012: Lu2012 reference solver is not bundled"
	if comparison_label != null:
		comparison_label.text = comparison_text


func _select_drift_compensation(index: int) -> void:
	config.drift_compensation = clampi(index, MixwellConfig.DriftCompensation.NONE,
			MixwellConfig.DriftCompensation.MEAN)
	solver.set_drift_compensation(config.drift_compensation)
	_request_reset()


func _set_boundary_mode(index: int) -> void:
	config.boundary_mode = clampi(index, MixwellConfig.BoundaryMode.FULLSCREEN,
			MixwellConfig.BoundaryMode.SLIP_WALLS)
	solver.set_boundary_mode(config.boundary_mode)
	_request_reset()


func _select_motion(index: int) -> void:
	motion_mode = index
	_drawing = false
	active_stroke = null
	strokes.clear()
	stroke_batches.clear()
	solver.set_preset(index)
	solver.set_pattern_step(-1)
	_preview_active = false
	_update_pattern_panel()
	_update_exhibit_panel()
	_request_reset()
	_update_official_panel()


func _previous_pattern_step() -> void:
	var total := solver.get_pattern_operation_count()
	if total <= 0:
		return
	var current := total if solver.get_pattern_step() < 0 else solver.get_pattern_step()
	solver.set_pattern_step(maxi(current - 1, 0))
	_update_pattern_panel()
	_request_reset()
	_update_official_panel()


func _next_pattern_step() -> void:
	var total := solver.get_pattern_operation_count()
	if total <= 0:
		return
	var current := total if solver.get_pattern_step() < 0 else solver.get_pattern_step()
	var next := current + 1
	solver.set_pattern_step(-1 if next >= total else next)
	_update_pattern_panel()
	_request_reset()
	_update_official_panel()


func _show_all_pattern_steps() -> void:
	solver.set_pattern_step(-1)
	_update_pattern_panel()
	_request_reset()
	_update_official_panel()


func _update_pattern_panel() -> void:
	if pattern_step_label == null or pattern_stack_label == null:
		return
	var descriptor: Dictionary = solver.get_pattern_descriptor()
	var operations: Array = descriptor.get("operations", [])
	var total := operations.size()
	var active := int(descriptor.get("active_operations", total))
	var active_step := int(descriptor.get("active_step", -1))
	pattern_step_label.text = "%s · active passes %d/%d · RDF order = reverse" % [
		str(descriptor.get("name", "Pattern")), active, total]
	var lines: Array[String] = []
	for index in total:
		var operation: Dictionary = operations[index]
		var marker := "▶" if index < active else "·"
		lines.append("%s %s" % [marker, _format_pattern_operation(operation, index, total)])
	if active_step == -1 and total > 0:
		lines.append("All passes active")
	pattern_stack_label.text = "\n".join(lines) if not lines.is_empty() else "No operations"


func _format_pattern_operation(operation: Dictionary, index: int, total: int) -> String:
	var kind := str(operation.get("kind", "LINE"))
	var direction: Vector2 = operation.get("direction", Vector2.RIGHT)
	var radius := float(operation.get("radius_px", -1.0))
	if radius <= 0.0:
		radius = config.brush_radius_px
	var pitch := float(operation.get("pitch", 0.0))
	var phase := float(operation.get("phase", 0.0))
	var extent: Vector2 = operation.get("extent", Vector2.ZERO)
	var detail := "dir=(%.2f, %.2f), r=%.1f" % [direction.x, direction.y, radius]
	if pitch > 0.0:
		detail += ", pitch=%.3f" % pitch
	if absf(phase) > 1.0e-6:
		detail += ", phase=%.3f" % phase
	if extent != Vector2.ZERO:
		detail += ", extent=(%.2f, %.2f)" % [extent.x, extent.y]
	if kind == "CURVE":
		detail += ", %s, points=%d" % [str(operation.get("curve_mode", "curve")),
			operation.get("points", []).size()]
	var rdf_index := total - index
	return "pass %02d / RDF %02d  %s  | %s" % [index + 1, rdf_index, kind, detail]


func _set_brush_radius(value: float) -> void:
	config.brush_radius_px = value
	solver.mark_snapshot_dirty()
	_request_reset()


func _set_midpoint_alpha(value: float) -> void:
	config.midpoint_alpha = value
	solver.mark_snapshot_dirty()
	_request_reset()


func _set_cutoff_gamma(value: float) -> void:
	config.cutoff_gamma = value
	solver.mark_snapshot_dirty()
	_request_reset()


func _select_target_spp(index: int) -> void:
	if index < 0 or index >= MixwellConfig.SPP_TARGETS.size():
		return
	config.target_spp = MixwellConfig.SPP_TARGETS[index]
	progress_bar.max_value = config.target_spp if not _preview_active else 1.0
	_request_reset()


func _set_gpu_budget(value: float) -> void:
	config.gpu_budget_ms = clampf(value, 0.5, 33.0)


## Tier launch path: writes the config the solver.initialize() below reads.
## After the menu exists the four keys are widget-bound, so tier switches go
## through the user callbacks (reset + resize included) and skip this.
func _apply_quality(values: Dictionary) -> void:
	config.target_spp = values.target_spp
	config.preview_scale = values.preview_scale
	config.final_scale = values.final_scale
	config.gpu_budget_ms = values.gpu_budget_ms


func _set_profiling(enabled: bool) -> void:
	solver.set_profiling(enabled)
	solver.set_diagnostics_enabled(enabled or display_mode != 0)
	_viewport_profiling = enabled
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), enabled)


func _run_periodic_gpu_ab() -> void:
	if solver.is_initialized():
		RenderingServer.call_on_render_thread(solver.verify_periodic_gpu_ab)


func _set_preview_scale(value: float) -> void:
	config.preview_scale = value
	if _preview_active:
		_schedule_resize(true)
	else:
		_request_reset()


func _set_final_scale(value: float) -> void:
	config.final_scale = value
	if not _preview_active:
		_schedule_resize(false)
	else:
		_request_reset()


func _set_affine_strength(value: float) -> void:
	config.affine_strength = value
	solver.mark_snapshot_dirty()
	_request_reset()


func _set_affine_radius(value: float) -> void:
	config.affine_radius_px = value
	solver.mark_snapshot_dirty()
	_request_reset()


func _request_reset() -> void:
	sample_index = 0
	_last_metrics_request = -1
	if solver.is_initialized() and not _render_transition:
		RenderingServer.call_on_render_thread(solver.reset_accumulation)


func _on_viewport_size_changed() -> void:
	var next_size := _viewport_size()
	if next_size == _last_viewport_size:
		return
	_last_viewport_size = next_size
	_schedule_resize(_preview_active)


func _schedule_resize(preview: bool) -> void:
	_preview_active = preview
	sample_index = 0
	var reference_size := _viewport_size()
	var next_size := _render_size(config.preview_scale if preview else config.final_scale)
	_requested_size = next_size
	progress_bar.max_value = 1.0 if preview else config.target_spp
	if solver.is_initialized() and not _render_transition \
			and solver.get_render_size() == next_size:
		RenderingServer.call_on_render_thread(solver.reset_accumulation)
		return
	if display_texture != null:
		display_texture.texture_rd_rid = RID()
	if source_texture != null:
		source_texture.texture_rd_rid = RID()
	if diagnostic_texture != null:
		diagnostic_texture.texture_rd_rid = RID()
	texture_bound = false
	_render_transition = true
	solver.mark_snapshot_dirty()
	RenderingServer.call_on_render_thread(solver.resize_render.bind(next_size, reference_size,
		solver.create_render_snapshot(next_size, reference_size)))


func _begin_stroke(position: Vector2) -> void:
	if menu.is_panel_open():
		return
	_drawing = true
	_preview_active = true
	active_stroke = MixwellStroke.new()
	active_stroke.radius_px = config.brush_radius_px
	stroke_preview.width = maxf(7.0, active_stroke.radius_px * 0.2)
	stroke_preview.default_color.a = 0.95
	active_stroke.points_px.append(_clamp_position(position))
	if _stroke_preview_tween != null:
		_stroke_preview_tween.kill()
	stroke_preview.modulate.a = 1.0
	stroke_preview.points = PackedVector2Array([
		_clamp_position(position) - Vector2(5.0, 0.0),
		_clamp_position(position) + Vector2(5.0, 0.0),
	])
	_apply_visible_strokes()
	_schedule_resize(true)


func _append_stroke_point(position: Vector2) -> void:
	if not _drawing or active_stroke == null:
		return
	var point := _clamp_position(position)
	var added := active_stroke.append_drag_point(point, _stroke_spacing(),
			_stroke_segment_capacity())
	if added > 0:
		stroke_preview.points = active_stroke.points_px
		_apply_visible_strokes()
		_request_reset()
		return
	var preview_points := active_stroke.points_px.duplicate()
	if preview_points.is_empty() or preview_points[preview_points.size() - 1] != point:
		preview_points.append(point)
	stroke_preview.points = preview_points


func _finish_stroke(position: Vector2) -> void:
	if not _drawing:
		return
	if active_stroke != null:
		var point := _clamp_position(position)
		var capacity := _stroke_segment_capacity()
		active_stroke.append_drag_point(point, _stroke_spacing(), capacity, true)
		if active_stroke.segment_count() == 0 and capacity > 0:
			var direction := Vector2(config.brush_radius_px * 2.0, 0.0)
			if position.x + direction.x > size.x:
				direction.x = -direction.x
			var click_end := _clamp_position(position + direction)
			active_stroke.points_px.append(click_end)
		stroke_preview.points = active_stroke.points_px
		if active_stroke.segment_count() > 0:
			strokes.append(active_stroke)
			stroke_batches.append(1)
	active_stroke = null
	_drawing = false
	_apply_visible_strokes()
	_schedule_resize(false)
	_stroke_preview_tween = create_tween()
	_stroke_preview_tween.tween_property(stroke_preview, "modulate:a", 0.0, 0.35)
	_stroke_preview_tween.tween_callback(func():
		if not _drawing:
			stroke_preview.clear_points()
	)


func _apply_visible_strokes() -> void:
	var visible_strokes: Array = []
	for stroke in strokes:
		visible_strokes.append(stroke)
	if active_stroke != null:
		visible_strokes.append(active_stroke)
	solver.set_strokes(visible_strokes, motion_mode)
	_update_pattern_panel()
	_update_official_panel()


func _undo() -> void:
	if _drawing:
		_drawing = false
		active_stroke = null
	else:
		if strokes.is_empty() or stroke_batches.is_empty():
			return
		var count: int = stroke_batches.pop_back()
		for _index in mini(count, strokes.size()):
			strokes.pop_back()
	_apply_visible_strokes()
	_preview_active = false
	_schedule_resize(false)


func _clear() -> void:
	_drawing = false
	active_stroke = null
	strokes.clear()
	stroke_batches.clear()
	_apply_visible_strokes()
	_preview_active = false
	_schedule_resize(false)


func _segment_limit() -> int:
	return solver.get_segment_limit()


func _stroke_spacing() -> float:
	return maxf(config.brush_radius_px, 12.0)


func _stroke_segment_capacity() -> int:
	return maxi(_segment_limit() - _committed_segment_count(), 0)


func _committed_segment_count() -> int:
	var count := 0
	for stroke in strokes:
		count += stroke.segment_count()
	return count


func _clamp_position(position: Vector2) -> Vector2:
	return Vector2(clampf(position.x, 0.0, size.x), clampf(position.y, 0.0, size.y))


func _input(event: InputEvent) -> void:
	if menu.is_panel_open():
		return
	var event_position := Vector2(-1.0, -1.0)
	if event is InputEventMouse:
		event_position = (event as InputEventMouse).position
	elif event is InputEventScreenTouch:
		event_position = (event as InputEventScreenTouch).position
	elif event is InputEventScreenDrag:
		event_position = (event as InputEventScreenDrag).position
	if event_position.x >= 0.0 and _is_ui_position(event_position):
		return
	if not _touch_points.is_empty() \
			and (event is InputEventMouseButton or event is InputEventMouseMotion):
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_begin_stroke(button.position)
			else:
				_finish_stroke(button.position)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _drawing:
		_append_stroke_point((event as InputEventMouseMotion).position)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touch_points[touch.index] = touch.position
			if _touch_points.size() == 1:
				_begin_stroke(touch.position)
		else:
			_touch_points.erase(touch.index)
			if _touch_points.is_empty():
				_finish_stroke(touch.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_touch_points[drag.index] = drag.position
		if _touch_points.size() == 1:
			_append_stroke_point(drag.position)
		get_viewport().set_input_as_handled()


func _is_ui_position(position: Vector2) -> bool:
	var controls := $UI/Experience/Controls as Control
	var top_right := $UI/SimMenu/TopRight as Control
	return controls.visible and controls.get_global_rect().has_point(position) \
			or top_right.visible and top_right.get_global_rect().has_point(position)


func _update_status() -> void:
	if status_label == null:
		return
	var segment_count := _committed_segment_count()
	if active_stroke != null:
		segment_count += active_stroke.segment_count()
	var phase := "preview 1 spp" if _preview_active else "%d/%d spp" % [sample_index, config.target_spp]
	var mode := Gallery.preset_name(Gallery.FREEHAND_LAB) \
		if not strokes.is_empty() or active_stroke != null else Gallery.preset_name(motion_mode)
	var refinement := solver.get_refinement_state(config.target_spp, _preview_active)
	var pattern_total := solver.get_pattern_operation_count()
	var pattern_active := pattern_total if solver.get_pattern_step() < 0 else solver.get_pattern_step()
	var timings: Dictionary = refinement.timings
	var metrics: Dictionary = solver.get_metrics()
	var boundary := "Fullscreen"
	if config.boundary_mode == MixwellConfig.BoundaryMode.PERIODIC:
		var comparison := solver.get_periodic_comparison()
		var dispatch := solver.get_periodic_dispatch_stats()
		if solver.get_active_boundary_mode() == MixwellConfig.BoundaryMode.PERIODIC:
			var domain: Vector2i = comparison.get("domain_pixels", solver.get_periodic_domain_size())
			boundary = "Periodic RDF %dx%d; dispatch %.1f%% / %.2fx; A/B %.6f / %.6f" % [domain.x, domain.y,
				float(dispatch.get("dispatch_reduction", 0.0)) * 100.0,
				float(dispatch.get("estimated_speedup", 1.0)),
				float(comparison.get("max_displacement", 0.0)),
				float(comparison.get("mean_colour", 0.0)),
			]
		else:
			boundary = "Fullscreen / periodic A/B rejected"
	elif config.boundary_mode == MixwellConfig.BoundaryMode.SLIP_WALLS:
		boundary = "Slip images 4 edge + 4 corner; matrix calibrated"
	var gpu_ab := solver.get_gpu_periodic_comparison()
	if not gpu_ab.is_empty():
		boundary += " · GPU A/B %s %.2fx" % [
			"pass" if gpu_ab.get("passes", false) else "reject",
			float(gpu_ab.get("measured_speedup", 1.0)),
		]
	var dispatch_stats := solver.get_periodic_dispatch_stats()
	if config.boundary_mode != MixwellConfig.BoundaryMode.SLIP_WALLS:
		var periodic_domain: Vector2i = dispatch_stats.get("periodic_domain", Vector2i.ZERO)
		var fullscreen_domain: Vector2i = dispatch_stats.get("fullscreen_domain", Vector2i.ZERO)
		boundary += " · domains %dx%d/%dx%d" % [periodic_domain.x, periodic_domain.y,
			fullscreen_domain.x, fullscreen_domain.y]
	var timing_line := "GPU %.2f/%.2f ms · init %.2f · RDF %.2f · shade %.2f · accum %.2f · viewport %.2f" % [
		float(refinement.sample_gpu_ms), config.gpu_budget_ms,
		float(timings.get("init", 0.0)),
		float(timings.get("rd_line", timings.get("rd_segment", 0.0))),
		float(timings.get("shade", 0.0)),
		float(timings.get("accumulate", 0.0)),
		RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()),
	]
	var quality_line := "area %.6f (max %.6f; p99 %.6f; core %.6f; cutoff %.6f; singularity %.6f; boundary %.6f; wall %.6f) · convergence max %.6f / RMS %.6f / p99 %.6f · wall calibration %.3f" % [
		float(metrics.get("area_error", 0.0)), float(metrics.get("max_area_error", 0.0)),
		float(metrics.get("area_p99", 0.0)), float(metrics.get("area_core", 0.0)),
		float(metrics.get("area_cutoff", 0.0)), float(metrics.get("area_singularity", 0.0)),
		float(metrics.get("area_boundary", 0.0)), float(metrics.get("area_wall", 0.0)),
		float(metrics.get("convergence_error", 0.0)),
		float(metrics.get("convergence_rms", 0.0)), float(metrics.get("convergence_p99", 0.0)),
		solver.get_wall_calibration(),
	]
	status_label.text = "%s · %s · %d strokes · %d/%d segments · passes %d/%d · %s · %s\n%s\n%s" % [
		SOURCE_NAMES[source_mode], "%s / %s / %s" % [mode, DISPLAY_NAMES[display_mode],
			Gallery.compensation_names()[config.drift_compensation]],
		strokes.size(), segment_count, _segment_limit(), pattern_active, pattern_total, phase,
		boundary, timing_line, quality_line,
	]
	if progress_bar != null:
		progress_bar.max_value = 1.0 if _preview_active else config.target_spp
		progress_bar.value = minf(float(sample_index), progress_bar.max_value)
