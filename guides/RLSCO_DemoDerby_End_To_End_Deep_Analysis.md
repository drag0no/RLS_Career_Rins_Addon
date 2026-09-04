# RLSCO Demo Derby FRE Event - End-to-End Deep Analysis

## 1) Purpose and Scope

This document is the full technical record of how the Demolition Derby FRE event type was added, expanded, and productized in the mod.

It covers:
- Original commit-era derby implementation.
- Post-commit integration work that made demo a full FRE discipline.
- Latest systems added in the most recent pass:
  - reward depth and anti-farm protection,
  - derby-specific stats and phone records,
  - AI personality profiles,
  - immediate elimination when player exits vehicle mid-event,
  - hardened exit detection (walking mode and vehicle-switch aware),
  - map POI integration for derby events without requiring `race_data.json` entries,
  - AI safety hardening to prevent control latching and stale crash-state carryover,
  - UI hardening for derby stats fallback, CSS keyframe lint compliance, and safe Lua payload serialization,
  - random player spawn assignment at event start with exact staged-position restore at event end,
  - staging popup activation by start-spot convention (`start_<eventKey>`, e.g., `start_demo_dirt`) replacing trigger dependency,
  - derby POI start-position resolution aligned to start spots first (trigger/zone as fallback),
  - subtle permanent in-world start marker rendering at derby start spots,
  - console-toggled play/elimination zone debug overlays (default off),
  - hotfix for start-spot radius clamp (`math.max`) to avoid runtime global-call errors.

This is intended as a maintainer-level reference: what was added, how it works, what it connects to, and why.

---

## 2) Chronological Buildout

## Phase A - Initial Derby Feature Commits

Primary source commits on `derby-demo`:
- `7740f01e`: initial derby event stack, staging, HUD, event controller, map config.
- `fdb47f37`: AI combat behavior pass and derby AI mode support.

Core outcome of Phase A:
- Playable derby event type exists.
- Event has map config + site geometry.
- Event has custom staging and completion popups.
- Event has elimination logic and AI behavior framework.

## Phase B - FRE Productization Pass

Follow-up integration transformed demo from a standalone event into a first-class FRE discipline:
- Active discipline registration in progression schema.
- Demo career skill track (1-50) and milestones.
- Reward wiring to money + `fre-demo` XP with top-half eligibility.
- Phone event discoverability.
- Popup reward payload and UI display.
- RLSCO-style popup redesign.
- Split damage display thresholds (`AI` vs `player`) + 100% damage elimination.
- Max AI cap updated to 9.

## Phase C - Advanced Systems Pass (Latest)

Recent additions extended depth and replay balance:
- Reward model depth:
  - AI-count reward scaling,
  - duration-band scaling,
  - anti-farm diminishing returns and cooldown.
- Derby-specific record stats persisted in leaderboard data.
- Phone app now surfaces derby stats and derby-oriented record ranking.
- AI personalities (aggressor/opportunist/survivor) with behavior variance.
- Mid-event player exit now causes immediate elimination with dedicated reason.

## Phase D - Post-Pass Hotfix and Discovery Integration

Recent reliability/discoverability updates:
- Exit-vehicle elimination logic was hardened to catch all practical player-exit cases:
  - no active player vehicle,
  - walking mode enabled,
  - switching away from the event-start vehicle.
- Freeroam map POI generation was extended to include derby events directly from
  `demo.config.json` (+ sites fallback), so derby events can appear even when
  `race_data.json` does not define them.

## Phase E - Safety and Reliability Hardening (`f834fa23`)

Stability and review-driven fixes landed in this pass:
- Vehicle pool correctness and spawn data cleanup:
  - default derby config replaced `grandmarshal` with `fullsize` and expanded event pool,
  - spawn transforms in `demolition.sites.json` were refreshed.
- Dead runtime helper removed:
  - removed unused `retargetAllAi()` from derby runtime.
- Vehicle AI safety fixes in `overrideAI.lua`:
  - no early return when crash anchor object disappears,
  - explicit neutral control command when derby target player is nil,
  - reset derby-only crash state (`crashObjID`, `internalState.crash.crashes`) during AI reset paths,
  - removed unused derby `targetSpeed` local.
- Phone/UI robustness:
  - derby stats fallback now renders when `demoStats` is missing,
  - toast keyframes renamed to kebab-case to satisfy lint,
  - derby staging `eventKey` now serialized safely before `engineLua` call.

