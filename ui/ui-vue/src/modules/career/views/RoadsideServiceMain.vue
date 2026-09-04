<template>
  <div class="roadside-service-wrapper">
    <BngCard class="roadside-service-container" v-bng-blur="1">
      <div class="main-header">
        <div class="header-titles">
          <h1>{{ view === 'repairDetail' ? 'Repair Details' : 'Roadside Service' }}</h1>
          <div v-if="uiData.spotName" class="spot-name">{{ uiData.spotName }}</div>
        </div>
        <button class="close-button" @click="close" data-focusable>
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <line x1="18" y1="6" x2="6" y2="18"/>
            <line x1="6" y1="6" x2="18" y2="18"/>
          </svg>
        </button>
      </div>

      <div v-if="loading" class="loading-state">
        <span>Loading service options...</span>
      </div>

      <div v-else-if="error" class="error-state">
        <span>{{ error }}</span>
        <BngButton @click="close">Close</BngButton>
      </div>

      <template v-else>
        <!-- Repair damage detail (second screen) -->
        <div v-if="view === 'repairDetail' && repairService" class="repair-detail">
          <div class="detail-summary">
            <div class="detail-total">
              <span class="detail-total-label">Estimated total</span>
              <span class="detail-total-value" :class="{ 'cannot-afford': !repairService.canAfford }">
                {{ formatMoney(repairService.cost) }}
              </span>
            </div>
            <div class="detail-subtotals" v-if="repairService.hasBrokenParts || repairService.hasFiniteDamage">
              <span v-if="repairService.hasBrokenParts">
                {{ repairService.brokenParts }} fully broken part{{ repairService.brokenParts === 1 ? '' : 's' }}
                ({{ formatMoney(repairService.brokenPartsCost) }} before labor)
              </span>
              <span v-if="repairService.hasFiniteDamage">
                Soft / cosmetic / tire work ({{ formatMoney(repairService.finiteCost) }} before labor)
              </span>
            </div>
          </div>

          <div class="damage-list-header">Damage found</div>
          <div class="damage-list" v-if="visibleDamageLines.length">
            <div
              v-for="line in visibleDamageLines"
              :key="line.id || line.label"
              class="damage-line"
              :class="'kind-' + (line.kind || 'info')"
            >
              <div class="damage-line-main">
                <span class="damage-label">{{ line.label }}</span>
                <span class="damage-cost" v-if="line.cost">{{ formatMoney(line.cost) }}</span>
              </div>
              <div class="damage-detail" v-if="line.detail">{{ line.detail }}</div>
            </div>
          </div>
          <div v-else class="damage-empty">No line items returned.</div>

          <button
            v-if="hiddenDamageCount > 0"
            type="button"
            class="show-more"
            @click="showMoreDamage"
          >
            Show more ({{ hiddenDamageCount }} remaining)
          </button>

          <div class="detail-actions">
            <BngButton @click="view = 'main'">Back</BngButton>
            <BngButton
              :accent="ACCENTS.attention"
              :disabled="!repairService.canAfford"
              @click="confirmRepairFromDetail"
            >
              {{ repairService.canAfford ? `Repair for ${formatMoney(repairService.cost)}` : 'Cannot afford' }}
            </BngButton>
          </div>
        </div>

        <!-- Main service list -->
        <template v-else>
          <div v-if="uiData.vehicle" class="vehicle-info">
            <div class="vehicle-name">{{ uiData.vehicle.niceName || uiData.vehicle.model || 'Vehicle' }}</div>
            <div class="vehicle-details" v-if="uiData.vehicle.mileage">
              {{ formatMileage(uiData.vehicle.mileage) }} mi
            </div>
          </div>

          <div class="service-note">
            <span class="note-icon">&#9432;</span>
            <span>Roadside service rates are {{ Math.round((uiData.laborMultiplier - 1) * 100) }}% higher than garage rates.</span>
          </div>

          <div class="services-grid">
            <div 
              v-for="service in orderedServices" 
              :key="service.id"
              class="service-tile"
              :class="{ 
                'disabled': !service.available || (service.id !== 'repair' && service.cost && !service.canAfford),
                'unavailable': !service.available
              }"
              @click="selectService(service)"
              data-focusable
              bng-nav-item
            >
              <div class="service-icon">
                <BngIcon :type="serviceIcons[service.id]" />
              </div>
              <div class="service-content">
                <div class="service-label">{{ service.label }}</div>
                <div class="service-description">{{ service.description }}</div>
                <div v-if="service.cost !== undefined && service.available" class="service-cost">
                  <span class="cost-label">Cost:</span>
                  <span class="cost-value" :class="{ 'cannot-afford': !service.canAfford }">
                    {{ formatMoney(service.cost) }}
                  </span>
                </div>
                <div v-if="service.available && service.id === 'repair'" class="service-hint">
                  Tap for damage details
                </div>
                <div v-if="service.reason" class="service-reason">{{ service.reason }}</div>
              </div>
            </div>
          </div>

          <div class="footer-info">
            <div class="player-money">
              <span class="money-label">Your Money:</span>
              <span class="money-value">{{ formatMoney(uiData.playerMoney || 0) }}</span>
            </div>
          </div>
        </template>
      </template>
    </BngCard>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showConfirmModal" class="modal-overlay" @click.self="cancelAction">
          <div class="modal-content">
            <h2>{{ confirmTitle }}</h2>
            <p>{{ confirmMessage }}</p>
            <div class="modal-buttons">
              <BngButton @click="cancelAction">Cancel</BngButton>
              <BngButton :accent="ACCENTS.attention" @click="confirmAction">{{ confirmButtonLabel }}</BngButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>

    <Teleport to="body">
      <transition name="modal-fade">
        <div v-if="showResultModal" class="modal-overlay" @click.self="closeResultModal">
          <div class="modal-content">
            <h2>{{ resultTitle }}</h2>
            <p>{{ resultMessage }}</p>
            <div class="modal-buttons">
              <BngButton @click="closeResultModal">OK</BngButton>
            </div>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import { BngCard, BngButton, BngIcon, icons, ACCENTS } from "@/common/components/base"
