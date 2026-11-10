#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

namespace pp
{

// Ports of FractalDE and FractalDD, bit-identical to the GDScript bodies they replace.
class FractalKernels : public godot::RefCounted
{
    GDCLASS(FractalKernels, godot::RefCounted)

protected:
    static void _bind_methods();

public:
    [[nodiscard]] double evaluate_at(double x,
                                     double y,
                                     double z,
                                     int64_t fractal_type,
                                     int64_t iterations,
                                     int64_t detail_iterations,
                                     double apollonian_scale,
                                     double klein_r,
                                     double klein_i,
                                     double klein_box_x,
                                     double klein_box_z) const;

    // z0 and c are (x hi, x lo, y hi, y lo) double-doubles.
    [[nodiscard]] godot::PackedFloat32Array orbit(int64_t step,
                                                  const godot::PackedFloat64Array &z0,
                                                  const godot::PackedFloat64Array &c,
                                                  int64_t count) const;
};

} // namespace pp