## Phase F - Player Spawn Reservation and Return Teleport (Current Working Tree)

Latest runtime behavior pass:
- On derby start, player staging transform is captured (exact vehicle position + rotation).
- Player is teleported to a random resolved derby parking spot each run.
- That player spot is reserved; AI spawning skips it and uses only remaining spots.
- AI count is capped by both configured max and available non-player spots.
- On derby end (win or elimination), player is teleported back to the exact staged transform.
- If start fails after player teleport (for example, no AI spawn), the player is restored immediately.

## Phase G - Staging Start-Spot Popup Gating (Current Working Tree)

Latest staging UX update:
- Derby staging popup is now driven by start-spot entry, not staging trigger entry.
- Spot naming convention defaults to `start_<eventKey>`.
  - Example: event key `demo_dirt` maps to parking spot `start_demo_dirt`.
- Entering the configured start spot radius opens the derby staging popup.
- Exiting that spot closes the popup if event has not started.
- Optional per-event overrides supported:
  - `startSpotName`
  - `startSpotRadius`

## Phase H - Start-Surface Polish and Debug Controls (Current Working Tree)

Latest polish and tooling updates:
- Derby POI location resolution in `freeroamEvents.lua` now prefers start parking spots first,
  then trigger fallback, then play-zone centroid fallback.
- A subtle permanent in-world derby start marker now renders while event is inactive:
  - compact dual-ring + short beacon style,
  - restrained alpha pulse,
  - distance-limited rendering to reduce visual noise.
- Zone debug visualization for play and elimination zones is now explicit console opt-in:
  - `setZoneDebugDrawEnabled(...)`,
  - `toggleZoneDebugDraw(...)`,
  - `getZoneDebugDrawState(...)`,
  - compatibility aliases: `setDebugZonesEnabled(...)`, `toggleDebugZones(...)`.
- Automatic zone-debug activation was removed from normal staging/start flow; overlays are off by default.
- Start-spot radius clamp crash fixed by using `math.max(...)` instead of an accidental global `max(...)` call.

---

## 3) Full File Inventory and Responsibilities

## 3.1 Event Definition and Spatial Data

- `levels/west_coast_usa/demo.config.json`
  - Authoritative derby gameplay tuning.
  - Contains defaults + per-event overrides.
  - Holds reward model, AI behavior, personality profiles, participant limits, damage display scaling, and economy values.
- `levels/west_coast_usa/demolition.sites.json`
  - Spatial source for spawn spots and zone geometry.
  - Defines play zone and elimination zones referenced by config.

## 3.2 FRE Progression and Discipline Mapping

- `gameplay/fre/freProgression.config.json`
  - Demo discipline block (`id: demo`, `skillKey: fre-demo`, active progression).
  - Includes contracts/sponsors/eventXp behavior.
  - Includes demo `rewardTuning` for reward scaling and anti-farm defaults.
  - Alias map supports `demo`, `demolition`, `demolitionderby`.
- `lua/ge/extensions/gameplay/fre/config.lua`
  - Runtime accessor layer for FRE config.
  - Added `getDisciplineRewardTuning(disciplineId)` to expose discipline-level reward tuning to event runtime.
- `gameplay/domains/careerSkills/skills/demo/info.json`
  - Demo 1-50 skill progression cards and milestone messaging.

## 3.3 Derby Runtime Controller

- `lua/ge/extensions/gameplay/events/freeroam/demolitionDerby.lua`
  - Main derby runtime lifecycle and combat logic.
  - Handles:
    - staging popup payload,
    - start-spot-driven staging popup flow,
    - subtle permanent start marker rendering for derby start spots,
    - zone debug overlay toggle APIs (console-driven, default off),
    - player staging transform capture/restore,
    - random player spot assignment + AI spot reservation,
    - AI spawning and control,
    - elimination checks,
    - placement tracking,
    - reward settlement,
    - derby stat recording,
    - HUD state updates,
    - popup payload for completion/failure.

## 3.4 Event Router and Phone Backend

- `lua/ge/extensions/gameplay/events/freeroamEvents.lua`
  - Core freeroam event routing; legacy derby staging-trigger route remains wired,
    while derby popup activation is handled by start-spot proximity checks in
    `demolitionDerby.lua`.
  - Post-pass extension now injects derby POIs from `demo.config.json` into raw map POI output,
    with position resolution via start parking spot (`start_<eventKey>` or `startSpotName`),
    then trigger fallback, then play-zone centroid fallback for map marker placement.
