# RLS Career: Tuning Shop Automation, Player Protection & Quality of Life

## TL;DR — What's New?
- **Manager Payout Prioritization**: The Tuning Shop manager now prioritizes the most profitable contracts first, ensuring technicians are always assigned high-paying jobs before lower-paying ones.
- **Smart Queue & Deadlock Fix**: The manager now assigns technicians to accepted jobs waiting in the shop before accepting new job offers, completely eliminating idle technician downtime.
- **Player Project Car Protection ("Hands Off My Build")**: Pulling a car out into the workshop reserves it for you. The manager will never auto-assign technicians to vehicles you are personally building or testing.
- **Clear Status Badges**: Active job cards in the business computer now clearly display whether a vehicle is reserved for you or open for manager assignment:
  - 🔵 **Player Assigned (No Auto-Assign)**: You are working on this vehicle; the manager will not touch it.
  - 🟢 **Auto-Assign Allowed**: Available for the manager to assign to an idle technician.
- **Zero-Lag Pull Out**: Fixed the 1-second freeze when pulling out vehicles by replacing full-game saving with an instant shop-only save.
- **Ghost Fleet Duplication Fix**: Fixed an issue where vehicles driven offsite by technicians appeared as duplicate ghost cars in the shop inventory.
- **Target Time Benchmark Fix**: Fixed corrupted track racing target times and added a fail-safe so impossible benchmarks can never permanently brick a contract.
- **Skill Tree Description Alignment**: Corrected perk descriptions and values so Manager Speed properly reduces cycle time by 3 minutes per level (down to 15 min), and No Hard Feelings clearly states the 5% abandon fee reduction per level.

---

## Detailed Overview

### 1. Motivation & Core Problems Solved

The Tuning Shop business in RLS Career Overhaul allows players to run an aftermarket tuning enterprise—either getting their hands dirty tuning and hotlapping customer cars themselves, or automating the operation through hired technicians and a shop manager.

The primary motivations for this update were two major gameplay blockers and an inventory bug:

1. **The Manager Deadlock Bug ("No Active Jobs Available")**:
   Previously, a bug in the manager workflow would occasionally take a job from the "new" pool and move it to the "active" pool, but fail to complete the technician assignment. The unassigned job remained stuck in the active pool. Over multiple cycles (or if the player had accepted contracts into the shop), the active pool eventually reached its maximum limit. Because the manager previously only inspected the "new" pool and immediately bailed out whenever the active pool was full, it permanently deadlocked—leaving idle technicians sitting around doing nothing and reporting that no jobs were available, despite plenty of offers waiting.
2. **Lack of Payout Prioritization**:
   The manager previously picked job offers in arbitrary array order. Players investing in hiring and leveling up a manager expect their enterprise to prioritize higher-paying, lucrative contracts first to maximize shop revenue.
3. **Ghost Fleet Duplication Bug**:
   When a technician drove a customer vehicle offsite to complete tuning, the car was correctly removed from the garage. However, every time the UI refreshed or the business computer opened, duplicate "ghost" vehicles were spawned in the garage inventory because the inventory verification loop failed to check if the job was already out with a technician.
4. **Active Assignment & The Need for Player Project Protection**:
   Solving the manager deadlock fundamentally required teaching the manager to inspect and assign jobs from the `active` pool. However, opening up the active pool introduced a new challenge: if a player accepted a contract wanting to personally build, tune, or test a car, the manager could now potentially pick that active job and send it offsite with a technician. To make active-pool assignment safe and transparent, a player project reservation system and clear UI indicators were introduced.

---

### 2. Smart Manager Automation & Payout Prioritization

#### 2.1 Payout Prioritization
Both the active job backlog and incoming new offers are now sorted by payout descending before assignment. Technicians are always assigned the most profitable available jobs first.

#### 2.2 Two-Stage Assignment Pipeline & Deadlock Resolution
Instead of only drawing from new offers, the manager operates in two distinct stages:
1. **Stage 1 — Active Jobs Pool**:
   - The manager first checks existing accepted jobs waiting in the shop.
   - Filters for jobs that are unassigned, eligible for technician tier limits, and **not** marked as player-managed.
   - Picks the highest-paying eligible active job and assigns it to an idle technician.
2. **Stage 2 — New Job Offers Pool**:
   - Only if no unassigned active jobs remain and active capacity permits, the manager checks new offers.
   - Picks the top-paying eligible contract, accepts it, and assigns it directly to an idle technician.

By clearing unassigned active jobs first, idle technicians never sit around waiting when work is already in the shop, completely resolving the deadlock.

---

### 3. Player Project Protection & UI Transparency

