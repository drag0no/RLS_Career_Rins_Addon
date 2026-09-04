# RLSCO Demo Derby - Exact Changes Added From Commits

## Scope

This document lists exactly what was added and edited for the new freeroam demolition derby event based on branch history, commit diffs, and current uncommitted working-tree updates.

Branch:
- derby-demo

Primary commits:
- 7740f01e - added demolition derby events (AI DOES NOTHING YET)
- fdb47f37 - added ai logic...

Current uncommitted updates:
- 2026-04-11 - code review consistency and teardown reliability fixes.

## 1) Commit 7740f01e - Initial Derby Event Integration

### Added files

- levels/west_coast_usa/demo.config.json
- levels/west_coast_usa/demolition.sites.json
- lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua
- ui/modModules/freeroamRaceHud/demoCongratulations.css
- ui/modModules/freeroamRaceHud/demoCongratulations.html
- ui/modModules/freeroamRaceHud/demoStaging.css
- ui/modModules/freeroamRaceHud/demoStaging.html

### Modified files

- lua/ge/extensions/gameplay/events/freeroamEvents.lua
- lua/ge/extensions/gameplay/fre/config.lua
- ui/modModules/freeroamRaceHud/freeroamRaceHud.css
- ui/modModules/freeroamRaceHud/freeroamRaceHud.html
- ui/modModules/freeroamRaceHud/freeroamRaceHud.js

### What this commit functionally added

- New derby event configuration layer for West Coast map.
- New derby runtime controller extension with:
  - staging popup
  - race HUD state updates
  - elimination zone checks
  - player and AI elimination handling
- Freeroam trigger integration in freeroam event router:
  - special handling for staging triggers under race name demo
- Freeroam update integration:
  - per-frame demolition derby update call
- HUD integration:
  - derby staging overlay
  - derby congratulations overlay
  - derby participant panel and elimination toasts in freeroam HUD
- FRE alias and discipline hook in Lua defaults:
  - added demo discipline in lua fre config defaults
  - added type alias mapping for demo and demolition

## 2) Commit fdb47f37 - AI Combat and Event Behavior Pass

### Modified files

- levels/west_coast_usa/demo.config.json
- levels/west_coast_usa/demolition.sites.json
- lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua
- lua/vehicle/extensions/overrideAI.lua
- ui/modModules/freeroamRaceHud/demoCongratulations.html

### What this commit functionally changed

- Expanded derby event AI behavior controls in map config:
  - aggression
  - retarget interval
  - player target weight
  - activation delay
  - avoid cars mode
- Updated vehicle model keys in derby config for valid model naming.
- Refined spawn spots and zone placements in demolition sites file.
- Added advanced derby AI runtime logic:
  - delayed AI activation
  - dynamic target selection and retargeting
  - recovery behavior near boundaries
  - stationary elimination checks
  - anti-stuck handling
- Extended vehicle AI override with derby-specific modes:
  - demoderby
  - demoderby_recovery
  - demoderby_reverse
- Updated congratulations overlay text for stationary elimination reason.

## 3) Current State After Both Commits

### Implemented now

- Derby event runtime is functional as a freeroam event mode.
- Derby has map-level config and zone/spot data.
- Derby has custom HUD overlays and event UI feedback.
- Derby AI logic is integrated and actively customized.
- FRE Lua aliasing recognizes demo and demolition types.

### Not implemented yet

- Demo discipline entry in gameplay/fre/freProgression.config.json.
- Demo career skill definition file under gameplay/domains/careerSkills/skills.
- Demo achievements and level milestone cards.
- Derby reward flow wired into standard FRE progression and payment pipeline.
- Phone Events visibility path for derby event metadata.
- Map-owner guide for adding demo events in other maps.

## 4) Important Clarification

- You already added a Lua-level demo discipline hook in lua/ge/extensions/gameplay/fre/config.lua.
- The main progression source file gameplay/fre/freProgression.config.json still does not include demo.
- That means runtime aliasing exists, but progression schema is not complete yet.

## 5) Net Summary

You added a complete first playable derby freeroam event stack plus AI and HUD integration. The remaining work is mainly progression productization:
- discipline schema in primary progression config
- levels and achievements
- rewards and FRE progression wiring
- discoverability in phone events
- map-agnostic documentation for other map owners

## 6) Recent UI and Bounds Polish (Current Work)

### Modified files

- lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua

### What was functionally changed

- Replaced radial start-spot trigger logic with exact Oriented Bounding Box (OBB) math to correspond exactly with the parking spot's orientation and scale.
- Added diegetic holographic start markers (drawSubtleStartMarker) using bouncing brackets and floating nametags.
- Added isAnotherActivityActive integration to suppress derby markers and interactions when a mission or another freeroam event is running.
- Added toggleZoneDebugDraw console command to toggle visual elimination/play zone debug volumes on the fly.

## 7) Current Work - Code Review Consistency and Teardown Reliability Pass

### Modified files

- lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua
- lua/vehicle/extensions/overrideAI.lua
- ui/modModules/freeroamRaceHud/freeroamRaceHud.js

### What was functionally changed

- Staging max AI now reserves one spawn slot for the player, so UI `maxAi` cannot exceed what start flow can actually spawn.
- Staging availability now disables start with an explicit reason when no AI slots are available.
- Added explicit traffic suppression tracking and restoration helper to guarantee traffic rollback when derby startup aborts, event ends, or extension unloads.
- Startup failure path after traffic shutdown now restores player transform and resets event/spatial state.
- clearAllAi now despawns every tracked derby AI vehicle (including eliminated IDs) before state reset.
- onExtensionUnloaded now mirrors end-event rollback order: restore player, restore traffic, clear spatial/event references, then clear AI/UI state.
- Removed duplicate derby stuck timer advancement in overrideAI so egoCannotMoveTime is only advanced in updateGFX.
- Retarget-forced paths now clear cached local target state alongside M.targetObjectID.
- Derby collision trigger loop now only treats objectCollisions[id] == 1 as active contact.
- DemoStagingUi handler now treats maxAi = 0 as a valid update, rebuilds options accordingly, clamps aiCount to 0, and forces disabled start state.