import { vBngBlur } from "@/common/directives"
import { lua } from "@/bridge"
import { installLuaBridgeFallbacks, callModLua } from "../utils/installLuaBridgeFallbacks"

installLuaBridgeFallbacks()

const DAMAGE_PAGE_SIZE = 12

const loading = ref(true)
const error = ref(null)
const uiData = ref({})
const view = ref('main') // 'main' | 'repairDetail'
const damageVisibleCount = ref(DAMAGE_PAGE_SIZE)

const showConfirmModal = ref(false)
const confirmTitle = ref('')
const confirmMessage = ref('')
const confirmButtonLabel = ref('Confirm')
const pendingAction = ref(null)

const showResultModal = ref(false)
const resultTitle = ref('')
const resultMessage = ref('')

const serviceIcons = {
  repair: icons.wrench,
  maintenance: icons.wrench,
  tuning: icons.cogs,
}

const serviceOrder = ['repair', 'maintenance', 'tuning']

const orderedServices = computed(() => {
  if (!uiData.value.services) return []
  return serviceOrder
    .filter(id => uiData.value.services[id])
    .map(id => uiData.value.services[id])
})

const repairService = computed(() => uiData.value?.services?.repair || null)

const allDamageLines = computed(() => repairService.value?.damageLines || [])

const visibleDamageLines = computed(() =>
  allDamageLines.value.slice(0, damageVisibleCount.value)
)

const hiddenDamageCount = computed(() =>
  Math.max(0, allDamageLines.value.length - damageVisibleCount.value)
)

const formatMoney = (amount) => {
  return '$' + (amount || 0).toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })
}

const formatMileage = (meters) => {
  const miles = (meters || 0) / 1609.344
  return miles.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })
}

const showMoreDamage = () => {
  damageVisibleCount.value = Math.min(
    allDamageLines.value.length,
    damageVisibleCount.value + DAMAGE_PAGE_SIZE
  )
}

watch(view, (next) => {
  if (next === 'repairDetail') damageVisibleCount.value = DAMAGE_PAGE_SIZE
})

const loadData = async () => {
  loading.value = true
  error.value = null
  try {
    const data = await callModLua("career_modules_roadsideServiceComputer.getUiData")
    if (data?.error) {
      error.value = data.debugError || data.error
    } else if (data) {
      uiData.value = data
    } else {
      error.value = 'Failed to load service data.'
    }
  } catch (e) {
    console.error('Failed to load roadside service data:', e)
    error.value = 'Failed to load service data.'
  }
  loading.value = false
}

const selectService = (service) => {
  if (!service.available) return
  if (service.cost !== undefined && !service.canAfford && service.id !== 'repair') return
  
  if (service.id === 'repair') {
    view.value = 'repairDetail'
  } else if (service.id === 'maintenance') {
    openMaintenance()
  } else if (service.id === 'tuning') {
    openTuning()
  }
}

const confirmRepairFromDetail = () => {
  if (!repairService.value?.canAfford) return
  performRepair()
}

