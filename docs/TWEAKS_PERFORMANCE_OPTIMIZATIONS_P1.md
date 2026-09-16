# RLS Career: Performance Optimizations (Phase 1)

## TL;DR
- **Smoother Gameplay**: Reduced background script overhead and memory clutter to cut down on micro-stutters and frame hitching.
- **No Mid-Drive Autosave Freezes**: Autosaves now require your car to stay stopped for 10 continuous seconds, eliminating freezes and force feedback (FFB) dropouts when spinning out, bumping a wall, or pausing at red lights.
- **Smarter Background Traffic & Police**: Police radar and distant traffic skip heavy checks and raycasts when cruising far away from the player.
- **Idle Modules Sleep**: Inactive career gigs (Bus, Ambulance), closed phone apps, and walking stamina tracking now sleep when not in use.

---

## 1. Motivation

My main goal was to find obvious quick wins to claw back some FPS. While these optimizations didn't noticeably increase the average FPS counter, since baseline vehicle physics and graphics draw calls dominate overall frame time, they noticeably smoothed out frame pacing and reduced micro-stutters, which is a solid improvement on its own.

---

## 2. Implemented Optimizations & Mechanisms

### 1. Autosave 10-Second Continuous Stop Delay
- **File**: [`saveSystem.lua`](lua/ge/extensions/overrides/career/saveSystem.lua)
- **Problem**: Bringing the vehicle to a brief stop (< 2 m/s) - such as hitting a barrier, spinning out, slowing down for a turn, or stopping at a red light - immediately triggered an autosave if the timer had elapsed. This caused a 100–300ms freeze and momentarily cut steering wheel FFB.
- **Solution**: Added `playerStoppedTimer`. Autosaves now require the vehicle to maintain `< 2 m/s` continuously for 10 seconds. Moving faster than `2 m/s` immediately resets the timer. Manual saves and mission completions still trigger immediately.

### 2. Police Ambient Scanning & Speeding Check Throttling (4 Hz)
- **File**: [`police.lua`](lua/ge/extensions/overrides/gameplay/police.lua)
- **Problem**: When cruising peacefully (`pursuit.mode == 0`), every traffic vehicle checked police distances and speed limits every single frame (60–144 Hz).
- **Solution**: Ambient scans are throttled to 4 Hz (every 0.25s), caching distances between checks. Active pursuits instantly revert to full per-frame checks.

### 3. Traffic Static Raycast Throttling & Fast Terrain Height Checks
- **File**: [`traffic/vehicle.lua`](lua/ge/extensions/overrides/gameplay/traffic/vehicle.lua)
- **Problem**: Active AI cars fired 3 static scene raycasts every tick to detect tunnel meshes, even at night or hundreds of meters away, and cast line-of-sight raycasts to the camera at any distance.
- **Solution**: Night driving skips tunnel checks (headlights are already on). Daytime tunnel detection checks 2D terrain height first, gating ceiling raycasts to `< 200m`. Camera visibility raycasts are skipped for cars farther than 400m.

### 4. Traffic Collision Lazy Scenegraph Lookup
- **File**: [`traffic/vehicle.lua`](lua/ge/extensions/overrides/gameplay/traffic/vehicle.lua)
- **Problem**: `checkCollisions()` called C++ `getObjectByID(id)` on every tracked vehicle pair in `map.objects` every check, even when cars were nowhere near each other.
- **Solution**: Checks collision flags first. If neither vehicle reports contact, it skips the C++ object lookup and bounding box calculation.

### 5. Tire Water Detection Fast-Path & 20 Hz Polling
- **Files**: [`rls_tire_model.lua`](lua/common/rls_tire_model.lua), [`rlsTireProvider.lua`](lua/vehicle/extensions/rlsTireProvider.lua)
- **Problem**: `wheelTouchesWater` scanned all 60+ tread nodes per wheel calling C++ `inWater()` every graphics frame across all wheels.
- **Solution**: Tests the active ground contact node first to confirm dry tires without scanning tread nodes. Polls water contact at 20 Hz (every 0.05s) in `rlsTireProvider.lua`.

### 6. Idle Gig Sleep Gates (Bus & Ambulance)
- **Files**: [`bus.lua`](lua/ge/extensions/gameplay/bus.lua), [`ambulance.lua`](lua/ge/extensions/gameplay/ambulance.lua)
- **Problem**: Both extensions ran extensive logic in `onUpdate` every frame even when not on a route or shift.
- **Solution**: Added early-return gates in `onUpdate` so they completely sleep when inactive.

