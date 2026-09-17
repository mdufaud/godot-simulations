extends SceneTree

## Boot-path probe for the Mixwell demo options and snapshot-cache churn: it
## instantiates res://scenes/mixwell_demo.tscn exactly like a player launch
## (GameManager.current_demo set, no harness) and drives the public option API.
##
## Checks:
## - every quality tier lands the tier-table spp in config AND in the dropdown
##   (the tier push passes the raw spp, the menu passes an index — both paths);
## - picking an official example re-syncs the Source dropdown;
## - the comparison overlay re-syncs the Display widget and drops diagnostics;
## - idle accumulation does not rebuild the render snapshot every frame.
##
## Log lines start with "MIXOPT ".

const CHURN_FRAMES := 120
const MAX_IDLE_BUILDS := 2


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for i in 2:
		await process_frame
	var failures := 0
	var settings: Node = root.get_node("/root/UserSettings")
	settings.clear_sim("mixwell_demo")
	var manager: Node = root.get_node("/root/GameManager")
	manager.current_demo = "mixwell_demo"
	manager.set_setting("mixwell_quality_profile", 1)

	var demo: Node = load("res://scenes/mixwell_demo.tscn").instantiate()
	root.add_child(demo)
	for i in 10:
		await process_frame
	if not demo.solver.is_initialized():
		print("MIXOPT FAIL solver not initialized (GPU compute unavailable?)")
		quit(1)
		return
	print("MIXOPT boot ok quality=%s" % demo.quality.label())

	# Quality tiers: the raw spp must reach config and the dropdown item.
	var tier := (int(demo.quality.requested) + 1) % 4
	for step in 4:
		while demo._render_transition or not demo.solver.is_initialized():
			await process_frame
		demo.quality.set_tier(tier)
		for i in 4:
			await process_frame
		var expected: int = MixwellQualityProfile.values(tier).target_spp
		var actual: int = demo.config.target_spp
		if actual != expected:
			failures += 1
			print("MIXOPT FAIL tier %d config.target_spp=%d expected %d" % [tier, actual, expected])
		var node: OptionButton = demo.quality._controls["target_spp"].node
		var shown := MixwellConfig.SPP_TARGETS.find(expected)
		if node.selected != shown:
			failures += 1
			print("MIXOPT FAIL tier %d spp dropdown item=%d expected %d" % [tier, node.selected, shown])
		tier = (tier + 1) % 4
	if failures == 0:
		print("MIXOPT PASS quality tiers drive spp + dropdown")

	# Official examples must re-sync the Source dropdown (Fig. 15 grid -> source 0).
	while demo._render_transition or not demo.solver.is_initialized():
		await process_frame
	demo._select_official_example(4)
	await process_frame
	if demo.source_option.selected != demo.source_mode:
		failures += 1
		print("MIXOPT FAIL source dropdown %d != source_mode %d" % [
			demo.source_option.selected, demo.source_mode])
	elif demo.config.source_mode != 0 or demo.solver.get_boundary_mode() \
			!= demo.config.boundary_mode:
		failures += 1
		print("MIXOPT FAIL example source not applied to config/solver")
	else:
		print("MIXOPT PASS official example re-syncs Source dropdown")

	# The comparison overlay forces Result view: Display widget + diagnostics follow.
	while demo._render_transition or not demo.solver.is_initialized():
		await process_frame
	demo._select_display(4)
	if not demo.solver.diagnostics_enabled():
		failures += 1
		print("MIXOPT FAIL display 'Area error' did not enable diagnostics")
	demo._select_comparison(1)
	if demo.display_mode != 0 or demo.display_option.selected != 0:
		failures += 1
		print("MIXOPT FAIL comparison left display_mode=%d widget=%d" % [
			demo.display_mode, demo.display_option.selected])
	elif demo.solver.diagnostics_enabled():
		failures += 1
		print("MIXOPT FAIL diagnostics still enabled under comparison overlay")
	else:
		print("MIXOPT PASS comparison overlay re-syncs Display + diagnostics")
	demo._select_comparison(0)
	await process_frame

	# Idle accumulation: the snapshot cache must hold (no per-frame rebuilds).
	while demo._render_transition or not demo.solver.is_initialized():
		await process_frame
	var builds_before: int = demo.solver.snapshot_build_count
	for i in CHURN_FRAMES:
		await process_frame
	var built: int = demo.solver.snapshot_build_count - builds_before
	if built > MAX_IDLE_BUILDS:
		failures += 1
		print("MIXOPT FAIL snapshot rebuilt %dx in %d idle frames" % [built, CHURN_FRAMES])
	else:
		print("MIXOPT PASS snapshot cache held (%d builds / %d frames)" % [built, CHURN_FRAMES])
	if demo.status_label.text.is_empty():
		failures += 1
		print("MIXOPT FAIL status label empty")
	else:
		print("MIXOPT PASS status label populated")

	if failures == 0:
		print("MIXOPT PROBE DONE ok")
		quit(0)
	else:
		print("MIXOPT PROBE DONE failures=%d" % failures)
		quit(1)
