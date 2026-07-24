extends Node3D

const VirtualJoystickScript = preload("res://scripts/ui/virtual_joystick.gd")
const SPHERICAL_GARDEN_SHADER := preload("res://shaders/non_euclidean/spherical_garden.gdshader")
const RESERVE_OUTER_SIZE := Vector3(6.0, 4.5, 8.0)
const RESERVE_INNER_SIZE := Vector3(22.0, 7.0, 30.0)
const STAIR_PERIOD := 4.0
const STAIR_RAISE := 0.45
const STAIR_WRAP_HEIGHT := 8.37
const STAIR_SEGMENTS := 48
const STAIR_CENTER_RADIUS := 3.225
const STAIR_WIDTH := 2.65
const STAIR_OUTER_RADIUS := 4.55

const EXHIBIT_NAMES := [
	"1 · Impossible Storage",
	"2 · Infinite Staircase",
	"3 · Spherical Curvature",
]

@onready var player: NonEuclideanPlayer = $Player
@onready var render_manager: PortalRenderManager = $PortalRenderManager
@onready var menu: SimMenu = $UI/SimMenu
@onready var ui_layer: CanvasLayer = $UI

var _cells: Node3D
var _materials: Dictionary = {}
var _exhibit_poses: Array[Transform3D] = []
var _current_exhibit := 0
var _case_option: OptionButton
var _hud_label: Label
var _debug_label: Label
var _touch_controls: Control
var _jump_button: Button
var _sprint_button: Button
var _reserve_props: Array[PortalRigidBody3D] = []
var _reserve_portals: Array[Portal3D] = []
var _stair_cell: Node3D
var _stair_ground_level: Node3D
var _stair_loop_seal: Node3D
var _stair_fill_light: OmniLight3D
var _stair_ascent_count := 0
var _stair_previous_local_y := 0.0
var _previous_scaling_mode: Viewport.Scaling3DMode
var _previous_scaling_scale := 1.0


func _ready() -> void:
	_previous_scaling_mode = get_viewport().scaling_3d_mode
	_previous_scaling_scale = get_viewport().scaling_3d_scale
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	_build_materials()
	_cells = Node3D.new()
	_cells.name = "Cells"
	add_child(_cells)
	_exhibit_poses.resize(EXHIBIT_NAMES.size())
	_build_impossible_reserve()
	_build_infinite_staircase()
	_build_spherical_garden()
	_setup_ui()
	_setup_touch_controls()
	render_manager.set_camera(player.get_camera())
	render_manager.configure_portals(_reserve_portals)
	_case_option.select(0)
	player.set_pose(_exhibit_poses[0])
	_update_hud()


func _physics_process(_delta: float) -> void:
	if _current_exhibit != 1 or _stair_cell == null:
		return
	var local_position := _stair_cell.to_local(player.global_position)
	if local_position.y >= STAIR_WRAP_HEIGHT:
		player.global_position += _stair_cell.global_basis * Vector3(0.0, -STAIR_PERIOD, 0.0)
		player._portal_previous_position = player.global_position
		player.reset_physics_interpolation()
		_stair_ascent_count += 1
		_stair_ground_level.position.y = -float(_stair_ascent_count) * STAIR_PERIOD
		_set_stair_loop_sealed(true)
		_update_hud()
		_stair_previous_local_y = local_position.y - STAIR_PERIOD
		return
	var moved_down := local_position.y < _stair_previous_local_y - 0.002
	var falling_down := player.velocity.dot(_stair_cell.global_basis.y) < -0.2
	if _stair_ascent_count > 0 and (moved_down or falling_down):
		_stair_ascent_count = 0
		_stair_ground_level.position.y = 0.0
		_set_stair_loop_sealed(false)
		_update_hud()
	_stair_previous_local_y = local_position.y


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		_toggle_menu()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _debug_label != null and _debug_label.visible:
		_debug_label.text = render_manager.get_debug_text()


func _build_materials() -> void:
	_materials["concrete"] = _make_downloaded_material("concrete_wall_001",
		Color(0.24, 0.27, 0.3), 0.0, 0.82, 2.5)
	_materials["concrete_dark"] = _make_material(Color(0.075, 0.09, 0.11), 0.0, 0.88)
	_materials["tile"] = _make_downloaded_material("grey_tiles",
		Color(0.16, 0.19, 0.22), 0.05, 0.46, 4.0)
	_materials["metal"] = _make_material(Color(0.065, 0.08, 0.1), 0.88, 0.25)
	_materials["white"] = _make_material(Color(0.58, 0.62, 0.66), 0.0, 0.58)
	_materials["blue"] = _make_material(Color(0.025, 0.11, 0.18), 0.35, 0.26,
		Color(0.05, 0.55, 1.0), 3.2)
	_materials["orange"] = _make_material(Color(0.18, 0.065, 0.02), 0.3, 0.3,
		Color(1.0, 0.26, 0.04), 3.2)
	_materials["green"] = _make_material(Color(0.025, 0.13, 0.08), 0.3, 0.3,
		Color(0.1, 1.0, 0.45), 3.2)
	_materials["stair_plain"] = _make_material(Color(0.2, 0.24, 0.23), 0.0, 0.84)
	_materials["measure"] = _make_material(Color(0.08, 0.13, 0.16), 0.15, 0.38,
		Color(0.12, 0.58, 0.86), 0.65)


