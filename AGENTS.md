# AGENTS.md - AI Agent Coding Guide

Companion/addon mod (`rls_career_z_rins_addon`) for **RLS Career Overhaul** in BeamNG.drive. Mounts override files over the base mod via PhysFS virtual filesystem. Base mod is required.

---

## 1. Non-Negotiable Guardrails

- **Do not modify** `overrideAI.lua` or vanilla BeamNG source files (`C:\Steam\steamapps\common\BeamNG.drive\lua\`). Vanilla files are read-only references.
- **Do not commit directly to `rls-release`** (clean upstream baseline). Branch features off `rls-release`.
- **Do not execute** automated `git add`, `git commit`, or branch checkouts unless explicitly instructed.
- **Do not run** ad-hoc Python runner scripts (`python -c`), `npm`, or `luac` (no Node toolchain present).

---

## 2. Key Directories & Workflows

### Repository
- `lua/ge/extensions/overhaul/`: Extension/override load order and lifecycle managers.
- `lua/ge/extensions/overrides/`: Direct engine & career overrides (only execute when RLS is active).
- `lua/ge/extensions/career/modules/`: Core career logic (business, inventory, computer).
- `lua/ge/extensions/gameplay/`: Loops (traffic, police, parking, racing, emergency).
- `lua/ge/extensions/ui/`: Lua-side UI bridge extensions and phone layout controllers.
- `lua/vehicle/extensions/`: Vehicle-side Lua (powertrain, tires, pause gear guards).
- `ui/ui-vue/src/modules/career/`: Vue 3 apps/stores. Declarative manifests in `apps/manifests/`.
- `ui/ui-vue/src/modules/career/apps/manifests/`: Declarative app, channel, and permission registries.
- `gameplay/`: Progression configs, skill trees, delivery catalogs, and economy JSON files.
- `docs/TWEAKS_*.md` (on `master` branch): Feature and architectural documentation. Use repo-relative paths (`../lua/...`).

### External & Engine Paths
- **BeamNG Original Lua Files** (`C:\Steam\steamapps\common\BeamNG.drive\lua\`):
- **BeamNG Log File** (`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\beamng.log`):
  - **Never read or request this file line-by-line or in full**.
  - To locate useful information, always filter for specific tags or keywords using `Select-String`


---

## 3. Engine & Code Conventions

### Coding Guidelines
- **Simplicity over cleverness**: Write minimal, readable, idiomatic code.
- **Integrate, don't patch**: Address root causes cleanly within existing architecture rather than stacking workarounds.
- **Focused changes**: Keep changes strictly scoped to the problem at hand. Avoid unrelated formatting, renames, or drive-by refactoring.
- **No defensive over-engineering**: Trust validated game engine callers; avoid redundant checks and speculative rollbacks for preconditions already validated upstream.
- **Do not use absolute OS paths in markdown documentation**.

### Mod Integration & Specifics
- **Filesystem**: Strict forward slashes (`/`). No Windows backslashes in paths.

- **Fail-Open**: Missing configs or new settings must default to `true` (enabled) to avoid breaking fresh saves.
- **JSON**: UTF-8 **without BOM** (BOM crashes BeamNG's parser).
- **Logging**:
  - No `print()`. Use `log(level, tag, message)` where level is `'D'`, `'I'`, `'W'`, or `'E'`.
  - Use `dumps(val)` to inspect tables (`jsonEncode` is `nil` in GE Lua).

---

## 4. Performance & Hot Loops
- **Zero per-frame allocations**: Never instantiate tables or `vec3` in `onUpdate` or hot loops. Mutate existing vectors (`:set()`) and clear static tables (`table.clear()`).
- **Fast-path gates**: Check cheap flags and 2D bounds before running 3D raycasts or C++ calls.
- **Pacing**: Throttle background scans to 1–4 Hz using shared timers outside entity loops. Interleave heavy work (spawns, raycasts) across alternating ticks.
- **Saves**: Never trigger synchronous global career saves (`career_saveSystem.saveCurrent()`) for localized state (causes ~1s frame freeze). Guard with dirty flags and use targeted module file writes.

---

## 5. UI & State Sync (Vue 3 <-> Lua)
- Register apps/channels declaratively in `manifests/*.js` instead of modifying base containers.
- Normalize settings bi-directionally in both Vue composables and Lua to prevent `nil` errors.
- Debounce disk writes (150–200ms) and flush immediately on unmount/deactivation.
- **Decouple UI from simulation**: Muting, filtering, or closing UI components must never interrupt background event generation, contracts, or game state updates.
