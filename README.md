# RLS Career Overhaul — Rin's Addon

A community companion mod for BeamNG.drive that brings major performance optimizations, FRE contract notification filters, multi-stage rally tours, and tuning shop business fixes to the **RLS Career Overhaul** experience.

> ⚠️ **Base Mod Required**: This is an **addon companion mod** and strictly requires the official [RLS Career Overhaul](https://www.patreon.com/cw/RacelessRLS) mod to be installed. It contains only refined overrides that mount seamlessly on top of the original mod.


## 📦 Installation

1. Ensure the official **RLS Career Overhaul** mod is installed and active in BeamNG.
2. Download the latest `rls_career_z_rins_addon_X.X.X.zip` from the [Releases](https://github.com/) page.
3. Drop the ZIP file directly into the **same mods folder** where you placed the original RLS Career mod:
   ```text
   %LOCALAPPDATA%\BeamNG.drive\<current_version>\mods\
   ```
4. Launch BeamNG.drive and load into Career Mode!

**100% Save Compatible**: This addon is designed to be completely safe to add to existing career saves. Progression, licenses, and skill points are automatically reconciled and preserved on load.


## 🐛 Bug Reports & Troubleshooting

I am a solo developer who implements and tests all features myself in my free time to the extent physically possible for a hobby. While I strive to keep everything as polished as possible, edge cases and bugs can still slip through in a conversion as complex as RLS Career.

If you encounter a bug, please follow these steps before submitting a report:
1. **Isolate**: Turn off all mods except the original **RLS Career Overhaul** mod.
2. **Verify**: Check if the bug still occurs in vanilla RLS Career. If it does, it is an upstream base mod issue.
3. **Confirm**: Re-enable **only Rin's Addon** alongside the base RLS mod. If the bug only appears with this addon active, you have found an addon bug!
4. **Report**: Please report it via [GitHub Issues](https://github.com/drag0no/) with reproduction steps and your `beamng.log`.


## ✨ Key Highlights

### ⚡ Performance & Stutter Reduction
* **Parked Vehicle Physics Pooling**: Freezes full physics simulation for distant parked cars across the map, eliminating the single biggest source of CPU contention in Career mode.
* **Smart Traffic Pooling**: Dynamically caps active physics calculation for traffic vehicles based on your CPU, maintaining high map variety without frame drops.
* **Tire Water Scan Fast-Path**: Slashes tire water detection interop calls by over 99%, keeping frame pacing smooth during spirited driving.
* **Zero FFB Cutoffs on Autosave**: Autosaves now wait for your vehicle to stay stopped for 10 seconds, eliminating sudden force feedback drops and 200ms freezes while cornering.

### 🏁 FRE Contract Improvements
* **Customizable Notification Filters**: Adds a dedicated filter in Phone Notification Settings allowing you to filter Contract Ready alerts based on **cars** (models you own vs. loaners), **difficulty tiers** (Easy, Medium, Hard), and active **disciplines** (Rally, Road Racing, Drift, etc.), while keeping all contracts accessible inside the app.
* **Multi-Stage Rally Tours**: Point-to-point stages across the map are now combined into a single unified rally contract with live progress tracking (`Stage 2/4`) and a **1.25x completion payout bonus**, replacing disjointed single-stage contracts.
* **New 50-Level "Dirt" Career Tree**: Features its own progression tree and unlockable licenses for **Rally**, **Dirt**, and **Rallycross**.
* **Fair Payouts for Single-Stage Runs**: Fixed an RLS bug that slashed 1-lap and 1-stage race rewards to 33%, restoring full 100% base payouts.
* **Rebalanced Target Times**: Rebalanced contract target times so players aren't forced to beat their all-time Personal Best just to clear Easy or Medium contracts.

### 🔧 Business Management Improvements
* **Deadlock Resolution**: Completely fixes the *"No active jobs available"* bug when the manager doesn't assign jobs to technicians.
* **Profit-First Automation**: Managers now sort incoming contracts by payout descending, ensuring technicians are always assigned the most profitable work first.
* **Player Project Protection**: Pulling a car out of the shop marks it with a cyan **`Player Assigned`** badge, preventing the automated manager from shipping your personal project offsite with a technician.
* **Ghost Fleet Fix**: Eliminates duplicate ghost vehicles appearing in garage storage while customer cars are offsite.


## 🚧 Work in Progress (Sneak Peek)

### 🏎️ Race Team Business Improvements
* **Background Race Simulation**: Run race team events in the background while you continue driving, exploring, or managing other career businesses.
* Additional enterprise management features and race team logistics currently in active development.


## 📖 In-Depth Feature Documentation

For detailed architectural breakdowns, math formulas, and technical change logs for each system, refer to the in-depth documentation in the [`docs/`](docs/) directory.


## 🤝 Project Philosophy & Credits

* **Author**: Solo passion project by **Rinskillite** (`drag0no`), an experienced software engineer and community modder.
* **Gratitude**: Built out of genuine love and appreciation for the incredible foundation laid by the RLS Career developers. Support their work on [Patreon](https://www.patreon.com/cw/RacelessRLS).
* **Open to Upstream**: The official RLS Career team has full permission to adopt, adapt, or merge any changes from this project into the base mod at any time.
* **Price**: Free forever.