func _build_impossible_reserve() -> void:
	var courtyard := _new_cell("ReserveCourtyard",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -200.0)))
	_build_reserve_courtyard(courtyard)
	var source := _add_portal(courtyard, "ReserveExpansion",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 1.7, 2.5)))

	var interior := _new_cell("ImpossibleReserve",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -450.0)))
	_room_shell_with_front_opening(interior, RESERVE_INNER_SIZE, Vector2(2.6, 3.4),
		_materials["concrete"], _materials["tile"])
	_add_ceiling_grid(interior, Vector2(19.0, 26.0), 6.65, Color(0.45, 0.72, 1.0), 3, 4)
	_add_reserve_floor_grid(interior, Vector2(22.0, 30.0))
	var destination := _add_portal(interior, "ReserveReturn",
		Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 1.7, 15.5)))
	_link(source, destination)
	_reserve_portals.assign([source, destination])

	var area_ratio := RESERVE_INNER_SIZE.x * RESERVE_INNER_SIZE.z \
		/ (RESERVE_OUTER_SIZE.x * RESERVE_OUTER_SIZE.z)
	_add_label(interior, "INTERIOR 22 × 30 m · 660 m² · ×%.2f FOOTPRINT" % area_ratio,
		Vector3(0.0, 5.4, -14.96), 0.0, Color(0.5, 0.78, 1.0), 76)
	_add_label(interior, "22 m", Vector3(0.0, 0.08, -14.65), 0.0,
		Color(0.35, 0.78, 1.0), 54)
	_add_label(interior, "30 m", Vector3(-10.65, 0.08, 0.0), -PI * 0.5,
		Color(0.35, 0.78, 1.0), 54)
	for x in [-7.5, 7.5]:
		for z in [-9.0, 0.0, 9.0]:
			_add_storage_rack(interior, Vector3(x, 0.0, z))
	_add_box(interior, Vector3(0.0, 0.45, -7.0), Vector3(7.0, 0.9, 3.2),
		_materials["white"])
	var courtyard_crate := _add_box_prop(courtyard, Vector3(0.0, 0.5, 4.25),
		Vector3(0.9, 0.9, 0.9), Color(0.24, 0.55, 0.78), 2.0)
	var inside_ball := _add_sphere_prop(interior, Vector3(0.0, 0.58, 12.4), 0.52,
		Color(0.92, 0.42, 0.1), 1.5)
	_reserve_props.assign([courtyard_crate, inside_ball])
	_exhibit_poses[0] = courtyard.global_transform * Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.9, 8.2))


func _build_infinite_staircase() -> void:
	_stair_cell = _new_cell("InfiniteStaircase",
		Transform3D(Basis.IDENTITY, Vector3(250.0, 0.0, -200.0)))
	_stair_ground_level = Node3D.new()
	_stair_ground_level.name = "GroundLevel"
	_stair_cell.add_child(_stair_ground_level)
	_build_stair_corridor(_stair_ground_level)
	_build_stair_core(_stair_cell)
	for module_index in range(0, 4):
		_build_stair_module(_stair_cell, float(module_index) * STAIR_PERIOD,
			module_index == 0)
	_build_stair_loop_seal(_stair_cell)
	_stair_fill_light = OmniLight3D.new()
	_stair_fill_light.name = "StairFillLight"
	_stair_fill_light.position = Vector3(0.0, 0.75, 0.0)
	_stair_fill_light.light_color = Color(0.42, 0.82, 0.62)
	_stair_fill_light.light_energy = 2.4
	_stair_fill_light.omni_range = 14.0
	_stair_fill_light.shadow_enabled = false
	_stair_fill_light.visible = false
	player.add_child(_stair_fill_light)
	_exhibit_poses[1] = _stair_cell.global_transform * Transform3D(Basis.IDENTITY,
		Vector3(-0.6, 0.9, 8.5))


func _build_stair_corridor(parent: Node3D) -> void:
	var ground_floor := _add_box(parent, Vector3(0.0, -0.12, 0.0),
		Vector3(10.2, 0.24, 10.2), _materials["tile"])
	ground_floor.name = "StairGroundFloor"
	_add_box(parent, Vector3(0.0, -0.1, 7.45), Vector3(3.2, 0.2, 6.3),
		_materials["tile"])
	_add_box(parent, Vector3(-1.85, 2.0, 7.45), Vector3(0.5, 4.0, 6.3),
		_materials["concrete"])
	_add_box(parent, Vector3(1.85, 2.0, 7.45), Vector3(0.5, 4.0, 6.3),
		_materials["concrete"])
	_add_box(parent, Vector3(0.0, 4.0, 7.45), Vector3(3.2, 0.25, 6.3),
		_materials["concrete"])
	_add_box(parent, Vector3(0.0, 2.0, 10.6), Vector3(4.2, 4.0, 0.5),
		_materials["concrete"])
	var label := _add_label(parent, "STAIRWELL ∞\nFLOOR 00", Vector3(0.0, 2.65, 10.32), PI,
		Color(0.2, 1.0, 0.55), 42)
	label.pixel_size = 0.004
	_add_ceiling_light(parent, Vector3(0.0, 3.72, 8.2), Color(0.45, 1.0, 0.72))


