# AGENTS.md - AI Agent Coding Guide

This guide is for AI coding agents working in this repository. Read it before inspecting or modifying code.

---

## 1. Project Identity & Developer Intentions

**This repository contains an ADDON / COMPANION mod for the "RLS Career Overhaul" mod for BeamNG.drive.**

It is **NOT** a standalone mod and does **NOT** replace RLS Career. It packages strictly changed and added override files that mount on top of the original mod via BeamNG's virtual filesystem (PhysFS). The base RLS Career mod must be installed for this addon to function.

- **Mod Identity**: "Rin's Addon" (`rls_career_z_rins_addon`).
- **Author**: Solo developer (Rinskillite), completely independent and unaffiliated with the official RLS Career development team.
- **Gratitude & Motivation**: Built out of deep appreciation for the RLS Career mod to enhance personal gameplay, improve performance, fix engine bottlenecks, and share these refinements freely with the BeamNG community.
- **Upstream Welcomed**: The official RLS Career development team has full permission to adopt, adapt, or merge any code or changes from this project into the base mod at any time.
- **Pricing**: Free forever. Optional support (donations/subscriptions) may be added later for those wishing to support development.

---

## 2. Work Style & Code Philosophy

- **Simplicity over cleverness**: Write minimal, readable, idiomatic code. Less code means fewer bugs and easier maintenance.
- **Integrate, don't patch**: Address root causes cleanly within existing architecture rather than stacking workarounds.
- **Reuse existing code**: Check game engine modules and RLS utilities before creating custom helpers.
- **Focused changes**: Keep changes strictly scoped to the problem at hand. Avoid unrelated formatting, renames, or drive-by refactoring.
- **Fail-open by default**: Any missing config, new toggle, or uninitialized setting must fail open (`true`) so fresh saves or upgrades never break.
- **No defensive over-engineering**: Trust validated game engine callers; avoid redundant checks and speculative rollbacks for preconditions already validated upstream.
- **Documentation standard**: Maintain player-facing docs in `docs/TWEAKS_*.md` with clear gameplay motivations and summary tables.

---

## 3. Repository Map

- `guides/` — Original developer architecture documentation, subsystem analyses (FRE, demo derby, maintenance wear), and research reports.
- `scripts/rls_career_overhaul/` — Mod entry bootstrap and runtime orchestration (`modScript.lua`).
- `lua/ge/extensions/overhaul/` — Extension manager and override manager controlling load order and wrapper lifecycles.
- `lua/ge/extensions/career/modules/` — Core career systems (business, inventory, missions, computer interfaces).
- `lua/ge/extensions/overrides/` — Direct engine and career module overrides (delivery, speed traps, player driving).
- `lua/ge/extensions/gameplay/` — Gameplay loops (traffic, police, parking, racing events, bus, ambulance, taxi).
- `lua/ge/extensions/ui/` — Lua-side UI bridge extensions and phone layout controllers.
- `lua/vehicle/extensions/` — Vehicle-side Lua (tires, powertrain logic, pause gear guards).
- `levels/` — Level-specific race definitions (`race_data.json`), facilities, and mission groups.
- `ui/ui-vue/src/modules/career/` — Vue 3 frontend apps, views, and Pinia/Vue stores (phone, business computer).
- `ui/ui-vue/src/modules/career/apps/manifests/` — Declarative app, channel, and permission registries.
- `gameplay/` — Progression configs, skill trees, delivery catalogs, and economy JSON files.
- `docs/` — Rin's Addon feature descriptions, architecture docs, and release notes (`TWEAKS_*.md`).
- `pack_addon.py` / `pack_addon.sh` — Addon packaging and deployment pipeline.

---

## 4. Stack & Engine Conventions

- **Paths**: BeamNG PhysFS virtual filesystem requires strict forward slashes `/`. Never use Windows backslashes in paths.
- **Encoding**: UTF-8 strictly **without BOM** (especially for `.json` files; BOM crashes the BeamNG JSON parser).
- **BeamNG GE Lua Logging**:
  - Never use raw `print()` in production Lua (it bypasses `beamng.log` and lacks console tags).
  - Always use `log(level, origin, message)` where `level` is `'D'`, `'I'`, `'W'`, or `'E'`.
  - Use `dumps(val)` for formatted table logging (`jsonEncode` is `nil` in GE Lua).
- **Module Safety**: Guard cross-module calls with `pcall(extensions.load, "moduleName")` and expose `onExtensionLoaded`.
- **UI & State Synchronization (Vue <-> Lua)**:
  - Register apps/channels declaratively in `manifests/*.js` instead of hardcoding custom views into base containers.
  - Bi-directional schema normalization: normalize settings in both Vue composables and Lua settings managers to prevent `nil` values.
  - Debounce settings writes (~150–200ms) to disk and flush immediately on unmount/deactivation.
  - Decouple presentation from background simulation: filtering, muting, or altering UI views must never prevent underlying game systems, contracts, or background events from generating and maintaining state.

---

## 5. Performance & Hot Loops

- **Zero gameplay regression**: Optimizations must never compromise gameplay responsiveness, AI behavior, or visual fidelity.
- **Zero per-frame allocations**: Never create tables or `vec3` instances inside `onUpdate` or high-frequency loops. Mutate vectors in-place (`:set()`) and reuse static buffer tables with `table.clear()`.
- **Fast-path gates**: Check cheap flags, 2D terrain heights, and distance limits before executing expensive 3D physics raycasts or C++ interop calls.
- **Throttling**: Ambient scans and background checks must run at 1–4 Hz instead of per-frame when cruising or inactive. Advance shared timers outside per-vehicle loops.
- **Save optimizations**: Synchronous career saves (`career_saveSystem.saveCurrent()`) freeze the game for ~1s. Guard saves with change flags and prefer targeted module file writes (`<1ms`) for localized state.

---

## 6. Git & Packaging Workflow

- **Branch structure**:
  - `rls-release`: Clean official release versions of the original RLS Career mod. Never commit custom feature code directly here.
  - `master`: Main integration branch where tested features are unified.
  - `feature/*`: Dedicated, isolated branches for individual features. Always branch from `rls-release` to keep features self-contained.
- **Packaging commands**:
  - **Test build**: `./pack_addon.sh` (packages changes against `rls-release` and deploys ZIP to BeamNG `mods/custom/`).
  - **Release build**: `./pack_addon.sh [--major|--minor|--fix]` (checks clean working tree, bumps `pack_addon.json`, creates Git commit & tag, then builds and deploys).

---

## 7. Things To Avoid

- **Do not modify `overrideAI.lua`** under any circumstances.
- **Do not commit feature code directly to `rls-release`**.
- **Do not execute automated `git add`, `git commit` or branch checkout commands** unless explicitly requested by the user.
- **Do not create or execute ad-hoc Python runner scripts** (`python -c ...`), `luac` or `npm` commands (no Node toolchain present).
- **Do not save `.json` or `.lua` files with UTF-8 BOM**.
- **Do not use raw `print()`** in production Lua code.
- **Do not allocate tables or vectors inside `onUpdate`** or per-frame hot loops.
- **Do not call synchronous global career saves** (`career_saveSystem.saveCurrent()`) for minor or localized state updates.
- **Do not block underlying game simulation or content generation** when silencing or filtering UI views.
