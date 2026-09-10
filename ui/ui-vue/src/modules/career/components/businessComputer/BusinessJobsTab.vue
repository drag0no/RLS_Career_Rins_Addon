<template>
  <div class="jobs-tab">
    <div class="tab-header">
      <div class="header-content">
        <div>
          <h2>{{ store.businessType === 'racingTeam' ? 'Goals' : 'Jobs' }}</h2>
          <p>{{ store.businessType === 'racingTeam' ? 'Track goals and milestones for your racing program.' : ' Manage active work and available opportunities in one place' }}</p>
        </div>
        <button 
          v-if="store.businessType === 'tuningShop'"
          class="filters-button"
          @click.stop="openFiltersModal"
          @mousedown.stop="openFiltersModal"
          data-focusable
          title="Manage filters, notifications, and blacklists"
        >
          <span class="filters-icon">⚙</span>
          <span>Filters</span>
        </button>
      </div>
    </div>
    <RacingTeamPromoPanel
      v-if="store.businessType === 'racingTeam' && league2Invite.visible"
      variant="card"
      :title="league2Invite.popupTitle"
      :body="league2Invite.popupBody"
      :image-url="league2Invite.popupImageUrl"
      :fee="league2Invite.fee"
    >
      <button type="button" class="btn btn-secondary" data-focusable @click.stop="onLeague2InviteLaterJobs" @mousedown.stop>
        {{ league2Invite.laterLabel }}
      </button>
      <button type="button" class="btn btn-primary" data-focusable @click.stop="onLeague2InviteAcceptJobs" @mousedown.stop>
        {{ league2Invite.acceptLabel }}
      </button>
    </RacingTeamPromoPanel>
  <div
    v-if="store.businessType === 'racingTeam' && racingTeamCurrentGoal"
    class="current-goal-panel"
  >
    <div class="current-goal-panel__header">
      <span v-if="racingTeamCurrentGoal.tier != null" class="current-goal-panel__tier">Tier {{ racingTeamCurrentGoal.tier }}</span>
      <span v-else-if="racingTeamLeagueLabel" class="current-goal-panel__tier">{{ racingTeamLeagueLabel }}</span>
      <h3 class="current-goal-panel__title">{{ racingTeamCurrentGoal.title || 'Current goal' }}</h3>
    </div>
    <p class="current-goal-panel__description">{{ racingTeamCurrentGoal.description || '' }}</p>
    <div class="current-goal-panel__meta">
      <span><strong>Target:</strong> {{ racingTeamCurrentGoal.targetLabel || '—' }}</span>
      <span><strong>Progress:</strong> {{ racingTeamCurrentGoal.progressLabel || '—' }}</span>
    </div>
  </div>
    <div
      v-if="store.businessType === 'racingTeam' && racingTeamCompletedGoals.length"
      class="completed-goals-panel"
    >
      <h3 class="completed-goals-panel__heading">Completed goals</h3>
      <ul class="completed-goals-panel__list">
        <li v-for="cg in displayedCompletedGoals" :key="cg.id" class="completed-goals-panel__item">
          <span class="completed-goals-panel__title">{{ cg.title || cg.id }}</span>
          <span v-if="formatLeagueLabel(cg.league)" class="completed-goals-panel__league">{{ formatLeagueLabel(cg.league) }}</span>
          <span v-if="cg.description" class="completed-goals-panel__detail">{{ cg.description }}</span>
          <span v-if="cg.completedBestTimesSummary" class="completed-goals-panel__detail">{{ cg.completedBestTimesSummary }}</span>
        </li>
      </ul>
      <button
        v-if="hasHiddenCompletedGoals"
        type="button"
        class="btn btn-secondary completed-goals-panel__toggle"
        data-focusable
        @click.stop="completedGoalsExpanded = !completedGoalsExpanded"
        @mousedown.stop
      >
        {{ completedGoalsExpanded ? "Show less" : "Show more" }}
      </button>
    </div>
    <div v-if="showRecognitionBanner" class="recognition-banner">
      <div v-if="store.brandRecognitionUnlocked" class="recognition-section" @click.stop="openBrandModal"
        @mousedown.stop="openBrandModal" data-focusable>
        <span class="banner-label">Brand Recognition</span>
        <span class="banner-value">{{ brandSelectionDisplay }}</span>
      </div>

      <div v-if="store.brandRecognitionUnlocked && store.raceRecognitionUnlocked" class="summary-divider"></div>

      <div v-if="store.raceRecognitionUnlocked" class="recognition-section" @click.stop="openRaceModal"
        @mousedown.stop="openRaceModal" data-focusable>
        <span class="banner-label">Race Recognition</span>
        <span class="banner-value">{{ raceSelectionDisplay }}</span>
      </div>
    </div>

    <div v-if="store.businessType !== 'racingTeam' && (store.activeJobs.length || store.newJobs.length)" class="jobs-content">
      <!-- Active Jobs Section -->
      <div v-if="store.activeJobs.length > 0" class="job-section">
        <h3>Active Jobs</h3>
        <div class="jobs-grid">
          <template v-for="job in store.activeJobs" :key="`active-${job.id}`">
            <div class="job-card-wrapper" @click.stop="interceptEvent" @mousedown.stop="interceptEvent">
              <BusinessJobCard :job="job" :is-active="true" :business-id="store.businessId" layout="full"
                @pull-out="handlePullOut(job)" @put-away="handlePutAway(job)" @abandon="handleAbandon(job)"
                @complete="handleComplete(job)" />
            </div>
          </template>
        </div>
      </div>

      <!-- New Jobs Section -->
      <div v-if="store.newJobs.length > 0" class="job-section">
        <h3>New Jobs</h3>
        <div class="jobs-grid">
          <template v-for="job in store.newJobs" :key="`new-${job.id}`">
            <div class="job-card-wrapper" @click.stop="interceptEvent" @mousedown.stop="interceptEvent">
              <BusinessJobCard :job="job" :is-active="false" layout="full" @accept="handleAccept"
                @decline="handleDecline" />
            </div>
          </template>
        </div>
      </div>
    </div>

    <div v-else-if="store.businessType !== 'racingTeam'" class="empty-state">
      No jobs to show right now
    </div>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showAbandonModal && store.businessType !== 'racingTeam'" class="modal-overlay" @click.self.stop="cancelAbandon"
          @mousedown.self.stop="cancelAbandon">
          <div class="modal-content" ref="abandonModalRef">
            <h2>Abandon Job</h2>
            <p>
              Are you sure you want to abandon this job? You will be charged a penalty of
              <span class="penalty-text">${{ penaltyCost.toLocaleString() }}</span>.
            </p>
            <div class="modal-buttons">
              <button class="btn btn-secondary" @click.stop="cancelAbandon"
                @mousedown.stop="cancelAbandon" data-focusable>Cancel</button>
              <button class="btn btn-danger" @click.stop="confirmAbandon" @mousedown.stop="confirmAbandon" data-focusable>
                Yes, Abandon
              </button>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showBrandModal" class="modal-overlay" @click.self.stop="closeBrandModal"
          @mousedown.self.stop="closeBrandModal">
          <div class="modal-content selection-modal" @click.stop @mousedown.stop ref="brandModalRef">
            <div class="modal-header">
              <h2>Select Brand</h2>
              <button class="modal-close" @click.stop="closeBrandModal" @mousedown.stop="closeBrandModal" data-focusable>×</button>
            </div>
            <div class="modal-body">
              <div v-if="isLoadingBrands" class="modal-empty">
                <p>Loading brands...</p>
              </div>
              <div v-else-if="store.availableBrands.length === 0" class="modal-empty">
                <p>No brands available</p>
                <small>Try refreshing or check if vehicles are loaded</small>
              </div>
              <div v-else class="selection-list">
                <button class="selection-item" :class="{ 'selected': !store.brandSelection }"
                  @click.stop="selectBrand(null)" @mousedown.stop="selectBrand(null)" data-focusable>
                  <span>Clear Selection</span>
                </button>
                <button v-for="brand in store.availableBrands" :key="brand" class="selection-item"
                  :class="{ 'selected': store.brandSelection === brand }" @click.stop="selectBrand(brand)"
                  @mousedown.stop="selectBrand(brand)" data-focusable>
                  <span>{{ brand }}</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showRaceModal" class="modal-overlay" @click.self.stop="closeRaceModal"
          @mousedown.self.stop="closeRaceModal">
          <div class="modal-content selection-modal" @click.stop @mousedown.stop ref="raceModalRef">
            <div class="modal-header">
              <h2>Select Race Type</h2>
              <button class="modal-close" @click.stop="closeRaceModal" @mousedown.stop="closeRaceModal" data-focusable>×</button>
            </div>
            <div class="modal-body">
              <div v-if="isLoadingRaceTypes" class="modal-empty">
                <p>Loading race types...</p>
              </div>
              <div v-else-if="store.availableRaceTypes.length === 0" class="modal-empty">
                <p>No race types available</p>
                <small>Check if race data is loaded</small>
              </div>
              <div v-else class="selection-list">
                <button class="selection-item" :class="{ 'selected': !store.raceSelection }"
                  @click.stop="selectRace(null)" @mousedown.stop="selectRace(null)" data-focusable>
                  <span>Clear Selection</span>
                </button>
                <button v-for="raceType in store.availableRaceTypes" :key="raceType.id" class="selection-item"
                  :class="{ 'selected': store.raceSelection === raceType.id }" @click.stop="selectRace(raceType.id)"
                  @mousedown.stop="selectRace(raceType.id)" data-focusable>
                  <span>{{ raceType.label }}</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <FiltersModal :show="showFiltersModal" @close="closeFiltersModal" />
  </div>
