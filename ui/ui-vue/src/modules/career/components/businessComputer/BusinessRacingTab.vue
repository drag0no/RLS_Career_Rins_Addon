<template>
  <div class="racing-tab" :class="{ 'racing-tab--phone': layout === 'phone' }">
    <div class="tab-header">
      <div class="header-content">
        <div>
          <h2>{{ raceOffersScreenTitle }}</h2>
          <p
            v-if="layout !== 'phone' && managerBookingTimerText"
            class="racing-tab__manager-booking-timer"
          >
            {{ managerBookingTimerText }}
          </p>
        </div>
      </div>
    </div>

    <section
      v-if="showManagerAutomationPanel"
      class="manager-auto-panel"
      :class="{ 'manager-auto-panel--phone': layout === 'phone' }"
    >
      <div class="manager-auto-panel__row">
        <div class="manager-auto-panel__heading">
          <div class="manager-auto-panel__title-row">
            <h3 class="manager-auto-panel__title">Manager automation</h3>
            <label
              class="manager-auto-toggle"
              :class="{ 'manager-auto-toggle--disabled': managerAutoToggleBusy }"
            >
              <input
                type="checkbox"
                :checked="managerAutoAssign"
                :disabled="managerAutoToggleBusy"
                @change="onManagerAutoToggle"
              />
              <span class="manager-auto-toggle__slider" aria-hidden="true" />
              <span class="manager-auto-toggle__label">{{ layout === 'phone' ? 'Auto-assign' : 'Auto-assign sanctioned offers' }}</span>
            </label>
          </div>
          <div v-if="managerSkillLevel >= 2" class="manager-auto-panel__interval">
            <span class="manager-auto-interval-text">Automation interval:</span>
            <div class="manager-interval-pills" role="radiogroup" aria-label="Automation interval">
              <button
                v-for="opt in managerIntervalOptions"
                :key="opt.value"
                type="button"
                class="manager-interval-pill"
                :class="{ active: managerIntervalModel === opt.value }"
                :disabled="managerIntervalBusy"
                :aria-checked="managerIntervalModel === opt.value"
                role="radio"
                @mousedown.stop
                @click.stop="selectManagerInterval(opt.value)"
              >
                {{ opt.shortLabel }}
              </button>
            </div>
          </div>
        </div>
      </div>
      <p
        v-if="managerBookingTimerText"
        class="manager-auto-panel__countdown"
      >
        {{ managerBookingTimerText }}
      </p>
      <p v-if="layout !== 'phone'" class="manager-auto-panel__hint">
        When on, books idle drivers from the offer board. Spectate alerts need Shop App.
      </p>
    </section>

    <div v-if="racingTeamProxyArmed" class="proxy-race-banner">
      <template v-if="isLeague1">
        <p class="proxy-race-banner__text">Team race armed — go to grid.</p>
        <button
          type="button"
          class="btn btn-primary proxy-race-banner__race"
          data-focusable
          :disabled="raceFromGarageBusy"
          @click.stop="onRaceFromGarage"
          @mousedown.stop
        >
          Go to grid
        </button>
      </template>
      <template v-else>
        <p class="proxy-race-banner__text">Spectate from Scheduled Races when ready.</p>
      </template>
    </div>

    <template v-if="!selectedOffer">
      <section v-if="driversWithScheduledRaces.length" class="races-section">
        <h3 class="races-section__title">Scheduled Races</h3>
        <ul v-if="layout === 'phone'" class="offers-list">
          <li v-for="row in driversWithScheduledRaces" :key="row.key" class="offer-row">
            <RaceOfferBoardCard
              :offer="row.offer"
              :driver-name="row.driverName"
              :declining="armScheduledBusyId === row.driverId || dropScheduledBusyId === row.driverId"
              :primary-disabled="!row.scheduledRaceReady"
              :status-text="row.scheduledRaceReady ? '' : formatWaitText(row.secondsUntilScheduledRace, row.useWallClock)"
              primary-label="Spectate"
              secondary-label="Drop out"
              @accept="startScheduledRaceSpectate(row.driverId)"
              @decline="dropScheduledRace(row.driverId)"
            />
          </li>
        </ul>
        <div v-else class="offers-grid">
          <div v-for="row in driversWithScheduledRaces" :key="row.key" class="offer-grid-item">
            <RaceOfferBoardCard
              :offer="row.offer"
              :driver-name="row.driverName"
              :declining="armScheduledBusyId === row.driverId || dropScheduledBusyId === row.driverId"
              :primary-disabled="!row.scheduledRaceReady"
              :status-text="row.scheduledRaceReady ? '' : formatWaitText(row.secondsUntilScheduledRace, row.useWallClock)"
              primary-label="Spectate"
              secondary-label="Drop out"
              @accept="startScheduledRaceSpectate(row.driverId)"
              @decline="dropScheduledRace(row.driverId)"
            />
          </div>
        </div>
      </section>

      <p v-if="raceOffersMessage" class="info-banner">{{ raceOffersMessage }}</p>

      <section class="races-section">
        <h3 class="races-section__title">Available Races</h3>
        <ul v-if="raceOffers.length && layout === 'phone'" class="offers-list">
          <li v-for="offer in raceOffers" :key="String(offer.id)" class="offer-row">
            <RaceOfferBoardCard
              :offer="offer"
              :declining="decliningOfferId === String(offer.id)"
              @accept="onAccept(offer)"
              @decline="onDeclineRaceOffer(offer)"
            />
          </li>
        </ul>
        <div v-else-if="raceOffers.length" class="offers-grid">
          <div v-for="offer in raceOffers" :key="String(offer.id)" class="offer-grid-item">
            <RaceOfferBoardCard
              :offer="offer"
              :declining="decliningOfferId === String(offer.id)"
              @accept="onAccept(offer)"
              @decline="onDeclineRaceOffer(offer)"
            />
          </div>
        </div>
        <div v-else class="empty-state">
          {{ driversWithScheduledRaces.length ? "No new offers on the board. Use Scheduled Races above when ready." : "No offers available right now." }}
        </div>
      </section>
    </template>

    <div v-else class="offer-detail">
      <button type="button" class="btn btn-secondary offer-detail__back" data-focusable @click.stop="onOfferDetailBack" @mousedown.stop>
        ← Back
      </button>
      <h3 class="offer-title">{{  selectedOffer.raceLabel || selectedOffer.raceName || "Race" }}</h3>
      <ul class="detail-meta">
        <li><span class="label">Scheduled</span> {{  selectedOffer.scheduledTime ?? "-" }}</li>
        <li><span class="label">Laps</span> {{  selectedOffer.lapCount ?? "-" }}</li>
        <li><span class="label">Class</span> {{ formatClassLabel(selectedOffer.hpBracketLabel, selectedOffer.classPwMin, selectedOffer.classPwMax, selectedOffer.hpBracketBranch) || "—" }}</li>
      </ul>
      <div class="offer-detail__actions">
        <button
          v-if="isLeague1"
          type="button"
          class="btn btn-primary"
          data-focusable
          :disabled="league1FleetLoading"
          @click.stop="openLeague1FleetPicker"
          @mousedown.stop
        >
          Choose fleet car
        </button>
        <button
          v-else
          type="button"
          class="btn btn-primary"
          data-focusable
          @click.stop="onAssignDriver"
          @mousedown.stop
        >
          Assign driver
        </button>
        <button
          v-if="!isLeague1"
          type="button"
          class="btn btn-secondary"
          data-focusable
          :disabled="league2FleetLoading"
          @click.stop="openLeague2FleetPicker"
          @mousedown.stop
          title="Drive yourself: 85% payout (15% crew share) · 15m cooldown."
        >
          Race myself
        </button>
      </div>

      <div v-if="isLeague1 && league1FleetPickerOpen" class="offer-detail__driver-picker">
        <p class="driver-picker-title">Choose a team car</p>
        <p class="driver-picker-hint">Match the car’s class to this offer.</p>
        <p v-if="league1FleetLoading" class="driver-picker-empty">Loading fleet…</p>
        <p v-else-if="!league1FleetOptions.length" class="driver-picker-empty">No fleet vehicle matches this sanctioned class.</p>
        <ul v-else class="driver-picker-list">
          <li v-for="fv in league1FleetOptions" :key="String(fv.vehicleId)" class="driver-picker-item">
            <div class="driver-picker-row-head">
              <div class="driver-picker-row-titles">
                <span class="driver-picker-name">{{ fv.vehicleName || ("Vehicle #" + fv.vehicleId) }}</span>
                <span
                  v-if="formatClassLabel(fv.fleetSanctionedClassLabel, fv.fleetEffectivePw) || fv.fleetClassStatusMessage"
                  class="driver-picker-class"
                >
                  {{ formatClassLabel(fv.fleetSanctionedClassLabel, fv.fleetEffectivePw) || fv.fleetClassStatusMessage }}
                </span>
              </div>
              <span v-if="fv.overpowered" :style="{ marginLeft: '0.5em', fontSize: '0.75em', padding: '0.15em 0.5em', borderRadius: '0.25em', background: 'rgba(245,73,0,0.2)', color: 'rgba(255,180,120,0.95)', border: '1px solid rgba(245,73,0,0.5)' }">Over class</span>
              <span v-if="fv.onCooldown" :style="{ marginLeft: '0.5em', fontSize: '0.75em', padding: '0.15em 0.5em', borderRadius: '0.25em', background: 'rgba(245,73,0,0.2)', color: 'rgba(255,180,120,0.95)', border: '1px solid rgba(245,73,0,0.5)' }">Cooling down {{ formatCooldown(fv.cooldownSec) }}</span>
            </div>
            <div class="driver-picker-actions">
              <button
                type="button"
                class="btn btn-primary"
                data-focusable
                :disabled="raceLeague1BusyVehicleId !== null"
                @click.stop="confirmLeague1RaceWithFleet(fv)"
                @mousedown.stop
              >
                Race
              </button>
            </div>
          </li>
        </ul>
      </div>

      <div v-if="!isLeague1 && league2FleetPickerOpen" class="offer-detail__driver-picker">
        <p class="driver-picker-title">Race this offer yourself</p>
        <p class="driver-picker-hint">85% payout (15% crew share) · 15m cooldown</p>
        <p v-if="league2FleetLoading" class="driver-picker-empty">Loading fleet…</p>
        <p v-else-if="!league2FleetOptions.length" class="driver-picker-empty">No fleet vehicle matches this sanctioned class.</p>
        <ul v-else class="driver-picker-list">
          <li v-for="fv in league2FleetOptions" :key="String(fv.vehicleId)" class="driver-picker-item">
            <div class="driver-picker-row-head">
              <div class="driver-picker-row-titles">
                <span class="driver-picker-name">{{ fv.vehicleName || ("Vehicle #" + fv.vehicleId) }}</span>
                <span
                  v-if="formatClassLabel(fv.fleetSanctionedClassLabel, fv.fleetEffectivePw) || fv.fleetClassStatusMessage"
                  class="driver-picker-class"
                >
                  {{ formatClassLabel(fv.fleetSanctionedClassLabel, fv.fleetEffectivePw) || fv.fleetClassStatusMessage }}
                </span>
              </div>
              <span v-if="fv.overpowered" :style="{ marginLeft: '0.5em', fontSize: '0.75em', padding: '0.15em 0.5em', borderRadius: '0.25em', background: 'rgba(245,73,0,0.2)', color: 'rgba(255,180,120,0.95)', border: '1px solid rgba(245,73,0,0.5)' }">Over class</span>
              <span v-if="fv.onCooldown" :style="{ marginLeft: '0.5em', fontSize: '0.75em', padding: '0.15em 0.5em', borderRadius: '0.25em', background: 'rgba(245,73,0,0.2)', color: 'rgba(255,180,120,0.95)', border: '1px solid rgba(245,73,0,0.5)' }">Vehicle cooling {{ formatCooldown(fv.cooldownSec) }}</span>
              <span v-if="fv.playerOnCooldown" :style="{ marginLeft: '0.5em', fontSize: '0.75em', padding: '0.15em 0.5em', borderRadius: '0.25em', background: 'rgba(245,73,0,0.2)', color: 'rgba(255,180,120,0.95)', border: '1px solid rgba(245,73,0,0.5)' }">Player cooling {{ formatCooldown(fv.playerCooldownSec) }}</span>
            </div>
            <div class="driver-picker-actions">
              <button
                type="button"
                class="btn btn-primary"
                data-focusable
                :disabled="raceLeague2BusyVehicleId !== null || fv.onCooldown || fv.playerOnCooldown || fv.overpowered"
                @click.stop="confirmLeague2RaceWithFleet(fv)"
                @mousedown.stop
              >
                Race
              </button>
            </div>
          </li>
        </ul>
      </div>

      <div v-if="driverPickerOpen && !isLeague1" class="offer-detail__driver-picker">
          <p class="driver-picker-title">Choose a driver</p>
          <p class="driver-picker-hint">Books the race; spectate from Scheduled Races when ready.</p>
          <p v-if="!availableDrivers.length" class="driver-picker-empty">No drivers available.</p>
          <ul v-else class="driver-picker-list">
            <li v-for="tech in availableDrivers" :key="String(tech.id)" class="driver-picker-item">
              <div class="driver-picker-row-head">
                <span class="driver-picker-name">{{ tech.name || ("Driver #" + tech.id) }}</span>
                <span v-if="tech.fleetVehicleName" class="driver-picker-sub"> — {{ tech.fleetVehicleName }}</span>
                <span v-else class="driver-picker-sub warn"> — assign a fleet car first</span>
                <span v-if="hasFleetVehicleAssigned(tech) && isDriverOnPostRaceCooldown(tech)" class="driver-picker-sub warn">
                  — recovering {{ formatCooldownCounter(remainingSecondsForPostRaceCooldown(tech)) }}
                </span>
              </div>
              <div class="driver-picker-actions">
                <button
                  type="button"
                  class="btn btn-primary"
                  data-focusable
                  :disabled="!hasFleetVehicleAssigned(tech) || isDriverOnPostRaceCooldown(tech)"
                  @click.stop="confirmRaceWithDriver(tech)"
                  @mousedown.stop
                >
                Schedule
                </button>
              </div>
            </li>
          </ul>
          <button type="button" class="btn btn-secondary offer-detail__back" data-focusable @click.stop="cancelDriverPicker" @mousedown.stop>
            Cancel
          </button>
      </div>
    </div>

    <Teleport to="body">
      <div
        v-if="vehicleOutOfClassModalOpen"
        class="modal-overlay"
        @click.self.stop="vehicleOutOfClassModalOpen = false"
        @mousedown.self.stop="vehicleOutOfClassModalOpen = false"
      >
        <div class="modal-content" @click.stop @mousedown.stop>
          <h2>Vehicle over class limit</h2>
          <p>
            This car's power-to-weight is above the race bracket (see class on the offer vs your vehicle card). Pick a lower-tier offer or use a less powerful tune.
          </p>
          <div class="modal-buttons">
            <button
              type="button"
              class="btn btn-primary"
              data-focusable
              @click.stop="vehicleOutOfClassModalOpen = false"
              @mousedown.stop
            >OK</button>
          </div>
        </div>
      </div>
      <div
        v-if="vehicleOnCooldownModalOpen"
        class="modal-overlay"
        @click.self.stop="vehicleOnCooldownModalOpen = false"
        @mousedown.self.stop="vehicleOnCooldownModalOpen = false"
      >
        <div class="modal-content" @click.stop @mousedown.stop>
          <h2>Vehicle on cooldown</h2>
          <p>
            This car just finished a race and needs time to reset. <span v-if="vehicleOnCooldownSec > 0">Try again in {{ formatCooldown(vehicleOnCooldownSec) }}.</span>
          </p>
          <div class="modal-buttons">
            <button
              type="button"
              class="btn btn-primary"
              data-focusable
              @click.stop="vehicleOnCooldownModalOpen = false"
              @mousedown.stop
            >OK</button>
          </div>
        </div>
      </div>
    </Teleport>
  </div>
