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
RIVER_MATERIAL_ASSETS = ("clean_pebbles", "leafy_grass")
RIVER_HDRI_ASSET = "kloofendal_48d_partly_cloudy_puresky"
PROJECT_DIR = Path(__file__).resolve().parent.parent
ROCKS_DIR = PROJECT_DIR / "resources" / "rocks"
MATERIALS_DIR = PROJECT_DIR / "resources" / "materials"
RIVER_DIR = PROJECT_DIR / "resources" / "river"

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


def river_hdri_url(asset: str) -> str:
    try:
        return fetch_json(f"{API_URL}/{asset}")["hdri"]["4k"]["hdr"]["url"]
    except KeyError:
        raise SystemExit(f"no hdri/4k/hdr variant for {asset}")


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
    if texture.parent.name in RIVER_MATERIAL_ASSETS:
        size_limit = 0
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
    textures = []
    textures.extend(
        MATERIALS_DIR / asset / f"{asset}_{kind}_{RESOLUTION}.jpg"
        for asset in MATERIAL_ASSETS + RIVER_MATERIAL_ASSETS
        for kind in ("diff", "nor_gl", "rough")
    )
    for asset in ROCK_ASSETS:
        textures.extend((ROCKS_DIR / asset).rglob("*.jpg"))
    return sum(configure_mobile_texture_import(texture) for texture in textures)


def main() -> int:
    river_only = "--river-only" in sys.argv[1:]
    for asset in (() if river_only else ROCK_ASSETS):
        print(asset)
        for relpath, url in asset_files(asset).items():
            dest = ROCKS_DIR / asset / relpath
            if dest.exists():
                print(f"  skip {relpath}")
                continue
            print(f"  get  {relpath}")
            download(url, dest)

    for asset in (RIVER_MATERIAL_ASSETS if river_only else MATERIAL_ASSETS + RIVER_MATERIAL_ASSETS):
        print(asset)
        for relpath, url in material_files(asset).items():
            dest = MATERIALS_DIR / asset / relpath
            if dest.exists():
                print(f"  skip {relpath}")
                continue
            print(f"  get  {relpath}")
            download(url, dest)

    hdri_path = RIVER_DIR / "river_sky_4k.hdr"
    if hdri_path.exists():
        print("skip river_sky_4k.hdr")
    else:
        print("get  river_sky_4k.hdr")
        download(river_hdri_url(RIVER_HDRI_ASSET), hdri_path)

    configured = configure_mobile_texture_imports()
    print(f"Configured {configured} mobile texture import profiles.")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.URLError as exc:
        raise SystemExit(f"network error: {exc.reason}") from exc
