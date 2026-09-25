<template>
  <div class="home-widget scheduled-races-widget" :class="{ 'home-widget--compact': compact }">
    <div class="widget-header">
      <h3>Scheduled Races</h3>
      <span v-if="scheduledRows.length" class="count-badge">{{ scheduledRows.length }}</span>
    </div>

    <div v-if="scheduledRows.length" class="widget-content">
      <ul v-if="compact" class="race-list">
        <li v-for="row in scheduledRows" :key="row.key" class="race-row">
          <div class="race-row__text">
            <span class="race-row__title">{{ row.raceTitle }}</span>
            <span class="race-row__driver">{{ row.driverName }}</span>
            <span :class="['race-row__meta', { 'race-row__meta--ready': row.metaReady }]">
              {{ row.metaText }}
            </span>
          </div>
        </li>
      </ul>
      <ul v-else class="scheduled-offers-list">
        <li v-for="row in scheduledRows" :key="row.key" class="scheduled-offers-list__item">
          <RaceOfferBoardCard
            :offer="row.offer"
            :driver-name="row.driverName"
            :declining="spectateBusyId === row.driverId || dropScheduledBusyId === row.driverId || sendWithManagerBusyId === row.driverId"
            :primary-disabled="row.primaryDisabled"
            :hide-primary="row.hidePrimary"
            :hide-secondary="row.hideSecondary"
            :show-send-with-manager="row.showSendWithManager"
            :send-with-manager-disabled="row.sendWithManagerDisabled"
            :send-with-manager-tooltip="row.sendWithManagerTooltip"
            :is-in-background-sim="row.isInSim"
            :sim-progress="row.simProgress"
            :sim-badge="row.simBadge"
            :status-text="row.statusText"
            :primary-label="row.primaryLabel"
            secondary-label="Drop out"
            @accept="onSpectate(row.driverId)"
            @send-with-manager="onSendDriverWithManager(row.driverId)"
            @decline="onDropScheduled(row.driverId)"
          />
        </li>
      </ul>
    </div>

    <div v-else class="widget-content empty">
      <p>No races currently scheduled.</p>
      <button
        type="button"
        class="btn-schedule-pill"
        :class="{ 'btn-schedule-pill--compact': compact }"
        data-focusable
        @click="goToRaceTab"
        @mousedown.stop
      >
        Schedule a race
      </button>
    </div>
  </div>
</template>