const performRepair = async () => {
  showConfirmModal.value = false
  try {
    const result = await callModLua("career_modules_roadsideServiceComputer.performRepair")
    if (result?.ok) {
      resultTitle.value = 'Repair Complete'
      resultMessage.value = result.message
        || `Your vehicle has been repaired for ${formatMoney(result.cost)}.`
      showResultModal.value = true
      view.value = 'main'
      await loadData()
    } else {
      resultTitle.value = 'Repair Failed'
      resultMessage.value = result?.message || 'Unable to complete repair.'
      showResultModal.value = true
    }
  } catch (e) {
    console.error('Repair failed:', e)
    resultTitle.value = 'Error'
    resultMessage.value = 'An unexpected error occurred.'
    showResultModal.value = true
  }
}

const openMaintenance = async () => {
  try {
    const result = await callModLua("career_modules_roadsideServiceComputer.openMaintenance")
    if (!result?.ok) {
      resultTitle.value = 'Unavailable'
      resultMessage.value = result?.message || 'Maintenance is unavailable.'
      showResultModal.value = true
    }
  } catch (e) {
    console.error('Failed to open maintenance:', e)
  }
}

const openTuning = async () => {
  try {
    const result = await callModLua("career_modules_roadsideServiceComputer.openTuning")
    if (!result?.ok) {
      resultTitle.value = 'Unavailable'
      resultMessage.value = result?.message || 'Tuning is unavailable.'
      showResultModal.value = true
    }
  } catch (e) {
    console.error('Failed to open tuning:', e)
  }
}

const confirmAction = () => {
  if (pendingAction.value) {
    pendingAction.value()
  }
  pendingAction.value = null
}

const cancelAction = () => {
  showConfirmModal.value = false
  pendingAction.value = null
}

const closeResultModal = () => {
  showResultModal.value = false
}

const close = async () => {
  try {
    await callModLua("career_modules_roadsideServiceComputer.closeMenu")
  } catch (e) {
    console.error('Failed to close roadside service via module:', e)
  }
  // Hard fallback so Escape / X never strand the player in this route.
  try {
    await callModLua("career_career.closeAllMenus")
  } catch (_) {
    lua.extensions?.ui_router?.navigate?.('play')
  }
}

onMounted(() => {
  loadData()
})
</script>

<style scoped lang="scss">
.roadside-service-wrapper {
  display: flex;
  justify-content: flex-start;
  align-items: center;
  height: 100%;
  padding: 2rem;
}

.roadside-service-container {
  width: 100%;
  max-width: 700px;
  background: rgba(0, 0, 0, 0.85);
  border-radius: 8px;
  padding: 1.5rem;
  color: white;
}

.main-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 1.5rem;
  padding-bottom: 1rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.2);

  .header-titles {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }

  h1 {
    margin: 0;
    font-size: 1.75rem;
    font-weight: 600;
  }

  .spot-name {
    font-size: 1rem;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.7);
  }

  .close-button {
    background: transparent;
    border: none;
    color: white;
    cursor: pointer;
    padding: 0.5rem;
    border-radius: 4px;
    transition: background-color 0.2s;

    &:hover {
      background: rgba(255, 255, 255, 0.1);
    }
  }
}

.loading-state, .error-state {
  text-align: center;
  padding: 3rem;
  color: rgba(255, 255, 255, 0.7);
}

.error-state {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  align-items: center;
}

.vehicle-info {
  background: rgba(255, 255, 255, 0.1);
  border-radius: 6px;
  padding: 1rem;
  margin-bottom: 1rem;

  .vehicle-name {
    font-size: 1.25rem;
    font-weight: 600;
  }

  .vehicle-details {
    font-size: 0.9rem;
    color: rgba(255, 255, 255, 0.7);
    margin-top: 0.25rem;
  }
}

.service-note {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.75rem 1rem;
  background: rgba(204, 76, 0, 0.3);
  border-radius: 6px;
  margin-bottom: 1.5rem;
  font-size: 0.9rem;
  color: rgba(255, 255, 255, 0.9);

  .note-icon {
    font-size: 1.1rem;
  }
}

