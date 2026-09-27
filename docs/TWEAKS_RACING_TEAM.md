# RLS Career: Racing Team Overhaul — AI Driver Progression, Parallel Background Simulation & Operations Rebalance

## TL;DR — What's New?

- **No More Boring Spectator Grinds**: Eliminates the chore of sitting through slow, repetitive 3D spectator races where passive AI rarely overtakes and your driver is virtually guaranteed to lose. Hired drivers can now race autonomously in the background while you explore, tune, or run deliveries. Background races award prize money, deduct tiered driver cuts, credit team & driver XP, trigger sponsor milestones, accumulate real vehicle odometer mileage (0.5 mi/lap short, 1.4 mi/lap long), apply incident wear risk to parts on mistakes, and arm driver cooldowns.
- **Realistic 5-Car Stochastic Math Model**: Background races resolve dynamically using a physics-grounded math model accounting for vehicle power-to-weight, driver skill XP, track characteristics (short vs. long courses), starting grid traffic (+0.7s per car ahead), Gaussian lap variance, and driver mistake risks.
- **Manager Automation Tiers**:
  - **Level 1**: Unlocks manual **"Send with Manager"** dispatch for ready scheduled races. Auto-books idle drivers every 20 min with strict car-to-bracket matching.
  - **Level 2**: Unlocks autonomous **"Auto-start background races"**, custom booking intervals (5–60 min; default 5 min).
- **AI Driver Paradox Fix**: Driver XP now directly scales aggression, bravery, apex line precision, and late braking, and not punished with stronger AI, how it was done previously.
- **Rebalanced Driver Revenue Cuts (15%–35%)**: Replaced the legacy flat driver cut with a tiered structure based on experience (Tier 1: 15% up to Tier 5: 35%), making rookie drivers affordable and veteran drivers rewarding.
- **Experience XP on Every Race Finish**: Drivers no longer receive 0 XP when losing or finishing off the podium. Every completed race awards baseline track experience XP, ensuring drivers still learn without undermining podium incentives.
- **Player-Driving Penalty Rebalance (85% Net Purse)**: Slashed the punitive 75% team tax down to a fair **15% pit crew & team operations share** (awarding **85% net earnings** to the player/team account), paired with an authentic 15-minute driver fatigue cooldown.
- **Dyno Assessment & Certification System**: Replaced loose modification checks with an authoritative 3-state certification status (`Assessment Required`, `In Progress`, `Certified`). Teams with a Workshop Dyno certify instantly and free; without a dyno, vehicles can be assessed by third-party testing ($1,200, 5-minute timer) via the Vehicles tab. Modifying parts or tuning immediately drops vehicles back to `Assessment Required`.
- **Underdog Racing Support**: Eliminates punitive power-to-weight floor disqualifications. Vehicles below bracket minimums (`pw < pwMin`) are freely eligible to enter higher tiers.
- **Persistent Vehicle Fuel & Damage**: Putting away and pulling out garage vehicles now preserves fuel levels, mechanical wear, and body damage instead of resetting to fresh showroom condition.
- **Repair Lock for Damaged Cars**: Stored cars with damage display a red **Repair Required** badge and cannot be pulled out until repaired through insurance, preventing free repairs by putting cars away.

---

## Detailed Overview

### 1. Motivation & Core Problems Solved

The primary catalyst for this overhaul began with a simple, frustrating reality: **spectating every proxy race in real-time 3D was an enormous waste of time.**

The experience was fundamentally unrewarding. In-game AI racers in these sanctioned events behave timidly—braking excessively early, taking overly conservative lines, following each other in slow single-file trains, and almost never attempting overtakes. Because of this passive AI behavior combined with starting grid traffic, a player's hired driver had an **incredibly low chance to ever win or advance through the pack**. Forcing the player to physically load into 3D spectator mode and sit through lap after lap of a foregone, boring procession felt like an unproductive chore rather than an exciting motorsport enterprise.

Frustrated by this dynamic, digging deeper into *why* hired drivers were constantly losing and *why* spectating felt so broken revealed a rabbit hole of systemic design flaws, exposing that **the entire racing team game mechanic was fundamentally broken**:

