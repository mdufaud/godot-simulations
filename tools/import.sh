#!/usr/bin/env bash
# Rebuild the Godot import cache (resource imports, global script class cache)
# under an exclusive lock on .godot/import.lock. Two concurrent imports — or an
# import racing a test run that parses scripts from the cache — can leave a
# half-written cache behind and fail every suite. The gate runners and capture
# tools hold the same lock in shared mode; this script is the only writer.
#
#   tools/import.sh
#   GODOT=/path/to/godot tools/import.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GODOT="${GODOT:-godot}"

mkdir -p "$PROJECT_DIR/.godot"
exec 9>>"$PROJECT_DIR/.godot/import.lock"
flock 9
exec "$GODOT" --headless --path "$PROJECT_DIR" --import "$@"
