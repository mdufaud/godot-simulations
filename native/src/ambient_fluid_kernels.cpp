#include "ambient_fluid_kernels.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <numbers>
#include <optional>
#include <span>
#include <utility>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace pp
{

namespace
{

using godot::Dictionary;
using godot::PackedFloat64Array;
using godot::PackedVector3Array;
using godot::real_t;
using godot::Vector3;
namespace Math = godot::Math;

using Polygon = std::vector<Vector3>;

std::span<const double> view(const PackedFloat64Array &array)
{
    return {array.ptr(), static_cast<size_t>(array.size())};
}

std::span<const Vector3> view(const PackedVector3Array &array)
{
    return {array.ptr(), static_cast<size_t>(array.size())};
}

void append_unique_point(Polygon &points, const Vector3 &point)
{
    if (std::ranges::none_of(points, [&](const Vector3 &existing) { return existing.distance_squared_to(point) <= 1.0e-12; }))
        points.push_back(point);
}

void clip_triangle_below_plane(const std::array<Vector3, 3> &triangle,
                               const Vector3 &normal,
                               double plane_offset,
                               Polygon &polygon,
                               Polygon &intersections)
{
    polygon.clear();
    intersections.clear();
    for (size_t edge = 0; edge < 3; ++edge)
    {
        const Vector3 &current = triangle[edge];
        const Vector3 &next = triangle[(edge + 1) % 3];
        const double current_distance = normal.dot(current) - plane_offset;
        const double next_distance = normal.dot(next) - plane_offset;
        if (current_distance <= 0.0)
            append_unique_point(polygon, current);
        if (std::abs(current_distance) <= 1.0e-8)
            append_unique_point(intersections, current);
        if ((current_distance < 0.0 && next_distance > 0.0) || (current_distance > 0.0 && next_distance < 0.0))
        {
            const double fraction = current_distance / (current_distance - next_distance);
            const Vector3 crossing = current.lerp(next, static_cast<real_t>(fraction));
            append_unique_point(polygon, crossing);
            append_unique_point(intersections, crossing);
        }
    }
}

double polygon_area(const Polygon &polygon)
{
    if (polygon.size() < 3)
        return 0.0;
    double area = 0.0;
    for (size_t index = 1; index + 1 < polygon.size(); ++index)
        area += (polygon[index] - polygon[0]).cross(polygon[index + 1] - polygon[0]).length() * 0.5;
    return area;
}

Vector3 polygon_area_centroid(const Polygon &polygon)
{
    if (polygon.size() < 3)
        return Vector3();
    double area = 0.0;
    Vector3 weighted_centroid;
    for (size_t index = 1; index + 1 < polygon.size(); ++index)
    {
        const Vector3 &a = polygon[0];
        const Vector3 &b = polygon[index];
        const Vector3 &c = polygon[index + 1];
        const double triangle_area = (b - a).cross(c - a).length() * 0.5;
        area += triangle_area;
        weighted_centroid += (a + b + c) * static_cast<real_t>(triangle_area / 3.0);
    }
    return area > 1.0e-12 ? weighted_centroid / static_cast<real_t>(area) : Vector3();
}

double mesh_signed_volume(std::span<const Vector3> vertices, const Vector3 &interior_point)
{
    double signed_volume = 0.0;
    for (size_t base = 0; base < vertices.size(); base += 3)
    {
        const Vector3 &a = vertices[base];
        Vector3 b = vertices[base + 1];
        Vector3 c = vertices[base + 2];
        if ((b - a).cross(c - a).dot((a + b + c) / 3.0 - interior_point) < 0.0)
            std::swap(b, c);
        signed_volume += (a - interior_point).dot((b - interior_point).cross(c - interior_point)) / 6.0;
    }
    return std::abs(signed_volume);
}

PackedVector3Array to_packed(const Polygon &points)
{
    PackedVector3Array out;
    out.resize(static_cast<int64_t>(points.size()));
    std::ranges::copy(points, out.ptrw());
    return out;
}

Dictionary clip_result(double volume_m3,
                       const Vector3 &centroid_m,
                       const PackedFloat64Array &wet_area_fractions,
                       const PackedVector3Array &wet_area_centers_m,
                       double wetted_area_fraction,
                       const PackedVector3Array &waterline_points)
{
    Dictionary out;
    out[godot::StringName("volume_m3")] = volume_m3;
    out[godot::StringName("centroid_m")] = centroid_m;
    out[godot::StringName("wet_area_fractions")] = wet_area_fractions;
    out[godot::StringName("wet_area_centers_m")] = wet_area_centers_m;
    out[godot::StringName("wetted_area_fraction")] = wetted_area_fraction;
    out[godot::StringName("waterline_points")] = waterline_points;
    return out;
}

void accumulate_wrench(std::span<double> wrench, const Vector3 &torque, const Vector3 &force)
{
    wrench[0] += torque.x;
    wrench[1] += torque.y;
    wrench[2] += torque.z;
    wrench[3] += force.x;
    wrench[4] += force.y;
    wrench[5] += force.z;
}

Dictionary surface_result(const PackedFloat64Array &pressure,
                          const PackedFloat64Array &friction,
                          int64_t attached_faces)
{
    Dictionary out;
    out[godot::StringName("pressure")] = pressure;
    out[godot::StringName("friction")] = friction;
    out[godot::StringName("attached_faces")] = attached_faces;
    return out;
}

} // namespace

void AmbientFluidKernels::_bind_methods()
{
    godot::ClassDB::bind_method(godot::D_METHOD("matrix_vector_multiply", "matrix", "vector"),
                                &AmbientFluidKernels::matrix_vector_multiply);
    godot::ClassDB::bind_method(godot::D_METHOD("matrix_inverse", "matrix", "size", "pivot_epsilon"),
                                &AmbientFluidKernels::matrix_inverse);
    godot::ClassDB::bind_method(godot::D_METHOD("clip_convex_mesh_below_plane",
                                                "triangle_vertices",
                                                "interior_point",
                                                "plane_normal",
                                                "plane_offset"),
                                &AmbientFluidKernels::clip_convex_mesh_below_plane);
    godot::ClassDB::bind_method(godot::D_METHOD("surface_wrench",
                                                "face_centers_m",
                                                "face_normals",
                                                "face_areas_m2",
                                                "generalized_velocity",
                                                "fluid_density_kg_m3",
                                                "dynamic_viscosity_pa_s",
                                                "separation_angle_rad",
                                                "characteristic_length_m",
                                                "wet_area_fractions",
                                                "wet_area_centers_m"),
                                &AmbientFluidKernels::surface_wrench);
}

PackedFloat64Array AmbientFluidKernels::matrix_vector_multiply(const PackedFloat64Array &matrix,
                                                               const PackedFloat64Array &vector) const
{
    const std::span<const double> m = view(matrix);
    const std::span<const double> v = view(vector);
    const size_t size = v.size();
    // Bound directly to ClassDB: a caller that skips the GDScript wrapper must not
    // be able to read past the matrix.
    if (m.size() != size * size)
        return {};
    PackedFloat64Array result_out;
    result_out.resize(vector.size());
    double *result = result_out.ptrw();
    for (size_t row = 0; row < size; ++row)
    {
        double value = 0.0;
        for (size_t col = 0; col < size; ++col)
            value += m[row * size + col] * v[col];
        result[row] = value;
    }
    return result_out;
}

PackedFloat64Array AmbientFluidKernels::matrix_inverse(const PackedFloat64Array &matrix,
                                                       int64_t size,
                                                       double pivot_epsilon) const
{
    const std::span<const double> m = view(matrix);
    if (size < 0 || m.size() != static_cast<size_t>(size) * static_cast<size_t>(size))
        return {};
    const auto n = static_cast<size_t>(size);
    const size_t width = n * 2;
    // Pivot threshold relative to the largest entry, as AmbientFluidMath does.
    double scale = 0.0;
    for (const double value : m)
    {
        const double magnitude = std::abs(value);
        if (std::isnan(magnitude))
        {
            scale = magnitude;
            break;
        }
        scale = std::max(scale, magnitude);
    }
    const double threshold = pivot_epsilon * scale;
    std::vector<double> augmented(n * width);
    for (size_t row = 0; row < n; ++row)
    {
        for (size_t col = 0; col < n; ++col)
        {
            augmented[row * width + col] = m[row * n + col];
            augmented[row * width + n + col] = row == col ? 1.0 : 0.0;
        }
    }

    for (size_t pivot = 0; pivot < n; ++pivot)
    {
        size_t pivot_row = pivot;
        double pivot_abs = std::abs(augmented[pivot * width + pivot]);
        for (size_t row = pivot + 1; row < n; ++row)
        {
            const double candidate = std::abs(augmented[row * width + pivot]);
            if (candidate > pivot_abs)
            {
                pivot_abs = candidate;
                pivot_row = row;
            }
        }
        if (!(pivot_abs > threshold))
            return {};
        if (pivot_row != pivot)
            std::swap_ranges(augmented.begin() + static_cast<std::ptrdiff_t>(pivot * width),
                             augmented.begin() + static_cast<std::ptrdiff_t>((pivot + 1) * width),
                             augmented.begin() + static_cast<std::ptrdiff_t>(pivot_row * width));

        const double pivot_value = augmented[pivot * width + pivot];
        for (size_t col = 0; col < width; ++col)
            augmented[pivot * width + col] /= pivot_value;
        for (size_t row = 0; row < n; ++row)
        {
            if (row == pivot)
                continue;
            const double factor = augmented[row * width + pivot];
            if (factor == 0.0)
                continue;
            for (size_t col = 0; col < width; ++col)
                augmented[row * width + col] -= factor * augmented[pivot * width + col];
        }
    }

    PackedFloat64Array result_out;
    result_out.resize(static_cast<int64_t>(n * n));
    double *result = result_out.ptrw();
    for (size_t row = 0; row < n; ++row)
        for (size_t col = 0; col < n; ++col)
            result[row * n + col] = augmented[row * width + n + col];
    return result_out;
}

Dictionary AmbientFluidKernels::clip_convex_mesh_below_plane(const PackedVector3Array &triangle_vertices,
                                                             const Vector3 &interior_point,
                                                             const Vector3 &plane_normal,
                                                             double plane_offset) const
{
    const std::span<const Vector3> vertices = view(triangle_vertices);
    const Vector3 normal = plane_normal.normalized();
    double minimum_distance = std::numeric_limits<double>::infinity();
    double maximum_distance = -std::numeric_limits<double>::infinity();
    for (const Vector3 &vertex : vertices)
    {
        const double distance = normal.dot(vertex) - plane_offset;
        minimum_distance = Math::min(minimum_distance, distance);
        maximum_distance = Math::max(maximum_distance, distance);
    }
    const size_t face_count = vertices.size() / 3;
    PackedFloat64Array wet_fractions_out;
    wet_fractions_out.resize(static_cast<int64_t>(face_count));
    PackedVector3Array wet_centers_out;
    wet_centers_out.resize(static_cast<int64_t>(face_count));
    const std::span<double> wet_fractions(wet_fractions_out.ptrw(), face_count);
    const std::span<Vector3> wet_centers(wet_centers_out.ptrw(), face_count);
    for (size_t face = 0; face < face_count; ++face)
    {
        const size_t base = face * 3;
        wet_centers[face] = (vertices[base] + vertices[base + 1] + vertices[base + 2]) / 3.0;
    }
    if (maximum_distance <= 1.0e-8)
    {
        wet_fractions_out.fill(1.0);
        return clip_result(mesh_signed_volume(vertices, interior_point),
                           interior_point,
                           wet_fractions_out,
                           wet_centers_out,
                           1.0,
                           PackedVector3Array());
    }
    if (minimum_distance >= -1.0e-8)
        return clip_result(0.0, interior_point, wet_fractions_out, wet_centers_out, 0.0, PackedVector3Array());

    std::vector<Polygon> clipped_surfaces;
    Polygon waterline;
    double total_surface_area = 0.0;
    double wetted_surface_area = 0.0;
    Polygon polygon;
    Polygon intersections;
    for (size_t face = 0; face < face_count; ++face)
    {
        const size_t base = face * 3;
        const Vector3 &a = vertices[base];
        Vector3 b = vertices[base + 1];
        Vector3 c = vertices[base + 2];
        if ((b - a).cross(c - a).dot((a + b + c) / 3.0 - interior_point) < 0.0)
            std::swap(b, c);
        const double original_area = (b - a).cross(c - a).length() * 0.5;
        total_surface_area += original_area;
        clip_triangle_below_plane({a, b, c}, normal, plane_offset, polygon, intersections);
        if (polygon.size() >= 3)
        {
            clipped_surfaces.push_back(polygon);
            const double clipped_area = polygon_area(polygon);
            wet_fractions[face] = Math::clamp(clipped_area / original_area, 0.0, 1.0);
            wet_centers[face] = polygon_area_centroid(polygon);
            wetted_surface_area += clipped_area;
        }
        for (const Vector3 &point : intersections)
            append_unique_point(waterline, point);
    }

    std::optional<size_t> cap_surface_index;
    if (waterline.size() >= 3)
    {
        Vector3 cap_center;
        for (const Vector3 &point : waterline)
            cap_center += point;
        cap_center /= static_cast<real_t>(waterline.size());
        const Vector3 up(0.0, 1.0, 0.0);
        const Vector3 reference_axis = std::abs(double{normal.dot(up)}) < 0.9 ? up : Vector3(1.0, 0.0, 0.0);
        const Vector3 tangent_x = normal.cross(reference_axis).normalized();
        const Vector3 tangent_y = normal.cross(tangent_x).normalized();
        std::ranges::stable_sort(waterline, [&](const Vector3 &left, const Vector3 &right) {
            const Vector3 left_delta = left - cap_center;
            const Vector3 right_delta = right - cap_center;
            return std::atan2(double{left_delta.dot(tangent_y)}, double{left_delta.dot(tangent_x)})
                   < std::atan2(double{right_delta.dot(tangent_y)}, double{right_delta.dot(tangent_x)});
        });
        cap_surface_index = clipped_surfaces.size();
        clipped_surfaces.push_back(waterline);
    }

    double signed_volume = 0.0;
    Vector3 weighted_centroid;
    for (size_t surface_index = 0; surface_index < clipped_surfaces.size(); ++surface_index)
    {
        const Polygon &surface = clipped_surfaces[surface_index];
        for (size_t triangle_index = 1; triangle_index + 1 < surface.size(); ++triangle_index)
        {
            const Vector3 &a = surface[0];
            Vector3 b = surface[triangle_index];
            Vector3 c = surface[triangle_index + 1];
            if (surface_index == cap_surface_index && (b - a).cross(c - a).dot(normal) < 0.0)
                std::swap(b, c);
            const double tetra_volume = a.dot(b.cross(c)) / 6.0;
            signed_volume += tetra_volume;
            weighted_centroid += (a + b + c) * static_cast<real_t>(tetra_volume * 0.25);
        }
    }
    Vector3 centroid = interior_point;
    if (std::abs(signed_volume) > 1.0e-12)
        centroid = weighted_centroid / static_cast<real_t>(signed_volume);
    return clip_result(std::abs(signed_volume),
                       centroid,
                       wet_fractions_out,
                       wet_centers_out,
                       total_surface_area > 1.0e-12 ? wetted_surface_area / total_surface_area : 0.0,
                       to_packed(waterline));
}

Dictionary AmbientFluidKernels::surface_wrench(const PackedVector3Array &face_centers_m,
                                               const PackedVector3Array &face_normals,
                                               const PackedFloat64Array &face_areas_m2,
                                               const PackedFloat64Array &generalized_velocity,
                                               double fluid_density_kg_m3,
                                               double dynamic_viscosity_pa_s,
                                               double separation_angle_rad,
                                               double characteristic_length_m,
                                               const PackedFloat64Array &wet_area_fractions,
                                               const PackedVector3Array &wet_area_centers_m) const
{
    constexpr int64_t wrench_size = 6;
    PackedFloat64Array pressure_out;
    pressure_out.resize(wrench_size);
    PackedFloat64Array friction_out;
    friction_out.resize(wrench_size);
    const int64_t face_count = face_centers_m.size();
    // Bound straight to ClassDB, so mismatched sizes must not read past a buffer.
    if (generalized_velocity.size() != wrench_size || face_normals.size() != face_count
        || face_areas_m2.size() != face_count
        || (!wet_area_fractions.is_empty() && wet_area_fractions.size() != face_count)
        || (!wet_area_centers_m.is_empty() && wet_area_centers_m.size() != face_count))
        return surface_result(pressure_out, friction_out, 0);
    const std::span<const double> velocity = view(generalized_velocity);
    const std::span<double> pressure(pressure_out.ptrw(), wrench_size);
    const std::span<double> friction(friction_out.ptrw(), wrench_size);

    const double cos_separation
        = std::cos(Math::clamp(separation_angle_rad, std::numbers::pi * 0.5, std::numbers::pi));
    // 1/2 C_f rho |u_s| = blasius * |u_s|^(4/5) (Eq. 19, 22); stokes = 3 mu / 2R, R = L / (2 sqrt(pi)).
    double blasius = 0.0;
    double stokes = 0.0;
    if (dynamic_viscosity_pa_s > 0.0 && characteristic_length_m > 0.0)
    {
        blasius = 0.0288 * fluid_density_kg_m3
                  * std::pow(fluid_density_kg_m3 * characteristic_length_m / dynamic_viscosity_pa_s, -0.2);
        stokes = 3.0 * std::sqrt(std::numbers::pi) * dynamic_viscosity_pa_s / characteristic_length_m;
    }
    const Vector3 angular_velocity(static_cast<real_t>(velocity[0]),
                                   static_cast<real_t>(velocity[1]),
                                   static_cast<real_t>(velocity[2]));
    const Vector3 linear_velocity(static_cast<real_t>(velocity[3]),
                                  static_cast<real_t>(velocity[4]),
                                  static_cast<real_t>(velocity[5]));

    const std::span<const Vector3> face_centers = view(face_centers_m);
    const std::span<const Vector3> normals = view(face_normals);
    const std::span<const double> face_areas = view(face_areas_m2);
    const std::span<const double> wet_fractions = view(wet_area_fractions);
    const std::span<const Vector3> wet_centers = view(wet_area_centers_m);
    int64_t attached_faces = 0;
    for (size_t face_index = 0; face_index < face_centers.size(); ++face_index)
    {
        const Vector3 &center = wet_centers.empty() ? face_centers[face_index] : wet_centers[face_index];
        const Vector3 &normal = normals[face_index];
        const double wet_fraction = wet_fractions.empty() ? 1.0 : Math::clamp(wet_fractions[face_index], 0.0, 1.0);
        const double area = face_areas[face_index] * wet_fraction;
        if (area <= 1.0e-12)
            continue;
        const Vector3 turning = angular_velocity.cross(center);
        if (stokes > 0.0)
        {
            // Stokes traction extension: -k zdot A, plus the torque of -k (w x c) A.
            const Vector3 stokes_drag = static_cast<real_t>(-stokes * area) * (linear_velocity + turning);
            const Vector3 stokes_spin = static_cast<real_t>(-stokes * area) * turning;
            accumulate_wrench(friction, center.cross(stokes_drag + stokes_spin), stokes_drag);
        }
        // Eq. 16-17: the face moves at zdot; attached where <n, zdot/|zdot|> > cos(alpha).
        const Vector3 surface_velocity = linear_velocity + turning;
        const double speed = surface_velocity.length();
        if (speed <= 1.0e-12 || normal.dot(surface_velocity) <= cos_separation * speed)
            continue;
        ++attached_faces;
        const Vector3 slip = normal * normal.dot(surface_velocity) - surface_velocity;
        const double slip_squared = slip.length_squared();
        // Eq. 20: f = -1/2 rho |u_s|^2 A n.
        const Vector3 pressure_force
            = static_cast<real_t>(-0.5 * fluid_density_kg_m3 * slip_squared * area) * normal;
        accumulate_wrench(pressure, center.cross(pressure_force), pressure_force);
        if (blasius > 0.0 && slip_squared > 0.0)
        {
            // Eq. 22 with the dissipative sign: f = +1/2 C_f rho |u_s| A u_s.
            const Vector3 friction_force
                = static_cast<real_t>(blasius * std::pow(slip_squared, 0.4) * area) * slip;
            accumulate_wrench(friction, center.cross(friction_force), friction_force);
        }
    }
    return surface_result(pressure_out, friction_out, attached_faces);
}

} // namespace pp
