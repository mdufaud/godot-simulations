extends "res://tests/test_case.gd"
## CPU gates for the wildfire fire records: a fire told to die is removed once its
## smoke has cleared, a persistent one is not, and a cluster's single fog cloud
## survives its owner going out. No GPU: the particle nodes are only created.

const BONFIRE := preload("res://resources/wildfire/presets/bonfire.tres")
const STEP := 1.0 / 30.0

var _system: WildfireSystem


func _initialize() -> void:
	_system = WildfireSystem.new()
	root.add_child(_system)
	_system.build(WildfireConfig.new())
	_test_cold_fire_is_removed()
	_test_persistent_fire_stays()
	_test_fog_survives_owner()
	_system.clear_all()
	_finish("wildfire_system")


func _advance(seconds: float) -> void:
	var elapsed := 0.0
	while elapsed < seconds:
		_system.update(STEP, Vector3.ZERO)
		elapsed += STEP


func _test_cold_fire_is_removed() -> void:
	_system.clear_all()
	var id := _system.add_fire(Vector3.ZERO, BONFIRE)
	_advance(2.0)
	_system.set_target(id, 0.0)
	_advance(1.0)
	_check(_system.fire_count() == 1, "a dying fire is kept while its smoke is in the air")
	_advance(BONFIRE.smoke_lifetime_s + 3.0)
	_check(_system.fire_count() == 0, "a fire set to target 0 is removed once cold")


func _test_persistent_fire_stays() -> void:
	_system.clear_all()
	var id := _system.add_fire(Vector3.ZERO, BONFIRE, false)
	_system.set_target(id, 0.0)
	_advance(BONFIRE.smoke_lifetime_s + 4.0)
	_check(_system.fire_count() == 1, "remove_when_cold false keeps the fire record")


func _test_fog_survives_owner() -> void:
	_system.clear_all()
	var owner := _system.add_fire(Vector3.ZERO, BONFIRE)
	var neighbour := _system.add_fire(Vector3(BONFIRE.haze_radius_m * 0.5, 0.0, 0.0), BONFIRE)
	_check(_system._fires_by_id[owner].fog != null, "the first fire of a cluster owns its fog")
	_check(_system._fires_by_id[neighbour].fog == null, "the cluster has a single fog cloud")
	_system.remove_fire(owner)
	_check(_system._fires_by_id[neighbour].fog != null,
		"the cluster's fog moved to the fire still burning")