.services-grid {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.service-tile {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 1.25rem;
  background: rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  cursor: pointer;
  transition: all 0.2s;
  border: 2px solid transparent;

  &:hover:not(.disabled) {
    background: rgba(255, 255, 255, 0.15);
    border-color: #cc4c00;
  }

  &:focus:not(.disabled) {
    outline: none;
    border-color: #cc4c00;
  }

  &.disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  &.unavailable {
    opacity: 0.4;
  }

  .service-icon {
    width: 48px;
    height: 48px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(204, 76, 0, 0.3);
    border-radius: 8px;
    flex-shrink: 0;

    :deep(svg) {
      width: 28px;
      height: 28px;
      fill: white;
    }
  }

  .service-content {
    flex: 1;

    .service-label {
      font-size: 1.2rem;
      font-weight: 600;
      margin-bottom: 0.25rem;
    }

    .service-description {
      font-size: 0.9rem;
      color: rgba(255, 255, 255, 0.7);
    }

    .service-cost {
      margin-top: 0.5rem;
      font-size: 1rem;

      .cost-label {
        color: rgba(255, 255, 255, 0.7);
        margin-right: 0.5rem;
      }

      .cost-value {
        font-weight: 600;
        color: #4caf50;

        &.cannot-afford {
          color: #f44336;
        }
      }
    }

    .service-reason {
      margin-top: 0.5rem;
      font-size: 0.85rem;
      color: rgba(255, 200, 100, 0.9);
      font-style: italic;
    }
  }
}

.service-hint {
  margin-top: 0.35rem;
  font-size: 0.8rem;
  color: rgba(255, 255, 255, 0.55);
}

.repair-detail {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  max-height: min(70vh, 640px);
}

.detail-summary {
  background: rgba(255, 255, 255, 0.1);
  border-radius: 6px;
  padding: 1rem;
}

.detail-total {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1rem;

  .detail-total-label {
    color: rgba(255, 255, 255, 0.75);
  }

  .detail-total-value {
    font-size: 1.4rem;
    font-weight: 700;
    color: #4caf50;

    &.cannot-afford {
      color: #f44336;
    }
  }
}

.detail-subtotals {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  margin-top: 0.75rem;
  font-size: 0.85rem;
  color: rgba(255, 255, 255, 0.7);
}

.damage-list-header {
  font-weight: 600;
  font-size: 1rem;
}

.damage-list {
  overflow-y: auto;
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding-right: 0.25rem;
  max-height: 40vh;
}

.damage-line {
  background: rgba(255, 255, 255, 0.06);
  border-left: 3px solid rgba(255, 255, 255, 0.25);
  border-radius: 4px;
  padding: 0.65rem 0.75rem;

  &.kind-broken { border-left-color: #f44336; }
  &.kind-soft { border-left-color: #ff9800; }
  &.kind-cosmetic { border-left-color: #9c27b0; }
  &.kind-state { border-left-color: #2196f3; }
  &.kind-tire { border-left-color: #4caf50; }
  &.kind-info { border-left-color: rgba(255, 255, 255, 0.35); }
}

.damage-line-main {
  display: flex;
  justify-content: space-between;
  gap: 0.75rem;
  font-weight: 600;
}

.damage-cost {
  white-space: nowrap;
  color: rgba(255, 255, 255, 0.9);
}

.damage-detail {
  margin-top: 0.2rem;
  font-size: 0.8rem;
  color: rgba(255, 255, 255, 0.6);
}

.damage-empty {
  color: rgba(255, 255, 255, 0.6);
  font-style: italic;
}

.show-more {
  align-self: center;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: rgba(255, 255, 255, 0.9);
  border-radius: 6px;
  padding: 0.45rem 0.9rem;
  cursor: pointer;
  font-size: 0.85rem;

  &:hover {
    background: rgba(255, 255, 255, 0.14);
  }
}

.detail-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.75rem;
  padding-top: 0.5rem;
  border-top: 1px solid rgba(255, 255, 255, 0.2);
}

.footer-info {
  margin-top: 1.5rem;
  padding-top: 1rem;
  border-top: 1px solid rgba(255, 255, 255, 0.2);
  display: flex;
  justify-content: flex-end;

  .player-money {
    .money-label {
      color: rgba(255, 255, 255, 0.7);
      margin-right: 0.5rem;
    }

    .money-value {
      font-weight: 600;
      font-size: 1.1rem;
    }
  }
}

.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  justify-content: center;
  align-items: center;
  z-index: 1000;
}

.modal-content {
  background: rgba(30, 30, 30, 0.95);
  border-radius: 8px;
  padding: 2rem;
  max-width: 400px;
  width: 90%;
  color: white;

  h2 {
    margin: 0 0 1rem 0;
    font-size: 1.5rem;
  }

  p {
    margin: 0 0 1.5rem 0;
    color: rgba(255, 255, 255, 0.8);
  }

  .modal-buttons {
    display: flex;
    justify-content: flex-end;
    gap: 1rem;
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s;
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
}
</style>
