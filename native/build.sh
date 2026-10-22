#!/usr/bin/env bash
# Builds addons/physics_native/bin/libphysics_native and makes sure the project loads it.
# Usage: native/build.sh [template_debug|template_release]   (default template_debug:
# editor, gates, probes; template_release: what a release export ships)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET="${1:-template_debug}"
EXTENSION="res://addons/physics_native/physics_native.gdextension"
LIBRARY="${PROJECT_DIR}/addons/physics_native/bin/libphysics_native.linux.${TARGET}.x86_64.so"

if [[ "${TARGET}" != template_debug && "${TARGET}" != template_release ]]; then
    printf 'Error: unknown target %s (template_debug or template_release)\n' "${TARGET}" >&2
    exit 2
fi
if [[ ! -f "${SCRIPT_DIR}/godot-cpp/SConstruct" ]]; then
    printf 'Error: %s\n' "godot-cpp is missing: git submodule update --init native/godot-cpp" >&2
    exit 1
fi

# SCons alone takes a second to find nothing to do; the runner calls this on every run.
if [[ ! -f "${LIBRARY}" ]] || [[ -n "$(find "${SCRIPT_DIR}/src" "${SCRIPT_DIR}/SConstruct" \
        "${SCRIPT_DIR}/godot-cpp" -newer "${LIBRARY}" -type f -print -quit)" ]]; then
    scons -C "${SCRIPT_DIR}" -Q -j"$(nproc)" target="${TARGET}" optimize=speed
    # SCons compares contents: a touched but unchanged source leaves the library's date behind.
    touch "${LIBRARY}"
fi

# Outside the editor Godot loads only the extensions .godot/extension_list.cfg names,
# and only an editor scan writes that file.
if ! grep -qxF -- "${EXTENSION}" "${PROJECT_DIR}/.godot/extension_list.cfg" 2>/dev/null; then
    "${PROJECT_DIR}/tools/import.sh"
fi