func _build_stair_core(parent: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "SolidCore"
	body.position.y = 8.0
	var mesh_instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.9
	mesh.bottom_radius = 1.9
	mesh.height = 20.0
	mesh.radial_segments = STAIR_SEGMENTS
	mesh_instance.mesh = mesh
	mesh_instance.layers = Portal3D.WORLD_LAYER
	mesh_instance.material_override = _materials["stair_plain"]
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 1.9
	shape.height = 20.0
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)


func _build_stair_module(parent: Node3D, base_y: float, entrance_open: bool) -> void:
	_add_helical_flight(parent, base_y)
	_add_stair_outer_wall(parent, base_y, entrance_open)
	for light_index in 4:
		var angle := PI * 0.5 + float(light_index) * PI * 0.5
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		_add_ceiling_light(parent,
			radial * 4.35 + Vector3.UP * (base_y + float(light_index) + 3.55),
			Color(0.35, 0.88, 0.62))


func _add_helical_flight(parent: Node3D, base_y: float) -> void:
	var body := StaticBody3D.new()
	body.name = "HelicalFlight"
	body.set_meta("infinite_stair_ramp", true)
	var segment_angle := TAU / float(STAIR_SEGMENTS)
	var rise := STAIR_PERIOD / float(STAIR_SEGMENTS)
	var length := TAU * STAIR_OUTER_RADIUS / float(STAIR_SEGMENTS) * 1.08
	var slope := atan(STAIR_PERIOD / (TAU * STAIR_CENTER_RADIUS))
	var slab_thickness := 0.3
	for index in STAIR_SEGMENTS:
		var angle := PI * 0.5 + (float(index) + 0.5) * segment_angle
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var tangent := Vector3(-sin(angle), 0.0, cos(angle))
		var flat_basis := Basis(radial, Vector3.UP, tangent)
		var ramp_basis := flat_basis * Basis(Vector3.RIGHT, -slope)
		var entry_raise := STAIR_RAISE
		if is_zero_approx(base_y):
			entry_raise *= minf(float(index + 1) / 6.0, 1.0)
		var visual_position := radial * STAIR_CENTER_RADIUS
		visual_position.y = base_y + float(index + 1) * rise + entry_raise \
			- slab_thickness * 0.5
		var mesh_instance := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(STAIR_WIDTH, slab_thickness, length)
		mesh_instance.mesh = mesh
		mesh_instance.transform = Transform3D(flat_basis, visual_position)
		mesh_instance.layers = Portal3D.WORLD_LAYER
		mesh_instance.material_override = _materials["tile"]
		body.add_child(mesh_instance)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(STAIR_WIDTH, 0.16, length)
		collision.shape = shape
		var collision_position := radial * STAIR_CENTER_RADIUS
		collision_position.y = base_y + (float(index) + 0.5) * rise + entry_raise - 0.08
		collision.transform = Transform3D(ramp_basis, collision_position)
		body.add_child(collision)
	parent.add_child(body)


func _add_stair_outer_wall(parent: Node3D, base_y: float, entrance_open: bool) -> void:
	var radius := 4.75
	var wall_depth := 0.4
	var segment_angle := TAU / float(STAIR_SEGMENTS)
	var segment_length := TAU * radius / float(STAIR_SEGMENTS) * 1.08
	for index in STAIR_SEGMENTS:
		var angle := PI * 0.5 + (float(index) + 0.5) * segment_angle
		var at_entrance := absf(wrapf(angle - PI * 0.5, -PI, PI)) < segment_angle * 2.7
		if entrance_open and at_entrance:
			continue
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var tangent := Vector3(-sin(angle), 0.0, cos(angle))
		var basis := Basis(tangent, Vector3.UP, -radial)
		_add_transformed_box(parent, Transform3D(basis,
			radial * radius + Vector3.UP * (base_y + STAIR_PERIOD * 0.5)),
			Vector3(segment_length, STAIR_PERIOD, wall_depth), _materials["stair_plain"])


func _build_stair_loop_seal(parent: Node3D) -> void:
	_stair_loop_seal = Node3D.new()
	_stair_loop_seal.name = "LoopSeal"
	parent.add_child(_stair_loop_seal)
	var ground_guard := _add_collision_box(_stair_loop_seal, Vector3(0.0, 2.0, 4.75),
		Vector3(3.2, 4.0, 0.4))
	ground_guard.name = "GroundOpeningGuard"
	_set_stair_loop_sealed(false)