- `lua/ge/extensions/ui/phone/freeroamEvents.lua`
  - Phone backend aggregator.
  - Merges demo events into phone events feed.
  - Provides nav targets and now derby stats payload fields.

## 3.5 Leaderboard/Data Persistence

- `lua/ge/extensions/gameplay/events/freeroam/leaderboardManager.lua`
  - Existing race record persistence plus new derby stat persistence.
  - Added `updateDemoDerbyStats(...)` and extended vehicle entry projection for derby fields.

## 3.6 HUD/UI Surfaces

- `ui/modModules/freeroamRaceHud/demoStaging.html`
- `ui/modModules/freeroamRaceHud/demoStaging.css`
  - Derby staging setup popup.
- `ui/modModules/freeroamRaceHud/demoCongratulations.html`
- `ui/modModules/freeroamRaceHud/demoCongratulations.css`
  - End-of-event result popup, reward display, and elimination reason handling.
- `ui/modModules/freeroamRaceHud/freeroamRaceHud.js`
  - Angular bridge listeners for derby popup messages (`DemoStagingUi`, `DemoCongratulationsUi`, elimination toast).
  - Staging start command now escapes/sanitizes derby start payload (`eventKey`, `aiCount`) before Lua dispatch.
- `ui/modModules/freeroamRaceHud/freeroamRaceHud.css`
  - Toast keyframes normalized to kebab-case (`frh-toast-slide-in/out`) for stylelint compliance.

## 3.7 Phone Frontend

- `ui-vue-src/modules/career/views/PhoneFreeroamEvents.vue`
  - Phone Events UI.
  - Added demo-aware metadata rendering:
    - wins,
    - podium rate,
    - average placement,
    - fastest elimination,
    - average survival,
    - derby-specific record row formatting.

---

## 4) Architecture: How Systems Connect

```text
Player enters start spot (start_<eventKey>)
  -> derby runtime spot proximity check
  -> DemoStagingUi payload
  -> HUD Angular controller (ai count selection)
  -> demolitionDerby.startEvent(aiCount, eventKey)

During event:
  demo.config + demolition.sites resolve gameplay + geometry
  -> capture player staging transform + teleport player to random derby spot
  -> spawn AI in remaining spots + assign personality + activate delayed AI logic
  -> onUpdate loop handles elimination, placement, retargeting, recovery

Event end:
  -> restore player to captured staging transform
  -> recordDerbyStats() -> leaderboardManager.updateDemoDerbyStats()
  -> settleCareerRewards() -> career_modules_payment.reward()
  -> DemoCongratulationsUi payload

Phone app:
  ui_phone_freeroamEvents backend reads leaderboard entries + demo config
  -> builds demoStats + vehicleRecords
  -> PhoneFreeroamEvents.vue renders derby stats and records
```

---

## 5) End-to-End Runtime Lifecycle

1. Runtime loads level-local `demo.config.json` and `demolition.sites.json`.
2. Runtime monitors player proximity to derby start spot (`start_<eventKey>`, e.g., `start_demo_dirt`) and renders a subtle start marker while event is inactive.
3. Entering that spot opens staging popup with event label + AI options (capped at 9).
4. Leaving that spot closes staging popup if event has not started.
5. Player starts event.
6. Runtime resolves event config, spawn points, play zone, elimination zones.
7. Player staging transform is captured; player is teleported to a random derby parking spot.
8. AI vehicles spawn in remaining spots (player spot reserved) and are assigned personality profiles.
9. Delayed activation starts AI combat targeting loop.
10. On each update:
   - AI elimination checks:
     - out-of-bounds/elimination zones,
     - stationary timeout,
     - 100% damage.
   - Player elimination checks:
     - out-of-bounds/elimination zones,
     - stationary timeout,
     - 100% damage,
     - immediate elimination on exiting vehicle mid-event.
   - Placement is assigned via countdown (`nextPlacement`).
11. If player eliminated or all AI eliminated, event ends.
12. End path:
    - derby stats are persisted to leaderboard store,
    - reward eligibility and payout are computed,
    - player is restored to exact staged position/rotation,
    - completion popup receives payout + reason payload.