</template>

<script setup>
import { computed, ref, watch, onMounted, onUnmounted } from "vue"
import { lua, useBridge } from "@/bridge"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { formatSanctionedClassWithBucket } from "../../utils/sanctionedClassFormat"
import RaceOfferBoardCard from "./RaceOfferBoardCard.vue"

defineProps({
  layout: {
    type: String,
    default: "computer",
    validator: (value) => ["computer", "phone"].includes(value),
  },
})

const store = useBusinessComputerStore()
const { events } = useBridge()

const scheduleUiSecondTick = ref(0)
let scheduleUiTimer = null

const formatCooldownCounter = (totalSec) => {
  const s = Math.max(0, Math.floor(Number(totalSec) || 0))
  if (s <= 0) return "0:00"
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const r = s % 60
  if (h > 0) {
    return `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`
  }
  return `${m}:${String(r).padStart(2, "0")}`
}

/** Matches scheduled-race countdown: prefer wall epoch so the UI ticks every second. */
const remainingSecondsForPostRaceCooldown = (tech) => {
  const wallDue = Number(tech?.postRaceCooldownReadyWallEpoch)
  void scheduleUiSecondTick.value
  if (Number.isFinite(wallDue)) {
    return Math.max(0, wallDue - Math.floor(Date.now() / 1000))
  }
  const until = Number(tech?.racingCooldownUntilSimTime)
  const now = Number(store.racingTeamCareerSimTime)
  if (Number.isFinite(until) && Number.isFinite(now)) {
    return Math.max(0, Math.floor(until - now))
  }
  const snap = Number(tech?.postRaceCooldownRemainingSec)
  return Number.isFinite(snap) ? Math.max(0, Math.floor(snap)) : 0
}

