#!/usr/bin/env bash
# ==============================================================================
# pack_addon.sh
# Runs pack_addon.py and moves the generated zip to BeamNG custom mods folder.
# Usage: ./pack_addon.sh [--major|--minor|--fix] [base_branch] [output_zip]
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

BUMP_TYPE=""
PASSTHROUGH_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --major) BUMP_TYPE="major" ;;
    --minor) BUMP_TYPE="minor" ;;
    --fix|--patch) BUMP_TYPE="fix" ;;
    *) PASSTHROUGH_ARGS+=("$arg") ;;
  esac
done

if [ -n "$BUMP_TYPE" ]; then
  # Ensure working directory is clean before releasing
  if [ -n "$(git status --porcelain)" ]; then
    echo "Error: Working directory has uncommitted changes. Commit or stash them before releasing." >&2
    exit 1
  fi

  NEW_VERSION="$("$PYTHON_BIN" pack_addon.py --bump "$BUMP_TYPE")"
  echo "==> Bumped version to v$NEW_VERSION"

  git add pack_addon.json
  git commit -m "chore(release): v$NEW_VERSION"
  git tag -a "v$NEW_VERSION" -m "Release v$NEW_VERSION"
  echo "==> Created Git commit and tag 'v$NEW_VERSION'"
fi

OUTPUT_ZIP="${PASSTHROUGH_ARGS[1]:-$("$PYTHON_BIN" pack_addon.py --name)}"

"$PYTHON_BIN" pack_addon.py ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}

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

  MOD_NAME="$("$PYTHON_BIN" pack_addon.py --mod-name 2>/dev/null || echo "rls_career_z_rins_addon")"

  # Remove previous versions of the addon from mods directories
  for old_file in "$TARGET_DIR/${MOD_NAME}"*.zip "$TARGET_DIR/../${MOD_NAME}"*.zip; do
    if [ -f "$old_file" ] && ! [ "$old_file" -ef "$OUTPUT_ZIP" ]; then
      echo "==> Removing previous version: $(basename "$old_file")"
      rm -f "$old_file"
    fi
  done

  echo "==> Moving '$OUTPUT_ZIP' to '$TARGET_DIR/'..."
  mv -f "$OUTPUT_ZIP" "$TARGET_DIR/"
  echo "==> Successfully installed addon to: $TARGET_DIR/$OUTPUT_ZIP"
fi

if [ -n "$BUMP_TYPE" ]; then
  echo "==> Release complete! Tip: Push commit & tag with: git push --follow-tags"
fi