func _add_transformed_box(parent: Node3D, box_transform: Transform3D, size: Vector3,
		material: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = box_transform
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.layers = Portal3D.WORLD_LAYER
	mesh_instance.material_override = material
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
	return body


func _add_collision_box(parent: Node3D, local_position: Vector3,
		size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = local_position
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
	return body


func _set_stair_loop_sealed(sealed: bool) -> void:
	if _stair_loop_seal == null:
		return
	_stair_loop_seal.visible = sealed
	for child in _stair_loop_seal.get_children():
		var collision := child.get_node("CollisionShape3D") as CollisionShape3D
		collision.set_deferred("disabled", not sealed)


func _build_spherical_garden() -> void:
	var center := Vector3(-300.0, 30.0, -350.0)
	var cell := _new_cell("SphericalGarden", Transform3D(Basis.IDENTITY, center))
	var visual_sphere := SphereMesh.new()
	visual_sphere.radius = 30.0
	visual_sphere.height = 60.0
	visual_sphere.radial_segments = 96
	visual_sphere.rings = 48
	visual_sphere.flip_faces = true
	var sphere_mesh := MeshInstance3D.new()
	sphere_mesh.mesh = visual_sphere
	sphere_mesh.layers = Portal3D.WORLD_LAYER
	var garden_material := ShaderMaterial.new()
	garden_material.shader = SPHERICAL_GARDEN_SHADER
	sphere_mesh.material_override = garden_material
	cell.add_child(sphere_mesh)

	var collision_sphere := SphereMesh.new()
	collision_sphere.radius = 30.0
	collision_sphere.height = 60.0
	collision_sphere.radial_segments = 48
	collision_sphere.rings = 24
	collision_sphere.flip_faces = true
	var shell_shape := collision_sphere.create_trimesh_shape()
	if shell_shape is ConcavePolygonShape3D:
		(shell_shape as ConcavePolygonShape3D).backface_collision = true
	var shell := StaticBody3D.new()
	var shell_collision := CollisionShape3D.new()
	shell_collision.shape = shell_shape
	shell.add_child(shell_collision)
	cell.add_child(shell)

	var gravity_field := GravityField3D.new()
	gravity_field.name = "RadialGravity"
	gravity_field.mode = GravityField3D.Mode.RADIAL_OUTWARD
	gravity_field.gravity_strength = 12.0
	var gravity_collision := CollisionShape3D.new()
	var gravity_shape := SphereShape3D.new()
	gravity_shape.radius = 29.85
	gravity_collision.shape = gravity_shape
	gravity_field.add_child(gravity_collision)
	cell.add_child(gravity_field)

	_add_great_circles(cell, 29.92)
	_add_spherical_columns(cell, 30.0)
	var light := OmniLight3D.new()
	light.position = Vector3.ZERO
	light.light_color = Color(0.52, 0.75, 1.0)
	light.light_energy = 5.0
	light.omni_range = 45.0
	light.shadow_enabled = true
	cell.add_child(light)
	var sphere_probe := ReflectionProbe.new()
	sphere_probe.size = Vector3.ONE * 55.0
	sphere_probe.box_projection = true
	sphere_probe.enable_shadows = false
	sphere_probe.cull_mask = Portal3D.WORLD_LAYER
	cell.add_child(sphere_probe)
	var garden_position := Vector3(0.0, -23.28, 17.46)
	var garden_up := -garden_position.normalized()
	var garden_forward := Vector3.RIGHT
	var garden_right := garden_forward.cross(garden_up).normalized()
	var garden_basis := Basis(garden_right, garden_up, -garden_forward).orthonormalized()
	_exhibit_poses[2] = cell.global_transform * Transform3D(garden_basis, garden_position)


func _setup_ui() -> void:
	menu.title = "Non-Euclidean Laboratory"
	menu.panel_toggled.connect(_on_menu_panel_toggled)
	menu.add_section("Navigation")
	_case_option = menu.add_option_button("Area", EXHIBIT_NAMES, 0, _go_to_case)
	menu.add_action("↺", "Reset", _reset_current_case)
	menu.add_separator()
	menu.add_section("Impossible Storage")
	menu.add_label("Live native-resolution view · dedicated render target · no fallback image")
	menu.add_debug_toggle("🧊", "Debug crossing volume", false,
		func(enabled: bool) -> void:
			render_manager.set_debug_enabled(enabled)
			_debug_label.visible = enabled
	)
	menu.add_separator()
	menu.add_section("Performance")
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, _set_render_scale)

	var panel := PanelContainer.new()
	panel.position = Vector2(18.0, 18.0)
	panel.custom_minimum_size = Vector2(430.0, 72.0)
	ui_layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	_hud_label = Label.new()
	_hud_label.add_theme_font_size_override("font_size", 20)
	box.add_child(_hud_label)
	var hint := Label.new()
	hint.text = "Joystick + drag to look · Jump, sprint and menu on screen" \
		if VirtualJoystickScript.is_touch_ui() else "WASD/ZQSD · Space jump · Shift sprint · F1 settings"
	hint.modulate = Color(1.0, 1.0, 1.0, 0.62)
	box.add_child(hint)

	var crosshair := Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 24)
	crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.position = Vector2(-12.0, -18.0)
	crosshair.size = Vector2(24.0, 36.0)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(crosshair)

	_debug_label = Label.new()
	_debug_label.position = Vector2(18.0, 102.0)
	_debug_label.add_theme_font_size_override("font_size", 15)
	_debug_label.modulate = Color(0.55, 0.9, 1.0)
	_debug_label.visible = false
	ui_layer.add_child(_debug_label)


