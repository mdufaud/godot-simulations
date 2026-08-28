#!/usr/bin/env python3
"""Fix plan 0.4: horizon silhouette and value-band metrics for ocean captures.

Reusable PIL script — run it on any capture to decide P0-C acceptance:
  - silhouette std (per-column water/sky boundary) — target >= 8 px swell,
    >= 20 px storm at 1280 px wide;
  - luma of the horizon band vs near water vs sky — target luma(far) >= luma(near),
    i.e. no dark band inversion.

  python3 tools/ocean_horizon_metrics.py out.png [more.png ...]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

LUMA = (0.2126, 0.7152, 0.0722)


def horizon_metrics(path: Path) -> str:
    img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    luma = img @ LUMA
    height, width = luma.shape
    search_top, search_bottom = int(height * 0.2), int(height * 0.9)
    kernel = np.ones(7) / 7.0

    horizon_rows: list[float] = []
    for x in range(0, width, 2):
        column = luma[:, x]
        gradient = np.abs(np.diff(column[search_top:search_bottom]))
        smoothed = np.convolve(gradient, kernel, mode="same")
        horizon_rows.append(search_top + int(np.argmax(smoothed)))
    horizon = np.array(horizon_rows, dtype=np.float64)
    std_px = float(horizon.std())
    p5, p95 = (float(value) for value in np.percentile(horizon, (5, 95)))

    horizon_mean = float(horizon.mean())
    sky_band = luma[: max(int(horizon_mean - height * 0.10), 1), :]
    far_band = luma[int(horizon_mean + height * 0.01): int(horizon_mean + height * 0.12), :]
    near_band = luma[int(height * 0.80):, :]
    sky_luma = float(sky_band.mean())
    far_luma = float(far_band.mean())
    near_luma = float(near_band.mean())
    inversion = "yes" if far_luma < near_luma else "no"
    return (
        f"HORIZON METRICS file={path.name} "
        f"silhouette_std_px={std_px:.2f} silhouette_p5_p95_px={p95 - p5:.1f} "
        f"sky_luma={sky_luma:.4f} far_luma={far_luma:.4f} near_luma={near_luma:.4f} "
        f"dark_band_inversion={inversion}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.images:
        print(horizon_metrics(path))


if __name__ == "__main__":
    main()