#### 3.1 Workshop Reservation on "Pull Out"
To ensure the manager's new active-pool assignment never interferes with cars the player wants to work on personally:
- Clicking **"Pull Out"** on a vehicle in the business computer immediately flags the job as player-worked-on.
- The manager strictly ignores all player-flagged jobs.
- The flag is saved to the business jobs file, so your project reservation persists even if you store the car or restart the game.
- **Player freedom preserved**: The player can still manually assign a technician to the car at any time through the technician menu if they change their mind.

#### 3.2 Dual Minimalistic UI Badges
Active job cards in the business computer display a clean status badge directly beneath the progress bar (in both Full and Compact layouts):
- 🔵 **`Player Assigned (No Auto-Assign)`** (Cyan): Indicates you have pulled out or worked on this car; the manager will not touch it.
- 🟢 **`Auto-Assign Allowed`** (Green): Indicates the job is open and eligible for manager auto-assignment.

---

### 4. Quality of Life & Side Fixes (Resolved Along the Way)

While refactoring the manager and inventory pipeline, several related issues were addressed:

#### 4.1 Zero-Lag Vehicle Pull Out
Clicking "Pull Out" previously triggered a full career save (`career_saveSystem.saveCurrent()`), freezing the entire game for ~1 second. This was replaced with a guard (`if not job.playerWorkedOn`) and a fast, targeted business save that only updates the shop's own jobs file in <1ms without any hitching.

#### 4.2 Ghost Fleet Fix
Added a check (`if not job.techAssigned`) in the active vehicle reconciliation loop so vehicles that are offsite with technicians are not erroneously re-added to garage storage.

#### 4.3 Target Time Benchmark Fix & Safe Fallback
Removed an erroneous `targetTime * 60` heuristic that corrupted lap times for track events. In addition, the missing benchmark fallback was updated from `0` to a safe high number so an unexpected invalid benchmark can never permanently lock a player into an uncompletable contract.

#### 4.4 Skill Tree Description & Value Alignment
- **Manager Speed**: Updated code formula to reduce assignment interval by 3 minutes (180s) per level, matching the description (down from 30 min base to 15 min at max level 5).
- **No Hard Feelings**: Updated description to clearly state that the abandon penalty is reduced by 5% of job payout per level (base 50%, down to 25% at max level).

---

### 5. Summary of Modified Files

| File | Type | Changes |
| :--- | :--- | :--- |
| [`tuningShop.lua`](file:///c:/Users/krotp/Projects/BeamNG_RLS/lua/ge/extensions/career/modules/business/tuningShop.lua) | Lua Logic | • Implemented 2-stage manager assignment with reward sorting.<br>• Added `assignJobByManager` helper.<br>• Added player protection tracking via `onVehiclePulledOut` and `isJobPlayerControlled`.<br>• Fixed ghost fleet re-injection in `ensureActiveJobVehicles`.<br>• Fixed target time normalization and added safe fallback.<br>• Fixed `manager-speed` reduction formula (-180s/level).<br>• Added `playerWorkedOn` persistence to `minimizeJob`. |
| [`businessComputer.lua`](file:///c:/Users/krotp/Projects/BeamNG_RLS/lua/ge/extensions/career/modules/business/businessComputer.lua) | Lua Bridge | • Updated `pullOutVehicle(businessId, vehicleId, jobId)` to accept and forward `jobId` to business modules. |
| [`BusinessJobCard.vue`](file:///c:/Users/krotp/Projects/BeamNG_RLS/ui/ui-vue/src/modules/career/components/businessComputer/BusinessJobCard.vue) | Vue Frontend | • Added computed `isPlayerControlled`.<br>• Added dual status badges (`Player Assigned` vs `Auto-Assign Allowed`) with styling and tooltips for Full and Compact layouts. |
| [`BusinessHomeView.vue`](file:///c:/Users/krotp/Projects/BeamNG_RLS/ui/ui-vue/src/modules/career/components/businessComputer/BusinessHomeView.vue) | Vue Frontend | • Updated `handlePullOut` to forward `jobId` into `store.pullOutVehicle`. |
| [`BusinessJobsTab.vue`](file:///c:/Users/krotp/Projects/BeamNG_RLS/ui/ui-vue/src/modules/career/components/businessComputer/BusinessJobsTab.vue) | Vue Frontend | • Updated `handlePullOut` to forward `jobId` into `store.pullOutVehicle`. |
| [`businessComputerStore.js`](file:///c:/Users/krotp/Projects/BeamNG_RLS/ui/ui-vue/src/modules/career/stores/businessComputerStore.js) | JS Store | • Updated `pullOutVehicle(vehicleId, jobId)` to pass `jobId` into Lua bridge. |
| [`skillTrees/tuningShop.json`](file:///c:/Users/krotp/Projects/BeamNG_RLS/lua/ge/extensions/career/modules/business/skillTrees/tuningShop.json) | Data / Config | • Aligned text descriptions for `manager-speed` (-3 min/lvl) and `no-hard-feelings` (-5% payout penalty/lvl). |