</template>

<script setup>
import { computed, ref, Teleport, onMounted, onUnmounted, watch, inject, nextTick } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { useBridge } from "@/bridge"
import BusinessJobCard from "./BusinessJobCard.vue"
import FiltersModal from "./FiltersModal.vue"
import RacingTeamPromoPanel from "../RacingTeamPromoPanel.vue"
import { normalizeId } from "../../utils/businessUtils"

const store = useBusinessComputerStore()
const controllerNav = inject('controllerNav', null)
const abandonModalRef = ref(null)
const brandModalRef = ref(null)
const raceModalRef = ref(null)
const { events } = useBridge()

const showAbandonModal = ref(false)
const jobToAbandon = ref(null)
const interceptEvent = () => { }

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

const showBrandModal = ref(false)
const showRaceModal = ref(false)
const showFiltersModal = ref(false)
const isLoadingBrands = ref(false)
const isLoadingRaceTypes = ref(false)

const showRecognitionBanner = computed(() => {
  return store.brandRecognitionUnlocked || store.raceRecognitionUnlocked
})

const racingTeamCurrentGoal = computed(() => {
  const g = store.businessData?.currentGoal
  if (!g || typeof g !== "object") return null
  return g
})

const racingTeamLeagueLabel = computed(() => {
  const g = store.businessData?.currentGoal
  if (g?.league) return formatLeagueLabel(g.league)
  const cl = store.businessData?.currentLeague
  if (cl) return formatLeagueLabel(cl)
  return ""
})