const handleVehicleOutOfClass = () => {
  vehicleOutOfClassModalOpen.value = true
}

const handleVehicleOnCooldown = (payload) => {
  const sec = Number(payload?.remainingSec)
  vehicleOnCooldownSec.value = Number.isFinite(sec) ? Math.max(0, Math.floor(sec)) : 0
  vehicleOnCooldownModalOpen.value = true
}

const formatCooldown = (totalSec) => formatCooldownCounter(totalSec)

onMounted(() => {
  scheduleUiTimer = setInterval(() => {
    scheduleUiSecondTick.value++
    if (
      managerAutoAssign.value
      && managerIntervalCountdownSec.value === 0
      && store.businessId
      && store.businessType
    ) {
      const now = Date.now()
      if (now - managerReloadThrottle > 4000) {
        managerReloadThrottle = now
        store.loadBusinessData(store.businessType, store.businessId)
      }
    }
  }, 1000)
  events.on("racingTeam:vehicleOutOfClass", handleVehicleOutOfClass)
  events.on("racingTeam:vehicleOnCooldown", handleVehicleOnCooldown)
  events.on("racingTeamManagerSettingsUpdated", onManagerSettingsUpdated)
})
onUnmounted(() => {
  if (scheduleUiTimer) {
    clearInterval(scheduleUiTimer)
    scheduleUiTimer = null
  }
  events.off("racingTeam:vehicleOutOfClass", handleVehicleOutOfClass)
  events.off("racingTeam:vehicleOnCooldown", handleVehicleOnCooldown)
  events.off("racingTeamManagerSettingsUpdated", onManagerSettingsUpdated)
})

function formatLeagueLabel (league) {
  if (!league || typeof league !== "string") return ""
  const map = store.racingTeamLeagueDisplayNames
  if (map && typeof map === "object" && map[league]) {
    return String(map[league])
  }
  const m = /^league(\d+)$/i.exec(league.trim())
  if (m) return `League ${m[1]}`
  return league
}

const raceOffersScreenTitle = computed(() => {
  const cl = store.businessData?.currentLeague
  if (!cl || typeof cl !== "string") return ""
  return formatLeagueLabel(cl) || ""
})

const selectedOffer = ref(null)

const driverPickerOpen = ref(false)

const league1FleetPickerOpen = ref(false)
const league1FleetOptions = ref([])
const league1FleetLoading = ref(false)
const raceLeague1BusyVehicleId = ref(null)

const league2FleetPickerOpen = ref(false)
const league2FleetOptions = ref([])
const league2FleetLoading = ref(false)
const raceLeague2BusyVehicleId = ref(null)

const raceFromGarageBusy = ref(false)

const armScheduledBusyId = ref(null)

const dropScheduledBusyId = ref(null)

const decliningOfferId = ref(null)

const vehicleOutOfClassModalOpen = ref(false)
const vehicleOnCooldownModalOpen = ref(false)
const vehicleOnCooldownSec = ref(0)

const remainingSecondsForScheduledDriver = (t) => {
  const pr = t?.pendingRaceOffer
  const wallDue = Number(pr?.scheduledRaceReadyWallEpoch ?? t?.scheduledRaceReadyWallEpoch)
  void scheduleUiSecondTick.value
  if (Number.isFinite(wallDue)) {
    return Math.max(0, wallDue - Math.floor(Date.now() / 1000))
  }
  const due = Number(t.scheduledRaceSimTime)
  const now = Number(store.racingTeamCareerSimTime)
  if (Number.isFinite(due) && Number.isFinite(now)) {
    return Math.max(0, Math.floor(due - now))
  }
  const fallback = Number(t.secondsUntilScheduledRace)
  if (Number.isFinite(fallback)) {
    return Math.max(0, Math.floor(fallback))
  }
  return null
}

const racingTeamProxyArmed = computed(() => store.businessData?.racingTeamProxyArmed === true)

const isLeague1 = computed(() => (store.businessData?.currentLeague || "") === "league1")

const showManagerAutomationPanel = computed(() => {
  if (store.businessType !== "racingTeam") return false
  const lv = Number(store.businessData?.racingTeamManagerSkillLevel ?? 0)
  if (lv <= 0) return false
  return store.isRacingTeamLeague2Plus
})

const managerSkillLevel = computed(() => Number(store.businessData?.racingTeamManagerSkillLevel ?? 0))

