#!/usr/bin/env python3
"""
pack_addon.py
Packages added and modified game files compared to the rls-release branch
into an addon zip file with mod_info.json for BeamNG.drive.
"""

import datetime
import json
import os
import re
import subprocess
import sys
import zipfile

DEFAULT_BASE = "rls-release"
CONFIG_FILE = "pack_addon.json"

EXCLUDE_EXTS = (".md", ".txt", ".sh", ".py", ".pyc", ".zip")
EXCLUDE_PREFIXES = ("guides/", "docs/", "licenses/", ".git", ".vscode/", ".idea/", "__pycache__/")
EXCLUDE_FILES = (CONFIG_FILE,)


def git_cmd(*args, check=False):
    res = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and res.returncode != 0:
        raise RuntimeError(res.stderr.strip())
    return res.stdout.strip() if res.returncode == 0 else ""


def get_git_root():
    return git_cmd("rev-parse", "--show-toplevel") or os.getcwd()


def load_config():
    config_path = os.path.join(get_git_root(), CONFIG_FILE)
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def get_changelog():
    p = os.path.join(get_git_root(), "CHANGELOG.md")
    content = open(p, "r", encoding="utf-8").read() if os.path.isfile(p) else ""
    return p, content


def bump_version(part):
    config = load_config()
    parts = [int(p) for p in config.get("version", "1.0.0").split(".")]
    major, minor, fix = (parts + [0, 0, 0])[:3]

    if part == "major":
        major, minor, fix = major + 1, 0, 0
    elif part == "minor":
        minor, fix = minor + 1, 0
    elif part in ("fix", "patch"):
        fix += 1
    else:
        sys.exit(f"Error: Unknown bump type '{part}'. Use major, minor, or fix.")

    new_version = f"{major}.{minor}.{fix}"
    config["version"] = new_version

    config_path = os.path.join(get_git_root(), CONFIG_FILE)
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
        f.write("\n")

    return new_version


def prepare_release(part):
    config = load_config()
    compat = config.get("compatible_rls", "").strip()
    if not compat:
        sys.exit("Error: 'compatible_rls' is missing or empty in pack_addon.json.")

    p, content = get_changelog()
    match = re.search(r"##\s*\[Unreleased\](.*?)(?=\n##\s*\[|\Z)", content, re.DOTALL | re.IGNORECASE)
    notes = re.sub(r"<!--.*?-->", "", match.group(1)).strip() if match else ""
    if not notes:
        sys.exit("Error: 'CHANGELOG.md' has no unreleased notes under '## [Unreleased]'.")

    latest_tag = git_cmd("describe", "--tags", "--abbrev=0")
    if latest_tag:
        rls_ref = resolve_base_branch("rls-release")
        count = int(git_cmd("rev-list", f"{latest_tag}..{rls_ref}", "--count") or 0)
        prev_json = json.loads(git_cmd("show", f"{latest_tag}:pack_addon.json") or "{}")
        if count > 0 and compat == prev_json.get("compatible_rls", ""):
            print(f"\n⚠️  Notice: '{rls_ref}' has {count} new commit(s) since {latest_tag},")
            print(f"   but 'compatible_rls' in pack_addon.json is unchanged: \"{compat}\"\n")
            ans = input("Do you want to proceed with this compatible_rls version? [y/N]: ").strip().lower()
            if ans not in ("y", "yes"):
                sys.exit("Release aborted. Please verify 'compatible_rls' in pack_addon.json.")

    new_version = bump_version(part)

    today = datetime.date.today().isoformat()
    new_content = re.sub(r"(##\s*\[Unreleased\])", rf"\1\n\n## [{new_version}] - {today}", content, count=1, flags=re.IGNORECASE)
    with open(p, "w", encoding="utf-8") as f:
        f.write(new_content)

    return new_version


def get_release_notes(version_tag=""):
    compat = load_config().get("compatible_rls", "").strip()
    v_clean = version_tag.lstrip("v")
    _, content = get_changelog()

    pattern = rf"##\s*\[v?{re.escape(v_clean)}\][^\n]*\n(.*?)(?=\n##\s*\[|\Z)" if v_clean else r"##\s*\[Unreleased\][^\n]*\n(.*?)(?=\n##\s*\[|\Z)"
    match = re.search(pattern, content, re.DOTALL | re.IGNORECASE)
    notes = match.group(1).strip() if match else f"Release {version_tag or 'latest'}"

    banner = f"> ⚠️ **Base Mod Compatibility**: Requires **`{compat}`** from official [RLS Career Overhaul](https://www.patreon.com/cw/RacelessRLS) releases.\n\n" if compat else ""
    return f"{banner}### What's Changed\n\n{notes}"


def get_default_output(config=None):
    if config is None:
        config = load_config()
    return f"{config['name']}_{config['version']}.zip"


def resolve_base_branch(base):
    for candidate in (base, f"origin/{base}"):
        if git_cmd("rev-parse", "--verify", candidate):
            return candidate
    return base


def get_changed_files(base_branch):
    files = set()
    for cmd in (["diff", "--name-only", base_branch], ["ls-files", "--others", "--exclude-standard"]):
        for line in git_cmd("--no-pager", *cmd).splitlines():
            f = line.strip().replace("\\", "/").lstrip("./")
            if f and os.path.isfile(f):
                files.add(f)
    return files


def is_game_file(path):
    if os.path.basename(path) in EXCLUDE_FILES:
        return False
    return not any(path.startswith(p) for p in EXCLUDE_PREFIXES) and not any(path.endswith(ext) for ext in EXCLUDE_EXTS)


def main():
    os.chdir(get_git_root())

    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "--release":
            if len(sys.argv) < 3:
                sys.exit("Error: --release requires major, minor, or fix")
            print(prepare_release(sys.argv[2]))
            return
        if cmd == "--bump":
            if len(sys.argv) < 3:
                sys.exit("Error: --bump requires major, minor, or fix")
            print(bump_version(sys.argv[2]))
            return
        if cmd in ("--name", "-n"):
            print(get_default_output())
            return
        if cmd in ("--mod-name", "-m"):
            print(load_config().get("name", "rls_career_z_rins_addon"))
            return
        if cmd == "--release-notes":
            print(get_release_notes(sys.argv[2] if len(sys.argv) > 2 else ""))
            return

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
        zf.writestr("mod_info.json", json.dumps(config, indent=2))
        for f in files_to_pack:
            zf.write(f, f.replace("\\", "/").lstrip("./"))

    size_kb = os.path.getsize(output_zip) / 1024
    print(f"==> Done! Created '{output_zip}' ({size_kb:.1f} KB, {len(files_to_pack)} files + mod_info.json).")
    print("    Drop this file into your BeamNG.drive 'mods/' folder to override the base mod.")


if __name__ == "__main__":
    main()
