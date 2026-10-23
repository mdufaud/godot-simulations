#include "smoke_kernels.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <span>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

namespace pp
{

namespace
{

namespace Math = godot::Math;
using godot::Vector3;

constexpr double miss = std::numeric_limits<double>::infinity();

// SmokeVoxelizer._ray_x_hit.
double ray_x_hit(const Vector3 &a, const Vector3 &b, const Vector3 &c, double ry, double rz)
{
    const double ay = a.y;
    const double az = a.z;
    const double by = double{b.y} - ay;
    const double bz = double{b.z} - az;
    const double cy = double{c.y} - ay;
    const double cz = double{c.z} - az;
    const double det = by * cz - bz * cy;
    if (std::abs(det) < 1e-18)
        return miss;
    const double py = ry - ay;
    const double pz = rz - az;
    const double wb = (py * cz - pz * cy) / det;
    const double wc = (by * pz - bz * py) / det;
    if (wb < 0.0 || wc < 0.0 || wb + wc > 1.0)
        return miss;
    return double{a.x} + wb * (double{b.x} - double{a.x}) + wc * (double{c.x} - double{a.x});
}

int64_t cell_of(double coordinate, double origin, double cell_m, int64_t count)
{
    return Math::clamp(static_cast<int64_t>(std::floor((coordinate - origin) / cell_m)), int64_t{0}, count - 1);
}

} // namespace

void SmokeKernels::_bind_methods()
{
    godot::ClassDB::bind_method(godot::D_METHOD("voxelize", "faces", "origin_m", "cell_m", "dims", "rays_per_axis"),
                                &SmokeKernels::voxelize);
}

godot::PackedFloat32Array SmokeKernels::voxelize(const godot::PackedVector3Array &faces,
                                                 const godot::Vector3 &origin_m,
                                                 double cell_m,
                                                 const godot::Vector3i &dims,
                                                 int64_t rays_per_axis) const
{
    const int64_t nx = dims.x;
    const int64_t ny = dims.y;
    const int64_t nz = dims.z;
    godot::PackedFloat32Array out_array;
    out_array.resize(nx * ny * nz);
    const int64_t triangle_count = faces.size() / 3;
    if (triangle_count == 0 || rays_per_axis < 1 || cell_m <= 0.0 || nx < 1 || ny < 1 || nz < 1)
        return out_array;
    const std::span<float> out(out_array.ptrw(), static_cast<size_t>(nx * ny * nz));
    const std::span<const Vector3> tris(faces.ptr(), static_cast<size_t>(triangle_count * 3));
    const double ox = origin_m.x;
    const double oy = origin_m.y;
    const double oz = origin_m.z;

    std::vector<int64_t> spans(static_cast<size_t>(triangle_count * 4));
    std::vector<int32_t> starts(static_cast<size_t>(ny * nz + 1), 0);
    for (int64_t t = 0; t < triangle_count; ++t)
    {
        const Vector3 &a = tris[static_cast<size_t>(t * 3)];
        const Vector3 &b = tris[static_cast<size_t>(t * 3 + 1)];
        const Vector3 &c = tris[static_cast<size_t>(t * 3 + 2)];
        const auto span = spans.begin() + t * 4;
        span[0] = cell_of(Math::min(Math::min(double{a.y}, double{b.y}), double{c.y}), oy, cell_m, ny);
        span[1] = cell_of(Math::max(Math::max(double{a.y}, double{b.y}), double{c.y}), oy, cell_m, ny);
        span[2] = cell_of(Math::min(Math::min(double{a.z}, double{b.z}), double{c.z}), oz, cell_m, nz);
        span[3] = cell_of(Math::max(Math::max(double{a.z}, double{b.z}), double{c.z}), oz, cell_m, nz);
        for (int64_t k = span[2]; k <= span[3]; ++k)
            for (int64_t j = span[0]; j <= span[1]; ++j)
                ++starts[static_cast<size_t>(k * ny + j + 1)];
    }
    for (size_t column = 0; column + 1 < starts.size(); ++column)
        starts[column + 1] += starts[column];
    std::vector<int32_t> cursor = starts;
    std::vector<int32_t> items(static_cast<size_t>(starts.back()));
    for (int64_t t = 0; t < triangle_count; ++t)
    {
        const auto span = spans.begin() + t * 4;
        for (int64_t k = span[2]; k <= span[3]; ++k)
            for (int64_t j = span[0]; j <= span[1]; ++j)
                items[static_cast<size_t>(cursor[static_cast<size_t>(k * ny + j)]++)] = static_cast<int32_t>(t);
    }

    const double rays = static_cast<double>(rays_per_axis);
    const double weight = 1.0 / (rays * rays);
    const double width = static_cast<double>(nx);
    std::vector<double> hits;
    for (int64_t k = 0; k < nz; ++k)
    {
        for (int64_t j = 0; j < ny; ++j)
        {
            const auto column = static_cast<size_t>(k * ny + j);
            if (starts[column] == starts[column + 1])
                continue;
            for (int64_t sk = 0; sk < rays_per_axis; ++sk)
            {
                for (int64_t sj = 0; sj < rays_per_axis; ++sj)
                {
                    const double ry = oy + (static_cast<double>(j) + (static_cast<double>(sj) + 0.5123) / rays) * cell_m;
                    const double rz = oz + (static_cast<double>(k) + (static_cast<double>(sk) + 0.5071) / rays) * cell_m;
                    hits.clear();
                    for (int32_t item = starts[column]; item < starts[column + 1]; ++item)
                    {
                        const auto t = static_cast<size_t>(items[static_cast<size_t>(item)]);
                        const double x = ray_x_hit(tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2], ry, rz);
                        if (x < miss)
                            hits.push_back(x);
                    }
                    std::sort(hits.begin(), hits.end());
                    const auto base = column * static_cast<size_t>(nx);
                    for (size_t h = 0; h + 1 < hits.size(); h += 2)
                    {
                        const double lo = Math::clamp((hits[h] - ox) / cell_m, 0.0, width);
                        const double hi = Math::clamp((hits[h + 1] - ox) / cell_m, 0.0, width);
                        for (auto i = static_cast<int64_t>(std::floor(lo)); i < nx && static_cast<double>(i) < hi; ++i)
                        {
                            float &cell = out[base + static_cast<size_t>(i)];
                            cell = static_cast<float>(
                                double{cell} + (Math::min(hi, static_cast<double>(i) + 1.0) - Math::max(lo, static_cast<double>(i))) * weight);
                        }
                    }
                }
            }
        }
    }
    return out_array;
}

} // namespace pp
