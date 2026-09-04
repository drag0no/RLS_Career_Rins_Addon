# RLS Career Overhaul Dev - Architecture Analysis

## Scope

This document captures a repository-level architecture analysis of the `rls-career-overhaul-dev` mod, including startup flow, override strategy, UI stack, core systems, FRE integration points, persistence model, and risk areas.

## High-Level Structure

The mod is organized as a layered BeamNG career overhaul:

- Core gameplay Lua extensions under `lua/ge/extensions`.
- Custom/overridden gameplay data under `gameplay`, `levels`, and related content folders.
- UI stacks under `baseUI` and `ui-vue-src`.
- Runtime script bootstrap under `scripts/rls_career_overhaul`.

Key top-level folders:

- `scripts/rls_career_overhaul`: startup and orchestration.
- `lua/ge/extensions/overhaul`: extension manager, override manager, map/setup helpers.
- `lua/ge/extensions/overrides`: selective replacement/wrapping of vanilla systems.
- `lua/ge/extensions/gameplay`: expanded career systems (economy, business, events, FRE, etc.).
- `ui-vue-src`: custom Vue career/phone modules and views.
- `baseUI`: Vite-based UI foundation build.
- `gameplay`: data-driven configs used by gameplay systems.

## Runtime Bootstrap and Override Model

Runtime initialization uses an explicit extension lifecycle model:

1. `scripts/rls_career_overhaul/modScript.lua` is the entry bootstrap.
2. `lua/ge/extensions/overhaul/extensionManager.lua` loads/unloads managed extensions.
3. `lua/ge/extensions/overhaul/overrideManager.lua` mounts and applies override wrappers.
4. Additional setup modules apply map/UI/config changes as needed.

Observed design characteristics:

- Aggressive control of extension load order.
- Manual unload/reload strategy to guarantee override precedence.
- Wrapper-based interception for selected career systems instead of modifying every upstream source directly.

This architecture is powerful for total conversion behavior, but introduces sensitivity to BeamNG internal API changes and extension naming changes.

## UI Architecture

The UI is a hybrid stack centered on Vue 3 with legacy compatibility still present.

### Build and Tooling

- `build_ui.sh` and `build_ui.bat` orchestrate UI build flow.
- `baseUI` uses Vite (`baseUI/vite.config.js`) with npm scripts from `baseUI/package.json`.
- Custom views/services are layered from `ui-vue-src` into the runtime UI.

### App Structure

- Route registry and app entry points are in Vue modules (career and phone experiences).
- Lua-to-UI communication relies on guihook events and Lua bridge calls.
- Phone experiences (market, logistics, FRE events, FRE contracts, etc.) are first-class views.

### Practical Effect

The mod has moved far beyond data-only changes. It operates as a full gameplay + UX platform with custom front-end surfaces and live backend feeds.

## Gameplay Systems Coverage

The overhaul spans broad career domains:

- Economy and money flows.
- Banking, loans, and account systems.
- Property/business features.
- Phone applications as primary interaction layer.
- FRE progression, contracts, sponsors, sanctioned racing.

Notable files reviewed include:

- `lua/ge/extensions/gameplay/events/freContracts.lua`
- `lua/ge/extensions/gameplay/events/freContracts/*.lua`
- `lua/ge/extensions/gameplay/events/freeroamEvents.lua`
- `lua/ge/extensions/gameplay/events/freeroam/raceSession.lua`
- `lua/ge/extensions/ui/phone/freContracts.lua`
- `lua/ge/extensions/ui/phone/freeroamEvents.lua`

## Persistence and State Model

State is split across multiple mechanisms:

- Career save hooks (`onSaveCurrentSaveSlot`) in extensions.
- JSON state files under career save paths.
- Regular settings/state files for UI and system preferences.

Example in FRE contracts:

- Persistent state: `/career/fre/freContractsSponsors.json`.
- Sim-time driven maintenance scheduling and event expiration checks.

The system is not purely event-driven. It uses periodic maintenance windows based on next known deadline/refresh times.

## FRE as a Cross-Cutting Subsystem

FRE is not isolated. It crosses:

- Race runtime (`freeroamEvents`, `raceSession`).
- Progression and offers (`freContracts` modules).
- UI control plane (`ui_phone_freContracts`, Vue phone app).
- Career skills/levels and unlock cards.
- Map-level sanctioned racing definitions.

This is a key architectural point: FRE sits at the intersection of gameplay logic, progression economy, and phone UX.

## Strengths

- Strong modularization by concern (`state`, `skills`, `offers`, `race`, `ui`, `actions`, `sanctionedRacing`).
- Data-driven progression via `gameplay/fre/freProgression.config.json`.
- Clear phone-facing API surface for runtime state and actions.
- Practical abstractions for target generation, route matching, and reward modifiers.

## Risks and Fragility Areas

- Override-heavy strategy can break on upstream updates.
- Coupling between race data shape and offer generation paths.
- Multiple sources of truth for level messaging vs hard-coded unlock logic if configs diverge.
- Map-specific sanctioned flow dependency (if required config assets are absent, feature is unavailable).
- UI and backend cadence mismatch can cause stale offer countdown perception if not handled carefully.

## Recommended Next Focus Areas

1. Add guardrails/tests around extension load order and override application.
2. Add schema validation for FRE config and map sanctioned config files.
3. Add instrumentation logs for offer generation failures (no races, invalid models, invalid targets).
4. Add compatibility checks for future BeamNG updates (API surface changes).
5. Document all phone action endpoints and expected payloads as a stable contract.

## Summary

`rls-career-overhaul-dev` is a deep career conversion framework, not just a small mod patch set. Its architecture combines extension lifecycle control, selective override injection, data-driven progression, and a custom Vue phone/UI layer. FRE is implemented as a mature subsystem tied into race runtime, progression math, sponsorship, and map-based sanctioned racing flows.
