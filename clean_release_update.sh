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

# Delete jpg, jpeg, and png files in levels/west_coast_usa/facilities/
RM_DIR="levels/west_coast_usa/facilities"
if [ -d "${RM_DIR}" ]; then
    echo "[-] Removing .jpg, .jpeg, .png files in ${RM_DIR}/..."
    find "${RM_DIR}" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -exec rm -vf "{}" +
else
    echo "[ ] Directory ${RM_DIR} does not exist, skipping."
fi

# Delete jpg, jpeg, and png files in ui/modules/whatsnew/
RM_DIR="ui/modules/whatsnew"
if [ -d "${RM_DIR}" ]; then
    echo "[-] Removing .jpg, .jpeg, .png files in ${RM_DIR}/..."
    find "${RM_DIR}" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -exec rm -vf "{}" +
else
    echo "[ ] Directory ${RM_DIR} does not exist, skipping."
fi

# Delete west_coast_usa.ter and west_coast_usa.ter.depth.png in levels/west_coast_usa/
echo "[-] Removing terrain files in levels/west_coast_usa/..."
rm -vf "levels/west_coast_usa/west_coast_usa.ter"
rm -vf "levels/west_coast_usa/west_coast_usa.ter.depth.png"

# Delete whole folder levels/west_coast_usa/art/
RM_DIR="levels/west_coast_usa/art"
if [ -d "${RM_DIR}" ]; then
    echo "[-] Removing ${RM_DIR}/ folder..."
    rm -rf "${RM_DIR}"
    echo "    Removed ${RM_DIR}"
else
    echo "[ ] Folder ${RM_DIR} does not exist, skipping."
fi

# Delete whole folder music/
RM_DIR="music"
if [ -d "${RM_DIR}" ]; then
    echo "[-] Removing ${RM_DIR}/ folder..."
    rm -rf "${RM_DIR}"
    echo "    Removed ${RM_DIR}"
else
    echo "[ ] Folder ${RM_DIR} does not exist, skipping."
fi

# Delete whole folder ui/entrypoints/main/cardSounds/
RM_DIR="ui/entrypoints/main/cardSounds"
if [ -d "${RM_DIR}" ]; then
    echo "[-] Removing ${RM_DIR}/ folder..."
    rm -rf "${RM_DIR}"
    echo "    Removed ${RM_DIR}"
else
    echo "[ ] Folder ${RM_DIR} does not exist, skipping."
fi

# Delete whole folder vehicles/
RM_DIR="vehicles"
if [ -d "${RM_DIR}" ]; then
    echo "[-] Removing ${RM_DIR}/ folder..."
    rm -rf "${RM_DIR}"
    echo "    Removed ${RM_DIR}"
else
    echo "[ ] Folder ${RM_DIR} does not exist, skipping."
fi

echo "=========================================="
echo "Cleanup completed successfully!"
echo "=========================================="