func _set_render_scale(v: float) -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = v


func _setup_touch_controls() -> void:
	if not VirtualJoystickScript.is_touch_ui():
		return
	_touch_controls = Control.new()
	_touch_controls.name = "TouchActions"
	_touch_controls.mouse_filter = Control.MOUSE_FILTER_PASS
	_touch_controls.theme = load("res://resources/themes/main_theme.tres")
	ui_layer.add_child(_touch_controls)
	get_viewport().size_changed.connect(_layout_touch_controls)
	_layout_touch_controls()

	_jump_button = Button.new()
	_jump_button.text = "Saut"
	_jump_button.pressed.connect(player.request_touch_jump)
	_touch_controls.add_child(_jump_button)

	_sprint_button = Button.new()
	_sprint_button.text = "Courir"
	_sprint_button.button_down.connect(func() -> void: player.set_touch_sprinting(true))
	_sprint_button.button_up.connect(func() -> void: player.set_touch_sprinting(false))
	_touch_controls.add_child(_sprint_button)
	_layout_touch_controls()


func _layout_touch_controls() -> void:
	if _touch_controls == null:
		return
	_touch_controls.size = get_viewport().get_visible_rect().size
	if _jump_button != null:
		_jump_button.position = Vector2(_touch_controls.size.x - 152.0, _touch_controls.size.y - 104.0)
		_jump_button.size = Vector2(128.0, 72.0)
	if _sprint_button != null:
		_sprint_button.position = Vector2(_touch_controls.size.x - 152.0, _touch_controls.size.y - 192.0)
		_sprint_button.size = Vector2(128.0, 72.0)


func _toggle_menu() -> void:
	menu.toggle_panel()


func _on_menu_panel_toggled(open: bool) -> void:
	player.set_controls_enabled(not open)
	if _jump_button != null:
		_jump_button.visible = not open
	if _sprint_button != null:
		_sprint_button.visible = not open


func _go_to_case(index: int) -> void:
	if index < 0 or index >= _exhibit_poses.size():
		return
	_current_exhibit = index
	var gravity := Vector3.DOWN * 12.0
	var radial_field: GravityField3D
	if index == 2:
		radial_field = _cells.get_node("SphericalGarden/RadialGravity") as GravityField3D
		gravity = radial_field.sample_gravity(_exhibit_poses[index].origin)
	player.set_pose(_exhibit_poses[index], gravity)
	if _stair_fill_light != null:
		_stair_fill_light.visible = index == 1
	if index == 1:
		_stair_previous_local_y = _stair_cell.to_local(player.global_position).y
	if radial_field != null:
		player.set_gravity_field(radial_field)
	if _case_option != null:
		_case_option.select(index)
	_update_hud()
	if menu.is_panel_open():
		menu.toggle_panel()


func _reset_current_case() -> void:
	if _current_exhibit == 0:
		_reset_reserve_props()
	elif _current_exhibit == 1:
		_stair_ascent_count = 0
		_stair_ground_level.position.y = 0.0
		_set_stair_loop_sealed(false)
	_go_to_case(_current_exhibit)


func _update_hud() -> void:
	if _hud_label == null:
		return
	match _current_exhibit:
		0:
			_hud_label.text = "%s\nWalk around the 6 × 8 m building, then enter its 22 × 30 m interior." % EXHIBIT_NAMES[0]
		1:
			_hud_label.text = "%s\nAscents: %d · Turn around and the climb never happened." % [
				EXHIBIT_NAMES[1], _stair_ascent_count]
		2:
			_hud_label.text = "%s\nWalk a great circle. Gravity remains radial." % EXHIBIT_NAMES[2]


func _reset_reserve_props() -> void:
	if _reserve_props.size() != 2:
		return
	var poses := [
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.5, -195.75)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.58, -437.6)),
	]
	for index in _reserve_props.size():
		var body := _reserve_props[index]
		body.global_transform = poses[index]
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.sleeping = false


func _link(a: Portal3D, b: Portal3D) -> void:
	a.linked_portal = b
	b.linked_portal = a


func _new_cell(cell_name: String, cell_transform: Transform3D) -> Node3D:
	var cell := Node3D.new()
	cell.name = cell_name
	cell.transform = cell_transform
	_cells.add_child(cell)
	return cell


