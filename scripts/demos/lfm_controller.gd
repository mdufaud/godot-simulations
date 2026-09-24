extends Node3D

const PRESETS := [
	preload("res://resources/lfm/presets/soufflerie.tres"),
	preload("res://resources/lfm/presets/anneau.tres"),
]
const QUALITY := [Vector3i(64, 32, 32), Vector3i(128, 64, 64), Vector3i(192, 96, 96)]
const QUALITY_REINIT := [2, 4, 5]

@onready var menu: SimMenu = $UI/SimMenu
@onready var volume: MeshInstance3D = $Volume
@onready var camera_rig: OrbitCamera = $CameraPivot
@onready var wing: MeshInstance3D = $Wing
@onready var viewport_guard := ViewportGuard.attach(self)

var solver := LfmSolver3D.new()
var config: LfmConfig
var preset_index := 0
var quality_index := 1
var view_index := 1
var method_index := 0
var menu_builder := LfmMenu.new()
var density_wrapper: Texture3DRD
var vorticity_wrapper: Texture3DRD
var density_prev_wrapper: Texture3DRD
var vorticity_prev_wrapper: Texture3DRD
var _bound := false
var _status_at_ms := 0
var _capture_fixed_delta_s := -1.0
var _capture_paused := false
var _simulation_speed_ratio := 1.0
var _presentation_phase := 0
var _wall_since_step_s := 0.0
var _presented_frames := 0
var _solved_frames := 0
var _simulated_s := 0.0
var render_scale := 0.5


func _ready() -> void:
	if not GpuPreflight.available():
		menu.add_label("This demo needs GPU compute (Forward+ / Vulkan).")
		return
	camera_rig.target = Vector3(0.95, 0.5, 0.5)
	camera_rig.distance = 1.8
	camera_rig.pitch = -17.0
	camera_rig.yaw = 55.0
	camera_rig.get_camera().fov = 60.0
	camera_rig.min_distance = 1.5
	camera_rig.max_distance = 10.0
	menu_builder.build(self)
	_status_at_ms = Time.get_ticks_msec()
	set_render_scale(render_scale)
	config = (PRESETS[0] as LfmConfig).duplicate(true) as LfmConfig
	_apply_quality_settings()
	menu_builder.sync_preset(config, preset_index, quality_index, view_index)
	_update_shape()
	solver.start(config)


func _process(delta: float) -> void:
	if not solver.is_initialized():
		return
	if not _bound:
		_bind_volume()
	if _capture_paused:
		return
	var frames_per_step := 1
	if config.interpolate_frames and _capture_fixed_delta_s < 0.0:
		frames_per_step = 2 if quality_index == 0 else 4
		_wall_since_step_s += delta
	if _presentation_phase == 0 or frames_per_step == 1:
		var elapsed_s := _capture_fixed_delta_s if _capture_fixed_delta_s > 0.0 \
			else (_wall_since_step_s if frames_per_step > 1 else delta)
		var frame_dt_s := config.bounded_frame_dt_s(elapsed_s)
		if frame_dt_s > 0.0:
			solver.step_frame(frame_dt_s)
			_solved_frames += 1
			_simulated_s += frame_dt_s
		_wall_since_step_s = 0.0
	_presentation_phase = (_presentation_phase + 1) % frames_per_step
	(volume.material_override as ShaderMaterial).set_shader_parameter("frame_blend",
		1.0 if frames_per_step == 1 else float(_presentation_phase if _presentation_phase > 0 \
		else frames_per_step) / frames_per_step)
	_presented_frames += 1
	var now := Time.get_ticks_msec()
	if now - _status_at_ms > 1000:
		var seconds := float(now - _status_at_ms) / 1000.0
		_simulation_speed_ratio = _simulated_s / seconds
		_status_at_ms = now
		var timing := solver.get_timings()
		menu_builder.status.text = "Draw %.0f fps · Solve %.1f Hz · Sim %.2fx · GPU %.0f ms · %s" % [
			_presented_frames / seconds, _solved_frames / seconds, _simulation_speed_ratio,
			float(timing.get("total", 0.0)),
			"LFM" if method_index == 0 else "Semi-Lagrangian"]
		_presented_frames = 0
		_solved_frames = 0
		_simulated_s = 0.0


func apply_preset(index: int) -> void:
	preset_index = clampi(index, 0, 1)
	config = (PRESETS[preset_index] as LfmConfig).duplicate(true) as LfmConfig
	_apply_quality_settings()
	if preset_index == 1:
		camera_rig.target = Vector3(0.7, 0.5, 0.5)
		camera_rig.distance = 1.8
		camera_rig.pitch = -23.0
		camera_rig.yaw = 35.0
		camera_rig.get_camera().fov = 42.0
	else:
		camera_rig.target = Vector3(0.95, 0.5, 0.5)
		camera_rig.distance = 1.8
		camera_rig.pitch = -17.0
		camera_rig.yaw = 55.0
		camera_rig.get_camera().fov = 60.0
	set_view(0 if preset_index == 1 else 1)
	menu_builder.sync_preset(config, preset_index, quality_index, view_index)
	_update_shape()
	_rebuild()


func set_quality_profile(index: int) -> void:
	quality_index = clampi(index, 0, QUALITY.size() - 1)
	menu_builder.quality_button.select(quality_index)
	_apply_quality_settings()
	menu_builder.sync_preset(config, preset_index, quality_index, view_index)
	_rebuild()


