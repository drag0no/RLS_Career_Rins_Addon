<template>
  <div class="job-card" :class="{ active: isActive }">
    <!-- Full Layout (formerly New Job Style) -->
    <div v-if="layout === 'full'" class="job-content-new">
      <div class="job-image-new">
        <img :src="job.vehicleImage" :alt="job.vehicleName" />
        <div v-if="vehicleCooldownSec > 0" class="cooldown-overlay">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
            <circle cx="12" cy="12" r="10" />
            <polyline points="12 6 12 12 16 14" />
          </svg>
          <span>Cooling down {{ formatCooldownMSS(vehicleCooldownSec) }}</span>
        </div>
        <div class="expiration-overlay" v-if="expirationText" :class="{ expired: isExpired }">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
            <circle cx="12" cy="12" r="10" />
            <polyline points="12 6 12 12 16 14" />
          </svg>
          <span>{{ expirationText }}</span>
        </div>
      </div>

      <div class="job-details-container">
        <h3 class="vehicle-name-new">
          {{ job.vehicleYear }} {{ job.vehicleName }}
        </h3>

        <div class="job-meta-row">
          <div class="reward-text">
            {{ formatCurrency(job.reward) }}
          </div>
          <div class="separator">•</div>
          <div class="goal-text">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
              <path d="M12 2v4m0 12v4M2 12h4m12 0h4" />
              <circle cx="12" cy="12" r="10" />
            </svg>
            <span>{{ job.goal }}</span>
          </div>
        </div>

        <!-- Active Job Status in Full Layout -->
        <div v-if="isActive" class="job-status-full">
          <div v-if="hasTechAssigned" class="tech-status-sleek">
            <div class="tech-info-row">
              <span class="tech-phase">{{ techStatus }}</span>
              <span class="tech-name-small">by {{ techName || 'Tech' }}</span>
            </div>
            <div class="tech-progress-bar">
              <div class="tech-progress-fill" :style="{ width: techProgress + '%' }"></div>
            </div>
          </div>
          <div v-else class="goal-section-sleek">
            <div class="goal-row current">
              <span class="goal-label">Current</span>
              <span class="goal-value highlight">{{ formatTime(job.currentTime ?? job.baselineTime, job.decimalPlaces) }}</span>
            </div>
            <div class="progress-bar-sleek">
              <div class="progress-fill" :style="{ width: progressPercent + '%' }"></div>
            </div>
            <div v-if="completionBlockedMessage" class="lock-message build-changed-message">
              {{ completionBlockedMessage }}
            </div>
          </div>
        </div>

        <div class="job-actions-new">
          <template v-if="isActive">
            <!-- Active Job Actions for Full Layout -->
            <div class="job-actions-sleek full-layout-actions" :class="{ locked: damageLockApplies || kitInstallLocked }">
              <template v-if="kitInstallLocked">
                <div class="kit-install-status">
                  <div class="kit-install-message">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <circle cx="12" cy="12" r="10"/>
                      <path d="M12 6v6l4 2"/>
                    </svg>
                    <span>Installing {{ kitInstallKitName }}</span>
                  </div>
                  <div class="kit-install-time">{{ formatTime(kitInstallSecondsRemaining) }} remaining</div>
                </div>
              </template>
              <template v-else-if="!hasTechAssigned">
                <template v-if="damageLockApplies">
                  <div class="lock-message">Vehicle Damaged</div>
                  <button class="btn btn-danger full-width" @mousedown.stop @click.stop="$emit('abandon', job)" data-focusable>
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <line x1="18" y1="6" x2="6" y2="18" />
                      <line x1="6" y1="6" x2="18" y2="18" />
                    </svg>
                    {{ abandonActionLabel }}
                  </button>
                </template>
                <template v-else>
                  <div v-if="completionBlockedMessage" class="lock-message">{{ completionBlockedMessage }}</div>
                  <button v-if="showCompleteButton" class="btn btn-success flex-grow"
                    @click.stop="$emit('complete', job)" data-focusable>
                    {{ store.businessType === 'racingTeam' ? 'Sell' : 'Complete' }}
                  </button>
                  <template v-else>
                    <button
                      v-if="showRacingTeamRepair"
                      class="btn btn-secondary full-width"
                      style="margin-bottom: 0.5em"
                      @click.stop="runRepair"
                      data-focusable
                    >
                      Repair
                    </button>
                    <button class="btn btn-primary flex-grow"
                      @click.stop="isPulledOut ? $emit('put-away') : $emit('pull-out', job)"
                      :disabled="(!isPulledOut && hasPulledOutVehicle) || pullOutBlockedByCooldown"
                      :title="pullOutButtonTitle"
                      data-focusable>
                      {{ isPulledOut ? 'Put Away' : 'Pull Out' }}
                    </button>
                    <button class="btn btn-danger btn-icon" @mousedown.stop @click.stop="$emit('abandon', job)"
                      :title="abandonActionLabel" data-focusable>
                      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                        stroke-width="2.5">
                        <line x1="18" y1="6" x2="6" y2="18" />
                        <line x1="6" y1="6" x2="18" y2="18" />
                      </svg>
                    </button>
                  </template>
                </template>
              </template>
            </div>
          </template>
          <template v-else>
            <!-- New Job Actions -->
            <template v-if="assignMode">
              <button class="btn btn-primary" @click.stop="$emit('assign', job)" data-focusable>
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
                  <circle cx="8.5" cy="7" r="4" />
                  <line x1="20" y1="8" x2="20" y2="14" />
                  <line x1="23" y1="11" x2="17" y2="11" />
                </svg>
                Assign
              </button>
            </template>
            <template v-else>
              <button class="btn btn-success flex-grow" :disabled="isAcceptDisabled"
                :title="acceptButtonTitle"
                @click.stop="$emit('accept', job)" data-focusable>
                {{ store.businessType === 'racingTeam' ? 'Purchase' : 'Accept' }}
              </button>
              <button class="btn btn-danger btn-icon" @click.stop="$emit('decline', job)" data-focusable>
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                  <line x1="18" y1="6" x2="6" y2="18" />
                  <line x1="6" y1="6" x2="18" y2="18" />
                </svg>
              </button>
            </template>
          </template>
        </div>
      </div>
    </div>

    <!-- Compact Layout (formerly Active/Sleek State) -->
    <div v-else class="job-content-active sleek">
      <div class="job-header-sleek">
        <div class="job-image-sleek">
          <img :src="job.vehicleImage" :alt="job.vehicleName" />
          <div v-if="vehicleCooldownSec > 0" class="cooldown-overlay cooldown-overlay--sleek">
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
              <circle cx="12" cy="12" r="10" />
              <polyline points="12 6 12 12 16 14" />
            </svg>
            <span>{{ formatCooldownMSS(vehicleCooldownSec) }}</span>
          </div>
        </div>
        <div class="job-info-sleek">
          <h3 class="vehicle-name-sleek">
            {{ job.vehicleYear }} {{ job.vehicleName }}
          </h3>
          <div class="reward-text-sleek">
            {{ formatCurrency(job.reward) }}
          </div>
        </div>
      </div>

      <div class="job-status-sleek">
        <template v-if="isActive">
          <!-- Tech Working Status -->
          <div v-if="hasTechAssigned" class="tech-status-sleek">
            <div class="tech-info-row">
              <span class="tech-phase">{{ techStatus }}</span>
              <span class="tech-name-small">by {{ techName || 'Tech' }}</span>
            </div>
            <div class="tech-progress-bar">
              <div class="tech-progress-fill" :style="{ width: techProgress + '%' }"></div>
            </div>
          </div>

          <!-- Goal Section (Only if NO Tech) -->
          <div v-else class="goal-section-sleek">
            <div class="goal-row">
              <span class="goal-label">Goal</span>
              <span class="goal-value">{{ job.goal }}</span>
            </div>
            <div class="goal-row current">
              <span class="goal-label">Current</span>
              <span class="goal-value highlight">{{ formatTime(job.currentTime ?? job.baselineTime, job.decimalPlaces) }}</span>
            </div>
            <div class="progress-bar-sleek">
              <div class="progress-fill" :style="{ width: progressPercent + '%' }"></div>
            </div>
            <div v-if="completionBlockedMessage" class="lock-message build-changed-message">
              {{ completionBlockedMessage }}
            </div>
          </div>
        </template>
        <template v-else>
          <!-- Compact New Job Info -->
          <div class="goal-section-sleek">
            <div class="goal-row">
              <span class="goal-label">Goal</span>
              <span class="goal-value">{{ job.goal }}</span>
            </div>
            <div v-if="expirationText" class="goal-row current">
              <span class="goal-label">Expires</span>
              <span class="goal-value" :class="{ 'text-danger': isExpired }">{{ expirationText.replace('Expires in ',
                '') }}</span>
            </div>
          </div>
        </template>
      </div>

      <div class="job-actions-sleek" :class="{ locked: damageLockApplies || kitInstallLocked }">
        <template v-if="isActive">
          <template v-if="kitInstallLocked">
            <div class="kit-install-status">
              <div class="kit-install-message">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="12" cy="12" r="10"/>
                  <path d="M12 6v6l4 2"/>
                </svg>
                <span>Installing {{ kitInstallKitName }}</span>
              </div>
              <div class="kit-install-time">{{ formatTime(kitInstallSecondsRemaining) }} remaining</div>
            </div>
          </template>
          <template v-else-if="!hasTechAssigned">
            <template v-if="damageLockApplies">
              <div class="lock-message">Vehicle Damaged</div>
              <button class="btn btn-danger full-width" @mousedown.stop @click.stop="$emit('abandon', job)" data-focusable>
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <line x1="18" y1="6" x2="6" y2="18" />
                  <line x1="6" y1="6" x2="18" y2="18" />
                </svg>
                {{ abandonActionLabel }}
              </button>
            </template>
            <template v-else>
              <div v-if="completionBlockedMessage" class="lock-message">{{ completionBlockedMessage }}</div>
              <button v-if="showCompleteButton" class="btn btn-success flex-grow"
                @click.stop="$emit('complete', job)" data-focusable>
                {{ store.businessType === 'racingTeam' ? 'Sell' : 'Complete' }}
              </button>
              <template v-else>
                <button
                  v-if="showRacingTeamRepair"
                  class="btn btn-secondary full-width"
                  style="margin-bottom: 0.5em"
                  @click.stop="runRepair"
                  data-focusable
                >
                  Repair
                </button>
                <button class="btn btn-primary flex-grow"
                  @click.stop="isPulledOut ? $emit('put-away') : $emit('pull-out', job)"
                  :disabled="(!isPulledOut && hasPulledOutVehicle) || pullOutBlockedByCooldown"
                  :title="pullOutButtonTitle"
                  data-focusable>
                  {{ isPulledOut ? 'Put Away' : 'Pull Out' }}
                </button>
                <button class="btn btn-danger btn-icon" @mousedown.stop @click.stop="$emit('abandon', job)"
                  :title="abandonActionLabel" data-focusable>
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                    <line x1="18" y1="6" x2="6" y2="18" />
                    <line x1="6" y1="6" x2="18" y2="18" />
                  </svg>
                </button>
              </template>
            </template>
          </template>
        </template>
        <template v-else>
          <!-- Compact New Job Actions -->
          <button class="btn btn-success flex-grow" :disabled="isAcceptDisabled"
            :title="acceptButtonTitle"
            @click.stop="$emit('accept', job)" data-focusable>
            {{ store.businessType === 'racingTeam' ? 'Purchase' : 'Accept' }}
          </button>
          <button class="btn btn-danger btn-icon" @click.stop="$emit('decline', job)" data-focusable>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </template>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted, watch } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { formatCurrency, formatTime, formatPhase, normalizeId } from "../../utils/businessUtils"