const COMPLETED_GOALS_COLLAPSED_COUNT = 1

const completedGoalsExpanded = ref(false)

const racingTeamCompletedGoals = computed(() => {
  const c = store.businessData?.completedGoals
  return Array.isArray(c) ? c : []
})

const racingTeamCompletedGoalsNewestFirst = computed(() => {
  const all = racingTeamCompletedGoals.value
  return all.length ? [...all].reverse() : []
})

const hasHiddenCompletedGoals = computed(
  () => racingTeamCompletedGoalsNewestFirst.value.length > COMPLETED_GOALS_COLLAPSED_COUNT
)

const displayedCompletedGoals = computed(() => {
  const all = racingTeamCompletedGoalsNewestFirst.value
  if (completedGoalsExpanded.value || all.length <= COMPLETED_GOALS_COLLAPSED_COUNT) {
    return all
  }
  return all.slice(0, COMPLETED_GOALS_COLLAPSED_COUNT)
})

const league2Invite = computed(() => store.league2Invite ?? {})

const onLeague2InviteLaterJobs = async () => {
  await store.racingTeamLeague2InviteLater()
}

const onLeague2InviteAcceptJobs = async () => {
  await store.acceptLeague2Invite()
}

const brandSelectionDisplay = computed(() => {
  const selection = store.brandSelection
  if (selection === null || selection === undefined || selection === "null" || selection === "") {
    return "Not Selected"
  }
  return selection
})