const managerAutoAssign = computed(() => store.businessData?.racingTeamManagerAutoAssign === true)

const DEFAULT_MANAGER_INTERVAL_SEC = 1800

const MANAGER_INTERVAL_SHORT = {
  600: "10m",
  1200: "20m",
  1800: "30m",
  2700: "45m",
  3600: "60m",
}

function managerIntervalShortLabel (sec, fullLabel) {
  const n = Number(sec)
  if (MANAGER_INTERVAL_SHORT[n]) return MANAGER_INTERVAL_SHORT[n]
  const m = Math.round(n / 60)
  if (Number.isFinite(m) && m > 0) return `${m}m`
  return String(fullLabel || sec)
}

const managerIntervalOptions = computed(() => {
  const opts = store.businessData?.racingTeamManagerAssignIntervalOptions
  const list = Array.isArray(opts) && opts.length
    ? opts
    : [
        { sec: 600, label: "10 minutes" },
        { sec: 1200, label: "20 minutes" },
        { sec: 1800, label: "30 minutes" },
        { sec: 2700, label: "45 minutes" },
        { sec: 3600, label: "60 minutes" },
      ]
  return list.map((o) => {
    const value = Number(o.sec)
    const label = String(o.label || o.sec)
    return {
      value,
      label,
      shortLabel: managerIntervalShortLabel(value, label),
    }
  })
})

const managerIntervalModel = ref(DEFAULT_MANAGER_INTERVAL_SEC)

watch(
  () => store.businessData?.racingTeamManagerAssignIntervalSec,
  (sec) => {
    const n = Number(sec)
    if (!Number.isFinite(n) || n <= 0) return
    if (managerIntervalOptions.value.some((o) => o.value === n)) {
      managerIntervalModel.value = n
    }
  },
  { immediate: true }
)

function formatManagerCountdown (seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0))
  const m = Math.floor(s / 60)
  const r = s % 60
  if (m <= 0) return `${r}s`
  return r > 0 ? `${m}m ${r}s` : `${m}m`
}

const managerIntervalCountdownSec = computed(() => {
  void scheduleUiSecondTick.value
  if (!managerAutoAssign.value) return null
  const due = Number(store.businessData?.racingTeamManagerNextAssignWallEpoch)
  if (Number.isFinite(due) && due > 0) {
    return Math.max(0, Math.floor(due - Date.now() / 1000))
  }
  const rem = Number(store.businessData?.racingTeamManagerAssignIntervalRemainingSec)
  return Number.isFinite(rem) ? Math.max(0, Math.floor(rem)) : null
})

const managerBookingTimerText = computed(() => {
  if (!showManagerAutomationPanel.value || !managerAutoAssign.value) return null
  const sec = managerIntervalCountdownSec.value
  if (sec === null) return null
  return `Next booking in ~${formatManagerCountdown(sec)}`
})

const managerAutoToggleBusy = ref(false)
const managerIntervalBusy = ref(false)
let managerReloadThrottle = 0

function selectManagerInterval (sec) {
  const n = Number(sec)
  if (!Number.isFinite(n) || n <= 0 || managerIntervalBusy.value) return
  if (managerIntervalModel.value === n) return
  managerIntervalModel.value = n
}

async function onManagerAutoToggle (ev) {
  const enabled = ev.target.checked
  managerAutoToggleBusy.value = true
  try {
    await lua.career_modules_business_racingTeam.setRacingTeamManagerAutoAssign(store.businessId, enabled)
    await store.loadBusinessData(store.businessType, store.businessId)
  } catch (err) {
    console.error("[BusinessRacingTab] setRacingTeamManagerAutoAssign", err)
  } finally {
    managerAutoToggleBusy.value = false
  }
}

watch(managerIntervalModel, async (sec, prevSec) => {
  if (sec === prevSec || managerIntervalBusy.value) return
  if (!Number.isFinite(sec) || sec <= 0) return
  const stored = Number(store.businessData?.racingTeamManagerAssignIntervalSec)
  if (sec === stored) return
  managerIntervalBusy.value = true
  try {
    await lua.career_modules_business_racingTeam.setRacingTeamManagerAssignInterval(store.businessId, sec)
    await store.loadBusinessData(store.businessType, store.businessId)
  } catch (err) {
    console.error("[BusinessRacingTab] setRacingTeamManagerAssignInterval", err)
    const rollback = Number.isFinite(stored) && stored > 0 ? stored : DEFAULT_MANAGER_INTERVAL_SEC
    managerIntervalModel.value = rollback
  } finally {
    managerIntervalBusy.value = false
  }
})

async function onManagerSettingsUpdated (data) {
  if (!data || String(data.businessId) !== String(store.businessId)) return
  if (!store.businessType || !store.businessId) return
  await store.loadBusinessData(store.businessType, store.businessId)
}

const driversWithScheduledRaces = computed(() => {
  void store.racingTeamCareerSimTime
  void scheduleUiSecondTick.value
  const list = store.techs
  if (!Array.isArray(list)) return []
  const rows = []
  for (const t of list) {
    if (!t || t.fired || !t.pendingRaceOffer) continue
    const pr = t.pendingRaceOffer
    const useWallClock = Number.isFinite(Number(pr.scheduledRaceReadyWallEpoch ?? t.scheduledRaceReadyWallEpoch))
    const remaining = remainingSecondsForScheduledDriver(t)
    rows.push({
      key: `sched-${t.id}-${pr.id ?? ""}`,
      driverId: t.id,
      driverName: t.name || `Driver #${t.id}`,
      offer: pr,
      scheduledRaceReady: remaining !== null ? remaining <= 0 : t.scheduledRaceReady === true,
      secondsUntilScheduledRace: remaining ?? 0,
      useWallClock,
    })
  }
  return rows
})

const formatWaitText = (seconds, useWallClock) => {
  if (!useWallClock && (store.racingTeamCareerSimTime === null || store.racingTeamCareerSimTime === undefined)) {
    if (Number.isFinite(seconds) && seconds > 0) {
      const s = Math.max(0, Math.floor(seconds))
      const minutes = Math.floor(s / 60)
      const secs = s % 60
      return minutes > 0 ? `Ready in ~${minutes}m ${secs}s (syncing…)` : `Ready in ~${secs}s (syncing…)`
    }
    return "Syncing countdown…"
  }
  if (!Number.isFinite(seconds) || seconds <= 0) return "Not ready yet"
  const s = Math.max(0, Math.floor(seconds))
  const minutes = Math.floor(s / 60)
  const secs = s % 60
  if (minutes > 0) {
    return `Ready in ${minutes}m ${secs}s`
  }
  return `Ready in ${secs}s`
}

const raceOffers = computed(() => {
  const list = store.businessData?.raceOffers
  return Array.isArray(list) ? list : []
})

const availableDrivers = computed(() => {
  const list = store.techs
  if (!Array.isArray(list)) return []
  return list.filter((t) => t && !t.fired && !t.pendingRaceOffer)
})

const raceOffersMessage = computed(() => store.businessData?.raceOffersMessage || "")

const formatMoney = (n) => {
  const v = Number(n)
  if (!Number.isFinite(v)) return "$0"
  return `$${Math.round(v).toLocaleString()}`
}

const formatClassLabel = (label, classPwMin, classPwMax, branch) => {
  const source = Number.isFinite(Number(classPwMin)) ? classPwMin : classPwMax
  return formatSanctionedClassWithBucket(label, source, branch)
}