const props = defineProps({
  job: Object,
  isActive: Boolean,
  businessId: String,
  assignMode: {
    type: Boolean,
    default: false
  },
  layout: {
    type: String,
    default: 'compact',
    validator: (value) => ['compact', 'full'].includes(value)
  }
})

const emit = defineEmits(['pull-out', 'put-away', 'abandon', 'accept', 'decline', 'complete', 'assign'])

const store = useBusinessComputerStore()

const abandonActionLabel = computed(() => (store.businessType === 'racingTeam' ? 'Sell' : 'Abandon'))

const jobIdentifier = computed(() => normalizeId(props.job?.jobId ?? props.job?.id))

const vehicleRowMatchesJob = (vehicle) => {
  if (!vehicle || !props.job) return false
  const sv = normalizeId(props.job.storedVehicleId)
  if (sv !== null && normalizeId(vehicle.vehicleId) === sv) return true
  const jid = normalizeId(props.job?.jobId ?? props.job?.id)
  return jid !== null && normalizeId(vehicle?.jobId) === jid
}
const techAssigned = computed(() => {
  if (!props.job?.techAssigned) return null
  return props.job.techAssigned
})
const assignedTech = computed(() => {
  if (!techAssigned.value) return null
  const techs = store.techs || []
  const tech = techs.find(t => String(t.id) === String(techAssigned.value)) || null
  if (!tech) return null
  const techJobId = normalizeId(tech.jobId)
  if (techJobId !== jobIdentifier.value) return null
  return tech
})
const techName = computed(() => {
  return assignedTech.value?.name || null
})
const hasTechAssigned = computed(() => !!assignedTech.value)
const techProgress = computed(() => {
  if (!assignedTech.value || !assignedTech.value.jobId) return 0
  const progress = assignedTech.value.progress
  return typeof progress === 'number' ? Math.min(100, Math.max(0, progress * 100)) : 0
})
const techStatus = computed(() => {
  if (!assignedTech.value) return null
  return formatPhase(assignedTech.value, false)
})
const pulledOutVehicleForJob = computed(() => {
  if (Array.isArray(store.pulledOutVehicles)) {
    const fromList = store.pulledOutVehicles.find(vehicle => vehicleRowMatchesJob(vehicle))
    if (fromList) {
      return fromList
    }
  }
  const pv = store.pulledOutVehicle
  if (pv && vehicleRowMatchesJob(pv)) {
    return pv
  }
  return null
})
const vehicleForJob = computed(() => {
  if (!Array.isArray(store.vehicles)) {
    return null
  }
  return store.vehicles.find(vehicle => vehicleRowMatchesJob(vehicle)) || null
})

