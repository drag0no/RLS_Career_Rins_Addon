<template>
  <div class="home-dashboard">
    <!-- Top Row: Garage Widget (Full Width) -->
    <div class="top-row">
      <HomeScheduledRacesWidget v-if="store.businessType === 'racingTeam'" />
      <HomeGarageWidget
        v-else
        @put-away="handlePutAway"
        @abandon="handleAbandon"
        @go-to-jobs="store.switchView('jobs')"
      />
    </div>

    <!-- Bottom Grid: Racing team = Finances (left) / Driver overview + Sponsorship (right). Tuning shop = Jobs (left) / Techs + Finances (right). -->
    <div class="dashboard-grid">
      <div class="dashboard-column main-column">
        <template v-if="store.businessType === 'racingTeam'">
          <HomeFinancesWidget />
        </template>
        <HomeJobsWidget
          v-else
          @pull-out="handlePullOut"
          @put-away="handlePutAway"
          @abandon="handleAbandon"
          @complete="handleComplete"
          @accept="handleAccept"
          @decline="handleDecline"
        />
      </div>

      <div class="dashboard-column side-column">
        <div
          class="side-stack"
          :class="{ 'side-stack--racing-team': store.businessType === 'racingTeam' }"
        >
          <template v-if="store.businessType === 'racingTeam'">
            <HomeJobsWidget
              @pull-out="handlePullOut"
              @put-away="handlePutAway"
              @abandon="handleAbandon"
              @complete="handleComplete"
              @accept="handleAccept"
              @decline="handleDecline"
            />
            <HomeSponsorshipWidget />
          </template>
          <template v-else>
            <HomeTechsWidget />
            <HomeFinancesWidget />
          </template>
        </div>
      </div>
    </div>

    <!-- Confirmation Modal -->
    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showAbandonModal" class="modal-overlay" @click.self="cancelAbandon">
          <div class="modal-content" ref="abandonModalRef">
            <h2>{{ isRacingTeamVehicleSell ? 'Sell vehicle' : 'Abandon Job' }}</h2>
            <p v-if="isRacingTeamVehicleSell">
              Sell this team vehicle? You will receive
              <span class="penalty-text">${{ saleProceeds.toLocaleString() }}</span> for the sale.
            </p>
            <p v-else>
              Are you sure you want to abandon this job? You will be charged a penalty of
              <span class="penalty-text">${{ penaltyCost.toLocaleString() }}</span>.
            </p>
            <div class="modal-buttons">
              <button class="btn btn-secondary" @click="cancelAbandon" data-focusable>Cancel</button>
              <button class="btn btn-danger" @click="confirmAbandon" data-focusable>
                {{ isRacingTeamVehicleSell ? 'Yes, Sell' : 'Yes, Abandon' }}
              </button>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <div
        v-if="vehicleOutOfClassModalOpen"
        class="modal-overlay"
        @click.self="vehicleOutOfClassModalOpen = false"
      >
        <div class="modal-content" @click.stop @mousedown.stop>
          <h2>Vehicle out of class</h2>
          <p>This car's effective HP is above the sanctioned HP class for the selected race. Choose another offer or switch to a car that matches the HP bracket.</p>
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
    </Teleport>
  </div>
</template>

<script setup>
import { computed, ref, Teleport, inject, watch, nextTick, onMounted, onUnmounted } from "vue"
import { useBridge } from "@/bridge"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import HomeJobsWidget from "./widgets/HomeJobsWidget.vue"
import HomeGarageWidget from "./widgets/HomeGarageWidget.vue"
import HomeScheduledRacesWidget from "./widgets/HomeScheduledRacesWidget.vue"
import HomeTechsWidget from "./widgets/HomeTechsWidget.vue"
import HomeFinancesWidget from "./widgets/HomeFinancesWidget.vue"
import HomeSponsorshipWidget from "./widgets/HomeSponsorshipWidget.vue"

const store = useBusinessComputerStore()
const { events } = useBridge()
const controllerNav = inject('controllerNav', null)
const abandonModalRef = ref(null)
const normalizeId = (id) => {
  if (id === undefined || id === null) return null
  const num = Number(id)
  return isNaN(num) ? String(id) : num
}

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)
const vehicleOutOfClassModalOpen = ref(false)

const handleVehicleOutOfClass = () => {
  vehicleOutOfClassModalOpen.value = true
}

onMounted(() => {
  events.on("racingTeam:vehicleOutOfClass", handleVehicleOutOfClass)
})
onUnmounted(() => {
  events.off("racingTeam:vehicleOutOfClass", handleVehicleOutOfClass)
})

const penaltyCost = computed(() => {
  if (!jobToAbandon.value) return 0
  return jobToAbandon.value.penalty || 0
})

const isRacingTeamVehicleSell = computed(() => store.businessType === "racingTeam")

const saleProceeds = computed(() => {
  if (!jobToAbandon.value) return 0
  const r = jobToAbandon.value.reward
  const n = typeof r === "number" ? r : Number(r)
  return Number.isFinite(n) ? n : 0
})

const pullOutDiag = (...args) => {
  try {
    console.debug("[rlsBizPull]", ...args)
  } catch (_) {}
}

