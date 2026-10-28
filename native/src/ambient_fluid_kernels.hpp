#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace pp
{

// Ports of AmbientFluidMath functions, bit-identical to the GDScript bodies they replace.
// Inputs are validated by the GDScript caller before it hands over.
class AmbientFluidKernels : public godot::RefCounted
{
    GDCLASS(AmbientFluidKernels, godot::RefCounted)

protected:
    static void _bind_methods();

public:
    [[nodiscard]] godot::PackedFloat64Array matrix_vector_multiply(const godot::PackedFloat64Array &matrix,
                                                                   const godot::PackedFloat64Array &vector) const;
    [[nodiscard]] godot::PackedFloat64Array matrix_inverse(const godot::PackedFloat64Array &matrix,
                                                           int64_t size,
                                                           double pivot_epsilon) const;
    [[nodiscard]] godot::Dictionary clip_convex_mesh_below_plane(const godot::PackedVector3Array &triangle_vertices,
                                                                 const godot::Vector3 &interior_point,
                                                                 const godot::Vector3 &plane_normal,
                                                                 double plane_offset) const;
    [[nodiscard]] godot::Dictionary surface_wrench(const godot::PackedVector3Array &face_centers_m,
                                                   const godot::PackedVector3Array &face_normals,
                                                   const godot::PackedFloat64Array &face_areas_m2,
                                                   const godot::PackedFloat64Array &generalized_velocity,
                                                   double fluid_density_kg_m3,
                                                   double dynamic_viscosity_pa_s,
                                                   double separation_angle_rad,
                                                   double characteristic_length_m,
                                                   const godot::PackedFloat64Array &wet_area_fractions,
                                                   const godot::PackedVector3Array &wet_area_centers_m) const;
};

} // namespace pp
