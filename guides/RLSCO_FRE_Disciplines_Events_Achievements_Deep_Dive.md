# RLSCO FRE Deep Dive

## Scope
This document is a full deep dive for:

- FRE disciplines and progression.
- FRE freeroam events integration.
- Contracts and sponsors lifecycle.
- Sanctioned racing flow.
- Achievements/levels behavior and milestone unlocks.
- Map-level dependencies.

Primary sources reviewed:

- `gameplay/fre/freProgression.config.json`
- `lua/ge/extensions/gameplay/fre/config.lua`
- `lua/ge/extensions/gameplay/events/freContracts.lua`
- `lua/ge/extensions/gameplay/events/freContracts/*.lua`
- `lua/ge/extensions/gameplay/events/freeroamEvents.lua`
- `lua/ge/extensions/gameplay/events/freeroam/raceSession.lua`
- `lua/ge/extensions/ui/phone/freContracts.lua`
- `ui-vue-src/modules/career/views/PhoneFreContracts.vue`
- `gameplay/domains/careerSkills/skills/*/info.json`
- `levels/west_coast_usa/competitiveRace/aiRacingConfig.json`

## 1) FRE System Topology

At runtime, the FRE ecosystem is coordinated by `gameplay_events_freContracts`:

1. Loads module set under `gameplay/events/freContracts/`.
2. Loads persistent state from `/career/fre/freContractsSponsors.json`.
3. Builds race cache from level `race_data.json`.
4. Purges expired entries, syncs offers, syncs sanctioned generation.
5. Schedules next maintenance tick using nearest expiry/checkpoint/offer time.

Core modules and responsibilities:

- `state.lua`: persistent state, sim-time clock, next maintenance scheduling.
- `skills.lua`: skill level/progress lookup and tier/slot/offer-cap computations.
- `raceCache.lua`: race indexing by discipline, target building, route handling.
- `vehiclePool.lua`: contract vehicle selection and model validation.
- `offers.lua`: contract/sponsor offer generation, normalization, expiry handling.
- `actions.lua`: accept/abandon/sign/drop/acknowledge actions.
- `race.lua`: sponsor bonus math, reward multipliers, contract/sponsor progression on race completion.
- `sanctionedRacing.lua`: sanctioned offer generation, commit/navigate/reschedule, podium settlement.
- `ui.lua`: UI state snapshot + live push payloads.

## 2) Discipline Model

Defined in `gameplay/fre/freProgression.config.json`:

- crawling (`fre-crawling`)
- roadracing (`fre-roadracing`)
- drift (`fre-drift`)
- drag (`fre-drag`)
- trail (`fre-trail`, placeholderOnly=true)
- oval (`fre-oval`)
- offroad (`fre-offroad`)
- rally (`fre-rally`)
- landspeed (`fre-landspeed`, placeholderOnly=true)
- mudding (`fre-mudding`)

Notes:

- `roadracing` has `sanctionedRacingUnlockLevel = 15`.
- `trail` and `landspeed` are explicitly marked placeholder-only in FRE config.
- `fre/config.lua` supports alias mapping so race type strings resolve to discipline IDs.

## 3) Leveling and Reward Scaling

Global scaling in progression config:

- `levelPercentPerLevelUp = 0.02`
- `maxLevel = 50`
- `sponsorBonusCap = 2.0`

In `freContracts/race.lua`, effective multipliers per discipline are:

- `skillMultiplier = 1 + (effectiveLevel - 1) * levelPercentPerLevelUp`
- `xpMultiplier = skillMultiplier * (1 + sponsorXpBonus)`
- `moneyMultiplier = skillMultiplier * (1 + sponsorMoneyBonus)`

Where sponsor bonuses are summed from active sponsors and capped by `sponsorBonusCap`.

For races tagged with multiple disciplines, overall money multiplier is averaged across those disciplines.

## 4) Tier and Unlock Logic

### Contract tiers
- Easy unlock: level 5
- Medium unlock: level 20
- Hard unlock: level 35

### Sponsor tiers
- Easy unlock: level 10
- Medium unlock: level 25
- Hard unlock: level 40

### Offer counts and slots
Contracts (`contracts` config):
- Base offers: 3
- +2 offers at levels 12, 27, 42
- Slots: base 2 at level 5, +1 slot at levels 14, 29, 44

Sponsors (`sponsors` config):
- Base offers: 3
- +2 offers at levels 16, 31, 46
- Slots: base 2 at level 10, +1 slot at levels 18, 33, 48

## 5) FRE XP Curves

XP is curve-driven via `skills.calculateXpFromTierCurve`.

Inputs per tier include:

- `xpAtTarget`
- `tenPercentBetterMultiplier`
- `belowTargetFloorMultiplier`
- `maxMultiplier`

Formula behavior:

