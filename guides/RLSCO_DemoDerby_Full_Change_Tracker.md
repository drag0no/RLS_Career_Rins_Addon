# RLSCO Demo Derby - Full Change Tracker

## Scope

This file tracks the Demolition Derby FRE feature from the first event-add commit through the latest current (uncommitted) working-tree updates.

Coverage source:
- Git history on derby-related files.
- Current working-tree diff.

Range:
- First derby commit: `7740f01e` (2026-04-05).
- Through latest committed derby fix pass: `f834fa23` (2026-04-11).
- Plus current uncommitted runtime updates.

---

## Timeline Summary

- 2026-04-05 - `7740f01e` - Initial derby event integration.
- 2026-04-06 - `fdb47f37` - AI combat behavior and derby AI mode support.
- 2026-04-10 - `1d957cf2` - FRE progression/skill integration and UI support pass.
- 2026-04-10 - `a62239a0` - Productization improvements (stats, rewards, phone UI/backend).
- 2026-04-10 - `2401f1f4` - POI discovery fix for derby visibility.
- 2026-04-11 - `f834fa23` - Safety/reliability/UI hardening pass.
- 2026-04-11 - Working tree (uncommitted) - Start-spot activation polish: spawn/restore flow, POI start-spot preference, subtle world marker, and console-toggled zone debug draws (default off).
- 2026-04-11 - Working tree (uncommitted) - Code review consistency fixes: staging AI-slot parity, startup/unload teardown rollback parity, and derby AI collision/retarget/stuck-timer correctness.

---

## Detailed Chronological Change Log

## 1) `7740f01e` (2026-04-05) - Initial Derby Event Stack

Main outcome: derby became playable as a freeroam event type.

Added:
- `levels/west_coast_usa/demo.config.json`
- `levels/west_coast_usa/demolition.sites.json`
- `lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua`
- `ui/modModules/freeroamRaceHud/demoStaging.html`
- `ui/modModules/freeroamRaceHud/demoStaging.css`
- `ui/modModules/freeroamRaceHud/demoCongratulations.html`
- `ui/modModules/freeroamRaceHud/demoCongratulations.css`

Modified:
- `lua/ge/extensions/gameplay/events/freeroamEvents.lua`
- `lua/ge/extensions/gameplay/fre/config.lua`
- `ui/modModules/freeroamRaceHud/freeroamRaceHud.html`
- `ui/modModules/freeroamRaceHud/freeroamRaceHud.css`
- `ui/modModules/freeroamRaceHud/freeroamRaceHud.js`

Functional additions:
- Derby staging/start flow.
- Derby runtime lifecycle controller.
- Elimination zones and placement logic.
- HUD and popup bridge for derby-specific UX.

## 2) `fdb47f37` (2026-04-06) - AI Behavior Pass

Main outcome: derby AI became actively competitive.

Modified:
- `levels/west_coast_usa/demo.config.json`
- `levels/west_coast_usa/demolition.sites.json`
- `lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua`
- `lua/vehicle/extensions/overrideAI.lua`
- `ui/modModules/freeroamRaceHud/demoCongratulations.html`

Functional additions:
- Derby-specific AI mode support in vehicle AI override (`demoderby`, `demoderby_recovery`, `demoderby_reverse`).
- Delayed AI activation, retargeting, anti-stuck behavior.
- Updated derby tuning and spawn/zone geometry.

## 3) `1d957cf2` (2026-04-10) - FRE Discipline/Progression Integration

Main outcome: derby connected into FRE progression and skills.

Added:
- `gameplay/domains/careerSkills/skills/demo/info.json`
- Multiple guide docs (planning/architecture/discipline analysis).

Modified:
- `gameplay/fre/freProgression.config.json`
- `lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua`
- `lua/ge/extensions/gameplay/fre/config.lua`
- `lua/ge/extensions/ui/phone/freeroamEvents.lua`
- Derby staging/congrats UI files.
- `levels/west_coast_usa/demo.config.json`

Functional additions:
- Demo skill track + progression data.
- FRE schema integration for demo discipline.
- Phone/backend support expansion and popup/UI polishing.

## 4) `a62239a0` (2026-04-10) - Productization Improvements

Main outcome: derby evolved from event mode to full FRE product behavior.

Modified:
- `gameplay/fre/freProgression.config.json`
- `levels/west_coast_usa/demo.config.json`
- `lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua`
- `lua/ge/extensions/gameplay/events/freeroam/leaderboardManager.lua`
- `lua/ge/extensions/gameplay/fre/config.lua`
- `lua/ge/extensions/ui/phone/freeroamEvents.lua`
- `ui-vue-src/modules/career/views/PhoneFreeroamEvents.vue`
- plus UI bundle outputs.

Functional additions:
- Reward model depth and anti-farm behavior.
- Derby stat persistence (`updateDemoDerbyStats`).
- Demo-specific phone stats and record rendering.
- Expanded runtime polish and documentation baseline.

## 5) `2401f1f4` (2026-04-10) - Derby POI Discovery Fix

Main outcome: derby discoverability improved in map/event surfaces.

Modified:
- `lua/ge/extensions/gameplay/events/freeroamEvents.lua`
- `guides/RLSCO_DemoDerby_End_To_End_Deep_Analysis.md`

Added:
- `levels/west_coast_usa/facilities/freeroamEvents/demo_dirt.jpg`

Functional additions:
- POI generation/fallback update so derby events appear reliably via map data flow.

## 6) `f834fa23` (2026-04-11) - Safety and Reliability Hardening

