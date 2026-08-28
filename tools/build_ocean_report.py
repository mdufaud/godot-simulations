#!/usr/bin/env python3
"""Build reproducible annotated comparison boards without modifying source PNGs."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageStat


PAIRS = {
    "swell_day": ("swell_day.png", "sot_swell_low_water_only.png"),
    "swell_sun": ("swell_sun.png", "sot_swell_sun_path.png"),
    "storm_overcast": ("storm_overcast.png", "sot_storm_dark_water_only.png"),
    "storm_backlight": ("storm_backlight.png", "sot_storm_low.png"),
}


def font(size: int):
    try:
        return ImageFont.truetype("DejaVuSans.ttf", size)
    except OSError:
        return ImageFont.load_default()


def metrics(image: Image.Image) -> tuple[float, float, float]:
    crop = image.crop((0, image.height // 3, image.width, image.height))
    rgb = crop.convert("RGB")
    stat = ImageStat.Stat(rgb)
    luma = sum(channel * weight for channel, weight in zip(stat.mean, (0.2126, 0.7152, 0.0722))) / 255.0
    saturation = sum(max(pixel) - min(pixel) for pixel in rgb.getdata()) / (3.0 * 255.0 * crop.width * crop.height)
    contrast = sum(stat.stddev) / (3.0 * 255.0)
    return luma, saturation, contrast


def board(name: str, capture: Image.Image, reference: Image.Image, output: Path) -> None:
    capture = capture.convert("RGB")
    reference = reference.convert("RGB")
    width = max(capture.width, reference.width)
    height = max(capture.height, reference.height)
    header = 58
    canvas = Image.new("RGB", (width * 2, height + header), (18, 22, 24))
    canvas.paste(reference.resize((width, height)), (0, header))
    canvas.paste(capture.resize((width, height)), (width, header))
    draw = ImageDraw.Draw(canvas)
    title = font(max(16, width // 70))
    draw.text((18, 16), "1  Sea of Thieves reference", fill=(235, 235, 228), font=title)
    draw.text((width + 18, 16), "2  Current OceanSolver capture", fill=(235, 235, 228), font=title)
    points = ((0.18, 0.72), (0.52, 0.58), (0.78, 0.31))
    for number, (x, y) in enumerate(points, 3):
        cx = int((width if number == 4 else 0) + x * width)
        cy = header + int(y * height)
        draw.ellipse((cx - 15, cy - 15, cx + 15, cy + 15), fill=(224, 174, 46), outline=(20, 20, 20), width=2)
        draw.text((cx - 5, cy - 11), str(number), fill=(20, 20, 20), font=font(18))
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, "PNG")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("campaign", type=Path)
    parser.add_argument("phase", nargs="?", default="final")
    parser.add_argument("--references", type=Path, default=Path("docs/images/reference/paired"))
    args = parser.parse_args()
    phase = args.campaign / args.phase
    pairs = phase / "pairs"
    annotated = phase / "annotated"
    rows = ["pair\tref_luma\tref_saturation\tref_contrast\tcapture_luma\tcapture_saturation\tcapture_contrast"]
    for name, (capture_name, reference_name) in PAIRS.items():
        capture_path = pairs / capture_name
        reference_path = args.references / reference_name
        if not capture_path.is_file() or not reference_path.is_file():
            raise SystemExit(f"missing pair input: {capture_path} or {reference_path}")
        capture = Image.open(capture_path)
        reference = Image.open(reference_path)
        board(name, capture, reference, annotated / f"{name}.png")
        ref_values = metrics(reference)
        capture_values = metrics(capture)
        rows.append(name + "\t" + "\t".join(f"{value:.6f}" for value in ref_values + capture_values))
    (phase / "metrics.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