/** Inventory vehicle id for racingTeamFleetCooldowns (Lua keys are tostring(vehicleId)). */
const fleetVehicleIdForCooldown = computed(() => {
  const row = vehicleForJob.value || pulledOutVehicleForJob.value
  const fromRow = row?.vehicleId
  if (fromRow !== undefined && fromRow !== null && fromRow !== "") {
    return fromRow
  }
  const stored = props.job?.storedVehicleId
  if (stored !== undefined && stored !== null && stored !== "") {
    return stored
  }
  const jv = props.job?.vehicleId
  if (jv !== undefined && jv !== null && jv !== "") {
    return jv
  }
  return null
})

const fleetCooldownSecondsFromServer = computed(() => {
  const map = store.businessData?.racingTeamFleetCooldowns
  const id = fleetVehicleIdForCooldown.value
  if (store.businessType !== "racingTeam" || !map || id === null || id === undefined || id === "") {
    return 0
  }
  const keys = new Set([String(id)])
  const norm = normalizeId(id)
  if (norm !== null) {
    keys.add(String(norm))
  }
  for (const k of keys) {
    const v = map[k]
    if (v !== undefined && v !== null && Number.isFinite(Number(v))) {
      return Number(v)
    }
  }
  return 0
})

const damageLockApplies = computed(() => {
  if (!pulledOutVehicleForJob.value) {
    return false
  }
  return !!pulledOutVehicleForJob.value.damageLocked
})
const kitInstallLocked = computed(() => {
  const vehicle = vehicleForJob.value || pulledOutVehicleForJob.value
  if (vehicle?.kitInstallLocked === true) return true
  return kitInstallSecondsRemaining.value > 0
})
const kitInstallSecondsRemaining = ref(0)
const kitInstallTimer = ref(null)
const kitInstallKitName = computed(() => {
  const vehicle = vehicleForJob.value || pulledOutVehicleForJob.value
  return vehicle?.kitInstallKitName || 'kit'
})
const syncKitInstallTime = () => {
  const vehicle = vehicleForJob.value || pulledOutVehicleForJob.value
  const serverTime = vehicle?.kitInstallTimeRemaining || 0
  kitInstallSecondsRemaining.value = Math.max(0, Math.floor(serverTime))
}
const startKitInstallCountdown = () => {
  stopKitInstallCountdown()
  syncKitInstallTime()
  if (kitInstallSecondsRemaining.value <= 0) return
  kitInstallTimer.value = setInterval(() => {
    if (kitInstallSecondsRemaining.value <= 0) {
      stopKitInstallCountdown()
      return
    }
    kitInstallSecondsRemaining.value = kitInstallSecondsRemaining.value - 1
  }, 1000)
}
const stopKitInstallCountdown = () => {
  if (kitInstallTimer.value) {
    clearInterval(kitInstallTimer.value)
    kitInstallTimer.value = null
  }
}
const canComplete = ref(false)
const completionStatusMessage = ref(null)
const completionStatusFetched = ref(false)
const remainingSeconds = ref(null)
const countdownTimer = ref(null)
const hasRequestedAfterExpiry = ref(false)

