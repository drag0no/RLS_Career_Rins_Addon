# RLSCO Demo Derby - Full Deep Integration Plan (No Code Yet)

## 1) Your Confirmed Product Decisions

This plan is based on your answers:

- Demo progression should be fully active now.
- Demo contracts and sponsors should be active in progression schema now.
- Rewards should include both money and XP.
- Rewards should be placement-based.
- Rewards should only be given to top 50% placements.
- Stationary elimination should not have reduced rewards compared to other elimination reasons.
- Demo should appear in Phone Events now.
- System should be map-agnostic so map owners can add demo events on their own maps.
- A map-owner guide is required.

## 2) Clarification: What Fully Active Progression Means

For demo discipline, fully active progression means:

1. Demo is a real progression discipline, not placeholder-only.
2. Demo has its own level curve and XP progression from level 1 to 50.
3. Demo has its own achievement and milestone cards in career skills UI.
4. Demo event results can award money and demo XP into player progression.
5. Demo can be shown/discovered in game UX (Phone Events and related surfaces).
6. Demo behavior works as a first-class feature with contracts and sponsors enabled.

In short:
- Fully active progression now includes contracts and sponsors for demo.
- It requires that leveling, rewards, achievements, and discipline economy systems are real and live.

## 3) Milestone Cadence Explanation

### A) Existing FRE cadence style
Current FRE skills (crawling, roadracing, etc.) generally follow repeated milestone rhythm:
- L5: contract unlock start
- L10: sponsor unlock start
- L12/L14: contract offer and slot expansions
- L16/L18: sponsor offer and slot expansions
- L20/L25/L35/L40 and later repeats

This cadence is tightly tied to contracts and sponsors.

### B) Custom demo cadence style
For demo with no contracts and sponsors, custom cadence is cleaner:
- keep level bonuses every level (or every 1 to 2 levels)
- replace contract and sponsor milestone cards with demo-specific milestones
- examples:
  - elimination consistency milestones
  - placement consistency milestones
  - map participation milestones
  - derby mastery tiers

### Recommendation
Use existing FRE cadence now (Option A).
Reason:
- It keeps demo milestones aligned with all other disciplines.
- It matches your decision to enable contracts and sponsors immediately.
- It lowers maintenance cost by preserving existing progression rhythm.

## 4) Target Architecture Outcome

After implementation, demo should have:

1. Demo discipline in primary progression schema file.
2. Demo alias mapping in schema file aligned with Lua defaults.
3. Demo skill file with 1 to 50 cards following existing FRE contract/sponsor cadence.
4. Derby result settlement that writes money and demo XP.
5. Top-50% reward eligibility logic.
6. Phone Events discoverability path for demo entries.
7. Map-agnostic event loading path for any map with demo config files.
8. Guide docs for map owners.

## 5) Execution Plan (Phased)

## Phase 1 - Foundation and Schema
Goal: make demo a first-class progression discipline.

Planned changes:
- Add demo discipline block to gameplay/fre/freProgression.config.json.
- Add demo and demolition aliases in gameplay/fre/freProgression.config.json typeAliasMap.
- Set demo placeholderOnly to false for active progression.
- Keep demo contracts and sponsors enabled with standard FRE tier unlock behavior.
- Keep compatibility with future contracts and sponsors by preserving schema shape.

Acceptance criteria:
- Demo discipline resolves consistently from both config and runtime alias mapping.
- No missing-discipline fallback paths for demo in FRE calculations.

## Phase 2 - Achievements, Levels, and Milestones
Goal: create full demo 1 to 50 progression cards.

Planned changes:
- Add gameplay/domains/careerSkills/skills/demo/info.json.
- Define attributeKey as fre-demo.
- Add level cards from 1 to 50.
- Use Option A milestone cadence (contracts and sponsors milestones in existing FRE rhythm).

Recommended milestone rhythm for Option A cadence:
- L5: contracts unlock and base contract slots.
- L10: sponsors unlock and base sponsor slots.
- L12/L14 and L27/L29 and L42/L44: contract offer/slot cadence.
- L16/L18 and L31/L33 and L46/L48: sponsor offer/slot cadence.
- Standard per-level bonus progression remains intact through level 50.

Acceptance criteria:
- Demo appears in Skills UI with complete level card sequence.
- Card text follows existing FRE contracts/sponsors milestone language.

## Phase 3 - Derby Reward and Progression Wiring
Goal: connect end-of-match derby outcomes to money and demo XP progression.

Planned changes:
- Wire derby end event path to career reward system.
- Compute placement and participant count reliably.
- Apply top-50% eligibility rule.
- Award both money and fre-demo XP for eligible placements.
- Keep stationary elimination reward treatment same as other elimination outcomes.
- Save and surface result feedback in existing FRE UX style.

Top-50% rule recommendation:
- Eligible if placement <= ceil(totalParticipants * 0.5).
- This guarantees at least half are eligible when count is odd.

Placement reward model recommendation (example shape):
- Determine base reward pool per event config.
- Apply placement multiplier.
- Apply same multiplier logic to both money and XP or separate tables.
- Non-eligible placements receive zero reward and explicit feedback message.

