class_name FireWeapons
extends Node3D

enum Kind { NONE, WATER_GUN, FLAMETHROWER }

var kind := Kind.NONE

@onready var _water_gun: Node3D = $WaterGun
@onready var _flamethrower: Node3D = $Flamethrower
@onready var _pilot: Node3D = $Flamethrower/Pilot


func _ready() -> void:
	equip(kind)


func equip(value: Kind) -> void:
	kind = value
	_water_gun.visible = kind == Kind.WATER_GUN
	_flamethrower.visible = kind == Kind.FLAMETHROWER
	if kind != Kind.FLAMETHROWER:
		_pilot.visible = false


func set_firing(on: bool) -> void:
	_pilot.visible = on and kind == Kind.FLAMETHROWER


func muzzle_position() -> Vector3:
	match kind:
		Kind.WATER_GUN:
			return ($WaterGun/Muzzle as Marker3D).global_position
		Kind.FLAMETHROWER:
			return ($Flamethrower/Muzzle as Marker3D).global_position
	return global_position
