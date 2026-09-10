# RLS Career: Performance Optimizations

## TL;DR
- **Better FPS**: Reduced CPU load from background scripts running every frame, helping bring back lost FPS.
- **No Autosave Stutter During Events**: Hitting a wall, spinning out, or stopping at a red light no longer triggers an immediate autosave. Autosaves now wait until the car has been stopped for 10 seconds.
- **Optimized Tire Water Detection**: Stopped scanning 60+ tire nodes on dry ground every frame.
- **Idle Script Sleeps**: Inactive gigs (Bus, Ambulance) and closed phone apps no longer run updates in the background.
- **Fewer Micro-Stutters**: Reused tables and vectors instead of constantly creating new ones every frame.

---

## 1. Motivation

On standard maps, BeamNG runs at around 120 FPS for me. With RLS Career Overhaul loaded, framerates drop down to the 40–50 FPS range due to the amount of scripts running every frame. The goal of these changes is to claw back some of these lost FPS with clean, high-impact quick wins.

Another big annoyance was autosaving during active driving: hitting an obstacle or spinning out during an ongoing event brought the car to a momentary stop (< 2 m/s), which immediately triggered an autosave. That caused an instant stutter and temporarily cut steering wheel Force Feedback (FFB) while trying to recover.

---

## 2. Changes

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

## 3. Summary of Modified Files

| File | Type | Changes |
| :--- | :--- | :--- |
| [`saveSystem.lua`](lua/ge/extensions/overrides/career/saveSystem.lua) | Career Override | Added 10s stop delay before autosaving to stop FFB cuts and stutters. |
| [`rls_tire_model.lua`](lua/common/rls_tire_model.lua) | Physics / Common | Added contact node and axle fast-paths in water check. |
| [`rlsTireProvider.lua`](lua/vehicle/extensions/rlsTireProvider.lua) | Vehicle Lua | Polled water check at 20 Hz and cached state per wheel. |
| [`traffic/vehicle.lua`](lua/ge/extensions/overrides/gameplay/traffic/vehicle.lua) | Traffic AI Override | Lazy `getObjectByID` call only when collision exists. |
| [`bus.lua`](lua/ge/extensions/gameplay/bus.lua) | Gameplay | Early return in `onUpdate` when bus gig is inactive. |
| [`ambulance.lua`](lua/ge/extensions/gameplay/ambulance.lua) | Gameplay | Early return in `onUpdate` when ambulance gig is inactive. |
| [`offroadRecovery.lua`](lua/ge/extensions/gameplay/offroadRecovery.lua) | Gameplay | Stopped 1 Hz UI broadcasts when phone app is closed. |
| [`PhoneOffroadRecovery.vue`](ui/ui-vue/src/modules/career/views/PhoneOffroadRecovery.vue) | Vue Frontend | Dispatched app open/close events to `offroadRecovery.lua`. |
| [`groundMarkerOwnership.lua`](lua/ge/extensions/overhaul/groundMarkerOwnership.lua) | Overhaul | Fast-path check in `install()` during `onPreRender`. |
| [`activityHeat.lua`](lua/ge/extensions/career/modules/activityHeat.lua) | Career Module | Throttled NPC demand drain to 1 Hz and reused buffer table. |
| [`stamina.lua`](lua/ge/extensions/career/modules/stamina.lua) | Career Module | Added driving transition check and reused vector in-place. |
| [`walkEnterVehicle.lua`](lua/ge/extensions/overhaul/walkEnterVehicle.lua) | Overhaul | Reused `lastPlayerPos` vector in-place. |
