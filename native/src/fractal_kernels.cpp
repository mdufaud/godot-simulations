#include "fractal_kernels.hpp"

#include <cmath>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

namespace pp
{

namespace
{

namespace Math = godot::Math;

constexpr int64_t apollonian_max_iterations = 64;
constexpr int64_t menger_max_iterations = 26;
constexpr int64_t klein_max_iterations = 64;
constexpr double cycle_epsilon2 = 1e-10;
constexpr double splitter = 134217729.0;
constexpr double orbit_escape2 = 1.0e10;
constexpr int64_t step_burning_ship = 2;
constexpr int64_t step_tricorn = 3;

double fract(double x)
{
    return x - std::floor(x);
}

double apollonian(double x, double y, double z, int64_t iterations, int64_t detail_iterations, double scale)
{
    double s = 1.0;
    double x1 = x + 1.0;
    double y1 = y + 1.0;
    double z1 = z + 1.0;
    double x2 = x - 1.0;
    double y2 = y - 1.0;
    double z2 = z - 1.0;
    const int64_t total = Math::min(iterations + detail_iterations, apollonian_max_iterations);

    for (int64_t i = 0; i < total; ++i)
    {
        if (i >= iterations && ((i - iterations) & 1) == 0)
        {
            const double dx = x - x2;
            const double dy = y - y2;
            const double dz = z - z2;
            if (dx * dx + dy * dy + dz * dz < cycle_epsilon2)
                break;
        }
        x2 = x1;
        y2 = y1;
        z2 = z1;
        x1 = x;
        y1 = y;
        z1 = z;
        x = -1.0 + 2.0 * fract(0.5 * x + 0.5);
        y = -1.0 + 2.0 * fract(0.5 * y + 0.5);
        z = -1.0 + 2.0 * fract(0.5 * z + 0.5);
        const double r2 = Math::max(x * x + y * y + z * z, 1e-9);
        const double k = scale / r2;
        x *= k;
        y *= k;
        z *= k;
        s *= k;
    }
    return 0.25 * std::abs(y) / std::abs(s);
}

double menger(double x, double y, double z, int64_t iterations)
{
    double d = -1e10;
    double s = 1.0;
    const int64_t total = Math::min(iterations, menger_max_iterations);

    for (int64_t i = 0; i < total; ++i)
    {
        const double ax = Math::fposmod(x * s, 2.0) - 1.0;
        const double ay = Math::fposmod(y * s, 2.0) - 1.0;
        const double az = Math::fposmod(z * s, 2.0) - 1.0;
        s *= 3.0;
        const double rx = std::abs(1.0 - 3.0 * std::abs(ax));
        const double ry = std::abs(1.0 - 3.0 * std::abs(ay));
        const double rz = std::abs(1.0 - 3.0 * std::abs(az));
        const double c = (Math::min(Math::max(rx, ry), Math::min(Math::max(ry, rz), Math::max(rz, rx))) - 1.0) / s;
        d = Math::max(d, c);
    }
    return d;
}

double jos_kleinian(double x, double y, double z, int64_t iterations, double a, double b, double bx, double bz)
{
    double lx = x + 1.0;
    double ly = y + 1.0;
    double lz = z + 1.0;
    double llx = x - 1.0;
    double lly = y - 1.0;
    double llz = z - 1.0;
    double df = 1.0;
    const double f = Math::sign(b);
    const int64_t total = Math::min(iterations, klein_max_iterations);

    for (int64_t i = 0; i < total; ++i)
    {
        x += b / a * y;
        x = Math::fposmod(x + bx, 2.0 * bx) - bx;
        z = Math::fposmod(z + bz, 2.0 * bz) - bz;
        x -= b / a * y;
        if (y >= a * 0.5
                     + f * (2.0 * a - 1.95) / 4.0 * Math::sign(x + b * 0.5)
                           * (1.0 - std::exp(-(7.2 - (1.95 - a) * 15.0) * std::abs(x + b * 0.5))))
        {
            x = -b - x;
            y = a - y;
            z = -z;
        }
        const double ir = 1.0 / Math::max(x * x + y * y + z * z, 1e-12);
        x *= -ir;
        y *= -ir;
        z *= -ir;
        x = -b - x;
        y = a + y;
        df *= Math::max(1.0, ir);
        const double ex = x - llx;
        const double ey = y - lly;
        const double ez = z - llz;
        if (ex * ex + ey * ey + ez * ez < 1e-5)
            break;
        llx = lx;
        lly = ly;
        llz = lz;
        lx = x;
        ly = y;
        lz = z;
    }
    const double top = Math::min(y, a - y);
    return Math::min(top, 0.3) / Math::max(df, 2.0);
}

} // namespace

void FractalKernels::_bind_methods()
{
    godot::ClassDB::bind_method(godot::D_METHOD("evaluate_at",
                                                "x",
                                                "y",
                                                "z",
                                                "fractal_type",
                                                "iterations",
                                                "detail_iterations",
                                                "apollonian_scale",
                                                "klein_r",
                                                "klein_i",
                                                "klein_box_x",
                                                "klein_box_z"),
                                &FractalKernels::evaluate_at);
    godot::ClassDB::bind_method(godot::D_METHOD("orbit", "step", "z0", "c", "count"), &FractalKernels::orbit);
}

double FractalKernels::evaluate_at(double x,
                                   double y,
                                   double z,
                                   int64_t fractal_type,
                                   int64_t iterations,
                                   int64_t detail_iterations,
                                   double apollonian_scale,
                                   double klein_r,
                                   double klein_i,
                                   double klein_box_x,
                                   double klein_box_z) const
{
    switch (fractal_type)
    {
        case 0:
            return apollonian(x, y, z, iterations, detail_iterations, apollonian_scale);
        case 1:
            return menger(x, y, z, iterations + detail_iterations);
        default:
            return jos_kleinian(x,
                                y,
                                z,
                                iterations + detail_iterations,
                                klein_r,
                                klein_i,
                                klein_box_x,
                                klein_box_z);
    }
}

godot::PackedFloat32Array FractalKernels::orbit(int64_t step,
                                                const godot::PackedFloat64Array &z0,
                                                const godot::PackedFloat64Array &c,
                                                int64_t count) const
{
    godot::PackedFloat32Array points;
    if (z0.size() < 4 || c.size() < 4 || count <= 0)
        return points;
    points.resize(count * 2);
    float *out = points.ptrw();
    double x = z0[0];
    double xl = z0[1];
    double y = z0[2];
    double yl = z0[3];
    const double cx = c[0];
    const double cxl = c[1];
    const double cy = c[2];
    const double cyl = c[3];
    int64_t used = 0;
    for (int64_t i = 0; i < count; ++i)
    {
        out[i * 2] = static_cast<float>(x);
        out[i * 2 + 1] = static_cast<float>(y);
        used = i + 1;
        if (x * x + y * y > orbit_escape2)
            break;
        if (step == step_burning_ship)
        {
            if (x < 0.0)
            {
                x = -x;
                xl = -xl;
            }
            if (y < 0.0)
            {
                y = -y;
                yl = -yl;
            }
        }

        double t = splitter * x;
        const double xh = t - (t - x);
        const double xt = x - xh;
        t = splitter * y;
        const double yh = t - (t - y);
        const double yt = y - yh;

        const double xx = x * x;
        double xx_lo = ((xh * xh - xx) + 2.0 * xh * xt) + xt * xt;
        xx_lo += 2.0 * x * xl;
        const double yy = y * y;
        double yy_lo = ((yh * yh - yy) + 2.0 * yh * yt) + yt * yt;
        yy_lo += 2.0 * y * yl;
        const double xy = x * y;
        double xy_lo = ((xh * yh - xy) + xh * yt + xt * yh) + xt * yt;
        xy_lo += x * yl + xl * y;

        double s = xx - yy;
        double bb = s - xx;
        double e = (xx - (s - bb)) + (-yy - bb);
        e += xx_lo - yy_lo;
        const double re = s + e;
        const double re_lo = e - (re - s);
        s = re + cx;
        bb = s - re;
        e = (re - (s - bb)) + (cx - bb);
        e += re_lo + cxl;
        const double nx = s + e;
        const double nxl = e - (nx - s);

        double im = 2.0 * xy;
        double im_lo = 2.0 * xy_lo;
        if (step == step_tricorn)
        {
            im = -im;
            im_lo = -im_lo;
        }
        s = im + cy;
        bb = s - im;
        e = (im - (s - bb)) + (cy - bb);
        e += im_lo + cyl;
        const double ny = s + e;
        const double nyl = e - (ny - s);

        x = nx;
        xl = nxl;
        y = ny;
        yl = nyl;
    }
    points.resize(used * 2);
    return points;
}

} // namespace pp