- `normalizedPerformance = ratio of actual performance vs target`
- `exponent = (normalizedPerformance - 1.0) / 0.1`
- `rawMultiplier = tenPercentBetterMultiplier ^ exponent`
- multiplier is clamped to floor/cap
- final XP is `floor(xpAtTarget * clampedMultiplier)`

Current event XP base in JSON is `xpAtTarget = 100` for easy/medium/hard across disciplines.
Contract tier XP-at-target values are higher (`375 / 750 / 1750` in current JSON).

## 6) Target Type Semantics by Discipline

From `raceCache.lua` and `offers.lua` target generation behavior:

- Drift discipline with drift-goal races uses `targetType = driftScore`.
- Crawling and trail use `targetType = maxDamagePct`.
- Most other disciplines use `targetType = time`.

Target generation references race cache entries and tier multiplier ranges.
Route type (`main` vs `alt`) is normalized and preserved on entries.

## 7) Contract Offer Lifecycle

### Generation pipeline (`offers.lua`)

1. Determine unlocked contract tiers from current discipline level.
2. Pull race candidates from discipline race cache.
3. Pick required vehicle model from `vehiclePool`:
   - pools: experienced owned, other owned, random
   - pick weights default: `0.5 / 0.3 / 0.2`
   - reward multipliers default: `1 / 1 / 1.25`
4. Build target:
   - may use player PB time for time-based contracts
   - otherwise target built from tier range.
5. Choose objective:
   - `laps` for loopable races
   - `events` for non-loop races
   - count computed from configured time window.
6. Compute preview rewards and expiry.

### Objective count model

- Uses `timeWindowMinutesByTier` and estimated sec/unit.
- Non-loop events add travel overhead via `nonLoopEventTimeMultiplier` (default 1.66).
- Crawling and damage-target flows can use explicit `eventCountOverrideByTier`.

### Reward preview model

`rawMoney` is influenced by:

- race reward at target,
- tier base payout multiplier (`easy=10, medium=15, hard=25`),
- count scaling (`extraLapEventBonusPerUnit`),
- payout variance,
- vehicle source multiplier,
- FRE discipline money modifier.

`rawXp` then uses `xpPercentOfMoney` (default 0.5) and FRE XP modifier.

### Acceptance and validity checks (`actions.lua`)

Contract acceptance is blocked when freeroam event session state is active/staged/drag-practice.
Additional checks:

- offer not expired,
- required model valid and allowed,
- slot capacity available.

Accepted contracts move from `available` to `active` and get tier-based TTL.

### Expiration and failure

- Available offers expire and are removed.
- Active contracts expire and increment failure counter.
- Maintenance loop repopulates offers up to cap based on refresh timing.

## 8) Sponsor Offer Lifecycle

### Generation

- Tier unlocked by level.
- Requirement is generated from discipline race cache + tier target.
- Bonus type weighted random:
  - money: 0.47
  - disciplineXP: 0.47
  - both: 0.06
- Bonus percent sampled by tier range:
  - easy: 1%-10%
  - medium: 10%-18%
  - hard: 15%-30%

### Signing and upkeep

On sign, sponsor enters active list with `nextCheckAt` from tier upkeep:

- easy: 180 min
- medium: 120 min
- hard: 60 min

Qualification requirement: complete required race/route and satisfy target once per upkeep window.

### Warning/drop behavior

If upkeep check fails:

1. first miss: warning issued, grace timer starts (`graceMinutes`, default 20).
2. miss again after warning: sponsor dropped and dropped counter increments.

## 9) Race Runtime Integration (Freeroam -> FRE Progress)

`freeroamEvents.lua` and `raceSession.lua` drive race completion and payout.

Key sequence:

1. Race payout computed by event type (time/drift/topSpeed/hybrid damage).
2. Normalized performance ratio is computed for FRE XP curve.
3. FRE money/xp multipliers are applied.
4. Rewards paid via career payment/bank channels.
5. `gameplay_events_freContracts_race.onFreeroamRaceCompleted` receives completion payload.
6. Contract/sponsor progress updates are applied if valid and not skipped.

Important gates:

- Invalid laps do not progress contracts/sponsors.
- Route and required model must match contract requirements.
- Skip flags can suppress FRE contract progress in certain sanctioned contexts.

## 10) Sanctioned Racing Deep Dive

Sanctioned racing is a road racing-specific flow managed by `sanctionedRacing.lua`.

### Unlock and availability

- Unlock level: Road Racing level 15.
- Requires map sanctioned entries in `levels/<level>/competitiveRace/aiRacingConfig.json`.

Current observed map config:

- `levels/west_coast_usa/competitiveRace/aiRacingConfig.json`
- Sanctioned entries for `track` main and alt routes.
- Offer refresh: 20 minutes.
- Start deadline: 60 minutes.

### Offer content

