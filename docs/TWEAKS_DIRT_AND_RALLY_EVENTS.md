# RLS Career: Dirt Skill, Multi-Stage Rally Event & Contract Balance Overhaul

## TL;DR — What's New?

- **New "Dirt" Parent Skill Category**: Dedicated 50-level progression tree separating loose-surface racing from technical off-roading.
- **Three Specialized Dirt Disciplines**:
  - 🌲 **Rally**: Point-to-point rally stages (`Rally Stage 1` through `Rally Stage 4`) and rally races. Automatically combined into unified multi-stage rally tours on maps with multiple stages.
  - 🏁 **Dirt**: Closed dirt circuits and dirt ovals (`Quarry Circuit`, `Beach Circuit`, `Dirt Oval`).
  - ⚡ **Rallycross**: High-speed mixed-surface courses featuring jumps and washboard sections (`Dirt Circuit`, `Rubberband`).
- **Unified Multi-Stage Rally Event Tours**: Rather than scattering multiple stages across the contract board, contracts automatically unite all unique rally stages into a **single comprehensive rally event tour** spanning the entire map, featuring progressive in-race HUD tracking, dynamic stage target updates, and a **+25% completion bonus**.
- **Single-Lap & Single-Stage Payout Fix**: Resolved a calculation bug where 1-lap or 1-stage contracts were slashed to only 33% of base pay. 1-unit contracts now correctly award 100% base rewards, with extra laps/stages adding +33% each.
- **Rebalanced FRE Contract PB Target Times**: Contract time objectives generated from player personal bests have been overhauled across all tiers to be fair, achievable, and competitive rather than requiring record-breaking runs.
- **Rebalanced Sponsor Durations & Upkeep**: Extended sponsor upkeep and probation windows to prevent premature contract drops during normal gameplay sessions.
- **Circuit Racing & Oval Retirement**: Relocated `Dirt Oval` to Dirt discipline and retired the legacy `Oval` discipline under Circuit Racing. Circuit Racing is now dedicated exclusively to paved closed courses (`Road Racing`) with smooth +4% level scaling and points capped at 3.
- **Off-Road Realignment**: Off-Road now cleanly focuses on 3 disciplines (`Offroad`, `Crawling`, `Mudding`) with +12% cycling bonuses and points capped at 9.
- **100% Seamless Save Migration**: Existing career saves automatically migrate unlocked licenses and spent points without any loss. Points from retired or moved disciplines are automatically credited back to the player.

---

## Detailed Overview

### 1. Motivation & Design Philosophy

Previously in RLS Career and the FRE ecosystem, all off-tarmac events were lumped under a single generic **Off-Road** skill umbrella. This created several issues:

1. **Offer Board Clutter**: Rock crawling trials, high-speed rally sprints, mud drags, Ultra4 races, and dirt ovals competed for the exact same contract slots.
2. **Rally Lacked Identity**: Rally contracts generated as isolated, single-stage sprints. In real motorsport, rally is a multi-stage endurance test against the clock.
3. **Mismatched Event Types**: Closed dirt loops (like Quarry Circuit) and technical jump courses (like Dirt Circuit and Rubberband Ridge) behaved identically to Ultra4 rock tracks.
4. **Punishing Contract Target Times**: Time-target contracts derived from personal bests (PBs) required beating or matching near-impossible record times even on Medium tiers.
5. **Severely Undervalued Single-Unit Contracts**: Single-lap and single-stage contracts suffered from a formula bug that slashed their base money and XP payouts down to a fraction of intended value.

This overhaul introduces a clear separation between **Dirt Racing** (speed, agility, and loose-surface car handling) and **Off-Road** (rigs, extreme terrain, crawling, and mud), while rebalancing contract generation and economy scaling across the entire game.

---

### 2. The New Discipline Structure

#### 🌲 Parent Skill: **Dirt** (`careerSkills-dirt`)
Focuses on production, tuned, and rally-spec vehicles racing on gravel, dirt, and sand.

| Discipline | Description | West Coast Events | Format |
| :--- | :--- | :--- | :--- |
| **`Rally`** | Point-to-point stages across natural terrain and rally races | `rally1`, `rally2`, `rally3`, `rally4` | **Multi-Stage Rally Tour** (unites all stages where possible; standalone events otherwise) |
| **`Dirt`** | Closed dirt circuits and dirt ovals | `quarryCircuit`, `beachCircuit`, `dirtOval` | Standard Multi-Lap Circuit Racing |
| **`Rallycross`** | High-speed dirt courses with jumps and washboard sections | `dirtCircuit`, `rubberBand` | Technical Mixed-Surface Sprint |

#### 🛞 Parent Skill: **Off-Road** (`careerSkills-offroad`)
Focuses on dedicated 4x4s, rock bouncers, crawlers, and heavy mud trucks.

| Discipline | Description | West Coast USA Events | Format |
| :--- | :--- | :--- | :--- |
| **`Offroad`** | Heavy terrain, Ultra4, and extreme endurance | `koh1`, `koh2`, `toughTruckBeach` | Single Event Racing |
| **`Crawling`** | Technical rock crawling and trial courses | `rockClimbS`, `rockClimbL` | Damage-limited Trial Runs |
| **`Mudding`** | Mud bogs and mud drag strips | `mudDrag1`, `mudDrag2` | Straight-Line Mud Acceleration |

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

### 4. Economy, Contract & Target Time Rebalance

#### 4.1 Single-Lap & Single-Stage Payout Fix (`offers.lua`)
In previous versions, contract rewards scaled via:
$$\text{lapEventMult} = \max(1, \text{requiredCount}) \times \text{extraLapEventBonusPerUnit}$$