func set_method(index: int) -> void:
	method_index = clampi(index, 0, 1)
	menu_builder.method_button.select(method_index)
	solver.set_method(method_index)


func set_view(index: int) -> void:
	view_index = clampi(index, 0, 1)
	menu_builder.view_button.select(view_index)
	(volume.material_override as ShaderMaterial).set_shader_parameter("view_mode", view_index)


func set_render_scale(value: float) -> void:
	render_scale = clampf(value, 0.5, 1.0)
	viewport_guard.set_render_scale(Viewport.SCALING_3D_MODE_FSR, render_scale)


func set_reinit_every(value: float) -> void:
	config.reinit_every = clampi(roundi(value), 2, 10)
	menu_builder.sync_preset(config, preset_index, quality_index, view_index)
	_unbind_volume()
	solver.restart_preserving(config)


func set_bfecc_clamp(enabled: bool) -> void:
	config.bfecc_clamp = enabled
	menu_builder.sync_preset(config, preset_index, quality_index, view_index)
	solver.set_bfecc_clamp(enabled)


func set_inlet_speed(value: float) -> void:
	config.inlet_speed_mps = value
	menu_builder.sync_preset(config, preset_index, quality_index, view_index)
	solver.set_inlet(config.inlet_speed_mps, config.inlet_angle_deg)


func set_inlet_angle(value: float) -> void:
	config.inlet_angle_deg = value
	menu_builder.sync_preset(config, preset_index, quality_index, view_index)
	solver.set_inlet(config.inlet_speed_mps, config.inlet_angle_deg)


func reset_simulation() -> void:
	_rebuild()


func capture_ready() -> bool:
	return solver.is_initialized() and _bound


func set_capture_view(view: String) -> void:
	set_view(0 if view == "density" else 1)


func set_capture_method(value: String) -> void:
	_capture_paused = true
	method_index = 1 if value == "baseline" else 0
	menu_builder.method_button.select(method_index)
	_rebuild()


func capture_start() -> void:
	_capture_paused = false


func capture_stop() -> void:
	_capture_paused = true


func set_capture_fixed_delta(value: float) -> void:
	_capture_fixed_delta_s = value if value > 0.0 else -1.0


func set_capture_ui(enabled: bool) -> void:
	menu.visible = enabled


func _rebuild() -> void:
	_unbind_volume()
	solver.stop()
	solver = LfmSolver3D.new()
	solver.method = method_index
	solver.start(config)


func _apply_quality_settings() -> void:
	config.grid_dims = QUALITY[quality_index]
	config.reinit_every = QUALITY_REINIT[quality_index]
	config.map_rk4 = quality_index == 2
	config.interpolate_frames = quality_index < 2
	config.max_frame_dt_s = 1.0 / 24.0 if quality_index == 0 else 1.0 / 30.0


func _bind_volume() -> void:
	var density_rid := solver.get_display_texture_rid(0)
	var vort_rid := solver.get_display_texture_rid(1)
	if not density_rid.is_valid() or not vort_rid.is_valid():
		return
	density_wrapper = Texture3DRD.new()
	vorticity_wrapper = Texture3DRD.new()
	density_wrapper.texture_rd_rid = density_rid
	vorticity_wrapper.texture_rd_rid = vort_rid
	var material := volume.material_override as ShaderMaterial
	material.set_shader_parameter("density_tex", density_wrapper)
	material.set_shader_parameter("vorticity_tex", vorticity_wrapper)
	if config.interpolate_frames:
		var density_prev_rid := solver.get_previous_display_texture_rid(0)
		var vort_prev_rid := solver.get_previous_display_texture_rid(1)
		if not density_prev_rid.is_valid() or not vort_prev_rid.is_valid():
			return
		density_prev_wrapper = Texture3DRD.new()
		vorticity_prev_wrapper = Texture3DRD.new()
		density_prev_wrapper.texture_rd_rid = density_prev_rid
		vorticity_prev_wrapper.texture_rd_rid = vort_prev_rid
		material.set_shader_parameter("density_prev_tex", density_prev_wrapper)
		material.set_shader_parameter("vorticity_prev_tex", vorticity_prev_wrapper)
	else:
		material.set_shader_parameter("density_prev_tex", density_wrapper)
		material.set_shader_parameter("vorticity_prev_tex", vorticity_wrapper)
	material.set_shader_parameter("frame_blend", 1.0)
	material.set_shader_parameter("view_mode", view_index)
	volume.visible = true
	_bound = true
	_status_at_ms = Time.get_ticks_msec()
	_presented_frames = 0
	_solved_frames = 0
	_simulated_s = 0.0


func _unbind_volume() -> void:
	volume.visible = false
	if density_wrapper != null:
		density_wrapper.texture_rd_rid = RID()
	if vorticity_wrapper != null:
		vorticity_wrapper.texture_rd_rid = RID()
	if density_prev_wrapper != null:
		density_prev_wrapper.texture_rd_rid = RID()
	if vorticity_prev_wrapper != null:
		vorticity_prev_wrapper.texture_rd_rid = RID()
	_presentation_phase = 0
	_wall_since_step_s = 0.0
	_bound = false


func _update_shape() -> void:
	wing.visible = preset_index == 0
	if wing.visible:
		wing.mesh = LfmShapes.wing_mesh(config.cell_size_m())


func _exit_tree() -> void:
	_unbind_volume()
	solver.stop()