const canCompleteLocal = computed(() => {
  if (store.businessType === 'tuningShop') {
    return false
  }
  if (!props.isActive || props.job.currentTime === undefined || props.job.currentTime === null || props.job.goalTime === undefined || props.job.goalTime === null) {
    return false
  }

  // For track races and drag races, lower time is better (currentTime <= goalTime)
  // Both times should be in the same unit (seconds from leaderboard)
  if (props.job.raceType === "track" || props.job.raceType === "trackAlt" || props.job.raceType === "drag") {
    // Ensure we have valid numbers
    const currentTime = Number(props.job.currentTime)
    const goalTime = Number(props.job.goalTime)

    if (isNaN(currentTime) || isNaN(goalTime) || goalTime <= 0) {
      return false
    }

    return currentTime <= goalTime
  }

  return false
})

const completionBlockedMessage = computed(() => {
  if (store.businessType !== 'tuningShop' || !props.isActive) {
    return null
  }
  if (!props.job.goalTimeMet) {
    return null
  }
  if (completionStatusFetched.value) {
    return completionStatusMessage.value || null
  }
  if (completionStatusMessage.value) {
    return completionStatusMessage.value
  }
  return props.job.completionBlockedMessage || null
})

const showCompleteButton = computed(() => {
  if (completionBlockedMessage.value) {
    return false
  }
  if (store.businessType === 'tuningShop') {
    return canComplete.value === true
  }
  return canComplete.value || canCompleteLocal.value
})