/** League 1 accept: Lua reason strings → in-game toast (Lua already ui_messages some cases). */
const LEAGUE1_ACCEPT_TOAST = {
  not_eligible_pw: "This car is outside the race power-to-weight bracket (too high or bracket read failed).",
  fleet_power_weight_unknown:
    "Cannot read this car's power-to-weight (dyno or weight missing). Run a dyno on it or pick another vehicle.",
  insufficient_funds: "Not enough team funds for the entry fee.",
  offer_not_on_board: "That offer is no longer on the board — refresh and pick again.",
  bad_fleet_vehicle: "Fleet vehicle not found. Pull the car from inventory or reload.",
  wrong_league: "League 1 sanctioned board is required for player races from this screen.",
  missing_args: "Missing race or vehicle selection.",
  sanctioned_module_missing: "Sanctioned racing module unavailable. Check the mod install.",
  player_cooldown: "You're still recovering from your last race. Wait for your cooldown to clear.",
}

/** Inventory ids may be 0; JS treats 0 as falsy — do not use !tech.fleetVehicleId for UI gating. */
const hasFleetVehicleAssigned = (tech) => {
  if (!tech) return false
  const id = tech.fleetVehicleId
  if (id === undefined || id === null) return false
  if (id === "") return false
  if (typeof id === "number" && !Number.isFinite(id)) return false
  return true
}

const isDriverOnPostRaceCooldown = (tech) => remainingSecondsForPostRaceCooldown(tech) > 0

const formatPostRaceCooldownText = (tech) => formatCooldownCounter(remainingSecondsForPostRaceCooldown(tech))

const onAccept = (offer) => {
  if (!offer || offer.id === undefined || offer.id === null) return
  selectedOffer.value = offer
}

const onDeclineRaceOffer = async (offer) => {
  if (!offer || offer.id === undefined || offer.id === null) return
  const oid = String(offer.id)
  decliningOfferId.value = oid
  try {
    const ok = await store.declineRacingTeamRaceOffer(offer.id)
    if (ok) {
      await store.loadBusinessData(store.businessType, store.businessId)
      if (selectedOffer.value && String(selectedOffer.value.id) === oid) {
        clearSelectedOffer()
      }
    }
  } finally {
    decliningOfferId.value = null
  }
}

const onOfferDetailBack = () => {
  if (league1FleetPickerOpen.value) {
    cancelLeague1FleetPicker()
    return
  }
  if (league2FleetPickerOpen.value) {
    cancelLeague2FleetPicker()
    return
  }
  clearSelectedOffer()
}

const clearSelectedOffer = () => {
  driverPickerOpen.value = false
  league1FleetPickerOpen.value = false
  league1FleetOptions.value = []
  league1FleetLoading.value = false
  raceLeague1BusyVehicleId.value = null
  league2FleetPickerOpen.value = false
  league2FleetOptions.value = []
  league2FleetLoading.value = false
  raceLeague2BusyVehicleId.value = null
  selectedOffer.value = null
}

const onAssignDriver = () => {
  if (isLeague1.value) return
  driverPickerOpen.value = true
}

const cancelLeague1FleetPicker = () => {
  league1FleetPickerOpen.value = false
  league1FleetOptions.value = []
  league1FleetLoading.value = false
  raceLeague1BusyVehicleId.value = null
}

const openLeague1FleetPicker = async () => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null) return
  league1FleetPickerOpen.value = true
  league1FleetLoading.value = true
  league1FleetOptions.value = []
  try {
    const opts = await store.listLeague1FleetVehiclesForSanctionedOffer(offer.id)
    league1FleetOptions.value = Array.isArray(opts) ? opts : []
    if (!league1FleetOptions.value.length) {
      try {
        lua.ui_message(
          "No fleet vehicle matches this race HP class. Buy or tune a car in the bracket shown on the offer.",
          9,
          "Racing Team",
          "warning"
        )
      } catch (e) {
      }
      league1FleetPickerOpen.value = false
    }
  } catch (e) {
    console.error("[BusinessRacingTab] openLeague1FleetPicker", e)
    league1FleetPickerOpen.value = false
  } finally {
    league1FleetLoading.value = false
  }
}

const cancelLeague2FleetPicker = () => {
  league2FleetPickerOpen.value = false
  league2FleetOptions.value = []
  league2FleetLoading.value = false
  raceLeague2BusyVehicleId.value = null
}

const openLeague2FleetPicker = async () => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null) return
  league2FleetPickerOpen.value = true
  league2FleetLoading.value = true
  league2FleetOptions.value = []
  try {
    const opts = await store.listLeague2FleetVehiclesForSanctionedOffer(offer.id)
    league2FleetOptions.value = Array.isArray(opts) ? opts : []
    if (!league2FleetOptions.value.length) {
      try {
        lua.ui_message(
          "No fleet vehicle matches this race power-to-weight class. Tune or assign a car in the bracket shown.",
          9,
          "Racing Team",
          "warning"
        )
      } catch (e) {
      }
      league2FleetPickerOpen.value = false
    }
  } catch (e) {
    console.error("[BusinessRacingTab] openLeague2FleetPicker", e)
    league2FleetPickerOpen.value = false
  } finally {
    league2FleetLoading.value = false
  }
}

const confirmLeague2RaceWithFleet = async (fv) => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null || !fv) return
  const vid = fv.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  raceLeague2BusyVehicleId.value = vid
  try {
    const res = await store.acceptRacingTeamRaceOfferAsPlayerAlongsideProxy(offer.id, vid)
    if (res === "out_of_class" || String(res || "").toLowerCase() === "out_of_class") {
      vehicleOutOfClassModalOpen.value = true
      return
    }
    if (res === "vehicle_cooldown" || String(res || "").toLowerCase() === "vehicle_cooldown") {
      vehicleOnCooldownModalOpen.value = true
      return
    }
    if (res !== true) {
      const key = typeof res === "string" ? String(res).toLowerCase() : ""
      const specific = key ? LEAGUE1_ACCEPT_TOAST[key] : null
      try {
        if (specific) {
          lua.ui_message(specific, 10, "Racing Team", "warning")
        } else if (res === false || res == null || res === "") {
          lua.ui_message(
            "Could not start this race. The offer may no longer be on the board, the team account may not cover the entry fee, or a sanctioned race may already be active.",
            8,
            "Racing Team",
            "error"
          )
        } else if (typeof res === "string" && res.length > 0) {
          lua.ui_message(`Could not start this race (${res}).`, 9, "Racing Team", "warning")
        }
      } catch (e) {
        /* ignore */
      }
      return
    }
    await store.loadBusinessData(store.businessType, store.businessId)
    clearSelectedOffer()
    try {
      lua.ui_message("Go to race set. Drive to staging to begin.", 6, "Racing Team", "info")
    } catch (e) {
    }
    if (store.exitBusinessComputerToPlay) {
      store.exitBusinessComputerToPlay()
    }
  } finally {
    raceLeague2BusyVehicleId.value = null
  }
}