1. **The Boredom Bottleneck (Forced 3D Spectating)**:
   Every single scheduled race demanded 100% of the player's presence. With no parallel resolution or background simulation, having a multi-driver roster brought the rest of the game to a dead halt. You couldn't work on customer cars in the tuning shop, run logistics, or drive in freeroam while your team raced.
2. **The AI Driver Paradox (Punished for Leveling Up)**:
   Investigating why hired drivers lost so consistently led directly into the codebase, uncovering a design flaw: **opponent AI vehicle power was mathematically scaled up with your own driver's XP**. Fresh rookie drivers faced slow, beatable opponents, whereas leveling up a driver and investing in their career matched them against stronger AI supercars. Training your driver actively doomed them to lose.
3. **The Player-Driving Penalty Trap**:
   When players inevitably grew tired of watching their AI driver lose and chose to take the wheel themselves, the game hit them with a punitive **75% "team tax" penalty**, pocketing three-quarters of the prize money despite the player doing 100% of the driving.
4. **A Broken Infrastructure & Perk Stack**:
   - The dyno could be accessed without unlocking its skill perk, while a double-dipping bug drained the team ledger with phantom daily overhead charges.
   - Purchasing Garage Slot perks (+1 vehicle capacity) cost substantial funds and XP but failed to increase the fleet vehicle cap.
   - Quick-travel fast recovery was completely non-functional upon unlock, failing to register the site.

What started as an effort to eliminate boring, uncompetitive spectator sessions revealed that most of the business mechanics were dysfunctional. This overhaul rebuilds the racing team from the ground up: introducing a parallel background simulation engine, interactive takeovers, physics-grounded AI math, inverted fair scaling, rebalanced financial shares, and robust business infrastructure.

---

### 2. Parallel Background Race Simulation Engine

#### 2.1 3-Phase State Machine
Background races resolve through a structured, multi-phase lifecycle managed by `../lua/ge/extensions/career/modules/business/racingTeamRaceSim.lua`:

```
[ Scheduled Race Ready ]
          │
          ▼  (Click "Send with Manager" or Level 2 Auto-Start)
┌────────────────────────────────────────────────────────┐
│  Phase 1: Driving to Race (150s / 2.5 min sim time)    │  <── Player can click "Manage myself"
│  Transit to the venue with live countdown & badge      │      to intercept & spectate in 3D!
└────────────────────────────────────────────────────────┘
          │
          ▼  (Transit completes)
┌────────────────────────────────────────────────────────┐
│  Phase 2: In Race (Dynamic Track & Lap Time)           │
│  80s/lap (Short Track) · 110s/lap (Long Course)        │
│  5-car stochastic math model & live progress bar       │
└────────────────────────────────────────────────────────┘
          │
          ▼  (Checkered flag)
┌────────────────────────────────────────────────────────┐
│  Phase 3: Driving from Race (150s / 2.5 min sim time)  │
│  Return commute to team garage                         │
└────────────────────────────────────────────────────────┘
          │
          ▼  (Arrival at HQ)
[ Post-Race Settlement: Banking, Cuts, XP, Odometer, Wear, Cooldown ]
```

#### 2.2 Interactive Transit Grace Period ("Manage Myself")
During **Phase 1 (`driving_to_race`)**, the driver is en route to the track. The Scheduled Races card displays a live countdown:
- The player can change their mind at any point during these 2.5 minutes and click **"Manage myself"**.
- Clicking **"Manage myself"** cleanly cancels the background simulation without penalizing the driver or forfeiting entry fees, smoothly staging the team car and launching the 3D spectator race.
- If the transit timer elapses without player intervention, the race seamlessly transitions into **Phase 2 (`in_race`)**.

#### 2.3 Single Concurrent Simulation Constraint
To prevent balance exploits and reflect realistic team logistics (1 manager and 1 track pit crew), a strict concurrency limit is enforced: **only 1 background race can be active at any time per racing business**. If a background race is already underway, other scheduled cards display a helpful tooltip: *"Manager is already supervising a race"*.

#### 2.4 Physics-Grounded 5-Car Stochastic Math Model
Background races resolve using a mathematically robust 5-car field simulation:
1. **Car Power Score ($S_{\text{car}}$)**: Evaluates the fleet vehicle's power-to-weight ratio against the class bracket limits ($\text{pwMin}$ to $\text{pwMax}$).
2. **Driver Skill Score ($S_{\text{driver}}$)**: Derived from driver XP ratio:
   $$S_{\text{driver}} = 0.20 + 0.80 \times \sqrt{\frac{\min(\text{XP}, 8000)}{8000}}$$