const statusText = computed(() => {
  return props.isActive ? "In Progress" : "Available"
})

const statusClass = computed(() => {
  return props.isActive ? "status-active" : "status-available"
})

const progressPercent = computed(() => {
  if (!props.isActive || !props.job.baselineTime || !props.job.goalTime) return 0
  const progress = ((props.job.baselineTime - props.job.currentTime) /
    (props.job.baselineTime - props.job.goalTime)) * 100
  return Math.max(0, Math.min(100, progress))
})

const isPulledOut = computed(() => {
  return !!pulledOutVehicleForJob.value
})

const liftsFull = computed(() => {
  if (Array.isArray(store.pulledOutVehicles)) {
    return store.pulledOutVehicles.length >= store.maxPulledOutVehicles
  }
  return !!store.pulledOutVehicle
})

const hasPulledOutVehicle = computed(() => {
  return liftsFull.value && !isPulledOut.value
})

const showRacingTeamRepair = computed(() => {
  if (store.businessType !== "racingTeam" || !props.isActive || hasTechAssigned.value || kitInstallLocked.value) {
    return false
  }
  if (!isPulledOut.value) {
    return false
  }
  const d = pulledOutVehicleForJob.value?.damage
  return typeof d === "number" && d >= 1
})

const runRepair = async () => {
  const v = pulledOutVehicleForJob.value
  if (!v?.vehicleId) {
    return
  }
  await store.repairBusinessVehicle(v.vehicleId)
}

const stopCountdown = () => {
  if (countdownTimer.value) {
    clearInterval(countdownTimer.value)
    countdownTimer.value = null
  }
}

