#include "planet_kernels.hpp"

#include <array>
#include <cstring>
#include <span>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace pp
{

void PlanetKernels::_bind_methods()
{
    godot::ClassDB::bind_method(godot::D_METHOD("unpack_vertices", "bytes", "vertex_count"),
                                &PlanetKernels::unpack_vertices);
}

godot::Array PlanetKernels::unpack_vertices(const godot::PackedByteArray &bytes, int64_t vertex_count) const
{
    // position.xyz + pad, normal.xyz + pad (shaders/planet/planet_marching_cubes.comp).
    using Vertex = std::array<float, 8>;
    if (vertex_count < 0 || bytes.size() < vertex_count * static_cast<int64_t>(sizeof(Vertex)))
        return {};
    const auto count = static_cast<size_t>(vertex_count);

    godot::PackedVector3Array positions_out;
    positions_out.resize(vertex_count);
    godot::PackedVector3Array normals_out;
    normals_out.resize(vertex_count);
    const std::span<godot::Vector3> positions(positions_out.ptrw(), count);
    const std::span<godot::Vector3> normals(normals_out.ptrw(), count);
    const uint8_t *source = bytes.ptr();

    for (size_t i = 0; i < count; ++i)
    {
        Vertex vertex;
        std::memcpy(vertex.data(), source + i * sizeof(Vertex), sizeof(Vertex));
        positions[i] = godot::Vector3(vertex[0], vertex[1], vertex[2]);
        normals[i] = godot::Vector3(vertex[4], vertex[5], vertex[6]);
    }

    godot::Array out;
    out.append(positions_out);
    out.append(normals_out);
    return out;
}

} // namespace pp
