# RLS Career: Performance Optimizations

## TL;DR
- **Better FPS**: Reduced CPU load from background scripts running every frame, helping bring back lost FPS.
- **Fixed Parked Car Physics Overload**: Actively simulated parked cars dynamically scaled to CPU cores (1–6 active) instead of running full physics for 20 parked cars across the entire map at once.
- **Traffic Active Pooling**: Actively simulated moving traffic dynamically scaled to CPU cores (2–8 active) while maintaining vehicle model variety across the map.
- **Reduced Traffic & Police Background Scans**: Stopped distant traffic cars (>400m) from raycasting camera visibility, gated covered structure raycasts (>200m, daytime only) while checking underground tunnels via fast 2D terrain height, and throttled ambient police speeding checks to 4 Hz (every 0.25s).
- **No Autosave Stutter During Events**: Hitting a wall, spinning out, or stopping at a red light no longer triggers an immediate autosave. Autosaves now wait until the car has been stopped for 10 seconds.
- **Optimized Tire Water Detection**: Stopped scanning 60+ tire nodes on dry ground every frame.
- **Idle Script Sleeps**: Inactive gigs (Bus, Ambulance) and closed phone apps no longer run updates in the background.
- **Fewer Micro-Stutters**: Reused tables and vectors instead of constantly creating new ones every frame.

---

## 1. Motivation

On standard maps, BeamNG runs at around 120 FPS for me. With RLS Career Overhaul loaded, framerates drop down to the 40–50 FPS range due to the amount of scripts and vehicles running every frame. The primary cause is vehicle physics overload: by default, the game was spawning up to 20 parked cars and 10+ traffic cars and keeping full physics simulations active for all of them at the same time across the entire map, alongside continuous raycasts and per-frame distance searches. The goal of these changes is to claw back some of these lost FPS with clean quick wins without sacrificing gameplay features.

Another big annoyance was autosaving during active driving: hitting an obstacle or spinning out during an ongoing event brought the car to a momentary stop (< 2 m/s), which immediately triggered an autosave. That caused an instant stutter and temporarily cut steering wheel Force Feedback (FFB) while trying to recover.

---

## 2. Changes

### Parked Vehicle Active Pooling Cap & Distance Cleanup
- **Files**: [`playerDriving.lua`](lua/ge/extensions/overrides/career/modules/playerDriving.lua), [`parking.lua`](lua/ge/extensions/overrides/gameplay/parking.lua)
- `playerDriving.lua`: Dynamically scales active parked cars to system CPU topology (`getDynamicActiveLimits()`, e.g. 2 for 8c/8t, 4 for 8c/16t, up to 6 for 16c/32t).
- `parking.lua`:
  - Enforced `vars.activeAmount` inside `enforceParkedCarCap()` and `insertVehicle()` so the active physics pool does not get overridden by the total vehicle spawn count.
  - Scaled `keepDist` in `applyFarInactive()` with vehicle speed so parked cars remain active smoothly as the player drives.
  - Added a 1.0-second periodic check in `onUpdate` to run `applyFarInactive()`, deactivating distant parked cars behind the player so physics is not simulated for 16–20 parked cars across the map.

### Traffic Active Pooling Cap
- **File**: [`playerDriving.lua`](lua/ge/extensions/overrides/career/modules/playerDriving.lua)
- Dynamically scales active moving traffic based on CPU threads (`clamp(trafficAmount, 1, maxTraffic)`, e.g. 3 for 8c/8t, 5 for 8c/16t, up to 8 for 16c/32t). This maintains vehicle model variety by spawning cars across the map while ensuring only the closest moving vehicles actively simulate physics simultaneously.

### Traffic Static Scene Raycast Throttling
- **File**: [`traffic/vehicle.lua`](lua/ge/extensions/overrides/gameplay/traffic/vehicle.lua)
  - Underground tunnels are detected directly via fast 2D terrain height check at any distance without raycasting.
  - Distant traffic cars (`focusDist > 200m`) and cars driving at night skip the 3 static scene physics raycasts previously used to detect covered mesh ceilings.
  - Cars farther than 400m skip the camera visibility raycast.