const raceSelectionDisplay = computed(() => {
  if (!store.raceSelection) return "Not Selected"
  const raceType = store.availableRaceTypes.find(rt => rt.id === store.raceSelection)
  return raceType ? raceType.label : "Not Selected"
})

const handleBrandsReceived = (data) => {
  if (data && Array.isArray(data.brands)) {
    store.availableBrands = data.brands
  } else {
    store.availableBrands = []
  }
  isLoadingBrands.value = false
}

const openBrandModal = async () => {
  showBrandModal.value = true
  if (store.availableBrands.length === 0) {
    isLoadingBrands.value = true
    store.getAvailableBrands()
  }
}

const closeBrandModal = () => {
  showBrandModal.value = false
}

const selectBrand = async (brand) => {
  await store.setBrandSelection(brand)
  closeBrandModal()
}

const handleRaceTypesReceived = (data) => {
  if (data && Array.isArray(data.raceTypes)) {
    store.availableRaceTypes = data.raceTypes
  } else {
    store.availableRaceTypes = []
  }
  isLoadingRaceTypes.value = false
}

const openRaceModal = async () => {
  showRaceModal.value = true
  if (store.availableRaceTypes.length === 0) {
    isLoadingRaceTypes.value = true
    store.getAvailableRaceTypes()
  }
}

const closeRaceModal = () => {
  showRaceModal.value = false
}

const openFiltersModal = () => {
  showFiltersModal.value = true
}