const confirmLeague1RaceWithFleet = async (fv) => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null || !fv) return
  const vid = fv.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  raceLeague1BusyVehicleId.value = vid
  try {
    // eslint-disable-next-line no-console
    console.warn("[L1PLAYER] confirmLeague1RaceWithFleet", { offerId: offer.id, fleetVehicleId: vid })
    const res = await store.acceptRacingTeamRaceOfferAsPlayer(offer.id, vid)
    // eslint-disable-next-line no-console
    console.warn("[L1PLAYER] acceptRacingTeamRaceOfferAsPlayer result", res)
    if (res === "out_of_class" || String(res || "").toLowerCase() === "out_of_class" || vehicleOutOfClassModalOpen.value) {
      vehicleOutOfClassModalOpen.value = true
      return
    }
    if (res === "vehicle_cooldown" || String(res || "").toLowerCase() === "vehicle_cooldown" || vehicleOnCooldownModalOpen.value) {
      vehicleOnCooldownModalOpen.value = true
      return
    }
    if (res !== true) {
      const key = typeof res === "string" ? String(res).toLowerCase() : ""
      const specific = key ? LEAGUE1_ACCEPT_TOAST[key] : null
      try {
        if (specific) {
          lua.ui_message(specific, 10, "Racing Team", "warning")
        } else if (res === false || res == null || res === "") {
          lua.ui_message(
            "Could not start this race. The offer may no longer be on the board, the team account may not cover the entry fee, or a sanctioned race may already be active.",
            8,
            "Racing Team",
            "error"
          )
        } else if (typeof res === "string" && res.length > 0) {
          lua.ui_message(`Could not start this race (${res}).`, 9, "Racing Team", "warning")
        }
      } catch (e) {
        /* ignore */
      }
      return
    }
    await store.loadBusinessData(store.businessType, store.businessId)
    clearSelectedOffer()
    try {
      lua.ui_message("Go to race set. Drive to staging to begin.", 6, "Racing Team", "info")
    } catch (e) {
    }
    if (store.exitBusinessComputerToPlay) {
      store.exitBusinessComputerToPlay()
    }
  } finally {
    raceLeague1BusyVehicleId.value = null
  }
}

const cancelDriverPicker = () => {
  driverPickerOpen.value = false
}

const confirmRaceWithDriver = async (tech) => {
  const offer = selectedOffer.value
  if (!offer || offer.id === undefined || offer.id === null || !tech) return
  if (!hasFleetVehicleAssigned(tech)) return
  await store.loadBusinessData(store.businessType, store.businessId)
  const fresh = store.techs.find((x) => x && Number(x.id) === Number(tech.id))
  if (fresh && isDriverOnPostRaceCooldown(fresh)) {
    try {
      lua.ui_message(
        `${fresh.name || "Driver"} is still recovering from their last race (${formatPostRaceCooldownText(fresh)} left).`,
        7,
        "Racing Team",
        "warning"
      )
    } catch (e) {
    }
    return
  }
  const accepted = await store.acceptRacingTeamRaceOffer(offer.id, tech.id)
  if (accepted === "out_of_class" || String(accepted || "").toLowerCase() === "out_of_class" || vehicleOutOfClassModalOpen.value) {
    vehicleOutOfClassModalOpen.value = true
    return
  }
  if (accepted === "vehicle_cooldown" || String(accepted || "").toLowerCase() === "vehicle_cooldown" || vehicleOnCooldownModalOpen.value) {
    vehicleOnCooldownModalOpen.value = true
    return
  }
  if (accepted !== true) {
    const key = typeof accepted === "string" ? String(accepted).toLowerCase() : ""
    const specific = key ? LEAGUE1_ACCEPT_TOAST[key] : null
    try {
      if (specific) {
        lua.ui_message(specific, 10, "Racing Team", "warning")
      } else if (!accepted) {
        lua.ui_message(
          "Could not accept this race. The offer may have expired, the fleet car may be invalid, or the car may not match the sanctioned class.",
          7,
          "Racing Team",
          "error"
        )
      } else if (typeof accepted === "string" && accepted.length > 0) {
        lua.ui_message(`Could not accept this race (${accepted}).`, 8, "Racing Team", "warning")
      }
    } catch (e) {
      /* ignore */
    }
    return
  }
  driverPickerOpen.value = false
  clearSelectedOffer()
  await store.loadBusinessData(store.businessType, store.businessId)
}

const isOutOfSpecErr = (err) => {
  const e = String(err || "")
  return e === "fleet_hp_over_class_max" || e === "fleet_hp_under_class_min" || e === "fleet_hp_bracket_mismatch"
}

const armScheduledErrMessage = (err) => {
  const m = {
    no_pending_race_offer: "That driver has no scheduled race.",
    race_not_scheduled_yet: "Race time not reached yet.",
    invalid_driver: "Invalid driver.",
    no_valid_fleet_vehicle: "Driver needs a valid fleet vehicle.",
    missing_business_or_driver: "Missing business or driver.",
    no_business: "No business selected.",
    fleet_hp_over_class_max: "Fleet car is too powerful for this race class.",
    fleet_hp_under_class_min: "Fleet car is below the minimum HP for this race class.",
    fleet_hp_bracket_mismatch: "Fleet car does not match the race HP class.",
    lua_error: "Something went wrong. Check the log.",
    no_proxy_flow: "Race flow extension is not ready. Restart the game or verify the mod install.",
    no_staging_spot: "No track staging spot (player_stage_track) on this map.",
    no_inventory: "Business inventory is not available.",
    teleport_failed: "Could not place the team car at staging.",
    enter_vehicle_failed: "Could not switch you into the team car.",
    begin_failed: "Staging did not complete. Check the log.",
    unknown_error: "Could not start spectate (no error detail from the game).",
  }
  return m[err] || (err ? String(err) : "Could not start the race.")
}

const proxyRaceErrMessage = (err) => {
  const m = {
    no_proxy_request: "No armed team race. Accept an offer and arm the proxy driver first.",
    sanctioned_phone_active: "Finish or cancel the sanctioned race from your phone first.",
    race_or_staging_active: "A race or staging is already in progress.",
    in_pursuit: "Cannot start while in a pursuit.",
    no_staging_spot: "No track staging spot (player_stage_track) on this map.",
    no_inventory: "Business inventory is not available.",
    teleport_failed: "Could not place the team car at staging.",
    enter_vehicle_failed: "Could not switch you into the team car.",
    no_business: "No business selected.",
    no_track_flow: "Track flow is not available.",
    no_proxy_flow: "Race flow extension is not ready. Restart the game or verify the mod install.",
    lua_error: "Something went wrong. Check the log.",
    begin_failed: "Staging did not complete. Check the log.",
    unknown_error: "Could not go to grid (no error detail from the game).",
  }
  return m[err] || (err ? String(err) : "Could not start the race.")
}

const dropScheduledErrMessage = (err) => {
  const m = {
    no_pending_race_offer: "That driver has no scheduled race to drop.",
    missing_business_or_driver: "Missing business or driver.",
    no_business: "No business selected.",
    no_racing_team: "Racing team module is not available.",
    lua_error: "Something went wrong. Check the log.",
  }
  return m[err] || (err ? String(err) : "Could not drop out of the scheduled race.")
}

const dropScheduledRace = async (driverId) => {
  if (driverId === undefined || driverId === null) return
  dropScheduledBusyId.value = driverId
  try {
    const res = await store.cancelRacingTeamProxyScheduledRace(driverId)
    if (res && res.ok) {
      await store.loadBusinessData(store.businessType, store.businessId)
      try {
        lua.ui_message("Scheduled team race withdrawn. Entry fee refunded when applicable.", 7, "Racing Team", "info")
      } catch (e) {
      }
    } else if (res && res.err) {
      try {
        lua.ui_message(dropScheduledErrMessage(res.err), 6, "Racing Team", "error")
      } catch (e) {
      }
    }
  } finally {
    dropScheduledBusyId.value = null
  }
}