func _build_reserve_courtyard(parent: Node3D) -> void:
	_add_box(parent, Vector3(0.0, -0.25, 0.0), Vector3(30.0, 0.5, 26.0), _materials["tile"])
	_add_box(parent, Vector3(-15.25, 4.0, 0.0), Vector3(0.5, 8.0, 26.0), _materials["concrete"])
	_add_box(parent, Vector3(15.25, 4.0, 0.0), Vector3(0.5, 8.0, 26.0), _materials["concrete"])
	_add_box(parent, Vector3(0.0, 4.0, -13.25), Vector3(30.0, 8.0, 0.5), _materials["concrete"])
	_add_box(parent, Vector3(0.0, 4.0, 13.25), Vector3(30.0, 8.0, 0.5), _materials["concrete"])
	_build_reserve_outer_shell(parent, Vector3(0.0, 0.0, -1.5), RESERVE_OUTER_SIZE,
		Vector2(2.6, 3.4))
	_add_label(parent, "STORAGE A-01", Vector3(0.0, 4.05, 2.53), 0.0,
		Color(0.68, 0.82, 0.9), 68)
	_add_box(parent, Vector3(7.0, 1.55, 2.45), Vector3(4.6, 2.7, 0.14),
		_materials["metal"], false)
	_add_label(parent, "EXTERIOR 6 × 8 m · 48 m²\nENTER TO VERIFY INTERIOR\nWALK AROUND THE BUILDING",
		Vector3(7.0, 1.55, 2.53), 0.0, Color(0.22, 0.72, 1.0), 38)
	_add_label(parent, "6 m", Vector3(0.0, 0.08, 3.25), 0.0,
		Color(0.28, 0.75, 1.0), 48)
	_add_label(parent, "8 m", Vector3(-3.55, 0.08, -1.5), -PI * 0.5,
		Color(0.28, 0.75, 1.0), 48)
	_add_box(parent, Vector3(0.0, 0.025, 3.0), Vector3(6.0, 0.05, 0.08),
		_materials["measure"], false)
	_add_box(parent, Vector3(-3.3, 0.025, -1.5), Vector3(0.08, 0.05, 8.0),
		_materials["measure"], false)
	_add_box(parent, Vector3(0.0, 8.25, 0.0), Vector3(30.0, 0.5, 26.0),
		_materials["concrete"])
	_add_ceiling_grid(parent, Vector2(26.0, 22.0), 7.95, Color(0.58, 0.75, 0.92), 4, 3)
	_add_omni_light(parent, Vector3(0.0, 6.8, 5.0), Color(0.58, 0.75, 0.92), 2.4, 18.0, true)


func _build_reserve_outer_shell(parent: Node3D, center: Vector3, size: Vector3,
		opening: Vector2) -> void:
	var wall := 0.5
	var inner_width := size.x - wall * 2.0
	var side_width := (inner_width - opening.x) * 0.5
	var front_z := center.z + size.z * 0.5 - wall * 0.5
	_add_box(parent, center + Vector3(-size.x * 0.5 + wall * 0.5, size.y * 0.5, 0.0),
		Vector3(wall, size.y, size.z), _materials["concrete"])
	_add_box(parent, center + Vector3(size.x * 0.5 - wall * 0.5, size.y * 0.5, 0.0),
		Vector3(wall, size.y, size.z), _materials["concrete"])
	_add_box(parent, center + Vector3(0.0, size.y * 0.5, -size.z * 0.5 + wall * 0.5),
		Vector3(inner_width, size.y, wall), _materials["concrete"])
	_add_box(parent, center + Vector3(0.0, size.y - wall * 0.5, 0.0),
		Vector3(inner_width, wall, size.z - wall * 2.0), _materials["concrete"])
	var side_offset := opening.x * 0.5 + side_width * 0.5
	_add_box(parent, Vector3(-side_offset, size.y * 0.5, front_z),
		Vector3(side_width, size.y, wall), _materials["concrete"])
	_add_box(parent, Vector3(side_offset, size.y * 0.5, front_z),
		Vector3(side_width, size.y, wall), _materials["concrete"])
	var top_height := size.y - opening.y
	_add_box(parent, Vector3(0.0, opening.y + top_height * 0.5, front_z),
		Vector3(opening.x, top_height, wall), _materials["concrete"])


func _room_shell_with_front_opening(parent: Node3D, size: Vector3, opening: Vector2,
		wall_material: Material, floor_material: Material) -> void:
	var wall := 0.5
	var floor := _add_box(parent, Vector3(0.0, -wall * 0.5, wall * 0.5),
		Vector3(size.x, wall, size.z + wall), floor_material)
	floor.name = "PortalThreshold"
	floor.set_meta("portal_threshold", true)
	_add_box(parent, Vector3(0.0, size.y + wall * 0.5, 0.0), Vector3(size.x, wall, size.z), wall_material)
	_add_box(parent, Vector3(-size.x * 0.5 - wall * 0.5, size.y * 0.5, 0.0),
		Vector3(wall, size.y, size.z), wall_material)
	_add_box(parent, Vector3(size.x * 0.5 + wall * 0.5, size.y * 0.5, 0.0),
		Vector3(wall, size.y, size.z), wall_material)
	_add_box(parent, Vector3(0.0, size.y * 0.5, -size.z * 0.5 - wall * 0.5),
		Vector3(size.x, size.y, wall), wall_material)
	_add_opening_wall(parent, size, opening, size.z * 0.5 + wall * 0.5, wall_material)
	var probe := ReflectionProbe.new()
	probe.position = Vector3(0.0, size.y * 0.5, 0.0)
	probe.size = size - Vector3.ONE
	probe.box_projection = true
	probe.enable_shadows = false
	probe.cull_mask = Portal3D.WORLD_LAYER
	parent.add_child(probe)


