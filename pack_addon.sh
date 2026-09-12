#!/usr/bin/env bash
# ==============================================================================
# pack_addon.sh
# Runs pack_addon.py and moves the generated zip to BeamNG custom mods folder.
# Usage: ./pack_addon.sh [base_branch] [output_zip]
# ==============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Find working Python 3 interpreter (prioritizing python and py over WindowsApps python3 stub)
PYTHON_BIN=""
for candidate in python py python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys; exit(0 if sys.version_info[0] >= 3 else 1)" >/dev/null 2>&1; then
    PYTHON_BIN="$candidate"
    break
  fi
done

if [ -z "$PYTHON_BIN" ]; then
  echo "Error: Python 3 not found." >&2
  exit 1
fi

OUTPUT_ZIP="${2:-$("$PYTHON_BIN" pack_addon.py --name)}"

"$PYTHON_BIN" pack_addon.py "$@"

if [ -f "$OUTPUT_ZIP" ]; then
  # Normalize LocalAppData path for MinGW / Linux compatibility
  LOCAL_APP="${LOCALAPPDATA:-${USERPROFILE:-$HOME}/AppData/Local}"
  LOCAL_APP="${LOCAL_APP//\\//}"

  # Check existing BeamNG user directory structures
  TARGET_DIR=""
  for candidate in \
    "$LOCAL_APP/BeamNG/BeamNG.drive/current/mods/custom" \
    "$LOCAL_APP/BeamNG.drive/current/mods/custom"; do
    if [ -d "$candidate" ]; then
      TARGET_DIR="$candidate"
      break
    fi
  done

  # Default fallback if directory does not exist yet
  if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR="$LOCAL_APP/BeamNG.drive/current/mods/custom"
    mkdir -p "$TARGET_DIR"
  fi

  echo "==> Moving '$OUTPUT_ZIP' to '$TARGET_DIR/'..."
  mv -f "$OUTPUT_ZIP" "$TARGET_DIR/"
  echo "==> Successfully installed addon to: $TARGET_DIR/$OUTPUT_ZIP"
fi
