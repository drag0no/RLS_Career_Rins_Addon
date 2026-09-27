# Changelog

All notable changes to **RLS Career Overhaul — Rin's Addon** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **Business / Parts Menu Tree View**: The vehicle parts menu now uses an expandable folder tree like the main garage, instead of opening each category in a separate window.
- **Racing Team / Background Races**: Hired drivers can now run scheduled races in the background while you do other things. They earn prize money, gain driver XP, put real miles on the car, and trigger normal cooldowns.
- **Racing Team / Realistic Race Simulation**: Background race results are calculated from car power-to-weight, driver skill, track type, starting position, and chance of driver mistakes.
- **Racing Team / Manager Automation**:
  - **Level 1**: Allows manually dispatching drivers with the manager, and automatically books idle drivers every 20 minutes.
  - **Level 2**: Adds selectable booking intervals (5–60 min) and an option to automatically start background races as soon as they are ready.
- **Racing Team / Dyno Certification**: Cars must now be certified before racing. Garages with a dyno certify instantly for free; otherwise, you can pay $1,200 for third-party testing (5-minute timer). Changing parts requires re-certification.
- **Racing Team / Underdog Racing**: Cars below a bracket's minimum power-to-weight ratio can now enter higher race classes if you want a challenge.

### Changed
- **Business / Disappearing Parts Fix**: Fixed spare parts vanishing from inventory after saving/reloading. Stock parts removed from cars now go to your inventory instead of being deleted.
- **Business / Persistent Car State**: Putting a car into garage storage no longer magically repairs damage or refills gas. Damaged cars must be repaired before taking them out.
- **Racing Team / Driver XP Fix**: Leveling up your driver now makes them faster, braver, and cleaner through corners.
- **Racing Team / Player Race Payouts**: Slashed the heavy 75% team cut down to 15% when you drive the race yourself.
- **Racing Team / Driver Payout Cuts**: Rebalanced hired driver cuts from 35–60% to a more realistic 15–35% of prize money based on their tier.
- **Racing Team / Finishing XP**: Drivers now earn experience points for finishing a race even if they don't make the podium.

---

## [1.1.0] - 2026-09-18

### Added
- **Immersion / Vehicle Rotation Pool**: Continuously cycles fresh traffic and parked cars from a background reserve so you stop seeing the same few models on repeat.
- **Immersion / Smart Fleet Sizing**: Automatically scales the number of background reserve cars based on your available RAM and VRAM.
- **Performance / Smooth Car Swapping**: Reserve cars stay frozen until needed, avoiding lag spikes when switching models.
- **Performance / Event Traffic Cleanup**: Automatically clears street traffic during races, time trials, and derbies for better FPS.
- **Police / Chase Persistence Fix**: Police cars chasing you will no longer despawn mid-pursuit if they crash or fall behind.

### Changed
- **Performance / Autosave Stutter Guard**: Autosaves now wait until your car is fully stopped for 10 seconds, preventing force feedback loss and freezes mid-corner.
- **Performance / Background Loop Optimization**: Slowed down background career checks (heat, stamina, bus/taxi loops) to 1–4 Hz so they don't eat CPU every frame.
- **Performance / Tire Water Check Optimization**: Greatly reduced CPU load from tire wetness checks while driving.

---

## [1.0.0] - 2026-09-13

### Added
- **Contracts / Notification Filters**: Added phone settings to filter contract notifications by car ownership (owned vs. loaner), difficulty, and race type.
- **Rally / Multi-Stage Rallies**: Point-to-point stages are now grouped into full rally events with progress tracking and a 25% bonus payout.
- **Progression / Dirt Career Tree**: Added a 50-level progression branch with Rally, Dirt, and Rallycross licenses.

### Fixed
- **Tuning Shop / Deadlock Fix**: Fixed a bug where managers stopped assigning jobs to technicians ("No active jobs available").
- **Tuning Shop / Better Job Sorting**: Managers now prioritize high-paying jobs first.
- **Tuning Shop / Project Car Protection**: Added a badge to prevent managers from sending your personal project cars off with technicians.
- **Tuning Shop / Ghost Car Fix**: Fixed duplicate invisible cars appearing in garage storage while customer cars were away.
- **Contracts / Fair Race Payouts**: Restored full 100% payouts on single-stage and single-lap events.
- **Contracts / Target Times Rebalance**: Rebalanced contract target times so you don't need all-time personal records to beat normal contracts.
