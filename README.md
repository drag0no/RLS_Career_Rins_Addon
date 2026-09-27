# RLS Career Overhaul — Rin's Addon

A community companion mod for BeamNG.drive designed to enhance immersion, performance, and gameplay depth across the **RLS Career Overhaul** experience.

> ⚠️ **Base Mod Required**: This is an **addon companion mod** and strictly requires the official [RLS Career Overhaul](https://www.patreon.com/cw/RacelessRLS) mod to be installed. It contains only refined overrides that mount seamlessly on top of the original mod.


## 📦 Installation

1. **Verify Compatibility**: Ensure the official **RLS Career Overhaul** mod is installed and that its version is compatible with this addon (check the [Releases](https://github.com/drag0no/RLS_Career_Rins_Addon/releases) page for the supported base mod version).
2. Download the latest `rls_career_z_rins_addon_X.X.X.zip` from the [Releases](https://github.com/drag0no/RLS_Career_Rins_Addon/releases) page.
3. **Delete previous versions**: If updating, delete any older `rls_career_z_rins_addon_*.zip` from your mods folder first to avoid conflicts.
4. Drop the new ZIP file directly into the **same mods folder** where you placed the original RLS Career mod:
   ```text
   %LOCALAPPDATA%\BeamNG.drive\<current_version>\mods\
   ```
5. Launch BeamNG.drive and load into Career Mode!

**100% Save Compatible**: This addon is designed to be completely safe to add to existing career saves. Progression, licenses, and skill points are automatically reconciled and preserved on load.


## ✨ Key Highlights

### 🏁 FRE Contracts

#### [📱 Contract Notification Filters](docs/TWEAKS_FRE_CONTRACT_NOTIFICATION_FILTERS.md)
* **Contract Notification Filters**: Added phone settings to filter contract notifications by car ownership (owned vs. loaner), difficulty, and race type.

#### [🚩 Multi-Stage Rallies & Dirt Progression](docs/TWEAKS_DIRT_AND_RALLY_EVENTS.md)
* **Multi-Stage Rallies**: Point-to-point stages are grouped into full rally events with progress tracking (`Stage 2/4`) and a 25% bonus payout.
* **Dirt Career Tree**: Added a 50-level progression branch with Rally, Dirt, and Rallycross licenses.
* **Fair Race Payouts & Target Times**: Restored 100% payouts on single-stage events and rebalanced target times so you don't need all-time personal records to beat normal contracts.

### 💼 Business Management Improvements

#### [🧩 Business Parts Customization & Inventory](docs/TWEAKS_BUSINESS_PARTS_CUSTOMIZATION_TREE.md)
* **Parts Menu Tree View**: The vehicle parts menu now uses an expandable folder tree like the main garage, instead of opening each category in a separate window.
* **Disappearing Parts Fix**: Fixed spare parts vanishing from inventory after saving/reloading. Stock parts removed from cars now go to your inventory instead of being deleted.
* **Persistent Car State**: Putting a car into garage storage no longer magically repairs damage or refills gas. Damaged cars must be repaired before taking them out.

#### [🏎️ Racing Team Operations & Background Race Sim](docs/TWEAKS_RACING_TEAM.md)
* **Background Races**: Hired drivers can run scheduled races in the background while you explore, tune cars, or do deliveries. They earn prize money, gain driver XP, put real miles on the car, and have normal cooldowns.
* **Realistic Race Simulation**: Race results are calculated from car power-to-weight, driver skill, track type, starting position, and chance of driver mistakes — no boring spectator grinds required.
* **Manager Automation**:
  - **Level 1**: Allows manually dispatching drivers with the manager (to start the background race), and automatically books idle drivers every 20 minutes.
  - **Level 2**: Adds selectable booking intervals (5–60 min) and an option to automatically start background races as soon as they are ready.
* **Driver XP Fix**: Leveling up your driver now makes them faster, braver, and cleaner through corners.
* **Finishing XP**: Drivers now earn experience points for finishing a race even if they don't make the podium.
* **Fairer Economics & Payouts**: Slashed the heavy 75% player-driving cut down to 15%; rebalanced hired driver cuts from 35–60% to a more realistic 15–35% of prize money based on their tier.
* **Dyno Certification**: Cars must now be certified on a dyno before racing (free and instant at your own shop, or paid via third-party testing). Changing performance parts requires re-certification.

#### [🔧 Tuning Shop Business Fixes](docs/TWEAKS_TUNING_SHOP.md)
* **Deadlock Resolution**: Fixed the bug where managers stopped assigning jobs to technicians ("No active jobs available").
* **Better Job Sorting**: Managers automatically prioritize high-paying jobs first.
* **Project Car Protection**: Added a cyan `Player Assigned` badge to prevent managers from sending your personal project cars off with technicians.

### [🚗 Vehicle Rotation Pool (High-Immersion Traffic)](docs/TWEAKS_VEHICLE_ROTATION_POOL.md)
* **Dynamic Fleet Variety**: Continuously cycles fresh traffic and parked cars from a background reserve so you stop seeing the same few models on repeat.
* **Smooth Car Swapping**: Reserve cars stay frozen until needed, avoiding lag spikes or disk hitches when switching models.
* **Police Chase Fix**: Police cars chasing you will no longer despawn mid-pursuit if they crash or fall behind.

### [⚡ Performance & Stutter Reduction](docs/TWEAKS_PERFORMANCE_OPTIMIZATIONS_P1.md)
* **Autosave Stutter Guard**: Autosaves wait until your car is fully stopped for 10 seconds, preventing force feedback loss and freezes mid-corner.
* **Background Loop Optimization**: Slowed down background career checks (heat, stamina, bus/taxi loops) to 1–4 Hz so they don't eat CPU every frame.
* **Tire Water Check Optimization**: Greatly reduced CPU load from tire wetness checks while driving.


## 🚧 Work in Progress (Sneak Peek)

### 🚓 Faster & More Aggressive Police Pursuits
* Tweaking police pursuit AI to make cruisers noticeably faster, more aggressive, and harder to shake off during chases.


## 🐛 Bug Reports & Troubleshooting

I am a solo developer who implements and tests all features myself in my free time to the extent physically possible for a hobby. While I strive to keep everything as polished as possible, edge cases and bugs can still slip through in a conversion as complex as RLS Career.

If you encounter a bug, please follow these steps before submitting a report:
1. **Isolate**: Turn off all mods except the original **RLS Career Overhaul** mod.
2. **Verify**: Check if the bug still occurs in vanilla RLS Career. If it does, it is an upstream base mod issue.
3. **Confirm**: Re-enable **only Rin's Addon** alongside the base RLS mod. If the bug only appears with this addon active, you have found an addon bug!
4. **Report**: Please report it via [GitHub Issues](https://github.com/drag0no/RLS_Career_Rins_Addon/issues) with reproduction steps and your `beamng.log`.


## 📖 In-Depth Feature Documentation

For detailed architectural breakdowns, math formulas, and technical change logs, check out the dedicated guides:
* [🏁 FRE Contract Notification Filters](docs/TWEAKS_FRE_CONTRACT_NOTIFICATION_FILTERS.md)
* [🚩 Dirt & Rally Career Events](docs/TWEAKS_DIRT_AND_RALLY_EVENTS.md)
* [🧩 Business Parts Customization Tree](docs/TWEAKS_BUSINESS_PARTS_CUSTOMIZATION_TREE.md)
* [🏎️ Racing Team Operations & Background Race Sim](docs/TWEAKS_RACING_TEAM.md)
* [🔧 Tuning Shop Business Fixes](docs/TWEAKS_TUNING_SHOP.md)
* [🚗 Vehicle Rotation Pool](docs/TWEAKS_VEHICLE_ROTATION_POOL.md)
* [⚡ Performance Optimizations](docs/TWEAKS_PERFORMANCE_OPTIMIZATIONS_P1.md)


## ☕ Support

This addon is 100% free and open source. If you enjoy the mod and want to support ongoing updates, optimizations, and new features, consider buying me a coffee!

[![Support on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/rinskillite)


## 🤝 Project Philosophy & Credits

* **Author**: Solo passion project by **Rinskillite** (`drag0no`), an experienced software engineer and community modder.
* **Gratitude**: Built out of genuine love and appreciation for the incredible foundation laid by the RLS Career developers. Support their work on [Patreon](https://www.patreon.com/cw/RacelessRLS).
* **Open to Upstream**: The official RLS Career team has full permission to adopt, adapt, or merge any changes from this project into the base mod at any time.
* **Price**: Free forever.