func _add_opening_wall(parent: Node3D, size: Vector3, opening: Vector2, wall_z: float,
		wall_material: Material) -> void:
	var wall := 0.5
	var side_width := (size.x - opening.x) * 0.5
	var side_offset := opening.x * 0.5 + side_width * 0.5
	_add_box(parent, Vector3(-side_offset, size.y * 0.5, wall_z),
		Vector3(side_width, size.y, wall), wall_material)
	_add_box(parent, Vector3(side_offset, size.y * 0.5, wall_z),
		Vector3(side_width, size.y, wall), wall_material)
	var top_height := size.y - opening.y
	_add_box(parent, Vector3(0.0, opening.y + top_height * 0.5, wall_z),
		Vector3(opening.x, top_height, wall), wall_material)


func _add_reserve_floor_grid(parent: Node3D, size: Vector2) -> void:
	for x in range(-10, 11, 2):
		_add_box(parent, Vector3(float(x), 0.012, 0.0), Vector3(0.025, 0.02, size.y),
			_materials["measure"], false)
	for z in range(-14, 15, 2):
		_add_box(parent, Vector3(0.0, 0.014, float(z)), Vector3(size.x, 0.022, 0.025),
			_materials["measure"], false)


func _add_storage_rack(parent: Node3D, center: Vector3) -> void:
	for x_offset in [-0.56, 0.56]:
		for z_offset in [-2.18, 2.18]:
			_add_box(parent, center + Vector3(x_offset, 2.4, z_offset),
				Vector3(0.12, 4.8, 0.12), _materials["metal"])
	for height in [0.42, 1.62, 2.82, 4.02, 4.72]:
		_add_box(parent, center + Vector3(0.0, height, 0.0),
			Vector3(1.25, 0.1, 4.5), _materials["white"])
	_add_box(parent, center + Vector3(0.0, 0.92, -1.25), Vector3(0.82, 0.9, 0.82),
		_materials["blue"], false)
	_add_box(parent, center + Vector3(0.0, 2.12, 1.15), Vector3(0.88, 0.9, 0.92),
		_materials["orange"], false)


func _add_box(parent: Node3D, local_position: Vector3, size: Vector3, material: Material,
		collision := true, rotation := Vector3.ZERO) -> Node3D:
	if collision:
		var body := StaticBody3D.new()
		body.position = local_position
		body.rotation = rotation
		var mesh_instance := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = size
		mesh_instance.mesh = mesh
		mesh_instance.layers = Portal3D.WORLD_LAYER
		mesh_instance.material_override = material
		body.add_child(mesh_instance)
		var collision_shape := CollisionShape3D.new()
		collision_shape.name = "CollisionShape3D"
		var shape := BoxShape3D.new()
		shape.size = size
		collision_shape.shape = shape
		body.add_child(collision_shape)
		parent.add_child(body)
		return body
	var visual := MeshInstance3D.new()
	var visual_mesh := BoxMesh.new()
	visual_mesh.size = size
	visual.mesh = visual_mesh
	visual.position = local_position
	visual.rotation = rotation
	visual.layers = Portal3D.WORLD_LAYER
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(visual)
	return visual


func _add_ceiling_grid(parent: Node3D, area: Vector2, height: float, color: Color,
		columns: int, rows: int) -> void:
	for x_index in columns:
		for z_index in rows:
			var x := 0.0 if columns == 1 else lerpf(-area.x * 0.42, area.x * 0.42,
				float(x_index) / float(columns - 1))
			var z := 0.0 if rows == 1 else lerpf(-area.y * 0.42, area.y * 0.42,
				float(z_index) / float(rows - 1))
			var emissive := _make_material(Color(0.12, 0.14, 0.16), 0.2, 0.25, color, 3.5)
			_add_box(parent, Vector3(x, height, z), Vector3(1.8, 0.08, 0.24), emissive, false)
			if (x_index + z_index) % 3 == 0:
				_add_omni_light(parent, Vector3(x, height - 0.25, z), color, 1.7, 10.0, false)


func _add_ceiling_light(parent: Node3D, local_position: Vector3, color: Color) -> void:
	var emissive := _make_material(Color(0.12, 0.14, 0.16), 0.2, 0.25, color, 3.5)
	_add_box(parent, local_position, Vector3(2.4, 0.08, 0.3), emissive, false)


func _add_omni_light(parent: Node3D, local_position: Vector3, color: Color, energy: float,
		range_value: float, shadows: bool) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.position = local_position
	light.light_color = color
	light.light_energy = energy
	light.omni_range = range_value
	light.shadow_enabled = shadows
	parent.add_child(light)
	return light