3. **Track Characteristic Weighting**:
   - **Short / Technical Courses**: 65% Driver Skill / 35% Vehicle Power.
   - **Long / High-Speed Tracks**: 40% Driver Skill / 60% Vehicle Power.
4. **Grid Draw & Traffic Penalties**: Starting grid slots (1 through 5) are drawn randomly. Cars starting deeper in the pack suffer a traffic penalty on Lap 1 ($+0.7\text{s}$ per car ahead).
5. **Gaussian Lap Variance & Mistakes**: Laps incorporate Box-Muller Gaussian noise ($\sigma = 1.6 - 1.35 \times \text{Rating}$). Drivers with lower XP have a higher mistake probability ($P_{\text{mistake}} = 0.18 - 0.16 \times \text{xpRatio}$), incurring a $2.0\text{s}$ to $4.5\text{s}$ time penalty if triggered.
6. **Realistic AI Competitors**: 4 distinct AI opponents are simulated alongside the player, including a designated top rival whose score closely tracks the upper league boundary.

#### 2.5 Post-Race Settlement Pipeline
When Phase 3 finishes, settlement executes automatically:
- **Prize Purse & Banking**: Credit first, second, or third place winnings into the team business account.
- **Driver Cut**: Deducts the hired driver's experience-scaled cut (15%–35%).
- **Sponsors & Goals**: Grants qualifying sponsor contract payouts, bonus XP, and team goal progress.
- **Driver & Team XP**: Awards full finishing and podium XP to both the driver and the racing business.
- **Odometer Accumulation**: Accumulates realistic distance onto the vehicle's odometer ($0.5\text{ mi/lap}$ for short tracks, $1.4\text{ mi/lap}$ for long tracks).
- **Incident Damage Risk**: If the driver suffered a race mistake, part condition integrity values have a chance of taking minor contact wear, encouraging vehicle maintenance.
- **Recovery Cooldown**: Arms driver fatigue cooldown (shortened by the *Reduced Cooldown* skill).
- **Silent HUD & Phone Notifications**: A clean smartphone lock-screen notification (`racingTeam.raceFinished`) delivers the driver's finish position, prize purse, and XP directly to the phone's notification drawer.

---

### 3. AI Driver Progression & Economy Rebalance

#### 3.1 Resolving the AI Driver Paradox
In legacy code, opponent AI power scaled with the player driver's XP. This created a paradoxical inverted difficulty curve where rookie drivers faced slow AI, while veteran drivers faced hyper-tuned rocketships.
- **Randomized Bracket Opponent Distribution**: Opponent vehicle power is now drawn randomly across the full sanctioned category bracket $[b_{\text{min}}, b_{\text{max}}]$, reflecting an authentic, varied motorsport field rather than artificial opponent handicaps.
- **XP-Driven AI Attributes**: Driver XP now dynamically enhances 3D spectator driving attributes:
  - **Aggression**: Scales smoothly from $0.88$ (rookie) to $1.20$ (elite).
  - **Traffic Overtaking & Line Precision**: Scales passing blend ($0.20$ to $0.85$), clearance scale, corner lift, throttle response, and late braking commitment. Elite drivers pass assertively and take sharper apex lines.

#### 3.2 Tiered Driver Revenue Cuts (15%–35%)
Hired driver cut percentages now scale realistically across 5 experience tiers:

| Driver Tier | Racing XP Range | Driver Cut (% of Prize) | Net to Team Account |
| :---: | :---: | :---: | :---: |
| **Tier 1 (Rookie)** | 0 – 399 XP | **15%** | **85%** |
| **Tier 2 (Club)** | 400 – 1,499 XP | **20%** | **80%** |
| **Tier 3 (Pro)** | 1,500 – 3,999 XP | **25%** | **75%** |
| **Tier 4 (Master)** | 4,000 – 7,999 XP | **30%** | **70%** |
| **Tier 5 (Legend)** | 8,000+ XP | **35%** | **65%** |

Rookies take minimal earnings while they learn; elite champions take higher cuts but deliver consistent podiums and championship points.

