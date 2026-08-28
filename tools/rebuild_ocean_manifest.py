#!/usr/bin/env python3
"""Rebuild the campaign manifest from captured PNG names and fixed protocol values."""

from pathlib import Path
import argparse


STATES = {"calm": (0, 0, 1), "breeze": (1, 0, 1), "swell": (2, 0, 1), "storm": (3, 1, 2)}
VIEWS = ("overhead", "low_crest", "horizon")
CONTROLS = ("no_foam", "no_micro", "no_reflection", "geometry", "normals", "crest", "breaking", "foam_fresh", "foam_persistent")
PAIRS = (("swell", 2, 0, 1, "low_crest", 34.0, 160.0), ("swell", 2, 0, 0, "sun", 8.0, 180.0), ("storm", 3, 1, 2, "low_crest", 9.0, 180.0), ("storm", 3, 1, 0, "low_crest", 8.0, 180.0))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("campaign", type=Path)
    args = parser.parse_args()
    rows = ["phase\tstate\tpreset\tmood\tlook\tview\ttime\tdt\twind_direction\tsun_elevation\tsun_azimuth"]
    for phase in ("baseline", "final"):
        root = args.campaign / phase
        for state, (preset, mood, default_look) in STATES.items():
            look = default_look
            for view in VIEWS:
                if (root / "full" / f"{state}_{view}.png").is_file():
                    rows.append(f"{phase}\t{state}\t{preset}\t{mood}\t{look}\t{view}\t20.0\t0.016666667\t0.0\t34.0\t160.0")
            for control in CONTROLS:
                if (root / "controls" / f"{state}_{control}.png").is_file():
                    rows.append(f"{phase}\t{state}\t{preset}\t{mood}\t{look}\tlow_crest:{control}\t20.0\t0.016666667\t0.0\t34.0\t160.0")
        for state, preset, mood, look, view, elevation, azimuth in PAIRS:
            if (root / "pairs" / f"{state}_{'day' if look == 1 else 'sun' if state == 'swell' else 'overcast' if look == 2 else 'backlight'}.png").is_file():
                rows.append(f"{phase}\t{state}\t{preset}\t{mood}\t{look}\t{view}\t20.0\t0.016666667\t0.0\t{elevation}\t{azimuth}")
    (args.campaign / "manifest.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