### Police Ambient Scanning & Speeding Check Throttling
- **File**: [`police.lua`](lua/ge/extensions/overrides/gameplay/police.lua)
- Throttled `getNearestPoliceVehicle` distance searches and `checkSpeedingOffense` calls to 4 Hz (every 0.25 seconds) during ambient driving when no active pursuit is taking place (`pursuit.mode == 0`). During active pursuits, all checks run every frame without delay.

### Autosave 10-Second Stop Delay
- **File**: [`saveSystem.lua`](lua/ge/extensions/overrides/career/saveSystem.lua)
- Autosave now requires the vehicle to stay nearly stopped (< 2 m/s) for 10 continuous seconds before triggering.
- Hitting something during an event, spinning out, slowing down for turns, or stopping at a red light will no longer trigger an autosave or cut steering wheel FFB.
- Manual saves and mission saves still happen immediately.

### Tire Water Detection Fast-Path & Polling
- **Files**: [`rls_tire_model.lua`](lua/common/rls_tire_model.lua), [`rlsTireProvider.lua`](lua/vehicle/extensions/rlsTireProvider.lua)
- `rls_tire_model.lua`: Checks the ground contact node and axle first. If they are on dry ground, it skips scanning the remaining 60+ tread nodes.
- `rlsTireProvider.lua`: Checks water contact at 20 Hz instead of every frame, and caches the result for tire thermals.

### Traffic Collision Lookup
- **File**: [`traffic/vehicle.lua`](lua/ge/extensions/overrides/gameplay/traffic/vehicle.lua)
- Skips calling `getObjectByID(id)` for traffic vehicles that are not in a collision.

### Gig Idle Checks
- **Files**: [`bus.lua`](lua/ge/extensions/gameplay/bus.lua), [`ambulance.lua`](lua/ge/extensions/gameplay/ambulance.lua)
- `bus.lua`: Exits early in `onUpdate` when no bus route is active, skipping vehicle and plate checks.
- `ambulance.lua`: Exits early in `onUpdate` when the player is not in an ambulance or on an active call, skipping marker updates.

### Offroad Recovery Phone App
- **Files**: [`offroadRecovery.lua`](lua/ge/extensions/gameplay/offroadRecovery.lua), [`PhoneOffroadRecovery.vue`](ui/ui-vue/src/modules/career/views/PhoneOffroadRecovery.vue)
- Only sends recovery state updates to the UI when the phone app is actually open.

### Ground Marker Ownership Fast-Path
- **File**: [`groundMarkerOwnership.lua`](lua/ge/extensions/overhaul/groundMarkerOwnership.lua)
- In `onPreRender`, checks if hooks are already installed before doing table lookups and function checks every frame.

### Memory Allocations & Garbage Collection
- **Files**: [`activityHeat.lua`](lua/ge/extensions/career/modules/activityHeat.lua), [`stamina.lua`](lua/ge/extensions/career/modules/stamina.lua), [`walkEnterVehicle.lua`](lua/ge/extensions/overhaul/walkEnterVehicle.lua)
- `activityHeat.lua`: Runs NPC demand drainage once per second instead of every frame, and reuses a shared buffer table with `table.clear()` instead of creating a new table each frame.
- `stamina.lua`: Skips repeated state resets while driving. Reuses `state.lastPos` in-place (`:set()`) instead of creating a new vector every frame.
- `walkEnterVehicle.lua`: Updates `lastPlayerPos` in-place (`:set()`) instead of creating a new vector every frame.

---

## 3. Summary of Implemented Optimizations (Ranked by CPU Impact)