13. Phone UI can then display updated derby stats and record leaderboards.

---

## 6) Reward Engine Deep Analysis

## 6.1 Base Reward Gate

Reward is still gated by top-half placement:
- `eligible = placement <= ceil(totalParticipants * 0.5)`
- If ineligible: zero payout with explicit reason text.

## 6.2 Final Reward Formula

Money and XP now include layered multipliers.

Money:

`money = baseReward * placementMult * aiCountMult * durationMoneyMult * antiFarmMult * freMoneyMult`

XP:

`xp = baseXpFromTierCurve * aiCountMult * durationXpMult * antiFarmMult * freXpMult`

Where:
- `placementMult`: better placement within eligible half yields better multiplier.
- `aiCountMult`: more opponents means higher reward pressure and payout.
- `duration*Mult`: match duration band affects payout quality.
- `antiFarmMult`: recent repeated runs reduce payout to discourage farming.
- `fre*Mult`: existing FRE contract/sponsor multiplier layer.

## 6.3 Reward Tuning Sources

Reward tuning can come from two layers:
1. Discipline defaults in `freProgression.config.json` (`rewardTuning`).
2. Event/local override in `demo.config.json` (`rewardModel`).

Runtime merges both so map-level event config can override discipline defaults without breaking FRE baseline consistency.

## 6.4 Anti-Farm Design

Current anti-farm model:
- Sliding history window (`historyWindowSeconds`),
- a number of full-value runs (`fullRewardRuns`),
- diminishing multiplier step (`diminishingStep`),
- floor (`minMultiplier`),
- short cooldown penalty (`cooldownSeconds`, `cooldownMultiplier`).

Implementation detail:
- Run timestamps are tracked in-memory (`rewardRunHistory`) per event key.
- History resets on extension unload.

---

## 7) AI Personality System Deep Analysis

## 7.1 Profiles

Three profiles are used:
- `aggressor`
- `opportunist`
- `survivor`

Each profile can tune:
- selection weight,
- player-target weight offset,
- aggression multiplier,
- retarget interval multiplier,
- boundary danger/safe margins,
- reverse-drive preference chance.

## 7.2 Assignment and Runtime Use

- Personality is selected on AI spawn by weighted random.
- Profile values are then applied to:
  - target selection preference,
  - aggression command value,
  - retarget cadence,
  - boundary recovery behavior,
  - drive mode bias (`demoderby` vs `demoderby_reverse`).

Result:
- AI field behavior becomes less homogeneous and more replay-variant.

---

## 8) Derby Stats Persistence and Phone Presentation

## 8.1 Persisted Derby Stats

Stored per inventory vehicle and per derby race label in leaderboard data:
- `demoRuns`
- `demoWins`
- `demoPodiums`
- `demoPlacementSum`
- `demoAveragePlacement`
- `demoPodiumRate`
- `demoAverageSurvivalTime`
- `demoTotalSurvivalTime`
- `demoBestPlacement`
- `demoLongestSurvivalTime`
- `demoFastestEliminationTime`

## 8.2 Event-End Stat Capture

At derby event end:
- runtime resolves player inventory identity,
- computes placement and survival time,
- carries first-elimination timing if available,
- writes through `leaderboardManager.updateDemoDerbyStats(...)`.

## 8.3 Phone Backend and Sorting

Phone backend (`ui/phone/freeroamEvents.lua`) now:
- detects demo-type events,
- builds `demoStats` in payload,
- includes demo stats in `vehicleRecords`,
- sorts demo records by:
  1. wins desc,
  2. podium rate desc,
  3. average placement asc.

## 8.4 Phone Frontend Rendering

Phone UI (`PhoneFreeroamEvents.vue`) now conditionally renders demo-specific cards:
- compact list/map meta: wins + podium rate,
- detailed derby stats section,
- derby-aware records row format.

---

## 9) Edge Case Handling

Implemented edge case requested in latest pass:
- If player exits vehicle mid-event, player is eliminated immediately.
- Elimination reason is `exited_vehicle`.
- Popup includes dedicated message:
  - "You were eliminated for exiting your vehicle during the event."

Exit detection was later hardened to avoid false negatives by checking:
- walking mode state,
- active player vehicle availability,
- mismatch vs. event-start player vehicle id.

Existing edge handling retained:
- stationary elimination,
- out-of-bounds elimination,
- 100% damage elimination.