const syncRemainingSeconds = () => {
  if (props.isActive) {
    remainingSeconds.value = null
    return
  }

  if (typeof props.job?.expiresInSeconds === "number") {
    remainingSeconds.value = Math.max(0, Math.floor(props.job.expiresInSeconds))
  } else {
    remainingSeconds.value = null
  }
}

const requestJobsAfterExpiry = async () => {
  if (hasRequestedAfterExpiry.value) {
    return
  }

  hasRequestedAfterExpiry.value = true

  const currentBusinessId = store.businessId
  const currentBusinessType = store.businessType

  if (!currentBusinessId || !currentBusinessType || !store.loadBusinessData) {
    return
  }

  try {
    await store.loadBusinessData(currentBusinessType, currentBusinessId)
  } catch (error) {
  }
}

const startCountdown = () => {
  stopCountdown()
  hasRequestedAfterExpiry.value = false
  syncRemainingSeconds()
  if (remainingSeconds.value === null) {
    return
  }

  countdownTimer.value = setInterval(() => {
    if (remainingSeconds.value === null) {
      stopCountdown()
      return
    }

    if (remainingSeconds.value <= 0) {
      remainingSeconds.value = 0
      requestJobsAfterExpiry()
      stopCountdown()
      return
    }

    remainingSeconds.value = remainingSeconds.value - 1
  }, 1000)
}

const checkCanComplete = async () => {
  if (!props.isActive || !props.businessId || !props.job.jobId) {
    canComplete.value = false
    completionStatusMessage.value = null
    completionStatusFetched.value = false
    return
  }

  try {
    if (store.businessType === 'tuningShop') {
      const response = await lua.career_modules_business_tuningShop.getJobCompletionStatus(props.businessId, props.job.jobId)
      const status = response && typeof response === 'object' ? response : {}
      canComplete.value = status.canComplete === true
      completionStatusMessage.value = status.goalTimeMet ? (status.blockedMessage || null) : null
      completionStatusFetched.value = true
      return
    }

    completionStatusFetched.value = false
    const result = await lua.career_modules_business_businessComputer.canCompleteJob(props.businessId, props.job.jobId)
    canComplete.value = result === true
    completionStatusMessage.value = null
  } catch (error) {
    canComplete.value = false
    completionStatusMessage.value = null
    completionStatusFetched.value = store.businessType === 'tuningShop'
  }
}

const isExpired = computed(() => {
  if (props.isActive) {
    return false
  }
  return remainingSeconds.value !== null && remainingSeconds.value <= 0
})

const expirationText = computed(() => {
  if (props.isActive || remainingSeconds.value === null) {
    return null
  }
  if (remainingSeconds.value <= 0) {
    return "Expired"
  }
  return `Expires in ${formatTime(remainingSeconds.value, 0)}`
})

const cooldownTick = ref(0)
let cooldownTickTimer = null
const cooldownStartMs = ref(0)
const cooldownStartSec = ref(0)

watch(
  () => fleetCooldownSecondsFromServer.value,
  (sec) => {
    cooldownStartSec.value = Math.max(0, Math.floor(sec || 0))
    cooldownStartMs.value = Date.now()
  },
  { immediate: true }
)

const vehicleCooldownSec = computed(() => {
  void cooldownTick.value
  const start = cooldownStartSec.value
  if (start <= 0) return 0
  const elapsed = Math.floor((Date.now() - cooldownStartMs.value) / 1000)
  return Math.max(0, start - elapsed)
})