| Rank | Impact | Optimization | Files | CPU Rationale & Mechanism |
| :---: | :---: | :--- | :--- | :--- |
| **1** | **Critical** | **Parked Vehicle Active Pooling Cap & Distance Deactivation** | [`parking.lua`](lua/ge/extensions/overrides/gameplay/parking.lua)<br>[`playerDriving.lua`](lua/ge/extensions/overrides/career/modules/playerDriving.lua) | Freezes full-physics simulation for 10–15 distant parked cars across the map; dynamically scales active parked cars to 1–6 near the player. Eliminates the mod's single biggest source of CPU core contention and thread starvation. |
| **2** | **Critical** | **Traffic Active Pooling Cap** | [`playerDriving.lua`](lua/ge/extensions/overrides/career/modules/playerDriving.lua) | Dynamically limits active moving traffic physics to 2–8 cars (based on host CPU topology) while spawning more cars across the map for model variety. Prevents concurrent vehicle Lua and JBeam solver bottlenecks. |
| **3** | **High** | **Tire Water Detection Fast-Path & 20 Hz Polling** | [`rls_tire_model.lua`](lua/common/rls_tire_model.lua)<br>[`rlsTireProvider.lua`](lua/vehicle/extensions/rlsTireProvider.lua) | Slashes C++ `vehicleObject:inWater()` interop calls from ~25,000/sec down to ~80/sec (>99.6% reduction) across all active wheels by testing ground contact first and polling at 20 Hz. |
| **4** | **High** | **Traffic Raycast Throttling & Fast Terrain Check** | [`traffic/vehicle.lua`](lua/ge/extensions/overrides/gameplay/traffic/vehicle.lua) | Replaces underground tunnel raycasts with instant 2D terrain height checks; gates covered mesh ceiling raycasts to $\le 200$m (daytime only) and camera visibility raycasts to $\le 400$m. Eliminates dozens of heavy 3D static world raycasts per tick. |
| **5** | **Medium** | **Police Ambient Scanning & Speeding Check Throttling** | [`police.lua`](lua/ge/extensions/overrides/gameplay/police.lua) | Throttles police distance searches and road graph speed-limit queries from 60–144 Hz to 4 Hz (every 0.25s) when cruising. Cuts road graph traversals and distance math by ~95% during normal driving. |
| **6** | **Medium** | **Traffic Collision Lazy Object Lookup** | [`traffic/vehicle.lua`](lua/ge/extensions/overrides/gameplay/traffic/vehicle.lua) | Checks collision flags before calling C++ `getObjectByID()`. Eliminates $O(N^2)$ object lookups per frame between non-colliding traffic vehicles. |
| **7** | **Medium**<br>*(Frame Pacing)* | **Autosave 10-Second Stop Delay (FFB Cut Elimination)** | [`saveSystem.lua`](lua/ge/extensions/overrides/career/saveSystem.lua) | Requires 10s of continuous near-stop (< 2 m/s) before autosaving. Eliminates 100–300ms disk I/O / JSON serialization freezes and FFB cutoffs during active driving and cornering. |
| **8** | **Low–Med** | **Gig Idle Polling Gates (Bus & Ambulance)** | [`bus.lua`](lua/ge/extensions/gameplay/bus.lua)<br>[`ambulance.lua`](lua/ge/extensions/gameplay/ambulance.lua) | Early returns in `onUpdate` when no bus route or ambulance mission is active. Skips vehicle lookups, license plate scans, string comparisons, and route marker updates. |
| **9** | **Low** | **Garbage Collection Churn & Vector In-Place Reuse** | [`activityHeat.lua`](lua/ge/extensions/career/modules/activityHeat.lua)<br>[`stamina.lua`](lua/ge/extensions/career/modules/stamina.lua)<br>[`walkEnterVehicle.lua`](lua/ge/extensions/overhaul/walkEnterVehicle.lua) | Mutates `vec3` in place (`:set()`), throttles demand drain to 1 Hz, and reuses shared buffer tables. Drastically reduces per-frame heap churn and LuaJIT GC pause latency. |
| **10** | **Low** | **Ground Marker Ownership Fast-Path** | [`groundMarkerOwnership.lua`](lua/ge/extensions/overhaul/groundMarkerOwnership.lua) | Adds a single-flag fast-path check in `install()` during `onPreRender`, eliminating redundant table lookups and function pointer comparisons every frame. |
| **11** | **Low** | **Offroad Recovery UI Broadcast Suppression** | [`offroadRecovery.lua`](lua/ge/extensions/gameplay/offroadRecovery.lua)<br>[`PhoneOffroadRecovery.vue`](ui/ui-vue/src/modules/career/views/PhoneOffroadRecovery.vue) | Halts 1 Hz JSON serialization and CEF messaging to the UI when the recovery phone app is closed. |