#### 3.3 Player-Driving Penalty Rebalance (85% Net Purse)
Previously, driving in a sanctioned race personally penalized the player with a 75% team tax.
- The penalty has been rebalanced to a sensible **15% pit crew & team operations share**.
- The player now receives **85% of the total prize purse** directly.
- A realistic **15-minute driver fatigue cooldown** applies after racing personally, preventing spam while keeping driver management valuable.
- All cuts and cooldowns are transparently displayed in UI tooltips, financial transaction ledgers, toasts, and in-game wiki guides.

#### 3.4 Race Experience & Non-Podium XP (No More 0 XP on Losses)
In legacy RLS Career, finishing off the podium (P4+) awarded exactly **0 XP** to both the proxy driver and the team. This punished player progression heavily, especially when drivers were developing:
- **Binary Half-Decay Track Experience XP**: Drivers still earn track experience for completing a race, but off-podium finishes decay exponentially ($2^{\max(2, \text{place}-2)}$) relative to the P3 podium baseline:
  - **P4 Finish**: **25.0%** of P3 podium XP (divisor 4, minimum 5 XP).
  - **P5 Finish**: **12.5%** of P3 podium XP (divisor 8, minimum 5 XP).
- **Sponsor Contract Multipliers**: Any active sponsor contract XP multiplier bonuses continue to apply to race experience earnings.
- **Unified Across Spectator & Background Modes**: Works identically whether you spectate the race in 3D or dispatch it in the background via the Manager.
- **Clear Milestone Feedback**: Toast notifications and post-race summaries celebrate driver learning milestones (e.g. *"P4 Finish (Driver Name): +30 XP gained from race experience."*).

---

### 4. Operations, Infrastructure & Quality of Life

#### 4.1 Dyno Skill Gating & Overhead Bug Fix
- **Skill Gate Enforced**: Access to vehicle dyno certification is now strictly gated behind unlocking the `dyno` node in the QOL skill tree.
- **Phantom Overhead Eliminated**: Fixed a bug where daily business overhead double-charged facility maintenance fees when the dyno was unlocked or under repair.

#### 4.2 Vehicle Dyno Assessment & Certification System (`dynoStatus`)
Vehicle certification uses an authoritative 3-state enum:
- **`-1` (Assessment Required)**: Newly bought vehicles (without an in-house workshop dyno) and any modified vehicle start in this uncertified state. Fleet cards display an orange `"Assessment Required"` badge and assign buttons are blocked.
- **`0` (In Progress / Assessing...)**: When the player clicks **"Assess Car ($1,200)"** on the Vehicles tab, $1,200 is debited from the team bank account and a 5-minute (300s sim time) third-party dyno assessment begins. A blue `"Assessing..."` badge appears on the car.
- **`1` (Dyno Certified)**: The assessment timer completes, registering peak horsepower and weight to certify the vehicle with a green `"Dyno Certified"` badge. If the team owns the Workshop Dyno skill perk (`dynoLevel > 0`), certification is **instant, automatic, and free** upon purchase or tuning.
- **Automatic Invalidation**: Whenever a certified vehicle undergoes any modification (parts installed via the business computer or career garage, or tuning sliders adjusted), its certification is immediately cleared back to `-1`, requiring re-assessment.

#### 4.3 Garage Slot Capacity Fix
Purchasing the `garageSlots` skill (+1 vehicle slot per level, max 2 levels) previously failed to increase the fleet vehicle limit. The inventory cap has been correctly bound to the skill level, allowing teams to expand their roster to 3 and 4 vehicles as intended.

#### 4.4 Quick-Travel Fast Recovery Fix
Unlocking the `quick-travel` skill node now properly registers the racing team facility on both:
1. The **Recovery Menu** (Quick Travel destinations).
2. The **Bigmap** fast-travel teleport nodes.

#### 4.5 Scrutineering Ceiling Enforcement & Underdog Racing Support
- **Ceiling-Only Scrutineering**: Scrutineering simply enforces that cars do not exceed the class power ceiling (`pwLive <= pwMax`).
- **Underdog Racing Support (`pw < pwMin`)**: Historically, entering a vehicle with power-to-weight below the category minimum was barred or disqualified. This punitive restriction has been eliminated. Underdog cars can freely enter higher tiers.

