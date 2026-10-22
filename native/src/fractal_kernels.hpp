#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace pp
{

// Ports of FractalDE, bit-identical to the GDScript bodies they replace.
class FractalKernels : public godot::RefCounted
{
    GDCLASS(FractalKernels, godot::RefCounted)

protected:
    static void _bind_methods();

public:
    [[nodiscard]] double evaluate(const godot::Vector3 &p,
                                  int64_t fractal_type,
                                  int64_t iterations,
                                  double apollonian_scale,
                                  double klein_r,
                                  double klein_i,
                                  double klein_box_x,
                                  double klein_box_z) const;
};

} // namespace pp
