#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

#include "ambient_fluid_kernels.hpp"
#include "fractal_kernels.hpp"
#include "planet_kernels.hpp"

namespace
{

void initialize(godot::ModuleInitializationLevel level)
{
    if (level != godot::MODULE_INITIALIZATION_LEVEL_SCENE)
        return;
    GDREGISTER_CLASS(pp::AmbientFluidKernels);
    GDREGISTER_CLASS(pp::FractalKernels);
    GDREGISTER_CLASS(pp::PlanetKernels);
}

void uninitialize([[maybe_unused]] godot::ModuleInitializationLevel level) {}

} // namespace

extern "C" GDExtensionBool GDE_EXPORT physics_native_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                                          GDExtensionClassLibraryPtr library,
                                                          GDExtensionInitialization *initialization)
{
    godot::GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize);
    init.register_terminator(uninitialize);
    init.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