func _add_portal(parent: Node3D, portal_name: String,
		portal_transform: Transform3D) -> Portal3D:
	var portal := Portal3D.new()
	portal.name = portal_name
	portal.transform = portal_transform
	parent.add_child(portal)
	return portal


func _add_label(parent: Node3D, text: String, local_position: Vector3, yaw: float,
		color: Color, font_size: int) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position = local_position
	label.rotation.y = yaw
	label.font_size = font_size
	label.pixel_size = 0.006
	label.modulate = color
	label.outline_size = 8
	parent.add_child(label)
	return label


func _add_box_prop(parent: Node3D, local_position: Vector3, size: Vector3,
		color: Color, mass_value: float) -> PortalRigidBody3D:
	var body := PortalRigidBody3D.new()
	body.position = local_position
	body.mass = mass_value
	body.albedo = color
	body.material_roughness = 0.52
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.layers = Portal3D.WORLD_LAYER
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.72
	physics_material.bounce = 0.08
	body.physics_material_override = physics_material
	parent.add_child(body)
	return body


func _add_sphere_prop(parent: Node3D, local_position: Vector3, radius: float,
		color: Color, mass_value: float) -> PortalRigidBody3D:
	var body := PortalRigidBody3D.new()
	body.position = local_position
	body.mass = mass_value
	body.albedo = color
	body.material_roughness = 0.22
	body.material_metallic = 0.35
	body.continuous_cd = true
	var mesh_instance := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh_instance.mesh = mesh
	mesh_instance.layers = Portal3D.WORLD_LAYER
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius
	collision.shape = shape
	body.add_child(collision)
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.48
	physics_material.bounce = 0.32
	body.physics_material_override = physics_material
	parent.add_child(body)
	return body


func _add_great_circles(parent: Node3D, radius: float) -> void:
	var segment_count := 96
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.16, 0.035, TAU * radius / float(segment_count) * 1.08)
	mesh.material = _materials["blue"]
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = segment_count * 3
	var index := 0
	for circle in 3:
		for segment in segment_count:
			var angle := TAU * float(segment) / float(segment_count)
			var direction := Vector3.ZERO
			var tangent := Vector3.ZERO
			if circle == 0:
				direction = Vector3(cos(angle), sin(angle), 0.0)
				tangent = Vector3(-sin(angle), cos(angle), 0.0)
			elif circle == 1:
				direction = Vector3(cos(angle), 0.0, sin(angle))
				tangent = Vector3(-sin(angle), 0.0, cos(angle))
			else:
				direction = Vector3(0.0, cos(angle), sin(angle))
				tangent = Vector3(0.0, -sin(angle), cos(angle))
			var local_up := -direction
			var local_right := local_up.cross(tangent).normalized()
			var basis := Basis(local_right, local_up, tangent).orthonormalized()
			multimesh.set_instance_transform(index, Transform3D(basis, direction * radius))
			index += 1
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.layers = Portal3D.WORLD_LAYER
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)


func _add_spherical_columns(parent: Node3D, radius: float) -> void:
	for index in 24:
		var angle := TAU * float(index) / 24.0
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var up := -direction
		var forward := Vector3.UP
		var right := up.cross(forward).normalized()
		var basis := Basis(right, up, forward).orthonormalized()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.16
		mesh.bottom_radius = 0.24
		mesh.height = 4.0
		mesh.material = _materials["blue"]
		var column := MeshInstance3D.new()
		column.mesh = mesh
		column.transform = Transform3D(basis, direction * (radius - 2.0))
		column.layers = Portal3D.WORLD_LAYER
		parent.add_child(column)


func _make_material(color: Color, metallic: float, roughness: float,
		emission := Color(0.0, 0.0, 0.0), emission_energy := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = emission_energy
	return material


func _make_downloaded_material(asset: String, fallback: Color, metallic: float,
		roughness: float, uv_scale: float) -> StandardMaterial3D:
	var material := _make_material(fallback, metallic, roughness)
	var directory := "res://resources/materials/%s/" % asset
	var diffuse_path := "%s%s_diff_2k.jpg" % [directory, asset]
	var normal_path := "%s%s_nor_gl_2k.jpg" % [directory, asset]
	var roughness_path := "%s%s_rough_2k.jpg" % [directory, asset]
	if ResourceLoader.exists(diffuse_path):
		material.albedo_color = Color.WHITE
		material.albedo_texture = load(diffuse_path) as Texture2D
	if ResourceLoader.exists(normal_path):
		material.normal_enabled = true
		material.normal_texture = load(normal_path) as Texture2D
	if ResourceLoader.exists(roughness_path):
		material.roughness_texture = load(roughness_path) as Texture2D
	material.uv1_scale = Vector3.ONE * uv_scale
	return material


func _exit_tree() -> void:
	_materials.clear()
	var viewport := get_viewport()
	if viewport != null:
		viewport.scaling_3d_mode = _previous_scaling_mode
		viewport.scaling_3d_scale = _previous_scaling_scale
