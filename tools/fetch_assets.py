#!/usr/bin/env python3
import hashlib
import json
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

API_URL = "https://api.polyhaven.com/files"
RESOLUTION = "2k"
ROCK_ASSETS = ("boulder_01", "rock_face_02", "namaqualand_boulder_03", "namaqualand_cliff_01")
MATERIAL_ASSETS = ("concrete_wall_001", "grey_tiles")
FOREST_ASSETS = (
    "forest_floor",
    "bark_brown_02",
    "pine_bark",
    "leafy_grass",
    "forest_ground_06",
    "dry_river_pebbles",
)
FOREST_MODELS = (
    "pine_tree_01",
    "jacaranda_tree",
    "tree_small_02",
    "island_tree_01",
    "island_tree_03",
    "grass_medium_01",
    "grass_medium_02",
    "fern_02",
    "shrub_01",
    "shrub_02",
    "shrub_03",
    "shrub_04",
    "nettle_plant",
    "weed_plant_02",
    "pine_sapling_small",
    "pine_roots",
    "tree_stump_01",
    "dead_tree_trunk",
    "rock_moss_set_01",
    "dandelion_01",
    "periwinkle_plant",
)
PROJECT_DIR = Path(__file__).resolve().parent.parent
ROCKS_DIR = PROJECT_DIR / "resources" / "rocks"
MATERIALS_DIR = PROJECT_DIR / "resources" / "materials"
FOREST_DIR = PROJECT_DIR / "resources" / "forest"

# Poly Haven's CDN answers 403 to the default Python-urllib User-Agent.
USER_AGENT = "physics-playground-asset-fetcher"


def open_url(url: str, timeout: int):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(request, timeout=timeout)


def fetch_json(url: str) -> dict[str, Any]:
    with open_url(url, timeout=30) as response:
        return json.load(response)


def asset_files(asset: str) -> dict[str, str]:
    data = fetch_json(f"{API_URL}/{asset}")
    try:
        entry = data["gltf"][RESOLUTION]["gltf"]
    except KeyError:
        raise SystemExit(f"no gltf/{RESOLUTION} variant for {asset}")

    gltf_url: str = entry["url"]
    files = {Path(gltf_url).name: gltf_url}
    files.update({relpath: info["url"] for relpath, info in entry["include"].items()})
    return files


def material_files(asset: str) -> dict[str, str]:
    base_url = f"https://dl.polyhaven.org/file/ph-assets/Textures/jpg/{RESOLUTION}/{asset}"
    return {
        f"{asset}_diff_{RESOLUTION}.jpg": f"{base_url}/{asset}_diff_{RESOLUTION}.jpg",
        f"{asset}_nor_gl_{RESOLUTION}.jpg": f"{base_url}/{asset}_nor_gl_{RESOLUTION}.jpg",
        f"{asset}_rough_{RESOLUTION}.jpg": f"{base_url}/{asset}_rough_{RESOLUTION}.jpg",
    }


def forest_files(asset: str) -> dict[str, str]:
    base_url = f"https://dl.polyhaven.org/file/ph-assets/Textures/jpg/{RESOLUTION}/{asset}"
    return {
        f"{asset}_{kind}_{RESOLUTION}.jpg": f"{base_url}/{asset}_{kind}_{RESOLUTION}.jpg"
        for kind in ("diff", "nor_gl", "arm")
    }


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_name(dest.name + ".part")
    with open_url(url, timeout=300) as response, partial.open("wb") as out:
        shutil.copyfileobj(response, out)
    partial.replace(dest)


def mobile_texture_size(texture: Path) -> int | None:
    name = texture.name
    if name.endswith("_diff_2k.jpg"):
        return 1024
    if name.endswith(("_nor_gl_2k.jpg", "_arm_2k.jpg", "_rough_2k.jpg")):
        return 512
    return None


def texture_import_uid(import_path: Path) -> str:
    if not import_path.exists():
        return ""
    for line in import_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("uid="):
            return f"{line}\n"
    return ""


def configure_mobile_texture_import(texture: Path) -> bool:
    size_limit = mobile_texture_size(texture)
    if size_limit is None or not texture.exists():
        return False

    resource_path = f"res://{texture.relative_to(PROJECT_DIR).as_posix()}"
    resource_hash = hashlib.md5(resource_path.encode("utf-8"), usedforsecurity=False).hexdigest()
    import_path = texture.with_name(f"{texture.name}.import")
    imported_base = f"res://.godot/imported/{texture.name}-{resource_hash}"
    content = f'''[remap]

importer="texture"
type="CompressedTexture2D"
{texture_import_uid(import_path)}path.s3tc="{imported_base}.s3tc.ctex"
path.etc2="{imported_base}.etc2.ctex"
metadata={{
"imported_formats": ["s3tc_bptc", "etc2_astc"],
"vram_texture": true
}}

[deps]

source_file="{resource_path}"
dest_files=["{imported_base}.s3tc.ctex", "{imported_base}.etc2.ctex"]

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit={size_limit}
detect_3d/compress_to=1
'''
    if import_path.exists() and import_path.read_text(encoding="utf-8") == content:
        return False
    import_path.write_text(content, encoding="utf-8")
    return True


def configure_mobile_texture_imports() -> int:
    textures = [
        FOREST_DIR / asset / f"{asset}_{kind}_{RESOLUTION}.jpg"
        for asset in FOREST_ASSETS
        for kind in ("diff", "nor_gl", "arm")
    ]
    textures.extend(
        MATERIALS_DIR / asset / f"{asset}_{kind}_{RESOLUTION}.jpg"
        for asset in MATERIAL_ASSETS
        for kind in ("diff", "nor_gl", "rough")
    )
    for asset in ROCK_ASSETS:
        textures.extend((ROCKS_DIR / asset).rglob("*.jpg"))
    return sum(configure_mobile_texture_import(texture) for texture in textures)


def main() -> int:
    for asset in ROCK_ASSETS:
        print(asset)
        for relpath, url in asset_files(asset).items():
            dest = ROCKS_DIR / asset / relpath
            if dest.exists():
                print(f"  skip {relpath}")
                continue
            print(f"  get  {relpath}")
            download(url, dest)

    for asset in MATERIAL_ASSETS:
        print(asset)
        for relpath, url in material_files(asset).items():
            dest = MATERIALS_DIR / asset / relpath
            if dest.exists():
                print(f"  skip {relpath}")
                continue
            print(f"  get  {relpath}")
            download(url, dest)

    for asset in FOREST_ASSETS:
        print(asset)
        for relpath, url in forest_files(asset).items():
            dest = FOREST_DIR / asset / relpath
            if dest.exists():
                print(f"  skip {relpath}")
                continue
            print(f"  get  {relpath}")
            download(url, dest)

    for asset in FOREST_MODELS:
        print(asset)
        for relpath, url in asset_files(asset).items():
            dest = FOREST_DIR / asset / relpath
            if dest.exists():
                print(f"  skip {relpath}")
                continue
            print(f"  get  {relpath}")
            download(url, dest)
        # Film-res scans: keep the Godot importer away, they are loaded at runtime.
        (FOREST_DIR / asset / ".gdignore").touch()

    configured = configure_mobile_texture_imports()
    print(f"Configured {configured} mobile texture import profiles.")

    print("Done. Bake the forest tree LODs with:")
    print("  godot --headless --path . -s tools/bake_forest_trees.gd")
    print("Then open the project in Godot to re-import.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.URLError as exc:
        raise SystemExit(f"network error: {exc.reason}") from exc