Additional hardening now in place:
- Nil-target derby branches issue a neutral `driveCar(0, 0, 0, 1)` command before return to avoid stale control inputs.
- Derby crash-context reset now clears both transient crash state and derby-only counters (`crashObjID`, `crash.crashes`).
- Derby stats fallback in phone UI now renders when `demoStats` is absent, preventing empty detail cards.
- Derby staging `eventKey` is escaped before Lua dispatch to prevent malformed command injection.
- Derby staging popup now activates from start-spot entry checks (`start_<eventKey>`) instead of staging trigger events.
- Start-spot radius clamp now uses `math.max(...)`, fixing runtime failures caused by a missing global `max(...)`.
- Play/elimination zone debug overlays are no longer auto-enabled by gameplay flow; they are explicitly controlled via console toggle APIs.

---

## 10) UI Payload Contracts

## 10.1 Staging Popup Payload (`DemoStagingUi`)

Includes:
- `visible`
- `maxAi`
- `eventKey`
- `label`

## 10.2 Completion Popup Payload (`DemoCongratulationsUi`)

Includes:
- `visible`
- `playerEliminated`
- `playerPlacement`
- `playerPlacementStr`
- `eliminationReason`
- `rewardMoney`
- `rewardXp`
- `rewardEligible`
- `rewardNoRewardDetail`

## 10.3 Phone Events Payload Additions (for demo)

Each demo event can now include:
- `isDemoEvent`
- `demoStats` (current vehicle summary)
- `vehicleRecords` with derby stats per vehicle

---

## 11) Map-Agnostic Extensibility Notes

The system is level-relative by design:
- config path uses `levels/<currentLevel>/demo.config.json`
- spatial path uses `levels/<currentLevel>/<sitesFile>`

This allows map owners to add derby support by:
1. defining map-local `demo.config.json`,
2. defining map-local `demolition.sites.json`,
3. adding start parking spots using `start_<eventKey>` (or `startSpotName` overrides).

No central hardcoding to West Coast is required at runtime logic level.

---

## 12) Validation and Build Notes

Static validation completed on modified source files:
- no Lua/JSON/Vue/HTML errors reported by diagnostics.

Latest pass validation:
- `demolitionDerby.lua` diagnostics checked after marker/debug-toggle/default-off updates and start-radius clamp fix.
- `freeroamEvents.lua` diagnostics checked after derby POI start-spot-preferred resolver update.
- no new Lua diagnostics reported.

UI build status:
- `build_ui.bat` executed successfully,
- updated bundles emitted and copied to `ui/ui-vue/dist`.

Build warnings observed:
- existing CSS pseudo-class warnings from unrelated selectors,
- npm audit vulnerability notices from dependency tree.

These warnings did not block build output.

---

## 13) Net Result

The demo derby event type is now a full FRE-integrated system with:
- active progression discipline,
- contracts/sponsors compatibility,
- reward economy integration,
- anti-farm reward balancing,
- personality-driven AI combat variance,
- persistent derby performance stats,
- phone-level derby analytics display,
- robust elimination reason handling including mid-event vehicle exit,
- freeroam map discoverability that no longer depends on derby being mirrored in `race_data.json`,
- control-safety and crash-state reset hardening in derby AI behavior,
- deterministic player lifecycle UX: random derby start slot plus exact staged-position return,
- staging popup activation via `start_<eventKey>` parking-spot convention (trigger-independent),
- derby POI placement aligned to start-spot convention before trigger/zone fallback,
- subtle always-on derby start marker presence without heavy track clutter,
- explicit console control over zone debug overlays with default-off behavior.

In practical terms, the feature moved from "playable event prototype" to a maintainable, progression-connected, analytics-aware FRE discipline implementation.

## Phase I - Visual Start Markers and Trigger Polish (Current Task)

  Latest UX and trigger boundary updates:
  - Replaced arbitrary radial trigger distances with precise Oriented Bounding Box (OBB) math to match the physical orientation of parking spots.
  - Implemented 3D holographic start markers using debugDrawer (bouncing corner brackets and floating text) for a playful, diegetic entry point.
  - Added event suppression logic (isAnotherActivityActive) using pcall to ensure derby markers and popups hide cleanly if another freeroam event or mission is currently running.
  - Removed the debug-style solid ground plane in favor of a subtle corner-bracket UI.
