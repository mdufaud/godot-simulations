#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

namespace pp
{

// Port of SmokeVoxelizer.voxelize, bit-identical to the GDScript body it replaces.
class SmokeKernels : public godot::RefCounted
{
    GDCLASS(SmokeKernels, godot::RefCounted)

protected:
    static void _bind_methods();

public:
    [[nodiscard]] godot::PackedFloat32Array voxelize(const godot::PackedVector3Array &faces,
                                                     const godot::Vector3 &origin_m,
                                                     double cell_m,
                                                     const godot::Vector3i &dims,
                                                     int64_t rays_per_axis) const;
};

} // namespace pp