#### 4.6 Vehicle Fuel & Condition Persistence
Putting a vehicle away in the garage and pulling it back out previously restored the fuel tank to 100% and erased all physical and mechanical damage.
- **Full Condition Retention**: Stored vehicles now faithfully retain their exact fuel level, odometer mileage, engine wear, and body damage between storage and deployment.
- **Seamless Restoral**: Synchronized vehicle initialization ensures tanks and individual parts match their exact saved state upon spawning.

#### 4.7 Damaged Vehicle Pull-Out Lock & Repair Enforcement
Previously, players could bypass paying repair costs by simply putting away a wrecked car and pulling it back out.
- **Pull-Out Lock**: Any damaged fleet vehicle stored in the garage is locked from deployment until repaired.
- **Repair Required Badge**: Damaged stored vehicles display a red `"Repair Required"` badge on the Vehicles tab, and the Pull Out button is disabled with an explanatory tooltip.
- **Insurance Deductible Flow**: Players can click the dedicated **"Repair"** button to pay the standard insurance deductible ($750), instantly restoring the car and re-enabling deployment.

#### 4.8 Sanctioned Opponent Vehicle Bracket Matching
Previously, AI opponent vehicle models in sanctioned races could spawn from random or mismatched car pools, leading to improper vehicles competing in specialized leagues.
- **Bracket-Accurate Spawning**: Event category and horsepower bracket requirements are now directly enforced when selecting opponent cars.
- **Tier-Matched Grids**: AI rivals strictly spawn car models designated for the active race class, ensuring visually coherent and competitive racing grids.

---

### 5. Manager Automation Progression & UI Integration

#### 5.1 Manager Level Progression

| Skill Level | Features & Unlocks |
| :---: | :--- |
| **Level 1** | • Auto-books idle drivers into available sanctioned races every **20 minutes** with strict bracket matching.<br>• Unlocks manual **"Send with Manager"** button for ready scheduled races.<br>• Runs single concurrent background simulation with 2.5m transit grace period. |
| **Level 2** | • Configurable auto-assign intervals (**5m, 10m, 20m, 30m, 60m**; default 5m).<br>• Unlocks **"Auto-start background races"** toggle: automatically dispatches ready races into background simulation without manual clicks. |

#### 5.2 Frontend UI & Visual Polish
- **Scheduled Race Cards ([`RaceOfferBoardCard.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/RaceOfferBoardCard.vue))**:
  - Live animated gradient progress bar showing simulation elapsed percentage.
  - Informative status badges: `"Driving to race (2:15 remaining)"`, `"In Race (Lap 2/3)"`, `"Returning to HQ"`.
  - Three distinct CTA buttons: `"Manage myself"` (primary), `"Send with Manager"` (secondary highlight), and `"Drop out"` (secondary).
- **Manager Automation Panel ([`BusinessRacingTab.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/BusinessRacingTab.vue))**:
  - Dual toggles for `"Auto-assign sanctioned offers"` and `"Auto-start background races"`.
  - Interval selector pills (5m to 60m) for Level 2 managers.