<script setup>
import { ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { useBusinessComputerStore } from "../../../stores/businessComputerStore"
import { useScheduledRaces } from "../../../composables/useScheduledRaces"
import RaceOfferBoardCard from "../RaceOfferBoardCard.vue"

const props = defineProps({
  compact: { type: Boolean, default: false },
})

const emit = defineEmits(["open-tab"])

const store = useBusinessComputerStore()
const { events } = useBridge()
const { scheduledRows } = useScheduledRaces(store)

const isOutOfSpecErr = (err) => {
  const e = String(err || "")
  return e === "fleet_hp_over_class_max" || e === "fleet_hp_under_class_min" || e === "fleet_hp_bracket_mismatch"
}

const spectateBusyId = ref(null)
const dropScheduledBusyId = ref(null)
const sendWithManagerBusyId = ref(null)

const goToRaceTab = () => {
  emit("open-tab")
  if (!props.compact) {
    store.switchView("race")
  }
}

const raceActionErr = (err) => {
  const m = {
    no_pending_race_offer: "No scheduled race on that driver.",
    race_not_scheduled_yet: "Race time not reached yet.",
    invalid_driver: "Invalid driver.",
    no_valid_fleet_vehicle: "Driver needs a fleet vehicle.",
    missing_business_or_driver: "Missing business or driver.",
    no_business: "No business selected.",
    dyno_required: "Dyno certification required before entering sanctioned races.",
    fleet_hp_over_class_max: "Fleet car is too powerful for this race class.",
    fleet_hp_under_class_min: "Fleet car is below the minimum HP for this race class.",
    fleet_hp_bracket_mismatch: "Fleet car does not match the race HP class.",
    requires_manager_level_1: "Requires Manager Lv 1.",
    manager_already_running_race: "Manager is already supervising a race.",
    lua_error: "Something went wrong.",
    no_proxy_flow: "Race flow extension is not ready. Restart the game or verify the mod install.",
    no_staging_spot: "No track staging spot (player_stage_track) on this map.",
    no_inventory: "Business inventory is not available.",
    teleport_failed: "Could not place the team car at staging.",
    enter_vehicle_failed: "Could not switch you into the team car.",
    begin_failed: "Staging did not complete. Check the log.",
    unknown_error: "Operation could not be completed.",
  }
  return m[err] || (err ? String(err) : "Operation failed.")
}

const onDropScheduled = async (driverId) => {
  if (driverId === undefined || driverId === null) return
  dropScheduledBusyId.value = driverId
  try {
    const row = scheduledRows.value.find((r) => r.driverId === driverId)
    if (row && row.isInSim) {
      await store.cancelRacingTeamBackgroundRace(driverId, "dropped")
    }
    const res = row?.isPlayer
      ? await store.cancelRacingTeamPlayerScheduledRace()
      : await store.cancelRacingTeamProxyScheduledRace(driverId)
    if (res && res.ok) {
      await store.loadBusinessData(store.businessType, store.businessId)
      try {
        lua.ui_message("Scheduled team race withdrawn. Entry fee refunded when applicable.", 7, "Racing Team", "info")
      } catch (e) {}
    } else if (res && res.err) {
      try {
        lua.ui_message(raceActionErr(res.err), 5, "Racing Team", "error")
      } catch (e) {}
    }
  } finally {
    dropScheduledBusyId.value = null
  }
}

const onSendDriverWithManager = async (driverId) => {
  if (driverId === undefined || driverId === null) return
  sendWithManagerBusyId.value = driverId
  try {
    const res = await store.sendRacingTeamDriverWithManager(driverId)
    if (res && res.ok) {
      try {
        lua.ui_message("Driver dispatched with team manager for background race.", 6, "Racing Team", "info")
      } catch (e) {}
      await store.loadBusinessData(store.businessType, store.businessId)
    } else {
      const err = res?.err || "unknown_error"
      try {
        lua.ui_message(raceActionErr(err), 6, "Racing Team", "warning")
      } catch (e) {}
    }
  } catch (err) {
    console.error("[HomeScheduledRacesWidget] sendDriverWithManager", err)
  } finally {
    sendWithManagerBusyId.value = null
  }
}

const onSpectate = async (driverId) => {
  if (driverId === undefined || driverId === null) return
  const row = scheduledRows.value.find((r) => r.driverId === driverId)
  if (row?.isPlayer) {
    if (store.exitBusinessComputerToPlay) {
      store.exitBusinessComputerToPlay()
    } else if (lua.career_career && lua.career_career.closeAllMenus) {
      lua.career_career.closeAllMenus()
    }
    return
  }

  if (row && row.isInSim) {
    try {
      await store.cancelRacingTeamBackgroundRace(driverId, "manage_myself")
      await store.loadBusinessData(store.businessType, store.businessId)
    } catch (e) {
      console.error("[HomeScheduledRacesWidget] cancelRacingTeamBackgroundRace error", e)
    }
  }

  spectateBusyId.value = driverId
  try {
    const res = await store.simulateRacingTeamProxyRace({ driverId })
    if (res && res.ok === true) {
      await store.loadBusinessData(store.businessType, store.businessId)
      try {
        lua.ui_message(
          "Team race spectate starting from the grid. Returning to gameplay.",
          8,
          "Racing Team",
          "info"
        )
      } catch (e) {}
      if (store.exitBusinessComputerToPlay) {
        store.exitBusinessComputerToPlay()
      }
      return
    }
    const err = res && res.err ? res.err : "unknown_error"
    let showOos = isOutOfSpecErr(err)
    if (!showOos) {
      try {
        const chk = await store.isProxyScheduledDriverFleetOverpowered(driverId)
        showOos = !!(chk && chk.overpowered)
      } catch (e) {}
    }
    if (showOos) {
      events.emit("racingTeam:vehicleOutOfClass")
      return
    }
    try {
      lua.ui_message(raceActionErr(err), 5, "Racing Team", "error")
    } catch (e) {}
  } finally {
    spectateBusyId.value = null
  }
}
</script>

<style scoped lang="scss">
.home-widget {
  background: rgba(30, 30, 30, 0.6);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 1em;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  min-height: 8em;
}

.widget-header {
  padding: 0.75em 1em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: rgba(0, 0, 0, 0.2);

  h3 {
    margin: 0;
    font-size: 1em;
    font-weight: 600;
    color: #fff;
  }
}

.count-badge {
  font-size: 0.8em;
  font-weight: 600;
  color: rgba(245, 73, 0, 1);
  background: rgba(245, 73, 0, 0.15);
  padding: 0.2em 0.55em;
  border-radius: 0.35em;
}

.widget-content {
  padding: 0.75em 1em;
  flex: 1;

  &.empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
    gap: 0.75em;
    color: rgba(255, 255, 255, 0.5);
    min-height: 6em;
  }
}

.scheduled-offers-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.65em;
}

.scheduled-offers-list__item {
  min-width: 0;
}

.race-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.race-row {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  gap: 0.65em;
  padding: 0.5em 0.65em;
  border-radius: 0.35em;
  background: rgba(0, 0, 0, 0.25);
  border: 1px solid rgba(255, 255, 255, 0.06);
}

.race-row__text {
  display: flex;
  flex-direction: column;
  gap: 0.2em;
  min-width: 0;
  flex: 1;
}

.race-row__title {
  font-weight: 600;
  color: #fff;
  font-size: 0.92em;
}

.race-row__driver {
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.55);
}

.race-row__meta {
  font-size: 0.74em;
  color: rgba(255, 255, 255, 0.45);
}

.race-row__meta--ready {
  color: rgba(120, 220, 140, 0.95);
  font-weight: 600;
}

.home-widget--compact {
  min-height: 0;
  flex-shrink: 0;
  height: auto;

  .widget-header {
    padding: 0.42em 0.55em;

    h3 {
      font-size: 0.82em;
    }
  }

  .count-badge {
    font-size: 0.68em;
    padding: 0.1em 0.4em;
  }

  .widget-content {
    padding: 0.4em 0.55em 0.5em;

    &.empty {
      min-height: 0;
      gap: 0.4em;
      font-size: 0.78em;
    }
  }

  .race-list {
    gap: 0.35em;
  }

  .race-row {
    padding: 0.35em 0.45em;
  }

  .race-row__title {
    font-size: 0.8em;
  }

  .race-row__driver,
  .race-row__meta {
    font-size: 0.7em;
  }
}

.btn-schedule-pill {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  margin: 0;
  padding: 0.5em 1.15em;
  border: none;
  border-radius: 999px;
  background: rgba(245, 73, 0, 0.92);
  color: #fff;
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.2;
  cursor: pointer;
  text-decoration: none;
  transition: background 0.15s;

  &:hover {
    background: rgba(255, 100, 30, 1);
  }

  &--compact {
    font-size: 0.72em;
    padding: 0.4em 1em;
  }
}
</style>
