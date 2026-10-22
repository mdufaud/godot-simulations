class_name Native
extends RefCounted
## The C++ kernels of addons/physics_native/physics_native.gdextension. Every caller keeps
## its GDScript body as the reference: NATIVE_KERNELS=0, or a parity check clearing
## `enabled`, runs that body instead.

static var enabled := OS.get_environment("NATIVE_KERNELS") != "0"


## A new instance of the kernel class `name`, or null when the kernels are off or
## the extension is not loaded.
static func kernel(name: StringName) -> Object:
	if not enabled or not ClassDB.class_exists(name):
		return null
	return ClassDB.instantiate(name)
