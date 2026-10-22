#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pp
{

// Ports of PlanetGenerator passes, bit-identical to the GDScript bodies they replace.
class PlanetKernels : public godot::RefCounted
{
    GDCLASS(PlanetKernels, godot::RefCounted)

protected:
    static void _bind_methods();

public:
    // PlanetGenerator._unpack_vertices: [positions, normals], or [] when bytes is too short.
    [[nodiscard]] godot::Array unpack_vertices(const godot::PackedByteArray &bytes, int64_t vertex_count) const;
};

} // namespace pp
