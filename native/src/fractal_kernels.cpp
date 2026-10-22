#include "fractal_kernels.hpp"

#include <cmath>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

namespace pp
{

namespace
{

using godot::real_t;
using godot::Vector3;
namespace Math = godot::Math;

const Vector3 one(1.0, 1.0, 1.0);

double fract(double x)
{
    return x - std::floor(x);
}

Vector3 fract3(const Vector3 &v)
{
    return Vector3(static_cast<real_t>(fract(v.x)), static_cast<real_t>(fract(v.y)), static_cast<real_t>(fract(v.z)));
}

Vector3 mod3(const Vector3 &v, double m)
{
    return Vector3(static_cast<real_t>(Math::fposmod(double{v.x}, m)),
                   static_cast<real_t>(Math::fposmod(double{v.y}, m)),
                   static_cast<real_t>(Math::fposmod(double{v.z}, m)));
}

double apollonian(const Vector3 &p, int64_t iterations, double scale)
{
    Vector3 z = p;
    double s = 1.0;
    for (int64_t i = 0; i < 40; ++i)
    {
        if (i >= iterations)
            break;
        z = -one + real_t{2.0} * fract3(real_t{0.5} * z + Vector3(0.5, 0.5, 0.5));
        const double r2 = Math::max(double{z.length_squared()}, 1e-9);
        const double k = scale / r2;
        z *= static_cast<real_t>(k);
        s *= k;
    }
    return 0.25 * std::abs(double{z.y}) / std::abs(s);
}

double menger(const Vector3 &p, int64_t iterations)
{
    double d = -1e10;
    double s = 1.0;
    for (int64_t i = 0; i < 10; ++i)
    {
        if (i >= iterations)
            break;
        const Vector3 a = mod3(p * static_cast<real_t>(s), 2.0) - one;
        s *= 3.0;
        const Vector3 r = (one - real_t{3.0} * a.abs()).abs();
        const double c = (Math::min(Math::max(double{r.x}, double{r.y}),
                                    Math::min(Math::max(double{r.y}, double{r.z}), Math::max(double{r.z}, double{r.x})))
                          - 1.0)
                         / s;
        d = Math::max(d, c);
    }
    return d;
}

double jos_kleinian(const Vector3 &p, int64_t iterations, double a, double b, double bx, double bz)
{
    Vector3 z = p;
    Vector3 lz = z + one;
    Vector3 llz = z - one;
    double df = 1.0;
    const double f = Math::sign(b);
    for (int64_t i = 0; i < 40; ++i)
    {
        if (i >= iterations)
            break;
        z.x = static_cast<real_t>(double{z.x} + b / a * double{z.y});
        z.x = static_cast<real_t>(Math::fposmod(double{z.x} + bx, 2.0 * bx) - bx);
        z.z = static_cast<real_t>(Math::fposmod(double{z.z} + bz, 2.0 * bz) - bz);
        z.x = static_cast<real_t>(double{z.x} - b / a * double{z.y});
        if (double{z.y} >= a * 0.5
                               + f * (2.0 * a - 1.95) / 4.0 * Math::sign(double{z.x} + b * 0.5)
                                     * (1.0 - std::exp(-(7.2 - (1.95 - a) * 15.0) * std::abs(double{z.x} + b * 0.5))))
            z = Vector3(static_cast<real_t>(-b), static_cast<real_t>(a), 0.0) - z;
        const double ir = 1.0 / Math::max(double{z.length_squared()}, 1e-12);
        z *= static_cast<real_t>(-ir);
        z.x = static_cast<real_t>(-b - double{z.x});
        z.y = static_cast<real_t>(a + double{z.y});
        df *= Math::max(1.0, ir);
        if ((z - llz).length_squared() < 1e-5)
            break;
        llz = lz;
        lz = z;
    }
    const double y = Math::min(double{z.y}, a - double{z.y});
    return Math::min(y, 0.3) / Math::max(df, 2.0);
}

} // namespace

void FractalKernels::_bind_methods()
{
    godot::ClassDB::bind_method(godot::D_METHOD("evaluate",
                                                "p",
                                                "fractal_type",
                                                "iterations",
                                                "apollonian_scale",
                                                "klein_r",
                                                "klein_i",
                                                "klein_box_x",
                                                "klein_box_z"),
                                &FractalKernels::evaluate);
}

double FractalKernels::evaluate(const Vector3 &p,
                                int64_t fractal_type,
                                int64_t iterations,
                                double apollonian_scale,
                                double klein_r,
                                double klein_i,
                                double klein_box_x,
                                double klein_box_z) const
{
    switch (fractal_type)
    {
        case 0:
            return apollonian(p, iterations, apollonian_scale);
        case 1:
            return menger(p, iterations);
        default:
            return jos_kleinian(p, iterations, klein_r, klein_i, klein_box_x, klein_box_z);
    }
}

} // namespace pp