### 7. Offroad Recovery Phone App Event Gating
- **Files**: [`offroadRecovery.lua`](lua/ge/extensions/gameplay/offroadRecovery.lua), [`PhoneOffroadRecovery.vue`](ui/ui-vue/src/modules/career/views/PhoneOffroadRecovery.vue)
- **Problem**: Broadcast state and serialized job lists to the UI every second even when the phone app was closed.
- **Solution**: UI broadcasts only run when the app is actively open on screen.

### 8. Ground Marker Ownership Pre-Render Fast-Path
- **File**: [`groundMarkerOwnership.lua`](lua/ge/extensions/overhaul/groundMarkerOwnership.lua)
- **Problem**: Performed table lookups and function comparisons on every render frame.
- **Solution**: Added a `hooksInstalled` flag to bypass checks once hooks are confirmed intact.

### 9. Memory Allocations & Garbage Collection Churn Reduction
- **Files**: [`activityHeat.lua`](lua/ge/extensions/career/modules/activityHeat.lua), [`stamina.lua`](lua/ge/extensions/career/modules/stamina.lua), [`walkEnterVehicle.lua`](lua/ge/extensions/overhaul/walkEnterVehicle.lua)
- **Problem**: Per-frame table and `vec3` creations caused frequent LuaJIT garbage collection pauses.
- **Solution**: Uses `vec3:set()` in place, reuses tables with `table.clear()`, and sleeps stamina tracking while driving.

---

## 3. Summary of Implemented Optimizations

| Optimization | Modified Files | Primary Mechanism & Benefit |
| :--- | :--- | :--- |
| **Autosave 10s Stop Delay** | [`saveSystem.lua`](lua/ge/extensions/overrides/career/saveSystem.lua) | Requires vehicle to remain $< 2$ m/s for 10s. Prevents 100–300ms save freezes and FFB cutoffs during crashes, event cornering, and traffic stops. |
| **Police Ambient Scan Throttling (4 Hz)** | [`police.lua`](lua/ge/extensions/overrides/gameplay/police.lua) | Reduces road graph distance traversals and speeding radar checks from 60–144 Hz to 4 Hz when cruising. Instantly restores per-frame execution in pursuits. |
| **Traffic Tunnel & Camera Raycast Gates** | [`traffic/vehicle.lua`](lua/ge/extensions/overrides/gameplay/traffic/vehicle.lua) | Bypasses ceiling raycasts at night and for cars $>200$m away; detects tunnels via 2D terrain height; skips camera visibility raycasts for cars $>400$m away. |
| **Tire Water Fast-Path & 20 Hz Polling** | [`rls_tire_model.lua`](lua/common/rls_tire_model.lua)<br>[`rlsTireProvider.lua`](lua/vehicle/extensions/rlsTireProvider.lua) | Tests active ground-contact node first to confirm dry tires; throttles water polling to 20 Hz (every 50ms) in vehicle VM. |
| **Traffic Collision Lazy Scenegraph Lookup** | [`traffic/vehicle.lua`](lua/ge/extensions/overrides/gameplay/traffic/vehicle.lua) | Checks collision flags before calling `getObjectByID()`, eliminating redundant scenegraph lookups across non-colliding vehicles. |
| **Gig Idle Updates Sleep Gates** | [`bus.lua`](lua/ge/extensions/gameplay/bus.lua)<br>[`ambulance.lua`](lua/ge/extensions/gameplay/ambulance.lua) | Early-returns in `onUpdate` when no bus route or ambulance call is active, skipping license plate scans, route updates, and vehicle checks. |
| **Offroad Recovery UI Broadcast Gating** | [`offroadRecovery.lua`](lua/ge/extensions/gameplay/offroadRecovery.lua)<br>[`PhoneOffroadRecovery.vue`](ui/ui-vue/src/modules/career/views/PhoneOffroadRecovery.vue) | Halts 1 Hz JSON serialization and CEF event triggers when the offroad recovery phone screen is closed. |
| **In-Place Vector Mutation & Table Reuse** | [`activityHeat.lua`](lua/ge/extensions/career/modules/activityHeat.lua)<br>[`stamina.lua`](lua/ge/extensions/career/modules/stamina.lua)<br>[`walkEnterVehicle.lua`](lua/ge/extensions/overhaul/walkEnterVehicle.lua) | Uses `vec3:set()` and `table.clear()`, throttling demand drain to 1 Hz. Eliminates per-frame heap allocations and minimizes LuaJIT GC pause latency. |
| **Ground Marker Pre-Render Fast-Path** | [`groundMarkerOwnership.lua`](lua/ge/extensions/overhaul/groundMarkerOwnership.lua) | Bypasses redundant table iterations and function wrapping checks during `onPreRender`. |
