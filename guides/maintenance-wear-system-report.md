# Maintenance and Wear System

## Design split

The system deliberately separates two ideas:

- Vehicle mileage and current driving behavior control fluid consumption.
- Miles driven by the player, heat, load, and low fluid control fluid-condition degradation.

Replacing a high-mileage engine or fluid does not reset the vehicle's odometer consumption factor. Servicing a fluid restores its tracked level/condition but does not erase native mechanical age wear.

## Mileage consumption

Vehicle mileage uses fixed 50,000-mile brackets:

| Vehicle mileage | Age index |
| --- | ---: |
| 0–49,999 | 1.0x |
| 50,000–99,999 | 1.5x |
| 100,000–149,999 | 2.0x |
| 150,000–199,999 | 3.0x |
| 200,000–249,999 | 5.0x |
| 250,000–299,999 | 6.5x |
| 300,000+ | 8.0x |

Each fluid maps that index to its own high-mileage cap. For a reference passenger vehicle under the standard drive profile, the level reaches its service target at approximately:

| Fluid level | New vehicle | 300,000+ miles | Target |
| --- | ---: | ---: | ---: |
| Engine oil | 240 mi | 20 mi | 50% |
| Coolant | 260 mi | 30 mi | 55% |
| Transmission fluid | 220 mi | 35 mi | 50% |

Mileage no longer shortens the base fluid-quality interval a second time.

## Driving and condition rules

- Oil-level consumption is primarily RPM driven, with a smaller load contribution.
- Oil quality responds more strongly to load, output stress, torque-capacity stress, and oil temperature.
- Coolant responds to heat, overheating, load, hot/cold cycles, and system integrity.
- Transmission fluid responds to load, RPM, simulated transmission heat, output, and limit stress.
- A live combustion-torque ratio begins adding oil use and oil-quality wear at 90% of the engine's `maxTorqueRating`.
- Oil-temperature quality multipliers are 1x through 110 C, 2x at 135 C, 4x at 150 C, and 8x at 170 C.

Low fluid reduces the available contamination reserve and accelerates condition degradation:

| Fluid remaining | Condition multiplier |
| --- | ---: |
| 70–100% | 1.0x |
| 50% | 1.25x |
| 30% | 2.0x |
| 15% | 4.0x |
| 0% | 8.0x |

## Extreme-output engines

Extreme oil consumption is gated by actual load and RPM, so a powerful engine does not consume drag-race quantities while cruising. The additional full-load curve begins above 700 hp and targets roughly:

| Installed output | Full-load multiplier |
| --- | ---: |
| 700 hp or less | 1x |
| 1,000 hp | 31x |
| 2,500 hp | 55x |
| 5,000 hp | 88x |

Full-load runtime counts even when the car covers little distance, using a 60-mph equivalent while the gate is active. This makes burnouts, dyno-style stationary pulls, and drag launches consume oil and age hot oil. The extreme term is additive to normal mileage/RPM consumption, so vehicle age does not multiply it into unusable values.

## Mechanical age wear

Age no longer applies an artificial age-only horsepower or torque ceiling. Instead, the engine manager applies enhanced BeamNG-native wear coefficients for friction, dynamic friction, and idle roughness. The curve starts after roughly 18,600 miles and reaches its main target at 300,000 miles. Direct output limiting remains reserved for actual oil starvation, overheating, severe ignition problems, transient symptoms, and saved damage.

This rewards an engine built with extra block capacity: a stage-three block operated well below its torque rating avoids the 90%+ capacity stress that a marginal block would see.

## Vehicle profiles

Saved maintenance state version 3 contains a profile snapshot. Classification priority is:

1. Explicit `maintenanceClass` metadata.
2. Body-style/type metadata from vehicle information.
3. Known model family.
4. Curb weight.
5. Engine-block node mass when other data is unavailable.

Supported classes and fallback capacities are:

| Class | Oil | Coolant | Transmission | Condition interval |
| --- | ---: | ---: | ---: | ---: |
| Passenger | 4 L | 5 L | 6 L | 1.0x |
| Light truck/SUV | 6 L | 8 L | 9 L | 1.15x |
| Medium truck | 10 L | 15 L | 14 L | 1.4x |
| Heavy truck/semi | 18 L | 25 L | 20 L | 1.75x |

Live engine oil volume and coolant mass replace class defaults when BeamNG exposes reliable values. Fluid consumption uses a damped capacity factor, `clamp(sqrt(reference / actual), 0.55, 1.5)`, rather than scaling linearly.

Diesels receive a separate overlay: 1.25x oil-quality life, 0.85x normal RPM oil use, up to 1.25x quality stress under full load, 25 condition-miles per idle hour, and a 1.25x fluid-material grade price.

## Service prices

Replacement-service pricing uses labor, filter, fluid capacity, fluid grade, and component complexity. Top-ups charge only for missing volume plus a small labor amount.

- Oil replacement: `$75 labor + $25 filter + $11/L`.
- Coolant replacement: `$85 labor + $13/L`.
- Transmission-fluid replacement: `$105 labor + $50 filter + $16/L`.
- Oil top-up: `$15 + $11/missing L`.
- Coolant top-up: `$15 + $8/missing L`.
- Transmission top-up: `$25 + $16/missing L`.

Material grade is 1.25x for a diesel or 700–1,499 hp, 1.5x at 1,500–2,999 hp, and 2x at 3,000+ hp. Replacement complexity adds 0.5% of tracked engine value above $10,000 (maximum $250), 0.5% of cooling value above $5,000 (maximum $200), or 0.75% of transmission value above $8,000 (maximum $350). Totals round to the nearest $5 below $500 and nearest $10 at $500 or more.

Service durations are unchanged.

## Persistence and diagnostics

Version-2 snapshots migrate to version 3 without resetting maintenance values, damage, or in-progress maintenance jobs. Debug output includes the class and source, capacity values/factors, mileage index and level multiplier, low-fluid multiplier, oil-temperature multiplier, live torque/rating ratio, extreme-output gate, native age-wear coefficients, and UI price breakdown.