Offer includes:

- race and route,
- stage number,
- HP bracket and class cap,
- randomized lap count,
- podium payouts (1st/2nd/3rd) and derived XP.

Class payout multipliers baseline:

- stock: 1.00
- modified: 1.35
- super: 1.85
- open: 2.35

Podium payout defaults:

- first: 8x
- second: 4.5x
- third: 2.5x

### State machine

`available -> committed -> racing -> cleared`

Actions:

- Commit from phone.
- Navigate to race (dispatch/staging integration).
- Reschedule while committed.
- Auto-clear on deadline miss, abort, or race settlement.

### Payout model and suppression

During sanctioned runs:

- standard lap/practice FRE payouts are suppressed,
- podium settlement determines final sanctioned payout,
- no-podium or over-power-cap conditions can produce no reward.

Result rewards are surfaced back into freeroam completion presentation.

## 11) Phone UX and API Surface

### Backend phone API (`ui/phone/freContracts.lua`)

Exposes:

- `getState`
- `startLiveUpdates` / `stopLiveUpdates`
- `acceptContract`, `abandonContract`
- `signSponsor`, `dropSponsor`, `acknowledgeSponsorWarning`
- `commitSanctionedRace`, `navigateSanctionedRace`, `rescheduleSanctionedRace`

### Frontend phone view (`PhoneFreContracts.vue`)

- Three tabs: Contracts, Sponsors, Racing (conditional for road racing unlock).
- Discipline filter and per-discipline summary cards.
- Live push updates via `phoneFreContractsData` event.
- Countdown and urgency labels computed client-side from server times.
- Racing tab presents available/next sanctioned offer cards and podium preview.

## 12) Achievements and Level Cards

FRE discipline skill cards live in:

- `gameplay/domains/careerSkills/skills/<discipline>/info.json`

All inspected FRE disciplines are 1-50 tracks with unlock cards.

Observed common milestone pattern across disciplines:

- L5: Easy contracts + 2 contract slots
- L10: Easy sponsors + 2 sponsor slots
- L12: Contract offers +2
- L14: +1 contract slot
- L16: Sponsor offers +2
- L18: +1 sponsor slot
- L20: Medium contracts
- L25: Medium sponsors
- L27: Contract offers +2
- L29: +1 contract slot
- L31: Sponsor offers +2
- L33: +1 sponsor slot
- L35: Hard contracts
- L40: Hard sponsors
- L42: Contract offers +2
- L44: +1 contract slot
- L46: Sponsor offers +2
- L48: +1 sponsor slot

Road Racing has one unique extra card:

- L15: Sanctioned Racing unlock card, describing phone-sanctioned AI circuit races and podium-purse behavior.

Important implementation note:

- Hard enforcement uses FRE config and code (`skills.lua`, `offers.lua`, `actions.lua`).
- Skill unlock cards are user-facing descriptions and can drift if not kept in sync.

## 13) Map/Level Dependencies

FRE contract/sponsor generation depends on level race data:

- `levels/<level>/race_data.json` must provide races and type metadata.

Sanctioned racing additionally depends on:

- `levels/<level>/competitiveRace/aiRacingConfig.json` with `sanctioned` blocks.

Without map config support, sanctioned generation for that level returns no offers.

## 14) Key Observations and Risks

1. FRE is strongly data-driven and scalable, but invalid/missing race data can silently reduce offer generation.
2. Contract/sponsor progression uses route matching; inconsistent route labels can create edge cases.
3. Placeholder disciplines (`trail`, `landspeed`) are marked in config but still have full 1-50 skill tracks; this is useful but can confuse release readiness.
4. Sanctioned racing is currently map-dependent and appears effectively configured for West Coast track flows.
5. Card text and runtime unlock math are separate sources of truth; regression checks should compare them.

## 15) Practical Validation Checklist

Use this checklist when validating FRE changes:

1. Verify discipline unlock thresholds at levels 5/10/20/25/35/40.
2. Verify offer caps and slot caps at milestone levels (12/14/16/18/27/29/31/33/42/44/46/48).
3. Verify target types by discipline (time, drift score, max damage).
4. Verify contract progress respects route/model and ignores invalid laps.
5. Verify sponsor warning and grace drop behavior.
6. Verify sanctioned level 15 unlock in Road Racing and phone Racing tab visibility.
7. Verify sanctioned payout suppression and podium-only settlement behavior.
8. Verify save/load durability from `/career/fre/freContractsSponsors.json` across reload.

## Summary
FRE in RLSCO is a complete progression subsystem with mature contract/sponsor generation, discipline-aware reward scaling, map-aware sanctioned race orchestration, and dedicated phone UX. The achievements-level layer mirrors this system with 1-50 skill tracks and milestone cards, with Road Racing uniquely extending into sanctioned racing at level 15.