Main outcome: review-driven fixes and robustness pass.

Modified:
- `levels/west_coast_usa/demo.config.json`
- `levels/west_coast_usa/demolition.sites.json`
- `lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua`
- `lua/vehicle/extensions/overrideAI.lua`
- `ui-vue-src/modules/career/views/PhoneFreeroamEvents.vue`
- `ui/modModules/freeroamRaceHud/freeroamRaceHud.css`
- `ui/modModules/freeroamRaceHud/freeroamRaceHud.js`

Functional additions/fixes:
- Corrected derby vehicle pool keys (`fullsize` usage) and updated site spawn transforms.
- Removed dead `retargetAllAi()` helper.
- Fixed derby AI control latching on nil player path by neutralizing controls before return.
- Fixed crash-anchor disappearance path in `overrideAI.lua` to clear crash state and continue pursuit.
- Reset derby-only crash state (`crashObjID`, `internalState.crash.crashes`) during reset paths.
- Removed unused local `targetSpeed` in derby-only branch.
- Ensured derby stats card fallback renders when `demoStats` is missing.
- Renamed toast keyframes to kebab-case for stylelint compliance.
- Added safe Lua string serialization for `eventKey` in derby staging start command.

## 7) Working Tree (Uncommitted, Current) - Start-Spot Activation Polish and Runtime UX/Debug Controls

Main outcome: derby start flow is now fully parking-spot-driven across popup/POI/marker surfaces with explicit debug controls and safer runtime behavior.

Modified:
- `lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua`
- `lua/ge/extensions/gameplay/events/freeroamEvents.lua`

Functional additions:
- Capture exact staged player vehicle transform (position + rotation) at event start.
- Teleport player to a random derby parking spot each run.
- Reserve player-selected spot and spawn AI only on remaining spots.
- Cap AI count by both configured max and available non-player spots.
- Restore player to exact staged transform when event ends (win or eliminated).
- Restore player immediately if start flow fails after player teleport.
- Clear saved staged transform on staging cancel and runtime cleanup.
- Add start-spot-driven staging popup behavior:
	- default spot-name convention: `start_<eventKey>` (example: `start_demo_dirt`),
	- optional per-event overrides: `startSpotName`, `startSpotRadius`,
	- popup opens when player reaches the configured start spot,
	- popup closes when player leaves the start spot before starting,
	- staging trigger callback is no longer used for popup activation.
- Add derby POI start-position preference update in `freeroamEvents.lua`:
	- POI position now resolves from configured start parking spot first (`start_<eventKey>` or `startSpotName`),
	- trigger-based position remains fallback,
	- play-zone centroid remains final fallback.
- Fix start-spot proximity runtime error:
	- replaced accidental global `max(...)` call with `math.max(...)` in start-radius clamp path.
- Add subtle permanent in-world start marker rendering:
	- lightweight dual-ring + short beacon marker at derby start spots,
	- restrained color/alpha pulse,
	- distance-limited draw to reduce track clutter.
- Add console-controlled debug zoning overlay for play/elimination zones:
	- `setZoneDebugDrawEnabled(...)`, `toggleZoneDebugDraw(...)`, `getZoneDebugDrawState(...)`,
	- compatibility aliases: `setDebugZonesEnabled(...)`, `toggleDebugZones(...)`,
	- debug overlays are now off by default and no longer auto-enabled by staging/start flow.

## 8) Working Tree (Uncommitted, Current) - Code Review Consistency and Cleanup Reliability Pass

Main outcome: staging UI, runtime start logic, and teardown behavior are now aligned so invalid starts do not silently degrade state or leave side effects behind.

Modified:
- `lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua`
- `lua/vehicle/extensions/overrideAI.lua`
- `ui/modModules/freeroamRaceHud/freeroamRaceHud.js`

Functional additions/fixes:
- Staging payload now reserves one spawn slot for the player when computing `maxAi` (`#resolvedSpots - 1`), matching start-time spawn math.
- Staging availability now reports disabled with reason when available AI slots are below 1.
- Added explicit traffic suppression tracking + restore helper so traffic state is restored on all teardown paths.
- Startup abort path (`spawned < 1`) now restores traffic, clears spatial/event state, and exits cleanly after restoring player transform.
- `clearAllAi()` now despawns every tracked derby AI ID, including recently eliminated entries.
- `onExtensionUnloaded()` now mirrors end-event rollback ordering (restore player, restore traffic, clear spatial/event state, then clear AI/UI state).
- Removed duplicate derby stuck-timer advancement in `overrideAI.lua` so `egoCannotMoveTime` is not incremented twice per frame.
- Forced retarget path now clears cached local target (`player = nil`) alongside `M.targetObjectID = -1`.
- Derby collision detection now only treats `objectCollisions[id] == 1` as active contact before triggering crash maneuver handling.
- HUD `DemoStagingUi` listener now treats `maxAi === 0` as valid payload, rebuilds empty options, clamps `aiCount` to 0, and forces disabled start with a reason.

---

## Current Status Snapshot

- Core derby event mode: implemented.
- Derby AI modes and combat loop: implemented.
- FRE progression/skill/reward integration: implemented.
- Derby stats persistence + phone rendering: implemented.
- Safety hardening (controls/crash state/UI/lint/injection): implemented.
- Player random derby spawn + exact staged return + parking-spot-driven popup/POI/marker flow: implemented in current working tree (not yet committed).
- Zone debug overlays are now explicit opt-in via console toggle (default off).
- Staging/start parity and teardown/collision reliability fixes from review feedback are implemented in current working tree (not yet committed).
