# RLS Career: FRE Contract Notification Filters

## TL;DR — What's New?
- **FRE Contract Notification Filters**: Adds selectable sub-filters under Phone Notification Settings for Contract Ready alerts.
- **Filter by Owned Vehicles**: Lists vehicle models from your garage so you only get alerts for cars you own, with a separate toggle for loaner/unowned cars.
- **Filter by Difficulty**: Separate toggles for Easy, Medium, and Hard tier contracts.
- **Filter by Discipline**: Individual toggles for active racing disciplines (Road Racing, Rally, Dirt, etc.).
- **Silent In-App Offers**: Filtered contracts still generate and remain available in the FRE Contracts app without sending phone notifications.
- **100% Seamless Save Compatibility**: Filters are enabled by default and saved per profile with zero setup required.

---

## Detailed Overview

### 1. Motivation & Problem Solved

As players progress through Career Mode and unlock licenses across multiple disciplines, the FRE Contracts system constantly generates new contract offers. Previously, players only had a single master toggle (`Contract Ready` on or off), creating a frustrating trade-off:

1. **Distracting Notification Spam**: Contract alerts pop up every few minutes during normal driving or other activities, often for disciplines, difficulty tiers, or loaner vehicles the player has no interest in.
2. **The "Check Phone Every 5 Minutes" Dilemma**: Turning off contract notifications silences the spam, but forces players to manually open and check their phone every 4–5 minutes just to see if a contract they actually care about appeared.
3. **Vehicle Mismatches**: Players often want alerts only when contracts appear for cars they actually own and tuned, rather than random stock loaners.

This feature adds sub-channel filtering directly inside Phone Notification Settings, keeping notifications relevant without forcing players to constantly check their phone manually.

---

### 2. Filter Categories

#### 🚗 Cars Filter
- **Garage Vehicle Model List**: Automatically inspects player-owned vehicles in your garage and provides individual toggles grouped by car model (e.g., Covet, Roamer, Bolide).
- **Other Vehicles (Loaners)**: Separate toggle for contracts that require vehicles not currently owned in your garage.
- **All Car Alerts Master Switch**: Easily toggle all vehicle alerts at once.

#### 🎯 Difficulty Filter
- **Tier Selection**: Dedicated toggles for **Easy**, **Medium**, and **Hard** contract tiers.
- **All Difficulty Alerts Master Switch**: Quick bulk toggle for all difficulty levels.

#### 🏁 Discipline Filter
- **Active Disciplines List**: Automatically populates from all active racing disciplines configured on the map (Road Racing, Rally, Dirt, Rallycross, Drag, Drift, Crawling, Mudding, etc.).
- **All Discipline Alerts Master Switch**: Easily enable or mute all disciplines simultaneously.

---

### 3. How the Filtering Works

1. **Offer Generation & Silent Gating**:
   Contract generation in the background is unchanged. When a contract offer becomes ready, the phone layout system checks the offer's model, tier, and discipline against your saved preferences:
   - If **allowed**: The phone plays the alert sound and displays the lock-screen banner/notification.
   - If **filtered**: The push notification is suppressed silently. The contract remains fully accessible inside the FRE Contracts app for manual browsing.
2. **Sub-Channel Dependency**:
   All sub-filters depend on the parent `Contract Ready` channel. If `Contract Ready` is disabled, all sub-filter categories are automatically muted.
3. **Master & Child Synchronization**:
   Turning off all individual items in a category automatically turns off the category master switch. Turning on any sub-item turns the category back on.

---

### 4. Settings Persistence & Architecture

- **Save-Slot Persistence**: Filter selections are saved alongside standard phone settings in your career profile, persisting across reloads and save migrations.
- **Fail-Open Defaults**: Unconfigured channels and filters fail open (`true`), ensuring fresh profiles and upgrades start with all notifications enabled until customized.
- **Extensible Registry**: Built on a modular selectable-channel registry in the phone UI and game engine layout system, making it easy to extend similar sub-channel filters to other career phone apps in the future.