- **Driver Roster Cards ([`BusinessDriversTab.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/BusinessDriversTab.vue))**:
  - Live progress container mirrors active background simulation status.
  - Fleet assignment locked while the driver is actively competing.

---

### 6. Summary of Modified & Added Files

| File | Type | Changes |
| :--- | :--- | :--- |
| [`racingTeamRaceSim.lua`](../lua/ge/extensions/career/modules/business/racingTeamRaceSim.lua) | **[NEW]** Logic | • 3-phase background race state machine (`driving_to_race`, `in_race`, `driving_from_race`).<br>• Stochastic 5-car math model with Gaussian lap variance and grid traffic delay.<br>• Full post-race settlement (purse, cuts, XP, goals, odometer accumulation, part wear).<br>• Silent HUD resolution: dispatches lock-screen phone notification (`racingTeam.raceFinished`) instead of screen pop-ups.<br>• 1 Hz throttled simulation ticker with zero per-frame allocations. |
| [`racingTeam.lua`](../lua/ge/extensions/career/modules/business/racingTeam.lua) | Lua Logic | • Required and integrated `racingTeamRaceSim`.<br>• Inverted AI opponent scaling to resolve the Driver Paradox; scaled bravery, aggression, and lines.<br>• Implemented 15%–35% tiered driver cuts and 85% player-driving purse rebalance.<br>• Added non-podium race experience XP with binary half-decay downscaling.<br>• Removed lower-tier vehicle penalties to reward underdog wins while providing strict bracket checking (`forceStrict`) for managers.<br>• Added Manager Lv 1 & Lv 2 helpers, eliminated global save frame stutters, and fixed auto-start toggle persistence.<br>• Enriched driver formatting payload with live simulation progress and badges.<br>• Implemented 3-state `dynoStatus` assessment tracking, invalidation on vehicle modifications, third-party assessment purchase flow, and background assessment timer ticking.<br>• Added player scheduled race tracking (`id = "player"`) for League 1 & 2+ with fee refunds on drop-out.<br>• Cleaned up dead functions (`buildOfferFromFactoryConfig`, `generateVehicleOffer`) and streamlined hot-loop guard checks. |
| [`racingTeamManager.lua`](../lua/ge/extensions/career/modules/business/racingTeamManager.lua) | Lua Logic | • Enforced strict vehicle bracket matching (`forceStrict = true`) for auto-assign across all manager levels.<br>• Rebalanced booking intervals: fixed 20 min for Lv 1; selectable 5m, 10m, 20m, 30m, 60m (default 5m) for Lv 2.<br>• Removed global `saveCurrent()` freeze on setting toggles in favor of direct module file saves.<br>• Normalized timer save path to `/career/rls_racing_team_manager_<id>.json` with backward-compatible legacy loading. |
| [`racing-team.js`](../ui/ui-vue/src/modules/career/apps/manifests/racing-team.js) | App Manifest | • Registered `racingTeam.raceFinished` notification channel in phone app manifest. |
| [`layout.lua`](../lua/ge/extensions/ui/phone/layout.lua) | Lua Bridge | • Mapped `racingTeam.raceFinished` to `racing-team` app in `NOTIFICATION_CHANNEL_APP_IDS`. |
| [`racingTeamRuntimeState.lua`](../lua/ge/extensions/career/modules/business/racingTeamRuntimeState.lua) | Lua Logic | • Added `autoStartBackgroundRacesByBusiness` runtime state tracking.<br>• Added dyno certification tracking tables (`dynoRequiredByBusiness`, `vehicleAssessmentInProgressByBusiness`). |
| [`businessComputer.lua`](../lua/ge/extensions/career/modules/business/businessComputer.lua) | Lua Bridge | • Exported `sendRacingTeamDriverWithManager`, `setRacingTeamAutoStartBackgroundRaces`, `cancelRacingTeamBackgroundRace`, and `startRacingTeamVehicleAssessment`.<br>• Added `pullOutVehicle` damage rejection guard (`errorCode = "repairRequired"`) when vehicle insurance indicates damage. |
| [`businessInventory.lua`](../lua/ge/extensions/career/modules/business/businessInventory.lua) | Lua Logic | • Deferred `applyPartConditionsForVehicle` to vehicle ready `'ping'` callback in `spawnBusinessVehicle`, ensuring complete vehicle VM initialization before applying part conditions. |
| [`businessPartConditions.lua`](../lua/ge/extensions/career/modules/business/businessPartConditions.lua) | Lua Logic | • Added `chosenPartName` key collection in `collectPartConditionKeysFromPartsTree`, preventing part conditions and energy storage data from being stripped during load sanitization. |
| [`racingTeamFinances.lua`](../lua/ge/extensions/career/modules/business/racingTeamFinances.lua) | Lua Logic | • Fixed dyno daily overhead double-charge bug.<br>• Formatted transparent financial transactions for driver cuts and pit crew shares. |
| [`racingTeamGoals.lua`](../lua/ge/extensions/career/modules/business/racingTeamGoals.lua) | Lua Logic | • Integrated background race completions into team goal tracking.<br>• Cleaned dead baseline HP helpers and simplified dyno peak HP notifications. |
| [`skillTrees/racingTeam.json`](../lua/ge/extensions/career/modules/business/skillTrees/racingTeam.json) | Data / Config | • Updated `manager` skill node descriptions for Lv 1 and Lv 2 background simulation powers. |
| [`sanctionedRacing.lua`](../lua/ge/extensions/gameplay/events/freContracts/sanctionedRacing.lua) | Lua Logic | • Rebalanced player-driving prize cut to 85% net (15% crew share).<br>• Applied 15-minute player recovery cooldown.<br>• Enforces clean class ceiling checks (`pwLive <= pwMax`).<br>• Added race abort and stage cleanup callbacks to clear player scheduled race state. |
| [`aiRacers.lua`](../lua/ge/extensions/gameplay/events/freeroam/aiRacers.lua) | Lua Logic | • Preserved bracket bounds for underdog players in 3D sanctioned races.<br>• Resolved opponent AI vehicle pools directly against the active category class bracket (`sanctionedSpawnCtx.hpBracketBranch`). |
| [`competitiveTrackFlow.lua`](../lua/ge/extensions/gameplay/events/freeroam/competitiveTrackFlow.lua) | Lua Logic | • Propagated sanctioned race category class context (`hpBracketBranch`) to `aiRacers` spawn context. |
| [`recoveryPrompt.lua`](../lua/ge/extensions/overrides/core/recoveryPrompt.lua) | Lua Override | • Registered racing team facility as a valid quick-travel destination upon skill unlock. |
| [`RaceOfferBoardCard.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/RaceOfferBoardCard.vue) | Vue Frontend | • Added animated progress bar track, progress fill, and simulation status badge.<br>• Added `"Send with Manager"` button between primary and secondary actions. |
| [`BusinessRacingTab.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/BusinessRacingTab.vue) | Vue Frontend | • Unified scheduled race layout via dynamic `<component :is="...">` wrapper.<br>• Precomputed presentation states in `driversWithScheduledRaces`.<br>• Consolidated race acceptance modal and toast handling into `handleRaceAcceptResult`.<br>• Added `"Auto-start background races"` toggle for Manager Lv 2.<br>• Wired `"Manage myself"` interception during transit grace period.<br>• Wired `"Send with Manager"` dispatch with tooltips and concurrency gating.<br>• Routed "Drive to Track" via centralized `store.driveToTrack`. |
| [`BusinessDriversTab.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/BusinessDriversTab.vue) | Vue Frontend | • Display live simulation progress container, badges, and phase status on driver cards.<br>• Locked fleet assignment while simulating. |
| [`BusinessVehiclesTab.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/BusinessVehiclesTab.vue) | Vue Frontend | • Integrated 3-state `dynoBadgeDisplay` badge rendering.<br>• Wired **"Assess Car ($1,200)"** action button for uncertified fleet vehicles.<br>• Added red "Repair Required" status badge, disabled Pull Out with explanatory tooltip for damaged vehicles, and added repair warning hint. |
| [`FleetAssignCard.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/FleetAssignCard.vue) | Vue Frontend | • Bound centralized `getDynoStatusBadge` computed for vehicle assignment badges and assign button disabling (`dynoStatus !== 1`). |
| [`HomeScheduledRacesWidget.vue`](../ui/ui-vue/src/modules/career/components/businessComputer/widgets/HomeScheduledRacesWidget.vue) | Vue Frontend | • Precomputed scheduled race meta strings and action buttons; wired player direct "Drive to Track" button to `store.driveToTrack`. |
| [`businessComputerStore.js`](../ui/ui-vue/src/modules/career/stores/businessComputerStore.js) | JS Store | • Added store actions `sendRacingTeamDriverWithManager`, `setRacingTeamAutoStartBackgroundRaces`, `cancelRacingTeamBackgroundRace`, and `startRacingTeamVehicleAssessment`.<br>• Enabled `"player"` driverId support in proxy race cancellation.<br>• Added centralized `driveToTrack` action that automatically pulls out stored assigned vehicles.<br>• Added user-facing warning toast handling for `repairRequired` error code. |
| [`businessUtils.js`](../ui/ui-vue/src/modules/career/utils/businessUtils.js) | JS Utility | • Added `getDynoStatusBadge` helper for `-1` (Assessment Required), `0` (Assessing...), and `1` (Dyno Certified).<br>• Added phase label formatting for `driving_to_race`, `in_race`, and `driving_from_race`. |
| [`guideWikiTopics.js`](../ui/ui-vue/src/modules/career/data/guideWikiTopics.js) | Data / Docs | • Updated `proxy-races-and-drivers`, `sponsors-finances-and-skills`, `sanctioned-races`, and `fleet-class-and-brackets` wiki entries with background simulation mechanics, transit grace period, manager progression, and underdog victory leniency. |