const startScheduledRaceSpectate = async (driverId) => {
  if (driverId === undefined || driverId === null) return
  armScheduledBusyId.value = driverId
  try {
    const res = await store.simulateRacingTeamProxyRace({ driverId })
    if (res && res.ok === true) {
      await store.loadBusinessData(store.businessType, store.businessId)
      try {
        lua.ui_message(
          "Team race spectate started from your scheduled row.",
          8,
          "Racing Team",
          "info"
        )
      } catch (e) {
      }
      store.exitBusinessComputerToPlay()
      return
    }
    const err = res && res.err ? res.err : "unknown_error"
    let showOos = isOutOfSpecErr(err)
    if (!showOos) {
      try {
        const chk = await store.isProxyScheduledDriverFleetOverpowered(driverId)
        showOos = !!(chk && chk.overpowered)
      } catch (e) {
      }
    }
    if (showOos) {
      vehicleOutOfClassModalOpen.value = true
      return
    }
    try {
      lua.ui_message(armScheduledErrMessage(err), 6, "Racing Team", "error")
    } catch (e) {
    }
  } finally {
    armScheduledBusyId.value = null
  }
}

const onRaceFromGarage = async () => {
  if (raceFromGarageBusy.value) return
  raceFromGarageBusy.value = true
  try {
    const res = await store.beginRacingTeamProxyRaceFromBusinessComputer()
    if (res && res.ok === true) {
      try {
        lua.ui_message("Team car placed at staging.", 4, "Racing Team", "info")
      } catch (e) {
      }
      await store.loadBusinessData(store.businessType, store.businessId)
      store.exitBusinessComputerToPlay()
      return
    }
    const err = res && res.err ? res.err : "unknown_error"
    let showOos = isOutOfSpecErr(err)
    if (!showOos) {
      try {
        const chk = await store.isArmedProxyFleetOverpoweredForRequest()
        showOos = !!(chk && chk.overpowered)
      } catch (e) {
      }
    }
    if (showOos) {
      vehicleOutOfClassModalOpen.value = true
      return
    }
    try {
      lua.ui_message(proxyRaceErrMessage(err), 6, "Racing Team", "error")
    } catch (e) {
    }
  } finally {
    raceFromGarageBusy.value = false
  }
}
</script>

<style scoped lang="scss">
.manager-auto-panel {
  margin: 0;
  padding: 0.85rem 1rem;
  border-radius: 10px;
  background: rgba(20, 26, 32, 0.85);
  border: 1px solid rgba(245, 73, 0, 0.22);
}
.manager-auto-panel__row {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  justify-content: space-between;
  gap: 0.75rem 1rem;
}
.manager-auto-panel__heading {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.35rem;
  min-width: 0;
  flex: 1 1 12rem;
}
.manager-auto-panel__title-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.35rem 0.5rem;
  width: 100%;
}
.manager-auto-panel__title {
  margin: 0;
  font-size: 1em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.92);
}
.manager-auto-toggle {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.88);
  cursor: pointer;
  user-select: none;
  flex-shrink: 0;

  input[type="checkbox"] {
    position: absolute;
    opacity: 0;
    width: 0;
    height: 0;
    pointer-events: none;
  }

  &__slider {
    position: relative;
    width: 22px;
    height: 12px;
    flex-shrink: 0;
    background: rgba(255, 255, 255, 0.22);
    border-radius: 6px;
    transition: background-color 0.2s ease;

    &::before {
      content: "";
      position: absolute;
      top: 2px;
      left: 2px;
      width: 8px;
      height: 8px;
      background: #fff;
      border-radius: 50%;
      transition: transform 0.2s ease;
    }
  }

  input[type="checkbox"]:checked + &__slider {
    background: rgba(245, 73, 0, 0.95);
  }

  input[type="checkbox"]:checked + &__slider::before {
    transform: translateX(10px);
  }

  &__label {
    line-height: 1.2;
  }

  &--disabled {
    opacity: 0.55;
    cursor: default;
  }
}
.manager-auto-panel__interval {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.3rem;
  width: 100%;
}
.manager-auto-interval-text {
  font-size: 0.82rem;
  color: rgba(255, 255, 255, 0.82);
}
.manager-interval-pills {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35rem;
}
.manager-interval-pill {
  margin: 0;
  padding: 0.22rem 0.55rem;
  border-radius: 4px;
  border: 1px solid rgba(255, 255, 255, 0.22);
  background: rgba(0, 0, 0, 0.32);
  color: rgba(255, 255, 255, 0.88);
  font-size: 0.78rem;
  font-weight: 600;
  line-height: 1.2;
  cursor: pointer;
  transition: border-color 0.15s, background 0.15s;

  &.active {
    border-color: rgba(245, 73, 0, 0.95);
    background: rgba(245, 73, 0, 0.22);
    color: #fff;
  }

  &:hover:not(:disabled):not(.active) {
    border-color: rgba(245, 73, 0, 0.55);
  }

  &:disabled {
    opacity: 0.5;
    cursor: default;
  }
}
.manager-auto-panel--phone {
  margin: 0;
  padding: 0.5rem 0.6rem;

  .manager-auto-panel__row {
    gap: 0;
  }

  .manager-auto-panel__heading {
    gap: 0.2rem;
    width: 100%;
    flex: 1 1 100%;
  }

  .manager-auto-panel__title {
    font-size: 0.9em;
  }

  .manager-auto-toggle {
    font-size: 0.78em;
    gap: 0.3rem;

    .manager-auto-toggle__slider {
      width: 20px;
      height: 11px;

      &::before {
        width: 7px;
        height: 7px;
      }
    }

    input[type="checkbox"]:checked + .manager-auto-toggle__slider::before {
      transform: translateX(9px);
    }
  }

  .manager-auto-interval-text {
    font-size: 0.75rem;
  }

  .manager-interval-pills {
    gap: 0.25rem;
  }

  .manager-interval-pill {
    padding: 0.14rem 0.38rem;
    font-size: 0.68rem;
  }

  .manager-auto-panel__countdown {
    margin-top: 0.1rem;
    font-size: 0.72rem;
  }
}
.racing-tab__manager-booking-timer {
  margin: 0.2rem 0 0;
  font-size: 0.85rem;
  font-weight: 500;
  color: rgba(245, 180, 120, 0.95);
}

.manager-auto-panel__countdown {
  margin: 0.15rem 0 0;
  font-size: 0.8rem;
  opacity: 0.85;
  color: rgba(245, 180, 120, 0.95);
}

.manager-auto-panel__hint {
  margin: 0.35rem 0 0;
  font-size: 0.78em;
  line-height: 1.35;
  color: rgba(255, 255, 255, 0.48);
}

