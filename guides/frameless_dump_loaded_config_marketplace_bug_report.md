# Frameless Dump Loaded Config Marketplace Bug Report

## Summary

Six Woermann frameless-dump presets contain a 30,000 kg dry-bulk payload but were not marked as loaded configurations. BeamNG therefore treated them as ordinary dealership inventory, allowing a player to purchase what appeared to be a normal frameless dump trailer with the payload already applied.

## Observed Behavior

- A purchased frameless dump trailer spawned at roughly 37-38 tonnes.
- The affected inventory entry retained `"$box_B_loadVolume": 30000` from its selected `.pc` configuration.
- Starting or committing cargo gameplay could appear to clear the unexpected weight because the delivery system replaces all cargo-container state with the currently assigned cargo.
- A loaner explicitly using one of the affected presets would likewise spawn at full preset weight before the cargo-container refresh.

## Root Cause

BeamNG's configuration list excludes loaded trailers from ordinary vehicle-shopping pools when `hasLoad` is true. Delivery generation intentionally requests loaded trailers with `getEligibleVehicles(false, true)`.

The Woermann presets correctly declared their loaded weight in both the `.pc` variable and displayed configuration weight, but their matching `info_*.json` files omitted `"hasLoad": true`. Consequently:

1. Vehicle shopping called `getEligibleVehicles()` with loaded trailers disallowed.
2. The missing flag made the six presets look unloaded.
3. They entered dealership selection alongside the empty `double`, `triple`, and `wide_double` configurations.

## Affected Configurations

| Configuration key | Payload | Total configured weight |
| --- | ---: | ---: |
| `woermann_ore_double` | 30,000 kg | 37,315 kg |
| `woermann_ore_triple` | 30,000 kg | 38,055 kg |
| `woermann_ore_wide_double` | 30,000 kg | 37,235 kg |
| `woermann_sand_double` | 30,000 kg | 37,315 kg |
| `woermann_sand_triple` | 30,000 kg | 38,055 kg |
| `woermann_sand_wide_double` | 30,000 kg | 37,235 kg |

## Fix

Add `"hasLoad": true` to each affected configuration's `info_*.json` metadata.

This is metadata-only. It does not change payload mass, capacity, rewards, trailer physics, material loading, or loaner spawning. It prevents the loaded presets from entering systems that request unloaded configurations.

## Trailer Configuration Audit

The mod's other trailer presets were checked for baked-in loads and load metadata:

- Log-trailer presets containing logs already use `"hasLoad": true`; empty and rack-only variants use `false`.
- Tiltdeck presets containing hay or wood planks already use `"hasLoad": true`; empty variants use `false`.
- Flatbed variants supplied by this mod are empty configurations and use `"hasLoad": false`.
- Cargo-ready box utility, large box utility, enclosed cargo, and tiltdeck loaners contain empty cargo-storage containers rather than a baked-in payload. They correctly remain unmarked so they can be selected as loaners and receive career cargo dynamically.
- No other mod trailer `.pc` file was found with a non-zero cargo-mass or cargo-volume variable requiring `hasLoad`.

## Compatibility and Existing Saves

Existing inventory vehicles preserve their saved configuration and are not silently rewritten. An already-purchased affected trailer may still contain the 30,000 kg preset until its Cargo Mass tuning variable is set to zero or it is replaced with an empty factory configuration.

New dealership stock will exclude the six loaded presets after configuration metadata is refreshed. Delivery generation still permits loaded configurations explicitly, and the frameless trailer-jockey filters continue to select the empty factory keys `double`, `triple`, and `wide_double`.
