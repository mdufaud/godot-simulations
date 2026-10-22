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

Dictionary pressure_result(const PackedFloat64Array &pressure, int64_t attached_faces)
{
    Dictionary out;
    out[godot::StringName("pressure")] = pressure;
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
    godot::ClassDB::bind_method(godot::D_METHOD("potential_pressure_wrench",
                                                "face_centers_m",
                                                "face_normals",
                                                "face_areas_m2",
                                                "slip_matrix",
                                                "generalized_velocity",
                                                "fluid_density_kg_m3",
                                                "separation_angle_rad",
                                                "wet_area_fractions",
                                                "wet_area_centers_m"),
                                &AmbientFluidKernels::potential_pressure_wrench);
}

PackedFloat64Array AmbientFluidKernels::matrix_vector_multiply(const PackedFloat64Array &matrix,
                                                               const PackedFloat64Array &vector) const
{
    const std::span<const double> m = view(matrix);
    const std::span<const double> v = view(vector);
    const size_t size = v.size();
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
    const auto n = static_cast<size_t>(size);
    const size_t width = n * 2;
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
        if (pivot_abs <= pivot_epsilon)
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
            if (Math::is_zero_approx(factor))
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

Dictionary AmbientFluidKernels::potential_pressure_wrench(const PackedVector3Array &face_centers_m,
                                                          const PackedVector3Array &face_normals,
                                                          const PackedFloat64Array &face_areas_m2,
                                                          const PackedFloat64Array &slip_matrix,
                                                          const PackedFloat64Array &generalized_velocity,
                                                          double fluid_density_kg_m3,
                                                          double separation_angle_rad,
                                                          const PackedFloat64Array &wet_area_fractions,
                                                          const PackedVector3Array &wet_area_centers_m) const
{
    const std::span<const double> velocity = view(generalized_velocity);
    const size_t matrix_size = velocity.size();
    PackedFloat64Array pressure_out;
    pressure_out.resize(generalized_velocity.size());
    const std::span<double> pressure(pressure_out.ptrw(), matrix_size);

    const double cos_separation
        = std::cos(Math::clamp(separation_angle_rad, std::numbers::pi * 0.5, std::numbers::pi));
    const Vector3 body_relative_velocity(static_cast<real_t>(velocity[3]),
                                         static_cast<real_t>(velocity[4]),
                                         static_cast<real_t>(velocity[5]));
    const double body_speed_squared = body_relative_velocity.length_squared();
    if (body_speed_squared <= 1.0e-16)
        return pressure_result(pressure_out, 0);
    const Vector3 incoming_flow_direction = -body_relative_velocity.normalized();
    const Vector3 angular_velocity(static_cast<real_t>(velocity[0]),
                                   static_cast<real_t>(velocity[1]),
                                   static_cast<real_t>(velocity[2]));

    const std::span<const Vector3> face_centers = view(face_centers_m);
    const std::span<const Vector3> normals = view(face_normals);
    const std::span<const double> face_areas = view(face_areas_m2);
    const std::span<const double> slip_rows = view(slip_matrix);
    const std::span<const double> wet_fractions = view(wet_area_fractions);
    const std::span<const Vector3> wet_centers = view(wet_area_centers_m);
    int64_t attached_faces = 0;
    for (size_t face_index = 0; face_index < face_centers.size(); ++face_index)
    {
        const Vector3 &face_center = face_centers[face_index];
        const Vector3 &center = wet_centers.empty() ? face_center : wet_centers[face_index];
        const Vector3 &normal = normals[face_index];
        const double wet_fraction = wet_fractions.empty() ? 1.0 : Math::clamp(wet_fractions[face_index], 0.0, 1.0);
        const double area = face_areas[face_index] * wet_fraction;
        if (area <= 1.0e-12)
            continue;
        const bool attached = normal.dot(incoming_flow_direction) >= cos_separation;
        if (attached)
            ++attached_faces;
        Vector3 slip;
        const size_t base = face_index * 3 * matrix_size;
        for (int row = 0; row < 3; ++row)
        {
            double value = 0.0;
            for (size_t col = 0; col < matrix_size; ++col)
                value += slip_rows[base + static_cast<size_t>(row) * matrix_size + col] * velocity[col];
            slip[row] = static_cast<real_t>(value);
        }
        const Vector3 center_delta = center - face_center;
        if (center_delta.length_squared() > 1.0e-16)
        {
            const Vector3 tangent_delta = angular_velocity.cross(center_delta);
            slip -= tangent_delta - normal * normal.dot(tangent_delta);
        }
        const double slip_speed = slip.length();
        if (attached)
        {
            const double pressure_delta = 0.5 * fluid_density_kg_m3 * (body_speed_squared - slip_speed * slip_speed);
            const Vector3 pressure_force = static_cast<real_t>(-pressure_delta * area) * normal;
            accumulate_wrench(pressure, center.cross(pressure_force), pressure_force);
        }
    }
    return pressure_result(pressure_out, attached_faces);
}

} // namespace pp