With `extraLapEventBonusPerUnit = 0.33`, any contract requiring only **1 lap** or **1 stage** was evaluated as $1 \times 0.33 = 0.33$, slashing the payout to **33%** of its intended base reward.

This was corrected to:
$$\text{lapEventMult} = 1.0 + (\max(1, \text{requiredCount}) - 1) \times \text{extraLapEventBonusPerUnit}$$

* **1-lap / 1-stage events**: Payout multiplier is now **$1.0\times$** (100% full base reward).
* **2-lap / 2-stage events**: Payout multiplier is **$1.33\times$** (+33%).
* **3-lap / 3-stage events**: Payout multiplier is **$1.66\times$** (+66%).

#### 4.2 Rebalanced PB Target Times (`freProgression.config.json`)
Previously, contract time targets calculated from a player's Personal Best (`contractPbTimeMultipliersByTier`) were excessively harsh, frequently forcing players to beat their all-time record just to pass an Easy or Medium contract. The multipliers have been rebalanced:

| Tier | Old PB Multiplier | New PB Multiplier | Impact |
| :--- | :--- | :--- | :--- |
| **Easy** | `1.025` – `1.100` | `1.040` – `1.100` | Gives a comfortable 4%–10% margin over PB for accessible contract completion. |
| **Medium** | `0.975` – `1.025` | `1.015` – `1.040` | Requires clean, competent driving within 1.5%–4% of PB without forcing record-breaking runs. |
| **Hard** | `0.925` – `0.975` | `0.995` – `1.015` | Highly competitive benchmark right around the player's personal best (0.5% faster to 1.5% slower) rather than demanding an impossible 7.5% improvement. |

#### 4.3 Rebalanced Sponsor Durations & Cooldowns
To prevent active sponsors from lapsing or warning prematurely during play sessions where players want to do some other activities in between:
* **Upkeep Durations**:
  - Easy: extended from 60 min $\rightarrow$ **150 min**.
  - Medium: extended from 45 min $\rightarrow$ **120 min**.
  - Hard: extended from 30 min $\rightarrow$ **90 min**.
  - Master: extended from 30 min $\rightarrow$ **60 min**.
* **Probation Windows**: Extended from 30 min $\rightarrow$ **60 min** (Master: 15 min $\rightarrow$ **30 min**).
* **Grace Period**: Extended from 5 min $\rightarrow$ **15 min**.
* **Dropped Slot Cooldown**: Reduced from 15 min $\rightarrow$ **3 min** to minimize downtime when swapping sponsors.

---

### 5. Parent Skill Progression & License Caps

In the FRE system, bonuses and license caps scale strictly with the number of active lanes ($\#\text{lanes}$):
* **Reward Bonus per Level**: $\text{bonusPerOccurrence} = 0.04 \times \#\text{lanes}$
* **Max License Points**: $\text{maxPoints} = \#\text{lanes} \times 3$ (each discipline has Easy, Medium, Hard tiers)

| Parent Skill | Active Lanes | Bonus per Level | Max License Points | Milestone Cap Level |
| :--- | :--- | :--- | :--- | :--- |
| **Dirt** | `rally`, `dirt`, `rallycross` (3) | **+12%** (cycling Rally $\rightarrow$ Dirt $\rightarrow$ Rallycross) | **9 points** | Level 35 |
| **Off-Road** | `offroad`, `crawling`, `mudding` (3) | **+12%** (cycling Off-Road $\rightarrow$ Crawling $\rightarrow$ Mudding) | **9 points** | Level 35 |
| **Speed** | `drag`, `landspeed` (2) | **+8%** (cycling Drag $\rightarrow$ Top Speed) | **6 points** | Level 25 |
| **Mayhem** | `drift`, `burnout`, `demo` (3) | **+12%** (cycling Drift $\rightarrow$ Burnout $\rightarrow$ Demo) | **9 points** | Level 35 |
| **Circuit Racing** | `roadracing` (1) | **+4%** (Road Racing at every level) | **3 points** | Level 15 |

All display files (`dirt/info.json`, `circuitRacing/info.json`, `offroad/info.json`) have been matched 1:1 to these formulas and caps.

---

### 6. Save Migration & License Reconciliation

A major priority of this feature was ensuring zero breakage for players with established Career saves:

- **2-Phase License Reconciliation** (`state.lua`):
  When loading a save file, the game collects all unlocked discipline licenses across all parent skills. It then assigns each license strictly to the parent skill that currently owns that lane according to configuration.
- **Automatic Point Rebalancing**:
  Because spent license points are computed dynamically from active licenses (`sum(tierRanks[license.tier])`), moving a discipline automatically deducts its spent points from the old parent skill and credits them to the new parent skill. No points are lost or double-counted.
- **Dedicated Dirt Parent Skill** (`dirt/info.json` & `playerAttributes.lua`):
  `careerSkills-dirt` possesses its own canonical attribute and 1-50 level progression tree. Discipline XP tags (`rally`, `dirt`, `rallycross`, `fre-rally`, `fre-dirt`, `fre-rallycross`, `dirtOval`) route directly into `careerSkills-dirt`. For legacy saves, previous `fre-rally` and `fre-oval` progress is seamlessly migrated into `careerSkills-dirt`.
- **Retirement of Oval from Circuit Racing**:
  With `dirtOval` grouped under the `dirt` discipline, `oval` under Circuit Racing has been retired (`placeholderOnly = true`, `legacyOnly = true`) and removed from `circuitRacing.laneIds`. Circuit Racing now features Road Racing (`roadracing`) as its primary lane (+4% payout bonus per level up to +200% at level 50). Any existing spent license points in Oval are automatically refunded to Circuit Racing upon save load.

---

### 7. Modder & Map Creator Reference

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