const handlePullOut = async (job) => {
  if (job == null) {
    pullOutDiag("Home handlePullOut abort: no job", {})
    return
  }

  if (!Array.isArray(store.vehicles)) {
    pullOutDiag("Home handlePullOut abort: vehicles not array", { jobId: job.jobId ?? job.id })
    return
  }

  const jobId = job.jobId ?? job.id
  if (jobId === undefined || jobId === null) {
    pullOutDiag("Home handlePullOut abort: no job id", { job })
    return
  }

  const normalizedStoredVid = normalizeId(job?.storedVehicleId)
  let vehicle = null
  if (normalizedStoredVid !== null) {
    vehicle = store.vehicles.find(v => normalizeId(v?.vehicleId) === normalizedStoredVid) || null
  }
  if (!vehicle) {
    const normalizedJobId = normalizeId(jobId)
    vehicle = store.vehicles.find(v => {
      if (!v.jobId) return false
      const normalizedVehicleJobId = normalizeId(v.jobId)
      return normalizedVehicleJobId === normalizedJobId
    })
  }

  if (!vehicle) {
    pullOutDiag("Home handlePullOut abort: no matching vehicle (Lua pullOut never called)", {
      jobId,
      storedVehicleId: job?.storedVehicleId,
      fleetCount: store.vehicles.length,
    })
    return
  }

  pullOutDiag("Home handlePullOut calling store.pullOutVehicle", { jobId, vehicleId: vehicle.vehicleId })
  await store.pullOutVehicle(vehicle.vehicleId)
}

const handlePutAway = async () => {
  await store.putAwayVehicle()
}

const handleAbandon = (job) => {
  if (!job) {
    return
  }
  jobToAbandon.value = job
  showAbandonModal.value = true
}

const confirmAbandon = async () => {
  if (jobToAbandon.value) {
    await store.abandonJob(parseInt(jobToAbandon.value.id))
    showAbandonModal.value = false
    jobToAbandon.value = null
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  jobToAbandon.value = null
}

watch(showAbandonModal, (isOpen) => {
  if (!controllerNav) return
  if (isOpen) {
    nextTick(() => {
      if (abandonModalRef.value) {
        controllerNav.pushModal(abandonModalRef.value, cancelAbandon)
      }
    })
  } else if (abandonModalRef.value) {
    controllerNav.removeModal(abandonModalRef.value)
  }
})

const handleAccept = async (job) => {
  await store.acceptJob(parseInt(job.id))
}

const handleDecline = async (job) => {
  await store.declineJob(parseInt(job.id))
}

const handleComplete = async (job) => {
  const jobId = job.jobId ?? parseInt(job.id)
  await store.completeJob(jobId)
}
</script>

<style scoped lang="scss">
.home-dashboard {
  height: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  padding-bottom: 1em; 
  gap: 1.5em;
}

.top-row {
  flex-shrink: 0;
}

.dashboard-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 1.5em;
  min-height: 0; /* Allow children to scroll */
  flex: 1;
  overflow-y: auto; /* Allow grid to scroll if needed on small screens */
  
  @media (min-width: 1280px) {
    grid-template-columns: 1fr 1fr; /* 50% - 50% split as requested */
    overflow-y: hidden; /* Lock scroll on large screens */
  }
}

.dashboard-column {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
  min-height: 0;
  
  &.main-column {
    height: 100%;
    overflow: hidden;

    :deep(.finances-widget) {
      flex: 1;
      min-height: 0;
    }
  }
  
  &.side-column {
    height: 100%;
    overflow: hidden; /* Match main column - widgets handle their own scroll */
    min-height: 0;
  }
}

.side-stack {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
  height: 100%; /* Fill full height of side column */
  min-height: 0;

  :deep(.finances-widget),
  :deep(.sponsorship-widget),
  :deep(.techs-widget) {
    flex: 1;
    min-height: 0;
  }

  &.side-stack--racing-team {
    :deep(.jobs-widget) {
      flex: 0 1 auto;
      max-height: min(22rem, 48%);
      min-height: 0;
    }

    :deep(.sponsorship-widget) {
      flex: 1;
      min-height: 0;
    }
  }
}

/* Modal Styles */
.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
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
    margin: 0 0 1em 0;
    color: white;
    font-size: 1.5em;
    font-weight: 600;
  }
  
  p {
    margin: 0 0 2em 0;
    color: rgba(255, 255, 255, 0.8);
    font-size: 1em;
    line-height: 1.5;
  }

  .penalty-text {
    color: #F54900;
    font-weight: 600;
  }
  
  .modal-buttons {
    display: flex;
    gap: 1em;
    justify-content: flex-end;
  }
  
  .btn {
    padding: 0.55em 1.25em;
    border-radius: 8px;
    font-weight: 600;
    font-size: 0.9em;
    cursor: pointer;
    border: none;
    transition: background 0.15s, opacity 0.15s;

    &.btn-primary {
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

    &.btn-secondary {
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

    &.btn-danger {
      background: rgba(239, 68, 68, 1);
      color: white;
      &:hover:not(:disabled) {
        background: rgba(239, 68, 68, 0.9);
      }
      &:disabled {
        opacity: 0.5;
        cursor: default;
      }
    }
  }
}

.modal-buttons {
  display: flex;
  justify-content: flex-end;
  gap: 0.5em;
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s ease;
  
  .modal-content {
    transition: transform 0.2s ease, opacity 0.2s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
  
  .modal-content {
    transform: scale(0.95);
    opacity: 0;
  }
}
</style>
