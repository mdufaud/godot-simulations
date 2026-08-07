class_name AmbientFluidMenu
extends RefCounted

var _status_label: Label
var _fluid_option: OptionButton
var _scenario_option: OptionButton
var _fluid_model_option: OptionButton


func build(menu: SimMenu, medium_index: int, object_index: int,
		object_density_kg_m3: float, throw_speed_m_s: float,
		flow_speed_m_s: float, callbacks: Dictionary) -> void:
	menu.title = "💧 Rigid Bodies in Fluids"
	var intro := menu.add_label("Pool mode is an approximation outside the article domain. Scientific scenarios use fully immersed bodies in a uniform medium with an identical vacuum baseline.")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	menu.add_section("Experiment")
	_scenario_option = menu.add_option_button("Scenario", ["Pool Showcase", "Falling Plate",
		"Magnus Ball", "Balloon", "Underwater Body"], 0, callbacks.scenario)
	_fluid_model_option = menu.add_option_button("Fluid Model", ["Pool Approximation", "Article Uniform"], 0,
		callbacks.fluid_model)
	menu.add_toggle("Vacuum Baseline", true, callbacks.vacuum_baseline)
	var fluid_density := menu.add_slider("Fluid Density", 0.0, 1500.0, 998.0,
		callbacks.fluid_density)
	fluid_density.step = 1.0
	var viscosity := menu.add_slider("Dynamic Viscosity", 0.0, 2.0, 0.001,
		callbacks.viscosity)
	viscosity.step = 0.001
	var separation := menu.add_slider("Separation Angle", 90.0, 180.0, 90.0,
		callbacks.separation)
	separation.step = 1.0
	var initial_speed := menu.add_slider("Initial Speed", 0.0, 20.0, 0.0,
		callbacks.initial_speed)
	initial_speed.step = 0.5
	var initial_spin := menu.add_slider("Initial Spin", 0.0, 20.0, 0.0,
		callbacks.initial_spin)
	initial_spin.step = 0.5
	_fluid_option = menu.add_option_button("Fluid", ["Water", "Oil", "Honey", "Air", "Vacuum"], medium_index,
		callbacks.medium)
	menu.add_option_button("Object", ["Ball", "Cube", "Plate", "Random"], object_index,
		callbacks.object)
	var density := menu.add_slider("Object Density", 10.0, 3000.0,
		object_density_kg_m3, callbacks.object_density)
	density.step = 10.0
	var speed := menu.add_slider("Max Throw Speed", 4.0, 28.0, throw_speed_m_s,
		callbacks.throw_speed)
	speed.step = 0.5
	var flow := menu.add_slider("Current", -4.0, 4.0, flow_speed_m_s,
		callbacks.flow_speed)
	flow.step = 0.1
	var guide := menu.add_label("Labels show density and mass. Yellow object is lighter than current medium; red/steel objects are heavier. Switch Air/Vacuum then press Drop Mix to compare lift versus free fall.")
	guide.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	menu.add_section("Live Result")
	_status_label = menu.add_label("")
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	menu.add_action("💧", "Next Fluid", callbacks.next_fluid)
	menu.add_action("➤", "Throw", callbacks.throw)
	menu.add_action("▦", "Drop Mix", callbacks.drop_mix)
	menu.add_action("↺", "Reset", callbacks.reset)
	menu.add_action("⌫", "Clear", callbacks.clear)
	menu.add_action("CSV", "Export CSV", callbacks.export_csv)


func sync_fluid(index: int) -> void:
	if _fluid_option != null:
		_fluid_option.select(index)


func sync_scenario(index: int) -> void:
	if _scenario_option != null:
		_scenario_option.select(index)
	if _fluid_model_option != null:
		_fluid_model_option.select(0 if index == 0 else 1)


func update_status(bodies: Array[AmbientFluidBody3D], medium_name: String,
		last_action: String, scenario_name := "Pool Showcase") -> void:
	if _status_label == null:
		return
	var moving := 0
	var underwater := 0
	var average_speed := 0.0
	var total_energy := 0.0
	var total_cpu_us := 0
	for body in bodies:
		if not is_instance_valid(body):
			continue
		average_speed += body.speed_m_s()
		total_energy += body.kinetic_energy_j()
		total_cpu_us += body.integration_cpu_time_us()
		if body.speed_m_s() > 0.15:
			moving += 1
		if body.global_position.y < 0.4:
			underwater += 1
	if not bodies.is_empty():
		average_speed /= bodies.size()
	_status_label.text = "Scenario: %s\nFluid: %s\nObjects: %d (moving %d, below surface %d)\nAverage speed: %.2f m/s\nKinetic energy: %.3f J · CPU: %d µs\nContacts use body inertia Kb, not combined K.\nLast action: %s\n\nF cycles fluid. Right-click or Space throws." % [
		scenario_name, medium_name, bodies.size(), moving, underwater, average_speed, total_energy,
		total_cpu_us, last_action]
