#!/usr/bin/env bash
# Builds the native library for every platform, exports the Linux, Windows and
# Android presets as release builds and publishes them as a GitHub release of HEAD.
#
#   tools/release.sh v0.1.0 [gh release create flags, e.g. --draft --prerelease]
#   BUILD_ONLY=1 tools/release.sh v0.1.0    # artifacts in bin/release/<tag>, no upload
#
# The Android export is signed with Godot's release keystore variables:
#   GODOT_ANDROID_KEYSTORE_RELEASE_PATH, GODOT_ANDROID_KEYSTORE_RELEASE_USER,
#   GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"
BUILD_ONLY="${BUILD_ONLY:-0}"
NAME="physics-playground"

die() {
	printf 'Error: %s\n' "$1" >&2
	exit 1
}

export_preset() {
	local preset="$1"
	local dir="$2"
	local file="$3"
	mkdir -p "$dir"
	"$GODOT" --headless --path "$PROJECT_DIR" --export-release "$preset" "$dir/$file" >"$dir.log" 2>&1 || {
		tail -n 30 "$dir.log" >&2
		die "export of '$preset' failed (log: $dir.log)"
	}
	[[ -f "$dir/$file" ]] || die "export of '$preset' wrote no $file (log: $dir.log)"
}

[[ $# -ge 1 && "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
	|| die "usage: tools/release.sh vX.Y.Z [gh release create flags]"
TAG="$1"
shift
cd "$PROJECT_DIR"

for var in GODOT_ANDROID_KEYSTORE_RELEASE_PATH GODOT_ANDROID_KEYSTORE_RELEASE_USER GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD; do
	[[ -n "${!var:-}" ]] || die "$var is not set (release keystore of the Android export)"
done
[[ -f "$GODOT_ANDROID_KEYSTORE_RELEASE_PATH" ]] || die "keystore not found: $GODOT_ANDROID_KEYSTORE_RELEASE_PATH"
[[ -d "${ANDROID_HOME:-}/ndk" ]] || die "ANDROID_HOME/ndk not found"
NDK_VERSION="$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -V | tail -n 1)"

if [[ "$BUILD_ONLY" != 1 ]]; then
	[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty: commit or stash first"
	[[ -n "$(git branch -r --contains HEAD)" ]] || die "HEAD is not pushed"
	if gh release view "$TAG" >/dev/null 2>&1; then
		die "release $TAG already exists"
	fi
fi

"$PROJECT_DIR/native/build.sh" template_release
scons -C native -Q -j"$(nproc)" platform=windows target=template_release optimize=speed
scons -C native -Q -j"$(nproc)" platform=android arch=arm64 ndk_version="$NDK_VERSION" \
	target=template_release optimize=speed
"$SCRIPT_DIR/import.sh"

OUT_DIR="$PROJECT_DIR/bin/release/$TAG"
LINUX_DIR="$OUT_DIR/$NAME-$TAG-linux-x86_64"
WINDOWS_DIR="$OUT_DIR/$NAME-$TAG-windows-x86_64"
ANDROID_DIR="$OUT_DIR/$NAME-$TAG-android-arm64"
rm -rf "$OUT_DIR"

# Exports rescan the import cache: hold the lock tools/import.sh and the gate runners share.
exec 9>>"$PROJECT_DIR/.godot/import.lock"
flock 9
export_preset "Linux" "$LINUX_DIR" "$NAME.x86_64"
export_preset "Windows Desktop" "$WINDOWS_DIR" "$NAME.exe"
export_preset "Android" "$ANDROID_DIR" "$NAME.apk"
exec 9>&-

(cd "$OUT_DIR" && zip -q -r "$LINUX_DIR.zip" "$(basename "$LINUX_DIR")")
(cd "$OUT_DIR" && zip -q -r "$WINDOWS_DIR.zip" "$(basename "$WINDOWS_DIR")")
cp "$ANDROID_DIR/$NAME.apk" "$ANDROID_DIR.apk"
ASSETS=("$LINUX_DIR.zip" "$WINDOWS_DIR.zip" "$ANDROID_DIR.apk")

if [[ "$BUILD_ONLY" == 1 ]]; then
	printf '%s\n' "${ASSETS[@]}"
	exit 0
fi
gh release create "$TAG" --target "$(git rev-parse HEAD)" --title "$TAG" --generate-notes "$@" "${ASSETS[@]}"