const formatCooldownMSS = (totalSec) => {
  const s = Math.max(0, Math.floor(Number(totalSec) || 0))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const r = s % 60
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`
  return `${m}:${String(r).padStart(2, "0")}`
}

const pullOutBlockedByCooldown = computed(() => {
  // Fleet vehicle post-race cooldown must not block pulling out to work on the car.
  return false
})

const pullOutButtonTitle = computed(() => {
  if (!pullOutBlockedByCooldown.value) {
    return ""
  }
  return `Vehicle cooling down (${formatCooldownMSS(vehicleCooldownSec.value)} remaining)`
})

const isAcceptDisabled = computed(() => {
  if (props.isActive) {
    return false
  }
  if (store.activeJobs.length >= store.maxActiveJobs) {
    return true
  }
  if (store.businessType === "racingTeam" && vehicleCooldownSec.value > 0) {
    return true
  }
  return false
})

const acceptButtonTitle = computed(() => {
  if (!isAcceptDisabled.value) {
    return ""
  }
  if (store.activeJobs.length >= store.maxActiveJobs) {
    return `Active job limit reached (${store.maxActiveJobs} max)`
  }
  if (store.businessType === "racingTeam" && vehicleCooldownSec.value > 0) {
    return `Vehicle cooling down (${formatCooldownMSS(vehicleCooldownSec.value)})`
  }
  return ""
})

onMounted(() => {
  checkCanComplete()
  startCountdown()
  startKitInstallCountdown()
  cooldownTickTimer = setInterval(() => {
    cooldownTick.value++
  }, 1000)
})

onUnmounted(() => {
  stopCountdown()
  stopKitInstallCountdown()
  if (cooldownTickTimer) {
    clearInterval(cooldownTickTimer)
    cooldownTickTimer = null
  }
})

watch(() => [props.isActive, props.job.currentTime, props.job.goalTime, props.job.jobId, props.job.completionBlockedMessage, props.job.buildChanged], () => {
  checkCanComplete()
}, { immediate: false })

watch(() => props.job, () => {
  hasRequestedAfterExpiry.value = false
  checkCanComplete()
}, { deep: true })

watch(() => props.isActive, () => {
  hasRequestedAfterExpiry.value = false
})

watch(() => [props.job?.jobId, props.job?.expiresInSeconds, props.isActive], () => {
  startCountdown()
})

watch(() => [vehicleForJob.value?.kitInstallTimeRemaining, pulledOutVehicleForJob.value?.kitInstallTimeRemaining], () => {
  startKitInstallCountdown()
})
</script>

<style scoped lang="scss">
.job-card {
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5em;
  padding: 0.75em;
  transition: border-color 0.2s;

  &:hover {
    border-color: rgba(245, 73, 0, 0.5);
  }
}

/* Common/Shared Styles */
.btn {
  padding: 0.5em 0.75em;
  border-radius: 0.375em;
  font-size: 0.875em;
  font-weight: 500;
  cursor: pointer;
  border: none;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  transition: all 0.2s;

  &.flex-grow {
    flex: 1;
  }

  &.full-width {
    width: 100%;
  }

  &.btn-icon {
    padding: 0.5em;
    width: 2.25em;
    /* fixed width for icon buttons */
    flex-shrink: 0;
  }

  &.btn-primary {
    background: rgba(245, 73, 0, 1);
    color: white;

    &:hover:not(:disabled) {
      background: rgba(245, 73, 0, 0.9);
    }

    &:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
  }

  &.btn-success {
    background: rgba(34, 197, 94, 1);
    color: white;

    &:hover:not(:disabled) {
      background: rgba(34, 197, 94, 0.9);
    }

    &:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
  }

  &.btn-danger {
    background: rgba(239, 68, 68, 1);
    color: white;

    &:hover {
      background: rgba(239, 68, 68, 0.9);
    }
  }
}

/* "New" Job Styles */
.job-content-new {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.job-image-new {
  position: relative;
  width: 100%;
  aspect-ratio: 16/9;
  border-radius: 0.375em;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.cooldown-overlay {
  position: absolute;
  top: 0.5em;
  left: 0.5em;
  background: rgba(0, 0, 0, 0.78);
  backdrop-filter: blur(4px);
  color: rgba(255, 180, 120, 0.95);
  border: 1px solid rgba(245, 73, 0, 0.55);
  padding: 0.25em 0.5em;
  border-radius: 0.25em;
  font-size: 0.75em;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 0.35em;

  svg {
    color: rgba(245, 73, 0, 1);
    opacity: 0.95;
  }

  &--sleek {
    font-size: 0.7em;
    padding: 0.15em 0.4em;
  }
}

.job-image-sleek {
  position: relative;
}

.expiration-overlay {
  position: absolute;
  bottom: 0.5em;
  right: 0.5em;
  background: rgba(0, 0, 0, 0.75);
  backdrop-filter: blur(4px);
  color: rgba(255, 255, 255, 0.9);
  padding: 0.25em 0.5em;
  border-radius: 0.25em;
  font-size: 0.75em;
  font-weight: 500;
  display: flex;
  align-items: center;
  gap: 0.35em;

  &.expired {
    background: rgba(239, 68, 68, 0.9);
    color: white;
  }

  svg {
    opacity: 0.9;
  }
}

.job-details-container {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

.vehicle-name-new {
  margin: 0;
  color: white;
  font-size: 1em;
  font-weight: 600;
  line-height: 1.3;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.job-meta-row {
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.875em;
}

.separator {
  color: rgba(255, 255, 255, 0.2);
}

.reward-text {
  color: #22c55e;
  font-weight: 600;
  display: flex;
  align-items: baseline;
  gap: 1px;

  .currency {
    font-size: 0.75em;
    opacity: 0.8;
  }
}

.goal-text {
  color: rgba(245, 73, 0, 1);
  display: flex;
  align-items: center;
  gap: 0.35em;
  font-weight: 500;

  svg {
    flex-shrink: 0;
  }
}

.job-actions-new {
  display: flex;
  gap: 0.5em;
  margin-top: 0.25em;
  flex-direction: row;
}

/* --- Sleek Active Job Styles --- */
.job-content-active.sleek {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.job-header-sleek {
  display: flex;
  gap: 0.75em;
  align-items: center;
}

.job-image-sleek {
  width: 4em;
  /* Compact thumbnail size */
  height: 4em;
  border-radius: 0.375em;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.5);
  flex-shrink: 0;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.job-info-sleek {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 0.25em;
}

.vehicle-name-sleek {
  margin: 0;
  color: white;
  font-size: 0.95em;
  font-weight: 600;
  line-height: 1.2;
  overflow: hidden;
  text-overflow: ellipsis;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
}

.reward-text-sleek {
  color: #22c55e;
  font-weight: 600;
  font-size: 0.9em;
}

/* Tech Status Sleek */
.tech-status-sleek {
  background: rgba(245, 73, 0, 0.15);
  border: 1px solid rgba(245, 73, 0, 0.25);
  border-radius: 0.375em;
  padding: 0.5em 0.75em;
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

.tech-info-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
}

.tech-phase {
  color: #f97316;
  font-size: 0.8em;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.tech-name-small {
  color: rgba(255, 255, 255, 0.5);
  font-size: 0.75em;
}

.tech-progress-bar {
  height: 4px;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 2px;
  overflow: hidden;

  .tech-progress-fill {
    height: 100%;
    background: #f97316;
    transition: width 0.2s;
  }
}

/* Goal Section Sleek */
.goal-section-sleek {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 0.375em;
  padding: 0.5em 0.75em;
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

.goal-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  font-size: 0.8em;

  .goal-label {
    color: rgba(255, 255, 255, 0.5);
    text-transform: uppercase;
    font-size: 0.7em;
  }

  .goal-value {
    color: rgba(255, 255, 255, 0.9);
    font-weight: 500;

    &.highlight {
      color: white;
      font-weight: 600;
    }
  }
}

.progress-bar-sleek {
  height: 3px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 1.5px;
  overflow: hidden;
  margin-top: 0.15em;

  .progress-fill {
    height: 100%;
    background: #f97316;
  }
}

.job-actions-sleek {
  display: flex;
  gap: 0.5em;
  margin-top: auto;

  &.full-layout-actions {
    flex: 1;
  }
}

.lock-message {
  color: #ef4444;
  font-size: 0.8em;
  font-weight: 600;
  text-align: center;
  margin-bottom: 0.25em;
  width: 100%;
}

.build-changed-message {
  margin-top: 0.35em;
  margin-bottom: 0;
}

.kit-install-status {
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.kit-install-message {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5em;
  color: #3b82f6;
  font-size: 0.8em;
  font-weight: 600;
  text-align: center;
  width: 100%;
  padding: 0.5em;
  background: rgba(59, 130, 246, 0.1);
  border-radius: 0.375em;
  border: 1px solid rgba(59, 130, 246, 0.3);

  svg {
    flex-shrink: 0;
  }
}

.kit-install-time {
  color: rgba(59, 130, 246, 0.8);
  font-size: 0.75em;
  text-align: center;
  width: 100%;
}
</style>