Acceptance criteria:
- Eligible top half gets both money and demo XP.
- Bottom half gets no reward.
- Reward output appears clearly in HUD/summary and persists.

## Phase 4 - Contracts and Sponsors Active
Goal: make demo participate in full FRE progression economy.

Planned changes:
- Ensure demo contract and sponsor paths are enabled and exposed when unlocked.
- Ensure demo sponsor and contract offers can be generated using existing systems.
- Ensure skill cards and UI milestones align with active contract/sponsor behavior.

Acceptance criteria:
- Demo contract and sponsor offers generate without schema errors.
- No broken references in FRE contract/sponsor UI for demo discipline.

## Phase 5 - UX and Discoverability (Phone Events)
Goal: demo event is visible and navigable from phone events immediately.

Planned changes:
- Add demo event metadata source compatible with Phone Events flow.
- Ensure event appears with label, thumbnail fallback, distance, and route action.
- Ensure map filtering and sorting behave correctly with demo type.
- Keep staging trigger integration unchanged unless needed.

Acceptance criteria:
- Demo event appears in Phone Events list and map view.
- Route navigation action works.
- No regression in existing event types.

## Phase 6 - Map-Agnostic Support
Goal: any map owner can add demo events with config and site files.

Planned changes:
- Keep core loader map-relative using current level identifier.
- Validate per-map config presence and fail gracefully.
- Support multiple demo events per map through event key naming pattern.

Acceptance criteria:
- New map with valid files can host demo event without core code duplication.
- Missing files produce clean warnings, not hard failures.

## Phase 7 - Documentation and Release Hygiene
Goal: provide production-grade docs and onboarding.

Planned docs output:
1. Internal implementation notes for maintainers.
2. Public map-owner guide with full setup steps.
3. Troubleshooting matrix for common setup mistakes.

Acceptance criteria:
- Map owner can follow guide and add at least one working demo event.

## 6) Map Owner Guide (Planned Full Guide Content)

This is the planned guide structure for map owners.

## Purpose
Allow any map owner to add a demolition derby event using map-local files.

## Required map files
Per map level folder:
- demo.config.json
- demolition.sites.json

## Event key and trigger convention
- Use freeroam staging trigger naming so event key is discoverable.
- Expected pattern for custom event key suffix:
  - fre_staging_demo_<suffix>
- Example:
  - fre_staging_demo_dirt resolves event key demo_dirt.

## demo.config.json responsibilities
- Define defaults shared across demo events.
- Define per-event block with:
  - label
  - reward baseline
  - type includes demo
  - vehiclePool
  - maxOpponents
  - spawnPrefix
  - playZone name
  - eliminationZones list
  - AI tuning values

## demolition.sites.json responsibilities
- Define parking spots matching spawnPrefix naming.
- Define play zone polygon.
- Define elimination zone polygons.
- Keep naming exactly aligned with config references.

## Minimum valid event checklist
1. Event key exists in config events object.
2. playZone exists in sites zones list.
3. elimination zone names exist in sites zones list.
4. spawn spots exist and match prefix.
5. At least one valid vehicle model in pool.

## Validation checklist after setup
1. Enter staging trigger and confirm staging overlay appears.
2. Start event and confirm AI spawns.
3. Confirm elimination boundaries work.
4. Confirm end conditions work for win and loss.
5. Confirm reward eligibility logic (top 50%) works once integrated.
6. Confirm event appears in Phone Events when discoverability integration is enabled.

## Common failure modes
- Wrong zone name in config.
- Wrong spawn prefix so zero spawn spots resolved.
- Invalid vehicle model keys.
- Trigger naming mismatch so event key cannot resolve.
- Missing map-level config files.

## 7) Risk Management

Primary risks and planned mitigation:

1. Schema drift between Lua fre config and JSON progression config.
- Mitigation: align demo aliases and discipline entries in both sources.

2. Reward exploits from placement calculation edge cases.
- Mitigation: deterministic placement normalization and top-half threshold tests.

3. Contract/sponsor progression mismatch for demo.
- Mitigation: use existing FRE cadence and standard unlock semantics in demo skills.

4. Map-owner setup errors.
- Mitigation: strict validation and clear warning logs plus documentation checklist.

## 8) Suggested Default Labeling

Recommended:
- Discipline name in progression cards: Demolition Derby.
- Internal id remains demo.

Reason:
- More explicit and user-friendly in UI.
- Internal id remains short and stable for config and code paths.

## 9) Deliverables Summary

Planned non-code and code deliverables (future implementation phase):

1. Updated demo progression schema.
2. New demo career skill file with full level cards.
3. Derby reward settlement integration with top-half eligibility.
4. Phone Events visibility for demo events.
5. Map-agnostic support verification.
6. Final map-owner how-to guide.

## 10) Immediate Next Step (Implementation Start)

Start coding in this order:
1. Progression schema updates for demo discipline + aliases + active contracts/sponsors.
2. Demo skill cards using Option A milestone cadence.
3. Derby reward wiring (money + demo XP, top-50% eligibility).
4. Phone Events inclusion for demo events.
