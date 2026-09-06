# RLS Career: Dirt Parent Skill & Multi-Stage Rally Event Overhaul

## TL;DR — What's New?

- **New "Dirt" Parent Skill Category**: Dedicated progression tree separating loose-surface racing from extreme technical off-roading.
- **Three Specialized Disciplines**:
  - 🌲 **Rally**: Point-to-point rally stages (e.g. `rally1` through `rally4`) and rally races. When multiple stages exist on a map, they are combined into a single unified rally tour.
  - 🏁 **Dirt**: Closed dirt circuits and dirt ovals (Quarry Circuit, Beach Circuit, Dirt Oval).
  - ⚡ **Rallycross**: Fast, technical dirt courses featuring jumps and washboards (Dirt Circuit, Rubberband Ridge).
- **Unified Multi-Stage Rally Event Tours**: Rather than scattering multiple stages across the contract board, contracts automatically unite all unique rally stages into a **single comprehensive rally event tour** spanning the entire map, with progressive in-race HUD tracking and a **+25% completion bonus** (while maintaining standard contract generation for standalone rally races or maps with individual stages).
- **100% Seamless Save Migration**: Existing career saves automatically migrate unlocked licenses and spent points without any loss. If you previously unlocked licenses for Rally under Off-Road, they are seamlessly transferred to Dirt with all points preserved.
- **Sandbox & Tuning Support**: Full integration with Career Start sandbox profiles (`economyAdjusterPolicy`, `xpAdjusterPolicy`, and `sandboxEconomyManifest`).

---

## Detailed Overview

### 1. Motivation & Design Philosophy

Previously in RLS Career and the FRE ecosystem, all off-tarmac events were lumped under a single generic **Off-Road** skill umbrella. This created several issues:

1. **Offer Board Clutter**: Rock crawling trials, high-speed rally sprints, mud drags, Ultra4 King of the Hammers, and dirt ovals competed for the exact same contract slots.
2. **Rally Lacked Identity**: Rally contracts generated as isolated, single-stage sprints. In real motorsport, rally is a multi-stage endurance test against the clock.
3. **Mismatched Event Types**: Closed dirt loops (like Quarry Circuit) and technical jump courses (like Dirt Circuit and Rubberband Ridge) behaved identically to Ultra4 rock tracks.

This overhaul introduces a clear separation between **Dirt Racing** (speed, agility, and loose-surface car handling) and **Off-Road** (rigs, extreme terrain, crawling, and mud).

---

### 2. The New Discipline Structure

#### 🌲 Parent Skill: **Dirt** (`careerSkills-dirt`)
Focuses on production, tuned, and rally-spec vehicles racing on gravel, dirt, and sand.

| Discipline | Description | West Coast USA Events | Objective Type | Format |
| :--- | :--- | :--- | :--- | :--- |
| **`rally`** | Point-to-point stages across natural terrain and rally races | `rally1`, `rally2`, `rally3`, `rally4` | Stage Time Targets / Best Time | **Multi-Stage Rally Tour** (unites all stages where possible; standalone events otherwise) |
| **`dirt`** | Closed dirt circuits and dirt ovals | `quarryCircuit`, `beachCircuit`, `dirtOval` | Laps (`laps`) | Standard Multi-Lap Circuit Racing |
| **`rallycross`** | High-speed dirt courses with jumps and washboard sections | `dirtCircuit`, `rubberBand` | Laps (`laps`) | Technical Mixed-Surface Sprint |

#### 🛞 Parent Skill: **Off-Road** (`careerSkills-offroad`)
Focuses on dedicated 4x4s, rock bouncers, crawlers, and heavy mud trucks.

| Discipline | Description | West Coast USA Events | Objective Type | Format |
| :--- | :--- | :--- | :--- | :--- |
| **`offroad`** | Heavy terrain, Ultra4, and extreme endurance | `koh1`, `koh2`, `toughTruckBeach` | Time / Position | Single Event Racing |
| **`crawling`** | Technical rock crawling and trial courses | `rockClimbS`, `rockClimbL` | Max Damage % | Damage-limited Trial Runs |
| **`mudding`** | Mud bogs and mud drag strips | `mudDrag1`, `mudDrag2` | Sprint Time | Straight-Line Mud Acceleration |

---

### 3. How the Multi-Stage Rally Tour Works

1. **Uniting Stages Where Possible**:
   When a contract offer is rolled for a rally stage, the generator inspects all unique point-to-point stages available on the map. If multiple stages exist, it automatically combines them into a unified multi-stage rally tour. If only a single stage or a standalone rally race is present, it generates as a standard contract.
2. **Dynamic Stage Progression**:
   - The contract displays the current stage in your phone and on the race HUD:
     - `Rally Event (4 Stages): Rally Stage 1`
     - Upon clearing Stage 1: `Rally Stage (2/4): Rally Stage 2`
     - Upon clearing Stage 2: `Rally Stage (3/4): Rally Stage 3`
     - ...and so on until the entire tour is completed.
   - The active target time dynamically updates to reflect the requirements of the *next* stage.
3. **Reward Multipliers**:
   - Because completing a full multi-stage tour requires consistency and vehicle preservation, clearing the entire rally event grants a **1.25x completion payout multiplier** on top of standard tier and vehicle bonuses.

---

### 4. Save Migration & License Reconciliation

A major priority of this feature was ensuring zero breakage for players with established Career saves:

- **2-Phase License Reconciliation** (`state.lua`):
  When loading a save file, the game collects all unlocked discipline licenses across all parent skills. It then assigns each license strictly to the parent skill that currently owns that lane according to configuration.
- **Automatic Point Rebalancing**:
  Because spent license points are computed dynamically from active licenses (`sum(tierRanks[license.tier])`), moving a discipline automatically deducts its spent points from the old parent skill and credits them to the new parent skill. No points are lost or double-counted.
- **Dedicated Dirt Parent Skill** (`dirt/info.json` & `playerAttributes.lua`):
  `careerSkills-dirt` possesses its own canonical attribute and 1-50 level progression tree. Discipline XP tags (`rally`, `dirt`, `rallycross`, `fre-rally`) route directly into `careerSkills-dirt`. For legacy saves, previous `fre-rally` progress is seamlessly migrated into `careerSkills-dirt`.

---

### 5. Modder & Map Creator Reference

To configure events on custom maps for these new disciplines, tag your courses in `levels/<map_name>/race_data.json`:

```json
"quarryCircuit": {
  "label": "Quarry Circuit",
  "type": ["dirt"],
  "hotlap": 35,
  "reward": 100
},
"dirtCircuit": {
  "label": "Dirt Circuit",
  "type": ["rallycross"],
  "hotlap": 66,
  "reward": 300
},
"stage1": {
  "label": "Rally Stage 1",
  "type": ["rally"],
  "bestTime": 120,
  "reward": 150
}
```

- Point-to-point stages tagged `["rally"]` automatically combine into the multi-stage Rally Tour whenever a map provides multiple stages. Standalone rally races and single stages remain fully supported as standard contracts.
- Events tagged `["dirt"]` or `["rallycross"]` generate multi-lap sprint contracts with lap-based rewards.
