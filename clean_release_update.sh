#!/usr/bin/env bash
#
# clean_release_update.sh
# Cleans unnecessary files and folders from the repository after an official RLS Career mod update.

set -euo pipefail

# Ensure script runs from the repository root directory
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

echo "=========================================="
echo "Cleaning repository after RLS Career update"
echo "Repository root: ${REPO_ROOT}"
echo "=========================================="

# 1. Delete jpg, jpeg, and png files in levels/west_coast_usa/facilities/
FACILITIES_DIR="levels/west_coast_usa/facilities"
if [ -d "${FACILITIES_DIR}" ]; then
    echo "[-] Removing .jpg, .jpeg, .png files in ${FACILITIES_DIR}/..."
    find "${FACILITIES_DIR}" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -exec rm -vf "{}" +
else
    echo "[ ] Directory ${FACILITIES_DIR} does not exist, skipping."
fi

# 2. Delete jpg, jpeg, and png files in ui/modules/whatsnew/
WHATSNEW_DIR="ui/modules/whatsnew"
if [ -d "${WHATSNEW_DIR}" ]; then
    echo "[-] Removing .jpg, .jpeg, .png files in ${WHATSNEW_DIR}/..."
    find "${WHATSNEW_DIR}" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -exec rm -vf "{}" +
else
    echo "[ ] Directory ${WHATSNEW_DIR} does not exist, skipping."
fi

# 3. Delete west_coast_usa.ter and west_coast_usa.ter.depth.png in levels/west_coast_usa/
echo "[-] Removing terrain files in levels/west_coast_usa/..."
rm -vf "levels/west_coast_usa/west_coast_usa.ter"
rm -vf "levels/west_coast_usa/west_coast_usa.ter.depth.png"

# 4. Delete whole folder levels/west_coast_usa/art/
if [ -d "levels/west_coast_usa/art" ]; then
    echo "[-] Removing levels/west_coast_usa/art/ folder..."
    rm -rf "levels/west_coast_usa/art"
    echo "    Removed levels/west_coast_usa/art/"
else
    echo "[ ] Folder levels/west_coast_usa/art/ does not exist, skipping."
fi

# 5. Delete whole folder music/
if [ -d "music" ]; then
    echo "[-] Removing music/ folder..."
    rm -rf "music"
    echo "    Removed music/"
else
    echo "[ ] Folder music/ does not exist, skipping."
fi

# 6. Delete whole folder vehicles/
if [ -d "vehicles" ]; then
    echo "[-] Removing vehicles/ folder..."
    rm -rf "vehicles"
    echo "    Removed vehicles/"
else
    echo "[ ] Folder vehicles/ does not exist, skipping."
fi

echo "=========================================="
echo "Cleanup completed successfully!"
echo "=========================================="