const closeFiltersModal = () => {
  showFiltersModal.value = false
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

watch(showBrandModal, (isOpen) => {
  if (!controllerNav) return
  if (isOpen) {
    nextTick(() => {
      if (brandModalRef.value) {
        controllerNav.pushModal(brandModalRef.value, closeBrandModal)
      }
    })
  } else if (brandModalRef.value) {
    controllerNav.removeModal(brandModalRef.value)
  }
})

watch(showRaceModal, (isOpen) => {
  if (!controllerNav) return
  if (isOpen) {
    nextTick(() => {
      if (raceModalRef.value) {
        controllerNav.pushModal(raceModalRef.value, closeRaceModal)
      }
    })
  } else if (raceModalRef.value) {
    controllerNav.removeModal(raceModalRef.value)
  }
})

const selectRace = async (raceType) => {
  await store.setRaceSelection(raceType)
  closeRaceModal()
}

onMounted(async () => {
  events.on('businessComputer:onAvailableBrandsReceived', handleBrandsReceived)
  events.on('businessComputer:onAvailableRaceTypesReceived', handleRaceTypesReceived)
  
  const needsBrandStatus = store.brandRecognitionUnlocked === undefined || store.brandRecognitionUnlocked === null
  const needsRaceStatus = store.raceRecognitionUnlocked === undefined || store.raceRecognitionUnlocked === null
  
  if (needsBrandStatus || needsRaceStatus) {
    await Promise.all([
      needsBrandStatus ? store.updateBrandRecognitionStatus() : Promise.resolve(),
      needsRaceStatus ? store.updateRaceRecognitionStatus() : Promise.resolve()
    ])
  }
  
  const needsBrandSelection = store.brandRecognitionUnlocked && store.brandSelection === null
  const needsRaceSelection = store.raceRecognitionUnlocked && store.raceSelection === null
  
  if (needsBrandSelection || needsRaceSelection) {
    await Promise.all([
      needsBrandSelection ? store.getBrandSelection() : Promise.resolve(),
      needsRaceSelection ? store.getRaceSelection() : Promise.resolve()
    ])
  }
})

onUnmounted(() => {
  events.off('businessComputer:onAvailableBrandsReceived', handleBrandsReceived)
  events.off('businessComputer:onAvailableRaceTypesReceived', handleRaceTypesReceived)
})

watch(() => store.brandRecognitionUnlocked, async (unlocked) => {
  if (unlocked && store.brandSelection === null) {
    await store.getBrandSelection()
  }
})

watch(() => store.raceRecognitionUnlocked, async (unlocked) => {
  if (unlocked && store.raceSelection === null) {
    await store.getRaceSelection()
  }
})

const penaltyCost = computed(() => {
  if (!jobToAbandon.value) return 0
  return jobToAbandon.value.penalty || 0
})

const pullOutDiag = (...args) => {
  try {
    console.debug("[rlsBizPull]", ...args)
  } catch (_) {}
}

const findVehicleForJob = (job) => {
  if (!Array.isArray(store.vehicles)) {
    pullOutDiag("Jobs findVehicleForJob: vehicles not array", { jobId: job?.jobId ?? job?.id })
    return null
  }
  const sv = normalizeId(job?.storedVehicleId)
  if (sv !== null) {
    const byStored = store.vehicles.find(vehicle => normalizeId(vehicle?.vehicleId) === sv)
    if (byStored) return byStored
  }
  const jobId = normalizeId(job?.jobId ?? job?.id)
  if (jobId === null) {
    pullOutDiag("Jobs findVehicleForJob: no job id", { job })
    return null
  }
  return store.vehicles.find(vehicle => {
    if (!vehicle.jobId) return false
    return normalizeId(vehicle.jobId) === jobId
  }) || null
}

const handlePullOut = async (job) => {
  const vehicle = findVehicleForJob(job)
  if (!vehicle) {
    pullOutDiag("Jobs handlePullOut abort: no vehicle (Lua pullOut never called)", {
      jobId: job?.jobId ?? job?.id,
      storedVehicleId: job?.storedVehicleId,
      fleetCount: Array.isArray(store.vehicles) ? store.vehicles.length : -1,
    })
    return
  }
  pullOutDiag("Jobs handlePullOut calling store.pullOutVehicle", { jobId: job?.jobId ?? job?.id, vehicleId: vehicle.vehicleId })
  await store.pullOutVehicle(vehicle.vehicleId, job?.jobId ?? job?.id)
}

const handlePutAway = async (job) => {
  const vehicle = findVehicleForJob(job)
  await store.putAwayVehicle(vehicle?.vehicleId)
}

const handleAbandon = (job) => {
  if (!job) return
  jobToAbandon.value = job
  showAbandonModal.value = true
}

const jobIdForAction = (job) => {
  const raw = job?.jobId ?? job?.id ?? job?.job_id
  if (raw === undefined || raw === null || raw === '') return undefined
  // Prefer numbers for Lua bridge: string job ids are received as 0 in GE Lua
  if (typeof raw === 'number' && Number.isFinite(raw)) return raw
  if (typeof raw === 'string' && /^\d+$/.test(raw.trim())) return Number(raw.trim())
  return String(raw)
}

const confirmAbandon = async () => {
  if (jobToAbandon.value) {
    await store.abandonJob(jobIdForAction(jobToAbandon.value))
    showAbandonModal.value = false
    jobToAbandon.value = null
  }
}

const cancelAbandon = () => {
  showAbandonModal.value = false
  jobToAbandon.value = null
}

const handleComplete = async (job) => {
  const jobId = job.jobId ?? parseInt(job.id)
  await store.completeJob(jobId)
}

const handleAccept = async (job) => {
  await store.acceptJob(jobIdForAction(job))
}

const handleDecline = async (job) => {
  await store.declineJob(jobIdForAction(job))
}

</script>

<style scoped lang="scss">
.jobs-tab {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
}

.tab-header {
  .header-content {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 1em;
    flex-wrap: wrap;

    h2 {
      margin: 0 0 0.5em 0;
      color: rgba(245, 73, 0, 1);
      font-size: 1.5em;
    }

    p {
      margin: 0;
      color: rgba(255, 255, 255, 0.6);
    }
  }

  .filters-button {
    display: flex;
    align-items: center;
    gap: 0.5em;
    padding: 0.6em 1.2em;
    background: rgba(255, 153, 51, 0.15);
    border: 1px solid rgba(255, 153, 51, 0.3);
    border-radius: 8px;
    color: rgba(255, 255, 255, 0.9);
    font-size: 0.9em;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.2s;
    white-space: nowrap;
    margin-top: 0.5em;

    .filters-icon {
      font-size: 1.1em;
    }

    &:hover {
      background: rgba(255, 153, 51, 0.25);
      border-color: rgba(255, 153, 51, 0.5);
      color: #fff;
    }
  }
}

.current-goal-panel {
  padding: 1em 1.24em;
  border-radius: 0.75em;
  background: rgba(20, 28, 36, 0.85);
  border: 1px solid rgba(245, 73, 0, 0.35);
  display: flex;
  flex-direction: column;
  gap: 0.65em;
}

.current-goal-panel__tier {
  font-size: 0.75em;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: rgba(245, 73, 0, 0.95);
}

.current-goal-panel__title {
  margin: 0;
  font-size: 1.15em;
  font-weight: 600;
  color: #fff;
}

.current-goal-panel__description {
  margin: 0;
  font-size: 0.9em;
  line-height: 1.45;
  color: rgba(255, 255, 255, 0.72);
}
.current-goal-panel__meta {
  display: flex;
  flex-wrap: wrap;
  gap: 1.25em;
  font-size: 0.88em;
  color: rgba(255, 255, 255, 0.85);
  strong {
    color: rgba(255, 255, 255, 0.95);
    margin-right: 0.25em;
  }
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

.completed-goals-panel {
  margin-top: 0.75em;
  padding: 0.85em 1.1em;
  border-radius: 0.65em;
  background: rgba(12, 18, 24, 0.72);
  border: 1px solid rgba(255, 255, 255, 0.08);
}

.completed-goals-panel__heading {
  margin: 0 0 0.5em;
  font-size: 0.95em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.88);
}

.completed-goals-panel__list {
  margin: 0;
  padding: 0;
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 0.4em;
}

.completed-goals-panel__item {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.5em 0.75em;
  font-size: 0.86em;
  color: rgba(255, 255, 255, 0.65);
}

.completed-goals-panel__title {
  color: rgba(255, 255, 255, 0.82);
}

.completed-goals-panel__league {
  font-size: 0.78em;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: rgba(245, 73, 0, 0.75);
}

.completed-goals-panel__detail {
  flex-basis: 100%;
  font-size: 0.78em;
  color: rgba(255, 255, 255, 0.5);
  line-height: 1.3;
}

.completed-goals-panel__toggle {
  margin-top: 0.55em;
  font-size: 0.82em;
}

.recognition-banner {
  display: flex;
  align-items: center;
  gap: 1.5em;
  padding: 0.75em 1.25em;
  border-radius: 0.75em;
  background: rgba(30, 30, 30, 0.75);
  border: 1px solid rgba(255, 255, 255, 0.08);
  flex-wrap: wrap;

  .recognition-section {
    display: flex;
    align-items: center;
    gap: 0.75em;
    cursor: pointer;
    transition: opacity 0.2s;

    &:hover {
      opacity: 0.8;
    }
  }

  .banner-label {
    color: rgba(255, 255, 255, 0.55);
    font-size: 0.85em;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    white-space: nowrap;
  }

  .banner-value {
    color: #fff;
    font-weight: 600;
    white-space: nowrap;
  }

  .summary-divider {
    width: 1px;
    height: 1.5em;
    background: rgba(255, 255, 255, 0.1);
  }
}

.jobs-content {
  display: flex;
  flex-direction: column;
  gap: 2em;
}

.job-section {
  h3 {
    margin: 0 0 1em 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.25em;
    font-weight: 600;
  }
}

.jobs-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 1em;

  @media (min-width: 1024px) {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

.job-card-wrapper {
  height: 100%;
}

.empty-state {
  padding: 3em;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

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
    padding: 0.75em 1.5em;
    border: none;
    border-radius: 0.25em;
    font-size: 0.875em;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;

    &.btn-secondary {
      background: rgba(255, 255, 255, 0.1);
      color: rgba(255, 255, 255, 0.9);

      &:hover {
        background: rgba(255, 255, 255, 0.15);
      }
    }

    &.btn-danger {
      background: rgba(239, 68, 68, 1);
      color: white;

      &:hover {
        background: rgba(239, 68, 68, 0.9);
        box-shadow: 0 0 10px rgba(239, 68, 68, 0.4);
      }
    }
  }

  &.selection-modal {
    max-width: 25em;
    padding: 0;

    .modal-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 1em 1.5em;
      border-bottom: 1px solid rgba(255, 255, 255, 0.1);
      background: rgba(0, 0, 0, 0.2);

      h2 {
        margin: 0;
        font-size: 1.1em;
        color: #fff;
        font-weight: 600;
      }

      .modal-close {
        background: none;
        border: none;
        color: rgba(255, 255, 255, 0.5);
        font-size: 1.5em;
        line-height: 1;
        cursor: pointer;
        padding: 4px;
        border-radius: 4px;
        transition: all 0.2s;

        &:hover {
          background: rgba(255, 255, 255, 0.1);
          color: #fff;
        }
      }
    }

    .modal-body {
      padding: 1em;
      max-height: 400px;
      overflow-y: auto;

      &::-webkit-scrollbar {
        width: 8px;
      }

      &::-webkit-scrollbar-track {
        background: rgba(0, 0, 0, 0.1);
      }

      &::-webkit-scrollbar-thumb {
        background: rgba(255, 255, 255, 0.1);
        border-radius: 4px;

        &:hover {
          background: rgba(255, 255, 255, 0.2);
        }
      }

      .modal-empty {
        text-align: center;
        padding: 2em 1em;

        p {
          color: rgba(255, 255, 255, 0.5);
          margin: 0;
        }
      }

      .selection-list {
        display: flex;
        flex-direction: column;
        gap: 0.5em;

        .selection-item {
          width: 100%;
          padding: 0.75em 1em;
          background: rgba(255, 255, 255, 0.05);
          border: 1px solid rgba(255, 255, 255, 0.1);
          border-radius: 0.5em;
          color: rgba(255, 255, 255, 0.9);
          font-size: 0.9em;
          text-align: left;
          cursor: pointer;
          transition: all 0.2s;

          &:hover {
            background: rgba(255, 255, 255, 0.1);
            border-color: rgba(255, 255, 255, 0.2);
          }

          &.selected {
            background: rgba(245, 73, 0, 0.2);
            border-color: rgba(245, 73, 0, 0.5);
            color: #fff;
            font-weight: 600;
          }

          span {
            display: block;
          }
        }
      }
    }
  }
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