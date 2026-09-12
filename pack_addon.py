#!/usr/bin/env python3
"""
pack_addon.py
Packages added and modified game files compared to the rls-release branch
into an addon zip file with mod_info.json for BeamNG.drive.
"""

import json
import os
import subprocess
import sys
import zipfile

DEFAULT_BASE = "rls-release"
CONFIG_FILE = "pack_addon.json"

EXCLUDE_EXTS = (".md", ".txt", ".sh", ".py", ".pyc", ".zip")
EXCLUDE_PREFIXES = ("guides/", "docs/", "licenses/", ".git", ".vscode/", ".idea/", "__pycache__/")
EXCLUDE_FILES = (CONFIG_FILE,)


def get_git_root():
    try:
        res = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True
        )
        return res.stdout.strip()
    except Exception:
        return os.getcwd()


def load_config():
    config_path = os.path.join(get_git_root(), CONFIG_FILE)
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def get_default_output(config=None):
    if config is None:
        config = load_config()
    return f"{config['name']}_{config['version']}.zip"


def resolve_base_branch(base):
    for candidate in [base, f"origin/{base}"]:
        res = subprocess.run(
            ["git", "rev-parse", "--verify", candidate],
            capture_output=True
        )
        if res.returncode == 0:
            return candidate
    return base


def get_changed_files(base_branch):
    files = set()
    for cmd in [
        ["git", "--no-pager", "diff", "--name-only", base_branch],
        ["git", "ls-files", "--others", "--exclude-standard"],
    ]:
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                f = line.strip().replace("\\", "/").lstrip("./")
                if f and os.path.isfile(f):
                    files.add(f)
    return files


def is_game_file(path):
    if os.path.basename(path) in EXCLUDE_FILES:
        return False
    return not any(path.startswith(p) for p in EXCLUDE_PREFIXES) and not any(path.endswith(ext) for ext in EXCLUDE_EXTS)


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("--name", "-n"):
        print(get_default_output())
        return

    os.chdir(get_git_root())
    config = load_config()
    base_branch = resolve_base_branch(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BASE)
    output_zip = sys.argv[2] if len(sys.argv) > 2 else get_default_output(config)

    print(f"==> Comparing against '{base_branch}'...")
    changed = get_changed_files(base_branch)
    files_to_pack = sorted([f for f in changed if is_game_file(f)])

    if not files_to_pack:
        print(f"No modified game files found compared to '{base_branch}'.")
        return

    print(f"==> Found {len(files_to_pack)} game file(s) to package:")
    for f in files_to_pack:
        print(f"  + {f}")

    print(f"==> Packing into '{output_zip}'...")
    with zipfile.ZipFile(output_zip, "w", zipfile.ZIP_DEFLATED) as zf:
        # BeamNG Mod Manager manifest (enables mod detection in game)
        zf.writestr("mod_info.json", json.dumps(config, indent=2))

        # Pack game files ensuring strictly forward slashes for PhysFS
        for f in files_to_pack:
            arcname = f.replace("\\", "/").lstrip("./")
            zf.write(f, arcname)

    size_kb = os.path.getsize(output_zip) / 1024
    print(f"==> Done! Created '{output_zip}' ({size_kb:.1f} KB, {len(files_to_pack)} files + mod_info.json).")
    print("    Drop this file into your BeamNG.drive 'mods/' folder to override the base mod.")


if __name__ == "__main__":
    main()