.racing-tab--phone {
  flex: 1;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: auto;
  gap: 0.65em;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  padding-bottom: 0.85em;
  box-sizing: border-box;

  .tab-header {
    display: none;
  }

  .proxy-race-banner {
    padding: 0.55em 0.65em;
    gap: 0.45em;
  }

  .proxy-race-banner__text {
    font-size: 0.78em;
    flex: 1 1 100%;
  }

  .proxy-race-banner__race {
    font-size: 0.78em;
    min-width: 0;
  }

  .info-banner {
    padding: 0.55em 0.65em;
    font-size: 0.78em;
  }

  .races-section__title {
    font-size: 0.88em;
  }

  .offers-list {
    gap: 0.45em;
    width: 100%;
  }

  .offer-row {
    padding: 0;
    border: none;
    background: transparent;
  }

  .offer-row :deep(.race-offer-card) {
    padding: 0.65em 0.7em;
    gap: 0.5em;
  }

  .offer-row :deep(.race-offer-card__title) {
    font-size: 0.88em;
  }

  .offer-row :deep(.race-offer-card__laps) {
    font-size: 0.72em;
  }

  .offer-row :deep(.race-offer-place__value) {
    font-size: 0.92em;
  }

  .offer-row :deep(.race-offer-card__actions .btn) {
    font-size: 0.74em;
    padding: 0.4em 0.55em;
  }

  .offer-detail {
    padding: 0.65em 0.7em;
    gap: 0.5em;
  }

  .detail-meta {
    font-size: 0.78em;

    .label {
      min-width: 4.5em;
    }
  }

  .offer-detail__actions .btn {
    padding: 0.4em 0.65em;
    font-size: 0.78em;
  }

  .empty-state {
    padding: 1em;
    font-size: 0.85em;
  }

  .driver-picker-title {
    font-size: 0.85em;
  }

  .driver-picker-hint {
    font-size: 0.72em;
  }

  .driver-picker-actions .btn {
    padding: 0.4em 0.65em;
    font-size: 0.78em;
  }
}

.racing-tab {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
}

.tab-header {
  .header-content {
    h2 {
      margin: 0;
      color: rgba(245, 73, 0, 1);
      font-size: 1.5em;
    }
  }
}

.proxy-race-banner {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 1em;
  padding: 1em 1.2em;
  border-radius: 0.75em;
  background: rgba(40, 32, 20, 0.92);
  border: 1px solid rgba(245, 73, 0, 0.45);
}

.proxy-race-banner__text {
  margin: 0;
  flex: 1 1 12em;
  font-size: 0.92em;
  line-height: 1.45;
  color: rgba(255, 255, 255, 0.88);
}

.proxy-race-banner__race {
  flex-shrink: 0;
  min-width: 6em;
}

.info-banner {
  margin: 0;
  padding: 1em 1.2em;
  border-radius: 0.75em;
  background: rgba(20, 28, 36, 0.85);
  border: 1px solid rgba(255, 255, 255, 0.1);
  color: rgba(255, 255, 255, 0.75);
  font-size: 0.95em;
  line-height: 1.45;
}

.races-section {
  display: flex;
  flex-direction: column;
  gap: 0.65em;
  min-width: 0;
}

.races-section__title {
  margin: 0;
  font-size: 1em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.92);
  line-height: 1.2;
}

.empty-state {
  padding: 2em;
  text-align: center;
  color: rgba(255, 255, 255, 0.45);
  border: 1px dashed rgba(255, 255, 255, 0.12);
  border-radius: 0.75em;
}

.offer-detail {
  padding: 1.25em 1.35em;
  border-radius: 0.75em;
  background: rgba(20, 28, 36, 0.92);
  border: 1px solid rgba(245, 73, 0, 0.28);
  display: flex;
  flex-direction: column;
  gap: 0.85em;
}

.offer-detail__back {
  align-self: flex-start;
}

.detail-meta {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  font-size: 0.92em;
  color: rgba(255, 255, 255, 0.82);
  .label {
    color: rgba(255, 255, 255, 0.45);
    margin-right: 0.5em;
    min-width: 5.5em;
    display: inline-block;
  }
}

.offer-detail__actions {
  margin-top: 0.15em;
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em;
  align-items: center;
}

.offers-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.65em;
  width: 100%;
}

.offer-row {
  min-width: 0;
}

.offer-grid-item {
  min-width: 0;
  height: 100%;
}

.offer-grid-item :deep(.race-offer-card) {
  height: 100%;
}

.offers-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 1.25em;
}

.offer-title {
  margin: 0;
  font-size: 1.05em;
  font-weight: 600;
  color: #fff;
  line-height: 1.3;
}

.btn {
  padding: 0.55em 1.25em;
  border-radius: 8px;
  font-weight: 600;
  font-size: 0.9em;
  cursor: pointer;
  border: none;
  transition: background 0.15s, opacity 0.15s;
}

.btn-primary {
  background: rgba(245, 73, 0, 0.9);
  color: #fff;
  &:hover:not(:disabled) {
    background: rgba(255, 100, 30, 1);
  }
  &:disabled {
    opacity: 0.5;
    cursor: default;
  }
}

.btn-secondary {
  background: rgba(40, 52, 64, 0.95);
  color: rgba(255, 255, 255, 0.92);
  border: 1px solid rgba(245, 73, 0, 0.35);
  &:hover:not(:disabled) {
    border-color: rgba(245, 73, 0, 0.55);
    background: rgba(50, 64, 78, 0.98);
  }
  &:disabled {
    opacity: 0.5;
    cursor: default;
  }
}

.offer-detail__driver-picker {
  margin-top: 0.5em;
  padding-top: 0.75em;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
}
.driver-picker-title {
  margin: 0 0 0.5em;
  font-size: 0.95em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.9);
}
.driver-picker-hint {
  margin: 0 0 0.75em;
  font-size: 0.8em;
  line-height: 1.45;
  color: rgba(255, 255, 255, 0.5);
  strong {
    color: rgba(255, 200, 160, 0.9);
    font-weight: 600;
  }
}
.driver-picker-empty {
  margin: 0;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.45);
}
.driver-picker-list {
  list-style: none;
  margin: 0 0 0.75em;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}
.driver-picker-item {
  display: flex;
  flex-direction: column;
  gap: 0.45em;
  padding: 0.5em 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  &:last-child {
    border-bottom: none;
  }
}
.driver-picker-row-head {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 0.35em 0.5em;
  font-size: 0.9em;
  color: rgba(255, 255, 255, 0.88);
}
.driver-picker-row-titles {
  display: flex;
  flex-direction: column;
  gap: 0.15em;
  min-width: 0;
  flex: 1;
}
.driver-picker-class {
  font-size: 0.82em;
  font-weight: 600;
  color: rgba(255, 200, 160, 0.92);
}
.driver-picker-name {
  font-weight: 600;
}
.driver-picker-hp {
  margin-left: 0.5em;
  font-size: 0.85em;
  font-weight: 500;
  color: rgba(255, 255, 255, 0.55);
}
.driver-picker-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em;
}
.driver-picker-row {
  width: 100%;
  text-align: left;
}
.driver-picker-sub {
  font-weight: 400;
  opacity: 0.85;
  &.warn {
    color: rgba(255, 180, 120, 0.95);
  }
}

.modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
  backdrop-filter: blur(4px);
}
.modal-content {
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.6);
  border-radius: 0.5em;
  padding: 2em;
  max-width: 30em;
  width: 90%;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);

  h2 {
    margin: 0 0 0.75em;
    color: #fff;
    font-size: 1.4em;
    font-weight: 600;
  }
  p {
    margin: 0 0 1.25em;
    color: rgba(255, 255, 255, 0.8);
    line-height: 1.45;
  }
}
.modal-buttons {
  display: flex;
  justify-content: flex-end;
  gap: 0.5em;
}
.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.15s ease;
}
.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
}
</style>
