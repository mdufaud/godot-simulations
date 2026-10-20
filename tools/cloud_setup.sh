#!/usr/bin/env bash
# Provision a GPU-less Linux container (Claude Code cloud session) so the gates,
# GPU suites and screenshots run: Mesa lavapipe (software Vulkan), Xvfb as the
# invisible display (tests/virtual_display.sh falls back to it without kwin),
# Godot, the fetched assets and the import cache. Idempotent; registered as the
# SessionStart hook in .claude/settings.json, which only runs it remotely.
#
#   tools/cloud_setup.sh                     # no-op outside a cloud session
#   CLOUD_SETUP_FORCE=1 tools/cloud_setup.sh # provision any Debian/Ubuntu host
set -euo pipefail

if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" && "${CLOUD_SETUP_FORCE:-0}" != "1" ]]; then
	exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT_VERSION="${GODOT_VERSION:-4.6-stable}"
APT_PACKAGES=(mesa-vulkan-drivers vulkan-tools xvfb ripgrep unzip curl)

SUDO=""
if [[ "$(id -u)" != "0" ]]; then
	SUDO="sudo"
fi

# Hook stdout lands in the session context: keep it to the final summary.
log() { printf 'cloud_setup: %s\n' "$*" >&2; }

missing=()
for pkg in "${APT_PACKAGES[@]}"; do
	dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} > 0 )); then
	log "apt install ${missing[*]}"
	export DEBIAN_FRONTEND=noninteractive
	if ! $SUDO apt-get install -y -q "${missing[@]}" >&2; then
		$SUDO apt-get update -q >&2
		$SUDO apt-get install -y -q "${missing[@]}" >&2
	fi
fi

if ! command -v godot >/dev/null 2>&1 \
	|| [[ "$(godot --version 2>/dev/null)" != "${GODOT_VERSION/-/.}"* ]]; then
	log "installing Godot $GODOT_VERSION"
	tmp="$(mktemp -d)"
	curl -fsSL -o "$tmp/godot.zip" \
		"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
	unzip -q "$tmp/godot.zip" -d "$tmp"
	$SUDO install -m 755 "$tmp/Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot
	rm -rf "$tmp"
fi

log "fetching assets"
python3 "$PROJECT_DIR/tools/fetch_assets.py" >&2

log "rebuilding import cache"
"$PROJECT_DIR/tools/import.sh" --quit >/dev/null 2>&1

device="$(vulkaninfo --summary 2>/dev/null | sed -n 's/^\s*deviceName\s*=\s*//p' | head -1)"
cat <<EOF
Cloud session provisioned: $(godot --version), Vulkan device: ${device:-none}.
- CPU/value gates: tests/run_tests.sh
- GPU suites: GPU=1 tests/run_tests.sh (Xvfb + software Vulkan, timeouts x10, slow)
- Screenshots: tools/capture.sh <demo_key> <out.png> [frames]; read the PNG to inspect it.
EOF
